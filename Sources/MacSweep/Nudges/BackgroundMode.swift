import AppKit
import Foundation
import SwiftUI

/// MacSweep can run as a menu-bar-only app: no Dock icon and no window until you open one.
/// It starts that way with `--background`, or when macOS opens it at login.
@MainActor
enum BackgroundMode {
    nonisolated static func shouldStartInBackground(arguments: [String], launchedAsLoginItem: Bool) -> Bool {
        arguments.contains("--background") || (launchedAsLoginItem && !arguments.contains("--foreground"))
    }

    /// True when macOS opened MacSweep as a login item.
    static var launchedAsLoginItem: Bool {
        guard let event = NSAppleEventManager.shared().currentAppleEvent,
              event.eventID == AEEventID(kAEOpenApplication),
              let property = event.paramDescriptor(forKeyword: AEKeyword(keyAEPropData)) else { return false }
        return property.enumCodeValue == OSType(keyAELaunchedAsLogInItem)
    }

    static var mainWindows: [NSWindow] {
        NSApp.windows.filter { $0.identifier?.rawValue.contains("main") == true && $0.canBecomeMain }
    }

    /// Closes the launch window and hides the Dock icon. Monitoring keeps running from the menu bar.
    static func enter() {
        WindowPresence.shared.mainWindowOpen = false
        for window in mainWindows { window.close() }
        NSApp.setActivationPolicy(.accessory)
    }

    /// After the last MacSweep window closes, drop back to menu-bar-only instead of quitting.
    static func observeWindowClosing() {
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification, object: nil, queue: .main) { note in
            let closing = note.object as? NSWindow
            MainActor.assumeIsolated {
                guard let closing, closing.identifier?.rawValue.contains("main") == true else { return }
                let others = mainWindows.filter { $0 !== closing && $0.isVisible }
                if others.isEmpty {
                    NSApp.setActivationPolicy(.accessory)
                    WindowPresence.shared.mainWindowOpen = false
                }
            }
        }
        for name in [NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification, NSWindow.didChangeOcclusionStateNotification] {
            NotificationCenter.default.addObserver(forName: name, object: nil, queue: .main) { note in
                let window = note.object as? NSWindow
                MainActor.assumeIsolated {
                    guard let window, window.identifier?.rawValue.contains("main") == true, window.isVisible else { return }
                    WindowPresence.shared.mainWindowOpen = true
                }
            }
        }
    }
}

/// SwiftUI keeps a closed main window (and its whole view tree) alive offscreen, and re-lays it out whenever
/// observed state changes. While the window is closed its content is swapped for an empty view, so a hidden
/// MacSweep does no layout work at all. Reopening the window rebuilds the content from `AppModel`.
@MainActor
final class WindowPresence: ObservableObject {
    static let shared = WindowPresence()
    @Published var mainWindowOpen = true {
        didSet { if oldValue != mainWindowOpen { PerfLog.note("main-window open=\(mainWindowOpen)") } }
    }
}

/// Root of the main window: the real content while the window is open, nothing while it is closed.
struct MainWindowRoot<Content: View>: View {
    @ObservedObject var presence: WindowPresence = .shared
    @ViewBuilder var content: () -> Content

    var body: some View {
        if presence.mainWindowOpen {
            content()
        } else {
            Color.clear
        }
    }
}
