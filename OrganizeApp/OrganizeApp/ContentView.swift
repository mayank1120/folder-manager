import SwiftUI
import OrganizeCore

struct ContentView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        NavigationSplitView {
            SidebarView()
                .navigationSplitViewColumnWidth(min: 200, ideal: 250, max: 300)
        } detail: {
            if let projectId = appState.selectedProjectId,
               let project = appState.projects.first(where: { $0.id == projectId }) {
                ProjectDetailView(project: project)
            } else {
                EmptyStateView()
            }
        }
        .frame(minWidth: 900, minHeight: 600)
        .task {
            await appState.loadProjects()
        }
    }
}

struct EmptyStateView: View {
    @Environment(AppState.self) private var appState
    
    var body: some View {
        VStack(spacing: 20) {
            Image(systemName: "folder.badge.gearshape")
                .font(.system(size: 64))
                .foregroundStyle(.tertiary)
            
            Text("No Project Selected")
                .font(.title2)
                .foregroundStyle(.secondary)
            
            Text("Select a project from the sidebar or create a new one.")
                .font(.body)
                .foregroundStyle(.tertiary)
            
            Button {
                Task {
                    try? await appState.createProject(name: "New Project")
                }
            } label: {
                Label("New Project", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

#Preview {
    ContentView()
        .environment(AppState())
}
