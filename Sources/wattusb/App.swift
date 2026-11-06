import AppKit
import ServiceManagement
import SwiftUI

@MainActor
final class LoginItem: ObservableObject {
    @Published var enabled = SMAppService.mainApp.status == .enabled

    // Opens at login by default, the first time the app runs, so turning it off sticks.
    func registerOnce() {
        guard !UserDefaults.standard.bool(forKey: "loginItemRegistered") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemRegistered")
        try? SMAppService.mainApp.register()
        enabled = SMAppService.mainApp.status == .enabled
    }

    func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
        enabled = SMAppService.mainApp.status == .enabled
    }
}

@MainActor
func showAbout() {
    let credits = NSMutableAttributedString(string: "Shows the live wattage your Mac is drawing, from its charger or its battery.\n\n")
    credits.append(NSAttributedString(string: "Fork on GitHub", attributes: [.link: URL(string: "https://github.com/benlumley/wattusb")!]))
    credits.append(NSAttributedString(string: "  ·  "))
    credits.append(NSAttributedString(string: "Made with ⚡ by Ben", attributes: [.link: URL(string: "https://www.interokedigital.co.uk")!]))
    let style = NSMutableParagraphStyle()
    style.alignment = .center
    credits.addAttributes([.font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize), .paragraphStyle: style,
                           .foregroundColor: NSColor.secondaryLabelColor],
                          range: NSRange(location: 0, length: credits.length))
    NSApp.activate(ignoringOtherApps: true)
    // An empty build number keeps the panel from adding "(1)" after the version.
    NSApp.orderFrontStandardAboutPanel(options: [.credits: credits, .version: ""])
}

// A window-style menu bar extra, like a panel, so the dashboard's gear can open a real menu of its own.
@main
struct WattUSB: App {
    @StateObject private var monitor = Monitor()
    @StateObject private var login = LoginItem()
    @StateObject private var shortcuts = Shortcuts()

    var body: some Scene {
        MenuBarExtra {
            Dashboard(monitor: monitor, login: login, shortcuts: shortcuts)
        } label: {
            MenuBarLabel(title: monitor.title)
                .onAppear {
                    login.registerOnce()
                    // Touches the shortcuts so the panel's is registered at launch, not when the panel first opens.
                    shortcuts.register()
                    closePanelWhenInactive()
                }
        }
        .menuBarExtraStyle(.window)
    }
}

// Watches just the title, so the menu bar updates while the panel is closed.
private struct MenuBarLabel: View {
    @ObservedObject var title: MenuBarTitle

    var body: some View {
        Image(nsImage: title.image)
    }
}

// Opens or closes the panel, as clicking the menu bar item does.
@MainActor func togglePanel() {
    NSApp.activate(ignoringOtherApps: true)
    statusButton()?.performClick(nil)
}

// Closes the panel, by clicking the menu bar item as you would, since closing the window itself leaves the item
// highlighted.
@MainActor func closePanel() {
    statusButton()?.performClick(nil)
}

// Closes the panel when another app comes to the front, e.g. one whose own panel was opened with a shortcut.
// A click elsewhere closes it, but switching apps from the keyboard doesn't.
private var inactiveObserver: Any?

@MainActor func closePanelWhenInactive() {
    guard inactiveObserver == nil else { return }
    inactiveObserver = NotificationCenter.default.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { _ in
        MainActor.assumeIsolated {
            if NSApp.windows.contains(where: { $0.className.contains("MenuBarExtraWindow") && $0.isVisible }) {
                closePanel()
            }
        }
    }
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
