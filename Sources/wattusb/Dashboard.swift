import AppKit
import Charts
import SwiftUI

struct Dashboard: View {
    @ObservedObject var monitor: Monitor
    @ObservedObject var login: LoginItem
    @ObservedObject var shortcuts: Shortcuts
    @State private var showHints = false
    @State private var flagsMonitor: Any?
    @State private var keyMonitor: Any?
    // The time under the pointer on the chart, whose sample the numbers show instead of the live ones.
    @State private var hovered: Date?

    private var hoveredSample: Sample? {
        guard let hovered else { return nil }
        return monitor.history.min { abs($0.date.timeIntervalSince(hovered)) < abs($1.date.timeIntervalSince(hovered)) }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = monitor.reading {
                header(r)
                chart(r)
            } else {
                Text("No battery data").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .frame(width: 320)
        // The material real menus use, like other menu bar apps' panels.
        .background(MenuMaterial().ignoresSafeArea())
        .environment(\.shortcutHints, showHints)
        .onAppear {
            monitor.panelOpen = true
            // Esc closes it, like a menu.
            keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
                guard event.keyCode == 53, NSApp.keyWindow?.className.contains("MenuBarExtraWindow") == true else { return event }
                closePanel()
                return nil
            }
            // Holding ⌘ on its own shows the shortcuts.
            flagsMonitor = NSEvent.addLocalMonitorForEvents(matching: .flagsChanged) { event in
                showHints = event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command
                return event
            }
            // Nothing starts focused, like Proton's panel, rather than the gear keeping its ring from last time.
            DispatchQueue.main.async { NSApp.keyWindow?.makeFirstResponder(nil) }
        }
        .onDisappear {
            monitor.panelOpen = false
            for monitor in [keyMonitor, flagsMonitor].compactMap({ $0 }) { NSEvent.removeMonitor(monitor) }
            keyMonitor = nil
            flagsMonitor = nil
            showHints = false
        }
    }

    private func header(_ r: Reading) -> some View {
        let sample = hoveredSample
        let load = Load(sample?.watts("Mac") ?? r.usageWatts)
        let watts = sample.map { $0.input ?? $0.parts.reduce(0) { $0 + $1.watts } } ?? monitor.headlineWatts
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: r.plugged ? (r.charging ? "bolt.fill" : "powerplug.fill") : "battery.75percent")
                    .foregroundStyle(.secondary)
                header(state: r).help(r.details)
                Spacer(minLength: 8)
                // Sized and spaced like Proton VPN Menu Bar's.
                HStack(spacing: 10) {
                    Menu {
                        Toggle("Open at Login", isOn: Binding(get: { login.enabled }, set: { login.set($0) }))
                        Button("Keyboard Shortcuts…") { showShortcuts(shortcuts) }
                        Divider()
                        Button("About wattusb") { showAbout() }
                    } label: {
                        Image(systemName: "gearshape")
                    }
                    .menuStyle(.button)
                    .buttonStyle(.plain).pointingHand()
                    .menuIndicator(.hidden)
                    .fixedSize()
                    .help("Settings")
                    Button { NSApp.terminate(nil) } label: { Image(systemName: "power") }
                        .buttonStyle(.plain).pointingHand()
                        .keyboardShortcut("q")
                        .shortcutHint("Q")
                        .help("Quit (⌘Q)")
                }
                .font(.system(size: 14))
                .foregroundStyle(.secondary)
            }
            .font(.body)
            .frame(height: 24)
            // "Moderate load" drops to "Moderate" when the charger's wattage needs the room.
            ViewThatFits(in: .horizontal) {
                numberRow(r, watts: watts, load: load, pill: load.label, at: sample?.date)
                numberRow(r, watts: watts, load: load, pill: load.shortLabel, at: sample?.date)
            }
            .help(r.breakdown)
            // The big number's descender space leaves too much of a gap above the chart.
            .padding(.bottom, -2)
        }
    }

    private func numberRow(_ r: Reading, watts: Double, load: Load, pill: String, at date: Date?) -> some View {
        HStack(alignment: .lastTextBaseline) {
            (Text("\(Int(watts.rounded()))")
                .font(.system(size: 40, weight: .semibold, design: .rounded))
                + Text("W")
                .font(.system(size: 20, weight: .medium, design: .rounded))
                .foregroundStyle(.secondary))
                .monospacedDigit()
            Text(pill)
                .font(.callout.weight(.semibold))
                .padding(.horizontal, 8)
                .padding(.vertical, 3)
                .background(load.color.opacity(0.2), in: Capsule())
                .foregroundStyle(load.color)
                .fixedSize()
                .alignmentGuide(.lastTextBaseline) { $0[.bottom] - 4 }
            Spacer(minLength: 8)
            // Reads on from the big number: "44W of 60W charger", "13W from battery".
            Group {
                if let date {
                    value(formatAgo(Date().timeIntervalSince(date))) + label(" ago")
                } else if r.connecting {
                    label("Mac usage")
                } else if r.plugged {
                    let headroom = r.adapterWatts > 0 ? r.drawWatts / Double(r.adapterWatts) : 0
                    label("of ") + value("\(r.adapterWatts)W", color: headroom > 0.9 ? .orange : .primary) + label(" charger")
                } else {
                    label("from battery")
                }
            }
            .font(.callout)
            .fixedSize()
        }
    }

    // Always the battery level first; the icon already says whether it's charging or on battery.
    private func header(state r: Reading) -> Text {
        if r.plugged && r.fullyCharged { return label("Battery ") + value("full") + label(" · on charger") }
        let percent = label("Battery ") + value("\(r.batteryPercent)%")
        let minutes = r.timeToFullMinutes > 0 && r.timeToFullMinutes < 60 * 24 ? r.timeToFullMinutes : 0
        if !r.plugged {
            return minutes > 0 ? percent + label(" · ") + value(formatTime(minutes)) + label(" left") : percent
        }
        if r.connecting { return percent + label(" · connecting…") }
        if r.charging {
            return minutes > 0 ? percent + label(" · ") + value(formatTime(minutes)) + label(" to full") : percent
        }
        // Plugged in but held below full, usually by Optimized Battery Charging.
        return percent + label(" · on hold")
    }

    private func chart(_ r: Reading) -> some View {
        let peak = monitor.history.compactMap { $0.watts("Mac") }.max() ?? 0
        let top = max(10, (monitor.history.map { max($0.watts("Mac") ?? 0, $0.input ?? 0) }.max() ?? 0) * 1.2)
        // The battery and each device seen during the window get their own line, in the order of Reading.parts.
        var others: [Part] = []
        for s in monitor.history { for p in s.parts where p.name != "Mac" && !others.contains(where: { $0.name == p.name }) { others.append(p) } }
        others.sort { ($0.name == "Battery" ? "" : $0.name) < ($1.name == "Battery" ? "" : $1.name) }
        // Skip anything that's sat at 0W the whole time, like the battery when it's full.
        others.removeAll { p in monitor.history.allSatisfy { ($0.watts(p.name) ?? 0) < 0.5 } }
        let now = hoveredSample?.parts ?? r.parts
        return VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(monitor.history) { s in
                    if let mac = s.watts("Mac") {
                        AreaMark(x: .value("Time", s.date), y: .value("Mac", mac))
                            .foregroundStyle(LinearGradient(colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.02)],
                                                            startPoint: .top, endPoint: .bottom))
                            .interpolationMethod(.monotone)
                        LineMark(x: .value("Time", s.date), y: .value("Mac", mac), series: .value("Series", "Mac"))
                            .foregroundStyle(Color.blue)
                            .lineStyle(StrokeStyle(lineWidth: 2))
                            .interpolationMethod(.monotone)
                    }
                    ForEach(others, id: \.name) { part in
                        LineMark(x: .value("Time", s.date), y: .value(part.name, s.watts(part.name) ?? 0), series: .value("Series", part.name))
                            .foregroundStyle(part.color)
                            .lineStyle(StrokeStyle(lineWidth: 1.5))
                            .interpolationMethod(.monotone)
                    }
                    if let input = s.input {
                        LineMark(x: .value("Time", s.date), y: .value("In", input), series: .value("Series", "In"))
                            .foregroundStyle(Color.gray)
                            .lineStyle(StrokeStyle(lineWidth: 1, dash: [3, 3]))
                            .interpolationMethod(.monotone)
                    }
                }
                if let s = hoveredSample {
                    RuleMark(x: .value("Time", s.date)).foregroundStyle(Color.secondary.opacity(0.6)).lineStyle(StrokeStyle(lineWidth: 1))
                }
            }
            .chartOverlay { proxy in
                GeometryReader { geo in
                    Rectangle().fill(.clear).contentShape(Rectangle())
                        .onContinuousHover { phase in
                            switch phase {
                            case .active(let point):
                                guard let plot = proxy.plotFrame else { return }
                                hovered = proxy.value(atX: point.x - geo[plot].origin.x, as: Date.self)
                            case .ended:
                                hovered = nil
                            }
                        }
                }
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: 0...top)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let w = value.as(Double.self), w > 0 { Text("\(Int(w))W") } }
                }
            }
            .frame(height: 100)
            let items: [AnyView] = [AnyView(swatch(.blue, "Mac", now.first?.watts ?? 0)
                .help("Peak \(Int(peak.rounded()))W"))]
                + others.map { part in
                    let current = now.first { $0.name == part.name }
                    return AnyView(swatch(part.color, part.name, current?.watts ?? 0).help(current?.help ?? part.help))
                }
            // One row, or two when there are too many devices to fit.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) {
                    ForEach(items.indices, id: \.self) { items[$0].fixedSize() }
                }
                VStack(alignment: .leading, spacing: 4) {
                    let half = (items.count + 1) / 2
                    HStack(spacing: 10) { ForEach(0..<half, id: \.self) { items[$0].fixedSize() } }
                    HStack(spacing: 10) { ForEach(half..<items.count, id: \.self) { items[$0].fixedSize() } }
                }
            }
            .font(.callout)
        }
    }

    private func swatch(_ color: Color, _ title: String, _ watts: Double?, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            // A ring for the dashed charger line, a dot for the rest.
            if dashed {
                Circle().strokeBorder(color, lineWidth: 1.5).frame(width: 7, height: 7)
            } else {
                Circle().fill(color).frame(width: 7, height: 7)
            }
            label(title) + (watts.map { value(" \(Int($0.rounded()))W") } ?? Text(""))
        }
    }

    // Every number is a value, in the primary color; every word around it is a label, in gray.
    private func value(_ s: String, color: Color = .primary) -> Text {
        Text(s).fontWeight(.medium).foregroundColor(color).monospacedDigit()
    }

    private func label(_ s: String) -> Text {
        Text(s).foregroundColor(.secondary)
    }

}

// Behind-window blur with the menu material, which is darker than a MenuBarExtra window's own.
struct MenuMaterial: NSViewRepresentable {
    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = .menu
        view.blendingMode = .behindWindow
        view.state = .active
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) {}
}

extension View {
    // A pointing hand over anything clickable, as on a web page.
    @ViewBuilder func pointingHand() -> some View {
        if #available(macOS 15, *) {
            pointerStyle(.link)
        } else {
            onHover { inside in inside ? NSCursor.pointingHand.push() : NSCursor.pop() }
        }
    }
}
