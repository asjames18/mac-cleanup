import Foundation

public enum JSONCoding {
    public static func encoder() -> JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    public static func decoder() -> JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }

    /// Accepts a UTF-8 byte-order mark written by other editors.
    public static func stripBOM(_ data: Data) -> Data {
        if data.count >= 3, data[0] == 0xEF, data[1] == 0xBB, data[2] == 0xBF { return Data(data.dropFirst(3)) }
        return data
    }
}

/// Atomic JSON files with timestamped backups. A corrupt file is renamed `<name>.bak`
/// and the caller's default is used, so one bad write never stops the app from starting.
public final class AtomicJSONStore: @unchecked Sendable {
    public struct LoadResult<T> {
        public let value: T
        /// Set when the file could not be decoded and was moved aside.
        public let recoveredBackup: URL?
    }

    public let root: URL
    public let backupLimit: Int
    private let lock = NSLock()
    private let fileManager = FileManager.default

    public init(root: URL, backupLimit: Int = 20) throws {
        self.root = root
        self.backupLimit = max(1, backupLimit)
        for folder in [root, root.appendingPathComponent("backups", isDirectory: true)] {
            try fileManager.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        }
    }

    public var backupsDirectory: URL { root.appendingPathComponent("backups", isDirectory: true) }

    public func load<T: Decodable>(_ file: String, as type: T.Type, default fallback: T) -> LoadResult<T> {
        lock.lock(); defer { lock.unlock() }
        let url = root.appendingPathComponent(file)
        guard fileManager.fileExists(atPath: url.path) else { return LoadResult(value: fallback, recoveredBackup: nil) }
        do {
            let data = try Data(contentsOf: url)
            return LoadResult(value: try JSONCoding.decoder().decode(T.self, from: JSONCoding.stripBOM(data)), recoveredBackup: nil)
        } catch {
            let bak = root.appendingPathComponent(file + ".bak")
            try? fileManager.removeItem(at: bak)
            try? fileManager.moveItem(at: url, to: bak)
            return LoadResult(value: fallback, recoveredBackup: bak)
        }
    }

    public func save<T: Encodable>(_ file: String, value: T, backupReason: String, now: Date = Date()) throws {
        lock.lock(); defer { lock.unlock() }
        let url = root.appendingPathComponent(file)
        if fileManager.fileExists(atPath: url.path) {
            let backup = backupsDirectory.appendingPathComponent("\(file).\(Self.stamp(now)).pre-\(Self.safeReason(backupReason))")
            try? fileManager.removeItem(at: backup)
            try fileManager.copyItem(at: url, to: backup)
            pruneBackups(for: file)
        }
        let data = try JSONCoding.encoder().encode(value)
        try data.write(to: url, options: .atomic)
        try? fileManager.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    public func backups(for file: String) -> [URL] {
        let names = (try? fileManager.contentsOfDirectory(atPath: backupsDirectory.path)) ?? []
        return names.filter { $0.hasPrefix(file + ".") }.sorted().map { backupsDirectory.appendingPathComponent($0) }
    }

    private func pruneBackups(for file: String) {
        let all = backups(for: file)
        guard all.count > backupLimit else { return }
        for old in all.prefix(all.count - backupLimit) { try? fileManager.removeItem(at: old) }
    }

    public static func stamp(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyyMMdd-HHmmss-SSS"
        return formatter.string(from: date)
    }

    public static func safeReason(_ reason: String) -> String {
        let mapped = String(reason.map { $0.isLetter || $0.isNumber || $0 == "-" ? $0 : "-" })
        let trimmed = mapped.trimmingCharacters(in: CharacterSet(charactersIn: "-"))
        return trimmed.isEmpty ? "change" : String(trimmed.prefix(40))
    }
}

public struct ActionLogEntry: Equatable, Sendable {
    public var time: Date
    public var kind: String
    public var message: String
}

/// Append-only, one line per action: `time | kind | message`. Rotates to `actions.log.1` past `maxBytes`.
public final class ActionLog: @unchecked Sendable {
    public let fileURL: URL
    public let maxBytes: Int
    private let lock = NSLock()

    public init(directory: URL, maxBytes: Int = 1_000_000) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        fileURL = directory.appendingPathComponent("actions.log")
        self.maxBytes = max(1_024, maxBytes)
        if !FileManager.default.fileExists(atPath: fileURL.path) {
            FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
    }

    public func append(kind: String, message: String, now: Date = Date()) {
        let clean = { (text: String) in text.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "|", with: "/") }
        let line = "\(Self.format(now)) | \(clean(kind)) | \(clean(String(message.prefix(4_000))))\n"
        guard let data = line.data(using: .utf8) else { return }
        lock.lock(); defer { lock.unlock() }
        let size = (try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int) ?? 0
        if size + data.count > maxBytes {
            let rotated = fileURL.appendingPathExtension("1")
            try? FileManager.default.removeItem(at: rotated)
            try? FileManager.default.moveItem(at: fileURL, to: rotated)
            FileManager.default.createFile(atPath: fileURL.path, contents: Data(), attributes: [.posixPermissions: 0o600])
        }
        guard let handle = try? FileHandle(forWritingTo: fileURL) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// Newest first.
    public func recent(limit: Int = 200) -> [ActionLogEntry] {
        lock.lock(); defer { lock.unlock() }
        guard let text = try? String(contentsOf: fileURL, encoding: .utf8) else { return [] }
        return text.split(separator: "\n").suffix(max(0, limit)).reversed().compactMap { line in
            let parts = line.split(separator: "|", maxSplits: 2, omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 3, let time = Self.parse(parts[0]) else { return nil }
            return ActionLogEntry(time: time, kind: parts[1], message: parts[2])
        }
    }

    private static func formatter() -> DateFormatter {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss'Z'"
        return formatter
    }

    public static func format(_ date: Date) -> String { formatter().string(from: date) }
    public static func parse(_ text: String) -> Date? { formatter().date(from: text) }
}

/// MacSweep's own settings file (`settings.json`). Unknown or missing keys fall back to safe defaults.
public struct MacSweepSettings: Codable, Equatable, Sendable {
    public var version: Int = 1
    public var sandboxEnabled: Bool = true
    public var ai: AISettings = .dormant

    public init(sandboxEnabled: Bool = true, ai: AISettings = .dormant) {
        self.sandboxEnabled = sandboxEnabled
        self.ai = ai
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        version = try container.decodeIfPresent(Int.self, forKey: .version) ?? 1
        sandboxEnabled = try container.decodeIfPresent(Bool.self, forKey: .sandboxEnabled) ?? true
        ai = ((try? container.decodeIfPresent(AISettings.self, forKey: .ai)) ?? .dormant).sanitized()
    }
}
