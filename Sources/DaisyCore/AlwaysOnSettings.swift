import Foundation

/// Settings for the always-on layer, saved in Daisy's config as `alwaysOn`. Every field is optional so
/// settings saved before it existed still decode; nil means the default.
///
/// Opening at login isn't here: macOS keeps that in System Settings → General → Login Items, and the
/// switch reads it from there (`LoginItem` in the app).
public struct AlwaysOnSettings: Codable, Sendable, Equatable {
    /// On battery, the wake word's always-open mic becomes click to talk, and goes back on with the
    /// charger. On by default: an open mic keeps the Mac from sleeping (it shows in `pmset -g assertions`),
    /// which is the real battery cost, not the wake word.
    public var clickToTalkOnBattery: Bool?
    /// Hold new background jobs while a ChatGPT usage window is about 80% used. On by default.
    public var holdJobsNearLimit: Bool?

    public init(clickToTalkOnBattery: Bool? = nil, holdJobsNearLimit: Bool? = nil) {
        self.clickToTalkOnBattery = clickToTalkOnBattery; self.holdJobsNearLimit = holdJobsNearLimit
    }

    public var clickToTalkOnBatteryEnabled: Bool { clickToTalkOnBattery ?? true }
    public var holdJobsEnabled: Bool { holdJobsNearLimit ?? true }
}
