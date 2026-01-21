import Foundation

// MARK: - EXPERIMENTAL / PLACEHOLDER
// These types are scaffolding for future incremental scan support.
// They are NOT YET WIRED into Scanner execution.
// The IncrementalScanSettings in ProjectSettings is stored but not used.

/// Result of an incremental scan
public struct IncrementalScanResult: Sendable {
    public let scan: Scan
    public let totalItems: Int
    public let unchangedCount: Int
    public let modifiedCount: Int
    public let newCount: Int
    public let deletedCount: Int
    public let skippedPaths: [String]  // Unchanged paths not re-indexed
    
    public init(
        scan: Scan,
        totalItems: Int,
        unchangedCount: Int,
        modifiedCount: Int,
        newCount: Int,
        deletedCount: Int,
        skippedPaths: [String]
    ) {
        self.scan = scan
        self.totalItems = totalItems
        self.unchangedCount = unchangedCount
        self.modifiedCount = modifiedCount
        self.newCount = newCount
        self.deletedCount = deletedCount
        self.skippedPaths = skippedPaths
    }
    
    /// Percentage of items that were skipped (cached)
    public var cacheHitRate: Double {
        guard totalItems > 0 else { return 0 }
        return Double(unchangedCount) / Double(totalItems) * 100
    }
}

/// Incremental scan settings
public struct IncrementalScanSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var trustInode: Bool  // If true, trust inode for faster comparison
    
    public init(enabled: Bool = false, trustInode: Bool = true) {
        self.enabled = enabled
        self.trustInode = trustInode
    }
}

/// Delegate for incremental scan progress
public protocol IncrementalScanDelegate: AnyObject, Sendable {
    func incrementalScanDidStart(totalFiles: Int)
    func incrementalScanFoundUnchanged(path: String, remaining: Int)
    func incrementalScanProcessingChanged(path: String, changeType: FileChangeType)
    func incrementalScanDidComplete(result: IncrementalScanResult)
}

/// Extension to provide default implementations
public extension IncrementalScanDelegate {
    func incrementalScanDidStart(totalFiles: Int) {}
    func incrementalScanFoundUnchanged(path: String, remaining: Int) {}
    func incrementalScanProcessingChanged(path: String, changeType: FileChangeType) {}
    func incrementalScanDidComplete(result: IncrementalScanResult) {}
}
