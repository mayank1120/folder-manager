import SwiftUI
import OrganizeCore
import AppKit

struct ProjectSetupView: View {
    @Bindable var viewModel: ProjectViewModel
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            // Source Folders
            VStack(alignment: .leading, spacing: 12) {
                HStack {
                    Text("Source Folders")
                        .font(.headline)
                    
                    Spacer()
                    
                    Button {
                        selectSourceFolders()
                    } label: {
                        Label("Add", systemImage: "plus")
                    }
                    .buttonStyle(.bordered)
                }
                
                if viewModel.project.sourceRoots.isEmpty {
                    DropZoneView(
                        title: "Drop folders here",
                        subtitle: "or click Add to browse",
                        onTap: { selectSourceFolders() }
                    ) { [viewModel] urls in
                        await MainActor.run {
                            for url in urls {
                                Task {
                                    do {
                                        try await viewModel.addSourceRoot(url)
                                    } catch {
                                        viewModel.errorMessage = error.localizedDescription
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 100)
                } else {
                    ForEach(viewModel.project.sourceRoots) { root in
                        SourceRootRow(root: root) {
                            Task {
                                do {
                                    try await viewModel.removeSourceRoot(root.id)
                                } catch {
                                    viewModel.errorMessage = error.localizedDescription
                                }
                            }
                        }
                    }
                    
                    // Add more button when sources exist
                    Button {
                        selectSourceFolders()
                    } label: {
                        Label("Add Another Folder", systemImage: "plus.circle")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.bordered)
                }
            }
            
            Divider()
            
            // Destination
            VStack(alignment: .leading, spacing: 12) {
                Text("Destination")
                    .font(.headline)
                
                if let dest = viewModel.project.destinationRoot {
                    HStack {
                        Image(systemName: "folder.fill")
                            .foregroundStyle(.blue)
                        Text(dest.path)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button {
                            selectDestinationFolder()
                        } label: {
                            Text("Change")
                        }
                    }
                    .padding(12)
                    .background(.background.secondary)
                    .cornerRadius(8)
                } else {
                    DropZoneView(
                        title: "Drop destination folder here",
                        subtitle: "or click to browse",
                        onTap: { selectDestinationFolder() }
                    ) { [viewModel] urls in
                        await MainActor.run {
                            if let url = urls.first {
                                Task {
                                    do {
                                        try await viewModel.setDestination(url)
                                    } catch {
                                        viewModel.errorMessage = error.localizedDescription
                                    }
                                }
                            }
                        }
                    }
                    .frame(height: 80)
                }
            }
            
            Divider()
            
            // People
            PeopleSection(viewModel: viewModel)
            
            Spacer()
            
            // Scan button
            HStack {
                Spacer()
                Button {
                    Task {
                        do {
                            try await viewModel.startScan()
                        } catch {
                            viewModel.errorMessage = error.localizedDescription
                        }
                    }
                } label: {
                    Label("Start Scan", systemImage: "magnifyingglass")
                }
                .buttonStyle(.borderedProminent)
                .disabled(!canScan)
            }
        }
    }
    
    private var canScan: Bool {
        !viewModel.project.sourceRoots.isEmpty && viewModel.project.destinationRoot != nil
    }
    
    // MARK: - NSOpenPanel Methods
    
    private func selectSourceFolders() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.message = "Select source folders to organize"
        panel.prompt = "Select"
        
        if panel.runModal() == .OK {
            Task {
                for url in panel.urls {
                    do {
                        try await viewModel.addSourceRoot(url)
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
    
    private func selectDestinationFolder() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false
        panel.message = "Select destination folder"
        panel.prompt = "Select"
        
        if panel.runModal() == .OK, let url = panel.url {
            Task {
                do {
                    try await viewModel.setDestination(url)
                } catch {
                    viewModel.errorMessage = error.localizedDescription
                }
            }
        }
    }
}

struct SourceRootRow: View {
    let root: SourceRoot
    let onRemove: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: root.isValid ? "folder.fill" : "folder.badge.questionmark")
                .foregroundStyle(root.isValid ? .blue : .orange)
            
            Text(root.path)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            if !root.isValid {
                Text("Stale")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.background.secondary)
        .cornerRadius(8)
    }
}

struct DropZoneView: View {
    let title: String
    let subtitle: String
    var onTap: (() -> Void)? = nil
    let onDrop: @Sendable ([URL]) async -> Void
    
    @State private var isTargeted = false
    
    var body: some View {
        RoundedRectangle(cornerRadius: 8)
            .strokeBorder(
                style: StrokeStyle(lineWidth: 2, dash: [8, 4])
            )
            .foregroundStyle(isTargeted ? Color.accentColor : Color.secondary.opacity(0.3))
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isTargeted ? Color.accentColor.opacity(0.1) : Color.clear)
            )
            .overlay {
                VStack(spacing: 4) {
                    Image(systemName: "folder.badge.plus")
                        .font(.title)
                        .foregroundStyle(.secondary)
                    Text(title)
                        .font(.headline)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                onTap?()
            }
            .onDrop(of: [.fileURL], isTargeted: $isTargeted) { providers in
                Task {
                    var urls: [URL] = []
                    for provider in providers {
                        if let item = try? await provider.loadItem(forTypeIdentifier: "public.file-url"),
                           let data = item as? Data,
                           let url = URL(dataRepresentation: data, relativeTo: nil) {
                            urls.append(url)
                        }
                    }
                    await onDrop(urls)
                }
                return true
            }
    }
}

struct PeopleSection: View {
    @Bindable var viewModel: ProjectViewModel
    @State private var isAddingPerson = false
    @State private var newPersonName = ""
    @State private var newPersonTokens = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("People")
                    .font(.headline)
                
                Spacer()
                
                Button {
                    isAddingPerson = true
                } label: {
                    Label("Add", systemImage: "plus")
                }
            }
            
            if viewModel.project.people.isEmpty {
                Text("No people configured. Files will be routed to 'Unassigned'.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.background.secondary)
                    .cornerRadius(8)
            } else {
                ForEach(viewModel.project.people) { person in
                    PersonRow(person: person) {
                        Task {
                            do {
                                try await viewModel.removePerson(person.id)
                            } catch {
                                viewModel.errorMessage = error.localizedDescription
                            }
                        }
                    }
                }
            }
        }
        .sheet(isPresented: $isAddingPerson) {
            AddPersonSheet(
                name: $newPersonName,
                tokens: $newPersonTokens
            ) {
                let tokens = newPersonTokens
                    .split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
                
                let person = Person(displayName: newPersonName, keywordTokens: tokens)
                Task {
                    do {
                        try await viewModel.addPerson(person)
                        newPersonName = ""
                        newPersonTokens = ""
                        isAddingPerson = false
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            }
        }
    }
}

struct PersonRow: View {
    let person: Person
    let onRemove: () -> Void
    
    var body: some View {
        HStack {
            Image(systemName: "person.fill")
                .foregroundStyle(.blue)
            
            VStack(alignment: .leading) {
                Text(person.displayName)
                    .fontWeight(.medium)
                Text(person.keywordTokens.joined(separator: ", "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            
            Spacer()
            
            Button(role: .destructive) {
                onRemove()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
        }
        .padding(12)
        .background(.background.secondary)
        .cornerRadius(8)
    }
}

struct AddPersonSheet: View {
    @Binding var name: String
    @Binding var tokens: String
    let onAdd: () -> Void
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Add Person")
                .font(.headline)
            
            TextField("Name", text: $name)
                .textFieldStyle(.roundedBorder)
            
            TextField("Keywords (comma-separated)", text: $tokens)
                .textFieldStyle(.roundedBorder)
            
            Text("Files containing these keywords will be routed to this person's folder.")
                .font(.caption)
                .foregroundStyle(.secondary)
            
            HStack {
                Button("Cancel") {
                    dismiss()
                }
                .keyboardShortcut(.escape)
                
                Button("Add") {
                    onAdd()
                }
                .keyboardShortcut(.defaultAction)
                .disabled(name.isEmpty)
            }
        }
        .padding()
        .frame(width: 350)
    }
}

#Preview {
    ProjectSetupView(viewModel: ProjectViewModel(project: Project(name: "Test"), appState: AppState()))
        .frame(width: 600, height: 600)
        .padding()
}
