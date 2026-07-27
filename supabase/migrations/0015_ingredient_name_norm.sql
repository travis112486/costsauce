-- 0015_ingredient_name_norm.sql — Phase 1c: close 1b's create-ingredient
-- TOCTOU. SQL mirror of api/kernel.py normalize_name; the kernel is the
-- source of truth — change both together or the equivalence test fails.
--
-- Locale/collation assumption (review round 1, Important-2): lower() below
-- is NOT locale-independent -- it folds case according to the database's
-- LC_CTYPE. This function assumes an en_US/C-family LC_CTYPE, which is
-- Supabase's default. A Turkish-locale ("tr_TR") LC_CTYPE would fold 'I' to
-- dotless 'ı' instead of 'i', diverging from Python's str.lower() (which is
-- locale-independent Unicode casefolding) on any name containing an 'I'.
-- The deploy runbook (Task 13) must verify `SHOW lc_ctype;` and
-- `SELECT datcollate FROM pg_database WHERE datname = current_database();`
-- report an en_US/C-family locale before this migration is applied.
--
-- Separately, Postgres's ARE regex \s in [^a-z0-9\s] and \s+ matches only
-- ASCII whitespace (space, tab, newline, CR, VT, FF); Python's re \s on a
-- str pattern matches the broader Unicode whitespace class (e.g. NBSP
-- U+00A0, en/em space). A name containing one of those non-ASCII
-- whitespace code points normalizes differently between this function and
-- api.kernel.normalize_name: Postgres treats it as an ordinary character
-- (stripped by the [^a-z0-9\s] pass, since it isn't in a-z0-9 either, but
-- NOT collapsed by the \s+ pass the way an ASCII space would be), while
-- Python's \s+ collapses/trims it as whitespace. In practice this is
-- covered by the equivalence test battery, not by a schema constraint --
-- there is no known real-world ingredient name relying on NBSP-class
-- whitespace, but it remains a residual divergence to be aware of.
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
