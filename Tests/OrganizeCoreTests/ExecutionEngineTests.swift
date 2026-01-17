import XCTest
@testable import OrganizeCore

final class ExecutionEngineTests: XCTestCase {
    func testApplyCopyFirstAndVerifyHappyPath() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try writeFile(src.appendingPathComponent("Mayank-document.pdf"), contents: "hello")
        try writeFile(src.appendingPathComponent("Mayank-note.txt"), contents: "world")

        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["Mayank"])]
        )

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)
        XCTAssertEqual(summary.moveEligibleCount, 2)

        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(
            planId: summary.plan.id,
            project: project,
            projectDirectory: tempDir
        )
        XCTAssertEqual(applyResult.totalOperations, 2)
        XCTAssertEqual(applyResult.completedCount, 2)
        XCTAssertEqual(applyResult.skippedCount, 0)
        XCTAssertEqual(applyResult.failedCount, 0)
        XCTAssertFalse(applyResult.dryRun)

        let ops = try await planStore.fetchPlanOperationExecutionRows(planId: summary.plan.id)
        for op in ops {
            XCTAssertTrue(FileManager.default.fileExists(atPath: op.operation.resolvedDestPath))
        }

        let journalURL = tempDir.appendingPathComponent(summary.plan.journalPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: journalURL.path))

        let verifyEngine = VerifyEngine(dbManager: dbManager)
        let verifyResult = try await verifyEngine.verify(planId: summary.plan.id)
        XCTAssertTrue(verifyResult.passed)
        XCTAssertEqual(verifyResult.completedCount, 2)
        XCTAssertEqual(verifyResult.skippedCount, 0)
        XCTAssertEqual(verifyResult.failedCount, 0)
    }

    func testApplyTimeCollisionResultsInSkipAndVerifyFails() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try writeFile(src.appendingPathComponent("Mayank-note.txt"), contents: "world")

        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["Mayank"])]
        )

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)
        XCTAssertEqual(summary.moveEligibleCount, 1)

        let ops = try await planStore.fetchPlanOperationExecutionRows(planId: summary.plan.id)
        let plannedDestPath = ops.first?.operation.resolvedDestPath
        XCTAssertNotNil(plannedDestPath)

        // Create an unexpected destination file after planning but before applying.
        if let plannedDestPath {
            let plannedDestURL = URL(fileURLWithPath: plannedDestPath)
            try FileManager.default.createDirectory(at: plannedDestURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try Data("collision".utf8).write(to: plannedDestURL, options: .atomic)
        }

        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(
            planId: summary.plan.id,
            project: project,
            projectDirectory: tempDir
        )

        XCTAssertEqual(applyResult.totalOperations, 1)
        XCTAssertEqual(applyResult.completedCount, 0)
        XCTAssertEqual(applyResult.skippedCount, 1)
        XCTAssertEqual(applyResult.failedCount, 0)

        let verifyEngine = VerifyEngine(dbManager: dbManager)
        let verifyResult = try await verifyEngine.verify(planId: summary.plan.id)
        XCTAssertFalse(verifyResult.passed)
        XCTAssertEqual(verifyResult.completedCount, 0)
        XCTAssertEqual(verifyResult.skippedCount, 1)
        XCTAssertEqual(verifyResult.failedCount, 0)
    }

    func testVerifyDetectsHashMismatchWhenSizeSame() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try writeFile(src.appendingPathComponent("Mayank-note.txt"), contents: "hello")

        let project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["Mayank"])]
        )

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)

        let applyEngine = ApplyEngine(dbManager: dbManager)
        _ = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)

        let ops = try await planStore.fetchPlanOperationExecutionRows(planId: summary.plan.id)
        guard let destPath = ops.first?.operation.resolvedDestPath else {
            XCTFail("Missing destination path")
            return
        }

        // Change destination content but keep size the same to trigger hash mismatch.
        try Data("world".utf8).write(to: URL(fileURLWithPath: destPath), options: .atomic)

        let verifyEngine = VerifyEngine(dbManager: dbManager)
        let verifyResult = try await verifyEngine.verify(planId: summary.plan.id)

        XCTAssertFalse(verifyResult.passed)
        XCTAssertEqual(verifyResult.failedCount, 1)
        XCTAssertEqual(verifyResult.failures.first?.issue, .hashMismatch)
    }

    func testApplySkipsCloudOnlyWhenDownloadBeforeProcessingOff() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try writeFile(src.appendingPathComponent("Mayank-note.txt"), contents: "world")

        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["Mayank"])]
        )
        project.settings.downloadBeforeProcessing = false

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)
        XCTAssertEqual(summary.moveEligibleCount, 1)

        // Force apply-time cloud-only behavior via dependency injection.
        let cloud = CloudDownloadHandler(
            isCloudOnly: { _ in true },
            startDownload: { _ in },
            waitForDownload: { _ in }
        )
        let applyEngine = ApplyEngine(dbManager: dbManager, cloudDownloadHandler: cloud)
        let applyResult = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)

        XCTAssertEqual(applyResult.totalOperations, 1)
        XCTAssertEqual(applyResult.completedCount, 0)
        XCTAssertEqual(applyResult.skippedCount, 1)
        XCTAssertEqual(applyResult.failedCount, 0)

        let ops = try await planStore.fetchPlanOperationExecutionRows(planId: summary.plan.id)
        XCTAssertEqual(ops.count, 1)
        XCTAssertFalse(FileManager.default.fileExists(atPath: ops[0].operation.resolvedDestPath))

        let journalURL = tempDir.appendingPathComponent(summary.plan.journalPath)
        let entries = try readJournalEntries(from: journalURL)
        XCTAssertTrue(entries.contains { $0.operationId == ops[0].operation.operationId && $0.state == .skipped && $0.reasonCode == ApplyReasonCode.cloudOnly.rawValue })
    }

    func testApplySkipsWhenDownloadFailsAndDownloadBeforeProcessingOn() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try writeFile(src.appendingPathComponent("Mayank-note.txt"), contents: "world")

        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["Mayank"])]
        )
        project.settings.downloadBeforeProcessing = true

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)
        XCTAssertEqual(summary.moveEligibleCount, 1)

        let cloud = CloudDownloadHandler(
            isCloudOnly: { _ in true },
            startDownload: { _ in },
            waitForDownload: { _ in throw CloudDownloadHandler.CloudDownloadError.timeout }
        )
        let applyEngine = ApplyEngine(dbManager: dbManager, cloudDownloadHandler: cloud)
        let applyResult = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)

        XCTAssertEqual(applyResult.totalOperations, 1)
        XCTAssertEqual(applyResult.completedCount, 0)
        XCTAssertEqual(applyResult.skippedCount, 1)
        XCTAssertEqual(applyResult.failedCount, 0)

        let ops = try await planStore.fetchPlanOperationExecutionRows(planId: summary.plan.id)
        XCTAssertEqual(ops.count, 1)

        let journalURL = tempDir.appendingPathComponent(summary.plan.journalPath)
        let entries = try readJournalEntries(from: journalURL)
        XCTAssertTrue(entries.contains { $0.operationId == ops[0].operation.operationId && $0.state == .skipped && $0.reasonCode == ApplyReasonCode.downloadFailed.rawValue })
    }

    func testResumeCopyItemWritesCompletedEntryWithCopyStatAtTime() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let sourceFile = src.appendingPathComponent("Mayank-note.txt")
        try writeFile(sourceFile, contents: "world")

        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["Mayank"])]
        )

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)
        XCTAssertEqual(summary.moveEligibleCount, 1)

        let ops = try await planStore.fetchPlanOperationExecutionRows(planId: summary.plan.id)
        XCTAssertEqual(ops.count, 1)
        let op = ops[0]

        // Simulate a crash after the copy finished: destination exists, journal_state says "started".
        let destURL = URL(fileURLWithPath: op.operation.resolvedDestPath)
        try FileManager.default.createDirectory(at: destURL.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("world".utf8).write(to: destURL, options: .atomic)

        let journalURL = tempDir.appendingPathComponent(summary.plan.journalPath)
        try FileManager.default.createDirectory(at: journalURL.deletingLastPathComponent(), withIntermediateDirectories: true)

        let sourceValues = try sourceFile.resourceValues(forKeys: [.fileSizeKey, .contentModificationDateKey])
        let stat = FileStat(
            sizeBytes: Int64(sourceValues.fileSize ?? 0),
            modifiedTime: sourceValues.contentModificationDate ?? Date()
        )

        let startedEntry = JournalEntry(
            planId: summary.plan.id,
            operationId: op.operation.operationId,
            state: .started,
            operationType: .copyItem,
            itemId: op.operation.itemId,
            resolvedDestPath: op.operation.resolvedDestPath,
            copyStatAtTime: stat
        )
        try writeJournalEntry(startedEntry, to: journalURL)

        let journalStore = JournalStore(dbManager: dbManager)
        try await journalStore.saveState(
            JournalState(
                planId: summary.plan.id,
                operationId: op.operation.operationId,
                currentState: .started,
                lastUpdated: Int64(Date().timeIntervalSince1970),
                tempPath: nil,
                phase: "copy"
            )
        )

        // Resume apply. This should mark the operation as completed and preserve copyStatAtTime.
        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)
        XCTAssertEqual(applyResult.completedCount, 1)

        let entries = try readJournalEntries(from: journalURL)
        XCTAssertTrue(
            entries.contains { $0.operationId == op.operation.operationId && $0.state == .completed && $0.copyStatAtTime != nil },
            "Expected a completed journal entry with copyStatAtTime after resume"
        )
    }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("organize-exec-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url, options: .atomic)
}

private func readJournalEntries(from url: URL) throws -> [JournalEntry] {
    guard FileManager.default.fileExists(atPath: url.path) else {
        return []
    }
    let data = try Data(contentsOf: url)
    let lines = String(decoding: data, as: UTF8.self).split(separator: "\n")

    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601

    return lines.compactMap { line in
        guard let lineData = String(line).data(using: .utf8) else { return nil }
        return try? decoder.decode(JournalEntry.self, from: lineData)
    }
}

private func writeJournalEntry(_ entry: JournalEntry, to url: URL) throws {
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys]
    encoder.dateEncodingStrategy = .iso8601

    let data = try encoder.encode(entry)
    var line = Data()
    line.append(data)
    line.append(0x0A)

    if !FileManager.default.fileExists(atPath: url.path) {
        FileManager.default.createFile(atPath: url.path, contents: nil)
    }

    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: line)
    try handle.synchronize()
}
