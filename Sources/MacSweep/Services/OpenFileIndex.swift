import Darwin
import Foundation

/// Files that running apps (of this user) have open right now, read with libproc. Read-only.
/// Used just before a Trash move so files in use are skipped and listed instead of being pulled out from under an app.
struct OpenFileIndex: Sendable {
    /// Normalized, lowercased paths.
    let paths: [String]

    init(paths: [String]) {
        self.paths = paths.map { ProtectionRules.normalizedPath(URL(fileURLWithPath: $0)).lowercased() }.sorted()
    }

    /// True when `url` is open, or is a folder that holds an open file.
    func isInUse(_ url: URL) -> Bool {
        let root = ProtectionRules.normalizedPath(url).lowercased()
        let prefix = root == "/" ? "/" : root + "/"
        // Sorted, so a binary search finds the first candidate at or after `root`.
        var low = 0, high = paths.count
        while low < high {
            let mid = (low + high) / 2
            if paths[mid] < root { low = mid + 1 } else { high = mid }
        }
        var index = low
        while index < paths.count {
            let path = paths[index]
            if path == root || path.hasPrefix(prefix) { return true }
            if !path.hasPrefix(root) { break }
            index += 1
        }
        return false
    }

    static func capture() -> OpenFileIndex {
        let ownPID = getpid()
        let capacity = Int(proc_listallpids(nil, 0)) + 64
        guard capacity > 64 else { return OpenFileIndex(paths: []) }
        var pids = [pid_t](repeating: 0, count: capacity)
        let count = Int(proc_listallpids(&pids, Int32(capacity * MemoryLayout<pid_t>.size)))
        guard count > 0 else { return OpenFileIndex(paths: []) }
        var found = Set<String>()
        let fdSize = MemoryLayout<proc_fdinfo>.stride
        for pid in pids.prefix(count) where pid > 0 && pid != ownPID {
            let bytes = proc_pidinfo(pid, PROC_PIDLISTFDS, 0, nil, 0)
            guard bytes > 0 else { continue }
            var fds = [proc_fdinfo](repeating: proc_fdinfo(), count: Int(bytes) / fdSize + 16)
            let filled = fds.withUnsafeMutableBytes { buffer in
                proc_pidinfo(pid, PROC_PIDLISTFDS, 0, buffer.baseAddress, Int32(buffer.count))
            }
            guard filled > 0 else { continue }
            for fd in fds.prefix(Int(filled) / fdSize) where fd.proc_fdtype == UInt32(PROX_FDTYPE_VNODE) {
                var info = vnode_fdinfowithpath()
                let size = Int32(MemoryLayout<vnode_fdinfowithpath>.size)
                guard proc_pidfdinfo(pid, fd.proc_fd, PROC_PIDFDVNODEPATHINFO, &info, size) == size else { continue }
                let path = withUnsafeBytes(of: &info.pvip.vip_path) { raw -> String in
                    String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
                }
                if path.hasPrefix("/") { found.insert(path) }
            }
        }
        return OpenFileIndex(paths: Array(found))
    }
}
