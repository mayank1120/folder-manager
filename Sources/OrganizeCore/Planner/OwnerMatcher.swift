import Foundation

public enum OwnerBucketKind: Sendable, Hashable {
    case person(EntityID)
    case shared
    case unassigned
}

public struct OwnerAssignment: Sendable, Hashable {
    public let bucketKind: OwnerBucketKind
    public let bucketName: String
    public let reason: OwnerReason
    public let confidence: OwnerConfidence
    public let matchedPeople: [EntityID]
    public let matchedTokens: [String]
}

public struct OwnerMatcher: Sendable {
    private let people: [Person]
    private let settings: OwnerMatchingSettings

    public init(people: [Person], settings: OwnerMatchingSettings = OwnerMatchingSettings()) {
        self.people = people
        self.settings = settings
    }

    public func match(path: String) -> OwnerAssignment {
        let tokens = tokenize(path, settings: settings)
        let tokenSet = Set(tokens)

        var matches: [(person: Person, matchedTokens: [String])] = []
        matches.reserveCapacity(people.count)

        for person in people {
            let matched = person.keywordTokens
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { tokenSet.contains($0) }
            if !matched.isEmpty {
                matches.append((person: person, matchedTokens: matched.sorted()))
            }
        }

        if matches.isEmpty {
            return OwnerAssignment(
                bucketKind: .unassigned,
                bucketName: "Unassigned",
                reason: .noMatch,
                confidence: .notConfident,
                matchedPeople: [],
                matchedTokens: []
            )
        }

        if matches.count == 1, let match = matches.first {
            return OwnerAssignment(
                bucketKind: .person(match.person.id),
                bucketName: sanitizeFolderName(match.person.displayName),
                reason: .singleMatch,
                confidence: .confident,
                matchedPeople: [match.person.id],
                matchedTokens: match.matchedTokens
            )
        }

        let matchedPeople = matches.map(\.person.id).sorted { $0.uuidString < $1.uuidString }
        let matchedTokens = matches.flatMap(\.matchedTokens)
        return OwnerAssignment(
            bucketKind: .shared,
            bucketName: "Shared",
            reason: .matchedMultiplePeople,
            confidence: .notConfident,
            matchedPeople: matchedPeople,
            matchedTokens: Array(Set(matchedTokens)).sorted()
        )
    }

    private func tokenize(_ input: String, settings: OwnerMatchingSettings) -> [String] {
        let separators = CharacterSet(charactersIn: " _-.,()[]/\\")
        let parts = input
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }

        var tokens: [String] = []
        tokens.reserveCapacity(parts.count * 2)

        for part in parts {
            var currentParts: [String] = [part]

            if settings.enableCamelCaseSplit {
                currentParts = currentParts.flatMap(splitCamelCase)
            }

            if settings.enableDigitSplit {
                currentParts = currentParts.flatMap(splitDigitBoundaries)
            }

            tokens.append(contentsOf: currentParts)
        }

        return tokens
            .map { $0.lowercased() }
            .filter { !$0.isEmpty }
    }

    private func splitCamelCase(_ input: String) -> [String] {
        if input.count < 2 {
            return [input]
        }

        var tokens: [String] = []
        var current = ""
        let chars = Array(input)

        for i in chars.indices {
            let ch = chars[i]
            let prev = i > 0 ? chars[i - 1] : nil
            let next = (i + 1 < chars.count) ? chars[i + 1] : nil

            if let prev, ch.isUppercase {
                let prevIsLower = prev.isLowercase
                let nextIsLower = next?.isLowercase ?? false
                if prevIsLower || nextIsLower {
                    if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                }
            }

            current.append(ch)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func splitDigitBoundaries(_ input: String) -> [String] {
        if input.count < 2 {
            return [input]
        }

        var tokens: [String] = []
        var current = ""
        let chars = Array(input)

        for i in chars.indices {
            let ch = chars[i]
            let prev = i > 0 ? chars[i - 1] : nil

            if let prev {
                let boundary = (prev.isNumber && !ch.isNumber) || (!prev.isNumber && ch.isNumber)
                if boundary {
                    if !current.isEmpty {
                        tokens.append(current)
                        current = ""
                    }
                }
            }

            current.append(ch)
        }

        if !current.isEmpty {
            tokens.append(current)
        }

        return tokens
    }

    private func sanitizeFolderName(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            return "Person"
        }

        var result = trimmed
        result = result.replacingOccurrences(of: "/", with: "-")
        result = result.replacingOccurrences(of: ":", with: "-")
        return result
    }
}
