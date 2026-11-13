import Darwin
import Foundation

/// Metadata is captured after the Trash move. Conservative change detection also
/// refuses files edited in Trash and directories whose immediate contents changed.
public struct RestoreSnapshot: Codable, Sendable, Equatable {
    let device: Int32
    let inode: UInt64
    let mode: UInt16
    let size: Int64
    let birthSeconds: Int64
    let birthNanos: Int64
    let modifiedSeconds: Int64
    let modifiedNanos: Int64
    let changedSeconds: Int64
    let changedNanos: Int64

    init(_ value: stat) {
        device = value.st_dev; inode = value.st_ino; mode = value.st_mode; size = value.st_size
        birthSeconds = Int64(value.st_birthtimespec.tv_sec); birthNanos = Int64(value.st_birthtimespec.tv_nsec)
        modifiedSeconds = Int64(value.st_mtimespec.tv_sec); modifiedNanos = Int64(value.st_mtimespec.tv_nsec)
        changedSeconds = Int64(value.st_ctimespec.tv_sec); changedNanos = Int64(value.st_ctimespec.tv_nsec)
    }

    func isSameObject(as other: RestoreSnapshot) -> Bool {
        device == other.device && inode == other.inode && birthSeconds == other.birthSeconds &&
        birthNanos == other.birthNanos && (mode & UInt16(S_IFMT)) == (other.mode & UInt16(S_IFMT))
    }

    static func capture(_ url: URL) throws -> RestoreSnapshot {
        let parent = try RestoreDirectory(url.deletingLastPathComponent())
        return try parent.snapshot(url.lastPathComponent)
    }
}

public struct RestoreAttempt: Codable, Sendable, Equatable {
    public enum State: String, Codable, Sendable { case pending, restored, failed }
    public let destination: URL
    public let date: Date
    public var state: State
    public var error: String? = nil
    public var reconciledAt: Date? = nil
}

/// Thrown only before a move or for a definitive rejected rename. Unknown I/O
/// and post-move verification failures must never use this marker.
struct RestoreNotMoved: Error {
    let underlying: Error
}

/// Only review can create a plan. Its complete journal entry and destination are
/// immutable; execution requires an explicit call after the user confirms them.
public struct RestorePlan: Sendable, Identifiable {
    public var id: UUID { entry.id }
    public var source: URL { entry.destination! }
    public let destination: URL
    let entry: CleanupJournalEntry
    let sourceParentSnapshot: RestoreSnapshot?
    let destinationParentSnapshot: RestoreSnapshot?
}

public enum RestoreError: Error, Sendable, Equatable, LocalizedError {
    case legacyRecord, invalidState, missingTrash, changedObject, changedFolder, conflict, unsafePath, accessDenied, crossVolume, io(Int32)
    public var errorDescription: String? {
        switch self {
        case .legacyRecord: return "Manual recovery only: this record has no verified Trash identity. Use Finder to inspect it."
        case .invalidState: return "Recovery is unavailable for this record. A pending restore has an uncertain outcome and must be inspected in Finder; it is never retried automatically."
        case .missingTrash: return "The recorded Trash item is missing. It may already have been restored or removed."
        case .changedObject: return "The Trash object has changed since cleanup. Inspect it in Finder before recovering it manually."
        case .changedFolder: return "A reviewed recovery folder has changed. Review the destination again before restoring."
        case .conflict: return "An item already exists at the restore destination. Choose another existing folder; nothing will be overwritten."
        case .unsafePath: return "Recovery requires existing folders without symbolic links, outside cleanup history and the Trash object."
        case .accessDenied: return "macOS denied access to this recovery location. Check System Settings > Privacy & Security > Full Disk Access for MacSweep, then refresh and retry. Managed restrictions may still apply."
        case .crossVolume: return "Recovery across volumes is unsupported. Choose an existing folder on the Trash item's volume."
        case .io(let code): return "Recovery could not finish (system error \(code)). Inspect the recorded locations in Finder before taking further action."
        }
    }
}

/// Directory-relative operations pin every ancestor and reject links. No folders
/// are created, and RENAME_EXCL makes the final destination collision check atomic.
private final class RestoreDirectory {
    let fd: Int32
    init(_ url: URL) throws {
        try Self.validate(url)
        var current = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard current >= 0 else { throw Self.pathError(errno) }
        do {
            for part in url.path.split(separator: "/") {
                let next = openat(current, String(part), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
                guard next >= 0 else { throw Self.pathError(errno) }
                close(current); current = next
            }
        } catch { close(current); throw error }
        fd = current
    }
    deinit { close(fd) }
    private static func pathError(_ code: Int32) -> RestoreError {
        code == EPERM || code == EACCES ? .accessDenied : .unsafePath
    }
    static func validate(_ url: URL) throws {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              url.path.hasPrefix("/"), url.path.utf8.count <= 4096, !url.path.utf8.contains(0),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            throw RestoreError.unsafePath
        }
    }
    func snapshot(_ name: String) throws -> RestoreSnapshot {
        var value = stat()
        guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) == 0 else {
            if errno == ENOENT { throw RestoreError.missingTrash }
            if errno == EPERM || errno == EACCES { throw RestoreError.accessDenied }
            throw RestoreError.io(errno)
        }
        let kind = value.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) else { throw RestoreError.unsafePath }
        return RestoreSnapshot(value)
    }
    func requireAbsent(_ name: String) throws {
        var value = stat()
        guard fstatat(fd, name, &value, AT_SYMLINK_NOFOLLOW) != 0 else { throw RestoreError.conflict }
        guard errno == ENOENT else { throw Self.pathError(errno) }
    }
    var snapshot: RestoreSnapshot {
        get throws {
            var value = stat()
            guard fstat(fd, &value) == 0 else { throw RestoreError.io(errno) }
            return RestoreSnapshot(value)
        }
    }
    var device: Int32 {
        get throws {
            var value = stat()
            guard fstat(fd, &value) == 0 else { throw RestoreError.io(errno) }
            return value.st_dev
        }
    }
}

public final class RestoreEngine: Sendable {
    private let journal: CleanupJournal
    public init(journal: CleanupJournal) { self.journal = journal }

    public func review(id: UUID, destination: URL? = nil) throws -> RestorePlan {
        let entry = try journal.verifiedRestoreEntry(id: id)
        let plan = RestorePlan(destination: destination ?? entry.source, entry: entry, sourceParentSnapshot: nil, destinationParentSnapshot: nil)
        let parents = try validate(plan)
        return RestorePlan(destination: plan.destination, entry: entry,
                           sourceParentSnapshot: try parents.0.snapshot,
                           destinationParentSnapshot: try parents.1.snapshot)
    }

    /// Assess an already-loaded entry without re-reading the complete journal.
    /// Execution still checks the original durable entry under the journal lock.
    public func assess(_ entry: CleanupJournalEntry) throws {
        let verified = try Self.verifiedCandidate(entry)
        _ = try validate(RestorePlan(destination: verified.source, entry: verified, sourceParentSnapshot: nil, destinationParentSnapshot: nil))
    }

    /// A denied post-Trash read is recoverable only with durable pre-move
    /// evidence. Rename can change ctime; size and mtime must still match. This
    /// pure check is used for availability and repeated under the journal lock
    /// during explicit review before its verified snapshot is persisted.
    static func verifiedCandidate(_ entry: CleanupJournalEntry) throws -> CleanupJournalEntry {
        guard entry.state == .moved, (entry.restore == nil || entry.restore?.state == .failed) else { throw RestoreError.invalidState }
        if entry.destinationSnapshot != nil { return entry }
        guard let original = entry.sourceSnapshot, let destination = entry.destination else { throw RestoreError.legacyRecord }
        let current = try RestoreSnapshot.capture(destination)
        guard current.isSameObject(as: original), current.size == original.size,
              current.modifiedSeconds == original.modifiedSeconds,
              current.modifiedNanos == original.modifiedNanos else { throw RestoreError.changedObject }
        var verified = entry
        verified.destinationSnapshot = current
        return verified
    }

    public func restore(_ plan: RestorePlan) throws {
        // Validate both before durable intent and immediately before the exclusive
        // rename, keeping directory descriptors open across the journal write.
        let (sourceParent, targetParent) = try validate(plan)
        try journal.commitRestore(plan) {
            do {
                guard try sourceParent.snapshot(plan.source.lastPathComponent) == plan.entry.destinationSnapshot else {
                    throw RestoreError.changedObject
                }
                try targetParent.requireAbsent(plan.destination.lastPathComponent)
            } catch { throw RestoreNotMoved(underlying: error) }
            guard renameatx_np(sourceParent.fd, plan.source.lastPathComponent,
                               targetParent.fd, plan.destination.lastPathComponent, UInt32(RENAME_EXCL)) == 0 else {
                if errno == EEXIST { throw RestoreNotMoved(underlying: RestoreError.conflict) }
                if errno == EXDEV { throw RestoreNotMoved(underlying: RestoreError.crossVolume) }
                if errno == EPERM || errno == EACCES { throw RestoreNotMoved(underlying: RestoreError.accessDenied) }
                throw RestoreError.io(errno)
            }
            // Darwin has no compare-identity-and-rename primitive. A source name
            // can race the last check. Verify the object at both the pinned target
            // and chosen path before claiming success; uncertainty stays pending,
            // with no automatic rollback or retry.
            let actual = try targetParent.snapshot(plan.destination.lastPathComponent)
            guard let expected = plan.entry.destinationSnapshot, actual.isSameObject(as: expected),
                  try RestoreSnapshot.capture(plan.destination).isSameObject(as: expected),
                  let expectedParent = plan.destinationParentSnapshot,
                  try RestoreDirectory(plan.destination.deletingLastPathComponent()).snapshot.isSameObject(as: expectedParent) else {
                throw RestoreError.changedObject
            }
            guard fsync(sourceParent.fd) == 0, fsync(targetParent.fd) == 0 else { throw RestoreError.io(errno) }
        }
    }

    private func validate(_ plan: RestorePlan) throws -> (RestoreDirectory, RestoreDirectory) {
        guard plan.entry.state == .moved, (plan.entry.restore == nil || plan.entry.restore?.state == .failed) else { throw RestoreError.invalidState }
        guard let snapshot = plan.entry.destinationSnapshot, let source = plan.entry.destination else { throw RestoreError.legacyRecord }
        try RestoreDirectory.validate(source)
        try RestoreDirectory.validate(plan.destination)
        let target = plan.destination.path
        let origin = source.path
        let history = journal.storageDirectory.path
        func overlaps(_ a: String, _ b: String) -> Bool { a == b || a.hasPrefix(b + "/") || b.hasPrefix(a + "/") }
        guard target != "/", origin != "/", !overlaps(target, history), !overlaps(origin, history),
              !overlaps(target, origin) else { throw RestoreError.unsafePath }
        let sourceParent = try RestoreDirectory(source.deletingLastPathComponent())
        let targetParent = try RestoreDirectory(plan.destination.deletingLastPathComponent())
        if let expected = plan.sourceParentSnapshot,
           try !sourceParent.snapshot.isSameObject(as: expected) { throw RestoreError.changedFolder }
        if let expected = plan.destinationParentSnapshot,
           try !targetParent.snapshot.isSameObject(as: expected) { throw RestoreError.changedFolder }
        guard try sourceParent.snapshot(source.lastPathComponent) == snapshot else { throw RestoreError.changedObject }
        guard try targetParent.device == snapshot.device else { throw RestoreError.crossVolume }
        try targetParent.requireAbsent(plan.destination.lastPathComponent)
        return (sourceParent, targetParent)
    }
}


public enum RestoreOutcomeError: Error, Sendable, Equatable, LocalizedError {
    case missingDestination, occupiedTrashLocation, changedDestination
    public var errorDescription: String? {
        switch self {
        case .missingDestination: return "The expected restored item is missing from its recorded destination. Inspect both recorded locations; the outcome remains unknown."
        case .occupiedTrashLocation: return "The former Trash location is occupied. MacSweep cannot confirm this restore while both locations contain items. Inspect both locations in Finder."
        case .changedDestination: return "The item at the restore destination does not match the recorded identity or reviewed metadata. Inspect it in Finder; the outcome remains unknown."
        }
    }
}

/// A journal-only recovery review. Confirming it never moves or deletes a file.
public struct RestoreReconciliationPlan: Sendable, Identifiable {
    public var id: UUID { entry.id }
    public var formerTrashLocation: URL { entry.destination! }
    public var restoredLocation: URL { entry.restore!.destination }
    let entry: CleanupJournalEntry
    let observed: RestoreSnapshot
    let formerTrashParent: RestoreSnapshot
    let restoredParent: RestoreSnapshot
}

extension RestoreEngine {
    public func reviewReconciliation(id: UUID) throws -> RestoreReconciliationPlan {
        guard let entry = try journal.entries().first(where: { $0.id == id }) else { throw CleanupJournalError.missingRecord }
        let evidence = try Self.verifyRestoredOutcome(entry)
        return RestoreReconciliationPlan(entry: entry, observed: evidence.item,
                                         formerTrashParent: evidence.oldParent, restoredParent: evidence.newParent)
    }

    public func confirmReconciliation(_ plan: RestoreReconciliationPlan) throws {
        try journal.reconcileRestore(plan) {
            let evidence = try Self.verifyRestoredOutcome(plan.entry)
            guard evidence.oldParent.isSameObject(as: plan.formerTrashParent),
                  evidence.newParent.isSameObject(as: plan.restoredParent) else { throw RestoreError.changedFolder }
            guard evidence.item == plan.observed else { throw RestoreOutcomeError.changedDestination }
        }
    }

    private static func verifyRestoredOutcome(_ entry: CleanupJournalEntry) throws -> (item: RestoreSnapshot, oldParent: RestoreSnapshot, newParent: RestoreSnapshot) {
        try Task.checkCancellation()
        guard entry.state == .moved, entry.restore?.state == .pending,
              let expected = entry.destinationSnapshot, let trash = entry.destination,
              let destination = entry.restore?.destination else { throw RestoreError.invalidState }
        guard trash != destination else { throw RestoreError.unsafePath }
        let oldParent = try RestoreDirectory(trash.deletingLastPathComponent())
        let newParent = try RestoreDirectory(destination.deletingLastPathComponent())
        let oldIdentity = try oldParent.snapshot
        let newIdentity = try newParent.snapshot
        let actual: RestoreSnapshot
        do { actual = try newParent.snapshot(destination.lastPathComponent) }
        catch RestoreError.missingTrash { throw RestoreOutcomeError.missingDestination }
        guard actual.isSameObject(as: expected), actual.size == expected.size,
              actual.modifiedSeconds == expected.modifiedSeconds,
              actual.modifiedNanos == expected.modifiedNanos else { throw RestoreOutcomeError.changedDestination }
        do { try oldParent.requireAbsent(trash.lastPathComponent) }
        catch RestoreError.conflict { throw RestoreOutcomeError.occupiedTrashLocation }
        guard try RestoreDirectory(trash.deletingLastPathComponent()).snapshot.isSameObject(as: oldIdentity),
              try RestoreDirectory(destination.deletingLastPathComponent()).snapshot.isSameObject(as: newIdentity),
              try RestoreSnapshot.capture(destination) == actual else { throw RestoreError.changedFolder }
        try Task.checkCancellation()
        return (actual, oldIdentity, newIdentity)
    }
}
