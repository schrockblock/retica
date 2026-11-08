import Foundation
import MeshCoreKit
import ReTiCAInterfaces

/// The three slot policy failures (spec Contract 2). Each one disconnects the radio and stops
/// automatic restarts, so the app needs to recognise them by text.
public enum MeshCoreLiveMessage {
    public static let noFreeSlot = "No free channel slot on this radio"
    public static let firmwareTooOld = "This radio's firmware is too old; update to v1.15 or later"
    public static let channelSetupFailed = "Couldn't set up the channel on this radio"

    /// True for exactly the three policy messages.
    public static func isPolicyFailure(_ text: String) -> Bool {
        text == noFreeSlot || text == firmwareTooOld || text == channelSetupFailed
    }
}

/// What the adapter should do with one kit event.
enum MeshCoreLiveStep: Equatable {
    case ignore
    case emit(MeshCoreDriverEvent)
    /// A handshake completed: run the slot policy, then `slotReady` and emit `connected(_:)`.
    case configure(MeshCoreRadioInfo)
}

/// Folds ONE subscription's events into driver events. The kit replays the session's current
/// connection state to every new subscriber, so after a terminal end the replay is a stale
/// `.disconnected("radio not found")`. `start`'s connect always emits `.connection(.connecting)`
/// first, so everything before this subscription's first `.connecting` is replay and is dropped.
///
/// `.connected` is never taken from `.connection(.connected)`: it comes from the adapter after
/// `.configured` and the slot policy. Every `.frame` is ignored (Contract 1: map `.frame` OR the
/// typed cases, and this maps the typed ones).
struct MeshCoreEventMapper: Equatable {
    private let dataType: UInt16
    private var sawConnecting = false
    private var slot: UInt8?

    init(dataType: UInt16) {
        self.dataType = dataType
    }

    /// The adapter calls this once our channel slot is usable.
    mutating func slotReady(_ index: UInt8) {
        slot = index
    }

    /// Adapter ends that follow an `.adapterUnavailable` event, so they stay plain drops.
    private static let adapterEndReasons: Set<String> = ["unauthorized", "unsupported"]

    mutating func map(_ event: MeshCoreEvent) -> MeshCoreLiveStep {
        if !sawConnecting {
            if case .connection(.connecting) = event { sawConnecting = true }
            return .ignore
        }
        switch event {
        case let .configured(info):
            slot = nil
            return .configure(info)
        case let .channelData(index, type, payload):
            guard let slot, index == slot, type == dataType else { return .ignore }
            return .emit(.datagram(payload))
        case let .rawData(payload):
            guard slot != nil else { return .ignore }
            return .emit(.datagram(payload))
        case .connection(.reconnecting), .connection(.disconnected(reason: nil)):
            slot = nil
            return .emit(.disconnected(reason: nil))
        case let .connection(.disconnected(reason?)):
            slot = nil
            if Self.adapterEndReasons.contains(reason) { return .ignore }
            if reason == MeshCoreSession.firmwareTooOldReason {
                return .emit(.unavailable(.other(MeshCoreLiveMessage.firmwareTooOld)))
            }
            return .emit(.unavailable(.other(reason)))
        case let .adapterUnavailable(cause):
            return .emit(.unavailable(Self.bleCause(cause)))
        case .connection(.connecting), .connection(.configuring), .connection(.connected), .frame:
            return .ignore
        }
    }

    static func connected(_ info: MeshCoreRadioInfo) -> MeshCoreDriverEvent {
        .connected(selfPrefix: info.publicKey.prefix(4), publicKey: info.publicKey,
                   params: MeshCoreLinkParams(spreadingFactor: info.spreadingFactor,
                                              bandwidthHz: info.bandwidthHz,
                                              codingRate: info.codingRate))
    }

    static func bleCause(_ cause: MeshCoreAdapterUnavailable) -> BLEAdapterUnavailable {
        switch cause {
        case .poweredOff:        return .poweredOff
        case .unauthorized:      return .unauthorized
        case .unsupported:       return .unsupported
        case let .other(detail): return .other(detail)
        }
    }
}
