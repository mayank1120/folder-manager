import Foundation

/// Details about a collision conflict
public struct ConflictDetails: Codable, Sendable, Hashable {
    public let targetPath: String
    public let conflictingItemIds: [String]
    public var userResolution: ConflictResolution?
    
    public init(
        targetPath: String,
        conflictingItemIds: [String],
        userResolution: ConflictResolution? = nil
    ) {
        self.targetPath = targetPath
        self.conflictingItemIds = conflictingItemIds
        self.userResolution = userResolution
    }
}

/// User-chosen resolution for a conflict
public enum ConflictResolution: String, Codable, Sendable, CaseIterable {
    case rename      // Add suffix to this item
    case skip        // Don't move this item
    case replace     // Replace existing file
    case keepBoth    // Keep both with different names
    
    public var displayName: String {
        switch self {
        case .rename: return "Rename"
        case .skip: return "Skip"
        case .replace: return "Replace"
        case .keepBoth: return "Keep Both"
        }
    }
}
