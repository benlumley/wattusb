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

    return Reading(
        plugged: plugged,
        charging: charging,
        drawWatts: Double(powerInMW) / 1000.0,
        voltsIn: Double(voltInMV) / 1000.0,
        ampsIn: Double(currentInMA) / 1000.0,
        adapterWatts: adapterWatts,
        adapterVolts: Double(adapterMV) / 1000.0,
        adapterAmps: Double(adapterMA) / 1000.0
    )
}

@MainActor
final class App: NSObject, NSApplicationDelegate {
    let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    var timer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        item.menu = NSMenu()
        item.button?.font = NSFont.monospacedDigitSystemFont(ofSize: 0, weight: .regular)
        refresh()
        timer = Timer.scheduledTimer(withTimeInterval: 2.0, repeats: true) { _ in
            Task { @MainActor in self.refresh() }
        }
    }

    func refresh() {
        let r = readBattery()
        let menu = NSMenu()

        guard let r, r.plugged else {
            item.button?.title = "—"
            menu.addItem(labelItem("Not plugged in"))
            menu.addItem(.separator())
            menu.addItem(quitItem())
            item.menu = menu
            return
        }

        item.button?.title = "\(Int(r.drawWatts.rounded()))W"

        menu.addItem(labelItem(String(format: "Drawing:  %dW (%.1fV · %.2fA)",
                                       Int(r.drawWatts.rounded()), r.voltsIn, r.ampsIn)))
        menu.addItem(labelItem(String(format: "Adapter:  %dW max (%.0fV · %.0fA PD)",
                                       r.adapterWatts, r.adapterVolts, r.adapterAmps)))
        menu.addItem(labelItem("Charging: \(r.charging ? "Yes" : "No")"))
        menu.addItem(.separator())
        menu.addItem(quitItem())
        item.menu = menu
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
