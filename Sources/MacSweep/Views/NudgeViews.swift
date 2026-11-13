import AppKit
import MacSweepCore
import SwiftUI

extension NudgeSeverity {
    var color: Color {
        switch self {
        case .bad: Theme.danger
        case .warn: Theme.warn
        case .info: Theme.info
        }
    }

    var symbol: String {
        switch self {
        case .bad: "exclamationmark.octagon.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .info: "info.circle.fill"
        }
    }
}

/// Dashboard card listing what currently needs attention.
struct NudgesCard: View {
    @ObservedObject var monitor: NudgeMonitor
    @ObservedObject var center: NudgeCenter
    let handler: NudgeActionHandler

    private var rows: [Nudge] { center.active.filter { $0.kind != .fullDiskAccess } }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            if monitor.lastHealthResults?.fullDiskAccess == false && center.preferences.allows(.fullDiskAccess) {
                FullDiskAccessCard(monitor: monitor, handler: handler)
            }
            SuiteCard {
                VStack(alignment: .leading, spacing: 14) {
                    HStack {
                        Label("Smart nudges", systemImage: "bell.badge").font(.headline)
                        if !rows.isEmpty { Chip(text: "\(rows.count)", color: rows.first?.severity.color ?? Theme.info) }
                        Spacer()
                        Button("Check Now") { monitor.runHealthChecks(); monitor.requestSample?() }
                            .help("Runs the security, drive, battery and startup checks again")
                    }
                    if !center.preferences.enabled {
                        Text("Smart nudges are off. Turn them on in Settings → Smart nudges.")
                            .font(.callout).foregroundStyle(Theme.muted)
                    } else if rows.isEmpty {
                        Label("Nothing needs your attention. MacSweep keeps an eye on CPU, memory, heat, disk, battery and security in the background.",
                              systemImage: "checkmark.seal").font(.callout).foregroundStyle(Theme.muted)
                    } else {
                        ForEach(rows) { nudge in NudgeRow(nudge: nudge, center: center, handler: handler) }
                    }
                }
            }
        }
    }
}

struct NudgeRow: View {
    let nudge: Nudge
    @ObservedObject var center: NudgeCenter
    let handler: NudgeActionHandler

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: nudge.severity.symbol).foregroundStyle(nudge.severity.color).font(.title3)
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(nudge.kind == .runawayProcess ? "\(nudge.title): \(nudge.key)" : nudge.title).font(.callout.weight(.semibold))
                    if center.isSnoozed(nudge) { Chip(text: "Snoozed", color: Theme.muted) }
                    Spacer()
                    Text(nudge.since, style: .relative).font(.caption).foregroundStyle(Theme.muted)
                }
                Text(nudge.message).font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    ForEach(NudgeActionHandler.actions(for: nudge)) { action in
                        Button { handler.perform(action) } label: { Label(action.title, systemImage: action.systemImage) }
                            .controlSize(.small)
                    }
                    Menu("Snooze") {
                        Button("1 hour") { center.snooze(nudge, for: 3600) }
                        Button("Until tomorrow") { center.snooze(nudge, for: NudgeActionHandler.untilTomorrowMorning(from: Date())) }
                        Button("1 week") { center.snooze(nudge, for: 7 * 86400) }
                    }.controlSize(.small).fixedSize()
                }
            }
        }
        .padding(12)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: 10))
    }
}

struct FullDiskAccessCard: View {
    @ObservedObject var monitor: NudgeMonitor
    let handler: NudgeActionHandler

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "lock.open.display").font(.title2).foregroundStyle(Theme.info)
            VStack(alignment: .leading, spacing: 4) {
                Text("Grant Full Disk Access").font(.headline)
                Text("Lets MacSweep also read system crash reports and check every startup item. MacSweep only reads; you turn this on yourself in System Settings → Privacy & Security → Full Disk Access.")
                    .font(.callout).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
            Spacer()
            VStack(spacing: 6) {
                Button("Open Settings…") {
                    handler.perform(NudgeUIAction(title: "Grant", systemImage: "", kind: .grantFullDiskAccess))
                }.buttonStyle(.borderedProminent).tint(Theme.accent)
                Button("Check Again") { monitor.runHealthChecks() }.controlSize(.small)
            }
        }
        .padding(16)
        .background(Theme.info.opacity(0.08), in: RoundedRectangle(cornerRadius: Theme.radius))
        .overlay { RoundedRectangle(cornerRadius: Theme.radius).strokeBorder(Theme.info.opacity(0.35)) }
    }
}

/// Top of the menu bar popover.
struct MenuBarNudgeList: View {
    @ObservedObject var center: NudgeCenter
    let handler: NudgeActionHandler

    var body: some View {
        let rows = Array(center.active.filter { $0.severity >= .warn }.prefix(3))
        if !rows.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Needs attention").font(.caption.weight(.semibold)).foregroundStyle(Theme.muted)
                ForEach(rows) { nudge in
                    Button { handler.showMain(.overview) } label: {
                        HStack(alignment: .top, spacing: 8) {
                            Image(systemName: nudge.severity.symbol).foregroundStyle(nudge.severity.color)
                            VStack(alignment: .leading, spacing: 2) {
                                Text(nudge.kind == .runawayProcess ? nudge.key : nudge.title).font(.callout.weight(.medium))
                                Text(nudge.message).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                            }
                        }
                    }.buttonStyle(.plain)
                }
            }
        }
    }
}

/// The menu bar icon: sparkles, with an amber or red dot while something needs attention.
struct MenuBarIcon: View {
    @ObservedObject var center: NudgeCenter
    let handler: NudgeActionHandler
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Image(nsImage: Self.image(for: center.worstSeverity))
            .onAppear { handler.openMainWindow = { openWindow(id: "main") } }
    }

    static func image(for severity: NudgeSeverity?) -> NSImage {
        let base = NSImage(systemSymbolName: "sparkles", accessibilityDescription: "MacSweep") ?? NSImage()
        guard let severity, severity >= .warn else {
            base.isTemplate = true
            return base
        }
        let dot: NSColor = severity == .bad ? NSColor(red: 1, green: 0.365, blue: 0.451, alpha: 1)
            : NSColor(red: 1, green: 0.663, blue: 0.302, alpha: 1)
        let image = NSImage(size: NSSize(width: 22, height: 16), flipped: false) { _ in
            let symbol = base.withSymbolConfiguration(.init(pointSize: 13, weight: .regular)
                .applying(.init(paletteColors: [NSColor.labelColor]))) ?? base
            symbol.draw(in: NSRect(x: 0, y: 0, width: 17, height: 16))
            dot.setFill()
            NSBezierPath(ovalIn: NSRect(x: 14, y: 8, width: 7, height: 7)).fill()
            return true
        }
        image.isTemplate = false
        image.accessibilityDescription = "MacSweep: \(severity == .bad ? "needs attention" : "something to review")"
        return image
    }
}

/// Settings → Smart nudges.
struct NudgeSettingsSection: View {
    @ObservedObject var monitor: NudgeMonitor
    @ObservedObject var center: NudgeCenter
    @State private var authorization: NotificationService.Authorization = .unknown
    @State private var loginStatus: LoginItemService.Status = .unknown
    @State private var loginError: String?
    var confirm: (String, String) -> Bool = { _, _ in false }

    private static let hours = Array(0..<24)

    var body: some View {
        Section("Smart nudges") {
            Toggle("Watch for things slowing down your Mac", isOn: binding(\.enabled))
            Toggle("Open MacSweep at login (menu bar only)", isOn: Binding(
                get: { loginStatus == .enabled || loginStatus == .requiresApproval },
                set: { setLoginItem($0) }
            ))
            if loginStatus == .requiresApproval {
                HStack {
                    Text("macOS needs you to allow MacSweep in Login Items.").font(.caption).foregroundStyle(Theme.warn)
                    Spacer()
                    Button("Open Login Items") { LoginItemService.openLoginItemsSettings() }
                }
            }
            if let loginError { Text(loginError).font(.caption).foregroundStyle(Theme.danger) }
            Toggle("Show notifications (at most \(center.preferences.dailyBannerLimit) a day)", isOn: binding(\.bannersEnabled))
                .disabled(!center.preferences.enabled)
            HStack {
                Text("Notifications: \(authorizationText)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if authorization == .notDetermined {
                    Button("Allow Notifications…") {
                        Task { _ = await NotificationService.shared.requestAuthorization(); await refresh() }
                    }
                } else if authorization == .denied {
                    Button("Open Notification Settings") { NotificationService.shared.openNotificationSettings() }
                }
            }
            HStack {
                Picker("Quiet from", selection: minutes(\.quietStart)) {
                    ForEach(Self.hours, id: \.self) { Text(Self.hourText($0)).tag($0 * 60) }
                }
                Picker("to", selection: minutes(\.quietEnd)) {
                    ForEach(Self.hours, id: \.self) { Text(Self.hourText($0)).tag($0 * 60) }
                }
            }
            Text("No banners during quiet hours, except a nearly full disk or a failing drive. Nudges still appear on the dashboard and in the menu bar.")
                .font(.caption).foregroundStyle(.secondary)
            DisclosureGroup("What to watch") {
                ForEach(NudgeKind.allCases, id: \.self) { kind in
                    Toggle(kind.title, isOn: Binding(
                        get: { !center.preferences.disabledKinds.contains(kind) },
                        set: { center.setKind(kind, enabled: $0) }
                    ))
                }
            }
            if !center.preferences.ignoredProcesses.isEmpty {
                DisclosureGroup("Ignored processes") {
                    ForEach(center.preferences.ignoredProcesses, id: \.self) { name in
                        HStack {
                            Text(name)
                            Spacer()
                            Button("Stop Ignoring") { center.unignore(process: name) }
                        }
                    }
                }
            }
            HStack {
                Text("Full Disk Access: \(fdaText)").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if monitor.lastHealthResults?.fullDiskAccess != true {
                    Button("Grant Full Disk Access…") { HealthCheckRunner.openFullDiskAccessSettings() }
                }
                Button("Check Now") { monitor.runHealthChecks() }
            }
            Text("Checks run on this Mac only: live readings every 30 seconds in the background (60 on battery), and security, drive, battery and startup checks every 6 hours. Nothing is sent anywhere.")
                .font(.caption).foregroundStyle(.secondary)
        }
        .task { await refresh() }
    }

    private var authorizationText: String {
        switch authorization {
        case .authorized, .provisional, .ephemeral: "allowed"
        case .denied: "not allowed (nudges still show here and in the menu bar)"
        case .notDetermined: "not set up yet"
        case .unavailable: "unavailable outside the app"
        case .unknown: "checking…"
        }
    }

    private var fdaText: String {
        switch monitor.lastHealthResults?.fullDiskAccess {
        case true?: "granted"
        case false?: "not granted (some checks are limited)"
        case nil: "not checked yet"
        }
    }

    private func refresh() async {
        authorization = await NotificationService.shared.authorization()
        loginStatus = LoginItemService.status
    }

    private func setLoginItem(_ on: Bool) {
        loginError = nil
        let detail = on
            ? "Open MacSweep automatically when you log in? It starts in the menu bar only and keeps watching for slowdowns. You can turn this off here or in Login Items settings."
            : "Stop opening MacSweep at login? Smart nudges will only run while MacSweep is open."
        guard confirm(ConfirmationLedger.title, detail) else { return }
        do { try on ? LoginItemService.register() : LoginItemService.unregister() }
        catch { loginError = "macOS did not accept the change: \(error.localizedDescription)" }
        loginStatus = LoginItemService.status
    }

    private func binding(_ key: WritableKeyPath<NudgePreferences, Bool>) -> Binding<Bool> {
        Binding(get: { center.preferences[keyPath: key] }, set: { value in center.updatePreferences { $0[keyPath: key] = value } })
    }

    private func minutes(_ key: WritableKeyPath<NudgePreferences, Int>) -> Binding<Int> {
        Binding(get: { center.preferences[keyPath: key] / 60 * 60 }, set: { value in center.updatePreferences { $0[keyPath: key] = value } })
    }

    static func hourText(_ hour: Int) -> String {
        let suffix = hour < 12 ? "AM" : "PM"
        let h = hour % 12 == 0 ? 12 : hour % 12
        return "\(h) \(suffix)"
    }
}
