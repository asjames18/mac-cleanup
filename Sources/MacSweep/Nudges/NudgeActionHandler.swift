import AppKit
import Foundation
import MacSweepCore
import UserNotifications

/// A button on a nudge card or banner.
struct NudgeUIAction: Identifiable, Equatable {
    enum Kind: Equatable {
        case show(MainViewMode)
        case openURL(String)
        case openApp(String)
        case quitProcess(String)
        case ignoreProcess(String)
        case grantFullDiskAccess
    }

    let title: String
    let systemImage: String
    let kind: Kind
    var id: String { title }
    /// Changes something, so it asks "Do you really want to do this action?" first.
    var needsConfirm: Bool {
        switch kind {
        case .quitProcess, .ignoreProcess: true
        default: false
        }
    }
}

/// Routes nudge buttons (cards, menu bar and notification actions). Everything that changes
/// the Mac or MacSweep's rules goes through the existing confirm first.
@MainActor
final class NudgeActionHandler {
    let model: AppModel
    let monitor: NudgeMonitor
    var center: NudgeCenter { monitor.center }
    /// Set by a view that can open the main window; falls back to reopening the app.
    var openMainWindow: (() -> Void)?

    static let activityMonitor = "/System/Applications/Utilities/Activity Monitor.app"
    static let diskUtility = "/System/Applications/Utilities/Disk Utility.app"
    static let console = "/System/Applications/Utilities/Console.app"
    static let softwareUpdate = "x-apple.systempreferences:com.apple.Software-Update-Settings.extension"
    static let privacySecurity = "x-apple.systempreferences:com.apple.settings.PrivacySecurity.extension"
    static let loginItems = "x-apple.systempreferences:com.apple.LoginItems-Settings.extension"
    static let battery = "x-apple.systempreferences:com.apple.Battery-Settings.extension"
    static let network = "x-apple.systempreferences:com.apple.Network-Settings.extension"

    init(model: AppModel, monitor: NudgeMonitor) {
        self.model = model
        self.monitor = monitor
    }

    static func actions(for nudge: Nudge) -> [NudgeUIAction] {
        let activity = NudgeUIAction(title: "Open Activity Monitor", systemImage: "waveform.path.ecg", kind: .openApp(activityMonitor))
        switch nudge.kind {
        case .runawayProcess:
            return [NudgeUIAction(title: "Quit \(nudge.key)…", systemImage: "xmark.circle", kind: .quitProcess(nudge.key)),
                    activity,
                    NudgeUIAction(title: "Ignore \(nudge.key)…", systemImage: "eye.slash", kind: .ignoreProcess(nudge.key))]
        case .cpuSustained, .memoryPressure, .swapGrowth, .thermal: return [activity]
        case .diskLow, .diskTrend:
            return [NudgeUIAction(title: "Open Storage", systemImage: "internaldrive", kind: .show(.storage)),
                    NudgeUIAction(title: "Smart Scan", systemImage: "sparkle.magnifyingglass", kind: .show(.cleanup))]
        case .driveHealth: return [NudgeUIAction(title: "Open Disk Utility", systemImage: "stethoscope", kind: .openApp(diskUtility))]
        case .battery: return [NudgeUIAction(title: "Battery Settings", systemImage: "battery.75percent", kind: .openURL(battery))]
        case .loginItems, .unsignedAgent:
            return [NudgeUIAction(title: "Review in Maintenance", systemImage: "slider.horizontal.3", kind: .show(.maintenance)),
                    NudgeUIAction(title: "Login Items Settings", systemImage: "person.crop.circle.badge.checkmark", kind: .openURL(loginItems))]
        case .uptime, .updates, .xprotect:
            return [NudgeUIAction(title: "Open Software Update", systemImage: "arrow.down.circle", kind: .openURL(softwareUpdate))]
        case .crashes: return [NudgeUIAction(title: "Open Console", systemImage: "doc.text.magnifyingglass", kind: .openApp(console))]
        case .gatekeeper, .fileVault, .sip:
            return [NudgeUIAction(title: "Privacy & Security", systemImage: "lock.shield", kind: .openURL(privacySecurity))]
        case .firewall: return [NudgeUIAction(title: "Network Settings", systemImage: "network", kind: .openURL(network))]
        case .fullDiskAccess:
            return [NudgeUIAction(title: "Grant Full Disk Access…", systemImage: "lock.open", kind: .grantFullDiskAccess)]
        }
    }

    func perform(_ action: NudgeUIAction) {
        switch action.kind {
        case .show(let mode):
            showMain(mode)
        case .openURL(let string):
            if let url = URL(string: string) { NSWorkspace.shared.open(url) }
        case .openApp(let path):
            NSWorkspace.shared.openApplication(at: URL(filePath: path), configuration: NSWorkspace.OpenConfiguration())
        case .grantFullDiskAccess:
            HealthCheckRunner.openFullDiskAccessSettings()
            model.showToast("Turn on MacSweep under Full Disk Access, then use Check Now.", kind: .info)
        case .quitProcess(let name):
            quit(processNamed: name)
        case .ignoreProcess(let name):
            guard model.confirm(title: ConfirmationLedger.title,
                                detail: "Stop nudging about \(name)? MacSweep will no longer warn when it runs hot. You can undo this in Settings → Smart nudges.") else { return }
            center.ignore(process: name)
            model.recordAction("nudge", "Ignored process \(name) after confirmation.")
            model.showToast("MacSweep will not nudge about \(name).", kind: .ok)
        }
    }

    func quit(processNamed name: String) {
        let targets = ProcessActions.targets(named: name)
        guard !targets.isEmpty else {
            model.showToast("\(name) is no longer running.", kind: .info)
            monitor.requestSample?()
            return
        }
        let list = targets.map { "\($0.name) (PID \($0.pid))" }.joined(separator: ", ")
        let detail = targets.contains(where: \.isApp)
            ? "MacSweep will ask \(list) to quit normally, so it can offer to save first. Unsaved work may be lost. This cannot be undone, but you can open it again."
            : "MacSweep will send \(list) a normal quit signal (SIGTERM). Unsaved work in it may be lost. This cannot be undone."
        guard model.confirm(title: ConfirmationLedger.title, detail: detail) else { return }
        let asked = ProcessActions.terminate(targets)
        model.recordAction("nudge", "Asked \(asked.count) of \(targets.count) \(name) processes to quit after confirmation.")
        model.showToast(asked.isEmpty ? "\(name) did not respond to Quit." : "Asked \(name) to quit.", kind: asked.isEmpty ? .warn : .ok)
        Task { @MainActor [weak monitor] in
            try? await Task.sleep(for: .seconds(2))
            monitor?.requestSample?()
        }
    }

    func showMain(_ mode: MainViewMode = .overview) {
        model.mainViewMode = mode
        NSApp.setActivationPolicy(.regular)
        WindowPresence.shared.mainWindowOpen = true
        if let window = NSApp.windows.first(where: { $0.identifier?.rawValue.contains("main") == true && $0.canBecomeMain }) {
            window.makeKeyAndOrderFront(nil)
        } else if let openMainWindow {
            openMainWindow()
        } else {
            NSWorkspace.shared.openApplication(at: Bundle.main.bundleURL, configuration: NSWorkspace.OpenConfiguration())
        }
        NSApp.activate(ignoringOtherApps: true)
    }

    // MARK: Notifications

    static var categories: Set<UNNotificationCategory> {
        let open = UNNotificationAction(identifier: NudgeActions.open, title: "Open MacSweep", options: [.foreground])
        let hour = UNNotificationAction(identifier: NudgeActions.snoozeHour, title: "Snooze 1 Hour")
        let day = UNNotificationAction(identifier: NudgeActions.snoozeDay, title: "Snooze Until Tomorrow")
        let review = UNNotificationAction(identifier: NudgeActions.reviewProcess, title: "Quit…", options: [.foreground])
        let ignore = UNNotificationAction(identifier: NudgeActions.ignoreProcess, title: "Ignore This App…", options: [.foreground])
        return [
            UNNotificationCategory(identifier: "macsweep.nudge", actions: [open, hour, day], intentIdentifiers: []),
            UNNotificationCategory(identifier: "macsweep.process", actions: [review, ignore, hour], intentIdentifiers: [])
        ]
    }

    func handleNotification(action: String, info: [String: String]) {
        let id = info["nudge"] ?? ""
        let key = info["key"] ?? ""
        let nudge = center.nudge(id: id)
        switch action {
        case NudgeActions.snoozeHour:
            if let nudge { center.snooze(nudge, for: 3600) }
        case NudgeActions.snoozeDay:
            if let nudge { center.snooze(nudge, for: Self.untilTomorrowMorning(from: Date())) }
        case NudgeActions.reviewProcess:
            showMain(.overview)
            if !key.isEmpty { quit(processNamed: key) }
        case NudgeActions.ignoreProcess:
            showMain(.overview)
            if !key.isEmpty { perform(NudgeUIAction(title: "Ignore", systemImage: "", kind: .ignoreProcess(key))) }
        default:
            showMain(.overview)
        }
    }

    /// Seconds until 8 AM tomorrow (local time).
    nonisolated static func untilTomorrowMorning(from now: Date, calendar: Calendar = .current) -> TimeInterval {
        let tomorrow = calendar.date(byAdding: .day, value: 1, to: now) ?? now.addingTimeInterval(86400)
        let morning = calendar.date(bySettingHour: 8, minute: 0, second: 0, of: tomorrow) ?? tomorrow
        return max(3600, morning.timeIntervalSince(now))
    }
}
