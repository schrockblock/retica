import Foundation
import ComposableArchitecture
import ReTiCA

// A Transport-internal date key whose testValue returns epoch-0, so that tests that exercise
// path-learning or link-packet forwarding without providing an explicit date dependency do not
// trigger an "unimplemented" failure. Tests that need a controllable date set $0.transportDate.
private enum TransportDateKey: DependencyKey {
    static let liveValue    = DateGenerator { Date() }
    static let testValue    = DateGenerator { Date(timeIntervalSince1970: 0) }
    static let previewValue = liveValue
}
extension DependencyValues {
    /// Date generator used internally by Transport for stamping learnedAt / refreshedAt.
    public var transportDate: DateGenerator {
        get { self[TransportDateKey.self] }
        set { self[TransportDateKey.self] = newValue }
    }
}

/// The Reticulum Transport layer, endpoint (leaf) subset: learns paths from announces,
/// delivers inbound packets to local destinations, and routes outbound packets to learned
/// destinations. Interface-agnostic — interfaces are referenced by `InterfaceID`.
@Reducer
public struct Transport {
    @ObservableState
    public struct State: Equatable {
        public var localDestinations: [Data: Destination] = [:]
        /// App data most recently announced for each local destination, replayed in path responses
        /// AND in any later announce that omits app data. Reference equivalent:
        /// `Destination.default_app_data` (RNS/Destination.py:193), which `announce()` substitutes
        /// whenever `app_data is None` (RNS/Destination.py:289-296) — so ordinary announces and
        /// path responses always advertise the same thing. Without this a path response — which is
        /// stamped NOW and so wins `shouldReplace` — overwrites the requester's richer entry with
        /// nil. Written by `.announce`, cleared by `.registerLocalDestination`; see both for the
        /// divergence from reference's explicit `set_default_app_data`.
        public var localAppData: [Data: Data] = [:]
        public var learned: [Data: LearnedDestination] = [:]
        public var interfaces: [InterfaceID: InterfaceProfile] = [:]
        public var transportIdentity: Identity? = nil
        var seenPacketHashes = RingSet(capacity: Transport.seenPacketRingSize)
        public var linkTable: [Data: LinkTableEntry] = [:]
        /// Per-destination ring of recently-seen announce random-blobs (the 10-byte announce
        /// random_hash). Replaces packetHash dedup for announces: a repeated blob is a replay
        /// (RNS Transport.py:1824 `not random_blob in random_blobs`). Bounded to
        /// `announceBlobRingSize` per destination (RNS MAX_RANDOM_BLOBS).
        public var announceBlobs: [Data: RingSet] = [:]
        /// A cached announce, kept whole so a relay can re-emit it verbatim.
        ///
        /// The context flag is stored ALONGSIDE the payload rather than re-derived when the
        /// response is minted, because for an announce the flag is a field-layout declaration
        /// about these exact bytes ("a 32-byte ratchet sits between random_hash and signature"),
        /// not a fact about our parsed view of them. The two can disagree: `Announce.parse` drops
        /// a ratchet that cannot perform key agreement while the bytes stay in the payload, so
        /// `learned[dest].ratchet == nil` does NOT imply the payload is ratchet-free. Deriving the
        /// flag from parsed state emitted `contextFlag: false` over a ratchet-carrying payload and
        /// the receiver then parsed with `ratchetLen = 0`, misaligning signature and app data.
        public struct CachedAnnounce: Equatable, Sendable {
            public var payload: Data
            public var contextFlag: Bool
            public init(payload: Data, contextFlag: Bool) {
                self.payload = payload
                self.contextFlag = contextFlag
            }
        }
        /// destHash → the announce payload (carries the destination's valid signature) and its
        /// context flag, for the currently-learned path. Enables a relay to re-emit a cached
        /// announce as a path response (RNS get_cached_packet, Transport.py:2973) — reference
        /// caches the whole PACKET and re-sends it, so the flag rides along there too. GC'd with
        /// the path.
        public var announceCache: [Data: CachedAnnounce] = [:]

        /// unique_tag (destHash ‖ tag) ring for PATH_REQUEST dedup — a duplicate tagged request is
        /// ignored rather than re-answered (RNS discovery_pr_tags, Transport.py:2924-2934). Bounded
        /// (auto-evicts oldest at capacity), so no separate GC pass.
        public var discoveryPrTags = RingSet(capacity: Transport.pathRequestTagRingSize)

        /// Opt-in: when set (and in relay mode), a PATH_REQUEST for an unknown destination is
        /// re-broadcast onward for recursive discovery (RNS recursive_prs, Transport.py:2946).
        public var recursivePathRequests = false

        /// destHash → when a recursive search for it began. Coalesces concurrent searches for the
        /// same destination; GC'd after pathRequestTimeout (RNS discovery_path_requests, Transport.py:3060).
        /// Written ONLY by the relay path (transportIdentity != nil && recursivePathRequests).
        public var discoveryPathRequests: [Data: Date] = [:]

        /// destHash → when THIS node issued a local path request for it (RNS Transport.path_requests,
        /// Transport.py:2899). Written by .requestPath regardless of relay/leaf mode. Distinct from
        /// discoveryPathRequests which is relay-only; both gate the ingress exemption so that a
        /// path-response announce for a destination we explicitly asked for is never held mid-burst
        /// (RNS Transport.py:1759 checks BOTH tables). GC'd after pathRequestGateTimeout (120 s).
        public var pathRequests: [Data: Date] = [:]

        public struct PendingAnnounce: Equatable, Sendable {
            public var raw: Data
            public var arrivalInterface: InterfaceID
            public var rebroadcasts: Int
            public var rebroadcastHops: UInt8     // hops our re-broadcast carries (= arrival packet.hops + 1)
            public var localRebroadcasts: Int     // heard peer re-broadcasts (RNS IDX_AT_LCL_RBRD)
            public init(raw: Data, arrivalInterface: InterfaceID, rebroadcastHops: UInt8,
                        rebroadcasts: Int = 0, localRebroadcasts: Int = 0) {
                self.raw = raw; self.arrivalInterface = arrivalInterface
                self.rebroadcastHops = rebroadcastHops
                self.rebroadcasts = rebroadcasts; self.localRebroadcasts = localRebroadcasts
            }
        }
        /// Fresh announces held for a jittered re-broadcast, keyed by destinationHash (4b-3b-1).
        public var announceTable: [Data: PendingAnnounce] = [:]

        /// An announce held for an interface until its pacing window opens (RNS announce_queue).
        public struct QueuedAnnounce: Equatable, Sendable {
            public var raw: Data
            public var hops: UInt8
            public var queuedAt: Date
            /// Destination hash — used for per-destination dedup (Finding 2 / RNS Transport.py:1292-1306).
            public var destination: Data
            /// Emission timestamp from the announce's random hash — used to pick the newer entry on upsert.
            public var emitted: UInt64
            public init(raw: Data, hops: UInt8, queuedAt: Date,
                        destination: Data = Data(), emitted: UInt64 = 0) {
                self.raw = raw; self.hops = hops; self.queuedAt = queuedAt
                self.destination = destination; self.emitted = emitted
            }
        }
        /// Earliest time each interface may emit its next RELAYED announce (RNS announce_allowed_at).
        public var announceAllowedAt: [InterfaceID: Date] = [:]
        /// Per-interface announces awaiting their pacing slot (RNS announce_queue).
        public var announceQueues: [InterfaceID: [QueuedAnnounce]] = [:]

        // MARK: - C4 ingress control state

        /// An announce held by ingress control until the burst subsides (RNS held_announces).
        public struct HeldAnnounce: Equatable, Sendable {
            public var raw: Data
            public var hops: UInt8
            public init(raw: Data, hops: UInt8) { self.raw = raw; self.hops = hops }
        }
        /// Arrival times of recent signature-valid announces per interface (RNS ia_freq_deque).
        public var announceArrivals: [InterfaceID: [Date]] = [:]
        /// Per-interface announce burst state (RNS ic_burst_*).
        public var ingressBursts: [InterfaceID: Transport.IngressBurst] = [:]
        /// Held announces per interface, keyed by destination (RNS held_announces).
        public var heldAnnounces: [InterfaceID: [Data: HeldAnnounce]] = [:]
        /// When each interface connected — drives the young/established burst threshold (RNS age()).
        public var interfaceConnectedAt: [InterfaceID: Date] = [:]

        public init() {}

        /// The learned path to `destinationHash`, but only when its interface is currently connected.
        ///
        /// `LearnedDestination.interfaceID` is captured at announce time and replaced only by a
        /// strictly-newer announce, so after a BLE peer restarts (its InterfaceID derives from the
        /// HELLO session token, making a reconnected peer a DIFFERENT interface) the stored binding
        /// names a dead interface until that peer's next announce — minutes away.
        ///
        /// Deliberately NON-DESTRUCTIVE: the entry is retained, not purged. Purging on
        /// `interfaceDisconnected` would discard every path on every TCP reconnect, since TCP's
        /// InterfaceID is fixed and returns after a blip.
        public func reachableLearned(_ destinationHash: Data) -> LearnedDestination? {
            guard let entry = learned[destinationHash], interfaces[entry.interfaceID] != nil
            else { return nil }
            return entry
        }

        public struct LinkTableEntry: Equatable, Sendable {
            public var rcvdIf: InterfaceID
            public var nhIf: InterfaceID
            public var refreshedAt: Date
            public init(rcvdIf: InterfaceID, nhIf: InterfaceID,
                        refreshedAt: Date = Date(timeIntervalSince1970: 0)) {
                self.rcvdIf = rcvdIf
                self.nhIf = nhIf
                self.refreshedAt = refreshedAt
            }
        }
    }

    public enum SendFailure: Equatable, Sendable {
        case notLearned
        case tooLarge
        /// The packet was addressed to an interface that is not currently connected. On BLE an
        /// InterfaceID is derived from the peer's HELLO session token, so a reconnected peer is a
        /// DIFFERENT interface — anything still bound to the old one (notably a LinkSession, which
        /// binds its interfaceID once at creation) lands here. Previously a silent drop.
        ///
        /// WARNING — `destinationHash` is semantically overloaded across callers:
        /// • For a `.send`/link packet it is the unreachable peer's destination hash.
        /// • For an announce it is OUR OWN destination hash (Transport.swift:773).
        /// • For a path request it is the fixed `pathRequestDestinationHash` for every
        ///   request (Transport.swift:790) — not the destination being sought.
        /// • For relayed traffic it is a third party's destination hash.
        /// A consumer MUST NOT read it as "delivery to this destination failed" without
        /// knowing the packet type that produced the failure.
        case interfaceUnavailable
    }

    public enum Action: Equatable {
        case interfaceConnected(InterfaceID, InterfaceProfile)
        case interfaceDisconnected(InterfaceID)
        case registerLocalDestination(Destination)
        case setTransportIdentity(Identity?)
        case setRecursivePathRequests(Bool)
        case received(InterfaceID, Data)
        case announce(destinationHash: Data, appData: Data?)
        case requestPath(destinationHash: Data)
        case send(destinationHash: Data, plaintext: Data)
        case announceRetransmitDue(destinationHash: Data)
        case announceQueueDrainDue(InterfaceID)
        case heldAnnounceReleaseDue(InterfaceID)
        case startMaintenance
        case stopMaintenance
        case maintenanceTick
        /// Restore `learned` from a previous session so that after a cold start the node can
        /// route to known destinations without waiting for announces to re-arrive.
        ///
        /// **Sweeps expired entries in the same pass.** `maintenanceTick` uses a mode-dependent
        /// expiry (1 day for AP, 6 hours for roaming, 7 days otherwise — `Transport.pathExpiry`).
        /// At rehydration time interfaces are not yet connected, so the mode is unknown; we apply
        /// the conservative 7-day default. The next `maintenanceTick` refines the expiry once an
        /// interface connects. Reference (`Transport.py:307-357`, stock 1.4.2) does NOT sweep on
        /// load — culling happens in the periodic jobs loop — but this action follows the
        /// `.rehydrateLearnedPeers` precedent and sweeps in the same pass to keep the table
        /// bounded before anything routes through it.
        ///
        /// **A restored entry NEVER replaces a fresher live one.** The app pattern merges
        /// `.endpoint(.start)` with an async database read, so an announce can populate `learned`
        /// before this action lands. An unconditional write would move `learnedAt` backward and
        /// restore superseded routing data. Check `learnedAt` and skip if the live entry is at
        /// least as fresh.
        ///
        /// **A row whose `learnedAt` is non-finite or in the future is dropped, not restored.**
        /// `Date + TimeInterval` is Double arithmetic and saturates rather than trapping, so there
        /// is no crash to catch — the test is the only guard. A future date would look unexpired
        /// forever; a NaN fails open (`now <= nan` is true). Drop both.
        case rehydrateLearnedDestinations([Data: LearnedDestination])
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: SendFailure)
            case linkPacket(linkID: Data, arrivalInterface: InterfaceID, data: Data)
            case linkRequest(destinationHash: Data, arrivalInterface: InterfaceID, data: Data)
        }
    }

    @Dependency(\.transportDate) var date
    @Dependency(\.continuousClock) var clock
    @Dependency(\.randomBytes) var randomBytes

    private enum CancelID: Hashable {
        case announceRetransmit(Data); case maintenance; case announceDrain(InterfaceID)
        case ingressRelease(InterfaceID)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { [clock, date, randomBytes] state, action in
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
            case let .interfaceConnected(id, profile):
                state.interfaces[id] = profile
                state.interfaceConnectedAt[id] = date.now
                return .none

            case let .interfaceDisconnected(id):
                state.interfaces[id] = nil
                state.announceAllowedAt[id] = nil
                state.announceQueues[id] = nil
                state.announceArrivals[id] = nil
                state.ingressBursts[id] = nil
                state.heldAnnounces[id] = nil
                state.interfaceConnectedAt[id] = nil
                return .merge(.cancel(id: CancelID.announceDrain(id)),
                              .cancel(id: CancelID.ingressRelease(id)))

            case let .registerLocalDestination(destination):
                // Registering a destination clears any app data stickily remembered for it. This is
                // ReTiCA's `Destination.clear_default_app_data()` (RNS/Destination.py:688-692), and
                // it is the ONLY clear path: `.announce` never erases (see there), so without this
                // a composition that stopped advertising app data could keep replaying the previous
                // one's forever, in both announces and path responses.
                //
                // Unconditional on purpose. The former `if localDestinations[hash] == nil` guard
                // could never fire — nothing ever removes a `localDestinations` entry, so on a
                // first registration `localAppData[hash]` is already nil, and on a re-registration
                // the guard is false. Every in-repo caller registers and announces in one `.merge`
                // (PNNode.swift `.registerPropagation`, LXMFServiceNode.swift `.registerPropagation`,
                // LXMFNode.swift `.registerDelivery`), and `.merge` delivers in order, so the clear
                // always precedes the announce that repopulates it. (Named by enclosing case rather
                // than by line: the previous revision's `LXMFNode.swift:91` had already rotted to
                // :201 within one slice.)
                state.localAppData[destination.hash] = nil
                state.localDestinations[destination.hash] = destination
                return .none

            case let .setTransportIdentity(identity):
                state.transportIdentity = identity
                guard identity == nil else { return .none }
                // Stopped relaying: cancel pending re-broadcasts and drop relay-only routing state.
                let cancels = state.announceTable.keys
                    .map { Effect<Action>.cancel(id: CancelID.announceRetransmit($0)) }
                state.announceTable = [:]
                state.linkTable = [:]
                state.discoveryPathRequests = [:]   // in-flight recursive searches are relay-only state
                return cancels.isEmpty ? .none : .merge(cancels)

            case let .setRecursivePathRequests(enabled):
                state.recursivePathRequests = enabled
                return .none

            case let .rehydrateLearnedDestinations(destinations):
                // Restore and sweep in one pass. See the action's declaration for the full
                // rationale. Short form: drop expired, drop future-dated, never overwrite fresher.
                let now = date.now
                for (hash, candidate) in destinations {
                    // Drop non-finite or future-dated timestamps — they would be unexpired forever
                    // (future) or fail open (NaN: `now <= nan` evaluates to true). See the action
                    // declaration for why clamping to now does not work.
                    guard candidate.learnedAt.timeIntervalSinceReferenceDate.isFinite,
                          candidate.learnedAt <= now,
                          now <= candidate.learnedAt + Transport.pathExpiry
                    else { continue }
                    // Never overwrite a fresher live entry.
                    if let live = state.learned[hash], live.learnedAt >= candidate.learnedAt { continue }
                    state.learned[hash] = candidate
                }
                return .none

            case let .received(interfaceID, data):
                // C5 IFAC (RNS Transport.py:1442-1486). MUST happen here, not in an Endpoint: C4
                // holds burst-limited announces by storing the VERBATIM `.received` payload and
                // replaying it through `.send(.received(id, raw))`. Unmasking upstream in an
                // Endpoint would store de-masked bytes that fail the flag check on replay and
                // vanish silently. (Reference RNS has that exact bug in process_held_announces.)
                // Storing masked bytes and unmasking again on replay is self-consistent.
                //
                // Asymmetry with outbound: IFAC masking on the transmit side lives in the
                // Endpoints (TCPEndpoint/BLEEndpoint), where `state.profile` is already in scope.
                // Masking there touches fewer sites than masking at each of Transport's emission
                // points, and outbound has no C4 replay constraint.
                let plain: Data
                if let ifac = state.interfaces[interfaceID]?.ifac {
                    guard let unmasked = ifac.unprotect(data) else { return .none }
                    plain = unmasked
                } else {
                    // Plain interface: reject any IFAC-flagged packet (RNS Transport.py:1482-1486).
                    guard data.first.map({ $0 & 0x80 == 0 }) ?? false else { return .none }
                    plain = data
                    // NOTE — "no registration ⇒ treat as an open network" is intentional.
                    // A miss in `state.interfaces` means the interface has not yet registered
                    // (or was never configured with IFAC), and we fall through to the plain-
                    // interface guard above. This does NOT create a window where an IFAC packet
                    // could slip through: TCA drains buffered actions FIFO, and `.interfaceConnected`
                    // is always emitted exactly one hop before the first `.received` on the same
                    // interface, so registration always precedes any delivery. That ordering is
                    // pinned by `ifacPacketArrivesAfterInterfaceConnectedIsIFACProcessed`.
                    // Making this fail-closed would require guarding every `.received` site (~133)
                    // with an explicit "interface must be registered" check — a larger change
                    // deferred until an actual miss is observed in practice.
                }
                guard let packet = Packet(raw: plain) else { return .none }
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
                        state.linkTable[packet.destinationHash]?.refreshedAt = date.now   // keep active links alive
                        var fwd = packet
                        fwd.hops = packet.hops + 1
                        guard let raw = try? fwd.packed() else { return .none }
                        return .send(.delegate(.transmit(outIf, raw)))
                    }
                    return .send(.delegate(.linkPacket(linkID: packet.destinationHash, arrivalInterface: interfaceID, data: plain)))
                }
                if packet.packetType == .linkRequest, state.localDestinations[packet.destinationHash] != nil {
                    return .send(.delegate(.linkRequest(destinationHash: packet.destinationHash,
                                                        arrivalInterface: interfaceID, data: plain)))
                }
                // Announces are deduped by per-destination random-blob (in the `.announce` case
                // below), NOT by packetHash: keying on the unforgeable-per-announce random_hash
                // prevents replays that mutate non-blob bytes (appData/signature/hops/transport_id)
                // from bypassing dedup, and matches RNS (Transport.py:1807/1824). Non-announce
                // packets keep packetHash dedup for loop protection.
                if packet.packetType != .announce {
                    guard state.seenPacketHashes.insert(packet.packetHash) else { return .none }
                }

                switch packet.packetType {
                case .announce:
                    // Don't learn a path to one of our own destinations.
                    guard state.localDestinations[packet.destinationHash] == nil else { return .none }
                    guard let parsed = Announce.parse(payload: packet.payload,
                                                      destinationHash: packet.destinationHash,
                                                      contextFlagSet: packet.contextFlag)
                    else { return .none }
                    // C4 ingress control (RNS Transport.py:1748-1766). Record the arrival first — the deque
                    // counts every signature-valid announce, including this one, before the decision.
                    let icNow = date.now
                    var arrivals = state.announceArrivals[interfaceID] ?? []
                    arrivals.append(icNow)
                    // Decay: drop samples older than the window, then cap the deque length.
                    arrivals.removeAll { icNow.timeIntervalSince($0) > Transport.arFreqDecay }
                    if arrivals.count > Transport.iaFreqSamples {
                        arrivals.removeFirst(arrivals.count - Transport.iaFreqSamples)
                    }
                    state.announceArrivals[interfaceID] = arrivals

                    // Limiting applies ONLY to destinations we have no path to, and never to one we have an
                    // outstanding path request for. Holding must happen BEFORE the blob ring records this
                    // announce, or the later release would look like a replay and be dropped.
                    //
                    // KNOWN DEFERRAL (I2): RNS Interface.received_announce() (Interface.py:257-260)
                    // propagates each arrival to parent_interface, so a listening interface sees the
                    // AGGREGATE rate across all spawned children. ReTiCA's BLEEndpoint mints a distinct
                    // InterfaceID per BLE peer (BLEEndpoint.swift:125-127), giving N independent
                    // ingress-control domains with no parent. N peers can each sustain just under 3 Hz
                    // without any burst activating, where reference would see 3N Hz and burst. Parent
                    // aggregation requires InterfaceProfile C1 rework and is its own slice.
                    let destinationKnown = state.learned[packet.destinationHash] != nil
                    let awaitingPath = state.discoveryPathRequests[packet.destinationHash] != nil
                                   || state.pathRequests[packet.destinationHash] != nil
                    if !destinationKnown, !awaitingPath {
                        let age = icNow.timeIntervalSince(state.interfaceConnectedAt[interfaceID] ?? icNow)
                        let decision = Transport.shouldIngressLimit(
                            samples: arrivals, now: icNow, interfaceAge: age,
                            burst: state.ingressBursts[interfaceID] ?? Transport.IngressBurst())
                        state.ingressBursts[interfaceID] = decision.burst
                        if decision.limit {
                            // hold_announce (Interface.py:223-229): too-far announces are dropped, an existing
                            // entry for this destination is replaced, otherwise held while under the cap.
                            if Int(packet.hops) < Transport.ingressHoldHopLimit {
                                var held = state.heldAnnounces[interfaceID] ?? [:]
                                if held[packet.destinationHash] != nil || held.count < Transport.maxHeldAnnounces {
                                    held[packet.destinationHash] = State.HeldAnnounce(raw: data, hops: packet.hops)
                                    state.heldAnnounces[interfaceID] = held
                                }
                                let releaseIn = max(Transport.icHeldReleaseInterval,
                                                   (state.ingressBursts[interfaceID]?.heldRelease ?? icNow)
                                                       .timeIntervalSince(icNow))
                                return .run { send in
                                    try await clock.sleep(for: .seconds(releaseIn))
                                    await send(.heldAnnounceReleaseDue(interfaceID))
                                }.cancellable(id: CancelID.ingressRelease(interfaceID), cancelInFlight: true)
                            }
                            return .none
                        }
                    }
                    // Anti-replay: a previously-seen random-blob for this destination is a replay.
                    // RingSet.insert both tests and records; false → already present → drop.
                    // NOTE: we record the blob for EVERY fresh announce here. RNS only appends the
                    // blob inside its `should_add` path-adopt branch (Transport.py:1934-1936); we
                    // remember more eagerly on purpose — a strict superset of RNS's anti-replay
                    // memory (never drops a fresh announce RNS keeps, never keeps a replay RNS drops).
                    // Do NOT narrow this to RNS's should_add gating: that would weaken anti-replay.
                    var ring = state.announceBlobs[packet.destinationHash]
                        ?? RingSet(capacity: Transport.announceBlobRingSize)
                    guard ring.insert(parsed.randomHash) else {
                        // REPLAY. A peer/downstream re-broadcast of an announce we are holding is a
                        // same-blob replay. Collaborative suppression: cancel our pending RETRY once
                        // neighbours have propagated it (RNS Transport.py:1774-1791).
                        guard var entry = state.announceTable[packet.destinationHash],
                              packet.transportId != nil    // HEADER_2 re-broadcast (RNS transport_id != None)
                        else { return .none }
                        if packet.hops == entry.rebroadcastHops {           // a peer re-broadcast
                            entry.localRebroadcasts += 1                     // count always (RNS increments unconditionally)
                            if entry.rebroadcasts >= 1,                      // a retry is pending (RNS IDX_AT_RETRIES > 0)
                               entry.localRebroadcasts >= Transport.announceMaxRebroadcasts {
                                state.announceTable[packet.destinationHash] = nil
                                return .cancel(id: CancelID.announceRetransmit(packet.destinationHash))
                            }
                            state.announceTable[packet.destinationHash] = entry
                            return .none
                        }
                        if packet.hops == entry.rebroadcastHops + 1, entry.rebroadcasts >= 1 {  // passed on downstream
                            state.announceTable[packet.destinationHash] = nil
                            return .cancel(id: CancelID.announceRetransmit(packet.destinationHash))
                        }
                        return .none
                    }
                    state.announceBlobs[packet.destinationHash] = ring

                    let emitted = Transport.announceEmitted(parsed.randomHash)
                    // Path-table next hop: relayed (HEADER_2) → its transport_id; directly heard → the dest.
                    let nextHop = packet.transportId ?? packet.destinationHash
                    let candidate = LearnedDestination(
                        identity: parsed.identity, appData: parsed.appData, ratchet: parsed.ratchet,
                        interfaceID: interfaceID, hops: packet.hops, nextHop: nextHop,
                        announceEmitted: emitted, learnedAt: date.now)
                    var effects: [Effect<Action>] = []
                    // Update the path only if this fresh announce improves it (unchanged logic).
                    if Transport.shouldReplace(state.learned[packet.destinationHash], with: candidate) {
                        state.learned[packet.destinationHash] = candidate
                        state.announceCache[packet.destinationHash] = State.CachedAnnounce(
                            payload: packet.payload, contextFlag: packet.contextFlag)
                        effects.append(.send(.delegate(.pathLearned(
                            destinationHash: packet.destinationHash, hops: packet.hops))))
                    }
                    // Relay mode: instead of re-broadcasting now, HOLD this fresh announce and
                    // re-broadcast it once after a jittered delay in [0, PATHFINDER_RW) — RNS
                    // Transport.py:1925. Only schedule when there is somewhere to send it.
                    // RNS Transport.py:1945 gates announce-table insertion on
                    // `packet.context != PATH_RESPONSE`. A path response is a targeted answer to
                    // one requester, not a network-wide advertisement. Re-broadcasting it makes one
                    // path request flood proportionally to the number of relays — and a LOCALLY
                    // MINTED response (branch 1 below) mints a fresh random_hash, so it is an unseen
                    // blob at every relay and the flood is not damped by blob dedup. (A RELAYED
                    // response, branch 2, replays `cachedPayload` verbatim and so carries the
                    // ORIGINAL announce's random_hash; that one does die at the receiver's blob ring
                    // as a replay. The gate is what makes both cases safe.) Adoption above still
                    // happens; only the re-broadcast is suppressed.
                    let arrivalMode = state.interfaces[interfaceID]?.mode
                    if packet.context != .pathResponse,
                       let relayID = state.transportIdentity,
                       Int(packet.hops) + 1 < Int(Packet.maxHops),
                       state.interfaces.contains(where: { $0.key != interfaceID
                           && Transport.mayRelayAnnounce(to: $0.value.mode, arrivalMode: arrivalMode) }) {
                        let rebroadcast = Packet(
                            headerType: .header2, packetType: .announce, transportType: .transport,
                            destinationType: packet.destinationType, context: packet.context,
                            contextFlag: packet.contextFlag, hops: packet.hops + 1,
                            destinationHash: packet.destinationHash, transportId: relayID.hash,
                            payload: packet.payload)
                        if let rebroadcastRaw = try? rebroadcast.packed() {
                            let destHash = packet.destinationHash
                            state.announceTable[destHash] = State.PendingAnnounce(
                                raw: rebroadcastRaw, arrivalInterface: interfaceID,
                                rebroadcastHops: packet.hops + 1)
                            let jitter = Transport.announceJitter(randomBytes(1).first ?? 0)
                            effects.append(.run { send in
                                try await clock.sleep(for: .seconds(jitter))
                                await send(.announceRetransmitDue(destinationHash: destHash))
                            }.cancellable(id: CancelID.announceRetransmit(destHash), cancelInFlight: true))
                        }
                    }
                    return effects.isEmpty ? .none : .merge(effects)
                case .data:
                    // A PATH_REQUEST (RNS Transport.py:2894/2939): a PLAIN DATA packet to the
                    // well-known control destination. If we OWN the requested destination, answer with
                    // a path-response announce on the arrival interface.
                    if packet.destinationHash == Transport.pathRequestDestinationHash {
                        guard packet.payload.count >= 16 else { return .none }
                        let requested = Data(packet.payload.prefix(16))
                        // Entry gate (RNS path_request_handler:2905-2934). Parse the request tag;
                        // ignore tagless requests and duplicate (destHash ‖ tag) requests.
                        let tag: Data
                        if packet.payload.count > 32 {
                            tag = Data(packet.payload.dropFirst(32).prefix(16))   // after destHash + transport_id
                        } else if packet.payload.count > 16 {
                            tag = Data(packet.payload.dropFirst(16).prefix(16))   // after destHash
                        } else {
                            return .none                                          // tagless (== 16) → ignore
                        }
                        guard state.discoveryPrTags.insert(requested + tag) else { return .none }
                        // (1) We OWN the requested destination → answer with a fresh path-response.
                        if let dest = state.localDestinations[requested],
                           let identity = dest.identity, identity.privateKey != nil {
                            let now = UInt64(date.now.timeIntervalSince1970)
                            let randomHash = Announce.randomHash(now: now, randomPrefix: SecureRandom.bytes(5))
                            // Replay the app data this destination last announced. A path response
                            // is stamped NOW, so it always wins `shouldReplace` on the requester —
                            // sending nil here would erase whatever richer entry the requester had
                            // learned from a normal announce (display name, PN metadata, ...).
                            //
                            // `ratchet` stays nil: ReTiCA has no own-ratchet lifecycle at all (it
                            // only honours a PEER's announced ratchet when encrypting), so there is
                            // nothing truthful to put here. Revisit when ratchets land.
                            let respPayload = Announce.buildPayload(identity: identity, destinationHash: dest.hash,
                                                                    nameHash: dest.nameHash, randomHash: randomHash,
                                                                    ratchet: nil,
                                                                    appData: state.localAppData[dest.hash])
                            let response = Packet.announce(from: dest, payload: respPayload, pathResponse: true)
                            guard let raw = try? response.packed() else { return .none }
                            return .send(.delegate(.transmit(interfaceID, raw)))
                        }
                        // (2) We are a relay that has learned + cached a path to the destination →
                        // re-emit the cached announce (verbatim payload, original signature) as a
                        // HEADER_2 pathResponse so the requester learns the destination via us.
                        // RNS Transport.py:2972-3033 (get_cached_packet + rebroadcast as path response).
                        if let relayID = state.transportIdentity,
                           let cached = state.announceCache[requested],
                           let entry = state.learned[requested],
                           Int(entry.hops) + 1 < Int(Packet.maxHops) {
                            // Loop guard: a relay requester carries its transport_id (48-byte payload).
                            // If that equals our next hop toward the destination, the requester is
                            // already on our path — do not answer (RNS Transport.py:2987).
                            let requestorTransportId: Data? = packet.payload.count > 32
                                ? Data(packet.payload.dropFirst(16).prefix(16)) : nil
                            guard requestorTransportId != entry.nextHop else { return .none }
                            // The flag comes from the CACHE, not from `entry.ratchet`. The payload is
                            // the original announce's bytes, so the flag must describe those bytes:
                            // `Announce.parse` drops a ratchet it cannot key-agree with, leaving the
                            // 32 bytes in the payload but `entry.ratchet == nil`. See CachedAnnounce.
                            let response = Packet(
                                headerType: .header2, packetType: .announce, transportType: .transport,
                                destinationType: .single, context: .pathResponse,
                                contextFlag: cached.contextFlag, hops: entry.hops + 1,
                                destinationHash: requested, transportId: relayID.hash, payload: cached.payload)
                            guard let raw = try? response.packed() else { return .none }
                            return .send(.delegate(.transmit(interfaceID, raw)))
                        }
                        // (3) Path unknown: if recursion is enabled (relay + opt-in) and we are not
                        // already searching for this destination, re-broadcast onward for recursive
                        // discovery (RNS path_request:3044-3070). Reusing the tag makes a looped-back
                        // copy die at the #4c-3a discoveryPrTags ring.
                        if let relayID = state.transportIdentity, state.recursivePathRequests,
                           state.learned[requested] == nil,
                           state.discoveryPathRequests[requested] == nil {
                            state.discoveryPathRequests[requested] = date.now
                            let fwd = Packet(
                                headerType: .header1, packetType: .data, transportType: .broadcast,
                                destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                                destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                                payload: requested + relayID.hash + tag)
                            guard let raw = try? fwd.packed() else { return .none }
                            let sends = state.interfaces.keys.filter { $0 != interfaceID }
                                .map { Effect<Action>.send(.delegate(.transmit($0, raw))) }
                            return sends.isEmpty ? .none : .merge(sends)
                        }
                        return .none
                    }
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
                        state.linkTable[linkID] = State.LinkTableEntry(
                            rcvdIf: interfaceID, nhIf: entry.interfaceID, refreshedAt: date.now)
                        guard let raw = forwardTowardDest(packet, entry) else { return .none }
                        return .send(.delegate(.transmit(entry.interfaceID, raw)))
                    }
                    return .none
                default:
                    return .none
                }

            case .startMaintenance:
                return .run { send in
                    while true {
                        try await clock.sleep(for: .seconds(Transport.maintenanceTickInterval))
                        await send(.maintenanceTick)
                    }
                }.cancellable(id: CancelID.maintenance, cancelInFlight: true)

            case .stopMaintenance:
                return .cancel(id: CancelID.maintenance)

            case .maintenanceTick:
                let now = date.now
                for (dest, entry) in state.learned
                where now.timeIntervalSince(entry.learnedAt)
                    > Self.pathExpiry(forMode: state.interfaces[entry.interfaceID]?.mode) {
                    state.learned[dest] = nil
                    state.announceBlobs[dest] = nil          // blob GC piggybacks on path expiry
                    state.announceCache[dest] = nil          // cached announce GC piggybacks too
                }
                for (link, entry) in state.linkTable
                where now.timeIntervalSince(entry.refreshedAt) > Transport.linkTableExpiry {
                    state.linkTable[link] = nil
                }
                for (dest, startedAt) in state.discoveryPathRequests
                where now.timeIntervalSince(startedAt) > Transport.pathRequestTimeout {
                    state.discoveryPathRequests[dest] = nil
                }
                for (dest, issuedAt) in state.pathRequests
                where now.timeIntervalSince(issuedAt) > Transport.pathRequestGateTimeout {
                    state.pathRequests[dest] = nil
                }
                for (id, queue) in state.announceQueues {
                    let live = queue.filter { now.timeIntervalSince($0.queuedAt) <= Transport.queuedAnnounceLife }
                    state.announceQueues[id] = live.isEmpty ? nil : live
                }
                return .none

            case let .announceRetransmitDue(destinationHash):
                guard var entry = state.announceTable[destinationHash] else { return .none }
                let arrivalMode = state.interfaces[entry.arrivalInterface]?.mode
                let now = date.now
                let eligible = state.interfaces
                    .filter { $0.key != entry.arrivalInterface
                        && Transport.mayRelayAnnounce(to: $0.value.mode, arrivalMode: arrivalMode) }
                // NOTE: reference Transport.py reaches the pacing block only in the final `else`
                // of the interface-mode ladder, so roaming and boundary interfaces are never paced
                // there. We pace every relay-eligible interface, which is more conservative and
                // appropriate since roaming links are often exactly the slow ones.
                var sends: [Effect<Action>] = []
                // Emission timestamp for per-destination upsert comparison (Finding 2).
                // state.learned is always populated before we schedule a retransmit (the
                // path-learning step that creates the announceTable entry also updates learned),
                // so this lookup reliably returns the announce's true emitted value.
                let emitted = state.learned[destinationHash]?.announceEmitted ?? 0
                for (id, profile) in eligible {
                    // Pacing intentionally measures `entry.raw.count` (the unmasked relay bytes),
                    // not the on-wire length after IFAC adds `ifac_size` bytes. Reference RNS does
                    // the same (Transport.py:1281 uses the pre-mask length), so this is parity,
                    // not a bug. Under-counting by `ifac_size` is accepted behaviour on both sides.
                    let wait = Transport.announcePacingWait(byteCount: entry.raw.count,
                                                            bitrate: profile.bitrate,
                                                            announceCap: profile.announceCap)
                    // Finding 1 (RNS Transport.py:1281-1282): only take the send-now branch when
                    // the queue is empty. While a backlog exists the drain is the sole emitter,
                    // keeping it self-serializing and preventing a send-now from jumping the queue.
                    let queueEmpty = state.announceQueues[id]?.isEmpty ?? true
                    if queueEmpty, (state.announceAllowedAt[id] ?? .distantPast) <= now {
                        sends.append(.send(.delegate(.transmit(id, entry.raw))))
                        state.announceAllowedAt[id] = now.addingTimeInterval(wait)
                    } else {
                        // Finding 2 (RNS Transport.py:1292-1306): at most one queued entry per
                        // destination per interface. If an entry for this destination already
                        // exists, upsert (replace raw/hops/queuedAt/emitted if our emitted is
                        // strictly newer) rather than appending a second entry.
                        //
                        // NOTE: reference Transport.py:1300-1305 uses `e` as the loop variable
                        // which after the loop refers to the LAST element, not the matched entry —
                        // a Python aliasing bug that corrupts the wrong queue slot when the match
                        // is not last. We deliberately diverge and replace the entry that matched.
                        if let existingIdx = state.announceQueues[id, default: []]
                            .firstIndex(where: { $0.destination == destinationHash }) {
                            // Entry for this destination exists: replace if our emitted is newer.
                            if emitted > state.announceQueues[id]![existingIdx].emitted {
                                state.announceQueues[id]![existingIdx] = State.QueuedAnnounce(
                                    raw: entry.raw, hops: entry.rebroadcastHops, queuedAt: now,
                                    destination: destinationHash, emitted: emitted)
                            }
                            // Drain timer already scheduled; the cancelInFlight below keeps it live.
                        } else if state.announceQueues[id, default: []].count < Transport.announceQueueLimit {
                            state.announceQueues[id, default: []].append(
                                State.QueuedAnnounce(raw: entry.raw, hops: entry.rebroadcastHops,
                                                     queuedAt: now, destination: destinationHash,
                                                     emitted: emitted))
                        }
                        // When the window is open but the queue is non-empty (Finding 1 guard
                        // redirected us here), opensIn is 0 — the drain should fire immediately.
                        let opensIn = max(0, (state.announceAllowedAt[id] ?? now).timeIntervalSince(now))
                        sends.append(.run { send in
                            try await clock.sleep(for: .seconds(opensIn))
                            await send(.announceQueueDrainDue(id))
                        }.cancellable(id: CancelID.announceDrain(id), cancelInFlight: true))
                    }
                }
                entry.rebroadcasts += 1
                if entry.rebroadcasts >= Transport.announceMaxRebroadcasts {
                    state.announceTable[destinationHash] = nil          // lifecycle complete
                    return sends.isEmpty ? .none : .merge(sends)
                }
                state.announceTable[destinationHash] = entry            // keep for the next retry
                // Retry delay is a FIXED PATHFINDER_G + PATHFINDER_RW (RNS Transport.py:603 adds the
                // constants, not a rand()*window draw). Only the initial send is jittered.
                let delay = Transport.announceRetryGrace + Transport.announceRebroadcastWindow
                let retry = Effect<Action>.run { send in
                    try await clock.sleep(for: .seconds(delay))
                    await send(.announceRetransmitDue(destinationHash: destinationHash))
                }.cancellable(id: CancelID.announceRetransmit(destinationHash), cancelInFlight: true)
                return .merge(sends + [retry])

            case let .announceQueueDrainDue(id):
                guard let profile = state.interfaces[id] else {
                    state.announceQueues[id] = nil        // interface vanished; drop its backlog
                    return .none
                }
                guard var queue = state.announceQueues[id], !queue.isEmpty else { return .none }
                // Fewest hops first, older first among equals (RNS orders by hops, then timestamp).
                let pick = queue.indices.min { a, b in
                    queue[a].hops != queue[b].hops ? queue[a].hops < queue[b].hops
                                                   : queue[a].queuedAt < queue[b].queuedAt
                }!
                let item = queue.remove(at: pick)
                state.announceQueues[id] = queue.isEmpty ? nil : queue
                let now = date.now
                // Same parity note as the send-now path above: pacing uses the unmasked byte
                // count (IFAC adds `ifac_size` on the wire). Reference RNS does the same.
                let wait = Transport.announcePacingWait(byteCount: item.raw.count,
                                                        bitrate: profile.bitrate,
                                                        announceCap: profile.announceCap)
                state.announceAllowedAt[id] = now.addingTimeInterval(wait)
                var effects: [Effect<Action>] = [.send(.delegate(.transmit(id, item.raw)))]
                if !queue.isEmpty {
                    effects.append(.run { send in
                        try await clock.sleep(for: .seconds(wait))
                        await send(.announceQueueDrainDue(id))
                    }.cancellable(id: CancelID.announceDrain(id), cancelInFlight: true))
                }
                return .merge(effects)

            case let .heldAnnounceReleaseDue(id):
                guard let held = state.heldAnnounces[id], !held.isEmpty else { return .none }
                let now = date.now
                let burst = state.ingressBursts[id] ?? Transport.IngressBurst()
                // Not yet past the penalty, or the rate is still hot: try again later.
                let age = now.timeIntervalSince(state.interfaceConnectedAt[id] ?? now)
                let threshold = Transport.ingressBurstThreshold(interfaceAge: age)
                let freq = Transport.announceFrequency(samples: state.announceArrivals[id] ?? [], now: now)
                guard now > burst.heldRelease, freq < threshold else {
                    return .run { send in
                        try await clock.sleep(for: .seconds(Transport.icHeldReleaseInterval))
                        await send(.heldAnnounceReleaseDue(id))
                    }.cancellable(id: CancelID.ingressRelease(id), cancelInFlight: true)
                }
                // Release the fewest-hop announce, then space the next release.
                guard let pick = held.min(by: { $0.value.hops < $1.value.hops }) else { return .none }
                var remaining = held
                remaining[pick.key] = nil
                state.heldAnnounces[id] = remaining.isEmpty ? nil : remaining
                var next = burst
                next.heldRelease = now.addingTimeInterval(Transport.icHeldReleaseInterval)
                state.ingressBursts[id] = next
                // Full re-entry (RNS process_held_announces → Transport.inbound): the released
                // announce takes the IDENTICAL path a freshly-arrived one takes — admission,
                // path adoption, AND relay re-broadcast with its mode gating and pacing. Do not
                // inline an admission copy here; it would silently drop the relay half.
                // Replaying the ORIGINAL bytes is safe because the hold gate sits BEFORE the
                // blob-ring insert, so this is not seen as a replay.
                // NOTE: while the burst is still active the gate holds it again — that bounce is
                // reference behaviour (should_ingress_limit returns limit even on the call that
                // deactivates). Releases are spaced icHeldReleaseInterval apart (~0.2 Hz), so the
                // rate stays far under threshold and the burst converges to inactive.
                var effects: [Effect<Action>] = [.send(.received(id, pick.value.raw))]
                if !remaining.isEmpty {
                    effects.append(.run { send in
                        try await clock.sleep(for: .seconds(Transport.icHeldReleaseInterval))
                        await send(.heldAnnounceReleaseDue(id))
                    }.cancellable(id: CancelID.ingressRelease(id), cancelInFlight: true))
                }
                return .merge(effects)

            case let .send(destinationHash, plaintext):
                guard let entry = state.learned[destinationHash] else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .notLearned)))
                }
                guard state.reachableLearned(destinationHash) != nil else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .interfaceUnavailable)))
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
                // Sticky app data: record a non-nil app data, and fall back to it when a later
                // announce omits one. Reference does that substitution for EVERY announce, ordinary
                // and path-response alike, because both are the same function
                // (RNS/Destination.py:289-296, inside announce() at :283-304). Without the fallback
                // here, `announce(X)` then `announce(nil)` would put nil-app-data on the wire while
                // path responses for the same destination still carried X — and since the later
                // packet wins recency-first `shouldReplace`, that nil announce would erase the
                // requester's `learned[dest].appData` through a different packet type.
                //
                // DIVERGENCE: reference's `default_app_data` is set EXPLICITLY, via
                // `set_default_app_data()`; `announce(app_data=X)` does not write it. ReTiCA has no
                // such setter, so it auto-captures the last non-nil announce instead. Clearing is
                // likewise folded into `.registerLocalDestination` rather than exposed as a
                // standalone `clear_default_app_data()` (RNS/Destination.py:688-692).
                //
                // The capture happens AFTER `packed()` succeeds, and that ordering is load-bearing.
                // Because the captured value is sticky AND is the fallback for every later announce
                // and path response, capturing an app data that cannot be packed poisoned the
                // destination permanently: the oversize announce emitted nothing, the next
                // `announce(nil)` fell back to the same oversize value and emitted nothing, and the
                // local path-response branch (the `.header2` path response built in the
                // path-request handler) read the same poisoned entry through the same `try?` and
                // answered nothing. One over-long display name took the delivery
                // destination off the network for good — recoverable only by announcing a value
                // that fits. Verified by probe before the fix (announce and path response both
                // silent; recovery only via a short name).
                //
                // This is the general fix: it covers ANY oversize app data from ANY caller, not
                // just a long LXMF display name (which `LXMFAnnounceData.pack` also bounds at
                // source). Reference cannot hit this at all — `Packet.pack` RAISES IOError on MTU
                // overflow (RNS 1.4.2 Packet.py:234-236) rather than failing silently, and its
                // `default_app_data` is only ever written by an explicit `set_default_app_data()`,
                // so there is no auto-capture to poison.
                let announcedAppData = appData ?? state.localAppData[destinationHash]
                let now = UInt64(date.now.timeIntervalSince1970)
                let randomHash = Announce.randomHash(now: now, randomPrefix: SecureRandom.bytes(5))
                let payload = Announce.buildPayload(identity: identity, destinationHash: destinationHash,
                                                    nameHash: dest.nameHash, randomHash: randomHash,
                                                    ratchet: nil, appData: announcedAppData)
                let packet = Packet.announce(from: dest, payload: payload)
                guard let raw = try? packet.packed() else { return .none }
                if let appData { state.localAppData[destinationHash] = appData }
                return .merge(state.interfaces.keys.map { .send(.delegate(.transmit($0, raw))) })

            case let .requestPath(destinationHash):
                // RNS request_path (Transport.py:2799): a DATA/BROADCAST/HEADER_1 packet to the
                // well-known PLAIN control destination; payload = destHash [+ our transport_id] + tag.
                // Record this request so that an arriving path-response announce for this destination
                // is exempt from ingress-control holding (RNS Transport.path_requests, Transport.py:2899).
                // This is the LOCAL gate entry (leaf+relay); discoveryPathRequests is relay-only.
                state.pathRequests[destinationHash] = date.now
                var payload = destinationHash
                if let relayID = state.transportIdentity { payload.append(relayID.hash) }
                payload.append(randomBytes(16))                        // request tag (RNS get_random_hash)
                let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                    destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                                    payload: payload)
                guard let raw = try? packet.packed() else { return .none }
                let sends = state.interfaces.keys.map { Effect<Action>.send(.delegate(.transmit($0, raw))) }
                return sends.isEmpty ? .none : .merge(sends)

            case .delegate:
                return .none
            }
        }
    }

    /// RNS `DESTINATION_TIMEOUT` (stock 1.4.2 `Transport.py:92`): learned paths expire after one
    /// week unused, in seconds.
    ///
    /// **`public` so a persisting host can prune its stored copy on the same terms.** An app that
    /// persists `learned` must expire its rows to match, or the table outgrows the state it
    /// mirrors. The only alternative to exporting this is a duplicated constant in the app behind
    /// a "keep in sync" comment — which is exactly the mirrored-copy drift that produced a real
    /// stamp-cost bug in this project, and which `LXMFServiceNode` carries a standing warning
    /// about. One source of truth is cheaper than the comment.
    ///
    /// Note this is the **default**; `pathExpiry(forMode:)` below is shorter for AP (1 day) and
    /// roaming (6 hours) interfaces. A host pruning at launch cannot use the mode-dependent form —
    /// interfaces are not connected yet — so this conservative value is the correct one there.
    public static let pathExpiry: TimeInterval = 60 * 60 * 24 * 7      // 604800
    /// Mode-dependent path lifetimes (RNS Transport.py:787-792).
    static let apPathExpiry: TimeInterval = 60 * 60 * 24       // AP_PATH_TIME, 1 day
    static let roamingPathExpiry: TimeInterval = 60 * 60 * 6   // ROAMING_PATH_TIME, 6 hours

    /// Path lifetime for a path learned on an interface of the given mode. nil mode = the
    /// interface has disconnected since; fall back to the 7-day default rather than expiring
    /// early (a cycling BLE peer must not silently drop paths).
    static func pathExpiry(forMode mode: InterfaceMode?) -> TimeInterval {
        switch mode {
        case .accessPoint: return apPathExpiry
        case .roaming:     return roamingPathExpiry
        default:           return pathExpiry
        }
    }

    /// Whether a RECEIVED announce may be relayed out an interface of mode `outMode`, given the
    /// mode of the interface it arrived on (RNS Transport.py:1224-1270). Applies ONLY to relay
    /// re-broadcast — locally-originated announces go everywhere (an access point "originates
    /// only"). nil arrivalMode = the arrival interface has disconnected since; permissive by
    /// C2 spec decision. `.interfaceInternal` is treated as `.full` (its announces_to_internal
    /// rule is deferred; no ReTiCA composition uses internal-mode interfaces).
    static func mayRelayAnnounce(to outMode: InterfaceMode, arrivalMode: InterfaceMode?) -> Bool {
        switch outMode {
        case .accessPoint: return false
        case .roaming:     return arrivalMode != .roaming && arrivalMode != .boundary
        case .boundary:    return arrivalMode != .roaming
        case .full, .pointToPoint, .gateway, .interfaceInternal: return true
        }
    }

    /// How long an interface must stay quiet after emitting a relayed announce of `byteCount`
    /// bytes, so relayed announces consume at most `announceCap` of its bandwidth
    /// (RNS Transport.py:1282-1285: tx_time = bits/bitrate; wait = tx_time / announce_cap).
    /// `bitrate` is guaranteed > 0 and `announceCap` ∈ (0, 1] by `InterfaceProfile`'s
    /// preconditions, so this needs no zero guard.
    static func announcePacingWait(byteCount: Int, bitrate: Int,
                                   announceCap: Double) -> TimeInterval {
        let txTime = (Double(byteCount) * 8.0) / Double(bitrate)
        return txTime / announceCap
    }

    /// RNS MAX_QUEUED_ANNOUNCES: per-interface cap on announces awaiting their pacing slot.
    static let announceQueueLimit = 16384
    /// RNS QUEUED_ANNOUNCE_LIFE: a queued announce older than this is dropped, seconds.
    static let queuedAnnounceLife: TimeInterval = 86_400

    // MARK: - C4 ingress control (RNS Interface.py:58-92, 152-255)

    /// Rolling window of announce arrival times used for the rate estimate (RNS IA_FREQ_SAMPLES).
    static let iaFreqSamples = 48
    /// Samples older than this decay out of the window (RNS AR_FREQ_DECAY = 1/AR_MINFREQ_HZ).
    static let arFreqDecay: TimeInterval = 10
    /// Per-interface cap on held announces (RNS MAX_HELD_ANNOUNCES).
    static let maxHeldAnnounces = 256
    /// Interfaces younger than this use the stricter burst threshold (RNS IC_NEW_TIME).
    static let icNewTime: TimeInterval = 7200
    /// Burst thresholds in Hz for young / established interfaces (RNS IC_BURST_FREQ_NEW / IC_BURST_FREQ).
    static let icBurstFreqNew: Double = 3
    static let icBurstFreq: Double = 10
    /// Minimum time a burst stays active once triggered (RNS IC_BURST_HOLD), seconds.
    static let icBurstHold: TimeInterval = 15
    /// Delay before the first held announce may be released (RNS IC_BURST_PENALTY), seconds.
    static let icBurstPenalty: TimeInterval = 15
    /// Spacing between held-announce releases (RNS IC_HELD_RELEASE_INTERVAL), seconds.
    static let icHeldReleaseInterval: TimeInterval = 5
    /// The rate estimate needs MORE than this many samples to be meaningful (RNS IC_DEQUE_MIN_SAMPLE).
    static let icDequeMinSample = 2
    /// RNS PATHFINDER_M: an announce at or past `maxHops - 1` is never held (it is dropped).
    static let ingressHoldHopLimit = Int(Packet.maxHops) - 1

    /// Per-interface announce burst state (RNS ic_burst_active / ic_burst_activated / ic_held_release).
    public struct IngressBurst: Equatable, Sendable {
        public var active: Bool
        public var activatedAt: Date
        public var heldRelease: Date
        public init(active: Bool = false,
                    activatedAt: Date = .distantPast,
                    heldRelease: Date = .distantPast) {
            self.active = active
            self.activatedAt = activatedAt
            self.heldRelease = heldRelease
        }
    }

    /// Announce arrival rate in Hz over the sample window (RNS incoming_announce_frequency,
    /// Interface.py:276-285). Returns 0 until more than `icDequeMinSample` samples exist, and
    /// on a non-positive span.
    static func announceFrequency(samples: [Date], now: Date) -> Double {
        let n = samples.count
        guard n > icDequeMinSample, let oldest = samples.first else { return 0 }
        let span = now.timeIntervalSince(oldest)
        guard span > 0 else { return 0 }
        return Double(n) / span
    }

    /// Burst threshold for an interface of the given age (RNS Interface.py:154).
    static func ingressBurstThreshold(interfaceAge: TimeInterval) -> Double {
        interfaceAge < icNewTime ? icBurstFreqNew : icBurstFreq
    }

    /// Whether this announce should be held, plus the updated burst state
    /// (RNS should_ingress_limit, Interface.py:152-172).
    ///
    /// Note the asymmetry, faithful to reference: the call that DEACTIVATES a burst still
    /// returns `limit == true`, so the announce that ends a burst is itself held.
    static func shouldIngressLimit(samples: [Date], now: Date, interfaceAge: TimeInterval,
                                   burst: IngressBurst) -> (limit: Bool, burst: IngressBurst) {
        let threshold = ingressBurstThreshold(interfaceAge: interfaceAge)
        let freq = announceFrequency(samples: samples, now: now)
        var next = burst
        if burst.active {
            if freq < threshold, now > burst.activatedAt.addingTimeInterval(icBurstHold),
               samples.count >= icDequeMinSample {
                next.active = false
            }
            return (true, next)
        }
        if freq > threshold {
            next.active = true
            next.activatedAt = now
            next.heldRelease = now.addingTimeInterval(icBurstPenalty)
            return (true, next)
        }
        return (false, next)
    }

    /// RNS LINK_TIMEOUT (Transport.py:89 = Link.STALE_TIME * 1.25 = (STALE_FACTOR*KEEPALIVE)*1.25).
    static let linkTableExpiry: TimeInterval = 900              // 720 * 1.25
    /// RNS PATH_REQUEST_TIMEOUT (Transport.py:79): in-flight recursive path searches expire, seconds.
    /// Governs discoveryPathRequests (relay-only). Do NOT use this for pathRequests.
    static let pathRequestTimeout: TimeInterval = 15
    /// RNS PATH_REQUEST_GATE_TIMEOUT (Transport.py:80): how long a local path-request entry stays
    /// in pathRequests to exempt arriving path-response announces from ingress holding. Distinct
    /// from pathRequestTimeout (which governs the relay discoveryPathRequests table and is 15 s).
    static let pathRequestGateTimeout: TimeInterval = 120
    /// Sweep cadence — a local tuning constant (NOT wire-visible, NOT cross-validated).
    static let maintenanceTickInterval: TimeInterval = 60

    /// RNS Transport path-request control destination: PLAIN "rnstransport"/["path","request"]
    /// (Transport.py:61,256). Deterministic (no identity). Cross-validated against genuine RNS.
    static let pathRequestDestinationHash: Data =
        Destination.hash(identityHash: nil, appName: "rnstransport", aspects: ["path", "request"])

    static let pathRequestTagRingSize = 32000      // RNS max_pr_tags (Transport.py:127)
    /// Packet-hash dedup window. Reference `hashlist_maxsize` is 1_000_000 with a two-generation
    /// flip keeping 500k-1M live (RNS Transport.py:177, 656-658); we hold 262144. DELIBERATE
    /// DIVERGENCE, not a port of the reference number — a quarter of the reference floor, still
    /// 262x the previous accidental 1000-entry default and far beyond any realistic
    /// packet-to-echo distance.
    ///
    /// A window this size is only affordable because `RingSet` is boxed and O(1) (see its doc
    /// comment). Reference affords 1 M for the same reason: a plain `set` plus a generation flip
    /// that drops the old generation *by reference*, never shifting an array and never deep-copying
    /// per packet. Taking the number without that structure inverts it — this constant at the
    /// old value-typed `RingSet` cost 67-82 ms and ~44 MB per received packet.
    ///
    /// Cost here: O(1) per packet (two SipHash passes, one `Set` insert, one `Set` remove, one
    /// array store — no allocation, no memmove, no CoW), and 48 bytes per remembered hash for a
    /// ~12.1 MB steady state that is only reached after 262144 distinct packets. `RingSet`'s
    /// two sibling rings — `pathRequestTagRingSize` (32000, ~1.5 MB) and `announceBlobRingSize`
    /// (64, per destination) — are the same type and get the same O(1) behaviour for free.
    static let seenPacketRingSize = 262_144
    /// Per-destination announce random-blob memory size (RNS Transport.MAX_RANDOM_BLOBS, Transport.py:98).
    static let announceBlobRingSize = 64
    /// RNS LOCAL_REBROADCASTS_MAX (Transport.py:77): total local re-broadcasts of one announce.
    static let announceMaxRebroadcasts = 2
    /// RNS PATHFINDER_G (Transport.py:69): grace between announce re-broadcast retries, seconds.
    static let announceRetryGrace = 5.0
    /// RNS PATHFINDER_RW (Transport.py:70): the random window for an announce re-broadcast, seconds.
    static let announceRebroadcastWindow = 0.5

    /// Jitter delay for an announce re-broadcast: `byte/256` of the window — the deterministic
    /// analogue of RNS's `rand() * PATHFINDER_RW` (Transport.py:1925). Always in `[0, window)`.
    static func announceJitter(_ byte: UInt8) -> Double {
        Double(byte) / 256.0 * announceRebroadcastWindow
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
