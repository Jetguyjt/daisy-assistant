import Foundation
import IOKit.ps

/// Where the Mac's power comes from right now.
public enum PowerSource: String, Sendable {
    case ac, battery, unknown
}

/// Reads the power source and says when it may have changed. The app uses IOKit's; tests use a fake.
public protocol PowerSourceReader: AnyObject {
    var current: PowerSource { get }
    /// `changed` runs on the main thread each time the power source might have changed.
    func observe(_ changed: @escaping () -> Void)
    func cancel()
}

/// The wake word's mic on battery: while the Mac runs on battery (and the setting is on), Daisy's
/// always-open mic becomes click to talk, and it opens again on the charger. Only wake-word mode
/// changes; the other modes already close the mic between turns.
public enum BatteryListening {
    public static func clickToTalk(wakeWordChosen: Bool, enabled: Bool, source: PowerSource) -> Bool {
        wakeWordChosen && enabled && source == .battery
    }

    /// For the always-listening switch while it's holding back.
    public static let note = "On battery: click to talk"
}

/// Watches mains versus battery. `onChange` runs on the main actor only when the source really changes.
@MainActor public final class PowerMonitor: ObservableObject {
    @Published public private(set) var source: PowerSource
    public var onChange: ((PowerSource) -> Void)?
    private let reader: PowerSourceReader
    private var watching = false

    public init(reader: PowerSourceReader = IOKitPowerSourceReader()) {
        self.reader = reader
        source = reader.current
    }

    public var onBattery: Bool { source == .battery }

    public func start() {
        guard !watching else { return }
        watching = true
        source = reader.current
        reader.observe { [weak self] in
            MainActor.assumeIsolated { self?.update() }
        }
    }

    public func stop() {
        guard watching else { return }
        watching = false
        reader.cancel()
    }

    /// Reads the source again; tells `onChange` when it moved.
    public func update() {
        let now = reader.current
        guard now != source else { return }
        source = now
        onChange?(now)
    }
}

/// IOKit's power sources: IOPSGetProvidingPowerSourceType for the source, and a run-loop source on the
/// main run loop for changes (IOPSNotificationCreateRunLoopSource). A Mac without a battery reads as AC.
public final class IOKitPowerSourceReader: PowerSourceReader {
    private var loopSource: CFRunLoopSource?
    private var changed: (() -> Void)?

    public init() {}
    deinit { cancel() }

    public var current: PowerSource {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let type = IOPSGetProvidingPowerSourceType(info)?.takeUnretainedValue() else { return .unknown }
        return Self.source(for: type as String)
    }

    /// kIOPMBatteryPowerKey, kIOPMACPowerKey and kIOPMUPSPowerKey, as IOKit spells them.
    public static func source(for type: String) -> PowerSource {
        switch type {
        case "Battery Power": return .battery
        case "AC Power", "UPS Power": return .ac
        default: return .unknown
        }
    }

    public func observe(_ changed: @escaping () -> Void) {
        cancel()
        self.changed = changed
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let source = IOPSNotificationCreateRunLoopSource({ context in
            guard let context else { return }
            Unmanaged<IOKitPowerSourceReader>.fromOpaque(context).takeUnretainedValue().changed?()
        }, context)?.takeRetainedValue() else { return }
        loopSource = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
    }

    public func cancel() {
        if let loopSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), loopSource, .commonModes) }
        loopSource = nil
        changed = nil
    }
}
