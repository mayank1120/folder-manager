import Foundation

// MARK: - Plan Building Context

/// Context for building a plan, encapsulating shared state
public struct PlanBuildContext: Sendable {
    public let project: Project
    public let scanId: EntityID
    public let destinationRoot: URL
    public let resolvedRuleDestinations: [EntityID: URL]
    public let userOverrides: [EntityID: UserOverride]
    public let scanRootById: [EntityID: String]
    
    public init(
        project: Project,
        scanId: EntityID,
        destinationRoot: URL,
        resolvedRuleDestinations: [EntityID: URL],
        userOverrides: [EntityID: UserOverride],
        scanRootById: [EntityID: String]
    ) {
        self.project = project
        self.scanId = scanId
        self.destinationRoot = destinationRoot
        self.resolvedRuleDestinations = resolvedRuleDestinations
        self.userOverrides = userOverrides
        self.scanRootById = scanRootById
    }
}

// MARK: - Operation ID Generator

/// Generates deterministic operation IDs
public struct OperationIdGenerator {
    
    /// Generate a unique operation ID from plan and item
    public static func generate(planId: EntityID, itemId: EntityID) -> String {
        return "\(planId.uuidString)-\(itemId.uuidString)"
    }
    
    /// Generate a collision-safe operation ID with suffix
    public static func generateWithSuffix(
        planId: EntityID,
        itemId: EntityID,
        suffix: Int
    ) -> String {
        return "\(planId.uuidString)-\(itemId.uuidString)-\(suffix)"
    }
}

// MARK: - Extension Matching Helpers

/// Result of extension rule matching
public struct ExtensionMatchResult: Sendable {
    public let matchedRule: ExtensionRule?
    public let isExcluded: Bool
    public let exclusionReason: String?
    
    public init(matchedRule: ExtensionRule?, isExcluded: Bool, exclusionReason: String?) {
        self.matchedRule = matchedRule
        self.isExcluded = isExcluded
        self.exclusionReason = exclusionReason
    }
    
    public static let noMatch = ExtensionMatchResult(matchedRule: nil, isExcluded: false, exclusionReason: nil)
    public static func excluded(_ reason: String) -> ExtensionMatchResult {
        ExtensionMatchResult(matchedRule: nil, isExcluded: true, exclusionReason: reason)
    }
}

// MARK: - Path Validation Helpers

/// Utilities for validating destination paths during planning
public enum PlanPathValidator {
    
    /// Validate a destination path is safe for use
    public static func validateDestination(
        _ path: String,
        allowedRoots: [URL]
    ) -> Bool {
        // Use PathSecurity for validation
        guard PathSecurity.isPathSafe(path) else {
            return false
        }
        
        // If absolute, must be within allowed roots
        if path.hasPrefix("/") {
            let destURL = URL(fileURLWithPath: path).standardizedFileURL
            return allowedRoots.contains { root in
                destURL.path.hasPrefix(root.standardizedFileURL.path)
            }
        }
        
        return true
    }
    
    /// Build a safe destination path with sanitization
    public static func buildSafeDestPath(
        base: URL,
        components: [String],
        filename: String
    ) -> String {
        var path = base
        for component in components {
            path = path.appendingPathComponent(component)
        }
        let safeFilename = PathSecurity.sanitizeFilename(filename)
        return path.appendingPathComponent(safeFilename).path
    }
}
