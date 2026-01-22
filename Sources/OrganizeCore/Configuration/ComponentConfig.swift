import Foundation

// MARK: - Scanner Configuration

/// Configuration options for the Scanner component
public struct ScannerConfiguration: Codable, Sendable, Hashable {
    /// Number of items to batch before writing to database
    public var batchSize: Int
    
    /// Whether to compute content hashes for duplicate detection
    public var computeHashes: Bool
    
    /// Maximum file size for hashing (larger files skip hashing)
    public var maxHashFileSizeBytes: Int64
    
    /// Whether to follow symbolic links
    public var followSymlinks: Bool
    
    /// File extensions to always exclude from scanning
    public var excludedExtensions: Set<String>
    
    public init(
        batchSize: Int = 100,
        computeHashes: Bool = false,
        maxHashFileSizeBytes: Int64 = 500 * 1024 * 1024, // 500 MB
        followSymlinks: Bool = false,
        excludedExtensions: Set<String> = [".DS_Store", ".localized"]
    ) {
        self.batchSize = batchSize
        self.computeHashes = computeHashes
        self.maxHashFileSizeBytes = maxHashFileSizeBytes
        self.followSymlinks = followSymlinks
        self.excludedExtensions = excludedExtensions
    }
    
    public static let `default` = ScannerConfiguration()
}

// MARK: - Planner Configuration

/// Configuration options for the Planner component
public struct PlannerConfiguration: Codable, Sendable, Hashable {
    /// Number of items to batch before writing to database
    public var batchSize: Int
    
    /// Whether to validate destination paths for security
    public var validateDestinations: Bool
    
    /// Whether to sanitize filenames during planning
    public var sanitizeFilenames: Bool
    
    public init(
        batchSize: Int = 100,
        validateDestinations: Bool = true,
        sanitizeFilenames: Bool = true
    ) {
        self.batchSize = batchSize
        self.validateDestinations = validateDestinations
        self.sanitizeFilenames = sanitizeFilenames
    }
    
    public static let `default` = PlannerConfiguration()
}

// MARK: - Apply Engine Configuration

/// Configuration options for the ApplyEngine component
public struct ApplyConfiguration: Codable, Sendable, Hashable {
    /// Whether to use atomic file operations (copy to temp, then rename)
    public var useAtomicOperations: Bool
    
    /// Whether to preserve file metadata (dates, permissions)
    public var preserveMetadata: Bool
    
    /// Maximum retries for transient failures
    public var maxRetries: Int
    
    /// Delay between retries in seconds
    public var retryDelaySeconds: Double
    
    /// Whether to clean up empty folders after moves
    public var cleanupEmptyFolders: Bool
    
    public init(
        useAtomicOperations: Bool = true,
        preserveMetadata: Bool = true,
        maxRetries: Int = 3,
        retryDelaySeconds: Double = 0.5,
        cleanupEmptyFolders: Bool = false
    ) {
        self.useAtomicOperations = useAtomicOperations
        self.preserveMetadata = preserveMetadata
        self.maxRetries = maxRetries
        self.retryDelaySeconds = retryDelaySeconds
        self.cleanupEmptyFolders = cleanupEmptyFolders
    }
    
    public static let `default` = ApplyConfiguration()
}

// MARK: - Verify Engine Configuration

/// Configuration options for the VerifyEngine component
public struct VerifyConfiguration: Codable, Sendable, Hashable {
    /// File size threshold at or below which hash verification is performed
    public var hashThresholdBytes: Int64
    
    /// Whether to verify file sizes
    public var verifySizes: Bool
    
    /// Whether to verify content hashes for files at or below threshold
    public var verifyHashes: Bool
    
    public init(
        hashThresholdBytes: Int64 = 5 * 1024 * 1024, // 5 MB
        verifySizes: Bool = true,
        verifyHashes: Bool = true
    ) {
        self.hashThresholdBytes = hashThresholdBytes
        self.verifySizes = verifySizes
        self.verifyHashes = verifyHashes
    }
    
    public static let `default` = VerifyConfiguration()
}
