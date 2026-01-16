import Foundation

/// Exclusion reason codes (structured, not stringly-typed)
public enum ExclusionReason: String, Codable, Sendable {
    // Symlink/Alias
    case symlink = "PolicyExclude:Symlink"
    case finderAlias = "PolicyExclude:FinderAlias"
    
    // Hidden items (dotfiles/dotfolders, Finder-hidden)
    case hiddenItem = "PolicyExclude:HiddenItem"
    
    // Packages
    case appBundle = "PolicyExclude:AppBundle"
    case photoLibrary = "PolicyExclude:PhotoLibrary"
    case packageGeneric = "PolicyExclude:Package"
    
    // Project folders
    case projectFolder = "PolicyExclude:ProjectFolder"
}

/// Excluded item record (persisted to DB)
public struct ExcludedItem: Codable, Sendable {
    public let scanId: EntityID
    public let sourceRootId: EntityID
    public let relativePath: String
    public let absolutePath: String
    public let reason: ExclusionReason
    public let isDirectory: Bool
    
    public init(
        scanId: EntityID,
        sourceRootId: EntityID,
        relativePath: String,
        absolutePath: String,
        reason: ExclusionReason,
        isDirectory: Bool = false
    ) {
        self.scanId = scanId
        self.sourceRootId = sourceRootId
        self.relativePath = relativePath
        self.absolutePath = absolutePath
        self.reason = reason
        self.isDirectory = isDirectory
    }
}
