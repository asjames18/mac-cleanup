import Darwin
import Foundation

/// Uses error domains/codes, never localized text, to suggest a next step.
/// A permission error alone does not prove which macOS policy rejected the move.
enum CleanupFailure {
    static func describe(_ error: Error, target: URL) -> String {
        let original = error as NSError
        var current: NSError? = original
        var visited = Set<ObjectIdentifier>()
        var denied = false
        var readOnly = false
        var full = false
        var canceled = false
        for _ in 0..<8 {
            guard let value = current, visited.insert(ObjectIdentifier(value)).inserted else { break }
            if value.domain == NSPOSIXErrorDomain {
                denied = denied || value.code == Int(EACCES) || value.code == Int(EPERM)
                readOnly = readOnly || value.code == Int(EROFS)
                full = full || value.code == Int(ENOSPC)
                canceled = canceled || value.code == Int(ECANCELED)
            } else if value.domain == NSCocoaErrorDomain {
                denied = denied || value.code == CocoaError.Code.fileWriteNoPermission.rawValue || value.code == CocoaError.Code.fileReadNoPermission.rawValue
                readOnly = readOnly || value.code == CocoaError.Code.fileWriteVolumeReadOnly.rawValue
                full = full || value.code == CocoaError.Code.fileWriteOutOfSpace.rawValue
                canceled = canceled || value.code == CocoaError.Code.userCancelled.rawValue
            }
            current = value.userInfo[NSUnderlyingErrorKey] as? NSError
        }
        let guidance: String?
        if canceled {
            guidance = "The operation was canceled. Review the current locations before trying again."
        } else if readOnly {
            guidance = "This location is on a read-only volume. Check the volume in Finder; changing privacy access will not make a read-only volume writable."
        } else if full {
            guidance = "The volume has insufficient free space to finish this operation. Check its available space and review the current file locations before retrying."
        } else if denied {
            if target.pathExtension.lowercased() == "app" {
                guidance = "macOS denied access. Check MacSweep under System Settings → Privacy & Security → App Management. Also check the app and parent folder permissions in Finder. An access error does not identify the exact restriction; system and managed protections still apply."
            } else {
                guidance = "macOS denied access. Check this item and its parent folder in Finder → Get Info → Sharing & Permissions. For protected personal folders, review MacSweep under System Settings → Privacy & Security → Files and Folders or Full Disk Access, then scan again. Managed restrictions may still apply."
            }
        } else {
            guidance = nil
        }
        guard let guidance else { return error.localizedDescription }
        return "\(String(original.localizedDescription.prefix(1_000)))\n\(guidance)\nError: \(original.domain) (\(original.code))."
    }
}
