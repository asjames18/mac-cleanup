import AppKit
import MacSweepCore
import SwiftUI
import XCTest
@testable import MacSweep

@MainActor
final class NudgeSurfaceTests: XCTestCase {
    private func tempCenter() -> NudgeCenter {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return NudgeCenter(fileURL: dir.appendingPathComponent("nudges.json"), poster: { _ in })
    }

    /// A uniquely named copy of /usr/bin/yes, so no other process on the Mac can match it.
    private func spawnBusy() throws -> (Process, String) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let name = "msweep-busy-\(UUID().uuidString.prefix(6).lowercased())"
        let tool = dir.appendingPathComponent(name)
        try FileManager.default.copyItem(at: URL(filePath: "/usr/bin/yes"), to: tool)
        // A copied platform binary is killed at launch unless it is re-signed (ad hoc) first.
        let sign = Process()
        sign.executableURL = URL(filePath: "/usr/bin/codesign")
        sign.arguments = ["--force", "--sign", "-", tool.path]
        sign.standardError = FileHandle.nullDevice
        try sign.run(); sign.waitUntilExit()
        XCTAssertEqual(sign.terminationStatus, 0)
        let process = Process()
        process.executableURL = tool
        process.standardOutput = FileHandle.nullDevice
        process.standardError = FileHandle.nullDevice
        try process.run()
        addTeardownBlock { if process.isRunning { process.terminate() }; process.waitUntilExit() }
        Thread.sleep(forTimeInterval: 0.3)
        return (process, name)
    }

    func testEveryKindHasAnActionAndRiskyOnesConfirm() {
        for kind in NudgeKind.allCases {
            let nudge = Nudge(kind: kind, key: kind == .runawayProcess ? "yes" : "", severity: .warn, message: "",
                              since: Date(), urgent: false, bannerShown: false)
            XCTAssertFalse(NudgeActionHandler.actions(for: nudge).isEmpty, "\(kind)")
        }
        let runaway = Nudge(kind: .runawayProcess, key: "yes", severity: .warn, message: "", since: Date(), urgent: false, bannerShown: false)
        let risky = NudgeActionHandler.actions(for: runaway).filter(\.needsConfirm).map(\.kind)
        XCTAssertEqual(risky, [NudgeUIAction.Kind.quitProcess("yes"), .ignoreProcess("yes")])
    }

    func testSnoozeUntilTomorrowMorning() {
        var c = Calendar(identifier: .gregorian); c.timeZone = TimeZone(identifier: "America/New_York")!
        let evening = c.date(from: DateComponents(year: 2026, month: 11, day: 2, hour: 21))!
        XCTAssertEqual(NudgeActionHandler.untilTomorrowMorning(from: evening, calendar: c), 11 * 3600)
    }

    func testQuitNeedsConfirmAndOnlyTouchesTheMatchingOwnProcess() throws {
        let (busy, name) = try spawnBusy()
        let targets = ProcessActions.targets(named: name)
        XCTAssertEqual(targets.map(\.pid), [busy.processIdentifier])
        XCTAssertFalse(ProcessActions.targets(named: ProcessInfo.processInfo.processName).contains { $0.pid == getpid() })

        var answer = false
        var asked: [String] = []
        let model = AppModel(confirmation: { title, detail in asked.append(title + " " + detail); return answer })
        model.toastDuration = .milliseconds(1)
        let handler = NudgeActionHandler(model: model, monitor: NudgeMonitor(center: tempCenter()))
        handler.quit(processNamed: name)
        XCTAssertEqual(asked.count, 1)
        XCTAssertTrue(asked[0].hasPrefix(ConfirmationLedger.title))
        XCTAssertTrue(asked[0].contains("PID \(busy.processIdentifier)"))
        Thread.sleep(forTimeInterval: 0.3)
        XCTAssertTrue(busy.isRunning, "Declined: nothing is signalled")

        answer = true
        handler.quit(processNamed: name)
        busy.waitUntilExit()
        XCTAssertFalse(busy.isRunning)
        XCTAssertEqual(busy.terminationReason, .uncaughtSignal)
    }

    func testIgnoreFromABannerAsksFirst() {
        var answer = false
        let model = AppModel(confirmation: { _, _ in answer })
        model.toastDuration = .milliseconds(1)
        let center = tempCenter()
        let handler = NudgeActionHandler(model: model, monitor: NudgeMonitor(center: center))
        handler.perform(NudgeUIAction(title: "Ignore", systemImage: "", kind: .ignoreProcess("ffmpeg")))
        XCTAssertTrue(center.preferences.ignoredProcesses.isEmpty)
        answer = true
        handler.perform(NudgeUIAction(title: "Ignore", systemImage: "", kind: .ignoreProcess("ffmpeg")))
        XCTAssertEqual(center.preferences.ignoredProcesses, ["ffmpeg"])
    }

    func testNotificationSnoozeAction() {
        let center = tempCenter()
        let noon = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        center.now = { noon }
        center.ingest([NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "m")])
        let handler = NudgeActionHandler(model: AppModel(confirmation: { _, _ in false }), monitor: NudgeMonitor(center: center))
        handler.handleNotification(action: NudgeActions.snoozeHour, info: ["nudge": "memoryPressure", "kind": "memoryPressure", "key": ""])
        XCTAssertTrue(center.isSnoozed(center.active[0]))
    }

    func testMenuBarIconShowsADotOnlyForWarnings() {
        XCTAssertTrue(MenuBarIcon.image(for: nil).isTemplate)
        XCTAssertTrue(MenuBarIcon.image(for: .info).isTemplate)
        XCTAssertFalse(MenuBarIcon.image(for: .warn).isTemplate)
        XCTAssertFalse(MenuBarIcon.image(for: .bad).isTemplate)
    }

    func testNudgesCardAndSettingsLayOut() async throws {
        _ = NSApplication.shared
        let center = tempCenter()
        center.ingest([NudgeObservation(kind: .runawayProcess, key: "yes", condition: .trigger, message: "yes (PID 1) has used 99% of a CPU core."),
                       NudgeObservation(kind: .fileVault, condition: .trigger, message: "FileVault is off.")])
        let monitor = NudgeMonitor(center: center)
        let handler = NudgeActionHandler(model: AppModel(), monitor: monitor)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 900, height: 700), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: VStack {
            NudgesCard(monitor: monitor, center: center, handler: handler)
            Form { NudgeSettingsSection(monitor: monitor, center: center) }
        }.frame(width: 900, height: 700))
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.height, 100)
        XCTAssertEqual(center.active.count, 2)
    }
}
