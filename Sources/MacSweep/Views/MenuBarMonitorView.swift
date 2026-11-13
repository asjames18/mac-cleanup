import AppKit
import MacSweepCore
import SwiftUI

struct MenuBarMonitorView: View {
    @ObservedObject var monitor: SystemMonitor
    var center: NudgeCenter? = nil
    var actions: NudgeActionHandler? = nil
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Label("MacSweep", systemImage: "sparkles").font(.headline).foregroundStyle(Theme.accent2)
            Divider()
            if let center, let actions { MenuBarNudgeList(center: center, handler: actions) }
            reading("CPU use", value: monitor.snapshot.cpuUsage.map { "\(Int(($0 * 100).rounded()))%" } ?? "Sampling…")
            reading("Memory used", value: monitor.snapshot.memoryUsed.map(\.formattedFileSize) ?? "Unavailable")
            reading("Memory pressure", value: monitor.snapshot.memoryPressure)
            reading("Disk available", value: monitor.snapshot.diskFree.map(\.formattedFileSize) ?? "Unavailable")
            Divider()
            Button("Open MacSweep") {
                NSApp.setActivationPolicy(.regular)
                openWindow(id: "main")
                NSApp.activate(ignoringOtherApps: true)
            }.buttonStyle(.borderedProminent).tint(Theme.accent)
            Button("Quit MacSweep") { NSApp.terminate(nil) }.buttonStyle(.plain).foregroundStyle(.secondary)
        }
        .padding(20).frame(width: 270)
    }

    private func reading(_ title: String, value: String) -> some View {
        HStack {
            Text(title).foregroundStyle(.secondary)
            Spacer()
            Text(value).monospacedDigit()
        }.font(.callout)
    }
}

struct MacSweepSettingsView: View {
    @ObservedObject var model: AppModel
    var nudges: NudgeMonitor? = nil
    @AppStorage("showMenuBarMonitor") private var showMenuBarMonitor = true
    var body: some View {
        Form {
            FolderAccessView(model: model)
            Section("Test sandbox") {
                Toggle("Only move files inside the test sandbox", isOn: Binding(
                    get: { model.sandboxEnabled },
                    set: { model.setSandboxEnabled($0) }
                ))
                Text("On by default. While on, MacSweep refuses every Trash move outside \(TestSandbox.defaultRoot.path). Turning it off asks you to confirm.")
                    .font(.caption).foregroundStyle(.secondary).textSelection(.enabled)
                HStack {
                    Button("Show Sandbox Folder") { model.revealSandbox() }
                    Button("Add Sandbox to Scan") { model.addSandboxToScanFolders() }
                    Button("Show Action Log") { model.revealActionLog() }.disabled(model.settingsStore == nil)
                }
            }.disabled(model.isBusy || model.waitingForFilesystem)
            AISettingsSection(model: model)
            if let nudges { NudgeSettingsSection(monitor: nudges, center: nudges.center, confirm: { model.confirm(title: $0, detail: $1) }) }
            Section("Monitoring") {
                Toggle("Show MacSweep in the menu bar", isOn: $showMenuBarMonitor)
                Text("Readings update every three seconds while a MacSweep window or this menu is open, and every 30 seconds in the background (60 on battery).")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Cleanup") {
                Label("Review every cleanup", systemImage: "checkmark.shield")
                Text("Scanning never deletes files. Select candidates, review the confirmation, then move them to Trash. Review recovery options in History or Finder when needed.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Section("Scan preferences") {
                Text("Added folders and your selected scan preset are remembered between launches. Remove a folder using its × button in Smart Scan. Saved folders still require macOS access; unavailable folders are reported during scanning.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Section("Exclusions") {
                Text("Excluded paths, their contents, and cleanup targets containing them are protected. Changing exclusions clears scan results. Moved files or other hard-linked paths need their own exclusion.")
                    .font(.caption).foregroundStyle(.secondary)
                ForEach(model.excludedFolders, id: \.path) { url in
                    HStack {
                        Text(url.path).lineLimit(2).textSelection(.enabled)
                        Spacer()
                        Button("Remove") { model.removeExclusion(url) }
                    }
                }
                Button("Add Exclusion…") { model.chooseExcludedFolders() }
            }.disabled(model.isBusy || model.waitingForFilesystem)
            Section("MacSweep") {
                Text("Version 2.0 · Built for your Mac")
                Text("Local scans. No account required.").font(.caption).foregroundStyle(.secondary)
            }
        }.formStyle(.grouped).padding(12).frame(width: 490, height: 610)
    }
}

/// Off by default. Stores an environment variable name only; this build makes no network calls.
struct AISettingsSection: View {
    @ObservedObject var model: AppModel
    @State private var draft = AISettings.dormant
    @State private var error: String?

    var body: some View {
        Section("AI suggestions (off by default)") {
            Toggle("Show AI suggestions", isOn: $draft.enabled)
            Picker("Provider", selection: $draft.provider) {
                Text("Local rules").tag(AISettings.Provider.rules)
                Text("OpenAI-compatible (not connected)").tag(AISettings.Provider.openai)
            }
            TextField("Base URL", text: $draft.baseURL)
            TextField("Model", text: $draft.model)
            TextField("API key environment variable name", text: $draft.keyEnv)
            Text("Enter only the variable name, for example OPENROUTER_API_KEY. Key values are rejected. Nothing is sent over the network in this version, and every Apply asks first.")
                .font(.caption).foregroundStyle(.secondary)
            if let error { Text(error).font(.caption).foregroundStyle(Theme.danger) }
            HStack {
                Spacer()
                Button("Save AI Settings") { error = model.saveAISettings(draft) }
            }
        }
        .onAppear { draft = model.aiSettings }
    }
}
