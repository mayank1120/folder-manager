import Foundation
import CryptoKit

public struct SettingsHasher: Sendable {
    public init() {}

    public func hash(project: Project) -> String {
        var components: [String] = []

        let settings = project.settings
        components.append("autoFileUnassigned=\(settings.autoFileUnassigned)")
        components.append("autoFileShared=\(settings.autoFileShared)")
        components.append("executionMode=\(settings.executionMode.rawValue)")
        components.append("collisionPolicy=\(settings.collisionPolicy.rawValue)")
        components.append("deleteOriginalsMode=\(settings.deleteOriginalsMode.rawValue)")
        components.append("downloadBeforeProcessing=\(settings.downloadBeforeProcessing)")
        components.append("enableOtherBucket=\(settings.enableOtherBucket)")
        components.append("tagsEnabled=\(settings.tagsEnabled)")

        components.append("tagNames=\(normalizeList(settings.tagNames).joined(separator: ","))")
        components.append("screenshotPrefixes=\(normalizeList(settings.screenshotPrefixes).joined(separator: ","))")
        components.append("cameraPrefixes=\(normalizeList(settings.cameraPrefixes).joined(separator: ","))")
        components.append("projectMarkers=\(normalizeList(settings.projectMarkers).joined(separator: ","))")

        let people = project.people.sorted { $0.id.uuidString < $1.id.uuidString }
        for person in people {
            let tokens = normalizeList(person.keywordTokens)
            components.append("person=\(person.id.uuidString):\(tokens.joined(separator: ","))")
        }
        
        let sourceRoots = project.sourceRoots.sorted { $0.id.uuidString < $1.id.uuidString }
        components.append("sourceRootIds=\(sourceRoots.map { $0.id.uuidString }.joined(separator: ","))")

        if let dest = project.destinationRoot?.path {
            components.append("destinationRoot=\(canonicalPath(dest))")
        } else {
            components.append("destinationRoot=")
        }

        let input = components.joined(separator: "\n")
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    private func normalizeList(_ values: [String]) -> [String] {
        let normalized = values
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return Array(Set(normalized)).sorted()
    }

    private func canonicalPath(_ path: String) -> String {
        URL(fileURLWithPath: path).standardizedFileURL.path
    }
}
