import Foundation

public enum DuplicateHandling: String, Codable, Sendable {
    case keepNewest
    case skipDuplicates
}

public struct DuplicateDetectionSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var handling: DuplicateHandling

    public init(
        enabled: Bool = false,
        handling: DuplicateHandling = .keepNewest
    ) {
        self.enabled = enabled
        self.handling = handling
    }
}

public struct LargeFileFilterSettings: Codable, Sendable, Hashable {
    public var enabled: Bool
    public var minimumBytes: Int64

    public init(
        enabled: Bool = false,
        minimumBytes: Int64 = 100 * 1024 * 1024
    ) {
        self.enabled = enabled
        self.minimumBytes = minimumBytes
    }
}

public enum PDFDateGrouping: String, Codable, Sendable {
    case year
    case yearMonth
}

public enum RuleTemplate: String, Codable, Sendable {
    case personal
    case work
    case school
}

public struct RuleTemplatePreset: Sendable, Hashable {
    public let template: RuleTemplate
    public let displayName: String
    public let description: String
    public let extensionRules: [ExtensionRule]
    public let extensionExclusions: ExtensionExclusions
    public let pdfDateGrouping: PDFDateGrouping
    public let largeFileFilter: LargeFileFilterSettings?

    public init(
        template: RuleTemplate,
        displayName: String,
        description: String,
        extensionRules: [ExtensionRule],
        extensionExclusions: ExtensionExclusions = ExtensionExclusions(),
        pdfDateGrouping: PDFDateGrouping = .year,
        largeFileFilter: LargeFileFilterSettings? = nil
    ) {
        self.template = template
        self.displayName = displayName
        self.description = description
        self.extensionRules = extensionRules
        self.extensionExclusions = extensionExclusions
        self.pdfDateGrouping = pdfDateGrouping
        self.largeFileFilter = largeFileFilter
    }
}

public enum RuleTemplateCatalog {
    public static let presets: [RuleTemplatePreset] = [
        RuleTemplatePreset(
            template: .personal,
            displayName: "Personal",
            description: "Photos into a custom folder; documents stay organized by year.",
            extensionRules: [
                ExtensionRule(
                    extensions: ["jpg", "jpeg", "png", "heic"],
                    destinationType: .customFolder,
                    destinationPath: "Photos",
                    destinationIsAbsolute: false,
                    ownerScope: .perOwner,
                    priority: 50
                )
            ]
        ),
        RuleTemplatePreset(
            template: .work,
            displayName: "Work",
            description: "Route docs, sheets, and slides into separate work folders.",
            extensionRules: [
                ExtensionRule(
                    extensions: ["doc", "docx", "rtf", "txt"],
                    destinationType: .customFolder,
                    destinationPath: "Work/Docs",
                    destinationIsAbsolute: false,
                    ownerScope: .perOwner,
                    priority: 50
                ),
                ExtensionRule(
                    extensions: ["xls", "xlsx", "csv"],
                    destinationType: .customFolder,
                    destinationPath: "Work/Sheets",
                    destinationIsAbsolute: false,
                    ownerScope: .perOwner,
                    priority: 50
                ),
                ExtensionRule(
                    extensions: ["ppt", "pptx", "key"],
                    destinationType: .customFolder,
                    destinationPath: "Work/Slides",
                    destinationIsAbsolute: false,
                    ownerScope: .perOwner,
                    priority: 50
                )
            ]
        ),
        RuleTemplatePreset(
            template: .school,
            displayName: "School",
            description: "Assignments, notes, and slides grouped into school folders.",
            extensionRules: [
                ExtensionRule(
                    extensions: ["pdf", "doc", "docx"],
                    destinationType: .customFolder,
                    destinationPath: "School/Assignments",
                    destinationIsAbsolute: false,
                    ownerScope: .perOwner,
                    priority: 50
                ),
                ExtensionRule(
                    extensions: ["txt", "md"],
                    destinationType: .customFolder,
                    destinationPath: "School/Notes",
                    destinationIsAbsolute: false,
                    ownerScope: .perOwner,
                    priority: 50
                ),
                ExtensionRule(
                    extensions: ["ppt", "pptx", "key"],
                    destinationType: .customFolder,
                    destinationPath: "School/Slides",
                    destinationIsAbsolute: false,
                    ownerScope: .perOwner,
                    priority: 50
                )
            ]
        )
    ]

    public static func preset(for template: RuleTemplate) -> RuleTemplatePreset? {
        presets.first { $0.template == template }
    }

    public static func apply(template: RuleTemplate, to settings: inout ProjectSettings) {
        guard let preset = preset(for: template) else { return }
        settings.extensionRules = preset.extensionRules
        settings.extensionExclusions = preset.extensionExclusions
        settings.pdfDateGrouping = preset.pdfDateGrouping
        if let largeFileFilter = preset.largeFileFilter {
            settings.largeFileFilter = largeFileFilter
        }
    }
}
