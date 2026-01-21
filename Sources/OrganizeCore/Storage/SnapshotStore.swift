import Foundation
import GRDB

/// Store for file snapshot operations (incremental scans)
public struct SnapshotStore: Sendable {
    private let dbManager: DatabaseManager
    
    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }
    
    // MARK: - Save
    
    /// Save a batch of snapshots (replaces existing for same project/root/path)
    public func saveSnapshots(_ snapshots: [FileSnapshot]) async throws {
        guard !snapshots.isEmpty else { return }
        
        try await dbManager.write { db in
            for snapshot in snapshots {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO file_snapshots
                        (snapshot_id, project_id, source_root_id, relative_path,
                         size_bytes, modified_time, inode, snapshot_date)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        snapshot.id,
                        snapshot.projectId.uuidString,
                        snapshot.sourceRootId.uuidString,
                        snapshot.relativePath,
                        snapshot.sizeBytes,
                        Int64(snapshot.modifiedTime.timeIntervalSince1970),
                        Int64(snapshot.inode),
                        Int64(snapshot.snapshotDate.timeIntervalSince1970)
                    ]
                )
            }
        }
    }
    
    // MARK: - Fetch
    
    /// Fetch all snapshots for a project
    public func fetchSnapshots(for projectId: EntityID) async throws -> [FileSnapshot] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM file_snapshots WHERE project_id = ? ORDER BY source_root_id, relative_path",
                arguments: [projectId.uuidString]
            )
            return rows.compactMap { parseSnapshot(from: $0) }
        }
    }
    
    /// Fetch snapshots as a dictionary keyed by id (sourceRootId:relativePath)
    public func fetchSnapshotMap(for projectId: EntityID) async throws -> [String: FileSnapshot] {
        let snapshots = try await fetchSnapshots(for: projectId)
        return Dictionary(uniqueKeysWithValues: snapshots.map { ($0.id, $0) })
    }
    
    /// Fetch snapshots for a specific source root
    public func fetchSnapshots(for projectId: EntityID, sourceRootId: EntityID) async throws -> [FileSnapshot] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: "SELECT * FROM file_snapshots WHERE project_id = ? AND source_root_id = ? ORDER BY relative_path",
                arguments: [projectId.uuidString, sourceRootId.uuidString]
            )
            return rows.compactMap { parseSnapshot(from: $0) }
        }
    }
    
    // MARK: - Delete
    
    /// Delete all snapshots for a project
    public func deleteSnapshots(for projectId: EntityID) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: "DELETE FROM file_snapshots WHERE project_id = ?",
                arguments: [projectId.uuidString]
            )
        }
    }
    
    /// Delete snapshots for a specific source root
    public func deleteSnapshots(for projectId: EntityID, sourceRootId: EntityID) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: "DELETE FROM file_snapshots WHERE project_id = ? AND source_root_id = ?",
                arguments: [projectId.uuidString, sourceRootId.uuidString]
            )
        }
    }
    
    /// Delete snapshots for paths that no longer exist
    public func deleteSnapshots(forPaths paths: [String], projectId: EntityID, sourceRootId: EntityID) async throws {
        guard !paths.isEmpty else { return }
        
        try await dbManager.write { db in
            let placeholders = paths.map { _ in "?" }.joined(separator: ", ")
            var args: [DatabaseValue] = [projectId.uuidString.databaseValue, sourceRootId.uuidString.databaseValue]
            args.append(contentsOf: paths.map { $0.databaseValue })
            
            try db.execute(
                sql: """
                    DELETE FROM file_snapshots
                    WHERE project_id = ? AND source_root_id = ? AND relative_path IN (\(placeholders))
                    """,
                arguments: StatementArguments(args)
            )
        }
    }
    
    // MARK: - Comparison
    
    /// Compare current files to previous snapshots and return change results
    public func compareToSnapshots(
        currentFiles: [(relativePath: String, sizeBytes: Int64, modifiedTime: Date, inode: UInt64)],
        previousSnapshots: [String: FileSnapshot],
        projectId: EntityID,
        sourceRootId: EntityID
    ) -> [FileChangeResult] {
        var results: [FileChangeResult] = []
        var seenPaths = Set<String>()
        
        for file in currentFiles {
            seenPaths.insert(file.relativePath)
            let snapshotId = "\(sourceRootId.uuidString):\(file.relativePath)"
            
            let currentSnapshot = FileSnapshot(
                projectId: projectId,
                sourceRootId: sourceRootId,
                relativePath: file.relativePath,
                sizeBytes: file.sizeBytes,
                modifiedTime: file.modifiedTime,
                inode: file.inode
            )
            
            if let previous = previousSnapshots[snapshotId] {
                // Compare
                if file.sizeBytes == previous.sizeBytes &&
                   abs(file.modifiedTime.timeIntervalSince(previous.modifiedTime)) < 1.0 &&
                   file.inode == previous.inode {
                    results.append(FileChangeResult(
                        relativePath: file.relativePath,
                        changeType: .unchanged,
                        currentSnapshot: currentSnapshot,
                        previousSnapshot: previous
                    ))
                } else {
                    results.append(FileChangeResult(
                        relativePath: file.relativePath,
                        changeType: .modified,
                        currentSnapshot: currentSnapshot,
                        previousSnapshot: previous
                    ))
                }
            } else {
                // New file
                results.append(FileChangeResult(
                    relativePath: file.relativePath,
                    changeType: .new,
                    currentSnapshot: currentSnapshot,
                    previousSnapshot: nil
                ))
            }
        }
        
        // Check for deleted files
        for (snapshotId, snapshot) in previousSnapshots {
            if snapshot.sourceRootId == sourceRootId && !seenPaths.contains(snapshot.relativePath) {
                results.append(FileChangeResult(
                    relativePath: snapshot.relativePath,
                    changeType: .deleted,
                    currentSnapshot: nil,
                    previousSnapshot: snapshot
                ))
            }
        }
        
        return results
    }
    
    // MARK: - Parsing
    
    private func parseSnapshot(from row: Row) -> FileSnapshot? {
        guard let projectIdStr = row["project_id"] as String?,
              let projectId = UUID(uuidString: projectIdStr),
              let sourceRootIdStr = row["source_root_id"] as String?,
              let sourceRootId = UUID(uuidString: sourceRootIdStr),
              let relativePath = row["relative_path"] as String?,
              let sizeBytes = row["size_bytes"] as Int64?,
              let modifiedTime = row["modified_time"] as Int64?,
              let inode = row["inode"] as Int64?,
              let snapshotDate = row["snapshot_date"] as Int64? else {
            return nil
        }
        
        return FileSnapshot(
            projectId: projectId,
            sourceRootId: sourceRootId,
            relativePath: relativePath,
            sizeBytes: sizeBytes,
            modifiedTime: Date(timeIntervalSince1970: TimeInterval(modifiedTime)),
            inode: UInt64(inode),
            snapshotDate: Date(timeIntervalSince1970: TimeInterval(snapshotDate))
        )
    }
}
