import Foundation

/// Shared helper for reading and writing Finder tags
/// Used by both ApplyEngine and RollbackManager
public enum TagHelper {
    
    // MARK: - Tag Operations
    
    /// Read current Finder tags from a file
    public static func readTags(from url: URL) -> [String] {
        // Use extended attribute directly for compatibility
        do {
            let data = try url.extendedAttribute(forName: "com.apple.metadata:_kMDItemUserTags")
            if let plist = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String] {
                // Tags are stored with color suffix like "TagName\n6" - strip the suffix
                return plist.map { tag in
                    if let range = tag.range(of: "\n") {
                        return String(tag[..<range.lowerBound])
                    }
                    return tag
                }
            }
        } catch {
            // No tags or can't read - return empty
        }
        return []
    }
    
    /// Write Finder tags to a file
    public static func writeTags(_ tags: [String], to url: URL) throws {
        // Convert tags to plist format with default color (gray = 0)
        let plistTags = tags.map { "\($0)\n0" }
        let data = try PropertyListSerialization.data(fromPropertyList: plistTags, format: .binary, options: 0)
        try url.setExtendedAttribute(data: data, forName: "com.apple.metadata:_kMDItemUserTags")
    }
    
    /// Merge existing tags with additional tags (no duplicates)
    public static func mergeTags(existing: [String], additional: [String]) -> [String] {
        var merged = existing
        for tag in additional {
            if !merged.contains(tag) {
                merged.append(tag)
            }
        }
        return merged
    }
    
    /// Remove specific tags from current set
    public static func removeTags(_ tagsToRemove: [String], from current: [String]) -> [String] {
        return current.filter { !tagsToRemove.contains($0) }
    }
    
    /// Restore tags to previous state
    public static func restoreTags(to previousTags: [String], at url: URL) throws {
        try writeTags(previousTags, to: url)
    }
}

// MARK: - Extended Attribute Helpers

extension URL {
    func extendedAttribute(forName name: String) throws -> Data {
        let path = self.path
        let length = getxattr(path, name, nil, 0, 0, 0)
        guard length >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        var data = Data(count: length)
        let result = data.withUnsafeMutableBytes { ptr in
            getxattr(path, name, ptr.baseAddress, length, 0, 0)
        }
        guard result >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        return data
    }
    
    func setExtendedAttribute(data: Data, forName name: String) throws {
        let path = self.path
        let result = data.withUnsafeBytes { ptr in
            setxattr(path, name, ptr.baseAddress, data.count, 0, 0)
        }
        guard result >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
    
    func removeExtendedAttribute(forName name: String) throws {
        let path = self.path
        let result = removexattr(path, name, 0)
        guard result >= 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
    }
}
