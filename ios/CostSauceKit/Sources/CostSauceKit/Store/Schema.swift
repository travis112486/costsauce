// The CostSauce local store — GRDB schema.
//
// One migration, "v1": four tables mirroring the syncable server tables
// (ingredients, recipes, recipe_items, purchases — columns exactly match
// the `_PULL` field lists, see Records.swift), plus two local-only
// tables: `pending_ops` (the outbox) and `meta` (identity + cursor,
// single row at rowid 1). Every synced column is TEXT except
// `server_seq`, which is INTEGER — money/decimals/timestamps all cross
// this boundary as verbatim strings (see Records.swift's header comment).

import GRDB

enum Schema {
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1") { db in
            try db.execute(sql: """
                CREATE TABLE ingredients (
                    id TEXT PRIMARY KEY,
                    location_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    base_unit TEXT NOT NULL,
                    vendor TEXT,
                    category TEXT,
                    source TEXT,
                    client_mutated_at TEXT NOT NULL,
                    server_seq INTEGER NOT NULL,
                    updated_at TEXT NOT NULL,
                    deleted_at TEXT,
                    created_at TEXT NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE recipes (
                    id TEXT PRIMARY KEY,
                    location_id TEXT NOT NULL,
                    name TEXT NOT NULL,
                    menu_price TEXT NOT NULL,
                    target_fc_pct TEXT NOT NULL,
                    client_mutated_at TEXT NOT NULL,
                    server_seq INTEGER NOT NULL,
                    updated_at TEXT NOT NULL,
                    deleted_at TEXT,
                    created_at TEXT NOT NULL
                )
                """)

            try db.execute(sql: """
                CREATE TABLE recipe_items (
                    id TEXT PRIMARY KEY,
                    location_id TEXT NOT NULL,
                    recipe_id TEXT NOT NULL,
                    ingredient_id TEXT NOT NULL,
                    qty_base_units TEXT NOT NULL,
                    client_mutated_at TEXT NOT NULL,
                    server_seq INTEGER NOT NULL,
                    updated_at TEXT NOT NULL,
                    deleted_at TEXT,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX recipe_items_ingredient_deleted_idx
                    ON recipe_items(ingredient_id, deleted_at)
                """)

            try db.execute(sql: """
                CREATE TABLE purchases (
                    id TEXT PRIMARY KEY,
                    location_id TEXT NOT NULL,
                    ingredient_id TEXT NOT NULL,
                    purchased_on TEXT NOT NULL,
                    recorded_at TEXT NOT NULL,
                    qty TEXT NOT NULL,
                    unit TEXT NOT NULL,
                    qty_in_case TEXT,
                    qty_base_units TEXT NOT NULL,
                    total_price TEXT NOT NULL,
                    unit_price TEXT,
                    source TEXT,
                    client_mutated_at TEXT NOT NULL,
                    server_seq INTEGER NOT NULL,
                    updated_at TEXT NOT NULL,
                    deleted_at TEXT,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX purchases_ingredient_deleted_idx
                    ON purchases(ingredient_id, deleted_at)
                """)

            // The outbox: still-unpushed local mutations. `"table"` is
            // quoted throughout because it's a SQL reserved word.
            try db.execute(sql: """
                CREATE TABLE pending_ops (
                    op_id TEXT PRIMARY KEY,
                    "table" TEXT NOT NULL,
                    row_id TEXT NOT NULL,
                    location_id TEXT NOT NULL,
                    client_mutated_at TEXT NOT NULL,
                    kind TEXT NOT NULL,
                    fields TEXT NOT NULL,
                    state TEXT NOT NULL,
                    reason TEXT,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX pending_ops_state_idx ON pending_ops(state)
                """)

            // Single-row identity + cursor. No declared primary key — the
            // row always lives at SQLite's implicit rowid 1 (see
            // LocalStore.meta()/bind()).
            try db.execute(sql: """
                CREATE TABLE meta (
                    user_id TEXT NOT NULL,
                    org_id TEXT NOT NULL,
                    location_id TEXT NOT NULL,
                    cursor INTEGER NOT NULL
                )
                """)
        }

        // Phase 3a. A SECOND migration rather than an edit to "v1": v1 has
        // shipped, and GRDB records which migrations have run -- editing it
        // would leave every existing install without these tables.
        migrator.registerMigration("v2") { db in
            try db.execute(sql: """
                CREATE TABLE invoices (
                    id TEXT PRIMARY KEY,
                    location_id TEXT NOT NULL,
                    captured_at TEXT NOT NULL,
                    parse_status TEXT NOT NULL,
                    client_mutated_at TEXT NOT NULL,
                    server_seq INTEGER NOT NULL,
                    updated_at TEXT NOT NULL,
                    deleted_at TEXT,
                    created_at TEXT NOT NULL
                )
                """)

            // page_no/width/height are integers server-side but TEXT here,
            // like every other synced column (this file's header comment) --
            // server_seq is the sole INTEGER exception.
            try db.execute(sql: """
                CREATE TABLE invoice_pages (
                    id TEXT PRIMARY KEY,
                    invoice_id TEXT NOT NULL,
                    location_id TEXT NOT NULL,
                    page_no TEXT NOT NULL,
                    storage_path TEXT NOT NULL,
                    width TEXT,
                    height TEXT,
                    sha256 TEXT,
                    client_mutated_at TEXT NOT NULL,
                    server_seq INTEGER NOT NULL,
                    updated_at TEXT NOT NULL,
                    deleted_at TEXT,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX invoice_pages_invoice_deleted_idx
                    ON invoice_pages(invoice_id, deleted_at)
                """)

            // Local-only, like pending_ops: the upload outbox (spec 3a-D2).
            // Never synced and never pushed -- it tracks BYTES, not rows, and
            // a stalled 12MB page must not block the JSON op batch.
            try db.execute(sql: """
                CREATE TABLE pending_uploads (
                    page_id TEXT PRIMARY KEY,
                    local_path TEXT NOT NULL,
                    state TEXT NOT NULL,
                    attempts INTEGER NOT NULL,
                    last_error TEXT,
                    created_at TEXT NOT NULL
                )
                """)
            try db.execute(sql: """
                CREATE INDEX pending_uploads_state_idx ON pending_uploads(state)
                """)

            try db.execute(sql: "ALTER TABLE purchases ADD COLUMN invoice_page_id TEXT")
        }

        return migrator
    }
}
