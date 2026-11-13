import AppKit
import Darwin
import Foundation
import IOKit
import IOKit.ps
import MacSweepCore
import Security

/// Slower, read-only checks: security settings, drive and battery health, updates, crashes and startup items.
/// Every tool here is a built-in macOS command run without a shell, admin rights or network access.
enum HealthCheckRunner {
    static func run(fileManager: FileManager = .default, now: Date = Date()) -> HealthCheckResults {
        var r = HealthCheckResults()
        func timed<T>(_ label: String, _ work: () -> T) -> T { PerfLog.measure("health.\(label)", work) }
        r.sip = timed("csrutil") { SystemSignals.run("/usr/bin/csrutil", ["status"]).flatMap(HealthCheckParsers.sip) }
        r.gatekeeper = timed("spctl") { SystemSignals.run("/usr/sbin/spctl", ["--status"]).flatMap(HealthCheckParsers.gatekeeper) }
        r.fileVault = timed("fdesetup") { SystemSignals.run("/usr/bin/fdesetup", ["status"]).flatMap(HealthCheckParsers.fileVault) }
        r.firewall = timed("socketfilterfw") {
            SystemSignals.run("/usr/libexec/ApplicationFirewall/socketfilterfw", ["--getglobalstate"]).flatMap(HealthCheckParsers.firewall)
        }
        r.smartStatus = timed("diskutil") { SystemSignals.run("/usr/sbin/diskutil", ["info", "disk0"]).flatMap(HealthCheckParsers.smartStatus) }
        r.battery = timed("battery") { battery() }
        r.uptime = ProcessInfo.processInfo.systemUptime
        (r.xprotectVersion, r.xprotectAge) = timed("xprotect") { xprotect(now: now) }
        r.pendingUpdates = timed("updates") { pendingUpdates() }
        r.fullDiskAccess = hasFullDiskAccess()
        r.crashCounts = timed("crashes") { crashCounts(now: now) }
        r.recentPanics = timed("panics") { panics(now: now) }
        timed("startup-items") { startupItems(into: &r) }
        return r
    }

    // MARK: Battery (laptops only)

    static func battery() -> BatteryInfo? {
        let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
        guard service != 0 else { return nil }
        defer { IOObjectRelease(service) }
        func int(_ key: String) -> Int? {
            IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?.takeRetainedValue() as? Int
        }
        var info = BatteryInfo(cycleCount: int("CycleCount"), maxCapacity: int("AppleRawMaxCapacity") ?? int("MaxCapacity"),
                               designCapacity: int("DesignCapacity"))
        if let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
           let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef] {
            for source in list {
                guard let description = IOPSGetPowerSourceDescription(blob, source)?.takeUnretainedValue() as? [String: Any],
                      (description[kIOPSTypeKey] as? String) == kIOPSInternalBatteryType else { continue }
                info.condition = (description["BatteryHealthCondition"] as? String) ?? (description[kIOPSBatteryHealthKey] as? String)
            }
        }
        return info
    }

    // MARK: Security definitions and updates

    static let xprotectPlist = "/Library/Apple/System/Library/CoreServices/XProtect.bundle/Contents/Info.plist"

    static func xprotect(now: Date) -> (String?, TimeInterval?) {
        guard let data = FileManager.default.contents(atPath: xprotectPlist),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return (nil, nil) }
        let version = plist["CFBundleShortVersionString"] as? String
        let modified = (try? FileManager.default.attributesOfItem(atPath: xprotectPlist)[.modificationDate]) as? Date
        return (version, modified.map { max(0, now.timeIntervalSince($0)) })
    }

    static func pendingUpdates() -> [String]? {
        guard let data = FileManager.default.contents(atPath: "/Library/Preferences/com.apple.SoftwareUpdate.plist"),
              let plist = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any] else { return nil }
        return HealthCheckParsers.pendingUpdates(plist)
    }

    // MARK: Full Disk Access

    /// Opens (and immediately closes, without reading) a file only Full Disk Access can open.
    static func hasFullDiskAccess() -> Bool? {
        let probe = "/Library/Application Support/com.apple.TCC/TCC.db"
        guard FileManager.default.fileExists(atPath: probe) else { return nil }
        let fd = open(probe, O_RDONLY)
        if fd >= 0 { close(fd); return true }
        return errno == EPERM || errno == EACCES ? false : nil
    }

    static func openFullDiskAccessSettings() {
        let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_AllFiles")!
        NSWorkspace.shared.open(url)
    }

    // MARK: Crashes

    static func crashCounts(now: Date) -> [String: Int]? {
        let folder = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Logs/DiagnosticReports")
        guard let files = try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        var counts: [String: Int] = [:]
        for file in files {
            guard let name = HealthCheckParsers.crashAppName(file.lastPathComponent),
                  let modified = try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate,
                  now.timeIntervalSince(modified) <= 86400 else { continue }
            counts[name, default: 0] += 1
        }
        return counts
    }

    /// Kernel panic reports in the last 7 days. nil when the folder cannot be read (often needs Full Disk Access).
    static func panics(now: Date) -> Int? {
        guard let files = try? FileManager.default.contentsOfDirectory(at: URL(filePath: "/Library/Logs/DiagnosticReports"),
                                                                      includingPropertiesForKeys: [.contentModificationDateKey]) else { return nil }
        return files.filter { file in
            file.pathExtension == "panic"
                && ((try? file.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate).map { now.timeIntervalSince($0) <= 7 * 86400 } ?? false)
        }.count
    }

    // MARK: Startup items

    static func startupItems(into r: inout HealthCheckResults) {
        guard let scan = try? StartupScanner.scan() else { return }
        r.startupItemsAtLogin = scan.definitions.filter { $0.runAtLoad == true || $0.keepAlive == "Yes" }.count
        var missing: [String] = []
        var unsigned: [String] = []
        for item in scan.definitions.prefix(80) {
            guard let program = item.program, program.hasPrefix("/") else { continue }
            guard FileManager.default.fileExists(atPath: program) else { missing.append(item.displayName); continue }
            if signatureState(program) == .unsigned { unsigned.append(item.displayName) }
        }
        r.missingStartupPrograms = missing
        r.unsignedStartupItems = unsigned
    }

    enum SignatureState: Equatable { case valid, unsigned, invalid, unreadable }

    /// Basic validation only (no full hashing of large binaries).
    static func signatureState(_ path: String) -> SignatureState {
        var code: SecStaticCode?
        guard SecStaticCodeCreateWithPath(URL(filePath: path) as CFURL, [], &code) == errSecSuccess, let code else { return .unreadable }
        let status = SecStaticCodeCheckValidity(code, SecCSFlags(rawValue: kSecCSBasicValidateOnly), nil)
        switch status {
        case errSecSuccess: return .valid
        case errSecCSUnsigned: return .unsigned
        case errSecCSStaticCodeNotFound: return .unreadable
        default: return .invalid
        }
    }
}
