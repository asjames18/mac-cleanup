import Foundation

/// Device and inode identity on supported local filesystems; never derived from a path.
/// Inodes can be reused over time, so mutation checks also compare snapshot metadata.
public struct FileIdentity: Hashable, Codable, Sendable {
    public let volumeKey: String
    public let resourceKey: String

    public init(volumeKey: String, resourceKey: String) {
        self.volumeKey = volumeKey
        self.resourceKey = resourceKey
    }
}

public struct FileSnapshot: Hashable, Codable, Sendable {
    public let identity: FileIdentity
    public let logicalBytes: Int64
    public let modifiedAt: Date
    public let contentDigest: String?
    public let changedAt: Date?

    public init(identity: FileIdentity, logicalBytes: Int64, modifiedAt: Date, contentDigest: String?, changedAt: Date? = nil) {
        self.identity = identity
        self.logicalBytes = logicalBytes
        self.modifiedAt = modifiedAt
        self.contentDigest = contentDigest
        self.changedAt = changedAt
    }
}

public struct TrashTarget: Equatable, Codable, Sendable {
    public let url: URL
    public let expected: FileSnapshot

    public init(url: URL, expected: FileSnapshot) {
        self.url = url
        self.expected = expected
    }
}

/// Immutable validation input, not authorization to mutate a filesystem path.
public struct TrashPlan: Codable, Sendable {
    public let id: UUID
    public let scanID: UUID
    public let ruleVersion: String
    public let targets: [TrashTarget]

    public init(id: UUID = UUID(), scanID: UUID, ruleVersion: String, targets: [TrashTarget]) {
        self.id = id
        self.scanID = scanID
        self.ruleVersion = ruleVersion
        self.targets = targets
    }
}

public enum TargetValidation: Equatable, Sendable {
    case unchanged
    case needsRescan
    case unavailable
}

public enum TrashPlanValidator {
    public static func validate(expected: FileSnapshot, current: FileSnapshot?) -> TargetValidation {
        guard let current else { return .unavailable }
        return expected == current ? .unchanged : .needsRescan
    }
}
