import Foundation

/// A user override for a specific inventory item
/// Allows manual reassignment of owner, category, or rule before plan generation
public struct UserOverride: Codable, Sendable, Hashable, Identifiable {
    public let id: EntityID
    public let projectId: EntityID
    public let itemId: String
    public var ownerBucket: String?
    public var category: String?
    public var subcategory: String?
    public var extensionRuleId: EntityID?
    public var exclude: Bool
    public var createdAt: Date
    public var updatedAt: Date
    
    public init(
        id: EntityID = UUID(),
        projectId: EntityID,
        itemId: String,
        ownerBucket: String? = nil,
        category: String? = nil,
        subcategory: String? = nil,
        extensionRuleId: EntityID? = nil,
        exclude: Bool = false,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.projectId = projectId
        self.itemId = itemId
        self.ownerBucket = ownerBucket
        self.category = category
        self.subcategory = subcategory
        self.extensionRuleId = extensionRuleId
        self.exclude = exclude
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
    
    /// Returns true if this override has any actual changes
    public var hasOverrides: Bool {
        ownerBucket != nil || category != nil || subcategory != nil || extensionRuleId != nil || exclude
    }
}
