import Darwin
import Foundation

struct FolderAccessResult: Identifiable, Sendable, Equatable {
    enum Status: Sendable, Equatable {
        case readable, denied, missing, unsupportedPath, failed(Int32)
        var label: String {
            switch self {
            case .readable: "Can list this folder"
            case .denied: "Access denied"
            case .missing: "Folder not found"
            case .unsupportedPath: "Not a direct folder path"
            case .failed(let code): "Check failed (system error \(code))"
            }
        }
    }
    let url: URL
    let status: Status
    var id: String { url.path }
}

/// Tests only folder listing access. Does not read file contents, infer TCC grants,
/// check write access, follow links or claim access to descendants.
enum FolderAccessChecker {
    static func check(_ url: URL) -> FolderAccessResult {
        func result(_ status: FolderAccessResult.Status) -> FolderAccessResult { .init(url: url, status: status) }
        func failure(_ code: Int32) -> FolderAccessResult {
            switch code {
            case EACCES, EPERM: result(.denied)
            case ENOENT: result(.missing)
            case ELOOP, ENOTDIR: result(.unsupportedPath)
            default: result(.failed(code))
            }
        }
        guard url.isFileURL, url.host == nil || url.host == "" || url.host == "localhost",
              !url.path.utf8.contains(0), url.path.hasPrefix("/"),
              !url.path.split(separator: "/").contains(where: { $0 == "." || $0 == ".." }) else {
            return result(.unsupportedPath)
        }
        var descriptor = open("/", O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
        guard descriptor >= 0 else { return failure(errno) }
        for component in url.path.split(separator: "/") {
            if Task.isCancelled { close(descriptor); return result(.failed(ECANCELED)) }
            let next = openat(descriptor, String(component), O_RDONLY | O_DIRECTORY | O_NOFOLLOW | O_CLOEXEC)
            let code = errno
            close(descriptor)
            guard next >= 0 else { return failure(code) }
            descriptor = next
        }
        guard let directory = fdopendir(descriptor) else {
            let code = errno; close(descriptor); return failure(code)
        }
        defer { closedir(directory) }
        errno = 0
        _ = readdir(directory)
        let code = errno
        return code == 0 ? result(.readable) : failure(code)
    }
}
