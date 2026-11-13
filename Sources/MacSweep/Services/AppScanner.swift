import Foundation
import CryptoKit
import Darwin
import MacSweepCore

struct AppInventoryReport: Sendable {
    let apps: [InstalledApp]
    let messages: [String]
}

struct AppInventoryUpdate: Sendable {
    let apps: [InstalledApp]
    let detail: String
}

enum AppScanner {
    private static let resourceKeys: Set<URLResourceKey> = [
        .isDirectoryKey,
        .isRegularFileKey,
        .isSymbolicLinkKey,
        .totalFileAllocatedSizeKey,
        .fileAllocatedSizeKey,
        .localizedTypeDescriptionKey
    ]

    /// Inventory only reads bundle metadata. Recursive sizing belongs to a separate operation.
    static func inventory(roots: [URL]? = nil, limit: ScanLimit = .quick,
                          progress: @escaping @Sendable (AppInventoryUpdate) -> Void = { _ in }) -> AppInventoryReport {
        let fileManager = FileManager.default
        let roots = roots ?? [
            URL(fileURLWithPath: "/Applications", isDirectory: true),
            fileManager.homeDirectoryForCurrentUser.appendingPathComponent("Applications", isDirectory: true),
            URL(fileURLWithPath: "/System/Applications", isDirectory: true)
        ]
        let keys: Set<URLResourceKey> = [.isDirectoryKey, .isSymbolicLinkKey, .isPackageKey]
        let started = ProcessInfo.processInfo.systemUptime
        var apps: [InstalledApp] = []
        var messages: [String] = []
        var visited: Set<String> = []
        var queue = roots.map { (url: $0, depth: 0) }
        var next = 0
        var examined = 0
        var readErrors = 0
        var depthLimited = 0
        var skippedLinks = 0
        var skippedPackages = 0
        var stopped = false
        func shouldStop() -> Bool {
            Task.isCancelled || examined >= limit.entries || ProcessInfo.processInfo.systemUptime - started >= limit.seconds
        }
        func recordError(_ url: URL, _ error: Error) {
            readErrors += 1
            if readErrors <= 20 { messages.append("Could not read \(url.path): \(error.localizedDescription)") }
        }
        progress(AppInventoryUpdate(apps: [], detail: "Reading installed application metadata"))
        while next < queue.count {
            if shouldStop() { stopped = true; break }
            let (directory, depth) = queue[next]
            next += 1
            guard visited.insert(directory.standardizedFileURL.path).inserted else { continue }
            guard !ProtectionRules.hasSymlinkComponent(directory) else { skippedLinks += 1; continue }
            do {
                let directoryValues = try directory.resourceValues(forKeys: keys)
                if directoryValues.isPackage == true || directory.pathExtension.lowercased() == "app" {
                    skippedPackages += 1
                    continue
                }
                let attributes = try fileManager.attributesOfItem(atPath: directory.path)
                guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                    throw CocoaError(.fileReadUnsupportedScheme)
                }
                // Checking mode bits also makes coverage explicit when running with elevated privileges.
                if let mode = attributes[.posixPermissions] as? NSNumber,
                   mode.intValue & 0o444 == 0 || mode.intValue & 0o111 == 0 {
                    throw CocoaError(.fileReadNoPermission)
                }
            } catch { recordError(directory, error); continue }
            progress(AppInventoryUpdate(apps: apps, detail: "Reading \(directory.path)"))
            guard let enumerator = fileManager.enumerator(at: directory, includingPropertiesForKeys: Array(keys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { url, error in
                    recordError(url, error)
                    return false
                }) else {
                recordError(directory, CocoaError(.fileReadUnknown))
                continue
            }
            while true {
                if shouldStop() { stopped = true; break }
                guard let url = enumerator.nextObject() as? URL else { break }
                examined += 1
                do {
                    let values = try url.resourceValues(forKeys: keys)
                    guard values.isSymbolicLink != true, !ProtectionRules.hasSymlinkComponent(url) else {
                        skippedLinks += 1
                        continue
                    }
                    guard values.isDirectory == true else { continue }
                    if url.pathExtension.lowercased() == "app" {
                        guard visited.insert(url.standardizedFileURL.path).inserted else { continue }
                        let rootBefore = try? FileSnapshotReader.capture(url)
                        let plistURL = url.appendingPathComponent("Contents/Info.plist")
                        let metadataBefore = try? FileSnapshotReader.capture(plistURL)
                        let info: (name: String?, bundleIdentifier: String?, version: String?)
                        do { info = try appInfo(url) }
                        catch {
                            recordError(url.appendingPathComponent("Contents/Info.plist"), error)
                            info = (nil, nil, nil)
                        }
                        apps.append(InstalledApp(id: url.standardizedFileURL.path(percentEncoded: false), url: url,
                            name: info.name ?? url.deletingPathExtension().lastPathComponent,
                            bundleIdentifier: info.bundleIdentifier, version: info.version, size: 0,
                            snapshot: rootBefore.flatMap { FileSnapshotReader.validate(expected: $0, at: url) == .unchanged ? $0 : nil },
                            metadataSnapshot: metadataBefore.flatMap { FileSnapshotReader.validate(expected: $0, at: plistURL) == .unchanged && info.bundleIdentifier != nil ? $0 : nil }, sizeIsKnown: false))
                        progress(AppInventoryUpdate(apps: apps, detail: "Found \(apps.last!.name)"))
                    } else if values.isPackage == true || ["bundle", "framework", "plugin", "appex", "pkg"].contains(url.pathExtension.lowercased()) {
                        skippedPackages += 1
                    } else if depth < 4 {
                        queue.append((url, depth + 1))
                    } else {
                        depthLimited += 1
                    }
                } catch { recordError(url, error) }
            }
            if stopped { break }
        }
        let coverage = Task.isCancelled ? "Cancelled; partial coverage." : stopped
            ? "Inventory limit reached; partial coverage." : readErrors > 0 || depthLimited > 0
            ? "Finished accessible locations; partial coverage." : "Finished accessible application locations."
        messages.append("\(coverage) \(apps.count) apps; \(examined) entries examined; \(readErrors) read errors; \(depthLimited) folders excluded by depth limit. Skipped \(skippedLinks) symbolic links and \(skippedPackages) other packages. Hidden entries and app contents are excluded. Bundle sizes have not been calculated.")
        progress(AppInventoryUpdate(apps: apps, detail: coverage))
        return AppInventoryReport(apps: apps, messages: messages)
    }

    static func scanInstalledApps() -> [InstalledApp] {
        inventory().apps
    }

    static func leftoverRestriction(_ url: URL, home: URL = FileManager.default.homeDirectoryForCurrentUser) -> String? {
        let managedRoots = ["Library/Containers", "Library/Group Containers"].map { home.appendingPathComponent($0) }
        if managedRoots.contains(where: { ProtectionRules.contains($0, url) }) {
            return "Unavailable: macOS-managed app container. Container reset/removal is not supported by MacSweep; it may include shared data and links to personal folders."
        }
        return nil
    }

    static func scanLeftovers(for app: InstalledApp) -> [AppLeftoverItem] {
        scanLeftoversReport(for: app).items
    }

    static func scanLeftoversReport(
        for app: InstalledApp,
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        roots suppliedRoots: [AppLeftoverRoot]? = nil,
        limit: ScanLimit = .quick,
        progress: @escaping @Sendable (AppLeftoverUpdate) -> Void = { _ in }
    ) -> AppLeftoverReport {
        let fileManager = FileManager.default
        let roots = suppliedRoots ?? [
            AppLeftoverRoot(location: "Application Support", url: home.appendingPathComponent("Library/Application Support", isDirectory: true)),
            AppLeftoverRoot(location: "Caches", url: home.appendingPathComponent("Library/Caches", isDirectory: true)),
            AppLeftoverRoot(location: "Preferences", url: home.appendingPathComponent("Library/Preferences", isDirectory: true)),
            AppLeftoverRoot(location: "Logs", url: home.appendingPathComponent("Library/Logs", isDirectory: true)),
            AppLeftoverRoot(location: "Saved State", url: home.appendingPathComponent("Library/Saved Application State", isDirectory: true)),
            AppLeftoverRoot(location: "Containers", url: home.appendingPathComponent("Library/Containers", isDirectory: true)),
            AppLeftoverRoot(location: "Group Containers", url: home.appendingPathComponent("Library/Group Containers", isDirectory: true))
        ]
        let tokens = matchTokens(for: app)
        let started = ProcessInfo.processInfo.systemUptime
        var leftovers: [AppLeftoverItem] = []
        var messages: [String] = []
        var examined = 0
        var errors = 0
        var skippedLinks = 0
        var incompleteMeasurements = 0
        var stopped = false
        var lastEmission: TimeInterval = -1
        let elapsed = { ProcessInfo.processInfo.systemUptime - started }
        func shouldStop() -> Bool { Task.isCancelled || examined >= limit.entries || elapsed() >= limit.seconds }
        func emit(_ detail: String, force: Bool = false) {
            let now = elapsed()
            guard force || now - lastEmission >= 0.25 else { return }
            lastEmission = now
            progress(AppLeftoverUpdate(items: leftovers, detail: detail, examined: examined, elapsed: now))
        }
        func recordError(_ url: URL, _ error: Error) {
            errors += 1
            if errors <= 20 { messages.append("Could not read or measure \(url.path): \(error.localizedDescription)") }
        }
        func validateDirectory(_ url: URL) throws {
            guard !ProtectionRules.hasSymlinkComponent(url) else { throw CocoaError(.fileReadNoPermission) }
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw CocoaError(.fileReadUnsupportedScheme) }
            if let mode = attributes[.posixPermissions] as? NSNumber, mode.intValue & 0o444 == 0 || mode.intValue & 0o111 == 0 {
                throw CocoaError(.fileReadNoPermission)
            }
            guard Darwin.access(url.path, R_OK | X_OK) == 0 else { throw CocoaError(.fileReadNoPermission) }
        }
        func isEffectivelyReadable(_ url: URL) throws -> Bool {
            let attributes = try fileManager.attributesOfItem(atPath: url.path)
            guard let mode = attributes[.posixPermissions] as? NSNumber else { return false }
            return mode.intValue & 0o444 != 0 && Darwin.access(url.path, R_OK) == 0
        }
        func measure(_ candidate: URL) -> (Int64, Bool) {
            do {
                let values = try candidate.resourceValues(forKeys: resourceKeys)
                if values.isSymbolicLink == true { skippedLinks += 1; return (0, false) }
                if values.isRegularFile == true {
                    guard try isEffectivelyReadable(candidate) else { throw CocoaError(.fileReadNoPermission) }
                    guard let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize else { return (0, false) }
                    return (Int64(size), true)
                }
                guard values.isDirectory == true else { throw CocoaError(.fileReadUnknown) }
                try validateDirectory(candidate)
            } catch { recordError(candidate, error); return (0, false) }
            var total: Int64 = 0
            var complete = true
            guard let enumerator = fileManager.enumerator(at: candidate, includingPropertiesForKeys: Array(resourceKeys),
                options: [], errorHandler: { url, error in
                    recordError(url, error); complete = false; return true
                }) else {
                recordError(candidate, CocoaError(.fileReadUnknown)); return (0, false)
            }
            while !shouldStop() {
                guard let child = enumerator.nextObject() as? URL else { break }
                examined += 1
                var childIsDirectory = false
                do {
                    let values = try child.resourceValues(forKeys: resourceKeys)
                    childIsDirectory = values.isDirectory == true
                    if values.isSymbolicLink == true { skippedLinks += 1; complete = false; enumerator.skipDescendants(); continue }
                    if ProtectionRules.isProtected(child, protectRecentFiles: false) {
                        complete = false
                        if values.isDirectory == true { enumerator.skipDescendants() }
                        continue
                    }
                    if values.isRegularFile == true {
                        guard try isEffectivelyReadable(child) else { throw CocoaError(.fileReadNoPermission) }
                        guard let size = values.totalFileAllocatedSize ?? values.fileAllocatedSize else { complete = false; continue }
                        total += Int64(size)
                    } else if values.isDirectory == true {
                        try validateDirectory(child)
                    } else {
                        complete = false
                    }
                } catch {
                    recordError(child, error)
                    complete = false
                    if childIsDirectory { enumerator.skipDescendants() }
                }
                emit("Measuring \(candidate.path)")
            }
            if shouldStop() { stopped = true; complete = false }
            return (total, complete)
        }

        guard !tokens.isEmpty else {
            let summary = "No reliable app identifier or name tokens were available; no locations were scanned."
            return AppLeftoverReport(items: [], messages: [summary], coverageComplete: false, cancelled: false,
                                     examined: 0, readErrorCount: 0, skippedSymlinkCount: 0)
        }
        emit("Preparing related-file scan", force: true)
        for root in roots {
            if shouldStop() { stopped = true; break }
            do { try validateDirectory(root.url) }
            catch { recordError(root.url, error); continue }
            emit("Reading \(root.url.path)", force: true)
            guard let enumerator = fileManager.enumerator(at: root.url, includingPropertiesForKeys: Array(resourceKeys),
                options: [.skipsHiddenFiles, .skipsSubdirectoryDescendants], errorHandler: { url, error in
                    recordError(url, error); return true
                }) else {
                recordError(root.url, CocoaError(.fileReadUnknown)); continue
            }

            while !shouldStop() {
                guard let url = enumerator.nextObject() as? URL else { break }
                examined += 1
                if (try? url.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink) == true {
                    skippedLinks += 1
                    continue
                }
                guard !ProtectionRules.isProtected(url, protectRecentFiles: false),
                      matches(url, tokens: tokens) else {
                    continue
                }

                let policyRestriction = leftoverRestriction(url, home: home)
                let before = try? FileSnapshotReader.capture(url)
                let measurement = policyRestriction == nil ? measure(url) : (0, false)
                let snapshot = before.flatMap { FileSnapshotReader.validate(expected: $0, at: url) == .unchanged ? $0 : nil }
                let incompleteReason: String? = snapshot == nil ? "Unavailable: the item changed or its scan identity could not be verified; scan again."
                    : measurement.1 ? nil : "Unavailable: size measurement incomplete; this item cannot be selected safely."
                leftovers.append(AppLeftoverItem(
                    id: url.standardizedFileURL.path(percentEncoded: false),
                    url: url,
                    location: root.location,
                    size: measurement.0,
                    reason: matchReason(url, app: app) ?? "Advisory name match. Review before selecting.",
                    isSelected: false,
                    blockedReason: policyRestriction ?? incompleteReason,
                    sizeIsKnown: measurement.1, snapshot: snapshot
                ))
                if !measurement.1 || snapshot == nil { incompleteMeasurements += 1 }
                emit("Found \(url.lastPathComponent)", force: true)
                if stopped { break }
            }
            if shouldStop() { stopped = true }
            if stopped { break }
        }
        leftovers = Array(Dictionary(leftovers.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first }).values)
        let cancelled = Task.isCancelled
        let complete = !cancelled && !stopped && errors == 0 && incompleteMeasurements == 0
        let coverage = cancelled ? "Cancelled; partial coverage." : stopped ? "Scan limit reached; partial coverage."
            : errors > 0 || incompleteMeasurements > 0 ? "Finished accessible locations; partial coverage." : "Finished accessible related-file locations."
        let summary = "\(coverage) Found \(leftovers.count) related items; examined \(examined) entries; \(errors) read or measurement errors. Skipped \(skippedLinks) symbolic links. Hidden entries are excluded from discovery; candidate contents are fully measured unless the item is marked unavailable."
        messages.append(summary)
        emit(coverage, force: true)
        return AppLeftoverReport(items: leftovers, messages: messages, coverageComplete: complete, cancelled: cancelled,
                                 examined: examined, readErrorCount: errors, skippedSymlinkCount: skippedLinks)
    }

    static func matchReason(_ url: URL, app: InstalledApp) -> String? {
        let name = url.lastPathComponent.lowercased()
        if let id = app.bundleIdentifier?.lowercased(), !id.isEmpty,
           [id, id + ".plist", id + ".savedstate"].contains(name) {
            return "Exact bundle identifier match. Review ownership before selecting."
        }
        return matches(url, tokens: matchTokens(for: app))
            ? "Advisory name match; this may be shared or belong to another app. Review manually."
            : nil
    }

    private static func appInfo(_ url: URL) throws -> (name: String?, bundleIdentifier: String?, version: String?) {
        let plistURL = url.appendingPathComponent("Contents/Info.plist")
        guard !ProtectionRules.hasSymlinkComponent(plistURL) else { throw CocoaError(.fileReadNoPermission) }
        let data = try BoundedFileReader.read(plistURL)
        guard let dictionary = try PropertyListSerialization.propertyList(from: data, options: [], format: nil) as? [String: Any] else {
            throw CocoaError(.propertyListReadCorrupt)
        }

        let name = dictionary["CFBundleDisplayName"] as? String
            ?? dictionary["CFBundleName"] as? String
        let bundleIdentifier = dictionary["CFBundleIdentifier"] as? String
        let version = dictionary["CFBundleShortVersionString"] as? String
            ?? dictionary["CFBundleVersion"] as? String

        return (name, bundleIdentifier, version)
    }

    private static func matchTokens(for app: InstalledApp) -> [String] {
        var tokens: Set<String> = []
        if let bundleIdentifier = app.bundleIdentifier?.lowercased(), !bundleIdentifier.isEmpty {
            tokens.insert(bundleIdentifier)
        }

        let name = app.name.lowercased()
        tokens.insert(name)
        tokens.insert(name.replacingOccurrences(of: " ", with: ""))
        tokens.insert(name.replacingOccurrences(of: " ", with: "-"))

        return tokens
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 3 }
    }

    private static func matches(_ url: URL, tokens: [String]) -> Bool {
        let target = url.lastPathComponent.lowercased()
        return tokens.contains { token in
            target == token
                || target.hasPrefix("\(token).")
                || target.hasPrefix("\(token)-")

        }
    }

}
