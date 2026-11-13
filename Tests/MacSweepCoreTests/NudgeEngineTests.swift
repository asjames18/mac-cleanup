import Foundation
import XCTest
@testable import MacSweepCore

final class NudgeEngineTests: XCTestCase {
    private var calendar: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/New_York")!
        return c
    }()

    /// 2026-11-02 at the given local hour and minute.
    private func at(_ hour: Int, _ minute: Int = 0, day: Int = 2) -> Date {
        calendar.date(from: DateComponents(year: 2026, month: 11, day: day, hour: hour, minute: minute))!
    }

    private func cpu(_ condition: NudgeObservation.Condition, severity: NudgeSeverity = .warn) -> NudgeObservation {
        NudgeObservation(kind: .cpuSustained, condition: condition, severity: severity, message: "CPU", sustain: 600)
    }

    private func engine() -> NudgeEngine { NudgeEngine(calendar: calendar) }

    func testSustainedWindowMustHoldBeforeActivating() {
        var e = engine()
        XCTAssertTrue(e.ingest([cpu(.trigger)], now: at(12)).active.isEmpty)
        XCTAssertTrue(e.ingest([cpu(.trigger)], now: at(12, 9)).active.isEmpty)
        let result = e.ingest([cpu(.trigger)], now: at(12, 10))
        XCTAssertEqual(result.active.map(\.kind), [.cpuSustained])
        XCTAssertEqual(result.banners.count, 1)
    }

    func testClearResetsThePendingWindow() {
        var e = engine()
        _ = e.ingest([cpu(.trigger)], now: at(12))
        _ = e.ingest([cpu(.clear)], now: at(12, 5))
        XCTAssertTrue(e.ingest([cpu(.trigger)], now: at(12, 11)).active.isEmpty, "Window restarted at 12:11")
        XCTAssertFalse(e.ingest([cpu(.trigger)], now: at(12, 21)).active.isEmpty)
    }

    func testHysteresisHoldKeepsActiveNudgeAndDoesNotFlap() {
        var e = engine()
        _ = e.ingest([cpu(.trigger)], now: at(12))
        _ = e.ingest([cpu(.trigger)], now: at(12, 10))
        for minute in 11...20 {
            let result = e.ingest([cpu(minute.isMultiple(of: 2) ? .hold : .trigger)], now: at(12, minute))
            XCTAssertEqual(result.active.count, 1)
            XCTAssertTrue(result.banners.isEmpty, "Only one banner while it stays active")
        }
        XCTAssertTrue(e.ingest([cpu(.clear)], now: at(12, 21)).active.isEmpty)
    }

    func testHoldDoesNotStartANudge() {
        var e = engine()
        _ = e.ingest([cpu(.trigger)], now: at(12))
        _ = e.ingest([cpu(.hold)], now: at(12, 5))
        XCTAssertTrue(e.ingest([cpu(.trigger)], now: at(12, 10)).active.isEmpty)
    }

    func testCooldownBlocksRepeatBanners() {
        var e = engine()
        let mem = NudgeObservation(kind: .memoryPressure, condition: .trigger, severity: .warn, message: "m")
        XCTAssertEqual(e.ingest([mem], now: at(12)).banners.count, 1)
        _ = e.ingest([NudgeObservation(kind: .memoryPressure, condition: .clear)], now: at(12, 30))
        XCTAssertTrue(e.ingest([mem], now: at(13)).banners.isEmpty, "Within 4 h cooldown")
        _ = e.ingest([NudgeObservation(kind: .memoryPressure, condition: .clear)], now: at(15))
        XCTAssertEqual(e.ingest([mem], now: at(16, 1)).banners.count, 1, "After 4 h")
    }

    func testDailyBudgetOfThree() {
        var e = engine()
        let kinds: [NudgeKind] = [.memoryPressure, .swapGrowth, .thermal, .diskTrend]
        let result = e.ingest(kinds.map { NudgeObservation(kind: $0, condition: .trigger, message: "x") }, now: at(12))
        XCTAssertEqual(result.banners.count, 3)
        XCTAssertEqual(result.active.count, 4, "The fourth still shows as a card")
        XCTAssertTrue(e.ingest([], now: at(18)).banners.isEmpty)
        XCTAssertEqual(e.ingest([], now: at(9, day: 3)).banners.count, 1, "The held one goes out the next day")
    }

    func testQuietHoursHoldBannersUntilMorning() {
        var e = engine()
        let mem = NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "m")
        let night = e.ingest([mem], now: at(23))
        XCTAssertTrue(night.banners.isEmpty)
        XCTAssertEqual(night.active.count, 1)
        XCTAssertTrue(e.ingest([mem], now: at(7, 59, day: 3)).banners.isEmpty)
        XCTAssertEqual(e.ingest([mem], now: at(8, 0, day: 3)).banners.count, 1)
    }

    func testUrgentBadNudgesBreakQuietHours() {
        var e = engine()
        let disk = NudgeObservation(kind: .diskLow, condition: .trigger, severity: .bad, message: "1 GB free", urgent: true)
        XCTAssertEqual(e.ingest([disk], now: at(2)).banners.count, 1)
        let warnOnly = NudgeObservation(kind: .driveHealth, condition: .trigger, severity: .warn, message: "x", urgent: true)
        XCTAssertTrue(e.ingest([warnOnly], now: at(2, 5)).banners.isEmpty)
    }

    func testQuietWindowMath() {
        let p = NudgePreferences()
        XCTAssertTrue(p.isQuiet(at(22), calendar: calendar))
        XCTAssertTrue(p.isQuiet(at(3), calendar: calendar))
        XCTAssertFalse(p.isQuiet(at(8), calendar: calendar))
        XCTAssertFalse(p.isQuiet(at(21, 59), calendar: calendar))
        var day = NudgePreferences(); day.quietStart = 9 * 60; day.quietEnd = 17 * 60
        XCTAssertTrue(day.isQuiet(at(12), calendar: calendar))
        XCTAssertFalse(day.isQuiet(at(18), calendar: calendar))
    }

    func testSnoozeByIdAndByKind() {
        var e = engine()
        let mem = NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "m")
        e.snooze(id: mem.id, until: at(13))
        XCTAssertTrue(e.ingest([mem], now: at(12)).banners.isEmpty)
        XCTAssertEqual(e.ingest([mem], now: at(13, 1)).banners.count, 1)
        e.snooze(kind: .runawayProcess, until: at(20))
        let proc = NudgeObservation(kind: .runawayProcess, key: "yes", condition: .trigger, message: "p")
        XCTAssertTrue(e.ingest([proc], now: at(14)).banners.isEmpty)
        XCTAssertEqual(e.ingest([], now: at(14)).active.count, 2, "Snoozed nudges still show as cards")
    }

    func testDisabledKindsAndIgnoredProcessesDisappear() {
        var e = engine()
        e.preferences.disabledKinds = [.thermal]
        let result = e.ingest([NudgeObservation(kind: .thermal, condition: .trigger, message: "t"),
                               NudgeObservation(kind: .runawayProcess, key: "ffmpeg", condition: .trigger, message: "p")], now: at(12))
        XCTAssertEqual(result.active.map(\.id), ["runawayProcess:ffmpeg"])
        e.ignore(process: "FFMPEG")
        XCTAssertTrue(e.ingest([], now: at(12, 1)).active.isEmpty)
        XCTAssertTrue(e.ingest([NudgeObservation(kind: .runawayProcess, key: "ffmpeg", condition: .trigger)], now: at(12, 2)).banners.isEmpty)
    }

    func testMasterSwitchAndBannerSwitch() {
        var e = engine()
        e.preferences.bannersEnabled = false
        let mem = NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "m")
        let r = e.ingest([mem], now: at(12))
        XCTAssertTrue(r.banners.isEmpty); XCTAssertEqual(r.active.count, 1)
        e.preferences.enabled = false
        XCTAssertTrue(e.ingest([mem], now: at(12, 1)).active.isEmpty)
    }

    func testEscalationEarnsANewBannerOnlyAfterCooldown() {
        var e = engine()
        let warn = NudgeObservation(kind: .memoryPressure, condition: .trigger, severity: .warn, message: "w")
        var bad = warn; bad.severity = .bad
        XCTAssertEqual(e.ingest([warn], now: at(12)).banners.count, 1)
        XCTAssertTrue(e.ingest([bad], now: at(12, 5)).banners.isEmpty, "Cooldown still applies")
        XCTAssertEqual(e.ingest([bad], now: at(16, 6)).banners.first?.severity, .bad)
    }

    func testInfoNudgesNeverBanner() {
        var e = engine()
        let r = e.ingest([NudgeObservation(kind: .uptime, condition: .trigger, severity: .info, message: "u")], now: at(12))
        XCTAssertTrue(r.banners.isEmpty); XCTAssertEqual(r.active.count, 1)
    }

    func testBannersHeldWhileNotAllowedThenSent() {
        var e = engine()
        let mem = NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "m")
        XCTAssertTrue(e.ingest([mem], now: at(12), bannersAllowed: false).banners.isEmpty)
        XCTAssertEqual(e.ingest([], now: at(12, 1)).banners.count, 1)
    }

    func testActiveOrderMostSevereFirst() {
        var e = engine()
        let r = e.ingest([NudgeObservation(kind: .uptime, condition: .trigger, severity: .info),
                          NudgeObservation(kind: .diskLow, condition: .trigger, severity: .bad),
                          NudgeObservation(kind: .firewall, condition: .trigger, severity: .warn)], now: at(12))
        XCTAssertEqual(r.active.map(\.kind), [.diskLow, .firewall, .uptime])
    }

    func testStateRoundTripsThroughJSON() throws {
        var e = engine()
        _ = e.ingest([NudgeObservation(kind: .memoryPressure, condition: .trigger, message: "m")], now: at(12))
        e.snooze(kind: .thermal, until: at(20))
        let data = try JSONCoding.encoder().encode(e.state)
        let back = try JSONCoding.decoder().decode(NudgeState.self, from: data)
        XCTAssertEqual(back.active.keys.sorted(), ["memoryPressure"])
        XCTAssertEqual(back.bannersPerDay.values.reduce(0, +), 1)
        XCTAssertNotNil(back.snoozedUntil["thermal"])
    }
}
