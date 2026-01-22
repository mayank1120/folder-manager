import Foundation

/// Configuration for tagging organized files
///
/// > Note: Currently only `globalTags` are applied during execution.
/// > `categoryTags` and `ownerTags` are reserved for future implementation
/// > and are not yet wired into ApplyEngine.
public struct TagConfiguration: Codable, Sendable, Hashable {
    /// Tags applied to all organized files (fully implemented)
    public var globalTags: [String]
    
    /// [EXPERIMENTAL] Tags applied based on file category - NOT YET IMPLEMENTED in ApplyEngine
    public var categoryTags: [String: [String]]
    
    /// [EXPERIMENTAL] Tags applied based on owner bucket - NOT YET IMPLEMENTED in ApplyEngine
    public var ownerTags: [String: [String]]
    
    public init(
        globalTags: [String] = [],
        categoryTags: [String: [String]] = [:],
        ownerTags: [String: [String]] = [:]
    ) {
        self.globalTags = globalTags
        self.categoryTags = categoryTags
        self.ownerTags = ownerTags
    }
    
    /// Compute effective tags for an item given its category and owner
    public func effectiveTags(category: String?, owner: String?) -> [String] {
        var tags = globalTags
        
        if let category = category, let categorySpecific = categoryTags[category] {
            tags.append(contentsOf: categorySpecific)
        }
        
        if let owner = owner, let ownerSpecific = ownerTags[owner] {
            tags.append(contentsOf: ownerSpecific)
        }
        
        // Remove duplicates while preserving order
        return tags.reduce(into: [String]()) { result, tag in
            if !result.contains(tag) {
                result.append(tag)
            }
        }
    }
    
    /// Check if any tags are configured
    public var isEmpty: Bool {
        globalTags.isEmpty && categoryTags.isEmpty && ownerTags.isEmpty
    }
    
    /// Legacy compatibility: convert to/from simple tag array
    public static func fromLegacyTags(_ tags: [String]) -> TagConfiguration {
        TagConfiguration(globalTags: tags)
    }
    
    public var legacyTags: [String] {
        globalTags
    }
}
