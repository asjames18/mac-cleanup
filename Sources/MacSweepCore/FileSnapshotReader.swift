import Darwin
import Foundation

public enum FileSnapshotError: Error, Equatable, Sendable {
    case invalidURL
    case symbolicLink
    case unsupportedFileType
    case unreliableIdentity
    case metadataUnavailable(Int32)
}

/// Reads metadata only. Callers must separately enforce allowed scopes and protection rules.
/// This check and a later Trash operation are not atomic; this is not a TOCTOU defense.
public enum FileSnapshotReader {
    public static func capture(_ url: URL) throws -> FileSnapshot {
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost" else {
            throw FileSnapshotError.invalidURL
        }
        let path = url.path
        guard path.hasPrefix("/"), !path.utf8.contains(0) else {
            throw FileSnapshotError.invalidURL
        }
        let components = path.split(separator: "/")
        // Do not standardize first: doing so could erase a symlink/.. component.
        guard !components.contains("..") else { throw FileSnapshotError.invalidURL }
        var prefix = ""
        var metadata = try readMetadata("/")
        for (index, component) in components.enumerated() {
            prefix += "/" + component
            metadata = try readMetadata(prefix)
            let kind = metadata.st_mode & mode_t(S_IFMT)
            guard kind != mode_t(S_IFLNK) else { throw FileSnapshotError.symbolicLink }
            if index < components.count - 1 {
                guard kind == mode_t(S_IFDIR) else { throw FileSnapshotError.unsupportedFileType }
            }
        }
        let kind = metadata.st_mode & mode_t(S_IFMT)
        guard kind == mode_t(S_IFREG) || kind == mode_t(S_IFDIR) else {
            throw FileSnapshotError.unsupportedFileType
        }
        guard metadata.st_ino != 0 else { throw FileSnapshotError.unreliableIdentity }
        return FileSnapshot(
            identity: FileIdentity(volumeKey: String(metadata.st_dev), resourceKey: String(metadata.st_ino)),
            logicalBytes: Int64(metadata.st_size),
            modifiedAt: date(metadata.st_mtimespec),
            contentDigest: nil,
            changedAt: date(metadata.st_ctimespec)
        )
    }

    public static func validate(expected: FileSnapshot, at url: URL) -> TargetValidation {
        TrashPlanValidator.validate(expected: expected, current: try? capture(url))
    }

    private static func readMetadata(_ path: String) throws -> stat {
        var metadata = stat()
        let result = path.withCString { lstat($0, &metadata) }
        guard result == 0 else { throw FileSnapshotError.metadataUnavailable(errno) }
        return metadata
    }

    private static func date(_ time: timespec) -> Date {
        Date(timeIntervalSince1970: Double(time.tv_sec) + Double(time.tv_nsec) / 1_000_000_000)
    }
}
