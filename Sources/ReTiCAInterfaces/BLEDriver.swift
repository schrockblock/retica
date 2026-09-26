import Foundation
import ComposableArchitecture

/// Locally-scoped handle for a remote device (wraps the CBPeer UUID). Pre-handshake identity —
/// plays the role the BLE address plays in ble-reticulum's Python.
public struct BLEPeerHandle: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

/// Opaque per-channel handle minted by the driver.
public struct BLEChannelID: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

public struct BLEDriverConfig: Equatable, Sendable {
    /// 16 bytes: served on the Identity characteristic and written as the handshake.
    public var localIdentity: Data
    public init(localIdentity: Data) { self.localIdentity = localIdentity }
}

/// Why the BLE adapter is unavailable. `isTerminal` separates causes retrying cannot fix
/// (`unauthorized`, `unsupported`) from transient ones (`poweredOff`, `other`).
public enum BLEAdapterUnavailable: Equatable, Sendable {
    case poweredOff
    case unauthorized
    case unsupported
    case other(String?)

    public var isTerminal: Bool {
        switch self {
        case .unauthorized, .unsupported: return true
        case .poweredOff, .other:         return false
        }
    }
}

public enum BLEDriverEvent: Equatable, Sendable {
    case ready
    case unavailable(BLEAdapterUnavailable)
    case peerDiscovered(BLEPeerHandle)
    /// Central role: the peer's Identity characteristic was read (16 bytes).
    case identityRead(BLEPeerHandle, identity: Data)
    case identityFailed(BLEPeerHandle, reason: String?)
    /// Outbound: after TX subscription + handshake write succeeded. Inbound: a central
    /// subscribed to our TX. `mtu` is the fragment size for this channel.
    case channelOpened(BLEChannelID, BLEPeerHandle, direction: BLEChannelDirection, mtu: Int)
    case channelFailed(BLEPeerHandle, reason: String?)
    /// One RX write (peripheral role) or one TX notification (central role).
    case channelData(BLEChannelID, Data)
    case channelClosed(BLEChannelID, reason: String?)
}

/// BLE driver dependency. Mechanism only — no policy, no retries, no fragmentation.
public struct BLEDriver: Sendable {
    public var start: @Sendable (BLEDriverConfig) -> AsyncStream<BLEDriverEvent>
    /// Connect, discover the v2.2 service, read Identity. Result arrives as identityRead/identityFailed.
    public var readIdentity: @Sendable (BLEPeerHandle) async -> Void
    /// Subscribe to TX and write our identity to RX. Result arrives as channelOpened/channelFailed.
    public var openChannel: @Sendable (BLEPeerHandle) async -> Void
    /// One packet's fragments — or a single keepalive — delivered in order and never interleaved with another call's fragments on the same channel. Central: sequential RX writes without response. Peripheral: TX notifies.
    public var send: @Sendable (BLEChannelID, [Data]) async -> Void
    public var closeChannel: @Sendable (BLEChannelID) async -> Void
    /// Tear down a peer that has NO open channel (cancel in-flight connect, drop the GATT link).
    public var disconnect: @Sendable (BLEPeerHandle) async -> Void
    public var stop: @Sendable () async -> Void

    public init(
        start: @escaping @Sendable (BLEDriverConfig) -> AsyncStream<BLEDriverEvent>,
        readIdentity: @escaping @Sendable (BLEPeerHandle) async -> Void,
        openChannel: @escaping @Sendable (BLEPeerHandle) async -> Void,
        send: @escaping @Sendable (BLEChannelID, [Data]) async -> Void,
        closeChannel: @escaping @Sendable (BLEChannelID) async -> Void,
        disconnect: @escaping @Sendable (BLEPeerHandle) async -> Void = { _ in },
        stop: @escaping @Sendable () async -> Void
    ) {
        self.start = start
        self.readIdentity = readIdentity
        self.openChannel = openChannel
        self.send = send
        self.closeChannel = closeChannel
        self.disconnect = disconnect
        self.stop = stop
    }
}

extension BLEDriver: DependencyKey {
    public static var liveValue: BLEDriver {
        #if canImport(CoreBluetooth) && (os(iOS) || os(macOS))
        return .fcb(central: .liveValue, peripheral: .liveValue)
        #else
        return BLEDriver(start: { _ in .finished }, readIdentity: { _ in }, openChannel: { _ in },
                         send: { _, _ in }, closeChannel: { _ in }, stop: {})
        #endif
    }

    public static let testValue = BLEDriver(
        start: unimplemented("BLEDriver.start", placeholder: AsyncStream { $0.finish() }),
        readIdentity: unimplemented("BLEDriver.readIdentity"),
        openChannel: unimplemented("BLEDriver.openChannel"),
        send: unimplemented("BLEDriver.send"),
        closeChannel: unimplemented("BLEDriver.closeChannel"),
        disconnect: unimplemented("BLEDriver.disconnect"),
        stop: unimplemented("BLEDriver.stop")
    )
}

extension DependencyValues {
    public var bleDriver: BLEDriver {
        get { self[BLEDriver.self] }
        set { self[BLEDriver.self] = newValue }
    }
}

// "now" for greylist / reassembly arithmetic. \.date's testValue is unimplemented in this TCA
// version, so a custom key (same pattern as Transport's \.transportDate).
private enum BLEDateKey: DependencyKey {
    static let liveValue = DateGenerator { Date() }
    static let testValue = DateGenerator { Date(timeIntervalSince1970: 0) }
    static let previewValue = liveValue
}
extension DependencyValues {
    public var bleDate: DateGenerator {
        get { self[BLEDateKey.self] }
        set { self[BLEDateKey.self] = newValue }
    }
}
