import Foundation

/// LXMF outbound delivery timing (RNS LXMRouter). Kept in core so the wire/behavior cross-validation
/// (which lives in the ReTiCA test target) can pin them against genuine LXMF; the LXMFRouter reducer
/// (ReTiCANode) references them.
public enum LXMFDelivery {
    /// Seconds between outbound delivery retries (RNS `LXMRouter.DELIVERY_RETRY_WAIT`).
    public static let retryWaitSeconds = 10
    /// Max delivery attempts before a message is failed (RNS `LXMRouter.MAX_DELIVERY_ATTEMPTS`).
    /// ReTiCA also reuses this as the ceiling on consecutive link-ESTABLISHMENT attempts per
    /// destination (`LXMFRouter.establish`), which has no counterpart in the reference constant —
    /// do not infer reference parity for that second use.
    public static let maxAttempts = 5
    /// Seconds to wait after requesting a path before the next opportunistic delivery attempt (RNS
    /// `LXMRouter.PATH_REQUEST_WAIT`; distinct from `retryWaitSeconds`).
    public static let pathRequestWaitSeconds = 7
    /// Seconds a direct link may carry no LXMF traffic before the router tears it down — a higher GC
    /// than the Link-level keepalive watchdog (RNS `LXMRouter.LINK_MAX_INACTIVITY`).
    public static let linkMaxInactivitySeconds = 600
}
