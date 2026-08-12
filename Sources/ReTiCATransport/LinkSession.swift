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

    /// Why establishment failed. The distinction is load-bearing above: a timeout is evidence
    /// about the PATH, a rejection is evidence about the PEER.
    public enum EstablishmentFailure: Equatable, Sendable {
        /// No LINKPROOF within `establishmentTimeout`. Usually means our PATH is wrong (peer moved,
        /// relay gone, peer absent) rather than that the peer refused — the peer never spoke at all.
        case timedOut
        /// The peer ANSWERED but the handshake did not validate (bad proof, empty session key,
        /// undecodable handshake data). The path demonstrably works; the problem is at the peer.
        case handshakeRejected
    }

    static let keepaliveByte: UInt8 = 0xFF
    static let keepaliveReplyByte: UInt8 = 0xFE
    static let resourceSDU = 464
    static let requestMDU = 431
    public static let maxEfficientSize = 1_048_575

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
        public struct SegmentedSend: Equatable, Sendable {
            public var remaining: [Data]        // segment payloads not yet sent (index order, cursor at front)
            public var nextIndex: UInt64         // 1-based index of the NEXT segment to send
            public var total: UInt64
            public var originalHash: Data
            public var totalDataSize: UInt64
            public var currentTransferID: UUID   // the hosted transfer for the segment in flight
        }
        public var segmentedSend: SegmentedSend? = nil
        public struct SegmentAccumulator: Equatable, Sendable {
            public var total: UInt64
            public var parts: [UInt64: Data]     // segmentIndex (1-based) -> segment data
        }
        public var incomingSegments: [Data: SegmentAccumulator] = [:]   // keyed by originalHash
        public var pendingDataReceipts: [Data: Data] = [:]              // sentPacketHash(32) → caller token
        public var establishmentTimeout: TimeInterval
        public var keepaliveInterval: TimeInterval
        var staleTime: TimeInterval { keepaliveInterval * 2 }
        public var relayNextHop: Data? = nil
        /// Initiator: link to a known destination identity.
        public init(id: UUID = UUID(), initiatorTo destinationIdentity: Identity, destinationHash: Data,
                    interfaceID: InterfaceID, ephemeral: Identity = Identity(),
                    establishmentTimeout: TimeInterval = 15, keepaliveInterval: TimeInterval = 30,
                    relayNextHop: Data? = nil) {
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
            self.relayNextHop = relayNextHop
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
        case sendWithReceipt(data: Data, token: Data)
        case dataProofDeadline(packetHash: Data)
        /// Prove ONE inbound link data packet, by its `packetHash` (as surfaced with
        /// `delegate(.dataReceived)`). Mirrors reference `RNS.Packet.prove()` →
        /// `RNS.Link.prove_packet` (RNS/Link.py:378-388). Deliberately an explicit command, not a
        /// policy flag: RNS proves per-destination (`proof_strategy`, default `PROVE_NONE`), so the
        /// decision belongs to whichever composition classified the packet — see `LXMFServiceNode`.
        case provePacket(packetHash: Data)
        case transfer(IdentifiedActionOf<ResourceTransfer>)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case established(linkID: Data, sessionKey: Data)
            case establishmentFailed(EstablishmentFailure)
            /// An inbound application data packet. `packetHash` is the 32-byte hash the sender
            /// records as its pending receipt — pass it back to `.provePacket` to prove the packet.
            /// (Mirrors the reference callback signature `LXMRouter.propagation_packet(data, packet)`,
            /// which receives BOTH the decoded payload and the packet it must prove.)
            case dataReceived(data: Data, packetHash: Data)
            case closed(CloseReason)
            case resourceReceived(Data)
            case resourceConcluded(Data)
            case resourceFailed(Data)
            case identified(Identity)
            case responseReceived(requestID: Data, data: Data)
            case requestFailed(requestID: Data)
            case requestReceived(requestID: Data, pathHash: Data, data: Data)
            case packetDelivered(token: Data)
            case packetDeliveryFailed(token: Data)
        }
    }

    @Dependency(\.date) var date
    @Dependency(\.continuousClock) var clock
    @Dependency(\.uuid) var uuid
    @Dependency(\.randomBytes) var randomBytes

    private enum CancelID: Hashable { case establishment, keepalive, inactivity, request(Data), receipt(Data) }

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
            // MUST be a function, NOT a `let`. `Effect.cancel(id:)` is EAGER: it is built with
            // `.publisher { ... }`, whose closure runs at CONSTRUCTION
            // (ComposableArchitecture/Effects/Publisher.swift:8-10 —
            // `Self(operation: .publisher(createPublisher().eraseToAnyPublisher()))`), and that
            // closure performs `_cancellationCancellables.withValue { $0.cancel(id:path:) }`
            // (ComposableArchitecture/Effects/Cancellation.swift:106-117). Swift evaluates all
            // three `.merge` arguments eagerly, so binding this as a `let` at the top of the
            // `Reduce` closure cancelled establishment + keepalive + inactivity on EVERY action,
            // whether or not the branch returned it. Three consequences, each reproduced by
            // re-introducing the `let` and watching a named test go red:
            //   • the keepalive `while true` loop was cancelled by the very `.keepaliveDeadline`
            //     it had just emitted, so an initiator sent exactly ONE keepalive per link
            //     (activeInitiatorEmitsKeepaliveEveryInterval);
            //   • any action arriving mid-handshake killed the establishment timer, so the
            //     session hung in `.pending` with no deadline — never `.closed`, so never reaped
            //     (strayPacketDoesNotDisarmTheEstablishmentTimer);
            //   • any action with no re-arm behind it killed the inactivity timer — notably the
            //     `.delegate(.transmit)` echo of our own `.send` — so links never timed out
            //     (outboundSendDoesNotDisarmTheInactivityTimer).
            // Note what was NOT broken, since it misleads: inbound packets kept working, because
            // the re-arm hoisted into `.received` re-registers the timer the same action had just
            // destroyed. Only an action that cancels WITHOUT re-arming is observable.
            // Do NOT "simplify" this back to a stored property.
            func cancelAll() -> Effect<Action> {
                .merge(.cancel(id: CancelID.establishment),
                       .cancel(id: CancelID.keepalive),
                       .cancel(id: CancelID.inactivity))
            }
            func cancelPending(_ state: inout State) -> Effect<Action> {
                let cancels = state.pendingRequests.map { Effect<Action>.cancel(id: CancelID.request($0)) }
                state.pendingRequests.removeAll()
                return .merge(cancels)
            }
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
                let packet: Packet
                if let relay = state.relayNextHop {
                    // Destination is via a relay → HEADER_2 LINKREQUEST to the next hop.
                    packet = Packet(headerType: .header2, packetType: .linkRequest, transportType: .transport,
                                    destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: state.destinationHash, transportId: relay, payload: payload)
                } else {
                    packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                                    destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: state.destinationHash, transportId: nil, payload: payload)
                }
                state.linkID = Link.linkID(requestPacket: packet)     // header-independent — same id either way
                state.requestedAt = date.now.timeIntervalSince1970
                // LEAK GUARD: `packed()` has THREE throws — a non-16-byte `destinationHash`, an MTU
                // overflow, and (on the HEADER_2 relay branch directly above) a `transportId` that
                // is nil or not 16 bytes. That third one is the mode specific to this branch and is
                // the easiest to overlook. Whichever fires, `linkID` and `requestedAt` have already
                // been written and
                // no timer has been armed — bailing to `.none` would leave the element permanently
                // unreachable and unreapable. Emit `establishmentFailed` so `LinkPlane` removes it.
                //
                // `.handshakeRejected` is a DELIBERATE approximation, adjudicated rather than
                // defaulted to. No handshake was attempted — the failure is local packet assembly —
                // so strictly none of the `EstablishmentFailure` cases fit. `.timedOut` would be
                // actively harmful (it routes as path-shaped and solicits a path that cannot help).
                // `.handshakeRejected` routes as peer-shaped, so the caller retries the link: also
                // wrong in principle, but the OUTCOME is right — every retry fails identically and
                // synchronously, so the destination reaches `giveUp` and the message reaches
                // `deliveryFailed`, which is the correct terminal answer. The only cost is wasted
                // attempts on a path that is unreachable through every public endpoint.
                //
                // REVISIT IF this becomes reachable — i.e. if any composition can hand `openLink` a
                // non-16-byte destination hash, a relay `nextHop` that is nil or not 16 bytes, or
                // an MTU shrinks enough for a LINKREQUEST to overflow. Then add a terminal
                // `EstablishmentFailure` case that neither retries nor requests a path.
                // `LinkPlane`'s mapping is an exhaustive switch precisely so that addition is a
                // compile error and a deliberate routing decision.
                //
                // Practically unreachable: `openLink` requires a `transport.learned` identity,
                // which the parser always produces with exactly 16-byte hashes; `packed()` would
                // only throw on a misconfigured caller. The fix is defensive.
                guard let raw = try? packet.packed()
                else { return .send(.delegate(.establishmentFailed(.handshakeRejected))) }
                let id = state.interfaceID
                return .merge(.send(.delegate(.transmit(id, raw))), establishmentTimer(state.establishmentTimeout))

            case let .acceptRequest(data):
                // Split into two guards with distinct semantics.
                //
                // INTERNAL invariants: reaching here in the wrong role/status, or with
                // `owningIdentity` nil, means the action was misrouted — a bug on our side, not
                // something a remote peer can trigger. Leave the element alone.
                // (`owningIdentity` is set by `LinkPlane.acceptLinkRequest` from
                // `localDestinations`; it is nil only if the session was misconfigured locally.)
                guard state.role == .responder, state.status == .pending,
                      let owner = state.owningIdentity
                else { return .none }
                // PEER-CONTROLLED validation: a malformed request is remotely triggerable. Any
                // peer that has heard our announce can send wrong-sized payloads. If this guard
                // fails we MUST reap the element — `LinkPlane` appended it before dispatching
                // `.acceptRequest` and only removes elements on a delegate. Bailing to `.none`
                // here would leak the element forever, and `routeLinkPacket` linear-scans
                // `state.links` on every inbound packet.
                //
                // `.establishmentFailed(.handshakeRejected)` is the existing "over, cannot
                // recover" signal. `LinkPlane` gates `linkFailed` on `role == .initiator`, so a
                // responder emitting it removes the element without producing a spurious
                // `linkFailed` for our own served destination.
                guard let packet = Packet(raw: data), packet.packetType == .linkRequest,
                      (packet.payload.count == 64 || packet.payload.count == 67)
                else { return .send(.delegate(.establishmentFailed(.handshakeRejected))) }
                let linkID = Link.linkID(requestPacket: packet)
                let peerPub = Data(packet.payload.prefix(32))
                let ourPriv = Data((state.ephemeral.privateKey ?? Data()).prefix(32))
                let key = Link.sessionKey(ephemeralPrivateX25519: ourPriv,
                                          peerPublicX25519: peerPub, linkID: linkID)
                guard !key.isEmpty else { return .send(.delegate(.establishmentFailed(.handshakeRejected))) }
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
                // LEAK GUARD: `packed()` throws only if `linkID` is not 16 bytes or the payload
                // overflows MTU. By this point `state.linkID`, `sessionKey`, and `status` have all
                // been written and the session is in `.handshake` with no timer armed — bailing to
                // `.none` would leave the element permanently unreachable and unreapable. Same class
                // of defect as Task 1's responder `packed()` guard; the fix is the same shape.
                //
                // In practice this path is currently unreachable: `Link.linkID(requestPacket:)`
                // always produces 16 bytes (it is a `Crypto.truncatedHash` result), and
                // `Link.buildProof` always returns exactly 99 bytes — far below the 500-byte MTU.
                // No test drives this failure because no public API lets a caller produce a
                // 99-byte proof with a non-16-byte linkID without seeding invalid state directly;
                // seeding state defeats the purpose of the test (see task-2-report.md for
                // the full analysis). The fix is defensive: if the invariants ever break
                // (e.g. a future API change changes `buildProof`'s output size), the element is
                // reaped rather than leaked. `.handshakeRejected` on a responder is suppressed by
                // `LinkPlane`'s role gate, so no spurious `linkFailed` escapes.
                guard let raw = try? packetOut.packed()
                else { return .send(.delegate(.establishmentFailed(.handshakeRejected))) }
                let id = state.interfaceID
                return .merge(.send(.delegate(.transmit(id, raw))), establishmentTimer(state.establishmentTimeout))

            case let .received(data):
                guard let packet = Packet(raw: data), packet.destinationHash == state.linkID
                else { return .none }
                let now = date.now.timeIntervalSince1970
                // Initiator's own keepalive echo arrives back on the same link and must NOT count
                // as proof of life from the peer (RNS/Link.py:931 gates the entire receive block
                // on this condition). Drop it before the inactivity re-arm logic.
                if state.role == .initiator, packet.packetType == .data, packet.context == .keepalive,
                   packet.payload == Data([LinkSession.keepaliveByte]) { return .none }
                // Every other inbound packet (including ones that fail decryption) resets the
                // inactivity clock (RNS/Link.py:935 stamps `last_inbound` before decryption).
                // The re-arm is hoisted above the switch deliberately: re-arming per-branch is
                // how the 60s mid-transfer teardown got in — DATA, RESOURCE, REQUEST, RESPONSE,
                // and LINKIDENTIFY each silently omitted it. Adding a new context must not
                // require remembering this.
                func dispatch(_ state: inout State) -> Effect<Action> {
                switch (state.role, state.status, packet.packetType, packet.context) {
                case (.initiator, .pending, .proof, .linkRequestProof):
                    guard let destID = state.destinationIdentity,
                          let peerPub = Link.validateProof(proofData: packet.payload,
                                                           linkID: state.linkID,
                                                           destinationIdentity: destID)
                    else { return .send(.delegate(.establishmentFailed(.handshakeRejected))) }
                    let ourPriv = Data((state.ephemeral.privateKey ?? Data()).prefix(32))
                    let key = Link.sessionKey(ephemeralPrivateX25519: ourPriv,
                                              peerPublicX25519: peerPub, linkID: state.linkID)
                    guard !key.isEmpty else { return .send(.delegate(.establishmentFailed(.handshakeRejected))) }
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
                    else { return .send(.delegate(.establishmentFailed(.handshakeRejected))) }
                    state.rtt = rtt
                    state.status = .active
                    state.activatedAt = now
                    state.lastInbound = now
                    return .merge(.send(.delegate(.established(linkID: state.linkID, sessionKey: state.sessionKey))),
                                  .cancel(id: CancelID.establishment), inactivityTimer(state.staleTime))

                case (_, .active, .data, .none):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey)
                    else { return .none }   // corrupt/foreign data is ignored, link stays active
                    return .send(.delegate(.dataReceived(data: plain, packetHash: packet.packetHash)))

                case (_, .active, .data, .linkClose):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          plain == state.linkID
                    else { return .none }
                    state.status = .closed
                    let reason: CloseReason = state.role == .initiator ? .destinationClosed : .initiatorClosed
                    return .merge(.send(.delegate(.closed(reason))), cancelAll(), cancelPending(&state))

                case (.responder, .active, .data, .keepalive):
                    state.lastInbound = now
                    var effects: [Effect<Action>] = [inactivityTimer(state.staleTime)]
                    if packet.payload == Data([LinkSession.keepaliveByte]),
                       let raw = linkPacket(state.linkID, .keepalive, Data([LinkSession.keepaliveReplyByte])) {
                        effects.append(.send(.delegate(.transmit(state.interfaceID, raw))))
                    }
                    return .merge(effects)

                case (.initiator, .active, .data, .keepalive):
                    // Our own 0xFF loopback is already dropped by the `keepaliveByte` early return
                    // at the top of `.received`, before `dispatch` is entered at all, so anything
                    // reaching here is the peer's 0xFE reply. One copy of that policy, not two.
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
                          case let .bin(requestID) = items[0],
                          state.pendingRequests.contains(requestID)
                    else { return .none }
                    let data = MsgPack.encode(items[1])
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
                          case let .bin(pathHash) = items[1]
                    else { return .none }
                    let data = MsgPack.encode(items[2])
                    return .send(.delegate(.requestReceived(requestID: requestID, pathHash: pathHash, data: data)))

                case (_, .active, .proof, .none):
                    guard packet.payload.count == 96 else { return .none }
                    let proofHash = Data(packet.payload.prefix(32))
                    let signature = Data(packet.payload.suffix(64))
                    guard let token = state.pendingDataReceipts[proofHash],
                          let peer = state.destinationIdentity,
                          peer.validate(signature: signature, message: proofHash)
                    else { return .none }
                    state.pendingDataReceipts[proofHash] = nil
                    return .merge(.cancel(id: CancelID.receipt(proofHash)),
                                  .send(.delegate(.packetDelivered(token: token))))

                default:
                    return .none
                }
                }
                let effect = dispatch(&state)
                // Re-arm only when the link is still active after dispatch: the LINKCLOSE branch
                // sets .closed and must not have an inactivity timer re-armed behind it.
                guard state.status == .active else { return effect }
                state.lastInbound = now
                return .merge(effect, inactivityTimer(state.staleTime))

            case let .sendResource(data):
                guard state.status == .active else { return .none }
                let rnd = Data(randomBytes(8))
                let prefix = Data(rnd[rnd.startIndex ..< rnd.startIndex + 4])
                let randomHash = Data(rnd[rnd.startIndex + 4 ..< rnd.startIndex + 8])
                let newID = uuid()
                if data.count <= Self.maxEfficientSize {
                    state.transfers.append(ResourceTransfer.State(
                        sending: data, linkID: state.linkID, sessionKey: state.sessionKey,
                        interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                        sdu: Self.resourceSDU, rtt: .seconds(state.rtt ?? 1), id: newID))
                    return .send(.transfer(.element(id: newID, action: .advertise)))
                }
                // Split into ceil(count / maxEfficientSize) segments (index order).
                var segments: [Data] = []
                var off = data.startIndex
                while off < data.endIndex {
                    let end = data.index(off, offsetBy: Self.maxEfficientSize, limitedBy: data.endIndex) ?? data.endIndex
                    segments.append(Data(data[off ..< end]))
                    off = end
                }
                let total = UInt64(segments.count)
                let seg0 = segments[0]
                state.transfers.append(ResourceTransfer.State(
                    sending: seg0, linkID: state.linkID, sessionKey: state.sessionKey,
                    interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                    sdu: Self.resourceSDU, segmentIndex: 1, totalSegments: total,
                    originalHash: nil, totalDataSize: UInt64(data.count),
                    rtt: .seconds(state.rtt ?? 1), id: newID))
                let originalHash = state.transfers[id: newID]?.resourceHash ?? Data()
                state.segmentedSend = State.SegmentedSend(
                    remaining: Array(segments.dropFirst()), nextIndex: 2, total: total,
                    originalHash: originalHash, totalDataSize: UInt64(data.count), currentTransferID: newID)
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
                                                    .bin(pathHash), MsgPack.decodeValue(data) ?? .null]))
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
                let packed = MsgPack.encode(.array([.bin(requestID), MsgPack.decodeValue(data) ?? .null]))
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
                let pending = cancelPending(&state)
                guard let raw = linkPacket(state.linkID, .linkClose, cipher) else {
                    return .merge(.send(closedAction), cancelAll(), pending)
                }
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(closedAction), cancelAll(), pending)

            case .establishmentDeadline:
                guard state.status == .pending || state.status == .handshake else { return .none }
                state.status = .closed
                // An INITIATOR's establishment timeout is an establishment FAILURE, and must be
                // delivered keyed by DESTINATION. Emitting .closed here instead surfaces as
                // linkClosed(linkID:), which LXMFNode cannot reverse-map — directLinks is written
                // only on linkEstablished (LXMFNode.swift:256) — so the destination would wedge at
                // .establishing forever with no timer, no retry and no deliveryFailed.
                //
                // A RESPONDER's timeout stays .closed. For a responder `destinationHash` is our OWN
                // served destination (`LinkPlane.acceptLinkRequest`), not a remote peer, so `linkFailed` for
                // it carries no useful reachability information — a timeout here says only that an
                // inbound handshake stalled. `.closed` is the accurate description of that.
                //
                // This is NOT a claim that a responder never emits `.establishmentFailed` — it
                // already does on a malformed handshake, carrying `.handshakeRejected`. Those are
                // now suppressed at the plane: `LinkPlane` gates `linkFailed` on
                // `role == .initiator`, because a responder's `destinationHash` is the destination
                // WE serve and reporting it as unreachable would misinform the delivery layer.
                // The point here is narrower: the timeout path should not ADD another such instance.
                if state.role == .initiator {
                    return .merge(.send(.delegate(.establishmentFailed(.timedOut))), cancelAll(), cancelPending(&state))
                }
                return .merge(.send(.delegate(.closed(.timedOut))), cancelAll(), cancelPending(&state))

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
                let pending = cancelPending(&state)
                guard let raw = linkPacket(state.linkID, .linkClose, cipher) else {
                    return .merge(.send(closedAction), cancelAll(), pending)
                }
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(closedAction), cancelAll(), pending)

            case let .requestDeadline(requestID):
                guard state.pendingRequests.contains(requestID) else { return .none }
                state.pendingRequests.remove(requestID)
                return .send(.delegate(.requestFailed(requestID: requestID)))

            case let .sendWithReceipt(data, token):
                guard state.status == .active else { return .none }
                let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                    destinationType: .link, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: state.linkID, transportId: nil,
                                    payload: Link.encrypt(data, sessionKey: state.sessionKey))
                let packetHash = packet.packetHash
                guard let raw = try? packet.packed() else { return .none }
                state.pendingDataReceipts[packetHash] = token
                let timeout = (state.rtt ?? 0.5) * 6 + 11.25
                return .merge(
                    .send(.delegate(.transmit(state.interfaceID, raw))),
                    .run { [timeout] send in
                        try await clock.sleep(for: .seconds(timeout))
                        await send(.dataProofDeadline(packetHash: packetHash))
                    }.cancellable(id: CancelID.receipt(packetHash), cancelInFlight: true))

            case let .provePacket(packetHash):
                // Reference RNS/Link.py:378-388 `prove_packet`:
                //   signature  = self.sign(packet.packet_hash)
                //   proof_data = packet.packet_hash + signature
                //   RNS.Packet(self, proof_data, RNS.Packet.PROOF).send()   # context NONE, unencrypted
                // The signing key is the link's `sig_prv`, which for a RESPONDER link is the owning
                // destination's long-term identity key (RNS/Link.py:277) — the key the initiator
                // validates against (`load_peer` with `destination.identity`, RNS/Link.py:407-408).
                // Requiring `owningIdentity` therefore also structurally restricts proving to the
                // responder role, matching RNS: an initiator link signs with an ephemeral key the
                // peer never learns, so an initiator-side packet proof could never validate.
                guard state.status == .active, let owner = state.owningIdentity else { return .none }
                let proofData = packetHash + owner.sign(packetHash)
                let proofPacket = Packet(headerType: .header1, packetType: .proof,
                                         transportType: .broadcast, destinationType: .link,
                                         context: .none, contextFlag: false, hops: 0,
                                         destinationHash: state.linkID, transportId: nil,
                                         payload: proofData)
                guard let raw = try? proofPacket.packed() else { return .none }
                return .send(.delegate(.transmit(state.interfaceID, raw)))

            case let .dataProofDeadline(packetHash):
                guard let token = state.pendingDataReceipts[packetHash] else { return .none }
                state.pendingDataReceipts[packetHash] = nil
                return .send(.delegate(.packetDeliveryFailed(token: token)))

            case let .transfer(.element(_, .delegate(.transmit(ifID, raw)))):
                return .send(.delegate(.transmit(ifID, raw)))
            case let .transfer(.element(elementID, .delegate(.received(payload)))):
                let adv = state.transfers[id: elementID]?.advertisement
                state.transfers.remove(id: elementID)          // GC the completed receiver
                if adv?.isRequest == true {
                    guard case let .array(items)? = MsgPack.decodeValue(payload), items.count == 3,
                          case let .bin(pathHash) = items[1] else { return .none }
                    let data = MsgPack.encode(items[2])
                    return .send(.delegate(.requestReceived(requestID: Crypto.truncatedHash(payload),
                                                            pathHash: pathHash, data: data)))
                } else if adv?.isResponse == true {
                    guard case let .array(items)? = MsgPack.decodeValue(payload), items.count == 2,
                          case let .bin(rid) = items[0],
                          state.pendingRequests.contains(rid) else { return .none }
                    let data = MsgPack.encode(items[1])
                    state.pendingRequests.remove(rid)
                    return .merge(.cancel(id: CancelID.request(rid)),
                                  .send(.delegate(.responseReceived(requestID: rid, data: data))))
                }
                if adv?.isSplit == true, let a = adv {
                    var acc = state.incomingSegments[a.originalHash] ?? State.SegmentAccumulator(total: a.totalSegments, parts: [:])
                    acc.parts[a.segmentIndex] = payload
                    if UInt64(acc.parts.count) == acc.total {
                        // All segments in → concatenate in index order (1..total) → surface once.
                        state.incomingSegments[a.originalHash] = nil
                        var whole = Data()
                        for i in 1...acc.total { whole.append(acc.parts[i] ?? Data()) }
                        return .send(.delegate(.resourceReceived(whole)))
                    }
                    state.incomingSegments[a.originalHash] = acc
                    return .none    // wait for the next segment
                }
                return .send(.delegate(.resourceReceived(payload)))
            case let .transfer(.element(elementID, .delegate(.concluded))):
                let adv = state.transfers[id: elementID]?.advertisement
                let hash = state.transfers[id: elementID]?.resourceHash
                state.transfers.remove(id: elementID)
                if adv?.isRequest == true || adv?.isResponse == true { return .none }   // internal req/resp delivery
                // Segmented send in progress on this element?
                if var send = state.segmentedSend, send.currentTransferID == elementID {
                    if send.remaining.isEmpty {
                        // last segment concluded → surface the whole once
                        state.segmentedSend = nil
                        return .send(.delegate(.resourceConcluded(send.originalHash)))
                    }
                    let nextData = send.remaining.removeFirst()
                    let idx = send.nextIndex
                    let rnd = Data(randomBytes(8))
                    let prefix = Data(rnd[rnd.startIndex ..< rnd.startIndex + 4])
                    let randomHash = Data(rnd[rnd.startIndex + 4 ..< rnd.startIndex + 8])
                    let nextID = uuid()
                    state.transfers.append(ResourceTransfer.State(
                        sending: nextData, linkID: state.linkID, sessionKey: state.sessionKey,
                        interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
                        sdu: Self.resourceSDU, segmentIndex: idx, totalSegments: send.total,
                        originalHash: send.originalHash, totalDataSize: send.totalDataSize,
                        rtt: .seconds(state.rtt ?? 1), id: nextID))
                    send.nextIndex += 1
                    send.currentTransferID = nextID
                    state.segmentedSend = send
                    return .send(.transfer(.element(id: nextID, action: .advertise)))
                }
                guard let hash else { return .none }
                return .send(.delegate(.resourceConcluded(hash)))
            case let .transfer(.element(elementID, .delegate(.failed))):
                let t = state.transfers[id: elementID]
                state.transfers.remove(id: elementID)
                if let rid = t?.advertisement?.requestID, state.pendingRequests.contains(rid) {
                    state.pendingRequests.remove(rid)
                    return .merge(.cancel(id: CancelID.request(rid)),
                                  .send(.delegate(.requestFailed(requestID: rid))))
                }
                if t?.advertisement?.isRequest == true || t?.advertisement?.isResponse == true { return .none }
                // Segmented send in progress on this element?
                if let send = state.segmentedSend, send.currentTransferID == elementID {
                    state.segmentedSend = nil
                    return .send(.delegate(.resourceFailed(send.originalHash)))
                }
                if let a = t?.advertisement, a.isSplit == true {
                    state.incomingSegments[a.originalHash] = nil
                    return .send(.delegate(.resourceFailed(a.originalHash)))
                }
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
