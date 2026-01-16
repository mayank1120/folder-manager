import Foundation

/// Unique identifier type for entities
public typealias EntityID = UUID

/// Execution mode for file operations
public enum ExecutionMode: String, Codable, Sendable {
    case move
    case copyFirst
}

/// Collision handling policy
public enum CollisionPolicy: String, Codable, Sendable {
    case autoSuffix
    case manual
}

/// Delete originals mode (copy-first only)
public enum DeleteOriginalsMode: String, Codable, Sendable {
    case moveToTrash
    case archiveToBackup
}

/// Item disposition in planning
public enum Disposition: String, Codable, Sendable {
    case moveEligible
    case needsReview
    case excludedByPolicy
}

/// Owner confidence level
public enum OwnerConfidence: String, Codable, Sendable {
    case confident
    case notConfident
}

/// Plan operation types (immutable plan phase)
public enum PlanOperationType: String, Codable, Sendable {
    case copyItem
    case moveItem
    case applyTags
}

/// Execution-phase operation types (journaled during apply/delete/rollback)
public enum ExecutionOperationType: String, Codable, Sendable {
    case copyItem
    case moveItem
    case applyTags
    case trashOriginal
    case archiveOriginal
    case rollbackMove
    case rollbackDelete
    case rollbackTags
}

/// Operation state in journal
public enum OperationState: String, Codable, Sendable {
    case planned
    case started
    case completed
    case failed
    case skipped
}

/// Routing date source
public enum RoutingDateSource: String, Codable, Sendable {
    case exifOriginal
    case modifiedTime
}
