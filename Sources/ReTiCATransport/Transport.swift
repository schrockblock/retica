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
        /// Our own ratchets, per local destination that has them enabled — reference
        /// `Destination.ratchets` (RNS 1.6.0 Destination.py:87-94, 233-262, 575-611). Present only
        /// after the host sends `.enableRatchets` with the ring it restored (a deliberate divergence:
        /// reference enables them on every LXMF delivery destination; see `.enableRatchets`). Each
        /// announce and local path response for the destination rotates the ring when due and
        /// carries the public key of `ring[0]`; inbound SINGLE packets to it are decrypted with the
        /// ring first. Kept across deregistration, as a stamp is.
        public var ownRatchets: [Data: OwnRatchets] = [:]
        public var learned: [Data: LearnedDestination] = [:]
        /// Every remote destination a valid announce was heard for (reference
        /// `Identity.known_destinations`) — what `recall(destinationHash:)` reads. Written on each
        /// announce that passes the ingress gate (before the replay check, as reference's
        /// `Identity.validate_announce` → `remember` runs), culled by `maintenanceTick` only once
        /// pathless past `Transport.knownDestinationExpiry`, restored by `.rehydrateKnownDestinations`.
        /// Also holds each peer's ratchet (`KnownDestination.ratchet`), which only a fresh announce
        /// (after the replay check) sets; read it with `recallRatchet(destinationHash:now:)`.
        public var knownDestinations: [Data: KnownDestination] = [:]
        public var interfaces: [InterfaceID: InterfaceProfile] = [:]
        public var transportIdentity: Identity? = nil
        var seenPacketHashes = RingSet(capacity: Transport.seenPacketRingSize)
        public var linkTable: [Data: LinkTableEntry] = [:]
        /// LinkIDs of links we are an endpoint of (initiator or responder). A link we own is never
        /// relay traffic: Transport must not table a reflected LINKREQUEST that collides with our
        /// own linkID, nor forward our own link's packets. Kept in sync by LinkPlane via
        /// register/unregister (see TransportEndpoint wiring). Session-only.
        public var localLinkIDs: Set<Data> = []
        /// Per-destination ring of recently-seen announce random-blobs (the 10-byte announce
        /// random_hash). Replaces packetHash dedup for announces: a repeated blob is a replay
        /// (RNS Transport.py:1824 `not random_blob in random_blobs`). Bounded to
        /// `announceBlobRingSize` per destination (RNS MAX_RANDOM_BLOBS).
        public var announceBlobs: [Data: RingSet] = [:]
        /// What recently heard announce bytes were judged to be (reference `announce_valid_cache` and
        /// `announce_invalid_cache`), consulted in place of a parse. See `AnnounceVerdictCache`.
        var announceVerdicts = AnnounceVerdictCache()
        /// A cached announce, kept whole so a relay can re-emit it verbatim.
        ///
        /// The context flag is stored ALONGSIDE the payload rather than re-derived when the
        /// response is minted, because for an announce the flag is a field-layout declaration
        /// about these exact bytes ("a 32-byte ratchet sits between random_hash and signature"),
        /// not a fact about our parsed view of them. The two can disagree: `Announce.parse` drops
        /// a ratchet that cannot perform key agreement while the bytes stay in the payload, so
        /// a known destination without a ratchet does NOT imply the payload is ratchet-free. Deriving the
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

        /// Stamp our own path requests (RNS `Transport.STAMP_PRS`, `[stamps] stamp_path_requests`).
        /// Off by default, as in 1.6.0. When on, `.requestPath` first searches for a stamp of
        /// `pathRequestValue` over `destinationHash + tag`, up to `NetworkStamp.pathStampTimeout`, and
        /// sends the 64-byte request only once one is found; a relay also marks unstamped requests it
        /// forwards with the lenient extension (`Transport.lenientPathRequestExtension`). A host sets
        /// it at construction, on `TransportEndpoint.State.transport`.
        public var stampPathRequests = false
        /// The stamp value our path requests carry when `stampPathRequests` is on (RNS `PR_VALUE`).
        public var pathRequestValue: Double = NetworkStamp.defaultPathRequestValue
        /// The sender ID a path request carries when this node has no `transportIdentity`. RNS 1.6.0
        /// always sends `destination + transport ID + tag` (Transport.py:3699) and every reference
        /// instance has a transport identity; a leaf here has none, so it sends 16 random bytes,
        /// drawn from the `randomBytes` dependency at its first path request and kept after that.
        /// A relay compares this field with its next hop (the loop guard), and a
        /// random value matches no real next hop.
        public var pathRequestSenderID: Data?
        /// Destinations whose path-request stamp search is in flight, each with the tag of the request
        /// that search is for. A further `.requestPath` for one of them is coalesced into it. Cleared
        /// when the search ends or `.cancelPathRequestStamps`.
        public var stampingPathRequests: [Data: Data] = [:]

        /// Stamp our own announces (RNS `Transport.STAMP_DESTINATIONS`, `[stamps] stamp_destinations`).
        /// Off by default, as in 1.6.0, and then announce bytes are exactly as before. When on, every
        /// announce and local path response carries the 18-byte extension (`Transport.destinationStampExtension`)
        /// with a stamp of `destinationValue` over `destinationHash + publicKey + nameHash`. The stamp is
        /// mined once per destination (about 45 s at the default value on a Mac; unmeasured on a
        /// phone) and reported with
        /// `.delegate(.destinationStampGenerated)` so the host can persist it and hand it back with
        /// `.rehydrateDestinationStamp` (reference persists it, Stamps.py:888-930). A host sets this at
        /// construction, on `TransportEndpoint.State.transport`; there is no action to change it.
        public var stampDestinations = false
        /// The value our announce stamps are mined to (RNS `Transport.DESTINATION_VALUE`). Read through
        /// `Transport.clampedDestinationValue`, which clamps it to 0...`NetworkStamp.stampCostCap` as
        /// reference's config parser does (Reticulum.py:529-531).
        public var destinationValue: Double = NetworkStamp.defaultDestinationValue
        /// The stamp held for each local destination, generated or rehydrated. Checked against
        /// `destinationValue` before each use; one that falls short is dropped and mined again.
        public var destinationStamps: [Data: Data] = [:]
        /// The link-request cost each local destination announces, already clamped to
        /// 0...`NetworkStamp.linkCostCap` (reference `set_link_cost`, Destination.py:399-405). Absent
        /// means `NetworkStamp.defaultLinkRequestCost` (reference `get_link_cost`, Destination.py:407-417).
        public var localLinkCosts: [Data: Double] = [:]
        /// Local destinations whose stamp search is in flight. One search per destination.
        public var stampingDestinations: Set<Data> = []
        /// Enforce network stamps on what we receive (RNS `[stamps] enforce_stamps`, which sets both
        /// `STAMPS_ENFORCED` and `LR_STAMPS_ENFORCED`, Reticulum.py:507-511). Off by default, as in
        /// 1.6.0. When on:
        ///   * an announce whose stamp does not meet the receiving interface's destination cost
        ///     (`resolvedDestinationCost(on:)`) is neither learned, remembered
        ///     nor relayed (Identity.py:883-889, Transport.py:2046-2049). The stamp is checked
        ///     before any public-key work (the Ed25519 signature, and the ratchet's trial X25519
        ///     agreement), so a junk announce costs at most two SHA-256;
        ///   * a path request without a stamp meeting the receiving interface's path-request cost
        ///     (`resolvedPathRequestCost(on:)`) over `destination + tag` is
        ///     neither answered nor forwarded (Transport.py:2099-2129);
        ///   * a link request to a local destination whose X25519 key, the stamp, does not meet that
        ///     destination's link cost over `destinationHash + Ed25519 key` is never handed to the link
        ///     plane, so it is not answered and costs no DH (Link.py:192-195).
        /// Peers learn our link cost only from stamped announces, so enforcing link requests without
        /// `stampDestinations` refuses every link a 1.6.0 peer opens to us, as reference does. Our own
        /// outbound traffic is unaffected. A host sets this at construction, on
        /// `TransportEndpoint.State.transport`.
        public var enforceStamps = false
        /// The stamp value an announce must carry (RNS `Transport.DESTINATION_COST`). Also the value
        /// below which a stamp is left in the app data and its link cost ignored, enforced or not.
        /// An interface whose `InterfaceProfile.destinationCost` is set uses that instead (reference
        /// `destination_cost`, Interface.py:350-353); see `resolvedDestinationCost(on:)`.
        public var destinationCost: Double = NetworkStamp.defaultDestinationCost
        /// The stamp value a path request must carry when `enforceStamps` is on (RNS
        /// `Transport.PR_COST`). An interface whose `InterfaceProfile.pathRequestCost` is set uses
        /// that instead (reference `pr_cost`, Interface.py:355-358); see `resolvedPathRequestCost(on:)`.
        public var pathRequestCost: Double = NetworkStamp.defaultPathRequestCost
        /// Announces and path responses waiting for their destination's stamp (reference
        /// `stamp_queues`, Transport.py:1453-1463). At most one announce per destination and target
        /// interface (the newest), and bounded overall by `Transport.stampedAnnounceQueueLimit` and
        /// `Transport.stampedPathResponseQueueLimit`; dropped if the search ends without a stamp.
        public var pendingStampedAnnounces: [PendingStampedAnnounce] = []

        /// An announce or path response held until its destination's stamp exists.
        public struct PendingStampedAnnounce: Equatable, Sendable {
            public enum Kind: Equatable, Sendable {
                /// `.announce(destinationHash:appData:interface:)` as it was sent.
                case announce(appData: Data?, interface: InterfaceID?)
                /// A path response owed on the interface its request arrived on.
                case pathResponse(interface: InterfaceID)
            }
            public var destinationHash: Data
            public var kind: Kind
            public var isPathResponse: Bool {
                if case .pathResponse = kind { return true }
                return false
            }
            public init(destinationHash: Data, kind: Kind) {
                self.destinationHash = destinationHash
                self.kind = kind
            }
        }

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
        /// Connect times of interfaces that have DISCONNECTED, oldest departure first, so a
        /// reconnect of the same id resumes its age: reference `Interface.created` is set once
        /// per Interface object (Interface.py:101) and a reconnect reuses the object
        /// (TCPInterface.py:270-297). At most `Transport.maxDepartedInterfaceAges`; an id evicted
        /// from here returns as a new interface (stricter, never looser).
        public var departedInterfaceAges: [Transport.DepartedInterfaceAge] = []

        /// An outbound single packet awaiting its delivery proof (RNS `PacketReceipt`,
        /// Packet.py:402-419), recorded by `.send(..., receiptToken:)`.
        public struct PendingReceipt: Equatable, Sendable {
            /// Full 32-byte packet hash: what the proof signs, and (first 16 bytes) its address.
            public var packetHash: Data
            /// Opaque to Transport. LXMF passes `message.hash`, so every resend shares one token.
            public var token: Data
            /// The recipient identity from `learned[dest]` at send time; the proof must verify with it.
            public var identity: Identity
            public var expiresAt: Date
            public init(packetHash: Data, token: Data, identity: Identity, expiresAt: Date) {
                self.packetHash = packetHash
                self.token = token
                self.identity = identity
                self.expiresAt = expiresAt
            }
        }
        /// `packetHash.prefix(16)` → receipt. The key is the proof's destination hash (the packet's
        /// `ProofDestination`), so an inbound proof finds its receipt with one lookup.
        public var pendingReceipts: [Data: PendingReceipt] = [:]

        /// One local destination's own ratchets.
        public struct OwnRatchets: Equatable, Sendable {
            /// X25519 private keys, newest first, at most `Transport.ratchetCount`. Secrets: the host
            /// persists them (`.delegate(.ratchetsChanged)`) somewhere fit for private keys.
            public internal(set) var ring: [Data]
            /// When the ring last rotated, or nil when it has not rotated since `.enableRatchets`
            /// (reference `latest_ratchet_time = 0`, Destination.py:591), so the next announce rotates.
            public internal(set) var lastRotation: Date?
            /// Drop inbound packets no ratchet decrypts, instead of trying the identity key —
            /// reference `enforce_ratchets` (Destination.py:600-611, Identity.py:1255-1259).
            public internal(set) var enforce: Bool
            public init(ring: [Data], lastRotation: Date? = nil, enforce: Bool = false) {
                self.ring = ring
                self.lastRotation = lastRotation
                self.enforce = enforce
            }
        }

        public init() {}

        /// The stamp value an announce received on `interfaceID` is checked against: that interface's
        /// `InterfaceProfile.destinationCost` when set, else `destinationCost` (reference
        /// `packet.receiving_interface.destination_cost`, Identity.py:794-795). An interface with no
        /// registered profile uses `destinationCost`, as reference does with no receiving interface.
        func resolvedDestinationCost(on interfaceID: InterfaceID) -> Double {
            interfaces[interfaceID]?.destinationCost ?? destinationCost
        }

        /// The stamp value a path request received on `interfaceID` must carry when enforcing: that
        /// interface's `InterfaceProfile.pathRequestCost` when set, else `pathRequestCost` (reference
        /// `packet.receiving_interface.pr_cost`, Transport.py:2103).
        func resolvedPathRequestCost(on interfaceID: InterfaceID) -> Double {
            interfaces[interfaceID]?.pathRequestCost ?? pathRequestCost
        }

        /// The public identity behind `destinationHash`, or nil if this node has never heard it —
        /// reference `Identity.recall(destination_hash)` (RNS/Identity.py:116-160). Looks in the
        /// known destinations first, then the path table (a host may have restored `learned` alone
        /// via `.rehydrateLearnedDestinations`), then — as reference does — this node's own
        /// registered destinations. Always public-only.
        ///
        /// An unknown hash is answered by asking the network: `.requestPath(destinationHash:)`
        /// solicits a path-response announce, and once it lands (`.delegate(.pathLearned)`) this
        /// returns the identity. Reference has the same shape (`Transport.request_path`, then
        /// `Identity.recall`).
        public func recall(destinationHash: Data) -> Identity? {
            if let known = knownDestinations[destinationHash] { return known.identity }
            if let path = learned[destinationHash] { return path.identity }
            if let local = localDestinations[destinationHash]?.identity {
                return Identity(publicKey: local.publicKey)
            }
            return nil
        }

        /// The public identity whose identity hash (`Identity.hash`) is `identityHash`, from any
        /// destination it has announced — reference `Identity.recall(.., from_identity_hash=True)`
        /// (RNS/Identity.py:129-140), extended to the same fallbacks as `recall(destinationHash:)`.
        /// A linear scan, as in reference.
        public func recall(identityHash: Data) -> Identity? {
            if let known = knownDestinations.values.first(where: { $0.identity.hash == identityHash }) {
                return known.identity
            }
            if let path = learned.values.first(where: { $0.identity.hash == identityHash }) {
                return path.identity
            }
            if let local = localDestinations.values.compactMap(\.identity).first(where: { $0.hash == identityHash }) {
                return Identity(publicKey: local.publicKey)
            }
            return nil
        }

        /// The app data last announced by `destinationHash`, or nil — reference
        /// `Identity.recall_app_data` (RNS/Identity.py:162-175).
        public func recallAppData(destinationHash: Data) -> Data? {
            if let known = knownDestinations[destinationHash] { return known.appData }
            return learned[destinationHash]?.appData
        }

        /// The link-request stamp cost `destinationHash` last announced, or nil if it is unknown or
        /// announced none — reference `Identity.recall_link_cost` (RNS 1.6.0 Identity.py:202-211).
        /// Read from the known destinations only, which every valid announce refreshes.
        public func recallLinkCost(destinationHash: Data) -> Double? {
            knownDestinations[destinationHash]?.linkCost
        }

        /// The ratchet public key to encrypt to `destinationHash` with, or nil to use its identity
        /// key — reference `Identity.get_ratchet` (RNS 1.6.0 Identity.py:618-675), which
        /// `Destination.encrypt` consults for every SINGLE destination (Destination.py:694-708).
        /// Nil when none is known or the known one was first heard more than `Transport.ratchetExpiry`
        /// (30 days) before `now`, as reference discards one read from its store (Identity.py:626).
        /// A ratchet with no receive time, or a non-finite one, counts as expired.
        /// `now` has no default: pass the clock the receive time was stamped with (`\.transportDate`).
        public func recallRatchet(destinationHash: Data, now: Date) -> Data? {
            guard let known = knownDestinations[destinationHash], let ratchet = known.ratchet,
                  let received = known.ratchetReceived,
                  Transport.ratchetIsFresh(received: received, now: now)
            else { return nil }
            return ratchet
        }

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

        /// The profile of the interface the learned path to `destinationHash` leaves on — reference
        /// `Transport.next_hop_interface` / `next_hop_interface_bitrate` (`RNS/Transport.py:2750-2765`,
        /// local 1.4.1 fork), whose interface is the path's receiving interface, as `interfaceID` is
        /// here. `nil` when there is no learned path, or it names an interface that is not connected.
        public func nextHopInterfaceProfile(_ destinationHash: Data) -> InterfaceProfile? {
            guard let entry = reachableLearned(destinationHash) else { return nil }
            return interfaces[entry.interfaceID]
        }

        public struct LinkTableEntry: Equatable, Sendable {
            public var rcvdIf: InterfaceID
            public var nhIf: InterfaceID
            public var refreshedAt: Date
            /// True once a link proof (LRPROOF) has flowed through this relay for the link — RNS
            /// `IDX_LT_VALIDATED`. Validated entries roll on data traffic; unvalidated entries die at
            /// `proofDeadline` and cannot be kept alive by junk.
            public var validated: Bool
            /// Hard deadline for an unvalidated entry (RNS `IDX_LT_PROOF_TMO`). Ignored once validated.
            public var proofDeadline: Date
            public init(rcvdIf: InterfaceID, nhIf: InterfaceID,
                        refreshedAt: Date = Date(timeIntervalSince1970: 0),
                        validated: Bool = false,
                        proofDeadline: Date = Date(timeIntervalSince1970: 0)) {
                self.rcvdIf = rcvdIf
                self.nhIf = nhIf
                self.refreshedAt = refreshedAt
                self.validated = validated
                self.proofDeadline = proofDeadline
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
        /// Register a local destination. `linkCost` is the link-request stamp cost it announces when
        /// `stampDestinations` is on: nil means `NetworkStamp.defaultLinkRequestCost` (reference
        /// `LR_COST`), and a value is clamped to 0...`NetworkStamp.linkCostCap`, NaN to 0, as reference
        /// `set_link_cost` does (Destination.py:399-405). LXMF registers 3.25.
        case registerLocalDestination(Destination, linkCost: Double? = nil)
        /// Remove a local destination — reference `Transport.deregister_destination`
        /// (RNS/Transport.py:2520-2527). From then on its DATA is dropped, its LINKREQUESTs are
        /// not surfaced, path requests for it are not answered and `.announce` for it emits
        /// nothing; its sticky app data is forgotten. A hash that is not registered is a no-op.
        /// Links already open on it belong to the link plane: `TransportEndpoint` closes them.
        ///
        /// It stops THIS node serving the hash; it does not withdraw paths the network already
        /// learned. Reticulum has no un-announce: peers and relays keep their path (and cached
        /// announce) until it expires, so traffic may still arrive here for a while — and is dropped.
        case deregisterLocalDestination(destinationHash: Data)
        case setTransportIdentity(Identity?)
        case setRecursivePathRequests(Bool)
        case registerLocalLink(Data)
        case unregisterLocalLink(Data)
        case received(InterfaceID, Data)
        /// Announce a local destination. `interface: nil` sends on every connected interface (the
        /// original behaviour). A non-nil `interface` sends on THAT interface only — used to
        /// re-announce on an interface that just came up (2026-10-16 Meshtastic spec, Contract 4) —
        /// and on nothing when it is not connected: never a silent fallback to every interface.
        case announce(destinationHash: Data, appData: Data?, interface: InterfaceID? = nil)
        case requestPath(destinationHash: Data)
        /// A path-request stamp search for `destinationHash` ended: `request` is the stamped 64-byte
        /// payload to send, or nil when the search ran out `NetworkStamp.pathStampTimeout`.
        case pathRequestStampSearchEnded(destinationHash: Data, tag: Data, request: Data?)
        /// Cancel every path-request stamp search; none of them sends. The host sends this when it stops.
        case cancelPathRequestStamps
        /// Hand back a destination stamp the host persisted from `.delegate(.destinationStampGenerated)`.
        /// One that is not `NetworkStamp.stampLength` bytes is discarded; the rest is checked against
        /// `destinationValue` before use, and one that falls short is mined again (Stamps.py:907-930).
        /// If a search for the destination is running and this stamp meets the value, it ends the
        /// search and releases what was waiting.
        case rehydrateDestinationStamp(destinationHash: Data, stamp: Data)
        /// A destination stamp search ended with `stamp` (nil if it ended without one) of `value`.
        case destinationStampSearchEnded(destinationHash: Data, stamp: Data?, value: Double)
        /// Cancel every destination stamp search and drop what waited for it, as reference drops
        /// announces whose stamp generation fails (Destination.py:349-351). The next announce searches
        /// again. The host sends this when it stops.
        case cancelDestinationStamps
        /// Encrypt `plaintext` to a learned destination and send it as one packet. With a non-nil
        /// `receiptToken`, also record a `PendingReceipt` so a valid proof for this packet emits
        /// `.delegate(.singlePacketDelivered(token:))`. The token is opaque to Transport.
        case send(destinationHash: Data, plaintext: Data, receiptToken: Data? = nil)
        /// Prove a single packet we received, reference-style (RNS `Identity.prove`,
        /// Identity.py:942-953): an unencrypted HEADER_1 PROOF to the packet's `ProofDestination`
        /// (hash = `packetHash[:16]`, type SINGLE, Packet.py:376-379), context NONE, carrying the
        /// 64-byte IMPLICIT proof — `identity.sign(packetHash)`, the reference default
        /// (Reticulum.py:259) — sent on the interface the packet arrived on. Does nothing when
        /// `identity` has no private key or `interfaceID` is not connected.
        case proveSingle(packetHash: Data, interfaceID: InterfaceID, identity: Identity)
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
        /// Restore `knownDestinations` from a previous session (reference
        /// `Identity.load_known_destinations`, RNS/Identity.py:216-233), so `recall` answers for
        /// destinations heard before the relaunch. Same guards as `.rehydrateLearnedDestinations`:
        /// a row whose `lastHeard` is non-finite, in the future, or older than
        /// `knownDestinationExpiry` is dropped, and a restored row never replaces a live entry heard
        /// at least as recently. (Reference does not sweep on load; its cull runs every 5 minutes.)
        /// Rows are stored public-only, and a row keyed by one of this node's registered local
        /// destinations is ignored. A row's ratchet is restored only if it passes
        /// `Identity.isUsableRatchet` and its `ratchetReceived` is finite, not in the future and within
        /// `ratchetExpiry`; otherwise the row is restored without it. The ratchet is merged apart from
        /// the rest of the entry: whichever entry wins, the ratchet received later is kept (the live
        /// one on a tie), so a newer row cannot wipe a fresher live ratchet.
        case rehydrateKnownDestinations([Data: KnownDestination])
        /// Enable our own ratchets on local destination `destinationHash`, starting from `ring`: the
        /// X25519 private keys the host saved from `.delegate(.ratchetsChanged)`, newest first, or
        /// `[]` for a destination that never had any. Reference `Destination.enable_ratchets`
        /// (RNS 1.6.0 Destination.py:575-598).
        ///
        /// A ring entry that is not 32 bytes is dropped, and the ring is cut to `Transport.ratchetCount`.
        /// The next announce or local path response rotates (reference resets `latest_ratchet_time` to
        /// 0), and from then on each carries the public key of the newest ratchet, which grows the
        /// announce by 32 bytes. If the app data this destination last announced no longer fits with
        /// those 32 bytes, it is forgotten (see `State.localAppData`), so a later announce without app
        /// data and path responses still go out. Sending it again restarts from the given ring.
        ///
        /// DIVERGENCE: reference LXMF enables ratchets on every delivery destination. ReTiCA enables
        /// them only here, because the ring is private keys only the host can keep: a ring lost on
        /// relaunch leaves every message encrypted to an old ratchet undecryptable, including ones a
        /// propagation node holds for days.
        case enableRatchets(destinationHash: Data, ring: [Data])
        /// Enforce ratchets on `destinationHash`: an inbound packet (and a propagated LXMF message
        /// LXMFNode downloads) that no ratchet decrypts is dropped instead of being tried with the
        /// identity key. Reference `Destination.enforce_ratchets` (Destination.py:600-611). Ignored
        /// unless ratchets are enabled on it, as reference returns False then.
        case setEnforceRatchets(destinationHash: Data, Bool)
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            /// A single packet decrypted for a local destination. `packetHash` is the full 32-byte
            /// `Packet.packetHash` (what a proof signs) and `interfaceID` is where it arrived (where
            /// a proof must go back out).
            case received(destinationHash: Data, plaintext: Data, packetHash: Data, interfaceID: InterfaceID)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: SendFailure)
            case linkPacket(linkID: Data, arrivalInterface: InterfaceID, data: Data)
            case linkRequest(destinationHash: Data, arrivalInterface: InterfaceID, data: Data)
            /// A valid proof arrived for a packet sent with `receiptToken`; the receipt is gone.
            case singlePacketDelivered(token: Data)
            /// A stamp was mined for a local destination. Persist it and hand it back with
            /// `.rehydrateDestinationStamp` after a relaunch: at the default value it takes about 45 s on
            /// a Mac, and has not been measured on a phone (reference `store_destination_stamp`,
            /// Stamps.py:888-905).
            case destinationStampGenerated(destinationHash: Data, stamp: Data, value: Double)
            /// The own ratchet ring of `destinationHash` rotated: `ring` is the whole ring, private
            /// keys, newest first. Persist it (replacing the previous one) somewhere fit for private
            /// keys, and pass it to `.enableRatchets` after a relaunch, before the first announce.
            case ratchetsChanged(destinationHash: Data, ring: [Data])
        }
    }

    @Dependency(\.transportDate) var date
    @Dependency(\.continuousClock) var clock
    @Dependency(\.randomBytes) var randomBytes
    @Dependency(\.destinationStampGenerator) var destinationStampGenerator

    private enum CancelID: Hashable {
        case announceRetransmit(Data); case maintenance; case announceDrain(InterfaceID)
        case ingressRelease(InterfaceID)
        case pathRequestStamp(Data)
        case destinationStamp(Data)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { [clock, date, randomBytes, destinationStampGenerator] state, action in
            // Shared helper: rewrite a packet for forwarding toward its destination.
            // Final hop → HEADER_1 direct; onward → HEADER_2 to next hop. The final hop is the
            // destination itself OR a local client of the next hop (`LearnedDestination.relayNextHop`,
            // reference `Transport.inbound` strips the header at remaining_hops == 1).
            func forwardTowardDest(_ packet: Packet, _ entry: LearnedDestination) -> Data? {
                let fwd: Packet
                if let nextHop = entry.relayNextHop(toward: packet.destinationHash) {
                    fwd = Packet(headerType: .header2, packetType: packet.packetType, transportType: .transport,
                                 destinationType: packet.destinationType, context: packet.context,
                                 contextFlag: packet.contextFlag, hops: packet.hops + 1,
                                 destinationHash: packet.destinationHash, transportId: nextHop,
                                 payload: packet.payload)
                } else {
                    fwd = Packet(headerType: .header1, packetType: packet.packetType, transportType: .broadcast,
                                 destinationType: packet.destinationType, context: packet.context,
                                 contextFlag: false, hops: packet.hops + 1,
                                 destinationHash: packet.destinationHash, transportId: nil, payload: packet.payload)
                }
                return try? fwd.packed()
            }

            // A path request of our own (RNS request_path, Transport.py:3716-3717): DATA, BROADCAST,
            // HEADER_1 to the well-known PLAIN control destination, on every given interface.
            func transmitPathRequest(_ payload: Data, on interfaces: [InterfaceID]) -> Effect<Action> {
                let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                    destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                                    payload: payload)
                guard let raw = try? packet.packed() else { return .none }
                let sends = interfaces.map { Effect<Action>.send(.delegate(.transmit($0, raw))) }
                return sends.isEmpty ? .none : .merge(sends)
            }

            // --- RNS 1.6.0 destination stamps on our own announces (Destination.py:266-379) ---

            // The stamp `dest` can use now: held, `stampLength` bytes, and meeting `destinationValue`.
            // One that falls short is dropped, so the caller mines a new one (reference `_await_stamp`
            // re-mines below `target_value`, Destination.py:268; `load_destination_stamp` discards a
            // wrong length, Stamps.py:917-919).
            func usableStamp(_ dest: Destination, _ identity: Identity, _ state: inout State) -> Data? {
                guard let stamp = state.destinationStamps[dest.hash] else { return nil }
                guard stamp.count == NetworkStamp.stampLength,
                      NetworkStamp.isValid(stamp: stamp, cost: Transport.clampedDestinationValue(state.destinationValue),
                                           material: dest.hash + identity.publicKey + dest.nameHash)
                else {
                    state.destinationStamps[dest.hash] = nil
                    return nil
                }
                return stamp
            }

            // An announce of `dest` as wire bytes. With a stamp, the 18-byte extension follows the app
            // data and the signature covers it (Destination.py:353-362). With a ratchet (32 bytes), it
            // sits between the random hash and the signature, is signed over, and the context flag is
            // set (Destination.py:335-376). Nil if it cannot be packed.
            func announceBytes(_ dest: Destination, _ identity: Identity, appData: Data?, stamp: Data?,
                               ratchet: Data?, pathResponse: Bool, _ state: State) -> Data? {
                var wireAppData = appData
                if let stamp {
                    let linkCost = state.localLinkCosts[dest.hash] ?? NetworkStamp.defaultLinkRequestCost
                    wireAppData = (appData ?? Data()) + Transport.destinationStampExtension(stamp: stamp, linkCost: linkCost)
                }
                let now = UInt64(date.now.timeIntervalSince1970)
                let randomHash = Announce.randomHash(now: now, randomPrefix: SecureRandom.bytes(5))
                let payload = Announce.buildPayload(identity: identity, destinationHash: dest.hash,
                                                    nameHash: dest.nameHash, randomHash: randomHash,
                                                    ratchet: ratchet, appData: wireAppData)
                return try? Packet.announce(from: dest, payload: payload, pathResponse: pathResponse,
                                            ratchetPresent: ratchet != nil).packed()
            }

            // Rotate `hash`'s own ratchets if due — reference `rotate_ratchets` (Destination.py:250-262),
            // called only from `_announce` (:335-338), so only when an announce or a local path response
            // is built: a new private key goes to the front once more than `ratchetInterval` has passed
            // since the last rotation, or at once after `.enableRatchets`, and the ring is cut to
            // `ratchetCount`. Reports the new ring so the host persists it (reference persists in
            // the same call, :259).
            func rotateRatchetsIfDue(_ hash: Data, _ state: inout State) -> Effect<Action> {
                guard var own = state.ownRatchets[hash] else { return .none }
                let now = date.now
                if let last = own.lastRotation, !(now > last.addingTimeInterval(Transport.ratchetInterval)) {
                    return .none
                }
                own.ring.insert(SecureRandom.bytes(Transport.ratchetKeyLength), at: 0)
                if own.ring.count > Transport.ratchetCount { own.ring.removeLast(own.ring.count - Transport.ratchetCount) }
                own.lastRotation = now
                state.ownRatchets[hash] = own
                return .send(.delegate(.ratchetsChanged(destinationHash: hash, ring: own.ring)))
            }

            // The ratchet `hash`'s announces carry: the public key of the newest ratchet, or nil when
            // ratchets are not enabled (reference `_ratchet_public_bytes(self.ratchets[0])`, :337).
            func announcedRatchet(_ hash: Data, _ state: State) -> Data? {
                state.ownRatchets[hash]?.ring.first.flatMap { Identity.ratchetPublicKey(privateKey: $0) }
            }

            // Bytes standing in for the ratchet when only the announce's length matters.
            func ratchetPlaceholder(_ hash: Data, _ state: State) -> Data? {
                state.ownRatchets[hash] != nil ? Data(count: Transport.ratchetKeyLength) : nil
            }

            // Emit an announce of `dest` (see `.announce` for the sticky app data rule, including why
            // the capture follows a successful pack). It rotates the ratchets first when due, and the
            // rotation is reported even if the announce then cannot be packed: the ring changed.
            func emitAnnounce(_ dest: Destination, _ identity: Identity, appData: Data?, interface: InterfaceID?,
                              stamp: Data?, _ state: inout State) -> Effect<Action> {
                let rotated = rotateRatchetsIfDue(dest.hash, &state)
                let announcedAppData = appData ?? state.localAppData[dest.hash]
                guard let raw = announceBytes(dest, identity, appData: announcedAppData, stamp: stamp,
                                              ratchet: announcedRatchet(dest.hash, state),
                                              pathResponse: false, state) else { return rotated }
                if let appData { state.localAppData[dest.hash] = appData }
                let targets: [InterfaceID] = interface.map { state.interfaces[$0] != nil ? [$0] : [] }
                    ?? Array(state.interfaces.keys)
                return .merge([rotated] + targets.map { .send(.delegate(.transmit($0, raw))) })
            }

            // Answer a path request for our own `dest` on `interfaceID`. It replays the app data this
            // destination last announced: a path response is stamped NOW, so it always wins
            // `shouldReplace` on the requester, and sending nil would erase whatever richer entry the
            // requester had learned from a normal announce (display name, PN metadata, ...).
            //
            // With ratchets enabled it carries the CURRENT newest ratchet and may rotate first: in
            // reference a local path response is a freshly built announce (`announce(path_response=True)`
            // → `_announce`, which rotates and signs over `ratchets[0]`, Destination.py:331-376; its
            // cached-tag branch at :319-329 is unreachable, as its comment says).
            func emitPathResponse(_ dest: Destination, _ identity: Identity, on interfaceID: InterfaceID,
                                  stamp: Data?, _ state: inout State) -> Effect<Action> {
                let rotated = rotateRatchetsIfDue(dest.hash, &state)
                guard let raw = announceBytes(dest, identity, appData: state.localAppData[dest.hash], stamp: stamp,
                                              ratchet: announcedRatchet(dest.hash, state),
                                              pathResponse: true, state) else { return rotated }
                return .merge(rotated, .send(.delegate(.transmit(interfaceID, raw))))
            }

            // One search per destination, no timeout (reference sets none for destination stamps; at
            // the default value it takes about 45 s on a Mac, unmeasured on a phone). Bounded by
            // cancellation: the endpoint's
            // stop, `.cancelDestinationStamps`, deregistration, or a rehydrated stamp.
            func startDestinationStampSearch(_ dest: Destination, _ identity: Identity,
                                             _ state: inout State) -> Effect<Action> {
                guard state.stampingDestinations.insert(dest.hash).inserted else { return .none }
                let hash = dest.hash
                let material = dest.hash + identity.publicKey + dest.nameHash      // stamp_material()
                let value = Transport.clampedDestinationValue(state.destinationValue)
                return .run { send in
                    let found = await destinationStampGenerator.generate(material, value)   // NetworkStamp.generate, live
                    // Cancelled from outside: nothing to report.
                    guard !Task.isCancelled else { return }
                    await send(.destinationStampSearchEnded(destinationHash: hash, stamp: found?.stamp,
                                                            value: found?.value ?? 0))
                }
                .cancellable(id: CancelID.destinationStamp(hash))
            }

            // Hold `item` until its destination's stamp exists, within the reference queue lengths;
            // past them the item is dropped, as reference drops it (Transport.py:1458-1461).
            //
            // Announces are KEYED by (destination, target interface): a newer one replaces the queued
            // one in place, keeping the newest app data. Reference keys by destination alone
            // (Transport.py:1456); the target is added so a per-interface re-announce (Contract 4) is
            // not swallowed by a broadcast one. A search takes about 45 s on a Mac at the default value
            // (unmeasured on a phone), so without the key
            // repeated announces of one destination filled every slot, crowding out other local
            // destinations, and then burst onto the air together. A queued announce for an interface
            // that is not connected would send nothing, so it is not queued. Path responses are not
            // keyed, as in reference: each answers its own request.
            func waitForStamp(_ item: State.PendingStampedAnnounce, _ dest: Destination, _ identity: Identity,
                              _ state: inout State) -> Effect<Action> {
                if case let .announce(_, interface) = item.kind {
                    if let interface, state.interfaces[interface] == nil { return .none }
                    if let queued = state.pendingStampedAnnounces.firstIndex(where: {
                        guard $0.destinationHash == item.destinationHash,
                              case let .announce(_, queuedInterface) = $0.kind else { return false }
                        return queuedInterface == interface
                    }) {
                        state.pendingStampedAnnounces[queued] = item
                        return startDestinationStampSearch(dest, identity, &state)
                    }
                }
                let limit = item.isPathResponse ? Transport.stampedPathResponseQueueLimit
                                                : Transport.stampedAnnounceQueueLimit
                // A destination may hold at most `stampedQueuePerDestinationLimit` of a class's slots
                // (reference has no such quota), so one destination announcing on many interfaces cannot
                // fill the queue. Past it the NEWEST is dropped, as reference drops the newest when the
                // queue is full (WorkerQueues.put raises Full, Transport.py:117); a replacement above
                // does not grow the queue and so never reaches this.
                let sameClass = state.pendingStampedAnnounces.filter { $0.isPathResponse == item.isPathResponse }
                if sameClass.count < limit,
                   sameClass.filter({ $0.destinationHash == item.destinationHash }).count
                       < Transport.stampedQueuePerDestinationLimit {
                    state.pendingStampedAnnounces.append(item)
                }
                return startDestinationStampSearch(dest, identity, &state)
            }

            // The stamp for `hash` exists: send everything that waited for it, path responses first
            // (reference queues them at a higher priority, Transport.py:1455), then announces in order.
            func releaseWaiting(_ hash: Data, stamp: Data, _ state: inout State) -> Effect<Action> {
                let waiting = state.pendingStampedAnnounces.filter { $0.destinationHash == hash }
                state.pendingStampedAnnounces.removeAll { $0.destinationHash == hash }
                guard let dest = state.localDestinations[hash],
                      let identity = dest.identity, identity.privateKey != nil else { return .none }
                var effects: [Effect<Action>] = []
                for item in waiting.filter(\.isPathResponse) + waiting.filter({ !$0.isPathResponse }) {
                    switch item.kind {
                    case let .pathResponse(interfaceID):
                        guard state.interfaces[interfaceID] != nil else { continue }
                        effects.append(emitPathResponse(dest, identity, on: interfaceID, stamp: stamp, &state))
                    case let .announce(appData, interface):
                        effects.append(emitAnnounce(dest, identity, appData: appData, interface: interface,
                                                    stamp: stamp, &state))
                    }
                }
                return .merge(effects)
            }

            switch action {
            case let .interfaceConnected(id, profile):
                state.interfaces[id] = profile
                // Spec 2026-10-16 §7 E.0(b): a repeated connect for a registered id (a radio preset
                // change) keeps its time, and a reconnect resumes the time of its first connect, so
                // neither reopens the 2 h new-interface ingress window (`icNewTime`).
                if state.interfaceConnectedAt[id] == nil {
                    if let departed = state.departedInterfaceAges.firstIndex(where: { $0.id == id }) {
                        state.interfaceConnectedAt[id] = state.departedInterfaceAges.remove(at: departed).connectedAt
                    } else {
                        state.interfaceConnectedAt[id] = date.now
                    }
                }
                return .none

            case let .interfaceDisconnected(id):
                state.interfaces[id] = nil
                state.announceAllowedAt[id] = nil
                state.announceQueues[id] = nil
                state.announceArrivals[id] = nil
                state.ingressBursts[id] = nil
                state.heldAnnounces[id] = nil
                if let connectedAt = state.interfaceConnectedAt[id] {
                    state.departedInterfaceAges.removeAll { $0.id == id }
                    state.departedInterfaceAges.append(Transport.DepartedInterfaceAge(id: id, connectedAt: connectedAt))
                    let excess = state.departedInterfaceAges.count - Transport.maxDepartedInterfaceAges
                    if excess > 0 { state.departedInterfaceAges.removeFirst(excess) }
                }
                state.interfaceConnectedAt[id] = nil
                return .merge(.cancel(id: CancelID.announceDrain(id)),
                              .cancel(id: CancelID.ingressRelease(id)))

            case let .registerLocalDestination(destination, linkCost):
                // The cost it announces: absent means `LR_COST`, a re-registration replaces it.
                state.localLinkCosts[destination.hash] = linkCost.map(Transport.clampedLinkCost)
                // Registering a destination clears any app data stickily remembered for it. This is
                // ReTiCA's `Destination.clear_default_app_data()` (RNS/Destination.py:688-692), and
                // it is one of two clear paths (the other is `.deregisterLocalDestination`):
                // `.announce` never erases (see there), so without this a composition that stopped
                // advertising app data could keep replaying the previous one's forever, in both
                // announces and path responses.
                //
                // Unconditional on purpose. The former `if localDestinations[hash] == nil` guard
                // could never fire — on a first registration `localAppData[hash]` is already nil
                // (deregistration clears it with the entry), and on a re-registration the guard is
                // false. Every in-repo caller registers and announces in one `.merge`
                // (PNNode.swift `.registerPropagation`, LXMFServiceNode.swift `.registerPropagation`,
                // LXMFNode.swift `.registerDelivery`), and `.merge` delivers in order, so the clear
                // always precedes the announce that repopulates it. (Named by enclosing case rather
                // than by line: the previous revision's `LXMFNode.swift:91` had already rotted to
                // :201 within one slice.)
                state.localAppData[destination.hash] = nil
                // Announces and path responses still waiting for this destination's stamp were queued
                // for the previous registration (its app data, its interfaces); drop them as
                // deregistration does, so only what is announced after this registration goes out.
                // The search itself keeps running: its stamp is the destination's, not the app data's.
                state.pendingStampedAnnounces.removeAll { $0.destinationHash == destination.hash }
                state.localDestinations[destination.hash] = destination
                return .none

            case let .deregisterLocalDestination(destinationHash):
                // Every gate on a local destination reads `localDestinations` when a packet is
                // handled — DATA delivery, the LINKREQUEST hand-up, the path-request answer and
                // `.announce` — so removing the entry is the whole of it, apart from a destination
                // stamp search (below), the one thing scheduled per local destination: with
                // `stampDestinations` on, an announce can be held for its stamp. The app data goes
                // too, as `.registerLocalDestination` clears it, so a later re-registration starts clean.
                state.localDestinations[destinationHash] = nil
                state.localAppData[destinationHash] = nil
                state.localLinkCosts[destinationHash] = nil
                // Its stamp search, and what waited for it, would only ever be dropped: stop it. The
                // stamp itself is kept, so a re-registration need not mine again.
                state.pendingStampedAnnounces.removeAll { $0.destinationHash == destinationHash }
                guard state.stampingDestinations.remove(destinationHash) != nil else { return .none }
                return .cancel(id: CancelID.destinationStamp(destinationHash))

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

            case let .registerLocalLink(linkID):
                state.localLinkIDs.insert(linkID)
                return .none

            case let .unregisterLocalLink(linkID):
                state.localLinkIDs.remove(linkID)
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

            case let .rehydrateKnownDestinations(destinations):
                let now = date.now
                for (hash, candidate) in destinations {
                    guard candidate.lastHeard.timeIntervalSinceReferenceDate.isFinite,
                          candidate.lastHeard <= now,
                          now.timeIntervalSince(candidate.lastHeard) <= Transport.knownDestinationExpiry
                    else { continue }
                    // Our own destinations are never remembered from announces (see `.received`),
                    // so a stored row for one is foreign data: it must not shadow the local identity.
                    guard state.localDestinations[hash] == nil else { continue }
                    // The ratchet goes to `Identity.encrypt`, whose agreement is force-unwrapped, so
                    // restored bytes face the check `Announce.parse` applies to announced ones; and a
                    // ratchet is kept only with a finite, not future, unexpired receive time. A ratchet
                    // failing either is dropped and the row kept (its destination is then encrypted to
                    // by identity key until it announces a ratchet).
                    var ratchet: Data? = nil
                    var ratchetReceived: Date? = nil
                    if let restored = candidate.ratchet, let received = candidate.ratchetReceived,
                       received <= now, Transport.ratchetIsFresh(received: received, now: now),
                       Identity.isUsableRatchet(restored) {
                        ratchet = restored
                        ratchetReceived = received
                    }
                    // The ratchet is merged on its own terms, whichever entry wins: an announce without a
                    // ratchet does not clear one (Identity.py:726), so the entry that was heard last need
                    // not hold the newest ratchet. The ratchet received later wins, the live one on a
                    // tie. A live ratchet without a receive time counts as expired and loses.
                    let live = state.knownDestinations[hash]
                    var keptRatchet = live?.ratchet
                    var keptReceived = live?.ratchetReceived
                    let restoredIsNewer: Bool = {
                        guard let ratchetReceived else { return false }
                        guard keptRatchet != nil, let keptReceived else { return true }
                        return ratchetReceived > keptReceived
                    }()
                    if let ratchet, restoredIsNewer {
                        keptRatchet = ratchet
                        keptReceived = ratchetReceived
                    }
                    if var live, live.lastHeard >= candidate.lastHeard {
                        if live.ratchet != keptRatchet || live.ratchetReceived != keptReceived {
                            live.ratchet = keptRatchet
                            live.ratchetReceived = keptReceived
                            state.knownDestinations[hash] = live
                        }
                        continue
                    }
                    // Public-only, whatever the host handed back: this table never holds a private key.
                    guard let publicOnly = Identity(publicKey: candidate.identity.publicKey) else { continue }
                    state.knownDestinations[hash] = KnownDestination(
                        identity: publicOnly, appData: candidate.appData, lastHeard: candidate.lastHeard,
                        linkCost: candidate.linkCost, stampValue: candidate.stampValue,
                        ratchet: keptRatchet, ratchetReceived: keptReceived)
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
                    // A link we are an endpoint of is never relay traffic — fall through to local delivery.
                    // Without this, a reflected LINKREQUEST that tabled our own linkID would shadow us.
                    if !state.localLinkIDs.contains(packet.destinationHash),
                       let entry = state.linkTable[packet.destinationHash],
                       Int(packet.hops) + 1 < Int(Packet.maxHops) {
                        let outIf: InterfaceID
                        if interfaceID == entry.rcvdIf { outIf = entry.nhIf }        // toward dest
                        else if interfaceID == entry.nhIf { outIf = entry.rcvdIf }   // toward initiator
                        else { return .none }
                        // Reference refresh semantics: a link proof VALIDATES the entry (but does not refresh its
                        // timestamp); only forwarded DATA refreshes. Never refresh on proof/other, so junk cannot
                        // keep an unvalidated entry alive.
                        if packet.packetType == .proof, packet.context == .linkRequestProof {
                            state.linkTable[packet.destinationHash]?.validated = true
                        } else if packet.packetType == .data {
                            state.linkTable[packet.destinationHash]?.refreshedAt = date.now
                        }
                        var fwd = packet
                        fwd.hops = packet.hops + 1
                        guard let raw = try? fwd.packed() else { return .none }
                        return .send(.delegate(.transmit(outIf, raw)))
                    }
                    return .send(.delegate(.linkPacket(linkID: packet.destinationHash, arrivalInterface: interfaceID, data: plain)))
                }
                if packet.packetType == .linkRequest, state.localDestinations[packet.destinationHash] != nil {
                    // Enforcing, a request whose key falls short of the destination's link cost is
                    // dropped before the link plane sees it, so it costs one hash and no DH.
                    if state.enforceStamps {
                        let cost = state.localLinkCosts[packet.destinationHash] ?? NetworkStamp.defaultLinkRequestCost
                        guard Transport.linkRequestStampMeets(cost: cost, destinationHash: packet.destinationHash,
                                                              payload: packet.payload)
                        else { return .none }
                    }
                    return .send(.delegate(.linkRequest(destinationHash: packet.destinationHash,
                                                        arrivalInterface: interfaceID, data: plain)))
                }
                // Announces are deduped by per-destination random-blob (in the `.announce` case
                // below), NOT by packetHash: keying on the unforgeable-per-announce random_hash
                // prevents replays that mutate non-blob bytes (appData/signature/hops/transport_id)
                // from bypassing dedup, and matches RNS (Transport.py:1807/1824). Non-announce
                // packets keep packetHash dedup for loop protection.
                // Proofs are not deduped either: a proof is matched against `pendingReceipts`, and a
                // duplicate proof for a receipt already removed simply misses that lookup.
                if packet.packetType != .announce, packet.packetType != .proof {
                    guard state.seenPacketHashes.insert(packet.packetHash) else { return .none }
                }

                switch packet.packetType {
                case .announce:
                    // Don't learn a path to one of our own destinations.
                    guard state.localDestinations[packet.destinationHash] == nil else { return .none }
                    // Enforcing, an announce below the receiving interface's destination cost
                    // (`resolvedDestinationCost(on:)`) stops here: not learned, not
                    // remembered, not relayed, and not counted by ingress control below, as reference
                    // returns before `received_announce` (Transport.py:2046-2053). A C4-held announce
                    // replays through here and is checked again.
                    //
                    // The verdict cache answers for bytes judged before (reference consults its caches
                    // first, Identity.py:750-791): a refused announce is dropped unparsed, and a valid one
                    // skips the parse and signature but goes on through ingress control, the
                    // known-destination refresh, the replay check and the path logic below as before.
                    guard let parsed = state.announceVerdicts.resolve(
                        packet, cost: state.resolvedDestinationCost(on: interfaceID), enforce: state.enforceStamps)
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
                    // Remember the announced identity for `recall` — reference `Identity.remember`,
                    // reached from `validate_announce` for every signature-valid announce of a
                    // non-local destination that got past ingress limiting (Transport.py:1772,
                    // Identity.py:579), BEFORE the replay check, so a replay refreshes it too.
                    // The link cost and stamp value ride here too, as reference's `remember` stores
                    // `lr_cost` and `stamp_value` (Identity.py:109-124): an announce that does not win
                    // the path below still updates the cost a link to this destination must pay.
                    // The ratchet already known is carried over here and replaced below only by a
                    // fresh announce that brings one.
                    let previous = state.knownDestinations[packet.destinationHash]
                    state.knownDestinations[packet.destinationHash] = KnownDestination(
                        identity: parsed.identity, appData: parsed.appData, lastHeard: icNow,
                        linkCost: parsed.linkCost, stampValue: parsed.stampValue,
                        ratchet: previous?.ratchet, ratchetReceived: previous?.ratchetReceived)
                    // Anti-replay: a previously-seen random-blob for this destination is a replay.
                    // RingSet.insert both tests and records; false → already present → drop.
                    // NOTE: we record the blob for EVERY fresh announce here. RNS only appends the
                    // blob inside its `should_add` path-adopt branch (Transport.py:1934-1936); we
                    // remember more eagerly on purpose — a strict superset of RNS's anti-replay
                    // memory (never drops a fresh announce RNS keeps, never keeps a replay RNS drops).
                    // Do NOT narrow this to RNS's should_add gating: that would weaken anti-replay.
                    let emitted = Transport.announceEmitted(parsed.randomHash)
                    // Path-table next hop: relayed (HEADER_2) → its transport_id; directly heard → the dest.
                    let nextHop = packet.transportId ?? packet.destinationHash
                    let candidate = LearnedDestination(
                        identity: parsed.identity, appData: parsed.appData,
                        interfaceID: interfaceID, hops: packet.hops, nextHop: nextHop,
                        announceEmitted: emitted, learnedAt: date.now)
                    // A route whose interface is gone (a radio switched off, a BLE session ended)
                    // carries nothing, yet it is kept on purpose (see `reachableLearned`: TCP comes
                    // back under the same id). Kept, it must not outrank a live route: reference
                    // removes such a path outright, its random blobs with it (RNS 1.4.2 Transport.py:797-801),
                    // so an older or already-seen announce over a connected interface is adopted.
                    // Without this, a peer heard last over a radio that went away stayed unreachable
                    // until its next announce or for the 7-day expiry, every path response to the
                    // `requestPath` recovery being older than the dead route or a seen blob.
                    let strandedRoute = state.interfaces[interfaceID] != nil
                        && state.learned[packet.destinationHash].map { state.interfaces[$0.interfaceID] == nil } == true
                    var ring = state.announceBlobs[packet.destinationHash]
                        ?? RingSet(capacity: Transport.announceBlobRingSize)
                    guard ring.insert(parsed.randomHash) else {
                        if strandedRoute {
                            // A seen announce: adopt the live route, but never relay it again.
                            state.learned[packet.destinationHash] = candidate
                            state.announceCache[packet.destinationHash] = State.CachedAnnounce(
                                payload: packet.payload, contextFlag: packet.contextFlag)
                            return .send(.delegate(.pathLearned(destinationHash: packet.destinationHash,
                                                                hops: packet.hops)))
                        }
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

                    // Remember the announced ratchet (reference `_remember_ratchet`, reached from
                    // `__finalize_av` for every valid announce, Identity.py:726), before and apart from
                    // the path decision below, so an announce that loses the path still refreshes it.
                    // An announce without one (or whose ratchet failed the usability check in
                    // `Announce.parse`) leaves the known one. The same ratchet heard again keeps its
                    // first receive time, as reference's store does (Storage.py:429-451).
                    //
                    // After the replay check, where reference has it on every validation: a replayed
                    // announce brings a ratchet this table already took when the announce was fresh,
                    // or an older one, and taking it would put an old ratchet back over a newer one.
                    // Reference reaches the same result by another route for a replay its verdict
                    // cache still holds: a cache hit for a known destination skips
                    // `_remember_ratchet` (Identity.py:722). A replay it has evicted from that cache
                    // (128 entries) it validates again and remembers; this does not.
                    if let ratchet = parsed.ratchet,
                       var known = state.knownDestinations[packet.destinationHash],
                       known.ratchet != ratchet {
                        known.ratchet = ratchet
                        known.ratchetReceived = icNow
                        state.knownDestinations[packet.destinationHash] = known
                    }

                    var effects: [Effect<Action>] = []
                    // Update the path only if this fresh announce improves it, or the current one is
                    // stranded on an interface that is gone.
                    if strandedRoute || Transport.shouldReplace(state.learned[packet.destinationHash], with: candidate) {
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
                        // RNS 1.6.0 ingress (Transport.py:2081-2093) and parse_path_request
                        // (Transport.py:3983-4005). Only three sizes are accepted: 32 (legacy,
                        // destHash + tag), 48 (destHash + sender ID + tag) and 64 (the 48 plus the
                        // 16-byte stamp extension). Tagless (16), oversized and in-between sizes drop.
                        let payload = packet.payload
                        guard Transport.pathRequestLengths.contains(payload.count) else { return .none }
                        let requested = Data(payload.prefix(16))
                        let tag = payload.count == Transport.pathRequestLegacyLength
                            ? Data(payload.dropFirst(16).prefix(16))          // after destHash
                            : Data(payload.dropFirst(32).prefix(16))          // after destHash + sender ID
                        let requestorTransportId: Data? = payload.count >= Transport.pathRequestLength
                            ? Data(payload.dropFirst(16).prefix(16)) : nil
                        // Carried through unchanged by a relay, whatever it holds (Transport.py:3940).
                        // Validated only when enforcing: 1.6.0 does not enforce by default.
                        let extensionPayload: Data? = payload.count == Transport.pathRequestStampedLength
                            ? Data(payload.dropFirst(Transport.pathRequestLength)) : nil
                        // Entry gate: ignore duplicate (destHash ‖ tag) requests.
                        guard state.discoveryPrTags.insert(requested + tag) else { return .none }
                        // Enforcing, a request without a stamp meeting the receiving interface's
                        // path-request cost (`resolvedPathRequestCost(on:)`) is neither answered nor forwarded. After the tag gate, as in reference (Transport.py:2088-2129),
                        // so a refused request still uses up its tag.
                        if state.enforceStamps {
                            guard Transport.pathRequestStampMeets(cost: state.resolvedPathRequestCost(on: interfaceID),
                                                                  destinationHash: requested,
                                                                  tag: tag, extensionPayload: extensionPayload)
                            else { return .none }
                        }
                        // (1) We OWN the requested destination → answer with a fresh path-response.
                        if let dest = state.localDestinations[requested],
                           let identity = dest.identity, identity.privateKey != nil {
                            // App data, ratchet and rotation: see `emitPathResponse`.
                            guard state.stampDestinations else {
                                return emitPathResponse(dest, identity, on: interfaceID, stamp: nil, &state)
                            }
                            // Stamping: the response carries the same extension as our announces. With
                            // no stamp yet it waits for one, ahead of waiting announces (reference
                            // queues it at a higher priority, Transport.py:1455).
                            if let stamp = usableStamp(dest, identity, &state) {
                                return emitPathResponse(dest, identity, on: interfaceID, stamp: stamp, &state)
                            }
                            return waitForStamp(State.PendingStampedAnnounce(destinationHash: dest.hash,
                                                                             kind: .pathResponse(interface: interfaceID)),
                                                dest, identity, &state)
                        }
                        // (2) We are a relay that has learned + cached a path to the destination →
                        // re-emit the cached announce (verbatim payload, original signature) as a
                        // HEADER_2 pathResponse so the requester learns the destination via us.
                        // RNS Transport.py:2972-3033 (get_cached_packet + rebroadcast as path response).
                        if let relayID = state.transportIdentity,
                           let cached = state.announceCache[requested],
                           let entry = state.learned[requested],
                           Int(entry.hops) + 1 < Int(Packet.maxHops) {
                            // Loop guard: the requester's sender ID (48- and 64-byte payloads). If that
                            // equals our next hop toward the destination, the requester is already on
                            // our path — do not answer (RNS Transport.py:3833). A leaf's random
                            // `pathRequestSenderID` matches no real next hop.
                            guard requestorTransportId != entry.nextHop else { return .none }
                            // The flag comes from the CACHE, not from any parsed ratchet. The payload is
                            // the original announce's bytes, so the flag must describe those bytes:
                            // `Announce.parse` drops a ratchet it cannot key-agree with, leaving the
                            // 32 bytes in the payload but no ratchet remembered. See CachedAnnounce.
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
                            // The received extension rides along unchanged; a stamping relay marks an
                            // unstamped request leniently instead of mining a stamp for someone else's
                            // tag (Transport.py:3935-3936). No search here, so no added delay.
                            var forwarded = requested + relayID.hash + tag
                            if let extensionPayload {
                                forwarded.append(extensionPayload)
                            } else if state.stampPathRequests {
                                forwarded.append(Transport.lenientPathRequestExtension)
                            }
                            return transmitPathRequest(forwarded,
                                                       on: state.interfaces.keys.filter { $0 != interfaceID })
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
                    // With our own ratchets enabled, every retained ratchet is tried (newest first), then
                    // the identity key unless enforced — reference `Destination.decrypt`
                    // (Destination.py:720-752), minus its reload-from-disk retry: the ring here is the
                    // only copy in the process. An empty ring passes no ratchets, as reference does.
                    let own = state.ownRatchets[packet.destinationHash]
                    guard let destination = state.localDestinations[packet.destinationHash],
                          destination.kind == packet.destinationType,
                          let plaintext = destination.decrypt(packet.payload, ratchets: own?.ring,
                                                              enforceRatchets: own?.enforce ?? false)
                    else { return .none }
                    return .send(.delegate(.received(destinationHash: packet.destinationHash,
                                                     plaintext: plaintext,
                                                     packetHash: packet.packetHash,
                                                     interfaceID: interfaceID)))
                case .linkRequest:
                    // Relay: a HEADER_2 LINKREQUEST naming us as next hop, for a REMOTE destination, is
                    // forwarded toward the dest and a link_table entry is recorded for reverse routing.
                    if let relayID = state.transportIdentity, packet.headerType == .header2,
                       packet.transportId == relayID.hash,
                       state.localDestinations[packet.destinationHash] == nil {
                        guard let entry = state.learned[packet.destinationHash],
                              Int(packet.hops) + 1 < Int(Packet.maxHops) else { return .none }
                        let linkID = Link.linkID(requestPacket: packet)
                        // A reflection of our OWN LINKREQUEST carries our own linkID (hashablePart excludes
                        // header/transport fields), so it would otherwise table a shadow of our live link. Drop it.
                        guard !state.localLinkIDs.contains(linkID) else { return .none }
                        // Amended Contract 4: plus one MTU of airtime on the interface the request
                        // ARRIVED on (`interfaceID`, which is the link's `rcvdIf`), as reference does:
                        // `extra_link_proof_timeout(packet.receiving_interface)`
                        // (RNS/Transport.py:1643-1644, local 1.4.1 fork). Unknown bitrate → no extra.
                        state.linkTable[linkID] = State.LinkTableEntry(
                            rcvdIf: interfaceID, nhIf: entry.interfaceID, refreshedAt: date.now,
                            validated: false,
                            proofDeadline: date.now.addingTimeInterval(
                                Self.establishmentTimeoutPerHop * Double(max(1, entry.hops))
                                + LinkTiming.relayProofExtraTimeout(bitrate: state.interfaces[interfaceID]?.bitrate)))
                        guard let raw = forwardTowardDest(packet, entry) else { return .none }
                        return .send(.delegate(.transmit(entry.interfaceID, raw)))
                    }
                    return .none
                case .proof:
                    // A delivery proof for a single packet we sent with a receipt token (RNS
                    // Transport.py:2334-2360 → PacketReceipt.validate_proof, Packet.py:480-515). It is
                    // addressed to our packet's ProofDestination, `packetHash[:16]`, which is exactly
                    // the `pendingReceipts` key — so where reference tries an implicit proof against
                    // every outstanding receipt, one lookup finds the only candidate.
                    guard packet.destinationType == .single,
                          let receipt = state.pendingReceipts[packet.destinationHash]
                    else { return .none }
                    let valid: Bool
                    switch packet.payload.count {
                    case Transport.implicitProofLength:
                        valid = receipt.identity.validate(signature: packet.payload, message: receipt.packetHash)
                    case Transport.explicitProofLength:
                        valid = packet.payload.prefix(32) == receipt.packetHash
                            && receipt.identity.validate(signature: Data(packet.payload.suffix(64)),
                                                         message: receipt.packetHash)
                    default:
                        valid = false
                    }
                    // A bad proof leaves the receipt in place, so a later genuine proof still confirms.
                    guard valid else { return .none }
                    state.pendingReceipts[packet.destinationHash] = nil
                    return .send(.delegate(.singlePacketDelivered(token: receipt.token)))
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
                // Known destinations outlive their path; one goes only once it is pathless AND
                // unheard for `knownDestinationExpiry` (reference `clean_known_destinations`,
                // Identity.py:285-338 — see the constant for the divergence).
                for (dest, known) in state.knownDestinations
                where state.learned[dest] == nil
                    && now.timeIntervalSince(known.lastHeard) > Transport.knownDestinationExpiry {
                    state.knownDestinations[dest] = nil
                }
                // A ratchet first heard more than `ratchetExpiry` ago is cleared (reference
                // `expire_ratchets` / `_clean_ratchets`, Identity.py:465-470, 578-615). `recallRatchet`
                // already ignores it; this keeps it from sitting in state for the host to persist.
                for (dest, known) in state.knownDestinations where known.ratchet != nil
                    && !(known.ratchetReceived.map { Transport.ratchetIsFresh(received: $0, now: now) } ?? false) {
                    state.knownDestinations[dest]?.ratchet = nil
                    state.knownDestinations[dest]?.ratchetReceived = nil
                }
                for (link, entry) in Array(state.linkTable) {
                    let expired = entry.validated
                        ? now.timeIntervalSince(entry.refreshedAt) > Transport.linkTableExpiry
                        : now > entry.proofDeadline
                    if expired { state.linkTable[link] = nil }
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
                // Expired receipts go silently: the LXMF retry timer is the only failure authority,
                // so reporting expiry here would double the retries (spec §2).
                state.pendingReceipts = state.pendingReceipts.filter { $0.value.expiresAt > now }
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

            case let .send(destinationHash, plaintext, receiptToken):
                guard let entry = state.learned[destinationHash] else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .notLearned)))
                }
                guard state.reachableLearned(destinationHash) != nil else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .interfaceUnavailable)))
                }
                // To the destination's ratchet while one is fresh, as reference `Destination.encrypt`
                // does for every SINGLE destination (Destination.py:694-708).
                let ciphertext = entry.identity.encrypt(
                    plaintext, ratchet: state.recallRatchet(destinationHash: destinationHash, now: date.now))
                let packet: Packet
                if let nh = entry.relayNextHop(toward: destinationHash) {
                    // Destination is reached via a relay → send HEADER_2 to the next hop.
                    packet = Packet(headerType: .header2, packetType: .data, transportType: .transport,
                                    destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: destinationHash, transportId: nh, payload: ciphertext)
                } else {
                    // Directly reachable, or a local client of the next hop → HEADER_1
                    // (`LearnedDestination.relayNextHop`).
                    packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                    destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: destinationHash, transportId: nil, payload: ciphertext)
                }
                guard let raw = try? packet.packed() else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .tooLarge)))
                }
                if let receiptToken {
                    let hopTimeout = Transport.receiptTimeoutPerHop * Double(max(1, entry.hops))
                    Transport.recordReceipt(State.PendingReceipt(
                        packetHash: packet.packetHash, token: receiptToken, identity: entry.identity,
                        expiresAt: date.now.addingTimeInterval(Transport.receiptTimeoutBase + hopTimeout)),
                                            in: &state)
                }
                return .send(.delegate(.transmit(entry.interfaceID, raw)))

            case let .announce(destinationHash, appData, interface):
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
                //
                // Stamping off (the default): sent at once, byte for byte as before.
                guard state.stampDestinations else {
                    return emitAnnounce(dest, identity, appData: appData, interface: interface, stamp: nil, &state)
                }
                if let stamp = usableStamp(dest, identity, &state) {
                    return emitAnnounce(dest, identity, appData: appData, interface: interface, stamp: stamp, &state)
                }
                // No stamp yet: the announce waits for one (reference `enqueue_stamped_announce`,
                // Destination.py:297-301). Its sticky app data is captured NOW, so a path response
                // released ahead of it replays it — but only if the stamped announce will pack, for
                // the reason above. Any 14 bytes give the same length as the real stamp, and any 32 the
                // same length as the ratchet the announce will carry when it is released.
                let announcedAppData = appData ?? state.localAppData[destinationHash]
                guard announceBytes(dest, identity, appData: announcedAppData,
                                    stamp: Data(count: NetworkStamp.stampLength),
                                    ratchet: ratchetPlaceholder(destinationHash, state), pathResponse: false, state) != nil
                else { return .none }
                if let appData { state.localAppData[destinationHash] = appData }
                return waitForStamp(State.PendingStampedAnnounce(destinationHash: destinationHash,
                                                                 kind: .announce(appData: appData, interface: interface)),
                                    dest, identity, &state)

            case let .requestPath(destinationHash):
                // RNS 1.6.0 request_path (Transport.py:3685-3722): payload = destHash + sender ID + tag,
                // always 48 bytes (Transport.py:3699). Record this request so that an arriving
                // path-response announce for this destination is exempt from ingress-control holding
                // (RNS Transport.path_requests). This is the LOCAL gate entry (leaf+relay);
                // discoveryPathRequests is relay-only. It is set BEFORE any stamp search, as reference
                // sets it before enqueueing one (Transport.py:3714).
                state.pathRequests[destinationHash] = date.now
                let tag = randomBytes(16)                              // request tag (RNS get_random_hash)
                let senderID: Data
                if let identityHash = state.transportIdentity?.hash {
                    senderID = identityHash
                } else if let held = state.pathRequestSenderID {
                    senderID = held
                } else {
                    senderID = randomBytes(16)
                    state.pathRequestSenderID = senderID
                }
                let request = destinationHash + senderID + tag
                // Stamping off (the default): sent at once, exactly as before.
                guard state.stampPathRequests else {
                    return transmitPathRequest(request, on: Array(state.interfaces.keys))
                }
                // Reference queues one stamp job per destination (enqueue_stamped_pr keys its queue
                // by destination, Transport.py:1466-1468): a search already running for it answers
                // this request too.
                guard state.stampingPathRequests[destinationHash] == nil else { return .none }
                // Nothing to send on: no search either (the pending entry above stays).
                guard !state.interfaces.isEmpty else { return .none }
                state.stampingPathRequests[destinationHash] = tag
                let material = destinationHash + tag                    // pr_stamp_material
                let cost = state.pathRequestValue
                return .run { send in
                    // Whichever ends first: the search, or `pathStampTimeout` (reference's
                    // `stamp_watchdog`, Transport.py:4028-4033). The loser is cancelled; `generate`
                    // stops within its yield interval of that.
                    let stamp = await withTaskGroup(of: Data?.self) { group in
                        group.addTask { await NetworkStamp.generate(material: material, cost: cost)?.stamp }
                        group.addTask {
                            try? await clock.sleep(for: .seconds(NetworkStamp.pathStampTimeout))
                            return nil
                        }
                        let first = await group.next() ?? nil
                        group.cancelAll()
                        return first
                    }
                    // Cancelled from outside (`.cancelPathRequestStamps`): nothing to report.
                    guard !Task.isCancelled else { return }
                    let stamped = stamp.flatMap { stamp in
                        stamp.count == NetworkStamp.stampLength
                            ? request + Data([NetworkStamp.extensionMarker, Transport.pathRequestStampFlags]) + stamp
                            : nil
                    }
                    await send(.pathRequestStampSearchEnded(destinationHash: destinationHash, tag: tag, request: stamped))
                }
                .cancellable(id: CancelID.pathRequestStamp(destinationHash))

            case let .pathRequestStampSearchEnded(destinationHash, tag, request):
                // Cancelled meanwhile (`.cancelPathRequestStamps`): the search no longer counts. A
                // cancelled search's end can already be queued when a re-request starts a new search
                // for the same destination; only the end carrying the recorded search's tag counts.
                guard state.stampingPathRequests[destinationHash] == tag else { return .none }
                state.stampingPathRequests[destinationHash] = nil
                // Ran out `pathStampTimeout`: reference logs and sends nothing (Transport.py:4038-4041).
                guard let request else { return .none }
                return transmitPathRequest(request, on: Array(state.interfaces.keys))

            case .cancelPathRequestStamps:
                let cancelled = state.stampingPathRequests.keys
                state.stampingPathRequests = [:]
                return .merge(cancelled.map { .cancel(id: CancelID.pathRequestStamp($0)) })

            case let .rehydrateDestinationStamp(destinationHash, stamp):
                guard stamp.count == NetworkStamp.stampLength else { return .none }
                state.destinationStamps[destinationHash] = stamp
                // A search already running for it (the host's read landed after the first announce):
                // if this stamp is good enough, it ends the search and releases what waited.
                guard state.stampingDestinations.contains(destinationHash),
                      let dest = state.localDestinations[destinationHash],
                      let identity = dest.identity, identity.privateKey != nil,
                      let usable = usableStamp(dest, identity, &state)
                else { return .none }
                state.stampingDestinations.remove(destinationHash)
                return .merge(.cancel(id: CancelID.destinationStamp(destinationHash)),
                              releaseWaiting(destinationHash, stamp: usable, &state))

            case let .destinationStampSearchEnded(destinationHash, stamp, value):
                // Cancelled meanwhile: the search no longer counts.
                guard state.stampingDestinations.remove(destinationHash) != nil else { return .none }
                // A search reports once, as its effect's last act; cancelling here only stops a stray.
                let stop = Effect<Action>.cancel(id: CancelID.destinationStamp(destinationHash))
                guard let stamp, stamp.count == NetworkStamp.stampLength else {
                    // Ended without a stamp: what waited is dropped, as reference drops an announce
                    // whose stamp generation fails (Destination.py:349-351).
                    state.pendingStampedAnnounces.removeAll { $0.destinationHash == destinationHash }
                    return stop
                }
                state.destinationStamps[destinationHash] = stamp
                return .merge(stop,
                              .send(.delegate(.destinationStampGenerated(destinationHash: destinationHash,
                                                                         stamp: stamp, value: value))),
                              releaseWaiting(destinationHash, stamp: stamp, &state))

            case .cancelDestinationStamps:
                let cancelled = state.stampingDestinations
                state.stampingDestinations = []
                state.pendingStampedAnnounces.removeAll { cancelled.contains($0.destinationHash) }
                return .merge(cancelled.map { .cancel(id: CancelID.destinationStamp($0)) })

            case let .proveSingle(packetHash, interfaceID, identity):
                guard identity.privateKey != nil, state.interfaces[interfaceID] != nil else { return .none }
                let proof = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                                   destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                   destinationHash: Data(packetHash.prefix(Packet.addressLength)),
                                   transportId: nil, payload: identity.sign(packetHash))
                guard let raw = try? proof.packed() else { return .none }
                return .send(.delegate(.transmit(interfaceID, raw)))

            case let .enableRatchets(destinationHash, ring):
                // A restored entry that is not a 32-byte private key is dropped, so it is never
                // announced nor tried. Ring order is the host's (newest first).
                let usable = ring.filter { Identity.ratchetPublicKey(privateKey: $0) != nil }
                state.ownRatchets[destinationHash] = State.OwnRatchets(
                    ring: Array(usable.prefix(Transport.ratchetCount)), lastRotation: nil,
                    enforce: state.ownRatchets[destinationHash]?.enforce ?? false)
                // The app data captured for this destination was checked against an announce without
                // a ratchet. One that no longer fits would silence every later announce without app
                // data and every path response (see `.announce`), so it is forgotten here.
                if let captured = state.localAppData[destinationHash],
                   let dest = state.localDestinations[destinationHash],
                   let identity = dest.identity, identity.privateKey != nil,
                   announceBytes(dest, identity, appData: captured,
                                 stamp: state.stampDestinations ? Data(count: NetworkStamp.stampLength) : nil,
                                 ratchet: ratchetPlaceholder(destinationHash, state),
                                 pathResponse: false, state) == nil {
                    state.localAppData[destinationHash] = nil
                }
                return .none

            case let .setEnforceRatchets(destinationHash, enforce):
                guard state.ownRatchets[destinationHash] != nil else { return .none }
                state.ownRatchets[destinationHash]?.enforce = enforce
                return .none

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

    /// How long a PATHLESS known destination is kept after its last announce: reference
    /// `DESTINATION_TIMEOUT * 1.25` (Identity.py:328), 8.75 days. `public` for the same reason as
    /// `pathExpiry`: a host persisting `knownDestinations` prunes its copy on the same terms.
    ///
    /// DIVERGENCE: reference measures from the last USE (`_used_destination_data`, stamped by
    /// `recall` and by traffic) and drops a never-used pathless entry after only
    /// `UNUSED_DESTINATION_LINGER` (6 minutes). ReTiCA's `recall` is a pure read of reducer state and
    /// cannot stamp a use, so it measures from the last announce for every entry — more retentive
    /// for a hash heard once and recalled days later (the case recall exists for), never less.
    public static let knownDestinationExpiry: TimeInterval = pathExpiry * 1.25
    /// How long a peer's ratchet is used after it was first heard: reference `RATCHET_EXPIRY`
    /// (RNS 1.6.0 Identity.py:72), 30 days. Past it `recallRatchet` answers nil and
    /// `maintenanceTick` clears it. `public` so a host persisting ratchets prunes on the same terms.
    /// A known destination culled earlier (`knownDestinationExpiry`) takes its ratchet with it, as
    /// reference's `clean_known_destinations` does (Identity.py:455).
    public static let ratchetExpiry: TimeInterval = 60 * 60 * 24 * 30
    /// How many of our own ratchets a destination keeps: reference `RATCHET_COUNT`
    /// (RNS 1.6.0 Destination.py:87-94), 512. Older ones fall off the ring at rotation.
    public static let ratchetCount = 512
    /// The minimum time between rotations of our own ratchets: reference `RATCHET_INTERVAL`
    /// (Destination.py:87-94), 30 minutes. Rotation happens only when announcing.
    public static let ratchetInterval: TimeInterval = 30 * 60
    /// A ratchet key's length, private or public (X25519): reference `RATCHETSIZE / 8`.
    public static let ratchetKeyLength = 32
    /// Whether a ratchet first heard at `received` is still usable at `now`. A non-finite time is not.
    static func ratchetIsFresh(received: Date, now: Date) -> Bool {
        let age = now.timeIntervalSince(received)
        return age.isFinite && age <= ratchetExpiry
    }
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

    /// Bound on `State.departedInterfaceAges`: remote churn (TCP-server connections, BLE peers)
    /// mints ids, so the record of departed ones must not grow without limit.
    static let maxDepartedInterfaceAges = 64

    /// A departed interface's original connect time (see `State.departedInterfaceAges`).
    public struct DepartedInterfaceAge: Equatable, Sendable {
        public var id: InterfaceID
        public var connectedAt: Date
        public init(id: InterfaceID, connectedAt: Date) {
            self.id = id
            self.connectedAt = connectedAt
        }
    }
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
    /// RNS ESTABLISHMENT_TIMEOUT_PER_HOP (Link.py). An unvalidated relay entry gets a hard deadline
    /// of now + this * max(1, hops-to-dest); if no proof flows through by then it is reaped, so junk
    /// LINKREQUESTs cannot accumulate. Plus `LinkTiming.relayProofExtraTimeout` of the interface the
    /// request arrived on.
    static let establishmentTimeoutPerHop: TimeInterval = LinkTiming.establishmentTimeoutPerHop
    /// Single-packet receipt lifetime: `receiptTimeoutBase + receiptTimeoutPerHop * max(1, hops)`.
    /// Reference: `PacketReceipt.timeout = first_hop_timeout + TIMEOUT_PER_HOP * hops_to(dest)`
    /// (Packet.py:417-418), where `first_hop_timeout` is `DEFAULT_PER_HOP_TIMEOUT` (6 s) plus a
    /// link-latency term ReTiCA does not track (Transport.py:2788-2791) and `TIMEOUT_PER_HOP` is
    /// also `DEFAULT_PER_HOP_TIMEOUT` (Reticulum.py:142). ReTiCA's learned `hops` is the announce's
    /// on-wire count (reference increments it on receipt), so `max(1, hops)` matches reference for a
    /// directly-heard peer and is one hop short for a relayed one. Harmless: an expired receipt emits
    /// nothing, because the LXMF retry timer is the only failure authority.
    static let receiptTimeoutBase: TimeInterval = 6
    static let receiptTimeoutPerHop: TimeInterval = 6
    /// RNS `MAX_RECEIPTS` (Transport.py:96). Reference culls the OLDEST receipt past the cap
    /// (Transport.py:570-575); ReTiCA evicts the one expiring soonest, which is the one least
    /// likely to still be proved.
    static let maxPendingReceipts = 1024
    /// RNS `PacketReceipt.IMPL_LENGTH` (Packet.py:399): an implicit proof is the bare signature.
    static let implicitProofLength = 64
    /// RNS `PacketReceipt.EXPL_LENGTH` (Packet.py:398): packet hash (32) ‖ signature (64).
    static let explicitProofLength = 96

    /// Record `receipt` under `packetHash.prefix(16)`, evicting the soonest-expiring entry when a
    /// NEW key would exceed `maxPendingReceipts`.
    static func recordReceipt(_ receipt: State.PendingReceipt, in state: inout State) {
        let key = Data(receipt.packetHash.prefix(Packet.addressLength))
        if state.pendingReceipts[key] == nil,
           state.pendingReceipts.count >= maxPendingReceipts,
           let soonest = state.pendingReceipts.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            state.pendingReceipts[soonest] = nil
        }
        state.pendingReceipts[key] = receipt
    }
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

    /// RNS PR_LEGACY_LENGTH: destination + tag, from a pre-1.6 leaf.
    static let pathRequestLegacyLength = 32
    /// RNS PR_LENGTH: destination + sender (transport) ID + tag.
    static let pathRequestLength = 48
    /// RNS PR_STAMPED_LENGTH: `pathRequestLength` plus the 16-byte extension (marker, flags, stamp).
    static let pathRequestStampedLength = pathRequestLength + 2 + NetworkStamp.stampLength
    /// The only path-request sizes reference accepts (Transport.py:2081-2093). Anything else is a
    /// protocol violation and is dropped, a size above `pathRequestStampedLength` included.
    static let pathRequestLengths: Set<Int> = [pathRequestLegacyLength, pathRequestLength, pathRequestStampedLength]
    /// Extension flags for a real stamp (Transport.py:3721).
    static let pathRequestStampFlags: UInt8 = 0x00
    /// The extension a stamping relay puts on an unstamped request it forwards, so the next hop can
    /// tell it came from a stamp-aware node: marker, flags `0xFF`, 14 zero bytes (Transport.py:3935-3936).
    static let lenientPathRequestExtension =
        Data([NetworkStamp.extensionMarker, 0xFF]) + Data(repeating: 0, count: NetworkStamp.stampLength)

    /// True when a path request's 16-byte extension holds a stamp meeting `cost` over
    /// `destinationHash + tag` (Transport.py:2099-2105, `validate_pr_stamp` 4012-4016). No extension, a
    /// wrong marker or a short stamp is false; the lenient mark's 14 zero bytes are judged like any
    /// stamp. One SHA-256.
    static func pathRequestStampMeets(cost: Double, destinationHash: Data, tag: Data, extensionPayload: Data?) -> Bool {
        guard let ext = extensionPayload, ext.count == 2 + NetworkStamp.stampLength,
              ext.first == NetworkStamp.extensionMarker else { return false }
        return NetworkStamp.isValid(stamp: Data(ext.dropFirst(2)), cost: cost, material: destinationHash + tag)
    }

    /// LINKREQUEST payload sizes reference reads, keys alone or with MTU signalling (Link.py:188).
    static let linkRequestPayloadLengths: Set<Int> = [64, 67]

    /// True when a LINKREQUEST's X25519 key, the stamp, meets `cost` over `destinationHash` plus the
    /// request's Ed25519 key (Link.py:190-195). Any other payload size is false. One SHA-256.
    static func linkRequestStampMeets(cost: Double, destinationHash: Data, payload: Data) -> Bool {
        guard linkRequestPayloadLengths.contains(payload.count) else { return false }
        let bytes = Data(payload)                       // zero-based, whatever slice it came from
        let x25519 = Data(bytes.prefix(32))
        let ed25519 = Data(bytes.dropFirst(32).prefix(32))
        return NetworkStamp.isValid(stamp: x25519, cost: cost, material: destinationHash + ed25519)
    }

    /// Extension flags on our announce stamps (reference `get_ext_flags`, Destination.py:384-385).
    static let destinationStampFlags: UInt8 = 0x00
    /// RNS STAMPER_AN_QUEUE_LENGTH (Transport.py:210): announces that may wait for a stamp.
    public static let stampedAnnounceQueueLimit = 32
    /// RNS STAMPER_PR_QUEUE_LENGTH (Transport.py:209): path responses that may wait for a stamp.
    public static let stampedPathResponseQueueLimit = 32
    /// Most announces (and, separately, path responses) one destination may have queued for its stamp.
    /// ReTiCA's own bound inside the two limits above.
    public static let stampedQueuePerDestinationLimit = 8

    /// `destinationValue` as reference's config parser clamps `destination_value`
    /// (Reticulum.py:529-531): 0...`NetworkStamp.stampCostCap`. NaN reads as 0, as Python's
    /// `max(0, min(nan, cap))` does.
    public static func clampedDestinationValue(_ value: Double) -> Double {
        value.isNaN ? 0 : min(max(value, 0), Double(NetworkStamp.stampCostCap))
    }

    /// A local destination's link cost as reference `set_link_cost` clamps it (Destination.py:399-405):
    /// 0...`NetworkStamp.linkCostCap`, NaN to 0.
    static func clampedLinkCost(_ cost: Double) -> Double {
        cost.isNaN ? 0 : min(max(cost, 0), Double(NetworkStamp.linkCostCap))
    }

    /// The 18-byte announce extension (Destination.py:353-354): marker, flags, the stamp, then the
    /// link cost's fixed-point bytes REVERSED, fraction byte first and integer byte last, the order
    /// `Announce.readStampExtension` (and reference `validate_announce`) reads them back in.
    /// `fixedPoint(cost:)` clamps to 0...`stampCostCap` * 256, so both bytes fit without trapping.
    static func destinationStampExtension(stamp: Data, linkCost: Double) -> Data {
        let fp = NetworkStamp.fixedPoint(cost: linkCost)
        return Data([NetworkStamp.extensionMarker, destinationStampFlags]) + stamp
            + Data([UInt8(fp & 0xFF), UInt8((fp >> 8) & 0xFF)])
    }

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
