import Foundation

// MARK: - Scanner Protocol

/// Protocol for scanner implementations - enables mocking in tests
public protocol ScannerProtocol: Sendable {
    /// Scan source roots and build inventory
    func scan(
        project: Project,
        progressHandler: ScanProgressHandler?
    ) async throws -> ScanResult
}

// MARK: - Planner Protocol

/// Protocol for planner implementations - enables mocking in tests
public protocol PlannerProtocol: Sendable {
    /// Create an execution plan from scanned inventory
    func createPlan(
        project: Project,
        scanId: EntityID,
        resolvedRuleDestinations: [EntityID: URL],
        userOverrides: [EntityID: UserOverride]
    ) async throws -> PlanBuildSummary
}

// MARK: - Apply Engine Protocol

/// Protocol for apply engine implementations - enables mocking in tests
public protocol ApplyEngineProtocol: Sendable {
    /// Apply a plan to the file system
    func apply(
        planId: EntityID,
        project: Project,
        projectDirectory: URL,
        dryRun: Bool,
        progressHandler: ApplyProgressHandler?
    ) async throws -> ApplyResult
}

// MARK: - Verify Engine Protocol

/// Protocol for verify engine implementations - enables mocking in tests
public protocol VerifyEngineProtocol: Sendable {
    /// Verify that applied operations were successful
    func verify(planId: EntityID) async throws -> VerificationResult
}

// MARK: - Rollback Manager Protocol

/// Protocol for rollback implementations - enables mocking in tests
public protocol RollbackManagerProtocol: Sendable {
    /// Rollback applied operations
    func rollback(
        planId: EntityID,
        projectDirectory: URL,
        progressHandler: RollbackProgressHandler?
    ) async throws -> RollbackResult
}

// MARK: - Inventory Store Protocol

/// Protocol for inventory storage - enables mocking in tests
public protocol InventoryStoreProtocol: Sendable {
    func saveInventoryItems(_ items: [InventoryItem]) async throws
    func fetchInventoryItems(for scanId: EntityID) async throws -> [InventoryItem]
    func saveScan(_ scan: Scan) async throws
    func fetchScan(id: EntityID) async throws -> Scan?
    func saveSourceRoot(_ root: SourceRoot, projectId: EntityID) async throws
    func saveScanSourceRoot(_ scanSourceRoot: ScanSourceRoot) async throws
    func fetchScanSourceRoots(for scanId: EntityID) async throws -> [ScanSourceRoot]
    func saveExcludedItems(_ items: [ExcludedItem]) async throws
    func fetchExcludedItems(for scanId: EntityID) async throws -> [ExcludedItem]
}

// MARK: - Plan Store Protocol

/// Protocol for plan storage - enables mocking in tests
public protocol PlanStoreProtocol: Sendable {
    func savePlan(_ plan: Plan) async throws
    func fetchPlan(id: EntityID) async throws -> Plan?
    func savePlanItems(_ items: [PlanItem]) async throws
    func fetchPlanItems(for planId: EntityID) async throws -> [PlanItem]
    func savePlanOperations(_ operations: [PlanOperation]) async throws
    func fetchPlanOperations(for planId: EntityID) async throws -> [PlanOperation]
    func fetchPlanOperationExecutionRows(planId: EntityID) async throws -> [PlanStore.PlanOperationExecutionRow]
}

// MARK: - File System Protocol

/// Protocol for file system operations - enables mocking in tests
public protocol FileSystemProtocol: Sendable {
    func fileExists(atPath path: String) -> Bool
    func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws
    func copyItem(at srcURL: URL, to dstURL: URL) throws
    func moveItem(at srcURL: URL, to dstURL: URL) throws
    func removeItem(at url: URL) throws
    func contentsOfDirectory(at url: URL) throws -> [URL]
    func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any]
}

/// Default implementation using FileManager
public struct DefaultFileSystem: FileSystemProtocol, Sendable {
    public init() {}
    
    public func fileExists(atPath path: String) -> Bool {
        FileManager.default.fileExists(atPath: path)
    }
    
    public func createDirectory(at url: URL, withIntermediateDirectories: Bool) throws {
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: withIntermediateDirectories)
    }
    
    public func copyItem(at srcURL: URL, to dstURL: URL) throws {
        try FileManager.default.copyItem(at: srcURL, to: dstURL)
    }
    
    public func moveItem(at srcURL: URL, to dstURL: URL) throws {
        try FileManager.default.moveItem(at: srcURL, to: dstURL)
    }
    
    public func removeItem(at url: URL) throws {
        try FileManager.default.removeItem(at: url)
    }
    
    public func contentsOfDirectory(at url: URL) throws -> [URL] {
        try FileManager.default.contentsOfDirectory(at: url, includingPropertiesForKeys: nil)
    }
    
    public func attributesOfItem(atPath path: String) throws -> [FileAttributeKey: Any] {
        try FileManager.default.attributesOfItem(atPath: path)
    }
}
