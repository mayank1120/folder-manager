import Foundation

/// Reads a JSONL journal file (append-only) for a plan.
public struct JournalReader: Sendable {
    private let decoder: JSONDecoder

    public init() {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        self.decoder = decoder
    }

    /// Returns a map of `operationId -> copyStatAtTime` for `copyItem` operations.
    ///
    /// The journal may contain the `copyStatAtTime` on either a `.started` or `.completed` entry,
    /// depending on where a crash/resume occurred. This method returns the first stat observed.
    public func copyStatsByOperationId(from journalFileURL: URL) throws -> [String: FileStat] {
        guard FileManager.default.fileExists(atPath: journalFileURL.path) else {
            return [:]
        }

        let handle = try FileHandle(forReadingFrom: journalFileURL)
        defer { try? handle.close() }

        var result: [String: FileStat] = [:]

        var buffer = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<newlineIndex)
                buffer.removeSubrange(0...newlineIndex)

                if lineData.isEmpty {
                    continue
                }

                if let entry = try? decoder.decode(JournalEntry.self, from: lineData),
                   entry.operationType == .copyItem,
                   let stat = entry.copyStatAtTime,
                   result[entry.operationId] == nil
                {
                    result[entry.operationId] = stat
                }
            }
        }

        if !buffer.isEmpty {
            if let entry = try? decoder.decode(JournalEntry.self, from: buffer),
               entry.operationType == .copyItem,
               let stat = entry.copyStatAtTime,
               result[entry.operationId] == nil
            {
                result[entry.operationId] = stat
            }
        }

        return result
    }
    
    /// Returns a map of `operationId -> tagsBefore` for `applyTags` operations.
    ///
    /// Used by rollback to restore tags to their prior state.
    public func tagsBeforeByOperationId(from journalFileURL: URL) throws -> [String: [String]] {
        guard FileManager.default.fileExists(atPath: journalFileURL.path) else {
            return [:]
        }

        let handle = try FileHandle(forReadingFrom: journalFileURL)
        defer { try? handle.close() }

        var result: [String: [String]] = [:]

        var buffer = Data()
        while let chunk = try handle.read(upToCount: 64 * 1024), !chunk.isEmpty {
            buffer.append(chunk)

            while let newlineIndex = buffer.firstIndex(of: 0x0A) {
                let lineData = buffer.subdata(in: 0..<newlineIndex)
                buffer.removeSubrange(0...newlineIndex)

                if lineData.isEmpty {
                    continue
                }

                if let entry = try? decoder.decode(JournalEntry.self, from: lineData),
                   entry.operationType == .applyTags,
                   let tagsBefore = entry.tagsBefore,
                   result[entry.operationId] == nil
                {
                    result[entry.operationId] = tagsBefore
                }
            }
        }

        if !buffer.isEmpty {
            if let entry = try? decoder.decode(JournalEntry.self, from: buffer),
               entry.operationType == .applyTags,
               let tagsBefore = entry.tagsBefore,
               result[entry.operationId] == nil
            {
                result[entry.operationId] = tagsBefore
            }
        }

        return result
    }
}
