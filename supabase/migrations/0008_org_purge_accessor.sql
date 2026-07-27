-- ===========================================================================
-- Task 12: the doomed-organization read accessor.
--
-- NUMBERING: this was not budgeted by the plan at all -- Task 12's brief
-- expected to need only `purge_scheduled_orgs` (0007) and produced no new
-- migration of its own. This one exists because that brief's own approach
-- does not work once deployed. 0009 is the next free number; Task 13's
-- sample-org migration, previously expected to land on 0008 (see the
-- renumbering note in tests/conftest.py's `seeded` fixture), moves to 0009.
--
-- THE BUG THIS CLOSES: the purge job (api/jobs/purge.py) must delete an
-- org's storage objects BEFORE the row, so a crash mid-purge leaves the row
-- behind and the job retries, instead of orphaning files an org no longer
-- exists to own. To do that it must know WHICH orgs are about to be purged
-- before `purge_scheduled_orgs` runs, taken in the same transaction and
-- locked so that a racing `cancel_org_deletion` is blocked for the whole
-- duration -- otherwise a cancel could commit between the storage delete and
-- the row purge, and this job would delete a saved org's files anyway. See
-- the lock-order note on the function itself: it takes the org ADVISORY lock
-- before the row lock, because taking them the other way round is what
-- actually deadlocked the two paths against each other.
--
-- `organizations` is `FORCE ROW LEVEL SECURITY` (0004) and the ONLY SELECT
-- policies on it belong to `authenticated` (scoped to the caller's own
-- orgs), `deletion_definer` and `purge_definer` -- both revoked from the
-- migration runner at the end of 0007, `GRANT ... TO CURRENT_USER` /
-- `REVOKE ... FROM CURRENT_USER` bracketing each migration exactly so no
-- lingering membership survives it. A job connecting as the plain migration
-- runner and running `SELECT ... FROM organizations ... FOR UPDATE` directly
-- -- which is what this task's first pass did -- has no policy that admits
-- it anything. In THIS repo's test harness that bug is invisible: `raw_conn`
-- and `db_url` connect as a genuine Postgres superuser, which bypasses RLS
-- regardless of FORCE, so the query "works" locally. On real Supabase the
-- migration-running role is not a bypassing superuser (the same uncertainty
-- Task 4's carry note raised about `purge_scheduled_orgs` itself), so that
-- same query would return ZERO rows there: `storage_delete` would never be
-- called for anything, while `purge_scheduled_orgs` -- itself SECURITY
-- DEFINER and therefore unaffected -- would still correctly delete every
-- org row. Confirmed against a live Postgres 17 instance with a
-- purpose-built no-privilege role standing in for the migration runner:
-- direct `SELECT` fails outright with `InsufficientPrivilege`; the exact
-- same query run inside a SECURITY DEFINER function it can only reach by
-- EXECUTE succeeds, and the row lock that function takes is held by the
-- CALLING session's transaction (locks belong to the transaction that
-- physically takes them, not to whichever privilege admitted the read), so
-- a concurrent `UPDATE` from a third session still blocks on it exactly as
-- required. That is the mechanism this migration installs.
--
-- Read-only and additive as far as `authenticated`/`app_user` are concerned
-- (neither gets anything new here); no change to `purge_scheduled_orgs` or
-- `accounts_pending_identity_purge` (0007). This function's only caller is
-- Task 12's job, run as the same migration-runner identity Task 4 and 0007
-- already assume; it deletes nothing itself.
--
-- ONE MORE THING `purge_definer` NEEDS, discovered only by trying this
-- against a live instance: a `SELECT ... FOR UPDATE` under row security
-- requires the executing role to hold actual `UPDATE` privilege on the
-- table -- `DELETE` does not substitute for it, even though both take a row
-- lock -- AND a policy that specifically covers `UPDATE` (or `ALL`); a
-- `SELECT`+`DELETE` policy pair, which is everything `purge_definer` had
-- before this file, is not enough. Get either one wrong and the failure
-- mode is NOT the loud `InsufficientPrivilege` you would want: missing the
-- GRANT raises exactly that, but missing only the POLICY does not raise at
-- all -- the query silently returns zero rows, indistinguishable from "no
-- orgs are due" or "nothing is due after all", precisely the failure class
-- this whole migration exists to close and that Task 4's carry note warned
-- about for `purge_scheduled_orgs` itself. Both reproduced directly against
-- a live Postgres 17 instance before settling on the GRANT + policy pair
-- below: `GRANT SELECT, DELETE` (no UPDATE) raises `InsufficientPrivilege`
-- from inside this function; `GRANT SELECT, UPDATE, DELETE` with a SELECT
-- and a DELETE policy but no UPDATE policy raises nothing and returns `[]`
-- for a row that plainly matches the SELECT policy; only granting UPDATE
-- **and** adding the UPDATE policy returns the row.
--
-- `purge_definer` never issues an actual `UPDATE` statement anywhere (this
-- function only takes the lock; `purge_scheduled_orgs` only `SELECT`s and
-- `DELETE`s) -- the grant exists purely to satisfy this locking
-- prerequisite, not to open a new column-modification path. It is also not
-- a bigger step up than what `purge_definer` already holds: it already has
-- an unconditional `DELETE` policy (`purge_definer_org_delete`, `USING
-- (true)`) on this same table, which is strictly more destructive than
-- `UPDATE` would be, and `purge_definer` remains unreachable from any
-- request-path role -- nothing here touches `authenticated` or `app_user`.
GRANT purge_definer TO CURRENT_USER;

GRANT UPDATE ON organizations TO purge_definer;
CREATE POLICY purge_definer_org_lock ON organizations FOR UPDATE TO purge_definer
  USING (true);

CREATE OR REPLACE FUNCTION organizations_pending_purge(grace interval)
RETURNS TABLE(id uuid)
LANGUAGE plpgsql SECURITY DEFINER
-- Same pg_temp-last discipline as every other definer function in this
-- codebase (0006, 0007): unqualified names would otherwise resolve against
-- a caller-owned TEMP table first, letting a caller answer this on its own
-- behalf.
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_ids uuid[];
  v_id  uuid;
BEGIN
  -- LOCK ORDER: ADVISORY FIRST, THEN THE ROW. Not negotiable, and not what
  -- this function did when it shipped.
  --
  -- Final-review Important-1. The original version went straight to
  -- `SELECT ... FOR UPDATE`, taking the ROW lock, and left the advisory lock
  -- to `purge_scheduled_orgs` (0007) afterwards. Every other writer in this
  -- codebase does the opposite: `cancel_org_deletion`
  -- (api/routes/deletion.py) takes `members._lock_org`'s ADVISORY lock and
  -- only then issues its `UPDATE organizations`, which is where the row lock
  -- is taken. Two parties, same two locks, opposite order -- a textbook
  -- deadlock, reproduced against Postgres 17 with these exact migrations in
  -- both victim directions:
  --
  --   * cancel as victim -- `DeadlockDetected` out of the route as an
  --     uncaught `psycopg.Error`, i.e. HTTP 500 on a legitimate cancel.
  --   * purge as victim -- the worse one, and the likely one whenever
  --     `storage_delete` takes longer than `deadlock_timeout` (1s), which a
  --     real bucket-prefix delete will. The purge aborts AFTER deleting the
  --     org's storage, the cancel then commits, and the org survives with
  --     its storage already destroyed. That is exactly the failure this
  --     file's own header claims to have closed, and it is latent only
  --     because `storage_delete` is not wired up yet (api/jobs/purge.py
  --     passes the default `None`).
  --
  -- So the advisory lock is taken here, first, using the IDENTICAL key
  -- derivation as the four call sites that already agree on it
  -- (`api/routes/members.py::_lock_org`, 0006's `accept_invite_tx`, 0007's
  -- `purge_scheduled_orgs`, and `_lock_caller_orgs` via `_lock_org`). A
  -- fifth call site that disagreed on this derivation cost Task 9 three fix
  -- rounds; there is no second spelling of it anywhere in this repo.
  --
  -- Pass 1 collects the candidate set and locks it advisory-only, in
  -- `ORDER BY id` -- the same order `purge_scheduled_orgs`'s loop and
  -- `_lock_caller_orgs` use, so overlapping acquirers queue instead of
  -- deadlocking against each other.
  SELECT array_agg(o.id ORDER BY o.id) INTO v_ids
    FROM public.organizations o
   WHERE o.deletion_scheduled_at IS NOT NULL
     AND o.deletion_scheduled_at < now() - grace;

  IF v_ids IS NULL THEN
    RETURN;
  END IF;

  FOREACH v_id IN ARRAY v_ids LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_id::text, 0));
  END LOOP;

  -- Pass 2 re-reads under the advisory locks and takes the row locks. The
  -- re-read is not redundant: a cancel that committed between pass 1's
  -- unlocked read and this transaction acquiring that org's advisory lock
  -- has saved the org, and this statement's own snapshot (READ COMMITTED
  -- takes a fresh one per statement) now sees that -- so the org is dropped
  -- from the result and `run_purge` never touches its storage. `now()` is
  -- fixed for the transaction, so the predicate cannot move underneath the
  -- two passes for any other reason.
  --
  -- `id = ANY(v_ids)` keeps the returned set a subset of what pass 1
  -- advisory-locked: nothing is ever handed back that this transaction does
  -- not hold BOTH locks on.
  --
  -- FOR UPDATE is still the guard the caller needs: a real row lock, taken
  -- on the CALLING transaction, that survives the return of this function
  -- for as long as that transaction stays open.
  RETURN QUERY
    SELECT o.id FROM public.organizations o
     WHERE o.id = ANY(v_ids)
       AND o.deletion_scheduled_at IS NOT NULL
       AND o.deletion_scheduled_at < now() - grace
     ORDER BY o.id
     FOR UPDATE;
END;
$$;
ALTER FUNCTION organizations_pending_purge(interval) OWNER TO purge_definer;

-- Never reachable except through this one call. No role -- including
-- `authenticated` -- gets EXECUTE; only the migration runner (CURRENT_USER
-- at apply time, the same identity that already holds EXECUTE on
-- `purge_scheduled_orgs` and `accounts_pending_identity_purge`) does.
REVOKE ALL ON FUNCTION organizations_pending_purge(interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION organizations_pending_purge(interval) TO CURRENT_USER;

-- Give the membership back. Left in place it is a live softening of FORCE
-- ROW LEVEL SECURITY for the migration runner -- see 0004's and 0007's
-- identical REVOKE and the comment on why that is not optional.
REVOKE purge_definer FROM CURRENT_USER;
