# Phase 1b Deploy Runbook: business tables and sample data

Audience: whoever runs the Supabase apply for `0012_business_tables.sql` and
`0013_sample_business_seed.sql`. Assumes the reader has already applied
`0001`-`0010` (see `docs/runbooks/phase-1a-deploy.md`) and has no memory of
how Phase 1b was built. Every claim below is sourced from the two migration
files themselves, as they actually shipped — not from the Task 13/14 plan
text, which is a design intent document, not a record of what is in the
repository.

**Target project:** `khohfrfqzbieaiikqlsa`. Same project as Phase 1a. As of
writing, nothing in this document has been applied to it — confirm the
current state with `list_migrations` before assuming otherwise.

---

## 1. What to apply

Two files, in this order, one `apply_migration` call each, **stopping at the
first error**:

```
0012_business_tables.sql
0013_sample_business_seed.sql
```

### Why the next file after `0010` is `0012`, not `0011`

`supabase/migrations/` in this repository has no file numbered `0011`. This
is intentional, not a gap to fill in. `0012_business_tables.sql`'s own header
comment explains it: the *live* `khohfrfqzbieaiikqlsa` project's migration
history already has a row named `0011_revoke_rpc_exposure_as_grantor` — during
the 2026-07-26 Phase 1a deploy, what is a single file in this repository
(`0010_revoke_rpc_exposure.sql`) was split and applied to the live project as
two separate migrations, `0010_revoke_rpc_exposure_on_definer_functions` and
`0011_revoke_rpc_exposure_as_grantor`. So the live project's migration list
already ends `...0010_revoke_rpc_exposure_on_definer_functions,
0011_revoke_rpc_exposure_as_grantor`, and local `0010_revoke_rpc_exposure.sql`
is the combined equivalent of both. If Task 14 had numbered the next new file
`0011`, it would collide with a name Supabase's migration history table
already has recorded against this exact project. Numbering the next file
`0012` sidesteps the collision entirely. Do not renumber `0012`/`0013`
downward to "fill the gap" — the gap is deliberate and specific to this one
project's history.

---

## 2. Pre-apply checks

Run these against `khohfrfqzbieaiikqlsa` before applying `0012`, and resolve
every finding before proceeding.

1. **`public` must not already contain `ingredients`, `purchases`, `recipes`,
   or `recipe_items`.** `list_tables` against the project and check.
   `0012_business_tables.sql` issues plain `CREATE TABLE` for all four with no
   `IF NOT EXISTS` guard — same rationale, same failure mode, as `0002`'s
   tenancy tables in Phase 1a (see that runbook's §3.1). If any of these
   already exist, the migration fails outright at whichever `CREATE TABLE`
   hits the collision first, and everything before that statement in the same
   file has already committed nothing (see §3's atomicity note) but you must
   still find out what the pre-existing table is and why before touching this
   migration set.

2. **`deletion_definer` must currently have zero members.** `0012` performs
   its own `GRANT deletion_definer TO CURRENT_USER` / `... REVOKE ...` bracket
   (see §3 below), and a leftover member from an earlier, unrelated partial
   failure would make it unclear whether any privilege gap you find after
   `0012` runs came from this file or from something older. Use the same
   query the Phase 1a runbook uses for this (its §4/§5.3), scoped to this one
   role:

   ```sql
   SELECT g.rolname AS member
   FROM pg_auth_members m
   JOIN pg_roles r ON r.oid = m.roleid
   JOIN pg_roles g ON g.oid = m.member
   WHERE r.rolname = 'deletion_definer';
   ```

   Expected: zero rows. If the migration runner (or anything else) appears
   here before you have even started, resolve that first — it means Phase
   1a's own post-apply state was never verified clean, or something applied
   between then and now that this runbook does not know about.

---

## 3. Mid-file failure hazards

Both files depend on being applied as one all-or-nothing transaction — the
same assumption the Phase 1a runbook flags as **not independently verified
against Supabase's own `apply_migration` mechanism** (its §3.4). If either
file fails partway, do not retry blindly; check for leftover state first.

### `0012`: the `deletion_definer` GRANT/REVOKE bracket

`0012` grants `deletion_definer` to `CURRENT_USER` near its middle (to create
`location_deletion_definer_read` and own the new
`reject_write_to_scheduled_org_location` trigger function), then revokes it
again at the very end of the file — **deliberately after**, not immediately
around, the four `CREATE TRIGGER` statements:

```sql
GRANT deletion_definer TO CURRENT_USER;
...
CREATE OR REPLACE FUNCTION reject_write_to_scheduled_org_location() ...
...
CREATE TRIGGER ingredients_reject_scheduled ...
CREATE TRIGGER purchases_reject_scheduled ...
CREATE TRIGGER recipes_reject_scheduled ...
CREATE TRIGGER recipe_items_reject_scheduled ...

REVOKE deletion_definer FROM CURRENT_USER;
```

This ordering is not a slip — the file's own comment calls out that Postgres
checks `EXECUTE` on a trigger's underlying function **at `CREATE TRIGGER`
time**, and the function is owned by `deletion_definer` with `EXECUTE`
revoked from `PUBLIC`. A non-superuser migration runner (Supabase's
`postgres`) needs its `deletion_definer` membership to still be live when
each of the four `CREATE TRIGGER` statements runs, or all four fail with
"permission denied for function." This is the same shape `0007_deletion.sql`
already uses for its own three triggers (`GRANT deletion_definer` before its
`CREATE TRIGGER` block, `REVOKE` after) — `0012` mirrors it rather than
introducing a new pattern.

**If `0012` fails partway, before retrying:** run the §2.2 query again. Any
row means the migration runner is still a live member of `deletion_definer`
from this partial application — `REVOKE deletion_definer FROM <member>`
before retrying the file. Retrying `0012` from the top is otherwise safe:
every `CREATE TABLE` up to that point either fully committed (if the file
failed later) or didn't run at all (if it failed at the `CREATE TABLE`
itself) — there is no partial-table state to clean up, only the role
membership.

### `0013`: the four transient `*_seed_insert` policies

`0013` creates, uses, and drops four `TO CURRENT_USER` insert policies in the
same file — `ingredients_seed_insert`, `purchases_seed_insert`,
`recipes_seed_insert`, `recipe_items_seed_insert` — because all four business
tables carry `FORCE ROW LEVEL SECURITY` (set in `0012`), which binds the
table owner too, and none of the four tables' real policies (`ingredient_write`,
`purchase_write`, `recipe_write`, `recipe_item_write`) name the migration
runner. This is the exact same pattern Phase 1a's `0009_sample_org.sql` uses
for `organizations`/`locations`, and it carries the same risk that runbook's
§12.5 documents: if the file fails **between** a `CREATE POLICY ..._seed_insert`
and its matching `DROP POLICY`, the migration runner is left holding a
**permanent** INSERT bypass on that table — silently undoing `0012`'s stated
invariant that all four tables' write policies are scoped to
`current_user_memberships()`, not to the runner.

**If `0013` fails partway, before retrying:** check for any surviving
`*_seed_insert` policy:

```sql
SELECT schemaname, tablename, policyname
FROM pg_policies
WHERE policyname LIKE '%_seed_insert';
```

Expected: zero rows once `0013` has either fully applied or not run at all.
Any row here — drop it explicitly before retrying:

```sql
DROP POLICY ingredients_seed_insert  ON ingredients;
DROP POLICY purchases_seed_insert    ON purchases;
DROP POLICY recipes_seed_insert      ON recipes;
DROP POLICY recipe_items_seed_insert ON recipe_items;
```

(Only run the `DROP POLICY` lines that match what the `pg_policies` query
above actually returned — do not blindly run all four if only one or two
survived; a `DROP POLICY` against a policy that was never created because the
matching `CREATE POLICY` never ran will error and stop you from finishing the
cleanup.)

Because `0013`'s seed data uses fixed UUIDs
(`00000000-0000-7000-8000-00000000b***`), retrying the file after cleanup is
also **not** automatically idempotent: if any `INSERT` inside `0013`
partially committed before the failure (i.e., the failure was itself
mid-transaction on a later statement, not the first one), a bare retry will
hit a primary-key collision on whichever rows already landed, and fail
loudly rather than silently double-seeding. That loud failure is
deliberate — see the file's header comment — but it also means you should
check `SELECT count(*) FROM ingredients WHERE source = 'seed'` (and the
equivalent for `purchases`, `recipes`, `recipe_items`) before retrying, not
just before considering the job done.

---

## 4. Post-apply verification

Run these against `khohfrfqzbieaiikqlsa` immediately after `0013` applies.

1. **`get_advisors` (type: security). Expect no new advisories attributable
   to these two files.** Specifically:

   - **No "RLS disabled in public" (or "RLS enabled, no policy") advisory
     naming `ingredients`, `purchases`, `recipes`, or `recipe_items`.** All
     four get `ENABLE ROW LEVEL SECURITY` and `FORCE ROW LEVEL SECURITY` in
     `0012`, plus two real policies each (`*_select`, `*_write`). If any of
     the four appears in either lint, the `ENABLE`/`FORCE` or the `CREATE
     POLICY` statements did not actually take — do not just add a policy and
     re-apply; find out whether the statement itself ran, the same caution
     the Phase 1a runbook gives for its own tables (§5.1).

   - **`reject_write_to_scheduled_org_location` should not appear under the
     definer-function-executable-by-anon/authenticated lint.** `0012` closes
     this function's own `PUBLIC` exposure with `REVOKE ALL ON FUNCTION
     reject_write_to_scheduled_org_location() FROM PUBLIC`, same as every
     other `SECURITY DEFINER` function in this codebase. Unlike `0007`'s
     analogous trigger function (`reject_write_to_scheduled_org`), this one
     did not exist when `0010_revoke_rpc_exposure.sql` was authored, so it is
     **not** in that file's `anon`/`authenticated` `REVOKE EXECUTE` list —
     `0012` does not add an equivalent revoke of its own either. This is
     expected to be safe regardless, because `reject_write_to_scheduled_org_location`
     is declared `RETURNS trigger`: Postgres itself refuses to invoke a
     trigger-returning function outside of trigger-firing context ("trigger
     functions can only be called as triggers"), so even if `anon` or
     `authenticated` held `EXECUTE` on it via the `ALTER DEFAULT PRIVILEGES`
     grant `0003` set up, a PostgREST call to
     `/rest/v1/rpc/reject_write_to_scheduled_org_location` cannot actually
     run the function body — the same reasoning `0010`'s own header comment
     gives for why trigger functions are a different risk class from
     `purge_scheduled_orgs`-style callable definer functions. Confirm this
     with `get_advisors` rather than taking it on faith: if the advisor
     surfaces this function under the executable-by-anon lint anyway, treat
     it as a live finding to escalate, not something this runbook has
     pre-cleared.

2. **Row counts, sample org only.** Confirm the seed landed exactly once and
   matches the fixed-UUID data in `0013`:

   ```sql
   SELECT count(*) FROM ingredients i
   JOIN locations l ON l.id = i.location_id
   WHERE l.org_id = '00000000-0000-7000-8000-00000000cafe';
   -- expect 5

   SELECT count(*) FROM purchases p
   JOIN locations l ON l.id = p.location_id
   WHERE l.org_id = '00000000-0000-7000-8000-00000000cafe';
   -- expect 20

   SELECT count(*) FROM recipes r
   JOIN locations l ON l.id = r.location_id
   WHERE l.org_id = '00000000-0000-7000-8000-00000000cafe';
   -- expect 2

   SELECT count(*) FROM recipe_items ri
   JOIN locations l ON l.id = ri.location_id
   WHERE l.org_id = '00000000-0000-7000-8000-00000000cafe';
   -- expect 4
   ```

   5 ingredients (`b001`-`b005`, one per fictional vendor), 20 purchases
   (`b101`-`b120`, 4 per ingredient — 3 baseline dates plus one latest date),
   2 recipes (`b201` Margarita Special, `b202` Fish Tacos), 4 recipe items
   (`b301`-`b304`) — all sourced from `0013`'s `VALUES` lists directly, not
   estimated.

3. **No leftover `*_seed_insert` policy and no leftover `deletion_definer`
   membership**, using the same two queries from §2.2 and §3's `0013`
   subsection. Both should read zero rows on a clean, fully-applied run —
   running them here is a final confirmation, not just a failure-recovery
   step.

---

## 5. Environment variables, roles, credentials

**None of these two migrations require anything new.** No new Postgres role
is created (`0012` only uses `authenticated`, already provisioned in `0003`,
and `deletion_definer`, already provisioned in `0007`). No new grant target,
no new secret, no new connection string. `DATABASE_URL` / `app_user`'s story
(Phase 1a runbook §2, §6) is unchanged — the API server gains routes that
read and write `ingredients`, `purchases`, `recipes`, and `recipe_items`
through the exact same `app_user` pooled connection it already uses for
everything else, subject to the exact same RLS policies pattern (location
join, then `current_user_memberships()`) as every other table in this
project. If a deploy of the API code that consumes these tables fails with a
permission error, the cause is in the application code or the policies
above, not in a missing credential.

---

## 6. Known gaps — restated, do not be surprised by these

Applying `0012` and `0013` changes what exists in the database. It does
**not**, by itself, change what the deployed API or the live Vercel demo
does.

- **The CSV import endpoint is deliberately absent.** `ingredients` and
  `purchases` both carry a `source` column constrained to `'manual'`,
  `'seed'`, or `'import'` — the schema already anticipates bulk import — but
  no route in this codebase writes `source = 'import'` yet. That is a Phase
  1d, web-only feature. Applying these migrations does not add it.

- **No sync columns exist yet.** `client_mutated_at` / `server_seq`-style
  columns for offline sync are explicitly out of scope for this migration
  set (`0012`'s own header says so) — Phase 1c's job. `deleted_at`
  tombstones do land now, on all four tables, because the drift-selection
  and merge logic that Phase 1c/1d build on needs them to already exist.

- **The live Vercel demo (the SPA) does not change.** It still consumes the
  old demo endpoints, not `ingredients`/`purchases`/`recipes`/`recipe_items`.
  SPA adoption of the new tables is a Phase 1d task. Deploying `0012` and
  `0013` to `khohfrfqzbieaiikqlsa` seeds real data that nothing user-facing
  reads yet — do not expect to see it anywhere in the live demo after this
  runbook is followed. The only way to observe the seeded data today is
  direct SQL against the project or the new API routes' own tests.
