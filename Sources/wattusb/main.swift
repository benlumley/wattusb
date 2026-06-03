import AppKit
import IOKit

struct Reading {
    let plugged: Bool
    let charging: Bool
    let drawWatts: Double
    let voltsIn: Double
    let ampsIn: Double
    let adapterWatts: Int
    let adapterVolts: Double
    let adapterAmps: Double
    let batteryPercent: Int
    let chargeWatts: Double       // power into the battery cells (when plugged)
    let dischargeWatts: Double    // power out of the battery (when on battery)
    let timeToFullMinutes: Int    // also serves as time-to-empty when unplugged
}

func readBattery() -> Reading? {
    let service = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching("AppleSmartBattery"))
    guard service != 0 else { return nil }
    defer { IOObjectRelease(service) }

    func prop(_ key: String) -> Any? {
        IORegistryEntryCreateCFProperty(service, key as CFString, kCFAllocatorDefault, 0)?
            .takeRetainedValue()
    }

    let plugged = (prop("ExternalConnected") as? Bool) ?? false
    let charging = (prop("IsCharging") as? Bool) ?? false

    let telemetry = prop("PowerTelemetryData") as? [String: Any] ?? [:]
    let powerInMW = telemetry["SystemPowerIn"] as? Int ?? 0
    let voltInMV = telemetry["SystemVoltageIn"] as? Int ?? 0
    let currentInMA = telemetry["SystemCurrentIn"] as? Int ?? 0

    let adapter = prop("AdapterDetails") as? [String: Any] ?? [:]
    let adapterWatts = adapter["Watts"] as? Int ?? 0
    let adapterMV = adapter["AdapterVoltage"] as? Int ?? 0
    let adapterMA = adapter["Current"] as? Int ?? 0

    let percent = prop("CurrentCapacity") as? Int ?? 0

    // Amperage is signed: positive = charging (into cells), negative = discharging.
    let batteryVoltMV = prop("Voltage") as? Int ?? 0
    let amperageMA = prop("Amperage") as? Int ?? 0
    let chargeMW = max(0, batteryVoltMV * amperageMA) / 1000
    let dischargeMW = max(0, batteryVoltMV * -amperageMA) / 1000

    let timeToFull = prop("TimeRemaining") as? Int ?? 0

    return Reading(
        plugged: plugged,
        charging: charging,
        drawWatts: Double(powerInMW) / 1000.0,
        voltsIn: Double(voltInMV) / 1000.0,
        ampsIn: Double(currentInMA) / 1000.0,
        adapterWatts: adapterWatts,
        adapterVolts: Double(adapterMV) / 1000.0,
        adapterAmps: Double(adapterMA) / 1000.0,
        batteryPercent: percent,
        chargeWatts: Double(chargeMW) / 1000.0,
        dischargeWatts: Double(dischargeMW) / 1000.0,
        timeToFullMinutes: timeToFull
    )
}

func formatTime(_ minutes: Int) -> String {
    let h = minutes / 60
    let m = minutes % 60
    if h > 0 { return "\(h)h \(m)m" }
    return "\(m)m"
}

@MainActor
final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        item.menu = NSMenu()
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        let r = readBattery()
        let menu = NSMenu()

        guard let r else {
            setStatusTitle("—")
            menu.addItem(labelItem("No battery data"))
            menu.addItem(.separator())
            menu.addItem(quitItem())
            item.menu = menu
            return
        }

        if r.plugged {
            setStatusTitle("\(Int(r.drawWatts.rounded()))W")

            let systemWatts = max(0, r.drawWatts - r.chargeWatts)
            menu.addItem(labelItem(String(format: "In:          %dW (%.1fV · %.2fA)",
                                           Int(r.drawWatts.rounded()), r.voltsIn, r.ampsIn)))
            menu.addItem(labelItem(String(format: "Adapter:     %dW max (%.0fV · %.0fA PD)",
                                           r.adapterWatts, r.adapterVolts, r.adapterAmps)))
            menu.addItem(labelItem(String(format: "To battery:  %dW",
                                           Int(r.chargeWatts.rounded()))))
            menu.addItem(labelItem(String(format: "To system:   %dW",
                                           Int(systemWatts.rounded()))))

            var batteryLine = "Battery:     \(r.batteryPercent)%"
            if r.charging && r.timeToFullMinutes > 0 && r.timeToFullMinutes < 60 * 24 {
                batteryLine += "  ·  \(formatTime(r.timeToFullMinutes)) to full"
            }
            menu.addItem(labelItem(batteryLine))
        } else {
            let draw = Int(r.dischargeWatts.rounded())
            setStatusTitle("\(draw)W")

            menu.addItem(labelItem(String(format: "Drawing:     %dW from battery", draw)))
            var batteryLine = "Battery:     \(r.batteryPercent)%"
            if r.timeToFullMinutes > 0 && r.timeToFullMinutes < 60 * 24 {
                batteryLine += "  ·  \(formatTime(r.timeToFullMinutes)) left"
            }
            menu.addItem(labelItem(batteryLine))
            menu.addItem(labelItem("Not plugged in"))
        }

        menu.addItem(.separator())
        menu.addItem(quitItem())
        item.menu = menu
    }

    private func setStatusTitle(_ text: String) {
        guard let button = item.button else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 12),
            .foregroundColor: NSColor.labelColor
        ]
        button.attributedTitle = NSAttributedString(string: text, attributes: attrs)
    }

    private func labelItem(_ s: String) -> NSMenuItem {
        let it = NSMenuItem(title: s, action: nil, keyEquivalent: "")
        it.isEnabled = false
        return it
    }

    private func quitItem() -> NSMenuItem {
        NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
