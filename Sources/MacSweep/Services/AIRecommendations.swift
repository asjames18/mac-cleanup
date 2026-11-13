import Foundation
import MacSweepCore

/// A suggested action. Applying one always goes through the confirm sheet and every safety check.
struct AIRecommendation: Identifiable, Equatable, Sendable {
    enum Action: Equatable, Sendable { case moveToTrash([URL]) }
    let id: String
    let title: String
    let detail: String
    let action: Action
    let reversible: Bool
}

/// Local, rule-based stub. There is no network client here: the `openai` provider is stored but
/// not connected, so it returns nothing and nothing leaves this Mac.
enum AIRecommender {
    static func recommendations(settings: AISettings, items: [CleanupItem]) -> [AIRecommendation] {
        guard settings.enabled, settings.provider == .rules else { return [] }
        let retained = CleanupSafety.retainedCopies(items)
        let downloads = CleanupSafety.uniqueItems(items.filter { $0.category == .downloads })
        let copies = items.filter { item in
            item.category == .duplicates && !retained.contains { ProtectionRules.contains(item.url, $0.url) }
        }
        var result: [AIRecommendation] = []
        if !downloads.isEmpty {
            let size = downloads.reduce(0) { $0 + $1.size }
            result.append(AIRecommendation(id: "old-downloads", title: "Move \(downloads.count) old downloads to Trash",
                                           detail: "Installers, archives and downloads untouched for 14 days · \(size.formattedFileSize).",
                                           action: .moveToTrash(downloads.map(\.url)), reversible: true))
        }
        if !copies.isEmpty {
            let size = copies.reduce(0) { $0 + $1.size }
            result.append(AIRecommendation(id: "duplicate-copies", title: "Move \(copies.count) extra duplicate copies to Trash",
                                           detail: "Keeps the oldest copy of each group · \(size.formattedFileSize).",
                                           action: .moveToTrash(copies.map(\.url)), reversible: true))
        }
        return result
    }
}
