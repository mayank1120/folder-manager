import Foundation

/// A group of duplicate files sharing the same content hash
public struct DuplicateGroup: Identifiable, Sendable {
    public let id: String  // content_hash
    public var items: [DuplicateItem]
    public var selectedKeeperId: String?  // User picks which to keep
    
    public init(id: String, items: [DuplicateItem], selectedKeeperId: String? = nil) {
        self.id = id
        self.items = items
        self.selectedKeeperId = selectedKeeperId
    }
    
    /// Total bytes that would be freed if only keeper is retained
    public var potentialSavingsBytes: Int64 {
        guard items.count > 1 else { return 0 }
        // Sum sizes of all items except the keeper
        let keeperId = selectedKeeperId ?? items.first?.itemId
        return items
            .filter { $0.itemId != keeperId }
            .reduce(0) { $0 + $1.sizeBytes }
    }
}

/// A single item within a duplicate group
public struct DuplicateItem: Identifiable, Sendable {
    public let id: String  // itemId
    public let itemId: String
    public let relativePath: String
    public let sourceRootId: EntityID
    public let sizeBytes: Int64
    public let modifiedTime: Date
    
    public init(
        itemId: String,
        relativePath: String,
        sourceRootId: EntityID,
        sizeBytes: Int64,
        modifiedTime: Date
    ) {
        self.id = itemId
        self.itemId = itemId
        self.relativePath = relativePath
        self.sourceRootId = sourceRootId
        self.sizeBytes = sizeBytes
        self.modifiedTime = modifiedTime
    }
}
