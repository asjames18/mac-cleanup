import AppKit
import SwiftUI

/// Long-lived services shared by the window, the menu bar and background mode.
@MainActor
enum AppServices {
    static let model = AppModel(scanPreferences: ScanPreferences(defaults: .standard), sandboxPreferences: SandboxPreferences(defaults: .standard),
                                settingsStore: try? SettingsStore(legacyDefaults: .standard))
    static let monitor = SystemMonitor()
    static let nudges = NudgeMonitor(center: NudgeCenter())
    static let actions = NudgeActionHandler(model: model, monitor: nudges)

    static func connect() {
        guard monitor.onSample == nil else { return }
        let nudges = nudges
        monitor.onSample = { nudges.ingest($0) }
        monitor.onBecameVisible = { nudges.publishLatest() }
        PerfWatch.watch([("model", model.objectWillChange), ("monitor", monitor.objectWillChange),
                         ("fast", monitor.fast.objectWillChange), ("slow", monitor.slow.objectWillChange),
                         ("health", monitor.health.objectWillChange), ("nudges", nudges.objectWillChange),
                         ("center", nudges.center.objectWillChange), ("presence", WindowPresence.shared.objectWillChange)])
        nudges.requestSample = { monitor.refresh() }
        let notes = NotificationService.shared
        notes.configure(categories: NudgeActionHandler.categories)
        notes.onResponse = { action, _, info in actions.handleNotification(action: action, info: info) }
        // Ask for notification permission once, a few seconds after the first launch with banners on.
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(5))
            guard nudges.center.preferences.enabled, nudges.center.preferences.bannersEnabled,
                  await notes.authorization() == .notDetermined else { return }
            _ = await notes.requestAuthorization()
        }
    }
}

@MainActor
final class MacSweepDelegate: NSObject, NSApplicationDelegate {
    private var background = false

    func applicationWillFinishLaunching(_ notification: Notification) {
        // The login-item Apple event is only readable while launching.
        background = BackgroundMode.shouldStartInBackground(arguments: ProcessInfo.processInfo.arguments,
                                                            launchedAsLoginItem: BackgroundMode.launchedAsLoginItem)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        AppServices.connect()
        BackgroundMode.observeWindowClosing()
        let arguments = ProcessInfo.processInfo.arguments
        if arguments.contains("--enable-login-item") {
            // Explicit setup step: open MacSweep at login (menu bar only). Turn it off in Settings.
            try? LoginItemService.register()
            AppServices.model.recordAction("login-item", "Launch at login requested from the command line; status \(LoginItemService.status.rawValue).")
        }
        if background {
            // Menu-bar-only mode needs the menu bar item, or MacSweep would be invisible.
            UserDefaults.standard.set(true, forKey: "showMenuBarMonitor")
            NSApp.setActivationPolicy(.accessory)
            // SwiftUI opens the main window right after launch; close it once it exists.
            Task { @MainActor in
                for _ in 0..<20 {
                    try? await Task.sleep(for: .milliseconds(100))
                    if !BackgroundMode.mainWindows.isEmpty { BackgroundMode.enter(); break }
                }
            }
        } else {
            NSApp.setActivationPolicy(.regular)
            NSApp.activate(ignoringOtherApps: true)
        }
        if ProcessInfo.processInfo.arguments.contains("--nudge-spike") {
            Task { @MainActor in
                let report = await NudgeSpike.run()
                _ = try? NudgeSpike.write(report)
            }
        }
    }
}

extension MacSweepDelegate {
    /// Clicking the Dock icon or reopening MacSweep from Finder shows the window again.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        NSApp.setActivationPolicy(.regular)
        WindowPresence.shared.mainWindowOpen = true
        return true
    }
}

@main
struct MacSweepApp: App {
    @NSApplicationDelegateAdaptor(MacSweepDelegate.self) private var delegate
    @StateObject private var model = AppServices.model
    // Not observed here: the App body would otherwise re-evaluate every scene (including a closed window)
    // on each sample. The views that show these observe them directly.
    private let monitor = AppServices.monitor
    private let nudges = AppServices.nudges
    @State private var didRunLaunchScan = false
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = true

    var body: some Scene {
        WindowGroup("MacSweep", id: "main") {
            MainWindowRoot {
                ContentView(model: model, monitor: monitor, nudges: nudges, actions: AppServices.actions)
            }
                .frame(minWidth: 1040, minHeight: 700)
                .task {
                    // Explicit read-only launch action for local diagnostics and shortcuts.
                    guard !didRunLaunchScan else { return }
                    let arguments = ProcessInfo.processInfo.arguments
                    if arguments.contains("--scan-apps") {
                        didRunLaunchScan = true
                        model.mainViewMode = .apps
                        model.scanInstalledApps()
                    } else if arguments.contains("--quick-scan") {
                        didRunLaunchScan = true
                        model.mainViewMode = .cleanup
                        model.selectedPreset = .quick
                        model.scan()
                    }
                }
        }
        .defaultSize(width: 1220, height: 840)
        .commands {
            CommandGroup(replacing: .newItem) { }
            CommandMenu("Scan") {
                Button("Start Smart Scan") {
                    model.mainViewMode = .cleanup
                    model.scan()
                }.keyboardShortcut("r", modifiers: .command).disabled(model.isBusy || model.waitingForFilesystem)
                Button("Scan Applications") {
                    model.mainViewMode = .apps
                    model.scanInstalledApps()
                }.keyboardShortcut("r", modifiers: [.command, .shift]).disabled(model.isBusy || model.waitingForFilesystem)
                Button("Cancel Scan") { model.cancelScan() }
                    .keyboardShortcut(".", modifiers: .command).disabled(!isScanning)
                Divider()
                Button("Add Folder…") { model.chooseCustomFolder() }
                    .keyboardShortcut("o", modifiers: .command).disabled(model.isBusy || model.waitingForFilesystem)
            }
        }
        Settings { MacSweepSettingsView(model: model, nudges: nudges).tint(Theme.accent).preferredColorScheme(.dark) }
        MenuBarExtra(isInserted: $showMenuBarMonitor) {
            MenuBarMonitorView(monitor: monitor, center: nudges.center, actions: AppServices.actions).preferredColorScheme(.dark)
                .onAppear { monitor.refresh() }
        } label: {
            MenuBarIcon(center: nudges.center, handler: AppServices.actions)
        }
        .menuBarExtraStyle(.window)
    }

    private var isScanning: Bool {
        if case .scanning = model.status { return true }
        return false
    }
}
