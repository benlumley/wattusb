import AppKit
import Carbon.HIToolbox
import SwiftUI

// The same keyboard shortcuts as Proton VPN Menu Bar: hold ⌘ in the panel to see its own, and record one that opens
// and closes the panel from any app.

struct Shortcut: Codable, Equatable {
    var keyCode: UInt16
    // NSEvent's device-independent modifier flags.
    var modifiers: UInt
    // The key's name, e.g. "W" or "Space".
    var key: String

    // Nil without ⌘, ⌥ or ⌃, since a key on its own (or with just ⇧) would get in the way of typing.
    init?(keyCode: UInt16, modifiers: NSEvent.ModifierFlags, characters: String?) {
        let flags = modifiers.intersection([.command, .option, .control, .shift])
        guard !flags.intersection([.command, .option, .control]).isEmpty else { return nil }
        let names: [UInt16: String] = [49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 123: "←", 124: "→", 125: "↓", 126: "↑"]
        guard let key = names[keyCode] ?? characters?.uppercased(), !key.isEmpty else { return nil }
        self.keyCode = keyCode
        self.modifiers = flags.rawValue
        self.key = key
    }

    var flags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    // In the usual order, e.g. ⌃⌥⌘W.
    var description: String {
        [(NSEvent.ModifierFlags.control, "⌃"), (.option, "⌥"), (.shift, "⇧"), (.command, "⌘")]
            .filter { flags.contains($0.0) }.map(\.1).joined() + key
    }

    // The modifiers as Carbon's hot key API wants them.
    var carbonModifiers: UInt32 {
        [(NSEvent.ModifierFlags.command, 256), (.shift, 512), (.option, 2048), (.control, 4096)]
            .filter { flags.contains($0.0) }.map(\.1).reduce(0, |)
    }
}

// The shortcut that opens and closes the panel from any app, if you've set one.
@MainActor final class Shortcuts: ObservableObject {
    @Published var panel: Shortcut? {
        didSet {
            UserDefaults.standard.set(try? JSONEncoder().encode(panel), forKey: "shortcut")
            register()
        }
    }

    init() {
        panel = UserDefaults.standard.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        register()
    }

    func register() {
        HotKey.shared.register(panel.map { [($0, togglePanel)] } ?? [])
    }
}

// Opens or closes the panel, as clicking the menu bar item does.
@MainActor func togglePanel() {
    NSApp.activate(ignoringOtherApps: true)
    statusButton()?.performClick(nil)
}

// The menu bar item's button, which SwiftUI's MenuBarExtra doesn't expose.
@MainActor private func statusButton() -> NSStatusBarButton? {
    func find(in view: NSView?) -> NSStatusBarButton? {
        guard let view else { return nil }
        if let button = view as? NSStatusBarButton { return button }
        return view.subviews.lazy.compactMap { find(in: $0) }.first
    }
    return NSApp.windows
        .filter { $0.className.contains("NSStatusBarWindow") }
        .lazy.compactMap { find(in: $0.contentView) }
        .first
}

// Shortcuts that work from any app, registered with macOS through Carbon, which needs no accessibility access.
@MainActor final class HotKey {
    static let shared = HotKey()
    private var hotKeys: [EventHotKeyRef] = []
    private var actions: [UInt32: () -> Void] = [:]
    private var handler: EventHandlerRef?

    // Registers these in place of any before.
    func register(_ shortcuts: [(Shortcut, () -> Void)]) {
        hotKeys.forEach { UnregisterEventHotKey($0) }
        hotKeys = []
        actions = [:]
        if handler == nil {
            var pressed = EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed))
            InstallEventHandler(GetApplicationEventTarget(), { _, event, _ in
                var id = EventHotKeyID()
                GetEventParameter(event, EventParamName(kEventParamDirectObject), EventParamType(typeEventHotKeyID), nil,
                                  MemoryLayout<EventHotKeyID>.size, nil, &id)
                DispatchQueue.main.async { MainActor.assumeIsolated { HotKey.shared.actions[id.id]?() } }
                return noErr
            }, 1, &pressed, nil, &handler)
        }
        for (index, (shortcut, action)) in shortcuts.enumerated() {
            let id = UInt32(index + 1)
            var hotKey: EventHotKeyRef?
            RegisterEventHotKey(UInt32(shortcut.keyCode), shortcut.carbonModifiers, EventHotKeyID(signature: 0x5741_5454, id: id),
                                GetApplicationEventTarget(), 0, &hotKey)
            if let hotKey {
                hotKeys.append(hotKey)
                actions[id] = action
            }
        }
    }
}

private var shortcutsWindow: NSWindow?

// Opens the Keyboard Shortcuts window, or brings it forward if it's open.
@MainActor func showShortcuts(_ shortcuts: Shortcuts) {
    if shortcutsWindow == nil {
        let content = NSHostingController(rootView: ShortcutsView(shortcuts: shortcuts))
        let window = NSWindow(contentViewController: content)
        window.title = "Keyboard Shortcuts"
        window.styleMask = [.titled, .closable]
        window.isReleasedWhenClosed = false
        // Its size first, so it's centered on the screen like About rather than by its corner.
        window.setContentSize(content.view.fittingSize)
        window.center()
        shortcutsWindow = window
    }
    NSApp.activate(ignoringOtherApps: true)
    shortcutsWindow?.makeKeyAndOrderFront(nil)
}

// The shortcut that works from any app, in a small window of its own like About.
struct ShortcutsView: View {
    @ObservedObject var shortcuts: Shortcuts

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Use this from any app, without opening the panel first.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            ShortcutRecorder(shortcuts: shortcuts, title: "Open or close wattusb", shortcut: $shortcuts.panel)
        }
        .padding(20)
        .frame(width: 320)
    }
}

// Records a shortcut: click, then press it; Esc cancels.
struct ShortcutRecorder: View {
    @ObservedObject var shortcuts: Shortcuts
    let title: String
    @Binding var shortcut: Shortcut?
    @State private var monitor: Any?
    // A key was pressed without ⌘, ⌥ or ⌃, which would get in the way of typing.
    @State private var needsModifier = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary).accessibilityHidden(true)
            HStack(spacing: 8) {
                Button {
                    monitor == nil ? record() : stop()
                } label: {
                    Text(monitor == nil ? shortcut?.description ?? "Click to record" : needsModifier ? "Add ⌘, ⌥ or ⌃" : "Press a shortcut…")
                        .font(.body.weight(.medium)).monospacedDigit()
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 8)
                        .background(RoundedRectangle(cornerRadius: 8).fill(monitor != nil ? Color.accentColor.opacity(0.25) : Color.primary.opacity(0.1)))
                        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(monitor != nil ? Color.accentColor : Color.primary.opacity(0.1)))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain).pointingHand()
                .accessibilityLabel("\(title): \(shortcut?.description ?? "none")")
                .accessibilityHint("Records a new shortcut")
                if shortcut != nil, monitor == nil {
                    Button("Clear") { shortcut = nil }
                        .buttonStyle(.plain).pointingHand()
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Clear \(title.lowercased()) shortcut")
                }
            }
        }
        .onDisappear(perform: stop)
    }

    func record() {
        // The current one would otherwise do its thing when pressed to be recorded.
        HotKey.shared.register([])
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 {
                stop()
            } else if let recorded = Shortcut(keyCode: event.keyCode, modifiers: event.modifierFlags,
                                               characters: event.charactersIgnoringModifiers) {
                stop()
                shortcut = recorded
            } else {
                needsModifier = true
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        needsModifier = false
        shortcuts.register()
    }
}

// Whether to show the panel's shortcuts on its buttons, while ⌘ is held.
private struct ShortcutHintsKey: EnvironmentKey {
    static let defaultValue = false
}

extension EnvironmentValues {
    var shortcutHints: Bool {
        get { self[ShortcutHintsKey.self] }
        set { self[ShortcutHintsKey.self] = newValue }
    }
}

extension View {
    // A button's shortcut, e.g. "Q" for ⌘Q, shown on it while ⌘ is held.
    func shortcutHint(_ key: String?) -> some View { modifier(ShortcutHint(key: key)) }
}

struct ShortcutHint: ViewModifier {
    let key: String?
    @Environment(\.shortcutHints) private var visible

    func body(content: Content) -> some View {
        content.overlay(alignment: .topTrailing) {
            if let key, visible {
                Text("⌘\(key)")
                    .font(.system(size: 9, weight: .semibold))
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .foregroundStyle(.primary)
                    .background(.regularMaterial, in: Capsule())
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(0.2), lineWidth: 0.5))
                    .shadow(color: .black.opacity(0.25), radius: 2, y: 1)
                    // Its own size, not squeezed to the power button's.
                    .fixedSize()
                    .offset(x: 4, y: -5)
                    .accessibilityHidden(true)
            }
        }
    }
}
