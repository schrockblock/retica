import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// MARK: - A small simulated network of real nodes
//
// Support for `MessagingIntegrationTests` and `AnnounceAndPathIntegrationTests`. Each node is a REAL
// `LXMFNode`, `LXMFServiceNode` or relaying `TransportEndpoint` store; only the sockets are
// replaced. Everything a node writes is carried to the other nodes by the world, so a test never
// bridges a frame by hand and never names an internal action: it drives a node the way the host
// app does and reads back what the host app would be told.
//
// Three media, and a node may sit on any of them:
//  - `.hub`: a shared TCP segment. Every node on it hears every other directly; nothing relays.
//  - `.uplink`: a TCP connection to the world's relay (`MessagingWorld.relay`), a real transport
//    node. Nodes on uplinks reach each other only THROUGH it: it rebroadcasts their announces,
//    answers path requests from what it has heard, and forwards their packets and links.
//  - `.lan`: AutoInterface. Multicast discovery reaches every node on the LAN, unicast reaches the
//    node holding that link-local address.
//
// Faults: `unplug`/`plug` a node, or `loseNextFrames(from:)`.
// Restarts: `relaunch(_:restoring:)` ends a client's process and starts a new one with the same
// identity, handing back whatever the test chooses of what the host had saved.

/// What the host app is told about a message.
enum MessagingEvent: Equatable, Sendable {
    case received(Received)
    case confirmed(Data)
    case acceptedByPropagationNode(Data)
    case failed(Data)
    case rejected(Data)
    case cancelled(Data)

    /// The outbound message a terminal outcome is about.
    var outboundHash: Data? {
        switch self {
        case .received: nil
        case let .confirmed(h), let .acceptedByPropagationNode(h), let .failed(h), let .rejected(h),
             let .cancelled(h): h
        }
    }
}

/// A message as the recipient's app sees it.
struct Received: Equatable, Sendable {
    var content: String
    var from: Data
    var validated: Bool
    var method: LXMFRouter.DeliveryMethod
}

enum Medium: Hashable, Sendable { case hub, uplink, lan }

/// What a host app keeps on disk between launches, as far as announces, paths and messages go.
/// Every field is a `var` so a test can launch with part of it missing.
struct SavedSession {
    /// The path table (`endpoint.learned`).
    var paths: [Data: LearnedDestination]
    /// Every identity heard (`endpoint.knownDestinations`).
    var knownDestinations: [Data: KnownDestination]
    /// Names and stamp costs from delivery announces (`learnedPeers`).
    var contacts: [Data: LXMFNode.LearnedPeer]
    /// Hashes of the messages received.
    var receivedMessages: [Data]
    /// Propagation-node entries already downloaded.
    var downloadedTransientIds: [Data]
    /// Our own ratchet private keys, newest first (empty when ratchets are off).
    var ratchetRing: [Data]
}

/// Runs `tap` on every action before `base` reduces it.
private struct Tapped<Base: Reducer>: Reducer {
    let base: Base
    let tap: @Sendable (Base.Action) -> Void

    var body: some Reducer<Base.State, Base.Action> {
        Reduce { _, action in
            tap(action)
            return .none
        }
        base
    }
}

private enum AutoDatagram: Sendable {
    case multicast(token: Data)
    case unicast(addr: String, port: UInt16, datagram: Data)
}

/// One mock TCP connection of one node.
private final class Socket: Sendable {
    enum Role: Sendable, Equatable {
        /// On the shared segment.
        case segment
        /// A client's connection to the relay.
        case uplink
        /// The relay's connection to the client of that name.
        case downlink(String)
    }

    static let port: UInt16 = 4242
    let role: Role
    let host: String
    let incoming: AsyncStream<TCPEvent>
    let input: AsyncStream<TCPEvent>.Continuation
    let out = LockIsolated<[Data]>([])

    init(role: Role, host: String) {
        self.role = role
        self.host = host
        (incoming, input) = AsyncStream<TCPEvent>.makeStream()
    }

    /// `TCPClientInterface.State.connectionKey` of the client that owns this socket.
    var key: String { "\(host):\(Socket.port)" }
    static func uplinkKey() -> String { "relay:\(port)" }
    static func downlinkKey(_ client: String) -> String { "\(client):\(port)" }
}

/// One node's attachment to the simulated network: what its mock sockets wrote, and where to hand
/// it what the others wrote.
@MainActor
final class NetworkPort {
    let name: String
    let media: Set<Medium>
    fileprivate let isRelay: Bool
    fileprivate let wiring: Wiring
    fileprivate var carried: [String: Int] = [:]
    fileprivate var lanCarried = 0
    fileprivate var online = false
    fileprivate var plugged = true
    fileprivate var framesToLose = 0

    fileprivate init(name: String, media: Set<Medium>, isRelay: Bool, wiring: Wiring) {
        self.name = name
        self.media = media
        self.isRelay = isRelay
        self.wiring = wiring
    }

    fileprivate var reachable: Bool { online && plugged }
}

/// The mock sockets of one node. Sendable, so the dependency closures can hold it.
private struct Wiring: Sendable {
    /// By `connectionKey`.
    let sockets: [String: Socket]
    let nic: AutoNIC
    let lanOut = LockIsolated<[AutoDatagram]>([])
    let lanSessions = LockIsolated<[AsyncStream<AutoSocketEvent>.Continuation]>([])
    let clock: TestClock<Duration>
    let epoch: TestClock<Duration>.Instant

    var linkLocal: String { nic.linkLocals[0] }

    /// One TCP-client slot per socket.
    var tcpClients: IdentifiedArrayOf<TCPEndpoint.State> {
        IdentifiedArray(uniqueElements: sockets.values.sorted { $0.key < $1.key }.map {
            TCPEndpoint.State(host: $0.host, port: Socket.port, reconnectOnDrop: false,
                              interfaceID: InterfaceID("tcp:\($0.host)"))
        })
    }

    func apply(_ values: inout DependencyValues) {
        values.tcpConnectionPool = TCPConnectionPool(connection: { key in
            guard let socket = sockets[key] else {
                return TCPConnection(open: { _, _ in AsyncStream { $0.finish() } }, send: { _ in }, close: { })
            }
            return TCPConnection(
                open: { _, _ in socket.incoming },
                send: { frame in socket.out.withValue { $0.append(frame) } },
                close: { })
        })
        values.autoInterfaceDriver = AutoInterfaceDriver(
            interfaces: { [nic] },
            run: { _ in
                let session = AsyncStream<AutoSocketEvent>.makeStream()
                lanSessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            rebind: { _ in }, unbind: { _ in },
            sendMulticast: { _, token, _ in
                lanOut.withValue { $0.append(.multicast(token: token)) }
                return .sent
            },
            sendUnicast: { addr, _, port, datagram in
                lanOut.withValue { $0.append(.unicast(addr: addr, port: port, datagram: datagram)) }
                return .sent
            },
            stop: { lanSessions.value.last?.finish() })
        // Wall time follows the test clock, so timeouts and measured round trips are virtual time.
        let now = DateGenerator {
            let d = epoch.duration(to: clock.now).components
            return MessagingWorld.base.addingTimeInterval(Double(d.seconds) + Double(d.attoseconds) / 1e18)
        }
        values.continuousClock = clock
        values.date = now
        values.transportDate = now
        values.uuid = .incrementing
        values.withRandomNumberGenerator = WithRandomNumberGenerator(SystemRandomNumberGenerator())
    }
}

@MainActor
final class MessagingWorld {
    nonisolated static let base = Date(timeIntervalSince1970: 1_700_000_000.5)

    let clock = TestClock<Duration>()
    private let epoch: TestClock<Duration>.Instant
    private var ports: [NetworkPort] = []
    private var messengers: [Messenger] = []
    private var propagationHosts: [PropagationHost] = []
    private var relays: [RelayHub] = []
    private var addressesIssued = 0

    init() { epoch = clock.now }

    /// Virtual time since the world began. Zero means no timer of any node has had to fire.
    var elapsed: Duration { epoch.duration(to: clock.now) }

    var now: Date {
        let d = elapsed.components
        return MessagingWorld.base.addingTimeInterval(Double(d.seconds) + Double(d.attoseconds) / 1e18)
    }

    // MARK: Building nodes

    private func newLinkLocal() -> String {
        addressesIssued += 1
        return "fe80::\(addressesIssued)"
    }

    private func makePort(_ name: String, _ media: Set<Medium>, linkLocal: String,
                          relayClients: [String]? = nil) -> NetworkPort {
        var sockets: [Socket] = []
        if let relayClients {
            sockets = relayClients.map { Socket(role: .downlink($0), host: $0) }
        } else {
            if media.contains(.hub) { sockets.append(Socket(role: .segment, host: name)) }
            if media.contains(.uplink) { sockets.append(Socket(role: .uplink, host: "relay")) }
        }
        let wiring = Wiring(sockets: Dictionary(uniqueKeysWithValues: sockets.map { ($0.key, $0) }),
                            nic: AutoNIC(name: "en0", index: 4, linkLocals: [linkLocal]),
                            clock: clock, epoch: epoch)
        let port = NetworkPort(name: name, media: media, isRelay: relayClients != nil, wiring: wiring)
        ports.append(port)
        return port
    }

    private func endpoint(_ port: NetworkPort) -> TransportEndpoint.State {
        TransportEndpoint.State(tcpClients: port.wiring.tcpClients,
                                auto: port.media.contains(.lan) ? AutoEndpoint.State() : nil)
    }

    /// A messaging client, not yet online. `configure` sets what the host would have set before
    /// launch (a display name, a stamp cost). With `ratchets`, the host enables ratchets on the
    /// delivery destination at every launch, as ReTiCAMsgr does.
    func messenger(_ name: String, on media: Set<Medium> = [.hub], ratchets: Bool = false,
                   configure: @escaping (inout LXMFNode.State) -> Void = { _ in }) -> Messenger {
        makeMessenger(name, identity: Identity(), media: media, linkLocal: newLinkLocal(),
                      ratchets: ratchets, configure: configure)
    }

    private func makeMessenger(_ name: String, identity: Identity, media: Set<Medium>, linkLocal: String,
                               ratchets: Bool, configure: @escaping (inout LXMFNode.State) -> Void) -> Messenger {
        let port = makePort(name, media, linkLocal: linkLocal)
        var state = LXMFNode.State(identity: identity, endpoint: endpoint(port))
        configure(&state)
        let journal = Messenger.Journal()
        let wiring = port.wiring
        let store = TestStore(initialState: state) {
            Tapped(base: LXMFNode()) { action in journal.record(action) }
        } withDependencies: {
            wiring.apply(&$0)
        }
        store.exhaustivity = .off
        let messenger = Messenger(name: name, identity: identity, store: store, port: port, journal: journal,
                                  ratchets: ratchets, configure: configure, world: self)
        messengers.append(messenger)
        return messenger
    }

    /// A node that is also an LXMF propagation node, not yet online. Its stamp cost is low so the
    /// real proof-of-work for a propagated copy takes no time worth noticing.
    func propagationHost(_ name: String, on media: Set<Medium> = [.hub]) -> PropagationHost {
        let port = makePort(name, media, linkLocal: newLinkLocal())
        let identity = Identity()
        let state = LXMFServiceNode.State(identity: identity, endpoint: endpoint(port), targetStampCost: 1)
        let stored = LockIsolated(0)
        let wiring = port.wiring
        let store = TestStore(initialState: state) {
            Tapped(base: LXMFServiceNode()) { action in
                guard case let .delegate(.messagesStored(entries)) = action else { return }
                stored.withValue { $0 += entries.count }
            }
        } withDependencies: {
            wiring.apply(&$0)
        }
        store.exhaustivity = .off
        let host = PropagationHost(name: name, identity: identity, store: store, port: port,
                                   stored: stored, world: self)
        propagationHosts.append(host)
        return host
    }

    /// The transport node every `.uplink` client connects to, not yet online. Create it AFTER the
    /// clients: it gets one connection per uplink client that exists now (a relaunched client keeps
    /// its connection).
    func relay(_ name: String = "relay") -> RelayHub {
        let clients = ports.filter { $0.media.contains(.uplink) }.map(\.name)
        let port = makePort(name, [], linkLocal: newLinkLocal(), relayClients: clients)
        let wiring = port.wiring
        let store = TestStore(initialState: endpoint(port)) {
            TransportEndpoint()
        } withDependencies: {
            wiring.apply(&$0)
        }
        store.exhaustivity = .off
        let relay = RelayHub(name: name, identity: Identity(), store: store, port: port, world: self)
        relays.append(relay)
        return relay
    }

    /// Bring these clients online, then have every client online announce, and give the network
    /// time to carry it, so everyone online has heard everyone else.
    func bringOnline(_ nodes: Messenger...) async {
        for node in nodes { await node.comeOnline() }
        // LAN peers must find each other before an announce can reach anyone.
        if nodes.contains(where: { $0.port.media.contains(.lan) }) { await advance(seconds: 5) }
        await introduce()
    }

    /// Every client online announces its delivery destination. A relay rebroadcasts after a short
    /// random wait, so time passes when anyone is behind one.
    func introduce() async {
        for node in messengers where node.port.online { await node.announce() }
        if !relays.isEmpty { await advance(seconds: 5) }
    }

    /// Let a minute pass, so nothing announced so far is still being repeated by a relay: what a
    /// node hears after this, it hears because of what the test does next.
    func quiet() async { await advance(seconds: 60, step: 5) }

    /// End `old`'s process and start a new one for the same person on the same device: same
    /// identity, same interfaces, same settings, an empty memory. `saved` is what the host hands
    /// back at launch (nil: nothing, a fresh install with a kept identity). The new client
    /// announces at launch, as every launch does; nobody else announces.
    func relaunch(_ old: Messenger, restoring saved: SavedSession?) async -> Messenger {
        await quit(old)
        let fresh = makeMessenger(old.name, identity: old.identity, media: old.port.media,
                                  linkLocal: old.port.wiring.linkLocal, ratchets: old.ratchets,
                                  configure: old.configure)
        await fresh.comeOnline(restoring: saved)
        return fresh
    }

    /// End a client's process. Nothing is told to anyone.
    func quit(_ node: Messenger) async {
        await node.store.send(.endpoint(.stop))
        await settle()
        node.port.online = false
        ports.removeAll { $0 === node.port }
        messengers.removeAll { $0 === node }
    }

    // MARK: Faults

    /// Cut the node off: nothing it writes arrives, and nothing reaches it. Its sockets stay open,
    /// as a phone out of range of its hub sees it until a timeout.
    func unplug(_ port: NetworkPort) { port.plugged = false }
    func plug(_ port: NetworkPort) { port.plugged = true }

    /// The next `count` frames this node writes to a TCP connection are lost on the way.
    func loseNextFrames(from port: NetworkPort, _ count: Int) { port.framesToLose += count }

    // MARK: Running

    /// Where a frame written to `socket` by `sender` arrives.
    private func destinations(of socket: Socket, from sender: NetworkPort) -> [Socket] {
        switch socket.role {
        case .segment:
            return ports.filter { $0 !== sender && $0.reachable }
                .compactMap { port in port.wiring.sockets.values.first { $0.role == .segment } }
        case .uplink:
            return ports.filter { $0.isRelay && $0.reachable }
                .compactMap { $0.wiring.sockets[Socket.downlinkKey(sender.name)] }
        case let .downlink(client):
            return ports.filter { $0.name == client && !$0.isRelay && $0.reachable }
                .compactMap { $0.wiring.sockets[Socket.uplinkKey()] }
        }
    }

    /// Carry everything written since the last pass. Returns whether anything moved.
    private func carry() async -> Bool {
        var moved = false
        for sender in ports {
            for socket in sender.wiring.sockets.values.sorted(by: { $0.key < $1.key }) {
                let frames = socket.out.value
                while sender.carried[socket.key, default: 0] < frames.count {
                    let frame = frames[sender.carried[socket.key, default: 0]]
                    sender.carried[socket.key, default: 0] += 1
                    moved = true
                    if sender.framesToLose > 0 {
                        sender.framesToLose -= 1
                        continue
                    }
                    guard sender.reachable else { continue }
                    for destination in destinations(of: socket, from: sender) {
                        destination.input.yield(.data(frame))
                    }
                    await Task.megaYield()
                }
            }
            let datagrams = sender.wiring.lanOut.value
            while sender.lanCarried < datagrams.count {
                let datagram = datagrams[sender.lanCarried]
                sender.lanCarried += 1
                moved = true
                guard sender.reachable else { continue }
                let source = sender.wiring.linkLocal
                for receiver in ports where receiver !== sender && receiver.reachable && receiver.media.contains(.lan) {
                    let nic = receiver.wiring.nic
                    let event: AutoSocketEvent
                    switch datagram {
                    case let .multicast(token):
                        event = .datagram(nic: nic.name, plane: .multicastDiscovery, source: source,
                                          sourceScope: nic.index, payload: token)
                    case let .unicast(addr, port, payload):
                        guard addr == receiver.wiring.linkLocal else { continue }
                        event = .datagram(nic: nic.name,
                                          plane: port == AutoInterfaceWire.defaultDataPort ? .data : .unicastDiscovery,
                                          source: source, sourceScope: nic.index, payload: payload)
                    }
                    receiver.wiring.lanSessions.value.last?.yield(event)
                }
                await Task.megaYield()
            }
        }
        return moved
    }

    private func drain() async {
        for node in messengers { await node.store.skipReceivedActions(strict: false) }
        for host in propagationHosts { await host.store.skipReceivedActions(strict: false) }
        for relay in relays { await relay.store.skipReceivedActions(strict: false) }
    }

    /// Run the network until nothing has moved for a while. Virtual time does not pass. Work a node
    /// does off the main actor (a stamp search) may still be going: wait for its result with
    /// `run(until:)`.
    func settle() async {
        var idle = 0
        while idle < 4 {
            await Task.megaYield()
            let moved = await carry()
            await drain()
            if moved {
                idle = 0
            } else {
                idle += 1
                try? await Task.sleep(for: .microseconds(300))
            }
        }
    }

    /// Run the network, without virtual time passing, until `done` holds. False when it never did
    /// within `timeout` of real time.
    @discardableResult
    func run(until done: () -> Bool, timeout: Duration = .seconds(20)) async -> Bool {
        let deadline = ContinuousClock.now + timeout
        while true {
            await settle()
            if done() { return true }
            if ContinuousClock.now >= deadline { return false }
            try? await Task.sleep(for: .milliseconds(2))
        }
    }

    /// Let virtual time pass, `step` seconds at a time, running the network after each step.
    /// Timers still fire in order inside a step; only the carrying of what they send waits for its
    /// end. Use a larger step for a long wait in which nothing has to arrive promptly (waiting out
    /// the retries to an unreachable peer): each step costs real time, and under a loaded test run
    /// hundreds of them add up.
    func advance(seconds: Int, step: Int = 1) async {
        var left = seconds
        while left > 0 {
            let now = min(step, left)
            await clock.advance(by: .seconds(now))
            await settle()
            left -= now
        }
    }

    /// Let up to `seconds` of virtual time pass, stopping as soon as `done` holds. At each second
    /// the nodes get a moment of real time to finish work they do off the main actor.
    @discardableResult
    func advance(upTo seconds: Int, until done: () -> Bool) async -> Bool {
        if await run(until: done, timeout: .milliseconds(50)) { return true }
        for _ in 0..<seconds {
            await clock.advance(by: .seconds(1))
            if await run(until: done, timeout: .milliseconds(50)) { return true }
        }
        return false
    }

    /// Stop every node.
    func shutDown() async {
        for node in messengers where node.port.online { await node.store.send(.endpoint(.stop)) }
        for host in propagationHosts where host.port.online { await host.store.send(.client(.endpoint(.stop))) }
        for relay in relays where relay.port.online { await relay.store.send(.stop) }
        await settle()
    }

    fileprivate func connect(_ port: NetworkPort) {
        port.online = true
        for socket in port.wiring.sockets.values { socket.input.yield(.connected) }
    }
}

private extension MessagingEvent {
    init?(_ delegate: LXMFNode.Action.Delegate) {
        switch delegate {
        case let .messageReceived(message, validated, method):
            self = .received(Received(content: String(decoding: message.content, as: UTF8.self),
                                      from: message.sourceHash, validated: validated, method: method))
        case let .deliveryConfirmed(hash): self = .confirmed(hash)
        case let .propagationAccepted(hash): self = .acceptedByPropagationNode(hash)
        case let .deliveryFailed(hash): self = .failed(hash)
        case let .deliveryRejected(hash): self = .rejected(hash)
        case let .deliveryCancelled(hash): self = .cancelled(hash)
        default: return nil
        }
    }
}

// MARK: - Nodes

/// A messaging client, driven the way the host app drives it.
@MainActor
final class Messenger {
    /// What the host app was told, and what it would have written to disk as it went.
    fileprivate final class Journal: Sendable {
        let events = LockIsolated<[MessagingEvent]>([])
        let receivedHashes = LockIsolated<[Data]>([])
        let lookedFor = LockIsolated<[Data]>([])
        let ratchetRing = LockIsolated<[Data]>([])

        func record(_ action: LXMFNode.Action) {
            switch action {
            case let .delegate(delegate):
                if case let .messageReceived(message, _, _) = delegate {
                    receivedHashes.withValue { $0.append(message.hash) }
                }
                if case let .deliveryPreparing(hash, .waitingForPeer) = delegate {
                    lookedFor.withValue { $0.append(hash) }
                }
                if let event = MessagingEvent(delegate) { events.withValue { $0.append(event) } }
            case let .endpoint(.delegate(.ratchetsChanged(_, ring))):
                ratchetRing.setValue(ring)
            default:
                break
            }
        }
    }

    let name: String
    let identity: Identity
    let store: TestStoreOf<LXMFNode>
    let port: NetworkPort
    fileprivate let ratchets: Bool
    fileprivate let configure: (inout LXMFNode.State) -> Void
    private let journal: Journal
    private unowned let world: MessagingWorld

    fileprivate init(name: String, identity: Identity, store: TestStoreOf<LXMFNode>, port: NetworkPort,
                     journal: Journal, ratchets: Bool, configure: @escaping (inout LXMFNode.State) -> Void,
                     world: MessagingWorld) {
        self.name = name
        self.identity = identity
        self.store = store
        self.port = port
        self.journal = journal
        self.ratchets = ratchets
        self.configure = configure
        self.world = world
    }

    /// This client's `lxmf.delivery` address.
    var address: Data { LXMessage.deliveryHash(identityHash: identity.hash) }

    // MARK: What the app was told

    /// Everything the host app has been told about messages, in order.
    var events: [MessagingEvent] { journal.events.value }

    /// Messages delivered to the app, in order.
    var inbox: [Received] {
        events.compactMap { if case let .received(r) = $0 { r } else { nil } }
    }

    /// The terminal outcomes reported for one outbound message, in order.
    func outcomes(of hash: Data) -> [MessagingEvent] { events.filter { $0.outboundHash == hash } }

    /// Whether the app was told this send is waiting to find its recipient ("Looking for them").
    func hadToLookForRecipient(of hash: Data) -> Bool { journal.lookedFor.value.contains(hash) }

    // MARK: What the app can read

    /// The name `other` announces, as this client's contact list would show it. Nil when no
    /// delivery announce of theirs has been heard (or restored).
    func nameKnown(for other: Messenger) -> String? { store.state.learnedPeers[other.address]?.displayName }

    /// Whether this client has heard (or been handed back) an announce of `other` at all.
    func hasHeardOf(_ other: Messenger) -> Bool { store.state.learnedPeers[other.address] != nil }

    /// Whether this client holds a route to `other`.
    func hasPath(to other: Messenger) -> Bool { store.state.endpoint.learned[other.address] != nil }

    /// The transport node the route to `other` goes through, or nil for a direct neighbour (or no route).
    func nextHop(to other: Messenger) -> Data? {
        guard let hop = store.state.endpoint.learned[other.address]?.nextHop, hop != other.address else { return nil }
        return hop
    }

    /// What the host has on disk right now.
    func saved() -> SavedSession {
        SavedSession(paths: store.state.endpoint.learned,
                     knownDestinations: store.state.endpoint.knownDestinations,
                     contacts: store.state.learnedPeers,
                     receivedMessages: journal.receivedHashes.value,
                     downloadedTransientIds: Array(store.state.router.downloadedTransientIds),
                     ratchetRing: journal.ratchetRing.value)
    }

    // MARK: What the app does

    /// Launch, in the order ReTiCAMsgr does it: ratchets, interfaces, what was saved, then (once
    /// connected) the delivery destination, which announces.
    func comeOnline(restoring saved: SavedSession? = nil) async {
        if ratchets {
            await store.send(.endpoint(.enableRatchets(destinationHash: address, ring: saved?.ratchetRing ?? [])))
        }
        await store.send(.endpoint(.start))
        if let saved {
            await store.send(.endpoint(.transport(.rehydrateKnownDestinations(saved.knownDestinations))))
            await store.send(.router(.rehydrateDedup(seenHashes: saved.receivedMessages,
                                                     downloadedTransientIds: saved.downloadedTransientIds)))
            await store.send(.rehydrateLearnedPeers(saved.contacts))
            await store.send(.endpoint(.transport(.rehydrateLearnedDestinations(saved.paths))))
            // The library restores routes but not whose signature to expect: ReTiCAMsgr writes the
            // router's `knownIdentities` itself for every restored delivery route (AppFeature,
            // `.rehydrateLearnedDestinations`). This is that step, through the router's own action.
            for (hash, path) in saved.paths where hash == LXMessage.deliveryHash(identityHash: path.identity.hash) {
                await store.send(.router(.learnedIdentity(destinationHash: hash, identity: path.identity)))
            }
        }
        world.connect(port)
        await world.settle()
        await store.send(.registerDelivery)
        await world.settle()
    }

    func announce() async {
        await store.send(.announceDelivery)
        await world.settle()
    }

    /// Change the display name and announce it.
    func rename(to name: String) async {
        await store.send(.setDisplayName(name, stampCost: store.state.deliveryStampCost))
        await announce()
    }

    /// Ask the network for a route to `other`.
    func lookUp(_ other: Messenger) async {
        await store.send(.endpoint(.requestPath(destinationHash: other.address)))
        await world.settle()
    }

    /// Send a text message as the app does. Returns its hash, which the outcomes name.
    @discardableResult
    func send(_ text: String, to recipient: Messenger, fallbackToPropagation: Bool = false) async -> Data {
        let message = LXMessage.create(source: identity, destinationHash: recipient.address,
                                       timestamp: world.now.timeIntervalSince1970,
                                       title: Data(), content: Data(text.utf8))
        await store.send(.sendMessage(message: message, fallbackToPropagation: fallbackToPropagation))
        await world.settle()
        return message.hash
    }

    func usePropagationNode(_ host: PropagationHost) async {
        await store.send(.setPropagationNode(destinationHash: host.address))
        await world.settle()
    }

    /// Ask the propagation node for waiting messages.
    func sync() async {
        await store.send(.syncFromPropagationNode)
        await world.settle()
    }
}

/// A node serving as an LXMF propagation node.
@MainActor
final class PropagationHost {
    let name: String
    let identity: Identity
    let store: TestStoreOf<LXMFServiceNode>
    let port: NetworkPort
    private let stored: LockIsolated<Int>
    private unowned let world: MessagingWorld

    fileprivate init(name: String, identity: Identity, store: TestStoreOf<LXMFServiceNode>, port: NetworkPort,
                     stored: LockIsolated<Int>, world: MessagingWorld) {
        self.name = name
        self.identity = identity
        self.store = store
        self.port = port
        self.stored = stored
        self.world = world
    }

    /// This node's `lxmf.propagation` address.
    var address: Data {
        Destination.hash(identityHash: identity.hash, appName: LXMessage.appName, aspects: ["propagation"])
    }

    /// How many messages it has reported storing.
    var storedCount: Int { stored.value }

    /// Launch with node mode on: registers and announces the propagation destination.
    func comeOnline() async {
        await store.send(.client(.endpoint(.start)))
        world.connect(port)
        await world.settle()
        await store.send(.setNodeMode(true))
        await world.settle()
    }
}

/// A transport node: it relays for the clients connected to it and holds no destination of its own.
@MainActor
final class RelayHub {
    let name: String
    let identity: Identity
    let store: TestStoreOf<TransportEndpoint>
    let port: NetworkPort
    private unowned let world: MessagingWorld

    fileprivate init(name: String, identity: Identity, store: TestStoreOf<TransportEndpoint>, port: NetworkPort,
                     world: MessagingWorld) {
        self.name = name
        self.identity = identity
        self.store = store
        self.port = port
        self.world = world
    }

    /// The transport id routes through this relay name as their next hop.
    var transportID: Data { identity.hash }

    func comeOnline() async {
        await store.send(.start)
        world.connect(port)
        await world.settle()
        await store.send(.enableRelay(identity))
        await world.settle()
    }
}
