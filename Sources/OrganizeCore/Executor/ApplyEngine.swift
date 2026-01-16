import Foundation
import Darwin

public struct ApplyResult: Sendable {
    public let planId: EntityID
    public let totalOperations: Int
    public let completedCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    public let dryRun: Bool

    public init(
        planId: EntityID,
        totalOperations: Int,
        completedCount: Int,
        skippedCount: Int,
        failedCount: Int,
        dryRun: Bool
    ) {
        self.planId = planId
        self.totalOperations = totalOperations
        self.completedCount = completedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.dryRun = dryRun
    }
}

public typealias ApplyProgressHandler = @Sendable (_ index: Int, _ total: Int, _ currentPath: String) -> Void

public struct CloudDownloadHandler: Sendable {
    public let isCloudOnly: @Sendable (URL) -> Bool
    public let startDownload: @Sendable (URL) throws -> Void
    public let waitForDownload: @Sendable (URL) async throws -> Void

    public init(
        isCloudOnly: @escaping @Sendable (URL) -> Bool,
        startDownload: @escaping @Sendable (URL) throws -> Void,
        waitForDownload: @escaping @Sendable (URL) async throws -> Void
    ) {
        self.isCloudOnly = isCloudOnly
        self.startDownload = startDownload
        self.waitForDownload = waitForDownload
    }

    public static func system(
        timeoutSeconds: TimeInterval = 120,
        pollIntervalSeconds: TimeInterval = 0.5
    ) -> CloudDownloadHandler {
        let detector = CloudStatusDetector()
        return CloudDownloadHandler(
            isCloudOnly: { url in detector.isCloudOnly(at: url) },
            startDownload: { url in try detector.startDownload(at: url) },
            waitForDownload: { url in
                let deadline = Date().addingTimeInterval(timeoutSeconds)
                while Date() < deadline {
                    if !detector.isCloudOnly(at: url) {
                        return
                    }
                    try await Task.sleep(nanoseconds: UInt64(pollIntervalSeconds * 1_000_000_000))
                }
                throw CloudDownloadError.timeout
            }
        )
    }

    public enum CloudDownloadError: Error, Sendable {
        case timeout
    }
}

public struct ApplyEngine: Sendable {
    private let dbManager: DatabaseManager
    private let planStore: PlanStore
    private let journalStore: JournalStore
    private let volumeDetector: VolumeDetector
    private let cloudDownloadHandler: CloudDownloadHandler

    public init(
        dbManager: DatabaseManager,
        cloudDownloadHandler: CloudDownloadHandler = .system()
    ) {
        self.dbManager = dbManager
        self.planStore = PlanStore(dbManager: dbManager)
        self.journalStore = JournalStore(dbManager: dbManager)
        self.volumeDetector = VolumeDetector()
        self.cloudDownloadHandler = cloudDownloadHandler
    }

    public func apply(
        planId: EntityID,
        project: Project,
        projectDirectory: URL,
        dryRun: Bool = false,
        progressHandler: ApplyProgressHandler? = nil
    ) async throws -> ApplyResult {
        guard let plan = try await planStore.fetchPlan(id: planId) else {
            throw ApplyError.planNotFound(planId: planId)
        }

        let rows = try await planStore.fetchPlanOperationExecutionRows(planId: planId)
        let total = rows.count

        if dryRun {
            return try dryRunApply(planId: planId, project: project, rows: rows, total: total, progressHandler: progressHandler)
        }

        let journalURL = projectDirectory.appendingPathComponent(plan.journalPath)
        let journalReader = JournalReader()
        let copyStatsByOperationId = (try? journalReader.copyStatsByOperationId(from: journalURL)) ?? [:]
        let journalWriter = try JournalWriter(planId: planId, journalFileURL: journalURL, journalStore: journalStore)

        var stateByOperationId: [String: JournalState] = [:]
        let existingStates = try await journalStore.fetchAllStates(planId: planId)
        stateByOperationId = Dictionary(uniqueKeysWithValues: existingStates.map { ($0.operationId, $0) })

        var completed = 0
        var skipped = 0
        var failed = 0

        for (index, row) in rows.enumerated() {
            let operation = row.operation
            let sourceURL = URL(fileURLWithPath: sourcePathForExecution(row: row, project: project))
            let destURL = URL(fileURLWithPath: operation.resolvedDestPath)

            progressHandler?(index + 1, total, sourceURL.path)

            if let existing = stateByOperationId[operation.operationId] {
                switch existing.currentState {
                case .completed:
                    completed += 1
                    continue
                case .failed:
                    failed += 1
                    continue
                case .skipped:
                    skipped += 1
                    continue
                case .planned, .started:
                    break
                }
            }

            do {
                if let existing = stateByOperationId[operation.operationId], existing.currentState == .started {
                    let resumed = try await resumeStartedOperation(
                        row: row,
                        sourceURL: sourceURL,
                        destURL: destURL,
                        existingState: existing,
                        copyStatsByOperationId: copyStatsByOperationId,
                        journalWriter: journalWriter
                    )

                    if resumed == .completed {
                        completed += 1
                        continue
                    }
                    if resumed == .skipped {
                        skipped += 1
                        continue
                    }
                    if resumed == .failed {
                        failed += 1
                        continue
                    }
                    // resumed == .planned => fall through and retry as a fresh operation
                }

                // Source must exist.
                guard FileManager.default.fileExists(atPath: sourceURL.path) else {
                    try await journalWriter.append(
                        JournalEntry(
                            planId: planId,
                            operationId: operation.operationId,
                            state: .failed,
                            operationType: toExecutionOpType(operation.operationType),
                            itemId: operation.itemId,
                            resolvedDestPath: operation.resolvedDestPath,
                            error: "Source missing: \(sourceURL.path)",
                            reasonCode: ApplyReasonCode.sourceMissing.rawValue
                        )
                    )
                    failed += 1
                    continue
                }

                // Never overwrite; apply-time collision => skip (unless resuming).
                if FileManager.default.fileExists(atPath: destURL.path) {
                    try await journalWriter.append(
                        JournalEntry(
                            planId: planId,
                            operationId: operation.operationId,
                            state: .skipped,
                            operationType: toExecutionOpType(operation.operationType),
                            itemId: operation.itemId,
                            resolvedDestPath: operation.resolvedDestPath,
                            error: "Destination already exists: \(destURL.path)",
                            reasonCode: ApplyReasonCode.applyTimeCollision.rawValue
                        )
                    )
                    skipped += 1
                    continue
                }

                // Cloud-only handling at apply time (file may have been evicted since planning).
                if cloudDownloadHandler.isCloudOnly(sourceURL) {
                    if project.settings.downloadBeforeProcessing {
                        do {
                            try cloudDownloadHandler.startDownload(sourceURL)
                            try await cloudDownloadHandler.waitForDownload(sourceURL)
                        } catch {
                            try await journalWriter.append(
                                JournalEntry(
                                    planId: planId,
                                    operationId: operation.operationId,
                                    state: .skipped,
                                    operationType: toExecutionOpType(operation.operationType),
                                    itemId: operation.itemId,
                                    resolvedDestPath: operation.resolvedDestPath,
                                    error: "Download failed for cloud-only item: \(sourceURL.path) (\(error))",
                                    reasonCode: ApplyReasonCode.downloadFailed.rawValue
                                )
                            )
                            skipped += 1
                            continue
                        }

                        if cloudDownloadHandler.isCloudOnly(sourceURL) {
                            try await journalWriter.append(
                                JournalEntry(
                                    planId: planId,
                                    operationId: operation.operationId,
                                    state: .skipped,
                                    operationType: toExecutionOpType(operation.operationType),
                                    itemId: operation.itemId,
                                    resolvedDestPath: operation.resolvedDestPath,
                                    error: "Download did not complete for cloud-only item: \(sourceURL.path)",
                                    reasonCode: ApplyReasonCode.downloadFailed.rawValue
                                )
                            )
                            skipped += 1
                            continue
                        }
                    } else {
                        try await journalWriter.append(
                            JournalEntry(
                                planId: planId,
                                operationId: operation.operationId,
                                state: .skipped,
                                operationType: toExecutionOpType(operation.operationType),
                                itemId: operation.itemId,
                                resolvedDestPath: operation.resolvedDestPath,
                                error: "Cloud-only item (downloadBeforeProcessing=OFF): \(sourceURL.path)",
                                reasonCode: ApplyReasonCode.cloudOnly.rawValue
                            )
                        )
                        skipped += 1
                        continue
                    }
                }

                // Create parent directories.
                if !dryRun {
                    try FileManager.default.createDirectory(
                        at: destURL.deletingLastPathComponent(),
                        withIntermediateDirectories: true
                    )
                }

                // Write planned -> started -> completed.
                try await journalWriter.append(
                    JournalEntry(
                        planId: planId,
                        operationId: operation.operationId,
                        state: .planned,
                        operationType: toExecutionOpType(operation.operationType),
                        itemId: operation.itemId,
                        resolvedDestPath: operation.resolvedDestPath
                    )
                )

                let sourceStat = fileStatForSource(
                    url: sourceURL,
                    fallbackSizeBytes: row.expectedSizeBytes,
                    fallbackModifiedTime: row.expectedModifiedTime,
                    isPackage: row.isPackage
                )

                switch operation.operationType {
                case .copyItem:
                    try await executeCopyItem(
                        planId: planId,
                        operationId: operation.operationId,
                        itemId: operation.itemId,
                        sourceURL: sourceURL,
                        destURL: destURL,
                        sourceStat: sourceStat,
                        journalWriter: journalWriter
                    )
                case .moveItem:
                    try await executeMoveItem(
                        planId: planId,
                        operationId: operation.operationId,
                        itemId: operation.itemId,
                        sourceURL: sourceURL,
                        destURL: destURL,
                        sourceStat: sourceStat,
                        journalWriter: journalWriter
                    )
                case .applyTags:
                    // Phase 4/5: tag operations. For now, skip.
                    try await journalWriter.append(
                        JournalEntry(
                            planId: planId,
                            operationId: operation.operationId,
                            state: .skipped,
                            operationType: .applyTags,
                            itemId: operation.itemId,
                            resolvedDestPath: operation.resolvedDestPath,
                            error: "applyTags not implemented in Phase 3",
                            reasonCode: ApplyReasonCode.accessError.rawValue
                        )
                    )
                    skipped += 1
                    continue
                }

                completed += 1
            } catch {
                let (reasonCode, shouldAbort) = mapApplyError(error)
                try await journalWriter.append(
                    JournalEntry(
                        planId: planId,
                        operationId: operation.operationId,
                        state: .failed,
                        operationType: toExecutionOpType(operation.operationType),
                        itemId: operation.itemId,
                        resolvedDestPath: operation.resolvedDestPath,
                        error: String(describing: error),
                        reasonCode: reasonCode
                    )
                )
                failed += 1
                if shouldAbort {
                    throw error
                }
            }
        }

        return ApplyResult(
            planId: planId,
            totalOperations: total,
            completedCount: completed,
            skippedCount: skipped,
            failedCount: failed,
            dryRun: dryRun
        )
    }

    private func dryRunApply(
        planId: EntityID,
        project: Project,
        rows: [PlanStore.PlanOperationExecutionRow],
        total: Int,
        progressHandler: ApplyProgressHandler?
    ) throws -> ApplyResult {
        var completed = 0
        var skipped = 0
        var failed = 0

        for (index, row) in rows.enumerated() {
            let operation = row.operation
            let sourceURL = URL(fileURLWithPath: sourcePathForExecution(row: row, project: project))
            progressHandler?(index + 1, total, sourceURL.path)

            let destURL = URL(fileURLWithPath: operation.resolvedDestPath)

            if !FileManager.default.fileExists(atPath: sourceURL.path) {
                failed += 1
                continue
            }
            if FileManager.default.fileExists(atPath: destURL.path) {
                skipped += 1
                continue
            }
            completed += 1
        }

        return ApplyResult(
            planId: planId,
            totalOperations: total,
            completedCount: completed,
            skippedCount: skipped,
            failedCount: failed,
            dryRun: true
        )
    }

    private func resumeStartedOperation(
        row: PlanStore.PlanOperationExecutionRow,
        sourceURL: URL,
        destURL: URL,
        existingState: JournalState,
        copyStatsByOperationId: [String: FileStat],
        journalWriter: JournalWriter
    ) async throws -> OperationState {
        let operation = row.operation
        let opType = operation.operationType

        // If destination exists, treat as completed for copy operations.
        if opType == .copyItem, FileManager.default.fileExists(atPath: destURL.path) {
            try await journalWriter.append(
                JournalEntry(
                    planId: operation.planId,
                    operationId: operation.operationId,
                    state: .completed,
                    operationType: toExecutionOpType(opType),
                    itemId: operation.itemId,
                    resolvedDestPath: operation.resolvedDestPath,
                    copyStatAtTime: copyStatsByOperationId[operation.operationId],
                    reasonCode: nil
                )
            )
            return .completed
        }

        // If destination exists and source is absent, treat as completed for move operations.
        if opType == .moveItem,
           FileManager.default.fileExists(atPath: destURL.path),
           !FileManager.default.fileExists(atPath: sourceURL.path) {
            try await journalWriter.append(
                JournalEntry(
                    planId: operation.planId,
                    operationId: operation.operationId,
                    state: .completed,
                    operationType: toExecutionOpType(opType),
                    itemId: operation.itemId,
                    resolvedDestPath: operation.resolvedDestPath
                )
            )
            return .completed
        }

        // Best-effort resume for cross-volume moves/copies using phase/tempPath.
        if let phase = existingState.phase {
            if phase == "delete" {
                // Destination should already exist; delete original if present.
                if FileManager.default.fileExists(atPath: sourceURL.path) {
                    try FileManager.default.removeItem(at: sourceURL)
                }

                if FileManager.default.fileExists(atPath: destURL.path) {
                    try await journalWriter.append(
                        JournalEntry(
                            planId: operation.planId,
                            operationId: operation.operationId,
                            state: .completed,
                            operationType: toExecutionOpType(opType),
                            itemId: operation.itemId,
                            resolvedDestPath: operation.resolvedDestPath
                        )
                    )
                    return .completed
                }
            }

            if phase == "copy", let tempPath = existingState.tempPath, !tempPath.isEmpty {
                let tempURL = URL(fileURLWithPath: tempPath)

                // If temp exists, try to finalize into destination (if safe).
                if FileManager.default.fileExists(atPath: tempURL.path) {
                    if !FileManager.default.fileExists(atPath: destURL.path) {
                        try FileManager.default.moveItem(at: tempURL, to: destURL)
                    } else {
                        try await journalWriter.append(
                            JournalEntry(
                                planId: operation.planId,
                                operationId: operation.operationId,
                                state: .skipped,
                                operationType: toExecutionOpType(opType),
                                itemId: operation.itemId,
                                resolvedDestPath: operation.resolvedDestPath,
                                error: "Destination already exists during resume: \(destURL.path)",
                                reasonCode: ApplyReasonCode.applyTimeCollision.rawValue
                            )
                        )
                        return .skipped
                    }
                }

                if FileManager.default.fileExists(atPath: destURL.path) {
                    // For cross-volume moves, proceed to delete original.
                    if opType == .moveItem, FileManager.default.fileExists(atPath: sourceURL.path) {
                        try FileManager.default.removeItem(at: sourceURL)
                    }

                    try await journalWriter.append(
                        JournalEntry(
                            planId: operation.planId,
                            operationId: operation.operationId,
                            state: .completed,
                            operationType: toExecutionOpType(opType),
                            itemId: operation.itemId,
                            resolvedDestPath: operation.resolvedDestPath
                        )
                    )
                    return .completed
                }
            }
        }

        // Fallback: restart as new (but never overwrite existing destination).
        if FileManager.default.fileExists(atPath: destURL.path) {
            try await journalWriter.append(
                JournalEntry(
                    planId: operation.planId,
                    operationId: operation.operationId,
                    state: .skipped,
                    operationType: toExecutionOpType(opType),
                    itemId: operation.itemId,
                    resolvedDestPath: operation.resolvedDestPath,
                    error: "Destination already exists during resume fallback: \(destURL.path)",
                    reasonCode: ApplyReasonCode.applyTimeCollision.rawValue
                )
            )
            return .skipped
        }

        return .planned
    }

    private func executeCopyItem(
        planId: EntityID,
        operationId: String,
        itemId: String,
        sourceURL: URL,
        destURL: URL,
        sourceStat: FileStat,
        journalWriter: JournalWriter
    ) async throws {
        let tempURL = tempURLForDestination(destURL: destURL, operationId: operationId)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }

        try await journalWriter.append(
            JournalEntry(
                planId: planId,
                operationId: operationId,
                state: .started,
                operationType: .copyItem,
                itemId: itemId,
                resolvedDestPath: destURL.path,
                tempPath: tempURL.path,
                phase: "copy",
                copyStatAtTime: sourceStat
            )
        )

        try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        try await journalWriter.append(
            JournalEntry(
                planId: planId,
                operationId: operationId,
                state: .completed,
                operationType: .copyItem,
                itemId: itemId,
                resolvedDestPath: destURL.path,
                copyStatAtTime: sourceStat
            )
        )
    }

    private func executeMoveItem(
        planId: EntityID,
        operationId: String,
        itemId: String,
        sourceURL: URL,
        destURL: URL,
        sourceStat: FileStat,
        journalWriter: JournalWriter
    ) async throws {
        let crossVolume = volumeDetector.isCrossVolume(source: sourceURL, destination: destURL)

        if !crossVolume {
            try await journalWriter.append(
                JournalEntry(
                    planId: planId,
                    operationId: operationId,
                    state: .started,
                    operationType: .moveItem,
                    itemId: itemId,
                    resolvedDestPath: destURL.path
                )
            )

            do {
                try FileManager.default.moveItem(at: sourceURL, to: destURL)
            } catch {
                if isCrossDeviceMoveError(error) {
                    try await executeCrossVolumeMove(
                        planId: planId,
                        operationId: operationId,
                        itemId: itemId,
                        sourceURL: sourceURL,
                        destURL: destURL,
                        sourceStat: sourceStat,
                        journalWriter: journalWriter
                    )
                    return
                }
                throw error
            }

            try await journalWriter.append(
                JournalEntry(
                    planId: planId,
                    operationId: operationId,
                    state: .completed,
                    operationType: .moveItem,
                    itemId: itemId,
                    resolvedDestPath: destURL.path,
                    copyStatAtTime: sourceStat
                )
            )
            return
        }

        try await executeCrossVolumeMove(
            planId: planId,
            operationId: operationId,
            itemId: itemId,
            sourceURL: sourceURL,
            destURL: destURL,
            sourceStat: sourceStat,
            journalWriter: journalWriter
        )
    }

    private func executeCrossVolumeMove(
        planId: EntityID,
        operationId: String,
        itemId: String,
        sourceURL: URL,
        destURL: URL,
        sourceStat: FileStat,
        journalWriter: JournalWriter
    ) async throws {
        let tempURL = tempURLForDestination(destURL: destURL, operationId: operationId)
        if FileManager.default.fileExists(atPath: tempURL.path) {
            try? FileManager.default.removeItem(at: tempURL)
        }

        // Phase 1: copy to temp
        try await journalWriter.append(
            JournalEntry(
                planId: planId,
                operationId: operationId,
                state: .started,
                operationType: .moveItem,
                itemId: itemId,
                resolvedDestPath: destURL.path,
                tempPath: tempURL.path,
                phase: "copy",
                copyStatAtTime: sourceStat
            )
        )
        try FileManager.default.copyItem(at: sourceURL, to: tempURL)
        try FileManager.default.moveItem(at: tempURL, to: destURL)

        // Phase 2: delete original
        try await journalWriter.append(
            JournalEntry(
                planId: planId,
                operationId: operationId,
                state: .started,
                operationType: .moveItem,
                itemId: itemId,
                resolvedDestPath: destURL.path,
                phase: "delete"
            )
        )
        try FileManager.default.removeItem(at: sourceURL)

        try await journalWriter.append(
            JournalEntry(
                planId: planId,
                operationId: operationId,
                state: .completed,
                operationType: .moveItem,
                itemId: itemId,
                resolvedDestPath: destURL.path,
                copyStatAtTime: sourceStat
            )
        )
    }

    private func sourcePathForExecution(row: PlanStore.PlanOperationExecutionRow, project: Project) -> String {
        if let currentRoot = project.sourceRoots.first(where: { $0.id == row.sourceRootId })?.path {
            let combined = (currentRoot as NSString).appendingPathComponent(row.relativePath)
            return URL(fileURLWithPath: combined).standardizedFileURL.path
        }
        return URL(fileURLWithPath: row.sourcePathAtScan).standardizedFileURL.path
    }

    private func tempURLForDestination(destURL: URL, operationId: String) -> URL {
        let dir = destURL.deletingLastPathComponent()
        return dir.appendingPathComponent(".organize-temp-\(operationId)")
    }

    private func fileStatForSource(
        url: URL,
        fallbackSizeBytes: Int64,
        fallbackModifiedTime: Date,
        isPackage: Bool
    ) -> FileStat {
        if isPackage {
            return FileStat(sizeBytes: fallbackSizeBytes, modifiedTime: fallbackModifiedTime)
        }

        if let values = try? url.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey]),
           let size = values.fileSize,
           let mtime = values.contentModificationDate {
            return FileStat(sizeBytes: Int64(size), modifiedTime: mtime)
        }

        return FileStat(sizeBytes: fallbackSizeBytes, modifiedTime: fallbackModifiedTime)
    }

    private func toExecutionOpType(_ planType: PlanOperationType) -> ExecutionOperationType {
        switch planType {
        case .copyItem: return .copyItem
        case .moveItem: return .moveItem
        case .applyTags: return .applyTags
        }
    }

    private func isCrossDeviceMoveError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == EXDEV {
            return true
        }
        // Cocoa wrapper
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteUnknownError {
            // Some cases wrap EXDEV; fall back to false unless POSIX indicates.
            return false
        }
        return false
    }

    private func mapApplyError(_ error: Error) -> (reasonCode: String, shouldAbort: Bool) {
        if isOutOfSpaceError(error) {
            return (ApplyReasonCode.diskFull.rawValue, true)
        }
        return (ApplyReasonCode.accessError.rawValue, false)
    }

    private func isOutOfSpaceError(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain && nsError.code == ENOSPC {
            return true
        }
        if nsError.domain == NSCocoaErrorDomain && nsError.code == NSFileWriteOutOfSpaceError {
            return true
        }
        return false
    }

    public enum ApplyError: Error {
        case planNotFound(planId: EntityID)
    }
}
