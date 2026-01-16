import Foundation

public enum DeleteOriginalsError: Error, Sendable {
    case verificationNotPassed(planId: EntityID)
    case planNotFound(planId: EntityID)
    case verificationRequired
    case destinationRootRequired
}

public struct DeleteOriginalsResult: Sendable {
    public let planId: EntityID
    public let totalEligible: Int
    public let deletedCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    public let mode: DeleteOriginalsMode

    public init(
        planId: EntityID,
        totalEligible: Int,
        deletedCount: Int,
        skippedCount: Int,
        failedCount: Int,
        mode: DeleteOriginalsMode
    ) {
        self.planId = planId
        self.totalEligible = totalEligible
        self.deletedCount = deletedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.mode = mode
    }
}

public typealias DeleteProgressHandler = @Sendable (_ index: Int, _ total: Int, _ sourcePath: String) -> Void

public struct DeleteOriginalsEngine: Sendable {
    private let dbManager: DatabaseManager
    private let planStore: PlanStore
    private let journalStore: JournalStore
    private let executionJournalStore: ExecutionJournalStore
    private let verifyEngine: VerifyEngine
    private let journalReader: JournalReader
    private let packageDetector: PackageDetector

    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
        self.planStore = PlanStore(dbManager: dbManager)
        self.journalStore = JournalStore(dbManager: dbManager)
        self.executionJournalStore = ExecutionJournalStore(dbManager: dbManager)
        self.verifyEngine = VerifyEngine(dbManager: dbManager)
        self.journalReader = JournalReader()
        self.packageDetector = PackageDetector()
    }

    /// Delete original files after successful copy-first verification.
    ///
    /// - Parameters:
    ///   - planId: The plan ID to delete originals for.
    ///   - project: The project configuration (for destinationRoot and deleteOriginalsMode).
    ///   - projectDirectory: The project directory (for archive paths).
    ///   - force: If true, skip verification gate (use with caution).
    ///   - progressHandler: Optional progress callback.
    /// - Returns: Result with counts of deleted, skipped, and failed operations.
    public func deleteOriginals(
        planId: EntityID,
        project: Project,
        projectDirectory: URL,
        force: Bool = false,
        progressHandler: DeleteProgressHandler? = nil
    ) async throws -> DeleteOriginalsResult {
        guard let plan = try await planStore.fetchPlan(id: planId) else {
            throw DeleteOriginalsError.planNotFound(planId: planId)
        }

        // Verification gate (unless forced).
        if !force {
            let verificationResult = try await verifyEngine.verify(planId: planId)
            guard verificationResult.passed else {
                throw DeleteOriginalsError.verificationNotPassed(planId: planId)
            }
        }

        // Fetch completed copy operations from journal.
        let journalStates = try await journalStore.fetchAllStates(planId: planId)
        let completedOperationIds = Set(
            journalStates
                .filter { $0.currentState == .completed }
                .map { $0.operationId }
        )

        // Load copy-time file stats from the journal JSONL (preferred for pre-delete recheck).
        let journalURL = projectDirectory.appendingPathComponent(plan.journalPath)
        let copyStatsByOperationId = (try? journalReader.copyStatsByOperationId(from: journalURL)) ?? [:]

        // Fetch operation rows to get source paths and sizes.
        let rows = try await planStore.fetchPlanOperationExecutionRows(planId: planId)
        let eligibleRows = rows.filter { row in
            completedOperationIds.contains(row.operation.operationId) &&
            row.operation.operationType == .copyItem
        }

        let mode = project.settings.deleteOriginalsMode
        guard let destRoot = project.destinationRoot else {
            throw DeleteOriginalsError.destinationRootRequired
        }
        let destinationRoot = URL(fileURLWithPath: destRoot.path)
        let timestamp = Date()
        var slugCache: [String: String] = [:]

        var deleted = 0
        var skipped = 0
        var failed = 0

        // Track already-deleted operations for resume.
        let existingEntries = try await executionJournalStore.fetchEntriesByType(
            planId: planId,
            operationType: mode == .moveToTrash ? .trashOriginal : .archiveOriginal
        )
        let alreadyProcessedOpIds = Set(existingEntries.map { $0.sourceOperationId ?? "" })

        for (index, row) in eligibleRows.enumerated() {
            let operationId = row.operation.operationId
            let sourcePath = sourcePathForExecution(row: row, project: project)
            progressHandler?(index + 1, eligibleRows.count, sourcePath)

            // Skip if already processed (resume support).
            if alreadyProcessedOpIds.contains(operationId) {
                let entry = existingEntries.first { $0.sourceOperationId == operationId }
                switch entry?.currentState {
                case .completed: deleted += 1
                case .skipped: skipped += 1
                case .failed: failed += 1
                default: break
                }
                continue
            }

            let sourceURL = URL(fileURLWithPath: sourcePath)
            let executionOpId = "\(operationId)-delete"

            let expectedStat = copyStatsByOperationId[operationId]
                ?? FileStat(sizeBytes: row.expectedSizeBytes, modifiedTime: row.expectedModifiedTime)

            // Pre-delete recheck: source must exist.
            guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                try await executionJournalStore.saveEntry(
                    ExecutionJournalEntry(
                        planId: planId,
                        executionOpId: executionOpId,
                        operationType: mode == .moveToTrash ? .trashOriginal : .archiveOriginal,
                        sourceOperationId: operationId,
                        currentState: .skipped,
                        itemId: row.operation.itemId,
                        sourcePath: sourceURL.path,
                        error: "Source already deleted or missing"
                    )
                )
                skipped += 1
                continue
            }

            // Pre-delete recheck: packages at least check logical size; files check size + mtime.
            if row.isPackage {
                let currentSize = packageDetector.computePackageSize(at: sourceURL)
                if currentSize != expectedStat.sizeBytes {
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: executionOpId,
                            operationType: mode == .moveToTrash ? .trashOriginal : .archiveOriginal,
                            sourceOperationId: operationId,
                            currentState: .skipped,
                            itemId: row.operation.itemId,
                            sourcePath: sourceURL.path,
                            error: "Source modified after copy: packageSize=\(currentSize) (expected \(expectedStat.sizeBytes))"
                        )
                    )
                    skipped += 1
                    continue
                }
            } else {
                let currentSize = Self.fileSize(at: sourceURL)
                let currentMtime = Self.modificationTime(at: sourceURL)

                let sizeMismatch = currentSize != expectedStat.sizeBytes
                let mtimeMismatch = currentMtime.map { abs($0.timeIntervalSince(expectedStat.modifiedTime)) > 1.0 } ?? true

                if sizeMismatch || mtimeMismatch {
                    try await executionJournalStore.saveEntry(
                        ExecutionJournalEntry(
                            planId: planId,
                            executionOpId: executionOpId,
                            operationType: mode == .moveToTrash ? .trashOriginal : .archiveOriginal,
                            sourceOperationId: operationId,
                            currentState: .skipped,
                            itemId: row.operation.itemId,
                            sourcePath: sourceURL.path,
                            error: "Source modified after copy: size=\(currentSize) (expected \(expectedStat.sizeBytes))"
                        )
                    )
                    skipped += 1
                    continue
                }
            }

            // Execute deletion.
            do {
                var archivePath: String? = nil

                switch mode {
                case .moveToTrash:
                    var resultingURL: NSURL?
                    try FileManager.default.trashItem(at: sourceURL, resultingItemURL: &resultingURL)

                case .archiveToBackup:
                    let slug = Self.sourceRootSlug(row.sourceRootPathAtScan, existingSlugs: &slugCache)
                    let archiveURL = Self.archivePath(
                        destinationRoot: destinationRoot,
                        timestamp: timestamp,
                        sourceRootSlug: slug,
                        relativePath: row.relativePath
                    )
                    archivePath = archiveURL.path

                    try FileManager.default.createDirectory(
                        at: archiveURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                    try FileManager.default.moveItem(at: sourceURL, to: archiveURL)
                }

                try await executionJournalStore.saveEntry(
                    ExecutionJournalEntry(
                        planId: planId,
                        executionOpId: executionOpId,
                        operationType: mode == .moveToTrash ? .trashOriginal : .archiveOriginal,
                        sourceOperationId: operationId,
                        currentState: .completed,
                        itemId: row.operation.itemId,
                        sourcePath: sourceURL.path,
                        destPath: row.operation.resolvedDestPath,
                        archivePath: archivePath
                    )
                )
                deleted += 1

            } catch {
                try await executionJournalStore.saveEntry(
                    ExecutionJournalEntry(
                        planId: planId,
                        executionOpId: executionOpId,
                        operationType: mode == .moveToTrash ? .trashOriginal : .archiveOriginal,
                        sourceOperationId: operationId,
                        currentState: .failed,
                        itemId: row.operation.itemId,
                        sourcePath: sourceURL.path,
                        error: String(describing: error)
                    )
                )
                failed += 1
            }
        }

        return DeleteOriginalsResult(
            planId: planId,
            totalEligible: eligibleRows.count,
            deletedCount: deleted,
            skippedCount: skipped,
            failedCount: failed,
            mode: mode
        )
    }

    // MARK: - Helpers

    private func sourcePathForExecution(row: PlanStore.PlanOperationExecutionRow, project: Project) -> String {
        if let currentRoot = project.sourceRoots.first(where: { $0.id == row.sourceRootId })?.path {
            let combined = (currentRoot as NSString).appendingPathComponent(row.relativePath)
            return URL(fileURLWithPath: combined).standardizedFileURL.path
        }
        return URL(fileURLWithPath: row.sourcePathAtScan).standardizedFileURL.path
    }

    private static func fileSize(at url: URL) -> Int64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = attrs[.size] as? Int64 else {
            return 0
        }
        return size
    }

    private static func modificationTime(at url: URL) -> Date? {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
              let date = attrs[.modificationDate] as? Date else {
            return nil
        }
        return date
    }

    static func archivePath(
        destinationRoot: URL,
        timestamp: Date,
        sourceRootSlug: String,
        relativePath: String
    ) -> URL {
        let isoTimestamp = timestamp.ISO8601Format()
            .replacingOccurrences(of: ":", with: "-")
            .replacingOccurrences(of: "+", with: "-")
        return destinationRoot
            .appendingPathComponent("_OriginalsBackup")
            .appendingPathComponent(isoTimestamp)
            .appendingPathComponent(sourceRootSlug)
            .appendingPathComponent(relativePath)
    }

    static func sourceRootSlug(_ path: String, existingSlugs: inout [String: String]) -> String {
        if let cached = existingSlugs[path] {
            return cached
        }

        let basename = URL(fileURLWithPath: path).lastPathComponent
        var slug = basename
        var counter = 2
        while existingSlugs.values.contains(slug) {
            slug = "\(basename)-\(counter)"
            counter += 1
        }
        existingSlugs[path] = slug
        return slug
    }
}
