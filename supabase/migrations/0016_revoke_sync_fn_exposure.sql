-- 0016_revoke_sync_fn_exposure.sql — Phase 1c hotfix, found by the live
-- deploy's advisor pass (2026-07-27): 0003's ALTER DEFAULT PRIVILEGES grants
-- EXECUTE on every new function to anon/authenticated, and 0010/0011's
-- revoke pass predates the three functions 0014 created — so all three were
-- callable via PostgREST /rest/v1/rpc/ on live.
--
-- The revokes are issued AS THE OWNING ROLE (SET ROLE), not as the migration
-- runner: ALTER FUNCTION ... OWNER re-attributes the default-privilege
-- grants to the new owner as grantor, and only the grantor can revoke them —
-- a runner-issued REVOKE succeeds and silently removes nothing (confirmed
-- against live with has_function_privilege; 0010's own header records the
-- same lesson, and the live project's 0011_revoke_rpc_exposure_as_grantor
-- exists because of it).
--
-- `anon` exists only on Supabase (0010's local no-op note), so its revokes
-- sit in IF EXISTS guards; PUBLIC/authenticated are unconditional.
--
-- Severity per function:
--   * purge_expired_sync_ops — REAL exposure: SECURITY DEFINER as
--     sync_definer (which holds DELETE on sync_ops via sync_ops_definer_all),
--     and the caller controls the retention arg — an anon call with
--     '0 seconds' empties the idempotency ledger. This revoke is the fix.
--   * sync_row_stamp / reject_write_to_scheduled_org_location — RETURNS
--     trigger, so Postgres itself refuses direct invocation ("trigger
--     functions can only be called as triggers"); revoked anyway so the
--     advisor lint stays clean and the ACL matches 0010's convention.
--
-- normalize_ingredient_name (0015) is deliberately NOT here: plain SQL,
-- SECURITY INVOKER, no elevated grants — callable-by-authenticated is the
-- same class as any other unprivileged helper.

SET ROLE sync_definer;
REVOKE EXECUTE ON FUNCTION purge_expired_sync_ops(interval) FROM PUBLIC, authenticated;
REVOKE EXECUTE ON FUNCTION sync_row_stamp() FROM PUBLIC, authenticated;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE EXECUTE ON FUNCTION public.purge_expired_sync_ops(interval) FROM anon;
    REVOKE EXECUTE ON FUNCTION public.sync_row_stamp() FROM anon;
  END IF;
END
$$;
RESET ROLE;

SET ROLE deletion_definer;
REVOKE EXECUTE ON FUNCTION reject_write_to_scheduled_org_location() FROM PUBLIC, authenticated;
DO $$
BEGIN
  IF EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'anon') THEN
    REVOKE EXECUTE ON FUNCTION public.reject_write_to_scheduled_org_location() FROM anon;
  END IF;
END
$$;
RESET ROLE;
