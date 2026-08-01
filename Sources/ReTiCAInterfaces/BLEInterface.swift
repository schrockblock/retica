import Foundation
import ComposableArchitecture
import ReTiCA

public enum BLEInterfaceStatus: Equatable, Sendable {
    case stopped, starting, online, waitingForAdapter
}

/// The Reticulum BLE interface (RBTP v2, Apple profile). Parent lifecycle + all policy:
/// discovery gating, establishment, HELLO/dedup, data plane, greylist, peer cap,
/// adapter-loss recovery. The driver underneath is mechanism only.
@Reducer
public struct BLEInterface {
    public static let protocolVersion: UInt8 = 2
    public static let defaultMaxPeers = 7
    public static let establishTimeout: Duration = .seconds(15)
    public static let helloTimeout: Duration = .seconds(10)
    public static let churnMinLifetime: TimeInterval = 10
    public static let adapterRetryMin: Duration = .seconds(5)
    public static let adapterRetryMax: Duration = .seconds(120)

    public struct ChannelState: Equatable, Sendable {
        public var peer: BLEPeerHandle
        public var direction: BLEChannelDirection
        var frameBuffer: BLEFrameBuffer
        var peerToken: Data?     // nil until a valid HELLO arrives
        var openedAt: Date
    }

    @ObservableState
    public struct State: Equatable {
        public var status: BLEInterfaceStatus = .stopped
        public var maxPeers: Int
        public var pairingMode: BLEPairingMode
        public internal(set) var sessionToken: Data?
        var channels: [BLEChannelID: ChannelState] = [:]
        var peers: [Data: BLEChannelID] = [:]      // established peers by token
        var pendingPeers: Set<BLEPeerHandle> = []  // establishment in flight
        var greylist = BLEPeerGreylist<BLEPeerHandle>()
        var adapterRetryDelay: Duration = BLEInterface.adapterRetryMin

        public init(maxPeers: Int = BLEInterface.defaultMaxPeers,
                    pairingMode: BLEPairingMode = .open) {
            self.maxPeers = maxPeers
            self.pairingMode = pairingMode
        }
    }

    public enum Action: Equatable {
        case start
        case stop
        case driverEvent(BLEDriverEvent)
        case send(peer: Data, packet: Data)
        case helloDeadline(BLEChannelID)
        case establishDeadline(BLEPeerHandle)
        case adapterRetry
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case peerOnline(Data)
            case peerOffline(Data)
            case packetReceived(peer: Data, packet: Data)
        }
    }

    @Dependency(\.bleDriver) var bleDriver
    @Dependency(\.continuousClock) var clock
    @Dependency(\.bleDate) var date
    @Dependency(\.bleRandomBytes) var randomBytes

    private enum CancelID: Hashable {
        case driver, retry
        case hello(BLEChannelID)
        case establish(BLEPeerHandle)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                guard state.status == .stopped else { return .none }
                state.sessionToken = randomBytes(BLEHello.tokenLength)
                state.status = .starting
                return startDriver(state: &state)

            case .stop:
                let established = Array(state.peers.keys)
                let channelIDs = Array(state.channels.keys)
                let pending = Array(state.pendingPeers)
                state.channels = [:]
                state.peers = [:]
                state.pendingPeers = []
                state.sessionToken = nil
                state.adapterRetryDelay = Self.adapterRetryMin
                state.status = .stopped
                var effects: [Effect<Action>] = [
                    .cancel(id: CancelID.driver),
                    .cancel(id: CancelID.retry),
                ]
                effects += channelIDs.map { .cancel(id: CancelID.hello($0)) }
                effects += pending.map { .cancel(id: CancelID.establish($0)) }
                effects.append(.run { [bleDriver] _ in await bleDriver.stop() })
                effects += established.map { .send(.delegate(.peerOffline($0))) }
                return .merge(effects)

            case .driverEvent(.ready):
                state.status = .online
                state.adapterRetryDelay = Self.adapterRetryMin
                return .none

            // Stubs — implemented in Tasks 5–7.
            case .driverEvent(.unavailable):
                return .none

            case let .driverEvent(.peerDiscovered(handle)):
                guard state.status == .online,
                      !state.pendingPeers.contains(handle),
                      !state.channels.values.contains(where: { $0.peer == handle }),
                      state.peers.count + state.pendingPeers.count < state.maxPeers,
                      !state.greylist.isBlocked(handle, now: date())
                else { return .none }
                state.pendingPeers.insert(handle)
                return .merge(
                    .run { [bleDriver] _ in await bleDriver.readDirectory(handle) },
                    .run { [clock] send in
                        try await clock.sleep(for: Self.establishTimeout)
                        await send(.establishDeadline(handle))
                    }
                    .cancellable(id: CancelID.establish(handle), cancelInFlight: true)
                )

            case let .driverEvent(.directoryRead(handle, version, psm)):
                guard state.pendingPeers.contains(handle) else { return .none }
                guard version == Self.protocolVersion else {
                    state.pendingPeers.remove(handle)
                    state.greylist.recordFailure(handle, now: date())
                    return .cancel(id: CancelID.establish(handle))
                }
                return .run { [bleDriver] _ in await bleDriver.openChannel(handle, psm) }

            case let .driverEvent(.directoryFailed(handle, _)),
                 let .driverEvent(.channelFailed(handle, _)):
                guard state.pendingPeers.contains(handle) else { return .none }
                state.pendingPeers.remove(handle)
                state.greylist.recordFailure(handle, now: date())
                return .cancel(id: CancelID.establish(handle))

            case let .establishDeadline(handle):
                guard state.pendingPeers.contains(handle) else { return .none }
                state.pendingPeers.remove(handle)
                state.greylist.recordFailure(handle, now: date())
                return .none

            case .driverEvent(.channelOpened):
                return .none
            case .driverEvent(.channelData):
                return .none
            case .driverEvent(.channelClosed):
                return .none
            case .send:
                return .none
            case .helloDeadline:
                return .none
            case .adapterRetry:
                return .none

            case .delegate:
                return .none
            }
        }
    }

    /// Subscribes to the driver's event stream (used by .start and, later, .adapterRetry).
    private func startDriver(state: inout State) -> Effect<Action> {
        let config = BLEDriverConfig(version: Self.protocolVersion, pairingMode: state.pairingMode)
        return .run { [bleDriver] send in
            for await event in bleDriver.start(config) {
                await send(.driverEvent(event))
            }
        }
        .cancellable(id: CancelID.driver, cancelInFlight: true)
    }
}
