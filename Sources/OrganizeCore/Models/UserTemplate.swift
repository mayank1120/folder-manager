import Foundation

/// A user-defined template that can be saved and loaded
public struct UserTemplate: Codable, Identifiable, Sendable {
    public let id: UUID
    public var name: String
    public var settings: ProjectSettings
    public var createdAt: Date
    public var updatedAt: Date
    
    public init(
        id: UUID = UUID(),
        name: String,
        settings: ProjectSettings,
        createdAt: Date = Date(),
        updatedAt: Date = Date()
    ) {
        self.id = id
        self.name = name
        self.settings = settings
        self.createdAt = createdAt
        self.updatedAt = updatedAt
    }
}

/// Manager for saving and loading user templates
public struct UserTemplateManager: Sendable {
    private let templatesDirectory: URL
    
    public init() {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        templatesDirectory = appSupport.appendingPathComponent("Organize/templates", isDirectory: true)
    }
    
    /// Ensure templates directory exists
    private func ensureDirectory() throws {
        try FileManager.default.createDirectory(at: templatesDirectory, withIntermediateDirectories: true)
    }
    
    /// Save a template
    public func saveTemplate(_ template: UserTemplate) throws -> URL {
        try ensureDirectory()
        
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        
        let data = try encoder.encode(template)
        let fileName = sanitizeFileName(template.name) + ".json"
        let url = templatesDirectory.appendingPathComponent(fileName)
        try data.write(to: url)
        return url
    }
    
    /// Load all user templates
    public func loadTemplates() throws -> [UserTemplate] {
        try ensureDirectory()
        
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        
        let files = try FileManager.default.contentsOfDirectory(
            at: templatesDirectory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        
        return files.compactMap { url in
            do {
                let data = try Data(contentsOf: url)
                return try decoder.decode(UserTemplate.self, from: data)
            } catch {
                return nil
            }
        }.sorted { $0.createdAt > $1.createdAt }
    }
    
    /// Delete a template
    public func deleteTemplate(_ template: UserTemplate) throws {
        let fileName = sanitizeFileName(template.name) + ".json"
        let url = templatesDirectory.appendingPathComponent(fileName)
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }
    
    private func sanitizeFileName(_ name: String) -> String {
        let invalidChars = CharacterSet(charactersIn: "/\\?%*|\"<>:")
        return name.components(separatedBy: invalidChars).joined(separator: "_")
    }
}
