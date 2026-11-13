import Foundation

struct HealthIssue: Identifiable, Equatable, Sendable {
    enum Severity: String, Sendable { case bad, warn, info }
    let text: String
    let severity: Severity
    let destination: MainViewMode
    var id: String { text }
}

struct HealthSummary: Equatable, Sendable {
    let score: Int
    let label: String
    let issues: [HealthIssue]
}

/// A simple 0–100 score from facts MacSweep already has (ported from Mac Cleanup's HealthScore).
enum HealthScore {
    static let gigabyte: Int64 = 1_073_741_824

    static func summarize(diskFree: Int64?, diskTotal: Int64?, duplicateWaste: Int64, oldDownloadBytes: Int64,
                          memoryPressure: String?, scanned: Bool) -> HealthSummary {
        var score = 100
        var issues: [HealthIssue] = []
        func hit(_ points: Int, _ text: String, _ severity: HealthIssue.Severity, _ destination: MainViewMode) {
            score -= points
            issues.append(HealthIssue(text: text, severity: severity, destination: destination))
        }
        if let free = diskFree, let total = diskTotal, total > 0 {
            let ratio = Double(free) / Double(total)
            if ratio < 0.05 { hit(30, "Your disk is nearly out of space (\(free.formattedFileSize) free).", .bad, .storage) }
            else if ratio < 0.10 { hit(20, "Your disk is almost full (\(free.formattedFileSize) free).", .bad, .storage) }
            else if ratio < 0.20 { hit(8, "Your disk is getting full (\(free.formattedFileSize) free).", .warn, .storage) }
        }
        switch memoryPressure {
        case "Critical": hit(20, "Memory pressure is critical. Quit apps you are not using.", .bad, .overview)
        case "Warning": hit(8, "Memory pressure is elevated.", .warn, .overview)
        default: break
        }
        if duplicateWaste >= 10 * gigabyte {
            hit(12, "\(duplicateWaste.formattedFileSize) of duplicate copies can be reviewed.", .warn, .cleanup)
        } else if duplicateWaste >= gigabyte {
            hit(6, "\(duplicateWaste.formattedFileSize) of duplicate copies can be reviewed.", .warn, .cleanup)
        }
        if oldDownloadBytes >= 10 * gigabyte {
            hit(10, "\(oldDownloadBytes.formattedFileSize) of old downloads can be reviewed.", .warn, .cleanup)
        } else if oldDownloadBytes >= gigabyte {
            hit(5, "\(oldDownloadBytes.formattedFileSize) of old downloads can be reviewed.", .warn, .cleanup)
        }
        if !scanned {
            issues.append(HealthIssue(text: "Run Smart Scan to check downloads and duplicates.", severity: .info, destination: .cleanup))
        }
        score = min(100, max(0, score))
        return HealthSummary(score: score, label: label(for: score), issues: issues)
    }

    /// Bands: 85-100 looking good, 60-84 review, below 60 needs attention. One serious problem
    /// (a nearly full disk or critical memory pressure) lands in review; two together, or a nearly
    /// full disk plus heavy clutter, need attention.
    static func label(for score: Int) -> String {
        score >= 85 ? "Looking good" : score >= 60 ? "A few things to review" : "Needs attention"
    }

    /// Duplicate bytes beyond the retained (oldest) copy of each group.
    static func duplicateWaste(_ items: [CleanupItem]) -> Int64 {
        let retained = CleanupSafety.retainedCopies(items)
        return CleanupSafety.uniqueItems(items.filter { item in
            item.category == .duplicates && !retained.contains { $0.id == item.id }
        }).reduce(0) { $0 + $1.size }
    }

    static func oldDownloads(_ items: [CleanupItem]) -> Int64 {
        CleanupSafety.uniqueItems(items.filter { $0.category == .downloads }).reduce(0) { $0 + $1.size }
    }
}
