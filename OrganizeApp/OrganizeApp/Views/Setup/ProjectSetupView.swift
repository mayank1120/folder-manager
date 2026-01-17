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

            Divider()

            // Extension Routing
            ExtensionRoutingSection(viewModel: viewModel)

            Divider()

            // Filters & Duplicates
            FilterSettingsSection(viewModel: viewModel)

            Divider()

            // Ownership & Matching
            OwnershipSettingsSection(viewModel: viewModel)

            Divider()

            // Advanced Routing Inputs
            AdvancedRoutingSection(viewModel: viewModel)

            Divider()

            // Execution Settings
            ExecutionSettingsSection(viewModel: viewModel)

            Divider()

            // Tags
            TagsSection(viewModel: viewModel)
            
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
        .onChange(of: viewModel.project.settings) { _, _ in
            Task {
                do {
                    try await viewModel.persistProject()
                } catch {
                    viewModel.errorMessage = error.localizedDescription
                }
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

struct ExtensionRoutingSection: View {
    @Bindable var viewModel: ProjectViewModel
    @State private var selectedTemplate: TemplateSelection = .custom
    @State private var isApplyingTemplate = false

    private enum TemplateSelection: String, CaseIterable, Identifiable {
        case custom
        case personal
        case work
        case school

        var id: String { rawValue }

        var displayName: String {
            switch self {
            case .custom: return "Custom"
            case .personal: return "Personal"
            case .work: return "Work"
            case .school: return "School"
            }
        }

        var template: RuleTemplate? {
            switch self {
            case .custom: return nil
            case .personal: return .personal
            case .work: return .work
            case .school: return .school
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Extension Routing")
                .font(.headline)

            Picker("Template", selection: $selectedTemplate) {
                ForEach(TemplateSelection.allCases) { template in
                    Text(template.displayName).tag(template)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: selectedTemplate) { _, newValue in
                guard let template = newValue.template else { return }
                isApplyingTemplate = true
                RuleTemplateCatalog.apply(template: template, to: &viewModel.project.settings)
                DispatchQueue.main.async {
                    isApplyingTemplate = false
                }
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Exclusions")
                    .font(.subheadline)

                Picker("Exclusion Mode", selection: excludeModeBinding) {
                    Text("Exclude only these").tag(ExtensionExcludeMode.excludeOnlyThese)
                    Text("Exclude all except these").tag(ExtensionExcludeMode.excludeAllExceptThese)
                    Text("No exclusions").tag(ExtensionExcludeMode.none)
                }

                TextField("Extensions (comma-separated)", text: excludedExtensionsBinding)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: viewModel.project.settings.extensionExclusions) { _, _ in
                        markCustom()
                    }
            }

            HStack {
                Text("Rules")
                    .font(.subheadline)
                Spacer()
                Button {
                    addRule()
                } label: {
                    Label("Add Rule", systemImage: "plus")
                }
            }

            if viewModel.project.settings.extensionRules.isEmpty {
                Text("No extension rules configured yet.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding()
                    .frame(maxWidth: .infinity)
                    .background(.background.secondary)
                    .cornerRadius(8)
            } else {
                ForEach($viewModel.project.settings.extensionRules) { $rule in
                    ExtensionRuleRow(
                        rule: $rule,
                        onRemove: { removeRule(rule.id) },
                        markCustom: markCustom
                    )
                }
            }
        }
        .onChange(of: viewModel.project.settings.extensionRules) { _, _ in
            markCustom()
        }
    }

    private var excludeModeBinding: Binding<ExtensionExcludeMode> {
        Binding(
            get: { viewModel.project.settings.extensionExclusions.excludeMode },
            set: { viewModel.project.settings.extensionExclusions.excludeMode = $0 }
        )
    }

    private var excludedExtensionsBinding: Binding<String> {
        Binding(
            get: {
                viewModel.project.settings.extensionExclusions.excludedExtensions.joined(separator: ", ")
            },
            set: { newValue in
                let parsed = parseList(newValue)
                viewModel.project.settings.extensionExclusions.excludedExtensions = ExtensionRule.normalizeExtensions(parsed)
            }
        )
    }

    private func addRule() {
        viewModel.project.settings.extensionRules.append(
            ExtensionRule(
                extensions: [],
                destinationType: .customFolder,
                destinationPath: nil,
                destinationIsAbsolute: false,
                ownerScope: .perOwner,
                priority: 0,
                enabled: true
            )
        )
        markCustom()
    }

    private func removeRule(_ id: UUID) {
        viewModel.project.settings.extensionRules.removeAll { $0.id == id }
        markCustom()
    }

    private func parseList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }

    private func markCustom() {
        if isApplyingTemplate {
            return
        }
        if selectedTemplate != .custom {
            selectedTemplate = .custom
        }
    }
}

struct ExtensionRuleRow: View {
    @Binding var rule: ExtensionRule
    let onRemove: () -> Void
    let markCustom: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                TextField("Extensions (e.g., pdf, docx)", text: extensionsBinding)
                    .textFieldStyle(.roundedBorder)
                Toggle("Enabled", isOn: $rule.enabled)
                    .toggleStyle(.switch)
                Button(role: .destructive) {
                    onRemove()
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }

            HStack {
                Picker("Destination", selection: $rule.destinationType) {
                    Text("Custom Folder").tag(ExtensionDestinationType.customFolder)
                    Text("Organized Root").tag(ExtensionDestinationType.organizedRoot)
                }
                .pickerStyle(.segmented)

                if rule.destinationType == .customFolder {
                    TextField("Destination Path", text: destinationPathBinding)
                        .textFieldStyle(.roundedBorder)
                    Toggle("Absolute", isOn: $rule.destinationIsAbsolute)
                        .toggleStyle(.switch)
                }
            }

            HStack {
                Picker("Owner Scope", selection: $rule.ownerScope) {
                    Text("Per Owner").tag(ExtensionOwnerScope.perOwner)
                    Text("Shared Only").tag(ExtensionOwnerScope.sharedOnly)
                    Text("All Owners").tag(ExtensionOwnerScope.allOwners)
                }
                .frame(maxWidth: 260)

                Stepper(value: $rule.priority, in: -10...100) {
                    Text("Priority: \(rule.priority)")
                }
            }
        }
        .padding(12)
        .background(.background.secondary)
        .cornerRadius(8)
        .onChange(of: rule) { _, _ in
            markCustom()
        }
    }

    private var extensionsBinding: Binding<String> {
        Binding(
            get: { rule.extensions.joined(separator: ", ") },
            set: { newValue in
                let parsed = newValue.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                rule.extensions = ExtensionRule.normalizeExtensions(parsed)
            }
        )
    }

    private var destinationPathBinding: Binding<String> {
        Binding(
            get: { rule.destinationPath ?? "" },
            set: { newValue in
                let trimmed = newValue.trimmingCharacters(in: .whitespacesAndNewlines)
                rule.destinationPath = trimmed.isEmpty ? nil : trimmed
            }
        )
    }
}

struct FilterSettingsSection: View {
    @Bindable var viewModel: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Filters & Duplicates")
                .font(.headline)

            Toggle("Detect duplicates (hash scan)", isOn: duplicateEnabledBinding)

            if viewModel.project.settings.duplicateDetection.enabled {
                Picker("Duplicate Handling", selection: duplicateHandlingBinding) {
                    Text("Keep newest").tag(DuplicateHandling.keepNewest)
                    Text("Skip duplicates").tag(DuplicateHandling.skipDuplicates)
                }
            }

            Toggle("Large file filter", isOn: largeFileEnabledBinding)

            if viewModel.project.settings.largeFileFilter.enabled {
                Stepper(value: largeFileMinimumMBBinding, in: 1...10_240) {
                    Text("Minimum size: \(largeFileMinimumMBBinding.wrappedValue) MB")
                }
            }

            Picker("PDF date grouping", selection: pdfDateGroupingBinding) {
                Text("Year").tag(PDFDateGrouping.year)
                Text("Year + Month").tag(PDFDateGrouping.yearMonth)
            }
        }
    }

    private var duplicateEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.project.settings.duplicateDetection.enabled },
            set: { viewModel.project.settings.duplicateDetection.enabled = $0 }
        )
    }

    private var duplicateHandlingBinding: Binding<DuplicateHandling> {
        Binding(
            get: { viewModel.project.settings.duplicateDetection.handling },
            set: { viewModel.project.settings.duplicateDetection.handling = $0 }
        )
    }

    private var largeFileEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.project.settings.largeFileFilter.enabled },
            set: { viewModel.project.settings.largeFileFilter.enabled = $0 }
        )
    }

    private var largeFileMinimumMBBinding: Binding<Int> {
        Binding(
            get: {
                Int(max(1, viewModel.project.settings.largeFileFilter.minimumBytes / (1024 * 1024)))
            },
            set: { newValue in
                viewModel.project.settings.largeFileFilter.minimumBytes = Int64(newValue) * 1024 * 1024
            }
        )
    }

    private var pdfDateGroupingBinding: Binding<PDFDateGrouping> {
        Binding(
            get: { viewModel.project.settings.pdfDateGrouping },
            set: { viewModel.project.settings.pdfDateGrouping = $0 }
        )
    }
}

struct OwnershipSettingsSection: View {
    @Bindable var viewModel: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Ownership & Matching")
                .font(.headline)

            Toggle("Auto-file Shared matches", isOn: autoFileSharedBinding)
            Toggle("Auto-file Unassigned matches", isOn: autoFileUnassignedBinding)

            Divider()

            Toggle("Enable camelCase splitting", isOn: camelCaseBinding)
            Toggle("Enable digit splitting", isOn: digitSplitBinding)
        }
    }

    private var autoFileSharedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.project.settings.autoFileShared },
            set: { viewModel.project.settings.autoFileShared = $0 }
        )
    }

    private var autoFileUnassignedBinding: Binding<Bool> {
        Binding(
            get: { viewModel.project.settings.autoFileUnassigned },
            set: { viewModel.project.settings.autoFileUnassigned = $0 }
        )
    }

    private var camelCaseBinding: Binding<Bool> {
        Binding(
            get: { viewModel.project.settings.ownerMatching.enableCamelCaseSplit },
            set: { viewModel.project.settings.ownerMatching.enableCamelCaseSplit = $0 }
        )
    }

    private var digitSplitBinding: Binding<Bool> {
        Binding(
            get: { viewModel.project.settings.ownerMatching.enableDigitSplit },
            set: { viewModel.project.settings.ownerMatching.enableDigitSplit = $0 }
        )
    }
}

struct AdvancedRoutingSection: View {
    @Bindable var viewModel: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Advanced Detection")
                .font(.headline)

            TextField("Screenshot prefixes (comma-separated)", text: screenshotPrefixesBinding)
                .textFieldStyle(.roundedBorder)

            TextField("Camera prefixes (comma-separated)", text: cameraPrefixesBinding)
                .textFieldStyle(.roundedBorder)

            TextField("Project markers (comma-separated)", text: projectMarkersBinding)
                .textFieldStyle(.roundedBorder)

            Text("Markers are used to exclude project/repo folders (e.g., .git, .xcodeproj).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private var screenshotPrefixesBinding: Binding<String> {
        Binding(
            get: { viewModel.project.settings.screenshotPrefixes.joined(separator: ", ") },
            set: { viewModel.project.settings.screenshotPrefixes = parseList($0) }
        )
    }

    private var cameraPrefixesBinding: Binding<String> {
        Binding(
            get: { viewModel.project.settings.cameraPrefixes.joined(separator: ", ") },
            set: { viewModel.project.settings.cameraPrefixes = parseList($0) }
        )
    }

    private var projectMarkersBinding: Binding<String> {
        Binding(
            get: { viewModel.project.settings.projectMarkers.joined(separator: ", ") },
            set: { viewModel.project.settings.projectMarkers = parseList($0) }
        )
    }

    private func parseList(_ text: String) -> [String] {
        text.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
    }
}

struct ExecutionSettingsSection: View {
    @Bindable var viewModel: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Execution Settings")
                .font(.headline)

            Picker("Execution Mode", selection: executionModeBinding) {
                Text("Copy-first").tag(ExecutionMode.copyFirst)
                Text("Move").tag(ExecutionMode.move)
            }
            .pickerStyle(.segmented)

            Picker("Collision Policy", selection: collisionPolicyBinding) {
                Text("Auto suffix").tag(CollisionPolicy.autoSuffix)
                Text("Manual review").tag(CollisionPolicy.manual)
            }

            Picker("Delete Originals Mode", selection: deleteOriginalsModeBinding) {
                Text("Move to Trash").tag(DeleteOriginalsMode.moveToTrash)
                Text("Archive to Backup").tag(DeleteOriginalsMode.archiveToBackup)
            }

            Toggle("Download cloud-only files during apply", isOn: downloadBeforeProcessingBinding)
            Toggle("Enable Other bucket", isOn: enableOtherBucketBinding)
            Toggle("Cleanup empty folders after apply", isOn: cleanupEmptyFoldersBinding)
        }
    }

    private var executionModeBinding: Binding<ExecutionMode> {
        Binding(
            get: { viewModel.project.settings.executionMode },
            set: { viewModel.project.settings.executionMode = $0 }
        )
    }

    private var collisionPolicyBinding: Binding<CollisionPolicy> {
        Binding(
            get: { viewModel.project.settings.collisionPolicy },
            set: { viewModel.project.settings.collisionPolicy = $0 }
        )
    }

    private var downloadBeforeProcessingBinding: Binding<Bool> {
        Binding(
            get: { viewModel.project.settings.downloadBeforeProcessing },
            set: { viewModel.project.settings.downloadBeforeProcessing = $0 }
        )
    }

    private var deleteOriginalsModeBinding: Binding<DeleteOriginalsMode> {
        Binding(
            get: { viewModel.project.settings.deleteOriginalsMode },
            set: { viewModel.project.settings.deleteOriginalsMode = $0 }
        )
    }

    private var enableOtherBucketBinding: Binding<Bool> {
        Binding(
            get: { viewModel.project.settings.enableOtherBucket },
            set: { viewModel.project.settings.enableOtherBucket = $0 }
        )
    }

    private var cleanupEmptyFoldersBinding: Binding<Bool> {
        Binding(
            get: { viewModel.project.settings.cleanupEmptyFolders },
            set: { viewModel.project.settings.cleanupEmptyFolders = $0 }
        )
    }
}

struct TagsSection: View {
    @Bindable var viewModel: ProjectViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tags")
                .font(.headline)

            Toggle("Enable tags", isOn: tagsEnabledBinding)

            TextField("Tag names (comma-separated)", text: tagNamesBinding)
                .textFieldStyle(.roundedBorder)
                .disabled(!viewModel.project.settings.tagsEnabled)
        }
    }

    private var tagsEnabledBinding: Binding<Bool> {
        Binding(
            get: { viewModel.project.settings.tagsEnabled },
            set: { viewModel.project.settings.tagsEnabled = $0 }
        )
    }

    private var tagNamesBinding: Binding<String> {
        Binding(
            get: { viewModel.project.settings.tagNames.joined(separator: ", ") },
            set: { newValue in
                let parsed = newValue.split(separator: ",")
                    .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                    .filter { !$0.isEmpty }
                viewModel.project.settings.tagNames = parsed
            }
        )
    }
}

#Preview {
    ProjectSetupView(viewModel: ProjectViewModel(project: Project(name: "Test"), appState: AppState()))
        .frame(width: 600, height: 600)
        .padding()
}
