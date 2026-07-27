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
