import Foundation

/// LXMF outbound delivery timing (RNS LXMRouter). Kept in core so the wire/behavior cross-validation
/// (which lives in the ReTiCA test target) can pin them against genuine LXMF; the LXMFRouter reducer
/// (ReTiCANode) references them.
public enum LXMFDelivery {
    /// Seconds between outbound delivery retries (RNS `LXMRouter.DELIVERY_RETRY_WAIT`).
    public static let retryWaitSeconds = 10

    /// The retry wait for a copy whose destination's next hop runs at `nextHopBitrate` bits/s:
    /// `max(retryWaitSeconds, ⌈4 · MTU·8 / b⌉)` — four MTU packets of airtime (2026-10-16
    /// Meshtastic spec, Contract 4). Rounded UP because router timers take whole seconds; never
    /// below the reference's fixed 10 s, so TCP and BLE are unchanged. `nil` or `≤ 0` (no path, no
    /// profile) → `retryWaitSeconds`.
    ///
    /// DELIBERATE DEVIATION from reference, which keeps `DELIVERY_RETRY_WAIT` fixed: at ~200 bps a
    /// 391-byte packet is ~24 s of airtime, so a fixed 10 s retry stacks duplicates on the medium.
    public static func retryWait(nextHopBitrate: Int?) -> Int {
        guard let bitrate = nextHopBitrate, bitrate > 0 else { return retryWaitSeconds }
        let airtime = (4.0 * Double(Packet.mtu * 8) / Double(bitrate)).rounded(.up)
        return max(retryWaitSeconds, Int(airtime))
    }
    /// Max delivery attempts before a message is failed (RNS `LXMRouter.MAX_DELIVERY_ATTEMPTS`).
    /// ReTiCA also reuses this as the ceiling on consecutive link-ESTABLISHMENT attempts per
    /// destination (`LXMFRouter.establish`), which has no counterpart in the reference constant —
    /// do not infer reference parity for that second use.
    public static let maxAttempts = 5
    /// The delivery-copy attempt at which a fallback-eligible message hands off to the propagation
    /// node (2026-10-21 propagation push spec, Amendment A2: about 20 s on TCP). Counts both the
    /// copy's retry attempts and its destination's link-establishment attempts. No reference
    /// counterpart: LXMF sends a message one way only.
    public static let propagationFallbackAfterAttempts = 3
    /// Seconds to wait after requesting a path before the next opportunistic delivery attempt (RNS
    /// `LXMRouter.PATH_REQUEST_WAIT`; distinct from `retryWaitSeconds`).
    public static let pathRequestWaitSeconds = 7
    /// Seconds a direct link may carry no LXMF traffic before the router tears it down — a higher GC
    /// than the Link-level keepalive watchdog (RNS `LXMRouter.LINK_MAX_INACTIVITY`).
    public static let linkMaxInactivitySeconds = 600
}
