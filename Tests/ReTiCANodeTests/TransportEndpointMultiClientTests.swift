import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// `TransportEndpoint.tcpClients` is a SET of TCP-client drivers over the one shared router. These
// pin the container wiring by id: both clients register, inbound bytes are tagged with the
// arriving client's id, outbound bytes reach the owning client, one client's explicit disconnect
// touches only its own interface, the shared maintenance loop stops with the LAST client, and
// `removeTCPClient` deregisters, closes that client's socket and drops its slot.

private let idA = InterfaceID("tcp:a:4242")
private let idB = InterfaceID("tcp:b:4242")
private let keyA = "a:4242"
private let keyB = "b:4242"

/// A keyed mock pool: one PRE-MADE event stream per "host:port" (so a test can yield before the
/// interface starts reading), sends recorded by key, evictions and closes recorded in ONE ordered
/// log (`events`: `"evict:<key>"` / `"close:<key>"`), and a close signal to await.
private struct KeyedPool {
    let streams: [String: AsyncStream<TCPEvent>]
    let continuations: [String: AsyncStream<TCPEvent>.Continuation]
    let sends = LockIsolated<[String]>([])
    let events = LockIsolated<[String]>([])
    let closed = AsyncStream<String>.makeStream()

    /// The keys closed so far, in order.
    var closedLog: [String] {
        events.value.compactMap { $0.hasPrefix("close:") ? String($0.dropFirst("close:".count)) : nil }
    }

    init(keys: [String]) {
        var streams: [String: AsyncStream<TCPEvent>] = [:]
        var continuations: [String: AsyncStream<TCPEvent>.Continuation] = [:]
        for key in keys {
            let (stream, continuation) = AsyncStream<TCPEvent>.makeStream()
            streams[key] = stream
            continuations[key] = continuation
        }
        self.streams = streams
        self.continuations = continuations
    }

    var pool: TCPConnectionPool {
        let streams = self.streams
        let sends = self.sends
        let events = self.events
        let closedContinuation = self.closed.continuation
        return TCPConnectionPool(
            connection: { key in
                TCPConnection(
                    open: { _, _ in streams[key] ?? .finished },
                    send: { _ in sends.withValue { $0.append(key) } },
                    close: {
                        events.withValue { $0.append("close:\(key)") }
                        closedContinuation.yield(key)
                    })
            },
            evict: { key in events.withValue { $0.append("evict:\(key)") } })
    }

    func yield(_ key: String, _ event: TCPEvent) { continuations[key]?.yield(event) }
}

/// The next close signal, or nil after `seconds`: a lost close must fail the test, not hang the
/// suite. The stream is made once per pool and read here only, so there is exactly one consumer.
private func nextClose(_ keyed: KeyedPool, within seconds: Double = 5) async -> String? {
    let stream = keyed.closed.stream
    return await withTaskGroup(of: String?.self) { group in
        group.addTask {
            var iterator = stream.makeAsyncIterator()
            return await iterator.next()
        }
        group.addTask {
            try? await Task.sleep(for: .seconds(seconds))
            return nil
        }
        let first = await group.next() ?? nil
        group.cancelAll()
        return first
    }
}

/// Records every `.transport(.startMaintenance)` / `.stopMaintenance` the container processes.
private struct MaintenanceLog<Wrapped: Reducer>: Reducer
where Wrapped.State == TransportEndpoint.State, Wrapped.Action == TransportEndpoint.Action {
    let log: LockIsolated<[String]>
    let wrapped: Wrapped
    init(log: LockIsolated<[String]>, @ReducerBuilder<State, Action> _ wrapped: () -> Wrapped) {
        self.log = log
        self.wrapped = wrapped()
    }
    func reduce(into state: inout TransportEndpoint.State, action: TransportEndpoint.Action)
        -> Effect<TransportEndpoint.Action> {
        if case .transport(.startMaintenance) = action { log.withValue { $0.append("start") } }
        if case .transport(.stopMaintenance) = action { log.withValue { $0.append("stop") } }
        return wrapped.reduce(into: &state, action: action)
    }
}

private func twoClientState(configure: (inout TransportEndpoint.State) -> Void = { _ in }) -> TransportEndpoint.State {
    var state = TransportEndpoint.State(tcpClients: [
        TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false, interfaceID: idA),
        TCPEndpoint.State(host: "b", port: 4242, reconnectOnDrop: false, interfaceID: idB),
    ])
    configure(&state)
    return state
}

@MainActor
private func makeTwoClients(log: LockIsolated<[String]>? = nil,
                            configure: (inout TransportEndpoint.State) -> Void = { _ in })
    -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, KeyedPool) {
    let keyed = KeyedPool(keys: [keyA, keyB])
    let store = TestStore(initialState: twoClientState(configure: configure)) {
        MaintenanceLog(log: log ?? LockIsolated([])) { TransportEndpoint() }
    } withDependencies: {
        $0.tcpConnectionPool = keyed.pool
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return (store, keyed)
}

/// Start both clients and bring both sockets up. Receives both registrations in either order.
@MainActor
private func connectBoth(_ store: TestStore<TransportEndpoint.State, TransportEndpoint.Action>, _ keyed: KeyedPool) async {
    await store.send(.start)
    keyed.yield(keyA, .connected)
    keyed.yield(keyB, .connected)
    for _ in 0..<2 {
        await store.receive { if case .transport(.interfaceConnected) = $0 { return true }; return false }
    }
}

private func announcePacket(identity: Identity) -> (raw: Data, destHash: Data) {
    let nameHash = Destination.nameHash(appName: "app", aspects: ["svc"])
    let destHash = Destination.hash(identityHash: identity.hash, appName: "app", aspects: ["svc"])
    let randomHash = Announce.randomHash(now: 1000, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 3,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

private func activeLink(id: UUID, on interfaceID: InterfaceID, linkID: Data) -> LinkSession.State {
    var link = LinkSession.State(id: id, responderFor: Identity(),
                                 destinationHash: Data(repeating: 0x02, count: 16), interfaceID: interfaceID)
    link.status = .active
    link.sessionKey = Data(repeating: 0x01, count: 64)
    link.linkID = linkID
    link.rtt = 1.0
    return link
}

@Test @MainActor func multiClientBothConnectAndRegisterAndStopDisconnectsBoth() async {
    let (store, keyed) = makeTwoClients()
    await connectBoth(store, keyed)
    #expect(store.state.interfaces[idA] == .tcpClient)
    #expect(store.state.interfaces[idB] == .tcpClient)

    await store.send(.stop)
    for _ in 0..<2 {
        await store.receive { if case .tcpClients(.element(_, .disconnect)) = $0 { return true }; return false }
    }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.isEmpty, "stop must deregister every client")
}

@Test @MainActor func multiClientPacketReceivedIsTaggedWithItsClientsID() async {
    let (store, keyed) = makeTwoClients()
    await connectBoth(store, keyed)
    let (raw, destHash) = announcePacket(identity: Identity())
    keyed.yield(keyB, .data(HDLC.frame(raw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(store.state.learned[destHash]?.interfaceID == idB,
            "a packet read from client B must enter the router tagged with B's id")
    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

@Test @MainActor func multiClientTransmitRoutesToTheOwningClient() async {
    let (store, keyed) = makeTwoClients()
    await connectBoth(store, keyed)
    let bytes = Data([1, 2, 3])
    await store.send(.transport(.delegate(.transmit(idB, bytes))))
    await store.receive(.tcpClients(.element(id: idB, action: .interface(.send(bytes)))))
    await store.receive { if case .tcpClients(.element(id: idB, action: .interface(.writerFinished))) = $0 { return true }; return false }
    #expect(keyed.sends.value == [keyB], "only client B's socket may carry a frame addressed to idB")
    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

@Test @MainActor func multiClientExplicitDisconnectDeregistersOnlyThatInterface() async {
    let linkOnA = Data(repeating: 0xAA, count: 16)
    let linkOnB = Data(repeating: 0xBB, count: 16)
    let (store, keyed) = makeTwoClients { state in
        state.linkPlane.links.append(activeLink(id: UUID(0), on: idA, linkID: linkOnA))
        state.linkPlane.links.append(activeLink(id: UUID(1), on: idB, linkID: linkOnB))
    }
    await connectBoth(store, keyed)

    await store.send(.tcpClients(.element(id: idA, action: .disconnect)))
    await store.receive { if case .transport(.interfaceDisconnected(idA)) = $0 { return true }; return false }
    await store.receive { if case .linkPlane(.interfaceDisconnected(idA)) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces[idA] == nil)
    #expect(store.state.interfaces[idB] == .tcpClient, "B's interface must survive A's disconnect")
    #expect(store.state.links[id: UUID(0)]?.rehomePermitted == true, "A's link learned its interface is gone")
    #expect(store.state.links[id: UUID(1)]?.rehomePermitted == false, "B's link must be untouched")
    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

@Test @MainActor func multiClientMaintenanceStopsOnlyWhenTheLastClientDeparts() async {
    let log = LockIsolated<[String]>([])
    let (store, keyed) = makeTwoClients(log: log)
    await connectBoth(store, keyed)
    #expect(log.value == ["start"], "the 0→1 transition arms maintenance exactly once")

    keyed.yield(keyA, .disconnected(reason: nil))
    await store.receive { if case .transport(.interfaceDisconnected(idA)) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(log.value.filter { $0 == "stop" }.isEmpty, "B is still up, so maintenance must stay armed")

    keyed.yield(keyB, .disconnected(reason: nil))
    await store.receive { if case .transport(.interfaceDisconnected(idB)) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(log.value.filter { $0 == "stop" }.count == 1, "the last client's departure stops maintenance")
}

@Test func multiClientTCPFactoryYieldsAOneElementSet() {
    let state = TransportEndpoint.State.tcp(TCPEndpoint.State(host: "h", port: 1, reconnectOnDrop: false))
    #expect(state.tcpClients.ids == [InterfaceID("tcp")])
    #expect(state.tcpClients[id: InterfaceID("tcp")]?.interface.host == "h")
}

@Test @MainActor func multiClientRemoveTCPClientDeregistersAndDropsTheSlot() async {
    let (store, keyed) = makeTwoClients()
    await connectBoth(store, keyed)

    await store.send(.removeTCPClient(idA))
    await store.receive { if case .transport(.interfaceDisconnected(idA)) = $0 { return true }; return false }
    await store.receive { if case .linkPlane(.interfaceDisconnected(idA)) = $0 { return true }; return false }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.tcpClients[id: idA] == nil, "the removed client's slot is gone")
    #expect(store.state.tcpClients[id: idB] != nil, "the other client's slot stays")
    #expect(store.state.interfaces[idA] == nil)
    #expect(store.state.interfaces[idB] == .tcpClient)
    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

@Test @MainActor func multiClientRemoveTCPClientClosesThatClientsSocket() async {
    let (store, keyed) = makeTwoClients()
    await connectBoth(store, keyed)

    await store.send(.removeTCPClient(idA))
    await store.skipReceivedActions(strict: false)
    let first = await nextClose(keyed)
    #expect(first == keyA, "removal must close the removed client's socket")
    #expect(keyed.closedLog == [keyA], "and only that one")
    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

/// The pool entry is retired before the (async) close, so a slot re-added for the same host:port
/// meanwhile dials a fresh actor and this close can only hit the old one.
@Test @MainActor func multiClientRemoveTCPClientEvictsBeforeItCloses() async {
    let (store, keyed) = makeTwoClients()
    await connectBoth(store, keyed)

    await store.send(.removeTCPClient(idA))
    await store.skipReceivedActions(strict: false)
    _ = await nextClose(keyed)
    #expect(keyed.events.value == ["evict:\(keyA)", "close:\(keyA)"])
    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

@Test @MainActor func multiClientRemoveUnknownClientIsANoOp() async {
    let (store, _) = makeTwoClients()
    store.exhaustivity = .on
    // An exhaustive send fails if the reducer mutates state or emits any action.
    await store.send(.removeTCPClient(InterfaceID("tcp:nobody:1")))
}
