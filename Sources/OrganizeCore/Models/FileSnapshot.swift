import Foundation

/// A snapshot of file metadata at scan time for incremental scan comparison
public struct FileSnapshot: Codable, Sendable, Hashable, Identifiable {
    public let id: String  // relative path as unique key
    public let projectId: EntityID
    public let sourceRootId: EntityID
    public let relativePath: String
    public let sizeBytes: Int64
    public let modifiedTime: Date
    public let inode: UInt64
    public let snapshotDate: Date
    
    public init(
        projectId: EntityID,
        sourceRootId: EntityID,
        relativePath: String,
        sizeBytes: Int64,
        modifiedTime: Date,
        inode: UInt64,
        snapshotDate: Date = Date()
    ) {
        self.id = "\(sourceRootId.uuidString):\(relativePath)"
        self.projectId = projectId
        self.sourceRootId = sourceRootId
        self.relativePath = relativePath
        self.sizeBytes = sizeBytes
        self.modifiedTime = modifiedTime
        self.inode = inode
        self.snapshotDate = snapshotDate
    }
}

/// Comparison result for an item during incremental scan
public enum FileChangeType: String, Codable, Sendable {
    case unchanged   // Same size, mtime, inode - skip reprocessing
    case modified    // Size or mtime changed
    case new         // Not in previous snapshot
    case deleted     // In previous snapshot but not found now
    case moved       // Same inode but different path (possibly)
}

/// Result of comparing current file state to snapshot
public struct FileChangeResult: Sendable {
    public let relativePath: String
    public let changeType: FileChangeType
    public let currentSnapshot: FileSnapshot?
    public let previousSnapshot: FileSnapshot?
    
    public init(
        relativePath: String,
        changeType: FileChangeType,
        currentSnapshot: FileSnapshot? = nil,
        previousSnapshot: FileSnapshot? = nil
    ) {
        self.relativePath = relativePath
        self.changeType = changeType
        self.currentSnapshot = currentSnapshot
        self.previousSnapshot = previousSnapshot
    }
    
    /// Returns true if this file needs reprocessing (not unchanged)
    public var needsReprocessing: Bool {
        changeType != .unchanged
    }
}
