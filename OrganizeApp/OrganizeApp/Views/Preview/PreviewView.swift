import SwiftUI
import OrganizeCore

struct PreviewView: View {
    @Bindable var viewModel: ProjectViewModel
    @State private var selectedTab: PreviewTab = .moveEligible
    @State private var searchText = ""
    
    enum PreviewTab: String, CaseIterable {
        case moveEligible = "Move Eligible"
        case needsReview = "Needs Review"
        case excluded = "Excluded"
        case tree = "Tree View"
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
            case .tree:
                TreeDiffView(
                    operations: filteredOperations,
                    destinationRoot: viewModel.project.destinationRoot?.path ?? ""
                )
            }
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
        }
        .padding()
        .background(.background.secondary)
    }
    
    private var filteredOperations: [PlanStore.PlanOperationExecutionRow] {
        guard !searchText.isEmpty else { return viewModel.operations }
        let query = searchText.lowercased()
        return viewModel.operations.filter { row in
            row.sourcePathAtScan.lowercased().contains(query) ||
            row.operation.resolvedDestPath.lowercased().contains(query)
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
        Text(disposition)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .cornerRadius(4)
    }
    
    private var backgroundColor: Color {
        switch disposition {
        case "MoveEligible": return .green.opacity(0.2)
        case "NeedsReview": return .orange.opacity(0.2)
        case "ExcludedByPolicy": return .gray.opacity(0.2)
        default: return .gray.opacity(0.2)
        }
    }
    
    private var foregroundColor: Color {
        switch disposition {
        case "MoveEligible": return .green
        case "NeedsReview": return .orange
        case "ExcludedByPolicy": return .secondary
        default: return .secondary
        }
    }
}

struct ConfidenceBadge: View {
    let confidence: String
    
    var body: some View {
        Text(confidence)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(backgroundColor)
            .foregroundStyle(foregroundColor)
            .cornerRadius(4)
    }
    
    private var backgroundColor: Color {
        switch confidence.lowercased() {
        case "high": return .green.opacity(0.2)
        case "medium": return .orange.opacity(0.2)
        case "low": return Color.red.opacity(0.2)
        default: return Color.gray.opacity(0.2)
        }
    }
    
    private var foregroundColor: Color {
        switch confidence.lowercased() {
        case "high": return Color.green
        case "medium": return Color.orange
        case "low": return Color.red
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
