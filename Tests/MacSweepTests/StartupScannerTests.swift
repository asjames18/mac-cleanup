import Darwin
import Foundation
import XCTest
@testable import MacSweep

final class StartupScannerTests: XCTestCase {
    private var fixtureRoot: URL!

    override func setUpWithError() throws {
        fixtureRoot = FileManager.default.temporaryDirectory
            .appending(path: UUID().uuidString, directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: fixtureRoot, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: fixtureRoot)
    }

    func testReadsDefinitionFieldsFromInjectedLocation() throws {
        let directory = fixtureRoot.appending(path: "LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try writePlist(
            [
                "Label": "com.example.helper",
                "ProgramArguments": ["/Applications/Example.app/Contents/MacOS/helper", "--quiet"],
                "RunAtLoad": true,
                "KeepAlive": ["SuccessfulExit": false]
            ],
            to: directory.appending(path: "com.example.helper.plist")
        )

        let result = try StartupScanner.scan(locations: [
            .init(url: directory, source: .userLaunchAgents)
        ])

        XCTAssertEqual(result.definitions.count, 1)
        XCTAssertEqual(result.definitions[0].label, "com.example.helper")
        XCTAssertEqual(result.definitions[0].program, "/Applications/Example.app/Contents/MacOS/helper")
        XCTAssertEqual(result.definitions[0].runAtLoad, true)
        XCTAssertEqual(result.definitions[0].keepAlive, "Conditional (SuccessfulExit)")
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testMissingDirectoriesAreValidAndProduceNoWarnings() throws {
        let result = try StartupScanner.scan(locations: [
            .init(url: fixtureRoot.appending(path: "Missing"), source: .localLaunchDaemons)
        ])

        XCTAssertTrue(result.definitions.isEmpty)
        XCTAssertTrue(result.warnings.isEmpty)
    }

    func testMalformedPlistProducesWarningWhileValidDefinitionsRemain() throws {
        let directory = fixtureRoot.appending(path: "LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data("not a plist".utf8).write(to: directory.appending(path: "broken.plist"))
        try writePlist(
            ["Label": "com.example.valid", "Program": "/usr/local/bin/example"],
            to: directory.appending(path: "valid.plist")
        )

        let result = try StartupScanner.scan(locations: [
            .init(url: directory, source: .localLaunchAgents)
        ])

        XCTAssertEqual(result.definitions.map(\.label), ["com.example.valid"])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("broken.plist"))
    }

    func testUnreadableLocationProducesWarningWhileOtherLocationsScan() throws {
        let validDirectory = fixtureRoot.appending(path: "Valid", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: validDirectory, withIntermediateDirectories: true)
        try writePlist(
            ["Label": "com.example.valid"],
            to: validDirectory.appending(path: "valid.plist")
        )
        let fileInsteadOfDirectory = fixtureRoot.appending(path: "NotADirectory")
        try Data().write(to: fileInsteadOfDirectory)

        let result = try StartupScanner.scan(locations: [
            .init(url: fileInsteadOfDirectory, source: .localLaunchDaemons),
            .init(url: validDirectory, source: .userLaunchAgents)
        ])

        XCTAssertEqual(result.definitions.count, 1)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("NotADirectory"))
    }

    func testOversizedPlistProducesWarningWhileValidDefinitionsRemain() throws {
        let directory = fixtureRoot.appending(path: "LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try Data(repeating: 0x20, count: 1_048_577)
            .write(to: directory.appending(path: "oversized.plist"))
        try writePlist(["Label": "com.example.valid"], to: directory.appending(path: "valid.plist"))

        let result = try StartupScanner.scan(locations: [
            .init(url: directory, source: .userLaunchAgents)
        ])

        XCTAssertEqual(result.definitions.map(\.label), ["com.example.valid"])
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertTrue(result.warnings[0].contains("oversized.plist"))
    }

    func testFIFOWithPlistExtensionProducesWarningWithoutBlocking() throws {
        let directory = fixtureRoot.appending(path: "LaunchAgents", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let fifo = directory.appending(path: "pipe.plist")
        XCTAssertEqual(mkfifo(fifo.path, 0o600), 0)
        let started = ContinuousClock.now

        let result = try StartupScanner.scan(locations: [
            .init(url: directory, source: .userLaunchAgents)
        ])

        XCTAssertTrue(result.definitions.isEmpty)
        XCTAssertEqual(result.warnings.count, 1)
        XCTAssertLessThan(started.duration(to: .now), .seconds(1))
    }

    func testCancelledScanThrowsCancellationError() async throws {
        let task = Task.detached {
            try Task.checkCancellation()
            return try StartupScanner.scan(locations: [])
        }
        task.cancel()

        do {
            _ = try await task.value
            XCTFail("A cancelled scan should not publish a result")
        } catch is CancellationError {
            // Expected.
        } catch {
            XCTFail("Expected CancellationError, got \(error)")
        }
    }

    private func writePlist(_ value: [String: Any], to url: URL) throws {
        let data = try PropertyListSerialization.data(
            fromPropertyList: value,
            format: .xml,
            options: 0
        )
        try data.write(to: url)
    }
}
