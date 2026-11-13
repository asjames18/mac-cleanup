import Foundation
import MacSweepCore
import SwiftUI
import XCTest
@testable import MacSweep

@MainActor
final class IdleCostTests: XCTestCase {
    private func noon() -> Date {
        Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    private func center() -> NudgeCenter {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let center = NudgeCenter(fileURL: dir.appendingPathComponent("nudges.json"), poster: { _ in })
        let time = noon()
        center.now = { time }
        return center
    }

    func testFullscreenCheckOnlyRunsWhenABannerIsDue() {
        let center = center()
        var checks = 0
        func allowed() -> Bool { checks += 1; return true }
        center.ingest([NudgeObservation(kind: .cpuSustained, condition: .clear, message: "c")], bannersAllowed: allowed())
        XCTAssertEqual(checks, 0, "No banner due, so the window list is never read")
        let banners = center.ingest([NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "m")], bannersAllowed: allowed())
        XCTAssertEqual(checks, 1)
        XCTAssertEqual(banners.map(\.id), ["memoryPressure"])
    }

    func testBlockedBannerStaysUnshownAndKeepsTheCard() {
        let center = center()
        let banners = center.ingest([NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "m")], bannersAllowed: false)
        XCTAssertTrue(banners.isEmpty)
        XCTAssertEqual(center.active.map(\.kind), [.memoryPressure])
    }

    func testRefreshPublishesEvenWithoutVisibleUI() async throws {
        let monitor = SystemMonitor()
        XCTAssertFalse(SystemMonitor.hasVisibleUI, "Tests have no windows")
        monitor.refresh()
        for _ in 0..<100 where monitor.snapshot.updatedAt == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(monitor.snapshot.updatedAt, "An explicit refresh (the popover opening) always publishes")
        XCTAssertEqual(monitor.snapshot, monitor.latest)
    }

    func testPerfLogWritesOnlyWhenEnabled() async throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("perf-\(UUID().uuidString).log")
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        let (wasEnabled, oldURL) = (PerfLog.enabled, PerfLog.fileURL)
        defer { PerfLog.enabled = wasEnabled; PerfLog.fileURL = oldURL }
        PerfLog.fileURL = url
        PerfLog.enabled = false
        XCTAssertEqual(PerfLog.measure("off") { 1 }, 1)
        PerfLog.enabled = true
        XCTAssertEqual(PerfLog.measure("on") { 2 }, 2)
        // Other tests' monitors may log too while it is on; wait for this line specifically.
        var text = ""
        for _ in 0..<150 where !text.contains("on wall=") {
            try await Task.sleep(for: .milliseconds(20))
            text = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        }
        XCTAssertTrue(text.contains("on wall="))
        XCTAssertFalse(text.contains("off wall="))
        XCTAssertGreaterThan(PerfLog.processCPUSeconds(), 0)
    }
}

@MainActor
final class WindowTeardownTests: XCTestCase {
    private final class Counter { var builds = 0 }

    private func settle(_ host: NSView) async throws {
        try await Task.sleep(for: .milliseconds(80))
        host.layoutSubtreeIfNeeded()
    }

    func testClosedMainWindowBuildsNoContent() async throws {
        let presence = WindowPresence()
        let counter = Counter()
        let host = NSHostingView(rootView: MainWindowRoot(presence: presence) {
            let _ = { counter.builds += 1 }()
            Text("content")
        })
        host.frame = NSRect(x: 0, y: 0, width: 200, height: 100)
        try await settle(host)
        XCTAssertGreaterThan(counter.builds, 0, "Open window shows its content")

        presence.mainWindowOpen = false
        try await settle(host)
        let afterClose = counter.builds
        for _ in 0..<5 {
            presence.objectWillChange.send()
            try await settle(host)
        }
        XCTAssertEqual(counter.builds, afterClose, "A closed window does not rebuild its content")

        presence.mainWindowOpen = true
        try await settle(host)
        XCTAssertGreaterThan(counter.builds, afterClose, "Reopening rebuilds the content")
    }
}
