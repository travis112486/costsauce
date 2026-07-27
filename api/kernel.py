"""The shared costing kernel. Pure functions only: no I/O, no DB, no FastAPI.

Contract: docs/superpowers/specs/2026-07-25-native-ios-app-design.md §8-§10.
Implemented three times — Python (this file), JavaScript (shared/kernel.js),
Swift (Phase 2a) — and pinned by shared/golden-vectors.json, which every
implementation must pass with exact string equality.

Internal arithmetic is fractions.Fraction (exact); every emitted number is a
Decimal quantized round-half-away-from-zero, matching Postgres round()."""
from __future__ import annotations

import re
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
