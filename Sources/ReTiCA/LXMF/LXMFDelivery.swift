import Foundation

/// LXMF outbound delivery timing (RNS LXMRouter). Kept in core so the wire/behavior cross-validation
/// (which lives in the ReTiCA test target) can pin them against genuine LXMF; the LXMFRouter reducer
/// (ReTiCANode) references them.
public enum LXMFDelivery {
    /// Seconds between outbound delivery retries (RNS `LXMRouter.DELIVERY_RETRY_WAIT`).
    public static let retryWaitSeconds = 10
    /// Max delivery attempts before a message is failed (RNS `LXMRouter.MAX_DELIVERY_ATTEMPTS`).
    public static let maxAttempts = 5
    /// Seconds to wait after requesting a path before the next opportunistic delivery attempt — longer
    /// than `retryWaitSeconds` (RNS `LXMRouter.PATH_REQUEST_WAIT`).
    public static let pathRequestWaitSeconds = 7
}
