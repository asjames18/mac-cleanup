import Foundation
import XCTest
@testable import MacSweepCore

final class ConfirmationLedgerTests: XCTestCase {
    private let start = Date(timeIntervalSince1970: 1_000_000)

    func testTokenIsSingleUse() throws {
        let ledger = ConfirmationLedger()
        let preview = try XCTUnwrap(ledger.issue(paths: ["/a", "/b", "/a"], now: start))
        XCTAssertEqual(preview.paths, ["/a", "/b"])
        XCTAssertEqual(preview.expiresAt, start.addingTimeInterval(300))
        let grant = try ledger.consume(token: preview.token, now: start.addingTimeInterval(10)).get()
        XCTAssertEqual(grant.paths, ["/a", "/b"])
        XCTAssertTrue(grant.matches(["/b", "/a"]))
        XCTAssertFalse(grant.matches(["/a"]))
        XCTAssertEqual(ledger.consume(token: preview.token, now: start.addingTimeInterval(11)), .failure(.alreadyUsed))
    }

    func testTokenExpiresAfterFiveMinutes() throws {
        let ledger = ConfirmationLedger()
        let preview = try XCTUnwrap(ledger.issue(paths: ["/a"], now: start, ttl: 3_600))
        XCTAssertEqual(preview.expiresAt, start.addingTimeInterval(300), "A longer lifetime is capped at five minutes")
        XCTAssertEqual(ledger.consume(token: preview.token, now: start.addingTimeInterval(301)), .failure(.expired))
        XCTAssertEqual(ledger.consume(token: preview.token, now: start.addingTimeInterval(302)), .failure(.alreadyUsed), "An expired token cannot be retried")
    }

    func testUnknownCancelledAndEmptyRequests() throws {
        let ledger = ConfirmationLedger()
        XCTAssertNil(ledger.issue(paths: [], now: start))
        XCTAssertNil(ledger.issue(paths: [""], now: start))
        XCTAssertEqual(ledger.consume(token: "nope", now: start), .failure(.unknown))
        let preview = try XCTUnwrap(ledger.issue(paths: ["/a"], now: start))
        ledger.cancel(token: preview.token)
        XCTAssertEqual(ledger.consume(token: preview.token, now: start), .failure(.unknown))
    }

    func testClockMovedBackwardIsRejected() throws {
        let ledger = ConfirmationLedger()
        let preview = try XCTUnwrap(ledger.issue(paths: ["/a"], now: start))
        XCTAssertEqual(ledger.consume(token: preview.token, now: start.addingTimeInterval(-60)), .failure(.expired))
    }

    func testTitleIsExact() {
        XCTAssertEqual(ConfirmationLedger.title, "Do you really want to do this action?")
    }
}
