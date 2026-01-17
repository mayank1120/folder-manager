import Foundation
import CryptoKit
import GRDB

public struct PlanExportPaths: Sendable {
    public let directory: URL
    public let inventoryCSV: URL
    public let proposedMovesCSV: URL
    public let needsReviewCSV: URL
    public let excludedByPolicyCSV: URL
    public let extensionReportCSV: URL

    public init(directory: URL) {
        self.directory = directory
        self.inventoryCSV = directory.appendingPathComponent("inventory.csv")
        self.proposedMovesCSV = directory.appendingPathComponent("proposed_moves.csv")
        self.needsReviewCSV = directory.appendingPathComponent("needs_review.csv")
        self.excludedByPolicyCSV = directory.appendingPathComponent("excluded_by_policy.csv")
        self.extensionReportCSV = directory.appendingPathComponent("extension_report.csv")
    }
}

public struct ExportManager: Sendable {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    public func exportPlan(planId: EntityID, to directory: URL) async throws -> PlanExportPaths {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let paths = PlanExportPaths(directory: directory)

        guard let plan = try await PlanStore(dbManager: dbManager).fetchPlan(id: planId) else {
            throw ExportError.planNotFound(planId: planId)
        }

        let inventoryRows = try await fetchInventoryExportRows(plan: plan)
        try writeCSV(
            url: paths.inventoryCSV,
            header: [
                "itemId", "scanId", "sourceRootId", "sourceRootPathAtScan", "relativePath",
                "isPackage", "sizeBytes", "modifiedTime", "createdTime", "exifDateTimeOriginal",
                "isCloudOnly", "uttypeIdentifier", "extension", "routingDate", "routingDateSource",
                "proposedOwnerBucket", "ownerReason", "ownerConfidence", "proposedCategory",
                "proposedSubcategory", "baseDestPath", "resolvedDestPath",
                "matchedRuleId", "classificationSource",
                "disposition", "reason"
            ],
            rows: inventoryRows.map { $0.csvRow }
        )

        let proposedMovesRows = try await fetchProposedMovesExportRows(planId: planId)
        try writeCSV(
            url: paths.proposedMovesCSV,
            header: [
                "operationId", "operationType", "executionMode", "sourcePath",
                "baseDestPath", "resolvedDestPath",
                "ownerBucket", "ownerReason", "ownerConfidence",
                "category", "subcategory",
                "matchedRuleId", "classificationSource",
                "collisionResolved", "conflictToken", "crossVolume", "reason"
            ],
            rows: proposedMovesRows.map { $0.csvRow }
        )

        let needsReviewRows = try await fetchNeedsReviewRows(planId: planId)
        try writeCSV(
            url: paths.needsReviewCSV,
            header: [
                "itemId", "path", "suggestedOwnerBucket", "suggestedBaseDestPath", "reason", "issueType"
            ],
            rows: needsReviewRows.map { $0.csvRow }
        )

        let excludedRows = try await fetchExcludedByPolicyRows(plan: plan)
        try writeCSV(
            url: paths.excludedByPolicyCSV,
            header: [
                "itemId", "path", "reason", "policyType"
            ],
            rows: excludedRows.map { $0.csvRow }
        )

        let extensionRows = try await fetchExtensionReportRows(scanId: plan.scanId)
        try writeCSV(
            url: paths.extensionReportCSV,
            header: ["extension", "count", "totalBytes"],
            rows: extensionRows.map { $0.csvRow }
        )

        return paths
    }

    // MARK: - Inventory Export

    private struct InventoryExportRow: Sendable {
        let itemId: String
        let scanId: String
        let sourceRootId: String
        let sourceRootPathAtScan: String
        let relativePath: String
        let isPackage: Bool
        let sizeBytes: Int64
        let modifiedTime: Date
        let createdTime: Date?
        let exifDateTimeOriginal: Date?
        let isCloudOnly: Bool
        let uttypeIdentifier: String?
        let fileExtension: String?
        let routingDate: Date
        let routingDateSource: RoutingDateSource
        let proposedOwnerBucket: String?
        let ownerReason: String?
        let ownerConfidence: String?
        let proposedCategory: String?
        let proposedSubcategory: String?
        let baseDestPath: String?
        let resolvedDestPath: String?
        let matchedRuleId: String?
        let classificationSource: String?
        let disposition: String
        let reason: String?

        var csvRow: [String?] {
            [
                itemId,
                scanId,
                sourceRootId,
                sourceRootPathAtScan,
                relativePath,
                isPackage ? "true" : "false",
                String(sizeBytes),
                ExportManager.formatDate(modifiedTime),
                createdTime.map(ExportManager.formatDate),
                exifDateTimeOriginal.map(ExportManager.formatDate),
                isCloudOnly ? "true" : "false",
                uttypeIdentifier,
                fileExtension,
                ExportManager.formatDate(routingDate),
                routingDateSource.rawValue,
                proposedOwnerBucket,
                ownerReason,
                ownerConfidence,
                proposedCategory,
                proposedSubcategory,
                baseDestPath,
                resolvedDestPath,
                matchedRuleId,
                classificationSource,
                disposition,
                reason
            ]
        }
    }

    private func fetchInventoryExportRows(plan: Plan) async throws -> [InventoryExportRow] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                      i.item_id,
                      i.scan_id,
                      i.source_root_id,
                      r.path_at_scan,
                      i.relative_path,
                      i.is_package,
                      i.size_bytes,
                      i.modified_time,
                      i.created_time,
                      i.exif_datetime_original,
                      i.is_cloud_only,
                      i.uttype_identifier,
                      i.extension,
                      p.disposition,
                      p.owner_bucket,
                      p.owner_reason,
                      p.owner_confidence,
                      p.category,
                      p.subcategory,
                      p.base_dest_path,
                      p.suggested_resolved_dest_path,
                      p.matched_rule_id,
                      p.classification_source,
                      p.reason_code
                    FROM inventory_items i
                    JOIN plan_items p
                      ON p.item_id = i.item_id AND p.plan_id = ?
                    JOIN scan_source_roots r
                      ON r.scan_id = i.scan_id AND r.source_root_id = i.source_root_id
                    WHERE i.scan_id = ?
                    ORDER BY i.source_root_id, i.relative_path
                    """,
                arguments: [plan.id.uuidString, plan.scanId.uuidString]
            )

            return rows.compactMap { row -> InventoryExportRow? in
                guard let itemId = row["item_id"] as String?,
                      let scanId = row["scan_id"] as String?,
                      let sourceRootId = row["source_root_id"] as String?,
                      let sourceRootPathAtScan = row["path_at_scan"] as String?,
                      let relativePath = row["relative_path"] as String?,
                      let isPackageInt = row["is_package"] as Int?,
                      let sizeBytes = row["size_bytes"] as Int64?,
                      let modifiedTimeEpoch = row["modified_time"] as Int64?,
                      let disposition = row["disposition"] as String? else {
                    return nil
                }

                let modifiedTime = Date(timeIntervalSince1970: TimeInterval(modifiedTimeEpoch))
                let createdTime = (row["created_time"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let exifDate = (row["exif_datetime_original"] as Int64?).map { Date(timeIntervalSince1970: TimeInterval($0)) }
                let isCloudOnly = (row["is_cloud_only"] as Int? ?? 0) == 1

                let routingDate = exifDate ?? modifiedTime
                let routingDateSource: RoutingDateSource = exifDate != nil ? .exifOriginal : .modifiedTime

                return InventoryExportRow(
                    itemId: itemId,
                    scanId: scanId,
                    sourceRootId: sourceRootId,
                    sourceRootPathAtScan: sourceRootPathAtScan,
                    relativePath: relativePath,
                    isPackage: isPackageInt == 1,
                    sizeBytes: sizeBytes,
                    modifiedTime: modifiedTime,
                    createdTime: createdTime,
                    exifDateTimeOriginal: exifDate,
                    isCloudOnly: isCloudOnly,
                    uttypeIdentifier: row["uttype_identifier"],
                    fileExtension: row["extension"],
                    routingDate: routingDate,
                    routingDateSource: routingDateSource,
                    proposedOwnerBucket: row["owner_bucket"],
                    ownerReason: row["owner_reason"],
                    ownerConfidence: row["owner_confidence"],
                    proposedCategory: row["category"],
                    proposedSubcategory: row["subcategory"],
                    baseDestPath: row["base_dest_path"],
                    resolvedDestPath: row["suggested_resolved_dest_path"],
                    matchedRuleId: row["matched_rule_id"],
                    classificationSource: row["classification_source"],
                    disposition: disposition,
                    reason: row["reason_code"]
                )
            }
        }
    }

    // MARK: - Proposed Moves Export

    private struct ProposedMovesExportRow: Sendable {
        let operationId: String
        let operationType: String
        let executionMode: String
        let sourcePath: String
        let baseDestPath: String
        let resolvedDestPath: String
        let ownerBucket: String?
        let ownerReason: String?
        let ownerConfidence: String?
        let category: String?
        let subcategory: String?
        let matchedRuleId: String?
        let classificationSource: String?
        let collisionResolved: Bool
        let conflictToken: String?
        let crossVolume: Bool
        let reason: String?

        var csvRow: [String?] {
            [
                operationId,
                operationType,
                executionMode,
                sourcePath,
                baseDestPath,
                resolvedDestPath,
                ownerBucket,
                ownerReason,
                ownerConfidence,
                category,
                subcategory,
                matchedRuleId,
                classificationSource,
                collisionResolved ? "true" : "false",
                conflictToken,
                crossVolume ? "true" : "false",
                reason
            ]
        }
    }

    private func fetchProposedMovesExportRows(planId: EntityID) async throws -> [ProposedMovesExportRow] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                      o.operation_id,
                      o.operation_type,
                      o.execution_mode,
                      i.relative_path,
                      r.path_at_scan,
                      o.base_dest_path,
                      o.resolved_dest_path,
                      p.owner_bucket,
                      p.owner_reason,
                      p.owner_confidence,
                      p.category,
                      p.subcategory,
                      p.matched_rule_id,
                      p.classification_source,
                      o.collision_resolved,
                      o.conflict_token,
                      o.cross_volume,
                      o.reason_code
                    FROM plan_operations o
                    JOIN inventory_items i
                      ON i.item_id = o.item_id
                    JOIN scan_source_roots r
                      ON r.scan_id = i.scan_id AND r.source_root_id = i.source_root_id
                    JOIN plan_items p
                      ON p.plan_id = o.plan_id AND p.item_id = o.item_id
                    WHERE o.plan_id = ?
                    ORDER BY o.sort_order
                    """,
                arguments: [planId.uuidString]
            )

            return rows.compactMap { row -> ProposedMovesExportRow? in
                guard let operationId = row["operation_id"] as String?,
                      let operationType = row["operation_type"] as String?,
                      let executionMode = row["execution_mode"] as String?,
                      let relativePath = row["relative_path"] as String?,
                      let pathAtScan = row["path_at_scan"] as String?,
                      let baseDestPath = row["base_dest_path"] as String?,
                      let resolvedDestPath = row["resolved_dest_path"] as String? else {
                    return nil
                }

                let sourcePath = (pathAtScan as NSString).appendingPathComponent(relativePath)
                return ProposedMovesExportRow(
                    operationId: operationId,
                    operationType: operationType,
                    executionMode: executionMode,
                    sourcePath: sourcePath,
                    baseDestPath: baseDestPath,
                    resolvedDestPath: resolvedDestPath,
                    ownerBucket: row["owner_bucket"],
                    ownerReason: row["owner_reason"],
                    ownerConfidence: row["owner_confidence"],
                    category: row["category"],
                    subcategory: row["subcategory"],
                    matchedRuleId: row["matched_rule_id"],
                    classificationSource: row["classification_source"],
                    collisionResolved: (row["collision_resolved"] as Int? ?? 0) == 1,
                    conflictToken: row["conflict_token"],
                    crossVolume: (row["cross_volume"] as Int? ?? 0) == 1,
                    reason: row["reason_code"]
                )
            }
        }
    }

    // MARK: - Needs Review Export

    private struct NeedsReviewExportRow: Sendable {
        let itemId: String
        let path: String
        let suggestedOwnerBucket: String?
        let suggestedBaseDestPath: String?
        let reason: String?
        let issueType: String?

        var csvRow: [String?] {
            [
                itemId,
                path,
                suggestedOwnerBucket,
                suggestedBaseDestPath,
                reason,
                issueType
            ]
        }
    }

    private func fetchNeedsReviewRows(planId: EntityID) async throws -> [NeedsReviewExportRow] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                      p.item_id,
                      i.relative_path,
                      r.path_at_scan,
                      p.owner_bucket,
                      p.base_dest_path,
                      p.reason_code,
                      p.issue_type
                    FROM plan_items p
                    JOIN inventory_items i
                      ON i.item_id = p.item_id
                    JOIN scan_source_roots r
                      ON r.scan_id = i.scan_id AND r.source_root_id = i.source_root_id
                    WHERE p.plan_id = ? AND p.disposition = ?
                    ORDER BY i.source_root_id, i.relative_path
                    """,
                arguments: [planId.uuidString, Disposition.needsReview.rawValue]
            )

            return rows.compactMap { row -> NeedsReviewExportRow? in
                guard let itemId = row["item_id"] as String?,
                      let relativePath = row["relative_path"] as String?,
                      let pathAtScan = row["path_at_scan"] as String? else {
                    return nil
                }

                let path = (pathAtScan as NSString).appendingPathComponent(relativePath)
                return NeedsReviewExportRow(
                    itemId: itemId,
                    path: path,
                    suggestedOwnerBucket: row["owner_bucket"],
                    suggestedBaseDestPath: row["base_dest_path"],
                    reason: row["reason_code"],
                    issueType: row["issue_type"]
                )
            }
        }
    }

    // MARK: - Excluded By Policy Export

    private struct ExcludedByPolicyExportRow: Sendable {
        let itemId: String
        let path: String
        let reason: String
        let policyType: String
        let sortKey: String

        var csvRow: [String?] {
            [itemId, path, reason, policyType]
        }
    }

    private func fetchExcludedByPolicyRows(plan: Plan) async throws -> [ExcludedByPolicyExportRow] {
        let planExcluded = try await fetchPlanExcludedRows(planId: plan.id)
        let scanExcluded = try await fetchScanExcludedRows(scanId: plan.scanId)

        let combined = (planExcluded + scanExcluded)
            .sorted { $0.sortKey < $1.sortKey }
        return combined
    }

    private func fetchPlanExcludedRows(planId: EntityID) async throws -> [ExcludedByPolicyExportRow] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                      p.item_id,
                      i.relative_path,
                      r.path_at_scan,
                      p.reason_code,
                      i.source_root_id
                    FROM plan_items p
                    JOIN inventory_items i
                      ON i.item_id = p.item_id
                    JOIN scan_source_roots r
                      ON r.scan_id = i.scan_id AND r.source_root_id = i.source_root_id
                    WHERE p.plan_id = ? AND p.disposition = ?
                    ORDER BY i.source_root_id, i.relative_path
                    """,
                arguments: [planId.uuidString, Disposition.excludedByPolicy.rawValue]
            )

            return rows.compactMap { row -> ExcludedByPolicyExportRow? in
                guard let itemId = row["item_id"] as String?,
                      let relativePath = row["relative_path"] as String?,
                      let pathAtScan = row["path_at_scan"] as String?,
                      let reason = row["reason_code"] as String?,
                      let sourceRootId = row["source_root_id"] as String? else {
                    return nil
                }

                let path = (pathAtScan as NSString).appendingPathComponent(relativePath)
                let policyType = reason.hasPrefix("PolicyExclude:") ? String(reason.dropFirst("PolicyExclude:".count)) : reason
                return ExcludedByPolicyExportRow(
                    itemId: itemId,
                    path: path,
                    reason: reason,
                    policyType: policyType,
                    sortKey: "\(sourceRootId)|\(relativePath)|\(reason)"
                )
            }
        }
    }

    private func fetchScanExcludedRows(scanId: EntityID) async throws -> [ExcludedByPolicyExportRow] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT scan_id, source_root_id, relative_path, absolute_path, reason
                    FROM scan_excluded_items
                    WHERE scan_id = ?
                    ORDER BY source_root_id, relative_path, reason
                    """,
                arguments: [scanId.uuidString]
            )

            return rows.compactMap { row -> ExcludedByPolicyExportRow? in
                guard let scanIdStr = row["scan_id"] as String?,
                      let sourceRootId = row["source_root_id"] as String?,
                      let relativePath = row["relative_path"] as String?,
                      let absolutePath = row["absolute_path"] as String?,
                      let reason = row["reason"] as String? else {
                    return nil
                }

                let input = "\(scanIdStr)|\(sourceRootId)|\(relativePath)|\(reason)"
                let hash = SHA256.hash(data: Data(input.utf8))
                let itemId = hash.prefix(8).map { String(format: "%02x", $0) }.joined()

                let policyType = reason.hasPrefix("PolicyExclude:") ? String(reason.dropFirst("PolicyExclude:".count)) : reason
                return ExcludedByPolicyExportRow(
                    itemId: itemId,
                    path: absolutePath,
                    reason: reason,
                    policyType: policyType,
                    sortKey: "\(sourceRootId)|\(relativePath)|\(reason)"
                )
            }
        }
    }

    // MARK: - Extension Report

    private struct ExtensionReportRow: Sendable {
        let fileExtension: String
        let count: Int
        let totalBytes: Int64

        var csvRow: [String?] {
            [
                fileExtension,
                String(count),
                String(totalBytes)
            ]
        }
    }

    private func fetchExtensionReportRows(scanId: EntityID) async throws -> [ExtensionReportRow] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                      LOWER(CASE
                        WHEN extension IS NULL OR extension = '' THEN '(none)'
                        ELSE extension
                      END) AS ext,
                      COUNT(*) AS item_count,
                      SUM(size_bytes) AS total_bytes
                    FROM inventory_items
                    WHERE scan_id = ?
                    GROUP BY ext
                    ORDER BY total_bytes DESC, item_count DESC, ext ASC
                    """,
                arguments: [scanId.uuidString]
            )

            return rows.compactMap { row -> ExtensionReportRow? in
                guard let ext = row["ext"] as String?,
                      let count = row["item_count"] as Int?,
                      let totalBytes = row["total_bytes"] as Int64? else {
                    return nil
                }
                return ExtensionReportRow(fileExtension: ext, count: count, totalBytes: totalBytes)
            }
        }
    }

    // MARK: - CSV Writing

    private enum ExportError: Error {
        case planNotFound(planId: EntityID)
    }

    private func writeCSV(url: URL, header: [String], rows: [[String?]]) throws {
        var lines: [String] = []
        lines.reserveCapacity(rows.count + 1)
        lines.append(header.map(csvEscape).joined(separator: ","))
        for row in rows {
            lines.append(row.map { csvEscape($0 ?? "") }.joined(separator: ","))
        }
        let content = lines.joined(separator: "\n") + "\n"
        try Data(content.utf8).write(to: url, options: .atomic)
    }

    private func csvEscape(_ value: String) -> String {
        if value.contains("\"") || value.contains(",") || value.contains("\n") || value.contains("\r") {
            let escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return value
    }

    private static func formatDate(_ date: Date) -> String {
        Self.iso8601Formatter.string(from: date)
    }

    private static let iso8601Formatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
