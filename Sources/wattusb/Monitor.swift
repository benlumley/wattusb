import AppKit
import SwiftUI

// The menu bar title, drawn as an image since MenuBarExtra ignores fonts on its label. menuBarFont at 11pt lines up
// with Control Center's battery percentage.
func statusImage(_ text: String, symbol: String?) -> NSImage {
    let title = NSAttributedString(string: text, attributes: [.font: NSFont.menuBarFont(ofSize: 11), .foregroundColor: NSColor.black])
    let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
    let icon = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config) }
    let iconWidth = icon.map { $0.size.width + 2 } ?? 0
    let titleSize = title.size()
    let image = NSImage(size: NSSize(width: ceil(iconWidth + titleSize.width), height: ceil(titleSize.height)), flipped: false) { rect in
        if let icon {
            icon.draw(in: NSRect(x: 0, y: (rect.height - icon.size.height) / 2, width: icon.size.width, height: icon.size.height))
        }
        title.draw(at: NSPoint(x: iconWidth, y: 0))
        return true
    }
    image.isTemplate = true
    return image
}

// A reading's split, every 2 seconds, so its time is its identity on the chart.
struct Sample: Identifiable {
    let date: Date
    let parts: [Part]
    let input: Double?    // charger watts, when plugged

    var id: Date { date }

    func watts(_ name: String) -> Double? { parts.first { $0.name == name }?.watts }
}

// The menu bar title, apart from the Monitor so it can update without redrawing the panel.
@MainActor
final class MenuBarTitle: ObservableObject {
    @Published private(set) var image = statusImage("—", symbol: nil)
    private var shown = "—"

    // Only redraws the menu bar when the title changes, not on every reading.
    func show(_ text: String, symbol: String?) {
        let title = text + (symbol ?? "")
        guard title != shown else { return }
        shown = title
        image = statusImage(text, symbol: symbol)
    }
}

@MainActor
final class Monitor: ObservableObject {
    // Not @Published: the panel only redraws while it's open, since once opened, SwiftUI keeps laying out its chart
    // behind the scenes every 2 seconds.
    var reading: Reading?
    var history: [Sample] = []
    var panelOpen = false {
        didSet { if panelOpen && !oldValue { objectWillChange.send() } }
    }
    let title = MenuBarTitle()
    let window: TimeInterval = 5 * 60
    private var timer: Timer?
    private var lastWatts: Double = 0

    // Just after unplugging, macOS reports no battery draw for a few seconds, so keep showing the last figure
    // rather than 0W.
    var headlineWatts: Double {
        guard let r = reading else { return 0 }
        return !r.plugged && r.headlineWatts == 0 ? lastWatts : r.headlineWatts
    }

    init(every interval: TimeInterval = 2, read: @escaping () -> Reading? = { readBattery() }) {
        update(read())
        // .common so it keeps updating while the panel is open. Timers fire on the main thread; a Task would wait
        // until it closes.
        let timer = Timer(timeInterval: interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.update(read()) }
        }
        // Lets macOS fire it alongside other wakeups, which saves more energy than the half second costs.
        timer.tolerance = interval / 4
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    private var titleParts: (text: String, symbol: String?) {
        guard let r = reading else { return ("—", nil) }
        return ("\(Int(headlineWatts.rounded()))W", r.plugged ? (r.charging ? "bolt.fill" : "powerplug.fill") : nil)
    }

    var statusImage: NSImage { wattusb.statusImage(titleParts.text, symbol: titleParts.symbol) }

    func update(_ r: Reading?) {
        if panelOpen { objectWillChange.send() }
        reading = r
        defer { title.show(titleParts.text, symbol: titleParts.symbol) }
        guard let r else { return }
        if r.headlineWatts > 0 { lastWatts = r.connecting ? r.usageWatts : r.plugged ? r.usageWatts + r.deviceWatts : r.headlineWatts }
        let now = Date()
        history.append(Sample(date: now, parts: r.connecting ? [] : r.parts, input: r.plugged && !r.connecting ? r.drawWatts : nil))
        history.removeAll { now.timeIntervalSince($0.date) > window }
    }
}

enum Load {
    case light, moderate, heavy, veryHeavy

    init(_ watts: Double) {
        switch watts {
        case ..<8: self = .light
        case ..<20: self = .moderate
        case ..<35: self = .heavy
        default: self = .veryHeavy
        }
    }

    var label: String {
        switch self {
        case .light: "Light load"
        case .moderate: "Moderate load"
        case .heavy: "Heavy load"
        case .veryHeavy: "Very heavy load"
        }
    }

    var shortLabel: String { String(label.dropLast(" load".count)) }

    var color: Color {
        switch self {
        case .light: .green
        case .moderate: Color(nsColor: NSColor(name: nil) { $0.name == .darkAqua ? .systemYellow : NSColor(red: 0.8, green: 0.6, blue: 0, alpha: 1) })
        case .heavy: .orange
        case .veryHeavy: .red
        }
    }
}
