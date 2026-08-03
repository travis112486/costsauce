-- Phase 3a: invoice capture. invoice_line_items is deliberately NOT created
-- here -- nothing in 3a reads or writes it, and shipping an unexercised
-- table is how schemas rot (spec 3a-D3).

CREATE TABLE invoices (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  location_id       uuid NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  captured_at       timestamptz NOT NULL,
  -- Only the two values 3a can actually produce. 3b widens this alongside
  -- the parser that can set the rest: a value no code path reaches is a
  -- value nothing tests.
  parse_status      text NOT NULL DEFAULT 'unparsed'
                      CHECK (parse_status IN ('unparsed','failed')),
  client_mutated_at timestamptz NOT NULL,
  server_seq        bigint,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE invoice_pages (
  id                uuid PRIMARY KEY DEFAULT uuid_generate_v7(),
  invoice_id        uuid NOT NULL REFERENCES invoices(id) ON DELETE CASCADE,
  location_id       uuid NOT NULL REFERENCES locations(id) ON DELETE CASCADE,
  page_no           int NOT NULL CHECK (page_no > 0),
  storage_path      text NOT NULL,
  width             int CHECK (width IS NULL OR width > 0),
  height            int CHECK (height IS NULL OR height > 0),
  sha256            text,
  client_mutated_at timestamptz NOT NULL,
  server_seq        bigint,
  updated_at        timestamptz NOT NULL DEFAULT now(),
  deleted_at        timestamptz,
  created_at        timestamptz NOT NULL DEFAULT now()
);

-- Live-only, exactly like recipe_items_live_uq: a retake tombstones its
-- predecessor and reuses the same page_no.
CREATE UNIQUE INDEX invoice_pages_live_uq
  ON invoice_pages (invoice_id, page_no) WHERE deleted_at IS NULL;

CREATE INDEX invoices_location_seq ON invoices (location_id, server_seq);
CREATE INDEX invoice_pages_location_seq ON invoice_pages (location_id, server_seq);
CREATE INDEX invoice_pages_invoice_deleted_idx
  ON invoice_pages (invoice_id, deleted_at);

-- SET NULL, not CASCADE: deleting the photograph must not delete the cost.
ALTER TABLE purchases
  ADD COLUMN invoice_page_id uuid REFERENCES invoice_pages(id) ON DELETE SET NULL;

-- ENABLE *and* FORCE, both, on each. Without FORCE the owner bypasses every
-- policy below; and a new tenant table inherits full DML for `authenticated`
-- from 0003's ALTER DEFAULT PRIVILEGES, so until both flags are set it is
-- readable and writable by every tenant regardless of the policies.
-- tests/test_rls_cross_org.py enforces this for every table in `public`.
ALTER TABLE invoices ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices FORCE ROW LEVEL SECURITY;
ALTER TABLE invoice_pages ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoice_pages FORCE ROW LEVEL SECURITY;

-- Shaped after purchases, NOT recipes: capture is data entry, so every
-- member of the org may do it, bookkeepers included. Gating it to
-- owner/manager would stop the person receiving the delivery from
-- photographing it.
CREATE POLICY invoice_select ON invoices FOR SELECT TO authenticated USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);
CREATE POLICY invoice_write ON invoices FOR ALL TO authenticated
USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
)
WITH CHECK (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);

CREATE POLICY invoice_page_select ON invoice_pages FOR SELECT TO authenticated USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);
CREATE POLICY invoice_page_write ON invoice_pages FOR ALL TO authenticated
USING (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
)
WITH CHECK (
  location_id IN (SELECT l.id FROM locations l
                  WHERE l.org_id IN (SELECT org_id FROM current_user_memberships()))
);
