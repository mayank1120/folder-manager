import Foundation

public enum ExtensionDestinationType: String, Codable, Sendable {
    case customFolder
    case organizedRoot
}

public enum ExtensionOwnerScope: String, Codable, Sendable {
    case perOwner
    case sharedOnly
    case allOwners
}

public enum ExtensionExcludeMode: String, Codable, Sendable {
    case excludeOnlyThese
    case excludeAllExceptThese
    case none
}

public struct ExtensionRule: Codable, Identifiable, Sendable, Hashable {
    public let id: EntityID
    public var extensions: [String]
    public var destinationType: ExtensionDestinationType
    public var destinationPath: String?
    public var destinationIsAbsolute: Bool
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
        self.ownerScope = ownerScope
        self.priority = priority
        self.enabled = enabled
        self.createdAt = createdAt
    }

    public func matches(extension ext: String) -> Bool {
        let normalized = Self.normalizeExtension(ext)
        return extensions.contains(normalized)
    }

    public static func normalizeExtension(_ ext: String) -> String {
        let trimmed = ext.trimmingCharacters(in: .whitespacesAndNewlines)
        let withoutDot = trimmed.hasPrefix(".") ? String(trimmed.dropFirst()) : trimmed
        return withoutDot.lowercased()
    }

    public static func normalizeExtensions(_ list: [String]) -> [String] {
        let normalized = list.map(Self.normalizeExtension).filter { !$0.isEmpty }
        return Array(Set(normalized)).sorted()
    }
}

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

public enum ClassificationSource: String, Codable, Sendable {
    case extensionRule
    case uttype
}
