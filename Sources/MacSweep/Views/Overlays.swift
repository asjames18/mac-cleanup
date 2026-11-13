import AppKit
import SwiftUI

struct Toast: Equatable, Identifiable, Sendable {
    enum Kind: Sendable { case info, ok, warn, danger }
    let id = UUID()
    var text: String
    var kind: Kind = .info

    var color: Color {
        switch kind {
        case .info: Theme.info
        case .ok: Theme.ok
        case .warn: Theme.warn
        case .danger: Theme.danger
        }
    }

    var icon: String {
        switch kind {
        case .info: "info.circle.fill"
        case .ok: "checkmark.circle.fill"
        case .warn: "exclamationmark.triangle.fill"
        case .danger: "xmark.octagon.fill"
        }
    }
}

struct ToastView: View {
    let toast: Toast
    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: toast.icon).foregroundStyle(toast.color)
            Text(toast.text).foregroundStyle(Theme.text).font(.callout).lineLimit(3)
        }
        .padding(.horizontal, 16).padding(.vertical, 11)
        .background(Theme.panel2, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(toast.color.opacity(0.45), lineWidth: 1))
        .shadow(color: .black.opacity(0.35), radius: 14, y: 6)
        .frame(maxWidth: 520)
        .accessibilityElement(children: .combine)
    }
}

enum KeyAction: Equatable {
    case section(MainViewMode)
    case toggleShortcuts
    case closeOverlay
    case trashSelection
}

/// Plain keys work only when no text field is being edited.
enum KeyMap {
    static let entries: [(keys: String, action: String)] = [
        ("1 – 6", "Switch section (Overview … History)"),
        ("⌘R", "Start Smart Scan"),
        ("⇧⌘R", "Scan applications"),
        ("⌘.", "Cancel the running scan"),
        ("⌘O", "Add a folder to scan"),
        ("Delete", "Move selected Smart Scan items to Trash (asks first)"),
        ("⌘,", "Settings: test sandbox, AI and exclusions"),
        ("?", "Show or hide these shortcuts"),
        ("Esc", "Close this overlay"),
    ]

    static func action(characters: String?, keyCode: UInt16, modifiers: NSEvent.ModifierFlags,
                       typing: Bool, overlayShown: Bool) -> KeyAction? {
        if keyCode == 53 { return overlayShown ? .closeOverlay : nil } // Esc
        if typing { return nil }
        guard modifiers.intersection([.command, .control, .option]).isEmpty else { return nil }
        if characters == "?" { return .toggleShortcuts }
        if overlayShown { return nil }
        if keyCode == 51 || keyCode == 117 { return .trashSelection } // Delete, forward delete
        if let characters, characters.count == 1, let digit = Int(characters), digit >= 1,
           digit <= MainViewMode.allCases.count {
            return .section(MainViewMode.allCases[digit - 1])
        }
        return nil
    }
}

struct ShortcutOverlay: View {
    var onClose: () -> Void
    var body: some View {
        ZStack {
            Color.black.opacity(0.5).ignoresSafeArea().onTapGesture(perform: onClose)
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    Text("Keyboard shortcuts").font(.title3.weight(.semibold)).foregroundStyle(Theme.text)
                    Spacer()
                    Button(action: onClose) { Image(systemName: "xmark") }.buttonStyle(.plain).foregroundStyle(Theme.muted)
                }
                ForEach(KeyMap.entries, id: \.keys) { entry in
                    HStack {
                        Kbd(text: entry.keys).frame(width: 82, alignment: .leading)
                        Text(entry.action).foregroundStyle(Theme.muted).font(.callout)
                        Spacer(minLength: 0)
                    }
                }
                Text("Number keys and Delete are ignored while you type in a search field.")
                    .font(.caption).foregroundStyle(Theme.muted)
            }
            .padding(24).frame(width: 470)
            .background(Theme.panel, in: RoundedRectangle(cornerRadius: Theme.radius, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: Theme.radius, style: .continuous).stroke(Theme.line, lineWidth: 1))
        }
    }
}

/// Holds the hosting window so key handling only applies to the main window.
final class WindowRef {
    weak var window: NSWindow?
}

struct WindowReader: NSViewRepresentable {
    let ref: WindowRef
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { [weak view] in ref.window = view?.window }
        return view
    }
    func updateNSView(_ nsView: NSView, context: Context) {
        if ref.window == nil { DispatchQueue.main.async { [weak nsView] in ref.window = nsView?.window } }
    }
}
