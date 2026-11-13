import Darwin
import Foundation

struct StorageObjectID: Hashable, Sendable {
    let device: Int32
    let inode: UInt64
    let birthSeconds: Int64
    let birthNanos: Int64
    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino
        birthSeconds = Int64(value.st_birthtimespec.tv_sec); birthNanos = Int64(value.st_birthtimespec.tv_nsec)
    }
}

struct StorageDirectoryStamp: Equatable, Sendable {
    let identity: StorageObjectID
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64
    init(_ value: stat) {
        identity = StorageObjectID(value)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
    }
}

enum StorageReadError: LocalizedError {
    case changedFolder
    var errorDescription: String? { "This folder changed while it was being read. Refresh and review its current contents." }
}

struct StorageEntry: Identifiable, Sendable {
    enum Kind: String, Sendable { case folder = "Folder", file = "File", link = "Symbolic link", other = "Special item" }
    let url: URL
    let kind: Kind
    let logicalBytes: Int64
    let allocatedBytes: Int64
    var identity: StorageObjectID? = nil
    var id: String { url.path }
}

struct StorageDirectoryReport: Sendable {
    let entries: [StorageEntry]
    let partial: Bool
    let skipped: Int
    var examined: Int = 0
    var device: Int32? = nil
    var stamp: StorageDirectoryStamp? = nil
}

enum StorageDirectoryReader {
    /// Shallow, metadata-only listing pinned to a no-follow directory descriptor.
    /// Folder sizes are deliberately not estimated from their directory metadata.
    static func read(_ url: URL, exclusions: [URL] = [], limit: ScanLimit = .quick, expectedIdentity: StorageObjectID? = nil,
                     beforeFinish: (() throws -> Void)? = nil) throws -> StorageDirectoryReport {
        guard url.isFileURL, !url.path.utf8.contains(0), url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        guard !exclusions.contains(where: { ProtectionRules.contains($0, url) }) else {
            throw CleanupSafety.Rejection.unavailable("This folder is excluded in MacSweep Settings.")
        }
        let fd = try openDirectory(url)
        guard let directory = fdopendir(fd) else {
            let code = errno; close(fd); throw NSError(domain: NSPOSIXErrorDomain, code: Int(code))
        }
        defer { closedir(directory) }
        var rootInfo = stat()
        guard fstat(fd, &rootInfo) == 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        let initial = StorageDirectoryStamp(rootInfo)
        if let expectedIdentity, initial.identity != expectedIdentity { throw StorageReadError.changedFolder }
        let started = ProcessInfo.processInfo.systemUptime
        var entries: [StorageEntry] = []
        var examined = 0
        var skipped = 0
        var partial = false
        while true {
            try Task.checkCancellation()
            if examined >= limit.entries || ProcessInfo.processInfo.systemUptime - started >= limit.seconds { partial = true; break }
            errno = 0
            guard let entry = readdir(directory) else {
                if errno != 0 { partial = true; skipped += 1 }
                break
            }
            let name = withUnsafePointer(to: entry.pointee.d_name) { pointer in
                pointer.withMemoryRebound(to: CChar.self, capacity: MemoryLayout.size(ofValue: entry.pointee.d_name)) {
                    String(validatingCString: $0)
                }
            }
            guard let name else { examined += 1; skipped += 1; continue }
            if name == "." || name == ".." { continue }
            examined += 1
            let child = url.appendingPathComponent(name)
            if exclusions.contains(where: { ProtectionRules.contains($0, child) }) { skipped += 1; continue }
            var info = stat()
            guard fstatat(fd, name, &info, AT_SYMLINK_NOFOLLOW) == 0 else { skipped += 1; partial = true; continue }
            let kind: StorageEntry.Kind
            switch info.st_mode & mode_t(S_IFMT) {
            case mode_t(S_IFDIR): kind = .folder
            case mode_t(S_IFREG): kind = .file
            case mode_t(S_IFLNK): kind = .link
            default: kind = .other
            }
            entries.append(StorageEntry(url: child, kind: kind, logicalBytes: max(0, info.st_size),
                                        allocatedBytes: info.st_blocks > Int64.max / 512 ? Int64.max : max(0, info.st_blocks * 512), identity: StorageObjectID(info)))
        }
        try beforeFinish?()
        var finished = stat()
        guard fstat(fd, &finished) == 0 else { throw StorageReadError.changedFolder }
        let unchangedPath = try verify(url, expected: initial)
        if StorageDirectoryStamp(finished) != initial || !unchangedPath { partial = true }
        return StorageDirectoryReport(entries: entries, partial: partial, skipped: skipped, examined: examined, device: rootInfo.st_dev, stamp: initial)
    }
    /// File identity and allocation come from one no-follow metadata read.
    /// Callers enforce their own scan scope and exclusion policy.
    static func fileEntry(_ url: URL) throws -> StorageEntry {
        guard url.isFileURL, !url.path.utf8.contains(0), url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw CocoaError(.fileReadUnsupportedScheme)
        }
        try Task.checkCancellation()
        let fd = try openDirectory(url.deletingLastPathComponent())
        defer { close(fd) }
        var value = stat()
        guard fstatat(fd, url.lastPathComponent, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno))
        }
        guard value.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG), value.st_ino != 0,
              value.st_size >= 0, value.st_blocks >= 0, value.st_blocks <= Int64.max / 512 else {
            throw CocoaError(.fileReadUnknown)
        }
        return StorageEntry(url: url, kind: .file, logicalBytes: value.st_size,
                            allocatedBytes: value.st_blocks * 512, identity: StorageObjectID(value))
    }

    static func verify(_ url: URL, expected: StorageDirectoryStamp) throws -> Bool {
        let fd: Int32
        do { fd = try openDirectory(url) } catch { throw StorageReadError.changedFolder }
        defer { close(fd) }
        var value = stat()
        guard fstat(fd, &value) == 0, StorageObjectID(value) == expected.identity else { throw StorageReadError.changedFolder }
        return StorageDirectoryStamp(value) == expected
    }

    private static func openDirectory(_ url: URL) throws -> Int32 {
        guard url.isFileURL, !url.path.utf8.contains(0), url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else { throw StorageReadError.changedFolder }
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(errno)) }
        for part in url.path.split(separator: "/") {
            if Task.isCancelled { close(fd); throw CancellationError() }
            let next = openat(fd, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno; close(fd)
            guard next >= 0 else { throw NSError(domain: NSPOSIXErrorDomain, code: Int(code)) }
            fd = next
        }
        return fd
    }

}
