import AppKit
import SwiftUI

struct ContentView: View {
    @ObservedObject var model: AppModel
    /// Not observed: only the sidebar's disk line shows live data, through `SidebarDiskFree`.
    let monitor: SystemMonitor
    var nudges: NudgeMonitor? = nil
    var actions: NudgeActionHandler? = nil
    @State private var showActivity = false
    @State private var windowRef = WindowRef()
    @State private var keyMonitor: Any?

    var body: some View {
        NavigationSplitView {
            VStack(spacing: 0) {
                HStack(spacing: 10) {
                    Image(systemName: "sparkles")
                        .font(.title2.weight(.semibold)).foregroundStyle(Theme.accent2)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("MacSweep").font(.title3.weight(.bold))
                        Text("A little room to breathe.").font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                }
                .padding(20)
                List(selection: $model.mainViewMode) {
                    Section("Your Mac") {
                        ForEach(MainViewMode.allCases) { mode in
                            Label(mode.title, systemImage: mode.systemImage)
                                .padding(.vertical, 5).tag(mode)
                        }
                    }
                }
                .listStyle(.sidebar)
                .scrollContentBackground(.hidden)
                VStack(alignment: .leading, spacing: 8) {
                    if model.sandboxEnabled {
                        Label("Test sandbox on", systemImage: "testtube.2")
                            .font(.caption.weight(.semibold)).foregroundStyle(Theme.warn)
                            .help("Only files inside the test sandbox folder can be moved to Trash.")
                    }
                    Label("You're in control", systemImage: "checkmark.shield").font(.caption.weight(.semibold))
                    Text("Review files before moving them to Trash.").font(.caption).foregroundStyle(.secondary)
                    SidebarDiskFree(slow: monitor.slow)
                }
                .padding(20)
                HStack(spacing: 6) {
                    Kbd(text: "?")
                    Text("Keyboard shortcuts").font(.caption).foregroundStyle(Theme.muted)
                }
                .padding(.horizontal, 20).padding(.bottom, 16)
                .onTapGesture { model.showShortcuts = true }
            }
            .background(Theme.panel)
            .navigationSplitViewColumnWidth(min: 210, ideal: 225, max: 260)
        } detail: {
            VStack(spacing: 0) {
                if model.isBusy { scanProgress }
                else if !model.scanSummary.isEmpty {
                    Text(model.scanSummary).font(.caption).foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 24).padding(.vertical, 10)
                        .background(Theme.accent2.opacity(0.06))
                }
                if model.sandboxEnabled, [.cleanup, .storage, .apps].contains(model.mainViewMode) {
                    SandboxBanner { model.setSandboxEnabled(false) }
                        .disabled(model.isBusy || model.waitingForFilesystem)
                }
                Group {
                    switch model.mainViewMode {
                    case .overview: DashboardView(model: model, monitor: monitor, nudges: nudges, actions: actions)
                    case .cleanup: CleanupView(model: model)
                    case .storage: StorageView(model: model)
                    case .apps: ApplicationsView(model: model)
                    case .maintenance: MaintenanceView()
                    case .history: HistoryView()
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                if showActivity {
                    Divider()
                    ActivityReportView(model: model)
                }
            }
            .background(Theme.bg)
            .navigationTitle(model.mainViewMode.title)
            .toolbar {
                ToolbarItemGroup(placement: .primaryAction) {
                    if model.mainViewMode == .cleanup || model.mainViewMode == .storage {
                        Button { model.chooseCustomFolder() } label: {
                            Label("Add Folder", systemImage: "folder.badge.plus")
                        }.disabled(model.isBusy || model.waitingForFilesystem)
                    }
                    if model.mainViewMode == .apps {
                        Button { model.scanInstalledApps() } label: {
                            Label("Scan Applications", systemImage: "arrow.clockwise")
                        }.disabled(model.isBusy || model.waitingForFilesystem)
                    } else if model.mainViewMode == .storage {
                        Button { model.analyzeStorage() } label: {
                            Label("Analyze Storage", systemImage: "magnifyingglass")
                        }.disabled(model.isBusy || model.waitingForFilesystem)
                    }
                    Button { showActivity.toggle() } label: {
                        Label("Activity", systemImage: "list.bullet.rectangle")
                    }.help("Show or hide scan activity")
                }
            }
        }
        .tint(Theme.accent)
        .preferredColorScheme(.dark)
        .overlay(alignment: .bottom) {
            if let toast = model.toast {
                ToastView(toast: toast).padding(.bottom, 24)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .id(toast.id)
            }
        }
        .overlay {
            if model.showShortcuts { ShortcutOverlay { model.showShortcuts = false } }
        }
        .animation(.easeOut(duration: 0.2), value: model.toast)
        .sheet(item: Binding(get: { model.pendingConfirmation },
                             set: { if $0 == nil { model.cancelPendingConfirmation() } })) { pending in
            ConfirmSheet(pending: pending, onCancel: { model.cancelPendingConfirmation() },
                         onConfirm: { model.approvePendingConfirmation() })
        }
        .background(WindowReader(ref: windowRef))
        .onAppear(perform: installKeyMonitor)
        .onDisappear {
            if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
            keyMonitor = nil
        }
    }

    private func installKeyMonitor() {
        guard keyMonitor == nil else { return }
        let ref = windowRef
        let model = model
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let eventWindow = event.window
            let characters = event.charactersIgnoringModifiers
            let keyCode = event.keyCode
            let modifiers = event.modifierFlags
            let handled = MainActor.assumeIsolated { () -> Bool in
                guard NSApp.modalWindow == nil, let window = ref.window, eventWindow === window,
                      window.attachedSheet == nil else { return false }
                let typing = window.firstResponder is NSTextView
                guard let action = KeyMap.action(characters: characters, keyCode: keyCode, modifiers: modifiers,
                                                 typing: typing, overlayShown: model.showShortcuts) else { return false }
                return model.handle(action)
            }
            return handled ? nil : event
        }
    }

    private var scanProgress: some View {
        HStack(spacing: 12) {
            ProgressView().controlSize(.small)
            if case .scanning(let message) = model.status {
                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(message).font(.callout)
                        if let started = model.scanStartedAt {
                            Text(started, style: .timer).monospacedDigit().font(.caption)
                        }
                    }
                    Text(model.scanDetail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(2).truncationMode(.middle)
                }
                Spacer()
                Button("Cancel", role: .cancel) { model.cancelScan() }
            } else {
                Text("Moving selected items to Trash…").font(.callout)
                Spacer()
            }
        }
        .padding(.horizontal, 24).padding(.vertical, 12)
        .background(Theme.accent2.opacity(0.08))
    }
}

/// Redraws its own line when the free space changes; never invalidates the sidebar.
struct SidebarDiskFree: View {
    let slow: ReadingStore<SlowReadings>

    var body: some View {
        Divider().padding(.vertical, 4)
        LiveText(store: slow, style: .captionMono) { $0.diskFreeText.map { "\($0) available" } ?? "" }
            .frame(maxWidth: .infinity, minHeight: 16, maxHeight: 16)
    }
}
