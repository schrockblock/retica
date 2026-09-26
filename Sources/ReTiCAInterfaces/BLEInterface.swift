import Foundation
import ComposableArchitecture
import ReTiCA

public enum BLEInterfaceStatus: Equatable, Sendable {
    case stopped, starting, online, waitingForAdapter
    /// Terminal: the adapter is unavailable for a reason retrying cannot fix. A fresh `.start` leaves it.
    case unavailable(BLEAdapterUnavailable)

    var isUnavailableTerminal: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// The Reticulum BLE interface speaking ble-reticulum protocol v2.2. Parent lifecycle + all policy:
/// discovery gating, establishment, identity handshake, duplicate resolution, fragmentation,
/// greylist, peer cap, keepalive, adapter-loss recovery. The driver underneath is mechanism only.
@Reducer
public struct BLEInterface {
    public static let defaultMaxPeers = 7
    public static let establishTimeout: Duration = .seconds(15)
    public static let handshakeTimeout: Duration = .seconds(10)
    public static let defaultKeepaliveInterval: Duration = .seconds(15)
    public static let churnMinLifetime: TimeInterval = 10
    public static let adapterRetryMin: Duration = .seconds(5)
    public static let adapterRetryMax: Duration = .seconds(120)

    public struct ChannelState: Equatable, Sendable {
        public var peer: BLEPeerHandle
        public var direction: BLEChannelDirection
        var fragmenter: BLEFragmenter
        var reassembler: BLEReassembler
        /// Outbound: set at channelOpened (from identityRead). Inbound: nil until the handshake.
        var peerIdentity: Data?
        var openedAt: Date
    }

    @ObservableState
    public struct State: Equatable {
        public var status: BLEInterfaceStatus = .stopped
        public var maxPeers: Int
        /// This node's 16-byte identity hash — served on Identity and sent as the handshake.
        public let localIdentity: Data
        /// Outbound-channel keepalive cadence; nil disables (spec §2.6).
        public var keepaliveInterval: Duration?
        var channels: [BLEChannelID: ChannelState] = [:]
        var peers: [Data: BLEChannelID] = [:]            // established peers by identity
        var pendingPeers: Set<BLEPeerHandle> = []        // establishment in flight
        var pendingIdentities: [BLEPeerHandle: Data] = [:]  // identity read, channel not yet open
        var greylist = BLEPeerGreylist<BLEPeerHandle>()
        var adapterRetryDelay: Duration = BLEInterface.adapterRetryMin

        public init(localIdentity: Data,
                    maxPeers: Int = BLEInterface.defaultMaxPeers,
                    keepaliveInterval: Duration? = BLEInterface.defaultKeepaliveInterval) {
            precondition(localIdentity.count == BLEProtocol.identityLength, "localIdentity must be 16 bytes")
            self.localIdentity = localIdentity
            self.maxPeers = maxPeers
            self.keepaliveInterval = keepaliveInterval
        }
    }

    public enum Action: Equatable {
        case start
        case stop
        case driverEvent(BLEDriverEvent)
        case send(peer: Data, packet: Data)
        case handshakeDeadline(BLEChannelID)
        case establishDeadline(BLEPeerHandle)
        case keepalive(BLEChannelID)
        case adapterRetry
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case peerOnline(Data)
            case peerOffline(Data)
            case packetReceived(peer: Data, packet: Data)
            case sendFailed(peer: Data, reason: SendFailedReason)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
        public enum SendFailedReason: Equatable {
            /// Empty packet or more than 65 535 fragments: a programmer error, not a lifecycle race.
            case unfragmentable
        }
    }

    @Dependency(\.bleDriver) var bleDriver
    @Dependency(\.continuousClock) var clock
    @Dependency(\.bleDate) var date

    private enum CancelID: Hashable {
        case driver, retry
        case handshake(BLEChannelID)
        case keepalive(BLEChannelID)
        case establish(BLEPeerHandle)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                guard state.status == .stopped || state.status.isUnavailableTerminal else { return .none }
                state.status = .starting
                return startDriver(state: &state)

            case .stop:
                let established = Array(state.peers.keys)
                let channelIDs = Array(state.channels.keys)
                let pending = Array(state.pendingPeers)
                state.channels = [:]
                state.peers = [:]
                state.pendingPeers = []
                state.pendingIdentities = [:]
                state.adapterRetryDelay = Self.adapterRetryMin
                state.status = .stopped
                var effects: [Effect<Action>] = [.cancel(id: CancelID.driver), .cancel(id: CancelID.retry)]
                effects += channelIDs.flatMap { [.cancel(id: CancelID.handshake($0)), .cancel(id: CancelID.keepalive($0))] }
                effects += pending.map { .cancel(id: CancelID.establish($0)) }
                effects.append(.run { [bleDriver] _ in await bleDriver.stop() })
                effects += established.map { .send(.delegate(.peerOffline($0))) }
                return .merge(effects)

            case .driverEvent(.ready):
                state.status = .online
                state.adapterRetryDelay = Self.adapterRetryMin
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
                    .run { [bleDriver] _ in await bleDriver.readIdentity(handle) },
                    .run { [clock] send in
                        try await clock.sleep(for: Self.establishTimeout)
                        await send(.establishDeadline(handle))
                    }
                    .cancellable(id: CancelID.establish(handle), cancelInFlight: true)
                )

            case let .driverEvent(.identityRead(handle, identity)):
                guard state.pendingPeers.contains(handle) else { return .none }
                guard identity.count == BLEProtocol.identityLength, identity != state.localIdentity else {
                    state.pendingPeers.remove(handle)
                    state.greylist.recordFailure(handle, now: date())
                    return .merge(.cancel(id: CancelID.establish(handle)),
                                  .run { [bleDriver] _ in await bleDriver.disconnect(handle) })
                }
                // Cheap pre-check (ble-reticulum does the same before dialing): if this identity
                // already has a channel the duplicate rule would keep, don't open a second one.
                if let existingID = state.peers[identity], let existing = state.channels[existingID],
                   bleResolveDuplicate(localToken: state.localIdentity, peerToken: identity,
                                       existingDirection: existing.direction, newDirection: .outbound) == .keepExisting {
                    state.pendingPeers.remove(handle)
                    return .merge(.cancel(id: CancelID.establish(handle)),
                                  .run { [bleDriver] _ in await bleDriver.disconnect(handle) })
                }
                state.pendingIdentities[handle] = identity
                return .run { [bleDriver] _ in await bleDriver.openChannel(handle) }

            case let .driverEvent(.identityFailed(handle, _)),
                 let .driverEvent(.channelFailed(handle, _)):
                guard state.pendingPeers.contains(handle) else { return .none }
                state.pendingPeers.remove(handle)
                state.pendingIdentities[handle] = nil
                if !hasEstablishedChannel(state, handle) {
                    state.greylist.recordFailure(handle, now: date())
                }
                return .cancel(id: CancelID.establish(handle))

            case let .establishDeadline(handle):
                guard state.pendingPeers.contains(handle) else { return .none }
                state.pendingPeers.remove(handle)
                state.pendingIdentities[handle] = nil
                // The peer came in the other way while we were dialing: leave its link alone.
                if hasEstablishedChannel(state, handle) { return .none }
                state.greylist.recordFailure(handle, now: date())
                return .run { [bleDriver] _ in await bleDriver.disconnect(handle) }

            case let .driverEvent(.channelOpened(channelID, handle, direction, mtu)):
                var effects: [Effect<Action>] = []
                var pendingIdentity: Data? = nil
                if direction == .outbound {
                    state.pendingPeers.remove(handle)
                    pendingIdentity = state.pendingIdentities.removeValue(forKey: handle)
                    effects.append(.cancel(id: CancelID.establish(handle)))
                }
                let now = date()
                guard state.status == .online,
                      state.peers.count < state.maxPeers,
                      !state.greylist.isBlocked(handle, now: now),
                      direction == .inbound || pendingIdentity != nil
                else {
                    effects.append(.run { [bleDriver] _ in await bleDriver.closeChannel(channelID) })
                    return .merge(effects)
                }
                state.channels[channelID] = ChannelState(
                    peer: handle, direction: direction,
                    fragmenter: BLEFragmenter(mtu: mtu), reassembler: BLEReassembler(),
                    peerIdentity: nil, openedAt: now)
                switch direction {
                case .outbound:
                    effects.append(establish(&state, channelID: channelID, identity: pendingIdentity!))
                case .inbound:
                    effects.append(.run { [clock] send in
                        try await clock.sleep(for: Self.handshakeTimeout)
                        await send(.handshakeDeadline(channelID))
                    }
                    .cancellable(id: CancelID.handshake(channelID), cancelInFlight: true))
                }
                return .merge(effects)

            case let .driverEvent(.channelData(channelID, bytes)):
                guard var channel = state.channels[channelID] else { return .none }
                if BLEKeepalive.isKeepalive(bytes) { return .none }
                guard channel.peerIdentity != nil else {
                    // Inbound, pre-handshake: only a 16-byte write that is not our own identity counts.
                    guard bytes.count == BLEProtocol.identityLength, bytes != state.localIdentity else { return .none }
                    return .merge(.cancel(id: CancelID.handshake(channelID)),
                                  establish(&state, channelID: channelID, identity: Data(bytes)))
                }
                let packet: Data?
                do {
                    packet = try channel.reassembler.receive(bytes, now: date())
                } catch {
                    packet = nil   // malformed: that packet's buffer is gone, the channel stays up
                }
                state.channels[channelID] = channel
                guard let packet, let identity = channel.peerIdentity else { return .none }
                return .send(.delegate(.packetReceived(peer: identity, packet: packet)))

            case let .send(peer, packet):
                guard let channelID = state.peers[peer], let channel = state.channels[channelID] else { return .none }
                guard let fragments = try? channel.fragmenter.fragment(packet) else {
                    return .send(.delegate(.sendFailed(peer: peer, reason: .unfragmentable)))
                }
                return .run { [bleDriver] _ in await bleDriver.send(channelID, fragments) }

            case let .keepalive(channelID):
                guard let channel = state.channels[channelID], channel.direction == .outbound,
                      channel.peerIdentity != nil else { return .none }
                return .run { [bleDriver] _ in await bleDriver.send(channelID, [BLEKeepalive.frame]) }

            case let .handshakeDeadline(channelID):
                guard let channel = state.channels[channelID], channel.peerIdentity == nil else { return .none }
                return tearDown(&state, channelID: channelID, strike: true)

            case let .driverEvent(.channelClosed(channelID, _)):
                guard let channel = state.channels.removeValue(forKey: channelID) else { return .none }
                var effects: [Effect<Action>] = [.cancel(id: CancelID.handshake(channelID)),
                                                 .cancel(id: CancelID.keepalive(channelID))]
                if let identity = channel.peerIdentity, state.peers[identity] == channelID {
                    state.peers[identity] = nil
                    effects.append(.send(.delegate(.peerOffline(identity))))
                }
                let now = date()
                if now.timeIntervalSince(channel.openedAt) < Self.churnMinLifetime {
                    state.greylist.recordFailure(channel.peer, now: now)
                }
                return .merge(effects)

            case let .driverEvent(.unavailable(cause)):
                guard state.status != .stopped else { return .none }
                let established = Array(state.peers.keys)
                let channelIDs = Array(state.channels.keys)
                let pending = Array(state.pendingPeers)
                state.channels = [:]
                state.peers = [:]
                state.pendingPeers = []
                state.pendingIdentities = [:]
                var effects: [Effect<Action>] = [.cancel(id: CancelID.driver)]
                effects += channelIDs.flatMap { [.cancel(id: CancelID.handshake($0)), .cancel(id: CancelID.keepalive($0))] }
                effects += pending.map { .cancel(id: CancelID.establish($0)) }
                effects += established.map { .send(.delegate(.peerOffline($0))) }
                if cause.isTerminal {
                    state.status = .unavailable(cause)
                    effects.append(.cancel(id: CancelID.retry))
                    effects.append(.send(.delegate(.adapterUnavailable(cause))))
                } else {
                    state.status = .waitingForAdapter
                    let delay = state.adapterRetryDelay
                    state.adapterRetryDelay = min(delay * 2, Self.adapterRetryMax)
                    effects.append(.run { [clock] send in
                        try await clock.sleep(for: delay)
                        await send(.adapterRetry)
                    }
                    .cancellable(id: CancelID.retry, cancelInFlight: true))
                }
                return .merge(effects)

            case .adapterRetry:
                guard state.status == .waitingForAdapter else { return .none }
                state.status = .starting
                return startDriver(state: &state)

            case .delegate:
                return .none
            }
        }
    }

    private func hasEstablishedChannel(_ state: State, _ handle: BLEPeerHandle) -> Bool {
        state.channels.values.contains { $0.peer == handle && $0.peerIdentity != nil }
    }

    private func startDriver(state: inout State) -> Effect<Action> {
        let config = BLEDriverConfig(localIdentity: state.localIdentity)
        return .run { [bleDriver] send in
            for await event in bleDriver.start(config) {
                await send(.driverEvent(event))
            }
        }
        .cancellable(id: CancelID.driver, cancelInFlight: true)
    }

    /// Marks `channelID` established for `identity`: runs the duplicate rule against any existing
    /// channel for that identity, registers the survivor, emits `peerOnline` for a new peer, and
    /// arms the keepalive on outbound channels.
    private func establish(_ state: inout State, channelID: BLEChannelID, identity: Data) -> Effect<Action> {
        guard var current = state.channels[channelID] else { return .none }
        var effects: [Effect<Action>] = []
        if let existingID = state.peers[identity], let existing = state.channels[existingID], existingID != channelID {
            switch bleResolveDuplicate(localToken: state.localIdentity, peerToken: identity,
                                       existingDirection: existing.direction, newDirection: current.direction) {
            case .keepExisting:
                state.channels[channelID] = nil
                effects.append(.run { [bleDriver] _ in await bleDriver.closeChannel(channelID) })
                return .merge(effects)
            case .keepNew:
                state.channels[existingID] = nil
                effects.append(.cancel(id: CancelID.handshake(existingID)))
                effects.append(.cancel(id: CancelID.keepalive(existingID)))
                effects.append(.run { [bleDriver] _ in await bleDriver.closeChannel(existingID) })
                current.peerIdentity = identity
                state.channels[channelID] = current
                state.peers[identity] = channelID
            }
        } else {
            current.peerIdentity = identity
            state.channels[channelID] = current
            state.peers[identity] = channelID
            effects.append(.send(.delegate(.peerOnline(identity))))
        }
        if current.direction == .outbound, let interval = state.keepaliveInterval {
            effects.append(.run { [clock] send in
                while true {
                    try await clock.sleep(for: interval)
                    await send(.keepalive(channelID))
                }
            }
            .cancellable(id: CancelID.keepalive(channelID), cancelInFlight: true))
        }
        return .merge(effects)
    }

    private func tearDown(_ state: inout State, channelID: BLEChannelID, strike: Bool) -> Effect<Action> {
        guard let channel = state.channels.removeValue(forKey: channelID) else { return .none }
        var effects: [Effect<Action>] = [
            .cancel(id: CancelID.handshake(channelID)),
            .cancel(id: CancelID.keepalive(channelID)),
            .run { [bleDriver] _ in await bleDriver.closeChannel(channelID) },
        ]
        if let identity = channel.peerIdentity, state.peers[identity] == channelID {
            state.peers[identity] = nil
            effects.append(.send(.delegate(.peerOffline(identity))))
        }
        if strike { state.greylist.recordFailure(channel.peer, now: date()) }
        return .merge(effects)
    }
}
