import AppKit
import Foundation
import Testing
@testable import wattusb

@MainActor struct ShortcutsTests {
    @Test func needsCommandOptionOrControl() {
        #expect(Shortcut(keyCode: 13, modifiers: [], characters: "w") == nil)
        #expect(Shortcut(keyCode: 13, modifiers: .shift, characters: "w") == nil)
        #expect(Shortcut(keyCode: 13, modifiers: [.command, .capsLock], characters: "w")?.flags == .command)
    }

    @Test func namesKeysWithoutCharacters() {
        #expect(Shortcut(keyCode: 49, modifiers: .option, characters: " ")?.key == "Space")
        #expect(Shortcut(keyCode: 126, modifiers: .control, characters: nil)?.key == "↑")
        #expect(Shortcut(keyCode: 99, modifiers: .control, characters: nil) == nil)
        #expect(Shortcut(keyCode: 99, modifiers: .control, characters: "") == nil)
    }

    @Test func describesModifiersInTheUsualOrder() {
        let s = Shortcut(keyCode: 13, modifiers: [.command, .shift, .option, .control], characters: "w")!
        #expect(s.description == "⌃⌥⇧⌘W")
        #expect(s.carbonModifiers == 256 | 512 | 2048 | 4096)
        #expect(Shortcut(keyCode: 13, modifiers: .command, characters: "w")!.carbonModifiers == 256)
    }

    @Test func remembersThePanelShortcut() throws {
        let defaults = try #require(UserDefaults(suiteName: "wattusb-tests-\(UUID().uuidString)"))
        #expect(Shortcuts(defaults: defaults).panel == nil)
        let shortcut = Shortcut(keyCode: 13, modifiers: [.command, .option], characters: "w")
        Shortcuts(defaults: defaults).panel = shortcut
        let reloaded = Shortcuts(defaults: defaults)
        #expect(reloaded.panel == shortcut)
        reloaded.panel = nil
        #expect(Shortcuts(defaults: defaults).panel == nil)
    }
}
