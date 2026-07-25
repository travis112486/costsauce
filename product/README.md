# CostSauce

Price-drift radar for independent restaurants. Tracks ingredient purchase prices over time, flags
drift against a trailing 90-day average, and recalculates recipe food-cost % and suggested menu
prices whenever costs move.

## Run it

One command (requires [uv](https://docs.astral.sh/uv/)):

```
uv run app.py
```

`uv` reads the inline PEP 723 metadata at the top of `app.py` and installs FastAPI/Uvicorn
automatically — no venv or `pip install` needed. Open **http://localhost:8321**.

On first launch the app seeds a SQLite database (`costsauce.db`, created in the working
directory) with a demo restaurant, **The Copper Ladle**: 24 ingredients with ~10 weeks of price
history, and 8 recipes. The seed data is built with realistic drift (lime +31%, chicken breast
+14%, ground beef +9%, flour −3%, etc.) so the dashboard shows live alerts and costed menu items
immediately — nothing to configure before you see value.

## Features

- **Dashboard** — active drift alerts, top price movers, and a plate-cost table for every recipe
  with a status chip (ok / watch / danger) based on food-cost % vs. target.
- **Ingredients** — full list with latest price, trailing average, and drift %; per-ingredient
  price history; quick-entry purchase form (supports `each`/`lb`/`oz`/`kg`/`g`/`case` units, with
  optional invoice photo attached for reference).
- **Recipes** — builder with an ingredient picker; plate cost, food-cost %, and suggested price
  (rounded to the nearest $0.50) recalculate live as you add/remove ingredients or quantities.
- **Import** — paste or upload a CSV of purchases, or upload an invoice photo for manual
  side-by-side entry.
- **Settings** — target food-cost % and drift-alert threshold, restaurant name.

Ingredient entry does fuzzy matching: typing "CHKN BRST" against an existing "Chicken Breast"
suggests linking to the existing ingredient instead of creating a duplicate.

## CSV import format

Header row (case-insensitive), one purchase per row:

```
item,vendor,date,qty,unit,total
Chicken Wings,Reinhart Foodservice,2026-07-20,30,lb,85.50
```

- `unit` — `each`, `lb`, `oz`, `kg`, `g`, or `case`. Weight units are normalized against the
  ingredient's base unit; `case` requires a `qty_in_case` when entered manually via the form (the
  bulk CSV importer treats new ingredients as `each` unless the unit is a recognized weight unit).
- Unmatched item names create a new ingredient (category `Imported`); names that fuzzy-match an
  existing ingredient are linked to it instead.
- Rows with bad data (non-numeric qty/total, unsupported unit) are skipped and reported back in
  the response `errors` list rather than failing the whole import.

## Data model

SQLite, stdlib `sqlite3` (no ORM): `ingredients`, `purchases` (unit price normalized to the
ingredient's base unit at entry time), `recipes`, `recipe_items`, `invoices`, `settings`. See
`app.py` for the schema and the drift/costing engine (`get_ingredient_drift`, `cost_recipe`).

## Honest scope note

This is a v1 built for a single restaurant location, run locally. Invoice photo upload stores
the image for reference alongside a manual purchase entry — there is no OCR/auto-extraction yet;
that's a paid-tier roadmap item. There are no POS or vendor EDI integrations; all price data comes
in via manual entry or CSV paste/upload.
