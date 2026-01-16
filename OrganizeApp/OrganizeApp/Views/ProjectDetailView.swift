import SwiftUI
import OrganizeCore

struct ProjectDetailView: View {
    let project: Project
    @Environment(AppState.self) private var appState
    @State private var viewModel: ProjectViewModel?
    @State private var staleBookmarkAlert: StaleBookmarkInfo?
    @State private var showingDeleteConfirmation = false
    
    var body: some View {
        Group {
            if let vm = viewModel {
                ProjectContentView(
                    viewModel: vm,
                    staleBookmarkAlert: $staleBookmarkAlert,
                    showingDeleteConfirmation: $showingDeleteConfirmation
                )
            } else {
                ProgressView("Loading...")
            }
        }
        .navigationTitle(project.name)
        .task {
            viewModel = ProjectViewModel(project: project, appState: appState)
        }
        .onChange(of: project.id) { _, newId in
            viewModel = ProjectViewModel(project: project, appState: appState)
        }
        // Stale bookmark relink sheet
        .sheet(item: $staleBookmarkAlert) { info in
            RelinkBookmarkSheet(info: info) { newURL in
                Task {
                    await viewModel?.relinkBookmark(info: info, newURL: newURL)
                    staleBookmarkAlert = nil
                }
            }
        }
        // Delete originals confirmation
        .confirmationDialog(
            "Delete Original Files?",
            isPresented: $showingDeleteConfirmation,
            titleVisibility: .visible
        ) {
            Button("Delete Originals", role: .destructive) {
                Task {
                    do {
                        try await viewModel?.deleteOriginals()
                    } catch {
                        viewModel?.errorMessage = error.localizedDescription
                    }
                }
            }
            Button("Cancel", role: .cancel) { }
        } message: {
            Text("This will permanently delete the original source files. This action cannot be undone unless you have 'Archive to Backup' mode enabled.")
        }
    }
}

// StaleBookmarkInfo is defined in ProjectViewModel.swift

struct RelinkBookmarkSheet: View {
    let info: StaleBookmarkInfo
    let onRelink: (URL) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var isSelectingFolder = false
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.questionmark")
                .font(.system(size: 48))
                .foregroundStyle(.orange)
            
            Text("Folder Access Lost")
                .font(.headline)
            
            Text("The \(info.isDestination ? "destination" : "source") folder is no longer accessible:")
                .multilineTextAlignment(.center)
            
            Text(info.originalPath)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            
            Text("Please select the folder again to restore access.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                
                Button("Select Folder") {
                    isSelectingFolder = true
                }
                .buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(width: 400)
        .fileImporter(
            isPresented: $isSelectingFolder,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            if case .success(let urls) = result, let url = urls.first {
                onRelink(url)
            }
        }
    }
}

struct ProjectContentView: View {
    @Bindable var viewModel: ProjectViewModel
    @Binding var staleBookmarkAlert: StaleBookmarkInfo?
    @Binding var showingDeleteConfirmation: Bool
    
    var body: some View {
        VStack(spacing: 0) {
            // Phase indicator - includes ALL phases
            PhaseIndicatorView(currentPhase: viewModel.currentPhase)
                .padding()
            
            Divider()
            
            // Phase content
            ScrollView {
                phaseContent
                    .padding()
            }
        }
        .toolbar {
            ToolbarItemGroup(placement: .primaryAction) {
                toolbarActions
            }
        }
        .alert("Error", isPresented: .init(
            get: { viewModel.errorMessage != nil },
            set: { if !$0 { viewModel.errorMessage = nil } }
        )) {
            Button("OK") { viewModel.errorMessage = nil }
        } message: {
            Text(viewModel.errorMessage ?? "")
        }
        // Handle stale bookmark errors
        .onReceive(NotificationCenter.default.publisher(for: .staleBookmarkDetected)) { notification in
            if let info = notification.object as? StaleBookmarkInfo {
                staleBookmarkAlert = info
            }
        }
    }
    
    @ViewBuilder
    private var phaseContent: some View {
        switch viewModel.currentPhase {
        case .setup:
            ProjectSetupView(viewModel: viewModel)
        case .scanning:
            ScanningView(viewModel: viewModel)
        case .planning:
            PlanningView(viewModel: viewModel)
        case .preview:
            PreviewView(viewModel: viewModel)
        case .applying:
            ApplyingView(viewModel: viewModel)
        case .verifying:
            VerifyingView(viewModel: viewModel)
        case .complete:
            CompleteView(viewModel: viewModel)
        }
    }
    
    @ViewBuilder
    private var toolbarActions: some View {
        switch viewModel.currentPhase {
        case .setup:
            Button {
                Task {
                    do {
                        try await viewModel.startScan()
                    } catch let error as BookmarkError {
                        handleBookmarkError(error)
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label("Scan", systemImage: "magnifyingglass")
            }
            .disabled(!canScan)
            
        case .preview:
            Button {
                Task {
                    do {
                        try await viewModel.apply()
                    } catch let error as BookmarkError {
                        handleBookmarkError(error)
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label("Apply", systemImage: "arrow.right.circle")
            }
            
        case .complete:
            if viewModel.verificationResult?.passed == true {
                // Delete Originals with confirmation
                Button {
                    showingDeleteConfirmation = true
                } label: {
                    Label("Delete Originals", systemImage: "trash")
                }
            }
            
            Button {
                Task {
                    do {
                        try await viewModel.rollback()
                    } catch let error as BookmarkError {
                        handleBookmarkError(error)
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label("Rollback", systemImage: "arrow.uturn.backward")
            }
            
        default:
            EmptyView()
        }
    }
    
    private var canScan: Bool {
        !viewModel.project.sourceRoots.isEmpty && viewModel.project.destinationRoot != nil
    }
    
    private func handleBookmarkError(_ error: BookmarkError) {
        switch error {
        case .stale(let url):
            staleBookmarkAlert = StaleBookmarkInfo(
                sourceRootId: nil,
                isDestination: false,
                originalPath: url.path
            )
        default:
            viewModel.errorMessage = error.localizedDescription
        }
    }
}

struct PhaseIndicatorView: View {
    let currentPhase: ProjectViewModel.Phase
    
    // All phases in display order
    private let displayPhases: [ProjectViewModel.Phase] = [
        .setup, .scanning, .planning, .preview, .applying, .verifying, .complete
    ]
    
    var body: some View {
        HStack(spacing: 0) {
            ForEach(displayPhases, id: \.self) { phase in
                PhaseStep(
                    phase: phase,
                    isCurrent: phase == currentPhase,
                    isCompleted: isCompleted(phase)
                )
                
                if phase != displayPhases.last {
                    Rectangle()
                        .fill(isCompleted(phase) ? Color.accentColor : Color.secondary.opacity(0.3))
                        .frame(height: 2)
                        .frame(maxWidth: 20)
                }
            }
        }
    }
    
    private func isCompleted(_ phase: ProjectViewModel.Phase) -> Bool {
        guard let currentIndex = displayPhases.firstIndex(of: currentPhase),
              let phaseIndex = displayPhases.firstIndex(of: phase) else { return false }
        return phaseIndex < currentIndex
    }
}

struct PhaseStep: View {
    let phase: ProjectViewModel.Phase
    let isCurrent: Bool
    let isCompleted: Bool
    
    var body: some View {
        VStack(spacing: 4) {
            ZStack {
                Circle()
                    .fill(isCurrent ? Color.accentColor : (isCompleted ? Color.accentColor : Color.secondary.opacity(0.2)))
                    .frame(width: 28, height: 28)
                
                Image(systemName: isCompleted ? "checkmark" : phase.icon)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(isCurrent || isCompleted ? .white : .secondary)
            }
            
            Text(phase.rawValue)
                .font(.caption2)
                .foregroundStyle(isCurrent ? .primary : .secondary)
        }
    }
}

// MARK: - Notification for stale bookmarks

extension Notification.Name {
    static let staleBookmarkDetected = Notification.Name("staleBookmarkDetected")
}

// MARK: - Phase Views

struct ScanningView: View {
    @Bindable var viewModel: ProjectViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.5)
            
            if let progress = viewModel.scanProgress {
                Text("Discovered \(progress.discovered) files...")
                    .font(.headline)
                Text("Processed \(progress.processed) files")
                    .foregroundStyle(.secondary)
            } else {
                Text("Starting scan...")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct PlanningView: View {
    @Bindable var viewModel: ProjectViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Generating plan...")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            do {
                try await viewModel.generatePlan()
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

struct ApplyingView: View {
    @Bindable var viewModel: ProjectViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            if let progress = viewModel.applyProgress {
                ProgressView(value: progress.fraction)
                    .progressViewStyle(.linear)
                    .frame(width: 300)
                
                Text("\(progress.completed) of \(progress.total) files")
                    .font(.headline)
                
                Text(progress.currentFile)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: 400)
            } else {
                ProgressView()
                Text("Starting apply...")
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct VerifyingView: View {
    @Bindable var viewModel: ProjectViewModel
    
    var body: some View {
        VStack(spacing: 16) {
            ProgressView()
            Text("Verifying...")
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .task {
            do {
                try await viewModel.verify()
            } catch {
                viewModel.errorMessage = error.localizedDescription
            }
        }
    }
}

struct CompleteView: View {
    @Bindable var viewModel: ProjectViewModel
    
    var body: some View {
        VStack(spacing: 24) {
            if let result = viewModel.verificationResult {
                Image(systemName: result.passed ? "checkmark.circle.fill" : "xmark.circle.fill")
                    .font(.system(size: 64))
                    .foregroundStyle(result.passed ? Color.green : Color.red)
                
                Text(result.passed ? "Verification Passed" : "Verification Failed")
                    .font(.title)
                
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("Planned:")
                        Text("\(result.plannedCount)")
                    }
                    GridRow {
                        Text("Completed:")
                        Text("\(result.completedCount)")
                    }
                    GridRow {
                        Text("Failed:")
                        Text("\(result.failures.count)")
                            .foregroundStyle(result.failures.isEmpty ? Color.primary : Color.red)
                    }
                }
                .font(.body)
                
                if result.passed {
                    Text("You can now delete the original files or rollback.")
                        .foregroundStyle(.secondary)
                }
            }
            
            if let deleteResult = viewModel.deleteResult {
                Divider()
                
                Text("Delete Originals Result")
                    .font(.headline)
                
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("Deleted:")
                        Text("\(deleteResult.deletedCount)")
                    }
                    GridRow {
                        Text("Skipped:")
                        Text("\(deleteResult.skippedCount)")
                    }
                    GridRow {
                        Text("Mode:")
                        Text(deleteResult.mode.rawValue)
                    }
                }
            }
            
            if let rollbackResult = viewModel.rollbackResult {
                Divider()
                
                Text("Rollback Result")
                    .font(.headline)
                
                Grid(alignment: .leading, horizontalSpacing: 20, verticalSpacing: 8) {
                    GridRow {
                        Text("Rolled back:")
                        Text("\(rollbackResult.rolledBackCount)")
                    }
                    GridRow {
                        Text("Skipped:")
                        Text("\(rollbackResult.skippedCount)")
                    }
                    GridRow {
                        Text("Failed:")
                        Text("\(rollbackResult.failedCount)")
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ProjectDetailView(project: Project(name: "Test"))
        .environment(AppState())
}
