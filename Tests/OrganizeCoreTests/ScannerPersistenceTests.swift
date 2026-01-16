import XCTest
@testable import OrganizeCore

final class ScannerPersistenceTests: XCTestCase {
    func testExcludedItemsDoNotCollideAcrossSourceRootsAndOrderingIsDeterministic() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)

        let rootA = tempDir.appendingPathComponent("rootA")
        let rootB = tempDir.appendingPathComponent("rootB")
        try FileManager.default.createDirectory(at: rootA, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: rootB, withIntermediateDirectories: true)

        let external = tempDir.appendingPathComponent("external")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try writeFile(external.appendingPathComponent("target.txt"), contents: "x")

        // Same relative path ("link") across two different source roots.
        try createSymlink(at: rootA.appendingPathComponent("link"), to: external)
        try createSymlink(at: rootB.appendingPathComponent("link"), to: external)

        // Same relative path ("same.txt") across two different source roots.
        try writeFile(rootA.appendingPathComponent("same.txt"), contents: "a")
        try writeFile(rootB.appendingPathComponent("same.txt"), contents: "b")

        let project = Project(
            name: "Test",
            sourceRoots: [
                SourceRoot(path: rootA.path),
                SourceRoot(path: rootB.path)
            ]
        )

        let result = try await scanner.scan(project: project)
        XCTAssertEqual(result.itemCount, 2)
        XCTAssertEqual(result.excludedItems.count, 2)

        let excludedFromDB = try await inventoryStore.fetchExcludedItems(for: result.scan.id)
        XCTAssertEqual(excludedFromDB.count, 2)
        XCTAssertEqual(Set(excludedFromDB.map(\.relativePath)), ["link"])
        XCTAssertEqual(Set(excludedFromDB.map(\.reason)), [.symlink])
        XCTAssertEqual(Set(excludedFromDB.map(\.sourceRootId)).count, 2)

        let excludedKeys = excludedFromDB.map { "\($0.sourceRootId.uuidString)|\($0.relativePath)" }
        XCTAssertEqual(excludedKeys, excludedKeys.sorted(), "Excluded items should be ordered deterministically")

        let inventoryFromDB = try await inventoryStore.fetchInventoryItems(for: result.scan.id)
        XCTAssertEqual(inventoryFromDB.count, 2)
        XCTAssertEqual(Set(inventoryFromDB.map(\.relativePath)), ["same.txt"])
        XCTAssertEqual(Set(inventoryFromDB.map(\.sourceRootId)).count, 2)

        let inventoryKeys = inventoryFromDB.map { "\($0.sourceRootId.uuidString)|\($0.relativePath)" }
        XCTAssertEqual(inventoryKeys, inventoryKeys.sorted(), "Inventory items should be ordered deterministically")
    }

    func testSourceRootProjectMarkerExcludesRootAndSkipsContents() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)

        let repoRoot = tempDir.appendingPathComponent("repoRoot")
        try FileManager.default.createDirectory(at: repoRoot, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: repoRoot.appendingPathComponent(".git"), withIntermediateDirectories: true)
        try writeFile(repoRoot.appendingPathComponent("should_not_scan.txt"), contents: "nope")

        let project = Project(name: "Test", sourceRoots: [SourceRoot(path: repoRoot.path)])
        let result = try await scanner.scan(project: project)

        XCTAssertEqual(result.itemCount, 0)
        XCTAssertEqual(result.excludedItems.count, 1)
        XCTAssertEqual(result.excludedItems.first?.reason, .projectFolder)
        XCTAssertEqual(result.excludedItems.first?.relativePath, ".")

        let excludedFromDB = try await inventoryStore.fetchExcludedItems(for: result.scan.id)
        XCTAssertEqual(excludedFromDB.count, 1)
        XCTAssertEqual(excludedFromDB.first?.reason, .projectFolder)
        XCTAssertEqual(excludedFromDB.first?.relativePath, ".")

        let inventoryFromDB = try await inventoryStore.fetchInventoryItems(for: result.scan.id)
        XCTAssertTrue(inventoryFromDB.isEmpty)
    }

    func testSymlinkToDirectoryIsExcludedAndNotFollowed() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)

        let sourceRoot = tempDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let external = tempDir.appendingPathComponent("externalDir")
        try FileManager.default.createDirectory(at: external, withIntermediateDirectories: true)
        try writeFile(external.appendingPathComponent("inside.txt"), contents: "secret")

        try createSymlink(at: sourceRoot.appendingPathComponent("linkDir"), to: external)

        let project = Project(name: "Test", sourceRoots: [SourceRoot(path: sourceRoot.path)])
        let result = try await scanner.scan(project: project)

        XCTAssertEqual(result.itemCount, 0)
        XCTAssertEqual(result.excludedItems.count, 1)
        XCTAssertEqual(result.excludedItems.first?.reason, .symlink)
        XCTAssertEqual(result.excludedItems.first?.relativePath, "linkDir")

        // If the enumerator followed the symlink, we'd see linkDir/inside.txt in the inventory.
        let inventoryFromDB = try await inventoryStore.fetchInventoryItems(for: result.scan.id)
        XCTAssertTrue(inventoryFromDB.isEmpty)
    }

    func testPackageAllowlistAndExcludedAppBundle() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)

        let sourceRoot = tempDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        let pagesPackage = sourceRoot.appendingPathComponent("Doc.pages")
        try FileManager.default.createDirectory(at: pagesPackage, withIntermediateDirectories: true)
        try writeFile(pagesPackage.appendingPathComponent("Contents/data.txt"), contents: "hello") // 5 bytes
        try writeFile(pagesPackage.appendingPathComponent("Contents/.hidden"), contents: "abcdef") // 6 bytes (hidden, should be counted in package size)

        let appBundle = sourceRoot.appendingPathComponent("Bad.app")
        try FileManager.default.createDirectory(at: appBundle, withIntermediateDirectories: true)
        try writeFile(appBundle.appendingPathComponent("Contents/Info.plist"), contents: "plist")

        let project = Project(name: "Test", sourceRoots: [SourceRoot(path: sourceRoot.path)])
        let result = try await scanner.scan(project: project)

        XCTAssertEqual(result.itemCount, 1)
        XCTAssertEqual(result.totalBytes, 11)
        XCTAssertEqual(result.excludedItems.count, 1)

        let inventoryFromDB = try await inventoryStore.fetchInventoryItems(for: result.scan.id)
        XCTAssertEqual(inventoryFromDB.count, 1)
        XCTAssertEqual(inventoryFromDB.first?.relativePath, "Doc.pages")
        XCTAssertEqual(inventoryFromDB.first?.isPackage, true)
        XCTAssertEqual(inventoryFromDB.first?.sizeBytes, 11)

        let excludedFromDB = try await inventoryStore.fetchExcludedItems(for: result.scan.id)
        XCTAssertEqual(excludedFromDB.count, 1)
        XCTAssertEqual(excludedFromDB.first?.relativePath, "Bad.app")
        XCTAssertEqual(excludedFromDB.first?.reason, .appBundle)
        XCTAssertEqual(excludedFromDB.first?.isDirectory, true)
    }

    func testHiddenItemsAreExcludedAndPersisted() async throws {
        let tempDir = try makeTempDir()
        defer { try? FileManager.default.removeItem(at: tempDir) }

        let dbURL = tempDir.appendingPathComponent("organize.db")
        let dbManager = try DatabaseManager(path: dbURL.path)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)

        let sourceRoot = tempDir.appendingPathComponent("source")
        try FileManager.default.createDirectory(at: sourceRoot, withIntermediateDirectories: true)

        try writeFile(sourceRoot.appendingPathComponent("visible.txt"), contents: "ok")
        try writeFile(sourceRoot.appendingPathComponent(".secret"), contents: "nope")

        let hiddenDir = sourceRoot.appendingPathComponent(".hiddenDir")
        try FileManager.default.createDirectory(at: hiddenDir, withIntermediateDirectories: true)
        try writeFile(hiddenDir.appendingPathComponent("inside.txt"), contents: "should-not-scan")

        let project = Project(name: "Test", sourceRoots: [SourceRoot(path: sourceRoot.path)])
        let result = try await scanner.scan(project: project)

        XCTAssertEqual(result.itemCount, 1)
        XCTAssertEqual(result.excludedItems.count, 2)

        let excluded = try await inventoryStore.fetchExcludedItems(for: result.scan.id)
        XCTAssertEqual(excluded.count, 2)

        XCTAssertTrue(excluded.contains { $0.relativePath == ".secret" && $0.reason == .hiddenItem && $0.isDirectory == false })
        XCTAssertTrue(excluded.contains { $0.relativePath == ".hiddenDir" && $0.reason == .hiddenItem && $0.isDirectory == true })

        // Ensure we did not follow into the hidden directory.
        let inventory = try await inventoryStore.fetchInventoryItems(for: result.scan.id)
        XCTAssertEqual(inventory.count, 1)
        XCTAssertEqual(inventory.first?.relativePath, "visible.txt")
    }
}

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory.appendingPathComponent("organize-tests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

private func writeFile(_ url: URL, contents: String) throws {
    try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data(contents.utf8).write(to: url, options: .atomic)
}

private func createSymlink(at linkURL: URL, to destinationURL: URL) throws {
    try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: destinationURL.path)
}
