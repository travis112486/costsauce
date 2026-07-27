"""The Python kernel vs the committed vectors. Exact string equality, zero
tolerance — a failure here is a CONTRACT violation, not a flake."""
import json
import pathlib
from datetime import date
from decimal import Decimal
import pytest
from api import kernel

VECTORS = json.loads(
    (pathlib.Path(__file__).parent.parent / "shared" / "golden-vectors.json")
    .read_text())


@pytest.mark.parametrize("case", VECTORS["normalize_purchase"],
                         ids=lambda c: c["name"])
def test_normalize_purchase(case):
    args = (case["base_unit"], Decimal(case["qty"]), case["unit"],
            Decimal(case["total_price"]),
            Decimal(case["qty_in_case"]) if case["qty_in_case"] else None)
    if case.get("expect_error"):
        with pytest.raises(kernel.KernelError):
            kernel.normalize_purchase(*args)
    else:
        assert str(kernel.normalize_purchase(*args)) == case["expect"]


@pytest.mark.parametrize("case", VECTORS["unit_price"])
def test_unit_price(case):
    got = kernel.unit_price(Decimal(case["total_price"]),
                            Decimal(case["qty_base_units"]))
    assert str(got) == case["expect"]


@pytest.mark.parametrize("case", VECTORS["suggested_price_cents"])
def test_suggested_price(case):
    assert kernel.suggested_price_cents(
        case["plate_cents"], case["target_bp"]) == case["expect"]


@pytest.mark.parametrize("case", VECTORS["fc_status"])
def test_fc_status(case):
    fc, status = kernel.fc_status(case["plate_cents"], case["menu_cents"],
                                  case["target_bp"])
    assert (str(fc), status) == (case["expect_fc"], case["expect_status"])


@pytest.mark.parametrize("case", VECTORS["drift"], ids=lambda c: c["name"])
def test_drift(case):
    rows = [kernel.PurchaseRow(
        purchased_on=date.fromisoformat(r["purchased_on"]),
        recorded_at=r["recorded_at"], id=r["id"],
        unit_price=Decimal(r["unit_price"]), deleted=r["deleted"])
        for r in case["rows"]]
    got = kernel.drift(rows)
    exp = case["expect"]
    if exp is None:
        assert got is None
        return
    assert str(got.latest_price) == exp["latest_price"]
    assert got.latest_on.isoformat() == exp["latest_on"]
    assert got.window_start.isoformat() == exp["window_start"]
    assert got.baseline_n == exp["baseline_n"]
    assert (str(got.trailing_avg) if got.trailing_avg is not None else None) \
        == exp["trailing_avg"]
    assert (str(got.drift_pct) if got.drift_pct is not None else None) \
        == exp["drift_pct"]
