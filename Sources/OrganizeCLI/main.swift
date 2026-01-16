import ArgumentParser
import OrganizeCore
import Foundation

@main
struct OrganizeCLI: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "organize",
        abstract: "Organize files into a structured folder hierarchy",
        version: "1.0.0",
        subcommands: [
            ScanCommand.self,
            PlanCommand.self,
            ApplyCommand.self,
            VerifyCommand.self,
            DeleteOriginalsCommand.self,
            RollbackCommand.self,
        ]
    )
}

struct ScanCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "scan",
        abstract: "Scan source folders and build inventory"
    )
    
    @Option(name: .long, help: "Path to project JSON file")
    var project: String
    
    @Option(name: .long, help: "Source folder to scan (can be repeated)")
    var source: [String] = []
    
    @Option(name: .long, help: "Destination root folder")
    var dest: String?
    
    @Flag(name: .long, help: "Show progress during scan")
    var verbose: Bool = false
    
    func run() async throws {
        let projectURL = URL(fileURLWithPath: project)
        let projectDir = projectURL.deletingLastPathComponent()
        
        // Load or create project using path-based operations
        let projectStore = ProjectStore()
        var proj: Project
        
        if let existingProject = try await projectStore.load(from: projectURL) {
            proj = existingProject
            if verbose {
                print("Loaded existing project: \(proj.name)")
            }
        } else {
            // Create new project
            let sourceRoots = source.map { path in
                SourceRoot(path: (path as NSString).standardizingPath)
            }
            
            proj = Project(
                name: projectURL.deletingPathExtension().lastPathComponent,
                sourceRoots: sourceRoots,
                destinationRoot: dest.map { DestinationRoot(path: ($0 as NSString).standardizingPath) }
            )
            if verbose {
                print("Created new project: \(proj.name)")
            }
        }
        
        // Add any new sources (dedupe by standardized path)
        for sourcePath in source {
            let standardized = (sourcePath as NSString).standardizingPath
            if !proj.sourceRoots.contains(where: { $0.path == standardized }) {
                proj.sourceRoots.append(SourceRoot(path: standardized))
            }
        }
        
        // Update destination if provided
        if let destPath = dest {
            proj.destinationRoot = DestinationRoot(path: (destPath as NSString).standardizingPath)
        }
        
        // Initialize database (sibling to project file)
        let dbPath = projectDir.appendingPathComponent("organize.db").path
        let dbManager = try DatabaseManager(path: dbPath)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let scanner = Scanner(inventoryStore: inventoryStore)
        
        print("Scanning \(proj.sourceRoots.count) source root(s)...")
        
        let progressHandler: ScanProgressHandler?
        if verbose {
            progressHandler = { count, path in
                print("[\(count)] \(path)")
            }
        } else {
            progressHandler = nil
        }
        
        let result = try await scanner.scan(project: proj, progressHandler: progressHandler)
        
        // Update project with scan ID and save to the specified path
        proj.currentScanId = result.scan.id
        proj.updatedAt = Date()
        try await projectStore.save(proj, to: projectURL)
        
        print("")
        print("Scan complete!")
        print("  Items: \(result.itemCount)")
        print("  Total size: \(formatBytes(result.totalBytes))")
        print("  Excluded: \(result.excludedItems.count)")
        print("  Scan ID: \(result.scan.id.uuidString)")
        print("  Project: \(projectURL.path)")
        
        if verbose && !result.excludedItems.isEmpty {
            print("")
            print("Excluded items:")
            for item in result.excludedItems.prefix(10) {
                print("  \(item.reason.rawValue): \(item.relativePath)")
            }
            if result.excludedItems.count > 10 {
                print("  ... and \(result.excludedItems.count - 10) more")
            }
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct PlanCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "plan",
        abstract: "Generate a deterministic plan from a scan snapshot"
    )

    @Option(name: .long, help: "Path to project JSON file")
    var project: String

    @Option(name: .long, help: "Scan ID to plan against (defaults to project currentScanId)")
    var scanId: String?

    @Option(name: .long, help: "Destination root folder (overrides project destinationRoot)")
    var dest: String?

    @Option(name: .long, help: "Output directory for CSV exports (defaults to <projectDir>/exports/<planId>/)")
    var out: String?

    func run() async throws {
        let projectURL = URL(fileURLWithPath: project)
        let projectDir = projectURL.deletingLastPathComponent()

        let projectStore = ProjectStore()
        guard var proj = try await projectStore.load(from: projectURL) else {
            throw ValidationError("Project not found at \(projectURL.path). Run `organize scan` first.")
        }

        if let destPath = dest {
            proj.destinationRoot = DestinationRoot(path: (destPath as NSString).standardizingPath)
        }

        let scanIdToUse: EntityID
        if let scanIdStr = scanId {
            guard let parsed = UUID(uuidString: scanIdStr) else {
                throw ValidationError("Invalid --scanId UUID: \(scanIdStr)")
            }
            scanIdToUse = parsed
        } else if let current = proj.currentScanId {
            scanIdToUse = current
        } else {
            throw ValidationError("No scanId provided and project.currentScanId is nil. Run `organize scan` first.")
        }

        let dbPath = projectDir.appendingPathComponent("organize.db").path
        let dbManager = try DatabaseManager(path: dbPath)
        let inventoryStore = InventoryStore(dbManager: dbManager)
        let planStore = PlanStore(dbManager: dbManager)

        let planner = Planner(inventoryStore: inventoryStore, planStore: planStore)
        let summary = try await planner.createPlan(project: proj, scanId: scanIdToUse)

        proj.currentPlanId = summary.plan.id
        proj.updatedAt = Date()
        try await projectStore.save(proj, to: projectURL)

        let exportRoot: URL
        if let outDir = out {
            exportRoot = URL(fileURLWithPath: (outDir as NSString).standardizingPath)
        } else {
            exportRoot = projectDir.appendingPathComponent("exports").appendingPathComponent(summary.plan.id.uuidString)
        }

        let exporter = ExportManager(dbManager: dbManager)
        let paths = try await exporter.exportPlan(planId: summary.plan.id, to: exportRoot)

        print("Plan complete!")
        print("  Plan ID: \(summary.plan.id.uuidString)")
        print("  Move eligible: \(summary.moveEligibleCount)")
        print("  Needs review: \(summary.needsReviewCount)")
        print("  Excluded by policy: \(summary.excludedByPolicyCount)")
        print("  Exports:")
        print("    \(paths.inventoryCSV.path)")
        print("    \(paths.proposedMovesCSV.path)")
        print("    \(paths.needsReviewCSV.path)")
        print("    \(paths.excludedByPolicyCSV.path)")
    }
}

struct ApplyCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "apply",
        abstract: "Apply a plan (copy or move) with crash-safe journaling"
    )

    @Option(name: .long, help: "Path to project JSON file")
    var project: String

    @Option(name: .long, help: "Plan ID to apply (defaults to project currentPlanId)")
    var planId: String?

    @Flag(name: .long, help: "Dry run (no filesystem changes, no journal writes)")
    var dryRun: Bool = false

    @Flag(name: .long, help: "Show progress during apply")
    var verbose: Bool = false

    func run() async throws {
        let projectURL = URL(fileURLWithPath: project)
        let projectDir = projectURL.deletingLastPathComponent()

        let projectStore = ProjectStore()
        guard let proj = try await projectStore.load(from: projectURL) else {
            throw ValidationError("Project not found at \(projectURL.path). Run `organize scan` + `organize plan` first.")
        }

        let planIdToUse: EntityID
        if let planIdStr = planId {
            guard let parsed = UUID(uuidString: planIdStr) else {
                throw ValidationError("Invalid --planId UUID: \(planIdStr)")
            }
            planIdToUse = parsed
        } else if let current = proj.currentPlanId {
            planIdToUse = current
        } else {
            throw ValidationError("No planId provided and project.currentPlanId is nil. Run `organize plan` first.")
        }

        let dbPath = projectDir.appendingPathComponent("organize.db").path
        let dbManager = try DatabaseManager(path: dbPath)

        let engine = ApplyEngine(dbManager: dbManager)
        let handler: ApplyProgressHandler?
        if verbose {
            handler = { index, total, path in
                print("[\(index)/\(total)] \(path)")
            }
        } else {
            handler = nil
        }

        let result = try await engine.apply(
            planId: planIdToUse,
            project: proj,
            projectDirectory: projectDir,
            dryRun: dryRun,
            progressHandler: handler
        )

        print("Apply complete!")
        print("  Plan ID: \(result.planId.uuidString)")
        print("  Total operations: \(result.totalOperations)")
        print("  Completed: \(result.completedCount)")
        print("  Skipped: \(result.skippedCount)")
        print("  Failed: \(result.failedCount)")
        print("  Dry run: \(result.dryRun ? "true" : "false")")
    }
}

struct VerifyCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "verify",
        abstract: "Verify an applied plan (counts + bytes + destination existence)"
    )

    @Option(name: .long, help: "Path to project JSON file")
    var project: String

    @Option(name: .long, help: "Plan ID to verify (defaults to project currentPlanId)")
    var planId: String?

    @Option(name: .long, help: "Output CSV path for verification failures (defaults to <projectDir>/exports/<planId>/verification.csv)")
    var out: String?

    func run() async throws {
        let projectURL = URL(fileURLWithPath: project)
        let projectDir = projectURL.deletingLastPathComponent()

        let projectStore = ProjectStore()
        guard let proj = try await projectStore.load(from: projectURL) else {
            throw ValidationError("Project not found at \(projectURL.path). Run `organize scan` + `organize plan` first.")
        }

        let planIdToUse: EntityID
        if let planIdStr = planId {
            guard let parsed = UUID(uuidString: planIdStr) else {
                throw ValidationError("Invalid --planId UUID: \(planIdStr)")
            }
            planIdToUse = parsed
        } else if let current = proj.currentPlanId {
            planIdToUse = current
        } else {
            throw ValidationError("No planId provided and project.currentPlanId is nil. Run `organize plan` first.")
        }

        let dbPath = projectDir.appendingPathComponent("organize.db").path
        let dbManager = try DatabaseManager(path: dbPath)

        let engine = VerifyEngine(dbManager: dbManager)
        let result = try await engine.verify(planId: planIdToUse)

        let outputURL: URL
        if let outPath = out {
            outputURL = URL(fileURLWithPath: (outPath as NSString).standardizingPath)
        } else {
            outputURL = projectDir
                .appendingPathComponent("exports")
                .appendingPathComponent(planIdToUse.uuidString)
                .appendingPathComponent("verification.csv")
        }
        try engine.writeCSV(result: result, to: outputURL)

        print("Verify complete!")
        print("  Plan ID: \(result.planId.uuidString)")
        print("  Planned: \(result.plannedCount)")
        print("  Completed: \(result.completedCount)")
        print("  Skipped: \(result.skippedCount)")
        print("  Failed: \(result.failedCount)")
        print("  Planned bytes: \(formatBytes(result.plannedBytes))")
        print("  Verified bytes: \(formatBytes(result.verifiedBytes))")
        print("  Passed: \(result.passed ? "true" : "false")")
        print("  Failures CSV: \(outputURL.path)")
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

struct DeleteOriginalsCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "delete-originals",
        abstract: "Delete original files after successful copy-first verification"
    )

    @Option(name: .long, help: "Path to project JSON file")
    var project: String

    @Option(name: .long, help: "Plan ID (defaults to project currentPlanId)")
    var planId: String?

    @Flag(name: .long, help: "Force delete without verification gate (use with caution)")
    var force: Bool = false

    @Flag(name: .long, help: "Show progress during delete")
    var verbose: Bool = false

    func run() async throws {
        let projectURL = URL(fileURLWithPath: project)
        let projectDir = projectURL.deletingLastPathComponent()

        let projectStore = ProjectStore()
        guard let proj = try await projectStore.load(from: projectURL) else {
            throw ValidationError("Project not found at \(projectURL.path). Run `organize scan` + `organize plan` + `organize apply` first.")
        }

        let planIdToUse: EntityID
        if let planIdStr = planId {
            guard let parsed = UUID(uuidString: planIdStr) else {
                throw ValidationError("Invalid --planId UUID: \(planIdStr)")
            }
            planIdToUse = parsed
        } else if let current = proj.currentPlanId {
            planIdToUse = current
        } else {
            throw ValidationError("No planId provided and project.currentPlanId is nil. Run `organize plan` first.")
        }

        let dbPath = projectDir.appendingPathComponent("organize.db").path
        let dbManager = try DatabaseManager(path: dbPath)

        let engine = DeleteOriginalsEngine(dbManager: dbManager)
        let handler: DeleteProgressHandler?
        if verbose {
            handler = { index, total, sourcePath in
                print("[\(index)/\(total)] Deleting: \(sourcePath)")
            }
        } else {
            handler = nil
        }

        let result = try await engine.deleteOriginals(
            planId: planIdToUse,
            project: proj,
            projectDirectory: projectDir,
            force: force,
            progressHandler: handler
        )

        print("Delete originals complete!")
        print("  Plan ID: \(result.planId.uuidString)")
        print("  Mode: \(result.mode.rawValue)")
        print("  Total eligible: \(result.totalEligible)")
        print("  Deleted: \(result.deletedCount)")
        print("  Skipped: \(result.skippedCount)")
        print("  Failed: \(result.failedCount)")
    }
}

struct RollbackCommand: AsyncParsableCommand {
    static var configuration = CommandConfiguration(
        commandName: "rollback",
        abstract: "Rollback applied operations using the journal"
    )

    @Option(name: .long, help: "Path to project JSON file")
    var project: String

    @Option(name: .long, help: "Plan ID to rollback (defaults to project currentPlanId)")
    var planId: String?

    @Flag(name: .long, help: "Show progress during rollback")
    var verbose: Bool = false

    func run() async throws {
        let projectURL = URL(fileURLWithPath: project)
        let projectDir = projectURL.deletingLastPathComponent()

        let projectStore = ProjectStore()
        guard let proj = try await projectStore.load(from: projectURL) else {
            throw ValidationError("Project not found at \(projectURL.path).")
        }

        let planIdToUse: EntityID
        if let planIdStr = planId {
            guard let parsed = UUID(uuidString: planIdStr) else {
                throw ValidationError("Invalid --planId UUID: \(planIdStr)")
            }
            planIdToUse = parsed
        } else if let current = proj.currentPlanId {
            planIdToUse = current
        } else {
            throw ValidationError("No planId provided and project.currentPlanId is nil.")
        }

        let dbPath = projectDir.appendingPathComponent("organize.db").path
        let dbManager = try DatabaseManager(path: dbPath)

        let manager = RollbackManager(dbManager: dbManager)
        let handler: RollbackProgressHandler?
        if verbose {
            handler = { index, total, opId in
                print("[\(index)/\(total)] Rolling back: \(opId)")
            }
        } else {
            handler = nil
        }

        let result = try await manager.rollback(
            planId: planIdToUse,
            projectDirectory: projectDir,
            progressHandler: handler
        )

        print("Rollback complete!")
        print("  Plan ID: \(result.planId.uuidString)")
        print("  Total operations: \(result.totalOperations)")
        print("  Rolled back: \(result.rolledBackCount)")
        print("  Skipped: \(result.skippedCount)")
        print("  Failed: \(result.failedCount)")
    }
}
