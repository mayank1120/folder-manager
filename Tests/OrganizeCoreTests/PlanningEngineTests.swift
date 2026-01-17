import XCTest
@testable import OrganizeCore

final class OwnerMatcherTests: XCTestCase {
    func testOwnerMatcherSingleMatch() {
        let people = [
            Person(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, displayName: "Mayank", keywordTokens: ["mayank"]),
            Person(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, displayName: "Juhi", keywordTokens: ["juhi"])
        ]

        let matcher = OwnerMatcher(people: people)
        let result = matcher.match(path: "Docs/Mayank-invoice.pdf")

        XCTAssertEqual(result.bucketName, "Mayank")
        XCTAssertEqual(result.confidence, .confident)
        XCTAssertEqual(result.reason, .singleMatch)
    }

    func testOwnerMatcherMultiMatch() {
        let people = [
            Person(id: UUID(uuidString: "11111111-1111-1111-1111-111111111111")!, displayName: "Mayank", keywordTokens: ["mayank"]),
            Person(id: UUID(uuidString: "22222222-2222-2222-2222-222222222222")!, displayName: "Juhi", keywordTokens: ["juhi"])
        ]

        let matcher = OwnerMatcher(people: people)
        let result = matcher.match(path: "Shared/mayank_juhi_document.pdf")

        XCTAssertEqual(result.bucketName, "Shared")
        XCTAssertEqual(result.confidence, .notConfident)
        XCTAssertEqual(result.reason, .matchedMultiplePeople)
    }

    func testOwnerMatcherNoMatch() {
        let people = [
            Person(displayName: "Mayank", keywordTokens: ["mayank"])
        ]

        let matcher = OwnerMatcher(people: people)
        let result = matcher.match(path: "random.pdf")

        XCTAssertEqual(result.bucketName, "Unassigned")
        XCTAssertEqual(result.confidence, .notConfident)
        XCTAssertEqual(result.reason, .noMatch)
    }

    func testOwnerMatcherCamelCaseSplittingMatches() {
        let people = [
            Person(displayName: "Juhi", keywordTokens: ["juhi"])
        ]

        let matcher = OwnerMatcher(
            people: people,
            settings: OwnerMatchingSettings(enableCamelCaseSplit: true)
        )
        let result = matcher.match(path: "Docs/JuhiBansal.pdf")

        XCTAssertEqual(result.bucketName, "Juhi")
        XCTAssertEqual(result.confidence, .confident)
        XCTAssertEqual(result.reason, .singleMatch)
    }

    func testOwnerMatcherPreservesOriginalTokenWhenCamelCaseSplitting() {
        let people = [
            Person(displayName: "John", keywordTokens: ["johndoe"])
        ]

        let matcher = OwnerMatcher(
            people: people,
            settings: OwnerMatchingSettings(enableCamelCaseSplit: true)
        )
        let result = matcher.match(path: "Docs/JohnDoe.pdf")

        XCTAssertEqual(result.bucketName, "John")
        XCTAssertEqual(result.confidence, .confident)
        XCTAssertEqual(result.reason, .singleMatch)
    }

    func testOwnerMatcherPreservesOriginalTokenWhenDigitSplitting() {
        let people = [
            Person(displayName: "Camera", keywordTokens: ["img2024"])
        ]

        let matcher = OwnerMatcher(
            people: people,
            settings: OwnerMatchingSettings(enableCamelCaseSplit: false, enableDigitSplit: true)
        )
        let result = matcher.match(path: "Photos/IMG2024.jpg")

        XCTAssertEqual(result.bucketName, "Camera")
        XCTAssertEqual(result.confidence, .confident)
        XCTAssertEqual(result.reason, .singleMatch)
    }

    func testOwnerMatcherDecodingDoesNotBreakCaseInsensitiveMatch() throws {
        let json = """
        {
          "id": "11111111-1111-1111-1111-111111111111",
          "displayName": "Mayank",
          "keywordTokens": ["Mayank"]
        }
        """.data(using: .utf8)!

        let decoded = try JSONDecoder().decode(Person.self, from: json)
        let matcher = OwnerMatcher(people: [decoded])
        let result = matcher.match(path: "Docs/mayank-invoice.pdf")

        XCTAssertEqual(result.bucketName, "Mayank")
        XCTAssertEqual(result.reason, .singleMatch)
    }
}

final class DispositionEngineTests: XCTestCase {
    func testPolicyExclusionByExtension() {
        let engine = DispositionEngine()

        let codeItem = InventoryItem(
            id: "id",
            scanId: UUID(),
            sourceRootId: UUID(),
            relativePath: "script.js",
            sizeBytes: 1,
            modifiedTime: Date(),
            uttypeIdentifier: "public.source-code",
            extension: "js"
        )
        XCTAssertEqual(engine.policyExclusionReason(for: codeItem), .policyExcludeCodeFile)

        let configItem = InventoryItem(
            id: "id2",
            scanId: UUID(),
            sourceRootId: UUID(),
            relativePath: "config.json",
            sizeBytes: 1,
            modifiedTime: Date(),
            uttypeIdentifier: "public.json",
            extension: "json"
        )
        XCTAssertEqual(engine.policyExclusionReason(for: configItem), .policyExcludeConfigFile)
    }
}

final class CollisionResolverTests: XCTestCase {
    func testCollisionResolverDeterministicSuffixing() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("organize-collision-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let baseDestPath = destDir.appendingPathComponent("file.pdf").path

        let candidate1 = CollisionCandidate(
            itemId: "a",
            sourcePath: "/src/A/file.pdf",
            baseDestPath: baseDestPath,
            sizeBytes: 10,
            modifiedTime: Date(timeIntervalSince1970: 1000)
        )
        let candidate2 = CollisionCandidate(
            itemId: "b",
            sourcePath: "/src/B/file.pdf",
            baseDestPath: baseDestPath,
            sizeBytes: 10,
            modifiedTime: Date(timeIntervalSince1970: 1000)
        )

        let resolver = CollisionResolver(fileExists: { FileManager.default.fileExists(atPath: $0) })
        let result1 = resolver.resolve(candidates: [candidate1, candidate2]).sorted { $0.itemId < $1.itemId }
        let result2 = resolver.resolve(candidates: [candidate1, candidate2]).sorted { $0.itemId < $1.itemId }

        XCTAssertEqual(result1, result2, "Resolution should be deterministic")
        XCTAssertEqual(Set(result1.map(\.resolvedDestPath)).count, 2, "Resolved paths should be unique")
        XCTAssertTrue(result1.contains(where: { $0.collisionResolved == true }))
    }

    func testCollisionResolverHandlesExistingDestination() throws {
        let tempDir = FileManager.default.temporaryDirectory.appendingPathComponent("organize-collision-tests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let destDir = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: destDir, withIntermediateDirectories: true)

        let baseDestURL = destDir.appendingPathComponent("file.pdf")
        try Data("x".utf8).write(to: baseDestURL)

        let candidate = CollisionCandidate(
            itemId: "a",
            sourcePath: "/src/A/file.pdf",
            baseDestPath: baseDestURL.path,
            sizeBytes: 10,
            modifiedTime: Date(timeIntervalSince1970: 1000)
        )

        let resolver = CollisionResolver()
        let result = resolver.resolve(candidates: [candidate])
        XCTAssertEqual(result.count, 1)
        XCTAssertNotEqual(result.first?.resolvedDestPath, baseDestURL.path)
        XCTAssertEqual(result.first?.collisionResolved, true)
        XCTAssertNotNil(result.first?.conflictToken)
    }
}

final class TypeClassifierTests: XCTestCase {
    func testPDFTopicFromFilenameOnly() {
        let settings = ProjectSettings()
        let classifier = TypeClassifier(settings: settings)

        let item = InventoryItem(
            id: "id",
            scanId: UUID(),
            sourceRootId: UUID(),
            relativePath: "Finance/invoice-123.pdf",
            sizeBytes: 1,
            modifiedTime: Date(),
            uttypeIdentifier: nil,
            extension: "pdf"
        )

        let classification = classifier.classify(item: item)
        XCTAssertEqual(classification?.category, .pdf)
        XCTAssertEqual(classification?.topic, "Receipts")
    }

    func testImageSubcategoryScreenshot() {
        var settings = ProjectSettings()
        settings.screenshotPrefixes = ["Screenshot"]
        settings.cameraPrefixes = ["IMG_"]

        let classifier = TypeClassifier(settings: settings)
        let item = InventoryItem(
            id: "id",
            scanId: UUID(),
            sourceRootId: UUID(),
            relativePath: "Screenshot 2024-01-01.png",
            sizeBytes: 1,
            modifiedTime: Date(),
            uttypeIdentifier: nil,
            extension: "png"
        )

        let classification = classifier.classify(item: item)
        XCTAssertEqual(classification?.category, .images)
        XCTAssertEqual(classification?.subcategory, "Screenshots")
    }

    func testScanHeuristicRoutesToScans() {
        let settings = ProjectSettings()
        let classifier = TypeClassifier(settings: settings)
        let item = InventoryItem(
            id: "id",
            scanId: UUID(),
            sourceRootId: UUID(),
            relativePath: "scan_0001.pdf",
            sizeBytes: 1,
            modifiedTime: Date(),
            uttypeIdentifier: nil,
            extension: "pdf"
        )

        let classification = classifier.classify(item: item)
        XCTAssertEqual(classification?.category, .scans)
    }
}

final class PlannerIntegrationTests: XCTestCase {
    func testPlannerCreatesPlanAndExports() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let rootA = tempDir.appendingPathComponent("rootA")
        let rootB = tempDir.appendingPathComponent("rootB")
        let destRoot = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)

        try writeFile(rootA.appendingPathComponent("Mayank-invoice.pdf"), contents: "a")
        try writeFile(rootB.appendingPathComponent("Mayank-invoice.pdf"), contents: "b") // collision at dest
        try writeFile(rootA.appendingPathComponent("Juhi-photo.jpg"), contents: "c")
        try writeFile(rootA.appendingPathComponent("unknown.xyz"), contents: "d")
        try writeFile(rootA.appendingPathComponent("mayank_juhi.pdf"), contents: "e")

        let people = [
            Person(displayName: "Mayank", keywordTokens: ["mayank"]),
            Person(displayName: "Juhi", keywordTokens: ["juhi"])
        ]

        let project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: rootA.path), SourceRoot(path: rootB.path)],
            destinationRoot: DestinationRoot(path: destRoot.path),
            people: people
        )

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)

        let planStore = PlanStore(dbManager: dbManager)
        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)

        let exportDir = tempDir.appendingPathComponent("exports").appendingPathComponent(summary.plan.id.uuidString)
        let exporter = ExportManager(dbManager: dbManager)
        let paths = try await exporter.exportPlan(planId: summary.plan.id, to: exportDir)

        let inventoryCSV = try String(contentsOf: paths.inventoryCSV, encoding: .utf8)
        let proposedMovesCSV = try String(contentsOf: paths.proposedMovesCSV, encoding: .utf8)
        let needsReviewCSV = try String(contentsOf: paths.needsReviewCSV, encoding: .utf8)
        let excludedCSV = try String(contentsOf: paths.excludedByPolicyCSV, encoding: .utf8)

        XCTAssertEqual(inventoryCSV.split(separator: "\n").count, 1 + 5) // header + 5 items
        XCTAssertEqual(needsReviewCSV.split(separator: "\n").count, 1 + 1) // mayank_juhi.pdf (autoFileShared default OFF)
        XCTAssertTrue(excludedCSV.contains("PolicyExclude:UnknownType"))

        // Proposed moves: 2 Mayank invoices (one collision-resolved) + 1 Juhi image.
        XCTAssertEqual(proposedMovesCSV.split(separator: "\n").count, 1 + 3)
        XCTAssertTrue(proposedMovesCSV.contains("conflict-"))
    }

    func testExtensionRuleCustomFolderPerOwner() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = tempDir.appendingPathComponent("root")
        let destRoot = tempDir.appendingPathComponent("dest")
        let customPDFs = tempDir.appendingPathComponent("custom-pdfs")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: customPDFs, withIntermediateDirectories: true)

        try writeFile(root.appendingPathComponent("Mayank-report.pdf"), contents: "a")

        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: root.path)],
            destinationRoot: DestinationRoot(path: destRoot.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["mayank"])]
        )

        let rule = ExtensionRule(
            extensions: ["pdf"],
            destinationType: .customFolder,
            destinationPath: customPDFs.path,
            destinationIsAbsolute: true,
            ownerScope: .perOwner,
            priority: 10
        )
        project.settings.extensionRules = [rule]

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)

        let planStore = PlanStore(dbManager: dbManager)
        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)

        let planItems = try await planStore.fetchPlanItemRows(
            planId: summary.plan.id,
            disposition: .moveEligible
        )
        XCTAssertEqual(planItems.count, 1)

        let item = planItems[0].planItem
        let expectedDest = customPDFs
            .appendingPathComponent("Mayank")
            .appendingPathComponent("Mayank-report.pdf")
            .path
        XCTAssertEqual(item.baseDestPath, expectedDest)
        XCTAssertEqual(item.classificationSource, .extensionRule)
        XCTAssertEqual(item.matchedRuleId, rule.id.uuidString)
    }

    func testExtensionExclusionBlocksByUserList() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let root = tempDir.appendingPathComponent("root")
        let destRoot = tempDir.appendingPathComponent("dest")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: destRoot, withIntermediateDirectories: true)

        try writeFile(root.appendingPathComponent("Mayank-report.pdf"), contents: "a")

        var project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: root.path)],
            destinationRoot: DestinationRoot(path: destRoot.path),
            people: [Person(displayName: "Mayank", keywordTokens: ["mayank"])]
        )
        project.settings.extensionExclusions = ExtensionExclusions(
            excludeMode: .excludeOnlyThese,
            excludedExtensions: ["pdf"]
        )

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)
        let scanResult = try await scanner.scan(project: project)

        let planStore = PlanStore(dbManager: dbManager)
        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: project, scanId: scanResult.scan.id)

        let excluded = try await planStore.fetchPlanItemRows(
            planId: summary.plan.id,
            disposition: .excludedByPolicy
        )
        XCTAssertEqual(excluded.count, 1)
        XCTAssertEqual(excluded[0].planItem.reasonCode, PlanReasonCode.policyExcludeUserExtension.rawValue)
    }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("organize-planner-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url, options: .atomic)
}
