# Phase 1d Deploy Runbook: web SPA go-live and acceptance smoke

Audience: whoever stands up the first real host for the FastAPI app now
that it serves the migrated SPA (`web/`) at `/app/` alongside the JSON API.
Assumes the reader has already applied `0001`-`0016` (phases 1a-1c) and has
no memory of how Phase 1d was built. Nothing in this document changes the
database schema — Phase 1d shipped zero new migrations. It is entirely an
API-code and static-asset change: two new mounts (`/app`, `/shared`), a new
`/config` endpoint, a new `POST /locations/{id}/purchases/import` CSV route,
and the `web/` + `shared/kernel.js` files themselves.

**Target project:** `khohfrfqzbieaiikqlsa`. Same project as Phases 1a-1c. No
new migrations to apply for this phase — skip straight to "What shipped"
below if you're only interested in the API/host side.

---

## 1. What shipped

- **`web/`**: a no-build, no-framework SPA (`index.html` + `js/*.mjs` ES
  modules + `css/style.css`). Tab-based (ingredients, purchases, recipes,
  CSV import, dashboard, settings) — no client-side router, no deep links.
  Served same-origin at `/app/` via `StaticFiles(..., html=True)`
  (`api/main.py`), so `GET /app/` returns `index.html` directly.
- **`shared/kernel.js`**: a JS port of the costing kernel
  (`api/kernel.py`), used ONLY for optimistic client-side preview math
  (e.g. live plate-cost while editing a recipe line). It is not a second
  source of truth — every number that lands in the database is computed and
  returned by the server; the client never re-derives or re-rounds a
  server-provided string. Served at `/shared/kernel.js` via a second
  `StaticFiles` mount, same file the node:test suite imports directly by
  filesystem path.
- **`GET /config`**: returns `{"supabase_url": ..., "supabase_anon_key":
  ...}` from environment variables so the SPA can initialize the Supabase
  JS client for magic-link auth without either value being baked into a
  static file.
- **`POST /locations/{id}/purchases/import`**: CSV purchase import
  (`api/routes/imports.py`), the web-only replacement for the legacy
  `product/app.py` endpoint of the same purpose. Auto-creates unmatched
  ingredients with `source='import'`, `category='Imported'`. The
  quick-entry purchase path in the UI still requires an explicit,
  already-created ingredient — CSV import is the only auto-create path.
- **`POST /auth/reviewer-otp`**: unchanged from Phase 1a/1b, but now the
  primary locally-testable sign-in path for this runbook's smoke script,
  since a real magic-link round trip needs a live Supabase project and an
  inbox.
- **No CORS middleware.** The API and the SPA are same-origin by
  construction (`/app/` and the JSON routes are both served by the one
  FastAPI process) — there was never a cross-origin request to allow.
- **`product/` and `site/` are untouched and stay frozen** — evidence /
  marketing snapshots of the pre-1d product, not a live deployment target.
  `product/app.py`'s CSV-import and settings endpoints are the ones
  `api/routes/imports.py` and `api/routes/locations.py::update_location`
  replace. Once a real host serves `/app/` from this repo, `product/` is
  **fully superseded** and should be retired (its Vercel deployment, if
  any, taken down or left to expire) — nothing in Phase 1d deletes it from
  the repo, this is a deployment-target decision for whoever owns hosting.
- **No new npm/build dependency.** `web/` and `shared/kernel.js` are plain
  ES modules; `shared/kernel.js`'s own tests run under Node's built-in
  `node:test`, no bundler, no package.json dependency tree to audit.

---

## 2. New environment variables for the future API host

Everything Phase 1a-1c already required (`DATABASE_URL`, `JWT_SECRET`,
`JWT_ISSUER`, `REVIEWER_OTP_ENABLED`/`REVIEWER_EMAIL`/`REVIEWER_CODE`/
`REVIEWER_USER_ID`, `RETURN_INVITE_TOKEN_ENABLED`, `PURGE_DATABASE_URL`)
still applies unchanged — see `phase-1a-deploy.md` §6-§8. Phase 1d adds
exactly two, both consumed only by `GET /config`:

| Var | Purpose |
|---|---|
| `SUPABASE_URL` | The Supabase project URL (`https://khohfrfqzbieaiikqlsa.supabase.co`). Handed to the SPA so it can call GoTrue directly for magic-link sign-in (`web/js/auth.mjs::requestMagicLink`). |
| `SUPABASE_ANON_KEY` | The project's anon/publishable key. Same audience as `SUPABASE_URL` — both are meant to be public, browser-visible values (that's what "anon key" means), not secrets. |

If either is unset, `/config` returns `null` for it and the SPA's
magic-link button fails client-side with a clear error — `/auth/reviewer-otp`
still works either way since it never reads `/config`. This is exactly the
state the acceptance smoke below runs in (both unset, reviewer OTP used
for auth).

**REVIEWER_USER_ID** for a real host should point at a real `auth.users`
row already provisioned by hand, per `phase-1a-deploy.md`'s operator
procedure — the smoke script below creates its own disposable one and is
not a template for production credentials.

---

## 3. Supabase Auth dashboard: magic-link redirect allowlist

`web/js/auth.mjs::magicLinkBody` sets `options.email_redirect_to` to
`${window.location.origin}/app/` — GoTrue silently drops that parameter
(falling back to the project's default site URL) unless it appears in the
project's own **Redirect URLs** allowlist. Before magic-link sign-in works
against a real host, add the exact URL to
`khohfrfqzbieaiikqlsa`'s Auth dashboard:

```
https://<host>/app/
```

- Trailing slash matters: the code always sends `<origin>/app/`, not
  `<origin>/app`. Add the literal value the code sends, not a normalized
  variant.
- Add one entry per real host (a staging host and the eventual production
  host are two different origins, hence two different allowlist entries).
- `http://127.0.0.1:8400/app/` (or whatever local port is used) is only
  needed here if someone intends to click through an actual magic-link
  email against local dev — the acceptance smoke below avoids that
  entirely by using the reviewer-OTP path instead.

This is a **console/dashboard change**, not something `apply_migration` or
any file in this repo can perform — track it as a manual step whenever a
new host goes live, the same way `phase-1a-deploy.md`'s reviewer-account
provisioning is a manual step.

---

## 4. Acceptance smoke — scripted, local, reproducible

This is the phase's end-to-end proof: a real (disposable) Postgres, a real
FastAPI process, real HTTP calls, no mocks. Run it locally before trusting
any host deploy; the exact commands below are the acceptance record, run
2026-07-27 against worktree HEAD `73c40c9` (1443 pytest + 64 node cases
green at the time).

### 4.1 Start a disposable Postgres 17

```bash
docker run -d --name cs-1d-smoke -e POSTGRES_PASSWORD=postgres -p 55440:5432 postgres:17
# wait for readiness
for i in $(seq 1 30); do
  docker exec cs-1d-smoke pg_isready -U postgres >/dev/null 2>&1 && break
  sleep 1
done
```

### 4.2 Bootstrap schema + reviewer identity + org/location

A short throwaway script (not committed — lives only in a scratch dir),
reusing `tests.conftest.apply_migrations` and `tests.factories` exactly as
the test suite does, so the seeded state is provably the same shape the
1443 pytest cases already exercise. Save it anywhere (e.g.
`scratch/bootstrap.py`) and run it **from the repo root** with `uv run
python`, so `tests` resolves as a plain top-level import the same way
`pyproject.toml`'s `pythonpath = ["."]` makes it resolve for pytest — no
`sys.path` hacking needed as long as the working directory is the repo
root when this runs:

```python
# bootstrap.py — run as: uv run python scratch/bootstrap.py (from repo root)
import asyncio, os
import psycopg
from tests.conftest import apply_migrations
from tests.factories import make_org, add_member, make_location

REVIEWER_USER_ID = "00000000-0000-7000-8000-0000000d1d01"
REVIEWER_EMAIL = "reviewer@example.com"

async def main():
    conn = await psycopg.AsyncConnection.connect(os.environ["DB_URL"], autocommit=False)
    await conn.execute("DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public")
    await conn.execute("DROP SCHEMA IF EXISTS auth CASCADE; CREATE SCHEMA auth")
    await conn.execute(
        "CREATE TABLE auth.users (id uuid PRIMARY KEY, email text, "
        "raw_user_meta_data jsonb DEFAULT '{}')")
    await conn.commit()
    await apply_migrations(conn)  # applies 0001-0016, sets app_user/app_pw
    await conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (%s, %s)",
        (REVIEWER_USER_ID, REVIEWER_EMAIL))
    await conn.execute(
        "INSERT INTO profiles (user_id, contact_email, contact_email_verified_at) "
        "VALUES (%s, %s, now())", (REVIEWER_USER_ID, REVIEWER_EMAIL))
    org_id = await make_org(conn, "Smoke Test Diner")
    await add_member(conn, REVIEWER_USER_ID, org_id, "owner")
    location_id = await make_location(conn, org_id, "Smoke Test Main")
    await conn.commit()
    print(f"ORG_ID={org_id}\nLOCATION_ID={location_id}")

asyncio.run(main())
```

```bash
# from the repo root:
DB_URL="postgresql://postgres:postgres@127.0.0.1:55440/postgres" \
  uv run python scratch/bootstrap.py
# -> ORG_ID=019fa657-92db-748b-acb7-a231055f09e9
#    LOCATION_ID=019fa657-92e1-76e9-83bd-c7e085c8bd1b
```

`apply_migrations` itself runs `ALTER ROLE app_user LOGIN PASSWORD
'app_pw'` at the end (its own docstring — the disposable-container
equivalent of the by-hand operator step `phase-1a-deploy.md` documents for
a real Supabase project), so no separate password step is needed here.

### 4.3 Start the API

```bash
export JWT_SECRET="smoke-test-secret-1d"
export JWT_ISSUER="costsauce-tests"
export DATABASE_URL="postgres://app_user:app_pw@127.0.0.1:55440/postgres"
export REVIEWER_OTP_ENABLED=1
export REVIEWER_EMAIL="reviewer@example.com"
export REVIEWER_CODE="123456"
export REVIEWER_USER_ID="00000000-0000-7000-8000-0000000d1d01"
unset SUPABASE_URL SUPABASE_ANON_KEY   # /config returns nulls; fine, OTP doesn't need it
uv run uvicorn api.main:app --port 8400 &
```

`JWT_SECRET`/`JWT_ISSUER` here only have to match each other (the server
mints and verifies its own tokens via `/auth/reviewer-otp` + `api/auth.py`)
— no separate local minting step is needed, unlike some of the test
suite's own fixtures which set a Supabase-shaped issuer to match the real
project.

### 4.4 Exercise the flow via curl, as the reviewer token

Every command below is copy-paste runnable in sequence (bash), against the
server from §4.3, using the `$ORG_ID`/`$LOC_ID` printed by §4.2's bootstrap
script. All of it ran against the container above and **passed** — the
inline comments after each block are the actual response bodies observed,
trimmed only where noted.

**1. `GET /config`**

```bash
curl -sS http://127.0.0.1:8400/config
```
```
{"supabase_url":null,"supabase_anon_key":null}
```

**2. `GET /app/` serves the SPA shell**

```bash
curl -sS http://127.0.0.1:8400/app/ | head -c 300
```
```
<!DOCTYPE html>
<html lang="en">
...
<title>CostSauce — Food Cost Analysis</title>
...
```

**3. `GET /shared/kernel.js` serves the kernel port**

```bash
curl -sS http://127.0.0.1:8400/shared/kernel.js | head -c 200
```
```
// shared/kernel.js
// The CostSauce costing kernel, JavaScript implementation. ES module, zero
// dependencies, Node >= 18 or any modern browser.
```

**4. `POST /auth/reviewer-otp` — sign in, capture the token**

```bash
RESP=$(curl -sS -X POST http://127.0.0.1:8400/auth/reviewer-otp \
  -H "Content-Type: application/json" \
  -d '{"email":"reviewer@example.com","code":"123456"}')
echo "$RESP"
TOKEN=$(echo "$RESP" | python3 -c "import sys,json; print(json.load(sys.stdin)['access_token'])")
```
```
{"access_token":"eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIwMDAwMDAwMC0wMDAwLTcwMDAtODAwMC0wMDAwMDAwZDFkMDEiLCJhdWQiOiJhdXRoZW50aWNhdGVkIiwiaXNzIjoiY29zdHNhdWNlLXRlc3RzIiwiZXhwIjoxNzg1MjA1ODA3fQ.kj6lavI7grkB-s_7nL7l3rjPwCt6n2mplDs9XnOa0lI"}
```

**5. `GET /me`**

```bash
curl -sS http://127.0.0.1:8400/me -H "Authorization: Bearer $TOKEN"
```
```json
{"user_id":"00000000-0000-7000-8000-0000000d1d01","contact_email":"reviewer@example.com",
 "contact_email_verified":true,"apple_linked":false,
 "memberships":[{"org_id":"019fa657-92db-748b-acb7-a231055f09e9","org_name":"Smoke Test Diner",
 "role":"owner","entitlement":{"plan":"starter","max_locations":1,"max_invoices_per_month":30,
 "max_recipes":25,"max_members":1}}]}
```

**6. `GET /orgs/{org}/locations`**

```bash
curl -sS http://127.0.0.1:8400/orgs/$ORG_ID/locations -H "Authorization: Bearer $TOKEN"
```
```json
[{"id":"019fa657-92e1-76e9-83bd-c7e085c8bd1b","name":"Smoke Test Main",
  "target_fc_pct":"30.00","drift_threshold_pct":"5.00"}]
```

**7. Create two ingredients, capture their ids**

```bash
ING1=$(curl -sS -X POST http://127.0.0.1:8400/locations/$LOC_ID/ingredients \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Flour","base_unit":"lb","vendor":"Acme Foods","category":"Dry Goods"}')
echo "$ING1"
ING1_ID=$(echo "$ING1" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")

ING2=$(curl -sS -X POST http://127.0.0.1:8400/locations/$LOC_ID/ingredients \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"name":"Sugar","base_unit":"lb","vendor":"Acme Foods","category":"Dry Goods"}')
echo "$ING2"
ING2_ID=$(echo "$ING2" | python3 -c "import sys,json; print(json.load(sys.stdin)['id'])")
```
```
{"id":"019fa658-0f93-7f58-8b3e-756c2b7d30e4","name":"Flour","base_unit":"lb","vendor":"Acme Foods","category":"Dry Goods"}
{"id":"019fa658-0fe2-7dd2-8565-562b9f6661ab","name":"Sugar","base_unit":"lb","vendor":"Acme Foods","category":"Dry Goods"}
```

**8. Record a purchase for each ingredient**

```bash
curl -sS -X POST http://127.0.0.1:8400/locations/$LOC_ID/purchases \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"ingredient_id\":\"$ING1_ID\",\"purchased_on\":\"2026-07-20\",\"qty\":\"10\",\"unit\":\"lb\",\"total_price\":\"12.50\"}"

curl -sS -X POST http://127.0.0.1:8400/locations/$LOC_ID/purchases \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"ingredient_id\":\"$ING2_ID\",\"purchased_on\":\"2026-07-20\",\"qty\":\"5\",\"unit\":\"lb\",\"total_price\":\"6.00\"}"
```
```
{"id":"019fa658-3ea2-769f-b96c-bdb7ed55fb23","purchased_on":"2026-07-20","qty_base_units":"10.0000","total_price":"12.50","unit_price":"1.250000"}
{"id":"019fa658-3ebd-79ba-a0a8-90603564deea","purchased_on":"2026-07-20","qty_base_units":"5.0000","total_price":"6.00","unit_price":"1.200000"}
```

**9. Create a recipe with 2 lines, capture the recipe id**

```bash
RECIPE=$(curl -sS -X POST http://127.0.0.1:8400/locations/$LOC_ID/recipes \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"name\":\"Test Bread\",\"menu_price\":\"8.00\",\"target_fc_pct\":\"30.00\",\"items\":[{\"ingredient_id\":\"$ING1_ID\",\"qty_base_units\":\"2\"},{\"ingredient_id\":\"$ING2_ID\",\"qty_base_units\":\"1\"}]}")
echo "$RECIPE"
RECIPE_ID=$(echo "$RECIPE" | python3 -c "import sys,json; print(json.load(sys.stdin)['recipe_id'])")
```
```json
{"recipe_id":"019fa658-3ed1-7991-b013-335e5005cba5","name":"Test Bread","menu_price":"8.00",
 "target_fc_pct":"30.00","plate_cost":"3.70","fc_pct":"46.3","status":"danger",
 "suggested_price":"12.50","complete":true,
 "items":[
   {"id":"019fa658-3ed6-7374-90af-fa359148d29e","ingredient_id":"019fa658-0f93-7f58-8b3e-756c2b7d30e4",
    "name":"Flour","qty_base_units":"2.0000","unit_price":"1.250000","cost":"2.50","is_resolvable":true},
   {"id":"019fa658-3ed9-72d0-8054-f159aab8669e","ingredient_id":"019fa658-0fe2-7dd2-8565-562b9f6661ab",
    "name":"Sugar","qty_base_units":"1.0000","unit_price":"1.200000","cost":"1.20","is_resolvable":true}]}
```

**10. `GET` the recipe back, capture both item ids**

```bash
GETR=$(curl -sS http://127.0.0.1:8400/locations/$LOC_ID/recipes/$RECIPE_ID -H "Authorization: Bearer $TOKEN")
echo "$GETR"
ITEM1_ID=$(echo "$GETR" | python3 -c "import sys,json; print(json.load(sys.stdin)['items'][0]['id'])")
ITEM2_ID=$(echo "$GETR" | python3 -c "import sys,json; print(json.load(sys.stdin)['items'][1]['id'])")
```
Response is byte-identical to step 9's. `ITEM1_ID` = `019fa658-3ed6-7374-90af-fa359148d29e`
(Flour), `ITEM2_ID` = `019fa658-3ed9-72d0-8054-f159aab8669e` (Sugar).

**11. `PUT` the recipe — Flour qty 2→3, both item ids round-tripped in the body**

```bash
curl -sS -X PUT http://127.0.0.1:8400/locations/$LOC_ID/recipes/$RECIPE_ID \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d "{\"name\":\"Test Bread\",\"menu_price\":\"8.00\",\"target_fc_pct\":\"30.00\",\"items\":[{\"id\":\"$ITEM1_ID\",\"ingredient_id\":\"$ING1_ID\",\"qty_base_units\":\"3\"},{\"id\":\"$ITEM2_ID\",\"ingredient_id\":\"$ING2_ID\",\"qty_base_units\":\"1\"}]}"
```
```json
{"recipe_id":"019fa658-3ed1-7991-b013-335e5005cba5","plate_cost":"4.95","fc_pct":"61.9",
 "items":[
   {"id":"019fa658-3ed6-7374-90af-fa359148d29e","qty_base_units":"3.0000","cost":"3.75"},
   {"id":"019fa658-3ed9-72d0-8054-f159aab8669e","qty_base_units":"1.0000","cost":"1.20"}]}
```
Both item ids in the response are exactly `$ITEM1_ID`/`$ITEM2_ID` — no id churn from the update.

**12. SQL assert — the 1d acceptance criterion**

```bash
docker exec cs-1d-smoke psql -U postgres -d postgres -c \
  "SELECT id, qty_base_units, deleted_at FROM recipe_items WHERE recipe_id = '$RECIPE_ID' ORDER BY id;"
docker exec cs-1d-smoke psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM recipe_items WHERE recipe_id = '$RECIPE_ID' AND deleted_at IS NULL;"
docker exec cs-1d-smoke psql -U postgres -d postgres -tAc \
  "SELECT count(*) FROM recipe_items WHERE recipe_id = '$RECIPE_ID' AND deleted_at IS NULL AND id IN ('$ITEM1_ID','$ITEM2_ID');"
```
```
                  id                  | qty_base_units | deleted_at
---------------------------------------+----------------+------------
 019fa658-3ed6-7374-90af-fa359148d29e |         3.0000 |
 019fa658-3ed9-72d0-8054-f159aab8669e |         1.0000 |
(2 rows)

2
2
```
Exactly 2 live rows, `deleted_at` NULL on both, and both ids match
`$ITEM1_ID`/`$ITEM2_ID` — `update_recipe` (`api/routes/recipes.py`) updated
the line in place; it never deleted and reinserted it, and the live line
count held at 2 across the PUT.

**13. CSV import, 2 rows**

```bash
cat > import.csv <<'EOF'
item,vendor,date,qty,unit,total
Butter,Acme Foods,2026-07-21,4,lb,10.00
Eggs,Acme Foods,2026-07-21,60,each,9.00
EOF

curl -sS -X POST http://127.0.0.1:8400/locations/$LOC_ID/purchases/import \
  -H "Authorization: Bearer $TOKEN" \
  -F "file=@import.csv;type=text/csv"
```
```
{"rows_processed":2,"created":2,"matched":0,"errors":[]}
```

**14. `PATCH /locations/{id}` — change the drift threshold**

```bash
curl -sS -X PATCH http://127.0.0.1:8400/locations/$LOC_ID \
  -H "Authorization: Bearer $TOKEN" -H "Content-Type: application/json" \
  -d '{"drift_threshold_pct":"12.50"}'
```
```json
{"id":"019fa657-92e1-76e9-83bd-c7e085c8bd1b","name":"Smoke Test Main",
 "target_fc_pct":"30.00","drift_threshold_pct":"12.50"}
```

**15. `GET` the dashboard — confirm the new threshold is reflected**

```bash
curl -sS http://127.0.0.1:8400/locations/$LOC_ID/dashboard -H "Authorization: Bearer $TOKEN"
```
```json
{"location":{"id":"019fa657-92e1-76e9-83bd-c7e085c8bd1b","name":"Smoke Test Main",
 "drift_threshold_pct":"12.50"}, "alerts":[], "top_movers":[], "menu_items":[...], "summary":{...}}
```
`location.drift_threshold_pct` is `"12.50"` — the settings change from step
14 is reflected immediately, no cache to invalidate.

### 4.5 Tear down

```bash
kill %1                       # the backgrounded uvicorn
docker rm -f cs-1d-smoke
```

`tests/conftest.py`'s own container-reaper pattern (atexit + SIGTERM
handler) is *not* needed here since this is a one-shot foreground script,
not a pytest session — but if this smoke is ever wrapped in a longer-lived
script, copy that pattern rather than relying on `docker run --rm` alone
(it only removes a container after it stops, not a still-running one on
an interrupted script).

---

## 5. Rollback

Additive only, same shape as every prior phase's rollback: `/app`,
`/shared`, `/config`, and `POST .../purchases/import` are new mounts and
routes on top of an otherwise-unchanged API; nothing in Phase 1d altered
an existing route's contract, dropped a column, or touched RLS. **Rollback
is an API code revert** (redeploy the pre-1d API image/commit, which
simply stops serving those mounts/routes) — there is no database migration
to roll back, because none shipped.

If a host is already live and needs to revert:

1. Redeploy the API at the pre-1d commit. `/app/`, `/shared/kernel.js`,
   `/config`, and CSV import 404 again; every other route is untouched.
2. Leave `web/` and `shared/kernel.js` in the repo — they are inert until
   something mounts them again.
3. No Supabase Auth dashboard change is needed to roll back (the redirect
   allowlist entry from §3 is harmless if `/app/` is temporarily
   unreachable — it just means nothing currently redeems it).

---

## 6. As deployed

No host exists for this project as of this writing (2026-07-27) — the
Phase 1a go-live checklist (`app_user` password, env vars, reviewer
account, purge cron) is still open on the Notion Human Action Board, and
`phase-1c-deploy.md` §10 recorded its own §8 smoke as deferred for the
same reason. This runbook's §4 smoke is the **local** substitute: it
proves the SPA + API integration works end-to-end against a real
Postgres and a real HTTP server, so that once a host exists, going live is
purely an environment/DNS/TLS exercise, not an unproven code path. Run §4
again against the real host once one exists, substituting the real
`DATABASE_URL`/`SUPABASE_URL`/`SUPABASE_ANON_KEY` and a by-hand-provisioned
reviewer account, before declaring that host live.
