-- supabase/migrations/0013_sample_business_seed.sql
-- ===========================================================================
-- Task 13: sample-org business seed. Demo data for "The Copper Ladle
-- (Sample)" (0009's fixed org `00000000-0000-7000-8000-00000000cafe`).
-- Fictional vendors ONLY (0009's header comment on the legacy demo's real,
-- trademarked distributor names still applies to this data).
--
-- Fixed dates: the drift window anchors on the latest purchase date
-- (2026-07-01), not today, so this demo shows the same numbers forever.
-- Fixed UUIDs (the `00000000-0000-7000-8000-00000000b***` range) so the file
-- is byte-stable and a re-run fails loudly on the PK rather than silently
-- doubling the seed.
--
-- Same FORCE RLS trap as 0009 (see that file's long comment): `ingredients`,
-- `purchases`, `recipes` and `recipe_items` are all FORCE ROW LEVEL SECURITY
-- (0012), which binds the table's OWNER too, and none of the four tables'
-- real policies name the migration-running role. Same fix: a `TO
-- CURRENT_USER` INSERT policy per table, created immediately before the
-- inserts and dropped immediately after -- nothing survives past this file.
--
-- Drift targets (spec'd in the Task 13 brief):
--   Limes:          baseline 10.00/10 (=1.00/each) x3, latest 13.10/10
--                    (=1.31/each) -> (1.31-1.00)/1.00 = +31.0%
--   Chicken Breast:  baseline 32.00/10 (=3.20/lb) x3, latest 36.50/10
--                    (=3.65/lb) -> (3.65-3.20)/3.20 = 0.140625 -> +14.1%
--   Cod Fillet, Cheddar Block, Corn Tortillas: flat -- 4 equal purchases
--   each, no drift.
-- ===========================================================================

CREATE POLICY ingredients_seed_insert ON ingredients
  FOR INSERT TO CURRENT_USER WITH CHECK (true);
CREATE POLICY purchases_seed_insert ON purchases
  FOR INSERT TO CURRENT_USER WITH CHECK (true);
CREATE POLICY recipes_seed_insert ON recipes
  FOR INSERT TO CURRENT_USER WITH CHECK (true);
CREATE POLICY recipe_items_seed_insert ON recipe_items
  FOR INSERT TO CURRENT_USER WITH CHECK (true);

-- ---------------------------------------------------------------------------
-- Ingredients: one per fictional vendor.
-- ---------------------------------------------------------------------------
WITH loc AS (
  SELECT id FROM locations
   WHERE org_id = '00000000-0000-7000-8000-00000000cafe' LIMIT 1
)
INSERT INTO ingredients (id, location_id, name, base_unit, vendor, category, source)
SELECT v.id::uuid, loc.id, v.name, v.base_unit, v.vendor, v.category, 'seed'
FROM loc, (VALUES
  ('00000000-0000-7000-8000-00000000b001', 'Chicken Breast', 'lb',
   'Northgate Provisions', 'Protein'),
  ('00000000-0000-7000-8000-00000000b002', 'Limes', 'each',
   'Cedar Valley Produce', 'Produce'),
  ('00000000-0000-7000-8000-00000000b003', 'Cod Fillet', 'lb',
   'Harborline Foods', 'Protein'),
  ('00000000-0000-7000-8000-00000000b004', 'Cheddar Block', 'lb',
   'Anchor Dairy Co.', 'Dairy'),
  ('00000000-0000-7000-8000-00000000b005', 'Corn Tortillas', 'each',
   'Ellsworth Specialty', 'Bakery')
) AS v(id, name, base_unit, vendor, category);

-- ---------------------------------------------------------------------------
-- Purchases: 5 ingredients x 4 purchases = 20 rows. 3 baseline dates
-- (2026-05-01, 2026-05-15, 2026-06-01) + 1 latest (2026-07-01) per
-- ingredient. qty = qty_base_units (no case packaging in the demo), unit =
-- the ingredient's base_unit, qty_in_case NULL, recorded_at =
-- purchased_on::timestamptz, source = 'seed'. unit_price is GENERATED --
-- never inserted.
-- ---------------------------------------------------------------------------
WITH loc AS (
  SELECT id FROM locations
   WHERE org_id = '00000000-0000-7000-8000-00000000cafe' LIMIT 1
)
INSERT INTO purchases (id, location_id, ingredient_id, purchased_on, recorded_at,
                        qty, unit, qty_in_case, qty_base_units, total_price, source)
SELECT v.id::uuid, loc.id, v.ingredient_id::uuid, v.purchased_on::date,
       v.purchased_on::date::timestamptz, v.qty, v.unit, NULL, v.qty, v.total_price,
       'seed'
FROM loc, (VALUES
  -- Chicken Breast (b001), lb: baseline 32.00/10 x3, latest 36.50/10 (+14.1%)
  ('00000000-0000-7000-8000-00000000b101', '00000000-0000-7000-8000-00000000b001',
   '2026-05-01', 10::numeric, 'lb', 32.00::numeric),
  ('00000000-0000-7000-8000-00000000b102', '00000000-0000-7000-8000-00000000b001',
   '2026-05-15', 10::numeric, 'lb', 32.00::numeric),
  ('00000000-0000-7000-8000-00000000b103', '00000000-0000-7000-8000-00000000b001',
   '2026-06-01', 10::numeric, 'lb', 32.00::numeric),
  ('00000000-0000-7000-8000-00000000b104', '00000000-0000-7000-8000-00000000b001',
   '2026-07-01', 10::numeric, 'lb', 36.50::numeric),

  -- Limes (b002), each: baseline 10.00/10 x3, latest 13.10/10 (+31.0%)
  ('00000000-0000-7000-8000-00000000b105', '00000000-0000-7000-8000-00000000b002',
   '2026-05-01', 10::numeric, 'each', 10.00::numeric),
  ('00000000-0000-7000-8000-00000000b106', '00000000-0000-7000-8000-00000000b002',
   '2026-05-15', 10::numeric, 'each', 10.00::numeric),
  ('00000000-0000-7000-8000-00000000b107', '00000000-0000-7000-8000-00000000b002',
   '2026-06-01', 10::numeric, 'each', 10.00::numeric),
  ('00000000-0000-7000-8000-00000000b108', '00000000-0000-7000-8000-00000000b002',
   '2026-07-01', 10::numeric, 'each', 13.10::numeric),

  -- Cod Fillet (b003), lb: flat, 45.00/10 all 4 dates
  ('00000000-0000-7000-8000-00000000b109', '00000000-0000-7000-8000-00000000b003',
   '2026-05-01', 10::numeric, 'lb', 45.00::numeric),
  ('00000000-0000-7000-8000-00000000b110', '00000000-0000-7000-8000-00000000b003',
   '2026-05-15', 10::numeric, 'lb', 45.00::numeric),
  ('00000000-0000-7000-8000-00000000b111', '00000000-0000-7000-8000-00000000b003',
   '2026-06-01', 10::numeric, 'lb', 45.00::numeric),
  ('00000000-0000-7000-8000-00000000b112', '00000000-0000-7000-8000-00000000b003',
   '2026-07-01', 10::numeric, 'lb', 45.00::numeric),

  -- Cheddar Block (b004), lb: flat, 28.00/10 all 4 dates
  ('00000000-0000-7000-8000-00000000b113', '00000000-0000-7000-8000-00000000b004',
   '2026-05-01', 10::numeric, 'lb', 28.00::numeric),
  ('00000000-0000-7000-8000-00000000b114', '00000000-0000-7000-8000-00000000b004',
   '2026-05-15', 10::numeric, 'lb', 28.00::numeric),
  ('00000000-0000-7000-8000-00000000b115', '00000000-0000-7000-8000-00000000b004',
   '2026-06-01', 10::numeric, 'lb', 28.00::numeric),
  ('00000000-0000-7000-8000-00000000b116', '00000000-0000-7000-8000-00000000b004',
   '2026-07-01', 10::numeric, 'lb', 28.00::numeric),

  -- Corn Tortillas (b005), each: flat, 6.00/50 all 4 dates
  ('00000000-0000-7000-8000-00000000b117', '00000000-0000-7000-8000-00000000b005',
   '2026-05-01', 50::numeric, 'each', 6.00::numeric),
  ('00000000-0000-7000-8000-00000000b118', '00000000-0000-7000-8000-00000000b005',
   '2026-05-15', 50::numeric, 'each', 6.00::numeric),
  ('00000000-0000-7000-8000-00000000b119', '00000000-0000-7000-8000-00000000b005',
   '2026-06-01', 50::numeric, 'each', 6.00::numeric),
  ('00000000-0000-7000-8000-00000000b120', '00000000-0000-7000-8000-00000000b005',
   '2026-07-01', 50::numeric, 'each', 6.00::numeric)
) AS v(id, ingredient_id, purchased_on, qty, unit, total_price);

-- ---------------------------------------------------------------------------
-- Recipes + recipe_items.
-- ---------------------------------------------------------------------------
WITH loc AS (
  SELECT id FROM locations
   WHERE org_id = '00000000-0000-7000-8000-00000000cafe' LIMIT 1
)
INSERT INTO recipes (id, location_id, name, menu_price)
SELECT v.id::uuid, loc.id, v.name, v.menu_price
FROM loc, (VALUES
  ('00000000-0000-7000-8000-00000000b201', 'Margarita Special', 10.00::numeric),
  ('00000000-0000-7000-8000-00000000b202', 'Fish Tacos', 14.00::numeric)
) AS v(id, name, menu_price);

WITH loc AS (
  SELECT id FROM locations
   WHERE org_id = '00000000-0000-7000-8000-00000000cafe' LIMIT 1
)
INSERT INTO recipe_items (id, location_id, recipe_id, ingredient_id, qty_base_units)
SELECT v.id::uuid, loc.id, v.recipe_id::uuid, v.ingredient_id::uuid, v.qty_base_units
FROM loc, (VALUES
  -- Margarita Special (b201): 2.0000 Limes (b002)
  ('00000000-0000-7000-8000-00000000b301', '00000000-0000-7000-8000-00000000b201',
   '00000000-0000-7000-8000-00000000b002', 2.0000::numeric),
  -- Fish Tacos (b202): 0.5000 Cod Fillet (b003), 3.0000 Corn Tortillas (b005),
  -- 1.0000 Limes (b002)
  ('00000000-0000-7000-8000-00000000b302', '00000000-0000-7000-8000-00000000b202',
   '00000000-0000-7000-8000-00000000b003', 0.5000::numeric),
  ('00000000-0000-7000-8000-00000000b303', '00000000-0000-7000-8000-00000000b202',
   '00000000-0000-7000-8000-00000000b005', 3.0000::numeric),
  ('00000000-0000-7000-8000-00000000b304', '00000000-0000-7000-8000-00000000b202',
   '00000000-0000-7000-8000-00000000b002', 1.0000::numeric)
) AS v(id, recipe_id, ingredient_id, qty_base_units);

DROP POLICY ingredients_seed_insert ON ingredients;
DROP POLICY purchases_seed_insert ON purchases;
DROP POLICY recipes_seed_insert ON recipes;
DROP POLICY recipe_items_seed_insert ON recipe_items;
