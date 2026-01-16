import Foundation
import CryptoKit
import Darwin

public struct PlanBuildSummary: Sendable {
    public let plan: Plan
    public let moveEligibleCount: Int
    public let needsReviewCount: Int
    public let excludedByPolicyCount: Int
    
    public init(plan: Plan, moveEligibleCount: Int, needsReviewCount: Int, excludedByPolicyCount: Int) {
        self.plan = plan
        self.moveEligibleCount = moveEligibleCount
        self.needsReviewCount = needsReviewCount
        self.excludedByPolicyCount = excludedByPolicyCount
    }
}

public struct Planner: Sendable {
    private let inventoryStore: InventoryStore
    private let planStore: PlanStore

    public init(inventoryStore: InventoryStore, planStore: PlanStore) {
        self.inventoryStore = inventoryStore
        self.planStore = planStore
    }

    public func createPlan(project: Project, scanId: EntityID) async throws -> PlanBuildSummary {
        guard let destinationRoot = project.destinationRoot?.path, project.destinationRoot?.isValid == true else {
            throw PlanningError.destinationRootMissing
        }

        try validateDestinationGuards(sourceRoots: project.sourceRoots, destinationRoot: destinationRoot)

        let inventoryItems = try await inventoryStore.fetchInventoryItems(for: scanId)
        let scanSourceRoots = try await inventoryStore.fetchScanSourceRoots(for: scanId)
        let scanRootById = Dictionary(uniqueKeysWithValues: scanSourceRoots.map { ($0.sourceRootId, $0.pathAtScan) })

        let ownerMatcher = OwnerMatcher(people: project.people)
        let typeClassifier = TypeClassifier(settings: project.settings)
        let dispositionEngine = DispositionEngine()

        let destRootURL = URL(fileURLWithPath: destinationRoot).standardizedFileURL
        let destDeviceId = Self.deviceId(path: destRootURL.path)
        let sourceDeviceById: [EntityID: dev_t] = Dictionary(uniqueKeysWithValues: scanSourceRoots.compactMap { root in
            guard let dev = Self.deviceId(path: root.pathAtScan) else { return nil }
            return (root.sourceRootId, dev)
        })

        struct WorkingItem {
            let item: InventoryItem
            let sourcePathAtScan: String
            let owner: OwnerAssignment
            let classification: TypeClassification?
            let baseDestPath: String?
            var disposition: Disposition
            var reasonCode: String?
            var issueType: String?
            var resolvedDestPath: String?
            var collisionResolved: Bool
            var conflictToken: String?
        }

        var working: [WorkingItem] = []
        working.reserveCapacity(inventoryItems.count)

        for item in inventoryItems {
            guard let rootPathAtScan = scanRootById[item.sourceRootId] else {
                throw PlanningError.scanSourceRootMissing(sourceRootId: item.sourceRootId)
            }
            let sourcePathAtScan = (rootPathAtScan as NSString).appendingPathComponent(item.relativePath)

            let owner = ownerMatcher.match(path: item.relativePath)
            let policyExclude = dispositionEngine.policyExclusionReason(for: item)

            var classification: TypeClassification?
            if policyExclude == nil {
                classification = typeClassifier.classify(item: item)
                if classification == nil, project.settings.enableOtherBucket {
                    classification = TypeClassification(category: .other)
                }
            }

            let baseDestPath = classification.flatMap { cls in
                buildBaseDestPath(
                    destinationRoot: destRootURL,
                    ownerBucketFolder: owner.bucketName,
                    classification: cls,
                    item: item
                )
            }

            var disposition: Disposition = .needsReview
            var reasonCode: String?
            var issueType: String?

            if let policyExclude {
                disposition = .excludedByPolicy
                reasonCode = policyExclude.rawValue
                issueType = nil
            } else if classification == nil || baseDestPath == nil {
                disposition = .needsReview
                reasonCode = PlanReasonCode.needsReviewUnmappedType.rawValue
                issueType = NeedsReviewIssueType.unmappedType.rawValue
            } else if item.isCloudOnly && !project.settings.downloadBeforeProcessing {
                disposition = .needsReview
                reasonCode = PlanReasonCode.cloudOnly.rawValue
                issueType = NeedsReviewIssueType.cloudOnly.rawValue
            } else if case .shared = owner.bucketKind, !project.settings.autoFileShared {
                disposition = .needsReview
                reasonCode = owner.reason.rawValue
                issueType = NeedsReviewIssueType.owner.rawValue
            } else if case .unassigned = owner.bucketKind, !project.settings.autoFileUnassigned {
                disposition = .needsReview
                reasonCode = owner.reason.rawValue
                issueType = NeedsReviewIssueType.owner.rawValue
            } else {
                disposition = .moveEligible
            }

            working.append(
                WorkingItem(
                    item: item,
                    sourcePathAtScan: sourcePathAtScan,
                    owner: owner,
                    classification: classification,
                    baseDestPath: baseDestPath,
                    disposition: disposition,
                    reasonCode: reasonCode,
                    issueType: issueType,
                    resolvedDestPath: nil,
                    collisionResolved: false,
                    conflictToken: nil
                )
            )
        }

        // Collisions: only for move-eligible items with a baseDestPath.
        var moveCandidates: [Int] = []
        moveCandidates.reserveCapacity(working.count)
        for (idx, w) in working.enumerated() where w.disposition == .moveEligible && w.baseDestPath != nil {
            moveCandidates.append(idx)
        }

        if project.settings.collisionPolicy == .manual {
            var basePathCounts: [String: Int] = [:]
            basePathCounts.reserveCapacity(moveCandidates.count)
            for idx in moveCandidates {
                let base = working[idx].baseDestPath!
                basePathCounts[base, default: 0] += 1
            }

            for idx in moveCandidates {
                let base = working[idx].baseDestPath!
                let collidesWithinPlan = (basePathCounts[base] ?? 0) > 1
                let collidesOnDisk = FileManager.default.fileExists(atPath: base)
                if collidesWithinPlan || collidesOnDisk {
                    working[idx].disposition = .needsReview
                    working[idx].reasonCode = PlanReasonCode.collisionManual.rawValue
                    working[idx].issueType = NeedsReviewIssueType.collision.rawValue
                } else {
                    working[idx].resolvedDestPath = base
                }
            }
        } else {
            let candidates: [CollisionCandidate] = moveCandidates.compactMap { idx in
                guard let base = working[idx].baseDestPath else { return nil }
                let item = working[idx].item
                return CollisionCandidate(
                    itemId: item.id,
                    sourcePath: working[idx].sourcePathAtScan,
                    baseDestPath: base,
                    sizeBytes: item.sizeBytes,
                    modifiedTime: item.modifiedTime
                )
            }

            let resolver = CollisionResolver()
            let resolutions = resolver.resolve(candidates: candidates)
            let resolutionById = Dictionary(uniqueKeysWithValues: resolutions.map { ($0.itemId, $0) })

            for idx in moveCandidates {
                let itemId = working[idx].item.id
                if let resolution = resolutionById[itemId] {
                    working[idx].resolvedDestPath = resolution.resolvedDestPath
                    working[idx].collisionResolved = resolution.collisionResolved
                    working[idx].conflictToken = resolution.conflictToken
                } else {
                    working[idx].resolvedDestPath = working[idx].baseDestPath
                }
            }
        }

        let settingsHash = SettingsHasher().hash(project: project)
        let planId = EntityID()
        let journalPath = "journals/move_log_\(planId.uuidString).jsonl"
        let plan = Plan(
            id: planId,
            scanId: scanId,
            projectId: project.id,
            createdAt: Date(),
            settingsHash: settingsHash,
            operationCount: 0,
            journalPath: journalPath
        )

        var planItems: [PlanItem] = []
        planItems.reserveCapacity(working.count)

        for w in working {
            let category = w.classification?.category.rawValue
            let subcategory = w.classification?.subcategory ?? w.classification?.topic

            planItems.append(
                PlanItem(
                    planId: planId,
                    itemId: w.item.id,
                    disposition: w.disposition,
                    ownerBucket: w.owner.bucketName,
                    ownerReason: w.owner.reason.rawValue,
                    ownerConfidence: w.owner.confidence,
                    category: category,
                    subcategory: subcategory,
                    baseDestPath: w.baseDestPath,
                    suggestedResolvedDestPath: w.resolvedDestPath,
                    reasonCode: w.reasonCode,
                    issueType: w.issueType
                )
            )
        }

        let operationType: PlanOperationType = (project.settings.executionMode == .move) ? .moveItem : .copyItem

        var operations: [(sourcePath: String, resolvedDestPath: String, op: PlanOperation)] = []
        operations.reserveCapacity(working.count)

        for w in working where w.disposition == .moveEligible {
            guard let baseDestPath = w.baseDestPath, let resolvedDestPath = w.resolvedDestPath else {
                continue
            }

            let operationId = computeOperationId(
                scanId: scanId,
                itemId: w.item.id,
                operationType: operationType,
                executionMode: project.settings.executionMode,
                resolvedDestPath: resolvedDestPath
            )

            let reasonCode = w.collisionResolved ? PlanReasonCode.collisionAutoResolved.rawValue : ""
            let crossVolume: Bool
            if operationType == .moveItem, let destDev = destDeviceId, let sourceDev = sourceDeviceById[w.item.sourceRootId] {
                crossVolume = destDev != sourceDev
            } else {
                crossVolume = false
            }

            let op = PlanOperation(
                operationId: operationId,
                planId: planId,
                itemId: w.item.id,
                operationType: operationType,
                executionMode: project.settings.executionMode,
                baseDestPath: baseDestPath,
                resolvedDestPath: resolvedDestPath,
                collisionResolved: w.collisionResolved,
                conflictToken: w.conflictToken,
                crossVolume: crossVolume,
                reasonCode: reasonCode,
                sortOrder: 0
            )

            operations.append((sourcePath: w.sourcePathAtScan, resolvedDestPath: resolvedDestPath, op: op))
        }

        // Deterministic apply order: sort by (resolvedDestPath, sourcePath).
        operations.sort { lhs, rhs in
            if lhs.resolvedDestPath != rhs.resolvedDestPath {
                return lhs.resolvedDestPath < rhs.resolvedDestPath
            }
            return lhs.sourcePath < rhs.sourcePath
        }

        var planOperations: [PlanOperation] = []
        planOperations.reserveCapacity(operations.count)
        for (index, entry) in operations.enumerated() {
            var op = entry.op
            op = PlanOperation(
                operationId: op.operationId,
                planId: op.planId,
                itemId: op.itemId,
                operationType: op.operationType,
                executionMode: op.executionMode,
                baseDestPath: op.baseDestPath,
                resolvedDestPath: op.resolvedDestPath,
                collisionResolved: op.collisionResolved,
                conflictToken: op.conflictToken,
                crossVolume: op.crossVolume,
                reasonCode: op.reasonCode,
                sortOrder: index
            )
            planOperations.append(op)
        }

        var planToSave = plan
        planToSave.operationCount = planOperations.count
        try await planStore.createPlan(planToSave, items: planItems, operations: planOperations)

        let moveEligibleCount = planOperations.count
        let needsReviewCount = planItems.filter { $0.disposition == .needsReview }.count
        let excludedByPolicyCount = planItems.filter { $0.disposition == .excludedByPolicy }.count

        return PlanBuildSummary(
            plan: planToSave,
            moveEligibleCount: moveEligibleCount,
            needsReviewCount: needsReviewCount,
            excludedByPolicyCount: excludedByPolicyCount
        )
    }

    private static func deviceId(path: String) -> dev_t? {
        var st = stat()
        if lstat(path, &st) != 0 {
            return nil
        }
        return st.st_dev
    }

    // MARK: - Destination Paths

    private func buildBaseDestPath(
        destinationRoot: URL,
        ownerBucketFolder: String,
        classification: TypeClassification,
        item: InventoryItem
    ) -> String {
        let routingDate = item.routingDate
        let (year, month) = yearMonthStrings(for: routingDate)

        let fileName = URL(fileURLWithPath: item.relativePath).lastPathComponent

        var dir = destinationRoot
            .appendingPathComponent(ownerBucketFolder)

        switch classification.category {
        case .pdf:
            let topic = classification.topic ?? "Other"
            dir = dir
                .appendingPathComponent("PDF")
                .appendingPathComponent(topic)
                .appendingPathComponent(year)
        case .docs:
            dir = dir
                .appendingPathComponent("Docs")
                .appendingPathComponent(year)
        case .sheets:
            dir = dir
                .appendingPathComponent("Sheets")
                .appendingPathComponent(year)
        case .scans:
            dir = dir
                .appendingPathComponent("Scans")
                .appendingPathComponent(year)
        case .images:
            let subcategory = classification.subcategory ?? "Other"
            dir = dir
                .appendingPathComponent("Images")
                .appendingPathComponent(subcategory)
                .appendingPathComponent(year)
                .appendingPathComponent(month)
        case .other:
            dir = dir
                .appendingPathComponent("Other")
                .appendingPathComponent(year)
        }

        return dir.appendingPathComponent(fileName).path
    }

    private func yearMonthStrings(for date: Date) -> (year: String, month: String) {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(secondsFromGMT: 0) ?? .current
        let components = calendar.dateComponents([.year, .month], from: date)
        let year = String(components.year ?? 1970)
        let month = String(format: "%02d", components.month ?? 1)
        return (year, month)
    }

    // MARK: - Guards

    private func validateDestinationGuards(sourceRoots: [SourceRoot], destinationRoot: String) throws {
        let destPath = URL(fileURLWithPath: destinationRoot).standardizedFileURL.path

        for root in sourceRoots where root.isValid {
            let sourcePath = URL(fileURLWithPath: root.path).standardizedFileURL.path
            if isPath(destPath, inside: sourcePath) || isPath(sourcePath, inside: destPath) {
                throw PlanningError.destinationInSource(source: sourcePath, destination: destPath)
            }
        }
    }

    private func isPath(_ candidate: String, inside base: String) -> Bool {
        if candidate == base {
            return true
        }
        let normalizedBase = base.hasSuffix("/") ? base : base + "/"
        return candidate.hasPrefix(normalizedBase)
    }

    // MARK: - Operation IDs

    private func computeOperationId(
        scanId: EntityID,
        itemId: String,
        operationType: PlanOperationType,
        executionMode: ExecutionMode,
        resolvedDestPath: String
    ) -> String {
        let input = "\(scanId.uuidString)|\(itemId)|\(operationType.rawValue)|\(executionMode.rawValue)|\(resolvedDestPath)"
        let hash = SHA256.hash(data: Data(input.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    public enum PlanningError: Error {
        case destinationRootMissing
        case destinationInSource(source: String, destination: String)
        case scanSourceRootMissing(sourceRootId: EntityID)
    }
}
