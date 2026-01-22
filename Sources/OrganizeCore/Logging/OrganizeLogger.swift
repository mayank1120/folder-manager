import Foundation
import os.log

// MARK: - Organize Logger

/// Centralized logging system for OrganizeCore
/// Uses OSLog for efficient, privacy-aware logging
public enum OrganizeLogger {
    
    // MARK: - Log Subsystems
    
    private static let subsystem = "com.organize.core"
    
    /// Logger for scanner operations
    public static let scanner = Logger(subsystem: subsystem, category: "scanner")
    
    /// Logger for planner operations
    public static let planner = Logger(subsystem: subsystem, category: "planner")
    
    /// Logger for apply/execution operations
    public static let apply = Logger(subsystem: subsystem, category: "apply")
    
    /// Logger for verification operations
    public static let verify = Logger(subsystem: subsystem, category: "verify")
    
    /// Logger for rollback operations
    public static let rollback = Logger(subsystem: subsystem, category: "rollback")
    
    /// Logger for database operations
    public static let database = Logger(subsystem: subsystem, category: "database")
    
    /// Logger for security-related events
    public static let security = Logger(subsystem: subsystem, category: "security")
    
    // MARK: - Convenience Methods
    
    /// Log a debug message
    public static func debug(_ message: String, category: LogCategory = .general) {
        category.logger.debug("\(message, privacy: .public)")
    }
    
    /// Log an info message
    public static func info(_ message: String, category: LogCategory = .general) {
        category.logger.info("\(message, privacy: .public)")
    }
    
    /// Log a warning message
    public static func warning(_ message: String, category: LogCategory = .general) {
        category.logger.warning("\(message, privacy: .public)")
    }
    
    /// Log an error message
    public static func error(_ message: String, category: LogCategory = .general) {
        category.logger.error("\(message, privacy: .public)")
    }
    
    /// Log an error with Error object
    public static func error(_ message: String, error: Error, category: LogCategory = .general) {
        category.logger.error("\(message, privacy: .public): \(error.localizedDescription, privacy: .public)")
    }
    
    /// Log a critical/fault message
    public static func fault(_ message: String, category: LogCategory = .general) {
        category.logger.fault("\(message, privacy: .public)")
    }
    
    // MARK: - File Path Logging (Privacy-aware)
    
    /// Log a file operation with privacy-aware path
    public static func logFileOperation(
        _ operation: String,
        path: String,
        category: LogCategory = .apply
    ) {
        // Only log filename, not full path, for privacy in production
        let filename = URL(fileURLWithPath: path).lastPathComponent
        category.logger.info("\(operation, privacy: .public): \(filename, privacy: .private(mask: .hash))")
    }
    
    /// Log a file operation with size
    public static func logFileWithSize(
        _ operation: String,
        path: String,
        sizeBytes: Int64,
        category: LogCategory = .apply
    ) {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        let sizeStr = ByteCountFormatter.string(fromByteCount: sizeBytes, countStyle: .file)
        category.logger.info("\(operation, privacy: .public): \(filename, privacy: .private(mask: .hash)) (\(sizeStr, privacy: .public))")
    }
    
    /// Log a security event
    public static func logSecurityEvent(_ event: String, detail: String? = nil) {
        if let detail = detail {
            security.warning("Security: \(event, privacy: .public) - \(detail, privacy: .private)")
        } else {
            security.warning("Security: \(event, privacy: .public)")
        }
    }
    
    /// Log a skipped operation with reason
    public static func logSkipped(_ reason: String, path: String, category: LogCategory = .apply) {
        let filename = URL(fileURLWithPath: path).lastPathComponent
        category.logger.info("Skipped: \(reason, privacy: .public) - \(filename, privacy: .private(mask: .hash))")
    }
}

// MARK: - Log Categories

public enum LogCategory: String, CaseIterable, Sendable {
    case general
    case scanner
    case planner
    case apply
    case verify
    case rollback
    case database
    case security
    
    var logger: Logger {
        switch self {
        case .general:
            return Logger(subsystem: "com.organize.core", category: "general")
        case .scanner:
            return OrganizeLogger.scanner
        case .planner:
            return OrganizeLogger.planner
        case .apply:
            return OrganizeLogger.apply
        case .verify:
            return OrganizeLogger.verify
        case .rollback:
            return OrganizeLogger.rollback
        case .database:
            return OrganizeLogger.database
        case .security:
            return OrganizeLogger.security
        }
    }
}

// MARK: - Signpost Support

/// Signpost support for performance profiling
public struct OrganizeSignpost {
    private static let subsystem = "com.organize.core"
    
    public static let scanner = OSSignposter(subsystem: subsystem, category: "scanner")
    public static let planner = OSSignposter(subsystem: subsystem, category: "planner")
    public static let apply = OSSignposter(subsystem: subsystem, category: "apply")
    
    /// Begin a signpost interval
    public static func begin(_ name: StaticString, signposter: OSSignposter = scanner) -> OSSignpostIntervalState {
        return signposter.beginInterval(name)
    }
    
    /// End a signpost interval
    public static func end(_ name: StaticString, _ state: OSSignpostIntervalState, signposter: OSSignposter = scanner) {
        signposter.endInterval(name, state)
    }
}
