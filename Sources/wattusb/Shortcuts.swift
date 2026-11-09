import AppKit

// The same keyboard shortcuts as Proton VPN Menu Bar: hold ⌘ in the panel to see its own, and record one that opens
// and closes the panel from any app. The window and recorder are in ShortcutsView.swift.

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
    private let defaults: UserDefaults

    @Published var panel: Shortcut? {
        didSet {
            defaults.set(try? JSONEncoder().encode(panel), forKey: "shortcut")
            register()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        panel = defaults.data(forKey: "shortcut").flatMap { try? JSONDecoder().decode(Shortcut.self, from: $0) }
        register()
    }

    func register() {
        HotKey.shared.register(panel.map { [($0, togglePanel)] } ?? [])
    }
}
