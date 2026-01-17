import Foundation
import GRDB

public struct PlanStore: Sendable {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    public func createPlan(_ plan: Plan, items: [PlanItem], operations: [PlanOperation]) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO plans
                    (plan_id, scan_id, project_id, created_at, settings_hash, operation_count, journal_path)
                    VALUES (?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    plan.id.uuidString,
                    plan.scanId.uuidString,
                    plan.projectId.uuidString,
                    Int64(plan.createdAt.timeIntervalSince1970),
                    plan.settingsHash,
                    plan.operationCount,
                    plan.journalPath
                ]
            )

            for item in items {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO plan_items
                        (plan_id, item_id, disposition, owner_bucket, owner_reason, owner_confidence,
                         category, subcategory, base_dest_path, suggested_resolved_dest_path,
                         reason_code, issue_type, matched_rule_id, classification_source)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        item.planId.uuidString,
                        item.itemId,
                        item.disposition.rawValue,
                        item.ownerBucket,
                        item.ownerReason,
                        item.ownerConfidence?.rawValue,
                        item.category,
                        item.subcategory,
                        item.baseDestPath,
                        item.suggestedResolvedDestPath,
                        item.reasonCode,
                        item.issueType,
                        item.matchedRuleId,
                        item.classificationSource?.rawValue
                    ]
                )
            }

            for op in operations {
                try db.execute(
                    sql: """
                        INSERT OR REPLACE INTO plan_operations
                        (plan_id, operation_id, item_id, operation_type, execution_mode,
                         base_dest_path, resolved_dest_path, collision_resolved, conflict_token,
                         cross_volume, reason_code, sort_order)
                        VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                        """,
                    arguments: [
                        op.planId.uuidString,
                        op.operationId,
                        op.itemId,
                        op.operationType.rawValue,
                        op.executionMode.rawValue,
                        op.baseDestPath,
                        op.resolvedDestPath,
                        op.collisionResolved ? 1 : 0,
                        op.conflictToken,
                        op.crossVolume ? 1 : 0,
                        op.reasonCode,
                        op.sortOrder
                    ]
                )
            }
        }
    }

    public func fetchPlan(id planId: EntityID) async throws -> Plan? {
        try await dbManager.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: "SELECT * FROM plans WHERE plan_id = ?",
                arguments: [planId.uuidString]
            ) else {
                return nil
            }

            guard let scanIdStr = row["scan_id"] as String?,
                  let scanId = UUID(uuidString: scanIdStr),
                  let projectIdStr = row["project_id"] as String?,
                  let projectId = UUID(uuidString: projectIdStr),
                  let createdAtEpoch = row["created_at"] as Int64?,
                  let settingsHash = row["settings_hash"] as String?,
                  let operationCount = row["operation_count"] as Int?,
                  let journalPath = row["journal_path"] as String? else {
                return nil
            }

            return Plan(
                id: planId,
                scanId: scanId,
                projectId: projectId,
                createdAt: Date(timeIntervalSince1970: TimeInterval(createdAtEpoch)),
                settingsHash: settingsHash,
                operationCount: operationCount,
                journalPath: journalPath
            )
        }
    }

    // MARK: - Apply / Verify Queries

    public struct PlanOperationExecutionRow: Sendable {
        public let operation: PlanOperation
        public let sourceRootId: EntityID
        public let sourceRootPathAtScan: String
        public let relativePath: String
        public let expectedSizeBytes: Int64
        public let expectedModifiedTime: Date
        public let isPackage: Bool

        public var sourcePathAtScan: String {
            (sourceRootPathAtScan as NSString).appendingPathComponent(relativePath)
        }
    }

    public func fetchPlanOperationExecutionRows(planId: EntityID) async throws -> [PlanOperationExecutionRow] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                      o.operation_id,
                      o.item_id,
                      o.operation_type,
                      o.execution_mode,
                      o.base_dest_path,
                      o.resolved_dest_path,
                      o.collision_resolved,
                      o.conflict_token,
                      o.cross_volume,
                      o.reason_code,
                      o.sort_order,
                      i.source_root_id,
                      i.relative_path,
                      i.is_package,
                      i.size_bytes,
                      i.modified_time,
                      r.path_at_scan
                    FROM plan_operations o
                    JOIN inventory_items i
                      ON i.item_id = o.item_id
                    JOIN plans p
                      ON p.plan_id = o.plan_id
                    JOIN scan_source_roots r
                      ON r.scan_id = p.scan_id AND r.source_root_id = i.source_root_id
                    WHERE o.plan_id = ?
                    ORDER BY o.sort_order
                    """,
                arguments: [planId.uuidString]
            )

            return rows.compactMap { row -> PlanOperationExecutionRow? in
                guard let operationId = row["operation_id"] as String?,
                      let itemId = row["item_id"] as String?,
                      let operationTypeStr = row["operation_type"] as String?,
                      let operationType = PlanOperationType(rawValue: operationTypeStr),
                      let executionModeStr = row["execution_mode"] as String?,
                      let executionMode = ExecutionMode(rawValue: executionModeStr),
                      let baseDestPath = row["base_dest_path"] as String?,
                      let resolvedDestPath = row["resolved_dest_path"] as String?,
                      let sortOrder = row["sort_order"] as Int?,
                      let sourceRootIdStr = row["source_root_id"] as String?,
                      let sourceRootId = UUID(uuidString: sourceRootIdStr),
                      let relativePath = row["relative_path"] as String?,
                      let sizeBytes = row["size_bytes"] as Int64?,
                      let modifiedTimeEpoch = row["modified_time"] as Int64?,
                      let pathAtScan = row["path_at_scan"] as String? else {
                    return nil
                }

                let op = PlanOperation(
                    operationId: operationId,
                    planId: planId,
                    itemId: itemId,
                    operationType: operationType,
                    executionMode: executionMode,
                    baseDestPath: baseDestPath,
                    resolvedDestPath: resolvedDestPath,
                    collisionResolved: (row["collision_resolved"] as Int? ?? 0) == 1,
                    conflictToken: row["conflict_token"],
                    crossVolume: (row["cross_volume"] as Int? ?? 0) == 1,
                    reasonCode: (row["reason_code"] as String?) ?? "",
                    sortOrder: sortOrder
                )

                return PlanOperationExecutionRow(
                    operation: op,
                    sourceRootId: sourceRootId,
                    sourceRootPathAtScan: pathAtScan,
                    relativePath: relativePath,
                    expectedSizeBytes: sizeBytes,
                    expectedModifiedTime: Date(timeIntervalSince1970: TimeInterval(modifiedTimeEpoch)),
                    isPackage: (row["is_package"] as Int? ?? 0) == 1
                )
            }
        }
    }
    
    // MARK: - Plan Item Queries
    
    /// A row structure for displaying plan items in the UI
    public struct PlanItemRow: Sendable {
        public let planItem: PlanItem
        public let relativePath: String
        public let isPackage: Bool
    }

    public struct ExtensionReportRow: Sendable, Hashable {
        public let fileExtension: String
        public let count: Int
        public let totalBytes: Int64
    }
    
    /// Fetch plan items with their file paths for a given disposition
    public func fetchPlanItemRows(planId: EntityID, disposition: Disposition) async throws -> [PlanItemRow] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT
                      pi.*,
                      ii.relative_path,
                      ii.is_package
                    FROM plan_items pi
                    JOIN inventory_items ii ON pi.item_id = ii.item_id
                    WHERE pi.plan_id = ? AND pi.disposition = ?
                    ORDER BY ii.relative_path
                    """,
                arguments: [planId.uuidString, disposition.rawValue]
            )
            
            return rows.compactMap { row -> PlanItemRow? in
                guard let itemId = row["item_id"] as String?,
                      let dispositionRaw = row["disposition"] as String?,
                      let disposition = Disposition(rawValue: dispositionRaw),
                      let relativePath = row["relative_path"] as String? else {
                    return nil
                }
                
                let planIdFromRow = planId // We already know the planId
                
                let planItem = PlanItem(
                    planId: planIdFromRow,
                    itemId: itemId,
                    disposition: disposition,
                    ownerBucket: row["owner_bucket"] as String?,
                    ownerReason: row["owner_reason"] as String?,
                    ownerConfidence: (row["owner_confidence"] as String?).flatMap { OwnerConfidence(rawValue: $0) },
                    category: row["category"] as String?,
                    subcategory: row["subcategory"] as String?,
                    baseDestPath: row["base_dest_path"] as String?,
                    suggestedResolvedDestPath: row["suggested_resolved_dest_path"] as String?,
                    reasonCode: row["reason_code"] as String?,
                    issueType: row["issue_type"] as String?,
                    matchedRuleId: row["matched_rule_id"] as String?,
                    classificationSource: (row["classification_source"] as String?).flatMap { ClassificationSource(rawValue: $0) }
                )
                
                return PlanItemRow(
                    planItem: planItem,
                    relativePath: relativePath,
                    isPackage: (row["is_package"] as Int? ?? 0) == 1
                )
            }
        }
    }

    public func fetchExtensionReport(scanId: EntityID) async throws -> [ExtensionReportRow] {
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
}
