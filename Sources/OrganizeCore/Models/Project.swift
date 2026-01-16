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
    public var tagNames: [String]
    public var screenshotPrefixes: [String]
    public var cameraPrefixes: [String]
    public var projectMarkers: [String]
    
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
        screenshotPrefixes: [String] = ["Screenshot", "Screen Shot"],
        cameraPrefixes: [String] = ["IMG_", "DSC_", "PXL_"],
        projectMarkers: [String] = [".git", ".svn", ".hg", "package.json", "Cargo.toml", "go.mod", "pyproject.toml", "requirements.txt", "Pipfile", "Podfile"]
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
        self.screenshotPrefixes = screenshotPrefixes
        self.cameraPrefixes = cameraPrefixes
        self.projectMarkers = projectMarkers
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
