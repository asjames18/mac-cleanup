import Foundation

/// How often MacSweep looks at the Mac while nobody is watching. Visible UI stays live;
/// hidden, the process scan backs off while nothing is busy and the slow checks run rarely.
public enum IdleSchedule {
    /// System sample (cheap host counters): every 3 s while a window or the popover is visible,
    /// otherwise 30 s on power and 60 s on battery or Low Power Mode.
    public static func sampleInterval(visible: Bool, constrained: Bool) -> TimeInterval {
        visible ? 3 : (constrained ? 60 : 30)
    }

    /// A MacSweep window is on screen but another app is in front, or the window is not key.
    public static let unfocusedInterval: TimeInterval = 15

    /// Per-process scan. Visible: every 30 s. Hidden: 60 s, doubling after each quiet scan
    /// up to 10 minutes (15 minutes on battery or Low Power Mode).
    public static func processScanInterval(visible: Bool, quietScans: Int, constrained: Bool) -> TimeInterval {
        if visible { return 30 }
        let cap: TimeInterval = constrained ? 900 : 600
        let steps = min(max(quietScans, 0), 10)
        return min(60 * pow(2, Double(steps)), cap)
    }

    /// The Mac as a whole is busy enough that a process scan should happen now, whatever the backoff says.
    public static let busyCPU = 0.6

    /// A scan counts as quiet when the Mac is calm and no single process is near the runaway threshold.
    public static func isQuiet(totalCPU: Double?, busiestProcessCores: Double) -> Bool {
        (totalCPU ?? 0) < busyCPU && busiestProcessCores < 0.5
    }

    /// Slow read-only checks (security, drive, battery, updates, crashes, startup items).
    public static func healthCheckInterval(constrained: Bool) -> TimeInterval {
        constrained ? 12 * 3600 : 6 * 3600
    }

    /// First run after launch: 60 s with a window open, 5 minutes when started in the background (login is busy).
    public static func firstHealthCheckDelay(visible: Bool) -> TimeInterval {
        visible ? 60 : 300
    }

    /// Timer leeway so macOS can coalesce wake-ups: 20% of the interval, between 0.5 s and 60 s.
    public static func tolerance(for interval: TimeInterval) -> TimeInterval {
        min(max(interval * 0.2, 0.5), 60)
    }
}
