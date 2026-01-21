import Foundation

/// Destination type for extension routing.
public enum ExtensionDestinationType: String, Codable, Sendable {
    case customFolder
    case organizedRoot
}

/// Which owners a rule applies to.
public enum ExtensionOwnerScope: String, Codable, Sendable {
    case perOwner
    case sharedOnly
    case allOwners
}

/// How extension exclusions are interpreted.
public enum ExtensionExcludeMode: String, Codable, Sendable {
    case excludeOnlyThese
    case excludeAllExceptThese
    case none
}

/// A rule that routes matching extensions into a custom destination.
public struct ExtensionRule: Codable, Identifiable, Sendable, Hashable {
    public let id: EntityID
    public var extensions: [String]
    public var destinationType: ExtensionDestinationType
    public var destinationPath: String?
    public var destinationIsAbsolute: Bool
    /// Security-scoped bookmark data for absolute custom destinations (App Store sandbox)
    public var destinationBookmarkData: Data?
    public var ownerScope: ExtensionOwnerScope
    public var priority: Int
    public var enabled: Bool
    public var createdAt: Date

    public init(
        id: EntityID = EntityID(),
        extensions: [String],
        destinationType: ExtensionDestinationType,
        destinationPath: String? = nil,
        destinationIsAbsolute: Bool = true,
        destinationBookmarkData: Data? = nil,
        ownerScope: ExtensionOwnerScope = .perOwner,
        priority: Int = 0,
        enabled: Bool = true,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.extensions = Self.normalizeExtensions(extensions)
        self.destinationType = destinationType
        self.destinationPath = destinationPath
        self.destinationIsAbsolute = destinationIsAbsolute
        self.destinationBookmarkData = destinationBookmarkData
        self.ownerScope = ownerScope
        self.priority = priority
        self.enabled = enabled
        self.createdAt = createdAt
    }

    /// Returns true if the provided extension matches this rule.
    public func matches(extension ext: String) -> Bool {
        let normalized = Self.normalizeExtension(ext)
        return extensions.contains(normalized)
    }

    /// Normalizes an extension (`.PDF` → `pdf`).
    public static func normalizeExtension(_ ext: String) -> String {
        let trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutDot = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        return withoutDot.lowercased()
    }

    /// Normalizes a list of extensions (deduped, sorted).
    public static func normalizeExtensions(_ list: [String]) -> [String] {
        let normalized = list.map(Self.normalizeExtension).filter { !$0.isEmpty }
        return Array(Set(normalized)).sorted()
    }
}

/// Global extension exclusion settings used by the planner.
public struct ExtensionExclusions: Codable, Sendable, Hashable {
    public var excludeMode: ExtensionExcludeMode
    public var excludedExtensions: [String]

    public init(
        excludeMode: ExtensionExcludeMode = .excludeOnlyThese,
        excludedExtensions: [String] = []
    ) {
        self.excludeMode = excludeMode
        self.excludedExtensions = ExtensionRule.normalizeExtensions(excludedExtensions)
    }
}

/// Settings controlling owner matching tokenization behavior.
public struct OwnerMatchingSettings: Codable, Sendable, Hashable {
    public var enableCamelCaseSplit: Bool
    public var enableDigitSplit: Bool

    public init(
        enableCamelCaseSplit: Bool = true,
        enableDigitSplit: Bool = false
    ) {
        self.enableCamelCaseSplit = enableCamelCaseSplit
        self.enableDigitSplit = enableDigitSplit
    }
}

/// Source of a file classification decision.
public enum ClassificationSource: String, Codable, Sendable {
    case extensionRule
    case uttype
}
