import Foundation

/// What a nudge is about. Each kind has its own toggle and cooldown.
public enum NudgeKind: String, Codable, CaseIterable, Sendable {
    case cpuSustained, memoryPressure, swapGrowth, runawayProcess, thermal
    case diskLow, diskTrend, driveHealth, battery
    case loginItems, unsignedAgent, uptime, crashes
    case sip, gatekeeper, fileVault, firewall, xprotect, updates
    case fullDiskAccess

    public enum Group: String, Codable, Sendable { case performance, storage, health, security }

    public var group: Group {
        switch self {
        case .cpuSustained, .memoryPressure, .swapGrowth, .runawayProcess, .thermal: .performance
        case .diskLow, .diskTrend: .storage
        case .driveHealth, .battery, .loginItems, .unsignedAgent, .uptime, .crashes, .fullDiskAccess: .health
        case .sip, .gatekeeper, .fileVault, .firewall, .xprotect, .updates: .security
        }
    }

    /// Minimum time between two banners for the same nudge.
    public var cooldown: TimeInterval {
        switch group {
        case .performance: 4 * 3600
        case .storage: 12 * 3600
        case .health, .security: 7 * 86400
        }
    }

    public var title: String {
        switch self {
        case .cpuSustained: "High CPU use"
        case .memoryPressure: "Memory pressure"
        case .swapGrowth: "Swap growing"
        case .runawayProcess: "Runaway process"
        case .thermal: "Mac running hot"
        case .diskLow: "Disk space low"
        case .diskTrend: "Disk filling up"
        case .driveHealth: "Drive health"
        case .battery: "Battery health"
        case .loginItems: "Startup items"
        case .unsignedAgent: "Unsigned startup items"
        case .uptime: "Restart recommended"
        case .crashes: "Repeated crashes"
        case .sip: "System Integrity Protection"
        case .gatekeeper: "Gatekeeper"
        case .fileVault: "FileVault"
        case .firewall: "Firewall"
        case .xprotect: "XProtect definitions"
        case .updates: "macOS updates"
        case .fullDiskAccess: "Full Disk Access"
        }
    }
}

public enum NudgeSeverity: String, Codable, Comparable, Sendable {
    case info, warn, bad

    private var rank: Int { switch self { case .info: 0; case .warn: 1; case .bad: 2 } }
    public static func < (lhs: NudgeSeverity, rhs: NudgeSeverity) -> Bool { lhs.rank < rhs.rank }
}

/// One reading from a signal. `trigger` starts (or keeps) a nudge, `clear` ends it, and
/// `hold` sits between the two thresholds (hysteresis), so a nudge neither starts nor ends.
public struct NudgeObservation: Equatable, Sendable {
    public enum Condition: String, Sendable { case trigger, hold, clear }

    public var kind: NudgeKind
    /// Distinguishes several nudges of one kind, such as one per process. Empty for most kinds.
    public var key: String
    public var condition: Condition
    public var severity: NudgeSeverity
    public var message: String
    /// How long `trigger` must hold continuously before the nudge becomes active.
    public var sustain: TimeInterval
    /// Allowed to show a banner during quiet hours (nearly full disk, failing drive).
    public var urgent: Bool

    public init(kind: NudgeKind, key: String = "", condition: Condition, severity: NudgeSeverity = .warn,
                message: String = "", sustain: TimeInterval = 0, urgent: Bool = false) {
        self.kind = kind; self.key = key; self.condition = condition; self.severity = severity
        self.message = message; self.sustain = sustain; self.urgent = urgent
    }

    public var id: String { Nudge.makeID(kind, key) }
}

public struct Nudge: Codable, Equatable, Identifiable, Sendable {
    public var kind: NudgeKind
    public var key: String
    public var severity: NudgeSeverity
    public var message: String
    public var since: Date
    public var urgent: Bool
    /// Whether a banner was shown since this nudge last became active or escalated.
    public var bannerShown: Bool

    public init(kind: NudgeKind, key: String = "", severity: NudgeSeverity, message: String, since: Date,
                urgent: Bool = false, bannerShown: Bool = false) {
        self.kind = kind; self.key = key; self.severity = severity; self.message = message
        self.since = since; self.urgent = urgent; self.bannerShown = bannerShown
    }

    public var id: String { Nudge.makeID(kind, key) }
    public var title: String { kind.title }

    public static func makeID(_ kind: NudgeKind, _ key: String) -> String {
        key.isEmpty ? kind.rawValue : "\(kind.rawValue):\(key)"
    }
}

public struct NudgePreferences: Codable, Equatable, Sendable {
    public var enabled = true
    public var bannersEnabled = true
    public var disabledKinds: [NudgeKind] = []
    /// Minutes after midnight, local time. Default 10 PM to 8 AM.
    public var quietStart = 22 * 60
    public var quietEnd = 8 * 60
    public var dailyBannerLimit = 3
    /// Process names that are expected to run hot (compilers, encoders) and never nudge.
    public var ignoredProcesses: [String] = []

    public init() {}

    public func allows(_ kind: NudgeKind) -> Bool { enabled && !disabledKinds.contains(kind) }

    public func isQuiet(_ date: Date, calendar: Calendar) -> Bool {
        let parts = calendar.dateComponents([.hour, .minute], from: date)
        let minute = (parts.hour ?? 0) * 60 + (parts.minute ?? 0)
        if quietStart == quietEnd { return false }
        return quietStart < quietEnd
            ? (minute >= quietStart && minute < quietEnd)
            : (minute >= quietStart || minute < quietEnd)
    }

    public func ignores(process name: String) -> Bool {
        ignoredProcesses.contains { $0.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public struct NudgeState: Codable, Equatable, Sendable {
    public var active: [String: Nudge] = [:]
    /// When a `trigger` first appeared without a clear since; used for sustained windows.
    public var pendingSince: [String: Date] = [:]
    public var lastBanner: [String: Date] = [:]
    /// Snoozes by nudge id, or by kind raw value to snooze a whole kind.
    public var snoozedUntil: [String: Date] = [:]
    /// Banners shown per local day, keyed "yyyy-MM-dd".
    public var bannersPerDay: [String: Int] = [:]

    public init() {}
}

/// Pure, deterministic rules: sustained windows, hysteresis, cooldowns, a daily banner budget,
/// quiet hours, snoozes and per-kind toggles. The app feeds it observations and shows what it returns.
public struct NudgeEngine: Sendable {
    public struct Result: Equatable, Sendable {
        /// Show these as notifications now.
        public var banners: [Nudge]
        /// Show these as cards and in the menu bar, most severe first.
        public var active: [Nudge]
    }

    public var preferences: NudgePreferences
    public var state: NudgeState
    public var calendar: Calendar

    public init(preferences: NudgePreferences = NudgePreferences(), state: NudgeState = NudgeState(),
                calendar: Calendar = .current) {
        self.preferences = preferences; self.state = state; self.calendar = calendar
    }

    /// `bannersAllowed` is false while, for example, a fullscreen app is in front; banners wait until later.
    public mutating func ingest(_ observations: [NudgeObservation], now: Date, bannersAllowed: Bool = true) -> Result {
        for observation in observations { apply(observation, now: now) }
        // Turned-off kinds and ignored processes disappear entirely.
        state.active = state.active.filter { _, nudge in visible(nudge) }
        pruneExpired(now: now)

        var banners: [Nudge] = []
        for id in state.active.keys.sorted(by: { order(state.active[$0]!, state.active[$1]!) }) {
            guard var nudge = state.active[id], !nudge.bannerShown, canBanner(nudge, now: now, bannersAllowed: bannersAllowed) else { continue }
            nudge.bannerShown = true
            state.active[id] = nudge
            state.lastBanner[id] = now
            state.bannersPerDay[dayKey(now), default: 0] += 1
            banners.append(nudge)
        }
        return Result(banners: banners, active: activeNudges(now: now))
    }

    public func activeNudges(now: Date) -> [Nudge] {
        state.active.values.filter(visible).sorted(by: order)
    }

    public mutating func snooze(id: String, until: Date) { state.snoozedUntil[id] = until }
    public mutating func snooze(kind: NudgeKind, until: Date) { state.snoozedUntil[kind.rawValue] = until }

    public mutating func ignore(process name: String) {
        guard !name.isEmpty, !preferences.ignores(process: name) else { return }
        preferences.ignoredProcesses.append(name)
        state.active = state.active.filter { _, nudge in visible(nudge) }
    }

    public func isSnoozed(_ nudge: Nudge, now: Date) -> Bool {
        [nudge.id, nudge.kind.rawValue].contains { (state.snoozedUntil[$0] ?? .distantPast) > now }
    }

    public func bannersToday(_ now: Date) -> Int { state.bannersPerDay[dayKey(now)] ?? 0 }

    // MARK: - Rules

    private mutating func apply(_ observation: NudgeObservation, now: Date) {
        let id = observation.id
        guard preferences.allows(observation.kind) else {
            state.active[id] = nil; state.pendingSince[id] = nil; return
        }
        switch observation.condition {
        case .clear:
            state.active[id] = nil
            state.pendingSince[id] = nil
        case .hold:
            // Keep an active nudge as it is; do not start one or extend a pending window.
            if state.active[id] == nil { state.pendingSince[id] = nil }
        case .trigger:
            if var nudge = state.active[id] {
                // Escalation (warn to bad) earns a fresh banner, still subject to cooldown and budget rules.
                if observation.severity > nudge.severity { nudge.bannerShown = false }
                nudge.severity = observation.severity
                nudge.message = observation.message
                nudge.urgent = observation.urgent
                state.active[id] = nudge
                return
            }
            let started = state.pendingSince[id] ?? now
            state.pendingSince[id] = started
            guard now.timeIntervalSince(started) >= observation.sustain else { return }
            state.pendingSince[id] = nil
            state.active[id] = Nudge(kind: observation.kind, key: observation.key, severity: observation.severity,
                                     message: observation.message, since: now, urgent: observation.urgent, bannerShown: false)
        }
    }

    private func canBanner(_ nudge: Nudge, now: Date, bannersAllowed: Bool) -> Bool {
        guard preferences.bannersEnabled, bannersAllowed, nudge.severity >= .warn, !isSnoozed(nudge, now: now) else { return false }
        if let last = state.lastBanner[nudge.id], now.timeIntervalSince(last) < nudge.kind.cooldown { return false }
        if preferences.isQuiet(now, calendar: calendar) && !(nudge.urgent && nudge.severity == .bad) { return false }
        return bannersToday(now) < preferences.dailyBannerLimit
    }

    private func visible(_ nudge: Nudge) -> Bool {
        guard preferences.allows(nudge.kind) else { return false }
        if nudge.kind == .runawayProcess, preferences.ignores(process: nudge.key) { return false }
        return true
    }

    private mutating func pruneExpired(now: Date) {
        state.snoozedUntil = state.snoozedUntil.filter { $0.value > now }
        let oldest = now.addingTimeInterval(-8 * 86400)
        state.lastBanner = state.lastBanner.filter { $0.value > oldest }
        let today = dayKey(now)
        state.bannersPerDay = state.bannersPerDay.filter { $0.key >= dayKey(oldest) || $0.key == today }
    }

    private func order(_ a: Nudge, _ b: Nudge) -> Bool {
        if a.severity != b.severity { return a.severity > b.severity }
        if a.since != b.since { return a.since < b.since }
        return a.id < b.id
    }

    private func dayKey(_ date: Date) -> String {
        let parts = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", parts.year ?? 0, parts.month ?? 0, parts.day ?? 0)
    }
}
