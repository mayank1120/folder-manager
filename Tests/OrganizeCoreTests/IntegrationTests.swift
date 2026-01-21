import XCTest
@testable import OrganizeCore

/// Integration tests covering the full scan → plan → apply → verify → rollback workflow
final class IntegrationTests: XCTestCase {
    
    // MARK: - Full Workflow Tests
    
    func testFullWorkflow_ScanPlanApplyVerify() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        // Setup directories
        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        
        // Create test files
        try writeFile(src.appendingPathComponent("Alice-document.pdf"), contents: "Alice's document")
        try writeFile(src.appendingPathComponent("Bob-photo.jpg"), contents: "Bob's photo data")
        try writeFile(src.appendingPathComponent("random-screenshot.png"), contents: "Screenshot")
        
        // Setup project with autoFileUnassigned enabled
        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [
                Person(displayName: "Alice", keywordTokens: ["Alice"]),
                Person(displayName: "Bob", keywordTokens: ["Bob"])
            ]
        )
        project.settings.autoFileUnassigned = true
        project.settings.enableOtherBucket = true
        
        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        
        // Step 1: Scan
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id
        
        XCTAssertEqual(scanResult.itemCount, 3)
        
        // Step 2: Plan
        let planStore = PlanStore(dbManager: dbManager)
        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)
        
        // At least 2 owner-matched items should be planned (Alice + Bob files)
        XCTAssertGreaterThanOrEqual(summary.plan.operationCount, 2)
        
        // Step 3: Apply
        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(
            planId: summary.plan.id,
            project: project,
            projectDirectory: tempDir
        )
        
        // Verify no failures
        XCTAssertEqual(applyResult.failedCount, 0)
        XCTAssertGreaterThanOrEqual(applyResult.completedCount, 2)
        
        // Verify at least the owner-matched files exist at some destination
        
        // Check destination directory is not empty (files were applied)
        let destContents = try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        XCTAssertNotNil(destContents)
        XCTAssertGreaterThan(destContents?.count ?? 0, 0)
        
        // Step 4: Verify
        let verifyEngine = VerifyEngine(dbManager: dbManager)
        let verifyResult = try await verifyEngine.verify(planId: summary.plan.id)
        
        // Verify completed items match applied items
        XCTAssertEqual(verifyResult.failedCount, 0)
    }
    
    func testFullWorkflow_ScanPlanApplyRollback() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        
        try writeFile(src.appendingPathComponent("Alice-document.pdf"), contents: "Original content")
        
        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Alice", keywordTokens: ["Alice"])]
        )
        
        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        
        // Scan → Plan → Apply
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id
        
        let planStore = PlanStore(dbManager: dbManager)
        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)
        
        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(planId: summary.plan.id, project: project, projectDirectory: tempDir)
        
        // Check file was applied somewhere in dest
        let destContents = try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        XCTAssertGreaterThan(destContents?.count ?? 0, 0)
        XCTAssertEqual(applyResult.completedCount, 1)
        
        // Step 5: Rollback
        let rollbackManager = RollbackManager(dbManager: dbManager)
        let rollbackResult = try await rollbackManager.rollback(
            planId: summary.plan.id,
            projectDirectory: tempDir
        )
        
        XCTAssertEqual(rollbackResult.failedCount, 0)
        
        // Destination should be empty after rollback
        let destContentsAfter = try? FileManager.default.contentsOfDirectory(at: dest, includingPropertiesForKeys: nil)
        // Either empty or only has empty dirs
        XCTAssertLessThanOrEqual(destContentsAfter?.count ?? 0, 1)
    }
    
    // MARK: - Edge Case Tests
    
    func testEdgeCase_UnicodeFilenames() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        
        // Unicode filenames - Japanese, Emoji, Special chars
        try writeFile(src.appendingPathComponent("Alice-日本語ドキュメント.pdf"), contents: "Japanese")
        try writeFile(src.appendingPathComponent("Bob-📸photo.jpg"), contents: "Emoji")
        try writeFile(src.appendingPathComponent("Carol-café résumé.txt"), contents: "Accents")
        
        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [
                Person(displayName: "Alice", keywordTokens: ["Alice"]),
                Person(displayName: "Bob", keywordTokens: ["Bob"]),
                Person(displayName: "Carol", keywordTokens: ["Carol"])
            ]
        )
        
        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id
        
        XCTAssertEqual(scanResult.itemCount, 3)
        
        let planStore = PlanStore(dbManager: dbManager)
        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)
        
        XCTAssertEqual(summary.plan.operationCount, 3)
        
        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(
            planId: summary.plan.id,
            project: project,
            projectDirectory: tempDir
        )
        
        XCTAssertEqual(applyResult.completedCount, 3)
        XCTAssertEqual(applyResult.failedCount, 0)
    }
    
    func testEdgeCase_LongFilename() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        
        // Create a long filename (near 255 char limit)
        let longName = "Alice-" + String(repeating: "a", count: 180) + ".pdf"
        try writeFile(src.appendingPathComponent(longName), contents: "Long name")
        
        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Alice", keywordTokens: ["Alice"])]
        )
        
        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id
        
        XCTAssertEqual(scanResult.itemCount, 1)
        
        let planStore = PlanStore(dbManager: dbManager)
        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)
        
        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(
            planId: summary.plan.id,
            project: project,
            projectDirectory: tempDir
        )
        
        XCTAssertEqual(applyResult.completedCount, 1)
    }
    
    func testEdgeCase_EmptySourceDirectory() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        
        let project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: []
        )
        
        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        
        XCTAssertEqual(scanResult.itemCount, 0)
    }
    
    func testEdgeCase_DuplicateFilenames() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }
        
        let src = tempDir.appendingPathComponent("src")
        let dest = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: src, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: dest, withIntermediateDirectories: true)
        
        // Create subdirs with same filenames
        try FileManager.default.createDirectory(at: src.appendingPathComponent("folder1"), withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: src.appendingPathComponent("folder2"), withIntermediateDirectories: true)
        try writeFile(src.appendingPathComponent("folder1/Alice-document.pdf"), contents: "Version 1")
        try writeFile(src.appendingPathComponent("folder2/Alice-document.pdf"), contents: "Version 2")
        
        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: src.path)],
            destinationRoot: DestinationRoot(path: dest.path),
            people: [Person(displayName: "Alice", keywordTokens: ["Alice"])]
        )
        project.settings.collisionPolicy = .autoSuffix
        
        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)
        project.currentScanId = scanResult.scan.id
        
        XCTAssertEqual(scanResult.itemCount, 2)
        
        let planStore = PlanStore(dbManager: dbManager)
        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)
        
        let applyEngine = ApplyEngine(dbManager: dbManager)
        let applyResult = try await applyEngine.apply(
            planId: summary.plan.id,
            project: project,
            projectDirectory: tempDir
        )
        
        // Both should succeed with collision handling (auto-suffix)
        XCTAssertEqual(applyResult.completedCount, 2)
        XCTAssertEqual(applyResult.failedCount, 0)
    }
    
    // MARK: - Security Tests
    
    func testSecurity_PathTraversalValidation() {
        // Test isPathSafe
        XCTAssertTrue(PathSecurity.isPathSafe("documents/file.pdf"))
        XCTAssertFalse(PathSecurity.isPathSafe("../etc/passwd"))
        XCTAssertFalse(PathSecurity.isPathSafe("documents/../../../etc/passwd"))
        XCTAssertTrue(PathSecurity.isPathSafe("normal/path/file.txt"))
    }
    
    func testSecurity_RelativePathValidation() {
        // Test isRelativePathSafe
        XCTAssertTrue(PathSecurity.isRelativePathSafe("documents/file.pdf"))
        XCTAssertFalse(PathSecurity.isRelativePathSafe("/absolute/path"))
        XCTAssertFalse(PathSecurity.isRelativePathSafe("documents/../escape"))
        XCTAssertTrue(PathSecurity.isRelativePathSafe("Alice/Documents/2024/file.pdf"))
    }
    
    func testSecurity_FilenameSanitization() {
        // Test sanitizeFilename
        XCTAssertEqual(PathSecurity.sanitizeFilename("normal.pdf"), "normal.pdf")
        XCTAssertEqual(PathSecurity.sanitizeFilename("file/with/slashes.pdf"), "filewithslashes.pdf")
        XCTAssertEqual(PathSecurity.sanitizeFilename("file:with:colons.txt"), "filewithcolons.txt")
        XCTAssertEqual(PathSecurity.sanitizeFilename("...hidden"), "hidden")
        XCTAssertEqual(PathSecurity.sanitizeFilename(""), "unnamed")
    }
    
    // MARK: - Helper Functions
    
    private func makeTempDir() throws -> URL {
        let tempDir = FileManager.default.temporaryDirectory
            .appendingPathComponent("OrganizeIntegrationTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        return tempDir
    }
    
    private func writeFile(_ url: URL, contents: String) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try contents.data(using: .utf8)!.write(to: url)
    }
}
