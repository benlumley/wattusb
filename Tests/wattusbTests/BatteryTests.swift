import Testing
@testable import wattusb

struct BatteryTests {
    @Test func readsAppleSmartBatterysProperties() {
        let r = Reading([
            "ExternalConnected": true, "IsCharging": true, "FullyCharged": false,
            "PowerTelemetryData": ["SystemPowerIn": 37_000, "SystemVoltageIn": 20_100, "SystemCurrentIn": 1_840, "SystemLoad": 11_000],
            "AdapterDetails": ["Watts": 60, "AdapterVoltage": 20_000, "Current": 3_000],
            "Voltage": 12_000, "Amperage": 1_500, "CurrentCapacity": 64, "TimeRemaining": 52,
            "DesignCapacity": 5_000, "NominalChargeCapacity": 4_000, "CycleCount": 794, "DesignCycleCount9C": 1_200,
            "Temperature": 3_150,
            "PowerOutDetails": [
                ["PortIndex": 2, "Watts": 7_400, "AdapterVoltage": 5_000, "Current": 1_480],
                ["PortIndex": 1, "Watts": 50],
                ["PortIndex": 3],
            ],
        ])
        #expect(r.plugged && r.charging && !r.fullyCharged)
        #expect(r.drawWatts == 37 && r.voltsIn == 20.1 && r.ampsIn == 1.84 && r.loadWatts == 11)
        #expect(r.adapterWatts == 60 && r.adapterVolts == 20 && r.adapterAmps == 3)
        #expect(r.chargeWatts == 18 && r.dischargeWatts == 0)
        #expect(r.batteryPercent == 64 && r.timeToFullMinutes == 52)
        #expect(r.healthPercent == 80 && r.cycles == 794 && r.designCycles == 1200 && r.temperature == 31.5)
        // Ports drawing under 0.1W are left out.
        #expect(r.devices.map(\.port) == [2])
        #expect(r.devices[0].watts == 7.4 && r.devices[0].volts == 5 && r.devices[0].amps == 1.48)
    }

    @Test func dischargingIsNegativeAmperage() {
        let r = Reading(["Voltage": 12_000, "Amperage": -1_000])
        #expect(r.dischargeWatts == 12 && r.chargeWatts == 0)
    }

    @Test func missingPropertiesReadAsNothing() {
        let r = Reading([:])
        #expect(!r.plugged && r.drawWatts == 0 && r.healthPercent == 0 && r.devices.isEmpty)
        #expect(r.designCycles == 1000)
        let port = Reading(["PowerOutDetails": [["Watts": 1_000]]]).devices
        #expect(port.count == 1 && port[0].port == 0 && port[0].volts == 0 && port[0].amps == 0)
        // A battery can't report more than 100%, even when it holds more than it was designed to.
        #expect(Reading(["DesignCapacity": 4_000, "NominalChargeCapacity": 4_400]).healthPercent == 100)
    }

    @Test func readsFromIOKit() {
        #expect(readBattery("NoSuchService") == nil)
        // Any service will do: one without a battery's properties reads as all zeros.
        #expect(readBattery("IOPlatformExpertDevice")?.drawWatts == 0)
    }

    @Test func usageIsTheMacsOwnLoadWhenReported() {
        #expect(reading(plugged: true, draw: 30, charge: 10, load: 12).usageWatts == 12)
        #expect(reading(plugged: true, draw: 30, charge: 10).usageWatts == 20)
        #expect(reading(plugged: true, draw: 5, charge: 10).usageWatts == 0)
        #expect(reading(discharge: 9).usageWatts == 9)
    }

    @Test func headlineIsTheChargerOrTheBattery() {
        #expect(reading(plugged: true, draw: 37).headlineWatts == 37)
        // While the charger negotiates, its input reads 0.
        let connecting = reading(plugged: true, load: 8)
        #expect(connecting.connecting && connecting.headlineWatts == 8)
        #expect(reading(discharge: 15, load: 6).headlineWatts == 15)
        #expect(reading(load: 6).headlineWatts == 6)
    }

    @Test func partsSplitTheChargerBetweenMacBatteryAndPorts() {
        let r = reading(plugged: true, draw: 37, charge: 18, devices: [Device(port: 2, watts: 7, volts: 5, amps: 1.4)])
        #expect(r.deviceWatts == 7)
        #expect(r.parts.map(\.name) == ["Mac", "Battery", "Port 2"])
        #expect(r.parts.map(\.watts) == [12, 18, 7])
        #expect(r.parts[2].help == "5.0V · 1.40A")
    }

    @Test func partsScaleDevicesDownToWhatsLeft() {
        let r = reading(discharge: 10, devices: [Device(port: 1, watts: 15, volts: 5, amps: 3), Device(port: 4, watts: 5, volts: 5, amps: 1)])
        #expect(r.parts.map(\.name) == ["Mac", "Port 1", "Port 4"])
        #expect(r.parts.map(\.watts) == [0, 7.5, 2.5])
    }

    @Test func partsNeverDivideByNothing() {
        #expect(reading().parts.map(\.watts) == [0.1])
    }

    @Test func breakdownForTheTooltip() {
        let charging = reading(plugged: true, draw: 30, charge: 10)
        #expect(charging.breakdown == "In: 30W · 20.0V · 1.50A\nCharger: 60W · 20V · 3A\nTo Mac: 20W\nTo battery: 10W")
        #expect(reading(discharge: 12).breakdown == "Battery: 12W\nTo Mac: 12W")
        #expect(reading(plugged: true, load: 8).breakdown == "To Mac: 0W\nTo battery: 0W")
    }

    @Test func detailsForTheBatteryTooltip() {
        #expect(reading().details == "Health 90%\n120 of 1000 cycles\n31°C")
    }
}
