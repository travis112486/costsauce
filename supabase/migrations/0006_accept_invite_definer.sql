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
-- Narrow by construction: the function takes only a token hash (unguessable,
-- 256 bits) and the CALLER's own user_id (api/routes/members.py always
-- passes caller.user_id from the caller's own verified JWT, never another
-- user's); it writes exactly one invites row and one memberships row.
--
-- It also closes a gap found in Task 9 review: `change_role` and
-- `remove_member` both refuse to leave an org with zero owners, but nothing
-- stopped an existing owner from accepting a *lower-role* invite for their
-- own org and silently demoting themselves via `ON CONFLICT DO UPDATE`,
-- bypassing that protection entirely. The same last-owner check is applied
-- here.
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

-- Both permissive USING (true) policies mirror `membership_definer_read`
-- (0004): the constant is what lets the definer function see anything at
-- all, and neither table policy references memberships recursively, so
-- there is no repeat of that recursion. Neither policy is reachable except
-- through the function below -- invite_definer is NOLOGIN and, after the
-- REVOKE at the end of this file, has no members.
CREATE POLICY invite_definer_rw ON invites FOR ALL TO invite_definer
  USING (true) WITH CHECK (true);
CREATE POLICY membership_definer_write ON memberships FOR ALL TO invite_definer
  USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION accept_invite_tx(p_token_hash text, p_user_id uuid)
-- Output columns are prefixed (out_*), NOT org_id/role: PL/pgSQL implicitly
-- declares RETURNS TABLE columns as variables in scope for the whole
-- function body, and org_id/role would then shadow memberships' own
-- columns of the same name inside `ON CONFLICT (user_id, org_id)` below --
-- caught empirically as `AmbiguousColumn`, not a hypothetical.
RETURNS TABLE(status text, out_org_id uuid, out_role text)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
DECLARE
  v_org_id uuid;
  v_role text;
  v_current_role text;
  v_owner_count int;
BEGIN
  UPDATE invites
     SET accepted_at = now()
   WHERE token_hash = p_token_hash
     AND accepted_at IS NULL
     AND expires_at > now()
  RETURNING invites.org_id, invites.role INTO v_org_id, v_role;

  IF v_org_id IS NULL THEN
    RETURN QUERY SELECT 'invalid'::text, NULL::uuid, NULL::text;
    RETURN;
  END IF;

  SELECT m.role INTO v_current_role
    FROM memberships m
   WHERE m.org_id = v_org_id AND m.user_id = p_user_id;

  -- Never let accepting an invite demote the sole remaining owner of an
  -- org -- the same invariant change_role/remove_member enforce. The
  -- invite is still consumed (accepted_at is already set above): a token
  -- that cannot be applied safely is not left lying around to retry,
  -- consistent with this codebase's other single-use tokens.
  IF v_current_role = 'owner' AND v_role <> 'owner' THEN
    SELECT count(*) INTO v_owner_count
      FROM memberships m
     WHERE m.org_id = v_org_id AND m.role = 'owner';
    IF v_owner_count <= 1 THEN
      RETURN QUERY SELECT 'last_owner_conflict'::text, v_org_id, v_current_role;
      RETURN;
    END IF;
  END IF;

  INSERT INTO memberships (user_id, org_id, role)
  VALUES (p_user_id, v_org_id, v_role)
  ON CONFLICT (user_id, org_id) DO UPDATE SET role = EXCLUDED.role;

  RETURN QUERY SELECT 'ok'::text, v_org_id, v_role;
END;
$$;

ALTER FUNCTION accept_invite_tx(text, uuid) OWNER TO invite_definer;
REVOKE ALL ON FUNCTION accept_invite_tx(text, uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION accept_invite_tx(text, uuid) TO authenticated;

-- Give it back -- see 0004's identical REVOKE for why this is not optional.
REVOKE invite_definer FROM CURRENT_USER;
