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
    public enum CloseReason: Equatable, Sendable {
        case initiatorClosed, destinationClosed, timedOut
        /// A channel envelope went unproven through `ChannelConstants.maxTries` sends, and the
        /// channel tore the link down (RNS Channel.py:469-483 → `LinkChannelOutlet.timed_out`).
        case channelRetriesExhausted
    }

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
    /// Reference RNS's keepalive derivation (RNS/Link.py:83-94, 795-797): the cadence scales
    /// with measured RTT and is clamped into this range. Both ends of a link derive the SAME
    /// cadence, because the initiator ships its measured RTT to the responder in the LRRTT
    /// packet — which is why a link's keepalives always fit inside its peer's stale window.
    static let keepaliveMaxRTTRatio = 360.0 / 1.75   // KEEPALIVE_MAX / KEEPALIVE_MAX_RTT
    static let keepaliveMin: TimeInterval = 5        // KEEPALIVE_MIN
    static let keepaliveMax: TimeInterval = 360      // KEEPALIVE_MAX
    /// Most packets a responder holds while waiting for the LRRTT. The initiator's legitimate
    /// pre-RTT burst is an identify plus a request or two; the cap stops a session-key holder
    /// from growing the buffer without bound during the establishment window.
    static let handshakeBacklogLimit = 8
    /// One inbound packet held in `State.handshakeBacklog`, with the interface it arrived on.
    struct BufferedPacket: Equatable, Sendable {
        var data: Data
        var arrivalInterface: InterfaceID?
    }
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
        /// Responder only: the initiator's per-link Ed25519 public key, link-request bytes 32..<64.
        /// RNS loads it as `peer_sig_pub` (Link.py:411-416) to validate the initiator's packet proofs.
        public var peerSigningPub: Data? = nil
        public var sessionKey: Data
        public var requestedAt: Double?
        public var rtt: Double?
        public var activatedAt: Double?
        public var lastInbound: Double?
        /// Last time an AUTHENTICATED non-keepalive packet arrived — i.e. one that actually
        /// decrypted under the session key. `LinkPlane` evicts responder links in order of this
        /// clock, so it must not be advanceable by an unauthenticated peer.
        ///
        /// RNS keeps the same keepalive-vs-data distinction (`if packet.context != KEEPALIVE:
        /// self.last_data = self.last_inbound`) but stamps it BEFORE it decrypts. We deliberately
        /// diverge: without the decryption requirement, an attacker advances this with garbage and
        /// the eviction policy protects exactly the wrong links.
        public var lastData: Double?
        /// Set by a LOCAL interface disconnect: permits ONE re-home from an unauthenticated
        /// packet, because a reconnected BLE peer's only traffic on an idle link is a plaintext
        /// keepalive. A remote attacker cannot forge a local disconnect. One-shot by design —
        /// it clears on the re-home it authorises, so a disconnect does not permanently downgrade
        /// this element to unauthenticated re-homing.
        public var rehomePermitted: Bool = false
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
        /// Transfers ended by `.cancelResource`. Their `.failed` is not surfaced as
        /// `resourceFailed`: the owner asked for the cancel, so it is not news, and a late report
        /// could otherwise be mistaken for the failure of whatever the owner sends next.
        public internal(set) var cancelledTransferIDs: Set<UUID> = []
        public struct SegmentAccumulator: Equatable, Sendable {
            public var total: UInt64
            public var parts: [UInt64: Data]     // segmentIndex (1-based) -> segment data
        }
        public var incomingSegments: [Data: SegmentAccumulator] = [:]   // keyed by originalHash
        public var pendingDataReceipts: [Data: Data] = [:]              // sentPacketHash(32) → caller token
        public var establishmentTimeout: TimeInterval
        /// The configured keepalive cadence, and the fallback until RTT is measured. Every
        /// arming site runs after the handshake sets `rtt`, so in practice this is the floor of
        /// `staleTime` below rather than the cadence — see `effectiveKeepalive` for why using it
        /// as the cadence breaks RNS interop.
        public var keepaliveInterval: TimeInterval
        /// The cadence this link actually keeps alive: RNS's RTT-derived value once the
        /// handshake has measured one. A fixed 30 s cannot interoperate, because RNS clamps its
        /// own derivation to a 5 s floor on a fast link and reaps a link silent for twice that —
        /// so a peer's tightest stale window is 10 s, and a 30 s keepalive never arrives in time.
        var effectiveKeepalive: TimeInterval {
            guard let rtt else { return keepaliveInterval }
            return min(max(rtt * LinkSession.keepaliveMaxRTTRatio, LinkSession.keepaliveMin),
                       LinkSession.keepaliveMax)
        }
        /// How long this link tolerates INBOUND silence. Never shorter than the configured
        /// window, and never shorter than two of its own keepalives — the coupling RNS relies on
        /// so that a link still being kept alive is never reaped by its own watchdog, including
        /// on a slow link where the derived cadence is far longer than 30 s.
        var staleTime: TimeInterval { max(keepaliveInterval, effectiveKeepalive) * 2 }
        public var relayNextHop: Data? = nil
        /// Responder only: authenticated link traffic (DATA/NONE, LINKIDENTIFY, REQUEST, CHANNEL) that
        /// arrived while still in `.handshake`, i.e. BEFORE the LRRTT that activates the link.
        /// Replayed in arrival order, right after `.established`, when the LRRTT lands. Bounded by
        /// `LinkSession.handshakeBacklogLimit`; dropped if the handshake times out.
        var handshakeBacklog: [BufferedPacket] = []
        /// This link's RNS `Channel`: nil until `.openChannel` (or `.registerChannelMessageType`),
        /// and nil again once the link closes, by any path.
        public var channel: ChannelState? = nil
        /// Initiator: link to a known destination identity.
        public init(id: UUID = UUID(), initiatorTo destinationIdentity: Identity, destinationHash: Data,
                    interfaceID: InterfaceID, ephemeral: Identity = Identity(),
                    establishmentTimeout: TimeInterval = LinkTiming.defaultEstablishmentTimeout, keepaliveInterval: TimeInterval = 30,
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
            self.lastData = nil
            self.rehomePermitted = false
            self.remoteIdentity = nil
            self.pendingRequests = []
            self.establishmentTimeout = establishmentTimeout
            self.keepaliveInterval = keepaliveInterval
            self.relayNextHop = relayNextHop
        }

        /// Responder: accept links for a destination owned by `owningIdentity`.
        public init(id: UUID = UUID(), responderFor owningIdentity: Identity, destinationHash: Data,
                    interfaceID: InterfaceID, ephemeral: Identity = Identity(),
                    establishmentTimeout: TimeInterval = LinkTiming.defaultEstablishmentTimeout, keepaliveInterval: TimeInterval = 30) {
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
            self.lastData = nil
            self.rehomePermitted = false
            self.remoteIdentity = nil
            self.pendingRequests = []
            self.establishmentTimeout = establishmentTimeout
            self.keepaliveInterval = keepaliveInterval
        }
    }

    public enum Action: Equatable {
        case establish
        case acceptRequest(Data)
        /// `arrivalInterface` is the interface the packet actually arrived on. `nil` means the
        /// caller did not specify one — the session will not re-home. Defaulted so that callers
        /// testing session logic (rather than routing) need not thread it through.
        case received(Data, arrivalInterface: InterfaceID? = nil)
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
        /// `RNS.Link.prove_packet` (RNS 1.6.0 Link.py:463-474), in either link role. Deliberately an explicit command, not a
        /// policy flag: RNS proves per-destination (`proof_strategy`, default `PROVE_NONE`), so the
        /// decision belongs to whichever composition classified the packet — see `LXMFServiceNode`.
        case provePacket(packetHash: Data)
        /// Cancel OUR plain outbound Resource `hash` — the hash `resourceProgress` and
        /// `resourceConcluded` report, i.e. a split send's original hash. The transfer in flight
        /// sends the standard RESOURCE_ICL, segments not yet sent are dropped, and no
        /// `resourceFailed` follows. Unknown hash: no-op. Mirrors reference `Resource.cancel()`
        /// (RNS/Resource.py:1084-1117) as driven by `LXMRouter.cancel_outbound`.
        case cancelResource(hash: Data)
        /// Open this link's channel (RNS `Link.get_channel()`, Link.py:1007-1014). Idempotent; there
        /// is no wire handshake. Until a channel is open, inbound CHANNEL packets are dropped
        /// unproven (Link.py:1234-1236).
        case openChannel
        /// Accept envelopes of `type` on this link's channel, opening it first if needed.
        case registerChannelMessageType(ChannelMessageType)
        /// Send one channel message (RNS `Channel.send`, Channel.py:495-530). Answered by
        /// `channelMessageSent` or `channelSendRejected`, then `channelMessageDelivered` once the
        /// peer proves it.
        case sendChannelMessage(type: ChannelMessageType, payload: Data, token: Data)
        /// Internal: the retry timer of the outbound envelope `sequence` ran out.
        case channelDeadline(sequence: UInt16)
        /// Buffer (RNS `RawChannelReader`, Buffer.py:116-165): deliver stream data for `streamID` as
        /// `streamDataReceived`. Opens the channel and registers the stream message type `0xFF00`.
        case openStreamReader(streamID: UInt16)
        /// Stop delivering `streamID`. Its data is then dropped, still advancing the ring; `0xFF00`
        /// stays registered (`RawChannelReader.close`, Buffer.py:188-191).
        case closeStreamReader(streamID: UInt16)
        /// Buffer (RNS `RawChannelWriter.write`, Buffer.py:232-267): send ONE chunk of `data` on
        /// `streamID`, answered by `streamWritten(token, consumed)`. Call again with the rest. A
        /// chunk that went out is also reported by `channelMessageDelivered(token)` once proven.
        case writeStream(streamID: UInt16, data: Data, token: Data)
        /// Buffer (RNS `RawChannelWriter.close`, Buffer.py:269-280): send an empty EOF chunk, once the
        /// channel is ready or after a wait, and mark every later write to `streamID` EOF. Answered
        /// by `streamWritten(token, consumed: 0)` whether or not the EOF went out.
        case closeStreamWriter(streamID: UInt16, token: Data)
        /// Internal: the wait of the pending EOF for `streamID` / `token` ran out.
        case streamEOFDeadline(streamID: UInt16, token: Data)
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
            /// A plain Resource on this link failed. `rejected` is true when the peer refused it (see
            /// `ResourceTransfer.Action.Delegate.failed`). Not emitted for a `.cancelResource`.
            case resourceFailed(Data, rejected: Bool)
            /// Progress of a plain (non-request, non-response) Resource, either direction. `hash` is
            /// what `resourceConcluded`/`resourceFailed` carry: a split Resource's original hash.
            case resourceProgress(hash: Data, role: ResourceTransfer.Role, bytesDone: Int,
                                  bytesTotal: Int, segment: Int, segments: Int)
            case identified(Identity)
            /// A request went out under `requestID` (RNS `RequestReceipt.request_id`): what its
            /// `responseReceived` / `requestFailed` will carry, so the sender can route the answer to
            /// the request it asked rather than to whatever else waits on the link.
            case requestSent(requestID: Data, path: String)
            case responseReceived(requestID: Data, data: Data)
            case requestFailed(requestID: Data)
            case requestReceived(requestID: Data, pathHash: Data, data: Data)
            case packetDelivered(token: Data)
            case packetDeliveryFailed(token: Data)
            /// The session rebound to a new interface. `LinkPlane` re-homes in-flight transfers.
            case rehomed(InterfaceID)
            /// This link's linkID is now assigned — register it so Transport treats it as local
            /// (never relays or shadows it). Emitted for both initiator (.establish) and responder
            /// (.acceptRequest).
            case linkIDAssigned(Data)
            /// A channel envelope of a registered type was delivered in sequence order.
            case channelMessageReceived(msgType: UInt16, payload: Data)
            /// A channel message went out under `sequence`.
            case channelMessageSent(token: Data, sequence: UInt16)
            /// The peer proved the channel message sent with `token`.
            case channelMessageDelivered(token: Data)
            /// `sendChannelMessage` sent nothing.
            case channelSendRejected(token: Data, reason: ChannelSendRejection)
            /// A chunk of stream `streamID`, in order, for an open reader: inflated if it came
            /// compressed. `eof` is the chunk's own bit; the reference reader makes it sticky.
            case streamDataReceived(streamID: UInt16, data: Data, eof: Bool)
            /// What `writeStream` / `closeStreamWriter` did: `consumed` input bytes went out. 0 when
            /// nothing did (no channel, link not active, window full, stream id above 0x3FFF),
            /// as `RawChannelWriter.write` returns 0 on ME_LINK_NOT_READY (Buffer.py:264-267).
            case streamWritten(token: Data, consumed: Int)
        }
    }

    @Dependency(\.date) var date
    @Dependency(\.continuousClock) var clock
    @Dependency(\.uuid) var uuid
    @Dependency(\.randomBytes) var randomBytes

    enum CancelID: Hashable {
        case establishment, keepalive, inactivity, request(Data), receipt(Data)
        /// The retry timer of outbound channel envelope `sequence` (`LinkSession+Channel.swift`).
        case channel(UInt16)
        /// The wait of a pending stream EOF (`LinkSession+Stream.swift`).
        case streamEOF(streamID: UInt16, token: Data)
    }

    public init() {}

    /// The identity whose signature proves a packet WE sent on this link, i.e. RNS's
    /// `peer_sig_pub` (Link.py:1279-1283). An initiator loads it from the destination identity
    /// (Link.py:492); a responder from the link request's Ed25519 half (Link.py:411-416), paired
    /// here with the request's X25519 half only so `Identity` can hold it.
    func proofValidator(_ state: State) -> Identity? {
        switch state.role {
        case .initiator:
            return state.destinationIdentity
        case .responder:
            guard let x = state.peerX25519Pub, let ed = state.peerSigningPub else { return nil }
            return Identity(publicKey: x + ed)
        }
    }

    /// Transmit a proof of the inbound link packet `packetHash`, or nothing when the F4 guards
    /// refuse. Reference RNS 1.6.0 Link.py:463-474 `prove_packet`:
    ///   signature  = self.sign(packet.packet_hash)
    ///   proof_data = packet.packet_hash + signature
    ///   RNS.Packet(self, proof_data, RNS.Packet.PROOF).send()   # context NONE, unencrypted
    /// `self.sign` uses the link's `sig_prv` (Link.py:1276-1277): on a RESPONDER the owning
    /// destination's identity key (Link.py:303), on an INITIATOR the per-link Ed25519 key
    /// (Link.py:316) whose public half went out in the LINKREQUEST — which is `state.ephemeral`, sent
    /// whole by `.establish`. The peer validates against whichever it loaded (`proofValidator`).
    /// F4 guard set: the signer is read from session state, never from an action argument; the link
    /// must be `.active`; and the signer must hold a private key, because `Identity.sign`
    /// `preconditionFailure`s without one. A keyless signer can be seeded by a direct-composition
    /// caller, so guard the crash site itself, which also defends every caller (`.provePacket` and
    /// the channel's prove-on-receive).
    func proofTransmit(_ state: State, packetHash: Data) -> Effect<Action> {
        let signer: Identity? = state.role == .initiator ? state.ephemeral : state.owningIdentity
        guard state.status == .active, let signer, signer.privateKey != nil else { return .none }
        let proofData = packetHash + signer.sign(packetHash)
        let proofPacket = Packet(headerType: .header1, packetType: .proof,
                                 transportType: .broadcast, destinationType: .link,
                                 context: .none, contextFlag: false, hops: 0,
                                 destinationHash: state.linkID, transportId: nil,
                                 payload: proofData)
        guard let raw = try? proofPacket.packed() else { return .none }
        return .send(.delegate(.transmit(state.interfaceID, raw)))
    }

    public var body: some ReducerOf<Self> {
        // LATE CHILD ACTIONS. A transfer can be removed (GC on `.received`/`.concluded`/`.failed`,
        // or reaped on close below) while actions for it are still queued: TCA drains effect
        // actions breadth-first, so a sibling packet's chain (e.g. a LINKCLOSE that arrived in
        // the same TCP read as a resource proof) can remove the element one level before the
        // transfer's own delegate lands. `.forEach` would `reportIssue` for such an action —
        // which is a test failure, and was the "missing element" at this file's `.forEach` in
        // Nbhd's live suite. Nothing can be done with an action for an element that no longer
        // exists, so drop it quietly. Removal itself still cancels the element's running effects
        // (the watchdog timers), so this only catches actions already emitted.
        IgnoringActionsForRemovedElements(withTransfers) { (state: State, action: Action) -> Bool in
            guard case let .transfer(.element(id, _)) = action else { return false }
            return state.transfers[id: id] == nil
        }
    }

    private var withTransfers: some ReducerOf<Self> {
        sessionAndReaper.forEach(\.transfers, action: \.transfer) { ResourceTransfer() }
    }

    @ReducerBuilder<State, Action>
    private var sessionAndReaper: some ReducerOf<Self> {
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
            // The per-link half of every close path's cleanup (`cancelAll` is the fixed timers):
            // pending requests, and the channel with every retry timer it has armed (RNS
            // `link_closed` → `Channel._shutdown`, Link.py:775), so no channel delegate can follow
            // `.closed`. Like `cancelAll`, a function, so its eager cancels run only when called.
            func cancelPending(_ state: inout State) -> Effect<Action> {
                let cancels = state.pendingRequests.map { Effect<Action>.cancel(id: CancelID.request($0)) }
                state.pendingRequests.removeAll()
                return .merge(cancels + [closeChannel(&state)])
            }
            func linkPacket(_ linkID: Data, _ context: PacketContext, _ payload: Data) -> Data? {
                let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                               destinationType: .link, context: context, contextFlag: false, hops: 0,
                               destinationHash: linkID, transportId: nil, payload: payload)
                return try? p.packed()
            }
            // Close an ACTIVE link from this end: LINKCLOSE out, `.closed(reason)`, everything
            // cancelled. One copy for `.close`, the inactivity deadline and channel retry exhaustion.
            func closeActive(_ state: inout State, _ reason: CloseReason) -> Effect<Action> {
                let cipher = Link.encrypt(state.linkID, sessionKey: state.sessionKey)
                state.status = .closed
                let closedAction = Action.delegate(.closed(reason))
                let pending = cancelPending(&state)
                guard let raw = linkPacket(state.linkID, .linkClose, cipher) else {
                    return .merge(.send(closedAction), cancelAll(), pending)
                }
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(closedAction), cancelAll(), pending)
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
                // Register our linkID with Transport (so it never relays or shadows this link) in
                // the same reducer turn as the transmit. This defeats the reflected-LINKREQUEST
                // attack (F13) NOT because of ordering within this `.merge` — TCA does not guarantee
                // the order in which sibling effects' emitted actions are processed — but because a
                // reflection is an inbound NETWORK event: it cannot arrive until the transmit has
                // left the device and an attacker has observed and echoed it, a full round-trip
                // after this register action was already dispatched.
                return .merge(.send(.delegate(.linkIDAssigned(state.linkID))),
                              .send(.delegate(.transmit(id, raw))),
                              establishmentTimer(state.establishmentTimeout))

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
                // RNS `load_peer(peer_pub_bytes, peer_sig_pub_bytes)` takes both halves of the
                // request's key (Link.py:411-416); the Ed25519 half validates the initiator's
                // packet proofs.
                state.peerSigningPub = Data(packet.payload[(packet.payload.startIndex + 32)..<(packet.payload.startIndex + 64)])
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
                // Register our responder linkID before the proof transmit — same F13 timing
                // guarantee as the initiator path in `.establish`: a reflection is a post-transmit
                // network event, not a within-turn `.merge` ordering concern.
                return .merge(.send(.delegate(.linkIDAssigned(linkID))),
                              .send(.delegate(.transmit(id, raw))),
                              establishmentTimer(state.establishmentTimeout))

            case let .received(data, arrivalInterface):
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
                // ONE copy of the "did this packet authenticate" policy. Every branch that
                // decrypts must go through this helper rather than calling `Link.decrypt`
                // directly, so that adding a new decrypting context cannot silently forget to
                // advance `lastData`. (The same reasoning as hoisting the inactivity re-arm
                // below: per-branch bookkeeping is how the mid-transfer teardown bug got in.)
                var sawAuthenticatedData = false
                // `sawGenuineData` gates ONLY the `lastData` eviction clock (below). It is a strict
                // subset of `sawAuthenticatedData`, which still gates re-home authentication and must
                // stay set for advertisements. Advertisements authenticate but are not genuine use of
                // the slot, so they set `sawAuthenticatedData` but NOT `sawGenuineData` — otherwise a
                // peer advertising resources it never sends would look "recently active" and outrank
                // quiet legitimate peers in the eviction LRU (F11).
                var sawGenuineData = false
                func authDecrypt(_ payload: Data, _ key: Data) -> Data? {
                    guard let plain = Link.decrypt(payload, sessionKey: key) else { return nil }
                    sawAuthenticatedData = true
                    sawGenuineData = true
                    return plain
                }
                func authDecryptAdvertisement(_ payload: Data, _ key: Data) -> Data? {
                    guard let plain = Link.decrypt(payload, sessionKey: key) else { return nil }
                    sawAuthenticatedData = true    // still counts for re-home
                    return plain                   // NOT sawGenuineData → does not advance lastData
                }
                func dispatch(_ state: inout State) -> Effect<Action> {
                switch (state.role, state.status, packet.packetType, packet.context) {
                case (.initiator, .pending, .proof, .linkRequestProof):
                    // UNAUTHENTICATED INPUT — the initiator-side mirror of the responder RTT
                    // branch below. `linkID` rides unencrypted in every link packet header and
                    // `Transport` routes link-addressed packets ahead of `seenPacketHashes`, so
                    // any observer can inject a packet that lands here.
                    //
                    // Reaping on a bad proof cost us twice: `LinkPlane` removed our own outbound
                    // element, AND `.handshakeRejected` is the one PEER-shaped `LinkFailure`, so
                    // `LXMFNode` answered by retrying the link instead of requesting a path —
                    // spending the whole establishment budget against a route that works.
                    //
                    // Ignore it and let `establishmentDeadline` decide. The establishment timer is
                    // already armed, so the element stays reapable; and the failure then arrives
                    // as `.timedOut` → `.establishmentTimedOut`, which is PATH-shaped and triggers
                    // a path request.
                    guard let destID = state.destinationIdentity,
                          let peerPub = Link.validateProof(proofData: packet.payload,
                                                           linkID: state.linkID,
                                                           destinationIdentity: destID)
                    else { return .none }
                    let ourPriv = Data((state.ephemeral.privateKey ?? Data()).prefix(32))
                    let key = Link.sessionKey(ephemeralPrivateX25519: ourPriv,
                                              peerPublicX25519: peerPub, linkID: state.linkID)
                    guard !key.isEmpty else { return .none }
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
                                                     keepaliveTimer(state.effectiveKeepalive))
                    guard let raw = linkPacket(state.linkID, .linkRequestRTT, cipher) else {
                        return .merge(.send(established), extra)
                    }
                    return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(established), extra)

                case (.responder, .handshake, .data, .linkRequestRTT):
                    // UNAUTHENTICATED INPUT: link packets are routed by cleartext linkID ahead of
                    // Transport's seenPacketHashes dedup, and linkID rides unencrypted in every link
                    // packet header — so any observer can inject a packet that lands here. Reaping
                    // on a decrypt failure would let ONE injected packet silently kill a legitimate
                    // establishment (LinkPlane removes the element on .establishmentFailed, and
                    // suppresses linkFailed for responders, so the death is invisible).
                    //
                    // Ignore it instead and let `establishmentDeadline` decide. Same policy as the
                    // (_, .active, .data, .none) branch below: corrupt/foreign data is ignored and
                    // the element stays alive. The establishment timer is already armed, so the
                    // element is still reapable — the §1b invariant holds.
                    guard let plain = authDecrypt(packet.payload, state.sessionKey),
                          let rtt = MsgPack.decodeDouble(plain)
                    else { return .none }
                    state.rtt = rtt
                    state.status = .active
                    state.activatedAt = now
                    state.lastInbound = now
                    // Replay anything that beat the LRRTT here (see the `.handshake` buffering
                    // branch below), AFTER `.established` and in arrival order, now that the
                    // `.active` branches will accept it.
                    let replays = state.handshakeBacklog.map {
                        Effect<Action>.send(.received($0.data, arrivalInterface: $0.arrivalInterface))
                    }
                    state.handshakeBacklog = []
                    let established = Effect<Action>.send(
                        .delegate(.established(linkID: state.linkID, sessionKey: state.sessionKey)))
                    return .merge(.concatenate([established] + replays),
                                  .cancel(id: CancelID.establishment), inactivityTimer(state.staleTime))

                case (.responder, .handshake, .data, .none),
                     (.responder, .handshake, .data, .linkIdentify),
                     (.responder, .handshake, .data, .request),
                     (.responder, .handshake, .data, .channel):
                    // Authenticated traffic that overtook the LRRTT. The initiator goes `.active`
                    // on the proof and may send DATA/identify/request immediately after the RTT;
                    // nothing guarantees they arrive after it (TCPClientInterface once reordered
                    // its own frames; a multi-path mesh still can). These used to fall to
                    // `default: .none` — the request was silently lost and the initiator's
                    // request timed out ~11 s later.
                    //
                    // Reference RNS (RNS/Link.py `__receive`) gates only on `status != CLOSED`:
                    // it processes LINKIDENTIFY and DATA during HANDSHAKE, but `handle_request`
                    // requires `status == ACTIVE`, so a pre-RTT REQUEST is dropped there too. RNS
                    // does NOT promote a link to ACTIVE on data — only `rtt_packet` (or
                    // `validate_proof` on the initiator) does. So we do not promote either: we
                    // BUFFER, and replay once the LRRTT activates the link, which also keeps the
                    // RTT/keepalive derivation fed by the real RTT.
                    //
                    // Only packets that decrypt under the session key are held (injected junk is
                    // still ignored, as in the RTT branch above), and at most
                    // `handshakeBacklogLimit` of them. The establishment timer stays armed, so a
                    // link that never receives its RTT is still reaped and the buffer with it.
                    guard state.handshakeBacklog.count < LinkSession.handshakeBacklogLimit,
                          authDecrypt(packet.payload, state.sessionKey) != nil
                    else { return .none }
                    state.handshakeBacklog.append(
                        BufferedPacket(data: data, arrivalInterface: arrivalInterface))
                    return .none

                case (_, .active, .data, .none):
                    guard let plain = authDecrypt(packet.payload, state.sessionKey)
                    else { return .none }   // corrupt/foreign data is ignored, link stays active
                    return .send(.delegate(.dataReceived(data: plain, packetHash: packet.packetHash)))

                case (_, .active, .data, .channel):
                    return receiveChannelPacket(&state, packet, decrypt: authDecrypt)

                case (_, .active, .data, .linkClose):
                    guard let plain = authDecrypt(packet.payload, state.sessionKey),
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
                    guard let plain = authDecryptAdvertisement(packet.payload, state.sessionKey),
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
                     (_, .active, .data, .resourceInitiatorCancel),
                     (_, .active, .data, .resourceReceiverCancel):
                    return .merge(state.transfers.ids.map {
                        .send(.transfer(.element(id: $0, action: .received(data))))
                    })

                case (_, .active, .data, .resourceProof),
                     (_, .active, .proof, .resourceProof):
                    // OWNERSHIP ROUTING. `Resource.proofData` is `hash ‖ fullHash(data ‖ hash)`,
                    // so the leading 32 bytes ARE the resource hash. Fanning a proof out to every
                    // transfer meant one packet reached transfers that did not own it — and two of
                    // our OWN concurrent sends destroyed each other, with no attacker involved.
                    //
                    // Reference routes the same way in `Link.receive`, and scopes to
                    // `outgoing_resources` — sender-role only. Note a proof CANNOT be
                    // authenticated: `Packet.pack` has a branch dedicated to `RESOURCE_PRF`
                    // leaving resource proofs unencrypted, so ownership is the only discriminator
                    // available. `ResourceTransfer` therefore also does not destroy itself on a
                    // proof that fails to validate — that half landed in `0101a74`, and the two
                    // together are what make an unownable, unauthenticatable packet harmless.
                    //
                    // Only `.resourceProof` left the fan-out group. The FIVE contexts in the case
                    // directly above still fan out to every transfer. Four of them are safe to
                    // fan out because their `ResourceTransfer` branch decrypts and THEN compares
                    // against `state.resourceHash`, so a non-owner returns `.none`:
                    // `.resourceRequest`, `.resourceHashmapUpdate`, `.resourceInitiatorCancel`,
                    // `.resourceReceiverCancel`. The fifth, `.resource`, carries no resource hash
                    // at all — its only discriminator is `Resource.mapHash` under the per-transfer
                    // `randomHash`, which is narrower than the other four. See
                    // `docs/superpowers/2026-08-13-destructive-transition-sweep.md`.
                    // (`d0570ef`'s commit message says "the other six resource contexts"; it is
                    // five. The code was right, the message was not, and a pushed message cannot
                    // be corrected in place.)
                    // The length check is load-bearing, not a formality: `prefix(32)` yields a
                    // SHORT `Data` rather than trapping, so without it a truncated payload would
                    // reach the comparison below. `role == .sender` independently saves us today
                    // (sender hashes are always 32-byte SHA-256), but a RECEIVER's `resourceHash`
                    // is wire-controlled — `ResourceAdvertisement.unpack` does not validate `h`'s
                    // length — so an empty advertised hash plus an empty payload would compare
                    // EQUAL the moment the role gate is weakened. Two locks, deliberately.
                    guard packet.payload.count >= 32 else { return .none }
                    let owner = Data(packet.payload.prefix(32))
                    guard let target = state.transfers.first(where: {
                        $0.role == .sender && $0.resourceHash == owner
                    }) else { return .none }
                    return .send(.transfer(.element(id: target.id, action: .received(data))))

                case (_, .active, .data, .response):
                    guard let plain = authDecrypt(packet.payload, state.sessionKey),
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
                          let plain = authDecrypt(packet.payload, state.sessionKey)
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
                    guard let plain = authDecrypt(packet.payload, state.sessionKey),
                          case let .array(items)? = MsgPack.decodeValue(Data(plain)), items.count == 3,
                          case let .bin(pathHash) = items[1]
                    else { return .none }
                    let data = MsgPack.encode(items[2])
                    return .send(.delegate(.requestReceived(requestID: requestID, pathHash: pathHash, data: data)))

                case (_, .active, .proof, .none):
                    guard packet.payload.count == 96 else { return .none }
                    let proofHash = Data(packet.payload.prefix(32))
                    let signature = Data(packet.payload.suffix(64))
                    guard let token = state.pendingDataReceipts[proofHash] else {
                        return channelProofReceived(&state, proofHash: proofHash, signature: signature)
                    }
                    guard let peer = proofValidator(state),
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
                if sawGenuineData { state.lastData = now }
                var extra: [Effect<Action>] = []
                // RE-HOME, gated on authentication OR a local-disconnect permission.
                //
                // Authentication gate: A BLE peer that reconnects gets a new InterfaceID by
                // construction, so the binding taken at creation goes stale and outbound would
                // fire at a dead interface. Re-homing on UNAUTHENTICATED input is link theft:
                // `linkID` rides unencrypted in every link packet header, so before this gate
                // merely OBSERVING one packet was enough to redirect a legitimate peer's traffic
                // to yourself.
                //
                // What the authentication gate actually establishes, stated precisely: this packet
                // ORIGINATED from a holder of the session key. It does NOT establish that the
                // party that just sent it holds that key. Nothing here dedupes inbound link
                // packets, so identical bytes decrypt identically however many times they
                // arrive, and from wherever.
                //
                // RESIDUAL, deliberately left open and recorded here because this is the only
                // site that reasons about it: an attacker who CAPTURES one authenticated data
                // packet can replay those exact bytes from its own interface and still re-home
                // the link. Link traffic reaches us ahead of Transport's replay dedup —
                // `Transport`'s `.received` returns `.delegate(.linkPacket(...))` for link
                // packets before it reaches the `seenPacketHashes.insert` guard, which sits
                // below that return — and `LinkSession` keeps no inbound packet-hash set of
                // its own (`pendingDataReceipts` is keyed by OUTBOUND packet hash, for proofs).
                // The vector is narrowed from "observe a linkID" to "capture a data packet",
                // not closed. Closing it needs per-packet replay rejection on the link, which
                // does not exist anywhere in the link path today.
                //
                // Local-disconnect permission (`rehomePermitted`): an idle link whose only
                // inbound traffic is plaintext keepalives can never set `sawAuthenticatedData`,
                // so a BLE peer that reconnects after an idle period would stay bound to the dead
                // interface and every outbound would fail. A LOCAL interface disconnect cannot be
                // forged by a remote attacker, so the TRIGGER is sound.
                //
                // The trigger being unforgeable does NOT make the CONSUMPTION authenticated, and
                // nothing below constrains who spends the grant. Recorded here because this block
                // is the only site that reasons about it: once `rehomePermitted` is set, the first
                // link-addressed packet arriving on ANY interface other than the stored one
                // re-homes the link with no authentication whatsoever. The reducer cannot tell the
                // reconnecting peer from anyone else — it sees only `arrivalInterface`.
                //
                // That is reachable, not theoretical. `BLEEndpoint.State.peerInterfaces` is a
                // multi-peer map (`[InterfaceID: Data]`), and BLEEndpoint's
                // `.transport(.delegate(.linkPacket))` handler routes EVERY peer's link packets
                // into `LinkPlane.routeLinkPacket` tagged with that peer's `InterfaceID`
                // (`Transport` passes through the `interfaceID` given to `.received`). Since
                // `linkID` rides in cleartext, a second connected BLE peer that has merely
                // OBSERVED one link packet can claim the grant ahead of the returning peer. Note
                // this residual has a WEAKER prerequisite than the replay residual above: that one
                // needs a captured authenticated packet, this one needs only an observed `linkID`.
                //
                // It is bounded to at most ONE re-home per local disconnect: the permission is
                // consumed on first use below, so a disconnect does not permanently downgrade this
                // element to unauthenticated re-homing.
                //
                // It is NOT usefully bounded by the inactivity watchdog, and an earlier version of
                // this comment claimed it was. The re-arm below `dispatch` fires for ANY packet
                // whose `destinationHash` matches `linkID` while the link is `.active` — including
                // one that fails to decrypt and one whose context has no branch at all — so the
                // party that spent the grant refreshes `staleTime` with junk for as long as it
                // likes. Nothing clears `rehomePermitted` except the re-home that spends it, so the
                // grant does not expire on its own either.
                //
                // Closing it properly needs the same thing the replay residual needs: authenticated
                // proof of liveness on the link, which does not exist in the link path today.
                // Accepted deliberately: without it a reconnected BLE peer is stranded on a dead
                // interface with no recovery short of link timeout.
                //
                // The `arrival != state.interfaceID` guard is load-bearing in BOTH branches: an
                // ordinary same-interface packet would otherwise burn the one-shot permission
                // before the reconnecting peer could use it.
                if let arrival = arrivalInterface, arrival != state.interfaceID,
                   sawAuthenticatedData || state.rehomePermitted {
                    state.rehomePermitted = false          // one-shot
                    state.interfaceID = arrival
                    extra.append(.send(.delegate(.rehomed(arrival))))
                }
                return .merge([effect, inactivityTimer(state.staleTime)] + extra)

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
                        .concatenate(.send(.delegate(.requestSent(requestID: requestID, path: path))),
                                     .send(.delegate(.transmit(ifID, raw)))),
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
                        .concatenate(.send(.delegate(.requestSent(requestID: requestID, path: path))),
                                     .send(.transfer(.element(id: newID, action: .advertise)))),
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
                // A close during `.handshake` still does not tear the link down (only an active
                // link has a session to close on the wire; the establishment deadline reaps it),
                // but it does drop anything held for replay — the owner no longer wants this
                // link's traffic, same as when the establishment deadline fires.
                if state.status == .handshake { state.handshakeBacklog = [] }
                guard state.status == .active else { return .none }
                return closeActive(&state, state.role == .initiator ? .initiatorClosed : .destinationClosed)

            case .establishmentDeadline:
                guard state.status == .pending || state.status == .handshake else { return .none }
                state.status = .closed
                state.handshakeBacklog = []
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
                return closeActive(&state, .timedOut)

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
                // Signing, F4 guards and the reference citations live in `proofTransmit`.
                return proofTransmit(state, packetHash: packetHash)

            case .openChannel:
                openChannel(&state)
                return .none

            case let .registerChannelMessageType(type):
                openChannel(&state)
                state.channel?.registered.insert(type.rawValue)
                return .none

            case let .sendChannelMessage(type, payload, token):
                return sendChannelMessage(&state, type: type, payload: payload, token: token)

            case let .channelDeadline(sequence):
                switch channelDeadline(&state, sequence: sequence) {
                case .ignored: return .none
                case let .resent(effect): return effect
                case .exhausted: return closeActive(&state, .channelRetriesExhausted)
                }

            case let .openStreamReader(streamID):
                openStreamReader(&state, streamID: streamID)
                return .none

            case let .closeStreamReader(streamID):
                state.channel?.streamReaders.remove(streamID)
                return .none

            case let .writeStream(streamID, data, token):
                return writeStream(&state, streamID: streamID, data: data, token: token)

            case let .closeStreamWriter(streamID, token):
                return closeStreamWriter(&state, streamID: streamID, token: token)

            case let .streamEOFDeadline(streamID, token):
                return streamEOFDeadline(&state, streamID: streamID, token: token)

            case let .dataProofDeadline(packetHash):
                guard let token = state.pendingDataReceipts[packetHash] else { return .none }
                state.pendingDataReceipts[packetHash] = nil
                return .send(.delegate(.packetDeliveryFailed(token: token)))

            case let .cancelResource(hash):
                if let send = state.segmentedSend, send.originalHash == hash {
                    // A split send: drop the segments not yet sent, then cancel the one in flight.
                    state.segmentedSend = nil
                    guard state.transfers[id: send.currentTransferID] != nil else { return .none }
                    state.cancelledTransferIDs.insert(send.currentTransferID)
                    return .send(.transfer(.element(id: send.currentTransferID, action: .cancel)))
                }
                guard let target = state.transfers.first(where: {
                    $0.role == .sender && $0.resourceHash == hash
                        && $0.advertisement?.isRequest != true && $0.advertisement?.isResponse != true
                }) else { return .none }
                state.cancelledTransferIDs.insert(target.id)
                return .send(.transfer(.element(id: target.id, action: .cancel)))

            case let .transfer(.element(elementID, .delegate(.progress(done, total, segment, segments)))):
                // Request/response Resources are this link's own plumbing, not deliveries.
                guard let t = state.transfers[id: elementID], let adv = t.advertisement,
                      !adv.isRequest, !adv.isResponse else { return .none }
                return .send(.delegate(.resourceProgress(hash: adv.isSplit ? adv.originalHash : t.resourceHash,
                                                         role: t.role, bytesDone: done, bytesTotal: total,
                                                         segment: segment, segments: segments)))
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
            case let .transfer(.element(elementID, .delegate(.failed(rejected)))):
                let t = state.transfers[id: elementID]
                state.transfers.remove(id: elementID)
                // Ended by `.cancelResource`: the owner asked for it.
                if state.cancelledTransferIDs.remove(elementID) != nil { return .none }
                if let rid = t?.advertisement?.requestID, state.pendingRequests.contains(rid) {
                    state.pendingRequests.remove(rid)
                    return .merge(.cancel(id: CancelID.request(rid)),
                                  .send(.delegate(.requestFailed(requestID: rid))))
                }
                if t?.advertisement?.isRequest == true || t?.advertisement?.isResponse == true { return .none }
                // Segmented send in progress on this element?
                if let send = state.segmentedSend, send.currentTransferID == elementID {
                    state.segmentedSend = nil
                    return .send(.delegate(.resourceFailed(send.originalHash, rejected: rejected)))
                }
                if let a = t?.advertisement, a.isSplit == true {
                    state.incomingSegments[a.originalHash] = nil
                    return .send(.delegate(.resourceFailed(a.originalHash, rejected: rejected)))
                }
                guard let hash = t?.resourceHash else { return .none }
                return .send(.delegate(.resourceFailed(hash, rejected: rejected)))
            case .transfer:
                return .none

            case .delegate:
                return .none
            }
        }
        // CLOSE REAPS TRANSFERS, at the source. Whatever closed the session (`.close`, an inbound
        // LINKCLOSE, the inactivity or establishment deadline), its transfers are dead with it.
        // Removing them HERE — inside the reducer that `.forEach(\.transfers)` wraps — makes
        // `.forEach` cancel their effects in the same turn, so a closed session's watchdogs can
        // no longer fire `receiverDeadline`/`senderDeadline` and retransmit on a closed link.
        // Before this, they ran until `LinkPlane` removed the whole element, and a session used
        // standalone kept transmitting resource traffic after it closed.
        Reduce { state, _ in
            guard state.status == .closed, !state.transfers.isEmpty || !state.cancelledTransferIDs.isEmpty
            else { return .none }
            state.transfers.removeAll()
            state.cancelledTransferIDs.removeAll()
            return .none
        }
    }
}

extension LinkSession.State: Identifiable {}
