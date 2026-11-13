import Foundation
import MacSweepCore

enum CleanerScanner {
    private static let sizeKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .fileSizeKey,
        .contentModificationDateKey,
        .localizedTypeDescriptionKey,
        .volumeIdentifierKey
    ]

    /// True when `url` sits on a different volume than the scan root. Scans never cross volumes.
    static func crossesVolume(_ values: URLResourceValues?, rootVolume: NSObject?) -> Bool {
        guard let rootVolume, let volume = values?.volumeIdentifier as? NSObject else { return false }
        return !volume.isEqual(rootVolume)
    }

    private static func volumeID(_ url: URL) -> NSObject? {
        (try? url.resourceValues(forKeys: [.volumeIdentifierKey]))?.volumeIdentifier as? NSObject
    }

    private static let storageTypeKeys: Set<URLResourceKey> = [.isDirectoryKey, .isRegularFileKey, .isSymbolicLinkKey]

    @TaskLocal private static var session: ScanSession?

    static func scan(customFolders: [URL], preset: ScanPreset, home: URL = FileManager.default.homeDirectoryForCurrentUser,
                     temporaryDirectory: URL = ProtectionRules.canonicalTrustedRoot(URL(fileURLWithPath: NSTemporaryDirectory())),
                     limit: ScanLimit? = nil, progress: @escaping @Sendable (ScanUpdate) -> Void = { _ in }) -> ScanReport {
        let session = ScanSession(limit: limit ?? (preset == .quick ? .quick : .extended), progress: progress)
        return $session.withValue(session) {
            scanCleanup(customFolders: customFolders, preset: preset, home: home, temporaryDirectory: temporaryDirectory)
        }
    }

    static func analyzeStorage(customFolders: [URL], home: URL = FileManager.default.homeDirectoryForCurrentUser,
                               limit: ScanLimit = .extended, progress: @escaping @Sendable (ScanUpdate) -> Void = { _ in }) -> ScanReport {
        let session = ScanSession(limit: limit, progress: progress)
        return $session.withValue(session) {
            var messages = ["Storage analysis: readable content, excluding hidden files and packages."]
            let storage = scanStorage(home: home, customFolders: customFolders, messages: &messages)
            messages.append(session.summary)
            return ScanReport(items: [], storageItems: storage, messages: messages, coverageSummary: session.summary)
        }
    }

    private static var stopped: Bool { Task.isCancelled || (session?.stopped ?? false) }

    private static func scanCleanup(customFolders: [URL], preset: ScanPreset, home: URL, temporaryDirectory: URL) -> ScanReport {
        var items: [CleanupItem] = []
        var messages: [String] = []

        messages.append("Running \(preset.title) across user-cleanable locations.")
        let storageItems: [StorageItem] = []
        session?.publish(items: items, stage: "Checking Downloads")

        if preset.includesDownloads && !stopped {
            scanDownloads(home: home, into: &items, messages: &messages)
        }

        session?.publish(items: items, stage: "Checking caches")
        if preset.includesCaches && !stopped {
            scanDirectoryChildren(
                home.appendingPathComponent("Library/Caches", isDirectory: true),
                category: .caches,
                minimumSize: 1_000_000,
                into: &items,
                messages: &messages
            )
        }

        session?.publish(items: items, stage: "Checking logs")
        if preset.includesLogs && !stopped {
            scanDirectoryChildren(
                home.appendingPathComponent("Library/Logs", isDirectory: true),
                category: .logs,
                minimumSize: 100_000,
                into: &items,
                messages: &messages
            )
        }

        session?.publish(items: items, stage: "Checking developer files")
        if preset.includesXcode && !stopped {
            scanDirectoryChildren(
                home.appendingPathComponent("Library/Developer/Xcode/DerivedData", isDirectory: true),
                category: .xcode,
                minimumSize: 1_000_000,
                into: &items,
                messages: &messages
            )
        }

        session?.publish(items: items, stage: "Checking temporary files")
        if preset.includesTemporary && !stopped {
            scanDirectoryChildren(
                temporaryDirectory,
                category: .temporary,
                minimumSize: 100_000,
                into: &items,
                messages: &messages
            )
        }

        session?.publish(items: items, stage: "Finding large files")
        if preset.includesLargeFiles && !stopped {
            scanLargeFiles(home: home, into: &items, messages: &messages)
        }

        session?.publish(items: items, stage: "Comparing duplicates")
        if preset.includesDuplicates && !stopped {
            scanDuplicates(home: home, customFolders: customFolders, into: &items, messages: &messages)
        }

        session?.publish(items: items, stage: "Checking added folders")
        if preset.includesCustomFolders && !stopped {
            for folder in customFolders {
                if stopped { break }
                scanDirectoryChildren(
                    folder,
                    category: .custom,
                    minimumSize: 1,
                    into: &items,
                    messages: &messages
                )
            }
        }

        session?.publish(items: items, stage: "Finishing scan")
        if let session { messages.append(session.summary) }
        let uniqueItems = Array(Dictionary(items.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
        let totalBytes = CleanupSafety.uniqueItems(uniqueItems).reduce(0) { $0 + $1.size }
        messages.append("Found \(uniqueItems.count) candidates totaling \(totalBytes.formattedFileSize).")

        return ScanReport(items: uniqueItems, storageItems: storageItems, messages: messages, coverageSummary: session?.summary ?? "")
    }

    private static func scanDownloads(home: URL, into items: inout [CleanupItem], messages: inout [String]) {
        let fileManager = FileManager.default
        let downloads = home.appendingPathComponent("Downloads", isDirectory: true)
        let extensions = Set(["dmg", "pkg", "zip", "rar", "7z", "tar", "gz", "iso", "mp4", "mov"])
        let cutoff = Calendar.current.date(byAdding: .day, value: -14, to: Date()) ?? Date()

        guard !ProtectionRules.hasSymlinkComponent(downloads), let urls = fileManager.enumerator(
            at: downloads,
            includingPropertiesForKeys: Array(sizeKeys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { url, error in
                session?.recordError(url, error: error)
                return !stopped
            }
        ) else {
            messages.append("Downloads unavailable or permission denied.")
            return
        }

        for case let url as URL in urls {
            session?.visit(url)
            if stopped { break }
            guard !ProtectionRules.isProtected(url) else { continue }
            let values = readValues(url)
            guard let size = allocatedSize(url) else { if stopped { break }; continue }
            if stopped { break }
            let modified = values?.contentModificationDate
            let isOld = modified.map { $0 < cutoff } ?? false
            let isInstallerOrArchive = extensions.contains(url.pathExtension.lowercased())

            guard size >= 10_000_000 || isInstallerOrArchive || isOld else { continue }
            let reason = isInstallerOrArchive
                ? "Installer, archive, disk image, or large media download."
                : isOld ? "Download has not been modified in at least 14 days." : "Download is larger than 10 MB."
            items.append(makeItem(url, category: .downloads, size: size, values: values, reason: reason))
        }

        messages.append(stopped ? "Downloads partially scanned." : "Downloads scan finished.")
    }

    private static func scanDirectoryChildren(
        _ folder: URL,
        category: CleanupCategory,
        minimumSize: Int64,
        into items: inout [CleanupItem],
        messages: inout [String]
    ) {
        let fileManager = FileManager.default
        guard !ProtectionRules.hasSymlinkComponent(folder), fileManager.fileExists(atPath: folder.path(percentEncoded: false)) else {
            messages.append("\(category.title) folder not found.")
            return
        }

        guard let urls = fileManager.enumerator(
            at: folder, includingPropertiesForKeys: Array(sizeKeys),
            options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants],
            errorHandler: { url, error in
                session?.recordError(url, error: error)
                return !stopped
            }
        ) else { messages.append("\(category.title) unavailable."); return }
        for case let url as URL in urls {
            session?.visit(url)
            if stopped { break }
            guard !ProtectionRules.isProtected(url) else { continue }
            let values = readValues(url)
            if values?.isSymbolicLink == true { continue }
            guard let size = allocatedSize(url) else { if stopped { break }; continue }
            if stopped { break }
            guard size >= minimumSize else { continue }
            items.append(makeItem(url, category: category, size: size, values: values, reason: category.detail))
        }
        messages.append(stopped ? "\(category.title) partially scanned." : "\(category.title) scan finished.")
    }

    private static func scanLargeFiles(home: URL, into items: inout [CleanupItem], messages: inout [String]) {
        let fileManager = FileManager.default
        let roots = [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Movies", isDirectory: true),
            home.appendingPathComponent("Pictures", isDirectory: true)
        ]
        let minimumSize: Int64 = 500_000_000

        for root in roots {
            if stopped { break }
            guard !ProtectionRules.hasSymlinkComponent(root), let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(sizeKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    session?.recordError(url, error: error)
                    return !stopped
                }
            ) else {
                continue
            }

            let rootVolume = volumeID(root)
            for case let url as URL in enumerator {
                session?.visit(url)
                if stopped { break }
                if ProtectionRules.isProtected(url) {
                    enumerator.skipDescendants()
                    continue
                }

                let values = readValues(url)
                if crossesVolume(values, rootVolume: rootVolume) {
                    enumerator.skipDescendants()
                    continue
                }
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }

                let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                guard size >= minimumSize else { continue }
                items.append(makeItem(url, category: .largeFiles, size: size, values: values, reason: "File is larger than 500 MB. Review before selecting."))
            }
        }

        messages.append(stopped ? "Large file scan stopped; partial coverage." : "Large file scan finished.")
    }

    private static func scanDuplicates(
        home: URL,
        customFolders: [URL],
        into items: inout [CleanupItem],
        messages: inout [String]
    ) {
        let initialErrors = session?.errors ?? 0
        var unavailableRoots = 0
        var hashedCount = 0
        var hashFailures = 0
        let fileManager = FileManager.default
        let roots = [
            home.appendingPathComponent("Desktop", isDirectory: true),
            home.appendingPathComponent("Documents", isDirectory: true),
            home.appendingPathComponent("Downloads", isDirectory: true),
            home.appendingPathComponent("Movies", isDirectory: true),
            home.appendingPathComponent("Pictures", isDirectory: true)
        ] + customFolders
        let minimumSize: Int64 = 1_000_000
        var bySize: [Int64: [URL]] = [:]

        for root in uniqueURLs(roots) {
            if stopped { break }
            guard !ProtectionRules.hasSymlinkComponent(root), let enumerator = fileManager.enumerator(
                at: root,
                includingPropertiesForKeys: Array(sizeKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    session?.recordError(url, error: error)
                    return !stopped
                }
            ) else {
                unavailableRoots += 1
                continue
            }

            let rootVolume = volumeID(root)
            for case let url as URL in enumerator {
                session?.visit(url)
                if stopped { break }
                if ProtectionRules.isProtected(url) {
                    enumerator.skipDescendants()
                    continue
                }

                let values = readValues(url)
                if crossesVolume(values, rootVolume: rootVolume) {
                    enumerator.skipDescendants()
                    continue
                }
                guard values?.isRegularFile == true, values?.isSymbolicLink != true else { continue }

                let size = Int64(values?.fileSize ?? 0)
                guard size >= minimumSize else { continue }
                bySize[size, default: []].append(url)
            }
        }

        var duplicateCount = 0
        for candidates in bySize.values where candidates.count > 1 {
            let sameSize = uniqueURLs(candidates)
            if stopped { break }
            var byHash: [String: [URL]] = [:]

            for url in sameSize {
                if stopped { break }
                guard let hash = sha256(url) else { hashFailures += 1; continue }
                hashedCount += 1
                byHash[hash, default: []].append(url)
            }

            for (hash, urls) in byHash where urls.count > 1 {
                if stopped { break }
                let sortedURLs = urls.sorted {
                    let leftDate = (try? $0.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    let rightDate = (try? $1.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate) ?? Date.distantPast
                    return leftDate == rightDate ? $0.path < $1.path : leftDate < rightDate
                }

                for (index, url) in sortedURLs.enumerated() {
                    if stopped { break }
                    let values = readValues(url)
                    let size = Int64(values?.totalFileAllocatedSize ?? values?.fileAllocatedSize ?? 0)
                    let reason = index == 0
                        ? "Original candidate in duplicate group. Kept unselected by default."
                        : "Duplicate file matches another file by size and SHA-256 hash."
                    items.append(makeItem(
                        url,
                        category: .duplicates,
                        size: size,
                        values: values,
                        reason: reason,
                        duplicateGroupID: hash,
                        selectedOverride: index != 0
                    ))
                    duplicateCount += 1
                }
            }
        }

        let readErrors = max(0, (session?.errors ?? 0) - initialErrors)
        let partial = stopped || readErrors > 0 || hashFailures > 0 || unavailableRoots > 0
        messages.append("Duplicate scan \(partial ? "has partial coverage" : "finished eligible files"): \(duplicateCount) matching files found; \(hashedCount) files hashed; \(hashFailures) hash attempts incomplete; \(readErrors) read errors; \(unavailableRoots) roots unavailable or excluded. Files below 1 MB, hidden files, package contents and protected paths are excluded. Only files sharing a logical size are hashed.")
    }

    private static func scanStorage(home: URL, customFolders: [URL], messages: inout [String]) -> [StorageItem] {
        let roots = [
            labeledURL("Desktop", home.appendingPathComponent("Desktop", isDirectory: true)),
            labeledURL("Documents", home.appendingPathComponent("Documents", isDirectory: true)),
            labeledURL("Downloads", home.appendingPathComponent("Downloads", isDirectory: true)),
            labeledURL("Movies", home.appendingPathComponent("Movies", isDirectory: true)),
            labeledURL("Music", home.appendingPathComponent("Music", isDirectory: true)),
            labeledURL("Pictures", home.appendingPathComponent("Pictures", isDirectory: true)),
            labeledURL("Application Support", home.appendingPathComponent("Library/Application Support", isDirectory: true)),
            labeledURL("Developer", home.appendingPathComponent("Library/Developer", isDirectory: true)),
            labeledURL("Caches", home.appendingPathComponent("Library/Caches", isDirectory: true))
        ] + customFolders.map { labeledURL($0.lastPathComponent, $0) }

        var completed: [StorageItem] = []
        let items = uniqueLabeledURLs(roots).compactMap { title, url -> StorageItem? in
            guard !stopped else { return nil }
            guard !ProtectionRules.isProtected(url, protectRecentFiles: false, protectHistory: false) else {
                messages.append("Storage root excluded by policy: \(url.path)")
                return nil
            }
            guard readValues(url, keys: storageTypeKeys) != nil else {
                messages.append("Storage root unavailable: \(url.path). Check whether it exists and whether MacSweep can access it.")
                return nil
            }

            session?.publish(storage: completed, stage: "Measuring \(title)")
            let errorsBefore = session?.errors ?? 0
            let usage = storageUsage(url)
            guard usage.files > 0 || usage.folders > 0 || (session?.errors ?? 0) > errorsBefore else { return nil }

            let item = StorageItem(
                id: url.standardizedFileURL.path(percentEncoded: false),
                url: url,
                title: (title.isEmpty ? url.lastPathComponent : title) + (stopped || (session?.errors ?? 0) != errorsBefore ? " (partial)" : ""),
                size: usage.size,
                fileCount: usage.files,
                folderCount: usage.folders
            )
            completed.append(item)
            session?.publish(storage: completed, stage: "Measured \(title)")
            return item
        }

        messages.append(stopped ? "Storage analysis stopped; displayed sizes are partial readable usage." : (session?.errors ?? 0) > 0 ? "Storage analysis finished with partial coverage; some roots or files were unavailable. See the listed paths and read errors." : "Storage analysis finished for accessible roots.")
        return items
    }

    private static func readValues(_ url: URL, keys: Set<URLResourceKey> = sizeKeys) -> URLResourceValues? {
        do { return try url.resourceValues(forKeys: keys) }
        catch { session?.recordError(url, error: error); return nil }
    }

    private static func allocatedSize(_ url: URL) -> Int64? {
        let fileManager = FileManager.default
        guard !ProtectionRules.hasSymlinkComponent(url), let values = readValues(url) else { return nil }

        if values.isRegularFile == true {
            return Int64(values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? 0)
        }

        if values.isDirectory == true {
            var total: Int64 = 0
            let errorsBefore = session?.errors ?? 0
            guard let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(sizeKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    session?.recordError(url, error: error)
                    return !stopped
                }
            ) else {
                return nil
            }

            for case let child as URL in enumerator {
                session?.visit(child)
                if stopped { break }
                let childValues = readValues(child)
                guard childValues?.isRegularFile == true, childValues?.isSymbolicLink != true else { continue }
                total += Int64(childValues?.totalFileAllocatedSize ?? childValues?.fileAllocatedSize ?? 0)
            }
            return stopped || (session?.errors ?? 0) != errorsBefore ? nil : total
        }

        return nil
    }

    private static func storageUsage(_ url: URL) -> (size: Int64, files: Int, folders: Int) {
        let fileManager = FileManager.default
        guard let values = readValues(url, keys: storageTypeKeys) else { return (0, 0, 0) }

        if values.isRegularFile == true {
            do { return (try StorageDirectoryReader.fileEntry(url).allocatedBytes, 1, 0) }
            catch { session?.recordError(url, error: error); return (0, 0, 0) }
        }

        guard values.isDirectory == true,
              let enumerator = fileManager.enumerator(
                at: url,
                includingPropertiesForKeys: Array(storageTypeKeys),
                options: [.skipsHiddenFiles, .skipsPackageDescendants],
                errorHandler: { url, error in
                    session?.recordError(url, error: error)
                    return !stopped
                }
              ) else {
            return (0, 0, 0)
        }

        var size: Int64 = 0
        var files = 0
        var folders = 1
        var seenFiles = Set<StorageObjectID>()

        for case let child as URL in enumerator {
                session?.visit(child)
                if stopped { break }
            if ProtectionRules.isProtected(child, protectRecentFiles: false, protectHistory: false) {
                enumerator.skipDescendants()
                continue
            }

            let childValues = readValues(child, keys: storageTypeKeys)
            if childValues?.isSymbolicLink == true { continue }

            if childValues?.isDirectory == true {
                folders += 1
            } else if childValues?.isRegularFile == true {
                do {
                    let entry = try StorageDirectoryReader.fileEntry(child)
                    guard let identity = entry.identity else { throw CocoaError(.fileReadUnknown) }
                    guard seenFiles.insert(identity).inserted else { continue }
                    let sum = size.addingReportingOverflow(entry.allocatedBytes)
                    guard !sum.overflow else { throw CocoaError(.fileReadTooLarge) }
                    files += 1; size = sum.partialValue
                } catch { session?.recordError(child, error: error) }
            }
        }

        return (size, files, folders)
    }

    private static func makeItem(
        _ url: URL,
        category: CleanupCategory,
        size: Int64,
        values: URLResourceValues?,
        reason: String,
        duplicateGroupID: String? = nil,
        selectedOverride: Bool? = nil
    ) -> CleanupItem {
        let path = url.standardizedFileURL.path(percentEncoded: false)
        let kind = values?.localizedTypeDescription ?? (values?.isDirectory == true ? "Folder" : "File")

        let item = CleanupItem(
            id: "\(category.rawValue):\(path)",
            url: url,
            category: category,
            size: size,
            modifiedAt: values?.contentModificationDate,
            kind: kind,
            reason: reason,
            safetyNote: ProtectionRules.note(for: url, category: category),
            duplicateGroupID: duplicateGroupID,
            isSelected: false,
            snapshot: try? FileSnapshotReader.capture(url)
        )
        session?.found(item)
        return item
    }

    private static func uniqueURLs(_ urls: [URL]) -> [URL] {
        var seen: Set<String> = []
        return urls.filter { url in
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    private static func labeledURL(_ title: String, _ url: URL) -> (String, URL) {
        (title, url)
    }

    private static func uniqueLabeledURLs(_ urls: [(String, URL)]) -> [(String, URL)] {
        var seen: Set<String> = []
        return urls.filter { _, url in
            let path = url.standardizedFileURL.path(percentEncoded: false)
            guard !seen.contains(path) else { return false }
            seen.insert(path)
            return true
        }
    }

    static func sha256(_ url: URL) -> String? {
        do {
            return try StableFileHasher.sha256(url, isCancelled: { stopped })
        } catch StableFileHashError.cancelled {
            return nil
        } catch {
            session?.recordError(url, error: error)
            return nil
        }
    }
}
