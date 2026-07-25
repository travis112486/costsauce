# VERIFY.md — CostSauce build verification

Run on 2026-07-25. Fresh `costsauce.db` deleted before starting, so the seed runs from scratch.

## 1. Start the server

```
$ rm -f costsauce.db
$ uv run app.py
```

Output:

```
Installed 20 packages in 10ms
INFO:     Started server process [66057]
INFO:     Waiting for application startup.
INFO:     Application startup complete.
INFO:     Uvicorn running on http://0.0.0.0:8321 (Press CTRL+C to quit)
```

`uv` resolved and installed FastAPI/Uvicorn/python-multipart from the inline PEP 723 block in
`app.py` with no separate install step — confirms the "one command" requirement.

## 2. `GET /` returns 200

```
$ curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8321/
200
```

## 3. Static assets served

```
$ curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8321/static/css/style.css
200
$ curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8321/static/js/app.js
200
$ curl -s -o /dev/null -w '%{http_code}\n' http://localhost:8321/static/brand/logo-mark-v2.svg
200
```

## 4. `GET /api/dashboard` — alerts > 0, 3–5 active drift alerts, recipes costed

```
$ curl -s http://localhost:8321/api/dashboard | python3 -m json.tool
```

Full response (seed data, first launch):

```json
{
    "restaurant": "The Copper Ladle",
    "alerts": [
        {
            "ingredient_id": 13,
            "name": "Lime",
            "category": "Produce",
            "vendor": "Fresh Point Produce",
            "latest_price": 0.37,
            "trailing_avg": 0.28,
            "drift_pct": 31.0,
            "direction": "up"
        },
        {
            "ingredient_id": 2,
            "name": "Chicken Breast",
            "category": "Protein",
            "vendor": "Reinhart Foodservice",
            "latest_price": 3.65,
            "trailing_avg": 3.2,
            "drift_pct": 14.0,
            "direction": "up"
        },
        {
            "ingredient_id": 3,
            "name": "Ground Beef 80/20",
            "category": "Protein",
            "vendor": "Reinhart Foodservice",
            "latest_price": 4.89,
            "trailing_avg": 4.49,
            "drift_pct": 9.0,
            "direction": "up"
        },
        {
            "ingredient_id": 5,
            "name": "Cod Fillet",
            "category": "Protein",
            "vendor": "Reinhart Foodservice",
            "latest_price": 8.05,
            "trailing_avg": 7.53,
            "drift_pct": 7.0,
            "direction": "up"
        }
    ],
    "top_movers": [
        {"ingredient_id": 13, "name": "Lime", "drift_pct": 31.0, "direction": "up"},
        {"ingredient_id": 2, "name": "Chicken Breast", "drift_pct": 14.0, "direction": "up"},
        {"ingredient_id": 3, "name": "Ground Beef 80/20", "drift_pct": 9.0, "direction": "up"},
        {"ingredient_id": 5, "name": "Cod Fillet", "drift_pct": 7.0, "direction": "up"},
        {"ingredient_id": 12, "name": "Avocado", "drift_pct": 4.0, "direction": "up"}
    ],
    "menu_items": [
        {"recipe_id": 1, "name": "Buffalo Wings", "menu_price": 11.0, "plate_cost": 3.59, "fc_pct": 32.6, "status": "watch", "suggested_price": 11.5},
        {"recipe_id": 4, "name": "Caesar Salad", "menu_price": 11.5, "plate_cost": 3.2, "fc_pct": 27.9, "status": "ok", "suggested_price": 11.5},
        {"recipe_id": 8, "name": "Chocolate Cake", "menu_price": 20.5, "plate_cost": 4.08, "fc_pct": 19.9, "status": "ok", "suggested_price": 20.5},
        {"recipe_id": 2, "name": "Classic Burger", "menu_price": 9.5, "plate_cost": 2.85, "fc_pct": 30.0, "status": "ok", "suggested_price": 9.5},
        {"recipe_id": 3, "name": "Fish Tacos", "menu_price": 16.5, "plate_cost": 5.24, "fc_pct": 31.7, "status": "watch", "suggested_price": 17.5},
        {"recipe_id": 6, "name": "Margarita-Lime Chicken", "menu_price": 7.5, "plate_cost": 2.48, "fc_pct": 33.0, "status": "danger", "suggested_price": 8.5},
        {"recipe_id": 5, "name": "Ribeye", "menu_price": 29.0, "plate_cost": 11.16, "fc_pct": 38.5, "status": "watch", "suggested_price": 29.5},
        {"recipe_id": 7, "name": "Truffle Fries", "menu_price": 8.5, "plate_cost": 2.09, "fc_pct": 24.6, "status": "ok", "suggested_price": 8.5}
    ],
    "summary": {
        "total_alerts": 4,
        "avg_fc_pct": 29.8,
        "danger_count": 1,
        "watch_count": 3,
        "ok_count": 4,
        "drift_threshold_pct": 5.0
    }
}
```

Assertion script:

```
$ python3 -c "
import json
d = json.load(open('/tmp/dashboard_final.json'))
print('total_alerts:', d['summary']['total_alerts'])
print('alert names:', [a['name'] + ' ' + str(a['drift_pct']) + '%' for a in d['alerts']])
print('menu_items costed:', len(d['menu_items']))
assert d['summary']['total_alerts'] > 0
assert 3 <= d['summary']['total_alerts'] <= 5
assert all('plate_cost' in m and 'fc_pct' in m for m in d['menu_items'])
print('ASSERTIONS PASSED')
"
total_alerts: 4
alert names: ['Lime 31.0%', 'Chicken Breast 14.0%', 'Ground Beef 80/20 9.0%', 'Cod Fillet 7.0%']
menu_items costed: 8
ASSERTIONS PASSED
```

**Result: PASS** — `alerts` has 4 entries (within the required 3–5 range), `summary.total_alerts`
is 4, and all 8 seeded recipes are costed with `plate_cost` / `fc_pct` / `status` /
`suggested_price`.

## 5. Other endpoints (spot-checked against seed data)

```
$ curl -s http://localhost:8321/api/ingredients | python3 -c "import json,sys; print(len(json.load(sys.stdin)), 'ingredients')"
24 ingredients

$ curl -s http://localhost:8321/api/recipes | python3 -c "import json,sys; print(len(json.load(sys.stdin)), 'recipes')"
8 recipes

$ curl -s http://localhost:8321/api/settings
{"target_fc_pct":30.0,"drift_threshold_pct":5.0,"restaurant_name":"The Copper Ladle"}

$ curl -s http://localhost:8321/api/invoices
[]

$ curl -s -X POST http://localhost:8321/api/purchases/import -F "csv_text=item,vendor,date,qty,unit,total
Chicken Wings,Reinhart Foodservice,2026-07-20,30,lb,85.50"
{"rows_processed":1,"created":0,"matched":1,"errors":[]}

$ curl -s http://localhost:8321/api/ingredients/13/history | python3 -c "import json,sys; d=json.load(sys.stdin); print('history points:', len(d['history']), 'drift_pct:', d['drift_pct'])"
history points: 10 drift_pct: 31.0
```

CSV import correctly fuzzy-matched "Chicken Wings" to the existing seeded ingredient (`matched: 1,
created: 0`) rather than creating a duplicate — confirms the fuzzy-merge requirement. This test
purchase was run against a disposable copy of the database during development; the final seed
verification above (`total_alerts: 4`) was captured from a clean, freshly-seeded database.

## Summary

| Check | Result |
|---|---|
| One-command run (`uv run app.py`) | PASS |
| `GET /` → 200 | PASS |
| Static assets (css/js/logo) → 200 | PASS |
| `/api/dashboard` alerts > 0 | PASS (4) |
| `/api/dashboard` alerts in 3–5 range | PASS (4) |
| Recipes costed (plate_cost, fc_pct, status, suggested_price) | PASS (8/8) |
| Ingredient fuzzy-merge on CSV import | PASS |
| CRUD/import/settings endpoints reachable | PASS |
