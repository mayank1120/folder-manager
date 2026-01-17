import XCTest
@testable import OrganizeCore

final class DeleteOriginalsTests: XCTestCase {
    func testDeleteOriginalsHappyPath() async throws {
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
        project.settings.deleteOriginalsMode = .archiveToBackup

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)

        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)
        XCTAssertEqual(applyResult.completedCount, 2)

        // Force delete-originals to bypass verification gate; this test targets the pre-delete
        // source modification check, which should still skip the item.
        let deleteEngine = DeleteOriginalsEngine(dbManager: dbManager)
        let deleteResult = try await deleteEngine.deleteOriginals(
            planId: summary.plan.id,
            project: project,
            projectDirectory: tempDir,
            force: true
        )

        XCTAssertEqual(deleteResult.totalEligible, 2)
        XCTAssertEqual(deleteResult.deletedCount, 2)
        XCTAssertEqual(deleteResult.skippedCount, 0)
        XCTAssertEqual(deleteResult.failedCount, 0)
        XCTAssertEqual(deleteResult.mode, .archiveToBackup)

        // Source files should be gone.
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("Mayank-document.pdf").path))
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("Mayank-note.txt").path))

        // Archive should exist.
        let backupDir = dest.appendingPathComponent("_OriginalsBackup")
        XCTAssertTrue(FileManager.default.fileExists(atPath: backupDir.path))
    }

    func testDeleteOriginalsFailsWithoutVerification() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try writeFile(src.appendingPathComponent("Mayank-document.pdf"), contents: "hello")

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

        // Don't apply – go straight to delete (should fail).
        let deleteEngine = DeleteOriginalsEngine(dbManager: dbManager)
        do {
            _ = try await deleteEngine.deleteOriginals(
                planId: summary.plan.id,
                project: project,
                projectDirectory: tempDir
            )
            XCTFail("Expected verificationNotPassed error")
        } catch DeleteOriginalsError.verificationNotPassed {
            // Expected.
        }

        // Source file should still exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("Mayank-document.pdf").path))
    }

    func testDeleteOriginalsSkipsModifiedSource() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try writeFile(src.appendingPathComponent("Mayank-document.pdf"), contents: "hello")

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

        let applyEngine = ApplyEngine(dbManager: dbManager)
        _ = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)

        // Modify source after apply.
        try writeFile(src.appendingPathComponent("Mayank-document.pdf"), contents: "hello world modified")

        // Force delete-originals to bypass verification gate; this test targets the pre-delete
        // source modification check, which should still skip the item.
        let deleteEngine = DeleteOriginalsEngine(dbManager: dbManager)
        let deleteResult = try await deleteEngine.deleteOriginals(
            planId: summary.plan.id,
            project: project,
            projectDirectory: tempDir,
            force: true
        )

        XCTAssertEqual(deleteResult.deletedCount, 0)
        XCTAssertEqual(deleteResult.skippedCount, 1)

        // Source file should still exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("Mayank-document.pdf").path))
    }

    func testDeleteOriginalsSkipsWhenDestinationMissing() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try writeFile(src.appendingPathComponent("Mayank-document.pdf"), contents: "hello")

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
        let destPath = ops.first?.operation.resolvedDestPath
        XCTAssertNotNil(destPath)

        if let destPath {
            try FileManager.default.removeItem(atPath: destPath)
        }

        let deleteEngine = DeleteOriginalsEngine(dbManager: dbManager)
        let deleteResult = try await deleteEngine.deleteOriginals(
            planId: summary.plan.id,
            project: project,
            projectDirectory: tempDir,
            force: true
        )

        XCTAssertEqual(deleteResult.deletedCount, 0)
        XCTAssertEqual(deleteResult.skippedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("Mayank-document.pdf").path))
    }

    func testDeleteOriginalsRecheckUsesCopyTimeNotScanTime() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let sourceFile = src.appendingPathComponent("Mayank-document.pdf")
        try writeFile(sourceFile, contents: "hello")

        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["Mayank"])]
        )
        project.settings.deleteOriginalsMode = .archiveToBackup

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id

        // Change mtime after scan (but keep size the same). Verification should still pass,
        // and delete-originals should compare against the copy-time mtime from the journal.
        try FileManager.default.setAttributes(
            [.modificationDate: Date().addingTimeInterval(10)],
            ofItemAtPath: sourceFile.path
        )

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)

        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)
        XCTAssertEqual(applyResult.completedCount, 1)

        let verifyEngine = VerifyEngine(dbManager: dbManager)
        let verifyResult = try await verifyEngine.verify(planId: summary.plan.id)
        XCTAssertTrue(verifyResult.passed)

        let deleteEngine = DeleteOriginalsEngine(dbManager: dbManager)
        let deleteResult = try await deleteEngine.deleteOriginals(
            planId: summary.plan.id,
            project: project,
            projectDirectory: tempDir
        )

        XCTAssertEqual(deleteResult.deletedCount, 1)
        XCTAssertEqual(deleteResult.skippedCount, 0)
        XCTAssertFalse(FileManager.default.fileExists(atPath: sourceFile.path))
    }

    func testDeleteOriginalsSkipsModifiedPackage() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        let package = src.appendingPathComponent("Mayank-Doc.pages")
        try FileManager.default.createDirectory(at: package, withIntermediateDirectories: true)
        try writeFile(package.appendingPathComponent("content.txt"), contents: "hello")

        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["Mayank"])]
        )
        project.settings.deleteOriginalsMode = .archiveToBackup

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)

        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)
        XCTAssertEqual(applyResult.completedCount, 1)

        let verifyEngine = VerifyEngine(dbManager: dbManager)
        let verifyResult = try await verifyEngine.verify(planId: summary.plan.id)
        XCTAssertTrue(verifyResult.passed)

        // Mutate the source package after apply (destination remains unchanged); delete-originals should skip.
        try writeFile(package.appendingPathComponent("extra.txt"), contents: "more")

        let deleteEngine = DeleteOriginalsEngine(dbManager: dbManager)
        let deleteResult = try await deleteEngine.deleteOriginals(
            planId: summary.plan.id,
            project: project,
            projectDirectory: tempDir
        )

        XCTAssertEqual(deleteResult.deletedCount, 0)
        XCTAssertEqual(deleteResult.skippedCount, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: package.path))
    }
}

final class RollbackTests: XCTestCase {
    func testRollbackMoveRestoresSource() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try writeFile(src.appendingPathComponent("Mayank-document.pdf"), contents: "hello")

        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["Mayank"])]
        )
        project.settings.executionMode = .move

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)

        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)
        XCTAssertEqual(applyResult.completedCount, 1)

        // Source should be gone, dest should exist.
        XCTAssertFalse(FileManager.default.fileExists(atPath: src.appendingPathComponent("Mayank-document.pdf").path))

        let rollbackManager = RollbackManager(dbManager: dbManager)
        let rollbackResult = try await rollbackManager.rollback(planId: summary.plan.id, projectDirectory: tempDir)

        XCTAssertEqual(rollbackResult.rolledBackCount, 1)
        XCTAssertEqual(rollbackResult.skippedCount, 0)
        XCTAssertEqual(rollbackResult.failedCount, 0)

        // Source should be restored.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("Mayank-document.pdf").path))
    }

    func testRollbackCopyDeletesDestination() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try writeFile(src.appendingPathComponent("Mayank-document.pdf"), contents: "hello")

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

        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)
        XCTAssertEqual(applyResult.completedCount, 1)

        let ops = try await planStore.fetchPlanOperationExecutionRows(planId: summary.plan.id)
        let destPath = ops.first?.operation.resolvedDestPath
        XCTAssertNotNil(destPath)
        XCTAssertTrue(FileManager.default.fileExists(atPath: destPath!))

        let rollbackManager = RollbackManager(dbManager: dbManager)
        let rollbackResult = try await rollbackManager.rollback(planId: summary.plan.id, projectDirectory: tempDir)

        XCTAssertEqual(rollbackResult.rolledBackCount, 1)

        // Destination should be deleted.
        XCTAssertFalse(FileManager.default.fileExists(atPath: destPath!))

        // Source should still exist.
        XCTAssertTrue(FileManager.default.fileExists(atPath: src.appendingPathComponent("Mayank-document.pdf").path))
    }

    func testRollbackConflictSkipsWhenSourceExists() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)

        try writeFile(src.appendingPathComponent("Mayank-document.pdf"), contents: "hello")

        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["Mayank"])]
        )
        project.settings.executionMode = .move

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)

        let applyEngine = ApplyEngine(dbManager: dbManager)
        _ = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)

        // Re-create source file (simulating conflict).
        try writeFile(src.appendingPathComponent("Mayank-document.pdf"), contents: "new content")

        let rollbackManager = RollbackManager(dbManager: dbManager)
        let rollbackResult = try await rollbackManager.rollback(planId: summary.plan.id, projectDirectory: tempDir)

        XCTAssertEqual(rollbackResult.skippedCount, 1)
        XCTAssertEqual(rollbackResult.rolledBackCount, 0)

        // Re-running rollback should keep reporting the prior skipped state (resume-safe).
        let rollbackResult2 = try await rollbackManager.rollback(planId: summary.plan.id, projectDirectory: tempDir)
        XCTAssertEqual(rollbackResult2.skippedCount, 1)
        XCTAssertEqual(rollbackResult2.rolledBackCount, 0)

        // Source should retain new content.
        let content = try String(contentsOfFile: src.appendingPathComponent("Mayank-document.pdf").path, encoding: .utf8)
        XCTAssertEqual(content, "new content")
    }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("organize-phase4-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url, options: .atomic)
}
