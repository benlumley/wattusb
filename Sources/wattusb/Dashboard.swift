import AppKit
import Charts
import SwiftUI

// One slice of where the power goes: into the battery, the Mac itself, or something charging off a port.
struct Part {
    let name: String
    let watts: Double
    let color: Color
    let help: String
}

extension Reading {
    var parts: [Part] {
        let total = max(plugged ? drawWatts : dischargeWatts, 0.1)
        let toBattery = plugged ? min(chargeWatts, total) : 0
        let scale = deviceWatts > 0 ? min(1, (total - toBattery) / deviceWatts) : 0
        let deviceColors: [Color] = [.purple, .pink, .teal]
        let toDevices = devices.map { d in
            Part(name: "Port \(d.port)", watts: d.watts * scale, color: deviceColors[max(0, d.port - 1) % deviceColors.count],
                 help: String(format: "Something on port %d is drawing %.1fV · %.2fA", d.port, d.volts, d.amps))
        }
        let toMac = total - toBattery - toDevices.reduce(0) { $0 + $1.watts }
        return [Part(name: "Mac", watts: toMac, color: .blue, help: "What the Mac itself is using")]
            + (plugged ? [Part(name: "Battery", watts: toBattery, color: .green, help: "Charging the battery")] : [])
            + toDevices
    }
}

struct Sample: Identifiable {
    let id = UUID()
    let date: Date
    let parts: [Part]
    let input: Double?    // charger watts, when plugged

    func watts(_ name: String) -> Double? { parts.first { $0.name == name }?.watts }
}

@MainActor
final class Monitor: ObservableObject {
    @Published var reading: Reading?
    @Published var history: [Sample] = []
    let window: TimeInterval = 5 * 60

    func update(_ r: Reading?) {
        reading = r
        guard let r else { return }
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

    var color: Color {
        switch self {
        case .light: .green
        case .moderate: Color(nsColor: NSColor(name: nil) { $0.name == .darkAqua ? .systemYellow : NSColor(red: 0.8, green: 0.6, blue: 0, alpha: 1) })
        case .heavy: .orange
        case .veryHeavy: .red
        }
    }
}

struct Dashboard: View {
    @ObservedObject var monitor: Monitor

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if let r = monitor.reading {
                header(r)
                chart(r)
            } else {
                Text("No battery data").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(width: 320)
    }

    private func header(_ r: Reading) -> some View {
        let load = Load(r.usageWatts)
        let watts = r.headlineWatts
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: r.plugged ? (r.charging ? "bolt.fill" : "powerplug.fill") : "battery.75percent")
                    .frame(width: 16)
                header(state: r).help(batteryDetails(r))
                Spacer()
                Text(load.label)
                    .font(.caption.weight(.semibold))
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(load.color.opacity(0.2), in: Capsule())
                    .foregroundStyle(load.color)
            }
            .font(.subheadline.weight(.medium))
            .foregroundStyle(.secondary)
            HStack(alignment: .lastTextBaseline) {
                (Text("\(Int(watts.rounded()))")
                    .font(.system(size: 40, weight: .semibold, design: .rounded))
                    + Text("W")
                    .font(.system(size: 20, weight: .medium, design: .rounded))
                    .foregroundStyle(.secondary))
                    .monospacedDigit()
                Spacer()
                // Reads on from the big number: "44W from 60W charger", "13W from battery".
                Group {
                    if r.connecting {
                        label("Mac usage")
                    } else if r.plugged {
                        let headroom = r.adapterWatts > 0 ? r.drawWatts / Double(r.adapterWatts) : 0
                        label("from ") + value("\(r.adapterWatts)W", color: headroom > 0.9 ? .orange : .primary) + label(" charger")
                    } else {
                        label("from battery")
                    }
                }
                .font(.caption)
            }
            .help(breakdown(r))
            // The big number's descender space leaves too much of a gap above the chart.
            .padding(.bottom, -2)
        }
    }

    // Always the battery level first; the icon already says whether it's charging or on battery.
    private func header(state r: Reading) -> Text {
        let percent = label("Battery ") + value("\(r.batteryPercent)%")
        let minutes = r.timeToFullMinutes > 0 && r.timeToFullMinutes < 60 * 24 ? r.timeToFullMinutes : 0
        if !r.plugged {
            return minutes > 0 ? percent + label(" · ") + value(formatTime(minutes)) + label(" left") : percent
        }
        if r.connecting { return percent + label(" · connecting…") }
        if r.charging {
            return minutes > 0 ? percent + label(" · ") + value(formatTime(minutes)) + label(" to full") : percent
        }
        return percent + label(r.fullyCharged ? " · charged" : " · not charging")
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
        let now = r.parts
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
            }
            .chartXAxis(.hidden)
            .chartYScale(domain: 0...top)
            .chartYAxis {
                AxisMarks(position: .trailing, values: .automatic(desiredCount: 3)) { value in
                    AxisGridLine().foregroundStyle(.quaternary)
                    AxisValueLabel { if let w = value.as(Double.self), w > 0 { Text("\(Int(w))W") } }
                }
            }
            .frame(height: 70)
            let items: [AnyView] = [AnyView(swatch(.blue, "Mac", now.first?.watts ?? 0)
                .help("What the Mac itself is using, peaking at \(Int(peak.rounded()))W in the last 5 minutes"))]
                + others.map { part in
                    let current = now.first { $0.name == part.name }
                    return AnyView(swatch(part.color, part.name, current?.watts ?? 0).help(current?.help ?? part.help))
                }
            HStack(spacing: 10) {
                ForEach(items.indices, id: \.self) { items[$0].fixedSize() }
            }
            .font(.caption)
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

    // Everything the original menu showed, for the big number's tooltip.
    private func breakdown(_ r: Reading) -> String {
        var lines: [String] = []
        if r.plugged && !r.connecting {
            lines.append(String(format: "In: %.0fW (%.1fV · %.2fA), the dashed line", r.drawWatts, r.voltsIn, r.ampsIn))
            lines.append(String(format: "Charger: %dW max (%.0fV · %.0fA PD)", r.adapterWatts, r.adapterVolts, r.adapterAmps))
        } else if !r.plugged {
            lines.append(String(format: "Drawing %.0fW from the battery", r.dischargeWatts))
        }
        for part in r.parts {
            lines.append(String(format: "To %@: %.0fW", part.name == "Mac" ? "Mac" : part.name.lowercased(), part.watts))
        }
        return lines.joined(separator: "\n")
    }

    // Health, cycles and temperature change over months, not minutes, so they live in the battery line's tooltip.
    private func batteryDetails(_ r: Reading) -> String {
        String(format: "Health %d%%: holds that much of the charge it did when new (macOS recommends service below 80%%)\n"
                   + "%d of the %d charge cycles it's rated for\n%.0f°C", r.healthPercent, r.cycles, r.designCycles, r.temperature)
    }
}
