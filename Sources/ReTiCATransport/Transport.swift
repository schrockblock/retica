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

            case .received, .announce, .send, .delegate:
                return .none
            }
        }
    }
}
