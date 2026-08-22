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
        /// Upper bound on concurrently-held ESTABLISHED responder links — those that reached
        /// `.active`, i.e. whose peer completed a handshake and therefore demonstrably holds the
        /// session key. `nil` disables the cap; `0` means zero, NOT unlimited (same rule
        /// `PropagationNode` documents for its transfer limit).
        ///
        /// Enforced at PROMOTION, in the `.delegate(.established)` handler — never in
        /// `acceptLinkRequest`. Unauthenticated input must not be able to spend this budget; it
        /// spends `maxIncompleteResponderLinks` instead.
        ///
        /// Only responder links are capped. Initiator links are ours; capping them would let an
        /// inbound flood evict our own outbound links and turn the cap into a DoS amplifier.
        public var maxResponderLinks: Int?
        /// Upper bound on concurrently-held responder links that have NOT reached `.active`.
        /// `nil` disables the bound; `0` means zero, NOT unlimited.
        ///
        /// This is the only budget an unauthenticated LINKREQUEST can spend, and it is deliberately
        /// a separate and much smaller one than `maxResponderLinks`. The two populations have
        /// nothing in common: a half-open element is minted for anyone who can put bytes on the
        /// wire and is held for at most one `establishmentTimeout`, whereas an `.active` responder
        /// link cost its peer a completed handshake and may live indefinitely.
        ///
        /// Sizing. A legitimate handshake occupies a slot for about one round trip, not for the
        /// whole establishment timeout, so even a busy propagation node holds far fewer half-open
        /// elements at once than this allows. Keeping the bound well below `maxResponderLinks`
        /// means the worst a flood can do is deny NEW inbound establishment for the length of an
        /// establishment timeout; it can neither consume the plane nor touch a link that is
        /// already up.
        public var maxIncompleteResponderLinks: Int?
        public init(links: IdentifiedArrayOf<LinkSession.State> = [],
                    registrations: [Data: RequestRegistration] = [:],
                    maxResponderLinks: Int? = 256,
                    maxIncompleteResponderLinks: Int? = 32) {
            self.links = links
            self.registrations = registrations
            self.maxResponderLinks = maxResponderLinks
            self.maxIncompleteResponderLinks = maxIncompleteResponderLinks
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

        /// A local interface went away. Grants each link bound to it ONE unauthenticated re-home
        /// so a reconnected peer is not stranded — see `LinkSession.State.rehomePermitted`.
        case interfaceDisconnected(InterfaceID)

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
            /// A local link's linkID was assigned / released — Transport tracks these to avoid
            /// relaying or shadowing links we are an endpoint of.
            case localLinkOpened(linkID: Data)
            case localLinkClosed(linkID: Data)
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
                // CAP THE HALF-OPEN POPULATION, AND ONLY THAT. This branch runs on bytes anyone
                // can put on the wire — opening a link is unauthenticated by protocol design — so
                // the only budget it may spend is the INCOMPLETE one. An unauthenticated request
                // must never displace a link whose peer completed a handshake.
                //
                // It used to. Until this guard replaced it, the `maxResponderLinks` cap was
                // enforced HERE and paid for by evicting an `.active` responder. That was
                // exploitable, not merely unfair: a LINKREQUEST whose 64-byte payload is random
                // bytes is viable all the way to `.handshake`. `Link.sessionKey` succeeds on such a
                // payload — several canonical low-order X25519 values (all-zeros among them) are
                // rejected by CryptoKit, but a random 32-byte key is overwhelmingly likely to be
                // accepted; it was choosing all-zeros that made the original F14 probe look mild. A
                // `.handshake` element is not evictable, so each junk request evicted an
                // authenticated link on
                // its way in and then parked in the slot it had just freed. A burst the size of
                // the cap flushed every established responder link and left the plane refusing
                // everything behind it, for an attacker holding no key at all. The eviction now
                // happens at PROMOTION — see the `.delegate(.established)` handler below, which
                // runs only after a peer has demonstrated it holds the session key.
                //
                // REFUSE rather than evict when this budget is full. Nothing here is evictable in
                // the first place: `LinkSession.close` guards on `status == .active`, so `.close`
                // to a `.pending`/`.handshake` element is a silent no-op, and appending regardless
                // would grow `links` without bound in exactly the flood this bound exists to stop.
                // Refusing strands nothing — every incomplete element leaves on its own
                // establishment deadline.
                //
                // Residual availability cost, accepted: a flood fills the half-open budget and new
                // inbound links are refused until those elements time out. Links that are already
                // up are untouched, which is the property the old shape did not have.
                if let incompleteCap = state.maxIncompleteResponderLinks {
                    let incomplete = state.links.filter { $0.role == .responder && $0.status != .active }
                    guard incomplete.count < incompleteCap else { return .none }
                }
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, responderFor: owner,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID))
                return .send(.link(.element(id: newID, action: .acceptRequest(data))))

            case let .routeLinkPacket(linkID, arrivalInterface, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                // Re-homing is decided INSIDE LinkSession, after decryption — see its `.received`
                // handler. Routing by cleartext linkID is addressing, not authentication, so this
                // layer must not move the binding.
                return .send(.link(.element(id: element.id,
                                            action: .received(data, arrivalInterface: arrivalInterface))))

            case let .interfaceDisconnected(interfaceID):
                // DELIBERATELY NOT FILTERED BY ROLE, and the consequence is real: after a local
                // disconnect, one unauthenticated packet from any interface re-homes one of OUR
                // OWN outbound links just as readily as an inbound one (F10 in the handoff).
                //
                // Restricting the grant to responders would not fix that — it would only trade it
                // for a worse failure. Our initiator links go stale on exactly the same event: a
                // BLE peer reconnects under a new token, so the `InterfaceID` we bound at creation
                // is dead. An initiator link's peer is the responder, which never initiates
                // keepalives (it only replies to ours, which would be going to the dead
                // interface), and if the peer is mid-transfer to us the segments it sends never
                // set `sawAuthenticatedData` — see the `.rehomed` handler below. Without the grant
                // those links recover only by timing out, aborting the transfer with them.
                for id in state.links.ids where state.links[id: id]?.interfaceID == interfaceID {
                    state.links[id: id]?.rehomePermitted = true
                }
                return .none

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
                guard let promoted = state.links[id: elementID] else { return .none }
                let established = Effect<Action>
                    .send(.delegate(.linkEstablished(linkID: linkID, destinationHash: promoted.destinationHash)))
                // EVICT HERE, NOT AT THE REQUEST. This action is emitted only after a handshake
                // completed — a responder reaches it by decrypting the peer's LRRTT under the
                // session key — so the party whose arrival costs an existing link a slot has
                // demonstrably paid for one. `acceptLinkRequest` deliberately evicts nothing.
                //
                // Responder promotions only. An initiator promotion does not change the responder
                // population, and initiator links are ours: an inbound flood must never be able to
                // make us close a link we opened.
                guard promoted.role == .responder, let cap = state.maxResponderLinks else { return established }
                let active = state.links.filter { $0.role == .responder && $0.status == .active }
                guard active.count > cap else { return established }
                // Evict on `lastData`, never on `lastInbound`: keepalives advance `lastInbound`,
                // so an LRU over it would preserve an attacker's keepalive-fed link and evict a
                // quiet legitimate one. `lastData` only advances on traffic that decrypted.
                //
                // Also skip links with in-flight transfers. Resource SEGMENT contexts forward raw
                // bytes to `ResourceTransfer` children that decrypt internally, so they never
                // advance `lastData` — only `.resourceAdvertisement` does, at transfer start.
                // Without this filter a link receiving a large resource would look idle and be
                // evicted mid-transfer.
                //
                // That filter is a TRADE-OFF, not pure protection. `LinkSession`'s
                // `.resourceAdvertisement` branch appends to `transfers` on a valid advertisement
                // alone, so a peer holding an active link (which it may have, by protocol design)
                // can advertise a resource, never send a segment, and become eviction-immune —
                // re-advertising outruns `ResourceTransfer`'s receiver watchdog. We accept it: it
                // is cheaper than throwing away demonstrably busy legitimate transfers, and
                // bounding transfers per link is the real fix.
                //
                // The element being promoted is excluded by id, not left to the comparator. It has
                // just stamped `lastData`, so a real clock would never choose it — but under a
                // constant clock every key ties and `sorted` is not documented to be stable, so
                // relying on the key would make "the newcomer cannot evict itself" an accident.
                //
                // Evict via `.close` so the element leaves through the normal `.delegate(.closed)`
                // path that removes it and reaps its transfers. A bare `state.links.remove` here
                // would strand `LXMFRouter.linkResourceInFlight`.
                let evictable = active
                    .filter { $0.id != elementID && $0.transfers.isEmpty }
                    .sorted { ($0.lastData ?? $0.activatedAt ?? 0) < ($1.lastData ?? $1.activatedAt ?? 0) }
                    .prefix(active.count - cap)
                // Nothing evictable: REFUSE the promotion by closing the link that just arrived,
                // rather than letting the active population climb past the cap. Every candidate is
                // an authenticated peer, so preferring the incumbents is the same
                // availability-for-memory trade the plane already makes — and the alternative is
                // unbounded growth, since a peer can make itself un-evictable by advertising.
                // `linkEstablished` still goes out ahead of the close: consumers key their link
                // bookkeeping on it, and a link that closes immediately after establishing is a
                // sequence they already handle.
                guard !evictable.isEmpty else {
                    return .merge(established, .send(.link(.element(id: elementID, action: .close))))
                }
                return .merge([established] + evictable.map {
                    .send(.link(.element(id: $0.id, action: .close)))
                })

            case let .link(.element(elementID, .delegate(.dataReceived(data, packetHash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data, packetHash: packetHash)))

            case let .link(.element(elementID, .delegate(.closed(reason)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                state.links.remove(id: elementID)
                return .merge(.send(.delegate(.linkClosed(linkID: linkID, reason: reason))),
                              .send(.delegate(.localLinkClosed(linkID: linkID))))

            case let .link(.element(elementID, .delegate(.establishmentFailed(kind)))):
                guard let session = state.links[id: elementID] else { return .none }
                let releasedLinkID = session.linkID
                state.links.remove(id: elementID)
                let unregister = Effect<Action>.send(.delegate(.localLinkClosed(linkID: releasedLinkID)))
                // Only an INITIATOR failure names a remote peer. A responder's destinationHash is the
                // destination WE serve (set by `acceptLinkRequest` above), so reporting linkFailed for
                // it would tell the delivery layer that a peer it never contacted is unreachable.
                // Still remove the element either way — that is the leak-prevention half, and it must
                // not become conditional on role.
                guard session.role == .initiator else { return unregister }
                // Exhaustive switch, deliberately not a ternary: a new EstablishmentFailure case must
                // be a COMPILE error here, not a silent default into `.handshakeRejected` — that is
                // the one PEER-shaped reason, and the only one the delivery layer does NOT answer
                // with a path request. A mislabel there costs a full establishment budget.
                let reason: LinkFailure
                switch kind {
                case .timedOut:          reason = .establishmentTimedOut
                case .handshakeRejected: reason = .handshakeRejected
                }
                return .merge(unregister, .send(.delegate(.linkFailed(destinationHash: session.destinationHash, reason: reason))))

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
                //
                // When a transfer's OWN traffic can trigger that repair depends on which half of
                // `LinkSession`'s re-home gate is available, and the two halves differ:
                //
                // • On the AUTHENTICATION half alone, it cannot. `LinkSession` sets
                //   `sawAuthenticatedData` only inside its `authDecrypt` helper, and the resource
                //   SEGMENT branches (`.resource`, `.resourceRequest`, `.resourceHashmapUpdate`,
                //   `.resourceProof`, and the two cancels) forward raw bytes to `ResourceTransfer`
                //   children that decrypt internally — they never call it. Only
                //   `.resourceAdvertisement`, at transfer START, does. So with no grant
                //   outstanding, some other authenticated packet on the link has to arrive first.
                //
                // • On the LOCAL-DISCONNECT half it can, and that is the mid-transfer BLE
                //   reconnect case this handler exists for. `interfaceDisconnected` above sets
                //   `rehomePermitted` on every link bound to the departing interface, and
                //   `LinkSession` re-homes on `sawAuthenticatedData || rehomePermitted`. A bare
                //   resource SEGMENT arriving from the reconnected peer's new interface therefore
                //   spends the grant and re-homes both the session and — via this handler — its
                //   in-flight transfers. That path DOES self-heal.
                //
                // Which also means the grant, not authentication, is what a bystander spends to
                // redirect a transfer mid-flight; see F10 in the handoff.
                for tid in state.links[id: elementID]?.transfers.ids ?? [] {
                    state.links[id: elementID]?.transfers[id: tid]?.interfaceID = interfaceID
                }
                return .none

            case let .link(.element(_, .delegate(.linkIDAssigned(linkID)))):
                return .send(.delegate(.localLinkOpened(linkID: linkID)))

            case .link, .delegate:
                return .none
            }
        }
        .forEach(\.links, action: \.link) { LinkSession() }
    }
}
