# CostSauce — Product Build Spec (for the builder agent)

Build a **local-first web app** called **CostSauce** — "price-drift radar for independent restaurants."
A stranger must be able to run it with ONE command and immediately see value via pre-seeded demo data.

## Hard requirements
- Python 3.11+ FastAPI + SQLite (stdlib sqlite3, no ORM needed). Deps via `uv run` PEP 723 inline metadata in `app.py` so the run command is literally: `uv run app.py` (uv installs fastapi/uvicorn automatically). Port **8321**.
- Serve a single-page frontend from `static/` (vanilla JS + CSS, no build step, no npm).
- Brand: teal `#0F5E63`, amber `#E8A33D`, cream `#FAF6EF`, charcoal `#23282B`, paprika `#C4502F` for alerts. Fonts: Fraunces (headings) + Inter (body) from Google Fonts CDN. Logo at `static/brand/logo-mark-v2.svg` (copy from `../brand/`).
- Seed script runs automatically on first launch creating demo restaurant **"The Copper Ladle"** with ~18 ingredients with 8–12 weeks of price history (realistic drift: chicken +14%, beef +9%, lime +31%, flour −3%...), ~8 recipes (wings, burger, fish tacos, caesar salad, ribeye, margarita-lime chicken, truffle fries, chocolate cake) with menu prices, producing 3–5 active drift alerts out of the box.

## Data model (sqlite, file `costsauce.db` in cwd)
- `ingredients(id, name, base_unit, vendor, category)`
- `purchases(id, ingredient_id, date, qty, unit, total_price, unit_price, source)` — unit_price normalized to base_unit
- `recipes(id, name, menu_price, target_fc_pct)`
- `recipe_items(id, recipe_id, ingredient_id, qty_base_units)`
- `invoices(id, filename, uploaded_at, status)` — photo upload stored under `uploads/`, status manual/entered
- `settings(key, value)` — target_fc_pct default 30, drift_threshold_pct default 5

## Core logic
- Unit normalization: lb/oz/kg/g; each; case→each via pack size captured at entry (qty_in_case). Store normalized `unit_price` per base unit.
- Drift engine: latest unit_price vs trailing-90-day average unit_price → drift_pct. |drift| ≥ threshold ⇒ alert.
- Recipe costing: plate_cost = Σ(qty_base × latest unit_price); food_cost_pct = plate_cost/menu_price×100; status: ok / watch (within 2pts of target) / danger (over target). Suggested price = plate_cost/(target_pct/100) rounded up to .50.
- REST API: `/api/dashboard` (summary: menu items by status, top movers, alerts), `/api/ingredients` CRUD + `/api/ingredients/{id}/history`, `/api/purchases` POST (manual + CSV import endpoint accepting Sysco-ish CSV: item,vendor,date,qty,unit,total), `/api/recipes` CRUD, `/api/invoices` upload+list, `/api/settings` GET/PUT.
- Frontend pages (one SPA, tab nav): **Dashboard** (alert cards + plate-cost table with status chips + top price movers with sparkline-ish bars), **Ingredients** (table + price history mini-chart canvas + quick-entry purchase form with optional invoice photo attach), **Recipes** (builder with ingredient picker, live plate-cost + FC% + suggested price), **Import** (CSV paste/upload + invoice photo upload with side-by-side manual entry), **Settings**.
- Ingredient fuzzy-merge on entry: if typed name case-insensitively matches or is a substring of existing ("CHKN BRST" vs "chicken breast"), suggest/link instead of duplicating (simple normalization: lowercase, strip punctuation, singular-ish).

## Quality bar
- It must actually work: no placeholder buttons. Every form persists. Every number recalculates from stored data.
- Money: 2dp display; percentages 1dp.
- Empty states with helpful copy; demo seed means they never show on first run.
- Mobile-responsive (CSS grid/flex, works at 390px).
- Include `README.md`: one-command run, feature list, CSV format, honest scope note ("photo-assisted entry in v1 — OCR extraction is a paid-tier roadmap item; no POS/EDI integrations yet").
- Verify before finishing: start the server, curl `/api/dashboard` and assert JSON has alerts > 0 and recipes costed; curl `/` returns 200. Write test results to `VERIFY.md` with the actual commands + outputs.
- Do NOT use placeholders, mock data beyond the seed, or external APIs. No secrets. Keep everything inside this `product/` directory except copying the logo from `../brand/`.
