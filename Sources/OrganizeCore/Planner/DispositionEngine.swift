import Foundation
import UniformTypeIdentifiers

public struct DispositionEngine: Sendable {
    public init() {}

    public func policyExclusionReason(for item: InventoryItem) -> PlanReasonCode? {
        if item.isPackage {
            let ext = (item.extension ?? URL(fileURLWithPath: item.relativePath).pathExtension).lowercased()
            if ["pages", "numbers", "key", "rtfd"].contains(ext) {
                return nil
            }
        }

        let ext = (item.extension ?? URL(fileURLWithPath: item.relativePath).pathExtension).lowercased()

        if isCodeFile(ext: ext) {
            return .policyExcludeCodeFile
        }

        if isConfigFile(ext: ext) {
            return .policyExcludeConfigFile
        }

        if isInstallerOrArchive(ext: ext) {
            return .policyExcludeInstallerOrArchive
        }

        if isVideo(ext: ext) {
            return .policyExcludeVideo
        }

        // Unknown type policy: UTType unknown and extension not mapped by TypeDetector.
        // Scanner sets uttypeIdentifier via contentTypeKey + extension fallback.
        if item.uttypeIdentifier == nil {
            return .policyExcludeUnknownType
        }

        // Dynamic UTTypes are commonly returned for extensions that have no known mapping.
        if let id = item.uttypeIdentifier, id.hasPrefix("dyn.") {
            return .policyExcludeUnknownType
        }

        // Also treat unparseable UTType identifiers as unknown.
        if let id = item.uttypeIdentifier, UTType(id) == nil {
            return .policyExcludeUnknownType
        }

        return nil
    }

    private func isCodeFile(ext: String) -> Bool {
        let code: Set<String> = [
            "py", "js", "ts", "java", "go", "rb", "rs", "c", "cpp", "h", "hpp",
            "swift", "sql", "ipynb",
            "sh", "bash", "zsh", "fish", "command"
        ]
        return code.contains(ext)
    }

    private func isConfigFile(ext: String) -> Bool {
        let config: Set<String> = [
            "env", "json", "yaml", "yml", "toml", "ini", "cfg", "conf", "xml"
        ]
        return config.contains(ext)
    }

    private func isInstallerOrArchive(ext: String) -> Bool {
        let installersAndArchives: Set<String> = [
            "dmg", "pkg", "zip", "rar", "7z", "tar", "gz"
        ]
        return installersAndArchives.contains(ext)
    }

    private func isVideo(ext: String) -> Bool {
        let videos: Set<String> = [
            "mov", "mp4", "m4v", "avi", "mkv", "webm"
        ]
        return videos.contains(ext)
    }
}
