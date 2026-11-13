import AppKit
import SwiftUI
import XCTest
@testable import MacSweep

final class ThemeAndShortcutTests: XCTestCase {
    func testPaletteMatchesHandoff() throws {
        func hex(_ color: Color) throws -> String {
            let ns = try XCTUnwrap(NSColor(color).usingColorSpace(.sRGB))
            return String(format: "%02x%02x%02x", Int((ns.redComponent * 255).rounded()), Int((ns.greenComponent * 255).rounded()), Int((ns.blueComponent * 255).rounded()))
        }
        XCTAssertEqual(try hex(Theme.bg), "0d1017")
        XCTAssertEqual(try hex(Theme.panel), "141822")
        XCTAssertEqual(try hex(Theme.panel2), "1a1f2c")
        XCTAssertEqual(try hex(Theme.line), "262c3b")
        XCTAssertEqual(try hex(Theme.text), "e8ebf2")
        XCTAssertEqual(try hex(Theme.muted), "8a93a8")
        XCTAssertEqual(try hex(Theme.accent), "7c6cff")
        XCTAssertEqual(try hex(Theme.accent2), "2dd4bf")
        XCTAssertEqual(try hex(Theme.danger), "ff5d73")
        XCTAssertEqual(try hex(Theme.warn), "ffa94d")
        XCTAssertEqual(try hex(Theme.info), "6ea8fe")
        XCTAssertEqual(try hex(Theme.ok), "3ddc97")
        XCTAssertEqual(Theme.radius, 14)
    }

    func testKeyMapPlainKeys() {
        func action(_ chars: String?, _ code: UInt16 = 0, _ mods: NSEvent.ModifierFlags = [], typing: Bool = false, overlay: Bool = false) -> KeyAction? {
            KeyMap.action(characters: chars, keyCode: code, modifiers: mods, typing: typing, overlayShown: overlay)
        }
        XCTAssertEqual(action("1"), .section(.overview))
        XCTAssertEqual(action("2"), .section(.cleanup))
        XCTAssertEqual(action("6"), .section(.history))
        XCTAssertNil(action("7"))
        XCTAssertNil(action("0"))
        XCTAssertEqual(action("?", 44, [.shift]), .toggleShortcuts)
        XCTAssertEqual(action(nil, 51), .trashSelection)
        XCTAssertEqual(action(nil, 53, overlay: true), .closeOverlay)
        XCTAssertNil(action(nil, 53, overlay: false), "Esc passes through when nothing is open")
    }

    func testKeyMapIgnoresTypingAndModifiedKeys() {
        XCTAssertNil(KeyMap.action(characters: "1", keyCode: 18, modifiers: [], typing: true, overlayShown: false))
        XCTAssertNil(KeyMap.action(characters: nil, keyCode: 51, modifiers: [], typing: true, overlayShown: false), "Delete while typing edits text")
        XCTAssertNil(KeyMap.action(characters: "1", keyCode: 18, modifiers: [.command], typing: false, overlayShown: false))
        XCTAssertNil(KeyMap.action(characters: nil, keyCode: 51, modifiers: [.option], typing: false, overlayShown: false))
        XCTAssertNil(KeyMap.action(characters: nil, keyCode: 51, modifiers: [], typing: false, overlayShown: true), "No Trash shortcut behind the overlay")
        XCTAssertEqual(KeyMap.action(characters: nil, keyCode: 53, modifiers: [], typing: true, overlayShown: true), .closeOverlay)
    }

    @MainActor
    func testModelHandlesActionsAndTrashKeyNeedsSelection() {
        let model = AppModel()
        XCTAssertTrue(model.handle(.section(.storage)))
        XCTAssertEqual(model.mainViewMode, .storage)
        XCTAssertTrue(model.handle(.toggleShortcuts))
        XCTAssertTrue(model.showShortcuts)
        XCTAssertTrue(model.handle(.closeOverlay))
        XCTAssertFalse(model.showShortcuts)
        XCTAssertFalse(model.handle(.closeOverlay))
        model.mainViewMode = .cleanup
        XCTAssertFalse(model.handle(.trashSelection), "Nothing selected, so Delete does nothing")
        XCTAssertFalse(model.isBusy)
    }

    @MainActor
    func testToastAppearsAndClearsItself() async throws {
        let model = AppModel()
        model.toastDuration = .milliseconds(30)
        model.showToast("Hello", kind: .ok)
        XCTAssertEqual(model.toast?.text, "Hello")
        for _ in 0..<100 where model.toast != nil { try await Task.sleep(for: .milliseconds(10)) }
        XCTAssertNil(model.toast)
    }

    func testShortcutListCoversEveryKeyMapAction() {
        let keys = KeyMap.entries.map(\.keys)
        for expected in ["1 – 6", "⌘R", "Delete", "?", "Esc"] { XCTAssertTrue(keys.contains(expected), expected) }
        XCTAssertEqual(MainViewMode.allCases.count, 6)
    }
}
