import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// A node that is BOTH an LXMF client and (optionally) an LXMF propagation node over ONE endpoint —
/// the shape reference LXMF uses: one identity, one connection, both destinations registered.
///
/// Composes the unchanged `LXMFNode` (client; owns the `TransportEndpoint`) with the unchanged
/// `PropagationNode` (store + serve logic), adding only the translation between the endpoint's inbound
/// delegates and the propagation node's actions. Every serve behavior is gated on `nodeModeEnabled`, so
/// with node-mode off this behaves exactly like a bare `LXMFNode`.
///
/// Serve scope is client-facing only (register/announce, ingest offers, two-phase `/get`). PN↔PN mesh
/// peering and time-based expiry are out of scope — see `PNNode` for the peering path. Inbound proving
/// of PACKET-framed propagation offers is in scope and lives at the `.linkDataReceived` handler below
/// (reference LXMRouter.py:2255); Resource-framed offers are proved by the resource transfer protocol.
@Reducer
public struct LXMFServiceNode {
    @ObservableState
    public struct State: Equatable {
        public var client: LXMFNode.State
        public var pn: PropagationNode.State
        /// While false, nothing is registered, ingested, or served.
        public var nodeModeEnabled: Bool = false
        /// linkID → the IDENTIFY'd remote client on that link. A `/get` without one is dropped.
        public var clientIdentities: [Data: Identity] = [:]
        /// client delivery hash → FIFO queue of in-flight /get requests. Clients can tear down and
        /// retry (reference LXMessage.py:616-621), so concurrent /gets from the same identity are
        /// possible. Using a queue per key prevents the second request from silently overwriting the
        /// first (the first's linkID would be lost and its response never sent).
        public var pendingGet: [Data: [PendingGet]] = [:]

        /// 32 MB — a mobile-appropriate cap for the store-and-forward backlog.
        public static let defaultStorageLimitBytes: Int = 32 * 1024 * 1024

        public init(identity: Identity, endpoint: TransportEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    minStampCost: Int = LXMFPropagation.defaultPropagationStampCost) {
            self.client = LXMFNode.State(identity: identity, endpoint: endpoint)
            self.pn = PropagationNode.State(storageLimitBytes: storageLimitBytes, minStampCost: minStampCost)
        }

        /// Convenience: run this node over TCP.
        public init(identity: Identity, endpoint: TCPEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    minStampCost: Int = LXMFPropagation.defaultPropagationStampCost) {
            self.init(identity: identity, endpoint: .tcp(endpoint),
                      storageLimitBytes: storageLimitBytes, minStampCost: minStampCost)
        }

        /// Convenience: run this node over BLE.
        public init(identity: Identity, endpoint: BLEEndpoint.State,
                    storageLimitBytes: Int? = State.defaultStorageLimitBytes,
                    minStampCost: Int = LXMFPropagation.defaultPropagationStampCost) {
            self.init(identity: identity, endpoint: .ble(endpoint),
                      storageLimitBytes: storageLimitBytes, minStampCost: minStampCost)
        }
    }

    public struct PendingGet: Equatable {
        public var linkID: Data
        public var requestID: Data
    }

    public enum Action: Equatable {
        case client(LXMFNode.Action)
        case pn(PropagationNode.Action)
        case registerPropagation
        case setNodeMode(Bool)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            /// Entries just accepted into the store — the host persists these.
            case messagesStored(entries: [PropagationStore.Entry])
            /// Entries just removed — the host deletes its mirrored copies.
            case messagesPurged(transientIds: [Data])
        }
    }

    @Dependency(\.date) var date
    public init() {}

    private static func arrayOfBin(_ value: MsgPackValue) -> [Data] {
        guard case let .array(items) = value else { return [] }
        return items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
    }

    /// The `/get` per-transfer cap in bytes, from a floating-point `data[2]` in kilobytes.
    ///
    /// Shared by the `.double` (float64, 0xCB) and `.float` (float32, 0xCA) branches of the
    /// transfer-limit switch, deliberately: they had drifted apart once already — `.float` was simply
    /// missing, so a float32 cap fell to `default: break` and became nil = NO CAP, strictly more
    /// permissive than reference. One function means one set of guards to get right.
    ///
    /// Guard every non-finite and negative value BEFORE converting: `Int(Double)` traps on NaN and on
    /// anything outside Int's range, and `raw >= x` is FALSE for NaN — so the NaN bound has to be an
    /// explicit isNaN test, not a comparison.
    ///
    /// Reference keeps the cap as a FLOAT and never converts it to an int:
    ///   client_transfer_limit = float(data[2])*1000      (LXMF 1.1.0 LXMRouter.py:1528, in a
    ///                                                     bare `try/except: pass`)
    ///   if limit != None and next_size > limit: pass     (LXMRouter.py:1547 — skip)
    /// Verified by reading the installed LXMF 1.1.0 source and modelling :1525-1547; `int()` appears
    /// nowhere, so no ValueError/OverflowError is ever raised there and the behaviour is decided
    /// entirely by float comparison. That matters because EVERY comparison against NaN is false,
    /// which flips the outcome:
    ///   - -inf / large finite negative / -0.0 / 0: `next_size > limit` is true, so reference skips
    ///     every message and serves nothing. Our 0 matches exactly.
    ///   - large finite positive, +inf, and any kb whose *1000 overflows to +inf: `next_size > limit`
    ///     is false, so reference serves everything. The Int.max clamp matches exactly — +inf
    ///     included. (By a different route: reference never overflows because Python floats saturate
    ///     to inf and inf loses the comparison; we saturate the cap instead. Same outcome.)
    ///   - NaN: `next_size > nan` is FALSE, so reference takes the else branch and serves EVERYTHING —
    ///     a NaN cap silently disables the cap. We serve NOTHING. DELIBERATE DIVERGENCE, and the one
    ///     place this path does not match reference: treating a hostile NaN as "no cap" lets any
    ///     client opt out of the limit it just asked for, so we take the restrictive direction. No
    ///     legitimate client sends NaN, so there is no interop cost. Pinned by
    ///     serviceNodeParsesNaNTransferLimitAsZero (float64) and serviceNodeParsesNaNFloat32-
    ///     TransferLimitAsZero (float32).
    /// -0.0 reaches 0 via the conversion, not the negative arm: IEEE 754 makes `-0.0 < 0` false.
    /// Reference's `next_size > -0.0` is true → serves nothing, so 0 is also the parity-correct
    /// answer. Pinned by the -0.0 tests.
    private static func transferLimitBytes(kilobytes kb: Double) -> Int {
        let raw = kb * 1000
        if raw.isNaN || raw < 0 { return 0 }
        if raw >= Double(Int.max) { return Int.max }
        return Int(raw)
    }

    public var body: some ReducerOf<Self> {
        Scope(state: \.client, action: \.client) { LXMFNode() }
        Scope(state: \.pn, action: \.pn) { PropagationNode() }
        Reduce { [date] state, action in
            /// True when this link terminates on the lxmf.propagation destination WE serve — i.e. the
            /// peer is a propagation client of ours, not a direct correspondent.
            func isPropagationLink(_ state: State, _ linkID: Data) -> Bool {
                guard let served = state.client.propagationDestinationHash else { return false }
                return state.client.linkDestinations[linkID] == served
            }

            switch action {
            case let .setNodeMode(enabled):
                state.nodeModeEnabled = enabled
                if enabled { return .send(.registerPropagation) }
                // Do NOT clear propagationDestinationHash on disable. The lxmf.propagation destination
                // cannot be unregistered, so links to it are still accepted. Keeping the classification
                // hint ensures arriving propagation data is recognised and DROPPED (because nodeModeEnabled
                // is false) rather than misclassified as a direct delivery message. Clearing serve-side
                // bookkeeping is sufficient — all serve behaviour is independently gated on nodeModeEnabled.
                state.clientIdentities = [:]
                state.pendingGet = [:]
                // Re-announce with nodeState = false so peers unpeer immediately rather than continuing
                // to sync into a node that now drops everything. Reference: LXMRouter.disable_propagation
                // (LXMRouter.py:692-694) sets self.propagation_node = False then calls
                // announce_propagation_node() (LXMRouter.py:338-345), which announces with the new
                // node_state. Peers react in Handlers.py:98-99: unpeer(destination_hash) when
                // propagation_enabled == False. Guard on propagationDestinationHash: without it there
                // is no destination to announce on (enable_propagation must have run first).
                guard let hash = state.client.propagationDestinationHash else { return .none }
                let appData = PNAnnounce(timebase: Int(date.now.timeIntervalSince1970), nodeState: false,
                                         perTransferLimit: LXMFPropagation.defaultPropagationTransferLimitKB,
                                         perSyncLimit: LXMFPropagation.defaultPropagationSyncLimitKB,
                                         targetStampCost: state.pn.store.minStampCost,
                                         stampCostFlexibility: 0, peeringCost: 0).packed
                return .send(.client(.endpoint(.announce(destinationHash: hash, appData: appData))))

            case .registerPropagation:
                guard state.nodeModeEnabled,
                      let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: ["propagation"], identity: state.client.identity)
                else { return .none }
                state.client.propagationDestinationHash = d.hash
                let appData = PNAnnounce(timebase: Int(date.now.timeIntervalSince1970), nodeState: true,
                                         // These are a REQUEST our peers honour, not a promise we keep:
                                         // a peer stores them on its LXMPeer record for US and filters
                                         // its own outbound offer (LXMPeer.py:370). 0 meant "no message
                                         // may ever be sent to me" — and reference marks each oversized
                                         // message handled, so it dropped everything, permanently.
                                         // Shared constants, not literals: the mirrored-copy drift that
                                         // produced the stamp-cost bug applies equally here.
                                         perTransferLimit: LXMFPropagation.defaultPropagationTransferLimitKB,
                                         perSyncLimit: LXMFPropagation.defaultPropagationSyncLimitKB,
                                         // Single source of truth: the value PropagationStore.ingest
                                         // actually enforces. A mirrored copy is what let PNNode
                                         // advertise 0 while enforcing 16.
                                         targetStampCost: state.pn.store.minStampCost,
                                         stampCostFlexibility: 0, peeringCost: 0).packed
                return .merge(
                    .send(.client(.endpoint(.registerLocalDestination(d)))),
                    .send(.client(.endpoint(.announce(destinationHash: d.hash, appData: appData)))))

            // --- Inbound offers (only on the link to the destination we serve) ---
            case let .client(.endpoint(.delegate(.resourceReceived(linkID, data)))):
                guard state.nodeModeEnabled, isPropagationLink(state, linkID) else { return .none }
                return .send(.pn(.ingestContainer(data)))

            case let .client(.endpoint(.delegate(.linkDataReceived(linkID, data, packetHash)))):
                guard state.nodeModeEnabled, isPropagationLink(state, linkID) else { return .none }
                // Reference LXMRouter.py:2252-2260: validate ALL entries in the container before deciding
                // whether to prove. If ANY entry fails stamp validation, send ERROR_INVALID_STAMP and tear
                // the link down — without a prove, which would falsely confirm delivery to the client.
                // If ALL entries pass (or the container is unstamped because minStampCost == 0), prove the
                // packet to complete the client's receipt (reference LXMRouter.py:2255).
                //
                // Deliberately scoped: this is the ONLY place ReTiCA proves an inbound data packet.
                // RNS proves per-destination (`proof_strategy`, default PROVE_NONE), so a blanket
                // auto-prove would be wrong; the decision lives here, in the composition that knows
                // the link terminates on the lxmf.propagation destination we serve AND that node mode
                // is on. Resource-framed offers already get a resource proof from `ResourceTransfer`.
                //
                // Unparseable containers: guard on parseContainer so a malformed wire payload neither
                // proves nor ingests (reference LXMRouter.py:2262 except block skips the prove).
                guard let (_, entries) = LXMFPropagation.parseContainer(data) else { return .none }
                if state.pn.store.minStampCost > 0 {
                    let anyRejected = entries.contains {
                        // Cheap dedup BEFORE the proof-of-work, and it has to be here rather than only
                        // in `PropagationStore.ingest`: this pre-scan runs first, so a replay used to
                        // pay a full 256 KB workblock per entry here and then hit ingest's dedup for
                        // free — measured 21.67 ms versus 0.0021 ms, a 10 328x bypass of the fix that
                        // was supposed to prevent exactly this. Reachable by any peer that can open a
                        // link to the propagation destination; the branch is gated on nodeModeEnabled
                        // and isPropagationLink only, with no identity check.
                        //
                        // Byte-identical replays only (`containsIdenticalStampedEntry`, not a
                        // stampless-core match). An entry that pairs a stored core with a different
                        // 32-byte tail carries a genuinely invalid stamp and must still earn
                        // ERROR_INVALID_STAMP plus teardown — a core-only match would silently
                        // convert that rejection into a prove. Such an entry therefore still pays the
                        // workblock; that is the junk-flood residue filed with the admission-control
                        // gap, not something dedup can close.
                        //
                        // One accepted edge: a stored entry was validated at whatever minStampCost
                        // was in force when it was accepted, so raising minStampCost afterwards lets
                        // a replay of a now-under-cost entry be proved rather than rejected.
                        // Deliberate — we already hold the entry, so "I have this" is the true
                        // answer, and re-validating what we have already stored buys nothing.
                        //
                        // STILL OPEN, deliberately: an entry that is ACCEPTED is validated TWICE —
                        // once here and once inside PropagationStore.ingest. Measured at 2 workblock
                        // derivations per novel entry by
                        // serviceNodeDoesNotRederiveWorkblockForStoredPacketOfferReplay's liveness
                        // counter. Reference validates once and passes the validated lxmf_data
                        // onward (LXMF 1.1.0 LXMRouter.py:2243-2249), so this is a parity regression.
                        // Not fixed here: threading validated entries into ingest would give the
                        // store a second entry point that trusts its caller's validation, and an
                        // attacker can only reach this path at all by doing the ~2^cost work of a
                        // valid stamp themselves. Filed with the admission-control gap.
                        !state.pn.store.containsIdenticalStampedEntry($0)
                            && LXStamper.validatePnStamp(transientData: $0, targetCost: state.pn.store.minStampCost) == nil
                    }
                    if anyRejected {
                        // Reference LXMRouter.py:2258-2260: send the error as a plain data packet, then teardown.
                        let errorBytes = MsgPack.encode(.array([.uint(LXMFPropagation.errorInvalidStamp)]))
                        return .merge(
                            .send(.client(.endpoint(.sendOverLink(linkID: linkID, data: errorBytes)))),
                            .send(.client(.endpoint(.closeLink(linkID: linkID)))))
                    }
                }
                return .merge(
                    .send(.pn(.ingestContainer(data))),
                    .send(.client(.endpoint(.provePacketOverLink(linkID: linkID, packetHash: packetHash)))))

            case let .client(.endpoint(.delegate(.linkIdentified(linkID, remoteIdentity)))):
                // Only record identity for links to OUR served propagation destination (Minor-4 / reference
                // LXMRouter.py:670: the /get handler is registered only on the propagation destination).
                guard state.nodeModeEnabled, isPropagationLink(state, linkID) else { return .none }
                state.clientIdentities[linkID] = remoteIdentity
                return .none

            // --- Two-phase /get ---
            case let .client(.endpoint(.delegate(.requestReceived(linkID, requestID, pathHash, data)))):
                // Guard on propagation-link classification (Minor-4): the /get handler is registered only
                // on the propagation destination (reference LXMRouter.py:670), so a /get on the delivery
                // link must be silently dropped rather than served.
                guard state.nodeModeEnabled,
                      isPropagationLink(state, linkID),
                      pathHash == Crypto.truncatedHash(Data("/get".utf8))
                else { return .none }
                // Reference LXMRouter.py:1483 — `message_get_request` returns LXMPeer.ERROR_NO_IDENTITY
                // (0xF0) as the response BODY when the link never IDENTIFY'd. Reference clients branch on
                // exactly that value (LXMRouter.py:1563 / :1608) to tear the link down and set
                // PR_NO_IDENTITY_RCVD; dropping silently instead makes them wait out the full request
                // timeout. Encoded the way the reference does: umsgpack.packb(0xF0) → uint8 0xCC 0xF0.
                guard let clientIdentity = state.clientIdentities[linkID] else {
                    return .send(.client(.endpoint(.sendResponseOverLink(
                        linkID: linkID, requestID: requestID,
                        data: MsgPack.encode(.uint(LXMFPropagation.errorNoIdentity))))))
                }
                guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2 else { return .none }
                let clientHash = LXMessage.deliveryHash(identityHash: clientIdentity.hash)
                let pending = PendingGet(linkID: linkID, requestID: requestID)
                // Queue the request (Minor-3): a client may have a concurrent in-flight /get (reference
                // LXMessage.py:616-621 tears down and retries on timeout). Appending preserves FIFO order;
                // the delegate pops the front when it responds.
                state.pendingGet[clientHash, default: []].append(pending)
                if case .null = items[0], case .null = items[1] {
                    return .send(.pn(.messageListRequested(destinationHash: clientHash)))
                }
                // Parse the optional third element as the client's per-transfer limit (Important-5).
                // Reference LXMRouter.py:1526-1529: client_transfer_limit = float(data[2])*1000.
                // The wire value may be a uint or a float (reference reads it via float()). Missing or
                // unparseable → nil (no limit). 0 is a valid 0-byte cap, NOT unlimited: the reference
                // computes `float(0)*1000 = 0.0` and then skips every message that would exceed it
                // (LXMRouter.py:1547), i.e. serves nothing. There is deliberately no `kb > 0` guard
                // here — that guard would silently turn a wire-level 0 into "unlimited".
                // Clamp: UInt64.max * 1000 overflows Int. Cap to Int.max when kb is too large.
                var transferLimitBytes: Int? = nil
                if items.count >= 3 {
                    switch items[2] {
                    case let .uint(kb):
                        transferLimitBytes = kb > UInt64(Int.max / 1000) ? Int.max : Int(kb) * 1000
                    case let .double(kb):
                        // float64 (0xCB). Every guard lives in transferLimitBytes(kilobytes:), shared
                        // with the .float branch below so the two cannot drift apart again.
                        transferLimitBytes = LXMFServiceNode.transferLimitBytes(kilobytes: kb)
                    case let .float(kb):
                        // float32 (0xCA) — the arm this switch was missing. Reference reads data[2]
                        // through `float()` (LXMF 1.1.0 LXMRouter.py:1528), which handles a float32
                        // exactly as it handles a float64, so falling to `default: break` left
                        // transferLimitBytes nil = NO CAP: strictly more permissive than reference,
                        // the identical failure the `.int` note below records one case over. Both
                        // arrived the same way — the decoder gained a type and this switch never grew
                        // the arm for it.
                        //
                        // Widen to Double BEFORE the *1000: Float arithmetic overflows a large float32
                        // to +-inf, whereas Float -> Double is lossless and Python's `float()` is a
                        // double, so this matches reference's arithmetic exactly. It is not a bug fix
                        // and no test pins it: the two routes return the same Int for every input
                        // (an overflow to +-inf lands on the clamp or the negative arm, which give the
                        // same answers as the finite comparisons do).
                        transferLimitBytes = LXMFServiceNode.transferLimitBytes(kilobytes: Double(kb))
                    case let .int(kb):
                        // A wire-decoded signed integer (e.g. int8(-1) = 0xFF). Before the decoder
                        // widening (177da8c) this type failed the msgpack parse and the whole request
                        // was rejected. Now it decodes as .int and fell to default: break → nil →
                        // unlimited — strictly more permissive than reference. Reference: `float(kb)*1000`
                        // on a negative kb produces a negative float, which is less than every message
                        // size, so nothing is served. We match that: negative → 0 (serve nothing).
                        // For non-negative: Int(kb) is an identity conversion (both are 64-bit Int/Int64),
                        // safe as long as kb <= Int.max / 1000. On this platform Int.max == Int64.max.
                        if kb < 0 {
                            transferLimitBytes = 0
                        } else if kb > Int64(Int.max / 1000) {
                            transferLimitBytes = Int.max
                        } else {
                            transferLimitBytes = Int(kb) * 1000
                        }
                    default: break
                    }
                }
                return .send(.pn(.messagesRequested(destinationHash: clientHash,
                                                    wants: LXMFServiceNode.arrayOfBin(items[0]),
                                                    haves: LXMFServiceNode.arrayOfBin(items[1]),
                                                    transferLimitBytes: transferLimitBytes)))

            case let .pn(.delegate(.deliverMessageList(dest, ids))):
                guard var queue = state.pendingGet[dest], !queue.isEmpty else { return .none }
                let p = queue.removeFirst()
                state.pendingGet[dest] = queue.isEmpty ? nil : queue
                return .send(.client(.endpoint(.sendResponseOverLink(
                    linkID: p.linkID, requestID: p.requestID,
                    data: MsgPack.encode(.array(ids.map { .bin($0) }))))))

            case let .pn(.delegate(.deliverMessages(dest, entries))):
                guard var queue = state.pendingGet[dest], !queue.isEmpty else { return .none }
                let p = queue.removeFirst()
                state.pendingGet[dest] = queue.isEmpty ? nil : queue
                return .send(.client(.endpoint(.sendResponseOverLink(
                    linkID: p.linkID, requestID: p.requestID,
                    data: MsgPack.encode(.array(entries.map { .bin($0) }))))))

            // --- Persistence signals out to the host ---
            case let .pn(.delegate(.storedEntries(entries))):
                guard !entries.isEmpty else { return .none }
                return .send(.delegate(.messagesStored(entries: entries)))

            case let .pn(.delegate(.purged(ids))):
                guard !ids.isEmpty else { return .none }
                return .send(.delegate(.messagesPurged(transientIds: ids)))

            // --- Link lifecycle cleanup ---
            case let .client(.endpoint(.delegate(.linkClosed(linkID, _)))):
                state.clientIdentities[linkID] = nil
                // Drop all queued requests for this link; responses can never be delivered.
                state.pendingGet = state.pendingGet.compactMapValues { queue in
                    let remaining = queue.filter { $0.linkID != linkID }
                    return remaining.isEmpty ? nil : remaining
                }
                return .none

            case let .client(.endpoint(.delegate(.requestFailed(linkID, _)))):
                state.pendingGet = state.pendingGet.compactMapValues { queue in
                    let remaining = queue.filter { $0.linkID != linkID }
                    return remaining.isEmpty ? nil : remaining
                }
                return .none

            case .client, .pn, .delegate:
                return .none
            }
        }
    }
}
