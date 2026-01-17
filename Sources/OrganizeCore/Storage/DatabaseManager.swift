import Foundation
import GRDB

/// Database actor for serialized access to SQLite
public actor DatabaseManager {
    private let dbQueue: DatabaseQueue
    
    public init(path: String) throws {
        var config = Configuration()
        config.foreignKeysEnabled = true
        config.prepareDatabase { db in
            // Enable WAL mode for concurrent reads
            try? db.execute(sql: "PRAGMA journal_mode = WAL")
        }
        
        self.dbQueue = try DatabaseQueue(path: path, configuration: config)
        try Self.createTablesIfNeeded(dbQueue: self.dbQueue)
    }
    
    /// Create all tables if they don't exist (static to call from init)
    private static func createTablesIfNeeded(dbQueue: DatabaseQueue) throws {
        try dbQueue.write { db in
            // Source roots
            try db.create(table: "source_roots", ifNotExists: true) { t in
                t.column("source_root_id", .text).primaryKey()
                t.column("project_id", .text).notNull()
                t.column("path", .text).notNull()
                t.column("slug", .text).notNull()
            }
            
            // Scans
            try db.create(table: "scans", ifNotExists: true) { t in
                t.column("scan_id", .text).primaryKey()
                t.column("project_id", .text).notNull()
                t.column("started_at", .integer)
                t.column("completed_at", .integer)
                t.column("item_count", .integer)
                t.column("total_bytes", .integer)
            }
            
            // Scan source roots (immutable snapshot)
            try db.create(table: "scan_source_roots", ifNotExists: true) { t in
                t.column("scan_id", .text).notNull()
                t.column("source_root_id", .text).notNull()
                t.column("path_at_scan", .text).notNull()
                t.column("slug_at_scan", .text).notNull()
                t.primaryKey(["scan_id", "source_root_id"])
                t.foreignKey(["scan_id"], references: "scans", columns: ["scan_id"])
                t.foreignKey(["source_root_id"], references: "source_roots", columns: ["source_root_id"])
            }
            
            // Inventory items
            try db.create(table: "inventory_items", ifNotExists: true) { t in
                t.column("item_id", .text).primaryKey()
                t.column("scan_id", .text).notNull()
                t.column("source_root_id", .text).notNull()
                t.column("relative_path", .text).notNull()
                t.column("is_package", .integer).notNull().defaults(to: 0)
                t.column("is_symlink", .integer).notNull().defaults(to: 0)
                t.column("is_alias", .integer).notNull().defaults(to: 0)
                t.column("size_bytes", .integer).notNull()
                t.column("modified_time", .integer).notNull()
                t.column("created_time", .integer)
                t.column("exif_datetime_original", .integer)
                t.column("is_cloud_only", .integer).notNull().defaults(to: 0)
                t.column("content_hash", .text)
                t.column("uttype_identifier", .text)
                t.column("extension", .text)
                t.foreignKey(["scan_id"], references: "scans", columns: ["scan_id"])
                t.foreignKey(["source_root_id"], references: "source_roots", columns: ["source_root_id"])
            }
            
            // Scan excluded items (for excluded_by_policy.csv)
            try Self.ensureScanExcludedItemsTable(db: db)
            
            // Plans
            try db.create(table: "plans", ifNotExists: true) { t in
                t.column("plan_id", .text).primaryKey()
                t.column("scan_id", .text).notNull()
                t.column("project_id", .text).notNull()
                t.column("created_at", .integer).notNull()
                t.column("settings_hash", .text).notNull()
                t.column("operation_count", .integer).notNull().defaults(to: 0)
                t.column("journal_path", .text).notNull()
                t.foreignKey(["scan_id"], references: "scans", columns: ["scan_id"])
            }
            
            // Plan items
            try db.create(table: "plan_items", ifNotExists: true) { t in
                t.column("plan_id", .text).notNull()
                t.column("item_id", .text).notNull()
                t.column("disposition", .text).notNull()
                t.column("owner_bucket", .text)
                t.column("owner_reason", .text)
                t.column("owner_confidence", .text)
                t.column("category", .text)
                t.column("subcategory", .text)
                t.column("base_dest_path", .text)
                t.column("suggested_resolved_dest_path", .text)
                t.column("reason_code", .text)
                t.column("issue_type", .text)
                t.column("matched_rule_id", .text)
                t.column("classification_source", .text)
                t.primaryKey(["plan_id", "item_id"])
                t.foreignKey(["plan_id"], references: "plans", columns: ["plan_id"])
                t.foreignKey(["item_id"], references: "inventory_items", columns: ["item_id"])
            }
            
            // Plan operations
            try db.create(table: "plan_operations", ifNotExists: true) { t in
                t.column("plan_id", .text).notNull()
                t.column("operation_id", .text).notNull()
                t.column("item_id", .text).notNull()
                t.column("operation_type", .text).notNull()
                t.column("execution_mode", .text).notNull()
                t.column("base_dest_path", .text).notNull()
                t.column("resolved_dest_path", .text).notNull()
                t.column("collision_resolved", .integer).notNull().defaults(to: 0)
                t.column("conflict_token", .text)
                t.column("cross_volume", .integer).notNull().defaults(to: 0)
                t.column("reason_code", .text)
                t.column("sort_order", .integer).notNull()
                t.primaryKey(["plan_id", "operation_id"])
                t.foreignKey(["plan_id"], references: "plans", columns: ["plan_id"])
                t.foreignKey(["item_id"], references: "inventory_items", columns: ["item_id"])
            }
            
            // Journal state
            try db.create(table: "journal_state", ifNotExists: true) { t in
                t.column("plan_id", .text).notNull()
                t.column("operation_id", .text).notNull()
                t.column("current_state", .text).notNull()
                t.column("last_updated", .integer).notNull()
                t.column("temp_path", .text)
                t.column("phase", .text)
                t.primaryKey(["plan_id", "operation_id"])
            }
            
            // Execution journal
            try db.create(table: "execution_journal", ifNotExists: true) { t in
                t.column("plan_id", .text).notNull()
                t.column("execution_op_id", .text).notNull()
                t.column("operation_type", .text).notNull()
                t.column("source_operation_id", .text)
                t.column("current_state", .text).notNull()
                t.column("last_updated", .integer).notNull()
                t.column("item_id", .text)
                t.column("source_path", .text)
                t.column("dest_path", .text)
                t.column("archive_path", .text)
                t.column("error", .text)
                t.primaryKey(["plan_id", "execution_op_id"])
            }
            
            // Migrate execution_journal if columns are missing
            try Self.ensureExecutionJournalColumns(db: db)
            try Self.ensurePlanItemsColumns(db: db)
            try Self.ensureInventoryItemColumns(db: db)
            
            // Indexes
            try db.create(index: "idx_inventory_scan", on: "inventory_items", columns: ["scan_id"], ifNotExists: true)
            try db.create(index: "idx_inventory_root", on: "inventory_items", columns: ["source_root_id"], ifNotExists: true)
            try db.create(index: "idx_scan_roots", on: "scan_source_roots", columns: ["scan_id"], ifNotExists: true)
            try db.create(index: "idx_excluded_scan", on: "scan_excluded_items", columns: ["scan_id"], ifNotExists: true)
            try db.create(index: "idx_plan_items_plan", on: "plan_items", columns: ["plan_id"], ifNotExists: true)
            try db.create(index: "idx_plan_ops_order", on: "plan_operations", columns: ["plan_id", "sort_order"], ifNotExists: true)
            try db.create(index: "idx_journal_plan", on: "journal_state", columns: ["plan_id"], ifNotExists: true)
            try db.create(index: "idx_exec_journal_plan", on: "execution_journal", columns: ["plan_id"], ifNotExists: true)
        }
    }

    private static func ensureScanExcludedItemsTable(db: Database) throws {
        let tableExists = try Row.fetchOne(
            db,
            sql: "SELECT name FROM sqlite_master WHERE type = 'table' AND name = ?",
            arguments: ["scan_excluded_items"]
        ) != nil

        if !tableExists {
            try Self.createScanExcludedItemsTable(db: db)
            return
        }

        let pkColumns = try Self.primaryKeyColumns(tableName: "scan_excluded_items", db: db)
        if pkColumns == ["scan_id", "source_root_id", "relative_path"] {
            return
        }

        try db.execute(sql: "DROP TABLE IF EXISTS scan_excluded_items_old")
        try db.execute(sql: "ALTER TABLE scan_excluded_items RENAME TO scan_excluded_items_old")
        try Self.createScanExcludedItemsTable(db: db)
        try db.execute(
            sql: """
                INSERT OR IGNORE INTO scan_excluded_items
                (scan_id, source_root_id, relative_path, absolute_path, reason, is_directory)
                SELECT scan_id, source_root_id, relative_path, absolute_path, reason, is_directory
                FROM scan_excluded_items_old
                """
        )
        try db.execute(sql: "DROP TABLE scan_excluded_items_old")
    }

    private static func createScanExcludedItemsTable(db: Database) throws {
        try db.create(table: "scan_excluded_items", ifNotExists: true) { t in
            t.column("scan_id", .text).notNull()
            t.column("source_root_id", .text).notNull()
            t.column("relative_path", .text).notNull()
            t.column("absolute_path", .text).notNull()
            t.column("reason", .text).notNull()
            t.column("is_directory", .integer).notNull().defaults(to: 0)
            t.primaryKey(["scan_id", "source_root_id", "relative_path"])
            t.foreignKey(["scan_id"], references: "scans", columns: ["scan_id"])
            t.foreignKey(["source_root_id"], references: "source_roots", columns: ["source_root_id"])
        }
    }

    private static func primaryKeyColumns(tableName: String, db: Database) throws -> [String]? {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(\(tableName))")
        if rows.isEmpty {
            return nil
        }

        return rows
            .compactMap { row -> (pkIndex: Int, columnName: String)? in
                guard let pkIndex = row["pk"] as Int?,
                      pkIndex > 0,
                      let columnName = row["name"] as String? else {
                    return nil
                }
                return (pkIndex: pkIndex, columnName: columnName)
            }
            .sorted { $0.pkIndex < $1.pkIndex }
            .map(\.columnName)
    }

    private static func ensureExecutionJournalColumns(db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(execution_journal)")
        let existingColumns = Set(rows.compactMap { $0["name"] as String? })

        if !existingColumns.contains("source_path") {
            try db.execute(sql: "ALTER TABLE execution_journal ADD COLUMN source_path TEXT")
        }
        if !existingColumns.contains("archive_path") {
            try db.execute(sql: "ALTER TABLE execution_journal ADD COLUMN archive_path TEXT")
        }
        if !existingColumns.contains("error") {
            try db.execute(sql: "ALTER TABLE execution_journal ADD COLUMN error TEXT")
        }
    }

    private static func ensurePlanItemsColumns(db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(plan_items)")
        let existingColumns = Set(rows.compactMap { $0["name"] as String? })

        if !existingColumns.contains("matched_rule_id") {
            try db.execute(sql: "ALTER TABLE plan_items ADD COLUMN matched_rule_id TEXT")
        }
        if !existingColumns.contains("classification_source") {
            try db.execute(sql: "ALTER TABLE plan_items ADD COLUMN classification_source TEXT")
        }
    }

    private static func ensureInventoryItemColumns(db: Database) throws {
        let rows = try Row.fetchAll(db, sql: "PRAGMA table_info(inventory_items)")
        let existingColumns = Set(rows.compactMap { $0["name"] as String? })

        if !existingColumns.contains("content_hash") {
            try db.execute(sql: "ALTER TABLE inventory_items ADD COLUMN content_hash TEXT")
        }
    }
    
    // MARK: - Read Operations
    
    public func read<T>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try dbQueue.read(block)
    }
    
    // MARK: - Write Operations
    
    public func write<T>(_ block: @Sendable (Database) throws -> T) throws -> T {
        try dbQueue.write(block)
    }
}
