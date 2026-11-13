import Foundation

/// What the user reviewed in the confirm sheet.
public struct ConfirmationPreview: Equatable, Sendable, Identifiable {
    public let token: String
    public let paths: [String]
    public let issuedAt: Date
    public let expiresAt: Date
    public var id: String { token }
}

/// Proof that the user approved exactly these paths. Only `ConfirmationLedger.consume` creates one.
public struct ConfirmationGrant: Equatable, Sendable {
    public let token: String
    public let paths: [String]

    init(token: String, paths: [String]) {
        self.token = token
        self.paths = paths
    }

    public var urls: [URL] { paths.map { URL(fileURLWithPath: $0) } }

    /// True when the grant covers exactly the given paths, in any order.
    public func matches(_ paths: [String]) -> Bool {
        Set(self.paths) == Set(paths)
    }
}

public enum ConfirmationFailure: Error, Equatable, Sendable, LocalizedError {
    case unknown, expired, alreadyUsed

    public var errorDescription: String? {
        switch self {
        case .unknown: "This confirmation is no longer valid. Review the items again."
        case .expired: "This confirmation expired after five minutes. Review the items again."
        case .alreadyUsed: "This confirmation was already used. Review the items again."
        }
    }
}

/// Single-use confirmations that expire after five minutes.
public final class ConfirmationLedger: @unchecked Sendable {
    public static let title = "Do you really want to do this action?"
    public static let lifetime: TimeInterval = 300

    private struct Record {
        var preview: ConfirmationPreview
        var used: Bool
    }

    private let lock = NSLock()
    private var records: [String: Record] = [:]
    private let makeToken: @Sendable () -> String

    public init(makeToken: @escaping @Sendable () -> String = { UUID().uuidString }) {
        self.makeToken = makeToken
    }

    /// Returns nil when there is nothing to confirm.
    public func issue(paths: [String], now: Date = Date(), ttl: TimeInterval = ConfirmationLedger.lifetime) -> ConfirmationPreview? {
        var seen = Set<String>()
        let unique = paths.filter { !$0.isEmpty && seen.insert($0).inserted }
        guard !unique.isEmpty else { return nil }
        let preview = ConfirmationPreview(token: makeToken(), paths: unique, issuedAt: now,
                                          expiresAt: now.addingTimeInterval(min(ttl, Self.lifetime)))
        lock.lock(); defer { lock.unlock() }
        records[preview.token] = Record(preview: preview, used: false)
        return preview
    }

    public func consume(token: String, now: Date = Date()) -> Result<ConfirmationGrant, ConfirmationFailure> {
        lock.lock(); defer { lock.unlock() }
        guard var record = records[token] else { return .failure(.unknown) }
        if record.used { return .failure(.alreadyUsed) }
        record.used = true
        records[token] = record
        if now > record.preview.expiresAt || now < record.preview.issuedAt { return .failure(.expired) }
        return .success(ConfirmationGrant(token: token, paths: record.preview.paths))
    }

    public func cancel(token: String) {
        lock.lock(); defer { lock.unlock() }
        records[token] = nil
    }
}
