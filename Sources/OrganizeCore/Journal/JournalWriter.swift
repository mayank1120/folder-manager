import Foundation

/// Crash-safe append-only journal writer (JSONL), with a SQLite index for fast resume.
public actor JournalWriter {
    private let planId: EntityID
    private let journalFileURL: URL
    private let journalStore: JournalStore
    private let encoder: JSONEncoder

    private var fileHandle: FileHandle?

    public init(planId: EntityID, journalFileURL: URL, journalStore: JournalStore) throws {
        self.planId = planId
        self.journalFileURL = journalFileURL
        self.journalStore = journalStore

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        self.encoder = encoder

        try Self.prepareFile(url: journalFileURL)
        self.fileHandle = try FileHandle(forWritingTo: journalFileURL)
    }

    deinit {
        try? fileHandle?.close()
    }

    public func append(_ entry: JournalEntry) async throws {
        guard entry.planId == planId else {
            throw JournalError.planIdMismatch(expected: planId, actual: entry.planId)
        }

        switch entry.operationType {
        case .copyItem, .moveItem, .applyTags:
            break
        default:
            throw JournalError.unsupportedOperationType(entry.operationType)
        }

        let data = try encoder.encode(entry)
        var line = Data()
        line.reserveCapacity(data.count + 1)
        line.append(data)
        line.append(0x0A) // "\n"

        try openFileHandleIfNeeded()
        guard let handle = fileHandle else {
            throw JournalError.fileHandleUnavailable
        }

        try handle.seekToEnd()
        try handle.write(contentsOf: line)
        try handle.synchronize()

        let state = JournalState(
            planId: entry.planId,
            operationId: entry.operationId,
            currentState: entry.state,
            lastUpdated: entry.timestamp,
            tempPath: entry.tempPath,
            phase: entry.phase
        )
        try await journalStore.saveState(state)
    }

    public func currentState(operationId: String) async throws -> JournalState? {
        try await journalStore.fetchState(planId: planId, operationId: operationId)
    }

    private func openFileHandleIfNeeded() throws {
        if fileHandle != nil {
            return
        }
        fileHandle = try FileHandle(forWritingTo: journalFileURL)
    }

    private static func prepareFile(url: URL) throws {
        let dir = url.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        if !FileManager.default.fileExists(atPath: url.path) {
            FileManager.default.createFile(atPath: url.path, contents: nil)
        }
    }

    public enum JournalError: Error {
        case planIdMismatch(expected: EntityID, actual: EntityID)
        case unsupportedOperationType(ExecutionOperationType)
        case fileHandleUnavailable
    }
}
