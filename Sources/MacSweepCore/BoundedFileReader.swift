import Darwin
import Foundation

public enum BoundedFileReadError: Error, Equatable, Sendable, LocalizedError {
    case invalidURL
    case invalidMaximumBytes
    case symbolicLink
    case unsupportedFileType
    case tooLarge(maximumBytes: Int)
    case cancelled
    case changedDuringRead
    case ioFailure(Int32)

    public var errorDescription: String? {
        switch self {
        case .invalidURL:
            "The file URL is invalid."
        case .invalidMaximumBytes:
            "The maximum byte count must not be negative."
        case .symbolicLink:
            "Symbolic links cannot be read safely."
        case .unsupportedFileType:
            "Only regular files can be read."
        case .tooLarge(let maximumBytes):
            "The file exceeds the \(maximumBytes)-byte read limit."
        case .cancelled:
            "The file read was cancelled."
        case .changedDuringRead:
            "The file changed while it was being read."
        case .ioFailure(let code):
            "The file could not be read (system error \(code))."
        }
    }
}

/// Reads one stable regular file without following symbolic links and without
/// allocating or consuming more than `maximumBytes + 1` bytes from the file.
public enum BoundedFileReader {
    public static func read(
        _ url: URL,
        maximumBytes: Int = 1_048_576,
        isCancelled: () -> Bool = { Task.isCancelled }
    ) throws -> Data {
        try read(
            url,
            maximumBytes: maximumBytes,
            isCancelled: isCancelled,
            beforeDescriptorTraversal: {},
            afterChunk: { _ in }
        )
    }

    static func read(
        _ url: URL,
        maximumBytes: Int = 1_048_576,
        isCancelled: () -> Bool = { Task.isCancelled },
        beforeDescriptorTraversal: () throws -> Void = {},
        afterChunk: (Int) throws -> Void
    ) throws -> Data {
        guard maximumBytes >= 0 else { throw BoundedFileReadError.invalidMaximumBytes }
        guard !isCancelled() else { throw BoundedFileReadError.cancelled }

        let pathBefore = try capturePath(url)
        guard pathBefore.logicalBytes <= Int64(maximumBytes) else {
            throw BoundedFileReadError.tooLarge(maximumBytes: maximumBytes)
        }

        try beforeDescriptorTraversal()
        let descriptor = try openWithoutFollowingLinks(url)
        defer { Darwin.close(descriptor) }

        let descriptorBefore = try captureDescriptor(descriptor)
        guard descriptorBefore.kind == mode_t(S_IFREG) else {
            throw BoundedFileReadError.unsupportedFileType
        }
        guard descriptorBefore.matches(pathBefore) else {
            throw BoundedFileReadError.changedDuringRead
        }
        guard descriptorBefore.size <= Int64(maximumBytes) else {
            throw BoundedFileReadError.tooLarge(maximumBytes: maximumBytes)
        }

        var data = Data()
        data.reserveCapacity(min(maximumBytes, Int(descriptorBefore.size)))
        var buffer = [UInt8](repeating: 0, count: min(65_536, maximumBytes == Int.max ? Int.max : maximumBytes + 1))
        var chunk = 0

        while true {
            guard !isCancelled() else { throw BoundedFileReadError.cancelled }
            let remaining = maximumBytes - data.count
            let requested = remaining >= buffer.count ? buffer.count : remaining + 1
            let count = Darwin.read(descriptor, &buffer, requested)
            if count < 0 {
                if errno == EINTR { continue }
                throw BoundedFileReadError.ioFailure(errno)
            }
            if count == 0 { break }
            guard count <= remaining else {
                throw BoundedFileReadError.tooLarge(maximumBytes: maximumBytes)
            }
            data.append(contentsOf: buffer[0..<count])
            chunk += 1
            try afterChunk(chunk)
        }

        guard !isCancelled() else { throw BoundedFileReadError.cancelled }
        let descriptorAfter = try captureDescriptor(descriptor)
        let pathAfter = try capturePath(url)
        guard descriptorBefore == descriptorAfter,
              descriptorAfter.matches(pathAfter),
              pathBefore == pathAfter else {
            throw BoundedFileReadError.changedDuringRead
        }
        return data
    }

    private static func capturePath(_ url: URL) throws -> FileSnapshot {
        do {
            return try FileSnapshotReader.capture(url)
        } catch let error as FileSnapshotError {
            switch error {
            case .invalidURL:
                throw BoundedFileReadError.invalidURL
            case .symbolicLink:
                throw BoundedFileReadError.symbolicLink
            case .unsupportedFileType:
                throw BoundedFileReadError.unsupportedFileType
            case .unreliableIdentity:
                throw BoundedFileReadError.changedDuringRead
            case .metadataUnavailable(let code):
                throw BoundedFileReadError.ioFailure(code)
            }
        }
    }

    private static func captureDescriptor(_ descriptor: Int32) throws -> BoundedDescriptorSnapshot {
        var metadata = stat()
        guard fstat(descriptor, &metadata) == 0 else {
            throw BoundedFileReadError.ioFailure(errno)
        }
        return BoundedDescriptorSnapshot(metadata)
    }

    private static func openWithoutFollowingLinks(_ url: URL) throws -> Int32 {
        let components = url.path.split(separator: "/").map(String.init)
        guard let leaf = components.last else { throw BoundedFileReadError.invalidURL }

        var parent = Darwin.open("/", O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NONBLOCK)
        guard parent >= 0 else { throw BoundedFileReadError.ioFailure(errno) }

        for component in components.dropLast() {
            let next = component.withCString {
                Darwin.openat(parent, $0, O_RDONLY | O_DIRECTORY | O_CLOEXEC | O_NOFOLLOW | O_NONBLOCK)
            }
            guard next >= 0 else {
                let code = errno
                Darwin.close(parent)
                if code == ELOOP || code == ENOTDIR { throw BoundedFileReadError.symbolicLink }
                throw BoundedFileReadError.ioFailure(code)
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
            if code == ELOOP { throw BoundedFileReadError.symbolicLink }
            throw BoundedFileReadError.ioFailure(code)
        }
        return descriptor
    }
}

private struct BoundedDescriptorSnapshot: Equatable {
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
