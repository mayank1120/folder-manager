import Foundation
import GRDB

/// SQLite-backed store for execution journal (delete-originals, rollback operations).
public struct ExecutionJournalStore: Sendable {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    public func saveEntry(_ entry: ExecutionJournalEntry) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO execution_journal
                    (plan_id, execution_op_id, operation_type, source_operation_id,
                     current_state, last_updated, item_id, source_path, dest_path,
                     archive_path, error)
                    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    entry.planId.uuidString,
                    entry.executionOpId,
                    entry.operationType.rawValue,
                    entry.sourceOperationId,
                    entry.currentState.rawValue,
                    entry.lastUpdated,
                    entry.itemId,
                    entry.sourcePath,
                    entry.destPath,
                    entry.archivePath,
                    entry.error
                ]
            )
        }
    }

    public func fetchEntries(planId: EntityID) async throws -> [ExecutionJournalEntry] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM execution_journal
                    WHERE plan_id = ?
                    ORDER BY last_updated ASC
                    """,
                arguments: [planId.uuidString]
            )
            return rows.compactMap { Self.parseRow($0, planId: planId) }
        }
    }

    public func fetchEntriesByType(
        planId: EntityID,
        operationType: ExecutionOperationType
    ) async throws -> [ExecutionJournalEntry] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM execution_journal
                    WHERE plan_id = ? AND operation_type = ?
                    ORDER BY last_updated ASC
                    """,
                arguments: [planId.uuidString, operationType.rawValue]
            )
            return rows.compactMap { Self.parseRow($0, planId: planId) }
        }
    }

    public func fetchEntry(
        planId: EntityID,
        executionOpId: String
    ) async throws -> ExecutionJournalEntry? {
        try await dbManager.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT * FROM execution_journal
                    WHERE plan_id = ? AND execution_op_id = ?
                    """,
                arguments: [planId.uuidString, executionOpId]
            ) else {
                return nil
            }
            return Self.parseRow(row, planId: planId)
        }
    }

    /// Fetch all completed delete operations for a plan (for rollback).
    public func fetchCompletedDeleteOperations(planId: EntityID) async throws -> [ExecutionJournalEntry] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT * FROM execution_journal
                    WHERE plan_id = ?
                      AND operation_type IN (?, ?)
                      AND current_state = ?
                    ORDER BY last_updated DESC
                    """,
                arguments: [
                    planId.uuidString,
                    ExecutionOperationType.trashOriginal.rawValue,
                    ExecutionOperationType.archiveOriginal.rawValue,
                    OperationState.completed.rawValue
                ]
            )
            return rows.compactMap { Self.parseRow($0, planId: planId) }
        }
    }

    private static func parseRow(_ row: Row, planId: EntityID) -> ExecutionJournalEntry? {
        guard let executionOpId = row["execution_op_id"] as String?,
              let operationTypeStr = row["operation_type"] as String?,
              let operationType = ExecutionOperationType(rawValue: operationTypeStr),
              let currentStateStr = row["current_state"] as String?,
              let currentState = OperationState(rawValue: currentStateStr),
              let lastUpdated = row["last_updated"] as Int64? else {
            return nil
        }

        return ExecutionJournalEntry(
            planId: planId,
            executionOpId: executionOpId,
            operationType: operationType,
            sourceOperationId: row["source_operation_id"],
            currentState: currentState,
            lastUpdated: lastUpdated,
            itemId: row["item_id"],
            sourcePath: row["source_path"],
            destPath: row["dest_path"],
            archivePath: row["archive_path"],
            error: row["error"]
        )
    }
}
