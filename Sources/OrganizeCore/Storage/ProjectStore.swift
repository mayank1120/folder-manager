import Foundation

/// Store for projects (JSON file-based)
/// Supports both path-based operations (for CLI --project /path/to/file.json)
/// and directory-based operations (for UI project browser)
public actor ProjectStore {
    
    /// Encoder configured for deterministic output
    private static let encoder: JSONEncoder = {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        enc.dateEncodingStrategy = .iso8601
        return enc
    }()
    
    /// Decoder for project files
    private static let decoder: JSONDecoder = {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return dec
    }()
    
    public init() {}
    
    // MARK: - Path-based operations (for CLI)
    
    /// Load project from a specific file path
    public func load(from path: URL) throws -> Project? {
        guard FileManager.default.fileExists(atPath: path.path) else {
            return nil
        }
        let data = try Data(contentsOf: path)
        return try Self.decoder.decode(Project.self, from: data)
    }
    
    /// Save project to a specific file path
    public func save(_ project: Project, to path: URL) throws {
        let directory = path.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        
        let data = try Self.encoder.encode(project)
        try data.write(to: path, options: .atomic)
    }
    
    // MARK: - Directory-based operations (for UI)
    
    /// Load project by ID from a projects directory
    public func load(id: EntityID, from directory: URL) throws -> Project? {
        let projectFile = directory.appendingPathComponent("\(id.uuidString).json")
        return try load(from: projectFile)
    }
    
    /// Save project to a directory (uses project.id as filename)
    public func save(_ project: Project, toDirectory directory: URL) throws {
        let projectFile = directory.appendingPathComponent("\(project.id.uuidString).json")
        try save(project, to: projectFile)
    }
    
    /// Load all projects from a directory
    public func loadAll(from directory: URL) throws -> [Project] {
        guard FileManager.default.fileExists(atPath: directory.path) else {
            return []
        }
        
        let files = try FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: nil
        ).filter { $0.pathExtension == "json" }
        
        return files.compactMap { file in
            try? Self.decoder.decode(Project.self, from: Data(contentsOf: file))
        }
    }
    
    /// Delete a project by ID from a directory
    public func delete(id: EntityID, from directory: URL) throws {
        let projectFile = directory.appendingPathComponent("\(id.uuidString).json")
        if FileManager.default.fileExists(atPath: projectFile.path) {
            try FileManager.default.removeItem(at: projectFile)
        }
    }
}

