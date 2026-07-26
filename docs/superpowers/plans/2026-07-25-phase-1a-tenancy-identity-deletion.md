# Phase 1a: Tenancy, Identity, and Deletion — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Turn the single-tenant CostSauce demo into a multi-tenant, authenticated backend with organizations, roles, invites, and compliant account deletion — with no sync and no business-logic port yet.

**Architecture:** Supabase provides Postgres 17, Auth (magic link + Sign in with Apple), and Storage. A FastAPI service connects to that same Postgres as an unprivileged `app_user` role and, per request, adopts the caller's identity via `SET LOCAL ROLE authenticated` plus `set_config('request.jwt.claims', …, true)`, so Row-Level Security is genuinely enforced rather than bypassed. Every tenant table carries an org path, and every RLS policy resolves access through the `memberships` table.

**Tech Stack:** Python 3.11+, FastAPI, psycopg 3 (async, with an explicit connection pool), pytest + pytest-asyncio, raw SQL migrations applied via the Supabase MCP `apply_migration` tool, PyJWT for token validation, `stripe` and `httpx` for the deletion side-effects.

## Global Constraints

Copied verbatim from `docs/superpowers/specs/2026-07-25-native-ios-app-design.md`. Every task's requirements implicitly include this section.

- **Supabase project ref:** `khohfrfqzbieaiikqlsa` (`CostSauce-Prod`), region `us-east-2`, Postgres 17.6.1.
- **Roles are exactly:** `owner`, `manager`, `bookkeeper`.
- **The DB role used by FastAPI is `app_user`:** `NOINHERIT`, **no `BYPASSRLS`**, not the table owner.
- **`SET LOCAL` only** — a session GUC surviving a pooled connection checkout hands org B org A's claims.
- `ALTER TABLE … FORCE ROW LEVEL SECURITY` on every tenant table.
- **Every policy carries `WITH CHECK` as well as `USING`**, written against the `memberships` subquery, never against a JWT claim.
- Identity keys on provider `sub`, **never on email**. Linking accounts on matching email is an account-takeover primitive and is forbidden.
- `profiles.contact_email` is separately supplied and verified; it is what digests and alerts use, never the Apple private-relay address.
- **Deletion uses a 30-day grace period.** Stripe cancellation and Apple `/auth/revoke` happen **immediately** on confirm, not after 30 days.
- Money columns are `numeric`, never float. (Phase 1a creates only `locations.target_fc_pct numeric(5,2)` and `drift_threshold_pct numeric(5,2)`; the full money contract lands in Phase 1b.)
- Primary keys are **UUIDv7**. Postgres 17 has no native `uuidv7()`; use the `uuid_generate_v7()` PL/pgSQL function defined in Task 2.
- **No sync in this phase.** No `client_mutated_at`, `server_seq`, or `sync_ops` tables. The only sync-adjacent artifact is the deletion guard in Task 10.
- Seed data must use **fictional distributor names**. Real trademarked names (Sysco, US Foods, Reinhart, FreshPoint, Regalis) must not appear in any seed.

---

## File Structure

| Path | Responsibility |
|---|---|
| `supabase/migrations/0001_extensions_and_uuidv7.sql` | Extensions; `uuid_generate_v7()` |
| `supabase/migrations/0002_tenancy_tables.sql` | `organizations`, `memberships`, `locations`, `profiles`, `invites`, token tables |
| `supabase/migrations/0003_app_user_role.sql` | `app_user` role, grants, no BYPASSRLS |
| `supabase/migrations/0004_rls_policies.sql` | FORCE RLS + USING/WITH CHECK policies |
| `supabase/migrations/0005_deletion.sql` | `deletion_scheduled_at`, purge function |
| `supabase/migrations/0006_sample_org.sql` | `organizations.is_sample`, sample-org seed |
| `api/db.py` | psycopg pool; `tenant_connection()` implementing SET LOCAL |
| `api/auth.py` | JWT validation, `CallerIdentity`, FastAPI dependency |
| `api/models.py` | Pydantic request/response models, plan limits |
| `api/routes/me.py` | `GET /me` — identity, memberships, entitlement |
| `api/routes/identity.py` | Apple link flow, contact-email verification, reviewer OTP |
| `api/routes/members.py` | Invites, role changes, member removal |
| `api/routes/deletion.py` | Account deletion, org deletion, export, cancel |
| `api/services/apple.py` | Apple `/auth/revoke` client |
| `api/services/billing.py` | Stripe cancellation |
| `api/services/export.py` | Org data export bundle |
| `api/jobs/purge.py` | 30-day scheduled purge |
| `api/main.py` | App wiring, deletion-guard middleware |
| `tests/conftest.py` | Postgres fixtures, JWT minting, app client |
| `tests/factories.py` | Org/user/membership/location factories |
| `tests/test_rls_cross_org.py` | **Non-negotiable** cross-org isolation test |
| `tests/test_deletion.py` | **Non-negotiable** end-to-end deletion test |

---

### Task 1: Test harness against a real Postgres

**Files:**
- Create: `api/__init__.py`, `pyproject.toml`, `tests/conftest.py`
- Test: `tests/test_harness.py`

**Interfaces:**
- Consumes: nothing
- Produces: pytest fixture `db_url: str`; fixture `raw_conn` yielding a `psycopg.AsyncConnection` as the **owner** role; `apply_migrations(conn, upto: int | None = None) -> None`

RLS cannot be tested against SQLite or a mock — policies are a Postgres feature. Tests run against a real Postgres 17 in Docker so they never touch the Supabase project.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_harness.py
async def test_postgres_is_reachable_and_is_v17(raw_conn):
    cur = await raw_conn.execute("SHOW server_version_num")
    (version_num,) = await cur.fetchone()
    assert int(version_num) >= 170000, f"need Postgres 17+, got {version_num}"
```

- [ ] **Step 2: Run it to verify it fails**

Run: `pytest tests/test_harness.py -v`
Expected: FAIL — fixture `raw_conn` not found.

- [ ] **Step 3: Write `pyproject.toml`**

```toml
[project]
name = "costsauce-api"
version = "0.1.0"
requires-python = ">=3.11"
dependencies = [
  "fastapi>=0.110",
  "uvicorn[standard]>=0.29",
  "psycopg[binary,pool]>=3.1",
  "pyjwt[crypto]>=2.8",
  "httpx>=0.27",
  "stripe>=9.0",
  "pydantic[email]>=2.6",
]

[project.optional-dependencies]
dev = ["pytest>=8", "pytest-asyncio>=0.23"]

[tool.pytest.ini_options]
asyncio_mode = "auto"
```

- [ ] **Step 4: Write `tests/conftest.py`**

```python
# tests/conftest.py
import os
import pathlib
import subprocess
import time
import uuid
import pytest
import psycopg

MIGRATIONS = pathlib.Path(__file__).parent.parent / "supabase" / "migrations"


@pytest.fixture(scope="session")
def db_url() -> str:
    """A disposable Postgres 17. Never the Supabase project."""
    url = os.environ.get("TEST_DATABASE_URL")
    if url:
        yield url
        return
    name = f"costsauce-test-{uuid.uuid4().hex[:8]}"
    subprocess.run(
        ["docker", "run", "-d", "--rm", "--name", name,
         "-e", "POSTGRES_PASSWORD=postgres", "-P", "postgres:17"],
        check=True, capture_output=True,
    )
    port = subprocess.run(
        ["docker", "port", name, "5432/tcp"],
        check=True, capture_output=True, text=True,
    ).stdout.strip().rsplit(":", 1)[1]
    url = f"postgresql://postgres:postgres@localhost:{port}/postgres"
    for _ in range(60):
        try:
            psycopg.connect(url, connect_timeout=1).close()
            break
        except psycopg.OperationalError:
            time.sleep(0.5)
    else:
        raise RuntimeError("test postgres never became ready")
    yield url
    subprocess.run(["docker", "kill", name], capture_output=True)


async def apply_migrations(conn, upto: int | None = None) -> None:
    for path in sorted(MIGRATIONS.glob("*.sql")):
        number = int(path.name.split("_", 1)[0])
        if upto is not None and number > upto:
            continue
        await conn.execute(path.read_text())
    await conn.commit()


@pytest.fixture
async def raw_conn(db_url):
    """Owner-role connection. Fresh schema per test."""
    conn = await psycopg.AsyncConnection.connect(db_url, autocommit=False)
    await conn.execute("DROP SCHEMA IF EXISTS public CASCADE; CREATE SCHEMA public")
    await conn.execute("DROP SCHEMA IF EXISTS auth CASCADE; CREATE SCHEMA auth")
    await conn.execute(
        "CREATE TABLE auth.users ("
        "  id uuid PRIMARY KEY, email text, raw_user_meta_data jsonb DEFAULT '{}')"
    )
    await conn.commit()
    yield conn
    await conn.close()
```

`auth.users` is stubbed because Supabase owns it in production but tests need the FK target.

- [ ] **Step 5: Run the test to verify it passes**

Run: `pytest tests/test_harness.py -v`
Expected: PASS.

- [ ] **Step 6: Commit**

```bash
git add pyproject.toml tests/conftest.py tests/test_harness.py api/__init__.py
git commit -m "test: pytest harness against real Postgres 17"
```

---

### Task 2: Tenancy schema

**Files:**
- Create: `supabase/migrations/0001_extensions_and_uuidv7.sql`, `supabase/migrations/0002_tenancy_tables.sql`
- Test: `tests/test_schema.py`

**Interfaces:**
- Consumes: `raw_conn`, `apply_migrations` (Task 1)
- Produces: tables `organizations`, `memberships`, `locations`, `profiles`, `invites`, `email_verifications`, `apple_link_requests`; SQL function `uuid_generate_v7() returns uuid`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_schema.py
import pytest
from tests.conftest import apply_migrations


async def test_uuidv7_is_time_ordered(raw_conn):
    await apply_migrations(raw_conn, upto=1)
    cur = await raw_conn.execute(
        "SELECT uuid_generate_v7()::text, uuid_generate_v7()::text, uuid_generate_v7()::text"
    )
    a, b, c = await cur.fetchone()
    assert a < b < c, "UUIDv7 must sort in generation order"
    assert a[14] == "7", f"version nibble must be 7, got {a[14]}"


async def test_role_check_rejects_unknown_role(raw_conn):
    await apply_migrations(raw_conn, upto=2)
    cur = await raw_conn.execute(
        "INSERT INTO organizations (name, plan) VALUES ('Acme', 'starter') RETURNING id"
    )
    (org_id,) = await cur.fetchone()
    cur = await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (uuid_generate_v7(), 'a@x.test') RETURNING id"
    )
    (user_id,) = await cur.fetchone()
    with pytest.raises(Exception) as exc:
        await raw_conn.execute(
            "INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, 'admin')",
            (user_id, org_id),
        )
    assert "memberships_role_check" in str(exc.value)


async def test_contact_email_is_required_on_profiles(raw_conn):
    await apply_migrations(raw_conn, upto=2)
    cur = await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (uuid_generate_v7(), 'b@x.test') RETURNING id"
    )
    (user_id,) = await cur.fetchone()
    with pytest.raises(Exception) as exc:
        await raw_conn.execute("INSERT INTO profiles (user_id) VALUES (%s)", (user_id,))
    assert "contact_email" in str(exc.value)
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/test_schema.py -v`
Expected: FAIL — `function uuid_generate_v7() does not exist`.

- [ ] **Step 3: Write `0001_extensions_and_uuidv7.sql`**

```sql
CREATE EXTENSION IF NOT EXISTS pgcrypto;
CREATE EXTENSION IF NOT EXISTS citext;

-- Postgres 17 has no native uuidv7(); this is the documented fallback,
-- extended per RFC 9562 Method 3 ("Replace Left-Most Random Bits with
-- Increased Clock Precision") so that UUIDs generated within the same
-- millisecond still sort in generation order.
--
-- Layout: 48-bit big-endian ms timestamp (bytes 0-5) | version 7 nibble +
-- 12-bit sub-ms fraction "rand_a" (bytes 6-7) | variant + 62 random bits
-- "rand_b" (bytes 8-15).
CREATE OR REPLACE FUNCTION uuid_generate_v7() RETURNS uuid AS $$
DECLARE
  ts      timestamptz := clock_timestamp();
  -- Single microsecond-resolution reading of the clock. unix_ms and
  -- sub_ms are both derived from this one integer below, so they can
  -- never straddle a tick relative to each other.
  unix_us bigint := (extract(epoch FROM ts) * 1000000)::bigint;
  unix_ms bigint := unix_us / 1000;
  sub_ms  bigint := unix_us % 1000;
  -- Sub-millisecond fraction (0-999) scaled into 12 bits (0-4095).
  rand_a  int := least(((sub_ms * 4096) / 1000)::int, 4095);
  bytes   bytea := gen_random_bytes(16);
BEGIN
  bytes := set_byte(bytes, 0, ((unix_ms >> 40) & 255)::int);
  bytes := set_byte(bytes, 1, ((unix_ms >> 32) & 255)::int);
  bytes := set_byte(bytes, 2, ((unix_ms >> 24) & 255)::int);
  bytes := set_byte(bytes, 3, ((unix_ms >> 16) & 255)::int);
  bytes := set_byte(bytes, 4, ((unix_ms >>  8) & 255)::int);
  bytes := set_byte(bytes, 5,  (unix_ms        & 255)::int);
  -- version 7 in the high nibble of byte 6; low nibble = top 4 bits of rand_a
  bytes := set_byte(bytes, 6, (112 | ((rand_a >> 8) & 15)));
  -- byte 7 = bottom 8 bits of rand_a
  bytes := set_byte(bytes, 7, (rand_a & 255));
  -- RFC 4122 variant in the high bits of byte 8; rest of rand_b stays random
  bytes := set_byte(bytes, 8, ((get_byte(bytes, 8) & 63) | 128));
  RETURN encode(bytes, 'hex')::uuid;
END;
$$ LANGUAGE plpgsql VOLATILE;
```

- [ ] **Step 4: Write `0002_tenancy_tables.sql`**

```sql
CREATE TABLE organizations (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  name          text NOT NULL CHECK (length(trim(name)) > 0),
  plan          text NOT NULL DEFAULT 'starter'
                  CHECK (plan IN ('starter', 'growth', 'pro')),
  sync_counter  bigint NOT NULL DEFAULT 0,
  created_at    timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE memberships (
  id         uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  org_id     uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  role       text NOT NULL CONSTRAINT memberships_role_check
               CHECK (role IN ('owner', 'manager', 'bookkeeper')),
  created_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (user_id, org_id)
);
CREATE INDEX memberships_user_idx ON memberships (user_id);
CREATE INDEX memberships_org_idx  ON memberships (org_id);

CREATE TABLE locations (
  id                  uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  org_id              uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  name                text NOT NULL,
  target_fc_pct       numeric(5,2) NOT NULL DEFAULT 30.00,
  drift_threshold_pct numeric(5,2) NOT NULL DEFAULT 5.00,
  created_at          timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX locations_org_idx ON locations (org_id);

CREATE TABLE profiles (
  user_id                   uuid PRIMARY KEY REFERENCES auth.users(id) ON DELETE CASCADE,
  apple_sub                 text UNIQUE,
  contact_email             citext NOT NULL,
  contact_email_verified_at timestamptz,
  created_at                timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE invites (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  org_id      uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  email       citext NOT NULL,
  role        text NOT NULL CHECK (role IN ('owner', 'manager', 'bookkeeper')),
  token_hash  text NOT NULL UNIQUE,
  invited_by  uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  expires_at  timestamptz NOT NULL,
  accepted_at timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX invites_org_idx ON invites (org_id);

CREATE TABLE email_verifications (
  id         uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  user_id    uuid NOT NULL REFERENCES auth.users(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE apple_link_requests (
  id         uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  apple_sub  text NOT NULL,
  token_hash text NOT NULL UNIQUE,
  expires_at timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now()
);
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pytest tests/test_schema.py -v`
Expected: 3 passed.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/0001_extensions_and_uuidv7.sql supabase/migrations/0002_tenancy_tables.sql tests/test_schema.py
git commit -m "feat: tenancy schema (organizations, memberships, locations, profiles, invites)"
```

---

### Task 3: `app_user` role and the SET LOCAL checkout pattern

**Files:**
- Create: `supabase/migrations/0003_app_user_role.sql`, `api/db.py`
- Test: `tests/test_db_checkout.py`

**Interfaces:**
- Consumes: Task 2 tables
- Produces: `api.db.pool_open(db_url: str) -> AsyncConnectionPool`; async context manager `tenant_connection(pool, claims: dict)`; `api.db.ClaimsLeakError`

This is the task that makes RLS real. If FastAPI connects as a superuser or with `BYPASSRLS`, every policy in Task 4 is decoration.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_db_checkout.py
import json
import pytest
from tests.conftest import apply_migrations
from api.db import pool_open, tenant_connection


def app_url(url: str) -> str:
    return url.replace("postgres:postgres", "app_user:app_pw")


async def test_app_user_has_no_bypassrls(raw_conn):
    await apply_migrations(raw_conn, upto=3)
    cur = await raw_conn.execute(
        "SELECT rolbypassrls, rolsuper, rolinherit FROM pg_roles WHERE rolname = 'app_user'"
    )
    bypass, super_, inherit = await cur.fetchone()
    assert bypass is False, "app_user must never have BYPASSRLS"
    assert super_ is False
    assert inherit is False, "app_user must be NOINHERIT"


async def test_claims_do_not_survive_checkout(raw_conn, db_url):
    """The whole point of SET LOCAL: org B must never see org A's claims."""
    await apply_migrations(raw_conn, upto=3)
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": "user-a"}) as conn:
        cur = await conn.execute("SELECT current_setting('request.jwt.claims', true)")
        (claims,) = await cur.fetchone()
        assert json.loads(claims)["sub"] == "user-a"
    async with tenant_connection(pool, {"sub": "user-b"}) as conn:
        cur = await conn.execute("SELECT current_setting('request.jwt.claims', true)")
        (claims,) = await cur.fetchone()
        assert json.loads(claims)["sub"] == "user-b", "claims leaked across checkout"
    await pool.close()


async def test_claims_are_cleared_after_rollback(raw_conn, db_url):
    await apply_migrations(raw_conn, upto=3)
    pool = await pool_open(app_url(db_url))
    with pytest.raises(RuntimeError):
        async with tenant_connection(pool, {"sub": "user-c"}):
            raise RuntimeError("boom")
    async with tenant_connection(pool, {"sub": "user-d"}) as conn:
        cur = await conn.execute("SELECT current_setting('request.jwt.claims', true)")
        (claims,) = await cur.fetchone()
        assert json.loads(claims)["sub"] == "user-d"
    await pool.close()
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/test_db_checkout.py -v`
Expected: FAIL — `No module named 'api.db'`.

- [ ] **Step 3: Write `0003_app_user_role.sql`**

```sql
-- The role FastAPI connects as. Deliberately powerless.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user LOGIN PASSWORD 'app_pw' NOINHERIT NOBYPASSRLS NOSUPERUSER;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER;
  END IF;
END $$;

-- app_user may become 'authenticated' but inherits nothing by default.
GRANT authenticated TO app_user;

GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;
GRANT SELECT ON auth.users TO authenticated;
ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
```

In production `app_user`'s password comes from the Supabase connection string, not this literal; the literal exists so tests can connect.

- [ ] **Step 4: Write `api/db.py`**

```python
# api/db.py
import json
from contextlib import asynccontextmanager
from psycopg_pool import AsyncConnectionPool


class ClaimsLeakError(RuntimeError):
    """Raised when a connection is handed out still carrying prior claims."""


async def pool_open(db_url: str) -> AsyncConnectionPool:
    pool = AsyncConnectionPool(db_url, open=False, min_size=1, max_size=10)
    await pool.open(wait=True)
    return pool


@asynccontextmanager
async def tenant_connection(pool: AsyncConnectionPool, claims: dict):
    """Yield a connection that has adopted the caller's identity.

    Everything happens inside ONE transaction and uses SET LOCAL exclusively,
    so the settings die with the transaction. A plain SET would survive the
    checkout and hand the next caller these claims.
    """
    async with pool.connection() as conn:
        await conn.set_autocommit(False)
        try:
            cur = await conn.execute("SELECT current_setting('request.jwt.claims', true)")
            (leftover,) = await cur.fetchone()
            if leftover:
                raise ClaimsLeakError(f"connection arrived with claims set: {leftover!r}")

            await conn.execute("SET LOCAL ROLE authenticated")
            await conn.execute(
                "SELECT set_config('request.jwt.claims', %s, true)",
                (json.dumps(claims),),
            )
            yield conn
            await conn.commit()
        except BaseException:
            await conn.rollback()
            raise
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pytest tests/test_db_checkout.py -v`
Expected: 3 passed.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/0003_app_user_role.sql api/db.py tests/test_db_checkout.py
git commit -m "feat: app_user role and SET LOCAL tenant connection"
```

---

### Task 4: RLS policies

**Files:**
- Create: `supabase/migrations/0004_rls_policies.sql`

**Interfaces:**
- Consumes: Tasks 2–3
- Produces: `FORCE ROW LEVEL SECURITY` + USING/WITH CHECK policies on all seven tables; SQL helper `current_user_id() returns uuid`

- [ ] **Step 1: Write `0004_rls_policies.sql`**

```sql
CREATE OR REPLACE FUNCTION current_user_id() RETURNS uuid AS $$
  SELECT nullif(current_setting('request.jwt.claims', true)::jsonb ->> 'sub', '')::uuid;
$$ LANGUAGE sql STABLE;

ALTER TABLE organizations       ENABLE ROW LEVEL SECURITY;
ALTER TABLE organizations       FORCE  ROW LEVEL SECURITY;
ALTER TABLE memberships         ENABLE ROW LEVEL SECURITY;
ALTER TABLE memberships         FORCE  ROW LEVEL SECURITY;
ALTER TABLE locations           ENABLE ROW LEVEL SECURITY;
ALTER TABLE locations           FORCE  ROW LEVEL SECURITY;
ALTER TABLE invites             ENABLE ROW LEVEL SECURITY;
ALTER TABLE invites             FORCE  ROW LEVEL SECURITY;
ALTER TABLE profiles            ENABLE ROW LEVEL SECURITY;
ALTER TABLE profiles            FORCE  ROW LEVEL SECURITY;
ALTER TABLE email_verifications ENABLE ROW LEVEL SECURITY;
ALTER TABLE email_verifications FORCE  ROW LEVEL SECURITY;
ALTER TABLE apple_link_requests ENABLE ROW LEVEL SECURITY;
ALTER TABLE apple_link_requests FORCE  ROW LEVEL SECURITY;

-- organizations: visible to members; mutable by owners.
CREATE POLICY org_select ON organizations FOR SELECT USING (
  EXISTS (SELECT 1 FROM memberships m
          WHERE m.org_id = organizations.id AND m.user_id = current_user_id())
);
CREATE POLICY org_update ON organizations FOR UPDATE
USING (
  EXISTS (SELECT 1 FROM memberships m
          WHERE m.org_id = organizations.id AND m.user_id = current_user_id()
            AND m.role = 'owner')
)
WITH CHECK (
  EXISTS (SELECT 1 FROM memberships m
          WHERE m.org_id = organizations.id AND m.user_id = current_user_id()
            AND m.role = 'owner')
);

-- memberships: a caller sees every membership of any org they belong to.
CREATE POLICY membership_select ON memberships FOR SELECT USING (
  org_id IN (SELECT m.org_id FROM memberships m WHERE m.user_id = current_user_id())
);
CREATE POLICY membership_write ON memberships FOR ALL
USING (
  org_id IN (SELECT m.org_id FROM memberships m
             WHERE m.user_id = current_user_id() AND m.role = 'owner')
)
WITH CHECK (
  org_id IN (SELECT m.org_id FROM memberships m
             WHERE m.user_id = current_user_id() AND m.role = 'owner')
);

-- locations: WITH CHECK is what stops a caller writing a row into another org.
CREATE POLICY location_select ON locations FOR SELECT USING (
  org_id IN (SELECT m.org_id FROM memberships m WHERE m.user_id = current_user_id())
);
CREATE POLICY location_write ON locations FOR ALL
USING (
  org_id IN (SELECT m.org_id FROM memberships m
             WHERE m.user_id = current_user_id() AND m.role IN ('owner', 'manager'))
)
WITH CHECK (
  org_id IN (SELECT m.org_id FROM memberships m
             WHERE m.user_id = current_user_id() AND m.role IN ('owner', 'manager'))
);

CREATE POLICY invite_all ON invites FOR ALL
USING (
  org_id IN (SELECT m.org_id FROM memberships m
             WHERE m.user_id = current_user_id() AND m.role = 'owner')
)
WITH CHECK (
  org_id IN (SELECT m.org_id FROM memberships m
             WHERE m.user_id = current_user_id() AND m.role = 'owner')
);

CREATE POLICY profile_self ON profiles FOR ALL
USING (user_id = current_user_id()) WITH CHECK (user_id = current_user_id());

CREATE POLICY email_verification_self ON email_verifications FOR ALL
USING (user_id = current_user_id()) WITH CHECK (user_id = current_user_id());

CREATE POLICY apple_link_self ON apple_link_requests FOR ALL
USING (apple_sub = current_setting('request.jwt.claims', true)::jsonb ->> 'sub')
WITH CHECK (apple_sub = current_setting('request.jwt.claims', true)::jsonb ->> 'sub');
```

- [ ] **Step 2: Verify every tenant table has FORCE RLS**

Run:
```bash
psql "$TEST_DATABASE_URL" -c "SELECT relname, relrowsecurity, relforcerowsecurity FROM pg_class WHERE relname IN ('organizations','memberships','locations','invites','profiles','email_verifications','apple_link_requests')"
```
Expected: all seven rows show `t | t`.

- [ ] **Step 3: Commit**

```bash
git add supabase/migrations/0004_rls_policies.sql
git commit -m "feat: RLS policies with FORCE and WITH CHECK on all tenant tables"
```

---

### Task 5: Cross-org RLS test (non-negotiable)

**Files:**
- Create: `tests/factories.py`, `tests/test_rls_cross_org.py`

**Interfaces:**
- Consumes: Tasks 2–4
- Produces: `tests.factories.make_user(conn, email) -> uuid`; `make_org(conn, name, plan='starter') -> uuid`; `add_member(conn, user_id, org_id, role) -> uuid`; `make_location(conn, org_id, name) -> uuid`

A tenancy leak is the one failure mode that is silent. This test is why the phase exists.

- [ ] **Step 1: Write `tests/factories.py`**

```python
# tests/factories.py
async def make_user(conn, email: str):
    cur = await conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (uuid_generate_v7(), %s) RETURNING id",
        (email,),
    )
    (user_id,) = await cur.fetchone()
    await conn.execute(
        "INSERT INTO profiles (user_id, contact_email) VALUES (%s, %s)", (user_id, email)
    )
    return user_id


async def make_org(conn, name: str, plan: str = "starter"):
    cur = await conn.execute(
        "INSERT INTO organizations (name, plan) VALUES (%s, %s) RETURNING id", (name, plan)
    )
    (org_id,) = await cur.fetchone()
    return org_id


async def add_member(conn, user_id, org_id, role: str):
    cur = await conn.execute(
        "INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, %s) RETURNING id",
        (user_id, org_id, role),
    )
    (mid,) = await cur.fetchone()
    return mid


async def make_location(conn, org_id, name: str):
    cur = await conn.execute(
        "INSERT INTO locations (org_id, name) VALUES (%s, %s) RETURNING id", (org_id, name)
    )
    (loc_id,) = await cur.fetchone()
    return loc_id
```

- [ ] **Step 2: Write the failing test**

```python
# tests/test_rls_cross_org.py
import pytest
from tests.conftest import apply_migrations
from tests.factories import make_user, make_org, add_member, make_location
from api.db import pool_open, tenant_connection


def app_url(url: str) -> str:
    return url.replace("postgres:postgres", "app_user:app_pw")


@pytest.fixture
async def two_orgs(raw_conn):
    await apply_migrations(raw_conn, upto=4)
    alice = await make_user(raw_conn, "alice@acme.test")
    bob = await make_user(raw_conn, "bob@bistro.test")
    acme = await make_org(raw_conn, "Acme Diner")
    bistro = await make_org(raw_conn, "Bistro Nine")
    await add_member(raw_conn, alice, acme, "owner")
    await add_member(raw_conn, bob, bistro, "owner")
    acme_loc = await make_location(raw_conn, acme, "Acme Main")
    bistro_loc = await make_location(raw_conn, bistro, "Bistro Main")
    await raw_conn.commit()
    return dict(alice=alice, bob=bob, acme=acme, bistro=bistro,
                acme_loc=acme_loc, bistro_loc=bistro_loc)


async def test_org_a_cannot_read_org_b_locations(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute("SELECT id FROM locations")
        rows = await cur.fetchall()
    await pool.close()
    ids = {r[0] for r in rows}
    assert two_orgs["acme_loc"] in ids
    assert two_orgs["bistro_loc"] not in ids, "TENANCY LEAK: read another org's location"


async def test_org_a_cannot_read_org_b_organizations(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute("SELECT id FROM organizations")
        rows = await cur.fetchall()
    await pool.close()
    assert {r[0] for r in rows} == {two_orgs["acme"]}


async def test_org_a_cannot_write_into_org_b(db_url, two_orgs):
    """WITH CHECK is the clause under test. USING alone would allow this."""
    pool = await pool_open(app_url(db_url))
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            await conn.execute(
                "INSERT INTO locations (org_id, name) VALUES (%s, 'Trojan')",
                (two_orgs["bistro"],),
            )
    await pool.close()
    assert "row-level security" in str(exc.value).lower()


async def test_org_a_cannot_update_org_b_row_by_id(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute(
            "UPDATE locations SET name = 'pwned' WHERE id = %s", (two_orgs["bistro_loc"],)
        )
        assert cur.rowcount == 0, "TENANCY LEAK: updated another org's row"
    await pool.close()


async def test_org_a_cannot_delete_org_b_row(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
        cur = await conn.execute("DELETE FROM locations WHERE id = %s", (two_orgs["bistro_loc"],))
        assert cur.rowcount == 0
    await pool.close()


async def test_org_a_cannot_escalate_by_inserting_membership(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    with pytest.raises(Exception) as exc:
        async with tenant_connection(pool, {"sub": str(two_orgs["alice"])}) as conn:
            await conn.execute(
                "INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, 'owner')",
                (two_orgs["alice"], two_orgs["bistro"]),
            )
    await pool.close()
    assert "row-level security" in str(exc.value).lower()


async def test_unauthenticated_claims_see_nothing(db_url, two_orgs):
    pool = await pool_open(app_url(db_url))
    async with tenant_connection(pool, {}) as conn:
        cur = await conn.execute("SELECT count(*) FROM locations")
        (n,) = await cur.fetchone()
    await pool.close()
    assert n == 0, "a caller with no sub must see nothing"
```

- [ ] **Step 3: Run to verify all pass**

Run: `pytest tests/test_rls_cross_org.py -v`
Expected: 7 passed. **If any fail, stop — do not proceed to later tasks.**

- [ ] **Step 4: Commit**

```bash
git add tests/factories.py tests/test_rls_cross_org.py
git commit -m "test: cross-org RLS isolation (read, write, update, delete, escalation)"
```

---

### Task 6: JWT validation and `GET /me`

**Files:**
- Create: `api/auth.py`, `api/models.py`, `api/routes/__init__.py`, `api/routes/me.py`, `api/main.py`
- Modify: `tests/conftest.py`
- Test: `tests/test_auth.py`

**Interfaces:**
- Consumes: Tasks 3–5
- Produces: `api.auth.CallerIdentity(user_id: str, claims: dict)`; dependency `require_caller() -> CallerIdentity`; `api.main.create_app() -> FastAPI`; `GET /me` → `MeResponse`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_auth.py
import time
import jwt

SECRET = "test-jwt-secret"
ISSUER = "https://khohfrfqzbieaiikqlsa.supabase.co/auth/v1"


def mint(sub: str, *, aud="authenticated", iss=ISSUER, exp_delta=3600, secret=SECRET):
    return jwt.encode(
        {"sub": sub, "aud": aud, "iss": iss, "exp": int(time.time()) + exp_delta},
        secret, algorithm="HS256",
    )


async def test_missing_token_is_401(app_client):
    r = await app_client.get("/me")
    assert r.status_code == 401


async def test_expired_token_is_401(app_client, seeded):
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']), exp_delta=-10)}"})
    assert r.status_code == 401
    assert "expired" in r.json()["detail"].lower()


async def test_wrong_audience_is_401(app_client, seeded):
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']), aud='anon')}"})
    assert r.status_code == 401


async def test_wrong_issuer_is_401(app_client, seeded):
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']), iss='https://evil.test')}"})
    assert r.status_code == 401


async def test_token_signed_with_wrong_key_is_401(app_client, seeded):
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']), secret='not-the-secret')}"})
    assert r.status_code == 401


async def test_me_returns_only_callers_memberships(app_client, seeded):
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']))}"})
    assert r.status_code == 200
    org_ids = {m["org_id"] for m in r.json()["memberships"]}
    assert org_ids == {str(seeded["acme"])}
    assert str(seeded["bistro"]) not in org_ids


async def test_entitlement_is_server_derived_not_client_supplied(app_client, seeded):
    """Plan comes from organizations.plan, never from the token."""
    r = await app_client.get("/me", headers={
        "Authorization": f"Bearer {mint(str(seeded['alice']))}"})
    assert r.json()["entitlement"]["plan"] == "starter"
    assert r.json()["entitlement"]["max_locations"] == 1
```

- [ ] **Step 2: Append the `seeded` and `app_client` fixtures to `tests/conftest.py`**

```python
# append to tests/conftest.py
from httpx import AsyncClient, ASGITransport


@pytest.fixture
async def seeded(raw_conn):
    from tests.factories import make_user, make_org, add_member, make_location
    await apply_migrations(raw_conn, upto=6)
    alice = await make_user(raw_conn, "alice@acme.test")
    bob = await make_user(raw_conn, "bob@bistro.test")
    acme = await make_org(raw_conn, "Acme Diner")
    bistro = await make_org(raw_conn, "Bistro Nine")
    await add_member(raw_conn, alice, acme, "owner")
    await add_member(raw_conn, bob, bistro, "owner")
    await make_location(raw_conn, acme, "Acme Main")
    await raw_conn.commit()
    return dict(alice=alice, bob=bob, acme=acme, bistro=bistro)


@pytest.fixture
async def app_client(db_url, monkeypatch):
    monkeypatch.setenv("JWT_SECRET", "test-jwt-secret")
    monkeypatch.setenv("JWT_ISSUER", "https://khohfrfqzbieaiikqlsa.supabase.co/auth/v1")
    monkeypatch.setenv("DATABASE_URL", db_url.replace("postgres:postgres", "app_user:app_pw"))
    from api.main import create_app
    app = create_app()
    async with app.router.lifespan_context(app):
        async with AsyncClient(transport=ASGITransport(app=app), base_url="http://t") as c:
            yield c
```

- [ ] **Step 3: Run to verify it fails**

Run: `pytest tests/test_auth.py -v`
Expected: FAIL — `No module named 'api.main'`.

- [ ] **Step 4: Write `api/models.py`**

```python
# api/models.py
from pydantic import BaseModel, EmailStr

PLAN_LIMITS = {
    "starter": {"max_locations": 1, "max_invoices_per_month": 30, "max_recipes": 25, "max_members": 1},
    "growth":  {"max_locations": 1, "max_invoices_per_month": None, "max_recipes": None, "max_members": 3},
    "pro":     {"max_locations": 3, "max_invoices_per_month": None, "max_recipes": None, "max_members": 10},
}


class MembershipOut(BaseModel):
    org_id: str
    org_name: str
    role: str


class EntitlementOut(BaseModel):
    plan: str
    max_locations: int
    max_invoices_per_month: int | None
    max_recipes: int | None
    max_members: int


class MeResponse(BaseModel):
    user_id: str
    contact_email: EmailStr | None
    contact_email_verified: bool
    apple_linked: bool
    memberships: list[MembershipOut]
    entitlement: EntitlementOut
```

- [ ] **Step 5: Write `api/auth.py`**

```python
# api/auth.py
import os
from dataclasses import dataclass
import jwt
from fastapi import HTTPException, Request


@dataclass(frozen=True)
class CallerIdentity:
    user_id: str
    claims: dict


def _decode(token: str) -> dict:
    try:
        return jwt.decode(
            token,
            os.environ["JWT_SECRET"],
            algorithms=["HS256"],
            audience="authenticated",
            issuer=os.environ["JWT_ISSUER"],
            options={"require": ["exp", "sub", "aud", "iss"]},
        )
    except jwt.ExpiredSignatureError:
        raise HTTPException(401, "token expired")
    except jwt.InvalidTokenError as e:
        raise HTTPException(401, f"invalid token: {e}")


async def require_caller(request: Request) -> CallerIdentity:
    header = request.headers.get("authorization", "")
    if not header.lower().startswith("bearer "):
        raise HTTPException(401, "missing bearer token")
    claims = _decode(header.split(" ", 1)[1])
    return CallerIdentity(user_id=claims["sub"], claims=claims)
```

- [ ] **Step 6: Write `api/routes/me.py`** (and an empty `api/routes/__init__.py`)

```python
# api/routes/me.py
from fastapi import APIRouter, Depends, Request
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.models import EntitlementOut, MeResponse, MembershipOut, PLAN_LIMITS

router = APIRouter()


@router.get("/me", response_model=MeResponse)
async def me(request: Request, caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "SELECT contact_email, contact_email_verified_at IS NOT NULL, apple_sub IS NOT NULL "
            "FROM profiles WHERE user_id = %s",
            (caller.user_id,),
        )
        row = await cur.fetchone()
        contact_email, verified, apple_linked = row if row else (None, False, False)

        cur = await conn.execute(
            "SELECT o.id::text, o.name, m.role, o.plan "
            "FROM memberships m JOIN organizations o ON o.id = m.org_id "
            "WHERE m.user_id = %s ORDER BY o.name",
            (caller.user_id,),
        )
        rows = await cur.fetchall()

    memberships = [MembershipOut(org_id=r[0], org_name=r[1], role=r[2]) for r in rows]
    plan = rows[0][3] if rows else "starter"
    return MeResponse(
        user_id=caller.user_id,
        contact_email=contact_email,
        contact_email_verified=bool(verified),
        apple_linked=bool(apple_linked),
        memberships=memberships,
        entitlement=EntitlementOut(plan=plan, **PLAN_LIMITS[plan]),
    )
```

- [ ] **Step 7: Write `api/main.py`**

```python
# api/main.py
import os
from contextlib import asynccontextmanager
from fastapi import FastAPI
from api.db import pool_open
from api.routes import me


@asynccontextmanager
async def lifespan(app: FastAPI):
    app.state.pool = await pool_open(os.environ["DATABASE_URL"])
    yield
    await app.state.pool.close()


def create_app() -> FastAPI:
    app = FastAPI(title="CostSauce API", lifespan=lifespan)
    app.include_router(me.router)
    return app


app = create_app()
```

- [ ] **Step 8: Run tests to verify they pass**

Run: `pytest tests/test_auth.py -v`
Expected: 7 passed.

- [ ] **Step 9: Commit**

```bash
git add api/auth.py api/models.py api/routes/ api/main.py tests/test_auth.py tests/conftest.py
git commit -m "feat: JWT validation and GET /me with server-derived entitlement"
```

---

### Task 7: Apple linking keyed on `sub`, and verified contact email

**Files:**
- Create: `api/routes/identity.py`
- Modify: `api/main.py`
- Test: `tests/test_identity.py`

**Interfaces:**
- Consumes: Task 6
- Produces: `POST /identity/contact-email {email}`; `POST /identity/contact-email/verify {token}`; `POST /identity/apple/link-request`; `POST /identity/apple/link-confirm {token}`

The forbidden shortcut is auto-linking on matching email. Apple's relay address can change while `sub` is stable, and email-matching is an account-takeover primitive.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_identity.py
from tests.test_auth import mint


async def test_apple_signin_with_no_membership_does_not_autocreate_org(app_client, raw_conn, seeded):
    """A brand-new Apple sub must land in a linking flow, not a fresh org."""
    new_sub = "00000000-0000-7000-8000-0000000000aa"
    await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (%s, 'relay@privaterelay.appleid.com')",
        (new_sub,),
    )
    await raw_conn.commit()
    cur = await raw_conn.execute("SELECT count(*) FROM organizations")
    (before,) = await cur.fetchone()
    r = await app_client.get("/me", headers={"Authorization": f"Bearer {mint(new_sub)}"})
    assert r.status_code == 200
    assert r.json()["memberships"] == []
    cur = await raw_conn.execute("SELECT count(*) FROM organizations")
    (after,) = await cur.fetchone()
    assert after == before, "Apple sign-in must not auto-create an organization"


async def test_linking_by_matching_email_is_refused(app_client, raw_conn, seeded):
    """Explicitly assert the account-takeover primitive is absent."""
    attacker = "00000000-0000-7000-8000-0000000000bb"
    await raw_conn.execute(
        "INSERT INTO auth.users (id, email) VALUES (%s, 'alice@acme.test')", (attacker,)
    )
    await raw_conn.commit()
    r = await app_client.get("/me", headers={"Authorization": f"Bearer {mint(attacker)}"})
    assert r.json()["memberships"] == [], "linked on email — account takeover"


async def test_link_confirm_requires_valid_token(app_client, seeded):
    r = await app_client.post(
        "/identity/apple/link-confirm",
        json={"token": "not-a-real-token"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 400


async def test_contact_email_starts_unverified(app_client, seeded):
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    r = await app_client.post("/identity/contact-email",
                              json={"email": "owner@acme.test"}, headers=hdr)
    assert r.status_code == 200
    me = await app_client.get("/me", headers=hdr)
    assert me.json()["contact_email"] == "owner@acme.test"
    assert me.json()["contact_email_verified"] is False


async def test_relay_address_is_rejected_as_contact_email(app_client, seeded):
    """The digest must never be sent to a relay address."""
    r = await app_client.post(
        "/identity/contact-email",
        json={"email": "abc123@privaterelay.appleid.com"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 422
    assert "relay" in str(r.json()).lower()
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/test_identity.py -v`
Expected: FAIL — 404 on `/identity/contact-email`.

- [ ] **Step 3: Write `api/routes/identity.py`**

```python
# api/routes/identity.py
import hashlib
import hmac
import os
import secrets
import time
from datetime import datetime, timedelta, timezone
import jwt
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, EmailStr
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection

router = APIRouter(prefix="/identity")
RELAY_DOMAIN = "privaterelay.appleid.com"


class ContactEmailIn(BaseModel):
    email: EmailStr


class TokenIn(BaseModel):
    token: str


class ReviewerOtpIn(BaseModel):
    email: EmailStr
    code: str


@router.post("/contact-email")
async def set_contact_email(
    body: ContactEmailIn, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    if body.email.lower().endswith(RELAY_DOMAIN):
        raise HTTPException(
            422,
            "An Apple private relay address cannot receive the weekly drift digest. "
            "Enter an address you check directly.",
        )
    token = secrets.token_urlsafe(32)
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await conn.execute(
            "UPDATE profiles SET contact_email = %s, contact_email_verified_at = NULL "
            "WHERE user_id = %s",
            (body.email, caller.user_id),
        )
        await conn.execute(
            "INSERT INTO email_verifications (user_id, token_hash, expires_at) VALUES (%s, %s, %s)",
            (caller.user_id, hashlib.sha256(token.encode()).hexdigest(),
             datetime.now(timezone.utc) + timedelta(hours=24)),
        )
    return {"verification_sent": True}


@router.post("/contact-email/verify")
async def verify_contact_email(
    body: TokenIn, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    token_hash = hashlib.sha256(body.token.encode()).hexdigest()
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "DELETE FROM email_verifications WHERE user_id = %s AND token_hash = %s "
            "AND expires_at > now() RETURNING id",
            (caller.user_id, token_hash),
        )
        if not await cur.fetchone():
            raise HTTPException(400, "invalid or expired verification token")
        await conn.execute(
            "UPDATE profiles SET contact_email_verified_at = now() WHERE user_id = %s",
            (caller.user_id,),
        )
    return {"verified": True}


@router.post("/apple/link-request")
async def apple_link_request(request: Request, caller: CallerIdentity = Depends(require_caller)):
    """Send a magic link to the EXISTING account's verified address.

    Linking is only ever confirmed from the original address. Matching on the
    Apple-supplied email is forbidden — it is an account-takeover primitive.
    """
    token = secrets.token_urlsafe(32)
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await conn.execute(
            "INSERT INTO apple_link_requests (apple_sub, token_hash, expires_at) VALUES (%s, %s, %s)",
            (caller.user_id, hashlib.sha256(token.encode()).hexdigest(),
             datetime.now(timezone.utc) + timedelta(minutes=30)),
        )
    return {"link_token_sent": True}


@router.post("/apple/link-confirm")
async def apple_link_confirm(
    body: TokenIn, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    token_hash = hashlib.sha256(body.token.encode()).hexdigest()
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "DELETE FROM apple_link_requests WHERE token_hash = %s AND expires_at > now() "
            "RETURNING apple_sub",
            (token_hash,),
        )
        row = await cur.fetchone()
        if not row:
            raise HTTPException(400, "invalid or expired link token")
        await conn.execute(
            "UPDATE profiles SET apple_sub = %s WHERE user_id = %s", (row[0], caller.user_id)
        )
    return {"linked": True}


async def reviewer_otp(body: ReviewerOtpIn):
    """Fixed-credential sign-in for App Review only. Feature-flagged off.

    Registered on a bare /auth/reviewer-otp path in api/main.py, not under
    the /identity prefix.
    """
    if os.environ.get("REVIEWER_OTP_ENABLED") != "1":
        raise HTTPException(404, "not found")
    expected_email = os.environ.get("REVIEWER_EMAIL", "")
    expected_code = os.environ.get("REVIEWER_CODE", "")
    ok_email = hmac.compare_digest(body.email.lower(), expected_email.lower())
    ok_code = hmac.compare_digest(body.code, expected_code)
    if not (expected_email and expected_code and ok_email and ok_code):
        raise HTTPException(403, "invalid reviewer credentials")
    token = jwt.encode(
        {"sub": os.environ["REVIEWER_USER_ID"], "aud": "authenticated",
         "iss": os.environ["JWT_ISSUER"], "exp": int(time.time()) + 3600},
        os.environ["JWT_SECRET"], algorithm="HS256",
    )
    return {"access_token": token}
```

- [ ] **Step 4: Register in `api/main.py`**

```python
from api.routes import identity, me
from api.routes.identity import reviewer_otp

# in create_app():
    app.include_router(identity.router)
    app.post("/auth/reviewer-otp", include_in_schema=False)(reviewer_otp)
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `pytest tests/test_identity.py -v`
Expected: 5 passed.

- [ ] **Step 6: Commit**

```bash
git add api/routes/identity.py api/main.py tests/test_identity.py
git commit -m "feat: Apple linking keyed on sub, verified contact email, relay rejection"
```

---

### Task 8: Reviewer OTP tests

**Files:**
- Test: `tests/test_reviewer_otp.py`

**Interfaces:**
- Consumes: Task 7's `reviewer_otp`
- Produces: nothing new

App Review cannot receive a magic-link email. Without this path, submission fails under guideline 2.1.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_reviewer_otp.py
async def test_reviewer_otp_disabled_by_default(app_client):
    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": "review@costsauce.com", "code": "123456"})
    assert r.status_code == 404


async def test_reviewer_otp_rejects_other_addresses(app_client, monkeypatch):
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.setenv("REVIEWER_EMAIL", "review@costsauce.com")
    monkeypatch.setenv("REVIEWER_CODE", "424242")
    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": "attacker@evil.test", "code": "424242"})
    assert r.status_code == 403


async def test_reviewer_otp_rejects_wrong_code(app_client, monkeypatch):
    monkeypatch.setenv("REVIEWER_OTP_ENABLED", "1")
    monkeypatch.setenv("REVIEWER_EMAIL", "review@costsauce.com")
    monkeypatch.setenv("REVIEWER_CODE", "424242")
    r = await app_client.post("/auth/reviewer-otp",
                              json={"email": "review@costsauce.com", "code": "000000"})
    assert r.status_code == 403
```

- [ ] **Step 2: Run tests to verify they pass**

Run: `pytest tests/test_reviewer_otp.py -v`
Expected: 3 passed (the route already exists from Task 7).

- [ ] **Step 3: Commit**

```bash
git add tests/test_reviewer_otp.py
git commit -m "test: reviewer OTP is off by default and rejects wrong credentials"
```

---

### Task 9: Invites and role management

**Files:**
- Create: `api/routes/members.py`
- Modify: `api/main.py`
- Test: `tests/test_members.py`

**Interfaces:**
- Consumes: Tasks 5–6
- Produces: `POST /orgs/{org_id}/invites {email, role}` → `{invite_id, token}`; `POST /invites/accept {token}`; `PATCH /orgs/{org_id}/members/{user_id} {role}`; `DELETE /orgs/{org_id}/members/{user_id}`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_members.py
from tests.test_auth import mint
from tests.factories import make_user, add_member


async def test_non_owner_cannot_invite(app_client, raw_conn, seeded):
    carol = await make_user(raw_conn, "carol@acme.test")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await raw_conn.commit()
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "dave@acme.test", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(carol))}"},
    )
    assert r.status_code == 403


async def test_owner_can_invite_and_invitee_joins(app_client, raw_conn, seeded):
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "dave@acme.test", "role": "bookkeeper"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200
    token = r.json()["token"]
    dave = await make_user(raw_conn, "dave@acme.test")
    await raw_conn.commit()
    r2 = await app_client.post("/invites/accept", json={"token": token},
                               headers={"Authorization": f"Bearer {mint(str(dave))}"})
    assert r2.status_code == 200
    me = await app_client.get("/me", headers={"Authorization": f"Bearer {mint(str(dave))}"})
    assert me.json()["memberships"][0]["role"] == "bookkeeper"


async def test_owner_of_org_a_cannot_invite_into_org_b(app_client, seeded):
    r = await app_client.post(
        f"/orgs/{seeded['bistro']}/invites",
        json={"email": "x@y.test", "role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 403


async def test_last_owner_cannot_be_demoted(app_client, seeded):
    r = await app_client.patch(
        f"/orgs/{seeded['acme']}/members/{seeded['alice']}",
        json={"role": "manager"},
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 409
    assert "last owner" in str(r.json()).lower()


async def test_last_owner_cannot_be_removed(app_client, seeded):
    r = await app_client.delete(
        f"/orgs/{seeded['acme']}/members/{seeded['alice']}",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 409
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/test_members.py -v`
Expected: FAIL — 404 on the invites route.

- [ ] **Step 3: Write `api/routes/members.py`**

```python
# api/routes/members.py
import hashlib
import secrets
from datetime import datetime, timedelta, timezone
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, EmailStr
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection

router = APIRouter()
ROLES = ("owner", "manager", "bookkeeper")


class InviteIn(BaseModel):
    email: EmailStr
    role: str


class AcceptIn(BaseModel):
    token: str


class RoleIn(BaseModel):
    role: str


async def _require_owner(conn, user_id: str, org_id: str):
    cur = await conn.execute(
        "SELECT 1 FROM memberships WHERE org_id = %s AND user_id = %s AND role = 'owner'",
        (org_id, user_id),
    )
    if not await cur.fetchone():
        raise HTTPException(403, "owner role required")


async def _owner_count(conn, org_id: str) -> int:
    cur = await conn.execute(
        "SELECT count(*) FROM memberships WHERE org_id = %s AND role = 'owner'", (org_id,)
    )
    (n,) = await cur.fetchone()
    return n


@router.post("/orgs/{org_id}/invites")
async def create_invite(
    org_id: str, body: InviteIn, request: Request,
    caller: CallerIdentity = Depends(require_caller),
):
    if body.role not in ROLES:
        raise HTTPException(422, "unknown role")
    token = secrets.token_urlsafe(32)
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_owner(conn, caller.user_id, org_id)
        cur = await conn.execute(
            "INSERT INTO invites (org_id, email, role, token_hash, invited_by, expires_at) "
            "VALUES (%s, %s, %s, %s, %s, %s) RETURNING id",
            (org_id, body.email, body.role, hashlib.sha256(token.encode()).hexdigest(),
             caller.user_id, datetime.now(timezone.utc) + timedelta(days=7)),
        )
        (invite_id,) = await cur.fetchone()
    return {"invite_id": str(invite_id), "token": token}


@router.post("/invites/accept")
async def accept_invite(
    body: AcceptIn, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    token_hash = hashlib.sha256(body.token.encode()).hexdigest()
    # The invitee has no membership yet, so RLS cannot see the invite row. This
    # is the one deliberate elevated path in the phase: it is narrow (one row,
    # found only by an unguessable token hash) and writes only the caller's own
    # membership.
    async with request.app.state.pool.connection() as conn:
        await conn.set_autocommit(False)
        try:
            cur = await conn.execute(
                "UPDATE invites SET accepted_at = now() WHERE token_hash = %s "
                "AND accepted_at IS NULL AND expires_at > now() RETURNING org_id, role",
                (token_hash,),
            )
            row = await cur.fetchone()
            if not row:
                await conn.rollback()
                raise HTTPException(400, "invalid, expired, or already-used invite")
            org_id, role = row
            await conn.execute(
                "INSERT INTO memberships (user_id, org_id, role) VALUES (%s, %s, %s) "
                "ON CONFLICT (user_id, org_id) DO UPDATE SET role = EXCLUDED.role",
                (caller.user_id, org_id, role),
            )
            await conn.commit()
        except HTTPException:
            raise
        except BaseException:
            await conn.rollback()
            raise
    return {"org_id": str(org_id), "role": role}


@router.patch("/orgs/{org_id}/members/{user_id}")
async def change_role(
    org_id: str, user_id: str, body: RoleIn, request: Request,
    caller: CallerIdentity = Depends(require_caller),
):
    if body.role not in ROLES:
        raise HTTPException(422, "unknown role")
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_owner(conn, caller.user_id, org_id)
        if body.role != "owner" and await _owner_count(conn, org_id) == 1:
            cur = await conn.execute(
                "SELECT 1 FROM memberships WHERE org_id = %s AND user_id = %s AND role = 'owner'",
                (org_id, user_id),
            )
            if await cur.fetchone():
                raise HTTPException(409, "cannot demote the last owner")
        await conn.execute(
            "UPDATE memberships SET role = %s WHERE org_id = %s AND user_id = %s",
            (body.role, org_id, user_id),
        )
    return {"role": body.role}


@router.delete("/orgs/{org_id}/members/{user_id}")
async def remove_member(
    org_id: str, user_id: str, request: Request,
    caller: CallerIdentity = Depends(require_caller),
):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_owner(conn, caller.user_id, org_id)
        cur = await conn.execute(
            "SELECT role FROM memberships WHERE org_id = %s AND user_id = %s", (org_id, user_id)
        )
        row = await cur.fetchone()
        if not row:
            raise HTTPException(404, "member not found")
        if row[0] == "owner" and await _owner_count(conn, org_id) == 1:
            raise HTTPException(409, "cannot remove the last owner; delete the organization instead")
        await conn.execute(
            "DELETE FROM memberships WHERE org_id = %s AND user_id = %s", (org_id, user_id)
        )
    return {"removed": True}
```

- [ ] **Step 4: Register the router and run tests**

Add `from api.routes import members` and `app.include_router(members.router)` to `create_app()`.
Run: `pytest tests/test_members.py -v`
Expected: 5 passed.

- [ ] **Step 5: Commit**

```bash
git add api/routes/members.py api/main.py tests/test_members.py
git commit -m "feat: invites and role management with last-owner protection"
```

---

### Task 10: Deletion side-effect services

**Files:**
- Create: `api/services/__init__.py`, `api/services/apple.py`, `api/services/billing.py`, `api/services/export.py`
- Test: `tests/test_deletion_services.py`

**Interfaces:**
- Consumes: nothing
- Produces: `revoke_apple_token(refresh_token, *, client_id, client_secret, http=None) -> None`; `AppleRevokeError`; `cancel_subscription(customer_id: str | None) -> None`; `build_export(conn, org_id: str) -> bytes`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_deletion_services.py
import io
import zipfile
import httpx
import pytest
from api.services.apple import revoke_apple_token, AppleRevokeError
from api.services.export import build_export


async def test_apple_revoke_posts_to_the_documented_endpoint():
    seen = {}

    async def handler(request):
        seen["url"] = str(request.url)
        seen["body"] = request.content.decode()
        return httpx.Response(200)

    async with httpx.AsyncClient(transport=httpx.MockTransport(handler)) as client:
        await revoke_apple_token("rt-123", client_id="app.costsauce",
                                 client_secret="secret", http=client)
    assert seen["url"] == "https://appleid.apple.com/auth/revoke"
    assert "token=rt-123" in seen["body"]
    assert "token_type_hint=refresh_token" in seen["body"]


async def test_apple_revoke_raises_on_failure():
    transport = httpx.MockTransport(lambda r: httpx.Response(400, text="invalid_grant"))
    async with httpx.AsyncClient(transport=transport) as client:
        with pytest.raises(AppleRevokeError):
            await revoke_apple_token("bad", client_id="c", client_secret="s", http=client)


async def test_export_contains_every_table_as_csv(raw_conn, seeded):
    blob = await build_export(raw_conn, str(seeded["acme"]))
    with zipfile.ZipFile(io.BytesIO(blob)) as z:
        names = set(z.namelist())
    assert {"organization.csv", "locations.csv", "members.csv"} <= names
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/test_deletion_services.py -v`
Expected: FAIL — `No module named 'api.services.apple'`.

- [ ] **Step 3: Write `api/services/apple.py`**

```python
# api/services/apple.py
import httpx

REVOKE_URL = "https://appleid.apple.com/auth/revoke"


class AppleRevokeError(RuntimeError):
    pass


async def revoke_apple_token(refresh_token: str, *, client_id: str,
                             client_secret: str, http: httpx.AsyncClient | None = None) -> None:
    """Apple requires token revocation when a SIWA account is deleted."""
    owns_client = http is None
    http = http or httpx.AsyncClient(timeout=10)
    try:
        resp = await http.post(REVOKE_URL, data={
            "client_id": client_id,
            "client_secret": client_secret,
            "token": refresh_token,
            "token_type_hint": "refresh_token",
        })
        if resp.status_code >= 400:
            raise AppleRevokeError(f"Apple revoke failed {resp.status_code}: {resp.text}")
    finally:
        if owns_client:
            await http.aclose()
```

- [ ] **Step 4: Write `api/services/billing.py`**

```python
# api/services/billing.py
import os
import stripe


class BillingError(RuntimeError):
    pass


async def cancel_subscription(customer_id: str | None) -> None:
    """Cancel immediately on deletion confirm, not after the 30-day grace."""
    if not customer_id:
        return
    stripe.api_key = os.environ.get("STRIPE_API_KEY", "")
    if not stripe.api_key:
        return
    try:
        for sub in stripe.Subscription.list(
            customer=customer_id, status="active"
        ).auto_paging_iter():
            stripe.Subscription.delete(sub.id)
    except stripe.error.StripeError as e:
        raise BillingError(str(e)) from e
```

- [ ] **Step 5: Write `api/services/export.py`**

```python
# api/services/export.py
import csv
import io
import zipfile

TABLES = {
    "organization.csv": "SELECT id, name, plan, created_at FROM organizations WHERE id = %s",
    "locations.csv": "SELECT id, name, target_fc_pct, drift_threshold_pct "
                     "FROM locations WHERE org_id = %s",
    "members.csv": "SELECT m.user_id, m.role, p.contact_email FROM memberships m "
                   "LEFT JOIN profiles p ON p.user_id = m.user_id WHERE m.org_id = %s",
}


async def build_export(conn, org_id: str) -> bytes:
    buf = io.BytesIO()
    with zipfile.ZipFile(buf, "w", zipfile.ZIP_DEFLATED) as z:
        for filename, sql in TABLES.items():
            cur = await conn.execute(sql, (org_id,))
            rows = await cur.fetchall()
            headers = [d.name for d in cur.description]
            out = io.StringIO()
            w = csv.writer(out)
            w.writerow(headers)
            w.writerows(rows)
            z.writestr(filename, out.getvalue())
    return buf.getvalue()
```

- [ ] **Step 6: Run tests to verify they pass**

Run: `pytest tests/test_deletion_services.py -v`
Expected: 3 passed.

- [ ] **Step 7: Commit**

```bash
git add api/services/ tests/test_deletion_services.py
git commit -m "feat: Apple revoke, Stripe cancel, and org export services"
```

---

### Task 11: Deletion schema, endpoints, and the write guard (non-negotiable)

**Files:**
- Create: `supabase/migrations/0005_deletion.sql`, `api/routes/deletion.py`
- Modify: `api/main.py`
- Test: `tests/test_deletion.py`

**Interfaces:**
- Consumes: Tasks 9–10
- Produces: `DELETE /me`; `POST /orgs/{org_id}/deletion`; `DELETE /orgs/{org_id}/deletion`; `GET /orgs/{org_id}/export`; SQL function `purge_scheduled_orgs(grace interval) returns int`; middleware `deletion_guard`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_deletion.py
from tests.test_auth import mint
from tests.factories import make_user, add_member


async def test_deleting_own_account_when_not_last_owner_leaves_org_intact(
    app_client, raw_conn, seeded
):
    carol = await make_user(raw_conn, "carol@acme.test")
    await add_member(raw_conn, carol, seeded["acme"], "manager")
    await raw_conn.commit()
    r = await app_client.delete("/me", headers={"Authorization": f"Bearer {mint(str(carol))}"})
    assert r.status_code == 200
    assert r.json()["deleted"] == "membership"
    cur = await raw_conn.execute(
        "SELECT count(*) FROM organizations WHERE id = %s", (seeded["acme"],)
    )
    (n,) = await cur.fetchone()
    assert n == 1, "removing a member must not delete the organization"


async def test_last_owner_deleting_account_is_routed_to_org_deletion(app_client, seeded):
    """Must not silently orphan the org."""
    r = await app_client.delete(
        "/me", headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    )
    assert r.status_code == 409
    detail = r.json()["detail"]
    assert "organization" in detail["detail"].lower()
    assert str(seeded["acme"]) in detail["orgs_requiring_deletion"]


async def test_scheduling_org_deletion_sets_timestamp_immediately(app_client, raw_conn, seeded):
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/deletion",
        headers={"Authorization": f"Bearer {mint(str(seeded['alice']))}"},
    )
    assert r.status_code == 200
    assert r.json()["purge_after_days"] == 30
    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (seeded["acme"],)
    )
    (ts,) = await cur.fetchone()
    assert ts is not None, "deletion_scheduled_at must be set on confirm"


async def test_scheduled_org_rejects_writes_before_purge(app_client, seeded):
    """The pre-sync deletion guard. Data must not be resurrected."""
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    r = await app_client.post(
        f"/orgs/{seeded['acme']}/invites",
        json={"email": "zombie@acme.test", "role": "manager"}, headers=hdr,
    )
    assert r.status_code == 410
    assert "scheduled for deletion" in str(r.json()).lower()


async def test_owner_can_cancel_within_grace_window(app_client, raw_conn, seeded):
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    r = await app_client.delete(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    assert r.status_code == 200
    cur = await raw_conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (seeded["acme"],)
    )
    (ts,) = await cur.fetchone()
    assert ts is None


async def test_purge_removes_org_only_after_grace_elapses(raw_conn, seeded):
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '10 days' WHERE id = %s",
        (seeded["acme"],),
    )
    cur = await raw_conn.execute("SELECT purge_scheduled_orgs(interval '30 days')")
    (purged,) = await cur.fetchone()
    assert purged == 0, "must not purge inside the grace window"

    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' WHERE id = %s",
        (seeded["acme"],),
    )
    cur = await raw_conn.execute("SELECT purge_scheduled_orgs(interval '30 days')")
    (purged,) = await cur.fetchone()
    assert purged == 1
    cur = await raw_conn.execute(
        "SELECT count(*) FROM locations WHERE org_id = %s", (seeded["acme"],)
    )
    (n,) = await cur.fetchone()
    assert n == 0, "purge must cascade to locations"


async def test_offline_device_push_after_deletion_is_discarded(app_client, seeded):
    """The 30-days-offline case: a stale device must not resurrect the org."""
    hdr = {"Authorization": f"Bearer {mint(str(seeded['alice']))}"}
    await app_client.post(f"/orgs/{seeded['acme']}/deletion", headers=hdr)
    r = await app_client.patch(
        f"/orgs/{seeded['acme']}/members/{seeded['alice']}",
        json={"role": "manager"}, headers=hdr,
    )
    assert r.status_code == 410
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/test_deletion.py -v`
Expected: FAIL — 405 on `DELETE /me`.

- [ ] **Step 3: Write `0005_deletion.sql`**

```sql
ALTER TABLE organizations ADD COLUMN deletion_scheduled_at timestamptz;
ALTER TABLE organizations ADD COLUMN stripe_customer_id text;
CREATE INDEX organizations_deletion_idx ON organizations (deletion_scheduled_at)
  WHERE deletion_scheduled_at IS NOT NULL;

CREATE OR REPLACE FUNCTION purge_scheduled_orgs(grace interval)
RETURNS int AS $$
DECLARE
  purged int;
BEGIN
  WITH doomed AS (
    DELETE FROM organizations
    WHERE deletion_scheduled_at IS NOT NULL
      AND deletion_scheduled_at < now() - grace
    RETURNING id
  )
  SELECT count(*) INTO purged FROM doomed;
  RETURN purged;
END;
$$ LANGUAGE plpgsql;
```

Every child table declares `ON DELETE CASCADE` against `organizations`, so this single delete removes memberships, locations, and invites. Storage objects are handled by the job in Task 12.

- [ ] **Step 4: Write `api/routes/deletion.py`**

```python
# api/routes/deletion.py
import os
from fastapi import APIRouter, Depends, HTTPException, Request, Response
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.services.apple import revoke_apple_token, AppleRevokeError
from api.services.billing import cancel_subscription
from api.services.export import build_export

router = APIRouter()
GRACE_DAYS = 30


async def _require_owner(conn, user_id: str, org_id: str):
    cur = await conn.execute(
        "SELECT 1 FROM memberships WHERE org_id = %s AND user_id = %s AND role = 'owner'",
        (org_id, user_id),
    )
    if not await cur.fetchone():
        raise HTTPException(403, "owner role required")


@router.delete("/me")
async def delete_account(request: Request, caller: CallerIdentity = Depends(require_caller)):
    """Remove the caller's memberships. If they are the last owner of any org,
    refuse and route them to organization deletion rather than orphaning it."""
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        cur = await conn.execute(
            "SELECT m.org_id::text FROM memberships m WHERE m.user_id = %s AND m.role = 'owner' "
            "AND (SELECT count(*) FROM memberships o WHERE o.org_id = m.org_id "
            "     AND o.role = 'owner') = 1",
            (caller.user_id,),
        )
        sole_owner_orgs = [r[0] for r in await cur.fetchall()]
        if sole_owner_orgs:
            raise HTTPException(409, detail={
                "detail": "You are the last owner of an organization. Delete the organization, "
                          "or transfer ownership first.",
                "orgs_requiring_deletion": sole_owner_orgs,
            })
        await conn.execute("DELETE FROM memberships WHERE user_id = %s", (caller.user_id,))
        await conn.execute("DELETE FROM profiles WHERE user_id = %s", (caller.user_id,))
    return {"deleted": "membership"}


@router.post("/orgs/{org_id}/deletion")
async def schedule_org_deletion(
    org_id: str, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_owner(conn, caller.user_id, org_id)
        cur = await conn.execute(
            "UPDATE organizations SET deletion_scheduled_at = now() WHERE id = %s "
            "RETURNING stripe_customer_id",
            (org_id,),
        )
        row = await cur.fetchone()
        stripe_customer_id = row[0] if row else None

    # Side effects happen immediately on confirm, never after the grace window.
    await cancel_subscription(stripe_customer_id)
    refresh_token = os.environ.get("APPLE_REFRESH_TOKEN")
    if refresh_token:
        try:
            await revoke_apple_token(
                refresh_token,
                client_id=os.environ["APPLE_CLIENT_ID"],
                client_secret=os.environ["APPLE_CLIENT_SECRET"],
            )
        except AppleRevokeError:
            pass  # logged upstream; must never block the user's deletion request

    return {"scheduled": True, "purge_after_days": GRACE_DAYS}


@router.delete("/orgs/{org_id}/deletion")
async def cancel_org_deletion(
    org_id: str, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_owner(conn, caller.user_id, org_id)
        await conn.execute(
            "UPDATE organizations SET deletion_scheduled_at = NULL WHERE id = %s", (org_id,)
        )
    return {"cancelled": True}


@router.get("/orgs/{org_id}/export")
async def export_org(
    org_id: str, request: Request, caller: CallerIdentity = Depends(require_caller)
):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_owner(conn, caller.user_id, org_id)
        blob = await build_export(conn, org_id)
    return Response(blob, media_type="application/zip", headers={
        "Content-Disposition": f'attachment; filename="costsauce-export-{org_id}.zip"',
        "X-Content-Type-Options": "nosniff",
    })
```

- [ ] **Step 5: Add the deletion guard to `api/main.py`**

```python
# api/main.py — add above create_app()
import re
from fastapi import Request
from fastapi.responses import JSONResponse

ORG_PATH = re.compile(r"/orgs/([0-9a-fA-F-]{36})")
READ_ONLY = {"GET", "HEAD", "OPTIONS"}


async def deletion_guard(request: Request, call_next):
    """Reject writes to an org scheduled for deletion.

    This is the guard the spec requires before any sync batch is applied. A
    device offline through the deletion must have its queue discarded rather
    than resurrecting the data.
    """
    match = ORG_PATH.search(request.url.path)
    is_cancel = request.method == "DELETE" and request.url.path.endswith("/deletion")
    if match and request.method not in READ_ONLY and not is_cancel:
        async with request.app.state.pool.connection() as conn:
            cur = await conn.execute(
                "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (match.group(1),)
            )
            row = await cur.fetchone()
        if row and row[0] is not None:
            return JSONResponse(
                {"detail": "This organization is scheduled for deletion."}, status_code=410
            )
    return await call_next(request)


# in create_app(), BEFORE include_router calls:
    app.middleware("http")(deletion_guard)
    app.include_router(deletion.router)
```

The guard queries as `app_user` without adopting caller claims. `organizations` has FORCE RLS, so add a dedicated policy in `0005_deletion.sql` permitting `app_user` to read only the `deletion_scheduled_at` column — or, simpler and preferred, define the check as a `SECURITY DEFINER` function:

```sql
CREATE OR REPLACE FUNCTION org_is_scheduled_for_deletion(target uuid)
RETURNS boolean AS $$
  SELECT deletion_scheduled_at IS NOT NULL FROM organizations WHERE id = target;
$$ LANGUAGE sql STABLE SECURITY DEFINER;
REVOKE ALL ON FUNCTION org_is_scheduled_for_deletion(uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION org_is_scheduled_for_deletion(uuid) TO app_user, authenticated;
```

Then the middleware calls `SELECT org_is_scheduled_for_deletion(%s)` instead of selecting from the table. It leaks one boolean about an org id the caller already named, and nothing else.

- [ ] **Step 6: Run tests to verify they pass**

Run: `pytest tests/test_deletion.py -v`
Expected: 7 passed. **All must pass — this is the second non-negotiable suite.**

- [ ] **Step 7: Commit**

```bash
git add supabase/migrations/0005_deletion.sql api/routes/deletion.py api/main.py tests/test_deletion.py
git commit -m "feat: account and org deletion with 30-day grace and pre-write guard"
```

---

### Task 12: Scheduled purge job

**Files:**
- Create: `api/jobs/__init__.py`, `api/jobs/purge.py`
- Test: `tests/test_purge_job.py`

**Interfaces:**
- Consumes: Task 11
- Produces: `run_purge(db_url: str, storage_delete=None) -> int`

- [ ] **Step 1: Write the failing test**

```python
# tests/test_purge_job.py
from api.jobs.purge import run_purge


async def test_purge_job_deletes_storage_prefix_for_each_purged_org(raw_conn, seeded, db_url):
    deleted_prefixes = []

    async def fake_storage_delete(prefix: str):
        deleted_prefixes.append(prefix)

    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() - interval '31 days' WHERE id = %s",
        (seeded["acme"],),
    )
    await raw_conn.commit()
    n = await run_purge(db_url, storage_delete=fake_storage_delete)
    assert n == 1
    assert deleted_prefixes == [f"{seeded['acme']}/"]


async def test_purge_job_is_a_noop_when_nothing_is_due(raw_conn, seeded, db_url):
    n = await run_purge(db_url, storage_delete=None)
    assert n == 0
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/test_purge_job.py -v`
Expected: FAIL — `No module named 'api.jobs.purge'`.

- [ ] **Step 3: Write `api/jobs/purge.py`**

```python
# api/jobs/purge.py
import asyncio
import os
import psycopg

GRACE = "30 days"


async def run_purge(db_url: str, storage_delete=None) -> int:
    """Hard-delete organizations whose grace window has elapsed.

    Storage objects are removed BEFORE the rows, so a crash mid-purge leaves the
    org row behind and the job retries, rather than orphaning files whose owning
    org no longer exists.
    """
    conn = await psycopg.AsyncConnection.connect(db_url, autocommit=False)
    try:
        cur = await conn.execute(
            "SELECT id::text FROM organizations WHERE deletion_scheduled_at IS NOT NULL "
            "AND deletion_scheduled_at < now() - interval %s FOR UPDATE",
            (GRACE,),
        )
        doomed = [r[0] for r in await cur.fetchall()]
        if not doomed:
            await conn.rollback()
            return 0
        if storage_delete is not None:
            for org_id in doomed:
                await storage_delete(f"{org_id}/")
        cur = await conn.execute("SELECT purge_scheduled_orgs(interval %s)", (GRACE,))
        (purged,) = await cur.fetchone()
        await conn.commit()
        return purged
    except BaseException:
        await conn.rollback()
        raise
    finally:
        await conn.close()


if __name__ == "__main__":
    print(asyncio.run(run_purge(os.environ["DATABASE_URL"])))
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_purge_job.py -v`
Expected: 2 passed.

- [ ] **Step 5: Commit**

```bash
git add api/jobs/ tests/test_purge_job.py
git commit -m "feat: scheduled 30-day purge job with storage-first ordering"
```

---

### Task 13: Sample org with fictional distributors

**Files:**
- Create: `supabase/migrations/0006_sample_org.sql`
- Test: `tests/test_sample_org.py`

**Interfaces:**
- Consumes: Task 2
- Produces: `organizations.is_sample boolean`; one seeded sample org

The current seed uses real trademarked distributors (`product/app.py:254-263`). Those names must not appear in App Store screenshots or on any customer's screen.

- [ ] **Step 1: Write the failing test**

```python
# tests/test_sample_org.py
from tests.conftest import apply_migrations

BANNED = ["Sysco", "US Foods", "Reinhart", "FreshPoint", "Fresh Point", "Regalis"]


async def test_no_real_distributor_names_anywhere_in_seed(raw_conn):
    await apply_migrations(raw_conn, upto=6)
    cur = await raw_conn.execute(
        "SELECT name FROM organizations UNION ALL SELECT name FROM locations"
    )
    blob = " ".join(r[0] for r in await cur.fetchall())
    for name in BANNED:
        assert name.lower() not in blob.lower(), f"real distributor name in seed: {name}"


async def test_sample_org_is_flagged(raw_conn):
    await apply_migrations(raw_conn, upto=6)
    cur = await raw_conn.execute("SELECT count(*) FROM organizations WHERE is_sample")
    (n,) = await cur.fetchone()
    assert n == 1


async def test_no_sample_rows_leak_into_a_real_org(raw_conn):
    await apply_migrations(raw_conn, upto=6)
    cur = await raw_conn.execute(
        "SELECT count(*) FROM locations l JOIN organizations o ON o.id = l.org_id "
        "WHERE NOT o.is_sample AND l.name LIKE 'Sample%'"
    )
    (n,) = await cur.fetchone()
    assert n == 0
```

- [ ] **Step 2: Run to verify it fails**

Run: `pytest tests/test_sample_org.py -v`
Expected: FAIL — column `is_sample` does not exist.

- [ ] **Step 3: Write `0006_sample_org.sql`**

```sql
ALTER TABLE organizations ADD COLUMN is_sample boolean NOT NULL DEFAULT false;

-- Demo organisation. Distributor names are deliberately fictional: the previous
-- seed paired real trademarked companies with invented prices and drift figures.
INSERT INTO organizations (id, name, plan, is_sample)
VALUES ('00000000-0000-7000-8000-00000000cafe', 'The Copper Ladle (Sample)', 'pro', true);

INSERT INTO locations (org_id, name, target_fc_pct, drift_threshold_pct)
VALUES ('00000000-0000-7000-8000-00000000cafe', 'Sample Kitchen', 30.00, 5.00);
```

Fictional vendor names for the Phase 1b ingredient seed, replacing the real ones: `Northgate Provisions`, `Harborline Foods`, `Cedar Valley Produce`, `Anchor Dairy Co.`, `Ellsworth Specialty`.

- [ ] **Step 4: Run tests to verify they pass**

Run: `pytest tests/test_sample_org.py -v`
Expected: 3 passed.

- [ ] **Step 5: Commit**

```bash
git add supabase/migrations/0006_sample_org.sql tests/test_sample_org.py
git commit -m "feat: flagged sample org with fictional distributor names"
```

---

### Task 14: Apply to Supabase and verify advisors

**Files:**
- Create: `docs/runbooks/phase-1a-deploy.md`

**Interfaces:**
- Consumes: Tasks 2–13
- Produces: the migrated `khohfrfqzbieaiikqlsa` project

- [ ] **Step 1: Run the full suite locally**

Run: `pytest -v`
Expected: every test passes. Do not proceed otherwise.

- [ ] **Step 2: Apply migrations via the Supabase MCP `apply_migration` tool**

Apply `0001` through `0006` in order, one call each, using each file's basename as the migration name. Stop at the first error.

- [ ] **Step 3: Verify RLS and check advisors**

Run `list_tables` with `verbose: true` against `khohfrfqzbieaiikqlsa`, then `get_advisors` with `type: "security"`.
Expected: **zero** advisories of type "RLS disabled in public". If any table appears, add its policy to `0004` and re-apply before continuing.

- [ ] **Step 4: Write `docs/runbooks/phase-1a-deploy.md`**

Record: the migration order; that `app_user`'s production password comes from the Supabase connection string and never the literal in `0003`; that `REVIEWER_OTP_ENABLED` is set to `1` only during App Review and unset immediately after; and that `api/jobs/purge.py` runs daily via cron.

- [ ] **Step 5: Commit**

```bash
git add docs/runbooks/phase-1a-deploy.md
git commit -m "docs: Phase 1a deployment runbook"
```

---

## Self-Review

**Spec coverage.** Every Phase 1a item in §16 of the spec maps to a task: organizations/memberships/locations/profiles → Task 2; RLS with FORCE and WITH CHECK → Tasks 4–5; `app_user` and SET LOCAL → Task 3; magic link + SIWA with `sub`-keyed identity and the explicit link flow → Tasks 6–7; verified contact email → Task 7; full multi-user roles and invites → Task 9; account and org deletion with 30-day grace, export, Stripe cancel, Apple revoke → Tasks 10–12; pre-sync deletion guard → Task 11; reviewer OTP → Tasks 7–8; sample org with fictional names → Task 13; cross-org RLS test → Task 5; end-to-end deletion test → Task 11.

**Deliberately out of scope, not gaps:** the ingredient/purchase/recipe tables, the money contract, and the golden vectors are Phase 1b. Phase 1a creates no business tables, so there is nothing for those to apply to yet.

**Known gap, tracked:** `api/services/billing.py` needs `organizations.stripe_customer_id` populated, which no Phase 1a task does — billing signup is a Phase 5 concern. The column exists and `cancel_subscription` no-ops on `None`, so this is safe, but it must be wired before the first paying customer.

**Type consistency.** `CallerIdentity(user_id, claims)` is constructed and consumed identically in Tasks 6–12. `tenant_connection(pool, claims)` always receives the claims dict, never the identity object. `apply_migrations(conn, upto=N)` uses the `upto` keyword throughout. Role strings are exactly `owner`/`manager`/`bookkeeper` in the CHECK constraint, the RLS policies, `PLAN_LIMITS`, and the `ROLES` tuple in `members.py`. `_require_owner` is defined separately in `members.py` and `deletion.py` with identical signatures — acceptable duplication across route modules, but if a third copy appears, hoist it into `api/auth.py`.
