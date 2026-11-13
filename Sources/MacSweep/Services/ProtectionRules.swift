import Foundation
import Darwin

enum ProtectionRules {
    @TaskLocal static var excludedURLs: [URL] = []

    static func isExcluded(_ url: URL, exclusions: [URL]? = nil) -> Bool {
        (exclusions ?? excludedURLs).contains { contains($0, url) || contains(url, $0) }
    }

    static var historyDirectory: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/MacSweep/History")
    }

    /// Use only for known system-provided roots; never resolve selected cleanup targets.
    static func canonicalTrustedRoot(_ url: URL) -> URL {
        guard let resolved = realpath(url.path, nil) else { return url }
        defer { free(resolved) }
        return URL(fileURLWithPath: String(cString: resolved), isDirectory: true)
    }

    static func normalizedPath(_ url: URL) -> String {
        var parts: [String] = []
        for part in url.path.split(separator: "/") {
            if part == "." { continue }
            if part == ".." { if !parts.isEmpty { parts.removeLast() }; continue }
            parts.append(String(part))
        }
        return "/" + parts.joined(separator: "/")
    }

    static func contains(_ parent: URL, _ child: URL) -> Bool {
        let p = normalizedPath(parent).lowercased()
        let c = normalizedPath(child).lowercased()
        return p == c || c.hasPrefix(p == "/" ? "/" : p + "/")
    }

    static func hasSymlinkComponent(_ url: URL) -> Bool {
        var current = url
        while current.path != "/" {
            var info = stat()
            if lstat(current.path, &info) == 0 && (info.st_mode & S_IFMT) == S_IFLNK { return true }
            current.deleteLastPathComponent()
        }
        return false
    }

    /// Developer and tool folders that are never cleanup targets (ported from Mac Cleanup's PathPolicy).
    /// DerivedData stays a reviewable cleanup category in MacSweep, so it is not listed here.
    static let toolDirectoryNames: Set<String> = [
        "node_modules", "site-packages", "__pycache__", "venv", ".venv", "virtualenv", ".virtualenv", ".git",
    ]

    /// Components to check: every ancestor, plus the item itself when it is a folder.
    private static func checkedComponents(_ url: URL, isDirectory: Bool) -> ArraySlice<String> {
        let parts = normalizedPath(url).split(separator: "/").map(String.init)
        return isDirectory ? parts[...] : parts.dropLast()
    }

    static func hasDotFolder(_ url: URL, isDirectory: Bool) -> Bool {
        checkedComponents(url, isDirectory: isDirectory).contains { $0.hasPrefix(".") }
    }

    static func hasToolDirectory(_ url: URL, isDirectory: Bool) -> Bool {
        checkedComponents(url, isDirectory: isDirectory).contains { toolDirectoryNames.contains($0.lowercased()) }
    }

    /// `/` and `/Volumes/<name>` are never targets.
    static func isVolumeRoot(_ url: URL) -> Bool {
        let parts = normalizedPath(url).split(separator: "/")
        return parts.isEmpty || (parts.count == 1 && parts[0].lowercased() == "volumes")
            || (parts.count == 2 && parts[0].lowercased() == "volumes")
    }

    /// SF_DATALESS: a cloud placeholder (iCloud Drive or another File Provider) whose bytes are not on disk.
    static let datalessFlag: UInt32 = 0x4000_0000

    static func isDatalessFlags(_ flags: UInt32) -> Bool { flags & datalessFlag != 0 }

    /// Reads inode flags only, so checking never downloads the file.
    static func isDataless(_ url: URL) -> Bool {
        var info = stat()
        guard lstat(url.path, &info) == 0 else { return false }
        return isDatalessFlags(info.st_flags)
    }

    /// Mac Cleanup's stricter location blocks. Contents of an app bundle that is moved as a unit
    /// are exempt from the dot-folder and tool-folder rules (Electron apps ship node_modules).
    static func strictBlock(_ url: URL, bundleContents: Bool = false) -> String? {
        let path = URL(fileURLWithPath: url.path)
        if isVolumeRoot(path) { return "Volume roots are never cleaned." }
        if isDataless(path) { return "Cloud-only file; MacSweep never opens or moves placeholders." }
        guard !bundleContents else { return nil }
        let isDirectory = (try? path.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) ?? false
        if hasDotFolder(path, isDirectory: isDirectory) { return "Hidden dot-folders are protected." }
        if hasToolDirectory(path, isDirectory: isDirectory) { return "Developer tool folders (.git, node_modules, virtual environments) are protected." }
        return nil
    }

    static func isProtected(_ url: URL, protectRecentFiles: Bool = true, protectHistory: Bool = true, reviewedAppScope: CleanupSafety.ValidatedAppScope? = nil, bundleContents: Bool = false) -> Bool {
        if isExcluded(url) { return true }
        if protectHistory, contains(url, historyDirectory) || contains(historyDirectory, url) { return true }
        // MacSweep's own settings, backups and action log are never cleanup targets.
        let support = historyDirectory.deletingLastPathComponent()
        for own in ["settings.json", "settings.json.bak", "backups", "logs"].map({ support.appendingPathComponent($0) })
        where contains(url, own) || contains(own, url) { return true }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let path = URL(fileURLWithPath: url.path)
        // Only the validated installed bundle subtree can bypass the Applications-root rule.
        // Every other protection, including links and sensitive libraries, remains in force.
        let roots = ["/System", "/Library", "/Applications", "/bin", "/sbin", "/usr", "/private/etc", "/private/var/db"]
            .filter { $0 != "/Applications" || reviewedAppScope?.contains(url) != true }
            .map { URL(fileURLWithPath: $0) }
        let sensitive = ["Library/Mail", "Library/Messages", "Library/Containers/com.apple.mail",
                         "Library/Containers/com.apple.MobileSMS", "Library/Group Containers/group.com.apple.notes",
                         "Library/Photos/Libraries", "Library/Mobile Documents", "Library/CloudStorage"]
            .map { home.appendingPathComponent($0) }
        if contains(path, home) || roots.contains(where: { contains($0, path) || contains(path, $0) })
            || sensitive.contains(where: { contains($0, path) || contains(path, $0) }) { return true }
        if hasSymlinkComponent(path) { return true }
        if strictBlock(path, bundleContents: bundleContents || reviewedAppScope?.contains(url) == true) != nil { return true }
        let protectedExtensions = Set(["photoslibrary", "musiclibrary", "fcpbundle", "logicx"])
        if path.pathComponents.contains(where: { protectedExtensions.contains(URL(fileURLWithPath: $0).pathExtension.lowercased()) }) { return true }
        if protectRecentFiles,
           let date = try? path.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
           date > Date().addingTimeInterval(-86400) { return true }
        return false
    }

    static func note(for url: URL, category: CleanupCategory) -> String {
        category == .duplicates
            ? "All copies start unselected. One copy is protected across all cleanup categories."
            : "Review before selecting. Recent files, sensitive libraries, system locations and symbolic links are excluded."
    }
}
