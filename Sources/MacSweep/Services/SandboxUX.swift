import Foundation

/// What to do when a confirm would include items the test sandbox will refuse.
enum SandboxPreflightChoice: Equatable, Sendable {
    case turnOffSandbox
    case skipOutside
    case cancel
}

/// Told to the user before the confirm sheet when selected items sit outside the sandbox.
struct SandboxPreflight: Equatable, Sendable {
    let outside: Int
    let total: Int
    /// Only plain cleanups can drop the outside items; app removals must match their full plan.
    let allowsSkip: Bool

    var inside: Int { max(0, total - outside) }

    var headline: String {
        if outside >= total {
            return total == 1 ? "The selected item is outside the test sandbox"
                : "All \(total) selected items are outside the test sandbox"
        }
        return "\(SandboxText.items(outside)) \(outside == 1 ? "is" : "are") outside the test sandbox and will be skipped"
    }

    var detail: String {
        SandboxText.banner + " Turn off the sandbox to clean "
            + (outside == 1 ? "it" : "them") + " (you will be asked to confirm), or cancel."
    }
}

enum SandboxText {
    static let banner = "Test sandbox is on, so only files in the test folder can be moved to Trash."
    static func items(_ count: Int) -> String { count == 1 ? "1 item" : "\(count) items" }
}

extension TestSandbox {
    /// The URLs this policy would refuse. Enforcement still happens in `CleanupSafety`; this only informs the UI.
    static func outside(_ urls: [URL], policy: SandboxPolicy) -> [URL] {
        guard policy.enabled else { return [] }
        return urls.filter { refusal(for: $0, policy: policy) != nil }
    }
}

/// A one-line summary of a Trash result, with the repeated per-file lines grouped for a details view.
struct TrashReport: Equatable, Sendable {
    struct Group: Equatable, Sendable {
        let reason: String
        let paths: [String]
    }

    let headline: String
    let summary: String
    let groups: [Group]
    let otherMessages: [String]

    var hasDetails: Bool { !groups.isEmpty || !otherMessages.isEmpty }

    /// Plain text for the details view: each reason once, then its paths.
    var detailText: String {
        var lines: [String] = []
        for group in groups {
            lines.append("\(group.reason) (\(SandboxText.items(group.paths.count)))")
            lines.append(contentsOf: group.paths.map { "  • \($0)" })
            lines.append("")
        }
        lines.append(contentsOf: otherMessages)
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func summarize(movedCount: Int, messages: [String]) -> TrashReport {
        var order: [String] = []
        var paths: [String: [String]] = [:]
        var other: [String] = []
        for message in messages where !message.isEmpty {
            guard let (path, reason) = skipped(message) else { other.append(message); continue }
            if paths[reason] == nil { order.append(reason) }
            paths[reason, default: []].append(path)
        }
        let groups = order.map { Group(reason: $0, paths: paths[$0] ?? []) }
        let skippedCount = groups.reduce(0) { $0 + $1.paths.count }
        let headline = movedCount == 0 ? "Nothing was moved to Trash" : "Moved \(SandboxText.items(movedCount)) to Trash"
        var parts: [String] = []
        if movedCount > 0 || skippedCount == 0 { parts.append("Moved \(SandboxText.items(movedCount)).") }
        if skippedCount > 0 {
            let reasons = groups.map { "\($0.paths.count) \(shortReason($0.reason))" }.joined(separator: ", ")
            parts.append("Skipped \(SandboxText.items(skippedCount)): \(reasons).")
        }
        if !other.isEmpty { parts.append("\(other.count == 1 ? "1 note" : "\(other.count) notes") to review.") }
        return TrashReport(headline: headline, summary: parts.joined(separator: " "), groups: groups, otherMessages: other)
    }

    /// "Skipped <path>: <reason>" → (path, reason).
    private static func skipped(_ message: String) -> (String, String)? {
        let prefix = "Skipped "
        guard message.hasPrefix(prefix) else { return nil }
        let body = message.dropFirst(prefix.count)
        guard let split = body.range(of: ": ") else { return nil }
        let path = String(body[..<split.lowerBound])
        let reason = String(body[split.upperBound...])
        guard !path.isEmpty, !reason.isEmpty else { return nil }
        return (path, reason)
    }

    static func shortReason(_ reason: String) -> String {
        if reason.hasPrefix("Test sandbox is on") { return "outside the test sandbox" }
        if reason.hasPrefix("protected by your exclusions") { return "excluded" }
        let trimmed = reason.trimmingCharacters(in: CharacterSet(charactersIn: ". "))
        return trimmed.count > 60 ? String(trimmed.prefix(57)) + "…" : trimmed
    }
}
