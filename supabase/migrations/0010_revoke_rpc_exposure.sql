-- ===========================================================================
-- PRODUCTION-ONLY DEFECT, found by Supabase's security advisors during the
-- Phase 1a apply. It could not surface in the local harness: there is no
-- PostgREST there and no `anon` role.
--
-- Supabase ships:
--     ALTER DEFAULT PRIVILEGES IN SCHEMA public
--       GRANT EXECUTE ON FUNCTIONS TO anon, authenticated, service_role;
--
-- so every SECURITY DEFINER function these migrations create picks up EXECUTE
-- for `anon` and `authenticated` AT CREATION TIME, and PostgREST exposes
-- anything executable in `public` at /rest/v1/rpc/<name>. The `REVOKE ALL ON
-- FUNCTION ... FROM PUBLIC` in 0004/0006/0007/0008 does not help: it removes
-- the PUBLIC grant, not role-specific ones.
--
-- Worst case, verified reachable on the live project before this migration:
--
--     POST /rest/v1/rpc/purge_scheduled_orgs   {"grace": "0 seconds"}
--
-- would hard-delete EVERY organization whose deletion was scheduled, bypassing
-- the entire 30-day grace window -- irreversible, and callable by anyone
-- holding the public anon key.
--
-- TWO THINGS TO KNOW BEFORE EDITING THIS FILE
--
-- 1. A REVOKE only removes grants made BY the revoking role. These grants are
--    attributed to the FUNCTION OWNER (the acl reads `anon=X/purge_definer`),
--    so revoking as the migration runner is a silent no-op -- it reports
--    success and changes nothing. Each REVOKE below therefore runs under
--    SET LOCAL ROLE <owner>. Verified: the first attempt, run as postgres,
--    reported success and left has_function_privilege('anon', ...) = true on
--    all six functions.
--
-- 2. Any NEW SECURITY DEFINER function added to `public` in a later phase will
--    inherit the same exposure. Add it here, or put it in a schema PostgREST
--    does not expose.
-- ===========================================================================

DO $$
BEGIN
  -- `anon` exists only on Supabase, so this is a no-op locally and the file
  -- reads identically in both environments.
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN

    SET LOCAL ROLE purge_definer;
      REVOKE EXECUTE ON FUNCTION purge_scheduled_orgs(interval)        FROM anon, authenticated;
      REVOKE EXECUTE ON FUNCTION organizations_pending_purge(interval) FROM anon, authenticated;
      REVOKE EXECUTE ON FUNCTION accounts_pending_identity_purge()     FROM anon, authenticated;
    RESET ROLE;

    SET LOCAL ROLE deletion_definer;
      -- A trigger function: triggers fire regardless of EXECUTE privilege, so
      -- no caller ever needs it and it must not be directly invokable.
      REVOKE EXECUTE ON FUNCTION reject_write_to_scheduled_org() FROM anon, authenticated;
    RESET ROLE;

    SET LOCAL ROLE invite_definer;
      -- `authenticated` KEEPS EXECUTE: the FastAPI route calls this on the
      -- caller's own connection. It is protected by an unguessable token hash
      -- plus a verified-contact-email match, and derives the acting user from
      -- current_user_id() rather than from an argument.
      REVOKE EXECUTE ON FUNCTION accept_invite_tx(text) FROM anon;
    RESET ROLE;

    SET LOCAL ROLE rls_definer;
      -- `authenticated` KEEPS EXECUTE: every RLS policy calls this as the
      -- caller. It returns only the caller's own memberships, so RPC exposure
      -- leaks nothing beyond what GET /me already returns.
      REVOKE EXECUTE ON FUNCTION current_user_memberships() FROM anon;
    RESET ROLE;

  END IF;
END $$;
