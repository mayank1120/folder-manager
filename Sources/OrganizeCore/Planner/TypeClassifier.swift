import Foundation
import UniformTypeIdentifiers

public enum OrganizedCategory: String, Sendable {
    case pdf = "PDF"
    case docs = "Docs"
    case sheets = "Sheets"
    case images = "Images"
    case scans = "Scans"
    case other = "Other"
}

public struct TypeClassification: Sendable, Hashable {
    public let category: OrganizedCategory
    public let subcategory: String?
    public let topic: String?

    public init(category: OrganizedCategory, subcategory: String? = nil, topic: String? = nil) {
        self.category = category
        self.subcategory = subcategory
        self.topic = topic
    }
}

public struct TypeClassifier: Sendable {
    private let screenshotPrefixes: [String]
    private let cameraPrefixes: [String]

    public init(settings: ProjectSettings) {
        self.screenshotPrefixes = settings.screenshotPrefixes
        self.cameraPrefixes = settings.cameraPrefixes
    }

    public func classify(item: InventoryItem) -> TypeClassification? {
        let fileName = URL(fileURLWithPath: item.relativePath).lastPathComponent
        let lowerPath = item.relativePath.lowercased()
        let ext = (item.extension ?? URL(fileURLWithPath: fileName).pathExtension).lowercased()

        if item.isPackage {
            switch ext {
            case "numbers":
                return TypeClassification(category: .sheets)
            case "pages", "rtfd", "key":
                return TypeClassification(category: .docs)
            default:
                return nil
            }
        }

        let isPDF = ext == "pdf" || uttypeConforms(item.uttypeIdentifier, to: .pdf)
        let isImage = isCommonImageExtension(ext) || uttypeConforms(item.uttypeIdentifier, to: .image)

        // Scan heuristic: if it looks like a scan and it's a PDF or Image, route to Scans/<YYYY>/...
        if (isPDF || isImage) && looksLikeScan(fileName: fileName, path: lowerPath) {
            return TypeClassification(category: .scans)
        }

        if isPDF {
            return TypeClassification(category: .pdf, topic: pdfTopic(for: lowerPath))
        }

        if isImage {
            let subcategory = imageSubcategory(fileName: fileName)
            return TypeClassification(category: .images, subcategory: subcategory)
        }

        if uttypeConforms(item.uttypeIdentifier, to: .spreadsheet) {
            return TypeClassification(category: .sheets)
        }

        if uttypeConforms(item.uttypeIdentifier, to: .presentation)
            || uttypeConforms(item.uttypeIdentifier, to: .compositeContent)
            || uttypeConforms(item.uttypeIdentifier, to: .text)
        {
            return TypeClassification(category: .docs)
        }

        return nil
    }

    private func looksLikeScan(fileName: String, path: String) -> Bool {
        let lowerName = fileName.lowercased()
        return lowerName.contains("scan") || path.contains("/scan") || path.contains("/scans")
    }

    private func pdfTopic(for lowerPath: String) -> String {
        let rules: [(topic: String, keywords: [String])] = [
            ("Receipts", ["receipt", "receipts", "invoice", "invoices"]),
            ("Finance", ["bank", "statement", "tax", "finance", "salary", "paystub"]),
            ("Medical", ["medical", "doctor", "hospital", "clinic", "rx", "prescription"]),
            ("Legal", ["legal", "contract", "agreement", "court", "visa", "law"]),
            ("Manuals", ["manual", "guide", "instruction", "instructions"])
        ]

        for rule in rules {
            if rule.keywords.contains(where: { lowerPath.contains($0) }) {
                return rule.topic
            }
        }
        return "Other"
    }

    private func imageSubcategory(fileName: String) -> String {
        let lowerName = fileName.lowercased()

        for prefix in screenshotPrefixes {
            let lowerPrefix = prefix.lowercased()
            if lowerName.hasPrefix(lowerPrefix) {
                return "Screenshots"
            }
        }

        for prefix in cameraPrefixes {
            let lowerPrefix = prefix.lowercased()
            if lowerName.hasPrefix(lowerPrefix) {
                return "Camera"
            }
        }

        return "Other"
    }

    private func uttypeConforms(_ identifier: String?, to type: UTType) -> Bool {
        guard let identifier, let uttype = UTType(identifier) else {
            return false
        }
        return uttype.conforms(to: type)
    }

    private func isCommonImageExtension(_ ext: String) -> Bool {
        switch ext {
        case "jpg", "jpeg", "png", "gif", "heic", "tiff", "tif", "bmp", "webp":
            return true
        default:
            return false
        }
    }
}

