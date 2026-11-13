import Foundation
import Darwin
import MacSweepCore

enum CleanupSafety {
    static var defaultJournal: CleanupJournal {
        CleanupJournal(directory: ProtectionRules.historyDirectory)
    }

    enum Rejection: LocalizedError {
        case protected, missing, duplicateChanged, unsafeApp, changedSinceScan
        case unavailable(String)
        var errorDescription: String? {
            switch self {
            case .unavailable(let reason): reason
            case .changedSinceScan: "The target changed or cannot be verified against the scan; scan again."
            case .protected: "Protected location or symbolic link."
            case .missing: "The target is no longer available."
            case .duplicateChanged: "The retained duplicate is missing or has changed; scan again."
            case .unsafeApp: "System apps, running apps and MacSweep cannot be uninstalled."
            }
        }
    }

    struct TrashResult: Sendable {
        var moved: [URL] = []
        var messages: [String] = []
    }

    /// The intent must be durable before invoking the filesystem mutation.
    /// A failed outcome write preserves a pending entry; never retry that move automatically.
    static func moveWithJournal(_ url: URL, journal: CleanupJournal = defaultJournal,
                                mover: (URL) throws -> URL? = finderTrash) -> TrashResult {
        moveWithJournal(url, journal: journal, revalidate: nil, mover: mover)
    }

    // Keep the original overload so Swift's forward trailing-closure matching
    // continues to bind existing call sites to mover, never to revalidate.
    static func moveWithJournal(_ url: URL, journal: CleanupJournal = defaultJournal,
                                revalidate: (() throws -> Void)?,
                                mover: (URL) throws -> URL? = { source in
                                    var destination: NSURL?
                                    try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
                                    return destination as URL?
                                }) -> TrashResult {
        guard !ProtectionRules.isExcluded(url) else {
            return TrashResult(messages: ["Skipped \(url.path): protected by your exclusions."])
        }
        if let refusal = TestSandbox.refusal(for: url) {
            return TrashResult(messages: ["Skipped \(url.path): \(refusal)"])
        }
        guard !ProtectionRules.contains(url, journal.storageDirectory),
              !ProtectionRules.contains(journal.storageDirectory, url) else {
            return TrashResult(messages: ["Skipped \(url.path): cleanup history and its containing folders are protected."])
        }
        let id: UUID
        do { id = try journal.recordIntent(source: url) }
        catch { return TrashResult(messages: ["Skipped \(url.path): could not save cleanup history (\(error.localizedDescription))."]) }
        let destination: URL?
        var moverStarted = false
        do {
            // Journal enumeration and fsync can take time. Recheck frozen evidence
            // after durable intent, immediately before the mover. The final check
            // and Finder Trash remain non-atomic; this narrows, not closes, that gap.
            guard !ProtectionRules.isExcluded(url) else { throw Rejection.unavailable("Protected by your exclusions.") }
            if let refusal = TestSandbox.refusal(for: url) { throw Rejection.unavailable(refusal) }
            try revalidate?()
            moverStarted = true
            destination = try mover(url)
        }
        catch {
            let reason = CleanupFailure.describe(error, target: url)
            var messages = [moverStarted
                ? "Outcome unknown for \(url.path): \(reason)\nInspect the original location and Trash in Finder. Do not retry this operation."
                : "Skipped \(url.path): \(reason)"]
            do {
                if moverStarted { try journal.recordUncertainOutcome(id: id, error: String(reason.prefix(2_000))) }
                else { try journal.recordOutcome(id: id, destination: nil, failure: String(reason.prefix(2_000))) }
            }
            catch { messages.append("History update failed; check the pending record before retrying: \(error.localizedDescription)") }
            return TrashResult(messages: messages)
        }
        var result = TrashResult(moved: [url], messages: ["Moved: \(url.path)"])
        do { try journal.recordOutcome(id: id, destination: destination, failure: nil) }
        catch { result.messages.append("The file was moved, but history remains pending: \(error.localizedDescription)") }
        return result
    }

    /// Moves only what the user approved in the confirm sheet. The grant is single use.
    static func trash(_ grant: ConfirmationGrant, allItems: [CleanupItem] = [], protectRecentFiles: Bool = true, runningURLs: [URL] = [], selfURL: URL = Bundle.main.bundleURL) -> TrashResult {
        trashApproved(grant.urls, allItems: allItems, protectRecentFiles: protectRecentFiles, runningURLs: runningURLs, selfURL: selfURL)
    }

    static let lastCopyMessage = "This would remove every copy in its duplicate group. Keep at least one copy."

    /// Normalized target paths that, together, would remove every member of a duplicate group.
    static func lastCopyTargets(_ targets: [URL], allItems: [CleanupItem]) -> Set<String> {
        var blocked = Set<String>()
        let groups = Dictionary(grouping: allItems.filter { $0.duplicateGroupID != nil }, by: { $0.duplicateGroupID! })
        for members in groups.values where members.count > 1 {
            var covering = Set<String>()
            let allRemoved = members.allSatisfy { member in
                guard let target = targets.first(where: { ProtectionRules.contains($0, member.url) }) else { return false }
                covering.insert(ProtectionRules.normalizedPath(target).lowercased())
                return true
            }
            if allRemoved { blocked.formUnion(covering) }
        }
        return blocked
    }

    private static func trashApproved(_ urls: [URL], allItems: [CleanupItem], protectRecentFiles: Bool, runningURLs: [URL], selfURL: URL) -> TrashResult {
        var result = TrashResult()
        let unique = uniqueURLs(urls)
        let lastCopy = lastCopyTargets(unique, allItems: allItems)
        for url in unique {
            if lastCopy.contains(ProtectionRules.normalizedPath(url).lowercased()) {
                result.messages.append("Skipped \(url.path): \(lastCopyMessage)")
                continue
            }
            do {
                try validate(url, protectRecentFiles: protectRecentFiles, runningURLs: runningURLs, selfURL: selfURL)
                try validateDuplicates(target: url, allItems: allItems)
                if !allItems.isEmpty { try validateSnapshot(url, allItems: allItems) }
                let outcome = moveWithJournal(url, revalidate: {
                    if Task.isCancelled { throw CancellationError() }
                    if !allItems.isEmpty { try validateSnapshot(url, allItems: allItems) }
                })
                result.moved.append(contentsOf: outcome.moved)
                result.messages.append(contentsOf: outcome.messages)
            } catch { result.messages.append("Skipped \(url.path): \(error.localizedDescription)") }
        }
        return result
    }

    static func validateSnapshot(_ url: URL, allItems: [CleanupItem]) throws {
        guard let item = allItems.first(where: { ProtectionRules.normalizedPath($0.url) == ProtectionRules.normalizedPath(url) }),
              let expected = item.snapshot,
              FileSnapshotReader.validate(expected: expected, at: url) == .unchanged else {
            throw Rejection.changedSinceScan
        }
    }

    struct AppRemovalPlan: Sendable {
        let app: InstalledApp
        let support: [AppLeftoverItem]
    }

    static func validateSupport(_ item: AppLeftoverItem, runningURLs: [URL], selfURL: URL) throws {
        guard item.canSelect, let expected = item.snapshot,
              FileSnapshotReader.validate(expected: expected, at: item.url) == .unchanged else { throw Rejection.changedSinceScan }
        try validate(item.url, protectRecentFiles: false, runningURLs: runningURLs, selfURL: selfURL)
        guard FileSnapshotReader.validate(expected: expected, at: item.url) == .unchanged else { throw Rejection.changedSinceScan }
    }

    static func preflight(_ plan: AppRemovalPlan, runningURLs: [URL], selfURL: URL, allowedRoots: [URL]? = nil) throws {
        try validateApp(plan.app, runningURLs: runningURLs, selfURL: selfURL, allowedRoots: allowedRoots)
        for item in plan.support { try validateSupport(item, runningURLs: runningURLs, selfURL: selfURL) }
    }

    static func trashSupport(_ items: [AppLeftoverItem], runningURLs: [URL], selfURL: URL,
                             journal: CleanupJournal = defaultJournal,
                             mover: (URL) throws -> URL? = finderTrash) -> TrashResult {
        var result = TrashResult()
        let paths = Set(uniqueURLs(items.map(\.url)).map(\.path))
        for item in items where paths.contains(item.url.path) {
            do {
                try validateSupport(item, runningURLs: runningURLs, selfURL: selfURL)
                let outcome = moveWithJournal(item.url, journal: journal, revalidate: {
                    if Task.isCancelled { throw CancellationError() }
                    guard item.canSelect, let expected = item.snapshot,
                          FileSnapshotReader.validate(expected: expected, at: item.url) == .unchanged else {
                        throw Rejection.changedSinceScan
                    }
                }, mover: mover)
                result.moved += outcome.moved; result.messages += outcome.messages
            } catch { result.messages.append("Needs rescan / unavailable: \(item.path): \(error.localizedDescription)") }
        }
        return result
    }

    static func finderTrash(_ source: URL) throws -> URL? {
        var destination: NSURL?
        try FileManager.default.trashItem(at: source, resultingItemURL: &destination)
        return destination as URL?
    }

    static func uninstall(_ plan: AppRemovalPlan, runningURLs: [URL], selfURL: URL,
                          allowedRoots: [URL]? = nil, journal: CleanupJournal = defaultJournal,
                          mover: (URL) throws -> URL? = finderTrash) -> TrashResult {
        do {
            try preflight(plan, runningURLs: runningURLs, selfURL: selfURL, allowedRoots: allowedRoots)
            // Repeat against the frozen scan evidence immediately before recording intent.
            try validateApp(plan.app, runningURLs: runningURLs, selfURL: selfURL, allowedRoots: allowedRoots)
            var result = moveWithJournal(plan.app.url, journal: journal, revalidate: {
                if Task.isCancelled { throw CancellationError() }
                guard let expected = plan.app.snapshot, let metadata = plan.app.metadataSnapshot,
                      FileSnapshotReader.validate(expected: expected, at: plan.app.url) == .unchanged,
                      FileSnapshotReader.validate(expected: metadata, at: plan.app.url.appendingPathComponent("Contents/Info.plist")) == .unchanged else {
                    throw Rejection.changedSinceScan
                }
            }, mover: mover)
            guard !result.moved.isEmpty else { return result }
            let supportResult = trashSupport(plan.support, runningURLs: runningURLs, selfURL: selfURL, journal: journal, mover: mover)
            result.moved += supportResult.moved; result.messages += supportResult.messages
            return result
        } catch { return TrashResult(messages: ["Needs rescan / unavailable: \(error.localizedDescription)"]) }
    }

    static func uniqueURLs(_ urls: [URL]) -> [URL] {
        let entries: [(url: URL, path: String)] = urls.map {
            (url: $0, path: ProtectionRules.normalizedPath($0).lowercased())
        }
        let sorted = entries.sorted { left, right in
            if left.path.count == right.path.count { return left.path < right.path }
            return left.path.count < right.path.count
        }
        var accepted = Set<String>()
        var result: [URL] = []
        for entry in sorted {
            if accepted.contains("/") { continue }
            var prefix = ""
            var covered = false
            for component in entry.path.split(separator: "/") {
                prefix += "/" + component
                if accepted.contains(prefix) { covered = true; break }
            }
            if !covered, accepted.insert(entry.path).inserted { result.append(entry.url) }
        }
        return result
    }

    static func uniqueItems(_ items: [CleanupItem]) -> [CleanupItem] {
        let paths = Set(uniqueURLs(items.map(\.url)).map { ProtectionRules.normalizedPath($0) })
        var seen = Set<String>()
        return items.filter { paths.contains(ProtectionRules.normalizedPath($0.url)) && seen.insert(ProtectionRules.normalizedPath($0.url)).inserted }
    }

    static func retainedCopies(_ items: [CleanupItem]) -> [CleanupItem] {
        Dictionary(grouping: items.filter { $0.duplicateGroupID != nil }, by: { $0.duplicateGroupID! }).values.compactMap {
            $0.sorted {
                if $0.modifiedAt != $1.modifiedAt { return ($0.modifiedAt ?? .distantPast) < ($1.modifiedAt ?? .distantPast) }
                return $0.path < $1.path
            }.first
        }
    }

    static func selection(_ items: [CleanupItem]) -> [CleanupItem] {
        let retained = retainedCopies(items)
        return uniqueItems(items.filter { item in
            item.isSelected && !retained.contains { ProtectionRules.contains(item.url, $0.url) }
        })
    }

    struct ValidatedAppScope {
        let url: URL
        fileprivate init(_ app: InstalledApp) { url = app.url }
        func contains(_ candidate: URL) -> Bool {
            let root = url.standardizedFileURL.path
            let path = candidate.standardizedFileURL.path
            return path == root || path.hasPrefix(root + "/")
        }
    }

    /// Read-only revalidation. Tests never invoke Finder Trash.
    static func validate(_ url: URL, protectRecentFiles: Bool = true, runningURLs: [URL] = [], selfURL: URL = Bundle.main.bundleURL, limit: ScanLimit = .quick) throws {
        try validateStructure(url, protectRecentFiles: protectRecentFiles, runningURLs: runningURLs, selfURL: selfURL, limit: limit)
    }

    private static func validateStructure(_ url: URL, protectRecentFiles: Bool, runningURLs: [URL], selfURL: URL,
                                          limit: ScanLimit, appScope: ValidatedAppScope? = nil) throws {
        if Task.isCancelled { throw CancellationError() }
        if ProtectionRules.isExcluded(url) { throw Rejection.unavailable("Protected by your exclusions.") }
        let started = ProcessInfo.processInfo.systemUptime
        var examined = 0
        if let reason = AppScanner.leftoverRestriction(url) { throw Rejection.unavailable(reason) }
        guard FileManager.default.fileExists(atPath: url.path) else { throw Rejection.missing }
        guard !ProtectionRules.isProtected(url, protectRecentFiles: protectRecentFiles, reviewedAppScope: appScope) else { throw Rejection.protected }
        // Catch a sensitive library or symlink newly moved inside a selected folder.
        let rootSnapshot = try FileSnapshotReader.capture(url)
        let freshURL = URL(fileURLWithPath: url.path)
        guard let values = try? freshURL.resourceValues(forKeys: [.isDirectoryKey, .isRegularFileKey]) else { throw Rejection.missing }
        guard values.isDirectory == true else {
            guard values.isRegularFile == true else { throw Rejection.protected }
            return
        }
        let infoURL = url.appendingPathComponent("Contents/Info.plist")
        let appID = (try? BoundedFileReader.read(infoURL)).flatMap { try? PropertyListSerialization.propertyList(from: $0, format: nil) as? [String: Any] }?["CFBundleIdentifier"] as? String
        let isAppBundle = url.pathExtension.lowercased() == "app"
            && !ProtectionRules.hasSymlinkComponent(infoURL)
            && appID != nil
        if isAppBundle {
            guard !(appID?.hasPrefix("com.apple.") ?? false),
                  !ProtectionRules.contains(url, selfURL),
                  !runningURLs.contains(where: { ProtectionRules.contains(url, $0) }) else { throw Rejection.unsafeApp }
        }
        var unreadable = false
        if let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.isSymbolicLinkKey], options: [], errorHandler: { _, _ in unreadable = true; return false }) {
            for case let child as URL in e {
                if Task.isCancelled { throw CancellationError() }
                examined += 1
                guard examined <= limit.entries, ProcessInfo.processInfo.systemUptime - started < limit.seconds else { throw Rejection.unavailable("This item exceeds the bounded structural review limit; removal is unavailable.") }
                let childValues = try child.resourceValues(forKeys: [.isSymbolicLinkKey, .isRegularFileKey, .isDirectoryKey])
                if isAppBundle, childValues.isSymbolicLink == true {
                    // Move the bundle as a unit; never traverse a framework alias.
                    // Use case-sensitive containment here to avoid admitting a sibling
                    // on a case-sensitive volume. Missing/outward links stay rejected.
                    guard let resolved = realpath(child.path, nil) else { throw Rejection.protected }
                    let resolvedPath = String(cString: resolved)
                    free(resolved)
                    let rootPath = ProtectionRules.normalizedPath(url)
                    guard resolvedPath.hasPrefix(rootPath + "/"),
                          (try? FileSnapshotReader.capture(URL(fileURLWithPath: resolvedPath)).identity.volumeKey) == rootSnapshot.identity.volumeKey else { throw Rejection.protected }
                    e.skipDescendants()
                    continue
                }
                guard childValues.isDirectory == true || childValues.isRegularFile == true,
                      try FileSnapshotReader.capture(child).identity.volumeKey == rootSnapshot.identity.volumeKey else { throw Rejection.protected }
                guard !ProtectionRules.isProtected(child, protectRecentFiles: protectRecentFiles, reviewedAppScope: appScope, bundleContents: isAppBundle) else { throw Rejection.protected }
            }
        } else {
            throw Rejection.protected
        }
        if unreadable { throw Rejection.protected }
    }

    static func validateDuplicates(target: URL, allItems: [CleanupItem]) throws {
        for retained in retainedCopies(allItems) {
            let group = allItems.filter { $0.duplicateGroupID == retained.duplicateGroupID }
            let removedMembers = group.filter { ProtectionRules.contains(target, $0.url) }
            guard !removedMembers.isEmpty else { continue }
            guard !ProtectionRules.contains(target, retained.url), !ProtectionRules.hasSymlinkComponent(retained.url),
                  CleanerScanner.sha256(retained.url) == retained.duplicateGroupID else { throw Rejection.duplicateChanged }
            for member in removedMembers {
                guard !ProtectionRules.hasSymlinkComponent(member.url), CleanerScanner.sha256(member.url) == retained.duplicateGroupID else { throw Rejection.duplicateChanged }
            }
        }
    }

    static func validateApp(_ app: InstalledApp, runningURLs: [URL], selfURL: URL, allowedRoots: [URL]? = nil) throws {
        if let reason = appRemovalRestriction(app, runningURLs: runningURLs, selfURL: selfURL, allowedRoots: allowedRoots) { throw Rejection.unavailable(reason) }
        guard let expected = app.snapshot, let metadata = app.metadataSnapshot else { throw Rejection.changedSinceScan }
        let plist = app.url.appendingPathComponent("Contents/Info.plist")
        guard FileSnapshotReader.validate(expected: expected, at: app.url) == .unchanged,
              FileSnapshotReader.validate(expected: metadata, at: plist) == .unchanged else { throw Rejection.changedSinceScan }
        let data = try BoundedFileReader.read(plist)
        let info = try PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any]
        guard info?["CFBundleIdentifier"] as? String == app.bundleIdentifier else { throw Rejection.changedSinceScan }
        try validateStructure(app.url, protectRecentFiles: false, runningURLs: runningURLs, selfURL: selfURL, limit: .extended, appScope: ValidatedAppScope(app))
        guard FileSnapshotReader.validate(expected: expected, at: app.url) == .unchanged,
              FileSnapshotReader.validate(expected: metadata, at: plist) == .unchanged else { throw Rejection.changedSinceScan }
    }

    /// Metadata-only eligibility used by the view. Structural checks run in background preflight.
    static func appRemovalRestriction(_ app: InstalledApp, runningURLs: [URL] = [], selfURL: URL = Bundle.main.bundleURL, allowedRoots: [URL]? = nil) -> String? {
        if ProtectionRules.isExcluded(app.url) { return "Unavailable: protected by your exclusions." }
        guard let id = app.bundleIdentifier, !id.isEmpty, app.snapshot != nil, app.metadataSnapshot != nil else {
            return "Unavailable: scan identity evidence is missing; scan applications again."
        }
        let allowed = allowedRoots ?? [URL(fileURLWithPath: "/Applications"), FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Applications")]
        let path = app.url.standardizedFileURL.path
        guard app.url.pathExtension.lowercased() == "app", allowed.contains(where: { path.hasPrefix($0.standardizedFileURL.path + "/") }) else {
            return "Unavailable: outside supported Applications folders."
        }
        guard !id.hasPrefix("com.apple."), !ProtectionRules.contains(app.url, selfURL),
              !runningURLs.contains(where: { ProtectionRules.contains(app.url, $0) }) else {
            return "Unavailable: Apple, running and MacSweep applications are protected."
        }
        return nil
    }
}
