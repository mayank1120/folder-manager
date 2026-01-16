import Foundation

public enum VerificationIssue: String, Codable, Sendable {
    case notCompleted = "NotCompleted"
    case destinationMissing = "DestinationMissing"
    case sizeMismatch = "SizeMismatch"
}

public struct VerificationFailure: Sendable {
    public let operationId: String
    public let itemId: String
    public let expectedPath: String
    public let issue: VerificationIssue
    public let expectedSizeBytes: Int64
    public let actualSizeBytes: Int64?
    public let detail: String?

    public init(
        operationId: String,
        itemId: String,
        expectedPath: String,
        issue: VerificationIssue,
        expectedSizeBytes: Int64,
        actualSizeBytes: Int64? = nil,
        detail: String? = nil
    ) {
        self.operationId = operationId
        self.itemId = itemId
        self.expectedPath = expectedPath
        self.issue = issue
        self.expectedSizeBytes = expectedSizeBytes
        self.actualSizeBytes = actualSizeBytes
        self.detail = detail
    }
}

public struct VerificationResult: Sendable {
    public let planId: EntityID
    public let plannedCount: Int
    public let completedCount: Int
    public let skippedCount: Int
    public let failedCount: Int
    public let plannedBytes: Int64
    public let verifiedBytes: Int64
    public let passed: Bool
    public let failures: [VerificationFailure]

    public init(
        planId: EntityID,
        plannedCount: Int,
        completedCount: Int,
        skippedCount: Int,
        failedCount: Int,
        plannedBytes: Int64,
        verifiedBytes: Int64,
        passed: Bool,
        failures: [VerificationFailure]
    ) {
        self.planId = planId
        self.plannedCount = plannedCount
        self.completedCount = completedCount
        self.skippedCount = skippedCount
        self.failedCount = failedCount
        self.plannedBytes = plannedBytes
        self.verifiedBytes = verifiedBytes
        self.passed = passed
        self.failures = failures
    }
}

public struct VerifyEngine: Sendable {
    private let planStore: PlanStore
    private let journalStore: JournalStore

    public init(dbManager: DatabaseManager) {
        self.planStore = PlanStore(dbManager: dbManager)
        self.journalStore = JournalStore(dbManager: dbManager)
    }

    public func verify(planId: EntityID) async throws -> VerificationResult {
        let rows = try await planStore.fetchPlanOperationExecutionRows(planId: planId)
        let plannedCount = rows.count

        let states = try await journalStore.fetchAllStates(planId: planId)
        let stateByOperationId = Dictionary(uniqueKeysWithValues: states.map { ($0.operationId, $0) })

        var completedCount = 0
        var skippedCount = 0
        var failedCount = 0
        var plannedBytes: Int64 = 0
        var verifiedBytes: Int64 = 0
        var failures: [VerificationFailure] = []
        failures.reserveCapacity(rows.count / 10)

        let packageDetector = PackageDetector()

        for row in rows {
            let op = row.operation
            plannedBytes += row.expectedSizeBytes

            guard let state = stateByOperationId[op.operationId] else {
                failures.append(
                    VerificationFailure(
                        operationId: op.operationId,
                        itemId: op.itemId,
                        expectedPath: op.resolvedDestPath,
                        issue: .notCompleted,
                        expectedSizeBytes: row.expectedSizeBytes,
                        detail: "No journal_state row for operation"
                    )
                )
                failedCount += 1
                continue
            }

            switch state.currentState {
            case .completed:
                break
            case .skipped:
                skippedCount += 1
                failures.append(
                    VerificationFailure(
                        operationId: op.operationId,
                        itemId: op.itemId,
                        expectedPath: op.resolvedDestPath,
                        issue: .notCompleted,
                        expectedSizeBytes: row.expectedSizeBytes,
                        detail: "Operation was skipped"
                    )
                )
                continue
            case .failed, .planned, .started:
                failures.append(
                    VerificationFailure(
                        operationId: op.operationId,
                        itemId: op.itemId,
                        expectedPath: op.resolvedDestPath,
                        issue: .notCompleted,
                        expectedSizeBytes: row.expectedSizeBytes,
                        detail: "Journal state: \(state.currentState.rawValue)"
                    )
                )
                failedCount += 1
                continue
            }

            let destURL = URL(fileURLWithPath: op.resolvedDestPath)
            guard FileManager.default.fileExists(atPath: destURL.path) else {
                failures.append(
                    VerificationFailure(
                        operationId: op.operationId,
                        itemId: op.itemId,
                        expectedPath: destURL.path,
                        issue: .destinationMissing,
                        expectedSizeBytes: row.expectedSizeBytes
                    )
                )
                failedCount += 1
                continue
            }

            let actualSize: Int64
            if row.isPackage {
                actualSize = packageDetector.computePackageSize(at: destURL)
            } else {
                let size = (try? destURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
                actualSize = Int64(size)
            }

            if actualSize != row.expectedSizeBytes {
                failures.append(
                    VerificationFailure(
                        operationId: op.operationId,
                        itemId: op.itemId,
                        expectedPath: destURL.path,
                        issue: .sizeMismatch,
                        expectedSizeBytes: row.expectedSizeBytes,
                        actualSizeBytes: actualSize
                    )
                )
                failedCount += 1
                continue
            }

            completedCount += 1
            verifiedBytes += actualSize
        }

        let passed = failures.isEmpty && completedCount == plannedCount

        return VerificationResult(
            planId: planId,
            plannedCount: plannedCount,
            completedCount: completedCount,
            skippedCount: skippedCount,
            failedCount: failedCount,
            plannedBytes: plannedBytes,
            verifiedBytes: verifiedBytes,
            passed: passed,
            failures: failures
        )
    }

    public func writeCSV(result: VerificationResult, to url: URL) throws {
        let header = [
            "operationId",
            "itemId",
            "expectedPath",
            "issue",
            "expectedSizeBytes",
            "actualSizeBytes",
            "detail"
        ]

        var lines: [String] = []
        lines.reserveCapacity(result.failures.count + 1)
        lines.append(header.map(csvEscape).joined(separator: ","))

        for failure in result.failures {
            let row: [String?] = [
                failure.operationId,
                failure.itemId,
                failure.expectedPath,
                failure.issue.rawValue,
                String(failure.expectedSizeBytes),
                failure.actualSizeBytes.map(String.init),
                failure.detail
            ]
            lines.append(row.map(csvEscape).joined(separator: ","))
        }

        let data = lines.joined(separator: "\n").appending("\n").data(using: .utf8) ?? Data()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: [.atomic])
    }

    private func csvEscape(_ value: String?) -> String {
        guard let value else { return "" }
        let needsQuotes = value.contains(",") || value.contains("\"") || value.contains("\n") || value.contains("\r")
        var escaped = value.replacingOccurrences(of: "\"", with: "\"\"")
        if needsQuotes {
            escaped = "\"\(escaped)\""
        }
        return escaped
    }
}
