import Foundation

/// Security utilities for path validation and sanitization
public enum PathSecurity {
    
    // MARK: - Path Traversal Protection
    
    /// Validates that a path doesn't contain traversal sequences that could escape the allowed root
    /// - Parameters:
    ///   - path: The path to validate
    ///   - allowedRoot: The root directory the path must stay within (optional, if nil only checks for traversal sequences)
    /// - Returns: True if path is safe, false if path contains traversal attempts
    public static func isPathSafe(_ path: String, withinRoot allowedRoot: URL? = nil) -> Bool {
        // Use component-wise validation to avoid false positives from substring matching
        // (e.g., "data..csv" should not be flagged as traversal)
        let components = path.split(separator: "/", omittingEmptySubsequences: false).map(String.init)
        
        for component in components {
            // Check for parent directory traversal
            if component == ".." {
                return false
            }
            // Check for null bytes (could terminate strings early in C APIs)
            if component.contains("\0") {
                return false
            }
        }
        
        // If allowed root specified, verify resolved path stays within it
        if let root = allowedRoot {
            let resolvedPath = URL(fileURLWithPath: path).standardizedFileURL.path
            let rootPath = root.standardizedFileURL.path
            
            // Resolved path must start with root path (with proper boundary check)
            if !resolvedPath.hasPrefix(rootPath) {
                return false
            }
            // Ensure we're matching a complete path component, not just a prefix
            // e.g., /foo/bar should not match /foo/barbaz
            if resolvedPath.count > rootPath.count {
                let nextChar = resolvedPath[resolvedPath.index(resolvedPath.startIndex, offsetBy: rootPath.count)]
                if nextChar != "/" && rootPath != "/" {
                    return false
                }
            }
        }
        
        return true
    }
    
    /// Validates a destination path for custom extension rules
    /// - Parameters:
    ///   - destPath: The destination path from user configuration
    ///   - allowedRoots: Set of allowed root directories (destination root + source roots)
    /// - Throws: PathSecurityError if path is invalid
    public static func validateCustomDestination(_ destPath: String, allowedRoots: [URL]) throws {
        // Empty path is invalid
        guard !destPath.isEmpty else {
            throw PathSecurityError.emptyPath
        }
        
        // Check for traversal patterns
        guard isPathSafe(destPath) else {
            throw PathSecurityError.pathTraversal(path: destPath)
        }
        
        // If absolute path, must be within one of the allowed roots
        if destPath.hasPrefix("/") {
            let destURL = URL(fileURLWithPath: destPath).standardizedFileURL
            let isWithinAllowed = allowedRoots.contains { root in
                destURL.path.hasPrefix(root.standardizedFileURL.path)
            }
            
            if !isWithinAllowed {
                throw PathSecurityError.outsideAllowedRoots(path: destPath)
            }
        }
    }
    
    // MARK: - Filename Sanitization
    
    /// Sanitizes a filename by removing or replacing dangerous characters
    /// - Parameter filename: The filename to sanitize
    /// - Returns: Sanitized filename safe for filesystem use
    public static func sanitizeFilename(_ filename: String) -> String {
        // Characters not allowed in filenames on macOS/Windows
        let dangerous: Set<Character> = ["/", "\\", ":", "*", "?", "\"", "<", ">", "|", "\0"]
        
        var sanitized = filename.filter { !dangerous.contains($0) }
        
        // Remove leading/trailing dots and spaces
        sanitized = sanitized.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        
        // Ensure non-empty result
        if sanitized.isEmpty {
            sanitized = "unnamed"
        }
        
        // Limit length (macOS max is 255 bytes, use 200 to be safe with UTF-8)
        if sanitized.utf8.count > 200 {
            // Truncate while keeping extension if present
            let ext = (filename as NSString).pathExtension
            let nameWithoutExt = (sanitized as NSString).deletingPathExtension
            let maxNameLength = 200 - ext.utf8.count - 1
            
            if maxNameLength > 0 {
                var truncated = String(nameWithoutExt.prefix(maxNameLength))
                if !ext.isEmpty {
                    truncated += "." + ext
                }
                sanitized = truncated
            }
        }
        
        return sanitized
    }
    
    /// Validates that a path component (single filename) is safe
    public static func isValidPathComponent(_ component: String) -> Bool {
        guard !component.isEmpty else { return false }
        guard component != "." && component != ".." else { return false }
        
        let dangerous: Set<Character> = ["/", "\\", ":", "\0"]
        return !component.contains { dangerous.contains($0) }
    }
    
    // MARK: - Symlink Escape Protection
    
    /// Validates that a relative path doesn't contain escape sequences or absolute components
    /// - Parameter relativePath: The relative path to validate
    /// - Returns: True if the relative path is safe
    public static func isRelativePathSafe(_ relativePath: String) -> Bool {
        // Relative paths should never start with /
        if relativePath.hasPrefix("/") {
            return false
        }
        
        // Split into components and validate each
        let components = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        
        for component in components {
            let comp = String(component)
            
            // No parent directory traversal
            if comp == ".." {
                return false
            }
            
            // No empty components (double slashes)
            if comp.isEmpty && component != components.first {
                return false
            }
            
            // No absolute paths embedded (Windows-style)
            if comp.contains(":") {
                return false
            }
        }
        
        return true
    }
    
    /// Resolves a path and verifies it doesn't escape the root directory via symlinks
    /// - Parameters:
    ///   - url: The URL to check
    ///   - root: The root directory it should stay within
    /// - Returns: The resolved real path if safe, nil if escape detected
    public static func resolveAndValidate(_ url: URL, withinRoot root: URL) -> URL? {
        let fm = FileManager.default
        
        // Get the real paths (resolving all symlinks)
        guard let realPath = try? fm.destinationOfSymbolicLink(atPath: url.path) else {
            // Not a symlink, use standardized path
            let standardized = url.standardizedFileURL
            let rootStandardized = root.standardizedFileURL
            
            guard standardized.path.hasPrefix(rootStandardized.path) else {
                return nil
            }
            return standardized
        }
        
        // Symlink detected - resolve and validate target
        let realURL = URL(fileURLWithPath: realPath).standardizedFileURL
        let rootStandardized = root.standardizedFileURL
        
        guard realURL.path.hasPrefix(rootStandardized.path) else {
            return nil // Symlink points outside root
        }
        
        return realURL
    }
    
    /// Validates a constructed destination path is safe (no escape via symlinks or traversal)
    /// - Parameters:
    ///   - basePath: The base destination directory
    ///   - relativePath: The relative path to append
    /// - Returns: Safe combined URL, or nil if validation fails
    public static func safeDestinationURL(base: URL, relativePath: String) -> URL? {
        // First validate the relative path structure
        guard isRelativePathSafe(relativePath) else {
            return nil
        }
        
        // Construct the full path
        let fullURL = base.appendingPathComponent(relativePath).standardizedFileURL
        
        // Verify it stays within base
        guard fullURL.path.hasPrefix(base.standardizedFileURL.path) else {
            return nil
        }
        
        return fullURL
    }
}

// MARK: - Errors

public enum PathSecurityError: Error, LocalizedError {
    case emptyPath
    case pathTraversal(path: String)
    case outsideAllowedRoots(path: String)
    case invalidFilename(filename: String)
    
    public var errorDescription: String? {
        switch self {
        case .emptyPath:
            return "Path cannot be empty"
        case .pathTraversal(let path):
            return "Path contains directory traversal sequences: \(path)"
        case .outsideAllowedRoots(let path):
            return "Path is outside allowed directories: \(path)"
        case .invalidFilename(let filename):
            return "Invalid filename: \(filename)"
        }
    }
}
