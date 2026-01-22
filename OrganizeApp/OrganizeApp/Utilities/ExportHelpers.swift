import Foundation
import OrganizeCore

/// Export utilities for plan and scan data
struct ExportHelpers {
    
    /// Export excluded items to CSV format
    static func exportToCSV(items: [ExcludedItem]) -> String {
        var lines = ["Path,Reason,Scan ID"]
        for item in items {
            let escapedPath = item.relativePath.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\"\(escapedPath)\",\"\(item.reason.rawValue)\",\"\(item.scanId)\"")
        }
        return lines.joined(separator: "\n")
    }
    
    /// Export excluded items to JSON format
    static func exportToJSON(items: [ExcludedItem]) throws -> Data {
        let exportItems = items.map { item in
            ExportedExcludedItem(
                path: item.relativePath,
                reason: item.reason.rawValue,
                scanId: item.scanId.uuidString
            )
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try encoder.encode(exportItems)
    }
    
    /// Export plan operations to CSV format  
    static func exportOperationsToCSV(operations: [PlanStore.PlanOperationExecutionRow]) -> String {
        var lines = ["Source Path,Destination Path,Operation Type,Size (bytes)"]
        for op in operations {
            let escapedSource = op.relativePath.replacingOccurrences(of: "\"", with: "\"\"")
            let escapedDest = op.operation.resolvedDestPath.replacingOccurrences(of: "\"", with: "\"\"")
            lines.append("\"\(escapedSource)\",\"\(escapedDest)\",\"\(op.operation.operationType.rawValue)\",\(op.expectedSizeBytes)")
        }
        return lines.joined(separator: "\n")
    }
}

private struct ExportedExcludedItem: Codable {
    let path: String
    let reason: String
    let scanId: String
}
