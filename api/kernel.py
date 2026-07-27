"""The shared costing kernel. Pure functions only: no I/O, no DB, no FastAPI.

Contract: docs/superpowers/specs/2026-07-25-native-ios-app-design.md §8-§10.
Implemented three times — Python (this file), JavaScript (shared/kernel.js),
Swift (Phase 2a) — and pinned by shared/golden-vectors.json, which every
implementation must pass with exact string equality.

Internal arithmetic is fractions.Fraction (exact); every emitted number is a
Decimal quantized round-half-away-from-zero, matching Postgres round()."""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import date, datetime, timedelta, timezone
from decimal import Decimal
from fractions import Fraction
from typing import Sequence


class KernelError(ValueError):
    """Invalid input to a kernel function. Routes map this to HTTP 400."""


def normalize_name(name: str) -> str:
    s = name.lower().strip()
    s = re.sub(r"[^a-z0-9\s]", "", s)
    s = re.sub(r"\s+", " ", s).strip()
    if s.endswith("s") and not s.endswith("ss") and len(s) > 3:
        s = s[:-1]
    return s


def match_ingredient(
    name: str, candidates: Sequence[tuple[str, str]]
) -> tuple[str, str, str] | None:
    """Port of product/app.py:find_ingredient_match, made pure and org-safe:
    the caller supplies the org-scoped candidate list in a deterministic
    order (created_at, id) — first match wins, so order is part of the
    contract."""
    norm = normalize_name(name)
    if not norm:
        return None
    for cid, cname in candidates:
        if normalize_name(cname) == norm:
            return (cid, cname, "exact")
    for cid, cname in candidates:
        cn = normalize_name(cname)
        if norm in cn or cn in norm:
            return (cid, cname, "fuzzy")
    return None


# Exact contract constants (spec §9 / legacy WEIGHT_TO_LB). Fractions so
# every conversion stays rational until the final quantize.
WEIGHT_TO_LB: dict[str, Fraction] = {
    "lb": Fraction(1),
    "oz": Fraction(1, 16),
    "kg": Fraction("2.2046226218"),
    "g": Fraction("0.0022046226218"),
}
BASE_UNITS = ("lb", "oz", "kg", "g", "each")


def round_half_away(x: Fraction, places: int) -> Decimal:
    """Round-half-away-from-zero at `places` decimals — Postgres round()
    semantics, the single rounding mode of the whole contract."""
    scale = 10 ** places
    scaled = x * scale
    n, d = scaled.numerator, scaled.denominator
    if n >= 0:
        q = (2 * n + d) // (2 * d)
    else:
        q = -((2 * (-n) + d) // (2 * d))
    return Decimal(q).scaleb(-places).quantize(Decimal(1).scaleb(-places))


def normalize_purchase(
    base_unit: str,
    qty: Decimal,
    unit: str,
    total_price: Decimal,
    qty_in_case: Decimal | None = None,
) -> Decimal:
    """qty entered in `unit` -> quantity in the ingredient's base unit,
    quantized to 4dp (numeric(14,4)). Raises KernelError on bad input."""
    if qty is None or qty <= 0 or total_price is None or total_price <= 0:
        raise KernelError("qty and total_price must be positive")
    if base_unit not in BASE_UNITS:
        raise KernelError(f"unknown base_unit {base_unit!r}")
    unit = (unit or "").strip().lower()
    if unit == "case":
        if not qty_in_case or qty_in_case <= 0:
            raise KernelError("qty_in_case is required when unit is 'case'")
        base_qty = Fraction(qty) * Fraction(qty_in_case)
    elif base_unit == "each":
        if unit != "each":
            raise KernelError(
                "this ingredient is tracked 'each' — use unit 'each' or 'case'")
        base_qty = Fraction(qty)
    else:
        if unit not in WEIGHT_TO_LB:
            raise KernelError(
                f"unsupported unit {unit!r} for a weight-tracked ingredient")
        base_qty = Fraction(qty) * WEIGHT_TO_LB[unit] / WEIGHT_TO_LB[base_unit]
    result = round_half_away(base_qty, 4)
    if result <= 0:
        raise KernelError(
            "quantity is too small to register at 4 decimal places")
    return result


def unit_price(total_price: Decimal, qty_base_units: Decimal) -> Decimal:
    """Mirror of the DB generated column: round(total/qty, 6)."""
    if qty_base_units <= 0 or total_price <= 0:
        raise KernelError("total_price and qty_base_units must be positive")
    return round_half_away(Fraction(total_price) / Fraction(qty_base_units), 6)


def suggested_price_cents(plate_cents: int, target_bp: int) -> int:
    """spec §8: ceil(plate_cents * 100 / target_pct / 50) * 50, in pure
    integers. target_bp is target percent x 100 (30.00% -> 3000)."""
    if target_bp <= 0:
        raise KernelError("target_bp must be positive")
    if plate_cents < 0:
        raise KernelError("plate_cents must be non-negative")
    num = plate_cents * 10000
    den = target_bp * 50
    return -(-num // den) * 50


def fc_status(plate_cents: int, menu_cents: int, target_bp: int) -> tuple[Decimal, str]:
    """Food-cost percent rounded to 1dp; status compared on the ROUNDED
    value (B4 fix)."""
    if menu_cents <= 0:
        raise KernelError("menu_cents must be positive")
    fc_rounded = round_half_away(Fraction(plate_cents * 100, menu_cents), 1)
    target = Fraction(target_bp, 100)
    fc_frac = Fraction(fc_rounded)
    if fc_frac <= target:
        status = "ok"
    elif fc_frac <= target + 2:
        status = "watch"
    else:
        status = "danger"
    return fc_rounded, status


MIN_BASELINE_N = 3
DRIFT_WINDOW_DAYS = 90


def canonical_recorded_at(dt: datetime) -> str:
    """The one cross-language encoding of recorded_at."""
    return dt.astimezone(timezone.utc).strftime("%Y-%m-%dT%H:%M:%S.%fZ")


@dataclass(frozen=True)
class PurchaseRow:
    purchased_on: date
    recorded_at: str          # canonical_recorded_at() encoding
    id: str                   # lowercase uuid string
    unit_price: Decimal
    deleted: bool = False


@dataclass(frozen=True)
class DriftResult:
    latest_price: Decimal
    latest_on: date
    window_start: date
    baseline_n: int
    trailing_avg: Decimal | None   # 6dp
    drift_pct: Decimal | None      # 1dp; None below MIN_BASELINE_N


def drift(rows) -> DriftResult | None:
    """spec §10, exactly: ordering rule, latest = first, positional rows[1:]
    baseline, 90-day window anchored on latest_on, tombstones excluded,
    baseline floor instead of a dishonest 0.0."""
    live = [r for r in rows if not r.deleted]
    if not live:
        return None
    ordered = sorted(
        live,
        key=lambda r: (r.purchased_on.toordinal(), r.recorded_at, r.id),
        reverse=True,
    )
    latest = ordered[0]
    window_start = latest.purchased_on - timedelta(days=DRIFT_WINDOW_DAYS)
    baseline = [r for r in ordered[1:] if r.purchased_on >= window_start]
    n = len(baseline)
    if n == 0:
        return DriftResult(latest.unit_price, latest.purchased_on,
                           window_start, 0, None, None)
    avg = Fraction(sum(Fraction(r.unit_price) for r in baseline), n)
    trailing_avg = round_half_away(avg, 6)
    if n < MIN_BASELINE_N:
        return DriftResult(latest.unit_price, latest.purchased_on,
                           window_start, n, trailing_avg, None)
    pct = (Fraction(latest.unit_price) - avg) / avg * 100
    return DriftResult(latest.unit_price, latest.purchased_on, window_start,
                       n, trailing_avg, round_half_away(pct, 1))
