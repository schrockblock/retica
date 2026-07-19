import Foundation
import ComposableArchitecture
import ReTiCA

/// The Reticulum Transport layer, endpoint (leaf) subset: learns paths from announces,
/// delivers inbound packets to local destinations, and routes outbound packets to learned
/// destinations. Interface-agnostic — interfaces are referenced by `InterfaceID`.
@Reducer
public struct Transport {
    @ObservableState
    public struct State: Equatable {
        public var localDestinations: [Data: Destination] = [:]
        public var learned: [Data: LearnedDestination] = [:]
        public var interfaces: Set<InterfaceID> = []
        var seenPacketHashes = RingSet()
        public init() {}
    }

    public enum SendFailure: Equatable, Sendable { case notLearned, tooLarge }

    public enum Action: Equatable {
        case interfaceConnected(InterfaceID)
        case interfaceDisconnected(InterfaceID)
        case registerLocalDestination(Destination)
        case received(InterfaceID, Data)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: SendFailure)
        }
    }

    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .interfaceConnected(id):
                state.interfaces.insert(id)
                return .none

            case let .interfaceDisconnected(id):
                state.interfaces.remove(id)
                return .none

            case let .registerLocalDestination(destination):
                state.localDestinations[destination.hash] = destination
                return .none

            case let .received(interfaceID, data):
                guard let packet = Packet(raw: data) else { return .none }
                guard state.seenPacketHashes.insert(packet.packetHash) else { return .none }

                switch packet.packetType {
                case .announce:
                    // Don't learn a path to one of our own destinations.
                    guard state.localDestinations[packet.destinationHash] == nil else { return .none }
                    guard let parsed = Announce.parse(payload: packet.payload,
                                                      destinationHash: packet.destinationHash,
                                                      contextFlagSet: packet.contextFlag)
                    else { return .none }
                    let emitted = Transport.announceEmitted(parsed.randomHash)
                    let candidate = LearnedDestination(
                        identity: parsed.identity, appData: parsed.appData, ratchet: parsed.ratchet,
                        interfaceID: interfaceID, hops: packet.hops, nextHop: packet.transportId,
                        announceEmitted: emitted)
                    guard Transport.shouldReplace(state.learned[packet.destinationHash], with: candidate)
                    else { return .none }
                    state.learned[packet.destinationHash] = candidate
                    return .send(.delegate(.pathLearned(destinationHash: packet.destinationHash,
                                                        hops: packet.hops)))
                case .data:
                    guard let destination = state.localDestinations[packet.destinationHash],
                          destination.kind == packet.destinationType,
                          let plaintext = destination.decrypt(packet.payload)
                    else { return .none }
                    return .send(.delegate(.received(destinationHash: packet.destinationHash,
                                                     plaintext: plaintext)))
                default:
                    return .none
                }

            case .announce, .send, .delegate:
                return .none
            }
        }
    }

    /// Emission time from an announce's random hash: big-endian of `randomHash[5..<10]`.
    static func announceEmitted(_ randomHash: Data) -> UInt64 {
        let bytes = randomHash.suffix(5)
        return bytes.reduce(UInt64(0)) { ($0 << 8) | UInt64($1) }
    }

    /// Recency rule: accept a candidate if there is no existing entry, or it is newer, or it
    /// is equally recent but reached us in fewer hops.
    static func shouldReplace(_ existing: LearnedDestination?, with candidate: LearnedDestination) -> Bool {
        guard let existing else { return true }
        if candidate.announceEmitted > existing.announceEmitted { return true }
        if candidate.announceEmitted == existing.announceEmitted && candidate.hops < existing.hops { return true }
        return false
    }
}
