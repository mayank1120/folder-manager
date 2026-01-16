import Foundation
import GRDB

/// Store for inventory items and scans
public struct InventoryStore: Sendable {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }
    
    // MARK: - Source Roots
    
    public func saveSourceRoot(_ root: SourceRoot, projectId: EntityID) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO source_roots (source_root_id, project_id, path, slug)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [root.id.uuidString, projectId.uuidString, root.path, root.slug]
            )
        }
    }
    
    public func fetchSourceRoots(for projectId: EntityID) async throws -> [SourceRoot] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM source_roots WHERE project_id = ?",
                arguments: [projectId.uuidString]
            )
            return rows.compactMap { row -> SourceRoot? in
                guard let idStr = row["source_root_id"] as String?,
                      let id = UUID(uuidString: idStr),
                      let path = row["path"] as String?,
                      let slug = row["slug"] as String? else {
                    return nil
                }
                return SourceRoot(id: id, path: path, slug: slug)
            }
        }
    }
    
    // MARK: - Scans
    
    public func saveScan(_ scan: Scan) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO scans (scan_id, project_id, started_at, completed_at, item_count, total_bytes)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    scan.id.uuidString,
                    scan.projectId.uuidString,
                    Int64(scan.startedAt.timeIntervalSince1970),
                    scan.completedAt.map { Int64($0.timeIntervalSince1970) },
                    scan.itemCount,
                    scan.totalBytes
                ]
            )
        }
    }
    
    public func fetchScan(id scanId: EntityID) async throws -> Scan? {
        try await dbManager.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM scans WHERE scan_id = ?",
                arguments: [scanId.uuidString]
            ) else {
                return nil
            }
            
            guard let projectIdStr = row["project_id"] as String?,
                  let projectId = UUID(uuidString: projectIdStr),
                  let startedAt = row["started_at"] as Int64? else {
                return nil
            }
            
            let completedAt: Date? = (row["completed_at"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            
            return Scan(
                id: scanId,
                projectId: projectId,
                startedAt: Date(timeIntervalSince1970: TimeInterval(startedAt)),
                completedAt: completedAt,
                itemCount: row["item_count"] ?? 0,
                totalBytes: row["total_bytes"] ?? 0
            )
        }
    }
    
    // MARK: - Scan Source Roots (Immutable Snapshot)
    
    public func saveScanSourceRoot(_ root: ScanSourceRoot) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO scan_source_roots (scan_id, source_root_id, path_at_scan, slug_at_scan)
                    VALUES (?, ?, ?, ?)
                    """,
                arguments: [
                    root.scanId.uuidString,
                    root.sourceRootId.uuidString,
                    root.pathAtScan,
                    root.slugAtScan
                ]
            )
        }
    }
    
    public func fetchScanSourceRoots(for scanId: EntityID) async throws -> [ScanSourceRoot] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM scan_source_roots WHERE scan_id = ?",
                arguments: [scanId.uuidString]
            )
            return rows.compactMap { row -> ScanSourceRoot? in
                guard let sourceRootIdStr = row["source_root_id"] as String?,
                      let sourceRootId = UUID(uuidString: sourceRootIdStr),
                      let pathAtScan = row["path_at_scan"] as String?,
                      let slugAtScan = row["slug_at_scan"] as String? else {
                    return nil
                }
                return ScanSourceRoot(
                    scanId: scanId,
                    sourceRootId: sourceRootId,
                    pathAtScan: pathAtScan,
                    slugAtScan: slugAtScan
                )
            }
        }
    }
    
    // MARK: - Inventory Items
    
    public func saveInventoryItem(_ item: InventoryItem) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO inventory_items 
                    (item_id, scan_id, source_root_id, relative_path, is_package, is_symlink, is_alias,
                     size_bytes, modified_time, created_time, exif_datetime_original, is_cloud_only,
                     uttype_identifier, extension)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    item.id,
                    item.scanId.uuidString,
                    item.sourceRootId.uuidString,
                    item.relativePath,
                    item.isPackage ? 1 : 0,
                    item.isSymlink ? 1 : 0,
                    item.isAlias ? 1 : 0,
                    item.sizeBytes,
                    Int64(item.modifiedTime.timeIntervalSince1970),
                    item.createdTime.map { Int64($0.timeIntervalSince1970) },
                    item.exifDateTimeOriginal.map { Int64($0.timeIntervalSince1970) },
                    item.isCloudOnly ? 1 : 0,
                    item.uttypeIdentifier,
                    item.extension
                ]
            )
        }
    }
    
    public func saveInventoryItems(_ items: [InventoryItem]) async throws {
        try await dbManager.write { db in
            let statement = try db.makeStatement(
                sql: """
                    INSERT OR REPLACE INTO inventory_items
                    (item_id, scan_id, source_root_id, relative_path, is_package, is_symlink, is_alias,
                     size_bytes, modified_time, created_time, exif_datetime_original, is_cloud_only,
                     uttype_identifier, extension)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """
            )

            for item in items {
                try statement.execute(arguments: [
                    item.id,
                    item.scanId.uuidString,
                    item.sourceRootId.uuidString,
                    item.relativePath,
                    item.isPackage ? 1 : 0,
                    item.isSymlink ? 1 : 0,
                    item.isAlias ? 1 : 0,
                    item.sizeBytes,
                    Int64(item.modifiedTime.timeIntervalSince1970),
                    item.createdTime.map { Int64($0.timeIntervalSince1970) },
                    item.exifDateTimeOriginal.map { Int64($0.timeIntervalSince1970) },
                    item.isCloudOnly ? 1 : 0,
                    item.uttypeIdentifier,
                    item.extension
                ])
            }
        }
    }
    
    public func fetchInventoryItems(for scanId: EntityID) async throws -> [InventoryItem] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM inventory_items WHERE scan_id = ? ORDER BY source_root_id, relative_path",
                arguments: [scanId.uuidString]
            )
            return rows.compactMap { row -> InventoryItem? in
                guard let itemId = row["item_id"] as String?,
                      let sourceRootIdStr = row["source_root_id"] as String?,
                      let sourceRootId = UUID(uuidString: sourceRootIdStr),
                      let relativePath = row["relative_path"] as String?,
                      let sizeBytes = row["size_bytes"] as Int64?,
                      let modifiedTimeEpoch = row["modified_time"] as Int64? else {
                    return nil
                }
                
                let createdTime: Date? = (row["created_time"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let exifDateTime: Date? = (row["exif_datetime_original"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                
                return InventoryItem(
                    id: itemId,
                    scanId: scanId,
                    sourceRootId: sourceRootId,
                    relativePath: relativePath,
                    isPackage: (row["is_package"] as Int? ?? 0) == 1,
                    isSymlink: (row["is_symlink"] as Int? ?? 0) == 1,
                    isAlias: (row["is_alias"] as Int? ?? 0) == 1,
                    sizeBytes: sizeBytes,
                    modifiedTime: Date(timeIntervalSince1970: TimeInterval(modifiedTimeEpoch)),
                    createdTime: createdTime,
                    exifDateTimeOriginal: exifDateTime,
                    isCloudOnly: (row["is_cloud_only"] as Int? ?? 0) == 1,
                    uttypeIdentifier: row["uttype_identifier"],
                    extension: row["extension"]
                )
            }
        }
    }
    
    public func fetchInventoryItem(id itemId: String) async throws -> InventoryItem? {
        try await dbManager.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM inventory_items WHERE item_id = ?",
                arguments: [itemId]
            ) else {
                return nil
            }
            
            guard let scanIdStr = row["scan_id"] as String?,
                  let scanId = UUID(uuidString: scanIdStr),
                  let sourceRootIdStr = row["source_root_id"] as String?,
                  let sourceRootId = UUID(uuidString: sourceRootIdStr),
                  let relativePath = row["relative_path"] as String?,
                  let sizeBytes = row["size_bytes"] as Int64?,
                  let modifiedTimeEpoch = row["modified_time"] as Int64? else {
                return nil
            }
            
            let createdTime: Date? = (row["created_time"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            let exifDateTime: Date? = (row["exif_datetime_original"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
            
            return InventoryItem(
                id: itemId,
                scanId: scanId,
                sourceRootId: sourceRootId,
                relativePath: relativePath,
                isPackage: (row["is_package"] as Int? ?? 0) == 1,
                isSymlink: (row["is_symlink"] as Int? ?? 0) == 1,
                isAlias: (row["is_alias"] as Int? ?? 0) == 1,
                sizeBytes: sizeBytes,
                modifiedTime: Date(timeIntervalSince1970: TimeInterval(modifiedTimeEpoch)),
                createdTime: createdTime,
                exifDateTimeOriginal: exifDateTime,
                isCloudOnly: (row["is_cloud_only"] as Int? ?? 0) == 1,
                uttypeIdentifier: row["uttype_identifier"],
                extension: row["extension"]
            )
        }
    }
    
    public func inventoryItemCount(for scanId: EntityID) async throws -> Int {
        try await dbManager.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM inventory_items WHERE scan_id = ?",
                arguments: [scanId.uuidString]
            ) ?? 0
        }
    }
    
    public func inventoryTotalBytes(for scanId: EntityID) async throws -> Int64 {
        try await dbManager.read { db in
            try Int64.fetchOne(
                db,
                sql: "SELECT COALESCE(SUM(size_bytes), 0) FROM inventory_items WHERE scan_id = ?",
                arguments: [scanId.uuidString]
            ) ?? 0
        }
    }
    
    // MARK: - Excluded Items
    
    public func saveExcludedItem(_ item: ExcludedItem) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO scan_excluded_items 
                    (scan_id, source_root_id, relative_path, absolute_path, reason, is_directory)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    item.scanId.uuidString,
                    item.sourceRootId.uuidString,
                    item.relativePath,
                    item.absolutePath,
                    item.reason.rawValue,
                    item.isDirectory ? 1 : 0
                ]
            )
        }
    }
    
    public func saveExcludedItems(_ items: [ExcludedItem]) async throws {
        try await dbManager.write { db in
            let statement = try db.makeStatement(
                sql: """
                    INSERT OR REPLACE INTO scan_excluded_items
                    (scan_id, source_root_id, relative_path, absolute_path, reason, is_directory)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """
            )

            for item in items {
                try statement.execute(arguments: [
                    item.scanId.uuidString,
                    item.sourceRootId.uuidString,
                    item.relativePath,
                    item.absolutePath,
                    item.reason.rawValue,
                    item.isDirectory ? 1 : 0
                ])
            }
        }
    }
    
    public func fetchExcludedItems(for scanId: EntityID) async throws -> [ExcludedItem] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM scan_excluded_items WHERE scan_id = ? ORDER BY source_root_id, relative_path",
                arguments: [scanId.uuidString]
            )
            return rows.compactMap { row -> ExcludedItem? in
                guard let sourceRootIdStr = row["source_root_id"] as String?,
                      let sourceRootId = UUID(uuidString: sourceRootIdStr),
                      let relativePath = row["relative_path"] as String?,
                      let absolutePath = row["absolute_path"] as String?,
                      let reasonStr = row["reason"] as String?,
                      let reason = ExclusionReason(rawValue: reasonStr) else {
                    return nil
                }
                return ExcludedItem(
                    scanId: scanId,
                    sourceRootId: sourceRootId,
                    relativePath: relativePath,
                    absolutePath: absolutePath,
                    reason: reason,
                    isDirectory: (row["is_directory"] as Int? ?? 0) == 1
                )
            }
        }
    }
    
    public func excludedItemCount(for scanId: EntityID) async throws -> Int {
        try await dbManager.read { db in
            try Int.fetchOne(
                db,
                sql: "SELECT COUNT(*) FROM scan_excluded_items WHERE scan_id = ?",
                arguments: [scanId.uuidString]
            ) ?? 0
        }
    }
}
