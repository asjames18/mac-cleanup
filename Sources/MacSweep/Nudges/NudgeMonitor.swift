import AppKit
import Combine
import Foundation
import MacSweepCore

/// Reads live signals on a low-priority task and feeds them to the nudge rules.
/// With a window open, processes are scanned every 30 seconds. Hidden, the scan backs off while the Mac
/// is calm (see `IdleSchedule`) and comes straight back when it gets busy. `pmset` runs only while the Mac is warm.
@MainActor
final class NudgeMonitor: ObservableObject {
    /// Not published: no view shows it, and publishing made every observer of this monitor redraw per sample.
    private(set) var lastSample: LiveSample?
    let center: NudgeCenter

    private var evaluator = LiveSignalEvaluator()
    private let scanner = ProcessScanner()
    private var lastProcessScan: Date = .distantPast
    /// Quiet hidden scans in a row; each one doubles the wait before the next.
    private(set) var quietScans = 0
    private var latestSample: LiveSample?
    private var lastSpeedCheck: Date = .distantPast
    private var lastSpeedLimit: Int?
    private var running = false
    private var checking = false
    private var lastHealthCheck: Date?
    private let launchedAt = Date()
    @Published private(set) var lastHealthResults: HealthCheckResults?
    /// The slower checks run 1 minute after launch (5 minutes when started hidden), then every 6 hours
    /// (12 hours on battery or Low Power Mode). Set to override, e.g. in tests.
    var healthCheckInterval: TimeInterval?
    private var lastCPUNote = Date()
    private var lastPSFallback: Date = .distantPast
    private var pressureSource: DispatchSourceMemoryPressure?
    private var thermalObserver: NSObjectProtocol?
    /// Called to request an immediate sample (memory pressure or thermal change).
    var requestSample: (() -> Void)?

    init(center: NudgeCenter) {
        self.center = center
        let source = DispatchSource.makeMemoryPressureSource(eventMask: [.warning, .critical, .normal], queue: .main)
        source.setEventHandler { [weak self] in MainActor.assumeIsolated { self?.requestSample?() } }
        source.resume()
        pressureSource = source
        thermalObserver = NotificationCenter.default.addObserver(forName: ProcessInfo.thermalStateDidChangeNotification,
                                                                 object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.requestSample?() }
        }
    }

    // Lives for the whole app run (AppServices), so it never tears down its observers.

    /// Runs the slower read-only checks now (also used by "Check Now").
    func runHealthChecks() {
        guard !checking else { return }
        checking = true
        lastHealthCheck = Date()
        Task {
            let results = await Task.detached(priority: .background) {
                PerfLog.measure("health-checks") { HealthCheckRunner.run() }
            }.value
            lastHealthResults = results
            center.ingest(HealthCheckEvaluator.observations(results), bannersAllowed: !Self.fullscreenAppInFront())
            checking = false
        }
    }

    private func runHealthChecksIfDue(now: Date) {
        let constrained = SystemSignals.onBattery || SystemSignals.lowPowerMode
        if let last = lastHealthCheck {
            let interval = healthCheckInterval ?? IdleSchedule.healthCheckInterval(constrained: constrained)
            if now.timeIntervalSince(last) >= interval { runHealthChecks() }
        } else if now.timeIntervalSince(launchedAt) >= IdleSchedule.firstHealthCheckDelay(visible: SystemMonitor.hasVisibleUI) {
            runHealthChecks()
        }
    }

    /// Called by `SystemMonitor` after each sample.
    func ingest(_ snapshot: SystemSnapshot) {
        guard !running, center.preferences.enabled else { return }
        runHealthChecksIfDue(now: Date())
        running = true
        let now = Date()
        let visible = SystemMonitor.hasVisibleUI
        if PerfLog.enabled, now.timeIntervalSince(lastCPUNote) >= 300 {
            lastCPUNote = now
            PerfLog.note(String(format: "process-cpu total=%.2fs visible=%@ quietScans=%d", PerfLog.processCPUSeconds(),
                                visible ? "yes" : "no", quietScans))
        }
        let scanInterval = IdleSchedule.processScanInterval(visible: visible, quietScans: quietScans,
                                                            constrained: SystemSignals.onBattery || SystemSignals.lowPowerMode)
        let busy = (snapshot.cpuUsage ?? 0) >= IdleSchedule.busyCPU
        let scanProcesses = now.timeIntervalSince(lastProcessScan) >= (busy ? min(scanInterval, 30) : scanInterval) - 1
        let checkSpeed = SystemSignals.thermal >= 1 && now.timeIntervalSince(lastSpeedCheck) >= 300
        if scanProcesses { lastProcessScan = now }
        if checkSpeed { lastSpeedCheck = now }
        if SystemSignals.thermal == 0 { lastSpeedLimit = nil }
        // The `ps` fallback (for busy root daemons) spawns a process; hidden, run it at most every 5 minutes.
        let allowPS = visible || now.timeIntervalSince(lastPSFallback) >= 300
        if allowPS, scanProcesses, (snapshot.cpuUsage ?? 0) >= 0.85 { lastPSFallback = now }
        let scanner = scanner
        let previousLimit = lastSpeedLimit
        Task {
            let extras = await Task.detached(priority: .utility) { () -> (Int64?, Double?, Int?, [ProcessSample]?, Int?) in
                var processes: [ProcessSample]? = scanProcesses ? PerfLog.measure("process-scan") { scanner.scan() } : nil
                if allowPS, let found = processes, (snapshot.cpuUsage ?? 0) >= 0.85, !found.contains(where: { $0.cpu >= 0.5 }) {
                    processes = found + ProcessScanner.psSnapshot().filter { $0.cpu >= 0.5 && !found.map(\.pid).contains($0.pid) }
                }
                return (SystemSignals.swapUsed(), SystemSignals.load1(), SystemSignals.pressureLevel(), processes,
                        checkSpeed ? SystemSignals.speedLimit() : previousLimit)
            }.value
            lastSpeedLimit = extras.4
            let sample = LiveSample(at: now, cpu: snapshot.cpuUsage, load1: extras.1, cores: SystemSignals.cores,
                                    memoryPressureLevel: extras.2, swapUsed: extras.0, thermal: SystemSignals.thermal,
                                    speedLimit: extras.4, processes: extras.3,
                                    diskFree: snapshot.diskFree, diskTotal: snapshot.diskTotal)
            latestSample = sample
            // Hidden views should not re-render every sample; publish only while MacSweep UI is on screen.
            if SystemMonitor.hasVisibleUI { lastSample = sample }
            if let processes = extras.3, !visible {
                let busiest = processes.map(\.cpu).max() ?? 0
                quietScans = IdleSchedule.isQuiet(totalCPU: snapshot.cpuUsage, busiestProcessCores: busiest) ? quietScans + 1 : 0
            } else if visible {
                quietScans = 0
            }
            center.ingest(evaluator.evaluate(sample), bannersAllowed: !Self.fullscreenAppInFront())
            running = false
        }
    }

    /// Shows the newest reading after the UI becomes visible again.
    func publishLatest() {
        if let latestSample, lastSample?.at != latestSample.at { lastSample = latestSample }
    }

    /// Banners wait while another app is fullscreen (presentations, games, video).
    static func fullscreenAppInFront() -> Bool {
        guard let front = NSWorkspace.shared.frontmostApplication, front.processIdentifier != getpid(),
              let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]],
              let screen = NSScreen.main?.frame else { return false }
        return list.contains { window in
            guard (window[kCGWindowOwnerPID as String] as? Int32) == front.processIdentifier,
                  (window[kCGWindowLayer as String] as? Int) == 0,
                  let bounds = window[kCGWindowBounds as String] as? [String: CGFloat] else { return false }
            return (bounds["Width"] ?? 0) >= screen.width && (bounds["Height"] ?? 0) >= screen.height
        }
    }
}
