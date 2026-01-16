import SwiftUI

@main
struct OrganizeApp: App {
    @State private var appState = AppState()
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(appState)
        }
        .commands {
            CommandGroup(replacing: .newItem) {
                Button("New Project") {
                    Task {
                        do {
                            _ = try await appState.createProject(name: "New Project")
                        } catch {
                            appState.errorMessage = error.localizedDescription
                        }
                    }
                }
                .keyboardShortcut("n", modifiers: .command)
            }
        }
        
        #if os(macOS)
        Settings {
            SettingsView()
        }
        #endif
    }
}

struct SettingsView: View {
    var body: some View {
        Form {
            Text("Organize Settings")
                .font(.headline)
            Text("No settings available yet.")
                .foregroundStyle(.secondary)
        }
        .padding()
        .frame(width: 400, height: 200)
    }
}
