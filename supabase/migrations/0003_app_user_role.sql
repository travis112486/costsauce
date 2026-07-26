-- The role FastAPI connects as. Deliberately powerless.
--
-- Task 14 credential fix: this file used to read
-- `CREATE ROLE app_user LOGIN PASSWORD 'app_pw' ...`. That literal is
-- committed to git, so applying this migration verbatim to Supabase would
-- make 'app_pw' the PRODUCTION password for the role the API server
-- authenticates as -- readable by anyone who has ever cloned this
-- repository. Two options considered and rejected: (1) a GUC/env-driven
-- placeholder the runner substitutes -- rejected because nothing in this
-- codebase's migration path does text substitution before executing a
-- file (`tests/conftest.py`'s `apply_migrations` and Supabase's own
-- `apply_migration` both send the file's bytes verbatim), so building that
-- would be new untested infrastructure solely to smuggle a secret through a
-- public file; (2) splitting CREATE ROLE from a same-file ALTER ROLE ...
-- PASSWORD -- rejected because the password would still have to be a
-- literal in a committed file, which is the exact defect being fixed, not
-- a different file for it to live in.
--
-- Chosen instead: `app_user` is created NOLOGIN. It exists and (via the
-- GRANT below) may become `authenticated`, but cannot authenticate AT ALL --
-- with any password, known or not -- until an operator deliberately enables
-- login out of band, against the running database directly, never through a
-- file this repository tracks:
--
--     ALTER ROLE app_user WITH LOGIN PASSWORD '<a freshly generated secret>';
--
-- then puts the resulting connection string in `DATABASE_URL`. See
-- docs/runbooks/phase-1a-deploy.md for the full step. This makes it
-- structurally impossible to accidentally deploy a known password: there is
-- no password for this migration to deploy, known or otherwise, and the
-- role is inert until someone takes the deliberate, separate, unversioned
-- step above.
--
-- The local test harness performs the disposable-container equivalent of
-- that same operator step itself, immediately after every call to
-- `apply_migrations` (tests/conftest.py) -- not here, so this file reads
-- identically in every environment and a literal password never has a
-- chance to reach git again.
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'app_user') THEN
    CREATE ROLE app_user NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER;
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
