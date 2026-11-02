import IOKit
import SwiftUI

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

extension Reading {
    // From AppleSmartBattery's properties, in its units: mV, mA, mW and hundredths of a °C.
    init(_ battery: [String: Any]) {
        let telemetry = battery["PowerTelemetryData"] as? [String: Any] ?? [:]
        let adapter = battery["AdapterDetails"] as? [String: Any] ?? [:]
        // Amperage is signed: positive = charging (into cells), negative = discharging.
        let batteryVoltMV = battery["Voltage"] as? Int ?? 0
        let amperageMA = battery["Amperage"] as? Int ?? 0
        let powerOut = battery["PowerOutDetails"] as? [[String: Any]] ?? []
        let design = battery["DesignCapacity"] as? Int ?? 0
        let nominal = battery["NominalChargeCapacity"] as? Int ?? 0

        self.init(
            plugged: battery["ExternalConnected"] as? Bool ?? false,
            charging: battery["IsCharging"] as? Bool ?? false,
            drawWatts: Double(telemetry["SystemPowerIn"] as? Int ?? 0) / 1000.0,
            voltsIn: Double(telemetry["SystemVoltageIn"] as? Int ?? 0) / 1000.0,
            ampsIn: Double(telemetry["SystemCurrentIn"] as? Int ?? 0) / 1000.0,
            adapterWatts: adapter["Watts"] as? Int ?? 0,
            adapterVolts: Double(adapter["AdapterVoltage"] as? Int ?? 0) / 1000.0,
            adapterAmps: Double(adapter["Current"] as? Int ?? 0) / 1000.0,
            batteryPercent: battery["CurrentCapacity"] as? Int ?? 0,
            chargeWatts: Double(max(0, batteryVoltMV * amperageMA) / 1000) / 1000.0,
            dischargeWatts: Double(max(0, batteryVoltMV * -amperageMA) / 1000) / 1000.0,
            timeToFullMinutes: battery["TimeRemaining"] as? Int ?? 0,
            fullyCharged: battery["FullyCharged"] as? Bool ?? false,
            healthPercent: design > 0 ? min(100, nominal * 100 / design) : 0,
            cycles: battery["CycleCount"] as? Int ?? 0,
            designCycles: battery["DesignCycleCount9C"] as? Int ?? 1000,
            temperature: Double(battery["Temperature"] as? Int ?? 0) / 100.0,
            loadWatts: Double(telemetry["SystemLoad"] as? Int ?? 0) / 1000.0,
            devices: powerOut.compactMap { port in
                let mW = port["Watts"] as? Int ?? 0
                guard mW >= 100 else { return nil }
                return Device(port: port["PortIndex"] as? Int ?? 0,
                              watts: Double(mW) / 1000.0,
                              volts: Double(port["AdapterVoltage"] as? Int ?? 0) / 1000.0,
                              amps: Double(port["Current"] as? Int ?? 0) / 1000.0)
            }
        )
    }
}

// The battery as IOKit reports it right now, or nil on a Mac without one.
func readBattery(_ service: String = "AppleSmartBattery") -> Reading? {
    let entry = IOServiceGetMatchingService(kIOMainPortDefault, IOServiceMatching(service))
    guard entry != 0 else { return nil }
    defer { IOObjectRelease(entry) }
    var properties: Unmanaged<CFMutableDictionary>?
    IORegistryEntryCreateCFProperties(entry, &properties, kCFAllocatorDefault, 0)
    return (properties?.takeRetainedValue() as? [String: Any]).map(Reading.init)
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
                 help: String(format: "%.1fV · %.2fA", d.volts, d.amps))
        }
        let toMac = total - toBattery - toDevices.reduce(0) { $0 + $1.watts }
        return [Part(name: "Mac", watts: toMac, color: .blue, help: "")]
            + (plugged ? [Part(name: "Battery", watts: toBattery, color: .green, help: "")] : [])
            + toDevices
    }

    // Everything the original menu showed, for the big number's tooltip.
    var breakdown: String {
        var lines: [String] = []
        if plugged && !connecting {
            lines.append(String(format: "In: %.0fW · %.1fV · %.2fA", drawWatts, voltsIn, ampsIn))
            lines.append(String(format: "Charger: %dW · %.0fV · %.0fA", adapterWatts, adapterVolts, adapterAmps))
        } else if !plugged {
            lines.append(String(format: "Battery: %.0fW", dischargeWatts))
        }
        for part in parts {
            lines.append(String(format: "To %@: %.0fW", part.name == "Mac" ? "Mac" : part.name.lowercased(), part.watts))
        }
        return lines.joined(separator: "\n")
    }

    // Health, cycles and temperature change over months, not minutes, so they live in the battery line's tooltip.
    var details: String {
        String(format: "Health %d%%\n%d of %d cycles\n%.0f°C", healthPercent, cycles, designCycles, temperature)
    }
}
