# Phase 1c Deploy Runbook: sync protocol and the ingredient-name TOCTOU close

Audience: whoever runs the Supabase apply for `0014_sync_protocol.sql` and
`0015_ingredient_name_norm.sql`, plus (if Phase 1b was never deployed) the
two files ahead of them. Assumes the reader has already applied `0001`-`0010`
(`docs/runbooks/phase-1a-deploy.md`) and has no memory of how Phase 1c was
built. Every claim below is sourced from the migration files themselves, as
they actually shipped, and from the test suite that pins their behavior —
not from the Task 13/14 plan text, which is a design intent document, not a
record of what is in the repository.

**Target project:** `khohfrfqzbieaiikqlsa`. Same project as Phases 1a/1b. As
of writing this runbook, `list_migrations` against that project shows
`0001`-`0010` applied (as `0010_revoke_rpc_exposure_on_definer_functions` +
`0011_revoke_rpc_exposure_as_grantor` — see `phase-1b-deploy.md` §1 for why
that split exists) and **nothing from Phase 1b or 1c** — `0012`-`0015` are
all still pending live. Confirm the current state with `list_migrations`
before assuming otherwise; it may have changed since this was written.

---

## 1. Preconditions

1. `pytest -q` is green at the deploy commit, locally, before touching
   Supabase. As of this runbook: 1410 passing, 0 failing.
2. Determine which of the two starting points applies, via `list_migrations`
   against `khohfrfqzbieaiikqlsa`:

   - **Case A — `docs/runbooks/phase-1b-deploy.md` already run on this
     project** (its migration list includes `0012_business_tables` and
     `0013_sample_business_seed`): skip to §3 below and apply `0014` then
     `0015`.
   - **Case B — Phase 1b was never deployed here** (the case as of writing):
     run `phase-1b-deploy.md` in full first — its own preconditions,
     pre-apply checks, mid-file failure hazards, and post-apply verification
     all still apply and are not repeated here — then continue with `0014`
     and `0015` below. Do **not** skip `0012`/`0013`'s own checks just
     because this document exists; `0014`'s backfill (§2 below) reads rows
     that `0013` seeds, and its policies bracket tables `0012` creates.

   Either way, the four files apply **in order**, one `apply_migration` call
   per file, stopping at the first error:

   ```
   0012_business_tables.sql       (Case B only)
   0013_sample_business_seed.sql  (Case B only)
   0014_sync_protocol.sql
   0015_ingredient_name_norm.sql
   ```

---

## 2. Locale/collation check — required before `0015`

`0015`'s own header comment (read it — `supabase/migrations/0015_ingredient_name_norm.sql`
lines 5-13) flags that `normalize_ingredient_name`'s `lower()` call is
**not** locale-independent: it folds case according to the database's
`LC_CTYPE`. This function assumes an en_US/C-family `LC_CTYPE` (Supabase's
default). Under a Turkish-locale (`tr_TR`) `LC_CTYPE`, `lower('I')` folds to
dotless `ı` instead of `i`, diverging from `api.kernel.normalize_name`
(locale-independent Python Unicode casefolding) on any ingredient name
containing an `'I'` — silently letting two names that should collide not
collide, or vice versa.

Run both of these against `khohfrfqzbieaiikqlsa` and confirm an en_US/C-family
result **before applying `0015`** (order relative to `0012`-`0014` doesn't
matter — run it any time before the `0015` `apply_migration` call):

```sql
SHOW lc_ctype;
```

```sql
SELECT datcollate, datctype
FROM pg_database
WHERE datname = current_database();
```

Expected: all three values start with `en_US` (e.g. `en_US.UTF-8`) or are a
plain `C`/`POSIX` locale. If any of the three reports something else (a
different language, or an ICU locale name that isn't `en-US`/`C`), stop —
do not apply `0015` — and escalate; the partial unique index it creates
would enforce a collision rule that disagrees with the application's own
`normalize_name`, and the mismatch would not throw, it would just silently
under- or over-merge duplicate ingredient names on any name containing a
letter with locale-sensitive casing.

---

## 3. Duplicate-name pre-check — required before `0015`

`0015` creates `ingredients_norm_name_live_uq`, a partial unique index on
`(location_id, normalize_ingredient_name(name))` for live (non-tombstoned)
rows. If any location already has two or more live ingredients whose names
normalize to the same string, `CREATE UNIQUE INDEX` in `0015` **fails
outright** — and because `normalize_ingredient_name()` does not exist until
`0015` itself creates it, this check has to inline the same normalization
expression by hand so it can run beforehand. It mirrors `0015`'s function
body statement-for-statement (case fold → strip non-`[a-z0-9\s]` → collapse
whitespace → trim → drop a trailing plural `s`) — keep it in sync with that
file if the function body ever changes.

Run this against `khohfrfqzbieaiikqlsa` after `0013` (or `0012`/`0013` if
this is Case B above) has applied, and before the `0015` `apply_migration`
call:

```sql
SELECT location_id, norm_name, array_agg(id) AS ingredient_ids, array_agg(name) AS names
FROM (
  SELECT id, location_id, name,
         CASE
           WHEN s LIKE '%s' AND s NOT LIKE '%ss' AND length(s) > 3
           THEN left(s, -1)
           ELSE s
         END AS norm_name
  FROM (
    SELECT id, location_id, name,
           btrim(regexp_replace(regexp_replace(lower(name), '[^a-z0-9\s]', '', 'g'),
                                 '\s+', ' ', 'g')) AS s
    FROM ingredients
    WHERE deleted_at IS NULL
  ) x
) y
WHERE norm_name <> ''
GROUP BY location_id, norm_name
HAVING count(*) > 1;
```

Expected: **zero rows.** (The `0013` sample seed does not collide — its five
ingredient names are all distinct even after normalization — so on a
from-scratch Case B run this is expected to return nothing.) If any row
comes back, do **not** proceed to `0015` — the index creation will fail
anyway, but worse, it means the app has already let two ingredients that the
UI/API would call duplicates coexist live. Merge them in-product first (the
existing merge endpoint, `POST /locations/{id}/ingredients/{id}/merge`) for
every group this query returns, then re-run the query until it is empty,
then apply `0015`.

---

## 4. Applying `0014` and `0015`

One `apply_migration` call per file, in order, stopping at the first error:

```
0014_sync_protocol.sql
0015_ingredient_name_norm.sql
```

### What to know before you apply `0014`

- **Both the backfill (§2 of the file) and the trigger-creation bracket
  (§4 of the file) use the same `GRANT <role> TO CURRENT_USER` /
  `... REVOKE ...` shape `0012`/`0013` already use**, for the same reason:
  `sync_definer`-owned objects need `EXECUTE`/table access checked at
  `CREATE TRIGGER`/policy-creation time, and the non-superuser migration
  runner needs a live membership for that one moment. If `0014` fails
  partway, check for leftover membership before retrying:

  ```sql
  SELECT g.rolname AS member
  FROM pg_auth_members m
  JOIN pg_roles r ON r.oid = m.roleid
  JOIN pg_roles g ON g.oid = m.member
  WHERE r.rolname = 'sync_definer';
  ```

  Expected: zero rows once `0014` has either fully applied or not run at
  all. Any row here — `REVOKE sync_definer FROM <member>` before retrying.

- **The backfill is not idempotent against a partial prior run.** It brackets
  four business tables plus `organizations`/`locations` with temporary
  `tmp_backfill_*` policies, computes dense per-org sequence numbers into a
  `TEMP TABLE`, and drops both the temp table and the policies at the end of
  the same file. If `0014` fails after the backfill's `UPDATE`s but before
  its own cleanup, check for leftover `tmp_backfill_*` policies:

  ```sql
  SELECT schemaname, tablename, policyname
  FROM pg_policies
  WHERE policyname LIKE 'tmp_backfill_%';
  ```

  Expected: zero rows on a clean, fully-applied (or fully-unapplied) state.
  Drop any that survive, matching only what this query actually returns,
  before retrying `0014` from the top — a bare retry is otherwise safe
  because the backfill's `UPDATE`s are keyed by row `id` and simply
  overwrite `server_seq`/`client_mutated_at`/`updated_at` again with the
  same computed values.

### What to know before you apply `0015`

- §2 (locale) and §3 (duplicate-name) above must both be clean **first**.
- `0015` is two statements: `CREATE OR REPLACE FUNCTION
  normalize_ingredient_name` and `CREATE UNIQUE INDEX
  ingredients_norm_name_live_uq`. If the file fails, it can only be at the
  index creation (the function replace cannot itself fail short of a syntax
  error, which `apply_migration` would have already rejected) — and per §3
  above, that specific failure mode is a duplicate this runbook's own
  pre-check should already have caught. If it still happens, re-run §3's
  query, resolve what it returns, and retry `0015` — no partial-apply
  cleanup is needed since `CREATE OR REPLACE FUNCTION` is naturally
  idempotent and a failed `CREATE INDEX` leaves nothing behind.

---

## 5. Post-apply verification

Run these against `khohfrfqzbieaiikqlsa` immediately after `0015` applies.

### 5.1 Sync columns exist and are `NOT NULL`

```sql
SELECT table_name, column_name, is_nullable
FROM information_schema.columns
WHERE table_schema = 'public'
  AND table_name IN ('ingredients', 'purchases', 'recipes', 'recipe_items')
  AND column_name IN ('client_mutated_at', 'server_seq', 'updated_at')
ORDER BY table_name, column_name;
```

Expected: 12 rows (4 tables × 3 columns), every `is_nullable` = `NO`.

### 5.2 Backfill is dense per org, and `sync_counter` matches the max

Adapted from `tests/test_sync_schema.py::test_backfill_is_dense_per_org_and_counter_matches`,
written to return only violations (expect zero rows):

```sql
WITH all_seqs AS (
  SELECT l.org_id, t.server_seq FROM ingredients   t JOIN locations l ON l.id = t.location_id
  UNION ALL
  SELECT l.org_id, t.server_seq FROM purchases     t JOIN locations l ON l.id = t.location_id
  UNION ALL
  SELECT l.org_id, t.server_seq FROM recipes       t JOIN locations l ON l.id = t.location_id
  UNION ALL
  SELECT l.org_id, t.server_seq FROM recipe_items  t JOIN locations l ON l.id = t.location_id
), per_org AS (
  SELECT org_id, count(*) AS n, min(server_seq) AS min_seq,
         max(server_seq) AS max_seq, count(DISTINCT server_seq) AS distinct_seqs
  FROM all_seqs
  GROUP BY org_id
)
SELECT p.org_id, p.n, p.min_seq, p.max_seq, p.distinct_seqs, o.sync_counter
FROM per_org p
JOIN organizations o ON o.id = p.org_id
WHERE NOT (
  p.n = p.distinct_seqs           -- no duplicate seqs within an org
  AND p.min_seq = 1               -- starts at 1
  AND p.max_seq = p.n             -- dense, no gaps: seqs are exactly 1..n
  AND p.max_seq = o.sync_counter  -- counter lands exactly on the max
);
```

Expected: **zero rows.** On a Case B (from-scratch) run, this also
implicitly re-confirms the `0013` sample org (`00000000-0000-7000-8000-00000000cafe`)
landed 5 ingredients + 20 purchases + 2 recipes + 4 recipe items = 31 rows,
so its `sync_counter` should read exactly `31`:

```sql
SELECT sync_counter FROM organizations
WHERE id = '00000000-0000-7000-8000-00000000cafe';
-- expect 31
```

### 5.3 Triggers present, in the required order

`*_sync_stamp` must fire strictly after `*_reject_scheduled` per table (a
frozen org's write must die on `CS410` before the counter is ever bumped —
Postgres fires same-timing triggers in name-sort order, and `r` sorts before
`s`):

```sql
SELECT c.relname AS table_name, t.tgname
FROM pg_trigger t
JOIN pg_class c ON c.oid = t.tgrelid
WHERE c.relname IN ('ingredients', 'purchases', 'recipes', 'recipe_items')
  AND NOT t.tgisinternal
ORDER BY c.relname, t.tgname;
```

Expected: exactly two rows per table, `<table>_reject_scheduled` sorting
immediately before `<table>_sync_stamp` (8 rows total).

### 5.4 `sync_definer` is inert outside its bracket

```sql
SELECT rolcanlogin, rolbypassrls, rolsuper
FROM pg_roles
WHERE rolname = 'sync_definer';
-- expect (f, f, f)
```

```sql
SELECT count(*) FROM pg_auth_members m
JOIN pg_roles r ON r.oid = m.roleid
WHERE r.rolname = 'sync_definer';
-- expect 0 -- the GRANT ... TO CURRENT_USER bracket in 0014 must be closed
```

### 5.5 `sync_ops`: FORCE RLS, and exactly the two grants it should have

```sql
SELECT relrowsecurity, relforcerowsecurity
FROM pg_class
WHERE relnamespace = 'public'::regnamespace AND relname = 'sync_ops';
-- expect (t, t)
```

```sql
SELECT privilege_type FROM information_schema.role_table_grants
WHERE table_schema = 'public' AND table_name = 'sync_ops' AND grantee = 'authenticated';
-- expect exactly {SELECT, INSERT} -- no UPDATE, no DELETE
```

```sql
SELECT tgname FROM pg_trigger t JOIN pg_class c ON c.oid = t.tgrelid
WHERE c.relname = 'sync_ops' AND NOT t.tgisinternal;
-- expect exactly {sync_ops_reject_write_to_scheduled_org}
```

### 5.6 `normalize_ingredient_name` matches the kernel

```sql
SELECT normalize_ingredient_name('Chicken Breasts') = 'chicken breast' AS matches;
-- expect t
```

```sql
SELECT indexname, indexdef FROM pg_indexes
WHERE tablename = 'ingredients' AND indexname = 'ingredients_norm_name_live_uq';
-- expect one row; indexdef shows a UNIQUE index on
-- (location_id, normalize_ingredient_name(name)) WHERE deleted_at IS NULL
-- AND normalize_ingredient_name(name) <> ''
```

### 5.7 No leftover temporary policies or role memberships

Final confirmation — same three queries used for failure recovery above,
all expected to return zero rows on a clean, fully-applied run:

```sql
SELECT policyname FROM pg_policies WHERE policyname LIKE 'tmp_backfill_%';
```

```sql
SELECT g.rolname FROM pg_auth_members m
JOIN pg_roles r ON r.oid = m.roleid JOIN pg_roles g ON g.oid = m.member
WHERE r.rolname IN ('sync_definer', 'deletion_definer');
```

```sql
SELECT policyname FROM pg_policies WHERE policyname LIKE '%_seed_insert';
```

---

## 6. Advisors

Run `get_advisors` for **both** `security` and `performance` against
`khohfrfqzbieaiikqlsa` after `0015` applies. Triage everything against what
`0014`/`0015` actually add:

- **No new "RLS disabled" or "RLS enabled, no policy" advisory naming
  `sync_ops`.** It gets `ENABLE`/`FORCE ROW LEVEL SECURITY` plus three real
  policies (`sync_ops_select`, `sync_ops_insert`, `sync_ops_definer_all`) in
  `0014`. If it appears in either lint, one of those statements did not
  actually take — do not just add a policy and re-apply; find out whether
  the statement itself ran, the same caution `phase-1b-deploy.md` §4.1
  gives for its own tables.
- **`sync_row_stamp`, `purge_expired_sync_ops`, and
  `normalize_ingredient_name` should not appear under the
  definer-function-executable-by-anon/authenticated lint.** All three close
  their own `PUBLIC` exposure (`REVOKE ALL ON FUNCTION ... FROM PUBLIC`)
  in the files that create them. `sync_row_stamp` is additionally
  `RETURNS trigger`, so — same reasoning as `phase-1b-deploy.md` §4.1 gives
  for `reject_write_to_scheduled_org_location` — Postgres itself refuses to
  invoke it outside trigger-firing context even if a stale grant existed.
  `normalize_ingredient_name` is a plain `SQL IMMUTABLE` function with no
  `SECURITY DEFINER` and no elevated grants at all — it should not be
  callable by `authenticated` any differently than any other unprivileged
  function default-granted by `0003`'s `ALTER DEFAULT PRIVILEGES`; that is
  expected and not itself a finding.
- Anything else new — new index-related performance advisories on the four
  `*_server_seq_idx` indexes, unused-index warnings before real traffic
  exists, etc. — is expected noise on a freshly-applied schema, not
  something to fix reflexively. Escalate only if it names an actual security
  gap (RLS, grants, exposed definer functions) that the bullets above don't
  already explain.

---

## 7. Cron: no new entry, output shape changed

`api/jobs/purge.py`'s daily cron invocation (`phase-1a-deploy.md` §9 has the
crontab entry — nothing about that entry changes) now also reaps
`sync_ops`. `run_all()`'s third "half" calls `0014`'s
`purge_expired_sync_ops(interval)` SQL function (7-day TTL,
`SYNC_OPS_TTL = "7 days"` in `api/jobs/purge.py`) using the same
`PURGE_DATABASE_URL` migration-runner identity the other two halves already
use — `purge_expired_sync_ops` is `EXECUTE`-granted only to that identity,
the same pattern as `purge_scheduled_orgs`/`accounts_pending_identity_purge`.

**The one thing that changed: `run_all()`'s return value is now a 3-tuple,
not a 2-tuple** — `(orgs_purged, identities_purged, sync_ops_purged)`. If
anything outside this repository (a monitoring script, a wrapper that logs
the cron job's return value) unpacks `run_all()`'s result positionally and
was written against the pre-1c 2-tuple, it will raise `ValueError: too many
values to unpack` the first time it runs post-deploy. Nothing in this
repository does that (`__main__`'s own invocation ignores the return value
and relies on the exit code / raised `RuntimeError` instead, per
`api/jobs/purge.py`'s bottom section) — this note exists for whatever
external tooling might be watching the cron job's own log output or exit
value, not for anything this runbook needs to change.

---

## 8. Smoke: `GET /sync` and `POST /sync`

Phase 1d note: the API now also serves a migrated web SPA at `/app/`
(`/shared/kernel.js` alongside it) — once a real host exists, run
`docs/runbooks/phase-1d-deploy.md` §4's SPA acceptance smoke there too, not
just the `/sync` smoke below.

Run these against the deployed API (not raw SQL) with a real bearer token
for a user who is a member of some organization — **use a throwaway test
org/location you control, not the `00000000-0000-7000-8000-00000000cafe`
sample org**, so the smoke write doesn't add stray rows to demo data. Obtain
`<ACCESS_TOKEN>` by signing in that user via Supabase Auth (the deployed
app's own login flow, or a direct call to Supabase's `/auth/v1/token` REST
endpoint) and substitute `<ORG_ID>` / `<LOCATION_ID>` for real values from
that org (`SELECT id FROM organizations ...`, `SELECT id FROM locations
WHERE org_id = ...`).

### 8.1 `GET /sync` pages through existing data

```bash
curl -sS -H "Authorization: Bearer <ACCESS_TOKEN>" \
  "https://<api-host>/sync?org_id=<ORG_ID>&since=0"
```

Expected shape: `{"changes": [...], "cursor": <int>, "has_more": <bool>}`.
If `has_more` is `true`, repeat with `since=<cursor from previous response>`
until `has_more` is `false` — confirms the page-cap (`SYNC_PAGE_CAP = 500`
in `api/services/sync.py`) and cursor-advance logic both work against real
data, not just the test suite's synthetic fixtures.

### 8.2 `POST /sync` applies a trivial op, then replays it

First call — a single ingredient insert:

```bash
curl -sS -X POST -H "Authorization: Bearer <ACCESS_TOKEN>" \
  -H "Content-Type: application/json" \
  -d '{
    "org_id": "<ORG_ID>",
    "batch_id": "<a fresh uuidv7, e.g. from `python -c \"import uuid,time; print(uuid.uuid4())\"` or any UUID>",
    "ops": [{
      "op_id": "<a fresh UUID>",
      "table": "ingredients",
      "row_id": "<a fresh UUID>",
      "location_id": "<LOCATION_ID>",
      "client_mutated_at": "2026-07-27T12:00:00Z",
      "fields": {"name": "Sync Smoke Test Ingredient", "base_unit": "oz"}
    }]
  }' \
  "https://<api-host>/sync"
```

Expected: `{"results": [{"op_id": "...", "status": "applied", "row_id": "..."}], "cursor": <int>}`.

Replay — **same request body, byte-for-byte, same `op_id`**:

```bash
# re-run the exact same curl command above, unchanged
```

Expected: identical `results[0]`, but with `"replayed": true` merged in
(`{"op_id": "...", "status": "applied", "row_id": "...", "replayed": true}`)
and `cursor` **unchanged** from the first call — confirms `sync_ops`
idempotency (§5.3 of `0014`) is live end-to-end, not just at the SQL layer.
Clean up the smoke-test row afterward with
`DELETE /locations/<LOCATION_ID>/ingredients/<INGREDIENT_ID>` (it's an
ingredient, not a purchase), or just leave it — it is inert demo-adjacent
data, not something a real tenant will see.

---

## 9. Rollback

`0014` and `0015` are **additive only** — new columns (all nullable-then-backfilled,
never dropped from an existing column), new indexes, a new table
(`sync_ops`), a new role (`sync_definer`), new triggers, new functions. Rolling
back is a **revert deploy of the API code** (stop routing `/sync`, `DELETE
/purchases`, and whatever else Phase 1c's routes added) — it is **not** a
database rollback.

**Do not drop the new columns, the `sync_ops` table, `sync_definer`, or
`ingredients_norm_name_live_uq` on live**, even if the API deploy is
reverted:

- Every row already has `client_mutated_at`/`server_seq`/`updated_at`
  populated from the moment `0014` applies (backfill + `NOT NULL` +
  `DEFAULT now()`); dropping them destroys data Phase 1c's own tests and any
  future re-apply of this runbook assume already exists, and gains nothing —
  an API revert alone already stops anything from reading or writing them.
- `sync_ops` accumulates nothing on its own once the API stops calling
  `POST /sync`; its 7-day TTL reaper (§7 above) already ages out whatever is
  there. Dropping the table is a one-way loss of the idempotency ledger for
  any in-flight client batch that hasn't finished retrying yet.
- `ingredients_norm_name_live_uq` is the fix for a real production bug (the
  1b create-ingredient TOCTOU). Dropping it un-fixes that bug.

If a genuine forward fix is needed after finding a problem post-deploy, write
a new migration (`0016_...`) — tombstone-style forward fixes only, per the
project's own established pattern (see `phase-1b-deploy.md`'s own framing of
`0012`/`0013` as immutable once shipped). Do not hand-edit `0014` or `0015`
in place after they've been applied anywhere.

---

## 10. As deployed, 2026-07-27 (addendum)

Executed against `khohfrfqzbieaiikqlsa` on 2026-07-27 by Claude (Travis
green-lit agent-run deploys). Outcomes and deviations, for whoever reads
the live migration list next:

- **Live migration names differ from the repo files.** The Supabase MCP
  `apply_migration` path **terminates the connection on any role-membership
  `GRANT`/`REVOKE` phrased `TO/FROM CURRENT_USER`** (confirmed by bisection;
  plain DDL, `CREATE ROLE`, table/schema grants, and `$$` bodies are all
  fine). The repo files were therefore applied split and adapted:
  `0012a_business_schema`, `0012b_business_policies`,
  `0012c_business_scheduled_freeze`, `0013_sample_business_seed`,
  `0014a_sync_columns_backfill`, `0014b_sync_definer_stamp`,
  `0014c_sync_stamp_ownership`, `0014d_sync_ops`,
  `0015_ingredient_name_norm`, `0016_revoke_sync_fn_exposure` (a recorded
  no-op — see next bullet), `0016b_revoke_sync_fn_exposure_as_grantor`.
  Net object state matches the repo files; the GRANT/REVOKE brackets were
  replaced by (a) creating triggers while the runner still owned the
  functions (EXECUTE is checked only at CREATE TRIGGER time), then
  (b) transferring ownership under a temporary `GRANT CREATE ON SCHEMA
  public` (revoked immediately), with the runner's SET-capable definer
  memberships granted out-of-band via `execute_sql` using explicit-member
  phrasing (`GRANT <role> TO postgres WITH SET TRUE`) and removed after
  (`REVOKE <role> FROM postgres GRANTED BY postgres`).
- **§2.2-style "zero members" pre-checks are a local-harness assumption.**
  On live, every definer role carries an implicit `admin_option`-only
  membership for `postgres` granted by `supabase_admin` at CREATE ROLE time
  (PG16 CREATEROLE behavior). That is the clean end state, not residue.
- **The advisor pass caught a real hole → migration 0016.** The three 0014
  functions were PostgREST-callable by `anon`/`authenticated` (0003's
  default privileges; 0010/0011 predate them). `purge_expired_sync_ops`
  was genuinely dangerous (caller-controlled retention). The first revoke
  attempt as the runner was a **silent no-op** — `ALTER FUNCTION ... OWNER`
  re-attributes default-privilege grants to the new owner as grantor, and
  only the grantor can revoke — so live carries `0016` (no-op, kept for
  the record) and `0016b` (the effective `SET ROLE` version, matching the
  repo's `0016_revoke_sync_fn_exposure.sql`). Verified after:
  `has_function_privilege` false for `anon`/`authenticated` on all three,
  true for `postgres` on `purge_expired_sync_ops` (the purge job's grant).
- **All §5 verification queries passed** (dense backfill with sample-org
  counter exactly 31; trigger ordering; sync_ops FORCE RLS with exactly
  SELECT+INSERT for `authenticated`; function owners; normalize index;
  zero leftover tmp/seed policies). Locale check: `en_US.UTF-8` /
  ICU `en-US` ✓. Duplicate-name pre-check: zero rows ✓.
- **§8 smoke is deferred**: no API host serves this project yet (the Phase
  1a go-live checklist — `app_user` password, env vars, reviewer account,
  purge cron — is still open on the Notion Human Action Board). Run §8
  once the FastAPI deploy exists.
