import Foundation

/// The ONE source of truth for how fast a Meshtastic radio may be fed, keyed by the raw
/// `Config.LoRaConfig.ModemPreset` value. Both the sender's pacing (`MeshtasticInterface`) and the
/// interface's declared bitrate (`InterfaceProfile.meshtastic(modemPreset:)`) derive from it.
public enum MeshtasticModemPreset {
    /// landandair `speed_to_delay` verbatim (Meshtastic_Interface.py:31-39), in milliseconds so
    /// the bitrate arithmetic below is exact integer division.
    static let delayTable: [Int: Int] = [
        8: 400,      // ShortTurbo
        6: 1_000,    // ShortFast
        5: 3_000,    // ShortSlow
        7: 12_000,   // LongModerate
        4: 4_000,    // MediumFast
        3: 6_000,    // MediumSlow
        1: 15_000,   // LongSlow
        0: 8_000,    // LongFast
    ]
    /// landandair's fallback for an unlisted preset (`... else 7`, Meshtastic_Interface.py:281).
    static let fallbackDelayMilliseconds = 7_000
    /// Bytes per paced fragment in the bitrate formula: a 200-byte body plus the 2-byte header.
    static let pacedFrameBytes = 202

    public static func fragmentDelayMilliseconds(_ preset: Int?) -> Int {
        preset.flatMap { delayTable[$0] } ?? fallbackDelayMilliseconds
    }

    public static func fragmentDelay(_ preset: Int?) -> Duration {
        .milliseconds(fragmentDelayMilliseconds(preset))
    }

    /// Effective paced bitrate, `Int(202 * 8 / delaySeconds)` (spec Contract 3).
    public static func pacedBitrate(_ preset: Int?) -> Int {
        pacedFrameBytes * 8 * 1_000 / fragmentDelayMilliseconds(preset)
    }
}
