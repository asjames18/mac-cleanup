import Darwin
import Foundation

public struct CleanupJournalEntry: Codable, Sendable, Identifiable, Equatable {
    public enum State: String, Codable, Sendable { case pending, moved, failed }
    public let id: UUID
    public let date: Date
    public let source: URL
    public var destination: URL?
    public var state: State
    public var error: String?
    public var sourceSnapshot: RestoreSnapshot?
    public var destinationSnapshot: RestoreSnapshot?
    public var restore: RestoreAttempt?
}

public enum CleanupJournalError: Error, Equatable, Sendable, LocalizedError {
    case invalidInput, unsafePath, corruptRecord, missingRecord, alreadyCompleted, capacityExceeded, pendingConflict
    case io(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidInput: return "The cleanup history entry contains invalid or oversized information."
        case .unsafePath: return "Cleanup history cannot use a symbolic link or an unsafe folder."
        case .corruptRecord: return "Cleanup history contains an unreadable or invalid record. Cleanup has stopped to preserve it."
        case .missingRecord: return "The pending cleanup history record could not be found."
        case .alreadyCompleted: return "This cleanup history record already has a recorded outcome."
        case .pendingConflict: return "An overlapping cleanup or restore has an unknown outcome in History. Inspect the recorded locations before another removal; retry is blocked."
        case .capacityExceeded: return "Cleanup history has reached its limit of 10,000 records."
        case .io(let code): return "Cleanup history could not be saved or read (system error \(code))."
        }
    }
}

/// A pending entry records intent, not proof that the source remains in place. Trash and
/// journal updates cannot be atomic together. Interrupted operations require inspection,
/// never automatic retry. Records are atomically replaced and synced before returning.
public final class CleanupJournal: @unchecked Sendable {
    private let directory: URL
    private let lock = NSLock()
    private let maximumRecords = 10_000
    private let maximumRecordBytes = 65_536

    public init(directory: URL) { self.directory = directory }

    public var storageDirectory: URL { directory }

    @discardableResult
    public func recordIntent(source: URL) throws -> UUID {
        try validateURL(source)
        return try withDirectory { fd in
            // Fail closed on existing corruption before authorizing another mutation.
            // This initial bounded store scans O(n) records per intent (O(n²) for a batch).
            let existing = try readEntries(fd)
            // Foundation standardization can rewrite existing /private/var paths
            // differently from missing paths. Compare lexical components only.
            func normalized(_ url: URL) -> String {
                var parts: [Substring] = []
                for part in url.path.split(separator: "/") {
                    if part == "." { continue }
                    if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
                    parts.append(part)
                }
                return ("/" + parts.joined(separator: "/")).lowercased()
            }
            let target = normalized(source)
            func overlaps(_ other: URL) -> Bool {
                let path = normalized(other)
                return target == path || target.hasPrefix(path == "/" ? "/" : path + "/") || path.hasPrefix(target == "/" ? "/" : target + "/")
            }
            guard !existing.contains(where: { entry in
                guard entry.state == .pending || entry.restore?.state == .pending else { return false }
                return ([entry.source] + [entry.destination, entry.restore?.destination].compactMap { $0 }).contains(where: overlaps)
            }) else { throw CleanupJournalError.pendingConflict }
            guard existing.count < maximumRecords else { throw CleanupJournalError.capacityExceeded }
            let entry = CleanupJournalEntry(id: UUID(), date: Date(), source: source,
                                            destination: nil, state: .pending, error: nil,
                                            sourceSnapshot: try? RestoreSnapshot.capture(source))
            try persist(entry, fd: fd, replacing: false)
            return entry.id
        }
    }

    /// Keep uncertain mutations pending while retaining their diagnostic. A later
    /// read of the source cannot prove that a multi-step mover changed nothing.
    public func recordUncertainOutcome(id: UUID, error: String) throws {
        guard !error.isEmpty, error.utf8.count <= 8_192 else { throw CleanupJournalError.invalidInput }
        try withDirectory { fd in
            var entry = try readEntry(name: filename(id), fd: fd)
            guard entry.state == .pending else { throw CleanupJournalError.alreadyCompleted }
            entry.error = error
            try persist(entry, fd: fd, replacing: true)
        }
    }

    public func recordOutcome(id: UUID, destination: URL?, failure: String?) throws {
        if let destination { try validateURL(destination) }
        if let failure {
            guard !failure.isEmpty, failure.utf8.count <= 8_192, destination == nil else {
                throw CleanupJournalError.invalidInput
            }
        }
        try withDirectory { fd in
            var entry = try readEntry(name: filename(id), fd: fd)
            guard entry.state == .pending else { throw CleanupJournalError.alreadyCompleted }
            entry.destination = destination
            entry.error = failure
            entry.state = failure == nil ? .moved : .failed
            if failure == nil, let original = entry.sourceSnapshot, let destination,
               let arrived = try? RestoreSnapshot.capture(destination), arrived.isSameObject(as: original) {
                entry.destinationSnapshot = arrived
            }
            try persist(entry, fd: fd, replacing: true)
        }
    }

    /// Explicit review may complete evidence capture that macOS previously denied.
    /// Availability checks never write; only matching recorded source identity and
    /// unchanged content metadata authorize this journal-only update.
    func verifiedRestoreEntry(id: UUID) throws -> CleanupJournalEntry {
        try withDirectory { fd in
            _ = try readEntries(fd)
            let entry = try readEntry(name: filename(id), fd: fd)
            let verified = try RestoreEngine.verifiedCandidate(entry)
            if verified != entry { try persist(verified, fd: fd, replacing: true) }
            return verified
        }
    }

    /// Hold the same process/cross-process lock across intent, mutation and outcome.
    /// Definitive no-move failures are durable and require a fresh review.
    /// Unknown failures after intent retain pending; they cannot be retried.
    func commitRestore(_ plan: RestorePlan, mutation: () throws -> Void) throws {
        try withDirectory { fd in
            _ = try readEntries(fd)
            var entry = try readEntry(name: filename(plan.id), fd: fd)
            guard entry == plan.entry, entry.state == .moved, (entry.restore == nil || entry.restore?.state == .failed),
                  entry.destinationSnapshot != nil else { throw RestoreError.invalidState }
            entry.restore = RestoreAttempt(destination: plan.destination, date: Date(), state: .pending)
            try persist(entry, fd: fd, replacing: true)
            do { try mutation() }
            catch let failure as RestoreNotMoved {
                entry.restore?.state = .failed
                entry.restore?.error = failure.underlying.localizedDescription
                try persist(entry, fd: fd, replacing: true)
                throw failure.underlying
            }
            entry.restore?.state = .restored
            try persist(entry, fd: fd, replacing: true)
        }
    }

    /// User-confirmed reconciliation updates only the journal. Re-read the exact
    /// reviewed entry under the operation lock and repeat endpoint verification.
    func reconcileRestore(_ plan: RestoreReconciliationPlan, verify: () throws -> Void) throws {
        try withDirectory { fd in
            _ = try readEntries(fd)
            var entry = try readEntry(name: filename(plan.id), fd: fd)
            guard entry == plan.entry, entry.restore?.state == .pending else { throw RestoreError.invalidState }
            try verify()
            try Task.checkCancellation()
            entry.restore?.state = .restored
            entry.restore?.reconciledAt = Date()
            try persist(entry, fd: fd, replacing: true)
        }
    }

    public func entries() throws -> [CleanupJournalEntry] {
        try withDirectory { try readEntries($0) }
    }

    private func validateURL(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), url.path.utf8.count <= 4_096,
              !url.path.utf8.contains(0) else { throw CleanupJournalError.invalidInput }
    }

    private func withDirectory<T>(_ action: (Int32) throws -> T) throws -> T {
        lock.lock()
        defer { lock.unlock() }
        try validateURL(directory)
        guard !directory.path.split(separator: "/").contains(".."), directory.path != "/" else {
            throw CleanupJournalError.unsafePath
        }
        // Walk from the filesystem root using pinned descriptors. O_NOFOLLOW applies
        // to every component, including ancestors; no recursive path-based creation
        // may follow a link. Existing ancestor permissions are never changed.
        var fd = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard fd >= 0 else { throw CleanupJournalError.io(errno) }
        defer { close(fd) }
        for component in directory.path.split(separator: "/") {
            let name = String(component)
            guard name != "." else { throw CleanupJournalError.unsafePath }
            var next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            if next < 0 {
                guard errno == ENOENT else { throw CleanupJournalError.unsafePath }
                guard mkdirat(fd, name, 0o700) == 0 || errno == EEXIST else {
                    throw CleanupJournalError.io(errno)
                }
                next = openat(fd, name, O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw CleanupJournalError.unsafePath }
                guard fsync(fd) == 0 else {
                    close(next)
                    throw CleanupJournalError.io(errno)
                }
            }
            close(fd)
            fd = next
        }
        var metadata = stat()
        guard fstat(fd, &metadata) == 0, metadata.st_uid == geteuid() else {
            throw CleanupJournalError.unsafePath
        }
        guard fchmod(fd, 0o700) == 0, flock(fd, LOCK_EX) == 0 else {
            throw CleanupJournalError.io(errno)
        }
        defer { flock(fd, LOCK_UN) }
        return try action(fd)
    }

    private func filename(_ id: UUID) -> String { id.uuidString + ".json" }

    private func readEntries(_ fd: Int32) throws -> [CleanupJournalEntry] {
        // Enumerate through a duplicate of the pinned directory descriptor, so a rename
        // of the journal directory cannot redirect reads or writes to another directory.
        let duplicate = dup(fd)
        guard duplicate >= 0 else { throw CleanupJournalError.io(errno) }
        guard let stream = fdopendir(duplicate) else {
            close(duplicate)
            throw CleanupJournalError.io(errno)
        }
        defer { closedir(stream) }
        rewinddir(stream)
        var result: [CleanupJournalEntry] = []
        while true {
            errno = 0
            guard let next = readdir(stream) else {
                guard errno == 0 else { throw CleanupJournalError.io(errno) }
                break
            }
            let name = withUnsafePointer(to: &next.pointee.d_name) {
                $0.withMemoryRebound(to: CChar.self, capacity: Int(next.pointee.d_namlen) + 1) { String(cString: $0) }
            }
            if name == "." || name == ".." { continue }
            // Abandoned staging files are never operation records and are never replayed.
            if name.hasPrefix(".staging-") { continue }
            guard result.count < maximumRecords else { throw CleanupJournalError.capacityExceeded }
            result.append(try readEntry(name: name, fd: fd))
        }
        return result.sorted { $0.date == $1.date ? $0.id.uuidString > $1.id.uuidString : $0.date > $1.date }
    }

    private func readEntry(name: String, fd: Int32) throws -> CleanupJournalEntry {
        guard name.hasSuffix(".json"), let id = UUID(uuidString: String(name.dropLast(5))),
              name == filename(id) else { throw CleanupJournalError.corruptRecord }
        let file = openat(fd, name, O_RDONLY | O_NOFOLLOW | O_NONBLOCK | O_CLOEXEC)
        guard file >= 0 else {
            if errno == ENOENT { throw CleanupJournalError.missingRecord }
            throw CleanupJournalError.unsafePath
        }
        defer { close(file) }
        var metadata = stat()
        guard fstat(file, &metadata) == 0,
              metadata.st_mode & mode_t(S_IFMT) == mode_t(S_IFREG),
              metadata.st_nlink == 1, metadata.st_uid == geteuid(),
              metadata.st_size > 0, metadata.st_size <= maximumRecordBytes else {
            throw CleanupJournalError.corruptRecord
        }
        guard fchmod(file, 0o600) == 0 else { throw CleanupJournalError.io(errno) }
        var data = Data(count: Int(metadata.st_size))
        let count = data.withUnsafeMutableBytes { buffer in
            Darwin.read(file, buffer.baseAddress, buffer.count)
        }
        guard count == data.count else { throw CleanupJournalError.corruptRecord }
        let entry: CleanupJournalEntry
        do { entry = try JSONDecoder().decode(CleanupJournalEntry.self, from: data) }
        catch { throw CleanupJournalError.corruptRecord }
        guard entry.id == id, entry.date.timeIntervalSince1970.isFinite else { throw CleanupJournalError.corruptRecord }
        do {
            try validateURL(entry.source)
            if let destination = entry.destination { try validateURL(destination) }
        } catch { throw CleanupJournalError.corruptRecord }
        if let restore = entry.restore {
            guard entry.state == .moved, entry.destinationSnapshot != nil,
                  restore.date.timeIntervalSince1970.isFinite else { throw CleanupJournalError.corruptRecord }
            do { try validateURL(restore.destination) } catch { throw CleanupJournalError.corruptRecord }
            if let checked = restore.reconciledAt {
                guard checked.timeIntervalSince1970.isFinite, restore.state == .restored else { throw CleanupJournalError.corruptRecord }
            }
        }
        guard entry.destinationSnapshot == nil || (entry.state == .moved && entry.destination != nil) else {
            throw CleanupJournalError.corruptRecord
        }
        switch entry.state {
        case .pending:
            guard entry.destination == nil else { throw CleanupJournalError.corruptRecord }
            if let error = entry.error {
                guard !error.isEmpty, error.utf8.count <= 8_192 else { throw CleanupJournalError.corruptRecord }
            }
        case .moved:
            guard entry.error == nil else { throw CleanupJournalError.corruptRecord }
        case .failed:
            guard entry.destination == nil, let error = entry.error, !error.isEmpty,
                  error.utf8.count <= 8_192 else { throw CleanupJournalError.corruptRecord }
        }
        return entry
    }

    private func persist(_ entry: CleanupJournalEntry, fd: Int32, replacing: Bool) throws {
        let name = filename(entry.id)
        if replacing { _ = try readEntry(name: name, fd: fd) }
        else {
            var metadata = stat()
            guard fstatat(fd, name, &metadata, AT_SYMLINK_NOFOLLOW) != 0, errno == ENOENT else {
                throw CleanupJournalError.unsafePath
            }
        }
        let data = try JSONEncoder().encode(entry)
        guard data.count <= maximumRecordBytes else { throw CleanupJournalError.invalidInput }
        let staging = ".staging-" + UUID().uuidString
        let file = openat(fd, staging, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard file >= 0 else { throw CleanupJournalError.io(errno) }
        defer { close(file); unlinkat(fd, staging, 0) }
        try data.withUnsafeBytes { bytes in
            var offset = 0
            while offset < bytes.count {
                let count = Darwin.write(file, bytes.baseAddress!.advanced(by: offset), bytes.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw CleanupJournalError.io(errno) }
                offset += count
            }
        }
        guard fsync(file) == 0, renameat(fd, staging, fd, name) == 0, fsync(fd) == 0 else {
            throw CleanupJournalError.io(errno)
        }
    }
}
