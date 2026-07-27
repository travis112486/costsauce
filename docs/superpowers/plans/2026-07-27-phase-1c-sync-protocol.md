# Phase 1c — Sync Protocol Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement the offline-first sync protocol from spec §5: per-org `server_seq` cursor, per-field LWW on `client_mutated_at`, `op_id` idempotency ledger, canonical recipe-item upsert, monotonic tombstones, FK-ordered atomic batch apply, deletion guard, page-capped pull — plus the two deferred 1b follow-ups (normalized-ingredient-name unique index, widened RLS audits).

**Architecture:** A migration (0014) adds the three-timestamp split and a `SECURITY DEFINER` stamp trigger that allocates `server_seq` from `organizations.sync_counter` inside the writing transaction, so every write path (routes AND sync) is covered structurally. A service (`api/services/sync.py`) owns apply/pull semantics; thin routes (`GET /sync`, `POST /sync`) own auth, org membership, the deletion guard, and the idempotency ledger. Migration 0015 closes the 1b TOCTOU with a functional unique index on the SQL mirror of `normalize_name`.

**Tech Stack:** FastAPI + psycopg3 (async), Postgres 17 (Supabase), pytest (+ dockerized PG in tests), plpgsql triggers.

## Global Constraints

Copied from the spec and Phase 1b conventions; every task inherits these.

- **Migration numbering:** local `0011` stays burned (live project carries a different 0011 — see `supabase/migrations/0012_business_tables.sql:4-8`). This phase creates exactly `0014_sync_protocol.sql` and `0015_ingredient_name_norm.sql`. Nothing else touches `supabase/migrations/`.
- **Spec source of truth:** `docs/superpowers/specs/2026-07-25-native-ios-app-design.md` §4.2, §5, §6.2 (line 295), §7 (line 314), §16. Do not relitigate its rejected alternatives (no `sync_changes` table, no HLC, no JSONB items, no `items_version`/409).
- **Money contract (1b, unchanged):** NUMERIC end-to-end; API emits money/qty as **strings** (`::text` casts), never floats. Sync field values are sent as strings (or null) and bound as text params — psycopg3 binds `str` with unknown OID so Postgres coerces to the column type (existing tests already bind `"9.9999"` to numeric).
- **Ordering rule (written, 1b):** `ORDER BY purchased_on DESC, recorded_at DESC, id DESC` — sync must never disturb the columns that feed it.
- **Tenancy:** every request-path query through `tenant_connection` (`api/db.py:17`); RLS is the boundary; routes 404 (not 403) for cross-org locations/orgs — unknown and cross-org indistinguishable.
- **`SET LOCAL` only; the request path role is `authenticated` via `app_user` checkout. No `service_role` anywhere.**
- **New SQLSTATEs:** `CS423` = tombstone monotonicity violation, `CS425` = `client_mutated_at` >5 min in the future. Existing `CS410` = scheduled-org write freeze (maps to HTTP 410 in `api/main.py:115`).
- **Constants:** `SYNC_PAGE_CAP = 500` (pull page cap), `MAX_BATCH_OPS = 200` (push batch cap → HTTP 413), `SYNC_OPS_TTL` = 7 days (§5.3).
- **Statuses (locked):** per-op result `status` ∈ `"applied" | "stale" | "needs_attention"`; replays return the stored result plus `"replayed": true`. `stale` is terminal-deterministic and ledgered; `needs_attention` is NOT ledgered (client may retry after fixing the cause).
- **Conflict rules (locked):** apply sent fields iff `op.client_mutated_at >= row.client_mutated_at` (ties: arrival order wins). Tombstones are terminal — any op against a tombstoned row is `stale` with `reason: "deleted"` regardless of clocks (spec §17 defers auto-undelete deliberately).
- **Org derivation (locked):** `org_id` is explicit in the sync envelope (a user may hold several memberships); membership is verified; **every op's `location_id` must belong to that org or the row fails** (`needs_attention`). `org_id`/`location_id` never appear in `fields`.
- **Local test gate:** `pytest -q` green from repo root after every task (runs JS vectors too). One commit per task, Conventional Commits with phase scope: `feat(1c): …` / `test(1c): …` / `docs(1c): …`.
- **Live deploy is a human action** — nothing in this phase applies migrations to the live Supabase project; Task 13's runbook covers it.
- Test auth convention: `from tests.test_auth import mint`; `auth(user_id)` returns `{"Authorization": f"Bearer {mint(sub=str(user_id))}"}` (see `tests/test_ingredients_routes.py:4-8`). Fixtures: `seeded_biz` (keys `alice`, `bob`, `acme`, `bistro`, `acme_loc`, `bistro_loc`), `app_client`, `raw_conn` (owner; bypasses RLS — never use it to exercise a policy), factories in `tests/factories.py`.

---

## File Structure

```
supabase/migrations/0014_sync_protocol.sql      # Task 1 (columns/backfill/triggers) + Task 2 (sync_ops, appended)
supabase/migrations/0015_ingredient_name_norm.sql  # Task 11
api/models.py                                   # Task 4 appends SyncOpIn, SyncPushIn
api/services/sync.py                            # Task 4 (apply core) + Task 5 (item canonicalization) + Task 7 (pull)
api/routes/sync.py                              # Task 6 (POST) + Task 7 (GET)
api/routes/ingredients.py                       # Task 3 (stamping), Task 11 (UniqueViolation → 409)
api/routes/recipes.py                           # Task 3 (stamping)
api/routes/purchases.py                         # Task 3 (adds DELETE — spec §13, B1 recovery)
api/jobs/purge.py                               # Task 10 (sync_ops TTL half)
api/main.py                                     # Task 6 registers the sync router
tests/test_sync_schema.py                       # Task 1 (+ Task 3 extends)
tests/test_sync_ops_rls.py                      # Task 2 (+ edits to conftest TENANT_TABLES & test_rls_cross_org.py)
tests/test_sync_service.py                      # Task 4 + Task 5
tests/test_sync_push.py                         # Task 6
tests/test_sync_pull.py                         # Task 7
tests/test_sync_scenarios.py                    # Task 8 + Task 9
tests/test_purge_job.py                         # Task 10 extends
tests/test_ingredient_name_norm.py              # Task 11
tests/test_rls_policies.py                      # Task 12 widens the upto=4 audits
docs/runbooks/phase-1c-deploy.md                # Task 13
```

---

### Task 1: Migration 0014 — sync columns, backfill, stamp triggers

**Files:**
- Create: `supabase/migrations/0014_sync_protocol.sql`
- Test: `tests/test_sync_schema.py`

**Interfaces:**
- Consumes: `organizations.sync_counter` (0002, currently unused), `locations`, the four 0012 business tables, the `deletion_definer` GRANT/REVOKE bracket pattern (0012:210-250), 0013's temporary-`TO CURRENT_USER`-policy pattern for FORCE-RLS backfills.
- Produces: columns `client_mutated_at timestamptz NOT NULL DEFAULT now()`, `server_seq bigint NOT NULL`, `updated_at timestamptz NOT NULL DEFAULT now()` on `ingredients`, `purchases`, `recipes`, `recipe_items`; role `sync_definer` (NOLOGIN); trigger fn `sync_row_stamp()`; triggers `<table>_sync_stamp`; SQLSTATEs `CS423`/`CS425`; policies `location_sync_definer_read`, `org_sync_definer_read`, `org_sync_definer_update`. Later tasks rely on: *every* INSERT/UPDATE on the four tables allocates a fresh `server_seq` and stamps `updated_at`, on any path, and never touches `client_mutated_at`.

- [ ] **Step 1: Write the failing tests** — `tests/test_sync_schema.py`:

```python
# tests/test_sync_schema.py
"""Migration 0014: the three-timestamp split and the stamp trigger.

Catalog + behavior checks run through raw_conn (owner). RLS is NOT under test
here — the trigger is SECURITY DEFINER and fires identically on every path;
tenancy for the sync endpoints lands in test_sync_ops_rls.py and
test_rls_cross_org.py.
"""
import pytest
from psycopg.errors import RaiseException
from tests.conftest import apply_migrations
from tests.factories import make_user, make_org, add_member, make_location, make_ingredient

SYNCABLE = ("ingredients", "purchases", "recipes", "recipe_items")


@pytest.fixture
async def synced(raw_conn):
    await apply_migrations(raw_conn)  # all, incl. 0014
    alice = await make_user(raw_conn, "alice@acme.test")
    acme = await make_org(raw_conn, "Acme Diner")
    await add_member(raw_conn, alice, acme, "owner")
    loc = await make_location(raw_conn, acme, "Acme Main")
    await raw_conn.commit()
    return dict(alice=alice, acme=acme, loc=loc)


async def _counter(conn, org):
    cur = await conn.execute(
        "SELECT sync_counter FROM organizations WHERE id = %s", (org,))
    (n,) = await cur.fetchone()
    return n


async def test_sync_columns_exist_not_null(raw_conn):
    await apply_migrations(raw_conn)
    for table in SYNCABLE:
        cur = await raw_conn.execute(
            "SELECT column_name, is_nullable FROM information_schema.columns"
            " WHERE table_schema = 'public' AND table_name = %s"
            "   AND column_name IN ('client_mutated_at','server_seq','updated_at')",
            (table,))
        cols = {r[0]: r[1] for r in await cur.fetchall()}
        assert set(cols) == {"client_mutated_at", "server_seq", "updated_at"}, table
        assert all(v == "NO" for v in cols.values()), (table, cols)


async def test_backfill_is_dense_per_org_and_counter_matches(raw_conn):
    """0013's sample-org seed rows get seqs 1..N with sync_counter == N."""
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute("""
        SELECT s.org_id, array_agg(s.server_seq ORDER BY s.server_seq)
        FROM (
          SELECT l.org_id, t.server_seq FROM ingredients t JOIN locations l ON l.id = t.location_id
          UNION ALL SELECT l.org_id, t.server_seq FROM purchases t JOIN locations l ON l.id = t.location_id
          UNION ALL SELECT l.org_id, t.server_seq FROM recipes t JOIN locations l ON l.id = t.location_id
          UNION ALL SELECT l.org_id, t.server_seq FROM recipe_items t JOIN locations l ON l.id = t.location_id
        ) s GROUP BY s.org_id""")
    rows = await cur.fetchall()
    assert rows, "the 0013 sample org should have produced syncable rows"
    for org_id, seqs in rows:
        assert seqs == list(range(1, len(seqs) + 1)), (org_id, seqs)
        assert await _counter(raw_conn, org_id) == len(seqs)


async def test_insert_and_update_allocate_fresh_seqs(synced, raw_conn):
    s = synced
    ing = await make_ingredient(raw_conn, s["loc"], "Flour")
    cur = await raw_conn.execute(
        "SELECT server_seq, updated_at, client_mutated_at FROM ingredients WHERE id = %s", (ing,))
    seq1, upd1, cm1 = await cur.fetchone()
    assert seq1 == await _counter(raw_conn, s["acme"]) == 1
    await raw_conn.execute(
        "UPDATE ingredients SET name = 'Bread Flour' WHERE id = %s", (ing,))
    cur = await raw_conn.execute(
        "SELECT server_seq, updated_at, client_mutated_at FROM ingredients WHERE id = %s", (ing,))
    seq2, upd2, cm2 = await cur.fetchone()
    assert seq2 == 2 and seq2 > seq1, "an update must move the row past any cursor"
    assert upd2 >= upd1
    assert cm2 == cm1, "the trigger must NEVER touch client_mutated_at (device clock only)"
    await raw_conn.commit()


async def test_tombstone_is_monotonic(synced, raw_conn):
    s = synced
    ing = await make_ingredient(raw_conn, s["loc"], "Salt")
    await raw_conn.execute(
        "UPDATE ingredients SET deleted_at = now() WHERE id = %s", (ing,))
    await raw_conn.commit()
    with pytest.raises(RaiseException) as exc:
        await raw_conn.execute(
            "UPDATE ingredients SET deleted_at = NULL WHERE id = %s", (ing,))
    assert exc.value.sqlstate == "CS423"
    await raw_conn.rollback()
    with pytest.raises(RaiseException) as exc:
        await raw_conn.execute(
            "UPDATE ingredients SET deleted_at = now() + interval '1 hour'"
            " WHERE id = %s", (ing,))
    assert exc.value.sqlstate == "CS423"
    await raw_conn.rollback()


async def test_future_client_clock_rejected(synced, raw_conn):
    s = synced
    with pytest.raises(RaiseException) as exc:
        await raw_conn.execute(
            "INSERT INTO ingredients (location_id, name, base_unit, client_mutated_at)"
            " VALUES (%s, 'Pepper', 'oz', now() + interval '10 minutes')", (s["loc"],))
    assert exc.value.sqlstate == "CS425"
    await raw_conn.rollback()
    await raw_conn.execute(
        "INSERT INTO ingredients (location_id, name, base_unit, client_mutated_at)"
        " VALUES (%s, 'Pepper', 'oz', now() + interval '1 minute')", (s["loc"],))
    await raw_conn.commit()


async def test_scheduled_org_write_never_bumps_counter(synced, raw_conn):
    """*_reject_scheduled must fire BEFORE *_sync_stamp (alphabetical:
    'r' < 's'), so a frozen org's counter cannot creep."""
    s = synced
    await make_ingredient(raw_conn, s["loc"], "Sugar")
    await raw_conn.commit()
    before = await _counter(raw_conn, s["acme"])
    await raw_conn.execute(
        "UPDATE organizations SET deletion_scheduled_at = now() WHERE id = %s",
        (s["acme"],))
    with pytest.raises(Exception) as exc:
        await make_ingredient(raw_conn, s["loc"], "Cinnamon")
    assert getattr(exc.value, "sqlstate", None) == "CS410"
    await raw_conn.rollback()
    assert await _counter(raw_conn, s["acme"]) == before


async def test_trigger_names_order_reject_before_stamp(raw_conn):
    await apply_migrations(raw_conn)
    for table in SYNCABLE:
        cur = await raw_conn.execute(
            "SELECT tgname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid"
            " WHERE c.relname = %s AND NOT t.tgisinternal ORDER BY tgname", (table,))
        names = [r[0] for r in await cur.fetchall()]
        assert f"{table}_reject_scheduled" in names and f"{table}_sync_stamp" in names
        assert names.index(f"{table}_reject_scheduled") < names.index(f"{table}_sync_stamp")


async def test_sync_definer_is_inert(raw_conn):
    """Same hygiene bar rls_definer is held to in test_rls_policies.py."""
    await apply_migrations(raw_conn)
    cur = await raw_conn.execute(
        "SELECT rolcanlogin, rolbypassrls, rolsuper FROM pg_roles"
        " WHERE rolname = 'sync_definer'")
    row = await cur.fetchone()
    assert row == (False, False, False)
    cur = await raw_conn.execute(
        "SELECT count(*) FROM pg_auth_members m JOIN pg_roles r ON r.oid = m.roleid"
        " WHERE r.rolname = 'sync_definer'")
    (members,) = await cur.fetchone()
    assert members == 0, "the GRANT ... TO CURRENT_USER bracket must be closed"
```

- [ ] **Step 2: Run to verify failure**

Run: `pytest tests/test_sync_schema.py -q`
Expected: FAIL — the sync columns do not exist.

- [ ] **Step 3: Write the migration** — `supabase/migrations/0014_sync_protocol.sql`:

```sql
-- 0014_sync_protocol.sql — Phase 1c: the three-timestamp split (spec §4.2),
-- per-org server_seq allocation (§5.1), monotonic tombstones, future-clock
-- rejection. Local numbering: 0011 stays burned (see 0012's header).
--
-- Why a trigger and not route code: "any invariant enforced only in a route
-- handler is unenforced on the sync path" (spec line 416) — and vice versa.
-- The stamp fires on EVERY insert/update — routes, sync, merge, or a future
-- job — so no path can forget the cursor.

-- ---------------------------------------------------------------------------
-- 1. Columns, nullable first; NOT NULL only after backfill.
-- ---------------------------------------------------------------------------
ALTER TABLE ingredients
  ADD COLUMN client_mutated_at timestamptz,
  ADD COLUMN server_seq bigint,
  ADD COLUMN updated_at timestamptz;
ALTER TABLE purchases
  ADD COLUMN client_mutated_at timestamptz,
  ADD COLUMN server_seq bigint,
  ADD COLUMN updated_at timestamptz;
ALTER TABLE recipes
  ADD COLUMN client_mutated_at timestamptz,
  ADD COLUMN server_seq bigint,
  ADD COLUMN updated_at timestamptz;
ALTER TABLE recipe_items
  ADD COLUMN client_mutated_at timestamptz,
  ADD COLUMN server_seq bigint,
  ADD COLUMN updated_at timestamptz;

-- ---------------------------------------------------------------------------
-- 2. Backfill. Same FORCE-RLS workaround as 0013: the live migration runner
-- is not a superuser and holds no policy on these tables, so temporary
-- CURRENT_USER policies bracket the writes. Seqs are dense per org over
-- (created_at, id) across all four tables; counters land on the max.
-- ---------------------------------------------------------------------------
CREATE POLICY tmp_backfill_ingredients ON ingredients
  FOR ALL TO CURRENT_USER USING (true) WITH CHECK (true);
CREATE POLICY tmp_backfill_purchases ON purchases
  FOR ALL TO CURRENT_USER USING (true) WITH CHECK (true);
CREATE POLICY tmp_backfill_recipes ON recipes
  FOR ALL TO CURRENT_USER USING (true) WITH CHECK (true);
CREATE POLICY tmp_backfill_recipe_items ON recipe_items
  FOR ALL TO CURRENT_USER USING (true) WITH CHECK (true);
CREATE POLICY tmp_backfill_organizations ON organizations
  FOR ALL TO CURRENT_USER USING (true) WITH CHECK (true);
CREATE POLICY tmp_backfill_locations ON locations
  FOR SELECT TO CURRENT_USER USING (true);

DROP TABLE IF EXISTS _seq_backfill;
CREATE TEMP TABLE _seq_backfill AS
SELECT id, tbl, org_id,
       row_number() OVER (PARTITION BY org_id ORDER BY created_at, id) AS seq
FROM (
  SELECT i.id, 'ingredients'::text AS tbl, l.org_id, i.created_at
    FROM ingredients i JOIN locations l ON l.id = i.location_id
  UNION ALL
  SELECT r.id, 'recipes', l.org_id, r.created_at
    FROM recipes r JOIN locations l ON l.id = r.location_id
  UNION ALL
  SELECT ri.id, 'recipe_items', l.org_id, ri.created_at
    FROM recipe_items ri JOIN locations l ON l.id = ri.location_id
  UNION ALL
  SELECT p.id, 'purchases', l.org_id, p.created_at
    FROM purchases p JOIN locations l ON l.id = p.location_id
) all_rows;

UPDATE ingredients t
   SET server_seq = b.seq, client_mutated_at = t.created_at, updated_at = t.created_at
  FROM _seq_backfill b WHERE b.tbl = 'ingredients' AND b.id = t.id;
UPDATE purchases t
   SET server_seq = b.seq, client_mutated_at = t.created_at, updated_at = t.created_at
  FROM _seq_backfill b WHERE b.tbl = 'purchases' AND b.id = t.id;
UPDATE recipes t
   SET server_seq = b.seq, client_mutated_at = t.created_at, updated_at = t.created_at
  FROM _seq_backfill b WHERE b.tbl = 'recipes' AND b.id = t.id;
UPDATE recipe_items t
   SET server_seq = b.seq, client_mutated_at = t.created_at, updated_at = t.created_at
  FROM _seq_backfill b WHERE b.tbl = 'recipe_items' AND b.id = t.id;

UPDATE organizations o SET sync_counter = coalesce(
  (SELECT max(b.seq) FROM _seq_backfill b WHERE b.org_id = o.id), 0);

DROP TABLE _seq_backfill;
DROP POLICY tmp_backfill_ingredients ON ingredients;
DROP POLICY tmp_backfill_purchases ON purchases;
DROP POLICY tmp_backfill_recipes ON recipes;
DROP POLICY tmp_backfill_recipe_items ON recipe_items;
DROP POLICY tmp_backfill_organizations ON organizations;
DROP POLICY tmp_backfill_locations ON locations;

-- ---------------------------------------------------------------------------
-- 3. NOT NULL + defaults. client_mutated_at DEFAULT now(): a route write IS
-- the device write (the API caller's clock is this server's clock); sync
-- always sends an explicit value. updated_at is display-only (§4.2) and
-- server-stamped by the trigger on every write.
-- ---------------------------------------------------------------------------
ALTER TABLE ingredients
  ALTER COLUMN client_mutated_at SET NOT NULL,
  ALTER COLUMN client_mutated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN server_seq SET NOT NULL;
ALTER TABLE purchases
  ALTER COLUMN client_mutated_at SET NOT NULL,
  ALTER COLUMN client_mutated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN server_seq SET NOT NULL;
ALTER TABLE recipes
  ALTER COLUMN client_mutated_at SET NOT NULL,
  ALTER COLUMN client_mutated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN server_seq SET NOT NULL;
ALTER TABLE recipe_items
  ALTER COLUMN client_mutated_at SET NOT NULL,
  ALTER COLUMN client_mutated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN server_seq SET NOT NULL;

CREATE INDEX ingredients_server_seq_idx ON ingredients (server_seq);
CREATE INDEX purchases_server_seq_idx ON purchases (server_seq);
CREATE INDEX recipes_server_seq_idx ON recipes (server_seq);
CREATE INDEX recipe_items_server_seq_idx ON recipe_items (server_seq);

-- ---------------------------------------------------------------------------
-- 4. sync_definer + the stamp trigger. Same GRANT/REVOKE bracket as 0012
-- (membership live while CREATE TRIGGER checks EXECUTE; REVOKE comes LAST).
-- The single-statement UPDATE ... RETURNING takes the org row lock, which
-- serializes allocation with commit order by construction (§5.1) — the
-- FOR UPDATE the spec sketches is subsumed by the row lock the UPDATE takes.
-- ---------------------------------------------------------------------------
CREATE ROLE sync_definer NOLOGIN NOINHERIT NOBYPASSRLS;
GRANT sync_definer TO CURRENT_USER;

GRANT SELECT ON locations TO sync_definer;
CREATE POLICY location_sync_definer_read ON locations
  FOR SELECT TO sync_definer USING (true);
GRANT SELECT, UPDATE ON organizations TO sync_definer;
CREATE POLICY org_sync_definer_read ON organizations
  FOR SELECT TO sync_definer USING (true);
CREATE POLICY org_sync_definer_update ON organizations
  FOR UPDATE TO sync_definer USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION sync_row_stamp()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _seq bigint;
BEGIN
  -- §4.2: the server rejects device clocks more than 5 minutes ahead.
  IF NEW.client_mutated_at > now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'client_mutated_at % is more than 5 minutes in the future',
      NEW.client_mutated_at USING ERRCODE = 'CS425';
  END IF;
  -- §4.2: tombstones are monotonic — NULL -> timestamp only, never back,
  -- never re-stamped. (Editing other fields of a tombstoned row is refused
  -- at the service layer, not here: the merge endpoint legitimately updates
  -- rows adjacent to tombstoning.)
  IF TG_OP = 'UPDATE' AND OLD.deleted_at IS NOT NULL
     AND NEW.deleted_at IS DISTINCT FROM OLD.deleted_at THEN
    RAISE EXCEPTION 'tombstones are monotonic; row % cannot be undeleted or re-stamped',
      OLD.id USING ERRCODE = 'CS423';
  END IF;
  UPDATE public.organizations o SET sync_counter = o.sync_counter + 1
   WHERE o.id = (SELECT l.org_id FROM public.locations l WHERE l.id = NEW.location_id)
   RETURNING o.sync_counter INTO _seq;
  IF _seq IS NULL THEN
    RAISE EXCEPTION 'no organization found for location %', NEW.location_id;
  END IF;
  NEW.server_seq := _seq;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
ALTER FUNCTION sync_row_stamp() OWNER TO sync_definer;
REVOKE ALL ON FUNCTION sync_row_stamp() FROM PUBLIC;

-- Named *_sync_stamp so they sort AFTER *_reject_scheduled ('r' < 's'):
-- a scheduled org's write dies on CS410 before the counter is ever bumped.
CREATE TRIGGER ingredients_sync_stamp
  BEFORE INSERT OR UPDATE ON ingredients
  FOR EACH ROW EXECUTE FUNCTION sync_row_stamp();
CREATE TRIGGER purchases_sync_stamp
  BEFORE INSERT OR UPDATE ON purchases
  FOR EACH ROW EXECUTE FUNCTION sync_row_stamp();
CREATE TRIGGER recipes_sync_stamp
  BEFORE INSERT OR UPDATE ON recipes
  FOR EACH ROW EXECUTE FUNCTION sync_row_stamp();
CREATE TRIGGER recipe_items_sync_stamp
  BEFORE INSERT OR UPDATE ON recipe_items
  FOR EACH ROW EXECUTE FUNCTION sync_row_stamp();

REVOKE sync_definer FROM CURRENT_USER;
```

- [ ] **Step 4: Run the new tests**

Run: `pytest tests/test_sync_schema.py -q`
Expected: PASS.

- [ ] **Step 5: Run the full suite**

Run: `pytest -q`
Expected: PASS. If the *unpinned* audits (`test_every_table_in_public_enables_and_forces_rls`, the seeded-fixture policy checks) fail, fix the MIGRATION, not the test. The only audit tests this phase may edit are the four `upto=4`-pinned ones, and that happens in Task 12.

- [ ] **Step 6: Commit**

```bash
git add supabase/migrations/0014_sync_protocol.sql tests/test_sync_schema.py
git commit -m "feat(1c): migration 0014 — sync columns, per-org seq allocation, stamp triggers"
```

### Task 2: sync_ops idempotency ledger + RLS wiring

**Files:**
- Modify: `supabase/migrations/0014_sync_protocol.sql` (append a section 5)
- Modify: `tests/conftest.py:27-31` (`TENANT_TABLES`), `tests/test_rls_cross_org.py` (`two_orgs` + `spec` fixtures, `NO_DELETE_GRANT_TABLES`)
- Test: `tests/test_sync_ops_rls.py`

**Interfaces:**
- Consumes: `current_user_memberships()` (0004 definer fn used by every 0012 policy), `sync_definer` (Task 1), 0008's accessor pattern.
- Produces: table `sync_ops (op_id uuid PK, org_id uuid NOT NULL REFERENCES organizations ON DELETE CASCADE, batch_id uuid NOT NULL, applied_at timestamptz NOT NULL DEFAULT now(), result_json jsonb NOT NULL)`; SQL fn `purge_expired_sync_ops(retention interval DEFAULT '7 days') RETURNS integer` (SECURITY DEFINER, EXECUTE granted to the migration-runner identity = purge-job identity). `authenticated` gets SELECT+INSERT only, org-membership policies `sync_ops_select` / `sync_ops_insert`; `sync_ops_definer_all` policy FOR ALL TO sync_definer.

- [ ] **Step 1: Write failing tests** — `tests/test_sync_ops_rls.py`: (a) catalog: sync_ops exists, RLS enabled+forced, `authenticated` has exactly {SELECT, INSERT} (query `information_schema.role_table_grants`); (b) behavior via `pool_open(app_url(db_url))` + `tenant_connection` with two orgs (reuse the `synced`-style fixture shape from Task 1 plus a second org): alice INSERTs a row for her org (ok), SELECT sees only her org's rows, INSERT for bob's org raises "row-level security", UPDATE raises "permission denied" (no grant), DELETE raises "permission denied"; (c) `purge_expired_sync_ops('7 days')` as raw_conn deletes a row backdated `applied_at = now() - interval '8 days'` and keeps a fresh one, returning the deleted count.
- [ ] **Step 2: Run to verify failure** — `pytest tests/test_sync_ops_rls.py -q` → FAIL (relation sync_ops does not exist).
- [ ] **Step 3: Append to 0014**:

```sql
-- ---------------------------------------------------------------------------
-- 5. sync_ops: the idempotency ledger (§5.3). One row per applied op, written
-- in the SAME transaction as the mutation it records; replay returns the
-- stored result and touches nothing. 7-day TTL via purge_expired_sync_ops(),
-- called by the daily purge job (api/jobs/purge.py).
-- ---------------------------------------------------------------------------
CREATE TABLE sync_ops (
  op_id       uuid PRIMARY KEY,
  org_id      uuid NOT NULL REFERENCES organizations(id) ON DELETE CASCADE,
  batch_id    uuid NOT NULL,
  applied_at  timestamptz NOT NULL DEFAULT now(),
  result_json jsonb NOT NULL
);
CREATE INDEX sync_ops_ttl_idx ON sync_ops (applied_at);
CREATE INDEX sync_ops_org_idx ON sync_ops (org_id);

ALTER TABLE sync_ops ENABLE ROW LEVEL SECURITY;
ALTER TABLE sync_ops FORCE ROW LEVEL SECURITY;

-- 0003's ALTER DEFAULT PRIVILEGES grants authenticated full DML on any new
-- table; narrow it. Replay needs SELECT, recording needs INSERT; nothing on
-- the request path rewrites or deletes a ledger row.
REVOKE ALL ON sync_ops FROM authenticated;
GRANT SELECT, INSERT ON sync_ops TO authenticated;

CREATE POLICY sync_ops_select ON sync_ops FOR SELECT TO authenticated USING (
  org_id IN (SELECT org_id FROM current_user_memberships())
);
CREATE POLICY sync_ops_insert ON sync_ops FOR INSERT TO authenticated WITH CHECK (
  org_id IN (SELECT org_id FROM current_user_memberships())
);

GRANT sync_definer TO CURRENT_USER;
GRANT SELECT, DELETE ON sync_ops TO sync_definer;
CREATE POLICY sync_ops_definer_all ON sync_ops
  FOR ALL TO sync_definer USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION purge_expired_sync_ops(retention interval DEFAULT '7 days')
RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE _n integer;
BEGIN
  DELETE FROM public.sync_ops WHERE applied_at < now() - retention;
  GET DIAGNOSTICS _n = ROW_COUNT;
  RETURN _n;
END;
$$;
ALTER FUNCTION purge_expired_sync_ops(interval) OWNER TO sync_definer;
REVOKE ALL ON FUNCTION purge_expired_sync_ops(interval) FROM PUBLIC;
-- CURRENT_USER here = the migration runner = the purge job's identity
-- (PURGE_DATABASE_URL; see api/jobs/purge.py's __main__ note).
GRANT EXECUTE ON FUNCTION purge_expired_sync_ops(interval) TO CURRENT_USER;
REVOKE sync_definer FROM CURRENT_USER;
```

- [ ] **Step 4: Wire the RLS matrix.** Append `"sync_ops"` to `TENANT_TABLES` in `tests/conftest.py`. In `tests/test_rls_cross_org.py`: in `two_orgs`, seed one sync_op per org (`INSERT INTO sync_ops (op_id, org_id, batch_id, result_json) VALUES (uuid_generate_v7(), %s, uuid_generate_v7(), '{}') RETURNING op_id`) storing `acme_sync_op`/`bistro_sync_op`; add a `spec` entry `"sync_ops": dict(key="op_id", mine=..., theirs=..., col="batch_id", val=<fresh uuid string>, insert=("INSERT INTO sync_ops (op_id, org_id, batch_id, result_json) VALUES (uuid_generate_v7(), %s, uuid_generate_v7(), '{}')", (t["bistro"],)))`. The update test expects `rowcount == 0` but authenticated has **no UPDATE grant** → mirror the existing `NO_DELETE_GRANT_TABLES` mechanism: add `NO_UPDATE_GRANT_TABLES = {"sync_ops"}` handled the same way (expect "permission denied"), and add `"sync_ops"` to `NO_DELETE_GRANT_TABLES`.
- [ ] **Step 5: Run** `pytest tests/test_sync_ops_rls.py tests/test_rls_cross_org.py -q` → PASS, then `pytest -q` → PASS.
- [ ] **Step 6: Commit** — `git add supabase/migrations/0014_sync_protocol.sql tests/test_sync_ops_rls.py tests/conftest.py tests/test_rls_cross_org.py && git commit -m "feat(1c): sync_ops idempotency ledger with org-scoped RLS and TTL reaper"`

---

### Task 3: Routes stamp client_mutated_at; DELETE /purchases

**Files:**
- Modify: `api/routes/ingredients.py` (tombstone + all five merge UPDATEs), `api/routes/recipes.py` (PUT recipe UPDATE, item qty UPDATE, removed-lines tombstone, DELETE both UPDATEs), `api/routes/purchases.py` (new DELETE route)
- Test: extend `tests/test_sync_schema.py`; extend `tests/test_purchases_routes.py`

**Interfaces:**
- Consumes: Task 1's columns; `_require_location` (`api/routes/ingredients.py:12`).
- Produces: every route UPDATE also sets `client_mutated_at = now()` (INSERTs are covered by the column DEFAULT); `DELETE /locations/{location_id}/purchases/{purchase_id}` → 204 tombstone / 404 (spec §13: B1's recovery gap — bad data must be fixable in-product; sync exposes purchase tombstones, web needs parity).

- [ ] **Step 1: Failing tests.** In `tests/test_sync_schema.py` add `test_route_updates_advance_client_mutated_at(app_client, seeded_biz, raw_conn)`: create a recipe via POST as alice, read `client_mutated_at` via raw_conn, sleep-free (`now()` moves per statement), PUT a rename, assert `client_mutated_at` increased. In `tests/test_purchases_routes.py` add `test_delete_purchase_tombstones`: factory purchase → DELETE as alice → 204 → row has `deleted_at` set and `client_mutated_at` advanced; second DELETE → 404; cross-org (bob) → 404.
- [ ] **Step 2:** `pytest tests/test_sync_schema.py tests/test_purchases_routes.py -q` → FAIL (route UPDATEs leave `client_mutated_at` at insert value; DELETE route 405/404).
- [ ] **Step 3: Implement.** Mechanical edits — every UPDATE in these routes gains `client_mutated_at = now()` in its SET list. Exact statements to touch: `ingredients.py:120-123` (tombstone), `ingredients.py:170-201` (merge: purchases repoint, keeper-line sum, loser-line tombstone, loser-line repoint, loser ingredient tombstone), `recipes.py:85-89` (recipe update), `recipes.py:103-105` (item qty), `recipes.py:110-113` (removed lines), `recipes.py:123-131` (recipe delete + its items). New route in `api/routes/purchases.py`:

```python
@router.delete("/locations/{location_id}/purchases/{purchase_id}", status_code=204)
async def tombstone_purchase(location_id: uuid.UUID, purchase_id: uuid.UUID,
                             request: Request,
                             caller: CallerIdentity = Depends(require_caller)):
    """Spec §13: DELETE /purchases/{id} exists so bad data is fixable
    in-product (B1's recovery gap). Tombstone, never a row DELETE."""
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        await _require_location(conn, location_id)
        cur = await conn.execute(
            "UPDATE purchases SET deleted_at = now(), client_mutated_at = now()"
            " WHERE id = %s AND location_id = %s AND deleted_at IS NULL",
            (purchase_id, location_id))
        if cur.rowcount != 1:
            raise HTTPException(404, "purchase not found")
```

(match `purchases.py`'s existing imports; it already imports `_require_location` from `api.routes.ingredients`).
- [ ] **Step 4:** `pytest -q` → PASS. **Step 5: Commit** — `git add api/routes/ingredients.py api/routes/recipes.py api/routes/purchases.py tests/test_sync_schema.py tests/test_purchases_routes.py && git commit -m "feat(1c): route updates stamp client_mutated_at; DELETE /purchases tombstone"`

---

### Task 4: Sync models + apply service core

**Files:**
- Modify: `api/models.py` (append)
- Create: `api/services/sync.py`
- Test: `tests/test_sync_service.py`

**Interfaces:**
- Consumes: Task 1 columns/SQLSTATEs; `tenant_connection`.
- Produces (frozen for Tasks 5-9):

```python
# api/models.py (append; add imports: from datetime import datetime; from typing import Literal)
class SyncOpIn(BaseModel):
    op_id: uuid.UUID
    table: Literal["ingredients", "recipes", "recipe_items", "purchases"]
    row_id: uuid.UUID
    location_id: uuid.UUID
    client_mutated_at: datetime
    fields: dict[str, str | None] = {}

class SyncPushIn(BaseModel):
    org_id: uuid.UUID
    batch_id: uuid.UUID
    ops: list[SyncOpIn]
```

```python
# api/services/sync.py — constants and signatures
SYNC_PAGE_CAP = 500
MAX_BATCH_OPS = 200
TABLE_ORDER = ("ingredients", "recipes", "recipe_items", "purchases")  # §5.5 FK order
INSERT_FIELDS = {
    "ingredients": {"name", "base_unit", "vendor", "category", "source", "deleted_at"},
    "recipes": {"name", "menu_price", "target_fc_pct", "deleted_at"},
    "recipe_items": {"recipe_id", "ingredient_id", "qty_base_units", "deleted_at"},
    "purchases": {"ingredient_id", "purchased_on", "recorded_at", "qty", "unit",
                  "qty_in_case", "qty_base_units", "total_price", "source", "deleted_at"},
}
UPDATE_FIELDS = {  # identity fields immutable: repointing is merge's job, never sync's
    "ingredients": {"name", "base_unit", "vendor", "category", "deleted_at"},
    "recipes": {"name", "menu_price", "target_fc_pct", "deleted_at"},
    "recipe_items": {"qty_base_units", "deleted_at"},
    "purchases": {"purchased_on", "recorded_at", "qty", "unit", "qty_in_case",
                  "qty_base_units", "total_price", "deleted_at"},
}
async def apply_op(conn, org_id, op) -> dict   # returns {"status": ..., [...]}
```

Result dicts: `{"status": "applied", "row_id": "<canonical uuid str>"}` | `{"status": "stale", "reason": "older" | "deleted"}` | `{"status": "needs_attention", "reason": "<short human string>"}`.

- [ ] **Step 1: Failing tests** — `tests/test_sync_service.py`. Fixture: `pool` from `pool_open(app_url(db_url))` + a `two_orgs`-lite seed (alice/acme/loc via factories; commit); helper `mkop(**kw) -> SyncOpIn`. Under `tenant_connection(pool, {"sub": str(alice)})`, assert:
  - insert ingredient (fields name/base_unit, cm=now) → `applied`, row exists with `id == row_id`, `client_mutated_at == cm`;
  - update with only `{"name": ...}` and newer cm → `applied`, other fields untouched, cm advanced;
  - update with older cm → `{"status": "stale", "reason": "older"}`, row untouched;
  - equal cm → applied (`>=` rule);
  - op against tombstoned row → `stale/deleted`;
  - tombstone op (`fields={"deleted_at": "<iso now>"}`) → applied, row tombstoned;
  - unknown field name → `needs_attention`; identity field on update (`recipe_items.ingredient_id`) → `needs_attention`;
  - location of another org in envelope → `needs_attention` (op-level check, spec line 314-315);
  - future cm (+10 min) → `needs_attention` (CS425 surfaced per-row, not batch);
  - purchases insert referencing a tombstoned ingredient → `needs_attention`; recipe_items insert referencing tombstoned ingredient or recipe → `needs_attention` (spec line 416 — the 1b route-only invariant, enforced on the sync path);
  - after a failed op, the same connection still applies the next op (savepoint isolation).
- [ ] **Step 2:** run → FAIL (module missing).
- [ ] **Step 3: Implement `api/services/sync.py`.** Shape:

```python
import psycopg
from psycopg.errors import (CheckViolation, ForeignKeyViolation,
    InsufficientPrivilege, NotNullViolation, NumericValueOutOfRange,
    RaiseException, UniqueViolation)

_REASONS = [
    (UniqueViolation, "duplicate"),
    (ForeignKeyViolation, "missing parent row"),
    (InsufficientPrivilege, "forbidden for this role"),
    ((CheckViolation, NotNullViolation, NumericValueOutOfRange), "invalid value"),
]
def _reason(exc):
    state = getattr(exc, "sqlstate", None)
    if state == "CS425": return "client_mutated_at too far in the future"
    if state == "CS423": return "tombstone is monotonic"
    for types, label in _REASONS:
        if isinstance(exc, types): return label
    return "rejected by database"

async def apply_op(conn, org_id, op):
    await conn.execute("SAVEPOINT sync_op")
    try:
        result = await _apply(conn, org_id, op)
    except psycopg.Error as exc:
        if getattr(exc, "sqlstate", None) == "CS410":
            raise  # deletion freeze is batch-level, never a per-row result
        await conn.execute("ROLLBACK TO SAVEPOINT sync_op")
        result = {"status": "needs_attention", "reason": _reason(exc)}
    else:
        await conn.execute("RELEASE SAVEPOINT sync_op")
    return result
```

`_apply(conn, org_id, op)`: (1) `SELECT 1 FROM locations WHERE id = %s AND org_id = %s` else `needs_attention` `"location is not in this organization"`; (2) `SELECT client_mutated_at, deleted_at, location_id FROM {table} WHERE id = %s` (table name from the validated Literal — safe to interpolate); (3) row exists → reject envelope-location mismatch (`"row belongs to a different location"`), tombstoned → `stale/deleted`, `op.client_mutated_at < row_cm` → `stale/older`, unknown/immutable fields (`set(fields) - UPDATE_FIELDS[table]`) → `needs_attention`, else `UPDATE {table} SET f1 = %s, ..., client_mutated_at = %s WHERE id = %s` → `applied`; (4) no row → unknown fields vs `INSERT_FIELDS` → `needs_attention`; parent-liveness checks (purchases → live ingredient at this location; recipe_items → live recipe AND live ingredient at this location) → `needs_attention` `"referenced <thing> is not live"`; else `INSERT INTO {table} (id, location_id, client_mutated_at, f1, ...) VALUES (...)` → `applied`. All field values bind as text params (global money contract). Insert of recipe_items uses the plain INSERT in this task; Task 5 replaces it with the canonical upsert.
- [ ] **Step 4:** `pytest tests/test_sync_service.py -q` → PASS; full `pytest -q` → PASS.
- [ ] **Step 5: Commit** — `git add api/models.py api/services/sync.py tests/test_sync_service.py && git commit -m "feat(1c): sync apply core — per-field LWW, terminal tombstones, savepoint isolation"`

### Task 5: recipe_items canonical upsert on sync insert

**Files:**
- Modify: `api/services/sync.py` (the recipe_items insert branch)
- Test: extend `tests/test_sync_service.py`

**Interfaces:**
- Consumes: `recipe_items_live_uq` — the partial unique index `(recipe_id, ingredient_id) WHERE deleted_at IS NULL` (0012:84-85, whose comment pre-declares this exact upsert).
- Produces: a sync insert of a recipe line that collides with a live line for the same `(recipe_id, ingredient_id)` becomes an LWW update of the **existing** row; the result's `row_id` is the canonical (existing) id so the client re-maps its local row. This is the §5.4 fix: one offline edit plus one online edit converges to five lines, never ten.

- [ ] **Step 1: Failing tests.** Extend `tests/test_sync_service.py`: (a) seed recipe + line (factories); push an *insert* op with a fresh `row_id`, same `(recipe_id, ingredient_id)`, newer cm, `qty_base_units` "3.0000" → `applied`, `result["row_id"] == str(existing_line_id)` (≠ op.row_id), live-line count for the recipe stays 1, qty updated; (b) same but **older** cm → `{"status": "stale", "reason": "older"}`, `row_id` still canonical, qty untouched; (c) an insert for a brand-new pair still creates a row with `id == op.row_id`.
- [ ] **Step 2:** run → FAIL (plain INSERT raises UniqueViolation → `needs_attention "duplicate"`).
- [ ] **Step 3: Implement.** In the recipe_items insert branch replace the plain INSERT with:

```python
cur = await conn.execute(
    "INSERT INTO recipe_items (id, location_id, recipe_id, ingredient_id,"
    " qty_base_units, deleted_at, client_mutated_at)"
    " VALUES (%s, %s, %s, %s, %s, %s, %s)"
    " ON CONFLICT (recipe_id, ingredient_id) WHERE deleted_at IS NULL"
    " DO UPDATE SET qty_base_units = EXCLUDED.qty_base_units,"
    "               deleted_at = EXCLUDED.deleted_at,"
    "               client_mutated_at = EXCLUDED.client_mutated_at"
    " WHERE recipe_items.client_mutated_at <= EXCLUDED.client_mutated_at"
    " RETURNING id",
    (op.row_id, op.location_id, fields.get("recipe_id"),
     fields.get("ingredient_id"), fields.get("qty_base_units"),
     fields.get("deleted_at"), op.client_mutated_at))
row = await cur.fetchone()
if row is None:
    # conflict arbitration ran and the existing line's clock was newer
    cur = await conn.execute(
        "SELECT id FROM recipe_items WHERE recipe_id = %s AND ingredient_id = %s"
        " AND deleted_at IS NULL",
        (fields.get("recipe_id"), fields.get("ingredient_id")))
    (canonical,) = await cur.fetchone()
    return {"status": "stale", "reason": "older", "row_id": str(canonical)}
return {"status": "applied", "row_id": str(row[0])}
```

- [ ] **Step 4:** `pytest tests/test_sync_service.py -q` then `pytest -q` → PASS.
- [ ] **Step 5: Commit** — `git add api/services/sync.py tests/test_sync_service.py && git commit -m "feat(1c): recipe line sync inserts canonicalize onto the live (recipe, ingredient) row"`

---

### Task 6: POST /sync — atomic FK-ordered batch apply

**Files:**
- Create: `api/routes/sync.py`
- Modify: `api/main.py` (import + `app.include_router(sync.router)` after `dashboard`)
- Test: `tests/test_sync_push.py`

**Interfaces:**
- Consumes: `SyncPushIn`, `apply_op`, `TABLE_ORDER`, `MAX_BATCH_OPS`, `sync_ops` (Task 2), `require_caller`, `tenant_connection`.
- Produces: `POST /sync` → `{"results": [per-op dicts in INPUT order, each with "op_id"], "cursor": <org sync_counter>}`. 404 unknown/non-member org; 410 scheduled org (batch discarded — spec line 295; note `deletion_guard` middleware does NOT match `/sync`, its docstring says this route must check explicitly); 413 oversized batch. Whole batch is ONE transaction; per-row failures are results, never aborts. Concurrent batches for one org serialize on `pg_advisory_xact_lock`.

- [ ] **Step 1: Failing tests** — `tests/test_sync_push.py` (app_client + seeded_biz + raw_conn; `auth`/`mint` convention; `op(...)`/`push(...)` json helpers). Cover: insert applied + row visible; results preserve input order and carry op_id; cursor equals org counter; non-member org → 404; unknown org → 404; oversized batch (`MAX_BATCH_OPS + 1` trivial ops) → 413; same op_id twice in one batch → second result has `"replayed": True` and equals the first; replay in a later batch → same; `needs_attention` op is NOT ledgered (push a purchases op for a not-yet-existing ingredient with the ingredient op ordered AFTER it in the list — FK order means ingredients apply first anyway, so instead use a genuinely missing parent, get `needs_attention`, then create the parent via a second push and re-push the SAME op_id → `applied`); bookkeeper (add via `add_member(raw_conn, carol, acme, "bookkeeper")`) pushing a recipes op → that row `needs_attention` "forbidden for this role" while an ingredients op in the same batch applies; ops listed child-before-parent in the payload (recipe_items before its recipe) all apply thanks to `TABLE_ORDER` sorting; scheduled org → 410 and nothing applied (schedule via raw_conn UPDATE, assert ingredient absent + sync_ops empty); detail text equals `api.main.ORG_SCHEDULED_MESSAGE`.
- [ ] **Step 2:** run → FAIL (404 route).
- [ ] **Step 3: Implement `api/routes/sync.py`:**

```python
# api/routes/sync.py
import uuid
from fastapi import APIRouter, Depends, HTTPException, Request
from psycopg.types.json import Jsonb
from api.auth import CallerIdentity, require_caller
from api.db import tenant_connection
from api.models import SyncPushIn
from api.services import sync as svc

router = APIRouter()

# Same literal as api.main.ORG_SCHEDULED_MESSAGE — importing api.main here
# would be circular (main imports this module). Pinned equal by a test.
ORG_SCHEDULED_MESSAGE = "This organization is scheduled for deletion."


async def _require_member_org(conn, org_id):
    """404 for unknown AND non-member alike (RLS hides the row): the same
    deliberate indistinguishability as _require_location."""
    cur = await conn.execute(
        "SELECT deletion_scheduled_at FROM organizations WHERE id = %s", (org_id,))
    row = await cur.fetchone()
    if row is None:
        raise HTTPException(404, "organization not found")
    return row[0]


@router.post("/sync")
async def push(body: SyncPushIn, request: Request,
               caller: CallerIdentity = Depends(require_caller)):
    if len(body.ops) > svc.MAX_BATCH_OPS:
        raise HTTPException(413, f"batch exceeds {svc.MAX_BATCH_OPS} ops")
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        scheduled = await _require_member_org(conn, body.org_id)
        if scheduled is not None:
            # §6.2 line 295: check BEFORE applying anything; the device
            # discards its queue on 410. The deletion_guard middleware only
            # covers /orgs/* paths — this check is the one it promised.
            raise HTTPException(410, ORG_SCHEDULED_MESSAGE)
        # Serialize whole batches per org. Without this, two devices racing
        # the same op_id could both miss the ledger read and double-apply:
        # the ledger insert's ON CONFLICT can only dedupe rows, not effects.
        await conn.execute(
            "SELECT pg_advisory_xact_lock(hashtextextended(%s::text, 0))",
            (body.org_id,))
        rank = {t: n for n, t in enumerate(svc.TABLE_ORDER)}
        indexed = sorted(enumerate(body.ops),
                         key=lambda p: (rank[p[1].table], p[0]))
        results: dict[int, dict] = {}
        for idx, op in indexed:
            cur = await conn.execute(
                "SELECT result_json FROM sync_ops WHERE op_id = %s", (op.op_id,))
            row = await cur.fetchone()
            if row is not None:
                results[idx] = {**row[0], "replayed": True}
                continue
            result = {"op_id": str(op.op_id),
                      **await svc.apply_op(conn, body.org_id, op)}
            if result["status"] != "needs_attention":
                # same transaction as the mutation (§5.3). needs_attention is
                # deliberately NOT ledgered: it applied nothing, and the
                # client retries it after fixing the cause.
                await conn.execute(
                    "INSERT INTO sync_ops (op_id, org_id, batch_id, result_json)"
                    " VALUES (%s, %s, %s, %s)",
                    (op.op_id, body.org_id, body.batch_id, Jsonb(result)))
            results[idx] = result
        cur = await conn.execute(
            "SELECT sync_counter FROM organizations WHERE id = %s", (body.org_id,))
        (cursor,) = await cur.fetchone()
    return {"results": [results[i] for i in range(len(body.ops))],
            "cursor": cursor}
```

Register in `api/main.py`: add `sync` to the `api.routes` import list and `app.include_router(sync.router)` after `dashboard`. Import collision note: the module is `api.routes.sync`; `main.py` imports it as `sync` alongside the others.
- [ ] **Step 4:** `pytest tests/test_sync_push.py -q` then `pytest -q` → PASS.
- [ ] **Step 5: Commit** — `git add api/routes/sync.py api/main.py tests/test_sync_push.py && git commit -m "feat(1c): POST /sync — atomic FK-ordered batch apply with op_id idempotency"`

---

### Task 7: GET /sync — cursor pull with page cap

**Files:**
- Modify: `api/services/sync.py` (add `pull`), `api/routes/sync.py` (add GET)
- Test: `tests/test_sync_pull.py`

**Interfaces:**
- Consumes: Task 1 columns, Task 6's `_require_member_org`.
- Produces: `async def pull(conn, org_id, since: int, limit: int | None = None) -> dict` returning `{"changes": [{"table": t, "row": {…}}…], "cursor": int, "has_more": bool}`, global `ORDER BY server_seq` across all four tables, tombstones included, `limit or SYNC_PAGE_CAP` rows max (monkeypatchable). `GET /sync?org_id=…&since=0` → that dict. Reads stay allowed for a deletion-scheduled org (grace window is export-friendly; only writes are frozen). Row payloads: every numeric/date/timestamp as `::text` strings (money contract — `to_jsonb` would surface floats via `json.loads`); `server_seq` as a JSON int.

- [ ] **Step 1: Failing tests** — `tests/test_sync_pull.py`: route-created rows appear in pull with correct table tags and string-typed money (`isinstance(row["total_price"], str)`); global seq ordering across tables; `since=cursor` → empty + `has_more is False`; tombstoned ingredient appears with non-null `deleted_at`; page-cap walk (monkeypatch `svc.SYNC_PAGE_CAP` to 3 via `pull`'s `limit` default resolution, create ~5 rows, two pages, no gaps/dupes, cursors chain); non-member org → 404; scheduled org still pulls (schedule via raw_conn, GET → 200); bistro rows never appear in an acme pull.
- [ ] **Step 2:** run → FAIL.
- [ ] **Step 3: Implement.** In `api/services/sync.py` add per-table jsonb fragments and `pull`:

```python
_PULL = {
    "ingredients": (
        "SELECT 'ingredients' AS tbl, t.server_seq AS seq, jsonb_build_object("
        "'id', t.id::text, 'location_id', t.location_id::text, 'name', t.name,"
        " 'base_unit', t.base_unit, 'vendor', t.vendor, 'category', t.category,"
        " 'source', t.source, 'client_mutated_at', t.client_mutated_at::text,"
        " 'server_seq', t.server_seq, 'updated_at', t.updated_at::text,"
        " 'deleted_at', t.deleted_at::text, 'created_at', t.created_at::text) AS row"
        " FROM ingredients t JOIN locations l ON l.id = t.location_id"
        " WHERE l.org_id = %(org)s AND t.server_seq > %(since)s"),
    "recipes": (
        "SELECT 'recipes', t.server_seq, jsonb_build_object("
        "'id', t.id::text, 'location_id', t.location_id::text, 'name', t.name,"
        " 'menu_price', t.menu_price::text, 'target_fc_pct', t.target_fc_pct::text,"
        " 'client_mutated_at', t.client_mutated_at::text, 'server_seq', t.server_seq,"
        " 'updated_at', t.updated_at::text, 'deleted_at', t.deleted_at::text,"
        " 'created_at', t.created_at::text)"
        " FROM recipes t JOIN locations l ON l.id = t.location_id"
        " WHERE l.org_id = %(org)s AND t.server_seq > %(since)s"),
    "recipe_items": (
        "SELECT 'recipe_items', t.server_seq, jsonb_build_object("
        "'id', t.id::text, 'location_id', t.location_id::text,"
        " 'recipe_id', t.recipe_id::text, 'ingredient_id', t.ingredient_id::text,"
        " 'qty_base_units', t.qty_base_units::text,"
        " 'client_mutated_at', t.client_mutated_at::text, 'server_seq', t.server_seq,"
        " 'updated_at', t.updated_at::text, 'deleted_at', t.deleted_at::text,"
        " 'created_at', t.created_at::text)"
        " FROM recipe_items t JOIN locations l ON l.id = t.location_id"
        " WHERE l.org_id = %(org)s AND t.server_seq > %(since)s"),
    "purchases": (
        "SELECT 'purchases', t.server_seq, jsonb_build_object("
        "'id', t.id::text, 'location_id', t.location_id::text,"
        " 'ingredient_id', t.ingredient_id::text, 'purchased_on', t.purchased_on::text,"
        " 'recorded_at', t.recorded_at::text, 'qty', t.qty::text, 'unit', t.unit,"
        " 'qty_in_case', t.qty_in_case::text, 'qty_base_units', t.qty_base_units::text,"
        " 'total_price', t.total_price::text, 'unit_price', t.unit_price::text,"
        " 'source', t.source, 'client_mutated_at', t.client_mutated_at::text,"
        " 'server_seq', t.server_seq, 'updated_at', t.updated_at::text,"
        " 'deleted_at', t.deleted_at::text, 'created_at', t.created_at::text)"
        " FROM purchases t JOIN locations l ON l.id = t.location_id"
        " WHERE l.org_id = %(org)s AND t.server_seq > %(since)s"),
}
_PULL_SQL = " UNION ALL ".join(_PULL[t] for t in TABLE_ORDER) + \
    " ORDER BY 2 LIMIT %(lim)s"

async def pull(conn, org_id, since, limit=None):
    cap = limit if limit is not None else SYNC_PAGE_CAP
    cur = await conn.execute(
        _PULL_SQL, {"org": org_id, "since": since, "lim": cap + 1})
    rows = await cur.fetchall()
    page = rows[:cap]
    changes = [{"table": tbl, "row": payload} for tbl, _seq, payload in page]
    return {"changes": changes,
            "cursor": page[-1][1] if page else since,
            "has_more": len(rows) > cap}
```

Route (`api/routes/sync.py`):

```python
@router.get("/sync")
async def pull_changes(org_id: uuid.UUID, request: Request, since: int = 0,
                       caller: CallerIdentity = Depends(require_caller)):
    async with tenant_connection(request.app.state.pool, caller.claims) as conn:
        # Reads stay available during the deletion grace window — the export
        # path depends on them; only writes are frozen (§6.2).
        await _require_member_org(conn, org_id)
        return await svc.pull(conn, org_id, since)
```

- [ ] **Step 4:** `pytest tests/test_sync_pull.py -q` then `pytest -q` → PASS.
- [ ] **Step 5: Commit** — `git add api/services/sync.py api/routes/sync.py tests/test_sync_pull.py && git commit -m "feat(1c): GET /sync — page-capped cursor pull, tombstones included"`

---

### Task 8: Scenario suite I — item count, stale loser, replay

**Files:**
- Create: `tests/test_sync_scenarios.py`

**Interfaces:** Consumes everything above through the HTTP surface only (`app_client`, `seeded_biz`, `auth`, plus raw_conn for seeding/assertion). Produces the §14 sync-scenario coverage.

- [ ] **Step 1: Write the three scenarios (they should PASS against Tasks 1-7; any failure is a bug in those tasks — debug there, do not weaken the assertions):**
  - `test_two_edits_converge_on_item_count` (§5.4's burger): seed 2 ingredients + purchases + a 2-line recipe via routes as alice; **device B** edits one line's qty via `PUT /locations/…/recipes/{id}`; **device A** (offline re-save) pushes *insert* ops with fresh UUIDs for the same `(recipe, ingredient)` pairs with newer cm. Assert: live line count is exactly 2 (never 4), each result's `row_id` equals the pre-existing canonical line id, and `GET /locations/…/recipes/{id}` plate-cost fields equal the 2-line cost (compute expected from the pushed qtys — string equality on the payload's cost fields).
  - `test_stale_thirty_day_edit_loses`: alice sets `menu_price` "15.00" via PUT today; a push arrives with `client_mutated_at` 30 days ago setting `menu_price` "11.00" → result `stale/older`; GET shows "15.00". The *newer* edit wins even though it synced first — the §4.2 anti-case.
  - `test_replay_after_concurrent_edit`: push op X renames recipe → "Alpha" (applied); PUT renames → "Beta"; re-push the byte-identical op X → result has `replayed: True` with the ORIGINAL applied result; name stays "Beta" (replay touches nothing).
- [ ] **Step 2:** `pytest tests/test_sync_scenarios.py -q` → PASS (fix earlier tasks if not). **Step 3:** `pytest -q` → PASS. **Step 4: Commit** — `git add tests/test_sync_scenarios.py && git commit -m "test(1c): sync scenarios — item-count convergence, stale loser, replay"`

---

### Task 9: Scenario suite II — reverse commit order + deletion guard

**Files:**
- Modify: `tests/test_sync_scenarios.py` (append)

**Interfaces:** Consumes `pool_open`/`tenant_connection` directly (concurrency), deletion routes in `api/routes/deletion.py` (grep that file for the exact schedule/cancel paths — they are `/orgs/{org_id}/…`-shaped; use the routes, not raw SQL, for the cancel case).

- [ ] **Step 1: Append two tests:**
  - `test_seq_allocation_serializes_with_commit_order` (§17's "write the reverse-commit-order test now regardless"): two tasks over `pool_open(app_url(db_url))` as alice. Task 1 enters `tenant_connection`, INSERTs an ingredient `RETURNING server_seq`, then awaits an `asyncio.Event` before exiting (commit happens on context exit). Task 2 does the same INSERT — assert via `asyncio.wait([task2], timeout=0.3)` that it is still blocked (the org counter row lock). Release task 1, await both. Assert `seq1 < seq2`, and a pull with `since=seq1` returns exactly the second row: **no committed gap can ever exist below the cursor**.
  - `test_offline_push_after_deletion_is_discarded_and_cancel_restores` (§14's non-negotiable, sync flavor): schedule org deletion as alice through the deletion route; push a queued batch → 410, ingredient absent, `sync_ops` empty; cancel through the deletion route; re-push the SAME batch (same op_ids) → applied. A device offline through the deletion cannot resurrect data (spec line 295-296), but a cancelled deletion loses nothing.
- [ ] **Step 2:** `pytest tests/test_sync_scenarios.py -q` → PASS; `pytest -q` → PASS. **Step 3: Commit** — `git add tests/test_sync_scenarios.py && git commit -m "test(1c): reverse-commit-order and deletion-guard sync scenarios"`

### Task 10: sync_ops TTL half of the purge job

**Files:**
- Modify: `api/jobs/purge.py`
- Test: extend `tests/test_purge_job.py`

**Interfaces:**
- Consumes: `purge_expired_sync_ops(interval)` (Task 2; EXECUTE belongs to the migration-runner identity, which is what `PURGE_DATABASE_URL` connects as), `run_all`'s independent-halves pattern.
- Produces: `SYNC_OPS_TTL = "7 days"` module constant (§5.3 — single source of truth, like `GRACE`); `async def purge_expired_sync_ops(db_url: str) -> int`; `run_all` gains a third independent half labeled `"sync_ops"` and returns a 3-tuple `(orgs, identities, sync_ops)` — update `__main__`'s unpacking and print accordingly.

- [ ] **Step 1: Failing tests.** In `tests/test_purge_job.py` mirror the existing halves' style: seed an org + a `sync_ops` row backdated 8 days and one fresh (raw_conn), run `purge_expired_sync_ops(db_url)` with the same db_url fixture the existing purge tests use → returns 1, fresh row survives; `run_all` still succeeds when this half succeeds and raises with `"sync_ops"` in the message when the DB is unreachable for it (follow the existing failure-injection pattern in that file — monkeypatch the SQL call or pass a bad URL clone, matching how the org/identity halves are failure-tested).
- [ ] **Step 2:** run → FAIL. **Step 3: Implement** (new section between Half 2 and `run_all`):

```python
# ---------------------------------------------------------------------------
# Half 3: sync_ops TTL (§5.3 — the ledger holds 7 days of applied op results)
# ---------------------------------------------------------------------------
SYNC_OPS_TTL = "7 days"

async def purge_expired_sync_ops(db_url: str) -> int:
    """Delete ledger rows older than the TTL via migration 0014's SECURITY
    DEFINER reaper. Same identity note as the other halves: sync_ops is
    FORCE RLS with member-scoped policies, so a direct DELETE from this
    connection would remove zero rows on real Supabase; the definer function
    is the only sanctioned path."""
    conn = await psycopg.AsyncConnection.connect(db_url, autocommit=False)
    try:
        cur = await conn.execute(
            "SELECT purge_expired_sync_ops(%s::interval)", (SYNC_OPS_TTL,))
        (n,) = await cur.fetchone()
        await conn.commit()
        return n
    except BaseException:
        await conn.rollback()
        raise
    finally:
        await conn.close()
```

In `run_all`, add a third try/except block after identities (`failed.append("sync_ops")`, count via `getattr(exc, "purged", 0)` → 0), return the 3-tuple, extend the raised RuntimeError attrs, and update `__main__` to unpack three values and print `sync_ops_purged=` too.
- [ ] **Step 4:** `pytest tests/test_purge_job.py -q` then `pytest -q` → PASS. **Step 5: Commit** — `git add api/jobs/purge.py tests/test_purge_job.py && git commit -m "feat(1c): purge job reaps expired sync_ops (7-day TTL)"`

---

### Task 11: Migration 0015 — normalized ingredient-name unique index

**Files:**
- Create: `supabase/migrations/0015_ingredient_name_norm.sql`
- Modify: `api/routes/ingredients.py` (catch UniqueViolation in `create_ingredient`)
- Test: `tests/test_ingredient_name_norm.py`

**Interfaces:**
- Consumes: `normalize_name` (`api/kernel.py` — lower → strip → drop `[^a-z0-9\s]` → collapse whitespace → strip → de-pluralize trailing `s` unless `ss` or len ≤ 3).
- Produces: IMMUTABLE SQL fn `normalize_ingredient_name(text) RETURNS text` mirroring the kernel byte-for-byte; partial unique index `ingredients_norm_name_live_uq ON ingredients (location_id, normalize_ingredient_name(name)) WHERE deleted_at IS NULL AND normalize_ingredient_name(name) <> ''`. This closes the 1b TOCTOU: two concurrent `create_ingredient` calls can both pass the app-side scan; the index makes the second one lose at commit. Sync-path duplicates already surface as `needs_attention "duplicate"` via Task 4's `_reason`.

- [ ] **Step 1: Failing tests** — `tests/test_ingredient_name_norm.py`:
  - **Equivalence property:** for a battery of names — every ingredient name in `shared/golden-vectors.json`, plus edge cases `"Chicken Breasts"`, `"  GRASS-fed   Beef  "`, `"Swiss"`, `"Eggs"`, `"óil"`, `"s"`, `"ss"`, `"bass"`, `"XS"`, `"a1-2 sauce!!"`, `""` — assert `SELECT normalize_ingredient_name(%s)` == `api.kernel.normalize_name(name)` (raw_conn, full migrations).
  - **TOCTOU closed at the DB:** two raw_conn INSERTs of `"Chicken Breast"` / `"chicken breasts"` at one location → second raises UniqueViolation; same normalized name at a *different* location is fine; re-using a tombstoned name is fine (partial index).
  - **Route still friendly:** POST duplicate via `app_client` → 409 with the existing `{"detail": "duplicate", "matches": [...]}` shape (the pre-scan), and a direct racing insert (seed the dup via raw_conn between scan and insert is impractical in-process — instead assert the new except-branch by POSTing a name whose normalized form collides while differing raw, e.g. seed `"Chicken  Breast"` via factory [which skips the route scan], then POST `"chicken breasts"` → 409, not 500).
- [ ] **Step 2:** run → FAIL. **Step 3: Migration:**

```sql
-- 0015_ingredient_name_norm.sql — Phase 1c: close 1b's create-ingredient
-- TOCTOU. SQL mirror of api/kernel.py normalize_name; the kernel is the
-- source of truth — change both together or the equivalence test fails.
CREATE OR REPLACE FUNCTION normalize_ingredient_name(name text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT CASE
           WHEN s LIKE '%s' AND s NOT LIKE '%ss' AND length(s) > 3
           THEN left(s, -1)
           ELSE s
         END
  FROM (
    SELECT btrim(regexp_replace(regexp_replace(lower(name), '[^a-z0-9\s]', '', 'g'),
                                '\s+', ' ', 'g')) AS s
  ) x
$$;

-- Live rows only (tombstoned names are reusable); empty normalizations are
-- excluded — the route 400s them, and two all-punctuation names colliding
-- on '' would be nonsense.
CREATE UNIQUE INDEX ingredients_norm_name_live_uq
  ON ingredients (location_id, normalize_ingredient_name(name))
  WHERE deleted_at IS NULL AND normalize_ingredient_name(name) <> '';
```

Route: wrap the INSERT in `create_ingredient` (`api/routes/ingredients.py:84-89`) in `try/except UniqueViolation` (import from `psycopg.errors`) → `raise HTTPException(409, detail={"detail": "duplicate", "matches": []})` — the scan above it still answers the common case with named matches; the except-branch is the race loser.
**Live-deploy precondition (runbook, Task 13):** the index build fails if live data already holds duplicates — the runbook must include the pre-check `SELECT location_id, normalize_ingredient_name(name), count(*) FROM ingredients WHERE deleted_at IS NULL GROUP BY 1,2 HAVING count(*) > 1;` (run AFTER 0015's function exists — or inline the expression) and a merge-first instruction.
- [ ] **Step 4:** `pytest tests/test_ingredient_name_norm.py -q` then `pytest -q` → PASS. **Step 5: Commit** — `git add supabase/migrations/0015_ingredient_name_norm.sql api/routes/ingredients.py tests/test_ingredient_name_norm.py && git commit -m "feat(1c): migration 0015 — normalized ingredient-name unique index closes create TOCTOU"`

---

### Task 12: Widen the upto=4 RLS audits

**Files:**
- Modify: `tests/test_rls_policies.py` (the four audits pinned at `apply_migrations(raw_conn, upto=4)`: lines ~108, ~341, ~371, ~411)

**Interfaces:** Consumes the full policy/role set after 0015. Produces audits that run against **all migrations** (drop the `upto=4` pins), the 1b deferred follow-up.

- [ ] **Step 1: Re-pin expectations, then remove the pins one test at a time (red → green each):**
  - `test_every_policy_carries_with_check_where_it_can_write`: drop the pin; assertion is shape-based and must pass unchanged — if it fails, a MIGRATION is missing WITH CHECK; fix the migration.
  - `test_rls_definer_cannot_be_logged_into_or_escalated` → parametrize over `("rls_definer", "deletion_definer", "purge_definer", "sync_definer")`: NOLOGIN, NOBYPASSRLS, NOSUPER for each; `app_user`/`authenticated` are members of none. Keep the rls_definer-specific assertions (policy `membership_definer_read` is SELECT/`qual='true'`; owns no tables) scoped to rls_definer.
  - `test_nothing_is_left_a_member_of_rls_definer` → assert `pg_auth_members` is empty for ALL four definer roles (every GRANT…TO CURRENT_USER bracket closed).
  - `test_application_policies_never_apply_to_the_definer_role` → allowed non-`["authenticated"]` policies become exactly: `membership_definer_read`, `location_deletion_definer_read`, `location_sync_definer_read`, `org_sync_definer_read`, `org_sync_definer_update`, `sync_ops_definer_all` — each must target a single `*_definer` role and (for the SELECT/UPDATE reads) carry `qual = 'true'`. Anything else with non-authenticated roles fails the audit. Assert no `tmp_backfill_*` policy survives (0013/0014 brackets closed).
- [ ] **Step 2:** `pytest tests/test_rls_policies.py -q` → PASS; `pytest -q` → PASS. **Step 3: Commit** — `git add tests/test_rls_policies.py && git commit -m "test(1c): RLS audits run the full migration set and cover all definer roles"`

---

### Task 13: Deploy runbook + docs

**Files:**
- Create: `docs/runbooks/phase-1c-deploy.md`
- Modify: `docs/runbooks/phase-1b-deploy.md` (one-line pointer at the top: 1c supersedes — deploy 0012-0015 together if 1b was never applied)

**Interfaces:** Consumes `docs/runbooks/phase-1b-deploy.md`'s structure (numbered steps, `apply_migration` one call per file, verify queries, advisors check, rollback notes). Live project: `khohfrfqzbieaiikqlsa`; migrations 0012-0013 are NOT yet applied there — 1c deploys 0012→0015 in order.

- [ ] **Step 1: Write the runbook** with these sections (concrete SQL/queries in each, modeled on the 1b runbook):
  1. **Preconditions** — 1b runbook completed through 0013, or apply 0012→0015 in sequence now; `pytest -q` green locally at the deploy commit.
  2. **Duplicate-name pre-check** (before 0015; Task 11's query inlined with the regexp expression so it runs before the function exists) — if rows return, merge in-product first.
  3. **Apply 0014, then 0015** via `apply_migration` (one call per file, exact filenames).
  4. **Verify** — sync columns NOT NULL; per-org `max(server_seq) == sync_counter` (Task 1's dense-backfill query); triggers present + ordering (`pg_trigger` names query); `sync_ops` FORCE RLS; `SELECT normalize_ingredient_name('Chicken Breasts') = 'chicken breast'`.
  5. **Advisors** — run `get_advisors` (security + performance), triage anything new against 0014/0015.
  6. **Cron** — the daily purge invocation now also reaps sync_ops (no new cron entry; `run_all` covers it); note the 3-tuple output change.
  7. **Smoke** — with a real token: `GET /sync?org_id=…&since=0` pages through seed data; `POST /sync` with a single trivial op applies and replays.
  8. **Rollback** — 0014/0015 are additive; rollback is a revert deploy of the API plus leaving columns in place (document explicitly: do NOT drop columns on live; tombstone-style forward fixes only).
- [ ] **Step 2:** `pytest -q` → PASS (unchanged). **Step 3: Commit** — `git add docs/runbooks/phase-1c-deploy.md docs/runbooks/phase-1b-deploy.md && git commit -m "docs(1c): deploy runbook for migrations 0014-0015"`

---

## Locked decisions (do not relitigate mid-task)

- Sync envelope carries explicit `org_id`; ops carry `location_id`; `fields` never contain either.
- LWW comparison is `>=` (ties → arrival order). Tombstones terminal (`stale/deleted`). No auto-undelete.
- `needs_attention` results are NOT written to `sync_ops`; `applied`/`stale` are.
- Batch serialization via `pg_advisory_xact_lock(hashtextextended(org_id::text, 0))` — not FOR UPDATE on organizations (authenticated may lack the UPDATE grant), not a schema change.
- `server_seq` allocation lives in the trigger (`sync_row_stamp`), never in route/service code; the trigger never touches `client_mutated_at`.
- GET /sync stays available for deletion-scheduled orgs; POST /sync 410s.
- Field values travel as strings; responses emit money as strings.
- `DELETE /purchases` ships in Task 3 (spec §13/B1); CSV import stays web-only; nothing in this phase touches the SPA (that is 1d).
- Deferred (unchanged from spec §17): HLC/409 conflict UI, `sync_changes` trigger infrastructure, tombstone GC, per-device heartbeats. Also deferred from this phase's review: DB-level in-use/liveness triggers for sync parent checks (service-level checks suffice until a second write path exists).

## Self-Review (performed while writing)

1. **Spec coverage:** §4.2 columns/trigger → Task 1; §5.1 cursor → Tasks 1/6/7; §5.2 per-field LWW → Task 4; §5.3 idempotency → Tasks 2/6; §5.4 item diff → Task 5 (+ 1b's PUT already upsert-diffs); §5.5 apply semantics → Tasks 6/7 (FK order, one txn, page cap; per-row 403 → `needs_attention`; client-side `sync_state`/`suggested_price` suppression is a Phase 2a client concern — out of scope here); §6.2 line 295 → Tasks 6/9; §7 line 314 → Task 4 location checks + envelope design; §14 scenarios → Tasks 8/9; 1b deferred follow-ups → Tasks 11/12; §16 "full scenario test suite" → Tasks 8/9 + per-task tests.
2. **Placeholder scan:** Task 2/8/9/10/12/13 steps reference existing file patterns by exact name/line rather than embedding full listings — each names the exact assertions and mechanisms; no TBDs remain.
3. **Type consistency:** `apply_op(conn, org_id, op: SyncOpIn) -> dict` and `pull(conn, org_id, since, limit=None)` used identically in Tasks 4-9; statuses/reasons match the Global Constraints table everywhere; `purge_expired_sync_ops` names both the SQL fn (Task 2) and the Python wrapper (Task 10) — intentional mirror, different arities.
4. **Known risk flags for implementers:** (a) `CREATE POLICY … TO CURRENT_USER` and partial-index `ON CONFLICT` arbitration are both version-sensitive — both patterns already exist in this codebase (0013; 0012's comment), trust the tests; (b) trigger-vs-RLS ordering on `organizations` for `sync_definer` is covered by the two definer policies; if `test_scheduled_org_write_never_bumps_counter` fails on ordering, check trigger names first; (c) if psycopg surfaces `RaiseException` subclasses differently for custom SQLSTATEs, match on `exc.sqlstate` (the tests already do).

