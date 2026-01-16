import Foundation

/// Manages security-scoped bookmarks for sandbox access.
final class BookmarkManager: Sendable {
    
    /// Create a security-scoped bookmark for a URL.
    func createBookmark(for url: URL) throws -> Data {
        // Temporarily access to create bookmark
        let didAccess = url.startAccessingSecurityScopedResource()
        defer {
            if didAccess {
                url.stopAccessingSecurityScopedResource()
            }
        }
        
        return try url.bookmarkData(
            options: .withSecurityScope,
            includingResourceValuesForKeys: nil,
            relativeTo: nil
        )
    }
    
    /// Resolve a bookmark to a URL. Does NOT start access - caller must use beginAccess/endAccess.
    func resolveBookmark(_ data: Data) throws -> (url: URL, isStale: Bool) {
        var isStale = false
        let url = try URL(
            resolvingBookmarkData: data,
            options: .withSecurityScope,
            relativeTo: nil,
            bookmarkDataIsStale: &isStale
        )
        return (url, isStale)
    }
    
    /// Begin security-scoped access to a URL. Returns true if access was granted.
    /// IMPORTANT: Must be balanced with endAccess().
    func beginAccess(to url: URL) -> Bool {
        return url.startAccessingSecurityScopedResource()
    }
    
    /// End security-scoped access to a URL.
    func endAccess(to url: URL) {
        url.stopAccessingSecurityScopedResource()
    }
    
    /// Refresh a stale bookmark with a new URL.
    func refreshBookmark(oldData: Data, newURL: URL) throws -> Data {
        return try createBookmark(for: newURL)
    }
}

enum BookmarkError: Error, LocalizedError {
    case accessDenied(url: URL)
    case stale(url: URL)
    case invalidData
    
    var errorDescription: String? {
        switch self {
        case .accessDenied(let url):
            return "Access denied to \(url.lastPathComponent)"
        case .stale(let url):
            return "Bookmark for \(url.lastPathComponent) is stale and needs to be refreshed"
        case .invalidData:
            return "Invalid bookmark data"
        }
    }
}

/// Helper for RAII-style scoped access
struct ScopedAccess {
    private let urls: [URL]
    private let accessResults: [(url: URL, granted: Bool)]
    private let bookmarkManager: BookmarkManager
    
    init(urls: [URL], bookmarkManager: BookmarkManager) {
        self.urls = urls
        self.bookmarkManager = bookmarkManager
        self.accessResults = urls.map { url in
            (url: url, granted: bookmarkManager.beginAccess(to: url))
        }
    }
    
    func endAccess() {
        for result in accessResults where result.granted {
            bookmarkManager.endAccess(to: result.url)
        }
    }
    
    var allAccessGranted: Bool {
        accessResults.allSatisfy { $0.granted }
    }
    
    var deniedURLs: [URL] {
        accessResults.filter { !$0.granted }.map { $0.url }
    }
}
