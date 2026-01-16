import Foundation

/// Represents a single file or atomic package in the inventory
public struct InventoryItem: Codable, Identifiable, Sendable, Hashable {
    public let id: String  // itemId
    public let scanId: EntityID
    public let sourceRootId: EntityID
    public let relativePath: String
    
    public let isPackage: Bool
    public let isSymlink: Bool
    public let isAlias: Bool
    public let sizeBytes: Int64
    public let modifiedTime: Date
    public let createdTime: Date?
    public let exifDateTimeOriginal: Date?
    public let isCloudOnly: Bool
    
    public let uttypeIdentifier: String?
    public let `extension`: String?
    
    public init(
        id: String,
        scanId: EntityID,
        sourceRootId: EntityID,
        relativePath: String,
        isPackage: Bool = false,
        isSymlink: Bool = false,
        isAlias: Bool = false,
        sizeBytes: Int64,
        modifiedTime: Date,
        createdTime: Date? = nil,
        exifDateTimeOriginal: Date? = nil,
        isCloudOnly: Bool = false,
        uttypeIdentifier: String? = nil,
        extension: String? = nil
    ) {
        self.id = id
        self.scanId = scanId
        self.sourceRootId = sourceRootId
        self.relativePath = relativePath
        self.isPackage = isPackage
        self.isSymlink = isSymlink
        self.isAlias = isAlias
        self.sizeBytes = sizeBytes
        self.modifiedTime = modifiedTime
        self.createdTime = createdTime
        self.exifDateTimeOriginal = exifDateTimeOriginal
        self.isCloudOnly = isCloudOnly
        self.uttypeIdentifier = uttypeIdentifier
        self.extension = `extension`
    }
    
    /// Full path reconstructed from source root path + relative path
    public func fullPath(withSourceRootPath rootPath: String) -> String {
        return (rootPath as NSString).appendingPathComponent(relativePath)
    }
    
    /// Routing date based on spec rules
    public var routingDate: Date {
        exifDateTimeOriginal ?? modifiedTime
    }
    
    public var routingDateSource: RoutingDateSource {
        exifDateTimeOriginal != nil ? .exifOriginal : .modifiedTime
    }
}

/// Scan metadata
public struct Scan: Codable, Identifiable, Sendable {
    public let id: EntityID  // scanId
    public let projectId: EntityID
    public let startedAt: Date
    public var completedAt: Date?
    public var itemCount: Int
    public var totalBytes: Int64
    
    public init(
        id: EntityID = EntityID(),
        projectId: EntityID,
        startedAt: Date = Date(),
        completedAt: Date? = nil,
        itemCount: Int = 0,
        totalBytes: Int64 = 0
    ) {
        self.id = id
        self.projectId = projectId
        self.startedAt = startedAt
        self.completedAt = completedAt
        self.itemCount = itemCount
        self.totalBytes = totalBytes
    }
}

/// Immutable snapshot of source root at scan time
public struct ScanSourceRoot: Codable, Sendable, Hashable {
    public let scanId: EntityID
    public let sourceRootId: EntityID
    public let pathAtScan: String
    public let slugAtScan: String
    
    public init(scanId: EntityID, sourceRootId: EntityID, pathAtScan: String, slugAtScan: String) {
        self.scanId = scanId
        self.sourceRootId = sourceRootId
        self.pathAtScan = pathAtScan
        self.slugAtScan = slugAtScan
    }
}
