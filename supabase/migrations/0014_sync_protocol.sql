-- 0014_sync_protocol.sql — Phase 1c: the three-timestamp split (spec §4.2),
-- per-org server_seq allocation (§5.1), monotonic tombstones, future-clock
-- rejection. Local numbering: 0011 stays burned (see 0012's header).
--
-- Why a trigger and not route code: "any invariant enforced only in a route
-- handler is unenforced on the sync path" (spec line 416) — and vice versa.
-- The stamp fires on EVERY insert/update — routes, sync, merge, or a future
-- job — so no path can forget the cursor.

-- ---------------------------------------------------------------------------
-- 1. Columns, nullable first; NOT NULL only after backfill.
-- ---------------------------------------------------------------------------
ALTER TABLE ingredients
  ADD COLUMN client_mutated_at timestamptz,
  ADD COLUMN server_seq bigint,
  ADD COLUMN updated_at timestamptz;
ALTER TABLE purchases
  ADD COLUMN client_mutated_at timestamptz,
  ADD COLUMN server_seq bigint,
  ADD COLUMN updated_at timestamptz;
ALTER TABLE recipes
  ADD COLUMN client_mutated_at timestamptz,
  ADD COLUMN server_seq bigint,
  ADD COLUMN updated_at timestamptz;
ALTER TABLE recipe_items
  ADD COLUMN client_mutated_at timestamptz,
  ADD COLUMN server_seq bigint,
  ADD COLUMN updated_at timestamptz;

-- ---------------------------------------------------------------------------
-- 2. Backfill. Same FORCE-RLS workaround as 0013: the live migration runner
-- is not a superuser and holds no policy on these tables, so temporary
-- CURRENT_USER policies bracket the writes. Seqs are dense per org over
-- (created_at, id) across all four tables; counters land on the max.
-- ---------------------------------------------------------------------------
CREATE POLICY tmp_backfill_ingredients ON ingredients
  FOR ALL TO CURRENT_USER USING (true) WITH CHECK (true);
CREATE POLICY tmp_backfill_purchases ON purchases
  FOR ALL TO CURRENT_USER USING (true) WITH CHECK (true);
CREATE POLICY tmp_backfill_recipes ON recipes
  FOR ALL TO CURRENT_USER USING (true) WITH CHECK (true);
CREATE POLICY tmp_backfill_recipe_items ON recipe_items
  FOR ALL TO CURRENT_USER USING (true) WITH CHECK (true);
CREATE POLICY tmp_backfill_organizations ON organizations
  FOR ALL TO CURRENT_USER USING (true) WITH CHECK (true);
CREATE POLICY tmp_backfill_locations ON locations
  FOR SELECT TO CURRENT_USER USING (true);

DROP TABLE IF EXISTS _seq_backfill;
CREATE TEMP TABLE _seq_backfill AS
SELECT id, tbl, org_id,
       row_number() OVER (PARTITION BY org_id ORDER BY created_at, id) AS seq
FROM (
  SELECT i.id, 'ingredients'::text AS tbl, l.org_id, i.created_at
    FROM ingredients i JOIN locations l ON l.id = i.location_id
  UNION ALL
  SELECT r.id, 'recipes', l.org_id, r.created_at
    FROM recipes r JOIN locations l ON l.id = r.location_id
  UNION ALL
  SELECT ri.id, 'recipe_items', l.org_id, ri.created_at
    FROM recipe_items ri JOIN locations l ON l.id = ri.location_id
  UNION ALL
  SELECT p.id, 'purchases', l.org_id, p.created_at
    FROM purchases p JOIN locations l ON l.id = p.location_id
) all_rows;

UPDATE ingredients t
   SET server_seq = b.seq, client_mutated_at = t.created_at, updated_at = t.created_at
  FROM _seq_backfill b WHERE b.tbl = 'ingredients' AND b.id = t.id;
UPDATE purchases t
   SET server_seq = b.seq, client_mutated_at = t.created_at, updated_at = t.created_at
  FROM _seq_backfill b WHERE b.tbl = 'purchases' AND b.id = t.id;
UPDATE recipes t
   SET server_seq = b.seq, client_mutated_at = t.created_at, updated_at = t.created_at
  FROM _seq_backfill b WHERE b.tbl = 'recipes' AND b.id = t.id;
UPDATE recipe_items t
   SET server_seq = b.seq, client_mutated_at = t.created_at, updated_at = t.created_at
  FROM _seq_backfill b WHERE b.tbl = 'recipe_items' AND b.id = t.id;

UPDATE organizations o SET sync_counter = coalesce(
  (SELECT max(b.seq) FROM _seq_backfill b WHERE b.org_id = o.id), 0);

DROP TABLE _seq_backfill;
DROP POLICY tmp_backfill_ingredients ON ingredients;
DROP POLICY tmp_backfill_purchases ON purchases;
DROP POLICY tmp_backfill_recipes ON recipes;
DROP POLICY tmp_backfill_recipe_items ON recipe_items;
DROP POLICY tmp_backfill_organizations ON organizations;
DROP POLICY tmp_backfill_locations ON locations;

-- ---------------------------------------------------------------------------
-- 3. NOT NULL + defaults. client_mutated_at DEFAULT now(): a route write IS
-- the device write (the API caller's clock is this server's clock); sync
-- always sends an explicit value. updated_at is display-only (§4.2) and
-- server-stamped by the trigger on every write.
-- ---------------------------------------------------------------------------
ALTER TABLE ingredients
  ALTER COLUMN client_mutated_at SET NOT NULL,
  ALTER COLUMN client_mutated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN server_seq SET NOT NULL;
ALTER TABLE purchases
  ALTER COLUMN client_mutated_at SET NOT NULL,
  ALTER COLUMN client_mutated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN server_seq SET NOT NULL;
ALTER TABLE recipes
  ALTER COLUMN client_mutated_at SET NOT NULL,
  ALTER COLUMN client_mutated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN server_seq SET NOT NULL;
ALTER TABLE recipe_items
  ALTER COLUMN client_mutated_at SET NOT NULL,
  ALTER COLUMN client_mutated_at SET DEFAULT now(),
  ALTER COLUMN updated_at SET NOT NULL,
  ALTER COLUMN updated_at SET DEFAULT now(),
  ALTER COLUMN server_seq SET NOT NULL;

CREATE INDEX ingredients_server_seq_idx ON ingredients (server_seq);
CREATE INDEX purchases_server_seq_idx ON purchases (server_seq);
CREATE INDEX recipes_server_seq_idx ON recipes (server_seq);
CREATE INDEX recipe_items_server_seq_idx ON recipe_items (server_seq);

-- ---------------------------------------------------------------------------
-- 4. sync_definer + the stamp trigger. Same GRANT/REVOKE bracket as 0012
-- (membership live while CREATE TRIGGER checks EXECUTE; REVOKE comes LAST).
-- The single-statement UPDATE ... RETURNING takes the org row lock, which
-- serializes allocation with commit order by construction (§5.1) — the
-- FOR UPDATE the spec sketches is subsumed by the row lock the UPDATE takes.
-- ---------------------------------------------------------------------------
DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'sync_definer') THEN
    CREATE ROLE sync_definer NOLOGIN NOINHERIT NOBYPASSRLS NOSUPERUSER;
  END IF;
END
$$;
GRANT sync_definer TO CURRENT_USER;

GRANT USAGE ON SCHEMA public TO sync_definer;
GRANT SELECT ON locations TO sync_definer;
CREATE POLICY location_sync_definer_read ON locations
  FOR SELECT TO sync_definer USING (true);
GRANT SELECT, UPDATE ON organizations TO sync_definer;
CREATE POLICY org_sync_definer_read ON organizations
  FOR SELECT TO sync_definer USING (true);
CREATE POLICY org_sync_definer_update ON organizations
  FOR UPDATE TO sync_definer USING (true) WITH CHECK (true);

CREATE OR REPLACE FUNCTION sync_row_stamp()
RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER
SET search_path = pg_catalog, public, pg_temp
AS $$
DECLARE
  _seq bigint;
BEGIN
  -- §4.2: the server rejects device clocks more than 5 minutes ahead.
  IF NEW.client_mutated_at > now() + interval '5 minutes' THEN
    RAISE EXCEPTION 'client_mutated_at % is more than 5 minutes in the future',
      NEW.client_mutated_at USING ERRCODE = 'CS425';
  END IF;
  -- §4.2: tombstones are monotonic — NULL -> timestamp only, never back,
  -- never re-stamped. (Editing other fields of a tombstoned row is refused
  -- at the service layer, not here: the merge endpoint legitimately updates
  -- rows adjacent to tombstoning.)
  IF TG_OP = 'UPDATE' AND OLD.deleted_at IS NOT NULL
     AND NEW.deleted_at IS DISTINCT FROM OLD.deleted_at THEN
    RAISE EXCEPTION 'tombstones are monotonic; row % cannot be undeleted or re-stamped',
      OLD.id USING ERRCODE = 'CS423';
  END IF;
  UPDATE public.organizations o SET sync_counter = o.sync_counter + 1
   WHERE o.id = (SELECT l.org_id FROM public.locations l WHERE l.id = NEW.location_id)
   RETURNING o.sync_counter INTO _seq;
  IF _seq IS NULL THEN
    RAISE EXCEPTION 'no organization found for location %', NEW.location_id;
  END IF;
  NEW.server_seq := _seq;
  NEW.updated_at := now();
  RETURN NEW;
END;
$$;
ALTER FUNCTION sync_row_stamp() OWNER TO sync_definer;
REVOKE ALL ON FUNCTION sync_row_stamp() FROM PUBLIC;

-- Named *_sync_stamp so they sort AFTER *_reject_scheduled ('r' < 's'):
-- a scheduled org's write dies on CS410 before the counter is ever bumped.
CREATE TRIGGER ingredients_sync_stamp
  BEFORE INSERT OR UPDATE ON ingredients
  FOR EACH ROW EXECUTE FUNCTION sync_row_stamp();
CREATE TRIGGER purchases_sync_stamp
  BEFORE INSERT OR UPDATE ON purchases
  FOR EACH ROW EXECUTE FUNCTION sync_row_stamp();
CREATE TRIGGER recipes_sync_stamp
  BEFORE INSERT OR UPDATE ON recipes
  FOR EACH ROW EXECUTE FUNCTION sync_row_stamp();
CREATE TRIGGER recipe_items_sync_stamp
  BEFORE INSERT OR UPDATE ON recipe_items
  FOR EACH ROW EXECUTE FUNCTION sync_row_stamp();

REVOKE sync_definer FROM CURRENT_USER;
