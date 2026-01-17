import Foundation

public enum OwnerReason: String, Codable, Sendable {
    case singleMatch = "SingleMatch"
    case matchedMultiplePeople = "MatchedMultiplePeople"
    case noMatch = "NoMatch"
    case explicitOverride = "ExplicitOverride"
}

public enum PlanReasonCode: String, Codable, Sendable {
    case collisionAutoResolved = "CollisionAutoResolved"
    case collisionManual = "CollisionManual"
    case cloudOnly = "CloudOnly"
    case categoryByExtension = "CategoryByExtension"

    case policyExcludeCodeFile = "PolicyExclude:CodeFile"
    case policyExcludeConfigFile = "PolicyExclude:ConfigFile"
    case policyExcludeInstallerOrArchive = "PolicyExclude:InstallerOrArchive"
    case policyExcludeVideo = "PolicyExclude:Video"
    case policyExcludeUnknownType = "PolicyExclude:UnknownType"
    case policyExcludeUserExtension = "PolicyExclude:UserExtension"

    case needsReviewUnmappedType = "NeedsReview:UnmappedType"
}

public enum NeedsReviewIssueType: String, Codable, Sendable {
    case owner = "Owner"
    case collision = "Collision"
    case cloudOnly = "CloudOnly"
    case unmappedType = "UnmappedType"
}

public enum ApplyReasonCode: String, Codable, Sendable {
    case applyTimeCollision = "ApplyTimeCollision"
    case sourceMissing = "SourceMissing"
    case cloudOnly = "CloudOnly"
    case downloadFailed = "DownloadFailed"
    case accessError = "AccessError"
    case diskFull = "DiskFull"
}
