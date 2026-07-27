-- 0015_ingredient_name_norm.sql — Phase 1c: close 1b's create-ingredient
-- TOCTOU. SQL mirror of api/kernel.py normalize_name; the kernel is the
-- source of truth — change both together or the equivalence test fails.
CREATE OR REPLACE FUNCTION normalize_ingredient_name(name text)
RETURNS text
LANGUAGE sql IMMUTABLE
SET search_path = pg_catalog
AS $$
  SELECT CASE
           WHEN s LIKE '%s' AND s NOT LIKE '%ss' AND length(s) > 3
           THEN left(s, -1)
           ELSE s
         END
  FROM (
    SELECT btrim(regexp_replace(regexp_replace(lower(name), '[^a-z0-9\s]', '', 'g'),
                                '\s+', ' ', 'g')) AS s
  ) x
$$;

-- Live rows only (tombstoned names are reusable); empty normalizations are
-- excluded — the route 400s them, and two all-punctuation names colliding
-- on '' would be nonsense.
CREATE UNIQUE INDEX ingredients_norm_name_live_uq
  ON ingredients (location_id, normalize_ingredient_name(name))
  WHERE deleted_at IS NULL AND normalize_ingredient_name(name) <> '';
