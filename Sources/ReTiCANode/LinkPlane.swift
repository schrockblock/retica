import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// Why a link could not be opened. Distinguishes failures that mean "our PATH is wrong"
/// (recoverable by requesting a fresh one) from "the PEER did not complete" (recoverable only
/// by retrying the link). `LXMFNode` routes on this — see its `linkFailed` handler.
///
/// Three of the four are PATH-shaped: `.noPath`, `.pathStale` and `.establishmentTimedOut` all
/// describe a route we cannot reach the peer over. Only `.handshakeRejected` is PEER-shaped —
/// it is the one case where the peer demonstrably received our packets.
public enum LinkFailure: Equatable, Sendable {
    /// No learned path at all for the destination.
    case noPath
    /// A learned path exists but names an interface that is gone (BLE peer reconnected with a
    /// new InterfaceID, interface removed). `Transport.reachableLearned` is the detector.
    case pathStale
    /// A link was minted and no proof came back within the establishment timeout. Treated as
    /// PATH-shaped: the peer never responded, so the most likely cause is that our route to it is
    /// wrong. Requesting a fresh path is cheap and bounded; retrying the link against a dead route
    /// costs the whole budget.
    case establishmentTimedOut
    /// The peer answered and the handshake failed to validate. PEER-shaped — a path request would
    /// not help, because the path demonstrably works.
    case handshakeRejected
}

/// The interface-agnostic link/resource/request plane: owns the live `LinkSession`s and the
/// request-handler registry, and surfaces link lifecycle + resource + request delegates.
///
/// It never reads `Transport` state — the host passes in whatever a link needs at creation
/// time (identity, destination hash, the `InterfaceID` the link rides). Outbound link packets
/// are surfaced as `.delegate(.transmit(interfaceID, raw))`; the host resolves that
/// `InterfaceID` to a concrete interface (one fixed ID for TCP; a per-peer map for BLE).
@Reducer
public struct LinkPlane {
    @ObservableState
    public struct State: Equatable {
        public var links: IdentifiedArrayOf<LinkSession.State> = []
        public var registrations: [Data: RequestRegistration] = [:]
        /// Upper bound on concurrently-held RESPONDER links. `nil` disables the cap; `0` means
        /// zero, NOT unlimited (same rule `PropagationNode` documents for its transfer limit).
        ///
        /// Only responder links are capped. Initiator links are ours; capping them would let an
        /// inbound flood evict our own outbound links and turn the cap into a DoS amplifier.
        public var maxResponderLinks: Int?
        public init(links: IdentifiedArrayOf<LinkSession.State> = [],
                    registrations: [Data: RequestRegistration] = [:],
                    maxResponderLinks: Int? = 256) {
            self.links = links
            self.registrations = registrations
            self.maxResponderLinks = maxResponderLinks
        }
    }

    public enum Action: Equatable {
        case link(IdentifiedActionOf<LinkSession>)

        /// Create an initiator link and start establishment.
        case openLink(initiatorTo: Identity, destinationHash: Data,
                      interfaceID: InterfaceID, relayNextHop: Data?)
        /// Create a responder link for an inbound LINKREQUEST and accept it.
        case acceptLinkRequest(owner: Identity, destinationHash: Data,
                               interfaceID: InterfaceID, data: Data)
        /// Route an inbound link-addressed packet to the link that owns it.
        case routeLinkPacket(linkID: Data, arrivalInterface: InterfaceID, data: Data)

        case sendOverLink(linkID: Data, data: Data)
        case sendResourceOverLink(linkID: Data, data: Data)
        case identifyOverLink(linkID: Data, identity: Identity)
        case sendRequestOverLink(linkID: Data, path: String, data: Data)
        case sendResponseOverLink(linkID: Data, requestID: Data, data: Data)
        case sendWithReceiptOverLink(linkID: Data, data: Data, token: Data)
        /// Prove one inbound data packet on `linkID` (reference `RNS.Packet.prove()`).
        case provePacketOverLink(linkID: Data, packetHash: Data)
        case closeLink(linkID: Data)
        case registerRequestHandler(path: String, policy: RequestPolicy)
        case deregisterRequestHandler(path: String)

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            /// Send `data` on the interface identified by this `InterfaceID`.
            case transmit(InterfaceID, Data)
            case linkEstablished(linkID: Data, destinationHash: Data)
            case linkDataReceived(linkID: Data, data: Data, packetHash: Data)
            case linkClosed(linkID: Data, reason: LinkSession.CloseReason)
            case linkFailed(destinationHash: Data, reason: LinkFailure)
            case resourceReceived(linkID: Data, data: Data)
            case resourceConcluded(linkID: Data, resourceHash: Data)
            case resourceFailed(linkID: Data, resourceHash: Data)
            case linkIdentified(linkID: Data, remoteIdentity: Identity)
            case requestReceived(linkID: Data, requestID: Data, pathHash: Data, data: Data)
            case responseReceived(linkID: Data, requestID: Data, data: Data)
            case requestFailed(linkID: Data, requestID: Data)
            case packetDelivered(token: Data)
            case packetDeliveryFailed(token: Data)
        }
    }

    public init() {}

    @Dependency(\.uuid) var uuid
    @Dependency(\.requestResponder) var requestResponder

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .openLink(identity, destinationHash, interfaceID, relayNextHop):
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, initiatorTo: identity,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID,
                                                     relayNextHop: relayNextHop))
                return .send(.link(.element(id: newID, action: .establish)))

            case let .acceptLinkRequest(owner, destinationHash, interfaceID, data):
                // DEDUPE BEFORE CRYPTO. A duplicate LINKREQUEST costs a DH, an HKDF, an Ed25519
                // signature with our long-term destination key, and — because we do not pass
                // `ephemeral:` below — a fresh keypair generation from the defaulted
                // `ephemeral: Identity = Identity()`. Transport hands LINKREQUESTs to us BEFORE
                // its seenPacketHashes dedup, so byte-identical replays arrive freely.
                //
                // Dropping a duplicate is always correct: both we and RNS mint a fresh ephemeral
                // per attempt (`Link.__init__` calls X25519PrivateKey.generate()) and neither
                // retransmits a LINKREQUEST, so an identical linkID is a replay or a multipath
                // copy — never a legitimate retry. Note HEADER_1 and relayed HEADER_2 copies of
                // the same request share a linkID (`hashablePart` excludes hops/headerType/
                // transportType/transportId), so this also collapses non-adversarial mesh
                // duplicates.
                //
                // Same shape as the dedup-before-PoW guard in `PropagationStore.ingest`.
                guard let requestPacket = Packet(raw: data) else { return .none }
                let requestLinkID = Link.linkID(requestPacket: requestPacket)
                guard !state.links.contains(where: { $0.linkID == requestLinkID }) else { return .none }
                // CAP. Opening a link is unauthenticated by protocol design: an attacker supplies
                // the LINKREQUEST, completes a genuine handshake with its own ephemeral, and then
                // holds a valid session key — so it can keep an element alive with perfectly
                // AUTHENTICATED keepalives forever. No authentication gate can bound this; only
                // resource policy can.
                //
                // Evict on `lastData`, never on `lastInbound`: keepalives advance `lastInbound`,
                // so an LRU over it would preserve an attacker's keepalive-fed link and evict a
                // quiet legitimate one. `lastData` only advances on traffic that decrypted.
                //
                // Also skip links with in-flight transfers. Resource SEGMENT contexts
                // forward raw bytes to ResourceTransfer children that decrypt internally,
                // so they never advance `lastData` — only `.resourceAdvertisement` does, at
                // transfer start. Without this filter a link receiving a large resource
                // would look idle and be evicted mid-transfer.
                //
                // This filter is a TRADE-OFF, not pure protection. `LinkSession`'s
                // `.resourceAdvertisement` branch appends to `transfers` on a valid advertisement
                // alone, so a peer holding an active link (which it may have, by protocol design)
                // can advertise a resource, never send a segment, and become eviction-immune —
                // re-advertising outruns `ResourceTransfer`'s receiver watchdog. With `cap` such
                // links, every inbound LINKREQUEST from anyone is refused.
                //
                // We accept that: it is the same availability-for-memory trade the cap already
                // makes, and cheaper than throwing away demonstrably busy legitimate transfers.
                // But note the asymmetry with the `.handshake` case below — that one self-clears
                // on the establishment deadline, whereas this one does NOT clear without the
                // advertiser's cooperation. Bounding transfers per link is the real fix.
                //
                // Evict via `.close` so the element leaves through the normal
                // `.delegate(.closed)` path that removes it and reaps its transfers. A bare
                // `state.links.remove` here would strand `LXMFRouter.linkResourceInFlight`.
                var evictions: [Effect<Action>] = []
                if let cap = state.maxResponderLinks {
                    let responders = state.links.filter { $0.role == .responder }
                    if responders.count >= cap {
                        // Only an .active element is evictable: `LinkSession.close` guards on
                        // `status == .active`, so `.close` to a .pending/.handshake element is a
                        // silent no-op. If we appended anyway, a flood of INCOMPLETE handshakes
                        // would grow `links` without bound — precisely the attack this cap exists
                        // to stop. So when nothing is evictable, REFUSE the new request. Incomplete
                        // elements are not stranded: each leaves on its own establishment deadline.
                        let evictable = responders
                            .filter { $0.status == .active && $0.transfers.isEmpty }
                            .sorted { ($0.lastData ?? $0.activatedAt ?? 0) < ($1.lastData ?? $1.activatedAt ?? 0) }
                            .prefix(responders.count - cap + 1)
                        guard !evictable.isEmpty else { return .none }
                        for victim in evictable {
                            evictions.append(.send(.link(.element(id: victim.id, action: .close))))
                        }
                    }
                }
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, responderFor: owner,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID))
                return .merge(evictions + [.send(.link(.element(id: newID, action: .acceptRequest(data))))])

            case let .routeLinkPacket(linkID, arrivalInterface, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                // Re-homing is decided INSIDE LinkSession, after decryption — see its `.received`
                // handler. Routing by cleartext linkID is addressing, not authentication, so this
                // layer must not move the binding.
                return .send(.link(.element(id: element.id,
                                            action: .received(data, arrivalInterface: arrivalInterface))))

            case let .sendOverLink(linkID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .send(data))))

            case let .sendResourceOverLink(linkID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendResource(data))))

            case let .identifyOverLink(linkID, identity):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .identify(identity))))

            case let .sendRequestOverLink(linkID, path, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendRequest(path: path, data: data))))

            case let .sendResponseOverLink(linkID, requestID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendResponse(requestID: requestID, data: data))))

            case let .sendWithReceiptOverLink(linkID, data, token):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendWithReceipt(data: data, token: token))))

            case let .provePacketOverLink(linkID, packetHash):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .provePacket(packetHash: packetHash))))

            case let .closeLink(linkID):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .close)))

            case let .registerRequestHandler(path, policy):
                state.registrations[Crypto.truncatedHash(Data(path.utf8))] = RequestRegistration(path: path, policy: policy)
                return .none

            case let .deregisterRequestHandler(path):
                state.registrations[Crypto.truncatedHash(Data(path.utf8))] = nil
                return .none

            // --- LinkSession element delegates → LinkPlane delegates ---

            case let .link(.element(_, .delegate(.transmit(txID, raw)))):
                return .send(.delegate(.transmit(txID, raw)))

            case let .link(.element(elementID, .delegate(.established(linkID, _)))):
                guard let destHash = state.links[id: elementID]?.destinationHash else { return .none }
                return .send(.delegate(.linkEstablished(linkID: linkID, destinationHash: destHash)))

            case let .link(.element(elementID, .delegate(.dataReceived(data, packetHash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data, packetHash: packetHash)))

            case let .link(.element(elementID, .delegate(.closed(reason)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                state.links.remove(id: elementID)
                return .send(.delegate(.linkClosed(linkID: linkID, reason: reason)))

            case let .link(.element(elementID, .delegate(.establishmentFailed(kind)))):
                guard let session = state.links[id: elementID] else { return .none }
                state.links.remove(id: elementID)
                // Only an INITIATOR failure names a remote peer. A responder's destinationHash is the
                // destination WE serve (set by `acceptLinkRequest` above), so reporting linkFailed for
                // it would tell the delivery layer that a peer it never contacted is unreachable.
                // Still remove the element either way — that is the leak-prevention half, and it must
                // not become conditional on role.
                guard session.role == .initiator else { return .none }
                // Exhaustive switch, deliberately not a ternary: a new EstablishmentFailure case must
                // be a COMPILE error here, not a silent default into `.handshakeRejected` — that is
                // the one PEER-shaped reason, and the only one the delivery layer does NOT answer
                // with a path request. A mislabel there costs a full establishment budget.
                let reason: LinkFailure
                switch kind {
                case .timedOut:          reason = .establishmentTimedOut
                case .handshakeRejected: reason = .handshakeRejected
                }
                return .send(.delegate(.linkFailed(destinationHash: session.destinationHash, reason: reason)))

            case let .link(.element(elementID, .delegate(.resourceReceived(data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceReceived(linkID: linkID, data: data)))

            case let .link(.element(elementID, .delegate(.resourceConcluded(hash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceConcluded(linkID: linkID, resourceHash: hash)))

            case let .link(.element(elementID, .delegate(.resourceFailed(hash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash)))

            case let .link(.element(elementID, .delegate(.identified(identity)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: identity)))

            case let .link(.element(elementID, .delegate(.requestReceived(rid, ph, data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                guard let reg = state.registrations[ph] else {
                    // No registered handler for this path: surface to the app.
                    return .send(.delegate(.requestReceived(linkID: linkID, requestID: rid, pathHash: ph, data: data)))
                }
                let identity = state.links[id: elementID]?.remoteIdentity
                guard isAllowed(reg.policy, identity) else { return .none }   // denied → silent drop
                let path = reg.path
                let responder = requestResponder
                return .run { send in
                    if let response = await responder(path, data, identity) {
                        await send(.sendResponseOverLink(linkID: linkID, requestID: rid, data: response))
                    }
                }

            case let .link(.element(elementID, .delegate(.responseReceived(rid, data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.responseReceived(linkID: linkID, requestID: rid, data: data)))

            case let .link(.element(elementID, .delegate(.requestFailed(rid)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.requestFailed(linkID: linkID, requestID: rid)))

            case let .link(.element(_, .delegate(.packetDelivered(token)))):
                return .send(.delegate(.packetDelivered(token: token)))

            case let .link(.element(_, .delegate(.packetDeliveryFailed(token)))):
                return .send(.delegate(.packetDeliveryFailed(token: token)))

            case let .link(.element(elementID, .delegate(.rehomed(interfaceID)))):
                // ResourceTransfer.State.interfaceID is a snapshot taken at creation and every
                // transfer transmit uses that stored copy, so a transfer running when the peer
                // reconnects would keep firing parts, hashmap updates, proofs and cancels at the
                // dead interface.
                for tid in state.links[id: elementID]?.transfers.ids ?? [] {
                    state.links[id: elementID]?.transfers[id: tid]?.interfaceID = interfaceID
                }
                return .none

            case .link, .delegate:
                return .none
            }
        }
        .forEach(\.links, action: \.link) { LinkSession() }
    }
}
