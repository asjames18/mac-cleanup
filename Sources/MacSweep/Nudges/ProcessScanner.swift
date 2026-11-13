import Darwin
import Foundation
import MacSweepCore

/// Per-process CPU and memory through libproc. Only processes this user may inspect are readable;
/// system daemons owned by root are counted as unreadable and skipped (no root, no private APIs).
final class ProcessScanner: @unchecked Sendable {
    private struct Previous { let cpuTime: UInt64; let at: UInt64 }
    private var previous: [pid_t: Previous] = [:]
    private let lock = NSLock()
    private let ownPID = getpid()
    private let timebase: (numer: UInt64, denom: UInt64) = {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return (UInt64(max(info.numer, 1)), UInt64(max(info.denom, 1)))
    }()

    private(set) var lastUnreadable = 0

    /// Returns processes with CPU measured since the previous scan. The first scan reports 0 CPU.
    func scan() -> [ProcessSample] {
        lock.lock(); defer { lock.unlock() }
        let now = DispatchTime.now().uptimeNanoseconds
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return [] }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return [] }

        var next: [pid_t: Previous] = [:]
        var samples: [ProcessSample] = []
        var unreadable = 0
        for pid in pids.prefix(count) where pid > 0 && pid != ownPID {
            var info = proc_taskinfo()
            let size = Int32(MemoryLayout<proc_taskinfo>.size)
            guard proc_pidinfo(pid, PROC_PIDTASKINFO, 0, &info, size) == size else { unreadable += 1; continue }
            let cpuTime = (info.pti_total_user &+ info.pti_total_system) &* timebase.numer / timebase.denom
            next[pid] = Previous(cpuTime: cpuTime, at: now)
            var cores = 0.0
            if let before = previous[pid], now > before.at, cpuTime >= before.cpuTime {
                cores = Double(cpuTime - before.cpuTime) / Double(now - before.at)
            }
            samples.append(ProcessSample(pid: pid, name: Self.name(pid), cpu: cores,
                                         residentBytes: Int64(clamping: info.pti_resident_size)))
        }
        previous = next
        lastUnreadable = unreadable
        return samples
    }

    /// Fallback for when the Mac is busy but no readable process explains it (for example a root daemon).
    static func psSnapshot() -> [ProcessSample] {
        guard let output = SystemSignals.run("/bin/ps", ["-axo", "pid=,pcpu=,rss=,comm="], timeout: 5) else { return [] }
        return PSOutput.parse(output, excluding: getpid())
    }

    static func name(_ pid: pid_t) -> String {
        var buffer = [CChar](repeating: 0, count: 4096)
        if proc_pidpath(pid, &buffer, UInt32(buffer.count)) > 0 {
            let path = String(cString: buffer)
            // Prefer the app name for helpers inside a bundle, e.g. "Google Chrome Helper".
            return URL(filePath: path).lastPathComponent
        }
        var short = [CChar](repeating: 0, count: 64)
        return proc_name(pid, &short, UInt32(short.count)) > 0 ? String(cString: short) : "pid \(pid)"
    }
}
