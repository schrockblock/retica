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
/// peering, inbound proving, and time-based expiry are out of scope — see `PNNode` for the peering path.
@Reducer
public struct LXMFServiceNode {
    @ObservableState
    public struct State: Equatable {
        public var client: LXMFNode.State
        public var pn: PropagationNode.State
        /// While false, nothing is registered, ingested, or served.
        public var nodeModeEnabled: Bool = false
        /// The stamp cost this node ENFORCES on inbound entries, and therefore also ADVERTISES.
        public var minStampCost: Int
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
            self.minStampCost = minStampCost
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
                return .none

            case .registerPropagation:
                guard state.nodeModeEnabled,
                      let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                          aspects: ["propagation"], identity: state.client.identity)
                else { return .none }
                state.client.propagationDestinationHash = d.hash
                let appData = PNAnnounce(timebase: Int(date.now.timeIntervalSince1970), nodeState: true,
                                         perTransferLimit: 0, perSyncLimit: 0,
                                         targetStampCost: state.minStampCost,   // advertised == enforced
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
                // Reference LXMRouter.py:2255 — after ingesting a PACKET-framed offer the node calls
                // `packet.prove()`, which completes the sending client's packet receipt. Without it a
                // reference client (which picks the PACKET path whenever the packed propagation payload
                // fits the link MDU — LXMessage.py:426-444, the ordinary chat-sized case) times out,
                // tears the link down and retries forever, never marking the message sent.
                //
                // Deliberately scoped: this is the ONLY place ReTiCA proves an inbound data packet.
                // RNS proves per-destination (`proof_strategy`, default PROVE_NONE), so a blanket
                // auto-prove would be wrong; the decision lives here, in the composition that knows
                // the link terminates on the lxmf.propagation destination we serve AND that node mode
                // is on. Resource-framed offers already get a resource proof from `ResourceTransfer`.
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
                // Missing or unparseable → nil (no limit). 0 is a valid 0-byte cap, NOT unlimited:
                // the reference computes `float(0)*1000 = 0.0` and then skips every message that would
                // exceed it (LXMRouter.py:1547), i.e. serves nothing. There is deliberately no `kb > 0`
                // guard here — that guard would silently turn a wire-level 0 into "unlimited".
                var transferLimitBytes: Int? = nil
                if items.count >= 3, case let .uint(kb) = items[2] {
                    transferLimitBytes = Int(kb) * 1000
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
