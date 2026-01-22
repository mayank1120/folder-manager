import SwiftUI
import OrganizeCore
import UniformTypeIdentifiers
import AppKit

struct PreviewView: View {
    @Bindable var viewModel: ProjectViewModel
    @State private var selectedTab: PreviewTab = .moveEligible
    @State private var searchText = ""
    @State private var showingExportPicker = false
    @State private var exportResult: ExportResult?
    
    enum PreviewTab: String, CaseIterable {
        case moveEligible = "Move Eligible"
        case needsReview = "Needs Review"
        case excluded = "Excluded"
        case scanExcluded = "Scan Excluded"
        case duplicates = "Duplicates"
        case tree = "Tree View"
        case extensions = "Extensions"
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Summary bar
            summaryBar
            
            Divider()
            
            // Tab picker
            Picker("View", selection: $selectedTab) {
                ForEach(PreviewTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)
            .padding()
            
            // Content
            switch selectedTab {
            case .moveEligible:
                OperationsTableView(
                    operations: filteredOperations,
                    searchText: $searchText,
                    destinationRoot: viewModel.project.destinationRoot?.path
                )
            case .needsReview:
                PlanItemsTableView(
                    items: viewModel.needsReviewItems,
                    searchText: $searchText,
                    title: "These items need manual review before filing"
                )
            case .excluded:
                PlanItemsTableView(
                    items: viewModel.excludedItems,
                    searchText: $searchText,
                    title: "These items are excluded by policy"
                )
            case .scanExcluded:
                ScanExcludedTableView(
                    items: viewModel.scanExcludedItems,
                    searchText: $searchText
                )
            case .duplicates:
                DuplicatesTableView(
                    groups: $viewModel.duplicateGroups,
                    viewModel: viewModel
                )
            case .tree:
                TreeDiffView(
                    operations: filteredOperations,
                    destinationRoot: viewModel.project.destinationRoot?.path ?? ""
                )
            case .extensions:
                ExtensionReportView(rows: viewModel.extensionReport)
            }
        }
        .onAppear {
            loadHistoryOnAppear()
        }
    }
    
    private var summaryBar: some View {
        HStack(spacing: 24) {
            if let summary = viewModel.planSummary {
                SummaryItem(
                    title: "Move Eligible",
                    value: "\(summary.moveEligibleCount)",
                    color: .green
                )
                SummaryItem(
                    title: "Needs Review",
                    value: "\(summary.needsReviewCount)",
                    color: summary.needsReviewCount > 0 ? .orange : .secondary
                )
                SummaryItem(
                    title: "Excluded",
                    value: "\(summary.excludedByPolicyCount)",
                    color: .secondary
                )
                
                // Plan History picker
                if viewModel.planHistory.count > 1 {
                    Divider()
                        .frame(height: 30)
                    
                    Menu {
                        ForEach(viewModel.planHistory, id: \.id) { plan in
                            Button {
                                Task {
                                    await viewModel.selectPlan(plan)
                                }
                            } label: {
                                HStack {
                                    Text(formatPlanDate(plan.createdAt))
                                    Text("(\(plan.operationCount) ops)")
                                        .foregroundStyle(.secondary)
                                    if plan.id == viewModel.project.currentPlanId {
                                        Image(systemName: "checkmark")
                                    }
                                }
                            }
                        }
                    } label: {
                        Label("Plan History", systemImage: "clock.arrow.circlepath")
                            .font(.caption)
                    }
                    .help("Switch between previous plans for this project")
                }
            }
            
            Spacer()
            
            Button {
                Task {
                    do {
                        try await viewModel.apply()
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label("Apply", systemImage: "arrow.right.circle.fill")
            }
            .buttonStyle(.borderedProminent)
            
            Button {
                Task {
                    do {
                        try await viewModel.apply(dryRun: true)
                    } catch {
                        viewModel.errorMessage = error.localizedDescription
                    }
                }
            } label: {
                Label("Dry Run", systemImage: "eye")
            }
            
            Button {
                showingExportPicker = true
            } label: {
                Label("Export Report", systemImage: "square.and.arrow.up")
            }
            .help("Export plan data to CSV files (inventory, proposed moves, needs review, excluded, extensions)")
        }
        .padding()
        .background(.background.secondary)
        .fileExporter(
            isPresented: $showingExportPicker,
            document: ExportFolderDocument(),
            contentType: .folder,
            defaultFilename: "OrganizeExport"
        ) { result in
            switch result {
            case .success(let url):
                Task {
                    do {
                        let paths = try await viewModel.exportPlan(to: url)
                        exportResult = ExportResult(success: true, directory: paths.directory, message: nil)
                    } catch {
                        exportResult = ExportResult(success: false, directory: nil, message: error.localizedDescription)
                    }
                }
            case .failure(let error):
                exportResult = ExportResult(success: false, directory: nil, message: error.localizedDescription)
            }
        }
        .alert("Export Complete", isPresented: .init(
            get: { exportResult?.success == true },
            set: { if !$0 { exportResult = nil } }
        )) {
            Button("Open Folder") {
                if let dir = exportResult?.directory {
                    NSWorkspace.shared.open(dir)
                }
                exportResult = nil
            }
            Button("OK", role: .cancel) {
                exportResult = nil
            }
        } message: {
            if let dir = exportResult?.directory {
                Text("5 CSV files exported to:\n\(dir.path)")
            }
        }
        .alert("Export Failed", isPresented: .init(
            get: { exportResult?.success == false },
            set: { if !$0 { exportResult = nil } }
        )) {
            Button("OK", role: .cancel) { exportResult = nil }
        } message: {
            Text(exportResult?.message ?? "Unknown error")
        }
    }
    
    private var filteredOperations: [PlanStore.PlanOperationExecutionRow] {
        let base = viewModel.operations.filter {
            $0.operation.operationType != .applyTags
        }
        guard !searchText.isEmpty else { return base }
        let query = searchText.lowercased()
        return base.filter { row in
            row.sourcePathAtScan.lowercased().contains(query) ||
            row.operation.resolvedDestPath.lowercased().contains(query)
        }
    }
    
    private func formatPlanDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

extension PreviewView {
    /// Load plan history when view appears
    func loadHistoryOnAppear() {
        Task {
            await viewModel.loadPlanHistory()
        }
    }
}

struct SummaryItem: View {
    let title: String
    let value: String
    let color: Color
    
    var body: some View {
        VStack(spacing: 2) {
            Text(value)
                .font(.title2)
                .fontWeight(.semibold)
                .foregroundStyle(color)
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - Operations Table (Move Eligible)

struct OperationsTableView: View {
    let operations: [PlanStore.PlanOperationExecutionRow]
    @Binding var searchText: String
    let destinationRoot: String?
    @State private var selection: String?
    
    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            SearchBar(searchText: $searchText)
            
            // Header
            HStack {
                Text("Source")
                    .frame(minWidth: 150, alignment: .leading)
                Spacer()
                Text("Destination")
                    .frame(minWidth: 200, alignment: .leading)
                Spacer()
                Text("Type")
                    .frame(width: 60)
                Text("Size")
                    .frame(width: 80)
            }
            .font(.caption.bold())
            .foregroundStyle(.secondary)
            .padding(.horizontal)
            .padding(.vertical, 8)
            .background(Color.secondary.opacity(0.1))
            
            Divider()
            
            // Scrollable list of operations
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(operations.enumerated()), id: \.offset) { index, row in
                        OperationRowView(
                            row: row,
                            destinationRoot: destinationRoot
                        )
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(index % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05))
                    }
                }
            }
        }
    }
}

struct OperationRowView: View {
    let row: PlanStore.PlanOperationExecutionRow
    let destinationRoot: String?
    
    var body: some View {
        HStack {
            // Source
            HStack {
                FileIcon(path: row.sourcePathAtScan, isPackage: row.isPackage)
                Text(URL(fileURLWithPath: row.sourcePathAtScan).lastPathComponent)
                    .lineLimit(1)
            }
            .frame(minWidth: 150, alignment: .leading)
            
            Spacer()
            
            // Destination
            Text(relativePath(row.operation.resolvedDestPath))
                .lineLimit(1)
                .foregroundStyle(.secondary)
                .frame(minWidth: 200, alignment: .leading)
            
            Spacer()
            
            // Type
            OperationTypeBadge(type: row.operation.operationType)
                .frame(width: 60)
            
            // Size
            Text(formatBytes(row.expectedSizeBytes))
                .foregroundStyle(.secondary)
                .frame(width: 80)
            
            // Collision indicator
            if row.operation.collisionResolved {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .help("Collision resolved with suffix")
            }
        }
        .padding(.vertical, 4)
    }
    
    private func relativePath(_ path: String) -> String {
        guard let root = destinationRoot, path.hasPrefix(root) else { return path }
        var relative = String(path.dropFirst(root.count))
        if relative.hasPrefix("/") { relative = String(relative.dropFirst()) }
        return relative.isEmpty ? "/" : relative
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Plan Items Table (Needs Review / Excluded)

struct PlanItemsTableView: View {
    let items: [PlanStore.PlanItemRow]
    @Binding var searchText: String
    let title: String
    @State private var selection: String?
    
    var filteredItems: [PlanStore.PlanItemRow] {
        guard !searchText.isEmpty else { return items }
        let query = searchText.lowercased()
        return items.filter { $0.relativePath.lowercased().contains(query) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            SearchBar(searchText: $searchText)
            
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("No items in this category")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Info banner
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text(title)
                        .font(.caption)
                    Spacer()
                    Text("\(items.count) item(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .padding(8)
                .background(.blue.opacity(0.1))
                
                // Scrollable list of items
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredItems.enumerated()), id: \.offset) { index, item in
                            PlanItemRowView(item: item)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .background(index % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05))
                        }
                    }
                }
            }
        }
    }
}

struct PlanItemRowView: View {
    let item: PlanStore.PlanItemRow
    
    var body: some View {
        HStack {
            // File info
            HStack {
                FileIcon(path: item.relativePath, isPackage: item.isPackage)
                Text(URL(fileURLWithPath: item.relativePath).lastPathComponent)
                    .lineLimit(1)
            }
            .frame(minWidth: 150, alignment: .leading)
            
            Spacer()
            
            // Disposition
            DispositionBadge(disposition: item.planItem.disposition.rawValue)
                .frame(width: 100)
            
            // Owner
            Text(item.planItem.ownerBucket ?? "—")
                .foregroundStyle(.secondary)
                .frame(width: 80)
            
            // Reason
            Text(item.planItem.reasonCode ?? item.planItem.issueType ?? "—")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(minWidth: 100)
            
            // Confidence
            if let confidence = item.planItem.ownerConfidence {
                ConfidenceBadge(confidence: confidence.rawValue)
                    .frame(width: 80)
            } else {
                Text("—")
                    .foregroundStyle(.secondary)
                    .frame(width: 80)
            }
        }
        .padding(.vertical, 4)
    }
}

// MARK: - Badges (PlanItemRow definition moved to PlanStore)

// MARK: - Badges

struct DispositionBadge: View {
    let disposition: String
    
    var body: some View {
        Text(displayText)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .cornerRadius(4)
    }
    
    private var displayText: String {
        switch disposition {
        case "moveEligible": return "Move Eligible"
        case "needsReview": return "Needs Review"
        case "excludedByPolicy": return "Excluded"
        default: return disposition
        }
    }
    
    private var backgroundColor: Color {
        switch disposition {
        case "moveEligible": return .green.opacity(0.2)
        case "needsReview": return .orange.opacity(0.2)
        case "excludedByPolicy": return .gray.opacity(0.2)
        default: return .gray.opacity(0.2)
        }
    }
    
    private var foregroundColor: Color {
        switch disposition {
        case "moveEligible": return .green
        case "needsReview": return .orange
        case "excludedByPolicy": return .secondary
        default: return .secondary
        }
    }
}

struct ConfidenceBadge: View {
    let confidence: String
    
    var body: some View {
        Text(displayText)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .cornerRadius(4)
    }
    
    private var displayText: String {
        switch confidence {
        case "confident": return "Confident"
        case "notConfident": return "Uncertain"
        default: return confidence
        }
    }
    
    private var backgroundColor: Color {
        switch confidence {
        case "confident": return .green.opacity(0.2)
        case "notConfident": return .orange.opacity(0.2)
        default: return Color.gray.opacity(0.2)
        }
    }
    
    private var foregroundColor: Color {
        switch confidence {
        case "confident": return Color.green
        case "notConfident": return Color.orange
        default: return .secondary
        }
    }
}

struct SearchBar: View {
    @Binding var searchText: String
    
    var body: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField("Search files...", text: $searchText)
                .textFieldStyle(.plain)
            if !searchText.isEmpty {
                Button {
                    searchText = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(.background.secondary)
    }
}

struct FileIcon: View {
    let path: String
    let isPackage: Bool
    
    var body: some View {
        Image(systemName: iconName)
            .foregroundStyle(iconColor)
    }
    
    private var iconName: String {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "pdf": return "doc.fill"
        case "jpg", "jpeg", "png", "heic", "gif": return "photo.fill"
        case "mp4", "mov", "avi": return "video.fill"
        case "mp3", "wav", "aac": return "music.note"
        case "pages", "key", "numbers": return "doc.richtext.fill"
        case "app": return "app.fill"
        default:
            return isPackage ? "folder.fill" : "doc.fill"
        }
    }
    
    private var iconColor: Color {
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "pdf": return .red
        case "jpg", "jpeg", "png", "heic", "gif": return .green
        case "mp4", "mov", "avi": return .purple
        case "mp3", "wav", "aac": return .pink
        case "pages", "key", "numbers": return .orange
        default: return .blue
        }
    }
}

struct OperationTypeBadge: View {
    let type: PlanOperationType
    
    var body: some View {
        Text(type == .copyItem ? "Copy" : "Move")
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(type == .copyItem ? Color.blue.opacity(0.2) : Color.orange.opacity(0.2))
            .foregroundStyle(type == .copyItem ? .blue : .orange)
            .cornerRadius(4)
    }
}

// MARK: - Extension Report

struct ExtensionReportView: View {
    let rows: [PlanStore.ExtensionReportRow]

    var body: some View {
        VStack(spacing: 0) {
            if rows.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.text.magnifyingglass")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No extension data available")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HStack {
                    Text("Extension")
                        .frame(minWidth: 120, alignment: .leading)
                    Spacer()
                    Text("Count")
                        .frame(width: 80, alignment: .trailing)
                    Text("Total Size")
                        .frame(width: 120, alignment: .trailing)
                }
                .font(.caption.bold())
                .foregroundStyle(.secondary)
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(Color.secondary.opacity(0.1))

                Divider()

                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                            HStack {
                                Text(row.fileExtension)
                                    .frame(minWidth: 120, alignment: .leading)
                                Spacer()
                                Text("\(row.count)")
                                    .frame(width: 80, alignment: .trailing)
                                Text(formatBytes(row.totalBytes))
                                    .frame(width: 120, alignment: .trailing)
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.horizontal)
                            .padding(.vertical, 6)
                            .background(index % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05))
                        }
                    }
                }
            }
        }
    }

    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Tree Diff View

struct TreeDiffView: View {
    let operations: [PlanStore.PlanOperationExecutionRow]
    let destinationRoot: String
    @State private var expandedPaths: Set<String> = []
    
    var body: some View {
        List {
            if let root = buildTree() {
                TreeNodeView(node: root, expandedPaths: $expandedPaths)
            }
        }
        .listStyle(.sidebar)
    }
    
    private func buildTree() -> TreeNode? {
        guard !operations.isEmpty else { return nil }
        
        let root = TreeNode(name: "Destination", path: "", isFolder: true, children: [])
        
        for op in operations {
            // Use relative path from destination root
            var destPath = op.operation.resolvedDestPath
            if destPath.hasPrefix(destinationRoot) {
                destPath = String(destPath.dropFirst(destinationRoot.count))
                if destPath.hasPrefix("/") { destPath = String(destPath.dropFirst()) }
            }
            
            let components = destPath.split(separator: "/").map(String.init)
            
            var current = root
            var currentPath = ""
            
            for (index, component) in components.enumerated() {
                currentPath += "/" + component
                
                let isLast = index == components.count - 1
                
                if let existing = current.children.first(where: { $0.name == component }) {
                    current = existing
                } else {
                    let newNode = TreeNode(
                        name: component,
                        path: currentPath,
                        isFolder: !isLast,
                        children: []
                    )
                    current.children.append(newNode)
                    current = newNode
                }
            }
        }
        
        return root
    }
}

class TreeNode: Identifiable {
    let id = UUID()
    let name: String
    let path: String
    let isFolder: Bool
    var children: [TreeNode]
    
    init(name: String, path: String, isFolder: Bool, children: [TreeNode]) {
        self.name = name
        self.path = path
        self.isFolder = isFolder
        self.children = children
    }
}

struct TreeNodeView: View {
    let node: TreeNode
    @Binding var expandedPaths: Set<String>
    
    private var isExpanded: Bool {
        expandedPaths.contains(node.path)
    }
    
    var body: some View {
        if node.isFolder && !node.children.isEmpty {
            DisclosureGroup(isExpanded: Binding(
                get: { isExpanded },
                set: { newValue in
                    if newValue {
                        expandedPaths.insert(node.path)
                    } else {
                        expandedPaths.remove(node.path)
                    }
                }
            )) {
                ForEach(node.children) { child in
                    TreeNodeView(node: child, expandedPaths: $expandedPaths)
                }
            } label: {
                Label(node.name, systemImage: "folder.fill")
                    .foregroundStyle(.primary)
            }
        } else {
            Label(node.name, systemImage: "doc.fill")
                .foregroundStyle(.secondary)
        }
    }
}

#Preview {
    PreviewView(viewModel: ProjectViewModel(project: Project(name: "Test"), appState: AppState()))
}

// MARK: - Scan Excluded Table View

struct ScanExcludedTableView: View {
    let items: [ExcludedItem]
    @Binding var searchText: String
    
    var filteredItems: [ExcludedItem] {
        guard !searchText.isEmpty else { return items }
        let query = searchText.lowercased()
        return items.filter { $0.relativePath.lowercased().contains(query) }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            SearchBar(searchText: $searchText)
            
            if items.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 48))
                        .foregroundStyle(.green)
                    Text("No items excluded during scan")
                        .font(.headline)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Info banner
                HStack {
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.blue)
                    Text("Items excluded during scan (symlinks, aliases, project folders, hidden items)")
                        .font(.caption)
                    Spacer()
                    Text("\(items.count) item(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    // Export menu
                    Menu {
                        Button("Export as CSV...") {
                            exportItems(format: .csv)
                        }
                        Button("Export as JSON...") {
                            exportItems(format: .json)
                        }
                    } label: {
                        Label("Export", systemImage: "square.and.arrow.up")
                            .font(.caption)
                    }
                    .menuStyle(.borderlessButton)
                }
                .padding(8)
                .background(.blue.opacity(0.1))
                
                // Scrollable list of items
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(Array(filteredItems.enumerated()), id: \.offset) { index, item in
                            ScanExcludedRowView(item: item)
                                .padding(.horizontal)
                                .padding(.vertical, 6)
                                .background(index % 2 == 0 ? Color.clear : Color.secondary.opacity(0.05))
                        }
                    }
                }
            }
        }
    }
    
    enum ExportFormat {
        case csv, json
        
        var fileExtension: String {
            switch self {
            case .csv: return "csv"
            case .json: return "json"
            }
        }
        
        var fileTypeName: String {
            switch self {
            case .csv: return "CSV"
            case .json: return "JSON"
            }
        }
    }
    
    private func exportItems(format: ExportFormat) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = format == .csv ? [.commaSeparatedText] : [.json]
        panel.nameFieldStringValue = "scan_excluded.\(format.fileExtension)"
        panel.title = "Export Scan-Excluded Items"
        panel.prompt = "Export"
        
        if panel.runModal() == .OK, let url = panel.url {
            do {
                let data: Data
                if format == .csv {
                    data = ExportHelpers.exportToCSV(items: items).data(using: .utf8) ?? Data()
                } else {
                    data = try ExportHelpers.exportToJSON(items: items)
                }
                try data.write(to: url)
            } catch {
                // Show error - in a real app would use alert
                print("Export failed: \(error)")
            }
        }
    }
}

struct ScanExcludedRowView: View {
    let item: ExcludedItem
    
    var body: some View {
        HStack {
            // Icon
            Image(systemName: item.isDirectory ? "folder.fill" : "doc.fill")
                .foregroundStyle(iconColor)
            
            // Path
            Text(item.relativePath)
                .lineLimit(1)
                .truncationMode(.middle)
            
            Spacer()
            
            // Reason badge
            Text(reasonLabel)
                .font(.caption)
                .padding(.horizontal, 8)
                .padding(.vertical, 2)
                .background(reasonColor.opacity(0.2))
                .foregroundStyle(reasonColor)
                .cornerRadius(4)
        }
    }
    
    private var iconColor: Color {
        switch item.reason {
        case .symlink, .finderAlias:
            return .orange
        case .hiddenItem:
            return .gray
        case .appBundle, .photoLibrary, .packageGeneric:
            return .purple
        case .projectFolder:
            return .blue
        }
    }
    
    private var reasonLabel: String {
        switch item.reason {
        case .symlink: return "Symlink"
        case .finderAlias: return "Alias"
        case .hiddenItem: return "Hidden"
        case .appBundle: return "App Bundle"
        case .photoLibrary: return "Photo Library"
        case .packageGeneric: return "Package"
        case .projectFolder: return "Project Folder"
        }
    }
    
    private var reasonColor: Color {
        switch item.reason {
        case .symlink, .finderAlias:
            return .orange
        case .hiddenItem:
            return .gray
        case .appBundle, .photoLibrary, .packageGeneric:
            return .purple
        case .projectFolder:
            return .blue
        }
    }
}

// MARK: - Duplicates Table View

struct DuplicatesTableView: View {
    @Binding var groups: [DuplicateGroup]
    var viewModel: ProjectViewModel
    @State private var isApplying = false
    @State private var applyError: String?
    
    var totalSavings: Int64 {
        groups.reduce(0) { $0 + $1.potentialSavingsBytes }
    }
    
    var body: some View {
        VStack(spacing: 0) {
            if groups.isEmpty {
                VStack(spacing: 12) {
                    Image(systemName: "doc.on.doc")
                        .font(.system(size: 48))
                        .foregroundStyle(.secondary)
                    Text("No duplicate files found")
                        .font(.headline)
                    Text("Enable duplicate detection in settings to scan for duplicates")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Summary header
                HStack {
                    Image(systemName: "doc.on.doc.fill")
                        .foregroundStyle(.orange)
                    Text("\(groups.count) duplicate group(s) found")
                        .font(.caption)
                    Spacer()
                    Text("Potential savings: \(formatBytes(totalSavings))")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    
                    Button {
                        applySelections()
                    } label: {
                        if isApplying {
                            ProgressView()
                                .scaleEffect(0.7)
                        } else {
                            Label("Apply Selections", systemImage: "checkmark.circle")
                        }
                    }
                    .disabled(isApplying)
                    .buttonStyle(.borderedProminent)
                }
                .padding(8)
                .background(.orange.opacity(0.1))
                
                // Scrollable list of groups
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 8) {
                        ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                            DuplicateGroupRowView(
                                group: Binding(
                                    get: { groups[index] },
                                    set: { groups[index] = $0 }
                                )
                            )
                        }
                    }
                    .padding()
                }
            }
        }
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
    
    private func applySelections() {
        isApplying = true
        applyError = nil
        Task {
            do {
                try await viewModel.applyDuplicateSelections()
            } catch {
                applyError = error.localizedDescription
            }
            isApplying = false
        }
    }
}

struct DuplicateGroupRowView: View {
    @Binding var group: DuplicateGroup
    @State private var isExpanded = true
    
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Group header
            Button {
                withAnimation { isExpanded.toggle() }
            } label: {
                HStack {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .foregroundStyle(.secondary)
                    Text("\(group.items.count) copies")
                        .fontWeight(.medium)
                    Text("(\(formatBytes(group.items.first?.sizeBytes ?? 0)) each)")
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("Hash: \(String(group.id.prefix(8)))...")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .padding(8)
            .background(.background.secondary)
            
            // Expanded items with radio buttons
            if isExpanded {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(group.items) { item in
                        HStack {
                            // Radio button for keeper selection
                            Image(systemName: group.selectedKeeperId == item.itemId ? "largecircle.fill.circle" : "circle")
                                .foregroundStyle(group.selectedKeeperId == item.itemId ? .blue : .secondary)
                                .onTapGesture {
                                    group.selectedKeeperId = item.itemId
                                }
                            
                            VStack(alignment: .leading) {
                                Text(item.relativePath)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                    .truncationMode(.middle)
                                Text("Modified: \(item.modifiedTime.formatted())")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            
                            Spacer()
                            
                            if group.selectedKeeperId == item.itemId {
                                Text("Keep")
                                    .font(.caption)
                                    .foregroundStyle(.blue)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.blue.opacity(0.1))
                                    .cornerRadius(4)
                            } else {
                                Text("Remove")
                                    .font(.caption)
                                    .foregroundStyle(.red)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(.red.opacity(0.1))
                                    .cornerRadius(4)
                            }
                        }
                        .padding(8)
                        .background(group.selectedKeeperId == item.itemId ? Color.blue.opacity(0.05) : Color.clear)
                    }
                }
                .padding(.leading, 24)
            }
        }
        .background(.background)
        .cornerRadius(8)
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(.separator, lineWidth: 1)
        )
    }
    
    private func formatBytes(_ bytes: Int64) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        return formatter.string(fromByteCount: bytes)
    }
}

// MARK: - Export Helper Types

/// Result of a plan export operation
private struct ExportResult {
    let success: Bool
    let directory: URL?
    let message: String?
}

/// Document type for folder selection in export
struct ExportFolderDocument: FileDocument {
    static var readableContentTypes: [UTType] { [.folder] }
    
    init() {}
    
    init(configuration: ReadConfiguration) throws {
        // Not used - we're only writing, not reading
    }
    
    func fileWrapper(configuration: WriteConfiguration) throws -> FileWrapper {
        // Return empty folder wrapper - ExportManager will populate it
        return FileWrapper(directoryWithFileWrappers: [:])
    }
}
