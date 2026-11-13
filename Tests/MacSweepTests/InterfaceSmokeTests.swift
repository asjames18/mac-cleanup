import AppKit
import SwiftUI
import XCTest
@testable import MacSweep

final class InterfaceSmokeTests: XCTestCase {
    @MainActor
    func testSettingsLayOutWithoutStartingAccessCheck() async throws {
        _ = NSApplication.shared
        let model = AppModel()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 490, height: 610),
                              styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: MacSweepSettingsView(model: model))
        window.contentView = host
        window.orderFront(nil)
        try await Task.sleep(for: .milliseconds(300))
        host.layoutSubtreeIfNeeded()
        XCTAssertGreaterThanOrEqual(host.bounds.height, 600)
        XCTAssertFalse(model.isBusy)
        if let folder = ProcessInfo.processInfo.environment["MACSWEEP_PREVIEW_DIR"] {
            let output = URL(fileURLWithPath: folder, isDirectory: true)
            try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
            let capture = Process()
            capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
            capture.arguments = ["-x", "-l", String(window.windowNumber), output.appendingPathComponent("settings.png").path]
            try capture.run(); capture.waitUntilExit()
            XCTAssertEqual(capture.terminationStatus, 0)
        }
    }

    @MainActor
    func testMainDestinationsLayOut() async throws {
        _ = NSApplication.shared
        let model = AppModel()
        let monitor = SystemMonitor()
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1220, height: 840),
                              styleMask: [.titled, .resizable], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let host = NSHostingView(rootView: ContentView(model: model, monitor: monitor))
        window.contentView = host
        window.orderFront(nil)
        for mode in MainViewMode.allCases {
            model.mainViewMode = mode
            // Give native split views and SwiftUI their layout/display pass.
            try await Task.sleep(for: .milliseconds(mode == .overview ? 3_200 : 150))
            host.layoutSubtreeIfNeeded()
            XCTAssertGreaterThan(host.bounds.width, 1000)
            XCTAssertGreaterThan(host.bounds.height, 650)
            if let folder = ProcessInfo.processInfo.environment["MACSWEEP_PREVIEW_DIR"] {
                let output = URL(fileURLWithPath: folder, isDirectory: true)
                try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
                let capture = Process()
                capture.executableURL = URL(fileURLWithPath: "/usr/sbin/screencapture")
                capture.arguments = ["-x", "-l", String(window.windowNumber), output.appendingPathComponent("\(mode.rawValue).png").path]
                try capture.run()
                capture.waitUntilExit()
                XCTAssertEqual(capture.terminationStatus, 0, "Own-window preview capture must succeed when explicitly requested.")
            }
        }
        XCTAssertTrue(model.items.isEmpty, "Viewing destinations must not run cleanup or populate fake results.")
        XCTAssertFalse(model.isBusy)
    }
}
