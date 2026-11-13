import AppKit
import Darwin
import Foundation

/// Quitting a busy process, only after the user confirms. Apps get a normal Quit (they may ask to save);
/// other processes get SIGTERM. MacSweep never signals itself, launchd, or processes it cannot inspect.
enum ProcessActions {
    struct Target: Equatable, Sendable {
        let pid: pid_t
        let name: String
        let isApp: Bool
    }

    /// Same-user processes with this name (by executable or app name).
    static func targets(named name: String) -> [Target] {
        let me = getpid()
        var result: [Target] = []
        var seen = Set<pid_t>()
        for app in NSWorkspace.shared.runningApplications where app.processIdentifier > 1 && app.processIdentifier != me {
            let executable = app.executableURL?.lastPathComponent
            guard executable == name || app.localizedName == name else { continue }
            result.append(Target(pid: app.processIdentifier, name: app.localizedName ?? name, isApp: true))
            seen.insert(app.processIdentifier)
        }
        for sample in ProcessScanner().scan() where sample.name == name && sample.pid > 1 && !seen.contains(sample.pid) {
            guard ownedByCurrentUser(sample.pid) else { continue }
            result.append(Target(pid: sample.pid, name: name, isApp: false))
        }
        return result.sorted { $0.pid < $1.pid }
    }

    static func ownedByCurrentUser(_ pid: pid_t) -> Bool {
        var info = proc_bsdinfo()
        let size = Int32(MemoryLayout<proc_bsdinfo>.size)
        guard proc_pidinfo(pid, PROC_PIDTBSDINFO, 0, &info, size) == size else { return false }
        return info.pbi_uid == getuid()
    }

    /// Returns the pids that were asked to quit.
    @discardableResult
    static func terminate(_ targets: [Target]) -> [pid_t] {
        targets.compactMap { target in
            guard target.pid > 1, target.pid != getpid() else { return nil }
            if target.isApp, let app = NSRunningApplication(processIdentifier: target.pid) {
                return app.terminate() ? target.pid : nil
            }
            guard ownedByCurrentUser(target.pid) else { return nil }
            return kill(target.pid, SIGTERM) == 0 ? target.pid : nil
        }
    }
}
