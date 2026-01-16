import SwiftUI
import OrganizeCore

struct SidebarView: View {
    @Environment(AppState.self) private var appState
    @State private var showingDeleteConfirmation = false
    @State private var projectToDelete: UUID?
    
    var body: some View {
        @Bindable var state = appState
        
        List(selection: $state.selectedProjectId) {
            Section("Projects") {
                ForEach(appState.projects) { project in
                    ProjectRow(project: project)
                        .tag(project.id)
                        .contextMenu {
                            Button(role: .destructive) {
                                projectToDelete = project.id
                                showingDeleteConfirmation = true
                            } label: {
                                Label("Delete", systemImage: "trash")
                            }
                        }
                }
            }
        }
        .listStyle(.sidebar)
        .navigationTitle("Organize")
        .toolbar {
            ToolbarItem {
                Button {
                    Task {
                        do {
                            _ = try await appState.createProject(name: "New Project")
                        } catch {
                            appState.errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label("New Project", systemImage: "plus")
                }
            }
        }
        .confirmationDialog(
            "Delete Project?",
            isPresented: $showingDeleteConfirmation,
            presenting: projectToDelete
        ) { id in
            Button("Delete", role: .destructive) {
                Task {
                    do {
                        try await appState.deleteProject(id)
                    } catch {
                        appState.errorMessage = error.localizedDescription
                    }
                }
            }
        } message: { _ in
            Text("This will delete the project and all its data. This cannot be undone.")
        }
        .alert("Error", isPresented: .init(
            get: { appState.errorMessage != nil },
            set: { if !$0 { appState.errorMessage = nil } }
        )) {
            Button("OK") { appState.errorMessage = nil }
        } message: {
            Text(appState.errorMessage ?? "")
        }
    }
}

struct ProjectRow: View {
    let project: Project
    
    var body: some View {
        HStack {
            Image(systemName: statusIcon)
                .foregroundStyle(statusColor)
            
            VStack(alignment: .leading, spacing: 2) {
                Text(project.name)
                    .fontWeight(.medium)
                
                Text(statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }
    
    private var statusIcon: String {
        if project.currentPlanId != nil {
            return "checkmark.circle.fill"
        } else if project.currentScanId != nil {
            return "circle.dashed"
        } else {
            return "circle"
        }
    }
    
    private var statusColor: Color {
        if project.currentPlanId != nil {
            return .green
        } else if project.currentScanId != nil {
            return .orange
        } else {
            return .secondary
        }
    }
    
    private var statusText: String {
        if project.currentPlanId != nil {
            return "Ready to apply"
        } else if project.currentScanId != nil {
            return "Scanned"
        } else if !project.sourceRoots.isEmpty {
            return "\(project.sourceRoots.count) source(s)"
        } else {
            return "Not configured"
        }
    }
}

#Preview {
    SidebarView()
        .environment(AppState())
}
