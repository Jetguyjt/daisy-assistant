import Foundation
import DaisyCore

/// Click to talk on battery: the rule, and the power monitor against a fake power source that can be
/// plugged in and out.
final class PowerTests {
    private final class FakePower: PowerSourceReader {
        var current: PowerSource
        private var changed: (() -> Void)?
        var watched: Bool { changed != nil }
        init(_ source: PowerSource) { current = source }
        func observe(_ changed: @escaping () -> Void) { self.changed = changed }
        func cancel() { changed = nil }
        /// The charger goes in or out; IOKit also calls back when only the charge level moved.
        func plug(_ source: PowerSource) { current = source; changed?() }
    }

    func testClickToTalkOnlyOnBatteryWithTheWakeWord() {
        expectTrue(BatteryListening.clickToTalk(wakeWordChosen: true, enabled: true, source: .battery))
        expectFalse(BatteryListening.clickToTalk(wakeWordChosen: true, enabled: true, source: .ac))
        expectFalse(BatteryListening.clickToTalk(wakeWordChosen: true, enabled: true, source: .unknown))
        expectFalse(BatteryListening.clickToTalk(wakeWordChosen: true, enabled: false, source: .battery))
        expectFalse(BatteryListening.clickToTalk(wakeWordChosen: false, enabled: true, source: .battery))
        expectTrue(AlwaysOnSettings().clickToTalkOnBatteryEnabled)
        expectFalse(AlwaysOnSettings(clickToTalkOnBattery: false).clickToTalkOnBatteryEnabled)
        expectTrue(AlwaysOnSettings().holdJobsEnabled)
    }

    @MainActor
    func testMonitorFollowsTheCharger() {
        let power = FakePower(.ac)
        let monitor = PowerMonitor(reader: power)
        var seen: [PowerSource] = []
        monitor.onChange = { seen.append($0) }
        monitor.start()
        expectTrue(power.watched)
        expectEqual(monitor.source, .ac)
        expectFalse(monitor.onBattery)
        power.plug(.battery)
        expectTrue(monitor.onBattery)
        power.plug(.battery)
        power.plug(.ac)
        expectEqual(seen, [.battery, .ac])
        // What AppModel does with it: the wake word's open mic becomes click to talk while on battery.
        var mic: [Bool] = []
        monitor.onChange = { source in mic.append(BatteryListening.clickToTalk(wakeWordChosen: true, enabled: true, source: source)) }
        power.plug(.battery)
        power.plug(.ac)
        expectEqual(mic, [true, false])
        monitor.stop()
        expectFalse(power.watched)
        power.plug(.battery)
        expectEqual(monitor.source, .ac)
    }

    @MainActor
    func testStartReadsTheSourceAgain() {
        let power = FakePower(.ac)
        let monitor = PowerMonitor(reader: power)
        power.current = .battery
        monitor.start()
        expectEqual(monitor.source, .battery)
    }

    func testIOKitNames() {
        expectEqual(IOKitPowerSourceReader.source(for: "Battery Power"), .battery)
        expectEqual(IOKitPowerSourceReader.source(for: "AC Power"), .ac)
        expectEqual(IOKitPowerSourceReader.source(for: "UPS Power"), .ac)
        expectEqual(IOKitPowerSourceReader.source(for: "something else"), .unknown)
        // The real reader answers something on any Mac (desktops read as AC).
        let reader = IOKitPowerSourceReader()
        expectTrue([PowerSource.ac, .battery, .unknown].contains(reader.current))
    }
}
