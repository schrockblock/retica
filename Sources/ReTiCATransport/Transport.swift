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
        public var transportIdentity: Identity? = nil
        var seenPacketHashes = RingSet()
        public var linkTable: [Data: LinkTableEntry] = [:]
        public init() {}

        public struct LinkTableEntry: Equatable, Sendable {
            public var rcvdIf: InterfaceID
            public var nhIf: InterfaceID
            public init(rcvdIf: InterfaceID, nhIf: InterfaceID) {
                self.rcvdIf = rcvdIf
                self.nhIf = nhIf
            }
        }
    }

    public enum SendFailure: Equatable, Sendable { case notLearned, tooLarge }

    public enum Action: Equatable {
        case interfaceConnected(InterfaceID)
        case interfaceDisconnected(InterfaceID)
        case registerLocalDestination(Destination)
        case setTransportIdentity(Identity?)
        case received(InterfaceID, Data)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: SendFailure)
            case linkPacket(linkID: Data, data: Data)
            case linkRequest(destinationHash: Data, data: Data)
        }
    }

    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            // Shared helper: rewrite a packet for forwarding toward its destination.
            // Final hop (nextHop == destHash) → HEADER_1 direct; onward → HEADER_2 to next hop.
            func forwardTowardDest(_ packet: Packet, _ entry: LearnedDestination) -> Data? {
                let fwd: Packet
                if entry.nextHop == packet.destinationHash {
                    fwd = Packet(headerType: .header1, packetType: packet.packetType, transportType: .broadcast,
                                 destinationType: packet.destinationType, context: packet.context,
                                 contextFlag: false, hops: packet.hops + 1,
                                 destinationHash: packet.destinationHash, transportId: nil, payload: packet.payload)
                } else {
                    fwd = Packet(headerType: .header2, packetType: packet.packetType, transportType: .transport,
                                 destinationType: packet.destinationType, context: packet.context,
                                 contextFlag: packet.contextFlag, hops: packet.hops + 1,
                                 destinationHash: packet.destinationHash, transportId: entry.nextHop,
                                 payload: packet.payload)
                }
                return try? fwd.packed()
            }

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

            case let .setTransportIdentity(identity):
                state.transportIdentity = identity
                return .none

            case let .received(interfaceID, data):
                guard let packet = Packet(raw: data) else { return .none }
                // Link traffic is recognized and routed up BEFORE the announce/data dedup:
                // byte-identical keepalives share a packet hash and must not be deduped, and a
                // retried link request should still reach us.
                if packet.destinationType == .link {
                    // Relay: a transited link's packets (LRPROOF + established traffic) are forwarded
                    // direction-aware by link_id; a local link surfaces to the endpoint as today.
                    if let entry = state.linkTable[packet.destinationHash],
                       Int(packet.hops) + 1 < Int(Packet.maxHops) {
                        let outIf: InterfaceID
                        if interfaceID == entry.rcvdIf { outIf = entry.nhIf }        // toward dest
                        else if interfaceID == entry.nhIf { outIf = entry.rcvdIf }   // toward initiator
                        else { return .none }
                        var fwd = packet
                        fwd.hops = packet.hops + 1
                        guard let raw = try? fwd.packed() else { return .none }
                        return .send(.delegate(.transmit(outIf, raw)))
                    }
                    return .send(.delegate(.linkPacket(linkID: packet.destinationHash, data: data)))
                }
                if packet.packetType == .linkRequest, state.localDestinations[packet.destinationHash] != nil {
                    return .send(.delegate(.linkRequest(destinationHash: packet.destinationHash, data: data)))
                }
                // NOTE (relay, 4b): packetHash is over `hashablePart`, which EXCLUDES hops and
                // transport_id — so a relayed announce shares the ORIGINAL's packet hash. A node
                // that already heard the original therefore drops the relayed copy here. That is
                // loop-protective (safe for 4b-1's re-broadcast), but means a relay-improved path
                // is not adopted for an already-seen announce. 4b-3's random-blob anti-replay
                // (keyed on the announce random_hash + transport_id, like RNS) is where that is fixed.
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
                    // Path-table next hop: relayed (HEADER_2) → its transport_id; directly heard → the dest.
                    let nextHop = packet.transportId ?? packet.destinationHash
                    let candidate = LearnedDestination(
                        identity: parsed.identity, appData: parsed.appData, ratchet: parsed.ratchet,
                        interfaceID: interfaceID, hops: packet.hops, nextHop: nextHop,
                        announceEmitted: emitted)
                    guard Transport.shouldReplace(state.learned[packet.destinationHash], with: candidate)
                    else { return .none }
                    state.learned[packet.destinationHash] = candidate
                    let learnedEffect = Effect<Action>.send(.delegate(.pathLearned(
                        destinationHash: packet.destinationHash, hops: packet.hops)))
                    // Relay mode: re-broadcast the announce (same payload, HEADER_2, our transport_id,
                    // hops+1) to every interface except the one it arrived on — but respect the hop limit.
                    guard let relayID = state.transportIdentity,
                          Int(packet.hops) + 1 < Int(Packet.maxHops)
                    else { return learnedEffect }
                    let rebroadcast = Packet(
                        headerType: .header2, packetType: .announce, transportType: .transport,
                        destinationType: packet.destinationType, context: packet.context,
                        contextFlag: packet.contextFlag, hops: packet.hops + 1,
                        destinationHash: packet.destinationHash, transportId: relayID.hash,
                        payload: packet.payload)
                    guard let rebroadcastRaw = try? rebroadcast.packed() else { return learnedEffect }
                    let out = state.interfaces
                        .filter { $0 != interfaceID }
                        .map { Effect<Action>.send(.delegate(.transmit($0, rebroadcastRaw))) }
                    return .merge([learnedEffect] + out)
                case .data:
                    // Relay: a HEADER_2 data packet naming us as the next hop, for a REMOTE destination,
                    // is forwarded toward the destination (nextHop-based; RNS Transport.py:1603-1614).
                    if let relayID = state.transportIdentity, packet.headerType == .header2,
                       packet.transportId == relayID.hash,
                       state.localDestinations[packet.destinationHash] == nil {
                        guard let entry = state.learned[packet.destinationHash],
                              Int(packet.hops) + 1 < Int(Packet.maxHops) else { return .none }
                        guard let raw = forwardTowardDest(packet, entry) else { return .none }
                        return .send(.delegate(.transmit(entry.interfaceID, raw)))
                    }
                    guard let destination = state.localDestinations[packet.destinationHash],
                          destination.kind == packet.destinationType,
                          let plaintext = destination.decrypt(packet.payload)
                    else { return .none }
                    return .send(.delegate(.received(destinationHash: packet.destinationHash,
                                                     plaintext: plaintext)))
                case .linkRequest:
                    // Relay: a HEADER_2 LINKREQUEST naming us as next hop, for a REMOTE destination, is
                    // forwarded toward the dest and a link_table entry is recorded for reverse routing.
                    if let relayID = state.transportIdentity, packet.headerType == .header2,
                       packet.transportId == relayID.hash,
                       state.localDestinations[packet.destinationHash] == nil {
                        guard let entry = state.learned[packet.destinationHash],
                              Int(packet.hops) + 1 < Int(Packet.maxHops) else { return .none }
                        let linkID = Link.linkID(requestPacket: packet)
                        state.linkTable[linkID] = State.LinkTableEntry(rcvdIf: interfaceID, nhIf: entry.interfaceID)
                        guard let raw = forwardTowardDest(packet, entry) else { return .none }
                        return .send(.delegate(.transmit(entry.interfaceID, raw)))
                    }
                    return .none
                default:
                    return .none
                }

            case let .send(destinationHash, plaintext):
                guard let entry = state.learned[destinationHash] else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .notLearned)))
                }
                let ciphertext = entry.identity.encrypt(plaintext, ratchet: entry.ratchet)
                let packet: Packet
                if let nh = entry.nextHop, nh != destinationHash {
                    // Destination is reached via a relay → send HEADER_2 to the next hop.
                    packet = Packet(headerType: .header2, packetType: .data, transportType: .transport,
                                    destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: destinationHash, transportId: nh, payload: ciphertext)
                } else {
                    // Directly reachable → HEADER_1 as before.
                    packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                    destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: destinationHash, transportId: nil, payload: ciphertext)
                }
                guard let raw = try? packet.packed() else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .tooLarge)))
                }
                return .send(.delegate(.transmit(entry.interfaceID, raw)))

            case let .announce(destinationHash, appData):
                guard let dest = state.localDestinations[destinationHash],
                      let identity = dest.identity, identity.privateKey != nil
                else { return .none }
                let now = UInt64(date.now.timeIntervalSince1970)
                let randomHash = Announce.randomHash(now: now, randomPrefix: SecureRandom.bytes(5))
                let payload = Announce.buildPayload(identity: identity, destinationHash: destinationHash,
                                                    nameHash: dest.nameHash, randomHash: randomHash,
                                                    ratchet: nil, appData: appData)
                let packet = Packet.announce(from: dest, payload: payload)
                guard let raw = try? packet.packed() else { return .none }
                return .merge(state.interfaces.map { .send(.delegate(.transmit($0, raw))) })

            case .delegate:
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
