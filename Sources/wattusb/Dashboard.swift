import AppKit
import Charts
import SwiftUI

struct Sample: Identifiable {
    let id = UUID()
    let date: Date
    let usage: Double
    let input: Double?    // charger watts, when plugged
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
        history.append(Sample(date: now, usage: r.usageWatts, input: r.plugged && !r.connecting ? r.drawWatts : nil))
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
                if r.plugged && !r.connecting { split(r) }
                battery(r)
            } else {
                Text("No battery data").foregroundStyle(.secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.top, 6)
        .padding(.bottom, 4)
        .frame(width: 300)
    }

    private func header(_ r: Reading) -> some View {
        let load = Load(r.usageWatts)
        let watts = r.headlineWatts
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: r.plugged ? (r.charging ? "bolt.fill" : "powerplug.fill") : "battery.75percent")
                    .frame(width: 16)
                Text(state(r))
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
                VStack(alignment: .trailing, spacing: 2) {
                    if r.connecting {
                        Text("Mac usage").foregroundStyle(.secondary)
                    } else if r.plugged {
                        let headroom = r.adapterWatts > 0 ? r.drawWatts / Double(r.adapterWatts) : 0
                        value("\(r.adapterWatts)W", color: headroom > 0.9 ? .orange : .primary) + label(" charger")
                        value(String(format: "%.1fV", r.voltsIn)) + label(" · ") + value(String(format: "%.2fA", r.ampsIn))
                    } else {
                        Text("from battery").foregroundStyle(.secondary)
                    }
                }
                .font(.caption)
                .monospacedDigit()
            }
            // The big number's descender space leaves too much of a gap above the chart.
            .padding(.bottom, -2)
        }
    }

    private func state(_ r: Reading) -> String {
        if !r.plugged { return "On battery" }
        if r.connecting { return "Connecting to charger…" }
        if r.charging { return "Charging" }
        return r.fullyCharged ? "Fully charged" : "Plugged in, not charging"
    }

    private func chart(_ r: Reading) -> some View {
        let peak = monitor.history.map(\.usage).max() ?? 0
        let top = max(10, (monitor.history.map { max($0.usage, $0.input ?? 0) }.max() ?? 0) * 1.2)
        return VStack(alignment: .leading, spacing: 6) {
            Chart {
                ForEach(monitor.history) { s in
                    AreaMark(x: .value("Time", s.date), y: .value("Usage", s.usage))
                        .foregroundStyle(LinearGradient(colors: [Color.blue.opacity(0.35), Color.blue.opacity(0.02)],
                                                        startPoint: .top, endPoint: .bottom))
                        .interpolationMethod(.monotone)
                    LineMark(x: .value("Time", s.date), y: .value("Usage", s.usage), series: .value("Series", "Usage"))
                        .foregroundStyle(Color.blue)
                        .lineStyle(StrokeStyle(lineWidth: 2))
                        .interpolationMethod(.monotone)
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
            HStack {
                swatch(.blue, "Mac")
                if r.plugged { swatch(.gray, "Charger", dashed: true) }
                Spacer()
                label("Peak ") + value("\(Int(peak.rounded()))W") + label(" · last 5 min")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    // Every number is a value, in the primary color; every word around it is a label, in gray.
    private func value(_ s: String, color: Color = .primary) -> Text {
        Text(s).fontWeight(.medium).foregroundColor(color).monospacedDigit()
    }

    private func label(_ s: String) -> Text {
        Text(s).foregroundColor(.secondary)
    }

    private func dot(_ color: Color) -> some View {
        Circle().fill(color).frame(width: 7, height: 7)
    }

    private func swatch(_ color: Color, _ title: String, dashed: Bool = false) -> some View {
        HStack(spacing: 4) {
            Path { $0.move(to: CGPoint(x: 0, y: 1)); $0.addLine(to: CGPoint(x: 12, y: 1)) }
                .stroke(color, style: StrokeStyle(lineWidth: 2, dash: dashed ? [3, 2] : []))
                .frame(width: 12, height: 2)
            Text(title)
        }
    }

    private func split(_ r: Reading) -> some View {
        let total = max(r.drawWatts, 0.1)
        let toBattery = min(r.chargeWatts, total)
        let toMac = total - toBattery
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { geo in
                HStack(spacing: 2) {
                    if toBattery >= 0.5 {
                        Capsule().fill(.green)
                            .frame(width: geo.size.width * toBattery / total)
                    }
                    Capsule().fill(.blue)
                }
            }
            .frame(height: 6)
            HStack(spacing: 12) {
                legend(.green, "To battery", toBattery)
                legend(.blue, "To Mac", toMac)
            }
        }
    }

    private func legend(_ color: Color, _ title: String, _ watts: Double) -> some View {
        HStack(spacing: 4) {
            dot(color)
            label(title + " ") + value("\(Int(watts.rounded()))W")
        }
        .font(.caption)
    }

    private func battery(_ r: Reading) -> some View {
        var time = Text("")
        if r.timeToFullMinutes > 0 && r.timeToFullMinutes < 60 * 24 {
            if r.plugged && r.charging { time = value(formatTime(r.timeToFullMinutes)) + label(" to full") }
            if !r.plugged { time = value(formatTime(r.timeToFullMinutes)) + label(" left") }
        }
        // Only flag what's worth worrying about: macOS recommends service below 80% health, batteries are rated
        // for a set number of cycles, and they shouldn't run hot.
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                label("Battery ") + value("\(r.batteryPercent)%")
                Spacer()
                time
            }
            label("Health ") + value("\(r.healthPercent)%", color: r.healthPercent < 80 ? .red : .primary)
                + label(" · ") + value("\(r.cycles)", color: r.cycles >= r.designCycles ? .red : .primary) + label(" cycles")
                + label(" · ") + value(String(format: "%.0f°C", r.temperature), color: r.temperature >= 40 ? .red : .primary)
        }
        .font(.caption)
    }
}
