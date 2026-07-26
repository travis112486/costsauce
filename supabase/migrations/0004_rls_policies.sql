-- ===========================================================================
-- Row-Level Security.
--
-- Two things in here are not in the original plan text, both forced by
-- PostgreSQL semantics. See the block comment above section 3.
-- ===========================================================================

-- ---------------------------------------------------------------------------
-- 1. Claim helpers.
--
-- `request.jwt.claims` is client-derived, so every one of these must fail
-- CLOSED: absent, blank, non-JSON, or non-UUID input returns NULL rather than
-- raising. A policy helper that raises turns a malformed token into a 500 on
-- every query -- a denial-of-service lever handed to the caller -- whereas
-- NULL simply makes every comparison in every policy evaluate to NULL, which
-- is never true, so the caller sees nothing and can write nothing.
-- ---------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION current_jwt_sub() RETURNS text
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog
AS $$
DECLARE
  raw text := current_setting('request.jwt.claims', true);
BEGIN
  IF raw IS NULL OR raw = '' THEN
    RETURN NULL;
  END IF;
  RETURN nullif(raw::jsonb ->> 'sub', '');
EXCEPTION WHEN invalid_text_representation THEN  -- claims were not valid JSON
  RETURN NULL;
END;
$$;

CREATE OR REPLACE FUNCTION current_user_id() RETURNS uuid
LANGUAGE plpgsql STABLE
SET search_path = pg_catalog, public
AS $$
BEGIN
  RETURN current_jwt_sub()::uuid;
EXCEPTION WHEN invalid_text_representation THEN  -- sub was not a UUID
  RETURN NULL;
END;
$$;

-- ---------------------------------------------------------------------------
-- 2. Enable and FORCE row security on all seven tenant tables.
--
-- FORCE is not optional. Migrations run as the table owner, and an owner
-- bypasses its own table's policies unless FORCE is set.
-- ---------------------------------------------------------------------------
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

-- ---------------------------------------------------------------------------
-- 3. The membership lookup, and why it cannot be a plain subquery.
--
-- Every tenant policy has to answer "which orgs does the caller belong to?",
-- and the only server-side answer is the `memberships` table. But `memberships`
-- is itself a tenant table under FORCE RLS, so a policy ON memberships that
-- SELECTs FROM memberships makes PostgreSQL expand memberships' policies while
-- already expanding them:
--
--     ERROR:  infinite recursion detected in policy for relation "memberships"
--
-- That error is raised structurally at rewrite time, so it fires on the very
-- first query against ANY of these tables, not just against memberships. It
-- cannot be dodged by narrowing the predicate, by routing through
-- `organizations` (mutual recursion is detected the same way), or by splitting
-- SELECT out of the FOR ALL policy (a FOR ALL policy's USING clause applies to
-- SELECT too).
--
-- The loop has to be broken by a read of `memberships` that is not itself
-- policy-filtered. Under FORCE RLS the only role exempt from a table's
-- policies is one the policies do not name, so:
--
--   * `rls_definer` is a NOLOGIN role that exists solely to own the lookup
--     function. Nothing can connect as it; it is reachable only by calling
--     that one SECURITY DEFINER function.
--   * `membership_definer_read` is the only policy `rls_definer` can see, and
--     it contains no subquery, so there is nothing left to recurse into.
--   * Every application policy below is scoped `TO authenticated` so that it
--     does NOT apply to `rls_definer` -- otherwise the recursion returns, at
--     runtime instead of at plan time.
--
-- The function is deliberately the narrowest possible bypass: one table, one
-- WHERE clause pinned to current_user_id(), no arguments a caller can steer.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'rls_definer') THEN
    CREATE ROLE rls_definer NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER;
  END IF;
END $$;

-- Lets the migration runner reassign ownership below even when it is not a
-- superuser (it is not, on Supabase).
GRANT rls_definer TO CURRENT_USER;

GRANT USAGE  ON SCHEMA public  TO rls_definer;
GRANT SELECT ON memberships    TO rls_definer;

CREATE POLICY membership_definer_read ON memberships
  FOR SELECT TO rls_definer USING (true);

CREATE OR REPLACE FUNCTION current_user_memberships()
RETURNS TABLE (org_id uuid, role text)
LANGUAGE sql STABLE SECURITY DEFINER
SET search_path = pg_catalog, public
AS $$
  SELECT m.org_id, m.role
    FROM public.memberships m
   WHERE m.user_id = public.current_user_id()
$$;
ALTER FUNCTION current_user_memberships() OWNER TO rls_definer;
REVOKE ALL   ON FUNCTION current_user_memberships() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION current_user_memberships() TO authenticated;

-- ---------------------------------------------------------------------------
-- 4. Policies. Every one carries WITH CHECK as well as USING: USING decides
--    which rows the caller may see or target, WITH CHECK decides which rows
--    the caller may leave behind. USING alone lets a caller INSERT or UPDATE a
--    row into somebody else's org.
--
--    Roles are exactly: owner, manager, bookkeeper.
-- ---------------------------------------------------------------------------

-- organizations: visible to members; mutable by owners. There is no INSERT
-- policy by design -- orgs are created out of band (signup, sample seeding).
CREATE POLICY org_select ON organizations FOR SELECT TO authenticated USING (
  id IN (SELECT org_id FROM current_user_memberships())
);
CREATE POLICY org_update ON organizations FOR UPDATE TO authenticated
USING (
  id IN (SELECT org_id FROM current_user_memberships() WHERE role = 'owner')
)
WITH CHECK (
  id IN (SELECT org_id FROM current_user_memberships() WHERE role = 'owner')
);

-- memberships: a caller sees every membership of any org they belong to,
-- and only an owner may add, change, or remove one.
CREATE POLICY membership_select ON memberships FOR SELECT TO authenticated USING (
  org_id IN (SELECT org_id FROM current_user_memberships())
);
CREATE POLICY membership_write ON memberships FOR ALL TO authenticated
USING (
  org_id IN (SELECT org_id FROM current_user_memberships() WHERE role = 'owner')
)
WITH CHECK (
  org_id IN (SELECT org_id FROM current_user_memberships() WHERE role = 'owner')
);

-- locations: WITH CHECK is what stops a caller writing a row into another org.
CREATE POLICY location_select ON locations FOR SELECT TO authenticated USING (
  org_id IN (SELECT org_id FROM current_user_memberships())
);
CREATE POLICY location_write ON locations FOR ALL TO authenticated
USING (
  org_id IN (SELECT org_id FROM current_user_memberships()
             WHERE role IN ('owner', 'manager'))
)
WITH CHECK (
  org_id IN (SELECT org_id FROM current_user_memberships()
             WHERE role IN ('owner', 'manager'))
);

CREATE POLICY invite_all ON invites FOR ALL TO authenticated
USING (
  org_id IN (SELECT org_id FROM current_user_memberships() WHERE role = 'owner')
)
WITH CHECK (
  org_id IN (SELECT org_id FROM current_user_memberships() WHERE role = 'owner')
);

CREATE POLICY profile_self ON profiles FOR ALL TO authenticated
USING (user_id = current_user_id()) WITH CHECK (user_id = current_user_id());

CREATE POLICY email_verification_self ON email_verifications FOR ALL TO authenticated
USING (user_id = current_user_id()) WITH CHECK (user_id = current_user_id());

-- apple_link_requests.apple_sub holds the caller's own subject identifier
-- (api/routes writes caller.user_id into it), so the caller's `sub` claim is
-- the correct key. Compared as text, via the same fail-closed helper.
CREATE POLICY apple_link_self ON apple_link_requests FOR ALL TO authenticated
USING (apple_sub = current_jwt_sub()) WITH CHECK (apple_sub = current_jwt_sub());
