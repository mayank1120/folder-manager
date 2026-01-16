import Foundation

/// File statistics at a point in time
public struct FileStat: Codable, Sendable, Hashable {
    public let sizeBytes: Int64
    public let modifiedTime: Date
    
    public init(sizeBytes: Int64, modifiedTime: Date) {
        self.sizeBytes = sizeBytes
        self.modifiedTime = modifiedTime
    }
}

/// Append-only journal entry
public struct JournalEntry: Codable, Sendable {
    public let planId: EntityID
    public let operationId: String
    public let timestamp: Int64  // epoch seconds
    public let state: OperationState
    public let operationType: ExecutionOperationType
    public let itemId: String?
    public let resolvedDestPath: String?
    public let tempPath: String?
    public let phase: String?
    public let error: String?
    public let copyStatAtTime: FileStat?
    public let tagsBefore: [String]?
    public let tagsAfter: [String]?
    public let reasonCode: String?
    
    public init(
        planId: EntityID,
        operationId: String,
        timestamp: Int64 = Int64(Date().timeIntervalSince1970),
        state: OperationState,
        operationType: ExecutionOperationType,
        itemId: String? = nil,
        resolvedDestPath: String? = nil,
        tempPath: String? = nil,
        phase: String? = nil,
        error: String? = nil,
        copyStatAtTime: FileStat? = nil,
        tagsBefore: [String]? = nil,
        tagsAfter: [String]? = nil,
        reasonCode: String? = nil
    ) {
        self.planId = planId
        self.operationId = operationId
        self.timestamp = timestamp
        self.state = state
        self.operationType = operationType
        self.itemId = itemId
        self.resolvedDestPath = resolvedDestPath
        self.tempPath = tempPath
        self.phase = phase
        self.error = error
        self.copyStatAtTime = copyStatAtTime
        self.tagsBefore = tagsBefore
        self.tagsAfter = tagsAfter
        self.reasonCode = reasonCode
    }
}

/// Journal state index entry (for fast resume)
public struct JournalState: Codable, Sendable {
    public let planId: EntityID
    public let operationId: String
    public let currentState: OperationState
    public let lastUpdated: Int64
    public let tempPath: String?
    public let phase: String?
    
    public init(
        planId: EntityID,
        operationId: String,
        currentState: OperationState,
        lastUpdated: Int64 = Int64(Date().timeIntervalSince1970),
        tempPath: String? = nil,
        phase: String? = nil
    ) {
        self.planId = planId
        self.operationId = operationId
        self.currentState = currentState
        self.lastUpdated = lastUpdated
        self.tempPath = tempPath
        self.phase = phase
    }
}

/// Execution journal entry for delete/rollback operations
public struct ExecutionJournalEntry: Codable, Sendable {
    public let planId: EntityID
    public let executionOpId: String
    public let operationType: ExecutionOperationType
    public let sourceOperationId: String?
    public let currentState: OperationState
    public let lastUpdated: Int64
    public let itemId: String?
    public let sourcePath: String?
    public let destPath: String?
    public let archivePath: String?
    public let error: String?
    
    public init(
        planId: EntityID,
        executionOpId: String,
        operationType: ExecutionOperationType,
        sourceOperationId: String? = nil,
        currentState: OperationState,
        lastUpdated: Int64 = Int64(Date().timeIntervalSince1970),
        itemId: String? = nil,
        sourcePath: String? = nil,
        destPath: String? = nil,
        archivePath: String? = nil,
        error: String? = nil
    ) {
        self.planId = planId
        self.executionOpId = executionOpId
        self.operationType = operationType
        self.sourceOperationId = sourceOperationId
        self.currentState = currentState
        self.lastUpdated = lastUpdated
        self.itemId = itemId
        self.sourcePath = sourcePath
        self.destPath = destPath
        self.archivePath = archivePath
        self.error = error
    }
}

