import Foundation

/// Stored paths are scan preferences, never a grant of filesystem access.
@MainActor
struct ScanPreferences {
    static let key = "scanPreferences.v1"
    let defaults: UserDefaults

    func load() -> (folders: [URL], preset: ScanPreset, exclusions: [URL]) {
        let record = defaults.dictionary(forKey: Self.key) ?? [:]
        let paths = record["folders"] as? [String] ?? []
        let folders = Self.normalized(paths.filter { $0.hasPrefix("/") && !$0.contains("\0") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) })
        let exclusions = Self.normalized((record["exclusions"] as? [String] ?? [])
            .filter { $0.hasPrefix("/") && !$0.contains("\0") }
            .map { URL(fileURLWithPath: $0, isDirectory: true) })
        return (folders, (record["preset"] as? String).flatMap(ScanPreset.init(rawValue:)) ?? .quick, exclusions)
    }

    func save(folders: [URL], preset: ScanPreset, exclusions: [URL]) {
        defaults.set(["folders": Self.normalized(folders).map(\.path), "preset": preset.rawValue, "exclusions": Self.normalized(exclusions).map(\.path)], forKey: Self.key)
    }

    static func normalized(_ urls: [URL]) -> [URL] {
        var seen = Set<String>()
        return urls.filter(\.isFileURL).map(\.standardizedFileURL).filter {
            !$0.path.contains("\0") && seen.insert($0.path).inserted
        }
    }
}
