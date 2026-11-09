import AppKit
import Combine
import SwiftUI
import Testing
@testable import wattusb

@MainActor struct MonitorTests {
    @Test func keepsTheLastFiveMinutes() {
        let m = Monitor(every: 3600) { reading(plugged: true, draw: 30, charge: 10) }
        #expect(m.history.count == 1)
        #expect(m.history[0].input == 30 && m.history[0].watts("Battery") == 10 && m.history[0].watts("Port 1") == nil)
        m.history.insert(Sample(date: Date().addingTimeInterval(-301), parts: [], input: nil), at: 0)
        m.update(reading(discharge: 9))
        #expect(m.history.count == 2 && m.history[1].input == nil)
        m.update(nil)
        #expect(m.reading == nil && m.history.count == 2)
    }

    @Test func readsTheBatteryByDefault() {
        // Nil on a Mac without one, like CI's.
        #expect(Monitor().reading?.batteryPercent == readBattery()?.batteryPercent)
    }

    @Test func eachSampleIsItsOwnPointOnTheChart() {
        let m = Monitor(every: 3600) { reading(discharge: 9) }
        m.update(reading(discharge: 9))
        #expect(m.history[0].id <= m.history[1].id)
    }

    @Test func leavesNegotiationOutOfTheChart() {
        let m = Monitor(every: 3600) { reading(plugged: true, load: 8) }
        #expect(m.history[0].parts.isEmpty && m.history[0].input == nil)
    }

    @Test func readsAgainOnATimer() async throws {
        var reads = 0
        let m = Monitor(every: 0.01) { reads += 1; return nil }
        try await Task.sleep(for: .milliseconds(200))
        #expect(reads > 1 && m.reading == nil)
    }

    @Test func holdsTheLastWattsJustAfterUnplugging() {
        let m = Monitor(every: 3600) { nil }
        #expect(m.headlineWatts == 0)
        m.update(reading(plugged: true, draw: 37, charge: 18, load: 11, devices: [Device(port: 2, watts: 7, volts: 5, amps: 1.4)]))
        #expect(m.headlineWatts == 37)
        // Unplugged, with the battery not reporting yet: what the Mac and its devices were using.
        m.update(reading())
        #expect(m.headlineWatts == 18)
        m.update(reading(plugged: true, load: 6))
        m.update(reading())
        #expect(m.headlineWatts == 6)
        m.update(reading(discharge: 15))
        m.update(reading())
        #expect(m.headlineWatts == 15)
    }

    @Test func menuBarTitle() {
        let m = Monitor(every: 3600) { nil }
        #expect(m.statusImage.isTemplate)
        let none = m.statusImage.size.width
        m.update(reading(plugged: true, charging: true, draw: 37))
        let charging = m.statusImage.size.width
        m.update(reading(plugged: true, draw: 37))
        #expect(m.statusImage.size.width > none)
        m.update(reading(discharge: 15))
        // The bolt or plug sits before the number; on battery there's none.
        #expect(charging > m.statusImage.size.width && m.statusImage.size.width > none)
    }

    @Test func updatesTheMenuBarTitleOnEveryReading() {
        let m = Monitor(every: 3600) { nil }
        let none = m.title.image.size.width
        m.update(reading(plugged: true, charging: true, draw: 37))
        #expect(m.title.image.size.width > none)
        m.update(nil)
        #expect(m.title.image.size.width == none)
    }

    @Test func onlyRedrawsTheMenuBarWhenTheTitleChanges() {
        let m = Monitor(every: 3600) { nil }
        var redraws = 0
        let watching = m.title.objectWillChange.sink { redraws += 1 }
        m.update(nil)
        #expect(redraws == 0)
        m.update(reading(plugged: true, charging: true, draw: 37))
        m.update(reading(plugged: true, charging: true, draw: 37.2))
        #expect(redraws == 1)
        // The same number with a different icon.
        m.update(reading(plugged: true, draw: 37))
        #expect(redraws == 2)
        watching.cancel()
    }

    @Test func onlyRedrawsThePanelWhileItsOpen() {
        let m = Monitor(every: 3600) { nil }
        var changes = 0
        let watching = m.objectWillChange.sink { changes += 1 }
        m.update(reading(discharge: 9))
        #expect(changes == 0)
        // Opening it catches up on what it missed.
        m.panelOpen = true
        m.panelOpen = true
        #expect(changes == 1)
        m.update(reading(discharge: 9))
        #expect(changes == 2)
        m.panelOpen = false
        m.update(reading(discharge: 9))
        #expect(changes == 2)
        watching.cancel()
    }

    @Test func titleDrawsWithAndWithoutAnIcon() {
        for image in [statusImage("37W", symbol: "bolt.fill"), statusImage("15W", symbol: nil)] {
            let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 60, pixelsHigh: 20, bitsPerSample: 8, samplesPerPixel: 4,
                                       hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
            NSGraphicsContext.saveGraphicsState()
            NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: rep)
            image.draw(in: NSRect(origin: .zero, size: image.size))
            NSGraphicsContext.restoreGraphicsState()
            #expect((0..<60).contains { x in (0..<20).contains { (rep.colorAt(x: x, y: $0)?.alphaComponent ?? 0) > 0 } })
        }
    }

    @Test func loadLevels() {
        #expect([3, 11, 24, 38].map { Load(Double($0)).label } == ["Light load", "Moderate load", "Heavy load", "Very heavy load"])
        #expect(Load(24).shortLabel == "Heavy")
        #expect([Load.light, .heavy, .veryHeavy].map(\.color) == [.green, .orange, .red])
    }

    @Test func moderateIsAmberInLightModeAndYellowInDark() {
        let color = NSColor(Load.moderate.color)
        var light = NSColor.clear, dark = NSColor.clear
        NSAppearance(named: .aqua)!.performAsCurrentDrawingAppearance { light = color.usingColorSpace(.sRGB)! }
        NSAppearance(named: .darkAqua)!.performAsCurrentDrawingAppearance { dark = color.usingColorSpace(.sRGB)! }
        #expect(light.redComponent == 0.8 && light.greenComponent == 0.6)
        #expect(dark != light)
    }
}
