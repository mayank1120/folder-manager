import Foundation

/// Immutable planned operation
public struct PlanOperation: Codable, Sendable, Hashable {
    public let operationId: String
    public let planId: EntityID
    public let itemId: String
    public let operationType: PlanOperationType
    public let executionMode: ExecutionMode
    public let baseDestPath: String
    public let resolvedDestPath: String
    public let collisionResolved: Bool
    public let conflictToken: String?
    public let crossVolume: Bool
    public let reasonCode: String
    public let sortOrder: Int
    
    public init(
        operationId: String,
        planId: EntityID,
        itemId: String,
        operationType: PlanOperationType,
        executionMode: ExecutionMode,
        baseDestPath: String,
        resolvedDestPath: String,
        collisionResolved: Bool = false,
        conflictToken: String? = nil,
        crossVolume: Bool = false,
        reasonCode: String,
        sortOrder: Int
    ) {
        self.operationId = operationId
        self.planId = planId
        self.itemId = itemId
        self.operationType = operationType
        self.executionMode = executionMode
        self.baseDestPath = baseDestPath
        self.resolvedDestPath = resolvedDestPath
        self.collisionResolved = collisionResolved
        self.conflictToken = conflictToken
        self.crossVolume = crossVolume
        self.reasonCode = reasonCode
        self.sortOrder = sortOrder
    }
}

/// Plan item with classification outcome for every inventory item
public struct PlanItem: Codable, Sendable, Hashable {
    public let planId: EntityID
    public let itemId: String
    public let disposition: Disposition
    public let ownerBucket: String?
    public let ownerReason: String?
    public let ownerConfidence: OwnerConfidence?
    public let category: String?
    public let subcategory: String?
    public let baseDestPath: String?
    public let suggestedResolvedDestPath: String?
    public let reasonCode: String?
    public let issueType: String?
    
    public init(
        planId: EntityID,
        itemId: String,
        disposition: Disposition,
        ownerBucket: String? = nil,
        ownerReason: String? = nil,
        ownerConfidence: OwnerConfidence? = nil,
        category: String? = nil,
        subcategory: String? = nil,
        baseDestPath: String? = nil,
        suggestedResolvedDestPath: String? = nil,
        reasonCode: String? = nil,
        issueType: String? = nil
    ) {
        self.planId = planId
        self.itemId = itemId
        self.disposition = disposition
        self.ownerBucket = ownerBucket
        self.ownerReason = ownerReason
        self.ownerConfidence = ownerConfidence
        self.category = category
        self.subcategory = subcategory
        self.baseDestPath = baseDestPath
        self.suggestedResolvedDestPath = suggestedResolvedDestPath
        self.reasonCode = reasonCode
        self.issueType = issueType
    }
}

/// Plan metadata
public struct Plan: Codable, Identifiable, Sendable {
    public let id: EntityID  // planId
    public let scanId: EntityID
    public let projectId: EntityID
    public let createdAt: Date
    public let settingsHash: String
    public var operationCount: Int
    public let journalPath: String
    
    public init(
        id: EntityID = EntityID(),
        scanId: EntityID,
        projectId: EntityID,
        createdAt: Date = Date(),
        settingsHash: String,
        operationCount: Int = 0,
        journalPath: String
    ) {
        self.id = id
        self.scanId = scanId
        self.projectId = projectId
        self.createdAt = createdAt
        self.settingsHash = settingsHash
        self.operationCount = operationCount
        self.journalPath = journalPath
    }
}
