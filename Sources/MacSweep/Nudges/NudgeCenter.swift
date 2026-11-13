import AppKit
import Combine
import Foundation
import MacSweepCore

/// Saved as nudges.json next to settings.json. Written atomically, only when something changed.
struct NudgeFile: Codable, Equatable {
    var version = 1
    var preferences = NudgePreferences()
    var state = NudgeState()
}

/// Owns the nudge rules, remembers their state between launches and posts banners.
@MainActor
final class NudgeCenter: ObservableObject {
    typealias Poster = @MainActor (Nudge) async -> Void

    @Published private(set) var active: [Nudge] = []
    @Published private(set) var preferences: NudgePreferences
    @Published private(set) var lastBanner: Nudge?

    private var engine: NudgeEngine
    private let fileURL: URL?
    private let poster: Poster
    var now: () -> Date = { Date() }

    static var defaultURL: URL { SettingsStore.defaultRoot.appendingPathComponent("nudges.json") }

    init(fileURL: URL? = NudgeCenter.defaultURL, calendar: Calendar = .current, poster: Poster? = nil) {
        self.fileURL = fileURL
        let saved = fileURL.flatMap { try? JSONCoding.decoder().decode(NudgeFile.self, from: Data(contentsOf: $0)) } ?? NudgeFile()
        engine = NudgeEngine(preferences: saved.preferences, state: saved.state, calendar: calendar)
        preferences = saved.preferences
        self.poster = poster ?? { nudge in
            _ = await NotificationService.shared.post(id: nudge.id, title: nudge.title, body: nudge.message,
                                                      category: NudgeActions.category(for: nudge),
                                                      userInfo: ["nudge": nudge.id, "kind": nudge.kind.rawValue, "key": nudge.key])
        }
        active = engine.activeNudges(now: Date())
    }

    var worstSeverity: NudgeSeverity? { active.map(\.severity).max() }

    func nudge(id: String) -> Nudge? { active.first { $0.id == id } }

    @discardableResult
    func ingest(_ observations: [NudgeObservation], bannersAllowed: @autoclosure () -> Bool = true) -> [Nudge] {
        let before = NudgeFile(preferences: engine.preferences, state: engine.state)
        let at = now()
        // Most samples produce no banner, so the (window-list) check behind `bannersAllowed` runs only when one is due.
        var trial = engine
        var result = trial.ingest(observations, now: at, bannersAllowed: true)
        if result.banners.isEmpty {
            engine = trial
        } else {
            result = engine.ingest(observations, now: at, bannersAllowed: bannersAllowed())
        }
        publishActive(result.active, at: at)
        for nudge in result.banners {
            lastBanner = nudge
            let post = poster
            Task { @MainActor in await post(nudge) }
        }
        saveIfChanged(from: before, throttlingWording: true, at: at)
        return result.banners
    }

    func snooze(_ nudge: Nudge, for interval: TimeInterval) {
        change { $0.snooze(id: nudge.id, until: now().addingTimeInterval(interval)) }
    }

    func snooze(kind: NudgeKind, for interval: TimeInterval) {
        change { $0.snooze(kind: kind, until: now().addingTimeInterval(interval)) }
    }

    func ignore(process name: String) { change { $0.ignore(process: name) } }

    func unignore(process name: String) {
        change { $0.preferences.ignoredProcesses.removeAll { $0.caseInsensitiveCompare(name) == .orderedSame } }
    }

    func updatePreferences(_ update: (inout NudgePreferences) -> Void) {
        change { update(&$0.preferences) }
    }

    func setKind(_ kind: NudgeKind, enabled: Bool) {
        updatePreferences { prefs in
            prefs.disabledKinds.removeAll { $0 == kind }
            if !enabled { prefs.disabledKinds.append(kind) }
        }
    }

    func isSnoozed(_ nudge: Nudge) -> Bool { engine.isSnoozed(nudge, now: now()) }
    var bannersToday: Int { engine.bannersToday(now()) }

    private func change(_ update: (inout NudgeEngine) -> Void) {
        let before = NudgeFile(preferences: engine.preferences, state: engine.state)
        update(&engine)
        // Re-evaluate with no new readings so toggles and ignores apply at once.
        let result = engine.ingest([], now: now(), bannersAllowed: false)
        active = result.active
        preferences = engine.preferences
        saveIfChanged(from: before)
    }

    /// Live nudges reword themselves on every sample ("CPU at 93%…"). Rewording alone is shown at most once a
    /// minute and saved at most every 5 minutes; a nudge appearing, clearing or changing severity is immediate.
    static let rewordInterval: TimeInterval = 60
    static let rewordSaveInterval: TimeInterval = 300
    private var lastActivePublish: Date = .distantPast
    private var lastSave: Date = .distantPast
    private(set) var activePublishes = 0
    private(set) var saves = 0

    nonisolated static func sameShape(_ a: [Nudge], _ b: [Nudge]) -> Bool {
        a.count == b.count && zip(a, b).allSatisfy { lhs, rhs in
            var lhs = lhs, rhs = rhs
            lhs.message = ""; rhs.message = ""
            return lhs == rhs
        }
    }

    private func publishActive(_ next: [Nudge], at: Date) {
        guard active != next else { return }
        if Self.sameShape(active, next), at.timeIntervalSince(lastActivePublish) < Self.rewordInterval { return }
        active = next
        lastActivePublish = at
        activePublishes += 1
    }

    private func saveIfChanged(from before: NudgeFile, throttlingWording: Bool = false, at: Date? = nil) {
        let after = NudgeFile(preferences: engine.preferences, state: engine.state)
        guard after != before, let fileURL else { return }
        if throttlingWording, let at {
            var a = before, b = after
            for key in a.state.active.keys { a.state.active[key]?.message = "" }
            for key in b.state.active.keys { b.state.active[key]?.message = "" }
            if a == b, at.timeIntervalSince(lastSave) < Self.rewordSaveInterval { return }
            lastSave = at
        }
        saves += 1
        do {
            try FileManager.default.createDirectory(at: fileURL.deletingLastPathComponent(), withIntermediateDirectories: true)
            try JSONCoding.encoder().encode(after).write(to: fileURL, options: .atomic)
        } catch {
            NSLog("MacSweep could not save nudges: \(error.localizedDescription)")
        }
    }
}

/// Notification categories and their buttons. Every button that changes something opens MacSweep
/// and asks "Do you really want to do this action?" there; buttons never act from the banner alone.
enum NudgeActions {
    static let open = "open"
    static let snoozeHour = "snooze.1h"
    static let snoozeDay = "snooze.1d"
    static let reviewProcess = "process.review"
    static let ignoreProcess = "process.ignore"

    static func category(for nudge: Nudge) -> String {
        nudge.kind == .runawayProcess ? "macsweep.process" : "macsweep.nudge"
    }
}
