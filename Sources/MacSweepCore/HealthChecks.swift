import Foundation

public struct BatteryInfo: Equatable, Sendable {
    public var cycleCount: Int?
    public var maxCapacity: Int?
    public var designCapacity: Int?
    /// macOS's own condition text, e.g. "Good", "Fair", "Poor", "Check Battery", "Service Recommended".
    public var condition: String?

    public init(cycleCount: Int? = nil, maxCapacity: Int? = nil, designCapacity: Int? = nil, condition: String? = nil) {
        self.cycleCount = cycleCount; self.maxCapacity = maxCapacity; self.designCapacity = designCapacity; self.condition = condition
    }

    /// Max capacity as a fraction of design capacity, when both are known.
    public var health: Double? {
        guard let maxCapacity, let designCapacity, designCapacity > 0, maxCapacity > 0 else { return nil }
        // Some Macs report MaxCapacity as a percentage rather than mAh.
        if maxCapacity <= 100 && designCapacity > 1000 { return Double(maxCapacity) / 100 }
        return min(1.5, Double(maxCapacity) / Double(designCapacity))
    }
}

/// Results of the slower checks (run at launch and every 6 hours). nil means "could not tell".
public struct HealthCheckResults: Equatable, Sendable {
    public var sip: Bool?
    public var gatekeeper: Bool?
    public var fileVault: Bool?
    public var firewall: Bool?
    public var smartStatus: String?
    public var battery: BatteryInfo?
    public var uptime: TimeInterval?
    public var xprotectVersion: String?
    public var xprotectAge: TimeInterval?
    public var pendingUpdates: [String]?
    /// App name → crash reports in the last 24 hours.
    public var crashCounts: [String: Int]?
    public var recentPanics: Int?
    public var startupItemsAtLogin: Int?
    public var missingStartupPrograms: [String]?
    public var unsignedStartupItems: [String]?
    public var fullDiskAccess: Bool?

    public init() {}
}

public enum HealthCheckEvaluator {
    public static func observations(_ r: HealthCheckResults) -> [NudgeObservation] {
        var out: [NudgeObservation] = []
        func toggle(_ kind: NudgeKind, _ on: Bool?, severity: NudgeSeverity, off message: String) {
            guard let on else { return }
            out.append(NudgeObservation(kind: kind, condition: on ? .clear : .trigger, severity: severity, message: message))
        }
        toggle(.sip, r.sip, severity: .bad, off: "System Integrity Protection is turned off. It protects macOS system files; turn it back on from Recovery unless you need it off.")
        toggle(.gatekeeper, r.gatekeeper, severity: .warn, off: "Gatekeeper is off, so apps from anywhere can open without a check. Turn it back on in Privacy & Security.")
        toggle(.fileVault, r.fileVault, severity: .warn, off: "FileVault is off, so your disk is not encrypted if this Mac is lost. Turn it on in Privacy & Security.")
        toggle(.firewall, r.firewall, severity: .info, off: "The macOS firewall is off. You can turn it on in Network settings.")

        if let smart = r.smartStatus {
            let failing = smart.localizedCaseInsensitiveContains("fail")
            out.append(NudgeObservation(kind: .driveHealth, condition: failing ? .trigger : .clear, severity: .bad,
                                        message: "Your internal drive reports SMART status \"\(smart)\". Back up your Mac now.", urgent: true))
        }

        if let battery = r.battery {
            let condition = battery.condition ?? ""
            let serviceText = ["service", "poor", "check", "replace"].contains { condition.localizedCaseInsensitiveContains($0) }
            let health = battery.health
            var details: [String] = []
            if let health { details.append("\(Int((health * 100).rounded()))% of original capacity") }
            if let cycles = battery.cycleCount { details.append("\(cycles) cycles") }
            if !condition.isEmpty { details.append("condition: \(condition)") }
            let summary = details.joined(separator: ", ")
            if serviceText || (health ?? 1) < 0.6 {
                out.append(NudgeObservation(kind: .battery, condition: .trigger, severity: .bad,
                                            message: "Your battery needs service (\(summary))."))
            } else if (health ?? 1) < 0.8 || (battery.cycleCount ?? 0) > 1000 {
                out.append(NudgeObservation(kind: .battery, condition: .trigger, severity: .warn,
                                            message: "Your battery is wearing out (\(summary))."))
            } else {
                out.append(NudgeObservation(kind: .battery, condition: .clear))
            }
        }

        if let uptime = r.uptime {
            let days = Int(uptime / 86400)
            let updates = (r.pendingUpdates ?? []).isEmpty ? "" : " Restarting also lets waiting updates install."
            if days >= 30 {
                out.append(NudgeObservation(kind: .uptime, condition: .trigger, severity: .warn,
                                            message: "Your Mac has been running for \(days) days. A restart clears memory leaks and stuck processes.\(updates)"))
            } else if days >= 14 {
                out.append(NudgeObservation(kind: .uptime, condition: .trigger, severity: .info,
                                            message: "Your Mac has been running for \(days) days. Consider a restart soon.\(updates)"))
            } else {
                out.append(NudgeObservation(kind: .uptime, condition: .clear))
            }
        }

        if let age = r.xprotectAge {
            let days = Int(age / 86400)
            out.append(NudgeObservation(kind: .xprotect, condition: days > 45 ? .trigger : .clear, severity: .warn,
                                        message: "XProtect malware definitions\(r.xprotectVersion.map { " (version \($0))" } ?? "") were last updated \(days) days ago. Make sure automatic security updates are on in Software Update."))
        }

        if let updates = r.pendingUpdates {
            let names = updates.prefix(3).joined(separator: ", ") + (updates.count > 3 ? " and \(updates.count - 3) more" : "")
            out.append(NudgeObservation(kind: .updates, condition: updates.isEmpty ? .clear : .trigger, severity: .warn,
                                        message: "\(updates.count == 1 ? "A macOS update is" : "\(updates.count) macOS updates are") waiting: \(names)."))
        }

        if r.crashCounts != nil || r.recentPanics != nil {
            let repeaters = (r.crashCounts ?? [:]).filter { $0.value >= 3 }.sorted { $0.value > $1.value || ($0.value == $1.value && $0.key < $1.key) }
            let panics = r.recentPanics ?? 0
            if repeaters.isEmpty && panics == 0 {
                out.append(NudgeObservation(kind: .crashes, condition: .clear))
            } else {
                var parts: [String] = []
                if panics > 0 { parts.append("macOS restarted unexpectedly \(panics == 1 ? "once" : "\(panics) times") this week") }
                if !repeaters.isEmpty {
                    parts.append(repeaters.prefix(3).map { "\($0.key) crashed \($0.value) times today" }.joined(separator: ", "))
                }
                out.append(NudgeObservation(kind: .crashes, condition: .trigger, severity: panics > 0 ? .bad : .warn,
                                            message: parts.joined(separator: "; ") + ". Updating or reinstalling the app often helps."))
            }
        }

        if r.startupItemsAtLogin != nil || r.missingStartupPrograms != nil {
            let missing = r.missingStartupPrograms ?? []
            let count = r.startupItemsAtLogin ?? 0
            if !missing.isEmpty {
                out.append(NudgeObservation(kind: .loginItems, condition: .trigger, severity: .warn,
                                            message: "\(missing.count == 1 ? "1 startup item points" : "\(missing.count) startup items point") to a program that no longer exists: \(missing.prefix(3).joined(separator: ", ")). Review them in Maintenance."))
            } else if count >= 15 {
                out.append(NudgeObservation(kind: .loginItems, condition: .trigger, severity: .info,
                                            message: "\(count) startup items run at login, which can slow startup. Review them in Maintenance or Login Items settings."))
            } else {
                out.append(NudgeObservation(kind: .loginItems, condition: .clear))
            }
        }

        if let unsigned = r.unsignedStartupItems {
            out.append(NudgeObservation(kind: .unsignedAgent, condition: unsigned.isEmpty ? .clear : .trigger, severity: .warn,
                                        message: "\(unsigned.count == 1 ? "1 startup item runs" : "\(unsigned.count) startup items run") a program with no valid code signature: \(unsigned.prefix(3).joined(separator: ", ")). Make sure you recognize \(unsigned.count == 1 ? "it" : "them")."))
        }

        if let fda = r.fullDiskAccess {
            out.append(NudgeObservation(kind: .fullDiskAccess, condition: fda ? .clear : .trigger, severity: .info,
                                        message: "Grant Full Disk Access so MacSweep can also check system crash reports and every startup item. MacSweep only reads; it never changes privacy settings itself."))
        }
        return out
    }
}

/// Parsers for the output of built-in macOS tools. Each returns nil when the text is not understood.
public enum HealthCheckParsers {
    /// `csrutil status`: "System Integrity Protection status: enabled."
    public static func sip(_ text: String) -> Bool? {
        let lower = text.lowercased()
        guard lower.contains("system integrity protection status") else { return nil }
        if lower.contains("status: enabled") { return true }
        if lower.contains("status: disabled") || lower.contains("status: unknown") { return false }
        return nil
    }

    /// `spctl --status`: "assessments enabled" / "assessments disabled".
    public static func gatekeeper(_ text: String) -> Bool? {
        let lower = text.lowercased()
        if lower.contains("assessments enabled") { return true }
        if lower.contains("assessments disabled") { return false }
        return nil
    }

    /// `fdesetup status`: "FileVault is On." / "FileVault is Off." (encryption in progress counts as on).
    public static func fileVault(_ text: String) -> Bool? {
        let lower = text.lowercased()
        if lower.contains("filevault is on") || lower.contains("encryption in progress") { return true }
        if lower.contains("filevault is off") { return false }
        return nil
    }

    /// `socketfilterfw --getglobalstate`: "Firewall is enabled. (State = 1)".
    public static func firewall(_ text: String) -> Bool? {
        let lower = text.lowercased()
        if lower.contains("state = 1") || lower.contains("state = 2") || lower.contains("firewall is enabled") { return true }
        if lower.contains("state = 0") || lower.contains("firewall is disabled") { return false }
        return nil
    }

    /// `diskutil info disk0`: "SMART Status:   Verified".
    public static func smartStatus(_ text: String) -> String? {
        for line in text.split(whereSeparator: \.isNewline) where line.contains("SMART Status") {
            let value = line.split(separator: ":", maxSplits: 1).last?.trimmingCharacters(in: .whitespaces) ?? ""
            return value.isEmpty ? nil : value
        }
        return nil
    }

    /// Display names from /Library/Preferences/com.apple.SoftwareUpdate.plist, written by macOS's own background check.
    public static func pendingUpdates(_ plist: [String: Any]) -> [String]? {
        if let list = plist["RecommendedUpdates"] as? [[String: Any]] {
            return list.compactMap { entry in
                let name = (entry["Display Name"] as? String) ?? (entry["Identifier"] as? String)
                guard let name else { return nil }
                if let version = entry["Display Version"] as? String, !version.isEmpty, !name.contains(version) { return "\(name) \(version)" }
                return name
            }
        }
        if let count = plist["LastRecommendedUpdatesAvailable"] as? Int { return count == 0 ? [] : Array(repeating: "macOS update", count: count) }
        return nil
    }

    /// "Safari-2026-10-31-101500.ips" → "Safari".
    public static func crashAppName(_ fileName: String) -> String? {
        guard fileName.hasSuffix(".ips") else { return nil }
        let stem = String(fileName.dropLast(4))
        guard let range = stem.range(of: #"[-_]\d{4}-\d{2}-\d{2}-\d{6}"#, options: .regularExpression) else { return nil }
        let name = String(stem[..<range.lowerBound])
        return name.isEmpty ? nil : name
    }
}
