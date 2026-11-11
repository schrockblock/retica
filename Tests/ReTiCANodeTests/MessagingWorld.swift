import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// MARK: - A small simulated network of real nodes
//
// Support for `MessagingIntegrationTests`. Each node is a REAL `LXMFNode` (or `LXMFServiceNode`)
// store; only the sockets are replaced. Everything a node writes is carried to the other nodes by
// the world, so a test never bridges a frame by hand and never names an internal action: it sends
// a message the way the host app does and reads back what the host app would be told.
//
// Two media, and a node may sit on either or both:
//  - `.hub`: every node's TCP client reaches every other node on the hub (a shared segment; the
//    nodes are leaves, so nothing relays).
//  - `.lan`: AutoInterface. Multicast discovery reaches every node on the LAN, unicast reaches the
//    node holding that link-local address.
//
// Faults: `unplug`/`plug` a node, or `loseNextFrames(from:)`.

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

enum Medium: Hashable, Sendable { case hub, lan }

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

/// One node's attachment to the simulated network: what its mock sockets wrote, and where to hand
/// it what the others wrote.
@MainActor
final class NetworkPort {
    let name: String
    let media: Set<Medium>
    fileprivate let wiring: Wiring
    fileprivate var hubCarried = 0
    fileprivate var lanCarried = 0
    fileprivate var online = false
    fileprivate var plugged = true
    fileprivate var framesToLose = 0

    fileprivate init(name: String, media: Set<Medium>, wiring: Wiring) {
        self.name = name
        self.media = media
        self.wiring = wiring
    }

    fileprivate var reachable: Bool { online && plugged }
}

/// The mock sockets of one node. Sendable, so the dependency closures can hold it.
private struct Wiring: Sendable {
    let hubIn: AsyncStream<TCPEvent>
    let hubInContinuation: AsyncStream<TCPEvent>.Continuation
    let hubOut = LockIsolated<[Data]>([])
    let nic: AutoNIC
    let lanOut = LockIsolated<[AutoDatagram]>([])
    let lanSessions = LockIsolated<[AsyncStream<AutoSocketEvent>.Continuation]>([])
    let clock: TestClock<Duration>
    let epoch: TestClock<Duration>.Instant

    var linkLocal: String { nic.linkLocals[0] }

    func apply(_ values: inout DependencyValues) {
        values.tcpConnection = TCPConnection(
            open: { _, _ in hubIn },
            send: { frame in hubOut.withValue { $0.append(frame) } },
            close: { })
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

    init() { epoch = clock.now }

    /// Virtual time since the world began. Zero means no timer of any node has had to fire.
    var elapsed: Duration { epoch.duration(to: clock.now) }

    var now: Date {
        let d = elapsed.components
        return MessagingWorld.base.addingTimeInterval(Double(d.seconds) + Double(d.attoseconds) / 1e18)
    }

    // MARK: Building nodes

    private func makePort(_ name: String, _ media: Set<Medium>) -> NetworkPort {
        let hub = AsyncStream<TCPEvent>.makeStream()
        let nic = AutoNIC(name: "en0", index: 4, linkLocals: ["fe80::\(ports.count + 1)"])
        let port = NetworkPort(name: name, media: media, wiring: Wiring(
            hubIn: hub.stream, hubInContinuation: hub.continuation, nic: nic, clock: clock, epoch: epoch))
        ports.append(port)
        return port
    }

    private func endpoint(_ name: String, _ media: Set<Medium>) -> TransportEndpoint.State {
        TransportEndpoint.State(
            tcpClients: media.contains(.hub) ? [TCPEndpoint.State(host: name, port: 4242, reconnectOnDrop: false)] : [],
            auto: media.contains(.lan) ? AutoEndpoint.State() : nil)
    }

    /// A messaging client, not yet online. `configure` sets what the host would have set before
    /// launch (a stamp cost, for example).
    func messenger(_ name: String, on media: Set<Medium> = [.hub],
                   configure: (inout LXMFNode.State) -> Void = { _ in }) -> Messenger {
        let port = makePort(name, media)
        let identity = Identity()
        var state = LXMFNode.State(identity: identity, endpoint: endpoint(name, media))
        configure(&state)
        let journal = LockIsolated<[MessagingEvent]>([])
        let wiring = port.wiring
        let store = TestStore(initialState: state) {
            Tapped(base: LXMFNode()) { action in
                guard case let .delegate(delegate) = action, let event = MessagingEvent(delegate) else { return }
                journal.withValue { $0.append(event) }
            }
        } withDependencies: {
            wiring.apply(&$0)
        }
        store.exhaustivity = .off
        let messenger = Messenger(name: name, identity: identity, store: store, port: port,
                                  journal: journal, world: self)
        messengers.append(messenger)
        return messenger
    }

    /// A node that is also an LXMF propagation node, not yet online. Its stamp cost is low so the
    /// real proof-of-work for a propagated copy takes no time worth noticing.
    func propagationHost(_ name: String, on media: Set<Medium> = [.hub]) -> PropagationHost {
        let port = makePort(name, media)
        let identity = Identity()
        let state = LXMFServiceNode.State(identity: identity, endpoint: endpoint(name, media), targetStampCost: 1)
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

    /// Bring these clients online, then have every client online announce, so everyone online has
    /// heard everyone else (as a hub replaying its announce cache would arrange).
    func bringOnline(_ nodes: Messenger...) async {
        for node in nodes { await node.comeOnline() }
        // LAN peers must find each other before an announce can reach anyone.
        if nodes.contains(where: { $0.port.media.contains(.lan) }) { await advance(seconds: 5) }
        await introduce()
    }

    /// Every client online announces its delivery destination.
    func introduce() async {
        for node in messengers where node.port.online { await node.announce() }
    }

    // MARK: Faults

    /// Cut the node off: nothing it writes arrives, and nothing reaches it. Its sockets stay open,
    /// as a phone out of range of its hub sees it until a timeout.
    func unplug(_ port: NetworkPort) { port.plugged = false }
    func plug(_ port: NetworkPort) { port.plugged = true }

    /// The next `count` frames this node writes to the hub are lost on the way.
    func loseNextFrames(from port: NetworkPort, _ count: Int) { port.framesToLose += count }

    // MARK: Running

    /// Carry everything written since the last pass. Returns whether anything moved.
    private func carry() async -> Bool {
        var moved = false
        for sender in ports {
            let frames = sender.wiring.hubOut.value
            while sender.hubCarried < frames.count {
                let frame = frames[sender.hubCarried]
                sender.hubCarried += 1
                moved = true
                if sender.framesToLose > 0 {
                    sender.framesToLose -= 1
                    continue
                }
                guard sender.reachable else { continue }
                for receiver in ports where receiver !== sender && receiver.reachable && receiver.media.contains(.hub) {
                    receiver.wiring.hubInContinuation.yield(.data(frame))
                }
                await Task.megaYield()
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

    /// Let virtual time pass, a second at a time, running the network after each.
    func advance(seconds: Int) async {
        for _ in 0..<seconds {
            await clock.advance(by: .seconds(1))
            await settle()
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
        await settle()
    }

    fileprivate func connect(_ port: NetworkPort) {
        port.online = true
        if port.media.contains(.hub) { port.wiring.hubInContinuation.yield(.connected) }
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
    let name: String
    let identity: Identity
    let store: TestStoreOf<LXMFNode>
    let port: NetworkPort
    private let journal: LockIsolated<[MessagingEvent]>
    private unowned let world: MessagingWorld

    fileprivate init(name: String, identity: Identity, store: TestStoreOf<LXMFNode>, port: NetworkPort,
                     journal: LockIsolated<[MessagingEvent]>, world: MessagingWorld) {
        self.name = name
        self.identity = identity
        self.store = store
        self.port = port
        self.journal = journal
        self.world = world
    }

    /// This client's `lxmf.delivery` address.
    var address: Data { LXMessage.deliveryHash(identityHash: identity.hash) }

    /// Everything the host app has been told, in order.
    var events: [MessagingEvent] { journal.value }

    /// Messages delivered to the app, in order.
    var inbox: [Received] {
        events.compactMap { if case let .received(r) = $0 { r } else { nil } }
    }

    /// The terminal outcomes reported for one outbound message, in order.
    func outcomes(of hash: Data) -> [MessagingEvent] { events.filter { $0.outboundHash == hash } }

    /// Launch: open the interfaces and register (and announce) the delivery destination.
    func comeOnline() async {
        await store.send(.endpoint(.start))
        world.connect(port)
        await world.settle()
        await store.send(.registerDelivery)
        await world.settle()
    }

    func announce() async {
        await store.send(.announceDelivery)
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
