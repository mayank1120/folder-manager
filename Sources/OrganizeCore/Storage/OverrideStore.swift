import Foundation
import GRDB

/// Store for user override operations
public struct OverrideStore: Sendable {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }
    
    // MARK: - Save/Update
    
    /// Save or update an override (upsert by project_id + item_id)
    public func saveOverride(_ override: UserOverride) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO user_overrides
                    (override_id, project_id, item_id, owner_bucket, category, subcategory,
                     extension_rule_id, exclude, created_at, updated_at)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    override.id.uuidString,
                    override.projectId.uuidString,
                    override.itemId,
                    override.ownerBucket,
                    override.category,
                    override.subcategory,
                    override.extensionRuleId?.uuidString,
                    override.exclude ? 1 : 0,
                    Int64(override.createdAt.timeIntervalSince1970),
                    Int64(override.updatedAt.timeIntervalSince1970)
                ]
            )
        }
    }
    
    // MARK: - Fetch
    
    /// Fetch all overrides for a project
    public func fetchOverrides(for projectId: EntityID) async throws -> [UserOverride] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM user_overrides WHERE project_id = ? ORDER BY item_id",
                arguments: [projectId.uuidString]
            )
            return rows.compactMap { parseOverride(from: $0) }
        }
    }
    
    /// Fetch overrides as a dictionary keyed by item_id for fast lookup
    public func fetchOverridesMap(for projectId: EntityID) async throws -> [String: UserOverride] {
        let overrides = try await fetchOverrides(for: projectId)
        return Dictionary(uniqueKeysWithValues: overrides.map { ($0.itemId, $0) })
    }
    
    /// Fetch a single override for an item
    public func fetchOverride(projectId: EntityID, itemId: String) async throws -> UserOverride? {
        try await dbManager.read { db in
            let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM user_overrides WHERE project_id = ? AND item_id = ?",
                arguments: [projectId.uuidString, itemId]
            )
            return row.flatMap { parseOverride(from: $0) }
        }
    }
    
    // MARK: - Delete
    
    /// Delete an override
    public func deleteOverride(_ override: UserOverride) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: "DELETE FROM user_overrides WHERE override_id = ?",
                arguments: [override.id.uuidString]
            )
        }
    }
    
    /// Delete all overrides for a project
    public func deleteOverrides(for projectId: EntityID) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: "DELETE FROM user_overrides WHERE project_id = ?",
                arguments: [projectId.uuidString]
            )
        }
    }
    
    // MARK: - Parsing
    
    private func parseOverride(from row: Row) -> UserOverride? {
        guard let idStr = row["override_id"] as String?,
              let id = UUID(uuidString: idStr),
              let projectIdStr = row["project_id"] as String?,
              let projectId = UUID(uuidString: projectIdStr),
              let itemId = row["item_id"] as String?,
              let createdAt = row["created_at"] as Int64?,
              let updatedAt = row["updated_at"] as Int64? else {
            return nil
        }
        
        let ruleIdStr = row["extension_rule_id"] as String?
        let ruleId = ruleIdStr.flatMap { UUID(uuidString: $0) }
        
        return UserOverride(
            id: id,
            projectId: projectId,
            itemId: itemId,
            ownerBucket: row["owner_bucket"],
            category: row["category"],
            subcategory: row["subcategory"],
            extensionRuleId: ruleId,
            exclude: (row["exclude"] as Int64? ?? 0) == 1,
            createdAt: Date(timeIntervalSince1970: TimeInterval(createdAt)),
            updatedAt: Date(timeIntervalSince1970: TimeInterval(updatedAt))
        )
    }
}
