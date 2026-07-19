import Foundation
import ComposableArchitecture
import ReTiCA

/// The Reticulum Link establishment handshake as a TCA feature (one instance per link).
/// Drives the initiator and responder roles through PENDING→HANDSHAKE→ACTIVE via the
/// three-packet handshake (LINKREQUEST → LRPROOF → LRRTT). Interface-agnostic: raw packet
/// bytes arrive via `received`/`acceptRequest`; outbound bytes leave via `delegate(.transmit)`.
/// Establishment only — no data flow, close, or timers.
@Reducer
public struct LinkSession {
    public enum Role: Equatable, Sendable { case initiator, responder }
    public enum Status: Equatable, Sendable { case pending, handshake, active }

    @ObservableState
    public struct State: Equatable {
        public var role: Role
        public var status: Status
        public var interfaceID: InterfaceID
        public var linkID: Data
        public var ephemeral: Identity
        public var destinationHash: Data
        public var destinationIdentity: Identity?   // initiator: peer identity that signs the proof
        public var owningIdentity: Identity?         // responder: local identity owning the destination
        public var peerX25519Pub: Data?
        public var sessionKey: Data
        public var requestedAt: Double?
        public var rtt: Double?

        /// Initiator: link to a known destination identity.
        public init(initiatorTo destinationIdentity: Identity, destinationHash: Data,
                    interfaceID: InterfaceID, ephemeral: Identity = Identity()) {
            self.role = .initiator
            self.status = .pending
            self.interfaceID = interfaceID
            self.linkID = Data()
            self.ephemeral = ephemeral
            self.destinationHash = destinationHash
            self.destinationIdentity = destinationIdentity
            self.owningIdentity = nil
            self.peerX25519Pub = nil
            self.sessionKey = Data()
            self.requestedAt = nil
            self.rtt = nil
        }

        /// Responder: accept links for a destination owned by `owningIdentity`.
        public init(responderFor owningIdentity: Identity, destinationHash: Data,
                    interfaceID: InterfaceID, ephemeral: Identity = Identity()) {
            self.role = .responder
            self.status = .pending
            self.interfaceID = interfaceID
            self.linkID = Data()
            self.ephemeral = ephemeral
            self.destinationHash = destinationHash
            self.destinationIdentity = nil
            self.owningIdentity = owningIdentity
            self.peerX25519Pub = nil
            self.sessionKey = Data()
            self.requestedAt = nil
            self.rtt = nil
        }
    }

    public enum Action: Equatable {
        case establish
        case acceptRequest(Data)
        case received(Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case established(linkID: Data, sessionKey: Data)
            case establishmentFailed
        }
    }

    @Dependency(\.date) var date

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .establish:
                guard state.role == .initiator, state.status == .pending, state.linkID.isEmpty
                else { return .none }
                let payload = state.ephemeral.publicKey + Link.signallingBytes
                let packet = Packet(headerType: .header1, packetType: .linkRequest,
                                    transportType: .broadcast, destinationType: .single,
                                    context: .none, contextFlag: false, hops: 0,
                                    destinationHash: state.destinationHash, transportId: nil,
                                    payload: payload)
                state.linkID = Link.linkID(requestPacket: packet)
                state.requestedAt = date.now.timeIntervalSince1970
                guard let raw = try? packet.packed() else { return .none }
                let id = state.interfaceID
                return .send(.delegate(.transmit(id, raw)))

            case let .acceptRequest(data):
                guard state.role == .responder, state.status == .pending,
                      let packet = Packet(raw: data), packet.packetType == .linkRequest,
                      packet.payload.count >= 64, let owner = state.owningIdentity
                else { return .none }
                let linkID = Link.linkID(requestPacket: packet)
                let peerPub = Data(packet.payload.prefix(32))
                let ourPriv = Data((state.ephemeral.privateKey ?? Data()).prefix(32))
                let key = Link.sessionKey(ephemeralPrivateX25519: ourPriv,
                                          peerPublicX25519: peerPub, linkID: linkID)
                guard !key.isEmpty else { return .send(.delegate(.establishmentFailed)) }
                state.linkID = linkID
                state.peerX25519Pub = peerPub
                state.sessionKey = key
                state.status = .handshake
                let proof = Link.buildProof(linkID: linkID, responderEphemeral: state.ephemeral,
                                            destinationIdentity: owner)
                let packetOut = Packet(headerType: .header1, packetType: .proof,
                                       transportType: .broadcast, destinationType: .link,
                                       context: .linkRequestProof, contextFlag: false, hops: 0,
                                       destinationHash: linkID, transportId: nil, payload: proof)
                guard let raw = try? packetOut.packed() else { return .none }
                let id = state.interfaceID
                return .send(.delegate(.transmit(id, raw)))

            case let .received(data):
                guard let packet = Packet(raw: data), packet.destinationHash == state.linkID
                else { return .none }
                switch (state.role, state.status, packet.packetType, packet.context) {
                case (.initiator, .pending, .proof, .linkRequestProof):
                    guard let destID = state.destinationIdentity,
                          let peerPub = Link.validateProof(proofData: packet.payload,
                                                           linkID: state.linkID,
                                                           destinationIdentity: destID)
                    else { return .send(.delegate(.establishmentFailed)) }
                    let ourPriv = Data((state.ephemeral.privateKey ?? Data()).prefix(32))
                    let key = Link.sessionKey(ephemeralPrivateX25519: ourPriv,
                                              peerPublicX25519: peerPub, linkID: state.linkID)
                    guard !key.isEmpty else { return .send(.delegate(.establishmentFailed)) }
                    state.peerX25519Pub = peerPub
                    state.sessionKey = key
                    state.status = .active
                    let now = date.now.timeIntervalSince1970
                    let rtt = now - (state.requestedAt ?? now)
                    state.rtt = rtt
                    let cipher = Link.encrypt(MsgPack.encode(rtt), sessionKey: key)
                    let rttPacket = Packet(headerType: .header1, packetType: .data,
                                           transportType: .broadcast, destinationType: .link,
                                           context: .linkRequestRTT, contextFlag: false, hops: 0,
                                           destinationHash: state.linkID, transportId: nil,
                                           payload: cipher)
                    let id = state.interfaceID
                    let established = Action.delegate(.established(linkID: state.linkID,
                                                                  sessionKey: key))
                    guard let raw = try? rttPacket.packed() else { return .send(established) }
                    return .merge(.send(.delegate(.transmit(id, raw))), .send(established))

                case (.responder, .handshake, .data, .linkRequestRTT):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          let rtt = MsgPack.decodeDouble(plain)
                    else { return .send(.delegate(.establishmentFailed)) }
                    state.rtt = rtt
                    state.status = .active
                    return .send(.delegate(.established(linkID: state.linkID,
                                                        sessionKey: state.sessionKey)))

                default:
                    return .none
                }

            case .delegate:
                return .none
            }
        }
    }
}
