-- ===========================================================================
-- Task 13: sample organisation with fictional distributor names.
--
-- NUMBERING: the plan called this file `0006_sample_org.sql`. Tasks 7, 9, 11
-- and 12 each took a migration number the plan had not budgeted at all --
-- 0005 (email_verification_binding), 0006 (accept_invite_definer), 0007
-- (deletion) and 0008 (org_purge_accessor) are all spoken for; see their own
-- header comments for the full renumbering chain. 0009 is the next free
-- number. Verified against the live migrations directory and against
-- `tests/conftest.py`'s `seeded` fixture, which already caps at `upto=9` in
-- anticipation of this file, rather than assumed from the plan text.
--
-- WHY THIS EXISTS: the legacy demo (product/app.py:254-263) paired invented
-- prices and invented drift percentages with real, trademarked distributors
-- -- Sysco, US Foods, Reinhart Foodservice, Fresh Point Produce, Regalis.
-- That data is live on the public demo site today and would otherwise land
-- in App Store screenshots. Going forward it has to be fictional.
--
-- Separately, App Review needs an account that lands in a populated app
-- rather than an empty one (guideline 4.2, minimum functionality), while an
-- app that is visibly full of placeholder content risks a 2.1 rejection.
-- `is_sample` is what lets a client tell "this is demo data" apart from a
-- real tenant's data without deleting or hiding the seed org. Wiring Task
-- 8's reviewer OTP (a fixed `REVIEWER_USER_ID` read from an env var) to a
-- membership in THIS org is deliberately NOT done here: `REVIEWER_USER_ID`
-- is set per-deployment and does not exist at migration-authoring time, so
-- that membership row is an ops step for whoever provisions the Supabase
-- project (Task 14), pointed at the fixed org id below.
-- ===========================================================================

ALTER TABLE organizations ADD COLUMN is_sample boolean NOT NULL DEFAULT false;

-- ---------------------------------------------------------------------------
-- The FORCE RLS trap, for a third table (see 0007's and 0008's identical
-- warnings about `purge_scheduled_orgs` / `organizations_pending_purge`).
--
-- `organizations` is FORCE ROW LEVEL SECURITY (0004), and FORCE applies to
-- the table's OWNER too, not only to `authenticated`. On real Supabase the
-- migration-running role owns every table it creates via migration and is
-- documented (0007/0008) to be neither a superuser nor BYPASSRLS. A bare
-- `INSERT INTO organizations` here -- the plan's literal text -- has no
-- policy naming that role at all (`organizations` deliberately carries no
-- INSERT policy: 0004 says orgs are "created out of band", and this seed
-- insert is exactly that out-of-band case), so it fails outright with `new
-- row violates row-level security policy for table "organizations"`. Same
-- problem for `locations`: its only policies (`location_select`,
-- `location_write`) are scoped `TO authenticated`, a role the migration
-- runner is not and does not inherit.
--
-- Reproduced directly: a purpose-built NOSUPERUSER NOBYPASSRLS role made the
-- OWNER of real `organizations`/`locations` tables (built the same way
-- 0002/0004/0007 build them) gets exactly that error from the plan's literal
-- INSERT; the version below, run as the same role, does not. Pinned by
-- `test_seed_insert_applies_for_a_non_superuser_owner` in
-- tests/test_sample_org.py, which runs THIS FILE's actual text over such a
-- connection -- this repo's own local harness (`raw_conn`) connects as a
-- genuine Postgres superuser and bypasses RLS regardless of FORCE, so
-- without that dedicated test the failure is invisible here and would only
-- surface on the first real `supabase db push` (Task 14).
--
-- Fixed with the narrowest possible bypass: a policy scoped `TO
-- CURRENT_USER` -- resolved at CREATE POLICY time to whichever specific
-- role is running this migration, never to `authenticated` or `app_user` --
-- created immediately before the inserts and dropped immediately after.
-- Nothing survives past this file: the "no INSERT policy on organizations"
-- invariant 0004 states holds again the moment this migration finishes, and
-- no application-facing role ever gains anything from it.
-- ---------------------------------------------------------------------------
CREATE POLICY organizations_seed_insert ON organizations
  FOR INSERT TO CURRENT_USER WITH CHECK (true);
CREATE POLICY locations_seed_insert ON locations
  FOR INSERT TO CURRENT_USER WITH CHECK (true);

-- Demo organisation. Fixed id so that whatever wires the App Review account
-- (Task 14) has a stable target to point a membership row at. `pro` plan
-- deliberately: a reviewer must see the full feature set, not a
-- starter-tier account with rows hidden behind entitlement limits.
INSERT INTO organizations (id, name, plan, is_sample)
VALUES ('00000000-0000-7000-8000-00000000cafe', 'The Copper Ladle (Sample)', 'pro', true);

INSERT INTO locations (org_id, name, target_fc_pct, drift_threshold_pct)
VALUES ('00000000-0000-7000-8000-00000000cafe', 'Sample Kitchen', 30.00, 5.00);

DROP POLICY organizations_seed_insert ON organizations;
DROP POLICY locations_seed_insert ON locations;

-- Fictional vendor names reserved for the Phase 1b ingredient seed,
-- replacing the real distributors named in the header comment above:
-- Northgate Provisions, Harborline Foods, Cedar Valley Produce, Anchor Dairy
-- Co., Ellsworth Specialty. No `vendors`/`ingredients` table exists yet in
-- Phase 1a -- this is a naming reservation for whichever Phase 1b task adds
-- one, not a seeded row.
