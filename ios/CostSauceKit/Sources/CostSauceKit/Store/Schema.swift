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

        return migrator
    }
}
