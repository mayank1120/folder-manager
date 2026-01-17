import Foundation
import UniformTypeIdentifiers

/// Detects file types using UTType and extension fallback
public struct TypeDetector: Sendable {
    
    public init() {}
    
    /// Detect UTType identifier for a file
    public func detectType(at url: URL) -> String? {
        if let uttype = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return uttype.identifier
        }
        
        // Fallback to extension
        let ext = url.pathExtension.lowercased()
        if let uttype = UTType(filenameExtension: ext) {
            return uttype.identifier
        }
        
        return nil
    }
    
    /// Check if file is an image
    public func isImage(uttypeIdentifier: String?) -> Bool {
        guard let id = uttypeIdentifier,
              let uttype = UTType(id) else {
            return false
        }
        return uttype.conforms(to: .image)
    }
    
    /// Check if file is a PDF
    public func isPDF(uttypeIdentifier: String?) -> Bool {
        guard let id = uttypeIdentifier,
              let uttype = UTType(id) else {
            return false
        }
        return uttype.conforms(to: .pdf)
    }
    
    /// Check if file is a document
    public func isDocument(uttypeIdentifier: String?) -> Bool {
        guard let id = uttypeIdentifier,
              let uttype = UTType(id) else {
            return false
        }
        return uttype.conforms(to: .compositeContent) || 
               uttype.conforms(to: .spreadsheet) ||
               uttype.conforms(to: .presentation)
    }
    
    /// Get file extension
    public func getExtension(at url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        return ext.isEmpty ? nil : ext
    }
}

/// Detects if a file/folder is a package (atomic bundle)
public struct PackageDetector: Sendable {
    
    /// Excluded package types per spec (always excluded)
    private static let excludedPackageExtensions: Set<String> = [
        "app", "photoslibrary"
    ]
    
    /// Allowed document package extensions per M1 v1.4 spec
    /// ONLY these are treated as atomic moveable items; all others → PolicyExclude:Package
    private static let allowedPackageExtensions: Set<String> = [
        "pages", "numbers", "key", "rtfd"
    ]
    
    public init() {}

    public func isKnownPackageExtension(at url: URL) -> Bool {
        let ext = url.pathExtension.lowercased()
        return Self.allowedPackageExtensions.contains(ext) || Self.excludedPackageExtensions.contains(ext)
    }
    
    /// Check if URL is a package
    public func isPackage(at url: URL) -> Bool {
        guard let resourceValues = try? url.resourceValues(forKeys: [.isPackageKey]) else {
            return false
        }
        return resourceValues.isPackage ?? false
    }
    
    /// Check if package should be excluded by policy
    public func isExcludedPackage(at url: URL) -> (isExcluded: Bool, reason: ExclusionReason?) {
        let ext = url.pathExtension.lowercased()
        
        if ext == "app" {
            return (true, .appBundle)
        }
        
        if ext == "photoslibrary" {
            return (true, .photoLibrary)
        }
        
        // Only allow document packages per spec
        if isPackage(at: url) && !Self.allowedPackageExtensions.contains(ext) {
            return (true, .packageGeneric)
        }
        
        return (false, nil)
    }
    
    /// Compute total size of package contents (excludes symlinks)
    public func computePackageSize(at url: URL) -> Int64 {
        var totalSize: Int64 = 0
        
        guard let enumerator = FileManager.default.enumerator(
            at: url,
            includingPropertiesForKeys: [.fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey],
            options: []
        ) else {
            return 0
        }
        
        for case let fileURL as URL in enumerator {
            guard let resourceValues = try? fileURL.resourceValues(forKeys: [
                .fileSizeKey, .isRegularFileKey, .isSymbolicLinkKey
            ]) else {
                continue
            }
            
            // Skip symlinks (don't follow or count)
            if resourceValues.isSymbolicLink == true {
                enumerator.skipDescendants()
                continue
            }
            
            // Only count regular files
            guard resourceValues.isRegularFile == true,
                  let size = resourceValues.fileSize else {
                continue
            }
            totalSize += Int64(size)
        }
        
        return totalSize
    }
}

/// Detects cloud-only status (iCloud, etc.)
public struct CloudStatusDetector: Sendable {
    
    public init() {}
    
    /// Check if file is cloud-only (not downloaded)
    public func isCloudOnly(at url: URL) -> Bool {
        guard let resourceValues = try? url.resourceValues(forKeys: [
            .ubiquitousItemDownloadingStatusKey
        ]) else {
            return false
        }
        
        let status = resourceValues.ubiquitousItemDownloadingStatus
        return status == .notDownloaded
    }
    
    /// Attempt to start downloading a cloud-only file
    public func startDownload(at url: URL) throws {
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
    }
}

/// Detects symlinks and Finder aliases
public struct AliasDetector: Sendable {
    
    public init() {}
    
    /// Check if URL is a symlink
    public func isSymlink(at url: URL) -> Bool {
        guard let resourceValues = try? url.resourceValues(forKeys: [.isSymbolicLinkKey]) else {
            return false
        }
        return resourceValues.isSymbolicLink ?? false
    }
    
    /// Check if URL is a Finder alias
    public func isFinderAlias(at url: URL) -> Bool {
        guard let resourceValues = try? url.resourceValues(forKeys: [.isAliasFileKey]) else {
            return false
        }
        return resourceValues.isAliasFile ?? false
    }
}

/// Detects project/repository folders by markers
public struct ProjectMarkerDetector: Sendable {
    
    /// Exact name markers (e.g., ".git", "package.json")
    private let exactMarkers: Set<String>
    
    /// Suffix markers (e.g., ".xcodeproj", ".xcworkspace")
    private let suffixMarkers: [String]
    
    /// Default suffix patterns for project detection
    private static let defaultSuffixes: [String] = [
        ".xcodeproj", ".xcworkspace", ".playground"
    ]
    
    public init(markers: [String]) {
        // Separate exact matches from suffix patterns
        var exact: Set<String> = []
        var suffixes: [String] = []
        
        for marker in markers {
            if marker.hasPrefix(".") && marker.count > 1 && !marker.contains("/") {
                // Could be a suffix pattern like ".xcodeproj" or hidden file like ".git"
                // Hidden files go to exact, package suffixes go to suffix
                if marker == ".git" || marker == ".svn" || marker == ".hg" {
                    exact.insert(marker)
                } else {
                    suffixes.append(marker)
                }
            } else {
                exact.insert(marker)
            }
        }
        
        // Add default suffixes
        suffixes.append(contentsOf: Self.defaultSuffixes)
        
        self.exactMarkers = exact
        self.suffixMarkers = Array(Set(suffixes))  // dedupe
    }
    
    /// Check if directory contains project markers
    public func containsProjectMarker(at url: URL) -> Bool {
        let fm = FileManager.default

        // Fast path: check exact marker names via fileExists (avoids listing directory contents).
        for marker in exactMarkers {
            let markerURL = url.appendingPathComponent(marker)
            if fm.fileExists(atPath: markerURL.path) {
                return true
            }
        }

        // Suffix markers require scanning direct children, but we can early-exit without building arrays.
        guard !suffixMarkers.isEmpty,
              let enumerator = fm.enumerator(
                at: url,
                includingPropertiesForKeys: [.nameKey],
                options: [.skipsSubdirectoryDescendants]
              ) else {
            return false
        }

        for case let childURL as URL in enumerator {
            let lowerName = childURL.lastPathComponent.lowercased()
            for suffix in suffixMarkers {
                if lowerName.hasSuffix(suffix.lowercased()) {
                    return true
                }
            }
        }

        return false
    }
}
