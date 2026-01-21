import Foundation
import UniformTypeIdentifiers

/// Detects file types using UTType and extension fallback
public struct TypeDetector: Sendable {
    
    // PERF: Extension-first lookup for common file types
    // Avoids costly UTType resolution for unambiguous extensions
    private static let knownExtensionTypes: [String: String] = [
        // Images
        "jpg": "public.jpeg", "jpeg": "public.jpeg", "png": "public.png",
        "gif": "com.compuserve.gif", "heic": "public.heic", "heif": "public.heif",
        "webp": "org.webmproject.webp", "tiff": "public.tiff", "tif": "public.tiff",
        "bmp": "com.microsoft.bmp", "ico": "com.microsoft.ico", "svg": "public.svg-image",
        "raw": "public.camera-raw-image", "cr2": "com.canon.cr2-raw-image",
        "nef": "com.nikon.nef-raw-image", "arw": "com.sony.arw-raw-image",
        
        // Documents
        "pdf": "com.adobe.pdf",
        "doc": "com.microsoft.word.doc", "docx": "org.openxmlformats.wordprocessingml.document",
        "xls": "com.microsoft.excel.xls", "xlsx": "org.openxmlformats.spreadsheetml.sheet",
        "ppt": "com.microsoft.powerpoint.ppt", "pptx": "org.openxmlformats.presentationml.presentation",
        "txt": "public.plain-text", "rtf": "public.rtf", "csv": "public.comma-separated-values-text",
        "md": "net.daringfireball.markdown", "json": "public.json", "xml": "public.xml",
        
        // Audio
        "mp3": "public.mp3", "m4a": "public.mpeg-4-audio", "aac": "public.aac-audio",
        "wav": "com.microsoft.waveform-audio", "flac": "org.xiph.flac", "aiff": "public.aiff-audio",
        
        // Video
        "mp4": "public.mpeg-4", "mov": "com.apple.quicktime-movie", "avi": "public.avi",
        "mkv": "io.matroska.mkv", "wmv": "com.microsoft.windows-media-wmv",
        "m4v": "com.apple.m4v-video", "webm": "org.webmproject.webm",
        
        // Archives
        "zip": "public.zip-archive", "tar": "public.tar-archive", "gz": "org.gnu.gnu-zip-archive",
        "rar": "com.rarlab.rar-archive", "7z": "org.7-zip.7-zip-archive", "dmg": "com.apple.disk-image",
        
        // Code/Dev
        "swift": "public.swift-source", "py": "public.python-script", "js": "com.netscape.javascript-source",
        "ts": "public.source-code", "html": "public.html", "css": "public.css",
        "java": "com.sun.java-source", "c": "public.c-source", "cpp": "public.c-plus-plus-source",
        "h": "public.c-header", "m": "public.objective-c-source", "rb": "public.ruby-script",
        "go": "public.source-code", "rs": "public.source-code", "sh": "public.shell-script"
    ]
    
    public init() {}
    
    /// Detect UTType identifier for a file
    /// Uses extension-first fast path for common types to avoid costly UTType resolution
    public func detectType(at url: URL) -> String? {
        let ext = url.pathExtension.lowercased()
        
        // PERF: Fast path for common extensions
        if let knownType = Self.knownExtensionTypes[ext] {
            return knownType
        }
        
        // Fall back to UTType for uncommon/ambiguous extensions
        if let uttype = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return uttype.identifier
        }
        
        // Last resort: UTType from extension
        if !ext.isEmpty, let uttype = UTType(filenameExtension: ext) {
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
