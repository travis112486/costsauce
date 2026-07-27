// tests/js/kernel.test.mjs
// Run: node --test tests/js/
import { test } from "node:test";
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";
import { dirname, join } from "node:path";
import {
  normalizePurchase, unitPrice, suggestedPriceCents, fcStatus, drift,
} from "../../shared/kernel.js";

const here = dirname(fileURLToPath(import.meta.url));
const V = JSON.parse(readFileSync(join(here, "../../shared/golden-vectors.json")));

test("normalize_purchase vectors", () => {
  for (const c of V.normalize_purchase) {
    const args = { baseUnit: c.base_unit, qty: c.qty, unit: c.unit,
                   totalPrice: c.total_price, qtyInCase: c.qty_in_case };
    if (c.expect_error) {
      assert.throws(() => normalizePurchase(args), undefined, c.name);
    } else {
      assert.equal(normalizePurchase(args), c.expect, c.name);
    }
  }
});

test("unit_price vectors", () => {
  for (const c of V.unit_price)
    assert.equal(unitPrice(c.total_price, c.qty_base_units), c.expect);
});

test("suggested_price_cents vectors", () => {
  for (const c of V.suggested_price_cents)
    assert.equal(suggestedPriceCents(c.plate_cents, c.target_bp), c.expect);
});

test("fc_status vectors", () => {
  for (const c of V.fc_status) {
    const { fc, status } = fcStatus(c.plate_cents, c.menu_cents, c.target_bp);
    assert.equal(fc, c.expect_fc);
    assert.equal(status, c.expect_status);
  }
});

test("drift vectors", () => {
  for (const c of V.drift)
    assert.deepEqual(drift(c.rows), c.expect, c.name);
});
