"""Generates shared/golden-vectors.json from an EXACT rational oracle.

Must never import api.kernel — the vectors exist to catch kernel bugs.
Every computation is fractions.Fraction; every emitted number is a string.

Run:  python tools/gen_golden_vectors.py

Regenerating is a CONTRACT CHANGE (spec §9: committed once); never
regenerate to make a failing kernel pass."""
import json
import pathlib
from datetime import date, timedelta
from fractions import Fraction

OUT = pathlib.Path(__file__).parent.parent / "shared" / "golden-vectors.json"

W = {"lb": Fraction(1), "oz": Fraction(1, 16),
     "kg": Fraction("2.2046226218"), "g": Fraction("0.0022046226218")}


def rha(x: Fraction, places: int) -> str:
    """round-half-away-from-zero, exact, as a fixed-point string."""
    scale = 10 ** places
    n, d = (x * scale).numerator, (x * scale).denominator
    q = (2 * n + d) // (2 * d) if n >= 0 else -((2 * (-n) + d) // (2 * d))
    sign = "-" if q < 0 else ""
    q = abs(q)
    if places == 0:
        return f"{sign}{q}"
    return f"{sign}{q // scale}.{q % scale:0{places}d}"


def norm_purchase(base_unit, qty, unit, total_price, qty_in_case):
    qty, total = Fraction(qty), Fraction(total_price)
    if qty <= 0 or total <= 0:
        return None
    if unit == "case":
        if not qty_in_case or Fraction(qty_in_case) <= 0:
            return None
        result = rha(qty * Fraction(qty_in_case), 4)
    elif base_unit == "each":
        if unit != "each":
            return None
        result = rha(qty, 4)
    else:
        if unit not in W or base_unit not in W:
            return None
        result = rha(qty * W[unit] / W[base_unit], 4)
    # A valid-looking input can still quantize to 0.0000 at 4dp (e.g. a
    # gram-scale purchase of a lb-tracked ingredient too small to register).
    # The DB's generated unit_price column is round(total/qty_base_units, 6),
    # so a zero qty_base_units would divide by zero before the CHECK
    # constraint ever fires -- the oracle treats underflow-to-zero as an
    # error, same as every other invalid input.
    if Fraction(result) <= 0:
        return None
    return result


def suggested(plate_cents, target_bp):
    num, den = plate_cents * 10000, target_bp * 50
    return -(-num // den) * 50


def fc_status(plate_cents, menu_cents, target_bp):
    fc = rha(Fraction(plate_cents * 100, menu_cents), 1)
    fc_f, target = Fraction(fc), Fraction(target_bp, 100)
    if fc_f <= target:
        return fc, "ok"
    if fc_f <= target + 2:
        return fc, "watch"
    return fc, "danger"


def drift(rows):
    live = [r for r in rows if not r["deleted"]]
    if not live:
        return None
    ordered = sorted(
        live, key=lambda r: (r["purchased_on"], r["recorded_at"], r["id"]),
        reverse=True)  # ISO date strings sort like dates
    latest = ordered[0]
    latest_on = date.fromisoformat(latest["purchased_on"])
    window_start = latest_on - timedelta(days=90)
    baseline = [r for r in ordered[1:]
                if date.fromisoformat(r["purchased_on"]) >= window_start]
    n = len(baseline)
    out = {"latest_price": latest["unit_price"],
           "latest_on": latest["purchased_on"],
           "window_start": window_start.isoformat(),
           "baseline_n": n, "trailing_avg": None, "drift_pct": None}
    if n == 0:
        return out
    avg = Fraction(sum(Fraction(r["unit_price"]) for r in baseline), n)
    out["trailing_avg"] = rha(avg, 6)
    if n >= 3:
        latest_p = Fraction(latest["unit_price"])
        out["drift_pct"] = rha((latest_p - avg) / avg * 100, 1)
    return out


def uid(n):
    return f"00000000-0000-7000-8000-{n:012x}"


def prow(d, price, rec="T00:00:00.000000Z", rid=0, deleted=False):
    return {"purchased_on": d, "recorded_at": d + rec, "id": uid(rid),
            "unit_price": price, "deleted": deleted}


def main():
    vectors = {
        "version": 1,
        "generated_by": "tools/gen_golden_vectors.py (fractions.Fraction oracle)",
    }

    np_cases = [
        ("kg to lb", "lb", "10", "kg", "55.10", None),
        ("g to lb", "lb", "500", "g", "4.00", None),
        ("oz to lb", "lb", "8", "oz", "2.00", None),
        ("lb identity", "lb", "12.5", "lb", "30.00", None),
        ("kg base from g", "kg", "750", "g", "6.00", None),
        ("oz base from kg", "oz", "1", "kg", "9.00", None),
        ("case each", "each", "2", "case", "40.00", "24"),
        ("case weight", "lb", "3", "case", "90.00", "10.5"),
        ("each plain", "each", "144", "each", "11.52", None),
        ("each rejects lb", "each", "2", "lb", "4.00", None),
        ("case missing qty_in_case", "lb", "2", "case", "4.00", None),
        ("zero qty", "lb", "0", "lb", "4.00", None),
        ("zero price", "lb", "1", "lb", "0", None),
        ("unknown unit", "lb", "1", "stone", "4.00", None),
        ("underflow to zero", "lb", "0.00001", "g", "4.00", None),
    ]
    vectors["normalize_purchase"] = []
    for name, b, q, u, t, qc in np_cases:
        expect = norm_purchase(b, q, u, t, qc)
        case = {"name": name, "base_unit": b, "qty": q, "unit": u,
                "total_price": t, "qty_in_case": qc}
        if expect is None:
            case["expect_error"] = True
        else:
            case["expect"] = expect
        vectors["normalize_purchase"].append(case)

    vectors["unit_price"] = [
        {"total_price": t, "qty_base_units": q,
         "expect": rha(Fraction(t) / Fraction(q), 6)}
        for t, q in [("55.10", "22.0462"), ("1.00", "3.0000"),
                     ("90.00", "31.5000"), ("11.52", "144.0000"),
                     ("2.00", "0.5000"), ("0.01", "0.0001")]
    ]

    # Full B3 sweep: every plate cost $1.00..$20.00 step $0.10, at the five
    # realistic targets. The old float formula was $0.50 high on 127 of
    # these; the exact expectations pin every one.
    vectors["suggested_price_cents"] = [
        {"plate_cents": pc, "target_bp": tbp, "expect": suggested(pc, tbp)}
        for tbp in (2500, 2800, 3000, 3200, 3500)
        for pc in range(100, 2001, 10)
    ]

    fc_cases = [(3004, 10000, 3000), (3005, 10000, 3000), (3205, 10000, 3000),
                (3200, 10000, 3000), (1, 10000, 3000), (9999, 10000, 3000),
                (2500, 10000, 2500), (331, 1100, 3000), (662, 1100, 3000)]
    vectors["fc_status"] = []
    for pc, mc, tbp in fc_cases:
        fc, st = fc_status(pc, mc, tbp)
        vectors["fc_status"].append(
            {"plate_cents": pc, "menu_cents": mc, "target_bp": tbp,
             "expect_fc": fc, "expect_status": st})

    drift_cases = [
        ("same-date tie broken by recorded_at", [
            prow("2026-07-01", "2.000000", rec="T08:00:00.000000Z", rid=1),
            prow("2026-07-01", "3.000000", rec="T09:00:00.000000Z", rid=2),
            prow("2026-06-01", "1.000000", rid=3),
            prow("2026-05-01", "1.000000", rid=4),
            prow("2026-04-20", "1.000000", rid=5)]),
        ("full tie broken by id", [
            prow("2026-07-01", "2.000000", rid=1),
            prow("2026-07-01", "3.000000", rid=2),
            prow("2026-06-01", "1.000000", rid=3),
            prow("2026-05-01", "1.000000", rid=4),
            prow("2026-04-20", "1.000000", rid=5)]),
        ("boundary minus-90 in minus-91 out", [
            prow("2024-01-01", "5.000000", rid=1),
            prow("2023-10-03", "4.000000", rid=2),
            prow("2023-10-02", "9.990000", rid=3),
            prow("2023-12-01", "4.000000", rid=4),
            prow("2023-11-01", "4.000000", rid=5)]),
        ("tombstone excluded", [
            prow("2026-07-01", "9.000000", rid=1, deleted=True),
            prow("2026-06-01", "2.000000", rid=2),
            prow("2026-05-01", "1.000000", rid=3),
            prow("2026-04-15", "1.000000", rid=4),
            prow("2026-04-01", "1.000000", rid=5)]),
        ("baseline floor two rows", [
            prow("2026-07-01", "2.000000", rid=1),
            prow("2026-06-01", "1.000000", rid=2),
            prow("2026-05-01", "1.000000", rid=3)]),
        ("single row no baseline", [prow("2026-07-01", "2.000000", rid=1)]),
        ("all tombstoned", [prow("2026-07-01", "2.000000", rid=1, deleted=True)]),
        ("negative drift", [
            prow("2026-07-01", "1.000000", rid=1),
            prow("2026-06-01", "2.000000", rid=2),
            prow("2026-05-01", "2.000000", rid=3),
            prow("2026-04-15", "2.000000", rid=4)]),
        ("repeating-decimal avg", [
            prow("2026-07-01", "2.000000", rid=1),
            prow("2026-06-01", "1.000000", rid=2),
            prow("2026-05-01", "1.000000", rid=3),
            prow("2026-04-15", "1.010000", rid=4)]),
    ]
    vectors["drift"] = [
        {"name": name, "rows": rows, "expect": drift(rows)}
        for name, rows in drift_cases
    ]

    OUT.parent.mkdir(exist_ok=True)
    OUT.write_text(json.dumps(vectors, indent=1) + "\n")
    print(f"wrote {OUT} "
          f"({sum(len(v) for v in vectors.values() if isinstance(v, list))} cases)")


if __name__ == "__main__":
    main()
