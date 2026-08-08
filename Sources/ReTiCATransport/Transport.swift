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
        public var learned: [Data: LearnedDestination] = [:]
        public var interfaces: [InterfaceID: InterfaceProfile] = [:]
        public var transportIdentity: Identity? = nil
        var seenPacketHashes = RingSet()
        public var linkTable: [Data: LinkTableEntry] = [:]
        /// Per-destination ring of recently-seen announce random-blobs (the 10-byte announce
        /// random_hash). Replaces packetHash dedup for announces: a repeated blob is a replay
        /// (RNS Transport.py:1824 `not random_blob in random_blobs`). Bounded to
        /// `announceBlobRingSize` per destination (RNS MAX_RANDOM_BLOBS).
        public var announceBlobs: [Data: RingSet] = [:]
        /// destHash → the announce payload (carries the destination's valid signature)
        /// for the currently-learned path. Enables a relay to re-emit a cached announce as
        /// a path response (RNS get_cached_packet, Transport.py:2973). GC'd with the path.
        public var announceCache: [Data: Data] = [:]

        /// unique_tag (destHash ‖ tag) ring for PATH_REQUEST dedup — a duplicate tagged request is
        /// ignored rather than re-answered (RNS discovery_pr_tags, Transport.py:2924-2934). Bounded
        /// (auto-evicts oldest at capacity), so no separate GC pass.
        public var discoveryPrTags = RingSet(capacity: Transport.pathRequestTagRingSize)

        /// Opt-in: when set (and in relay mode), a PATH_REQUEST for an unknown destination is
        /// re-broadcast onward for recursive discovery (RNS recursive_prs, Transport.py:2946).
        public var recursivePathRequests = false

        /// destHash → when a recursive search for it began. Coalesces concurrent searches for the
        /// same destination; GC'd after pathRequestTimeout (RNS discovery_path_requests, Transport.py:3060).
        public var discoveryPathRequests: [Data: Date] = [:]

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

        public init() {}

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

    public enum SendFailure: Equatable, Sendable { case notLearned, tooLarge }

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
        case startMaintenance
        case stopMaintenance
        case maintenanceTick
        case delegate(Delegate)

        @CasePathable
        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: SendFailure)
            case linkPacket(linkID: Data, data: Data)
            case linkRequest(destinationHash: Data, arrivalInterface: InterfaceID, data: Data)
        }
    }

    @Dependency(\.transportDate) var date
    @Dependency(\.continuousClock) var clock
    @Dependency(\.randomBytes) var randomBytes

    private enum CancelID: Hashable {
        case announceRetransmit(Data); case maintenance; case announceDrain(InterfaceID)
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
                return .none

            case let .interfaceDisconnected(id):
                state.interfaces[id] = nil
                state.announceAllowedAt[id] = nil
                state.announceQueues[id] = nil
                return .cancel(id: CancelID.announceDrain(id))

            case let .registerLocalDestination(destination):
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
                        state.linkTable[packet.destinationHash]?.refreshedAt = date.now   // keep active links alive
                        var fwd = packet
                        fwd.hops = packet.hops + 1
                        guard let raw = try? fwd.packed() else { return .none }
                        return .send(.delegate(.transmit(outIf, raw)))
                    }
                    return .send(.delegate(.linkPacket(linkID: packet.destinationHash, data: data)))
                }
                if packet.packetType == .linkRequest, state.localDestinations[packet.destinationHash] != nil {
                    return .send(.delegate(.linkRequest(destinationHash: packet.destinationHash,
                                                        arrivalInterface: interfaceID, data: data)))
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
                        state.announceCache[packet.destinationHash] = packet.payload
                        effects.append(.send(.delegate(.pathLearned(
                            destinationHash: packet.destinationHash, hops: packet.hops))))
                    }
                    // Relay mode: instead of re-broadcasting now, HOLD this fresh announce and
                    // re-broadcast it once after a jittered delay in [0, PATHFINDER_RW) — RNS
                    // Transport.py:1925. Only schedule when there is somewhere to send it.
                    let arrivalMode = state.interfaces[interfaceID]?.mode
                    if let relayID = state.transportIdentity,
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
                            let respPayload = Announce.buildPayload(identity: identity, destinationHash: dest.hash,
                                                                    nameHash: dest.nameHash, randomHash: randomHash,
                                                                    ratchet: nil, appData: nil)
                            let response = Packet.announce(from: dest, payload: respPayload, pathResponse: true)
                            guard let raw = try? response.packed() else { return .none }
                            return .send(.delegate(.transmit(interfaceID, raw)))
                        }
                        // (2) We are a relay that has learned + cached a path to the destination →
                        // re-emit the cached announce (verbatim payload, original signature) as a
                        // HEADER_2 pathResponse so the requester learns the destination via us.
                        // RNS Transport.py:2972-3033 (get_cached_packet + rebroadcast as path response).
                        if let relayID = state.transportIdentity,
                           let cachedPayload = state.announceCache[requested],
                           let entry = state.learned[requested],
                           Int(entry.hops) + 1 < Int(Packet.maxHops) {
                            // Loop guard: a relay requester carries its transport_id (48-byte payload).
                            // If that equals our next hop toward the destination, the requester is
                            // already on our path — do not answer (RNS Transport.py:2987).
                            let requestorTransportId: Data? = packet.payload.count > 32
                                ? Data(packet.payload.dropFirst(16).prefix(16)) : nil
                            guard requestorTransportId != entry.nextHop else { return .none }
                            let response = Packet(
                                headerType: .header2, packetType: .announce, transportType: .transport,
                                destinationType: .single, context: .pathResponse,
                                contextFlag: entry.ratchet != nil, hops: entry.hops + 1,
                                destinationHash: requested, transportId: relayID.hash, payload: cachedPayload)
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
                return .merge(state.interfaces.keys.map { .send(.delegate(.transmit($0, raw))) })

            case let .requestPath(destinationHash):
                // RNS request_path (Transport.py:2799): a DATA/BROADCAST/HEADER_1 packet to the
                // well-known PLAIN control destination; payload = destHash [+ our transport_id] + tag.
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

    /// RNS DESTINATION_TIMEOUT (Transport.py:91): learned paths expire after one week unused, seconds.
    static let pathExpiry: TimeInterval = 60 * 60 * 24 * 7      // 604800
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

    /// RNS LINK_TIMEOUT (Transport.py:89 = Link.STALE_TIME * 1.25 = (STALE_FACTOR*KEEPALIVE)*1.25).
    static let linkTableExpiry: TimeInterval = 900              // 720 * 1.25
    /// RNS PATH_REQUEST_TIMEOUT (Transport.py:79): in-flight recursive path searches expire, seconds.
    static let pathRequestTimeout: TimeInterval = 15
    /// Sweep cadence — a local tuning constant (NOT wire-visible, NOT cross-validated).
    static let maintenanceTickInterval: TimeInterval = 60

    /// RNS Transport path-request control destination: PLAIN "rnstransport"/["path","request"]
    /// (Transport.py:61,256). Deterministic (no identity). Cross-validated against genuine RNS.
    static let pathRequestDestinationHash: Data =
        Destination.hash(identityHash: nil, appName: "rnstransport", aspects: ["path", "request"])

    static let pathRequestTagRingSize = 32000      // RNS max_pr_tags (Transport.py:127)
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
