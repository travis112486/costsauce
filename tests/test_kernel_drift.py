from datetime import date, datetime, timezone
from decimal import Decimal
from api.kernel import PurchaseRow, drift, canonical_recorded_at


def row(d, price, rec="2026-01-01T00:00:00.000000Z", rid="0" * 32, deleted=False):
    return PurchaseRow(purchased_on=date.fromisoformat(d), recorded_at=rec,
                       id=rid, unit_price=Decimal(price), deleted=deleted)


def test_ordering_rule_breaks_same_date_ties():
    rows = [
        row("2026-07-01", "2.00", rec="2026-07-01T08:00:00.000000Z", rid="a"),
        row("2026-07-01", "3.00", rec="2026-07-01T09:00:00.000000Z", rid="b"),
        row("2026-06-01", "1.00"),
        row("2026-05-01", "1.00"),
        row("2026-04-20", "1.00"),
    ]
    r = drift(rows)
    assert r.latest_price == Decimal("3.00")     # later recorded_at wins
    # positional rows[1:]: the same-date sibling (2.00) IS in the baseline
    assert r.baseline_n == 4
    # avg = (2+1+1+1)/4 = 1.25 ; drift = (3-1.25)/1.25*100 = 140.0
    assert str(r.drift_pct) == "140.0"


def test_id_breaks_full_ties():
    rows = [
        row("2026-07-01", "2.00", rid="a"),
        row("2026-07-01", "3.00", rid="b"),
        row("2026-06-01", "1.00", rid="c"),
        row("2026-05-01", "1.00", rid="d"),
        row("2026-04-01", "1.00", rid="e"),
    ]
    assert drift(rows).latest_price == Decimal("3.00")  # higher id wins


def test_window_anchored_on_latest_not_today():
    rows = [
        row("2024-01-01", "5.00", rid="z"),          # ancient latest
        row("2023-10-03", "4.00", rid="a"),          # exactly -90 -> IN
        row("2023-10-02", "9.99", rid="b"),          # -91 -> OUT
        row("2023-12-01", "4.00", rid="c"),
        row("2023-11-01", "4.00", rid="d"),
    ]
    r = drift(rows)
    assert r.window_start == date(2023, 10, 3)
    assert r.baseline_n == 3
    assert str(r.trailing_avg) == "4.000000"
    assert str(r.drift_pct) == "25.0"


def test_tombstones_are_invisible():
    rows = [
        row("2026-07-01", "9.00", rid="t", deleted=True),
        row("2026-06-01", "2.00", rid="a"),
        row("2026-05-01", "1.00", rid="b"),
        row("2026-04-15", "1.00", rid="c"),
        row("2026-04-01", "1.00", rid="d"),
    ]
    assert drift(rows).latest_price == Decimal("2.00")


def test_baseline_floor_refuses_drift_not_zero():
    rows = [row("2026-07-01", "2.00", rid="a"),
            row("2026-06-01", "1.00", rid="b"),
            row("2026-05-01", "1.00", rid="c")]
    r = drift(rows)
    assert r.baseline_n == 2
    assert r.drift_pct is None                 # never the dishonest 0.0
    assert str(r.trailing_avg) == "1.000000"   # avg still reported


def test_no_baseline_and_no_rows():
    r = drift([row("2026-07-01", "2.00")])
    assert (r.baseline_n, r.trailing_avg, r.drift_pct) == (0, None, None)
    assert drift([]) is None
    assert drift([row("2026-07-01", "2.00", deleted=True)]) is None


def test_canonical_recorded_at():
    dt = datetime(2026, 7, 1, 8, 30, 15, 123456, tzinfo=timezone.utc)
    assert canonical_recorded_at(dt) == "2026-07-01T08:30:15.123456Z"
