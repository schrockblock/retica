import Foundation
import ComposableArchitecture
import ReTiCA

/// The Reticulum Link establishment handshake as a TCA feature (one instance per link).
/// Drives the initiator and responder roles through PENDING→HANDSHAKE→ACTIVE via the
/// three-packet handshake (LINKREQUEST → LRPROOF → LRRTT). Interface-agnostic: raw packet
/// bytes arrive via `received`/`acceptRequest`; outbound bytes leave via `delegate(.transmit)`.
/// After establishment the link can carry encrypted application data (DATA/NONE) and be
/// explicitly closed (LINKCLOSE). A clock-driven watchdog times out hung handshakes, sends
/// keepalives (initiator 0xFF / responder 0xFE) to keep active links alive, and tears down
/// links that go silent (all via cancellable timer effects, cancelled on close).
@Reducer
public struct LinkSession {
    public enum Role: Equatable, Sendable { case initiator, responder }
    public enum Status: Equatable, Sendable { case pending, handshake, active, closed }
    public enum CloseReason: Equatable, Sendable { case initiatorClosed, destinationClosed, timedOut }

    static let keepaliveByte: UInt8 = 0xFF
    static let keepaliveReplyByte: UInt8 = 0xFE
    static let resourceSDU = 464
    static let requestMDU = 431

    @ObservableState
    public struct State: Equatable {
        public let id: UUID
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
        public var activatedAt: Double?
        public var lastInbound: Double?
        public var remoteIdentity: Identity?
        public var pendingRequests: Set<Data>
        public var transfers: IdentifiedArrayOf<ResourceTransfer.State> = []
        public var establishmentTimeout: TimeInterval
        public var keepaliveInterval: TimeInterval
        var staleTime: TimeInterval { keepaliveInterval * 2 }
        /// Initiator: link to a known destination identity.
        public init(id: UUID = UUID(), initiatorTo destinationIdentity: Identity, destinationHash: Data,
                    interfaceID: InterfaceID, ephemeral: Identity = Identity(),
                    establishmentTimeout: TimeInterval = 15, keepaliveInterval: TimeInterval = 30) {
            self.id = id
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
            self.activatedAt = nil
            self.lastInbound = nil
            self.remoteIdentity = nil
            self.pendingRequests = []
            self.establishmentTimeout = establishmentTimeout
            self.keepaliveInterval = keepaliveInterval
        }

        /// Responder: accept links for a destination owned by `owningIdentity`.
        public init(id: UUID = UUID(), responderFor owningIdentity: Identity, destinationHash: Data,
                    interfaceID: InterfaceID, ephemeral: Identity = Identity(),
                    establishmentTimeout: TimeInterval = 15, keepaliveInterval: TimeInterval = 30) {
            self.id = id
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
            self.activatedAt = nil
            self.lastInbound = nil
            self.remoteIdentity = nil
            self.pendingRequests = []
            self.establishmentTimeout = establishmentTimeout
            self.keepaliveInterval = keepaliveInterval
        }
    }

    public enum Action: Equatable {
        case establish
        case acceptRequest(Data)
        case received(Data)
        case send(Data)
        case identify(Identity)
        case close
        case establishmentDeadline
        case keepaliveDeadline
        case inactivityDeadline
        case sendResource(Data)
        case sendRequest(path: String, data: Data)
        case sendResponse(requestID: Data, data: Data)
        case requestDeadline(Data)
        case transfer(IdentifiedActionOf<ResourceTransfer>)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case established(linkID: Data, sessionKey: Data)
            case establishmentFailed
            case dataReceived(Data)
            case closed(CloseReason)
            case resourceReceived(Data)
            case resourceConcluded(Data)
            case resourceFailed(Data)
            case identified(Identity)
            case responseReceived(requestID: Data, data: Data)
            case requestFailed(requestID: Data)
            case requestReceived(requestID: Data, pathHash: Data, data: Data)
        }
    }

    @Dependency(\.date) var date
    @Dependency(\.continuousClock) var clock
    @Dependency(\.uuid) var uuid
    @Dependency(\.randomBytes) var randomBytes

    private enum CancelID: Hashable { case establishment, keepalive, inactivity, request(Data) }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { [date, clock, uuid, randomBytes] state, action in
            func establishmentTimer(_ t: TimeInterval) -> Effect<Action> {
                .run { send in try await clock.sleep(for: .seconds(t)); await send(.establishmentDeadline) }
                    .cancellable(id: CancelID.establishment, cancelInFlight: true)
            }
            func inactivityTimer(_ t: TimeInterval) -> Effect<Action> {
                .run { send in try await clock.sleep(for: .seconds(t)); await send(.inactivityDeadline) }
                    .cancellable(id: CancelID.inactivity, cancelInFlight: true)
            }
            func keepaliveTimer(_ t: TimeInterval) -> Effect<Action> {
                .run { send in while true { try await clock.sleep(for: .seconds(t)); await send(.keepaliveDeadline) } }
                    .cancellable(id: CancelID.keepalive, cancelInFlight: true)
            }
            let cancelAll = Effect<Action>.merge(.cancel(id: CancelID.establishment),
                                                 .cancel(id: CancelID.keepalive),
                                                 .cancel(id: CancelID.inactivity))
            func linkPacket(_ linkID: Data, _ context: PacketContext, _ payload: Data) -> Data? {
                let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                               destinationType: .link, context: context, contextFlag: false, hops: 0,
                               destinationHash: linkID, transportId: nil, payload: payload)
                return try? p.packed()
            }

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
                return .merge(.send(.delegate(.transmit(id, raw))), establishmentTimer(state.establishmentTimeout))

            case let .acceptRequest(data):
                guard state.role == .responder, state.status == .pending,
                      let packet = Packet(raw: data), packet.packetType == .linkRequest,
                      (packet.payload.count == 64 || packet.payload.count == 67),
                      let owner = state.owningIdentity
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
                return .merge(.send(.delegate(.transmit(id, raw))), establishmentTimer(state.establishmentTimeout))

            case let .received(data):
                guard let packet = Packet(raw: data), packet.destinationHash == state.linkID
                else { return .none }
                let now = date.now.timeIntervalSince1970
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
                    state.activatedAt = now
                    state.lastInbound = now
                    let rtt = now - (state.requestedAt ?? now)
                    state.rtt = rtt
                    let cipher = Link.encrypt(MsgPack.encode(rtt), sessionKey: key)
                    let established = Action.delegate(.established(linkID: state.linkID, sessionKey: key))
                    let extra = Effect<Action>.merge(.cancel(id: CancelID.establishment),
                                                     inactivityTimer(state.staleTime),
                                                     keepaliveTimer(state.keepaliveInterval))
                    guard let raw = linkPacket(state.linkID, .linkRequestRTT, cipher) else {
                        return .merge(.send(established), extra)
                    }
                    return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(established), extra)

                case (.responder, .handshake, .data, .linkRequestRTT):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          let rtt = MsgPack.decodeDouble(plain)
                    else { return .send(.delegate(.establishmentFailed)) }
                    state.rtt = rtt
                    state.status = .active
                    state.activatedAt = now
                    state.lastInbound = now
                    return .merge(.send(.delegate(.established(linkID: state.linkID, sessionKey: state.sessionKey))),
                                  .cancel(id: CancelID.establishment), inactivityTimer(state.staleTime))

                case (_, .active, .data, .none):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey)
                    else { return .none }   // corrupt/foreign data is ignored, link stays active
                    return .send(.delegate(.dataReceived(plain)))

                case (_, .active, .data, .linkClose):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          plain == state.linkID
                    else { return .none }
                    state.status = .closed
                    let reason: CloseReason = state.role == .initiator ? .destinationClosed : .initiatorClosed
                    return .merge(.send(.delegate(.closed(reason))), cancelAll)

                case (.responder, .active, .data, .keepalive):
                    state.lastInbound = now
                    var effects: [Effect<Action>] = [inactivityTimer(state.staleTime)]
                    if packet.payload == Data([LinkSession.keepaliveByte]),
                       let raw = linkPacket(state.linkID, .keepalive, Data([LinkSession.keepaliveReplyByte])) {
                        effects.append(.send(.delegate(.transmit(state.interfaceID, raw))))
                    }
                    return .merge(effects)

                case (.initiator, .active, .data, .keepalive):
                    guard packet.payload != Data([LinkSession.keepaliveByte]) else { return .none } // ignore own 0xFF loopback
                    state.lastInbound = now
                    return inactivityTimer(state.staleTime)                                          // 0xFE reply resets inactivity

                case (_, .active, .data, .resourceAdvertisement):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          let adv = ResourceAdvertisement.unpack(plain) else { return .none }
                    if state.transfers.contains(where: { $0.resourceHash == adv.hash }) { return .none }
                    // A response-Resource is only ours if its request_id is currently pending.
                    if adv.isResponse {
                        guard let rid = adv.requestID, state.pendingRequests.contains(rid) else { return .none }
                    }
                    let newID = uuid()
                    let transferRTT: Duration = .seconds(state.rtt ?? 1)
                    state.transfers.append(ResourceTransfer.State(
                        receivingOn: state.linkID, sessionKey: state.sessionKey,
                        interfaceID: state.interfaceID, rtt: transferRTT, id: newID))
                    state.transfers[id: newID]?.resourceHash = adv.hash
                    let accept = Effect<Action>.send(.transfer(.element(id: newID, action: .accept(data))))
                    if adv.isResponse, let rid = adv.requestID {
                        // Response is arriving; stop the request timeout while it downloads.
                        return .merge(accept, .cancel(id: CancelID.request(rid)))
                    }
                    return accept

                case (_, .active, .data, .resource),
                     (_, .active, .data, .resourceRequest),
                     (_, .active, .data, .resourceHashmapUpdate),
                     (_, .active, .data, .resourceProof),
                     (_, .active, .data, .resourceInitiatorCancel),
                     (_, .active, .data, .resourceReceiverCancel),
                     (_, .active, .proof, .resourceProof):
                    return .merge(state.transfers.ids.map {
                        .send(.transfer(.element(id: $0, action: .received(data))))
                    })

                case (_, .active, .data, .response):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          case let .array(items)? = MsgPack.decodeValue(Data(plain)), items.count == 2,
                          case let .bin(requestID) = items[0], case let .bin(data) = items[1],
                          state.pendingRequests.contains(requestID)
                    else { return .none }
                    state.pendingRequests.remove(requestID)
                    return .merge(.cancel(id: CancelID.request(requestID)),
                                  .send(.delegate(.responseReceived(requestID: requestID, data: data))))

                case (_, .active, .data, .linkIdentify):
                    guard state.role == .responder,
                          let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey)
                    else { return .none }
                    let p = Data(plain)
                    guard p.count == 128,
                          let peer = Identity(publicKey: Data(p[p.startIndex..<(p.startIndex + 64)])),
                          peer.validate(signature: Data(p[(p.startIndex + 64)..<(p.startIndex + 128)]),
                                        message: state.linkID + Data(p[p.startIndex..<(p.startIndex + 64)]))
                    else { return .none }
                    state.remoteIdentity = peer
                    return .send(.delegate(.identified(peer)))

                case (_, .active, .data, .request):
                    let requestID = packet.truncatedHash
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          case let .array(items)? = MsgPack.decodeValue(Data(plain)), items.count == 3,
                          case let .bin(pathHash) = items[1], case let .bin(data) = items[2]
                    else { return .none }
                    return .send(.delegate(.requestReceived(requestID: requestID, pathHash: pathHash, data: data)))

                default:
                    return .none
                }

            case let .sendResource(data):
                guard state.status == .active else { return .none }
                let r = Data(randomBytes(8))
                let prefix = Data(r[r.startIndex ..< r.startIndex + 4])
                let randomHash = Data(r[r.startIndex + 4 ..< r.startIndex + 8])
                let newID = uuid()
                state.transfers.append(ResourceTransfer.State(
                    sending: data, linkID: state.linkID, sessionKey: state.sessionKey,
                    interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                    sdu: Self.resourceSDU, rtt: .seconds(state.rtt ?? 1), id: newID))
                return .send(.transfer(.element(id: newID, action: .advertise)))

            case let .identify(identity):
                guard state.role == .initiator, state.status == .active else { return .none }
                let payload = identity.publicKey + identity.sign(state.linkID + identity.publicKey)
                guard let raw = linkPacket(state.linkID, .linkIdentify,
                                           Link.encrypt(payload, sessionKey: state.sessionKey))
                else { return .none }
                return .send(.delegate(.transmit(state.interfaceID, raw)))

            case let .sendRequest(path, data):
                guard state.status == .active else { return .none }
                let pathHash = Crypto.truncatedHash(Data(path.utf8))
                let packed = MsgPack.encode(.array([.double(date.now.timeIntervalSince1970),
                                                    .bin(pathHash), .bin(data)]))
                let ifID = state.interfaceID
                let timeout = (state.rtt ?? 0.5) * 6 + 11.25
                if packed.count <= Self.requestMDU {
                    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                        destinationType: .link, context: .request, contextFlag: false, hops: 0,
                                        destinationHash: state.linkID, transportId: nil,
                                        payload: Link.encrypt(packed, sessionKey: state.sessionKey))
                    let requestID = packet.truncatedHash
                    guard let raw = try? packet.packed() else { return .none }
                    state.pendingRequests.insert(requestID)
                    return .merge(
                        .send(.delegate(.transmit(ifID, raw))),
                        .run { send in
                            try await clock.sleep(for: .seconds(timeout)); await send(.requestDeadline(requestID))
                        }.cancellable(id: CancelID.request(requestID), cancelInFlight: true))
                } else {
                    // Large request: send as a request-Resource; request_id = truncatedHash(packed blob).
                    let requestID = Crypto.truncatedHash(packed)
                    state.pendingRequests.insert(requestID)
                    let rnd = Data(randomBytes(8))
                    let prefix = Data(rnd[rnd.startIndex ..< rnd.startIndex + 4])
                    let randomHash = Data(rnd[rnd.startIndex + 4 ..< rnd.startIndex + 8])
                    let newID = uuid()
                    state.transfers.append(ResourceTransfer.State(
                        sending: packed, linkID: state.linkID, sessionKey: state.sessionKey,
                        interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                        sdu: Self.resourceSDU, requestID: requestID, isResponse: false,
                        rtt: .seconds(state.rtt ?? 1), id: newID))
                    return .merge(
                        .send(.transfer(.element(id: newID, action: .advertise))),
                        .run { send in
                            try await clock.sleep(for: .seconds(timeout)); await send(.requestDeadline(requestID))
                        }.cancellable(id: CancelID.request(requestID), cancelInFlight: true))
                }

            case let .sendResponse(requestID, data):
                guard state.status == .active else { return .none }
                let packed = MsgPack.encode(.array([.bin(requestID), .bin(data)]))
                if packed.count <= Self.requestMDU {
                    guard let raw = linkPacket(state.linkID, .response,
                                               Link.encrypt(packed, sessionKey: state.sessionKey))
                    else { return .none }
                    return .send(.delegate(.transmit(state.interfaceID, raw)))
                } else {
                    let rnd = Data(randomBytes(8))
                    let prefix = Data(rnd[rnd.startIndex ..< rnd.startIndex + 4])
                    let randomHash = Data(rnd[rnd.startIndex + 4 ..< rnd.startIndex + 8])
                    let newID = uuid()
                    state.transfers.append(ResourceTransfer.State(
                        sending: packed, linkID: state.linkID, sessionKey: state.sessionKey,
                        interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                        sdu: Self.resourceSDU, requestID: requestID, isResponse: true,
                        rtt: .seconds(state.rtt ?? 1), id: newID))
                    return .send(.transfer(.element(id: newID, action: .advertise)))
                }

            case let .send(plaintext):
                guard state.status == .active else { return .none }
                let cipher = Link.encrypt(plaintext, sessionKey: state.sessionKey)
                let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                    destinationType: .link, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: state.linkID, transportId: nil, payload: cipher)
                guard let raw = try? packet.packed() else { return .none }
                let id = state.interfaceID
                return .send(.delegate(.transmit(id, raw)))

            case .close:
                guard state.status == .active else { return .none }
                let cipher = Link.encrypt(state.linkID, sessionKey: state.sessionKey)
                state.status = .closed
                let reason: CloseReason = state.role == .initiator ? .initiatorClosed : .destinationClosed
                let closedAction = Action.delegate(.closed(reason))
                guard let raw = linkPacket(state.linkID, .linkClose, cipher) else {
                    return .merge(.send(closedAction), cancelAll)
                }
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(closedAction), cancelAll)

            case .establishmentDeadline:
                guard state.status == .pending || state.status == .handshake else { return .none }
                state.status = .closed
                return .merge(.send(.delegate(.closed(.timedOut))), cancelAll)

            case .keepaliveDeadline:
                guard state.status == .active, state.role == .initiator else { return .none }
                guard let raw = linkPacket(state.linkID, .keepalive, Data([LinkSession.keepaliveByte]))
                else { return .none }
                return .send(.delegate(.transmit(state.interfaceID, raw)))

            case .inactivityDeadline:
                guard state.status == .active else { return .none }
                let cipher = Link.encrypt(state.linkID, sessionKey: state.sessionKey)
                state.status = .closed
                let closedAction = Action.delegate(.closed(.timedOut))
                guard let raw = linkPacket(state.linkID, .linkClose, cipher) else {
                    return .merge(.send(closedAction), cancelAll)
                }
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(closedAction), cancelAll)

            case let .requestDeadline(requestID):
                guard state.pendingRequests.contains(requestID) else { return .none }
                state.pendingRequests.remove(requestID)
                return .send(.delegate(.requestFailed(requestID: requestID)))

            case let .transfer(.element(_, .delegate(.transmit(ifID, raw)))):
                return .send(.delegate(.transmit(ifID, raw)))
            case let .transfer(.element(elementID, .delegate(.received(payload)))):
                let adv = state.transfers[id: elementID]?.advertisement
                if adv?.isRequest == true {
                    guard case let .array(items)? = MsgPack.decodeValue(payload), items.count == 3,
                          case let .bin(pathHash) = items[1], case let .bin(data) = items[2] else { return .none }
                    return .send(.delegate(.requestReceived(requestID: Crypto.truncatedHash(payload),
                                                            pathHash: pathHash, data: data)))
                } else if adv?.isResponse == true {
                    guard case let .array(items)? = MsgPack.decodeValue(payload), items.count == 2,
                          case let .bin(rid) = items[0], case let .bin(data) = items[1],
                          state.pendingRequests.contains(rid) else { return .none }
                    state.pendingRequests.remove(rid)
                    return .merge(.cancel(id: CancelID.request(rid)),
                                  .send(.delegate(.responseReceived(requestID: rid, data: data))))
                }
                return .send(.delegate(.resourceReceived(payload)))
            case let .transfer(.element(elementID, .delegate(.concluded))):
                let adv = state.transfers[id: elementID]?.advertisement
                if adv?.isRequest == true || adv?.isResponse == true { return .none }   // internal req/resp delivery
                guard let hash = state.transfers[id: elementID]?.resourceHash else { return .none }
                return .send(.delegate(.resourceConcluded(hash)))
            case let .transfer(.element(elementID, .delegate(.failed))):
                let t = state.transfers[id: elementID]
                if let rid = t?.advertisement?.requestID, state.pendingRequests.contains(rid) {
                    state.pendingRequests.remove(rid)
                    return .merge(.cancel(id: CancelID.request(rid)),
                                  .send(.delegate(.requestFailed(requestID: rid))))
                }
                if t?.advertisement?.isRequest == true || t?.advertisement?.isResponse == true { return .none }
                guard let hash = t?.resourceHash else { return .none }
                return .send(.delegate(.resourceFailed(hash)))
            case .transfer:
                return .none

            case .delegate:
                return .none
            }
        }
        .forEach(\.transfers, action: \.transfer) { ResourceTransfer() }
    }
}

extension LinkSession.State: Identifiable {}
