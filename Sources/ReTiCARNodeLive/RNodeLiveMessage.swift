import Foundation
import RNodeKit

/// The user-readable texts the live driver reports as `.unavailable(.other(_))` for the session's
/// four terminal reasons (spec Contract 2). The app shows them verbatim, and reads
/// `needsUserAction(_:)` to stop re-dialling a failure only the person can fix.
public enum RNodeLiveMessage {
    public static let firmwareTooOld = "This RNode's firmware is too old. Update it to 1.52 or later."
    public static let pairingRequired =
        "Pairing didn't finish. Hold the RNode's button for 5 to 10 seconds until it shows a PIN, then Connect and enter that PIN."
    public static let pairingRemoved =
        "This RNode no longer recognises this device. Forget the RNode in this device's Bluetooth settings, then pair again."
    public static let configurationRejectedPrefix = "The radio didn't accept these settings: "
    static let configurationRejectedSuffix = ". Change them in Settings, then Connect."

    /// One clause per mismatch, in the order given, joined by `, `.
    public static func configurationRejected(_ mismatches: [RNodeParameterMismatch]) -> String {
        configurationRejectedPrefix + mismatches.map(clause).joined(separator: ", ") + configurationRejectedSuffix
    }

    /// Exactly the four failures only the user can fix (a rejection matched by prefix). The app
    /// uses it to stop automatic re-dials until the user acts.
    public static func needsUserAction(_ text: String) -> Bool {
        text == firmwareTooOld || text == pairingRequired || text == pairingRemoved
            || text.hasPrefix(configurationRejectedPrefix)
    }

    private static func clause(_ mismatch: RNodeParameterMismatch) -> String {
        let field = mismatch.field
        // Always this clause, whatever the radio echoed, or didn't.
        if field == .radioState { return "the radio didn't turn on" }
        let asked = "(asked for \(value(mismatch.requested, field)))"
        guard let reported = mismatch.reported else { return "\(name(field)) no reply \(asked)" }
        return "\(name(field)) \(value(reported, field)) \(asked)"
    }

    private static func name(_ field: RNodeParameterMismatch.Field) -> String {
        switch field {
        case .frequency:       "frequency"
        case .bandwidth:       "bandwidth"
        case .txPower:         "TX power"
        case .spreadingFactor: "spreading factor"
        case .codingRate:      "coding rate"
        case .radioState:      "radio state"
        }
    }

    private static func value(_ value: UInt32, _ field: RNodeParameterMismatch.Field) -> String {
        switch field {
        case .frequency:                                     megahertz(value) + " MHz"
        case .bandwidth:                                     kilohertz(value) + " kHz"
        case .txPower:                                       "\(value) dBm"
        case .spreadingFactor, .codingRate, .radioState:     "\(value)"
        }
    }

    /// 868_100_000 → `868.1`, 868_000_000 → `868`.
    static func megahertz(_ hz: UInt32) -> String { decimal(hz, places: 6) }

    /// 62_500 → `62.5`, 125_000 → `125`.
    static func kilohertz(_ hz: UInt32) -> String { decimal(hz, places: 3) }

    /// `value / 10^places` in exact decimal, trailing zeros (and a bare point) dropped.
    private static func decimal(_ value: UInt32, places: Int) -> String {
        var divisor: UInt32 = 1
        for _ in 0..<places { divisor *= 10 }
        let whole = value / divisor
        var fraction = String(value % divisor)
        fraction = String(repeating: "0", count: places - fraction.count) + fraction
        while fraction.hasSuffix("0") { fraction.removeLast() }
        return fraction.isEmpty ? "\(whole)" : "\(whole).\(fraction)"
    }
}
