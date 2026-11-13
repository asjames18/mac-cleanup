import AppKit
import Combine
import Foundation
import MacSweepCore

@MainActor
final class SystemMonitor: ObservableObject {
    /// Full reading, for the menu bar popover. The dashboard observes the smaller stores below instead,
    /// so a new sample only redraws the widgets whose displayed value changed.
    @Published var snapshot: SystemSnapshot = .unavailable
    let fast = ReadingStore(FastReadings())
    let slow = ReadingStore(SlowReadings())
    let health = ReadingStore(HealthInputs())

    private var updateTask: Task<Void, Never>?
    private var refreshTask: Task<Void, Never>?
    private var previousCPUTicks: CPUTicks?
    private var isSampling = false
    private var lastSampleAt: Date = .distantPast
    /// Called on the main actor after every sample; the nudge monitor listens here.
    var onSample: ((SystemSnapshot) -> Void)?
    /// Called when MacSweep UI comes back on screen, so other hidden-time state can be published.
    var onBecameVisible: (() -> Void)?
    /// Visible UI samples every 3 s while MacSweep is the active app with a key window, every 15 s while it is
    /// visible behind other apps. In the background: 30 s on power, 60 s on battery or Low Power Mode.
    var interactiveInterval: TimeInterval = 3

    /// MacSweep is the active app and one of its windows (or the popover) is key.
    static var uiIsFocused: Bool {
        guard let app = NSApp, app.isActive, let key = app.keyWindow else { return false }
        return key.isVisible && key.className != "NSStatusBarWindow"
    }

    nonisolated static func backgroundInterval(onBattery: Bool, lowPower: Bool) -> TimeInterval {
        IdleSchedule.sampleInterval(visible: false, constrained: onBattery || lowPower)
    }

    /// A MacSweep window or the menu bar popover is on screen. The status item itself does not count.
    static var hasVisibleUI: Bool {
        NSApp?.windows.contains { window in
            window.isVisible && window.occlusionState.contains(.visible)
                && window.className != "NSStatusBarWindow" && window.frame.height > 40
        } ?? false
    }

    /// The newest reading. While no MacSweep UI is visible it is kept here instead of in `snapshot`,
    /// so hidden SwiftUI views (a closed window SwiftUI keeps alive) are not re-laid out every sample.
    private(set) var latest: SystemSnapshot = .unavailable
    private var visibilityObservers: [NSObjectProtocol] = []

    init() {
        start()
        observeVisibility()
    }

    deinit {
        updateTask?.cancel()
        refreshTask?.cancel()
    }

    func start() {
        guard updateTask == nil else { return }
        updateTask = Task { [weak self] in
            var onBattery = SystemSignals.onBattery
            var lastPowerCheck = Date.distantPast
            while !Task.isCancelled {
                guard let self else { break }
                let visible = Self.hasVisibleUI
                if Date().timeIntervalSince(lastPowerCheck) >= 300 {
                    onBattery = SystemSignals.onBattery
                    lastPowerCheck = Date()
                }
                let interval = visible ? (Self.uiIsFocused ? interactiveInterval : IdleSchedule.unfocusedInterval)
                    : IdleSchedule.sampleInterval(visible: false, constrained: onBattery || SystemSignals.lowPowerMode)
                let elapsed = Date().timeIntervalSince(lastSampleAt)
                if elapsed >= interval - 0.5 { await sampleAndPublish(force: false) }
                // Sleep until the next sample is due. Hidden, that is one wake-up per sample with generous
                // leeway; `wake()` cuts the sleep short when a window or the popover appears.
                let wait = max(0.5, interval - Date().timeIntervalSince(lastSampleAt))
                do {
                    try await Task.sleep(for: .seconds(wait), tolerance: .seconds(IdleSchedule.tolerance(for: wait)))
                } catch {
                    break
                }
            }
        }
    }

    /// Restarts the loop so a newly visible window gets 3-second updates right away.
    func wake() {
        updateTask?.cancel()
        updateTask = nil
        start()
    }

    func refresh() {
        guard refreshTask == nil else { return }
        refreshTask = Task { [weak self] in
            await self?.sampleAndPublish(force: true)
            self?.refreshTask = nil
        }
    }

    private func observeVisibility() {
        let center = NotificationCenter.default
        let names: [Notification.Name] = [NSWindow.didChangeOcclusionStateNotification, NSWindow.didBecomeKeyNotification,
                                          NSApplication.didBecomeActiveNotification, NSApplication.didResignActiveNotification]
        for name in names {
            visibilityObservers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                MainActor.assumeIsolated { self?.visibilityChanged() }
            })
        }
    }

    private var wasVisible = false
    private var wasFocused = false

    private func visibilityChanged() {
        let visible = Self.hasVisibleUI
        let focused = visible && Self.uiIsFocused
        defer { wasVisible = visible; wasFocused = focused }
        if visible, !wasVisible {
            publish(latest)
            onBecameVisible?()
            wake()
        } else if focused, !wasFocused {
            // Back in front: return to 3-second updates now rather than after the slower sleep.
            wake()
        }
    }

    private func publish(_ reading: SystemSnapshot) {
        if snapshot != reading { snapshot = reading }
        fast.update(FastReadings(reading))
        slow.update(SlowReadings(reading))
        health.update(HealthInputs(reading))
    }

    /// A refresh asked to publish while another sample was in flight; that sample publishes instead.
    private var publishRequested = false

    private func sampleAndPublish(force: Bool) async {
        if force { publishRequested = true }
        guard !isSampling else { return }
        isSampling = true
        defer { isSampling = false }
        let sample = await Task.detached(priority: .utility) {
            PerfLog.measure("system-sample") { SystemMetrics.sample() }
        }.value
        guard !Task.isCancelled else { return }

        let usage = SystemMetrics.cpuUsage(previous: previousCPUTicks, current: sample.cpuTicks)
        previousCPUTicks = sample.cpuTicks
        lastSampleAt = sample.sampledAt
        latest = SystemSnapshot(
            cpuUsage: usage,
            memoryUsed: sample.memoryUsed,
            memoryTotal: sample.memoryTotal,
            memoryPressure: sample.memoryPressure,
            diskFree: sample.diskFree,
            diskTotal: sample.diskTotal,
            uptime: sample.uptime,
            updatedAt: sample.sampledAt
        )
        if publishRequested || Self.hasVisibleUI { publish(latest) }
        publishRequested = false
        onSample?(latest)
    }
}
