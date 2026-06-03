# wattusb

Tiny macOS menu bar app that shows the live wattage your Mac is currently drawing from its USB-C / MagSafe charger.

Useful for:

- Telling whether a given charger is actually delivering its rated power.
- Comparing ports on multi-port chargers (the "fast" port vs the slower ones).
- Sanity-checking cables — a flaky cable will cap the negotiated voltage and the wattage drops accordingly.

## What it shows

**Menu bar**: a single number, e.g. `58W` — the actual power flowing in right now (rounded). When nothing is plugged in: `—`.

**Click for details**:

```
Drawing:  58W (19.5V · 2.98A)
Adapter:  60W max (20V · 3A PD)
Charging: Yes
─────────
Quit
```

- **Drawing** — real-time power being delivered, with voltage and current.
- **Adapter** — the PD contract the charger negotiated (what it advertises as max).
- **Charging** — whether the battery is currently topping up.

Updates every 2 seconds.

## Install

```sh
git clone https://github.com/benlumley/wattusb.git
cd wattusb
sh build.sh
mv wattusb.app /Applications/
open /Applications/wattusb.app
```

Requires macOS 14+ and Xcode command-line tools.

The build script produces a universal binary (Apple Silicon + Intel) and ad-hoc signs it so Gatekeeper lets it launch.

## How it works

All data comes from IOKit's `AppleSmartBattery` service:

- Live draw — `PowerTelemetryData.SystemPowerIn` (milliwatts coming in from the adapter)
- Voltage / current — `SystemVoltageIn`, `SystemCurrentIn`
- PD contract — `AdapterDetails.Watts`, `AdapterVoltage`, `Current`
- State flags — `ExternalConnected`, `IsCharging`

No entitlements, no network, no preferences, no launch agent. The whole app is one Swift file (~95 lines). It's an `LSUIElement` app so there's no dock icon and no main window.

## Quit

Click the menu bar item → Quit (or `⌘Q` while the menu is open).

## License

MIT.
