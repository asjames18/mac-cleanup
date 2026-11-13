import CryptoKit
import Darwin
import Foundation

public enum StableFileHashError: Error, Equatable, Sendable {
    case invalidURL
    case symbolicLink
    case unsupportedFileType
    case cancelled
    case changedDuringRead
    case ioFailure(Int32)
}

/// Hashes the bytes read from one regular-file descriptor and rejects files whose
/// identity or metadata changes during the read. Filesystem validation and later
/// caller actions remain separate operations and are not atomic.
public enum StableFileHasher {
    public static func sha256(
        _ url: URL,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> String {
        try sha256(url, isCancelled: isCancelled, afterChunk: { _ in })
    }

    static func sha256(
        _ url: URL,
        isCancelled: () -> Bool = { Task.isCancelled },
        beforeDescriptorTraversal: () throws -> Void = {},
        afterChunk: (Int) throws -> Void
    ) throws -> String {
        guard !isCancelled() else { throw StableFileHashError.cancelled }

        let pathBefore = try capturePath(url)
        try beforeDescriptorTraversal()
        let descriptor = try openWithoutFollowingLinks(url)
        defer { Darwin.close(descriptor) }

        let descriptorBefore = try captureDescriptor(descriptor)
        guard descriptorBefore.kind == mode_t(S_IFREG) else {
            throw StableFileHashError.unsupportedFileType
        }
        guard descriptorBefore.matches(pathBefore) else {
            throw StableFileHashError.changedDuringRead
        }

        var hasher = SHA256()
        var buffer = [UInt8](repeating: 0, count: 1_048_576)
        var chunk = 0
        while true {
            guard !isCancelled() else { throw StableFileHashError.cancelled }
            let count = Darwin.read(descriptor, &buffer, buffer.count)
            if count < 0 {
                if errno == EINTR { continue }
                throw StableFileHashError.ioFailure(errno)
            }
            if count == 0 { break }
            hasher.update(data: Data(buffer[0..<count]))
            chunk += 1
            try afterChunk(chunk)
        }

        guard !isCancelled() else { throw StableFileHashError.cancelled }
        let descriptorAfter = try captureDescriptor(descriptor)
        let pathAfter = try capturePath(url)
        guard descriptorBefore == descriptorAfter,
              descriptorAfter.matches(pathAfter),
              pathBefore == pathAfter else {
            throw StableFileHashError.changedDuringRead
        }

        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private static func capturePath(_ url: URL) throws -> FileSnapshot {
        do {
            return try FileSnapshotReader.capture(url)
        } catch let error as FileSnapshotError {
            switch error {
            case .invalidURL:
                throw StableFileHashError.invalidURL
            case .symbolicLink:
                throw StableFileHashError.symbolicLink
            case .unsupportedFileType:
                throw StableFileHashError.unsupportedFileType
            case .unreliableIdentity:
                throw StableFileHashError.changedDuringRead
            case .metadataUnavailable(let code):
                throw StableFileHashError.ioFailure(code)
            }
        }
    }

    private static func captureDescriptor(_ descriptor: Int32) throws -> DescriptorSnapshot {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw StableFileHashError.ioFailure(errno)
        }
        return DescriptorSnapshot(metadata)
    }

    private static func openWithoutFollowingLinks(_ url: URL) throws -> Int32 {
        let components = url.path.split(separator: "/").map(String.init)
        guard let leaf = components.last else { throw StableFileHashError.unsupportedFileType }

        var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK)
        guard parent >= 0 else { throw StableFileHashError.ioFailure(errno) }

        for component in components.dropLast() {
            let next = component.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard next >= 0 else {
                let code = errno
                Darwin.close(parent)
                if code == ELOOP || code == ENOTDIR { throw StableFileHashError.symbolicLink }
                throw StableFileHashError.ioFailure(code)
            }
            Darwin.close(parent)
            parent = next
        }

        let descriptor = leaf.withCString {
            Darwin.openat(parent, $0, O_RDONLY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
        }
        let code = errno
        Darwin.close(parent)
        guard descriptor >= 0 else {
            if code == ELOOP { throw StableFileHashError.symbolicLink }
            throw StableFileHashError.ioFailure(code)
        }
        return descriptor
    }
}

private struct DescriptorSnapshot: Equatable {
    let device: UInt64
    let inode: UInt64
    let size: Int64
    let modifiedSeconds: Int
    let modifiedNanoseconds: Int
    let changedSeconds: Int
    let changedNanoseconds: Int
    let kind: mode_t

    init(_ metadata: stat) {
        device = UInt64(metadata.st_dev)
        inode = UInt64(metadata.st_ino)
        size = metadata.st_size
        modifiedSeconds = metadata.st_mtimespec.tv_sec
        modifiedNanoseconds = metadata.st_mtimespec.tv_nsec
        changedSeconds = metadata.st_ctimespec.tv_sec
        changedNanoseconds = metadata.st_ctimespec.tv_nsec
        kind = metadata.st_mode & mode_t(S_IFMT)
    }

    func matches(_ snapshot: FileSnapshot) -> Bool {
        snapshot.identity == FileIdentity(volumeKey: String(device), resourceKey: String(inode))
            && snapshot.logicalBytes == size
            && snapshot.modifiedAt == date(seconds: modifiedSeconds, nanoseconds: modifiedNanoseconds)
            && snapshot.changedAt == date(seconds: changedSeconds, nanoseconds: changedNanoseconds)
    }

    private func date(seconds: Int, nanoseconds: Int) -> Date {
        Date(timeIntervalSince1970: Double(seconds) + Double(nanoseconds) / 1_000_000_000)
    }
}
