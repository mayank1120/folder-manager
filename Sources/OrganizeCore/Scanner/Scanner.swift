import Foundation
import CryptoKit

/// Result of a scan operation.
///
/// A scan is read-only: it enumerates files under user-selected source roots and records an immutable
/// inventory snapshot in SQLite. The result contains summary counts and any excluded items observed
/// during enumeration.
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
    let inode: UInt64
}

/// Main scanner for traversing source roots and persisting an inventory snapshot.
///
/// The scanner never follows symlinks and treats certain macOS packages as atomic items.
/// Excluded items are persisted to SQLite as they are encountered.
public actor Scanner {
    private let inventoryStore: InventoryStore
    private let snapshotStore: SnapshotStore?
    private let configuration: ScannerConfiguration
    
    public init(
        inventoryStore: InventoryStore,
        snapshotStore: SnapshotStore? = nil,
        configuration: ScannerConfiguration = .default
    ) {
        self.inventoryStore = inventoryStore
        self.snapshotStore = snapshotStore
        self.configuration = configuration
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
        
        let batchSize = configuration.batchSize
        
        // Load previous snapshots for incremental mode
        let isIncremental = project.settings.incrementalScan.enabled && snapshotStore != nil
        var newSnapshots: [FileSnapshot] = []

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
                projectMarkers: project.settings.projectMarkers,
                duplicateDetection: project.settings.duplicateDetection,
                maxHashFileSizeBytes: configuration.maxHashFileSizeBytes
            ) {
                switch event {
                case .item(let scannedItem):
                    itemBatch.append(scannedItem.item)
                    itemCount += 1
                    totalBytes += scannedItem.item.sizeBytes
                    progressHandler?(itemCount, scannedItem.relativePath)
                    
                    // Create snapshot for incremental scan
                    if isIncremental {
                        newSnapshots.append(FileSnapshot(
                            projectId: project.id,
                            sourceRootId: sourceRoot.id,
                            relativePath: scannedItem.relativePath,
                            sizeBytes: scannedItem.item.sizeBytes,
                            modifiedTime: scannedItem.item.modifiedTime,
                            inode: scannedItem.inode
                        ))
                    }

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
        
        // Save snapshots for next incremental scan
        if isIncremental, let store = snapshotStore, !newSnapshots.isEmpty {
            try await store.saveSnapshots(newSnapshots)
        }
        
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
        projectMarkers: [String],
        duplicateDetection: DuplicateDetectionSettings,
        maxHashFileSizeBytes: Int64
    ) -> AsyncStream<ScanEvent> {
        AsyncStream { continuation in
            let task = Task.detached(priority: .userInitiated) {
                defer { continuation.finish() }
                // Instantiate detectors locally (Swift 6 concurrency requirement)
                let typeDetector = TypeDetector()
                let packageDetector = PackageDetector()
                let cloudStatusDetector = CloudStatusDetector()
                let aliasDetector = AliasDetector()
                let projectMarkerDetector = ProjectMarkerDetector(markers: projectMarkers)
                let exifReader = EXIFReader()
                let shouldHash = duplicateDetection.enabled

                let sourceURL = URL(fileURLWithPath: sourceRoot.path).standardizedFileURL

                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: sourceURL.path, isDirectory: &isDir), isDir.boolValue else {
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
                    return
                }

                while let fileURL = enumerator.nextObject() as? URL {
                    if Task.isCancelled {
                        break
                    }

                    let relativePath = Self.computeRelativePath(from: sourceURL, to: fileURL)

                    // PERF: Single resourceValues call with all needed keys
                    // Avoids 2-3 extra stat() calls per file from separate symlink/alias checks
                    guard let resourceValues = try? fileURL.resourceValues(forKeys: [
                        .isSymbolicLinkKey, .isAliasFileKey,  // For symlink/alias exclusion
                        .isRegularFileKey, .isDirectoryKey, .isPackageKey,
                        .isHiddenKey,
                        .fileSizeKey, .contentModificationDateKey, .creationDateKey,
                        .fileResourceIdentifierKey  // For inode tracking in snapshots
                    ]) else {
                        continue
                    }

                    // Check symlink from unified values - skip descendants
                    if resourceValues.isSymbolicLink == true {
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

                    // Check Finder alias from unified values
                    if resourceValues.isAliasFile == true {
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
                            contentHash: nil,
                            uttypeIdentifier: typeDetector.detectType(at: fileURL),
                            extension: typeDetector.getExtension(at: fileURL)
                        )

                        let fileInode = resourceValues.fileResourceIdentifier.map { UInt64($0.hash) } ?? 0
                        continuation.yield(.item(ScannedItem(item: item, relativePath: relativePath, inode: fileInode)))
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

                    let contentHash: String?
                    if shouldHash && !isCloudOnly && fileSize <= maxHashFileSizeBytes {
                        contentHash = try? await computeContentHash(for: fileURL)
                    } else {
                        contentHash = nil
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
                        contentHash: contentHash,
                        uttypeIdentifier: uttypeIdentifier,
                        extension: fileExtension
                    )

                    continuation.yield(.item(ScannedItem(item: item, relativePath: relativePath, inode: UInt64(resourceValues.fileResourceIdentifier?.hash ?? 0))))
                }
            }

            continuation.onTermination = { @Sendable _ in
                task.cancel()
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

    private static func computeContentHash(for url: URL) async throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }

        var hasher = SHA256()
        var chunkCount = 0

        while true {
            try Task.checkCancellation()

            let data = try handle.read(upToCount: 1_048_576)
            guard let chunk = data, !chunk.isEmpty else {
                break
            }

            hasher.update(data: chunk)
            chunkCount += 1

            // Yield occasionally to keep cancellation responsive.
            if chunkCount % 8 == 0 {
                await Task.yield()
            }
        }

        let digest = hasher.finalize()
        return digest.map { String(format: "%02x", $0) }.joined()
    }
}
