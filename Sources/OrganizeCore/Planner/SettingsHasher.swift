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
        components.append("ownerMatching.camelCase=\(settings.ownerMatching.enableCamelCaseSplit)")
        components.append("ownerMatching.digitSplit=\(settings.ownerMatching.enableDigitSplit)")

        components.append("tagNames=\(normalizeList(settings.tagNames).joined(separator: ","))")
        components.append("screenshotPrefixes=\(normalizeList(settings.screenshotPrefixes).joined(separator: ","))")
        components.append("cameraPrefixes=\(normalizeList(settings.cameraPrefixes).joined(separator: ","))")
        components.append("projectMarkers=\(normalizeList(settings.projectMarkers).joined(separator: ","))")
        components.append("extensionExcludeMode=\(settings.extensionExclusions.excludeMode.rawValue)")
        components.append("extensionExcluded=\(normalizeExtensions(settings.extensionExclusions.excludedExtensions).joined(separator: ","))")

        let rules = settings.extensionRules.sorted { lhs, rhs in
            if lhs.priority != rhs.priority {
                return lhs.priority > rhs.priority
            }
            if lhs.createdAt != rhs.createdAt {
                return lhs.createdAt < rhs.createdAt
            }
            return lhs.id.uuidString < rhs.id.uuidString
        }
        for rule in rules {
            let exts = normalizeExtensions(rule.extensions).joined(separator: ",")
            let destPath = normalizeDestinationPath(
                rule.destinationPath,
                isAbsolute: rule.destinationIsAbsolute
            )
            components.append(
                "extensionRule=\(rule.id.uuidString)|enabled=\(rule.enabled)|priority=\(rule.priority)|destType=\(rule.destinationType.rawValue)|destPath=\(destPath)|destAbs=\(rule.destinationIsAbsolute)|ownerScope=\(rule.ownerScope.rawValue)|exts=\(exts)"
            )
        }

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

    private func normalizeExtensions(_ values: [String]) -> [String] {
        let normalized = values
            .map { ExtensionRule.normalizeExtension($0) }
            .filter { !$0.isEmpty }
        return Array(Set(normalized)).sorted()
    }

    private func normalizeDestinationPath(_ path: String?, isAbsolute: Bool) -> String {
        guard let path, !path.isEmpty else {
            return ""
        }
        if isAbsolute {
            return canonicalPath(path)
        }
        return path.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
