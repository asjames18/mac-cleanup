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

    private static func readDefinition(
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
            keepAlive: describeKeepAlive(dictionary["KeepAlive"])
        )
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
