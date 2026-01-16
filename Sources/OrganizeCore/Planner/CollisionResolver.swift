import Foundation
import CryptoKit

public struct CollisionCandidate: Sendable, Hashable {
    public let itemId: String
    public let sourcePath: String
    public let baseDestPath: String
    public let sizeBytes: Int64
    public let modifiedTime: Date

    public init(itemId: String, sourcePath: String, baseDestPath: String, sizeBytes: Int64, modifiedTime: Date) {
        self.itemId = itemId
        self.sourcePath = sourcePath
        self.baseDestPath = baseDestPath
        self.sizeBytes = sizeBytes
        self.modifiedTime = modifiedTime
    }
}

public struct CollisionResolution: Sendable, Hashable {
    public let itemId: String
    public let resolvedDestPath: String
    public let collisionResolved: Bool
    public let conflictToken: String?
}

public struct CollisionResolver: Sendable {
    public typealias FileExists = @Sendable (String) -> Bool

    private let fileExists: FileExists

    public init(fileExists: @escaping FileExists = { FileManager.default.fileExists(atPath: $0) }) {
        self.fileExists = fileExists
    }

    public func resolve(candidates: [CollisionCandidate]) -> [CollisionResolution] {
        let grouped = Dictionary(grouping: candidates, by: \.baseDestPath)
        var usedPaths: Set<String> = []

        var results: [CollisionResolution] = []
        results.reserveCapacity(candidates.count)

        let sortedBasePaths = grouped.keys.sorted()
        for basePath in sortedBasePaths {
            guard var group = grouped[basePath] else { continue }
            group.sort { $0.sourcePath < $1.sourcePath }

            for (index, candidate) in group.enumerated() {
                let resolved: CollisionResolution
                if index == 0 {
                    resolved = resolveFirst(candidate: candidate, usedPaths: &usedPaths)
                } else {
                    resolved = resolveWithSuffix(candidate: candidate, usedPaths: &usedPaths)
                }
                results.append(resolved)
            }
        }

        return results
    }

    private func resolveFirst(candidate: CollisionCandidate, usedPaths: inout Set<String>) -> CollisionResolution {
        let base = candidate.baseDestPath
        if !usedPaths.contains(base) && !fileExists(base) {
            usedPaths.insert(base)
            return CollisionResolution(itemId: candidate.itemId, resolvedDestPath: base, collisionResolved: false, conflictToken: nil)
        }
        return resolveWithSuffix(candidate: candidate, usedPaths: &usedPaths)
    }

    private func resolveWithSuffix(candidate: CollisionCandidate, usedPaths: inout Set<String>) -> CollisionResolution {
        let destDirectory = URL(fileURLWithPath: candidate.baseDestPath).deletingLastPathComponent().path
        let token = conflictToken(sourcePath: candidate.sourcePath, sizeBytes: candidate.sizeBytes, modifiedTime: candidate.modifiedTime, destDirectory: destDirectory)
        var attempt = applyConflictToken(baseDestPath: candidate.baseDestPath, token: token, sequence: nil)

        var suffixIndex = 2
        while usedPaths.contains(attempt) || fileExists(attempt) {
            attempt = applyConflictToken(baseDestPath: candidate.baseDestPath, token: token, sequence: suffixIndex)
            suffixIndex += 1
        }

        usedPaths.insert(attempt)
        return CollisionResolution(itemId: candidate.itemId, resolvedDestPath: attempt, collisionResolved: true, conflictToken: token)
    }

    private func conflictToken(sourcePath: String, sizeBytes: Int64, modifiedTime: Date, destDirectory: String) -> String {
        let modifiedEpoch = Int64(modifiedTime.timeIntervalSince1970)
        let input = "\(sourcePath)|\(sizeBytes)|\(modifiedEpoch)|\(destDirectory)"
        let hash = SHA256.hash(data: Data(input.utf8))
        let hex = hash.map { String(format: "%02X", $0) }.joined()
        return String(hex.prefix(6))
    }

    private func applyConflictToken(baseDestPath: String, token: String, sequence: Int?) -> String {
        let url = URL(fileURLWithPath: baseDestPath)
        let directory = url.deletingLastPathComponent()
        let fileName = url.lastPathComponent

        let ext = url.pathExtension
        let baseName: String
        if ext.isEmpty {
            baseName = fileName
        } else {
            baseName = String(fileName.dropLast(ext.count + 1))
        }

        let suffix = sequence.map { "-\($0)" } ?? ""
        let newName = "\(baseName) (conflict-\(token))\(suffix)" + (ext.isEmpty ? "" : ".\(ext)")
        return directory.appendingPathComponent(newName).path
    }
}

