-- The role FastAPI connects as. Deliberately powerless.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user LOGIN PASSWORD 'app_pw' NOINHERIT NOBYPASSRLS NOSUPERUSER;
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'authenticated') THEN
    CREATE ROLE authenticated NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER;
  END IF;
END $$;

-- app_user may become 'authenticated' but inherits nothing by default.
GRANT authenticated TO app_user;

GRANT USAGE ON SCHEMA public, auth TO authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO authenticated;

-- There is deliberately NO grant on auth.users, and adding one is a cross-org
-- data leak. auth.users has no RLS and never gets any -- it is not our table --
-- so a single `GRANT SELECT` on it hands every tenant the full user list:
-- probed through tenant_connection, an Acme owner read both her own address and
-- another tenant's, while `profiles` correctly showed her exactly one row. On
-- real Supabase that table also carries encrypted_password, phone and identity
-- metadata. Nothing needs it: `profiles.contact_email` is the address the
-- application actually uses, and the 0002 foreign keys that REFERENCE
-- auth.users(id) do not require SELECT on it -- referential-integrity checks
-- run with the referenced table's owner rights, not the caller's.
--
-- The grant was also never deployable. On Supabase auth.users is owned by
-- supabase_auth_admin, so this statement would have failed at deploy time; it
-- only ever succeeded here because the local harness runs as a superuser.
-- Either a leak or a broken deploy, never benign. Pinned by
-- test_authenticated_cannot_read_auth_users.

ALTER DEFAULT PRIVILEGES IN SCHEMA public
  GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO authenticated;
