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

            case let .driverEvent(.channelOpened(channelID, handle, direction)):
                var effects: [Effect<Action>] = []
                if direction == .outbound {
                    state.pendingPeers.remove(handle)
                    effects.append(.cancel(id: CancelID.establish(handle)))
                }
                let now = date()
                guard state.status == .online,
                      let token = state.sessionToken,
                      state.peers.count < state.maxPeers,
                      !state.greylist.isBlocked(handle, now: now)
                else {
                    effects.append(.run { [bleDriver] _ in await bleDriver.closeChannel(channelID) })
                    return .merge(effects)
                }
                state.channels[channelID] = ChannelState(
                    peer: handle, direction: direction,
                    frameBuffer: BLEFrameBuffer(), peerToken: nil, openedAt: now)
                // 20-byte HELLO framed by hand — cannot exceed frame bounds, no throw.
                var hello = Data([0x00, UInt8(BLEHello.length)])
                hello.append(BLEHello.pack(version: Self.protocolVersion, token: token))
                let framedHello = hello
                effects.append(.run { [bleDriver] _ in await bleDriver.send(channelID, framedHello) })
                effects.append(.run { [clock] send in
                    try await clock.sleep(for: Self.helloTimeout)
                    await send(.helloDeadline(channelID))
                }
                .cancellable(id: CancelID.hello(channelID), cancelInFlight: true))
                return .merge(effects)

            case let .driverEvent(.channelData(channelID, bytes)):
                guard var channel = state.channels[channelID] else { return .none }
                let frames: [Data]
                do {
                    frames = try channel.frameBuffer.append(bytes)
                    state.channels[channelID] = channel
                } catch {
                    state.channels[channelID] = channel
                    return tearDown(&state, channelID: channelID, strike: true)
                }
                var effects: [Effect<Action>] = []
                for frame in frames {
                    guard let current = state.channels[channelID] else { break }
                    if let token = current.peerToken {
                        effects.append(.send(.delegate(.packetReceived(peer: token, packet: frame))))
                        continue
                    }
                    // First frame must be a valid v2 HELLO that is not our own echo.
                    guard let hello = BLEHello.parse(frame),
                          hello.version == Self.protocolVersion,
                          hello.token != state.sessionToken
                    else {
                        effects.append(tearDown(&state, channelID: channelID, strike: true))
                        continue  // channel gone; loop guard drops remaining frames
                    }
                    effects.append(.cancel(id: CancelID.hello(channelID)))
                    let token = hello.token
                    if let existingID = state.peers[token],
                       let existing = state.channels[existingID],
                       existingID != channelID {
                        let resolution = bleResolveDuplicate(
                            localToken: state.sessionToken ?? Data(),
                            peerToken: token,
                            existingDirection: existing.direction,
                            newDirection: current.direction)
                        switch resolution {
                        case .keepExisting:
                            // Close the new channel quietly: never online, no strike.
                            state.channels[channelID] = nil
                            effects.append(.run { [bleDriver] _ in
                                await bleDriver.closeChannel(channelID)
                            })
                        case .keepNew:
                            // Swap channels under the peer without an offline blip.
                            state.channels[existingID] = nil
                            effects.append(.cancel(id: CancelID.hello(existingID)))
                            effects.append(.run { [bleDriver] _ in
                                await bleDriver.closeChannel(existingID)
                            })
                            var updated = current
                            updated.peerToken = token
                            state.channels[channelID] = updated
                            state.peers[token] = channelID
                        }
                    } else {
                        var updated = current
                        updated.peerToken = token
                        state.channels[channelID] = updated
                        state.peers[token] = channelID
                        effects.append(.send(.delegate(.peerOnline(token))))
                    }
                }
                return .merge(effects)

            case let .send(peer, packet):
                guard let channelID = state.peers[peer],
                      let framed = try? BLEFraming.frame(packet)
                else { return .none }
                return .run { [bleDriver] _ in await bleDriver.send(channelID, framed) }

            case let .helloDeadline(channelID):
                guard let channel = state.channels[channelID], channel.peerToken == nil
                else { return .none }
                return tearDown(&state, channelID: channelID, strike: true)

            case let .driverEvent(.channelClosed(channelID, _)):
                guard let channel = state.channels.removeValue(forKey: channelID) else { return .none }
                var effects: [Effect<Action>] = [.cancel(id: CancelID.hello(channelID))]
                if let token = channel.peerToken, state.peers[token] == channelID {
                    state.peers[token] = nil
                    effects.append(.send(.delegate(.peerOffline(token))))
                }
                let now = date()
                if now.timeIntervalSince(channel.openedAt) < Self.churnMinLifetime {
                    state.greylist.recordFailure(channel.peer, now: now)
                }
                return .merge(effects)

            case .driverEvent(.unavailable):
                guard state.status != .stopped else { return .none }
                let established = Array(state.peers.keys)
                let channelIDs = Array(state.channels.keys)
                let pending = Array(state.pendingPeers)
                state.channels = [:]
                state.peers = [:]
                state.pendingPeers = []
                state.status = .waitingForAdapter
                let delay = state.adapterRetryDelay
                state.adapterRetryDelay = min(delay * 2, Self.adapterRetryMax)
                var effects: [Effect<Action>] = [.cancel(id: CancelID.driver)]
                effects += channelIDs.map { .cancel(id: CancelID.hello($0)) }
                effects += pending.map { .cancel(id: CancelID.establish($0)) }
                effects += established.map { .send(.delegate(.peerOffline($0))) }
                effects.append(.run { [clock] send in
                    try await clock.sleep(for: delay)
                    await send(.adapterRetry)
                }
                .cancellable(id: CancelID.retry, cancelInFlight: true))
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

    /// Removes a channel, closes it at the driver, emits peerOffline if it was the
    /// established channel for a peer, and optionally records a greylist strike.
    private func tearDown(_ state: inout State, channelID: BLEChannelID, strike: Bool) -> Effect<Action> {
        guard let channel = state.channels.removeValue(forKey: channelID) else { return .none }
        var effects: [Effect<Action>] = [
            .cancel(id: CancelID.hello(channelID)),
            .run { [bleDriver] _ in await bleDriver.closeChannel(channelID) },
        ]
        if let token = channel.peerToken, state.peers[token] == channelID {
            state.peers[token] = nil
            effects.append(.send(.delegate(.peerOffline(token))))
        }
        if strike {
            state.greylist.recordFailure(channel.peer, now: date())
        }
        return .merge(effects)
    }
}
