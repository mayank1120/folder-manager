import Foundation
import Darwin

public enum RollbackError: Error, Sendable {
    case planNotFound(planId: EntityID)
    case noJournalEntries
}

public struct RollbackResult: Sendable {
    public let planId: EntityID
    public let totalOperations: Int
    public let rolledBackCount: Int
    public let skippedCount: Int
    public let failedCount: Int

    public init(
        planId: EntityID,
        totalOperations: Int,
        rolledBackCount: Int,
        skippedCount: Int,
        failedCount: Int
    ) {
        self.planId = planId
        self.totalOperations = totalOperations
        self.rolledBackCount = rolledBackCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
    }
}

public typealias RollbackProgressHandler = @Sendable (_ index: Int, _ total: Int, _ operationId: String) -> Void

/// Reverses applied operations using the journal.
public struct RollbackManager: Sendable {
    private let dbManager: DatabaseManager
    private let planStore: PlanStore
    private let journalStore: JournalStore
    private let executionJournalStore: ExecutionJournalStore

    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
        self.planStore = PlanStore(dbManager: dbManager)
        self.journalStore = JournalStore(dbManager: dbManager)
        self.executionJournalStore = ExecutionJournalStore(dbManager: dbManager)
    }

    /// Rollback applied operations for a plan.
    ///
    /// Strategy:
    /// - Reverse operations in LIFO order (newest first).
    /// - For copyItem: delete destination file.
    /// - For moveItem: move destination back to source.
    /// - For archiveOriginal: move from archive back to source.
    /// - Never overwrite existing files (skip with RollbackConflict).
    public func rollback(
        planId: EntityID,
        projectDirectory: URL,
        progressHandler: RollbackProgressHandler? = nil
    ) async throws -> RollbackResult {
        guard let _ = try await planStore.fetchPlan(id: planId) else {
            throw RollbackError.planNotFound(planId: planId)
        }

        // Fetch all journal entries (apply operations).
        let journalStates = try await journalStore.fetchAllStates(planId: planId)
        let completedOpIds = Set(
            journalStates
                .filter { $0.currentState == .completed }
                .map { $0.operationId }
        )
        
        // Read tagsBefore from journal for proper tag rollback
        guard let plan = try await planStore.fetchPlan(id: planId) else {
            throw RollbackError.planNotFound(planId: planId)
        }
        let journalURL = projectDirectory.appendingPathComponent(plan.journalPath)
        let journalReader = JournalReader()
        let tagsBeforeMap = (try? journalReader.tagsBeforeByOperationId(from: journalURL)) ?? [:]

        // Fetch operation rows.
        let rows = try await planStore.fetchPlanOperationExecutionRows(planId: planId)
        let completedRows = rows.filter { completedOpIds.contains($0.operation.operationId) }

        // Also fetch completed delete operations (archiveOriginal).
        let deleteEntries = try await executionJournalStore.fetchCompletedDeleteOperations(planId: planId)

        // Track which rollbacks are already done (resume support).
        let existingRollbacks = try await executionJournalStore.fetchEntriesByType(planId: planId, operationType: .rollbackMove)
        let existingRollbackDeletes = try await executionJournalStore.fetchEntriesByType(planId: planId, operationType: .rollbackDelete)
        var rollbackBySourceOperationId: [String: ExecutionJournalEntry] = [:]
        rollbackBySourceOperationId.reserveCapacity(existingRollbacks.count + existingRollbackDeletes.count)
        for entry in existingRollbacks + existingRollbackDeletes {
            guard let sourceOpId = entry.sourceOperationId else { continue }
            rollbackBySourceOperationId[sourceOpId] = entry
        }

        var rolledBack = 0
        var skipped = 0
        var failed = 0

        // 1. First, rollback archive deletions (restore from archive).
        let archiveEntries = deleteEntries.filter { $0.operationType == .archiveOriginal && $0.archivePath != nil }
        for (index, entry) in archiveEntries.enumerated() {
            progressHandler?(index + 1, archiveEntries.count + completedRows.count, entry.executionOpId)

            if let existing = rollbackBySourceOperationId[entry.executionOpId] {
                switch existing.currentState {
                case .completed:
                    rolledBack += 1
                    continue
                case .skipped:
                    skipped += 1
                    continue
                case .failed:
                    failed += 1
                    continue
                case .planned, .started:
                    break
                }
            }

            let rollbackOpId = "\(entry.executionOpId)-rollback"
            guard let archivePath = entry.archivePath,
                  let sourcePath = entry.sourcePath else {
                skipped += 1
                continue
            }

            let archiveURL = URL(fileURLWithPath: archivePath)
            let sourceURL = URL(fileURLWithPath: sourcePath)

            // Check if archive still exists.
            guard FileManager.default.fileExists(atPath: archiveURL.path) else {
                try await executionJournalStore.saveEntry(
                    ExecutionJournalEntry(
                        planId: planId,
                        executionOpId: rollbackOpId,
                        operationType: .rollbackDelete,
                        sourceOperationId: entry.executionOpId,
                        currentState: .skipped,
                        sourcePath: sourcePath,
                        archivePath: archivePath,
                        error: "Archive file not found"
                    )
                )
                skipped += 1
                continue
            }

            // Never overwrite: check if source already exists.
            if FileManager.default.fileExists(atPath: sourceURL.path) {
                try await executionJournalStore.saveEntry(
                    ExecutionJournalEntry(
                        planId: planId,
                        executionOpId: rollbackOpId,
                        operationType: .rollbackDelete,
                        sourceOperationId: entry.executionOpId,
                        currentState: .skipped,
                        sourcePath: sourcePath,
                        archivePath: archivePath,
                        error: "RollbackConflict: source already exists"
                    )
                )
                skipped += 1
                continue
            }

            do {
                try FileManager.default.createDirectory(
                    at: sourceURL.deletingLastPathComponent(),
                    withIntermediateDirectories: true
                )
                try moveOrCopyDelete(sourceURL: archiveURL, destinationURL: sourceURL, tempIdentifier: rollbackOpId)

                try await executionJournalStore.saveEntry(
                    ExecutionJournalEntry(
                        planId: planId,
                        executionOpId: rollbackOpId,
                        operationType: .rollbackDelete,
                        sourceOperationId: entry.executionOpId,
                        currentState: .completed,
                        sourcePath: sourcePath,
                        archivePath: archivePath
                    )
                )
                rolledBack += 1
            } catch {
                try await executionJournalStore.saveEntry(
                    ExecutionJournalEntry(
                        planId: planId,
                        executionOpId: rollbackOpId,
                        operationType: .rollbackDelete,
                        sourceOperationId: entry.executionOpId,
                        currentState: .failed,
                        sourcePath: sourcePath,
                        archivePath: archivePath,
                        error: String(describing: error)
                    )
                )
                failed += 1
            }
        }

        // 2. Rollback apply operations (reverse order).
        let reversedRows = completedRows.reversed()
        for (index, row) in reversedRows.enumerated() {
            let op = row.operation
            progressHandler?(archiveEntries.count + index + 1, archiveEntries.count + completedRows.count, op.operationId)

            if let existing = rollbackBySourceOperationId[op.operationId] {
                switch existing.currentState {
                case .completed:
                    rolledBack += 1
                    continue
                case .skipped:
                    skipped += 1
                    continue
                case .failed:
                    failed += 1
                    continue
                case .planned, .started:
                    break
                }
            }

            let rollbackOpId = "\(op.operationId)-rollback"
            let destURL = URL(fileURLWithPath: op.resolvedDestPath)
            let sourceURL = URL(fileURLWithPath: row.sourcePathAtScan)

            switch op.operationType {
            case .copyItem:
                // Delete destination file.
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: rollbackOpId,
                            operationType: .rollbackDelete,
                            sourceOperationId: op.operationId,
                            currentState: .skipped,
                            itemId: op.itemId,
                            sourcePath: sourceURL.path,
                            destPath: destURL.path,
                            error: "Destination already missing"
                        )
                    )
                    skipped += 1
                    continue
                }

                do {
                    try FileManager.default.removeItem(at: destURL)
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: rollbackOpId,
                            operationType: .rollbackDelete,
                            sourceOperationId: op.operationId,
                            currentState: .completed,
                            itemId: op.itemId,
                            sourcePath: sourceURL.path,
                            destPath: destURL.path
                        )
                    )
                    rolledBack += 1
                } catch {
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: rollbackOpId,
                            operationType: .rollbackDelete,
                            sourceOperationId: op.operationId,
                            currentState: .failed,
                            itemId: op.itemId,
                            sourcePath: sourceURL.path,
                            destPath: destURL.path,
                            error: String(describing: error)
                        )
                    )
                    failed += 1
                }

            case .moveItem:
                // Move destination back to source.
                if !FileManager.default.fileExists(atPath: destURL.path) {
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: rollbackOpId,
                            operationType: .rollbackMove,
                            sourceOperationId: op.operationId,
                            currentState: .skipped,
                            itemId: op.itemId,
                            sourcePath: sourceURL.path,
                            destPath: destURL.path,
                            error: "Destination already missing"
                        )
                    )
                    skipped += 1
                    continue
                }

                // Never overwrite: check if source already exists.
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: rollbackOpId,
                            operationType: .rollbackMove,
                            sourceOperationId: op.operationId,
                            currentState: .skipped,
                            itemId: op.itemId,
                            sourcePath: sourceURL.path,
                            destPath: destURL.path,
                            error: "RollbackConflict: source already exists"
                        )
                    )
                    skipped += 1
                    continue
                }

                do {
                    try FileManager.default.createDirectory(
                        at: sourceURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try moveOrCopyDelete(sourceURL: destURL, destinationURL: sourceURL, tempIdentifier: rollbackOpId)
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: rollbackOpId,
                            operationType: .rollbackMove,
                            sourceOperationId: op.operationId,
                            currentState: .completed,
                            itemId: op.itemId,
                            sourcePath: sourceURL.path,
                            destPath: destURL.path
                        )
                    )
                    rolledBack += 1
                } catch {
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: rollbackOpId,
                            operationType: .rollbackMove,
                            sourceOperationId: op.operationId,
                            currentState: .failed,
                            itemId: op.itemId,
                            sourcePath: sourceURL.path,
                            destPath: destURL.path,
                            error: String(describing: error)
                        )
                    )
                    failed += 1
                }

            case .applyTags:
                // Rollback tags: restore to tagsBefore state
                let rollbackOpId = "\(op.operationId)-rollback"
                
                guard FileManager.default.fileExists(atPath: destURL.path) else {
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: rollbackOpId,
                            operationType: .rollbackTags,
                            sourceOperationId: op.operationId,
                            currentState: .skipped,
                            itemId: op.itemId,
                            destPath: destURL.path,
                            error: "File not found for tag rollback"
                        )
                    )
                    skipped += 1
                    continue
                }
                
                // Fetch the original tagsBefore from journal
                // Only rollback if the tag operation completed
                guard completedOpIds.contains(op.operationId) else {
                    skipped += 1
                    continue
                }
                
                do {
                    // Restore to prior tags from journal
                    let tagsToRestore = tagsBeforeMap[op.operationId] ?? []
                    try TagHelper.writeTags(tagsToRestore, to: destURL)
                    
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: rollbackOpId,
                            operationType: .rollbackTags,
                            sourceOperationId: op.operationId,
                            currentState: .completed,
                            itemId: op.itemId,
                            destPath: destURL.path
                        )
                    )
                    rolledBack += 1
                } catch {
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: rollbackOpId,
                            operationType: .rollbackTags,
                            sourceOperationId: op.operationId,
                            currentState: .failed,
                            itemId: op.itemId,
                            destPath: destURL.path,
                            error: String(describing: error)
                        )
                    )
                    failed += 1
                }
            }
        }

        return RollbackResult(
            planId: planId,
            totalOperations: archiveEntries.count + completedRows.count,
            rolledBackCount: rolledBack,
            skippedCount: skipped,
            failedCount: failed
        )
    }

    private func moveOrCopyDelete(sourceURL: URL, destinationURL: URL, tempIdentifier: String) throws {
        do {
            try FileManager.default.moveItem(at: sourceURL, to: destinationURL)
            return
        } catch {
            if isCrossDeviceMoveError(error) {
                try copyThenDelete(sourceURL: sourceURL, destinationURL: destinationURL, tempIdentifier: tempIdentifier)
                return
            }
            throw error
        }
    }

    private func copyThenDelete(sourceURL: URL, destinationURL: URL, tempIdentifier: String) throws {
        let tempURL = destinationURL
            .deletingLastPathComponent()
            .appendingPathComponent(".organize-rollback-temp-\(tempIdentifier)")

        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }

        do {
            try FileManager.default.copyItem(at: sourceURL, to: tempURL)
            try FileManager.default.moveItem(at: tempURL, to: destinationURL)
        } catch {
            try? FileManager.default.removeItem(at: tempURL)
            throw error
        }

        // Best-effort cleanup: remove original after restore.
        try FileManager.default.removeItem(at: sourceURL)
    }

    private func isCrossDeviceMoveError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == EXDEV {
            return true
        }
        return false
    }
}
