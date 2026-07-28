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
still applies unchanged — see `phase-1a-deploy.md` §9-§11. Phase 1d adds
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
1443 pytest cases already exercise:

```python
# bootstrap.py — see task-7-report.md for the full listing
import asyncio, os, pathlib, sys
sys.path.insert(0, "/path/to/repo")
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
DB_URL="postgresql://postgres:postgres@127.0.0.1:55440/postgres" \
  uv run python bootstrap.py
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

All steps below ran against the container above and **passed**:

| Step | Call | Result |
|---|---|---|
| 1 | `GET /config` | `{"supabase_url":null,"supabase_anon_key":null}` |
| 2 | `GET /app/` | `<!DOCTYPE html>...<title>CostSauce — Food Cost Analysis</title>...` |
| 3 | `GET /shared/kernel.js` | `// shared/kernel.js` header + kernel source |
| 4 | `POST /auth/reviewer-otp` `{"email":"reviewer@example.com","code":"123456"}` | `{"access_token": "<jwt>"}` |
| 5 | `GET /me` | 1 membership, `role":"owner"`, org `Smoke Test Diner` |
| 6 | `GET /orgs/{org}/locations` | 1 location, `Smoke Test Main`, `target_fc_pct:"30.00"`, `drift_threshold_pct:"5.00"` |
| 7 | `POST .../ingredients` ×2 | Flour + Sugar created, `201` |
| 8 | `POST .../purchases` ×2 | Flour `$12.50/10lb`, Sugar `$6.00/5lb`, `unit_price` `1.250000`/`1.200000` |
| 9 | `POST .../recipes` (2 lines) | `plate_cost:"3.70"`, `fc_pct:"46.3"`, both items `is_resolvable:true` |
| 10 | `GET .../recipes/{id}` | same 2 item ids captured: `...d29e` (Flour), `...669e` (Sugar) |
| 11 | `PUT .../recipes/{id}` (Flour qty 2→3, both ids round-tripped) | same 2 item ids echoed back; `plate_cost:"4.95"` |
| 12 | **SQL**: `SELECT id, qty_base_units, deleted_at FROM recipe_items WHERE recipe_id = <id>` | **exactly 2 rows, `deleted_at` NULL on both, ids identical to step 10/11** — the 1d acceptance criterion: update-in-place, never delete-and-reinsert |
| 13 | `POST .../purchases/import` (2-row CSV, Butter + Eggs) | `{"rows_processed":2,"created":2,"matched":0,"errors":[]}` |
| 14 | `PATCH /locations/{id}` `{"drift_threshold_pct":"12.50"}` | `{"drift_threshold_pct":"12.50", ...}` |
| 15 | `GET .../dashboard` | `location.drift_threshold_pct:"12.50"` — settings change reflected immediately, no cache to invalidate |

Full request/response transcript: `task-7-report.md` (this task's report,
alongside this runbook).

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
