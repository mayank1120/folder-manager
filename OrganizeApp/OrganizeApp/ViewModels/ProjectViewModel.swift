import Foundation
import SwiftUI
import OrganizeCore

/// ViewModel for a single project's scan/plan/apply workflow.
/// NOTE: Requires macOS 14+ for @Observable macro.
@MainActor
@Observable
final class ProjectViewModel {
    var project: Project
    var currentPhase: Phase = .setup
    var isProcessing = false
    var errorMessage: String?
    
    // Scan state
    var scanProgress: ScanProgress?
    var lastScanResult: ScanResult?
    
    // Plan state (uses PlanBuildSummary from OrganizeCore)
    var planSummary: PlanBuildSummary?
    var operations: [PlanStore.PlanOperationExecutionRow] = []
    var needsReviewItems: [PlanStore.PlanItemRow] = []
    var excludedItems: [PlanStore.PlanItemRow] = []
    var extensionReport: [PlanStore.ExtensionReportRow] = []
    
    // Apply state
    var applyProgress: ApplyProgress?
    var applyResult: ApplyResult?
    
    // Verify state
    var verificationResult: VerificationResult?
    
    // Delete state
    var deleteResult: DeleteOriginalsResult?
    
    // Rollback state
    var rollbackResult: RollbackResult?
    
    private let appState: AppState
    private var dbManager: DatabaseManager?
    
    enum Phase: String, CaseIterable {
        case setup = "Setup"
        case scanning = "Scanning"
        case planning = "Planning"
        case preview = "Preview"
        case applying = "Applying"
        case verifying = "Verifying"
        case complete = "Complete"
        
        var icon: String {
            switch self {
            case .setup: return "folder.badge.plus"
            case .scanning: return "magnifyingglass"
            case .planning: return "list.bullet.clipboard"
            case .preview: return "eye"
            case .applying: return "arrow.right.circle"
            case .verifying: return "checkmark.circle"
            case .complete: return "checkmark.seal.fill"
            }
        }
    }
    
    init(project: Project, appState: AppState) {
        self.project = project
        self.appState = appState
        
        // Initialize DB manager
        if let projectDir = appState.projectDirectory(for: project.id) {
            let dbPath = projectDir.appendingPathComponent("organize.db").path
            self.dbManager = try? DatabaseManager(path: dbPath)
        }
        
        // Determine initial phase based on project state
        if project.sourceRoots.isEmpty || project.destinationRoot == nil {
            currentPhase = .setup
        } else if project.currentPlanId != nil {
            currentPhase = .preview
            // Load plan data asynchronously
            Task {
                await loadExistingPlanData()
            }
        }
    }
    
    /// Load plan data when reopening a project with an existing plan
    func loadExistingPlanData() async {
        guard let dbManager, let planId = project.currentPlanId else { return }
        
        let planStore = PlanStore(dbManager: dbManager)
        
        do {
            // Load plan summary from PlanBuilder stats if available
            if let plan = try await planStore.fetchPlan(id: planId) {
                // Create minimal summary from stored plan
                planSummary = PlanBuildSummary(
                    plan: plan,
                    moveEligibleCount: 0,  // Will be populated from operations
                    needsReviewCount: 0,   // Will be populated from items
                    excludedByPolicyCount: 0       // Will be populated from items
                )
                extensionReport = try await planStore.fetchExtensionReport(scanId: plan.scanId)
            }
            
            // Load operations
            operations = try await planStore.fetchPlanOperationExecutionRows(planId: planId)
            
            // Load plan items
            needsReviewItems = try await planStore.fetchPlanItemRows(planId: planId, disposition: .needsReview)
            excludedItems = try await planStore.fetchPlanItemRows(planId: planId, disposition: .excludedByPolicy)
            
            // Update summary counts based on actual loaded data
            if var summary = planSummary {
                planSummary = PlanBuildSummary(
                    plan: summary.plan,
                    moveEligibleCount: operations.count,
                    needsReviewCount: needsReviewItems.count,
                    excludedByPolicyCount: excludedItems.count
                )
            }
        } catch {
            errorMessage = "Failed to load plan data: \(error.localizedDescription)"
        }
    }
    
    // MARK: - Setup
    
    func addSourceRoot(_ url: URL) async throws {
        project = try await appState.addSourceRoot(to: project, url: url)
    }
    
    func removeSourceRoot(_ id: UUID) async throws {
        project.sourceRoots.removeAll { $0.id == id }
        try await appState.updateProject(project)
    }
    
    func setDestination(_ url: URL) async throws {
        project = try await appState.setDestination(for: project, url: url)
    }
    
    func addPerson(_ person: Person) async throws {
        project.people.append(person)
        try await appState.updateProject(project)
    }
    
    func removePerson(_ id: UUID) async throws {
        project.people.removeAll { $0.id == id }
        try await appState.updateProject(project)
    }

    func persistProject() async throws {
        try await appState.updateProject(project)
    }
    
    // MARK: - Scan
    
    func startScan() async throws {
        guard let dbManager else {
            throw ProjectError.noDatabaseManager
        }
        
        isProcessing = true
        currentPhase = .scanning
        scanProgress = ScanProgress(discovered: 0, processed: 0)
        
        defer { isProcessing = false }
        
        // Setup scoped access for source roots
        let sourceURLs = try appState.resolveSourceRootURLs(for: project)
        let scopedAccess = ScopedAccess(urls: sourceURLs, bookmarkManager: appState.bookmarkManager)
        defer { scopedAccess.endAccess() }
        if !scopedAccess.allAccessGranted {
            if let denied = scopedAccess.deniedURLs.first {
                throw BookmarkError.accessDenied(url: denied)
            }
            throw BookmarkError.invalidData
        }
        
        do {
            let inventoryStore = InventoryStore(dbManager: dbManager)
            let scanner = Scanner(inventoryStore: inventoryStore)
            
            // ScanProgressHandler signature: (Int, String) -> Void
            let result = try await scanner.scan(project: project) { [weak self] count, relativePath in
                Task { @MainActor in
                    self?.scanProgress = ScanProgress(
                        discovered: count,
                        processed: count
                    )
                }
            }
            
            lastScanResult = result
            project.currentScanId = result.scan.id
            try await appState.updateProject(project)
            currentPhase = .planning
        } catch {
            errorMessage = "Scan failed: \(error.localizedDescription)"
            currentPhase = .setup
            throw error
        }
    }
    
    // MARK: - Plan
    
    func generatePlan() async throws {
        guard let dbManager, let scanId = project.currentScanId else {
            throw ProjectError.noScan
        }
        
        isProcessing = true
        currentPhase = .planning
        
        defer { isProcessing = false }
        
        // Setup scoped access for destination (for collision checks)
        if let destURL = try appState.resolveDestinationURL(for: project) {
            let scopedAccess = ScopedAccess(urls: [destURL], bookmarkManager: appState.bookmarkManager)
            defer { scopedAccess.endAccess() }
            if !scopedAccess.allAccessGranted {
                throw BookmarkError.accessDenied(url: destURL)
            }
        }
        
        do {
            let inventoryStore = InventoryStore(dbManager: dbManager)
            let planStore = PlanStore(dbManager: dbManager)
            let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
            
            // Returns PlanBuildSummary
            let summary = try await planner.createPlan(project: project, scanId: scanId)
            planSummary = summary
            project.currentPlanId = summary.plan.id
            try await appState.updateProject(project)
            
            // Load operations for preview
            operations = try await planStore.fetchPlanOperationExecutionRows(planId: summary.plan.id)
            
            // Load NeedsReview and Excluded items
            needsReviewItems = try await planStore.fetchPlanItemRows(planId: summary.plan.id, disposition: .needsReview)
            excludedItems = try await planStore.fetchPlanItemRows(planId: summary.plan.id, disposition: .excludedByPolicy)
            extensionReport = try await planStore.fetchExtensionReport(scanId: summary.plan.scanId)
            
            currentPhase = .preview
        } catch {
            errorMessage = "Plan failed: \(error.localizedDescription)"
            throw error
        }
    }
    
    // MARK: - Apply
    
    func apply(dryRun: Bool = false) async throws {
        guard let dbManager, let planId = project.currentPlanId else {
            throw ProjectError.noPlan
        }
        
        guard let projectDir = appState.projectDirectory(for: project.id) else {
            throw ProjectError.noProjectDirectory
        }
        
        isProcessing = true
        currentPhase = .applying
        applyProgress = ApplyProgress(completed: 0, total: operations.count, currentFile: "")
        
        defer { isProcessing = false }
        
        // Setup scoped access for source and destination
        let sourceURLs = try appState.resolveSourceRootURLs(for: project)
        let destURL = try appState.resolveDestinationURL(for: project)
        var allURLs = sourceURLs
        if let destURL { allURLs.append(destURL) }
        let scopedAccess = ScopedAccess(urls: allURLs, bookmarkManager: appState.bookmarkManager)
        defer { scopedAccess.endAccess() }
        if !scopedAccess.allAccessGranted {
            if let denied = scopedAccess.deniedURLs.first {
                throw BookmarkError.accessDenied(url: denied)
            }
            throw BookmarkError.invalidData
        }
        
        do {
            let engine = ApplyEngine(dbManager: dbManager)
            let result = try await engine.apply(
                planId: planId,
                project: project,
                projectDirectory: projectDir,
                dryRun: dryRun
            ) { [weak self] index, total, path in
                Task { @MainActor in
                    self?.applyProgress = ApplyProgress(
                        completed: index,
                        total: total,
                        currentFile: path
                    )
                }
            }
            
            applyResult = result
            currentPhase = .verifying
        } catch {
            errorMessage = "Apply failed: \(error.localizedDescription)"
            throw error
        }
    }
    
    // MARK: - Verify
    
    func verify() async throws {
        guard let dbManager, let planId = project.currentPlanId else {
            throw ProjectError.noPlan
        }
        
        isProcessing = true
        currentPhase = .verifying
        
        defer { isProcessing = false }
        
        // Setup scoped access for destination
        if let destURL = try appState.resolveDestinationURL(for: project) {
            let scopedAccess = ScopedAccess(urls: [destURL], bookmarkManager: appState.bookmarkManager)
            defer { scopedAccess.endAccess() }
            if !scopedAccess.allAccessGranted {
                throw BookmarkError.accessDenied(url: destURL)
            }
        }
        
        do {
            let engine = VerifyEngine(dbManager: dbManager)
            let result = try await engine.verify(planId: planId)
            verificationResult = result
            
            if result.passed {
                currentPhase = .complete
            }
        } catch {
            errorMessage = "Verify failed: \(error.localizedDescription)"
            throw error
        }
    }
    
    // MARK: - Delete Originals
    
    func deleteOriginals() async throws {
        guard let dbManager, let planId = project.currentPlanId else {
            throw ProjectError.noPlan
        }
        
        guard let projectDir = appState.projectDirectory(for: project.id) else {
            throw ProjectError.noProjectDirectory
        }
        
        isProcessing = true
        
        defer { isProcessing = false }
        
        // Setup scoped access for source and destination
        let sourceURLs = try appState.resolveSourceRootURLs(for: project)
        let destURL = try appState.resolveDestinationURL(for: project)
        var allURLs = sourceURLs
        if let destURL { allURLs.append(destURL) }
        let scopedAccess = ScopedAccess(urls: allURLs, bookmarkManager: appState.bookmarkManager)
        defer { scopedAccess.endAccess() }
        if !scopedAccess.allAccessGranted {
            if let denied = scopedAccess.deniedURLs.first {
                throw BookmarkError.accessDenied(url: denied)
            }
            throw BookmarkError.invalidData
        }
        
        do {
            let engine = DeleteOriginalsEngine(dbManager: dbManager)
            let result = try await engine.deleteOriginals(
                planId: planId,
                project: project,
                projectDirectory: projectDir
            )
            deleteResult = result
        } catch {
            errorMessage = "Delete originals failed: \(error.localizedDescription)"
            throw error
        }
    }
    
    // MARK: - Rollback
    
    func rollback() async throws {
        guard let dbManager, let planId = project.currentPlanId else {
            throw ProjectError.noPlan
        }
        
        guard let projectDir = appState.projectDirectory(for: project.id) else {
            throw ProjectError.noProjectDirectory
        }
        
        isProcessing = true
        
        defer { isProcessing = false }
        
        // Setup scoped access for source and destination
        let sourceURLs = try appState.resolveSourceRootURLs(for: project)
        let destURL = try appState.resolveDestinationURL(for: project)
        var allURLs = sourceURLs
        if let destURL { allURLs.append(destURL) }
        let scopedAccess = ScopedAccess(urls: allURLs, bookmarkManager: appState.bookmarkManager)
        defer { scopedAccess.endAccess() }
        if !scopedAccess.allAccessGranted {
            if let denied = scopedAccess.deniedURLs.first {
                throw BookmarkError.accessDenied(url: denied)
            }
            throw BookmarkError.invalidData
        }
        
        do {
            let manager = RollbackManager(dbManager: dbManager)
            let result = try await manager.rollback(planId: planId, projectDirectory: projectDir)
            rollbackResult = result
        } catch {
            errorMessage = "Rollback failed: \(error.localizedDescription)"
            throw error
        }
    }
    // MARK: - Relink Bookmark
    
    func relinkBookmark(info: StaleBookmarkInfo, newURL: URL) async {
        do {
            if info.isDestination {
                try await setDestination(newURL)
            } else if let sourceRootId = info.sourceRootId {
                // Find and update the source root
                if let index = project.sourceRoots.firstIndex(where: { $0.id == sourceRootId }) {
                    let bookmarkData = try appState.bookmarkManager.createBookmark(for: newURL)
                    project.sourceRoots[index].path = newURL.path
                    project.sourceRoots[index].bookmarkData = bookmarkData
                    project.sourceRoots[index].isValid = true
                    try await appState.updateProject(project)
                }
            } else {
                // Try to add as new source root
                try await addSourceRoot(newURL)
            }
        } catch {
            errorMessage = "Failed to relink: \(error.localizedDescription)"
        }
    }
}

// MARK: - Stale Bookmark Info

struct StaleBookmarkInfo: Identifiable {
    let id = UUID()
    let sourceRootId: UUID?
    let isDestination: Bool
    let originalPath: String
}

// MARK: - Progress Types

struct ScanProgress {
    var discovered: Int
    var processed: Int
}

struct ApplyProgress {
    var completed: Int
    var total: Int
    var currentFile: String
    
    var fraction: Double {
        guard total > 0 else { return 0 }
        return Double(completed) / Double(total)
    }
}

// MARK: - Errors

enum ProjectError: Error, LocalizedError {
    case noDatabaseManager
    case noScan
    case noPlan
    case noProjectDirectory
    
    var errorDescription: String? {
        switch self {
        case .noDatabaseManager:
            return "Database not initialized"
        case .noScan:
            return "No scan available. Please scan first."
        case .noPlan:
            return "No plan available. Please generate a plan first."
        case .noProjectDirectory:
            return "Project directory not found"
        }
    }
}
