@testable import wattusb

// A reading with everything at 0 but what a test cares about.
func reading(plugged: Bool = false, charging: Bool = false, draw: Double = 0, charge: Double = 0, discharge: Double = 0,
             load: Double = 0, devices: [Device] = [], percent: Int = 50, minutes: Int = 0, full: Bool = false) -> Reading {
    Reading(plugged: plugged, charging: charging, drawWatts: draw, voltsIn: 20, ampsIn: draw / 20, adapterWatts: 60,
            adapterVolts: 20, adapterAmps: 3, batteryPercent: percent, chargeWatts: charge, dischargeWatts: discharge,
            timeToFullMinutes: minutes, fullyCharged: full, healthPercent: 90, cycles: 120, designCycles: 1000,
            temperature: 31, loadWatts: load, devices: devices)
}
