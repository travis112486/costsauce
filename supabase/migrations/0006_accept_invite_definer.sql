-- Task 9 fix: a SECURITY DEFINER escape hatch for invite acceptance.
--
-- The plan's brief has `accept_invite` use "a raw pool.connection()" rather
-- than `tenant_connection`, reasoning that the invitee has no membership yet
-- so RLS cannot see the invite row (owner-only `invite_all`, migration
-- 0004). That reasoning is right, but the mechanism as literally written
-- does not work: `app.state.pool` authenticates as `app_user` (0003), which
-- is NOINHERIT and holds NO grants of its own -- every GRANT in 0003 targets
-- `authenticated`, and NOINHERIT means app_user only gets those privileges
-- via an explicit `SET ROLE authenticated`, which a bare `pool.connection()`
-- never issues. Confirmed empirically: every query on such a connection
-- fails with `relation "invites" does not exist` (Postgres reports "does not
-- exist" rather than "permission denied" when the role lacks USAGE on every
-- schema that could contain the name) -- a hard failure on every call, not
-- an RLS-filtered empty result.
--
-- The fix mirrors 0004's OWN escape hatch for the structurally identical
-- problem (`current_user_memberships()` bypassing the
-- memberships-reads-memberships recursion): a narrow, unreachable NOLOGIN
-- role owning exactly one SECURITY DEFINER function, reached through the
-- ordinary `tenant_connection` path (the invitee's own verified claims,
-- `SET LOCAL ROLE authenticated`) instead of a bespoke raw-connection code
-- path. This keeps exactly ONE mechanism doing the bypassing -- the same one
-- the plan sanctions, just correctly implemented -- and leaves app_user's and
-- authenticated's own privileges exactly as hardened by Tasks 3-5.
--
-- Review round 1 found two Critical defects in the first version of this
-- migration, both fixed here:
--
--  1. `SET search_path = pg_catalog, public` (no `pg_temp`) let an
--     `authenticated` session shadow `invites`/`memberships` with same-named
--     TEMP tables it owns -- Postgres searches pg_temp FIRST whenever it is
--     not explicitly listed in search_path, so the function's bare
--     `invites`/`memberships` references resolved to the caller's forged
--     temp tables instead of the real ones, and `membership_definer_write`'s
--     `USING (true)` then waved the forged INSERT through. Demonstrated: a
--     forged temp `invites` row with role='owner' produced a real 'owner'
--     membership with no genuine invite ever issued. Fixed two ways, belt
--     and suspenders: `pg_temp` is now explicitly listed LAST in
--     search_path (so a real `public` object is found before pg_temp is
--     ever consulted -- explicitly naming pg_temp overrides its normal
--     search-first default), AND every reference is schema-qualified
--     (`public.invites`, `public.memberships`, ...), matching 0004's own
--     style (`public.memberships m`, `public.current_user_id()`) exactly.
--     Schema-qualification alone is sufficient; the search_path change is
--     redundant-but-cheap defense in depth.
--
--  2. `p_user_id` was a caller-supplied argument, so at the SQL contract
--     level the function could write ANY user's membership, not just the
--     caller's own -- the "no arguments a caller can steer" invariant 0004
--     states for `current_user_memberships()` did not actually hold here;
--     only the Python route enforced it, by convention, not the schema.
--     Fixed by dropping the parameter entirely and deriving the user from
--     `public.current_user_id()` (0004), which reads the same
--     `request.jwt.claims` GUC `tenant_connection` already sets for this
--     same transaction -- the SQL contract itself now can't write anyone
--     else's membership.
--
-- Review round 1 also found Important-3 (plan-mandated): invites were an
-- unbound bearer token -- token possession alone was sufficient to accept,
-- regardless of who the invite's `email` column named. Combined with
-- `create_invite` returning the token in its response body, this made an
-- invite a pure bearer credential. Fixed by requiring the accepting
-- caller's own `profiles.contact_email` to case-insensitively match the
-- invite's `email` (both `citext`) as part of the same atomic
-- UPDATE ... RETURNING that consumes the token, so a mismatched caller
-- cannot even burn the token for the real invitee.
--
-- Review round 1 also found Critical-2 (write skew / the "last owner"
-- race): the owner-count check here (and in change_role/remove_member, see
-- api/routes/members.py) was an unlocked `SELECT count(*)`. Under READ
-- COMMITTED, two concurrent transactions removing/demoting DIFFERENT owner
-- rows of the SAME org each see the other owner as still present (neither
-- sees the other's uncommitted change), both pass their own check, both
-- commit -- zero owners, textbook write skew. A naive re-check inside a
-- trigger does not fix this either (same READ COMMITTED visibility rules
-- apply inside a trigger); it requires an actual lock.
--
-- Round 1's chosen fix -- `SELECT 1 FROM organizations WHERE id = <org> FOR
-- UPDATE` -- was itself broken here, found in review round 2: Postgres
-- applies UPDATE policies (not just SELECT) to `SELECT ... FOR UPDATE`, and
-- `invite_definer` only ever had a FOR SELECT policy on organizations
-- (`invite_definer_org_read`, since removed). With no UPDATE policy, RLS
-- filtered the row out entirely, `PERFORM` matched zero rows, and NO LOCK
-- WAS TAKEN -- `FOR UPDATE` fails OPEN (returns nothing rather than
-- erroring), so nothing noticed. Reproduced live: two owners, a pending
-- invite; remove_member(owner B) held its (correctly-working, Python-side)
-- lock uncommitted while accept_invite (as owner A, demoting to a lower
-- role) ran concurrently -- accept_invite's dead lock never blocked,
-- returned 200, final owner count 0.
--
-- Fixed by switching EVERY owner-count-sensitive lock -- the three Python
-- call sites in api/routes/members.py (`_lock_org`) AND this function --
-- to `pg_advisory_xact_lock(hashtextextended(org_id::text, 0))` instead of
-- a row lock. Two reasons this is the right fix, not just a patch for the
-- one broken instance:
--   1. Advisory locks are NOT subject to RLS at all -- no policy, no role
--      grant, nothing to get out of sync with a table's policies ever
--      again. This removes the whole CLASS of failure the row-lock
--      approach was exposed to, not just this one occurrence of it.
--   2. Row locks and advisory locks are two independent Postgres locking
--      systems that do not interact. If only this SQL function had moved to
--      an advisory lock while the three Python call sites kept the row
--      lock, accept_invite_tx would never serialize against
--      change_role/remove_member/create_invite at all (different lock
--      spaces) -- the exact cross-call-site race above would persist,
--      just moved. All four call sites MUST use the identical lock
--      derivation to actually block each other.
-- A deferrable constraint trigger was considered and rejected again for the
-- same reason as round 1: it would need this same lock inside it, so it
-- adds indirection without adding safety on its own.
--
-- `organizations` no longer needs any grant or policy for `invite_definer`
-- at all -- pg_advisory_xact_lock needs neither table privilege nor an RLS
-- policy match, so the round-1 `GRANT SELECT, UPDATE ON organizations` and
-- `invite_definer_org_read` policy (the direct cause of the broken lock
-- above) are both removed as dead weight.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'invite_definer') THEN
    CREATE ROLE invite_definer NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER;
  END IF;
END $$;

-- Lets this migration reassign function ownership below even when the
-- runner is not a superuser (Supabase). REVOKEd again at the end -- see
-- 0004's identical dance and its comment for why this matters in production.
GRANT invite_definer TO CURRENT_USER;

GRANT USAGE ON SCHEMA public TO invite_definer;
GRANT SELECT, UPDATE ON invites      TO invite_definer;
GRANT SELECT, INSERT, UPDATE ON memberships TO invite_definer;
GRANT SELECT ON profiles TO invite_definer;
-- No grant on organizations: the org lock is now an advisory lock, which
-- needs no table privilege at all (see the Critical-2 note above).

-- Both permissive USING (true) policies mirror `membership_definer_read`
-- (0004): the constant is what lets the definer function see anything at
-- all, and neither table policy references memberships recursively, so
-- there is no repeat of that recursion. Neither is reachable except through
-- the function below -- invite_definer is NOLOGIN and, after the REVOKE at
-- the end of this file, has no members. profiles is READ-ONLY for this
-- role (SELECT-only grant; scoped FOR SELECT explicitly to say so
-- directly).
CREATE POLICY invite_definer_rw ON invites FOR ALL TO invite_definer
  USING (true) WITH CHECK (true);
CREATE POLICY membership_definer_write ON memberships FOR ALL TO invite_definer
  USING (true) WITH CHECK (true);
CREATE POLICY invite_definer_profile_read ON profiles FOR SELECT TO invite_definer
  USING (true);

-- Review round 2, new Important: the earlier version of this file defined
-- accept_invite_tx(text, uuid) (the caller-steerable, temp-shadowable
-- signature CREATE OR REPLACE below does NOT touch -- a different
-- parameter list is a genuinely different function in Postgres, not a
-- replacement). In any environment where that version was already applied
-- before this fix landed, both overloads would otherwise coexist, leaving
-- the vulnerable one live and EXECUTE-granted to `authenticated` even
-- though no application code calls it anymore. IF EXISTS makes this safe
-- on a fresh schema (this harness's raw_conn drops/recreates `public` every
-- test, so the 2-arg version never existed there to begin with).
DROP FUNCTION IF EXISTS accept_invite_tx(text, uuid);

CREATE OR REPLACE FUNCTION accept_invite_tx(p_token_hash text)
-- Output columns are prefixed (out_*), NOT org_id/role: PL/pgSQL implicitly
-- declares RETURNS TABLE columns as variables in scope for the whole
-- function body, and org_id/role would then shadow memberships' own
-- columns of the same name inside `ON CONFLICT (user_id, org_id)` below --
-- caught empirically as `AmbiguousColumn`, not a hypothetical.
RETURNS TABLE(status text, out_org_id uuid, out_role text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  v_user_id uuid := public.current_user_id();
  v_caller_email public.citext;
  v_org_id uuid;
  v_role text;
  v_current_role text;
  v_owner_count int;
BEGIN
  -- Fail closed on a malformed/missing sub exactly like every other policy
  -- helper in this schema (0004's current_user_id()) -- rather than let a
  -- NULL propagate into comparisons below in some subtler way.
  IF v_user_id IS NULL THEN
    RETURN QUERY SELECT 'invalid'::text, NULL::uuid, NULL::text;
    RETURN;
  END IF;

  -- Review round 2, Important-3 (still open after round 1): matching on
  -- contact_email alone let an attacker holding a leaked/shared token defeat
  -- the binding with one extra request -- POST /identity/contact-email to
  -- self-set (UNVERIFIED) contact_email to the invite's target address,
  -- then retry. Reproduced live: mallory's own accept attempt 400s, she
  -- self-sets contact_email to the invite's address, retries, 200. Fixed by
  -- requiring contact_email_verified_at IS NOT NULL here -- an invitee must
  -- have completed Task 7's /identity/contact-email/verify flow BEFORE
  -- accepting. v_caller_email stays NULL (never matches anything) for a
  -- caller with no profile or an unverified one, so this fails closed the
  -- same way a missing profile already did.
  SELECT contact_email INTO v_caller_email
    FROM public.profiles
   WHERE user_id = v_user_id
     AND contact_email_verified_at IS NOT NULL;

  -- The email match is folded into the SAME UPDATE that consumes the
  -- token: a caller whose contact_email does not match the invite's email
  -- does not consume it either (accepted_at stays NULL), so a wrong holder
  -- of a leaked/shared token cannot burn the real invitee's chance, and
  -- gets the same generic "invalid" response a bad token would -- no
  -- separate status leaks which reason it failed.
  UPDATE public.invites
     SET accepted_at = now()
   WHERE token_hash = p_token_hash
     AND accepted_at IS NULL
     AND expires_at > now()
     AND email = v_caller_email
  RETURNING public.invites.org_id, public.invites.role INTO v_org_id, v_role;

  IF v_org_id IS NULL THEN
    RETURN QUERY SELECT 'invalid'::text, NULL::uuid, NULL::text;
    RETURN;
  END IF;

  -- Critical-2 fix (round 2: advisory lock, not a row lock -- see the file
  -- header). Same key derivation as api/routes/members.py's `_lock_org`,
  -- required for the two to actually block each other. A concurrent
  -- remove_member/change_role/create_invite/another accept_invite on this
  -- SAME org blocks here until whichever transaction got here first
  -- commits (xact-scoped: released automatically at COMMIT/ROLLBACK), then
  -- this read sees post-commit state instead of a stale count.
  PERFORM pg_advisory_xact_lock(hashtextextended(v_org_id::text, 0));

  SELECT m.role INTO v_current_role
    FROM public.memberships m
   WHERE m.org_id = v_org_id AND m.user_id = v_user_id;

  -- Never let accepting an invite demote the sole remaining owner of an
  -- org -- the same invariant change_role/remove_member enforce. The
  -- invite is still consumed (accepted_at is already set above): a token
  -- that cannot be applied safely is not left lying around to retry,
  -- consistent with this codebase's other single-use tokens.
  IF v_current_role = 'owner' AND v_role <> 'owner' THEN
    SELECT count(*) INTO v_owner_count
      FROM public.memberships m
     WHERE m.org_id = v_org_id AND m.role = 'owner';
    IF v_owner_count <= 1 THEN
      RETURN QUERY SELECT 'last_owner_conflict'::text, v_org_id, v_current_role;
      RETURN;
    END IF;
  END IF;

  INSERT INTO public.memberships (user_id, org_id, role)
  VALUES (v_user_id, v_org_id, v_role)
  ON CONFLICT (user_id, org_id) DO UPDATE SET role = EXCLUDED.role;

  RETURN QUERY SELECT 'ok'::text, v_org_id, v_role;
END;
$$;

ALTER FUNCTION accept_invite_tx(text) OWNER TO invite_definer;
REVOKE ALL ON FUNCTION accept_invite_tx(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION accept_invite_tx(text) TO authenticated;

-- Give it back -- see 0004's identical REVOKE for why this is not optional.
REVOKE invite_definer FROM CURRENT_USER;
