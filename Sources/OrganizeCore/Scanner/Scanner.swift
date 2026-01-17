import Foundation
import CryptoKit

/// Result of a scan operation
public struct ScanResult: Sendable {
    public let scan: Scan
    public let scanSourceRoots: [ScanSourceRoot]
    public let itemCount: Int
    public let totalBytes: Int64
    public let excludedItems: [ExcludedItem]
    
    public init(
        scan: Scan,
        scanSourceRoots: [ScanSourceRoot],
        itemCount: Int,
        totalBytes: Int64,
        excludedItems: [ExcludedItem]
    ) {
        self.scan = scan
        self.scanSourceRoots = scanSourceRoots
        self.itemCount = itemCount
        self.totalBytes = totalBytes
        self.excludedItems = excludedItems
    }
}

/// Progress callback for scanning
public typealias ScanProgressHandler = @Sendable (Int, String) -> Void

/// Scanned item result (internal)
private struct ScannedItem: Sendable {
    let item: InventoryItem
    let relativePath: String
}

/// Main scanner for traversing source roots
public actor Scanner {
    private let inventoryStore: InventoryStore
    
    public init(inventoryStore: InventoryStore) {
        self.inventoryStore = inventoryStore
    }
    
    /// Scan source roots and build inventory
    public func scan(
        project: Project,
        progressHandler: ScanProgressHandler? = nil
    ) async throws -> ScanResult {
        let scanId = EntityID()
        var scan = Scan(id: scanId, projectId: project.id)
        var scanSourceRoots: [ScanSourceRoot] = []
        var itemCount = 0
        var totalBytes: Int64 = 0
        var allExcludedItems: [ExcludedItem] = []
        
        // Save scan record first (FK constraint requires it before inventory_items)
        try await inventoryStore.saveScan(scan)
        
        let batchSize = 100

        // Process each source root
        for sourceRoot in project.sourceRoots where sourceRoot.isValid {
            // Save source root to DB (FK constraint requires it before inventory_items)
            try await inventoryStore.saveSourceRoot(sourceRoot, projectId: project.id)
            
            // Create and save immutable snapshot (FK requires scan + source_root exist)
            let scanSourceRoot = ScanSourceRoot(
                scanId: scanId,
                sourceRootId: sourceRoot.id,
                pathAtScan: sourceRoot.path,
                slugAtScan: sourceRoot.slug
            )
            try await inventoryStore.saveScanSourceRoot(scanSourceRoot)
            scanSourceRoots.append(scanSourceRoot)
            
            var itemBatch: [InventoryItem] = []
            var excludedBatch: [ExcludedItem] = []

            for await event in Self.scanEvents(
                sourceRoot: sourceRoot,
                scanId: scanId,
                projectMarkers: project.settings.projectMarkers
            ) {
                switch event {
                case .item(let scannedItem):
                    itemBatch.append(scannedItem.item)
                    itemCount += 1
                    totalBytes += scannedItem.item.sizeBytes
                    progressHandler?(itemCount, scannedItem.relativePath)

                    if itemBatch.count >= batchSize {
                        try await inventoryStore.saveInventoryItems(itemBatch)
                        itemBatch.removeAll(keepingCapacity: true)
                    }
                case .excluded(let excludedItem):
                    allExcludedItems.append(excludedItem)
                    excludedBatch.append(excludedItem)

                    if excludedBatch.count >= batchSize {
                        try await inventoryStore.saveExcludedItems(excludedBatch)
                        excludedBatch.removeAll(keepingCapacity: true)
                    }
                }
            }

            // Save remaining batches.
            if !itemBatch.isEmpty {
                try await inventoryStore.saveInventoryItems(itemBatch)
            }
            if !excludedBatch.isEmpty {
                try await inventoryStore.saveExcludedItems(excludedBatch)
            }
        }
        
        // Update scan with final counts
        scan.completedAt = Date()
        scan.itemCount = itemCount
        scan.totalBytes = totalBytes
        try await inventoryStore.saveScan(scan)  // Update with final counts
        
        return ScanResult(
            scan: scan,
            scanSourceRoots: scanSourceRoots,
            itemCount: itemCount,
            totalBytes: totalBytes,
            excludedItems: allExcludedItems
        )
    }
    
    private enum ScanEvent {
        case item(ScannedItem)
        case excluded(ExcludedItem)
    }

    /// Stream scan events from a synchronous enumerator to avoid async iterator warnings.
    private static func scanEvents(
        sourceRoot: SourceRoot,
        scanId: EntityID,
        projectMarkers: [String]
    ) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let queue = DispatchQueue(label: "organize.scanner.enumeration")

            queue.async {
                // Instantiate detectors locally (Swift 6 concurrency requirement)
                let typeDetector = TypeDetector()
                let packageDetector = PackageDetector()
                let cloudStatusDetector = CloudStatusDetector()
                let aliasDetector = AliasDetector()
                let projectMarkerDetector = ProjectMarkerDetector(markers: projectMarkers)
                let exifReader = EXIFReader()

                let sourceURL = URL(fileURLWithPath: sourceRoot.path).standardizedFileURL

                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue else {
                    continuation.finish()
                    return
                }

                // If the source root itself is a project/repo folder, exclude it and skip scanning its contents.
                if projectMarkerDetector.containsProjectMarker(at: sourceURL) {
                    continuation.yield(.excluded(ExcludedItem(
                        scanId: scanId,
                        sourceRootId: sourceRoot.id,
                        relativePath: ".",
                        absolutePath: sourceURL.path,
                        reason: .projectFolder,
                        isDirectory: true
                    )))
                    continuation.finish()
                    return
                }

                guard let enumerator = FileManager.default.enumerator(
                    at: sourceURL,
                    includingPropertiesForKeys: [
                        .isRegularFileKey,
                        .isDirectoryKey,
                        .isPackageKey,
                        .isSymbolicLinkKey,
                        .isAliasFileKey,
                        .isHiddenKey,
                        .fileSizeKey,
                        .contentModificationDateKey,
                        .creationDateKey,
                        .contentTypeKey,
                        .ubiquitousItemDownloadingStatusKey
                    ],
                    options: []
                ) else {
                    continuation.finish()
                    return
                }

                for case let fileURL as URL in enumerator {
                    let relativePath = Self.computeRelativePath(from: sourceURL, to: fileURL)

                    // Check for symlink - skip descendants
                    if aliasDetector.isSymlink(at: fileURL) {
                        enumerator.skipDescendants()
                        continuation.yield(.excluded(ExcludedItem(
                            scanId: scanId,
                            sourceRootId: sourceRoot.id,
                            relativePath: relativePath,
                            absolutePath: fileURL.path,
                            reason: .symlink,
                            isDirectory: false
                        )))
                        continue
                    }

                    // Check for Finder alias - files, so no skipDescendants needed
                    if aliasDetector.isFinderAlias(at: fileURL) {
                        continuation.yield(.excluded(ExcludedItem(
                            scanId: scanId,
                            sourceRootId: sourceRoot.id,
                            relativePath: relativePath,
                            absolutePath: fileURL.path,
                            reason: .finderAlias,
                            isDirectory: false
                        )))
                        continue
                    }

                    // Get resource values
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: [
                        .isRegularFileKey, .isDirectoryKey, .isPackageKey,
                        .isHiddenKey,
                        .fileSizeKey, .contentModificationDateKey, .creationDateKey
                    ]) else {
                        continue
                    }

                    let isDirectory = resourceValues.isDirectory ?? false
                    let isPackage = (resourceValues.isPackage ?? false) || (isDirectory && packageDetector.isKnownPackageExtension(at: fileURL))

                    // Hidden items: exclude and skip descendants for directories.
                    let isHidden = (resourceValues.isHidden ?? false) || fileURL.lastPathComponent.hasPrefix(".")
                    if isHidden {
                        if isDirectory {
                            enumerator.skipDescendants()
                        }
                        continuation.yield(.excluded(ExcludedItem(
                            scanId: scanId,
                            sourceRootId: sourceRoot.id,
                            relativePath: relativePath,
                            absolutePath: fileURL.path,
                            reason: .hiddenItem,
                            isDirectory: isDirectory
                        )))
                        continue
                    }

                    // Handle packages atomically
                    if isPackage {
                        enumerator.skipDescendants()

                        // Check for excluded package types
                        let (isExcluded, reason) = packageDetector.isExcludedPackage(at: fileURL)
                        if isExcluded, let excludeReason = reason {
                            continuation.yield(.excluded(ExcludedItem(
                                scanId: scanId,
                                sourceRootId: sourceRoot.id,
                                relativePath: relativePath,
                                absolutePath: fileURL.path,
                                reason: excludeReason,
                                isDirectory: true
                            )))
                            continue
                        }

                        // Compute package size
                        let packageSize = packageDetector.computePackageSize(at: fileURL)

                        // Create inventory item for package
                        let itemId = generateItemId(scanId: scanId, sourceRootId: sourceRoot.id, relativePath: relativePath)

                        let item = InventoryItem(
                            id: itemId,
                            scanId: scanId,
                            sourceRootId: sourceRoot.id,
                            relativePath: relativePath,
                            isPackage: true,
                            sizeBytes: packageSize,
                            modifiedTime: resourceValues.contentModificationDate ?? Date(),
                            createdTime: resourceValues.creationDate,
                            isCloudOnly: cloudStatusDetector.isCloudOnly(at: fileURL),
                            uttypeIdentifier: typeDetector.detectType(at: fileURL),
                            extension: typeDetector.getExtension(at: fileURL)
                        )

                        continuation.yield(.item(ScannedItem(item: item, relativePath: relativePath)))
                        continue
                    }

                    // Skip plain directories (per spec: only files and packages)
                    if isDirectory {
                        // Check if it's a project folder
                        if projectMarkerDetector.containsProjectMarker(at: fileURL) {
                            enumerator.skipDescendants()
                            continuation.yield(.excluded(ExcludedItem(
                                scanId: scanId,
                                sourceRootId: sourceRoot.id,
                                relativePath: relativePath,
                                absolutePath: fileURL.path,
                                reason: .projectFolder,
                                isDirectory: true
                            )))
                        }
                        continue
                    }

                    // Handle regular files
                    let isRegularFile = resourceValues.isRegularFile ?? false
                    guard isRegularFile else { continue }

                    let fileSize = Int64(resourceValues.fileSize ?? 0)
                    let itemId = generateItemId(scanId: scanId, sourceRootId: sourceRoot.id, relativePath: relativePath)
                    let uttypeIdentifier = typeDetector.detectType(at: fileURL)
                    let fileExtension = typeDetector.getExtension(at: fileURL)
                    let isCloudOnly = cloudStatusDetector.isCloudOnly(at: fileURL)

                    let exifDate: Date?
                    if !isCloudOnly && typeDetector.isImage(uttypeIdentifier: uttypeIdentifier) {
                        exifDate = exifReader.extractDateTimeOriginal(from: fileURL)
                    } else {
                        exifDate = nil
                    }

                    let item = InventoryItem(
                        id: itemId,
                        scanId: scanId,
                        sourceRootId: sourceRoot.id,
                        relativePath: relativePath,
                        isPackage: false,
                        sizeBytes: fileSize,
                        modifiedTime: resourceValues.contentModificationDate ?? Date(),
                        createdTime: resourceValues.creationDate,
                        exifDateTimeOriginal: exifDate,
                        isCloudOnly: isCloudOnly,
                        uttypeIdentifier: uttypeIdentifier,
                        extension: fileExtension
                    )

                    continuation.yield(.item(ScannedItem(item: item, relativePath: relativePath)))
                }

                continuation.finish()
            }
        }
    }
    
    /// Compute relative path safely using standardized URLs
    private static func computeRelativePath(from base: URL, to url: URL) -> String {
        let basePath = base.standardizedFileURL.path
        let filePath = url.standardizedFileURL.path
        
        if filePath.hasPrefix(basePath) {
            var relativePath = String(filePath.dropFirst(basePath.count))
            if relativePath.hasPrefix("/") {
                relativePath = String(relativePath.dropFirst())
            }
            return relativePath
        }
        return url.lastPathComponent
    }
    
    /// Generate deterministic item ID
    private static func generateItemId(scanId: EntityID, sourceRootId: EntityID, relativePath: String) -> String {
        let input = "\(scanId.uuidString)|\(sourceRootId.uuidString)|\(relativePath)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.prefix(16).map { String(format: "%02x", $0) }.joined()
    }
}
