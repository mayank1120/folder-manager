import XCTest
@testable import OrganizeCore

final class CoreTypesTests: XCTestCase {
    
    func testExecutionModeEncoding() throws {
        let encoder = JSONEncoder()
        let decoder = JSONDecoder()
        
        let mode = ExecutionMode.copyFirst
        let data = try encoder.encode(mode)
        let decoded = try decoder.decode(ExecutionMode.self, from: data)
        
        XCTAssertEqual(mode, decoded)
    }
    
    func testDispositionValues() {
        XCTAssertEqual(Disposition.moveEligible.rawValue, "moveEligible")
        XCTAssertEqual(Disposition.needsReview.rawValue, "needsReview")
        XCTAssertEqual(Disposition.excludedByPolicy.rawValue, "excludedByPolicy")
    }
    
    func testPlanOperationTypeSeparation() {
        // Plan types should NOT include delete/rollback
        let planTypes: [PlanOperationType] = [.copyItem, .moveItem, .applyTags]
        XCTAssertEqual(planTypes.count, 3)
        
        // Execution types include all operation types
        let execTypes: [ExecutionOperationType] = [
            .copyItem, .moveItem, .applyTags,
            .trashOriginal, .archiveOriginal,
            .rollbackMove, .rollbackDelete, .rollbackTags
        ]
        XCTAssertEqual(execTypes.count, 8)
    }
}

final class ProjectTests: XCTestCase {
    
    func testProjectCreation() {
        let project = Project(name: "Test Project")
        
        XCTAssertEqual(project.name, "Test Project")
        XCTAssertEqual(project.schemaVersion, Project.currentSchemaVersion)
        XCTAssertTrue(project.sourceRoots.isEmpty)
        XCTAssertNil(project.destinationRoot)
        XCTAssertTrue(project.people.isEmpty)
    }
    
    func testProjectSettingsDefaults() {
        let settings = ProjectSettings()
        
        XCTAssertFalse(settings.autoFileUnassigned)
        XCTAssertFalse(settings.autoFileShared)
        XCTAssertEqual(settings.executionMode, .copyFirst)
        XCTAssertEqual(settings.collisionPolicy, .autoSuffix)
        XCTAssertEqual(settings.deleteOriginalsMode, .moveToTrash)
        XCTAssertFalse(settings.downloadBeforeProcessing)
    }
    
    func testSourceRootSlugGeneration() {
        let root = SourceRoot(path: "/Users/test/Documents")
        XCTAssertEqual(root.slug, "Documents")
        
        let customSlug = SourceRoot(path: "/Users/test/Documents", slug: "MyDocs")
        XCTAssertEqual(customSlug.slug, "MyDocs")
    }
    
    func testPersonTokenNormalization() {
        let person = Person(displayName: "John Doe", keywordTokens: ["  JOHN  ", "Doe"])
        
        XCTAssertEqual(person.keywordTokens, ["john", "doe"])
    }
    
    func testProjectEncoding() throws {
        let project = Project(
            name: "Test",
            sourceRoots: [SourceRoot(path: "/test")],
            destinationRoot: DestinationRoot(path: "/output"),
            people: [Person(displayName: "Test User", keywordTokens: ["test"])]
        )
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = .sortedKeys
        
        let data = try encoder.encode(project)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let decoded = try decoder.decode(Project.self, from: data)
        
        XCTAssertEqual(decoded.name, project.name)
        XCTAssertEqual(decoded.sourceRoots.count, 1)
        XCTAssertEqual(decoded.people.count, 1)
    }
}

final class InventoryItemTests: XCTestCase {
    
    func testInventoryItemFullPath() {
        let item = InventoryItem(
            id: "test-id",
            scanId: UUID(),
            sourceRootId: UUID(),
            relativePath: "Documents/file.pdf",
            sizeBytes: 1024,
            modifiedTime: Date()
        )
        
        let fullPath = item.fullPath(withSourceRootPath: "/Users/test")
        XCTAssertEqual(fullPath, "/Users/test/Documents/file.pdf")
    }
    
    func testRoutingDateUsesEXIF() {
        let exifDate = Date(timeIntervalSince1970: 1000)
        let modifiedDate = Date(timeIntervalSince1970: 2000)
        
        let item = InventoryItem(
            id: "test-id",
            scanId: UUID(),
            sourceRootId: UUID(),
            relativePath: "photo.jpg",
            sizeBytes: 1024,
            modifiedTime: modifiedDate,
            exifDateTimeOriginal: exifDate
        )
        
        XCTAssertEqual(item.routingDate, exifDate)
        XCTAssertEqual(item.routingDateSource, .exifOriginal)
    }
    
    func testRoutingDateFallsBackToMtime() {
        let modifiedDate = Date(timeIntervalSince1970: 2000)
        
        let item = InventoryItem(
            id: "test-id",
            scanId: UUID(),
            sourceRootId: UUID(),
            relativePath: "document.pdf",
            sizeBytes: 1024,
            modifiedTime: modifiedDate,
            exifDateTimeOriginal: nil
        )
        
        XCTAssertEqual(item.routingDate, modifiedDate)
        XCTAssertEqual(item.routingDateSource, .modifiedTime)
    }
}

final class PlanOperationTests: XCTestCase {
    
    func testPlanOperationCreation() {
        let op = PlanOperation(
            operationId: "op-123",
            planId: UUID(),
            itemId: "item-456",
            operationType: .copyItem,
            executionMode: .copyFirst,
            baseDestPath: "/output/Documents",
            resolvedDestPath: "/output/Documents/file.pdf",
            reasonCode: "SingleMatch",
            sortOrder: 0
        )
        
        XCTAssertEqual(op.operationId, "op-123")
        XCTAssertEqual(op.operationType, .copyItem)
        XCTAssertFalse(op.collisionResolved)
        XCTAssertFalse(op.crossVolume)
    }
}

final class JournalEntryTests: XCTestCase {
    
    func testJournalEntryCreation() {
        let planId = UUID()
        let entry = JournalEntry(
            planId: planId,
            operationId: "op-123",
            state: .started,
            operationType: .copyItem,
            itemId: "item-456"
        )
        
        XCTAssertEqual(entry.planId, planId)
        XCTAssertEqual(entry.state, .started)
        XCTAssertGreaterThan(entry.timestamp, 0)
    }
    
    func testFileStatEncoding() throws {
        let stat = FileStat(sizeBytes: 1024, modifiedTime: Date())
        
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let data = try encoder.encode(stat)
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        let decoded = try decoder.decode(FileStat.self, from: data)
        
        XCTAssertEqual(decoded.sizeBytes, stat.sizeBytes)
    }
}
