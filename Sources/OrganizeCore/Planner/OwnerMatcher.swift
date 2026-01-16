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

    public init(people: [Person]) {
        self.people = people
    }

    public func match(path: String) -> OwnerAssignment {
        let tokens = tokenize(path)
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

    private func tokenize(_ input: String) -> [String] {
        let separators = CharacterSet(charactersIn: " _-.,()[]/\\")
        return input
            .lowercased()
            .components(separatedBy: separators)
            .filter { !$0.isEmpty }
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
