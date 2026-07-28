// tests/js/api.test.mjs
// Run: node --test tests/js/
//
// Pure, DOM-free coverage for web/js/api.mjs::ApiError's message-selection
// logic only. Everything else in api.mjs (setToken/getToken/clearToken,
// the api() fetch wrapper) touches localStorage/fetch/window and is
// exercised by Task 7's scripted smoke instead -- see api.mjs's own file
// header for why the module is safe to import here regardless (every
// browser-only reference lives inside a function body, not at module top
// level, so importing the module doesn't execute any of them).
import { test } from "node:test";
import assert from "node:assert/strict";
import { ApiError } from "../../web/js/api.mjs";

test("ApiError: string detail is used as the message verbatim", () => {
  const err = new ApiError(400, "bad request");
  assert.equal(err.message, "bad request");
});

test("ApiError: object detail with a .message field uses that message", () => {
  const err = new ApiError(409, { message: "duplicate ingredient" });
  assert.equal(err.message, "duplicate ingredient");
});

// Final fix wave, Minor-4: FastAPI's own 422 validation errors ship
// `detail` as a LIST of {loc, msg, type} objects -- a shape the fallback
// didn't handle before, so a validation failure's toast read the useless
// generic "HTTP 422" instead of surfacing FastAPI's own field-level
// message.
test("ApiError: list-shaped FastAPI validation detail uses detail[0].msg", () => {
  const err = new ApiError(422, [
    { loc: ["body", "qty"], msg: "field required", type: "missing" },
  ]);
  assert.equal(err.message, "field required");
});

test("ApiError: falls back to a generic 'HTTP <status>' message otherwise", () => {
  assert.equal(new ApiError(500, null).message, "HTTP 500");
  assert.equal(new ApiError(500, {}).message, "HTTP 500");
  assert.equal(new ApiError(422, []).message, "HTTP 422");
});
