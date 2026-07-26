-- ===========================================================================
-- Task 11: deletion schema, the write guard, and the purge function.
--
-- NUMBERING: the plan called this file `0005_deletion.sql`. It was written
-- before Task 7 took 0005 (email_verification_binding) and Task 9 took 0006
-- (accept_invite_definer, which the plan had not budgeted a migration for at
-- all). 0007 is the next free number; Task 13's sample-org migration becomes
-- 0008. `tests/conftest.py`'s `seeded` already caps at 8.
--
-- Two operations are modelled here and they are deliberately NOT symmetric:
--
--   * "delete my account"       -- immediate, no grace. Removes the caller's
--                                  memberships and profile only.
--   * "delete my organization"  -- 30-day grace, owner-only, cancellable
--                                  strictly inside the window. Stripe
--                                  cancellation and Apple revocation happen
--                                  IMMEDIATELY on confirm, never after the
--                                  grace elapses.
--
-- The 30-day window is a human-partner decision and MUST be stated in the
-- privacy policy (carried to the Task 14 runbook).
-- ===========================================================================

ALTER TABLE organizations ADD COLUMN deletion_scheduled_at timestamptz;
ALTER TABLE organizations ADD COLUMN stripe_customer_id    text;

-- Set only when billing cancellation has actually been confirmed for this
-- org (including the legitimate "there was no Stripe customer to cancel"
-- case). `cancel_subscription` (api/services/billing.py) raises rather than
-- silently skipping a misconfigured cancellation, and the deletion endpoint
-- deliberately does NOT abort the deletion when it does -- the user asked to
-- be deleted and that request is the durable state. That combination would
-- otherwise leave Stripe billing a customer who was told billing had
-- stopped, with nothing anywhere recording the discrepancy. This column IS
-- that record: Task 12's purge job must treat
-- `deletion_scheduled_at IS NOT NULL AND billing_cancelled_at IS NULL` as an
-- alert, not as a row to quietly delete.
ALTER TABLE organizations ADD COLUMN billing_cancelled_at  timestamptz;

CREATE INDEX organizations_deletion_idx ON organizations (deletion_scheduled_at)
  WHERE deletion_scheduled_at IS NOT NULL;


-- ---------------------------------------------------------------------------
-- 1. Letting a member remove their own membership.
--
-- `membership_write` (0004) is scoped to OWNERS of the org, for ALL commands.
-- Under FORCE RLS that makes `DELETE /me` structurally impossible for
-- everyone it is actually meant for: a manager deleting their own account
-- matches zero rows and -- with no rowcount check -- gets a cheerful 200
-- while their membership, profile and account all survive. That is the exact
-- failure Task 4's carry note predicted ("Task 11 delete_account removes 0
-- memberships for non-owners while returning success") and it is worse than
-- an error, because the user believes they are gone.
--
-- Deliberately FOR DELETE only, and deliberately NOT a `FOR ALL` widening of
-- `membership_write`: leaving an org is a legitimate capability for the row's
-- own subject, whereas INSERT/UPDATE would let a caller mint or re-role their
-- own membership. It does not lower the floor on the zero-owner invariant --
-- that invariant has never had database-level enforcement (Task 9's reviewer
-- confirmed it lives entirely in application code, guarded by the org
-- advisory lock), and every path that removes an owner row, this new one
-- included, takes the same `_lock_org` key before deciding.
CREATE POLICY membership_self_leave ON memberships FOR DELETE TO authenticated
  USING (user_id = current_user_id());


-- ---------------------------------------------------------------------------
-- 2. The deletion guard, at the database rather than the URL.
--
-- api/main.py carries an HTTP middleware that 410s writes to `/orgs/{id}/...`
-- for a scheduled org. That is the guard the spec asks for and it produces the
-- right status code, but it is a REGEX OVER PATHS: it cannot see a write whose
-- org id is not in the URL. `POST /invites/accept` is exactly that -- an
-- invite issued before the deletion was scheduled still adds a live membership
-- to a doomed org, and `accept_invite_tx` runs as `invite_definer`, nowhere
-- near the middleware.
--
-- So the actual invariant lives here, as a BEFORE trigger on every table that
-- carries an org_id. It fires regardless of which role writes, which route
-- (or SECURITY DEFINER function) issued the statement, and whether the path
-- happened to name the org. `POST /sync` does not exist in this phase; when it
-- does, it is already covered.
--
-- The trigger function has to be SECURITY DEFINER, not a plain one: a trigger
-- body otherwise runs as the INVOKING role, and `organizations` is under FORCE
-- RLS. Evaluated as `invite_definer` (which has no policy on organizations at
-- all, by design -- see 0006) the lookup returns FALSE and the guard fails
-- OPEN. Same class of bug as 0006's `FOR UPDATE`-under-RLS lock that never
-- locked, and pinned by a mutation check: dropping SECURITY DEFINER here lets
-- an invite into a scheduled org be accepted.
--
-- Deliberately NOT split into a separately-granted
-- `org_is_scheduled_for_deletion(uuid)` helper, which is what the plan
-- suggested. Any role that writes a row carrying an org_id would need EXECUTE
-- on such a helper -- including `authenticated` -- and that hands every tenant
-- a cross-org oracle: `SELECT org_is_scheduled_for_deletion('<someone
-- else's org>')` answers for an org RLS otherwise hides completely. Folding
-- the lookup into the trigger function itself removes that surface entirely,
-- because PostgreSQL checks EXECUTE on a trigger function when the TRIGGER is
-- created, not each time it fires -- so no request-path role needs any grant
-- on it at all.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'deletion_definer') THEN
    CREATE ROLE deletion_definer NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER;
  END IF;
END $$;

-- Reassigning function ownership below needs this even when the migration
-- runner is not a superuser (Supabase). REVOKEd at the end of the file --
-- see 0004's identical dance and its comment for why that is not optional.
GRANT deletion_definer TO CURRENT_USER;

GRANT USAGE  ON SCHEMA public   TO deletion_definer;
GRANT SELECT ON organizations   TO deletion_definer;

-- Mirrors 0004's `membership_definer_read`: the permissive constant is what
-- lets the definer function see anything at all. Unreachable except through
-- the one function below -- deletion_definer is NOLOGIN and, after the REVOKE
-- at the end of this file, has no members.
CREATE POLICY deletion_definer_org_read ON organizations FOR SELECT TO deletion_definer
  USING (true);

CREATE OR REPLACE FUNCTION reject_write_to_scheduled_org()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
-- pg_temp listed LAST and every reference schema-qualified, for the reason
-- spelled out at length in 0006: unless pg_temp is named explicitly Postgres
-- searches it FIRST, and a caller-owned TEMP table named `organizations`
-- would otherwise answer this question on the caller's behalf -- turning the
-- guard off for anyone who can create a temp table.
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.organizations o
     WHERE o.id = NEW.org_id AND o.deletion_scheduled_at IS NOT NULL
  ) THEN
    -- Custom SQLSTATE so api/main.py can map exactly this condition to HTTP
    -- 410 without pattern-matching an error message. Deliberately outside
    -- every standard class.
    RAISE EXCEPTION 'organization % is scheduled for deletion', NEW.org_id
      USING ERRCODE = 'CS410';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION reject_write_to_scheduled_org() OWNER TO deletion_definer;
-- Nothing may call it directly. It is reached only by the three triggers
-- below, which need no runtime EXECUTE grant of their own.
REVOKE ALL ON FUNCTION reject_write_to_scheduled_org() FROM PUBLIC;

-- DELETEs are intentionally NOT guarded. A member must still be able to leave
-- (or delete their account out of) an org that is on its way out, and the
-- purge itself is a delete. Only resurrection is blocked.
CREATE TRIGGER memberships_reject_write_to_scheduled_org
  BEFORE INSERT OR UPDATE ON memberships
  FOR EACH ROW EXECUTE FUNCTION reject_write_to_scheduled_org();
CREATE TRIGGER locations_reject_write_to_scheduled_org
  BEFORE INSERT OR UPDATE ON locations
  FOR EACH ROW EXECUTE FUNCTION reject_write_to_scheduled_org();
CREATE TRIGGER invites_reject_write_to_scheduled_org
  BEFORE INSERT OR UPDATE ON invites
  FOR EACH ROW EXECUTE FUNCTION reject_write_to_scheduled_org();


-- ---------------------------------------------------------------------------
-- 3. The purge.
--
-- Runs as its OWN definer role rather than relying on the caller bypassing
-- RLS. Task 4's carry note flags this exact uncertainty: migrations run as
-- `postgres`, `organizations` is FORCE RLS, and whether Supabase's `postgres`
-- carries BYPASSRLS decides between "deletes every due org" and "silently
-- deletes zero" -- with no error either way. Making the function a SECURITY
-- DEFINER with its own explicit DELETE policy removes the question entirely,
-- in every environment.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'purge_definer') THEN
    CREATE ROLE purge_definer NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER;
  END IF;
END $$;

GRANT purge_definer TO CURRENT_USER;

GRANT USAGE ON SCHEMA public TO purge_definer;
GRANT SELECT, DELETE ON organizations TO purge_definer;

CREATE POLICY purge_definer_org_read ON organizations FOR SELECT TO purge_definer
  USING (true);
CREATE POLICY purge_definer_org_delete ON organizations FOR DELETE TO purge_definer
  USING (true);

CREATE OR REPLACE FUNCTION purge_scheduled_orgs(grace interval)
RETURNS int
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_id     uuid;
  v_purged int := 0;
BEGIN
  -- Deliberately NOT the plan's single `DELETE ... RETURNING`, for two
  -- reasons:
  --
  --  1. It takes the SAME org advisory lock every owner-count-sensitive
  --     decision in this codebase takes (api/routes/members.py `_lock_org`,
  --     0006's accept_invite_tx), with the SAME key derivation. Without it
  --     the purge is the one writer that never serializes against the
  --     others -- and it is the destructive one.
  --  2. Re-checking the predicate AFTER the lock closes the cancel race
  --     deterministically. A cancel that commits while the purge is
  --     mid-flight then provably saves the org, instead of depending on
  --     READ COMMITTED's EPQ re-evaluation to do it by accident.
  --
  -- ORDER BY id matches the ordering `delete_account` uses when it locks
  -- several orgs at once, so the two can never deadlock against each other.
  FOR v_id IN
    SELECT o.id FROM public.organizations o
     WHERE o.deletion_scheduled_at IS NOT NULL
       AND o.deletion_scheduled_at < now() - grace
     ORDER BY o.id
  LOOP
    PERFORM pg_advisory_xact_lock(hashtextextended(v_id::text, 0));
    DELETE FROM public.organizations o
     WHERE o.id = v_id
       AND o.deletion_scheduled_at IS NOT NULL
       AND o.deletion_scheduled_at < now() - grace;
    IF FOUND THEN
      v_purged := v_purged + 1;
    END IF;
  END LOOP;
  RETURN v_purged;
END;
$$;
ALTER FUNCTION purge_scheduled_orgs(interval) OWNER TO purge_definer;

-- `grace` is an ARGUMENT, so EXECUTE on this function is equivalent to
-- "delete every organization anyone has ever scheduled, right now, grace
-- ignored". It must never be reachable from the request path: no grant to
-- `authenticated`, none to `app_user`. Only the migration runner -- the same
-- identity Task 12's job will hold -- gets it. Pinned by
-- test_authenticated_cannot_execute_the_purge_function.
REVOKE ALL ON FUNCTION purge_scheduled_orgs(interval) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION purge_scheduled_orgs(interval) TO CURRENT_USER;

-- Give both definer memberships back. Left in place, each is a live softening
-- of FORCE ROW LEVEL SECURITY for the migration runner -- RLS role matching
-- uses has_privs_of_role(), so `purge_definer_org_delete`'s USING (true)
-- would reach any INHERIT member. See 0004's identical REVOKE.
REVOKE deletion_definer FROM CURRENT_USER;
REVOKE purge_definer    FROM CURRENT_USER;
