import Foundation

/// One process as seen by the scanner. `cpu` is in cores (1.0 = one full core) over the last interval.
public struct ProcessSample: Equatable, Sendable {
    public var pid: Int32
    public var name: String
    public var cpu: Double
    public var residentBytes: Int64

    public init(pid: Int32, name: String, cpu: Double, residentBytes: Int64) {
        self.pid = pid; self.name = name; self.cpu = cpu; self.residentBytes = residentBytes
    }
}

/// Everything the live monitor read in one tick. Optional fields were not read this tick.
public struct LiveSample: Sendable {
    public var at: Date
    public var cpu: Double?
    public var load1: Double?
    public var cores: Int
    /// 1 normal, 2 warning, 4 critical (kern.memorystatus_vm_pressure_level).
    public var memoryPressureLevel: Int?
    public var swapUsed: Int64?
    /// ProcessInfo.ThermalState raw value: 0 nominal, 1 fair, 2 serious, 3 critical.
    public var thermal: Int
    /// CPU_Speed_Limit from `pmset -g therm` (100 = not throttled), when read.
    public var speedLimit: Int?
    /// nil when processes were not scanned this tick.
    public var processes: [ProcessSample]?
    public var diskFree: Int64?
    public var diskTotal: Int64?

    public init(at: Date, cpu: Double? = nil, load1: Double? = nil, cores: Int = 1, memoryPressureLevel: Int? = nil,
                swapUsed: Int64? = nil, thermal: Int = 0, speedLimit: Int? = nil, processes: [ProcessSample]? = nil,
                diskFree: Int64? = nil, diskTotal: Int64? = nil) {
        self.at = at; self.cpu = cpu; self.load1 = load1; self.cores = cores
        self.memoryPressureLevel = memoryPressureLevel; self.swapUsed = swapUsed; self.thermal = thermal
        self.speedLimit = speedLimit; self.processes = processes; self.diskFree = diskFree; self.diskTotal = diskTotal
    }
}

/// Turns live readings into nudge observations with trigger, hold and clear thresholds.
public struct LiveSignalEvaluator: Sendable {
    public struct Thresholds: Equatable, Sendable {
        public var cpuTrigger = 0.85, cpuClear = 0.60, cpuSustain: TimeInterval = 600
        public var processCPUTrigger = 0.80, processCPUClear = 0.50, processSustain: TimeInterval = 600
        public var processRAMTrigger: Int64 = 4 * gigabyte, processRAMClear: Int64 = 3 * gigabyte
        public var swapGrowthTrigger: Int64 = 2 * gigabyte, swapGrowthClear: Int64 = gigabyte / 2
        public var swapWindow: TimeInterval = 1800
        public var memoryWarnSustain: TimeInterval = 300, memoryCriticalSustain: TimeInterval = 60
        public var thermalSustain: TimeInterval = 180, throttleTrigger = 70
        public var diskBadRatio = 0.05, diskWarnRatio = 0.10, diskClearRatio = 0.15
        public var diskBadBytes: Int64 = 5 * gigabyte, diskUrgentBytes: Int64 = 2 * gigabyte
        public init() {}
    }

    public static let gigabyte: Int64 = 1_073_741_824

    struct Point: Sendable { let at: Date; let value: Int64 }

    public var thresholds = Thresholds()
    var swapHistory: [Point] = []
    var diskHistory: [Point] = []
    var runawayKeys: Set<String> = []

    public init(thresholds: Thresholds = Thresholds()) { self.thresholds = thresholds }

    public mutating func evaluate(_ sample: LiveSample) -> [NudgeObservation] {
        var out: [NudgeObservation] = []
        let t = thresholds
        let top = sample.processes?.max { $0.cpu < $1.cpu }

        if let cpu = sample.cpu {
            let condition: NudgeObservation.Condition = cpu >= t.cpuTrigger ? .trigger : cpu < t.cpuClear ? .clear : .hold
            var message = "CPU has been above \(percent(t.cpuTrigger)) for \(minutes(t.cpuSustain)) (now \(percent(cpu)))."
            if let top, top.cpu >= 0.5 { message += " Busiest: \(top.name) at \(percent(top.cpu))." }
            out.append(NudgeObservation(kind: .cpuSustained, condition: condition, message: message, sustain: t.cpuSustain))
        }

        if let level = sample.memoryPressureLevel {
            switch level {
            case 4: out.append(NudgeObservation(kind: .memoryPressure, condition: .trigger, severity: .bad,
                                                message: "Memory pressure is critical. Quit apps you are not using.",
                                                sustain: t.memoryCriticalSustain))
            case 2: out.append(NudgeObservation(kind: .memoryPressure, condition: .trigger, severity: .warn,
                                                message: "Memory pressure has been elevated for \(minutes(t.memoryWarnSustain)). Closing unused apps or tabs will help.",
                                                sustain: t.memoryWarnSustain))
            case 1: out.append(NudgeObservation(kind: .memoryPressure, condition: .clear))
            default: break
            }
        }

        if let swap = sample.swapUsed {
            swapHistory.append(Point(at: sample.at, value: swap))
            swapHistory.removeAll { sample.at.timeIntervalSince($0.at) > t.swapWindow }
            if let first = swapHistory.first, sample.at.timeIntervalSince(first.at) >= t.swapWindow / 2 {
                let growth = swap - (swapHistory.map(\.value).min() ?? first.value)
                let condition: NudgeObservation.Condition = growth >= t.swapGrowthTrigger ? .trigger
                    : growth < t.swapGrowthClear ? .clear : .hold
                out.append(NudgeObservation(kind: .swapGrowth, condition: condition,
                                            message: "Swap grew by \(bytes(growth)) in the last \(minutes(t.swapWindow)) (\(bytes(swap)) in use). Your Mac is short on memory."))
            }
        }

        do {
            let throttled = (sample.speedLimit ?? 100) <= t.throttleTrigger
            var message = sample.thermal >= 3 ? "Your Mac is critically hot and is slowing itself down." : "Your Mac is running hot."
            if let limit = sample.speedLimit, limit < 100 { message += " CPU speed is limited to \(limit)%." }
            message += " Check for busy apps and keep the vents clear."
            switch sample.thermal {
            case 3...: out.append(NudgeObservation(kind: .thermal, condition: .trigger, severity: .bad, message: message, sustain: 60))
            case 2: out.append(NudgeObservation(kind: .thermal, condition: .trigger, message: message, sustain: t.thermalSustain))
            case 1: out.append(NudgeObservation(kind: .thermal, condition: throttled ? .trigger : .hold, message: message, sustain: t.thermalSustain))
            default: out.append(NudgeObservation(kind: .thermal, condition: throttled ? .trigger : .clear, message: message, sustain: t.thermalSustain))
            }
        }

        if let processes = sample.processes { out += runaways(processes) }

        if let free = sample.diskFree, let total = sample.diskTotal, total > 0 {
            out.append(diskLow(free: free, total: total))
            if let trend = diskTrend(free: free, at: sample.at) { out.append(trend) }
        }
        return out
    }

    private mutating func runaways(_ processes: [ProcessSample]) -> [NudgeObservation] {
        let t = thresholds
        var grouped: [String: (cpu: Double, ram: Int64, pids: [Int32])] = [:]
        for p in processes where !p.name.isEmpty {
            var entry = grouped[p.name] ?? (0, 0, [])
            entry.cpu += p.cpu; entry.ram += p.residentBytes; entry.pids.append(p.pid)
            grouped[p.name] = entry
        }
        var out: [NudgeObservation] = []
        var seen: Set<String> = []
        for (name, entry) in grouped.sorted(by: { $0.key < $1.key }) {
            let cpuHot = entry.cpu >= t.processCPUTrigger, ramHot = entry.ram >= t.processRAMTrigger
            let cpuCool = entry.cpu < t.processCPUClear, ramCool = entry.ram < t.processRAMClear
            let condition: NudgeObservation.Condition = (cpuHot || ramHot) ? .trigger : (cpuCool && ramCool) ? .clear : .hold
            guard condition != .clear || runawayKeys.contains(name) else { continue }
            seen.insert(name)
            let pid = entry.pids.count == 1 ? " (PID \(entry.pids[0]))" : " (\(entry.pids.count) processes)"
            let message = ramHot && !cpuHot
                ? "\(name)\(pid) is using \(bytes(entry.ram)) of memory."
                : "\(name)\(pid) has used \(percent(entry.cpu)) of a CPU core for over \(minutes(t.processSustain))."
            out.append(NudgeObservation(kind: .runawayProcess, key: name, condition: condition, message: message, sustain: t.processSustain))
        }
        // Processes that went away are cleared.
        for gone in runawayKeys.subtracting(seen) {
            out.append(NudgeObservation(kind: .runawayProcess, key: gone, condition: .clear))
        }
        runawayKeys = Set(out.filter { $0.condition != .clear }.map(\.key))
        return out
    }

    private func diskLow(free: Int64, total: Int64) -> NudgeObservation {
        let t = thresholds
        let ratio = Double(free) / Double(total)
        let message = "Only \(bytes(free)) of disk space is left. Review large files and caches in Storage."
        if ratio < t.diskBadRatio || free < t.diskBadBytes {
            return NudgeObservation(kind: .diskLow, condition: .trigger, severity: .bad, message: message, urgent: free < t.diskUrgentBytes)
        }
        if ratio < t.diskWarnRatio { return NudgeObservation(kind: .diskLow, condition: .trigger, message: message) }
        return NudgeObservation(kind: .diskLow, condition: ratio >= t.diskClearRatio ? .clear : .hold)
    }

    private mutating func diskTrend(free: Int64, at: Date) -> NudgeObservation? {
        if let last = diskHistory.last, at.timeIntervalSince(last.at) < 600 { return nil }
        diskHistory.append(Point(at: at, value: free))
        diskHistory.removeAll { at.timeIntervalSince($0.at) > 86400 }
        guard let first = diskHistory.first else { return nil }
        let span = at.timeIntervalSince(first.at)
        guard span >= 6 * 3600 else { return nil }
        let drop = first.value - free
        guard drop > 0 else { return NudgeObservation(kind: .diskTrend, condition: .clear) }
        let days = Double(free) / (Double(drop) / span) / 86400
        let condition: NudgeObservation.Condition = (days < 3 && drop >= 2 * Self.gigabyte) ? .trigger : days > 7 ? .clear : .hold
        return NudgeObservation(kind: .diskTrend, condition: condition,
                                message: "Your disk lost \(bytes(drop)) in the last \(Int(span / 3600)) hours. At this rate it fills in about \(max(1, Int(days.rounded()))) day\(days < 1.5 ? "" : "s").")
    }

    private func percent(_ value: Double) -> String { "\(Int((value * 100).rounded()))%" }
    private func minutes(_ seconds: TimeInterval) -> String { "\(Int(seconds / 60)) minutes" }
    private func bytes(_ value: Int64) -> String { ByteCountFormatter.string(fromByteCount: value, countStyle: .file) }
}

/// Parses `pmset -g therm`, for example "CPU_Speed_Limit \t= 100".
public enum PmsetTherm {
    public static func speedLimit(_ output: String) -> Int? {
        for line in output.split(whereSeparator: \.isNewline) where line.contains("CPU_Speed_Limit") {
            if let value = line.split(separator: "=").last.map({ $0.trimmingCharacters(in: .whitespaces) }), let n = Int(value) {
                return n
            }
        }
        return nil
    }
}

/// Parses `ps -axo pid=,pcpu=,rss=,comm=` (rss in KB, %CPU where 100 = one core).
public enum PSOutput {
    public static func parse(_ output: String, excluding pid: Int32) -> [ProcessSample] {
        output.split(whereSeparator: \.isNewline).compactMap { line in
            let fields = line.split(separator: " ", maxSplits: 3, omittingEmptySubsequences: true)
            guard fields.count == 4, let p = Int32(fields[0]), p != pid, let cpu = Double(fields[1]), let rss = Int64(fields[2]) else { return nil }
            let name = String(fields[3]).split(separator: "/").last.map(String.init) ?? String(fields[3])
            return ProcessSample(pid: p, name: name, cpu: cpu / 100, residentBytes: rss * 1024)
        }
    }
}
