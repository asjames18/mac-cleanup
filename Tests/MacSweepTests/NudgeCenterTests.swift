import Foundation
import MacSweepCore
import XCTest
@testable import MacSweep

@MainActor
final class NudgeCenterTests: XCTestCase {
    private func tempFile() -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        addTeardownBlock { try? FileManager.default.removeItem(at: dir) }
        return dir.appendingPathComponent("nudges.json")
    }

    private func noon() -> Date {
        var c = Calendar.current; c.timeZone = .current
        return c.date(bySettingHour: 12, minute: 0, second: 0, of: Date())!
    }

    func testBannersGoToThePosterAndStatePersists() async throws {
        let url = tempFile()
        var posted: [String] = []
        let center = NudgeCenter(fileURL: url, poster: { posted.append($0.id) })
        let time = noon()
        center.now = { time }
        let banners = center.ingest([NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "m")])
        XCTAssertEqual(banners.map(\.id), ["memoryPressure"])
        for _ in 0..<50 where posted.isEmpty { try await Task.sleep(for: .milliseconds(20)) }
        XCTAssertEqual(posted, ["memoryPressure"])
        XCTAssertEqual(center.worstSeverity, .warn)
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))

        let reopened = NudgeCenter(fileURL: url, poster: { _ in XCTFail("No repeat banner after relaunch") })
        reopened.now = { time.addingTimeInterval(60) }
        XCTAssertTrue(reopened.ingest([NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "m")]).isEmpty)
        XCTAssertEqual(reopened.active.count, 1)
    }

    func testIgnoreAndToggleApplyImmediately() {
        let center = NudgeCenter(fileURL: tempFile(), poster: { _ in })
        let time = noon()
        center.now = { time }
        center.ingest([NudgeObservation(kind: .runawayProcess, key: "yes", condition: .trigger, message: "p"),
                       NudgeObservation(kind: .thermal, condition: .trigger, message: "t")])
        XCTAssertEqual(center.active.count, 2)
        center.ignore(process: "yes")
        XCTAssertEqual(center.active.map(\.kind), [.thermal])
        center.setKind(.thermal, enabled: false)
        XCTAssertTrue(center.active.isEmpty)
        XCTAssertEqual(center.preferences.ignoredProcesses, ["yes"])
        center.unignore(process: "YES")
        XCTAssertTrue(center.preferences.ignoredProcesses.isEmpty)
    }

    func testCorruptFileFallsBackToDefaults() throws {
        let url = tempFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not json".utf8).write(to: url)
        let center = NudgeCenter(fileURL: url, poster: { _ in })
        XCTAssertEqual(center.preferences, NudgePreferences())
    }
}
