import Combine
import Foundation
import MacSweepCore
import SwiftUI
import XCTest
@testable import MacSweep

@MainActor
final class DashboardPerfTests: XCTestCase {
    private func snapshot(cpu: Double, memory: Int64, disk: Int64, at: Date = Date()) -> SystemSnapshot {
        SystemSnapshot(cpuUsage: cpu, memoryUsed: memory, memoryTotal: 16_000_000_000, memoryPressure: "Normal",
                       diskFree: disk, diskTotal: 500_000_000_000, uptime: 100, updatedAt: at)
    }

    func testReadingsRoundToWhatIsShown() {
        let at = Date()
        let a = snapshot(cpu: 0.181, memory: 13_180_000_000, disk: 134_890_000_000, at: at)
        let b = snapshot(cpu: 0.179, memory: 13_181_000_000, disk: 134_890_400_000, at: at)
        XCTAssertEqual(FastReadings(a), FastReadings(b), "18.1% and 17.9% both show 18%")
        XCTAssertEqual(SlowReadings(a), SlowReadings(b), "A few hundred KB of disk churn changes nothing on screen")
        XCTAssertEqual(FastReadings(a).cpuText, "18%")
        XCTAssertEqual(FastReadings(a).cpuFraction, 0.18)
        XCTAssertNotEqual(FastReadings(snapshot(cpu: 0.4, memory: 13_180_000_000, disk: 1)), FastReadings(a))
    }

    func testStoreOnlyNotifiesOnRealChanges() {
        let store = ReadingStore(FastReadings())
        var notifications = 0
        let token = store.objectWillChange.sink { notifications += 1 }
        defer { token.cancel() }
        let at = Date()
        store.update(FastReadings(snapshot(cpu: 0.2, memory: 1_000_000_000, disk: 1, at: at)))
        store.update(FastReadings(snapshot(cpu: 0.2, memory: 1_000_000_000, disk: 2, at: at)))
        store.update(FastReadings(snapshot(cpu: 0.2001, memory: 1_000_000_000, disk: 3, at: at)))
        XCTAssertEqual(notifications, 1)
        XCTAssertEqual(store.changes, 1)
        store.update(FastReadings(snapshot(cpu: 0.5, memory: 1_000_000_000, disk: 3, at: at)))
        XCTAssertEqual(notifications, 2)
    }

    func testLiveViewsRedrawOnlyWhenTheirValueChanges() {
        let label = LiveLabelView(frame: NSRect(x: 0, y: 0, width: 100, height: 20))
        label.text = "18%"
        label.text = "18%"
        XCTAssertEqual(label.redraws, 1)
        label.text = "19%"
        XCTAssertEqual(label.redraws, 2)
        XCTAssertEqual(label.intrinsicContentSize.width, NSView.noIntrinsicMetric, "Text changes never resize the view")
        let meter = LiveMeterView(frame: NSRect(x: 0, y: 0, width: 100, height: 7))
        meter.fraction = 0.3
        meter.fraction = 0.3
        XCTAssertEqual(meter.redraws, 1)
        XCTAssertEqual(UsageMeter(fraction: 0.3, color: Theme.warn), UsageMeter(fraction: 0.3, color: Theme.warn))
    }

    func testBoundLabelFollowsTheStoreWithoutSwiftUIUpdates() async throws {
        let store = ReadingStore(FastReadings())
        let host = NSHostingView(rootView: LiveText(store: store, style: .metric) { $0.cpuText }.frame(width: 120, height: 34))
        host.frame = NSRect(x: 0, y: 0, width: 120, height: 34)
        host.layoutSubtreeIfNeeded()
        func label(in view: NSView) -> LiveLabelView? {
            if let found = view as? LiveLabelView { return found }
            for sub in view.subviews { if let found = label(in: sub) { return found } }
            return nil
        }
        let view = try XCTUnwrap(label(in: host))
        XCTAssertEqual(view.text, "—")
        store.update(FastReadings(snapshot(cpu: 0.42, memory: 1, disk: 1)))
        XCTAssertEqual(view.text, "42%")
        let redraws = view.redraws
        store.update(FastReadings(snapshot(cpu: 0.4201, memory: 1, disk: 1)))
        XCTAssertEqual(view.redraws, redraws, "Same displayed value, no redraw")
    }

    func testRewordedNudgesPublishAndSaveRarely() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        let center = NudgeCenter(fileURL: dir.appendingPathComponent("nudges.json"), poster: { _ in })
        var time = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
        center.now = { time }
        center.ingest([NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "pressure 1")])
        let (publishes, saves) = (center.activePublishes, center.saves)
        XCTAssertEqual(publishes, 1)
        for step in 2...10 {
            time = time.addingTimeInterval(3)
            center.ingest([NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "pressure \(step)")])
        }
        XCTAssertEqual(center.activePublishes, publishes, "Rewording alone waits a minute")
        XCTAssertEqual(center.saves, saves, "…and is not written to disk every sample")
        XCTAssertEqual(center.active.first?.message, "pressure 1")
        time = time.addingTimeInterval(61)
        center.ingest([NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "pressure 11")])
        XCTAssertEqual(center.active.first?.message, "pressure 11")
        center.ingest([NudgeObservation(kind: .thermal, condition: .trigger, message: "hot")])
        XCTAssertTrue(center.active.contains { $0.kind == .thermal }, "A new nudge shows at once")
    }

    func testHealthInputsIgnoreDiskChurn() {
        let at = Date()
        XCTAssertEqual(HealthInputs(snapshot(cpu: 0.1, memory: 1, disk: 134_100_000_000, at: at)),
                       HealthInputs(snapshot(cpu: 0.9, memory: 2, disk: 134_900_000_000, at: at)))
    }

    func testUnfocusedWindowRefreshesSlower() {
        XCTAssertEqual(IdleSchedule.unfocusedInterval, 15)
        XCTAssertGreaterThan(IdleSchedule.unfocusedInterval, SystemMonitor().interactiveInterval)
        XCTAssertFalse(SystemMonitor.uiIsFocused, "No key window under tests")
    }

    func testRefreshFillsTheDashboardStores() async throws {
        let monitor = SystemMonitor()
        monitor.refresh()
        for _ in 0..<100 where monitor.slow.value.diskFreeText == nil { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertNotNil(monitor.slow.value.diskFreeText)
        XCTAssertNotNil(monitor.fast.value.updatedText)
    }

    func testDashboardRendersWithLiveViews() async throws {
        let model = AppModel()
        let monitor = SystemMonitor()
        let host = NSHostingView(rootView: DashboardView(model: model, monitor: monitor).frame(width: 1100, height: 900))
        host.frame = NSRect(x: 0, y: 0, width: 1100, height: 900)
        monitor.refresh()
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThan(host.fittingSize.width, 0)
    }
}
