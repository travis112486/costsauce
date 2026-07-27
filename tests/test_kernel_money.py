from decimal import Decimal
from fractions import Fraction
import pytest
from api.kernel import (
    KernelError, round_half_away, normalize_purchase, unit_price,
    suggested_price_cents, fc_status,
)


def test_round_half_away():
    assert round_half_away(Fraction(1, 8), 2) == Decimal("0.13")     # 0.125 up
    assert round_half_away(Fraction(-1, 8), 2) == Decimal("-0.13")   # away from zero
    assert round_half_away(Fraction(25, 1000), 2) == Decimal("0.03") # not banker's
    assert str(round_half_away(Fraction(3), 1)) == "3.0"             # scale kept


def test_normalize_purchase_paths():
    assert normalize_purchase("each", Decimal("2"), "case", Decimal("40"),
                              Decimal("24")) == Decimal("48.0000")
    assert normalize_purchase("lb", Decimal("10"), "kg",
                              Decimal("55.10")) == Decimal("22.0462")
    assert normalize_purchase("lb", Decimal("500"), "g",
                              Decimal("4.00")) == Decimal("1.1023")
    assert normalize_purchase("lb", Decimal("8"), "oz",
                              Decimal("2.00")) == Decimal("0.5000")
    with pytest.raises(KernelError):   # each-tracked rejects weight units
        normalize_purchase("each", Decimal("2"), "lb", Decimal("4.00"))
    with pytest.raises(KernelError):   # case requires qty_in_case
        normalize_purchase("lb", Decimal("2"), "case", Decimal("4.00"))
    with pytest.raises(KernelError):
        normalize_purchase("lb", Decimal("0"), "lb", Decimal("4.00"))
    with pytest.raises(KernelError):
        normalize_purchase("lb", Decimal("1"), "lb", Decimal("0"))
    with pytest.raises(KernelError):
        normalize_purchase("lb", Decimal("1"), "stone", Decimal("4.00"))


def test_unit_price_mirrors_db_generated_column():
    assert unit_price(Decimal("55.10"), Decimal("22.0462")) == Decimal("2.499297")
    assert unit_price(Decimal("1.00"), Decimal("3.0000")) == Decimal("0.333333")


def test_suggested_price_b3_boundary():
    # THE B3 case: plate $4.20 at 30% -> exactly $14.00, never $14.50.
    assert suggested_price_cents(420, 3000) == 1400
    assert suggested_price_cents(421, 3000) == 1450
    assert suggested_price_cents(500, 3000) == 1700  # 16.666.. -> 17.00
    with pytest.raises(KernelError):
        suggested_price_cents(420, 0)


def test_fc_status_compares_rounded_b4():
    # 30.04% rounds to 30.0 <= 30 -> "ok" (legacy compared unrounded: "watch")
    fc, status = fc_status(3004, 10000, 3000)
    assert (str(fc), status) == ("30.0", "ok")
    fc, status = fc_status(3005, 10000, 3000)
    assert (str(fc), status) == ("30.1", "watch")
    fc, status = fc_status(3205, 10000, 3000)
    assert (str(fc), status) == ("32.1", "danger")
    fc, status = fc_status(3200, 10000, 3000)   # exactly target+2 still watch
    assert (str(fc), status) == ("32.0", "watch")
