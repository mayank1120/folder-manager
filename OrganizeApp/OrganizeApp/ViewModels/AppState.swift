import Foundation
import SwiftUI
import OrganizeCore

/// Global application state for project management.
/// NOTE: Requires macOS 14+ for @Observable macro.
@MainActor
@Observable
final class AppState {
    var projects: [Project] = []
    var selectedProjectId: UUID?
    var isLoading = false
    var errorMessage: String?
    
    private let projectStore = ProjectStore()
    let bookmarkManager = BookmarkManager()
    private var projectsDirectory: URL?
    
    var selectedProject: Project? {
        projects.first { $0.id == selectedProjectId }
    }
    
    init() {
        // Use Application Support for project storage
        if let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first {
            let organizeDir = appSupport.appendingPathComponent("Organize", isDirectory: true)
            try? FileManager.default.createDirectory(at: organizeDir, withIntermediateDirectories: true)
            self.projectsDirectory = organizeDir
        }
    }
    
    // MARK: - Project Management
    
    func loadProjects() async {
        guard let dir = projectsDirectory else { return }
        
        isLoading = true
        defer { isLoading = false }
        
        do {
            let contents = try FileManager.default.contentsOfDirectory(
                at: dir,
                includingPropertiesForKeys: [.isDirectoryKey]
            )
            
            var loadedProjects: [Project] = []
            for folder in contents {
                var isDir: ObjCBool = false
                guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDir),
                      isDir.boolValue else { continue }
                
                let projectFile = folder.appendingPathComponent("project.json")
                if let project = try await projectStore.load(from: projectFile) {
                    loadedProjects.append(project)
                }
            }
            
            projects = loadedProjects.sorted { $0.name < $1.name }
            
            // Select first project if none selected
            if selectedProjectId == nil, let first = projects.first {
                selectedProjectId = first.id
            }
        } catch {
            errorMessage = "Failed to load projects: \(error.localizedDescription)"
        }
    }
    
    func createProject(name: String) async throws -> Project {
        guard let dir = projectsDirectory else {
            throw AppStateError.noProjectsDirectory
        }
        
        let project = Project(name: name)
        let projectDir = dir.appendingPathComponent(project.id.uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: projectDir, withIntermediateDirectories: true)
        
        let projectFile = projectDir.appendingPathComponent("project.json")
        try await projectStore.save(project, to: projectFile)
        
        projects.append(project)
        projects.sort { $0.name < $1.name }
        selectedProjectId = project.id
        
        return project
    }
    
    func deleteProject(_ id: UUID) async throws {
        guard let dir = projectsDirectory else { return }
        
        let projectDir = dir.appendingPathComponent(id.uuidString, isDirectory: true)
        if FileManager.default.fileExists(atPath: projectDir.path) {
            try FileManager.default.removeItem(at: projectDir)
        }
        
        projects.removeAll { $0.id == id }
        if selectedProjectId == id {
            selectedProjectId = projects.first?.id
        }
    }
    
    func updateProject(_ project: Project) async throws {
        guard let dir = projectsDirectory else { return }
        
        let projectDir = dir.appendingPathComponent(project.id.uuidString, isDirectory: true)
        let projectFile = projectDir.appendingPathComponent("project.json")
        try await projectStore.save(project, to: projectFile)
        
        if let index = projects.firstIndex(where: { $0.id == project.id }) {
            projects[index] = project
        }
    }
    
    func projectDirectory(for projectId: UUID) -> URL? {
        projectsDirectory?.appendingPathComponent(projectId.uuidString, isDirectory: true)
    }
    
    // MARK: - Bookmark Management
    
    func addSourceRoot(to project: Project, url: URL) async throws -> Project {
        let bookmarkData = try bookmarkManager.createBookmark(for: url)
        var sourceRoot = SourceRoot(path: url.path)
        sourceRoot.bookmarkData = bookmarkData
        var updatedProject = project
        updatedProject.sourceRoots.append(sourceRoot)
        try await updateProject(updatedProject)
        return updatedProject
    }
    
    func setDestination(for project: Project, url: URL) async throws -> Project {
        let bookmarkData = try bookmarkManager.createBookmark(for: url)
        var destRoot = DestinationRoot(path: url.path)
        destRoot.bookmarkData = bookmarkData
        var updatedProject = project
        updatedProject.destinationRoot = destRoot
        try await updateProject(updatedProject)
        return updatedProject
    }
    
    /// Resolve source root URLs and begin scoped access. Returns nil if stale.
    func resolveSourceRootURLs(for project: Project) throws -> [URL] {
        var urls: [URL] = []
        for root in project.sourceRoots {
            if let data = root.bookmarkData {
                let (url, isStale) = try bookmarkManager.resolveBookmark(data)
                if isStale {
                    throw BookmarkError.stale(url: url)
                }
                urls.append(url)
            } else {
                urls.append(URL(fileURLWithPath: root.path))
            }
        }
        return urls
    }
    
    func resolveDestinationURL(for project: Project) throws -> URL? {
        guard let dest = project.destinationRoot, let data = dest.bookmarkData else {
            if let dest = project.destinationRoot {
                return URL(fileURLWithPath: dest.path)
            }
            return nil
        }
        let (url, isStale) = try bookmarkManager.resolveBookmark(data)
        if isStale {
            throw BookmarkError.stale(url: url)
        }
        return url
    }
}

enum AppStateError: Error, LocalizedError {
    case noProjectsDirectory
    case projectNotFound(UUID)
    
    var errorDescription: String? {
        switch self {
        case .noProjectsDirectory:
            return "Application Support directory not available"
        case .projectNotFound(let id):
            return "Project \(id) not found"
        }
    }
}
