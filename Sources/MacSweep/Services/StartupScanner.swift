import Foundation
import MacSweepCore

struct StartupDefinition: Identifiable, Sendable {
    enum Source: String, Sendable {
        case userLaunchAgents = "User LaunchAgents"
        case localLaunchAgents = "Local LaunchAgents"
        case localLaunchDaemons = "Local LaunchDaemons"
    }

    let id: String
    let url: URL
    let label: String
    let displayName: String
    let source: Source
    let program: String?
    let runAtLoad: Bool?
    let keepAlive: String?
    /// Why it cannot start (missing program or drive), or nil when it looks fine or cannot be judged.
    var brokenReason: String? = nil

    var isBroken: Bool { brokenReason != nil }

    /// Only your own LaunchAgents can be switched off without an administrator password.
    var canSwitchOff: Bool { source == .userLaunchAgents }

    /// A short identifier for suggestions. Uses the label, not the file path, so no folder names leave the Mac.
    var suggestionKey: String { "\(source == .userLaunchAgents ? "user" : source == .localLaunchAgents ? "agent" : "daemon"):\(label)" }
}

struct StartupScanResult: Sendable {
    let definitions: [StartupDefinition]
    let warnings: [String]
}

enum StartupScanner {
    struct Location: Sendable {
        let url: URL
        let source: StartupDefinition.Source
    }

    static func scan() throws -> StartupScanResult {
        try scan(locations: standardLocations())
    }

    static func standardLocations(
        home: URL = FileManager.default.homeDirectoryForCurrentUser,
        localLibrary: URL = URL(filePath: "/Library", directoryHint: .isDirectory)
    ) -> [Location] {
        [
            Location(
                url: home.appending(path: "Library/LaunchAgents", directoryHint: .isDirectory),
                source: .userLaunchAgents
            ),
            Location(
                url: localLibrary.appending(path: "LaunchAgents", directoryHint: .isDirectory),
                source: .localLaunchAgents
            ),
            Location(
                url: localLibrary.appending(path: "LaunchDaemons", directoryHint: .isDirectory),
                source: .localLaunchDaemons
            )
        ]
    }

    static func scan(locations: [Location]) throws -> StartupScanResult {

        var definitions: [StartupDefinition] = []
        var warnings: [String] = []

        for location in locations {
            try Task.checkCancellation()
            guard FileManager.default.fileExists(atPath: location.url.path) else {
                continue
            }

            let files: [URL]
            do {
                files = try FileManager.default.contentsOfDirectory(
                    at: location.url,
                    includingPropertiesForKeys: [.isRegularFileKey],
                    options: [.skipsHiddenFiles]
                )
            } catch {
                warnings.append("Could not read \(location.url.path): \(error.localizedDescription)")
                continue
            }

            for file in files where file.pathExtension.lowercased() == "plist" {
                try Task.checkCancellation()
                if let definition = try readDefinition(at: file, source: location.source) {
                    definitions.append(definition)
                } else {
                    warnings.append("Could not read a launch definition from \(file.lastPathComponent).")
                }
            }
        }

        return StartupScanResult(
            definitions: definitions.sorted {
                $0.displayName.localizedStandardCompare($1.displayName) == .orderedAscending
            },
            warnings: warnings
        )
    }

    static func readDefinition(
        at url: URL,
        source: StartupDefinition.Source
    ) throws -> StartupDefinition? {
        let data: Data
        do {
            data = try BoundedFileReader.read(url)
        } catch BoundedFileReadError.cancelled {
            throw CancellationError()
        } catch {
            return nil
        }

        guard
            let plist = try? PropertyListSerialization.propertyList(from: data, format: nil),
            let dictionary = plist as? [String: Any]
        else { return nil }

        let fallbackLabel = url.deletingPathExtension().lastPathComponent
        let label = (dictionary["Label"] as? String)?.nonEmpty ?? fallbackLabel
        let displayName = (dictionary["CFBundleDisplayName"] as? String)?.nonEmpty
            ?? (dictionary["Program"] as? String)?.nonEmpty?.lastPathComponent
            ?? label
        let arguments = dictionary["ProgramArguments"] as? [String]
        let program = (dictionary["Program"] as? String)?.nonEmpty ?? arguments?.first?.nonEmpty

        return StartupDefinition(
            id: url.standardizedFileURL.path,
            url: url,
            label: label,
            displayName: displayName,
            source: source,
            program: program,
            runAtLoad: dictionary["RunAtLoad"] as? Bool,
            keepAlive: describeKeepAlive(dictionary["KeepAlive"]),
            brokenReason: brokenReason(program: program)
        )
    }

    /// Checks the real target. Only absolute paths are judged; a bare command name (found on PATH) is left alone.
    static func brokenReason(program: String?, fileManager: FileManager = .default) -> String? {
        guard let program, program.hasPrefix("/") else { return nil }
        let parts = program.split(separator: "/").map(String.init)
        if parts.count >= 2, parts[0] == "Volumes" {
            let volume = "/Volumes/\(parts[1])"
            var isDirectory: ObjCBool = false
            if !fileManager.fileExists(atPath: volume, isDirectory: &isDirectory) || !isDirectory.boolValue {
                return "The drive “\(parts[1])” it starts from isn't connected."
            }
        }
        if !fileManager.fileExists(atPath: program) {
            return "The program it starts is missing (\(URL(fileURLWithPath: program).lastPathComponent))."
        }
        return nil
    }

    private static func describeKeepAlive(_ value: Any?) -> String? {
        if let flag = value as? Bool { return flag ? "Yes" : "No" }
        if let rules = value as? [String: Any], !rules.isEmpty {
            return "Conditional (\(rules.keys.sorted().joined(separator: ", ")))"
        }
        return nil
    }
}

private extension String {
    var nonEmpty: String? { isEmpty ? nil : self }
    var lastPathComponent: String { URL(filePath: self).lastPathComponent }
}

/// Switches off a broken LaunchAgent by moving its launch file to the Trash through the journaled cleanup path,
/// so it can be restored from History. Re-checks everything just before the move.
enum StartupSwitch {
    static var userLaunchAgents: URL {
        FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/LaunchAgents", isDirectory: true)
    }

    /// Returns the result and whether macOS refused the move (so the suggestion can be hidden for 14 days).
    static func switchOff(_ definition: StartupDefinition, launchAgents: URL = userLaunchAgents,
                          journal: CleanupJournal = CleanupSafety.defaultJournal,
                          mover: (URL) throws -> URL? = CleanupSafety.finderTrash) -> (CleanupSafety.TrashResult, Bool) {
        let url = definition.url
        func skipped(_ reason: String, refused: Bool = false) -> (CleanupSafety.TrashResult, Bool) {
            (CleanupSafety.TrashResult(messages: ["Skipped \(url.path): \(reason)"]), refused)
        }
        guard definition.canSwitchOff, url.pathExtension.lowercased() == "plist",
              ProtectionRules.normalizedPath(url.deletingLastPathComponent()).lowercased() == ProtectionRules.normalizedPath(launchAgents).lowercased(),
              !ProtectionRules.hasSymlinkComponent(url) else {
            return skipped("Only launch files in your own LaunchAgents folder can be switched off.")
        }
        func stillBroken() throws {
            let fresh: StartupDefinition?
            do { fresh = try StartupScanner.readDefinition(at: url, source: .userLaunchAgents) }
            catch { throw CleanupSafety.Rejection.changedSinceScan }
            guard let fresh, fresh.label == definition.label, fresh.isBroken else {
                throw CleanupSafety.Rejection.unavailable("It is no longer broken or has changed; refresh Maintenance.")
            }
        }
        do {
            try stillBroken()
            try CleanupSafety.validate(url, protectRecentFiles: false)
        } catch { return skipped(error.localizedDescription) }
        guard FileManager.default.isDeletableFile(atPath: url.path) else {
            return skipped("macOS does not allow MacSweep to move this file.", refused: true)
        }
        let result = CleanupSafety.moveWithJournal(url, journal: journal, revalidate: { try stillBroken() }, mover: mover)
        let refused = result.moved.isEmpty && result.messages.contains {
            $0.localizedCaseInsensitiveContains("permission") || $0.localizedCaseInsensitiveContains("not permitted")
        }
        return (result, refused)
    }
}
