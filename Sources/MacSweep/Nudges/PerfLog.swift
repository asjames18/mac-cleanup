import Combine
import Darwin
import Foundation

/// Opt-in timing log for the background work (`--perf-log`, or `defaults write com.local.MacSweep perfLog -bool true`).
/// Writes logs/perf.log next to the actions log. Off by default, so normal runs pay nothing.
enum PerfLog {
    nonisolated(unsafe) static var enabled: Bool = ProcessInfo.processInfo.arguments.contains("--perf-log")
        || UserDefaults.standard.bool(forKey: "perfLog")
    nonisolated(unsafe) static var fileURL: URL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/MacSweep/logs/perf.log")
    private static let queue = DispatchQueue(label: "MacSweep.perflog", qos: .background)

    /// Runs `work` and logs how long it took in wall time and in this thread's CPU time.
    @discardableResult
    static func measure<T>(_ label: String, _ work: () throws -> T) rethrows -> T {
        guard enabled else { return try work() }
        let wall = DispatchTime.now().uptimeNanoseconds
        let cpu = threadCPUNanoseconds()
        let value = try work()
        let wallMS = Double(DispatchTime.now().uptimeNanoseconds - wall) / 1e6
        let cpuMS = Double(threadCPUNanoseconds() &- cpu) / 1e6
        write(String(format: "%@ wall=%.1fms cpu=%.1fms", label, wallMS, cpuMS))
        return value
    }

    static func note(_ message: String) {
        guard enabled else { return }
        write(message)
    }

    /// Total CPU time this process has used (user + system), in seconds.
    static func processCPUSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ t: timeval) -> Double { Double(t.tv_sec) + Double(t.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    static func threadCPUNanoseconds() -> UInt64 {
        var ts = timespec()
        return clock_gettime(CLOCK_THREAD_CPUTIME_ID, &ts) == 0 ? UInt64(ts.tv_sec) * 1_000_000_000 + UInt64(ts.tv_nsec) : 0
    }

    private static func write(_ message: String) {
        let line = "\(ISO8601DateFormatter().string(from: Date())) | \(message)\n"
        let url = fileURL
        queue.async {
            try? FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
            if let handle = try? FileHandle(forWritingTo: url) {
                _ = try? handle.seekToEnd()
                try? handle.write(contentsOf: Data(line.utf8))
                try? handle.close()
            } else {
                try? Data(line.utf8).write(to: url)
            }
        }
    }
}

/// With `--perf-log`, counts how often each long-lived observable object announces a change, logged once a
/// minute. A busy counter points at the view that keeps re-rendering.
@MainActor
enum PerfWatch {
    private static var counts: [String: Int] = [:]
    private static var subscriptions: [AnyCancellable] = []
    private static var timer: Timer?

    static func watch(_ objects: [(String, ObservableObjectPublisher)]) {
        guard PerfLog.enabled, subscriptions.isEmpty else { return }
        for (name, publisher) in objects {
            subscriptions.append(publisher.sink { MainActor.assumeIsolated { counts[name, default: 0] += 1 } })
        }
        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { _ in
            MainActor.assumeIsolated {
                let line = counts.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: " ")
                PerfLog.note(String(format: "changes/min %@ cpu=%.2fs", line, PerfLog.processCPUSeconds()))
                counts = [:]
            }
        }
        timer?.tolerance = 5
    }
}
