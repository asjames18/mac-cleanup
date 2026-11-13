import Darwin
import Foundation
import IOKit.ps
import MacSweepCore

/// Cheap, root-free system reads used by the nudge monitor.
enum SystemSignals {
    static func swapUsed() -> Int64? {
        var usage = xsw_usage()
        var size = MemoryLayout<xsw_usage>.size
        guard sysctlbyname("vm.swapusage", &usage, &size, nil, 0) == 0 else { return nil }
        return Int64(clamping: usage.xsu_used)
    }

    static func load1() -> Double? {
        var loads = [Double](repeating: 0, count: 3)
        return getloadavg(&loads, 3) >= 1 ? loads[0] : nil
    }

    static var cores: Int { ProcessInfo.processInfo.activeProcessorCount }

    static var thermal: Int {
        switch ProcessInfo.processInfo.thermalState {
        case .nominal: 0
        case .fair: 1
        case .serious: 2
        case .critical: 3
        @unknown default: 0
        }
    }

    static func pressureLevel() -> Int? {
        var level: Int32 = 0
        var size = MemoryLayout.size(ofValue: level)
        guard sysctlbyname("kern.memorystatus_vm_pressure_level", &level, &size, nil, 0) == 0 else { return nil }
        return Int(level)
    }

    /// True when running on battery power. Desktops and unknown states count as AC.
    static var onBattery: Bool {
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(blob)?.takeUnretainedValue() as String? else { return false }
        return type == kIOPSBatteryPowerValue
    }

    static var lowPowerMode: Bool { ProcessInfo.processInfo.isLowPowerModeEnabled }

    /// Runs a system tool with a hard timeout and returns stdout. Never uses a shell.
    static func run(_ path: String, _ arguments: [String], timeout: TimeInterval = 10) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        let process = Process()
        process.executableURL = URL(filePath: path)
        process.arguments = arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        process.standardInput = FileHandle.nullDevice
        let exited = DispatchSemaphore(value: 0)
        process.terminationHandler = { _ in exited.signal() }
        do { try process.run() } catch { return nil }
        // Drain the pipe on another thread so a chatty tool cannot fill it and stall.
        let box = OutputBox()
        let drained = DispatchSemaphore(value: 0)
        let handle = out.fileHandleForReading
        DispatchQueue.global(qos: .utility).async {
            box.data = handle.readDataToEndOfFile()
            drained.signal()
        }
        guard exited.wait(timeout: .now() + timeout) == .success else {
            process.terminate()
            _ = exited.wait(timeout: .now() + 1)
            try? out.fileHandleForWriting.close()
            return nil
        }
        guard drained.wait(timeout: .now() + 2) == .success else { return nil }
        return String(data: box.data, encoding: .utf8)
    }

    private final class OutputBox: @unchecked Sendable { var data = Data() }

    static func speedLimit() -> Int? {
        run("/usr/bin/pmset", ["-g", "therm"], timeout: 5).flatMap(PmsetTherm.speedLimit)
    }
}
