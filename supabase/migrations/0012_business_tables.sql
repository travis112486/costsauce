-- supabase/migrations/0012_business_tables.sql
-- ===========================================================================
-- Phase 1b: the business tables the engine port runs on.
--
-- NUMBERING: this file is 0012, not 0011. The live project already carries a
-- migration labelled 0011_revoke_rpc_exposure_as_grantor (the second half of
-- local 0010, applied as two files during the 2026-07-26 deploy). Local
-- numbering skips 0011 so the labels never collide.
--
-- Money contract (spec §8): numeric everywhere, unit_price GENERATED — the
-- three-way rounding drift of the demo (qty, total, unit_price each rounded
-- independently) is structurally impossible here.
--
-- No sync columns yet (client_mutated_at / server_seq are Phase 1c).
-- deleted_at tombstones land now: drift selection and merge need them.
-- ===========================================================================

CREATE TABLE ingredients (
  id          uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  location_id uuid NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  name        text NOT NULL CHECK (length(trim(name)) > 0),
  base_unit   text NOT NULL CHECK (base_unit IN ('lb','oz','kg','g','each')),
  vendor      text,
  category    text,
  source      text NOT NULL DEFAULT 'manual'
                CHECK (source IN ('manual','seed','import')),
  deleted_at  timestamptz,
  created_at  timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX ingredients_location_idx ON ingredients (location_id);

CREATE TABLE purchases (
  id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  location_id    uuid NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  -- CASCADE on ingredient_id too: the org purge deletes locations, which
  -- cascades into ingredients AND purchases concurrently; a RESTRICT here
  -- would make the cascade order-dependent.
  ingredient_id  uuid NOT NULL REFERENCES ingredients(id) ON DELETE CASCADE,
  purchased_on   date NOT NULL,
  recorded_at    timestamptz NOT NULL DEFAULT now(),
  qty            numeric(14,4) NOT NULL CHECK (qty > 0),
  unit           text NOT NULL,
  qty_in_case    numeric(14,4) CHECK (qty_in_case IS NULL OR qty_in_case > 0),
  qty_base_units numeric(14,4) NOT NULL CHECK (qty_base_units > 0),
  total_price    numeric(12,2) NOT NULL CHECK (total_price > 0),
  -- round() is numeric round-half-away-from-zero: the one rounding mode the
  -- whole kernel contract pins. The column cannot drift from total/qty.
  unit_price     numeric(14,6) GENERATED ALWAYS AS
                   (round(total_price / qty_base_units, 6)) STORED,
  source         text NOT NULL DEFAULT 'manual'
                   CHECK (source IN ('manual','seed','import')),
  deleted_at     timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);
-- The ordering rule, as an index, live rows only.
CREATE INDEX purchases_drift_idx ON purchases
  (ingredient_id, purchased_on DESC, recorded_at DESC, id DESC)
  WHERE deleted_at IS NULL;
CREATE INDEX purchases_location_idx ON purchases (location_id);

CREATE TABLE recipes (
  id            uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  location_id   uuid NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  name          text NOT NULL CHECK (length(trim(name)) > 0),
  menu_price    numeric(10,2) NOT NULL CHECK (menu_price > 0),
  target_fc_pct numeric(5,2) NOT NULL DEFAULT 30.00 CHECK (target_fc_pct > 0),
  deleted_at    timestamptz,
  created_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX recipes_location_idx ON recipes (location_id);

CREATE TABLE recipe_items (
  id             uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  location_id    uuid NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  recipe_id      uuid NOT NULL REFERENCES recipes(id) ON DELETE CASCADE,
  ingredient_id  uuid NOT NULL REFERENCES ingredients(id) ON DELETE CASCADE,
  qty_base_units numeric(14,4) NOT NULL CHECK (qty_base_units > 0),
  deleted_at     timestamptz,
  created_at     timestamptz NOT NULL DEFAULT now()
);
-- Spec §5.4's UNIQUE (recipe_id, ingredient_id), partial over live rows so a
-- tombstoned line does not block re-adding the ingredient. Phase 1c's sync
-- upsert will target this index with ON CONFLICT ... WHERE deleted_at IS NULL.
CREATE UNIQUE INDEX recipe_items_live_uq
  ON recipe_items (recipe_id, ingredient_id) WHERE deleted_at IS NULL;
CREATE INDEX recipe_items_recipe_idx ON recipe_items (recipe_id);
CREATE INDEX recipe_items_ingredient_idx ON recipe_items (ingredient_id);

-- FORCE now, policies appended by the next task: between the two,
-- authenticated sees nothing rather than everything, and pg_class-walking
-- tests stay green.
ALTER TABLE ingredients  ENABLE ROW LEVEL SECURITY;
ALTER TABLE ingredients  FORCE  ROW LEVEL SECURITY;
ALTER TABLE purchases    ENABLE ROW LEVEL SECURITY;
ALTER TABLE purchases    FORCE  ROW LEVEL SECURITY;
ALTER TABLE recipes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE recipes      FORCE  ROW LEVEL SECURITY;
ALTER TABLE recipe_items ENABLE ROW LEVEL SECURITY;
ALTER TABLE recipe_items FORCE  ROW LEVEL SECURITY;

-- Explicit rather than relying on 0003's ALTER DEFAULT PRIVILEGES (which
-- only binds to the role that issued it — 1a runbook §12.7). No DELETE: the
-- app tombstones; hard deletes belong to the purge cascade alone.
GRANT SELECT, INSERT, UPDATE ON ingredients, purchases, recipes, recipe_items
  TO authenticated;

-- The GRANT above is S/I/U only, but that alone does not withhold DELETE:
-- 0003's `ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT ... DELETE ... TO
-- authenticated` binds to the ROLE that issued it, not to a point in time,
-- so any table later created BY THAT SAME ROLE -- which is exactly what
-- happens here, since every migration in this deploy runs as the one
-- migration-runner role -- inherits DELETE automatically regardless of what
-- this file's own GRANT does or does not list. Proven by
-- `test_delete_is_not_granted`: without this REVOKE, `ingredient_write`'s
-- `FOR ALL` policy has a USING clause wide enough to pass a same-org DELETE,
-- and the row is gone. Explicit REVOKE is the only way to actually withhold
-- it, matching the comment above ("No DELETE: the app tombstones").
REVOKE DELETE ON ingredients, purchases, recipes, recipe_items FROM authenticated;

-- ---------------------------------------------------------------------------
-- Policies. Tenancy path is location_id -> locations.org_id -> memberships.
-- The locations subquery expands locations' own policies (which read
-- memberships via the 0004 definer function) — no recursion: nothing here
-- reads the table it is defined on.
--
-- Write shape: ingredients/purchases writable by every role (entering
-- deliveries is the bookkeeper's whole job); recipes/recipe_items are
-- owner/manager only (menu pricing is management). All members read.
-- ---------------------------------------------------------------------------
CREATE POLICY ingredient_select ON ingredients FOR SELECT TO authenticated USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);
CREATE POLICY ingredient_write ON ingredients FOR ALL TO authenticated
USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
)
WITH CHECK (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);

CREATE POLICY purchase_select ON purchases FOR SELECT TO authenticated USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);
CREATE POLICY purchase_write ON purchases FOR ALL TO authenticated
USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
)
WITH CHECK (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);

CREATE POLICY recipe_select ON recipes FOR SELECT TO authenticated USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);
CREATE POLICY recipe_write ON recipes FOR ALL TO authenticated
USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()
                                     WHERE role IN ('owner','manager')))
)
WITH CHECK (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()
                                     WHERE role IN ('owner','manager')))
);

CREATE POLICY recipe_item_select ON recipe_items FOR SELECT TO authenticated USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);
CREATE POLICY recipe_item_write ON recipe_items FOR ALL TO authenticated
USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()
                                     WHERE role IN ('owner','manager')))
)
WITH CHECK (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()
                                     WHERE role IN ('owner','manager')))
);

-- ---------------------------------------------------------------------------
-- Scheduled-org write freeze for location_id-keyed tables. 0007's trigger
-- keys on NEW.org_id, which these tables do not carry; this variant joins
-- through locations. Same definer role, same CS410 SQLSTATE that api/main.py
-- already maps to HTTP 410. Same GRANT/REVOKE bracket as 0007. 0007 already
-- gives deletion_definer its organizations read; only the locations read is
-- new here. (Check 0007 before finalizing; drop any line it already covers.)
--
-- The REVOKE deliberately comes LAST, after the four CREATE TRIGGER
-- statements below, not right after the function is defined. PostgreSQL
-- checks EXECUTE on a trigger's function at CREATE TRIGGER time, and the
-- function is deletion_definer-owned with EXECUTE revoked from PUBLIC -- so
-- a non-superuser migration runner (Supabase's `postgres`) still needs its
-- membership in deletion_definer to be live when each CREATE TRIGGER runs.
-- Revoking the membership any earlier makes all four CREATE TRIGGER
-- statements fail with "permission denied for function". 0007 has this
-- exact shape already (its triggers precede its own REVOKE, see that file's
-- comments near the role bootstrap and its closing REVOKE): this file now
-- matches it.
-- ---------------------------------------------------------------------------
GRANT deletion_definer TO CURRENT_USER;

GRANT SELECT ON locations TO deletion_definer;
CREATE POLICY location_deletion_definer_read ON locations
  FOR SELECT TO deletion_definer USING (true);

CREATE OR REPLACE FUNCTION reject_write_to_scheduled_org_location()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
-- pg_temp LAST and every reference schema-qualified — same reasoning as 0006.
SET search_path = pg_catalog, public, pg_temp
AS $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.organizations o
    JOIN public.locations l ON l.org_id = o.id
    WHERE l.id = NEW.location_id AND o.deletion_scheduled_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'organization for location % is scheduled for deletion',
      NEW.location_id USING ERRCODE = 'CS410';
  END IF;
  RETURN NEW;
END;
$$;
ALTER FUNCTION reject_write_to_scheduled_org_location() OWNER TO deletion_definer;
REVOKE ALL ON FUNCTION reject_write_to_scheduled_org_location() FROM PUBLIC;

CREATE TRIGGER ingredients_reject_scheduled
  BEFORE INSERT OR UPDATE ON ingredients
  FOR EACH ROW EXECUTE FUNCTION reject_write_to_scheduled_org_location();
CREATE TRIGGER purchases_reject_scheduled
  BEFORE INSERT OR UPDATE ON purchases
  FOR EACH ROW EXECUTE FUNCTION reject_write_to_scheduled_org_location();
CREATE TRIGGER recipes_reject_scheduled
  BEFORE INSERT OR UPDATE ON recipes
  FOR EACH ROW EXECUTE FUNCTION reject_write_to_scheduled_org_location();
CREATE TRIGGER recipe_items_reject_scheduled
  BEFORE INSERT OR UPDATE ON recipe_items
  FOR EACH ROW EXECUTE FUNCTION reject_write_to_scheduled_org_location();

REVOKE deletion_definer FROM CURRENT_USER;
