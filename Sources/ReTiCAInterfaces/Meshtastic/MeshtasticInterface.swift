import Foundation
import ComposableArchitecture

/// Where a `MeshtasticInterface` is in its radio lifecycle.
public enum MeshtasticInterfaceStatus: Equatable, Sendable {
    /// Not started, or stopped by `.stop`.
    case stopped
    /// Started, waiting for the driver's `.connected` (first connect, or after a drop —
    /// reconnecting is MeshtasticKit's job; the interface only waits).
    case connecting
    /// The radio finished its handshake. `modemPreset` is the raw `Config.LoRaConfig.ModemPreset`.
    case online(myNodeNum: UInt32, modemPreset: Int?)
    /// The driver reported the adapter unavailable. A fresh `.start` leaves this state.
    case unavailable(BLEAdapterUnavailable)
}

/// Reticulum over ONE Meshtastic radio, in landandair/RNS_Over_Meshtastic's fragment format
/// (spec 2026-10-16 §5): driver lifecycle and inbound reassembly keyed by sending node.
@Reducer
public struct MeshtasticInterface {
    @ObservableState
    public struct State: Equatable {
        public let config: MeshtasticDriverConfig
        public let framing: MeshtasticFraming
        public internal(set) var status: MeshtasticInterfaceStatus = .stopped
        public internal(set) var reassembler = MeshtasticReassembler()

        public init(config: MeshtasticDriverConfig, framing: MeshtasticFraming = .landandair) {
            self.config = config
            self.framing = framing
        }

        public var isOnline: Bool {
            if case .online = status { return true }
            return false
        }

        public var modemPreset: Int? {
            if case let .online(_, preset) = status { return preset }
            return nil
        }
    }

    public enum Action: Equatable {
        case start
        case stop
        case driverEvent(MeshtasticDriverEvent)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case online(myNodeNum: UInt32, modemPreset: Int?)
            case offline(reason: String?)
            case packetReceived(Data)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
    }

    @Dependency(\.meshtasticDriver) var driver
    @Dependency(\.meshtasticDate) var date

    private enum CancelID: Hashable { case driver }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                switch state.status {
                case .stopped, .unavailable: break
                case .connecting, .online: return .none
                }
                state.status = .connecting
                let config = state.config
                return .run { [driver] send in
                    for await event in driver.start(config) {
                        await send(.driverEvent(event))
                    }
                }
                .cancellable(id: CancelID.driver, cancelInFlight: true)

            case .stop:
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .stopped
                state.reassembler.reset()
                var effects: [Effect<Action>] = [.cancel(id: CancelID.driver),
                                                 .run { [driver] _ in await driver.stop() }]
                if wasOnline { effects.append(.send(.delegate(.offline(reason: nil)))) }
                return .merge(effects)

            case let .driverEvent(.connected(myNodeNum, modemPreset)):
                guard state.status != .stopped else { return .none }
                state.status = .online(myNodeNum: myNodeNum, modemPreset: modemPreset)
                return .send(.delegate(.online(myNodeNum: myNodeNum, modemPreset: modemPreset)))

            case let .driverEvent(.disconnected(reason)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .connecting
                state.reassembler.reset()
                return wasOnline ? .send(.delegate(.offline(reason: reason))) : .none

            case let .driverEvent(.unavailable(cause)):
                guard state.status != .stopped else { return .none }
                let wasOnline = state.isOnline
                state.status = .unavailable(cause)
                state.reassembler.reset()
                var effects: [Effect<Action>] = []
                if wasOnline { effects.append(.send(.delegate(.offline(reason: nil)))) }
                effects.append(.send(.delegate(.adapterUnavailable(cause))))
                return .merge(effects)

            case let .driverEvent(.fragment(from, frame)):
                guard state.isOnline else { return .none }
                switch state.framing.codec.parse(frame) {
                case nil:
                    state.reassembler.recordMalformed()
                    return .none
                case let .data(index, pos, body):
                    guard let packet = state.reassembler.receive(from: from, index: index, pos: pos,
                                                                 body: body, now: date())
                    else { return .none }
                    return .send(.delegate(.packetReceived(packet)))
                case .request:
                    return .none
                }

            case .delegate:
                return .none
            }
        }
    }
}
