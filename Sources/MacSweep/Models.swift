import Foundation
import MacSweepCore

enum MainViewMode: String, CaseIterable, Identifiable {
    case overview
    case cleanup
    case storage
    case apps
    case maintenance
    case history

    var id: String { rawValue }

    var title: String {
        switch self {
        case .overview: "Overview"
        case .cleanup: "Smart Scan"
        case .storage: "Storage"
        case .apps: "Applications"
        case .maintenance: "Maintenance"
        case .history: "History"
        }
    }

    var systemImage: String {
        switch self {
        case .overview: "square.grid.2x2"
        case .cleanup: "sparkle.magnifyingglass"
        case .storage: "internaldrive"
        case .apps: "square.stack.3d.up"
        case .maintenance: "slider.horizontal.3"
        case .history: "clock.arrow.circlepath"
        }
    }
}

enum ScanPreset: String, CaseIterable, Identifiable, Sendable {
    case quick
    case deep
    case developer
    case duplicatesOnly

    var id: String { rawValue }

    var title: String {
        switch self {
        case .quick: "Quick Scan"
        case .deep: "Deep Scan"
        case .developer: "Developer"
        case .duplicatesOnly: "Duplicates Only"
        }
    }

    var includesDownloads: Bool {
        self != .developer && self != .duplicatesOnly
    }

    var includesCaches: Bool {
        self != .duplicatesOnly
    }

    var includesLogs: Bool {
        self == .deep || self == .developer
    }

    var includesXcode: Bool {
        self == .deep || self == .developer
    }

    var includesTemporary: Bool {
        self != .duplicatesOnly
    }

    var includesLargeFiles: Bool {
        self == .deep
    }

    var includesDuplicates: Bool {
        self == .deep || self == .duplicatesOnly
    }

    var includesCustomFolders: Bool {
        self != .duplicatesOnly
    }

    /// Crash and diagnostic reports, browser caches and GPU shader caches ride along with the cache scan.
    var includesCrashReports: Bool { self != .duplicatesOnly }
    var includesBrowserCaches: Bool { includesCaches }
    var includesShaderCaches: Bool { includesCaches }

    /// Developer caches (pip, Yarn, Homebrew, CocoaPods, device support…) are opt-in, except in the Developer preset.
    func includesDeveloperCaches(optedIn: Bool) -> Bool {
        self == .developer || (optedIn && self != .duplicatesOnly)
    }

    /// Review-only locations (macOS and iPhone update files) are listed so you can see them; they are never cleaned.
    var includesReviewOnly: Bool { self == .quick || self == .deep }
}

enum CleanupCategory: String, CaseIterable, Identifiable, Sendable {
    case downloads
    case caches
    case logs
    case xcode
    case temporary
    case largeFiles
    case duplicates
    case custom
    case crashReports
    case browserCaches
    case shaderCaches
    case developerCaches
    case oldInstallers
    case systemUpdates

    var id: String { rawValue }

    /// Shown so you can review them; MacSweep never selects or moves these.
    var isReviewOnly: Bool { self == .oldInstallers || self == .systemUpdates }

    /// Caches and reports that apps or macOS rebuild. Low risk to clean.
    var isRebuildable: Bool {
        switch self {
        case .caches, .logs, .xcode, .temporary, .crashReports, .browserCaches, .shaderCaches, .developerCaches: true
        default: false
        }
    }

    var title: String {
        switch self {
        case .downloads: "Downloads"
        case .caches: "Caches"
        case .logs: "Logs"
        case .xcode: "Xcode"
        case .temporary: "Temporary"
        case .largeFiles: "Large Files"
        case .duplicates: "Duplicates"
        case .custom: "Custom"
        case .crashReports: "Crash Reports"
        case .browserCaches: "Browser Caches"
        case .shaderCaches: "GPU Shader Caches"
        case .developerCaches: "Developer Caches"
        case .oldInstallers: "Old Installers"
        case .systemUpdates: "Update Files"
        }
    }

    var systemImage: String {
        switch self {
        case .downloads: "arrow.down.circle"
        case .caches: "externaldrive"
        case .logs: "doc.text.magnifyingglass"
        case .xcode: "hammer"
        case .temporary: "clock.arrow.circlepath"
        case .largeFiles: "shippingbox"
        case .duplicates: "doc.on.doc"
        case .custom: "folder.badge.gearshape"
        case .crashReports: "exclamationmark.bubble"
        case .browserCaches: "globe"
        case .shaderCaches: "cpu"
        case .developerCaches: "shippingbox.circle"
        case .oldInstallers: "opticaldiscdrive"
        case .systemUpdates: "arrow.down.app"
        }
    }

    var detail: String {
        switch self {
        case .downloads: "Older installers, archives, disk images, and bulky downloads."
        case .caches: "User cache folders that apps can usually rebuild."
        case .logs: "App logs that have not changed in at least 30 days."
        case .xcode: "DerivedData and archives generated by Xcode builds."
        case .temporary: "Files in the current user temporary directory."
        case .largeFiles: "Large files in common media and document folders."
        case .duplicates: "Duplicate files found by matching size and SHA-256 hash."
        case .custom: "Files found in folders you choose manually."
        case .crashReports: "Crash, hang and diagnostic reports in your Library. macOS writes new ones when needed."
        case .browserCaches: "Web caches for Safari, Chrome, Firefox, Edge, Brave and Arc. Quit the browser first; it rebuilds the cache."
        case .shaderCaches: "Compiled GPU shader caches. Apps and games rebuild them, so the first launch afterwards may be slower."
        case .developerCaches: "Package and tool caches (pip, Yarn, Homebrew, CocoaPods, Swift packages, device support). Opt-in; tools download them again when needed."
        case .oldInstallers: "Disk images and installer packages in Downloads older than 30 days. Review only: MacSweep never moves these."
        case .systemUpdates: "macOS and iPhone update files. Review only: macOS manages these; use Storage settings or Finder."
        }
    }
}

struct CleanupItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let category: CleanupCategory
    let size: Int64
    let modifiedAt: Date?
    let kind: String
    let reason: String
    let safetyNote: String
    let duplicateGroupID: String?
    var isSelected: Bool

    var name: String {
        url.lastPathComponent.isEmpty ? url.path(percentEncoded: false) : url.lastPathComponent
    }

    var path: String {
        url.path(percentEncoded: false)
    }
    var snapshot: FileSnapshot? = nil
}

struct CategorySummary: Identifiable {
    let category: CleanupCategory
    let count: Int
    let size: Int64

    var id: CleanupCategory { category }
}

struct StorageItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let title: String
    let size: Int64
    let fileCount: Int
    let folderCount: Int

    var path: String {
        url.path(percentEncoded: false)
    }
}

struct InstalledApp: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let name: String
    let bundleIdentifier: String?
    let version: String?
    let size: Int64

    // Root and Info.plist evidence only; this does not snapshot all bundle descendants.
    var snapshot: FileSnapshot? = nil
    var metadataSnapshot: FileSnapshot? = nil
    var sizeIsKnown: Bool = true
    var sizeDescription: String { sizeIsKnown ? size.formattedFileSize : "Not measured" }

    var path: String {
        url.path(percentEncoded: false)
    }
}

struct AppLeftoverItem: Identifiable, Hashable, Sendable {
    let id: String
    let url: URL
    let location: String
    let size: Int64
    let reason: String
    var isSelected: Bool

    var blockedReason: String? = nil
    var sizeIsKnown: Bool = true
    var snapshot: FileSnapshot? = nil
    var unavailableReason: String? {
        blockedReason ?? (!sizeIsKnown ? "Unavailable: size measurement incomplete." : snapshot == nil ? "Unavailable: scan identity evidence is missing; scan related files again." : nil)
    }
    var canSelect: Bool { unavailableReason == nil }
    var sizeDescription: String { sizeIsKnown ? size.formattedFileSize : "Not fully measured" }

    var name: String {
        url.lastPathComponent
    }

    var path: String {
        url.path(percentEncoded: false)
    }
}

struct AppLeftoverRoot: Sendable {
    let location: String
    let url: URL
}

struct AppLeftoverUpdate: Sendable {
    let items: [AppLeftoverItem]
    let detail: String
    let examined: Int
    let elapsed: TimeInterval
}

struct AppLeftoverReport: Sendable {
    let items: [AppLeftoverItem]
    let messages: [String]
    let coverageComplete: Bool
    let cancelled: Bool
    let examined: Int
    let readErrorCount: Int
    let skippedSymlinkCount: Int
}

enum ScanStatus: Equatable {
    case idle
    case scanning(String)
    case complete
    case cleaning
}

struct ScanReport: Sendable {
    let items: [CleanupItem]
    let storageItems: [StorageItem]
    let messages: [String]
    var coverageSummary: String = ""
}
