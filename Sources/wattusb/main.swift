import AppKit
import SwiftUI
import IOKit
import ServiceManagement

// Something charging off one of the Mac's USB-C ports, e.g. a phone.
struct Device {
    let port: Int
    let watts: Double
    let volts: Double
    let amps: Double
}

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
    let fullyCharged: Bool
    let healthPercent: Int        // full charge capacity vs design capacity
    let cycles: Int
    let designCycles: Int         // cycles the battery is rated for
    let temperature: Double       // °C
    let loadWatts: Double         // what the Mac itself is using, whichever way the power is coming in
    let devices: [Device]

    var deviceWatts: Double { devices.reduce(0) { $0 + $1.watts } }

    var usageWatts: Double {
        if loadWatts > 0 { return loadWatts }
        return plugged ? max(0, drawWatts - chargeWatts) : dischargeWatts
    }

    // Charger input reads 0 for a few seconds after plugging in, while it negotiates.
    var connecting: Bool { plugged && drawWatts == 0 }
    // Everything coming in from the charger, or going out of the battery, including devices charging off the ports.
    var headlineWatts: Double {
        if plugged { return connecting ? usageWatts : drawWatts }
        return dischargeWatts > 0 ? dischargeWatts : usageWatts
    }
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
    let loadMW = telemetry["SystemLoad"] as? Int ?? 0

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

    let powerOut = prop("PowerOutDetails") as? [[String: Any]] ?? []
    let devices = powerOut.compactMap { port -> Device? in
        let mW = port["Watts"] as? Int ?? 0
        guard mW >= 100 else { return nil }
        return Device(port: port["PortIndex"] as? Int ?? 0,
                      watts: Double(mW) / 1000.0,
                      volts: Double(port["AdapterVoltage"] as? Int ?? 0) / 1000.0,
                      amps: Double(port["Current"] as? Int ?? 0) / 1000.0)
    }

    let design = prop("DesignCapacity") as? Int ?? 0
    let nominal = prop("NominalChargeCapacity") as? Int ?? 0
    let health = design > 0 ? min(100, nominal * 100 / design) : 0

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
        timeToFullMinutes: timeToFull,
        fullyCharged: (prop("FullyCharged") as? Bool) ?? false,
        healthPercent: health,
        cycles: prop("CycleCount") as? Int ?? 0,
        designCycles: prop("DesignCycleCount9C") as? Int ?? 1000,
        temperature: Double(prop("Temperature") as? Int ?? 0) / 100.0,
        loadWatts: Double(loadMW) / 1000.0,
        devices: devices
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
    let monitor = Monitor()
    lazy var host = NSHostingView(rootView: Dashboard(monitor: monitor))
    var timer: Timer?

    func applicationDidFinishLaunching(_: Notification) {
        let menu = NSMenu()
        let dashboard = NSMenuItem()
        dashboard.view = host
        menu.addItem(dashboard)
        menu.addItem(.separator())
        menu.addItem(loginItem)
        menu.addItem(NSMenuItem(title: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        menu.delegate = self
        item.menu = menu

        registerLoginItemOnce()
        refresh()
        // .common so it keeps updating while the menu is open. Timers fire on the main thread; a Task would wait
        // until the menu closes.
        let timer = Timer(timeInterval: 2.0, repeats: true) { _ in
            MainActor.assumeIsolated { self.refresh() }
        }
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func refresh() {
        monitor.update(readBattery())
        host.frame.size = host.fittingSize
        guard let r = monitor.reading else {
            setStatus("—", symbol: nil)
            return
        }
        let watts = Int(r.headlineWatts.rounded())
        setStatus("\(watts)W", symbol: r.plugged ? (r.charging ? "bolt.fill" : "powerplug.fill") : nil)
    }

    private func setStatus(_ text: String, symbol: String?) {
        guard let button = item.button else { return }
        let attrs: [NSAttributedString.Key: Any] = [
            .font: NSFont.menuBarFont(ofSize: 11),
            .foregroundColor: NSColor.labelColor
        ]
        let attributed = NSAttributedString(string: text, attributes: attrs)
        button.attributedTitle = attributed
        let config = NSImage.SymbolConfiguration(pointSize: 9, weight: .semibold)
        button.image = symbol.flatMap { NSImage(systemSymbolName: $0, accessibilityDescription: nil)?.withSymbolConfiguration(config) }
        button.imagePosition = .imageLeading
        let imageWidth = button.image.map { $0.size.width + 2 } ?? 0
        item.length = ceil(attributed.size().width + imageWidth) + 6
    }

    private lazy var loginItem: NSMenuItem = {
        let it = NSMenuItem(title: "Open at Login", action: #selector(toggleOpenAtLogin), keyEquivalent: "")
        it.target = self
        return it
    }()

    // Opens at login by default, the first time the app runs, so turning it off sticks.
    private func registerLoginItemOnce() {
        guard !UserDefaults.standard.bool(forKey: "loginItemRegistered") else { return }
        UserDefaults.standard.set(true, forKey: "loginItemRegistered")
        try? SMAppService.mainApp.register()
    }

    @objc private func toggleOpenAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            let alert = NSAlert()
            alert.messageText = "Couldn't change Open at Login"
            alert.informativeText = error.localizedDescription
            NSApp.activate(ignoringOtherApps: true)
            alert.runModal()
        }
    }
}

extension App: NSMenuDelegate {
    func menuWillOpen(_: NSMenu) {
        loginItem.state = SMAppService.mainApp.status == .enabled ? .on : .off
    }
}

MainActor.assumeIsolated {
    let app = NSApplication.shared
    let delegate = App()
    app.delegate = delegate
    app.setActivationPolicy(.accessory)
    app.run()
}
