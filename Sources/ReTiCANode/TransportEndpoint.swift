import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// A Reticulum endpoint that may run SEVERAL interface drivers at once over ONE shared router
/// and ONE shared link plane. Presents a single unified action/delegate surface so compositions
/// above it (`LXMFNode`, `PNNode`) stay transport-agnostic: `.send`/`.openLink`/… reach the
/// shared router regardless of which driver carries the bytes, and every driver's delegates
/// surface under the same unified names.
///
/// Task-1b hoist: the router (`transport`) and the link/resource/request machinery (`linkPlane`)
/// live HERE, one of each, shared across all drivers. Each driver is a thin, KIND-indexed slot
/// (`tcpClients`, `tcpServer`, `ble`) owning only its interface(s); the container performs ALL the
/// wiring — inbound driver bytes are tagged with the arriving `InterfaceID` into the shared
/// router, and the router's outbound `.transmit(InterfaceID, data)` is routed back to whichever
/// driver owns that id. A packet arriving over one driver can therefore leave over another.
///
/// Transport-specific driving stays available through the KIND-addressed
/// `.tcpClients(.element(id:action:))` / `.ble(...)` escape hatches — which is also where
/// BLE-only delegates (`peerOnline`/`peerOffline`) remain observable; they are deliberately
/// absent from the unified surface because LXMF has no use for them.
@Reducer
public struct TransportEndpoint {
    @ObservableState
    public struct State: Equatable {
        /// The ONE shared router.
        public var transport: Transport.State
        /// The ONE shared link/resource/request plane.
        public var linkPlane: LinkPlane.State
        /// The TCP-client driver slots, one per dialed node, keyed by `interfaceID`. Each owns
        /// its own socket (`TCPConnectionPool`); the router, link plane and maintenance loop are
        /// shared by all of them, exactly as they are shared with the server and BLE slots.
        public var tcpClients: IdentifiedArrayOf<TCPEndpoint.State>
        /// The TCP-server driver slot (at most one; owns N accepted connections internally).
        public var tcpServer: TCPServerEndpoint.State?
        /// The BLE driver slot.
        public var ble: BLEEndpoint.State?
        /// The Meshtastic radio slot: at most one radio, with ONE `InterfaceID`
        /// (`meshtastic:<UUID>`) and the TCP-client lifecycle — registered when the radio comes
        /// online, deregistered when it drops. A broadcast medium has no per-peer interfaces.
        public var meshtastic: MeshtasticEndpoint.State?

        /// Learned-destination table of the shared router (identity / appData / path).
        public var learned: [Data: LearnedDestination] { transport.learned }

        /// Connected interfaces of the shared router. Paired with `learned`: an entry in
        /// `learned` names an `interfaceID`, and only an id present HERE is still reachable —
        /// which is the test `Transport.reachableLearned` performs and `openLink` gates on.
        public var interfaces: [InterfaceID: InterfaceProfile] { transport.interfaces }

        /// Live links of the shared link plane.
        public var links: IdentifiedArrayOf<LinkSession.State> { linkPlane.links }

        /// Request-handler registrations of the shared link plane.
        public var registrations: [Data: RequestRegistration] { linkPlane.registrations }

        public init(transport: Transport.State = Transport.State(),
                    linkPlane: LinkPlane.State = LinkPlane.State(),
                    tcpClients: IdentifiedArrayOf<TCPEndpoint.State> = [],
                    tcpServer: TCPServerEndpoint.State? = nil,
                    ble: BLEEndpoint.State? = nil,
                    meshtastic: MeshtasticEndpoint.State? = nil) {
            self.transport = transport
            self.linkPlane = linkPlane
            self.tcpClients = tcpClients
            self.tcpServer = tcpServer
            self.ble = ble
            self.meshtastic = meshtastic
        }

        /// Convenience factory: an endpoint running over a single TCP-client driver.
        public static func tcp(_ driver: TCPEndpoint.State) -> State {
            State(tcpClients: [driver])
        }

        /// Convenience factory: an endpoint running over a TCP-server (listener) driver.
        public static func tcpServer(_ driver: TCPServerEndpoint.State) -> State {
            State(tcpServer: driver)
        }

        /// Convenience factory: an endpoint running over a BLE driver.
        public static func ble(_ driver: BLEEndpoint.State) -> State {
            State(ble: driver)
        }

        /// Convenience factory: an endpoint running over one Meshtastic radio.
        public static func meshtastic(_ driver: MeshtasticEndpoint.State) -> State {
            State(meshtastic: driver)
        }
    }

    public enum Action: Equatable {
        case tcpClients(IdentifiedActionOf<TCPEndpoint>)
        /// Drop one TCP-client slot: deregister its interface (when registered), remove the slot
        /// (which cancels its connection stream, reconnect timer and writer — `forEach` cancels a
        /// removed element's effects) and close its socket. The explicit-disconnect arm is NOT
        /// enough on its own: it leaves the slot, and `.start` would dial it again.
        case removeTCPClient(InterfaceID)
        case tcpServer(TCPServerEndpoint.Action)
        case ble(BLEEndpoint.Action)
        case meshtastic(MeshtasticEndpoint.Action)
        case transport(Transport.Action)
        case linkPlane(LinkPlane.Action)
        case link(IdentifiedActionOf<LinkSession>)

        case start
        case stop
        case registerLocalDestination(Destination)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data, receiptToken: Data? = nil)
        case enableRelay(Identity)
        case requestPath(destinationHash: Data)
        case openLink(destinationHash: Data)
        case sendOverLink(linkID: Data, data: Data)
        case sendResourceOverLink(linkID: Data, data: Data)
        case cancelResource(linkID: Data, hash: Data)
        case identifyOverLink(linkID: Data, identity: Identity)
        case sendRequestOverLink(linkID: Data, path: String, data: Data)
        case sendResponseOverLink(linkID: Data, requestID: Data, data: Data)
        case sendWithReceiptOverLink(linkID: Data, data: Data, token: Data)
        case provePacketOverLink(linkID: Data, packetHash: Data)
        /// Prove a single (non-link) packet we received — see `Transport.Action.proveSingle`.
        case proveSinglePacket(packetHash: Data, interfaceID: InterfaceID, identity: Identity)
        case closeLink(linkID: Data)
        case registerRequestHandler(path: String, policy: RequestPolicy)
        case deregisterRequestHandler(path: String)

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            case messageReceived(destinationHash: Data, plaintext: Data, packetHash: Data, interfaceID: InterfaceID)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: Transport.SendFailure)
            case linkEstablished(linkID: Data, destinationHash: Data)
            case linkDataReceived(linkID: Data, data: Data, packetHash: Data)
            case linkClosed(linkID: Data, reason: LinkSession.CloseReason)
            case linkFailed(destinationHash: Data, reason: LinkFailure)
            case resourceReceived(linkID: Data, data: Data)
            case resourceConcluded(linkID: Data, resourceHash: Data)
            case resourceFailed(linkID: Data, resourceHash: Data, rejected: Bool)
            case resourceProgress(linkID: Data, resourceHash: Data, role: ResourceTransfer.Role,
                                  bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int)
            case linkIdentified(linkID: Data, remoteIdentity: Identity)
            case requestReceived(linkID: Data, requestID: Data, pathHash: Data, data: Data)
            case responseReceived(linkID: Data, requestID: Data, data: Data)
            case requestFailed(linkID: Data, requestID: Data)
            case packetDelivered(token: Data)
            case packetDeliveryFailed(token: Data)
            /// A single (non-link) packet sent with a receipt token was proved. Distinct from
            /// `packetDelivered(token:)`, which stays link-only.
            case singlePacketDelivered(token: Data)
        }
    }

    @Dependency(\.tcpConnectionPool) var connectionPool

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.transport, action: \.transport) { Transport() }
        Scope(state: \.linkPlane, action: \.linkPlaneRoute) { LinkPlane() }
        Reduce { state, action in
            switch action {
            // --- unified verbs → shared router / link plane ---
            case .start:
                return .merge(state.tcpClients.ids.map { .send(.tcpClients(.element(id: $0, action: .connect))) }
                              + [state.tcpServer != nil ? .send(.tcpServer(.start)) : .none,
                                 state.ble != nil ? .send(.ble(.start)) : .none,
                                 state.meshtastic != nil ? .send(.meshtastic(.start)) : .none])
            case .stop:
                return .merge(state.tcpClients.ids.map { .send(.tcpClients(.element(id: $0, action: .disconnect))) }
                              + [state.tcpServer != nil ? .send(.tcpServer(.stop)) : .none,
                                 state.ble != nil ? .send(.ble(.stop)) : .none,
                                 state.meshtastic != nil ? .send(.meshtastic(.stop)) : .none])
            case let .registerLocalDestination(d):  return .send(.transport(.registerLocalDestination(d)))
            case let .announce(h, a):               return .send(.transport(.announce(destinationHash: h, appData: a)))
            case let .send(h, p, token):            return .send(.transport(.send(destinationHash: h, plaintext: p,
                                                                                  receiptToken: token)))
            case let .enableRelay(identity):        return .send(.transport(.setTransportIdentity(identity)))
            case let .requestPath(h):               return .send(.transport(.requestPath(destinationHash: h)))
            case let .proveSinglePacket(h, id, identity):
                return .send(.transport(.proveSingle(packetHash: h, interfaceID: id, identity: identity)))

            case let .openLink(destinationHash):
                // F8 stale-path gate, on the SHARED router. `learned` is deliberately
                // non-destructive, so an entry outlives the interface it names: the socket drops,
                // Transport drops the interface, the path stays. Minting a LinkSession on a dead
                // interface transmits into nothing and exits only via the 15s establishment
                // deadline — misreported as a dead ROUTE (soliciting a pointless path request)
                // rather than a dead interface. `Transport.send` gates the same way.
                guard let learned = state.transport.learned[destinationHash] else {
                    return .send(.delegate(.linkFailed(destinationHash: destinationHash, reason: .noPath)))
                }
                guard state.transport.reachableLearned(destinationHash) != nil else {
                    return .send(.delegate(.linkFailed(destinationHash: destinationHash, reason: .pathStale)))
                }
                // Via a relay (learned nextHop != the destination) → HEADER_2 LINKREQUEST to the
                // relay. The learned entry records which interface the destination was heard on.
                let relayNextHop: Data? = learned.nextHop == destinationHash ? nil : learned.nextHop
                return .send(.linkPlane(.openLink(initiatorTo: learned.identity,
                                                  destinationHash: destinationHash,
                                                  interfaceID: learned.interfaceID,
                                                  relayNextHop: relayNextHop)))

            // The link verbs (`.sendOverLink`, `.closeLink`, `.registerRequestHandler`, …) are
            // NOT forwarded here: they are aliased straight into the shared `LinkPlane` by
            // `linkPlaneRoute` and have already been consumed by the `Scope` above. Forwarding
            // them again would double-deliver (e.g. two `.close`s to one element — a "forEach
            // received an action for a missing element" crash).

            // --- TCP client interface events → shared router (per client, by id) ---
            case let .tcpClients(.element(id, .interface(.delegate(.packetReceived(data))))):
                return .send(.transport(.received(id, data)))
            case let .tcpClients(.element(id, .interface(.connectionEvent(.connected)))):
                guard let profile = state.tcpClients[id: id]?.profile else { return .none }
                return .merge([.send(.transport(.interfaceConnected(id, profile)))]
                              + maintenanceStartEffect(state))
            case let .tcpClients(.element(id, .interface(.connectionEvent(.disconnected)))):
                return .merge([.send(.transport(.interfaceDisconnected(id))),
                               .send(.linkPlane(.interfaceDisconnected(id)))]
                              + maintenanceStopEffect(state, departing: id))
            case let .tcpClients(.element(id, .disconnect)):
                // An EXPLICIT disconnect (`.stop`, or a host closing its sockets on background)
                // cancels the connection stream silently: `TCPClientInterface` deliberately emits
                // no `.disconnected` event for it, so the router would keep the interface
                // registered, links on it would stay open, and a host keying "is this node up?" on
                // `interfaceDisconnected` would never re-dial. Deregister here, exactly as a
                // dropped socket does, but only when the interface is actually registered — a
                // disconnect while still connecting has nothing to undo. Only THIS client's id.
                guard state.transport.interfaces[id] != nil else { return .none }
                return .merge([.send(.transport(.interfaceDisconnected(id))),
                               .send(.linkPlane(.interfaceDisconnected(id)))]
                              + maintenanceStopEffect(state, departing: id))

            case let .removeTCPClient(id):
                guard let driver = state.tcpClients[id: id] else { return .none }
                var effects: [Effect<Action>] = []
                if state.transport.interfaces[id] != nil {
                    effects.append(.send(.transport(.interfaceDisconnected(id))))
                    effects.append(.send(.linkPlane(.interfaceDisconnected(id))))
                    effects.append(contentsOf: maintenanceStopEffect(state, departing: id))
                }
                // Removing the element makes `forEach` cancel the slot's effects; cancellation
                // stops the stream reader but never closes the socket, so close it here. Evict
                // FIRST (synchronously): a slot re-added for the same host:port in the meantime
                // then dials a fresh actor, and this late close can only ever hit the old one.
                state.tcpClients.remove(id: id)
                let key = driver.interface.connectionKey
                let connection = connectionPool.connection(key)
                connectionPool.evict(key)
                effects.append(.run { _ in await connection.close() })
                return .merge(effects)

            // --- TCP-server connection lifecycle → shared router interface set (+ maintenance) ---
            // Mirrors the BLE 1:N peer wiring: one Transport InterfaceID per accepted connection,
            // tracked in the driver's connInterfaces map so transmit can route back to it.
            case let .tcpServer(.interface(.delegate(.connectionAccepted(conn)))):
                let id = tcpServerInterfaceID(conn)
                guard let profile = state.tcpServer?.profile else { return .none }
                let startEffects = maintenanceStartEffect(state)
                state.tcpServer?.connInterfaces[id] = conn
                return .merge([.send(.transport(.interfaceConnected(id, profile)))] + startEffects)

            case let .tcpServer(.interface(.delegate(.packetReceived(conn, data)))):
                return .send(.transport(.received(tcpServerInterfaceID(conn), data)))

            case let .tcpServer(.interface(.delegate(.connectionClosed(conn)))):
                let id = tcpServerInterfaceID(conn)
                state.tcpServer?.connInterfaces[id] = nil
                return .merge([.send(.transport(.interfaceDisconnected(id))),
                               .send(.linkPlane(.interfaceDisconnected(id)))]
                              + maintenanceStopEffect(state, departing: id))

            // --- BLE peer lifecycle → shared router interface set (+ maintenance) ---
            case let .ble(.ble(.delegate(.peerOnline(token)))):
                let id = bleInterfaceID(token)
                guard let profile = state.ble?.profile else { return .none }
                let startEffects = maintenanceStartEffect(state)
                state.ble?.peerInterfaces[id] = token
                return .merge([.send(.transport(.interfaceConnected(id, profile))),
                               .send(.ble(.delegate(.peerOnline(token))))] + startEffects)

            case let .ble(.ble(.delegate(.peerOffline(token)))):
                let id = bleInterfaceID(token)
                state.ble?.peerInterfaces[id] = nil
                return .merge([.send(.transport(.interfaceDisconnected(id))),
                               .send(.linkPlane(.interfaceDisconnected(id))),
                               .send(.ble(.delegate(.peerOffline(token))))]
                              + maintenanceStopEffect(state, departing: id))

            case let .ble(.ble(.delegate(.packetReceived(token, packet)))):
                return .send(.transport(.received(bleInterfaceID(token), packet)))

            // Terminal adapter unavailability (S6): translate the interface-level delegate to the
            // BLE-only hatch delegate and surface it. Like peerOnline/peerOffline, it is deliberately
            // absent from the unified surface — LXMF has no use for it; only the app consumes it (A5).
            case let .ble(.ble(.delegate(.adapterUnavailable(cause)))):
                return .send(.ble(.delegate(.adapterUnavailable(cause))))

            // --- Meshtastic radio lifecycle → shared router interface set (+ maintenance) ---
            // ONE InterfaceID per radio, the TCP-client shape. The preset — hence the paced
            // bitrate — is only known once the radio is configured, so the profile is computed
            // here. A repeated `.online` (preset changed, or a reconnect the driver reported
            // without a drop) re-registers with the new profile; maintenance is not re-armed
            // because the shared interface set is not empty. Re-registering also resets
            // Transport's interfaceConnectedAt for the id, reopening the new-interface ingress-
            // control window (stricter announce ingress only). Preserving the
            // timestamp across a re-register belongs in Transport.swift (lane C), not here.
            case let .meshtastic(.interface(.delegate(.online(myNodeNum, modemPreset)))):
                guard let mesh = state.meshtastic else { return .none }
                let id = mesh.interfaceID
                let startEffects = maintenanceStartEffect(state)
                return .merge([.send(.transport(.interfaceConnected(id, mesh.registeredProfile(modemPreset: modemPreset))))]
                              + startEffects
                              + [.send(.meshtastic(.delegate(.radioOnline(myNodeNum: myNodeNum,
                                                                           modemPreset: modemPreset))))])

            case let .meshtastic(.interface(.delegate(.offline(reason)))):
                guard let mesh = state.meshtastic else { return .none }
                let id = mesh.interfaceID
                var effects: [Effect<Action>] = []
                if state.transport.interfaces[id] != nil {
                    effects.append(.send(.transport(.interfaceDisconnected(id))))
                    effects.append(.send(.linkPlane(.interfaceDisconnected(id))))
                    effects.append(contentsOf: maintenanceStopEffect(state, departing: id))
                }
                effects.append(.send(.meshtastic(.delegate(.radioOffline(reason: reason)))))
                return .merge(effects)

            case let .meshtastic(.interface(.delegate(.packetReceived(packet)))):
                guard let mesh = state.meshtastic else { return .none }
                return .send(.transport(.received(mesh.interfaceID, packet)))

            // Like BLE's (S6), adapter unavailability is Meshtastic-hatch-only; the app consumes it.
            case let .meshtastic(.interface(.delegate(.adapterUnavailable(cause)))):
                return .send(.meshtastic(.delegate(.adapterUnavailable(cause))))

            // --- shared router delegates → interface / unified delegate ---
            case let .transport(.delegate(.transmit(txID, raw))):
                // C5 IFAC outbound masking, on the interface's OWN profile. `transport.interfaces`
                // is registered per driver at `.interfaceConnected`, so the ifac key there is the
                // driver's profile — equivalent to the pre-hoist per-endpoint `state.profile.ifac`.
                // Masking centrally (not in Transport) keeps it off every emission point and off
                // the inbound C4 replay path.
                let masked = state.transport.interfaces[txID]?.ifac?.protect(raw) ?? raw
                return transmit(state, to: txID, masked: masked, unmasked: raw)
            case let .transport(.delegate(.received(h, p, packetHash, interfaceID))):
                return .send(.delegate(.messageReceived(destinationHash: h, plaintext: p,
                                                        packetHash: packetHash, interfaceID: interfaceID)))
            case let .transport(.delegate(.singlePacketDelivered(token))):
                return .send(.delegate(.singlePacketDelivered(token: token)))
            case let .transport(.delegate(.pathLearned(h, hops))):
                return .send(.delegate(.pathLearned(destinationHash: h, hops: hops)))
            case let .transport(.delegate(.sendFailed(h, r))):
                return .send(.delegate(.sendFailed(destinationHash: h, reason: r)))

            // --- shared router → shared link plane ---
            case let .transport(.delegate(.linkPacket(linkID, arrivalInterface, data))):
                return .send(.linkPlane(.routeLinkPacket(linkID: linkID, arrivalInterface: arrivalInterface, data: data)))

            case let .transport(.delegate(.linkRequest(destHash, arrivalInterface, data))):
                guard let owner = state.transport.localDestinations[destHash]?.identity,
                      owner.privateKey != nil
                else { return .none }
                // Reply on the interface the request arrived from.
                return .send(.linkPlane(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                                           interfaceID: arrivalInterface, data: data)))

            // --- shared link plane delegates → interface / unified delegate ---
            case let .linkPlane(.delegate(.transmit(txID, raw))):
                // C5 IFAC outbound masking (same rationale as transport transmit above).
                let masked = state.transport.interfaces[txID]?.ifac?.protect(raw) ?? raw
                return transmit(state, to: txID, masked: masked, unmasked: raw)

            case let .linkPlane(.delegate(.linkEstablished(linkID, destHash))):
                return .send(.delegate(.linkEstablished(linkID: linkID, destinationHash: destHash)))
            case let .linkPlane(.delegate(.linkDataReceived(linkID, data, packetHash))):
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data, packetHash: packetHash)))
            case let .linkPlane(.delegate(.linkClosed(linkID, reason))):
                return .send(.delegate(.linkClosed(linkID: linkID, reason: reason)))
            case let .linkPlane(.delegate(.linkFailed(destHash, reason))):
                return .send(.delegate(.linkFailed(destinationHash: destHash, reason: reason)))
            case let .linkPlane(.delegate(.resourceReceived(linkID, data))):
                return .send(.delegate(.resourceReceived(linkID: linkID, data: data)))
            case let .linkPlane(.delegate(.resourceConcluded(linkID, hash))):
                return .send(.delegate(.resourceConcluded(linkID: linkID, resourceHash: hash)))
            case let .linkPlane(.delegate(.resourceFailed(linkID, hash, rejected))):
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash, rejected: rejected)))
            case let .linkPlane(.delegate(.resourceProgress(linkID, hash, role, done, total, segment, segments))):
                return .send(.delegate(.resourceProgress(linkID: linkID, resourceHash: hash, role: role,
                                                         bytesDone: done, bytesTotal: total,
                                                         segment: segment, segments: segments)))
            case let .linkPlane(.delegate(.linkIdentified(linkID, identity))):
                return .send(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: identity)))
            case let .linkPlane(.delegate(.requestReceived(linkID, rid, ph, data))):
                return .send(.delegate(.requestReceived(linkID: linkID, requestID: rid, pathHash: ph, data: data)))
            case let .linkPlane(.delegate(.responseReceived(linkID, rid, data))):
                return .send(.delegate(.responseReceived(linkID: linkID, requestID: rid, data: data)))
            case let .linkPlane(.delegate(.requestFailed(linkID, rid))):
                return .send(.delegate(.requestFailed(linkID: linkID, requestID: rid)))
            case let .linkPlane(.delegate(.packetDelivered(token))):
                return .send(.delegate(.packetDelivered(token: token)))
            case let .linkPlane(.delegate(.packetDeliveryFailed(token))):
                return .send(.delegate(.packetDeliveryFailed(token: token)))
            case let .linkPlane(.delegate(.localLinkOpened(linkID))):
                return .send(.transport(.registerLocalLink(linkID)))
            case let .linkPlane(.delegate(.localLinkClosed(linkID))):
                return .send(.transport(.unregisterLocalLink(linkID)))

            // Everything else (child scopes already ran; the link verbs were consumed by the
            // `linkPlaneRoute` alias Scope).
            case .tcpClients, .tcpServer, .ble, .meshtastic, .transport, .linkPlane, .link, .delegate,
                 .sendOverLink, .sendResourceOverLink, .cancelResource, .identifyOverLink, .sendRequestOverLink,
                 .sendResponseOverLink, .sendWithReceiptOverLink, .provePacketOverLink,
                 .closeLink, .registerRequestHandler, .deregisterRequestHandler:
                return .none
            }
        }
        .forEach(\.tcpClients, action: \.tcpClients) { TCPEndpoint() }
        .ifLet(\.tcpServer, action: \.tcpServer) { TCPServerEndpoint() }
        .ifLet(\.ble, action: \.ble) { BLEEndpoint() }
        .ifLet(\.meshtastic, action: \.meshtastic) { MeshtasticEndpoint() }
    }

    /// The ONE maintenance loop (path-expiry / link-table / discovery-request GC) is shared by the
    /// whole router, so its start/stop MUST be driven off the SHARED interface count — not any one
    /// driver's own map. Otherwise a multi-driver node (several tcpClients, tcpServer, the slice's
    /// opt-in client+listener case) would halt GC for still-live interfaces the moment ANY one
    /// driver lost its last interface.
    ///
    /// Evaluation order (verified): the connect/disconnect arms register the interface with the
    /// router by RETURNING `.transport(.interfaceConnected/interfaceDisconnected(...))` as effects,
    /// which the Transport scope applies LATER. So at the moment these helpers run,
    /// `state.transport.interfaces` does NOT yet contain a CONNECTING id and STILL contains a
    /// DISCONNECTING id. Hence: "first interface" ⇔ `interfaces.isEmpty` (before the pending
    /// connect); "last interface" ⇔ only the departing id remains (`interfaces` == {departing}).
    /// The regression tests assert the resulting maintenance behaviour, not this reasoning.

    /// Arm the shared maintenance loop iff this is the node's 0→1 interface transition (across ALL
    /// drivers). Call BEFORE mutating any driver's own map — reads the pre-connect router state.
    private func maintenanceStartEffect(_ state: State) -> [Effect<Action>] {
        state.transport.interfaces.isEmpty ? [.send(.transport(.startMaintenance))] : []
    }

    /// Stop the shared maintenance loop iff `departing` is the node's LAST interface across ALL
    /// drivers — i.e. the router's interface set is exactly {departing} at call time (the
    /// disconnect effect that removes it is still pending). Any other live interface keeps GC up.
    private func maintenanceStopEffect(_ state: State, departing: InterfaceID) -> [Effect<Action>] {
        let live = state.transport.interfaces
        let isLast = live[departing] != nil ? live.count <= 1 : live.isEmpty
        return isLast ? [.send(.transport(.stopMaintenance))] : []
    }

    /// Routes an outbound (already IFAC-masked) buffer to whichever driver owns `txID`. Each TCP
    /// client owns its own `interfaceID` (the set key); the TCP-server owns each accepted
    /// connection in its `connInterfaces` map (1:N, like BLE); BLE owns each token in its
    /// `peerInterfaces` map. If the id maps to no live driver interface, the send is not
    /// deliverable: for BLE, surface `.sendFailed` (a stale binding otherwise dies silently on the
    /// ~60s inactivity watchdog); for TCP the id mismatch cannot occur for a live socket, so drop.
    private func transmit(_ state: State, to txID: InterfaceID,
                          masked: Data, unmasked: Data) -> Effect<Action> {
        if state.tcpClients[id: txID] != nil {
            return .send(.tcpClients(.element(id: txID, action: .interface(.send(masked)))))
        }
        if let conn = state.tcpServer?.connInterfaces[txID] {
            return .send(.tcpServer(.interface(.send(conn: conn, masked))))
        }
        if let peerToken = state.ble?.peerInterfaces[txID] {
            return .send(.ble(.ble(.send(peer: peerToken, packet: masked))))
        }
        // The radio's ONE id, while the radio is online. Between a drop and the reconnect learned
        // paths still name it, so a send then falls through to `.interfaceUnavailable` below.
        let meshOwnsID = state.meshtastic?.interfaceID == txID
        if meshOwnsID, state.meshtastic?.interface.isOnline == true {
            return .send(.meshtastic(.interface(.send(masked))))
        }
        // Not deliverable. `Packet(raw:)` recovers the destination hash; for established link
        // traffic that value IS the link ID, so the failure correlates. An unparseable packet
        // drops silently (no destination to report).
        guard state.ble != nil || meshOwnsID, let destHash = Packet(raw: unmasked)?.destinationHash else { return .none }
        return .send(.delegate(.sendFailed(destinationHash: destHash, reason: .interfaceUnavailable)))
    }
}

extension TransportEndpoint.Action.AllCasePaths {
    /// The case path the shared `LinkPlane` is scoped through. Aliases every `LinkPlane.Action`
    /// that has an identically-shaped `TransportEndpoint.Action` case (`.link`, `.sendOverLink`,
    /// `.closeLink`, `.registerRequestHandler`, …) onto that case, and rides the plane-only
    /// actions (`.openLink(initiatorTo:…)`, `.acceptLinkRequest`, `.routeLinkPacket`,
    /// `.interfaceDisconnected`, `.delegate`) on `.linkPlane(...)`.
    ///
    /// It is a bijection, not a forward-plus-mirror: each `LinkPlane.Action` reaches the plane
    /// exactly once, with no re-entry. This preserves the pre-hoist spelling so callers keep
    /// sending AND matching `.link(.element(id:action:))`, `.sendResponseOverLink(...)` etc.
    public var linkPlaneRoute: AnyCasePath<TransportEndpoint.Action, LinkPlane.Action> {
        AnyCasePath(
            embed: { plane in
                switch plane {
                case let .link(action):
                    return .link(action)
                case let .sendOverLink(linkID, data):
                    return .sendOverLink(linkID: linkID, data: data)
                case let .sendResourceOverLink(linkID, data):
                    return .sendResourceOverLink(linkID: linkID, data: data)
                case let .cancelResource(linkID, hash):
                    return .cancelResource(linkID: linkID, hash: hash)
                case let .identifyOverLink(linkID, identity):
                    return .identifyOverLink(linkID: linkID, identity: identity)
                case let .sendRequestOverLink(linkID, path, data):
                    return .sendRequestOverLink(linkID: linkID, path: path, data: data)
                case let .sendResponseOverLink(linkID, requestID, data):
                    return .sendResponseOverLink(linkID: linkID, requestID: requestID, data: data)
                case let .sendWithReceiptOverLink(linkID, data, token):
                    return .sendWithReceiptOverLink(linkID: linkID, data: data, token: token)
                case let .provePacketOverLink(linkID, packetHash):
                    return .provePacketOverLink(linkID: linkID, packetHash: packetHash)
                case let .closeLink(linkID):
                    return .closeLink(linkID: linkID)
                case let .registerRequestHandler(path, policy):
                    return .registerRequestHandler(path: path, policy: policy)
                case let .deregisterRequestHandler(path):
                    return .deregisterRequestHandler(path: path)
                case .openLink, .acceptLinkRequest, .routeLinkPacket, .interfaceDisconnected, .delegate:
                    return .linkPlane(plane)
                }
            },
            extract: { action in
                switch action {
                case let .link(elementAction):
                    return .link(elementAction)
                case let .sendOverLink(linkID, data):
                    return .sendOverLink(linkID: linkID, data: data)
                case let .sendResourceOverLink(linkID, data):
                    return .sendResourceOverLink(linkID: linkID, data: data)
                case let .cancelResource(linkID, hash):
                    return .cancelResource(linkID: linkID, hash: hash)
                case let .identifyOverLink(linkID, identity):
                    return .identifyOverLink(linkID: linkID, identity: identity)
                case let .sendRequestOverLink(linkID, path, data):
                    return .sendRequestOverLink(linkID: linkID, path: path, data: data)
                case let .sendResponseOverLink(linkID, requestID, data):
                    return .sendResponseOverLink(linkID: linkID, requestID: requestID, data: data)
                case let .sendWithReceiptOverLink(linkID, data, token):
                    return .sendWithReceiptOverLink(linkID: linkID, data: data, token: token)
                case let .provePacketOverLink(linkID, packetHash):
                    return .provePacketOverLink(linkID: linkID, packetHash: packetHash)
                case let .closeLink(linkID):
                    return .closeLink(linkID: linkID)
                case let .registerRequestHandler(path, policy):
                    return .registerRequestHandler(path: path, policy: policy)
                case let .deregisterRequestHandler(path):
                    return .deregisterRequestHandler(path: path)
                case let .linkPlane(plane):
                    return plane
                default:
                    return nil
                }
            }
        )
    }
}
