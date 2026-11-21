import Foundation

// Suggestions safety model (ported from PC Cleanup & Organizer v3).
// The AI never names files. It can only pick actions from an allowlist the app builds from its own scan,
// every pick is re-validated by the app, and the app's own sizes replace any number the model gives.

/// One action a suggestion can take. Targets are always identifiers the app produced, never raw paths.
public enum SuggestionAction: Hashable, Sendable {
    /// Move the app's own scan results for one cleanable category to the Trash.
    case trashCategory(String)
    /// Move the extra copies of each duplicate group to the Trash, keeping one copy per group.
    case trashDuplicateCopies
    /// Switch off a broken startup item by moving its launch file to the Trash (restorable).
    case disableStartupItem(String)
    /// Open a section of MacSweep so the user can review it. Changes nothing.
    case review(String)

    /// Stable signature used for de-duplication, the applied list and the skip file.
    public var signature: String {
        switch self {
        case .trashCategory(let id): "trash:\(id)"
        case .trashDuplicateCopies: "duplicates"
        case .disableStartupItem(let id): "startup:\(id)"
        case .review(let tab): "review:\(tab)"
        }
    }

    public var changesFiles: Bool {
        if case .review = self { return false }
        return true
    }
}

/// What the app currently allows. Built from the latest scan; anything outside it is dropped.
public struct SuggestionCapabilities: Equatable, Sendable {
    public var trashableCategories: Set<String>
    public var duplicateCopies: Bool
    public var brokenStartupIDs: Set<String>
    public var reviewTabs: Set<String>

    public init(trashableCategories: Set<String> = [], duplicateCopies: Bool = false,
                brokenStartupIDs: Set<String> = [], reviewTabs: Set<String> = []) {
        self.trashableCategories = trashableCategories
        self.duplicateCopies = duplicateCopies
        self.brokenStartupIDs = brokenStartupIDs
        self.reviewTabs = reviewTabs
    }

    /// Re-validates one action against the allowlist. Returns nil when it is not allowed.
    public func validate(_ action: SuggestionAction) -> SuggestionAction? {
        switch action {
        case .trashCategory(let id): trashableCategories.contains(id) ? action : nil
        case .trashDuplicateCopies: duplicateCopies ? action : nil
        case .disableStartupItem(let id): brokenStartupIDs.contains(id) ? action : nil
        case .review(let tab): reviewTabs.contains(tab) ? action : nil
        }
    }

    /// The allowlist in the form sent to the model.
    public var allowlist: [[String: String]] {
        var list: [[String: String]] = []
        for id in trashableCategories.sorted() { list.append(["type": "trash_category", "category": id]) }
        if duplicateCopies { list.append(["type": "trash_duplicate_copies"]) }
        for id in brokenStartupIDs.sorted() { list.append(["type": "disable_startup_item", "id": id]) }
        for tab in reviewTabs.sorted() { list.append(["type": "review", "tab": tab]) }
        return list
    }
}

public enum SuggestionSource: String, Codable, Sendable {
    case rules, ai, both

    public var label: String {
        switch self {
        case .rules: "Rules"
        case .ai: "AI"
        case .both: "AI + Rules"
        }
    }
}

public enum SuggestionRisk: String, Codable, Sendable, Comparable {
    case none, low, medium

    public var label: String {
        switch self {
        case .none: "No change"
        case .low: "Low risk"
        case .medium: "Review first"
        }
    }

    public static func < (lhs: SuggestionRisk, rhs: SuggestionRisk) -> Bool {
        let order: [SuggestionRisk] = [.none, .low, .medium]
        return order.firstIndex(of: lhs)! < order.firstIndex(of: rhs)!
    }
}

/// A raw pick from either source, before the app attaches its own facts.
public struct SuggestionProposal: Equatable, Sendable {
    public var title: String
    public var reason: String
    public var action: SuggestionAction

    public init(title: String, reason: String, action: SuggestionAction) {
        self.title = String(title.prefix(120))
        self.reason = String(reason.prefix(300))
        self.action = action
    }
}

/// The app's own facts for an action: size, risk and whether it can be undone. Never taken from the model.
public struct SuggestionFacts: Equatable, Sendable {
    public var bytes: Int64
    public var risk: SuggestionRisk
    public var reversible: Bool
    public var itemCount: Int

    public init(bytes: Int64, risk: SuggestionRisk, reversible: Bool, itemCount: Int) {
        self.bytes = bytes
        self.risk = risk
        self.reversible = reversible
        self.itemCount = itemCount
    }
}

/// A card shown to the user.
public struct SuggestionCard: Identifiable, Equatable, Sendable {
    public var id: String { action.signature }
    public var title: String
    public var reason: String
    public var action: SuggestionAction
    public var source: SuggestionSource
    public var facts: SuggestionFacts

    public init(title: String, reason: String, action: SuggestionAction, source: SuggestionSource, facts: SuggestionFacts) {
        self.title = title
        self.reason = reason
        self.action = action
        self.source = source
        self.facts = facts
    }
}

public enum SuggestionMerger {
    /// Validates both lists, attaches the app's facts, de-duplicates by action and sorts by size (largest first).
    /// When the model and the rules pick the same action, the model's wording is kept and the source is "AI + Rules".
    public static func merge(rules: [SuggestionProposal], ai: [SuggestionProposal], capabilities: SuggestionCapabilities,
                             facts: (SuggestionAction) -> SuggestionFacts?) -> [SuggestionCard] {
        var cards: [String: SuggestionCard] = [:]
        var order: [String] = []
        func add(_ proposal: SuggestionProposal, source: SuggestionSource) {
            guard let action = capabilities.validate(proposal.action), let fact = facts(action) else { return }
            if action.changesFiles && fact.itemCount == 0 { return }
            let key = action.signature
            if var existing = cards[key] {
                if existing.source != source {
                    existing.source = .both
                    if source == .ai, !proposal.title.isEmpty { existing.title = proposal.title; existing.reason = proposal.reason }
                }
                cards[key] = existing
                return
            }
            let title = proposal.title.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !title.isEmpty else { return }
            cards[key] = SuggestionCard(title: title, reason: proposal.reason, action: action, source: source, facts: fact)
            order.append(key)
        }
        rules.forEach { add($0, source: .rules) }
        ai.forEach { add($0, source: .ai) }
        let list = order.compactMap { cards[$0] }
        return list.enumerated().sorted { left, right in
            let l = left.element, r = right.element
            if l.action.changesFiles != r.action.changesFiles { return l.action.changesFiles }
            if l.facts.bytes != r.facts.bytes { return l.facts.bytes > r.facts.bytes }
            return left.offset < right.offset
        }.map(\.element)
    }
}

/// Reads the model's answer. Accepts JSON mode output, fenced code blocks, or JSON embedded in prose.
public enum SuggestionResponseParser {
    public static let maximumItems = 12

    public static func parse(_ content: String) -> [SuggestionProposal] {
        guard let object = jsonObject(in: content) else { return [] }
        let rawItems: [Any]
        if let list = object as? [Any] { rawItems = list }
        else if let dict = object as? [String: Any] {
            rawItems = (dict["recommendations"] as? [Any]) ?? (dict["suggestions"] as? [Any]) ?? (dict["items"] as? [Any]) ?? []
        } else { rawItems = [] }
        var result: [SuggestionProposal] = []
        for raw in rawItems.prefix(maximumItems * 2) {
            guard let item = raw as? [String: Any], let title = item["title"] as? String,
                  let action = action(from: item["action"]) else { continue }
            result.append(SuggestionProposal(title: title, reason: (item["reason"] as? String) ?? "", action: action))
            if result.count == maximumItems { break }
        }
        return result
    }

    /// Only the four allowlisted action shapes are understood. Anything else (paths, commands, "empty trash") is ignored.
    public static func action(from value: Any?) -> SuggestionAction? {
        guard let dict = value as? [String: Any], let type = dict["type"] as? String else { return nil }
        func text(_ key: String) -> String? {
            guard let value = dict[key] as? String, !value.isEmpty, value.count <= 300 else { return nil }
            return value
        }
        switch type {
        case "trash_category": return text("category").map { .trashCategory($0) }
        case "trash_duplicate_copies": return .trashDuplicateCopies
        case "disable_startup_item": return text("id").map { .disableStartupItem($0) }
        case "review": return text("tab").map { .review($0) }
        default: return nil
        }
    }

    static func jsonObject(in content: String) -> Any? {
        var text = content.trimmingCharacters(in: .whitespacesAndNewlines)
        if let fence = text.range(of: "```") {
            var inner = text[fence.upperBound...]
            if let newline = inner.firstIndex(of: "\n") { inner = inner[inner.index(after: newline)...] }
            if let end = inner.range(of: "```") { inner = inner[..<end.lowerBound] }
            text = String(inner)
        }
        if let data = text.data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) { return object }
        for (open, close) in [("{", "}"), ("[", "]")] {
            guard let start = text.firstIndex(of: Character(open)), let end = text.lastIndex(of: Character(close)), start < end else { continue }
            if let data = String(text[start...end]).data(using: .utf8), let object = try? JSONSerialization.jsonObject(with: data) { return object }
        }
        return nil
    }
}

/// Suggestions the OS refused (for example a launch file MacSweep may not move), hidden for 14 days.
/// Stored as rec-skip.json in MacSweep's Application Support folder. Holds signatures and dates only.
public struct SuggestionSkipList: Codable, Equatable, Sendable {
    public static let fileName = "rec-skip.json"
    public static let hideDays = 14

    public var refused: [String: Date]

    public init(refused: [String: Date] = [:]) { self.refused = refused }

    public func isHidden(_ signature: String, now: Date) -> Bool {
        guard let date = refused[signature] else { return false }
        return now.timeIntervalSince(date) < Double(Self.hideDays) * 86_400 && date <= now.addingTimeInterval(60)
    }

    public mutating func refuse(_ signature: String, now: Date) { refused[signature] = now }

    /// Drops expired entries so the file stays small.
    public mutating func prune(now: Date) {
        refused = refused.filter { isHidden($0.key, now: now) }
    }

    public static func load(from directory: URL) -> SuggestionSkipList {
        let url = directory.appendingPathComponent(fileName)
        guard let data = try? Data(contentsOf: url),
              let list = try? JSONCoding.decoder().decode(SuggestionSkipList.self, from: JSONCoding.stripBOM(data)) else { return SuggestionSkipList() }
        return list
    }

    public func save(to directory: URL) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try JSONCoding.encoder().encode(self)
        let url = directory.appendingPathComponent(Self.fileName)
        try data.write(to: url, options: .atomic)
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}

/// Applies the list rules: applied suggestions stay hidden until the next Smart Scan, refused ones for 14 days.
public enum SuggestionFilter {
    public static func visible(_ cards: [SuggestionCard], applied: Set<String>, skip: SuggestionSkipList, now: Date) -> (cards: [SuggestionCard], hidden: Int) {
        var hidden = 0
        let shown = cards.filter { card in
            let hide = applied.contains(card.id) || skip.isHidden(card.id, now: now)
            if hide { hidden += 1 }
            return !hide
        }
        return (shown, hidden)
    }
}
