import Foundation
import MacSweepCore

/// Everything the suggestion engine looks at. Built from MacSweep's own scan results.
struct SuggestionContext: Sendable {
    var items: [CleanupItem]
    var keep: CleanupSafety.DuplicateKeep = .oldest
    var startup: [StartupDefinition] = []
    var protection: ProtectionStatus? = nil
    var homebrewOutdated: Int? = nil
}

/// Review destinations a suggestion can open. Opening one changes nothing.
enum ReviewTab: String, CaseIterable, Sendable {
    case maintenance, duplicates, largeFiles = "large-files", oldInstallers = "old-installers", updateFiles = "update-files", storage

    var title: String {
        switch self {
        case .maintenance: "Maintenance"
        case .duplicates: "Duplicates"
        case .largeFiles: "Large Files"
        case .oldInstallers: "Old Installers"
        case .updateFiles: "Update Files"
        case .storage: "Storage"
        }
    }
}

/// The offline rules engine plus the app-owned facts, allowlist and snapshot for the AI.
/// The AI only ever sees sizes and counts (no file names or paths) and may only pick allowlisted actions.
enum SuggestionEngine {
    /// Categories a suggestion may move to the Trash in bulk. Personal files (large files, added folders)
    /// and review-only categories are never bulk actions; they get a review link instead.
    static let bulkCategories: [CleanupCategory] = [.caches, .browserCaches, .crashReports, .shaderCaches, .logs, .temporary,
                                                    .xcode, .developerCaches, .downloads]

    static func items(in category: CleanupCategory, _ context: SuggestionContext) -> [CleanupItem] {
        CleanupSafety.uniqueItems(context.items.filter { $0.category == category })
    }

    static func capabilities(_ context: SuggestionContext) -> SuggestionCapabilities {
        var caps = SuggestionCapabilities()
        for category in bulkCategories where !items(in: category, context).isEmpty { caps.trashableCategories.insert(category.rawValue) }
        caps.duplicateCopies = !CleanupSafety.extraDuplicateCopies(context.items, keep: context.keep).isEmpty
        caps.brokenStartupIDs = Set(context.startup.filter { $0.isBroken && $0.canSwitchOff }.map(\.suggestionKey))
        var tabs: Set<String> = [ReviewTab.maintenance.rawValue, ReviewTab.storage.rawValue]
        if caps.duplicateCopies { tabs.insert(ReviewTab.duplicates.rawValue) }
        if context.items.contains(where: { $0.category == .largeFiles }) { tabs.insert(ReviewTab.largeFiles.rawValue) }
        if context.items.contains(where: { $0.category == .oldInstallers }) { tabs.insert(ReviewTab.oldInstallers.rawValue) }
        if context.items.contains(where: { $0.category == .systemUpdates }) { tabs.insert(ReviewTab.updateFiles.rawValue) }
        caps.reviewTabs = tabs
        return caps
    }

    /// The app's own size, risk and undo facts. Never taken from the model.
    static func facts(_ action: SuggestionAction, _ context: SuggestionContext) -> SuggestionFacts? {
        switch action {
        case .trashCategory(let id):
            guard let category = CleanupCategory(rawValue: id) else { return nil }
            let list = items(in: category, context)
            return SuggestionFacts(bytes: list.reduce(0) { $0 + $1.size }, risk: category.isRebuildable ? .low : .medium,
                                   reversible: true, itemCount: list.count)
        case .trashDuplicateCopies:
            let copies = CleanupSafety.extraDuplicateCopies(context.items, keep: context.keep)
            return SuggestionFacts(bytes: copies.reduce(0) { $0 + $1.size }, risk: .medium, reversible: true, itemCount: copies.count)
        case .disableStartupItem(let key):
            guard context.startup.contains(where: { $0.suggestionKey == key && $0.isBroken && $0.canSwitchOff }) else { return nil }
            return SuggestionFacts(bytes: 0, risk: .low, reversible: true, itemCount: 1)
        case .review(let tab):
            guard let tab = ReviewTab(rawValue: tab) else { return nil }
            let bytes: Int64
            switch tab {
            case .duplicates: bytes = CleanupSafety.extraDuplicateCopies(context.items, keep: context.keep).reduce(0) { $0 + $1.size }
            case .largeFiles: bytes = items(in: .largeFiles, context).reduce(0) { $0 + $1.size }
            case .oldInstallers: bytes = items(in: .oldInstallers, context).reduce(0) { $0 + $1.size }
            case .updateFiles: bytes = items(in: .systemUpdates, context).reduce(0) { $0 + $1.size }
            case .maintenance, .storage: bytes = 0
            }
            return SuggestionFacts(bytes: bytes, risk: .none, reversible: true, itemCount: 0)
        }
    }

    /// Built-in rules. Work with no network and are always merged with any AI picks.
    static func rules(_ context: SuggestionContext) -> [SuggestionProposal] {
        var result: [SuggestionProposal] = []
        func size(_ category: CleanupCategory) -> Int64 { items(in: category, context).reduce(0) { $0 + $1.size } }
        let thresholds: [(CleanupCategory, Int64, String, String)] = [
            (.caches, 50_000_000, "Clear app caches", "Apps rebuild these caches when they need them."),
            (.browserCaches, 50_000_000, "Clear browser caches", "Browsers rebuild their caches as you browse. Quit the browser first; open files are skipped."),
            (.crashReports, 5_000_000, "Clear old crash reports", "Crash and diagnostic reports are only useful for troubleshooting; macOS writes new ones when needed."),
            (.shaderCaches, 50_000_000, "Clear GPU shader caches", "Apps and games rebuild compiled shaders; the first launch afterwards may be slower."),
            (.logs, 20_000_000, "Clear app logs older than 30 days", "Old logs are rarely needed. Recent logs are left alone."),
            (.temporary, 50_000_000, "Clear temporary files", "Temporary files that apps no longer need."),
            (.xcode, 200_000_000, "Clear Xcode build data", "DerivedData and archives are rebuilt by Xcode."),
            (.developerCaches, 200_000_000, "Clear developer caches", "Package managers download what they need again."),
        ]
        for (category, minimum, title, reason) in thresholds where size(category) >= minimum {
            result.append(SuggestionProposal(title: title, reason: reason, action: .trashCategory(category.rawValue)))
        }
        let downloads = items(in: .downloads, context)
        if !downloads.isEmpty {
            result.append(SuggestionProposal(title: "Move \(downloads.count) old downloads to Trash",
                                             reason: "Installers, archives and downloads untouched for 14 days.",
                                             action: .trashCategory(CleanupCategory.downloads.rawValue)))
        }
        let copies = CleanupSafety.extraDuplicateCopies(context.items, keep: context.keep)
        if !copies.isEmpty {
            result.append(SuggestionProposal(title: "Move \(copies.count) extra duplicate copies to Trash",
                                             reason: "Keeps the \(context.keep == .oldest ? "oldest" : "newest") copy of each group.",
                                             action: .trashDuplicateCopies))
        }
        for item in context.startup where item.isBroken {
            if item.canSwitchOff {
                result.append(SuggestionProposal(title: "Switch off broken startup item \(item.displayName)",
                                                 reason: item.brokenReason ?? "", action: .disableStartupItem(item.suggestionKey)))
            }
        }
        if context.startup.contains(where: { $0.isBroken && !$0.canSwitchOff }) {
            result.append(SuggestionProposal(title: "Review broken system startup items",
                                             reason: "Some startup items in the Mac's Library point to missing programs. Removing them needs an administrator.",
                                             action: .review(ReviewTab.maintenance.rawValue)))
        }
        if !items(in: .oldInstallers, context).isEmpty {
            result.append(SuggestionProposal(title: "Review old installers in Downloads",
                                             reason: "Disk images and packages older than 30 days. MacSweep lists them but never moves them.",
                                             action: .review(ReviewTab.oldInstallers.rawValue)))
        }
        if !items(in: .largeFiles, context).isEmpty {
            result.append(SuggestionProposal(title: "Review large files", reason: "Files over 500 MB in your personal folders.",
                                             action: .review(ReviewTab.largeFiles.rawValue)))
        }
        if context.protection?.gatekeeperOn == false {
            result.append(SuggestionProposal(title: "Turn Gatekeeper back on", reason: "Apps from anywhere can open without a check.",
                                             action: .review(ReviewTab.maintenance.rawValue)))
        }
        if let outdated = context.homebrewOutdated, outdated > 0 {
            result.append(SuggestionProposal(title: "Update \(outdated) Homebrew packages",
                                             reason: "Run brew upgrade in Terminal when convenient. MacSweep only reports this.",
                                             action: .review(ReviewTab.maintenance.rawValue)))
        }
        return result
    }

    /// The URLs a trash action covers, always from MacSweep's own scan.
    static func targets(_ action: SuggestionAction, _ context: SuggestionContext) -> [URL] {
        switch action {
        case .trashCategory(let id):
            guard let category = CleanupCategory(rawValue: id), bulkCategories.contains(category) else { return [] }
            return CleanupSafety.uniqueURLs(items(in: category, context).map(\.url))
        case .trashDuplicateCopies:
            return CleanupSafety.uniqueURLs(CleanupSafety.extraDuplicateCopies(context.items, keep: context.keep).map(\.url))
        case .disableStartupItem, .review:
            return []
        }
    }

    static func cards(_ context: SuggestionContext, ai: [SuggestionProposal] = []) -> [SuggestionCard] {
        let caps = capabilities(context)
        return SuggestionMerger.merge(rules: rules(context), ai: ai, capabilities: caps) { facts($0, context) }
    }

    /// Compact JSON for the model: categories with sizes and counts, duplicate totals, broken startup items by name,
    /// protection status and the allowlist. No file names, folder names or paths.
    static func snapshot(_ context: SuggestionContext) -> Data {
        let caps = capabilities(context)
        var categories: [[String: Any]] = []
        for category in CleanupCategory.allCases {
            let list = items(in: category, context)
            guard !list.isEmpty, category != .duplicates, category != .custom else { continue }
            let bytes = list.reduce(0) { $0 + $1.size }
            categories.append(["id": category.rawValue, "title": category.title, "items": list.count, "bytes": bytes,
                               "size": bytes.formattedFileSize, "review_only": category.isReviewOnly,
                               "rebuildable": category.isRebuildable, "bulk_action_allowed": caps.trashableCategories.contains(category.rawValue)])
        }
        let copies = CleanupSafety.extraDuplicateCopies(context.items, keep: context.keep)
        let groups = Set(context.items.compactMap(\.duplicateGroupID)).count
        let copyBytes = copies.reduce(0) { $0 + $1.size }
        var payload: [String: Any] = [
            "app": "MacSweep", "platform": "macOS",
            "categories": categories,
            "duplicates": ["groups": groups, "extra_copies": copies.count, "bytes": copyBytes, "size": copyBytes.formattedFileSize,
                           "kept_copy": context.keep.rawValue],
            "startup": ["definitions": context.startup.count,
                        "broken": context.startup.filter(\.isBroken).prefix(20).map {
                            ["id": $0.suggestionKey, "name": String($0.displayName.prefix(80)), "can_switch_off": $0.canSwitchOff,
                             "problem": $0.brokenReason?.contains("drive") == true ? "drive not connected" : "program missing"] as [String: Any]
                        }],
            "allowed_actions": caps.allowlist,
            "rules_suggest": rules(context).map(\.action.signature),
        ]
        var protection: [String: Any] = [:]
        if let gatekeeper = context.protection?.gatekeeperOn { protection["gatekeeper_on"] = gatekeeper }
        if let age = context.protection?.xprotectAgeDays { protection["xprotect_age_days"] = age }
        if let pending = context.protection?.pendingMacOSUpdates { protection["pending_macos_updates"] = pending.count }
        if let outdated = context.homebrewOutdated { protection["homebrew_outdated"] = outdated }
        if !protection.isEmpty { payload["protection"] = protection }
        return (try? JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])) ?? Data("{}".utf8)
    }
}

/// "Space you could free": the dashboard breakdown after a scan.
struct SpaceBreakdown: Equatable, Sendable {
    struct Line: Equatable, Sendable, Identifiable {
        let category: CleanupCategory
        let bytes: Int64
        let count: Int
        var id: CleanupCategory { category }
    }

    var readyToClean: [Line] = []   // rebuildable caches, logs and reports
    var reviewFirst: [Line] = []    // personal files: downloads, duplicates' extra copies, large files, added folders
    var reviewOnly: [Line] = []     // never cleaned by MacSweep

    var readyBytes: Int64 { readyToClean.reduce(0) { $0 + $1.bytes } }
    var reviewBytes: Int64 { reviewFirst.reduce(0) { $0 + $1.bytes } }
    var reviewOnlyBytes: Int64 { reviewOnly.reduce(0) { $0 + $1.bytes } }
    /// What MacSweep could move to the Trash (ready + review first). Review-only space is reported separately.
    var totalBytes: Int64 { readyBytes + reviewBytes }

    static func compute(_ items: [CleanupItem], keep: CleanupSafety.DuplicateKeep = .oldest) -> SpaceBreakdown {
        var result = SpaceBreakdown()
        // A file can show up in two categories (an old download that is also a duplicate); count it once.
        var seen = Set<String>()
        for category in CleanupCategory.allCases {
            let list: [CleanupItem] = (category == .duplicates
                ? CleanupSafety.extraDuplicateCopies(items, keep: keep)
                : CleanupSafety.uniqueItems(items.filter { $0.category == category }))
                .filter { seen.insert(ProtectionRules.normalizedPath($0.url).lowercased()).inserted }
            guard !list.isEmpty else { continue }
            let line = Line(category: category, bytes: list.reduce(0) { $0 + $1.size }, count: list.count)
            if category.isReviewOnly { result.reviewOnly.append(line) }
            else if category.isRebuildable { result.readyToClean.append(line) }
            else { result.reviewFirst.append(line) }
        }
        for keyPath in [\SpaceBreakdown.readyToClean, \.reviewFirst, \.reviewOnly] {
            result[keyPath: keyPath].sort { $0.bytes > $1.bytes }
        }
        return result
    }
}
