import Foundation

/// A person configured for owner matching
public struct Person: Codable, Identifiable, Sendable, Hashable {
    public let id: EntityID
    public var displayName: String
    public var keywordTokens: [String]
    
    public init(id: EntityID = EntityID(), displayName: String, keywordTokens: [String]) {
        self.id = id
        self.displayName = displayName
        self.keywordTokens = keywordTokens.map { $0.lowercased().trimmingCharacters(in: .whitespaces) }
    }
}

/// Source root folder configuration
public struct SourceRoot: Codable, Identifiable, Sendable, Hashable {
    public let id: EntityID
    public var path: String
    public var slug: String
    public var bookmarkData: Data?
    public var isValid: Bool
    
    public init(
        id: EntityID = EntityID(),
        path: String,
        slug: String? = nil,
        bookmarkData: Data? = nil,
        isValid: Bool = true
    ) {
        self.id = id
        self.path = path
        self.slug = slug ?? URL(fileURLWithPath: path).lastPathComponent
        self.bookmarkData = bookmarkData
        self.isValid = isValid
    }
}

/// Destination root folder configuration
public struct DestinationRoot: Codable, Sendable, Hashable {
    public var path: String
    public var bookmarkData: Data?
    public var isValid: Bool
    
    public init(path: String, bookmarkData: Data? = nil, isValid: Bool = true) {
        self.path = path
        self.bookmarkData = bookmarkData
        self.isValid = isValid
    }
}

/// Project settings
public struct ProjectSettings: Codable, Sendable, Hashable {
    public var autoFileUnassigned: Bool
    public var autoFileShared: Bool
    public var executionMode: ExecutionMode
    public var collisionPolicy: CollisionPolicy
    public var deleteOriginalsMode: DeleteOriginalsMode
    public var downloadBeforeProcessing: Bool
    public var enableOtherBucket: Bool
    public var tagsEnabled: Bool
    public var tagNames: [String]  // Legacy: global tags only
    public var tagConfiguration: TagConfiguration  // New: supports per-category/owner tags
    public var screenshotPrefixes: [String]
    public var cameraPrefixes: [String]
    public var projectMarkers: [String]
    public var extensionRules: [ExtensionRule]
    public var extensionExclusions: ExtensionExclusions
    public var ownerMatching: OwnerMatchingSettings
    public var duplicateDetection: DuplicateDetectionSettings
    public var largeFileFilter: LargeFileFilterSettings
    public var pdfDateGrouping: PDFDateGrouping
    public var cleanupEmptyFolders: Bool
    public var incrementalScan: IncrementalScanSettings
    
    public init(
        autoFileUnassigned: Bool = false,
        autoFileShared: Bool = false,
        executionMode: ExecutionMode = .copyFirst,
        collisionPolicy: CollisionPolicy = .autoSuffix,
        deleteOriginalsMode: DeleteOriginalsMode = .moveToTrash,
        downloadBeforeProcessing: Bool = false,
        enableOtherBucket: Bool = false,
        tagsEnabled: Bool = false,
        tagNames: [String] = [],
        tagConfiguration: TagConfiguration = TagConfiguration(),
        screenshotPrefixes: [String] = ["Screenshot", "Screen Shot"],
        cameraPrefixes: [String] = ["IMG_", "DSC_", "PXL_"],
        projectMarkers: [String] = [".git", ".svn", ".hg", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "Pipfile", "Podfile"],
        extensionRules: [ExtensionRule] = [],
        extensionExclusions: ExtensionExclusions = ExtensionExclusions(),
        ownerMatching: OwnerMatchingSettings = OwnerMatchingSettings(),
        duplicateDetection: DuplicateDetectionSettings = DuplicateDetectionSettings(),
        largeFileFilter: LargeFileFilterSettings = LargeFileFilterSettings(),
        pdfDateGrouping: PDFDateGrouping = .year,
        cleanupEmptyFolders: Bool = false,
        incrementalScan: IncrementalScanSettings = IncrementalScanSettings()
    ) {
        self.autoFileUnassigned = autoFileUnassigned
        self.autoFileShared = autoFileShared
        self.executionMode = executionMode
        self.collisionPolicy = collisionPolicy
        self.deleteOriginalsMode = deleteOriginalsMode
        self.downloadBeforeProcessing = downloadBeforeProcessing
        self.enableOtherBucket = enableOtherBucket
        self.tagsEnabled = tagsEnabled
        self.tagNames = tagNames
        self.tagConfiguration = tagConfiguration
        self.screenshotPrefixes = screenshotPrefixes
        self.cameraPrefixes = cameraPrefixes
        self.projectMarkers = projectMarkers
        self.extensionRules = extensionRules
        self.extensionExclusions = extensionExclusions
        self.ownerMatching = ownerMatching
        self.duplicateDetection = duplicateDetection
        self.largeFileFilter = largeFileFilter
        self.pdfDateGrouping = pdfDateGrouping
        self.cleanupEmptyFolders = cleanupEmptyFolders
        self.incrementalScan = incrementalScan
    }

    private enum CodingKeys: String, CodingKey {
        case autoFileUnassigned
        case autoFileShared
        case executionMode
        case collisionPolicy
        case deleteOriginalsMode
        case downloadBeforeProcessing
        case enableOtherBucket
        case tagsEnabled
        case tagNames
        case tagConfiguration
        case screenshotPrefixes
        case cameraPrefixes
        case projectMarkers
        case extensionRules
        case extensionExclusions
        case ownerMatching
        case duplicateDetection
        case largeFileFilter
        case pdfDateGrouping
        case cleanupEmptyFolders
        case incrementalScan
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        self.autoFileUnassigned = try container.decodeIfPresent(Bool.self, forKey: .autoFileUnassigned) ?? false
        self.autoFileShared = try container.decodeIfPresent(Bool.self, forKey: .autoFileShared) ?? false
        self.executionMode = try container.decodeIfPresent(ExecutionMode.self, forKey: .executionMode) ?? .copyFirst
        self.collisionPolicy = try container.decodeIfPresent(CollisionPolicy.self, forKey: .collisionPolicy) ?? .autoSuffix
        self.deleteOriginalsMode = try container.decodeIfPresent(DeleteOriginalsMode.self, forKey: .deleteOriginalsMode) ?? .moveToTrash
        self.downloadBeforeProcessing = try container.decodeIfPresent(Bool.self, forKey: .downloadBeforeProcessing) ?? false
        self.enableOtherBucket = try container.decodeIfPresent(Bool.self, forKey: .enableOtherBucket) ?? false
        self.tagsEnabled = try container.decodeIfPresent(Bool.self, forKey: .tagsEnabled) ?? false
        self.tagNames = try container.decodeIfPresent([String].self, forKey: .tagNames) ?? []
        // Migration: if tagConfiguration missing but tagNames present, convert
        if let config = try container.decodeIfPresent(TagConfiguration.self, forKey: .tagConfiguration) {
            self.tagConfiguration = config
        } else {
            self.tagConfiguration = TagConfiguration.fromLegacyTags(self.tagNames)
        }
        self.screenshotPrefixes = try container.decodeIfPresent([String].self, forKey: .screenshotPrefixes) ?? ["Screenshot", "Screen Shot"]
        self.cameraPrefixes = try container.decodeIfPresent([String].self, forKey: .cameraPrefixes) ?? ["IMG_", "DSC_", "PXL_"]
        self.projectMarkers = try container.decodeIfPresent([String].self, forKey: .projectMarkers)
            ?? [".git", ".svn", ".hg", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "Pipfile", "Podfile"]
        self.extensionRules = try container.decodeIfPresent([ExtensionRule].self, forKey: .extensionRules) ?? []
        self.extensionExclusions = try container.decodeIfPresent(ExtensionExclusions.self, forKey: .extensionExclusions)
            ?? ExtensionExclusions()
        self.ownerMatching = try container.decodeIfPresent(OwnerMatchingSettings.self, forKey: .ownerMatching)
            ?? OwnerMatchingSettings()
        self.duplicateDetection = try container.decodeIfPresent(DuplicateDetectionSettings.self, forKey: .duplicateDetection)
            ?? DuplicateDetectionSettings()
        self.largeFileFilter = try container.decodeIfPresent(LargeFileFilterSettings.self, forKey: .largeFileFilter)
            ?? LargeFileFilterSettings()
        self.pdfDateGrouping = try container.decodeIfPresent(PDFDateGrouping.self, forKey: .pdfDateGrouping)
            ?? .year
        self.cleanupEmptyFolders = try container.decodeIfPresent(Bool.self, forKey: .cleanupEmptyFolders)
            ?? false
        self.incrementalScan = try container.decodeIfPresent(IncrementalScanSettings.self, forKey: .incrementalScan)
            ?? IncrementalScanSettings()
    }
}

/// Project container with all configuration
public struct Project: Codable, Identifiable, Sendable {
    public static let currentSchemaVersion = 1
    
    public let id: EntityID
    public var name: String
    public var schemaVersion: Int
    public var engineVersion: String
    public var createdAt: Date
    public var updatedAt: Date
    
    public var sourceRoots: [SourceRoot]
    public var destinationRoot: DestinationRoot?
    public var people: [Person]
    public var settings: ProjectSettings
    
    public var currentScanId: EntityID?
    public var currentPlanId: EntityID?
    
    public init(
        id: EntityID = EntityID(),
        name: String,
        sourceRoots: [SourceRoot] = [],
        destinationRoot: DestinationRoot? = nil,
        people: [Person] = [],
        settings: ProjectSettings = ProjectSettings()
    ) {
        self.id = id
        self.name = name
        self.schemaVersion = Self.currentSchemaVersion
        self.engineVersion = "1.0.0"
        self.createdAt = Date()
        self.updatedAt = Date()
        self.sourceRoots = sourceRoots
        self.destinationRoot = destinationRoot
        self.people = people
        self.settings = settings
        self.currentScanId = nil
        self.currentPlanId = nil
    }
}
