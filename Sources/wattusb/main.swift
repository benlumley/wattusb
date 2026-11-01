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

// "40s", "2m 10s"
func formatAgo(_ seconds: TimeInterval) -> String {
    let s = Int(seconds.rounded())
    return s < 60 ? "\(s)s" : "\(s / 60)m \(s % 60)s"
}

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
struct WattUSB: App {
    @StateObject private var monitor = Monitor()
    @StateObject private var login = LoginItem()
    @StateObject private var shortcuts = Shortcuts()

    var body: some Scene {
        MenuBarExtra {
            Dashboard(monitor: monitor, login: login, shortcuts: shortcuts)
        } label: {
            Image(nsImage: monitor.statusImage)
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

WattUSB.main()
