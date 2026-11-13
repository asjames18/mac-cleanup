import Combine
import Foundation

/// What the fast-moving dashboard widgets show, already rounded to what is displayed, so an update
/// that would not change a pixel does not invalidate any view.
struct FastReadings: Equatable, Sendable {
    var cpuPercent: Int?
    var memoryText: String = "—"
    /// Rounded to whole percent.
    var memoryFraction: Double?
    var memoryPressure: String = "Unavailable"
    var updatedText: String?

    init() {}

    init(_ snapshot: SystemSnapshot) {
        cpuPercent = snapshot.cpuUsage.map { Int(($0 * 100).rounded()) }
        memoryText = snapshot.memoryUsed.map(\.formattedFileSize) ?? "—"
        memoryFraction = snapshot.memoryUsed.flatMap { used in
            snapshot.memoryTotal > 0 ? (Double(used) / Double(snapshot.memoryTotal) * 100).rounded() / 100 : nil
        }
        memoryPressure = snapshot.memoryPressure
        updatedText = snapshot.updatedAt.map { $0.formatted(date: .omitted, time: .standard) }
    }

    var cpuText: String { cpuPercent.map { "\($0)%" } ?? "—" }
    var cpuFraction: Double? { cpuPercent.map { Double($0) / 100 } }
}

/// Slow-moving facts (disk space, memory pressure) used by the health card and the sidebar.
struct SlowReadings: Equatable, Sendable {
    var diskFreeText: String?
    /// Rounded to 0.1%.
    var diskUsedFraction: Double?
    /// Rounded to 100 MB so the health score is not recomputed for every byte the disk changes.
    var diskFree: Int64?
    var diskTotal: Int64?
    var memoryPressure: String?

    init() {}

    init(_ snapshot: SystemSnapshot) {
        let step: Int64 = 100_000_000
        diskFree = snapshot.diskFree.map { ($0 / step) * step }
        diskTotal = snapshot.diskTotal
        diskFreeText = snapshot.diskFree.map(\.formattedFileSize)
        if let free = snapshot.diskFree, let total = snapshot.diskTotal, total > 0 {
            diskUsedFraction = (Double(total - free) / Double(total) * 1000).rounded() / 1000
        }
        memoryPressure = snapshot.updatedAt == nil ? nil : snapshot.memoryPressure
    }
}

/// What the health score needs, rounded to whole gigabytes (the score's thresholds are in GB), so disk churn
/// from other apps does not recompute or redraw the health card.
struct HealthInputs: Equatable, Sendable {
    var diskFree: Int64?
    var diskTotal: Int64?
    var memoryPressure: String?

    init() {}

    init(_ snapshot: SystemSnapshot) {
        let gigabyte: Int64 = 1_000_000_000
        diskFree = snapshot.diskFree.map { ($0 / gigabyte) * gigabyte }
        diskTotal = snapshot.diskTotal
        memoryPressure = snapshot.updatedAt == nil ? nil : snapshot.memoryPressure
    }
}

/// A tiny observable box that only notifies when its value actually changes.
@MainActor
final class ReadingStore<Value: Equatable>: ObservableObject {
    @Published private(set) var value: Value
    private(set) var changes = 0

    init(_ value: Value) { self.value = value }

    func update(_ newValue: Value) {
        guard newValue != value else { return }
        value = newValue
        changes += 1
    }
}
