import Foundation
import GRDB

/// SQLite-backed index of journal state for fast resume queries.
///
/// Source of truth remains the append-only JSONL journal file.
public struct JournalStore: Sendable {
    private let dbManager: DatabaseManager

    public init(dbManager: DatabaseManager) {
        self.dbManager = dbManager
    }

    public func saveState(_ state: JournalState) async throws {
        try await dbManager.write { db in
            try db.execute(
                sql: """
                    INSERT OR REPLACE INTO journal_state
                    (plan_id, operation_id, current_state, last_updated, temp_path, phase)
                    VALUES (?, ?, ?, ?, ?, ?)
                    """,
                arguments: [
                    state.planId.uuidString,
                    state.operationId,
                    state.currentState.rawValue,
                    state.lastUpdated,
                    state.tempPath,
                    state.phase
                ]
            )
        }
    }

    public func fetchState(planId: EntityID, operationId: String) async throws -> JournalState? {
        try await dbManager.read { db in
            guard let row = try Row.fetchOne(
                db,
                sql: """
                    SELECT current_state, last_updated, temp_path, phase
                    FROM journal_state
                    WHERE plan_id = ? AND operation_id = ?
                    """,
                arguments: [planId.uuidString, operationId]
            ) else {
                return nil
            }

            guard let stateStr = row["current_state"] as String?,
                  let currentState = OperationState(rawValue: stateStr),
                  let lastUpdated = row["last_updated"] as Int64? else {
                return nil
            }

            return JournalState(
                planId: planId,
                operationId: operationId,
                currentState: currentState,
                lastUpdated: lastUpdated,
                tempPath: row["temp_path"],
                phase: row["phase"]
            )
        }
    }

    public func fetchAllStates(planId: EntityID) async throws -> [JournalState] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT operation_id, current_state, last_updated, temp_path, phase
                    FROM journal_state
                    WHERE plan_id = ?
                    ORDER BY operation_id
                    """,
                arguments: [planId.uuidString]
            )

            return rows.compactMap { row -> JournalState? in
                guard let operationId = row["operation_id"] as String?,
                      let stateStr = row["current_state"] as String?,
                      let currentState = OperationState(rawValue: stateStr),
                      let lastUpdated = row["last_updated"] as Int64? else {
                    return nil
                }

                return JournalState(
                    planId: planId,
                    operationId: operationId,
                    currentState: currentState,
                    lastUpdated: lastUpdated,
                    tempPath: row["temp_path"],
                    phase: row["phase"]
                )
            }
        }
    }

    /// Returns operation IDs that are not in a terminal state.
    ///
    /// Terminal states: completed, failed, skipped.
    public func fetchPendingOperationIds(planId: EntityID) async throws -> [String] {
        try await dbManager.read { db in
            let rows = try Row.fetchAll(
                db,
                sql: """
                    SELECT o.operation_id
                    FROM plan_operations o
                    LEFT JOIN journal_state j
                      ON j.plan_id = o.plan_id AND j.operation_id = o.operation_id
                    WHERE o.plan_id = ?
                      AND (
                        j.current_state IS NULL OR
                        j.current_state IN (?, ?)
                      )
                    ORDER BY o.sort_order
                    """,
                arguments: [
                    planId.uuidString,
                    OperationState.planned.rawValue,
                    OperationState.started.rawValue
                ]
            )
            return rows.compactMap { $0["operation_id"] as String? }
        }
    }
}

