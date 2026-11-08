import Foundation

/// LoRa airtime and the pacing derived from it (spec §5.4). The one source for the sender's
/// fragment delay and for the interface profile's bitrate.
public enum MeshCoreLinkPacing {
    /// Firmware accepts SF 5-12, CR 5-8 (the denominator) and bandwidth 7000-500000 Hz
    /// (`MyMesh.cpp:1441-1442`).
    public static func isInRange(_ params: MeshCoreLinkParams) -> Bool {
        (5...12).contains(params.spreadingFactor)
            && (5...8).contains(params.codingRate)
            && (7000...500_000).contains(params.bandwidthHz)
    }

    /// Semtech time-on-air in milliseconds for `payloadBytes`, with CRC and an explicit header.
    /// Low-data-rate optimise is on when the symbol time is at least 16 ms. `cr` is the
    /// denominator (5-8), used directly in place of Semtech's `CR + 4`. Precondition: in range.
    public static func airtimeMilliseconds(_ params: MeshCoreLinkParams, payloadBytes: Int = 181) -> Double {
        let sf = Double(params.spreadingFactor)
        let cr = Double(params.codingRate)
        let tsym = pow(2.0, sf) / Double(params.bandwidthHz) * 1000.0
        let de = tsym >= 16 ? 1.0 : 0.0
        let preamble = params.spreadingFactor <= 8 ? 32.0 : 16.0
        let blocks = ((8.0 * Double(payloadBytes) - 4.0 * sf + 44.0) / (4.0 * (sf - 2.0 * de))).rounded(.up)
        let payloadSymbols = 8.0 + max(blocks * cr, 0)
        return (preamble + 4.25) * tsym + payloadSymbols * tsym
    }

    /// `max(2.5 s, 2 x airtime(181 B))`; nil or out-of-range params give 5 s.
    public static func fragmentDelaySeconds(_ params: MeshCoreLinkParams?) -> Double {
        guard let params, isInRange(params) else { return 5 }
        return max(2.5, 2 * airtimeMilliseconds(params) / 1000)
    }

    /// `fragmentDelaySeconds` rounded up to whole milliseconds.
    public static func fragmentDelay(_ params: MeshCoreLinkParams?) -> Duration {
        .milliseconds(Int((fragmentDelaySeconds(params) * 1000).rounded(.up)))
    }

    /// `Int(148 * 8 / seconds)`, from the unrounded delay. Always positive.
    public static func bitrate(_ params: MeshCoreLinkParams?) -> Int {
        Int(148 * 8 / fragmentDelaySeconds(params))
    }
}
