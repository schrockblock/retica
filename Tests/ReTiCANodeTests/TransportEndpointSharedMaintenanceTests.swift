import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// MARK: - Shared maintenance loop across MULTIPLE drivers (fix-wave Finding 1)
//
// `TransportEndpoint` runs up to three kind-slot drivers over ONE shared `Transport` router. That
// router has ONE maintenance loop (path-expiry GC, link-table GC, discovery-request GC) for the
// WHOLE node. The bug being regressed: each driver used to arm/stop maintenance off its OWN
// interface map, so on a multi-driver node (the slice's opt-in client+listener runs tcpClient AND
// tcpServer at once) one driver losing its LAST interface stopped maintenance for the STILL-LIVE
// interfaces of the other driver.
//
// The fix drives start/stop off the SHARED `transport.interfaces` count in one rule:
//   * arm on the node's 0→1 transition;
//   * stop only on the node's 1→0 transition (last interface across ALL drivers).
//
// These tests assert the actual maintenance BEHAVIOUR (a learned path is/ isn't swept by the tick)
// where possible, and the `.startMaintenance`/`.stopMaintenance` effects otherwise. All observe
// only through the unified surface + dependencies; anti-vacuity: assert after effects drain.

/// A single `TransportEndpoint` running BOTH a tcpClient driver and a tcpServer driver at once —
/// exactly the multi-driver node the slice enables. Returns the store plus each driver's inbound
/// event continuation, and the wall clock + tick clock the shared maintenance GC reads.
@MainActor
private func makeClientPlusServer()
    -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>,
        AsyncStream<TCPEvent>.Continuation,           // client inbound
        AsyncStream<TCPListenerEvent>.Continuation,   // server inbound
        LockIsolated<Date>,
        TestClock<Duration>) {
    let clientEvents = AsyncStream<TCPEvent>.makeStream()
    let serverEvents = AsyncStream<TCPListenerEvent>.makeStream()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let clock = TestClock<Duration>()
    let initial = TransportEndpoint.State(
        tcpClients: [TCPEndpoint.State(host: "peer", port: 4242, reconnectOnDrop: false)],
        tcpServer: TCPServerEndpoint.State(port: 5252, profile: .tcp))
    let store = TestStore(initialState: initial) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in clientEvents.stream },
                                         send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in serverEvents.stream },
                                     send: { _, _ in }, close: { _ in }, stop: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { now.value }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return (store, clientEvents.continuation, serverEvents.continuation, now, clock)
}

private func makeAnnouncePacket(identity: Identity, appName: String, aspects: [String],
                                hops: UInt8, emitted: UInt64) -> (Data, Data) {
    let nameHash = Destination.nameHash(appName: appName, aspects: aspects)
    let destHash = Destination.hash(identityHash: identity.hash, appName: appName, aspects: aspects)
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

// ═════════════════════════════════════════════════════════════════════════════
// (a) Dropping ONE driver's LAST interface must NOT stop maintenance while the OTHER driver still
// has a live interface. Proven behaviourally: after the partial drop, a path learned on the STILL-
// LIVE server connection is still swept by the maintenance tick — the loop is alive.
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func partialDropKeepsSharedMaintenanceAliveForTheLiveDriver() async throws {
    let (store, clientEvents, serverEvents, now, clock) = makeClientPlusServer()
    let conn = TCPConnID(1)
    let serverIfID = tcpServerInterfaceID(conn)

    await store.send(.start)
    // Client connects (0→1: arms maintenance) and server accepts a connection (1→2: no re-arm).
    clientEvents.yield(.connected)
    serverEvents.yield(.started)
    serverEvents.yield(.accepted(conn))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.count == 2, "both drivers' interfaces must be up")

    // Learn a path over the SERVER connection (so it names the server interface, not the client).
    let remote = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["svc"], hops: 3, emitted: 1000)
    serverEvents.yield(.data(conn, HDLC.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(store.state.learned[destHash]?.interfaceID == serverIfID,
            "the path must be learned on the still-live server interface")

    // The CLIENT driver loses its ONLY interface. Under the bug this stopped shared maintenance.
    clientEvents.yield(.disconnected(reason: nil))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces[serverIfID] != nil, "the server interface must still be live")
    #expect(store.state.interfaces.count == 1, "only the server interface remains")

    // Age past expiry and fire one tick. If maintenance is still alive (fix), the path is swept.
    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.learned[destHash] == nil,
            "maintenance must stay alive after a partial drop and sweep the expired path")

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

// ═════════════════════════════════════════════════════════════════════════════
// (b) Dropping the FINAL interface across ALL drivers DOES stop maintenance: after the last drop a
// path can no longer be swept by a tick, because the loop is cancelled. Proven behaviourally by
// contrast with (a): same aging + tick, but with NO live interface, the path survives.
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func finalDropAcrossAllDriversStopsSharedMaintenance() async throws {
    let (store, clientEvents, serverEvents, now, clock) = makeClientPlusServer()
    let conn = TCPConnID(1)
    let serverIfID = tcpServerInterfaceID(conn)

    await store.send(.start)
    clientEvents.yield(.connected)
    serverEvents.yield(.started)
    serverEvents.yield(.accepted(conn))
    await store.skipReceivedActions(strict: false)

    // Learn a path over the server connection.
    let remote = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["svc"], hops: 3, emitted: 1000)
    serverEvents.yield(.data(conn, HDLC.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(store.state.learned[destHash]?.interfaceID == serverIfID)

    // Drop BOTH drivers' interfaces: client first (2→1, maintenance must stay up), then the server
    // connection (1→0, the node's LAST interface → maintenance stops).
    clientEvents.yield(.disconnected(reason: nil))
    serverEvents.yield(.closed(conn, reason: nil))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.isEmpty, "all interfaces across all drivers must be gone")

    // Age past expiry and fire a tick. With maintenance stopped, nothing sweeps the path.
    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.learned[destHash] != nil,
            "with all interfaces gone maintenance is stopped, so no tick sweeps the path")

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

// ═════════════════════════════════════════════════════════════════════════════
// (c) Arm side: bringing the FIRST interface up arms maintenance EXACTLY ONCE across the node — a
// second driver's interface coming up must NOT re-arm. Asserted on the `.startMaintenance` effect
// itself, counting occurrences across both drivers' connect arms.
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func firstInterfaceArmsMaintenanceExactlyOnceAcrossDrivers() async throws {
    // Count maintenance actions DETERMINISTICALLY by recording each action the reducer processes
    // exactly once (a scanning TestStore `receive` predicate is re-invoked per action, so counting
    // inside it is unreliable). `MaintenanceRecorder` appends every action, then runs the real
    // `TransportEndpoint`.
    // Record a compact, Sendable marker per maintenance action ("start" / "stop"), in order.
    let log = LockIsolated<[String]>([])
    let clientEvents = AsyncStream<TCPEvent>.makeStream()
    let serverEvents = AsyncStream<TCPListenerEvent>.makeStream()
    let initial = TransportEndpoint.State(
        tcpClients: [TCPEndpoint.State(host: "peer", port: 4242, reconnectOnDrop: false)],
        tcpServer: TCPServerEndpoint.State(port: 5252, profile: .tcp))
    let store = TestStore(initialState: initial) {
        MaintenanceRecorder(log: log) { TransportEndpoint() }
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in clientEvents.stream }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in serverEvents.stream },
                                     send: { _, _ in }, close: { _ in }, stop: { })
        $0.continuousClock = TestClock<Duration>()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 0) }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    let conn = TCPConnID(1)

    await store.send(.start)

    // First interface up (client connects): 0→1 across the node.
    clientEvents.continuation.yield(.connected)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.count == 1, "first interface (client) must be up")

    // Second interface up (server accepts) with the client ALREADY registered: 1→2.
    serverEvents.continuation.yield(.started)
    serverEvents.continuation.yield(.accepted(conn))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.count == 2, "both interfaces must be up")

    let starts = log.value.filter { $0 == "start" }.count
    let stops = log.value.filter { $0 == "stop" }.count
    #expect(starts == 1,
            "maintenance must be armed exactly once (only the 0→1 node transition), not per driver; saw \(starts)")
    #expect(stops == 0, "no interface was lost, so maintenance must never stop; saw \(stops)")

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}

/// A transparent wrapper that records every action processed by the wrapped reducer, exactly once,
/// so a test can count actions deterministically without a re-invoked scanning predicate.
private struct MaintenanceRecorder<Wrapped: Reducer>: Reducer
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
        if case let .transport(.interfaceDisconnected(id)) = action { log.withValue { $0.append("disc:" + id.rawValue) } }
        if case let .linkPlane(.interfaceDisconnected(id)) = action { log.withValue { $0.append("linkdisc:" + id.rawValue) } }
        return wrapped.reduce(into: &state, action: action)
    }
}

// ═════════════════════════════════════════════════════════════════════════════
// (d) Stopping a TCP-server endpoint closes its accepted connections: stopping the listener cancels
// its event effect, so no `.closed` reaches the reducer, and the endpoint must report each accepted
// connection disconnected itself — else the interfaces stay registered and the shared loop never stops.
// ═════════════════════════════════════════════════════════════════════════════

@MainActor
private func makeServerOnly(log: LockIsolated<[String]>, listenerStops: LockIsolated<Int> = LockIsolated(0))
    -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>,
        AsyncStream<TCPListenerEvent>.Continuation, LockIsolated<Date>, TestClock<Duration>) {
    let serverEvents = AsyncStream<TCPListenerEvent>.makeStream()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let clock = TestClock<Duration>()
    let store = TestStore(initialState: TransportEndpoint.State.tcpServer(
        TCPServerEndpoint.State(port: 5252, profile: .tcp))) {
        MaintenanceRecorder(log: log) { TransportEndpoint() }
    } withDependencies: {
        $0.tcpListener = TCPListener(listen: { _ in serverEvents.stream },
                                     send: { _, _ in }, close: { _ in },
                                     stop: { listenerStops.withValue { $0 += 1 } })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { now.value }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return (store, serverEvents.continuation, now, clock)
}

@Test @MainActor func stoppingAServerDisconnectsEveryAcceptedConnectionAndStopsMaintenance() async throws {
    let log = LockIsolated<[String]>([])
    let (store, serverEvents, now, clock) = makeServerOnly(log: log)
    let (a, b) = (TCPConnID(1), TCPConnID(2))

    await store.send(.start)
    serverEvents.yield(.started)
    serverEvents.yield(.accepted(a))
    serverEvents.yield(.accepted(b))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.count == 2)

    let remote = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: remote, appName: "app",
                                                     aspects: ["svc"], hops: 3, emitted: 1000)
    serverEvents.yield(.data(a, HDLC.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.isEmpty, "both accepted connections must leave the router")
    #expect(store.state.tcpServer?.connInterfaces.isEmpty == true)
    let disconnected = log.value.filter { $0.hasPrefix("disc:") }
    #expect(Set(disconnected) == ["disc:\(tcpServerInterfaceID(a).rawValue)", "disc:\(tcpServerInterfaceID(b).rawValue)"])
    #expect(disconnected.count == 2, "each connection is reported exactly once")
    #expect(Set(log.value.filter { $0.hasPrefix("linkdisc:") })
            == ["linkdisc:\(tcpServerInterfaceID(a).rawValue)", "linkdisc:\(tcpServerInterfaceID(b).rawValue)"],
            "the link plane must hear each departure too")
    #expect(log.value.filter { $0 == "stop" }.count == 1, "the shared loop stops once, at the last interface")

    // The loop is really gone: aging past expiry and ticking sweeps nothing.
    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.learned[destHash] != nil, "with the loop stopped no tick sweeps the path")
}

@Test @MainActor func aLateCloseAfterTheStopIsNotReportedASecondTime() async throws {
    let log = LockIsolated<[String]>([])
    let (store, serverEvents, _, _) = makeServerOnly(log: log)
    let conn = TCPConnID(1)

    await store.send(.start)
    serverEvents.yield(.started)
    serverEvents.yield(.accepted(conn))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.count == 1)

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.isEmpty)
    #expect(log.value.filter { $0.hasPrefix("disc:") }.count == 1)

    // A `.closed` that was already in flight when the stop landed.
    await store.send(.tcpServer(.interface(.listenerEvent(.closed(conn, reason: nil)))))
    await store.skipReceivedActions(strict: false)
    #expect(log.value.filter { $0.hasPrefix("disc:") }.count == 1,
            "a connection already reported disconnected must not be reported again")
    #expect(log.value.filter { $0 == "stop" }.count == 1)
    #expect(log.value.filter { $0.hasPrefix("linkdisc:") }.count == 1)
}

@Test @MainActor func aListenerFailureDisconnectsEveryAcceptedConnectionOnceAndStopsMaintenance() async throws {
    let log = LockIsolated<[String]>([])
    let listenerStops = LockIsolated(0)
    let (store, serverEvents, _, _) = makeServerOnly(log: log, listenerStops: listenerStops)
    let (a, b) = (TCPConnID(1), TCPConnID(2))

    await store.send(.start)
    serverEvents.yield(.started)
    serverEvents.yield(.accepted(a))
    serverEvents.yield(.accepted(b))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.count == 2)

    serverEvents.yield(.failed(reason: "boom"))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.isEmpty, "a failed listener's connections must leave the router")
    #expect(log.value.filter { $0.hasPrefix("disc:") }.count == 2)
    #expect(log.value.filter { $0.hasPrefix("linkdisc:") }.count == 2)
    #expect(log.value.filter { $0 == "stop" }.count == 1)
    #expect(listenerStops.value >= 1, "the orphaned sockets must be closed through the listener")

    // A `.closed` for either, arriving later, reports nothing more.
    await store.send(.tcpServer(.interface(.listenerEvent(.closed(a, reason: nil)))))
    await store.skipReceivedActions(strict: false)
    #expect(log.value.filter { $0.hasPrefix("disc:") }.count == 2)
}

@Test @MainActor func stoppingOnlyTheServerLeavesTheSharedLoopRunningForALiveClient() async throws {
    let log = LockIsolated<[String]>([])
    let clientEvents = AsyncStream<TCPEvent>.makeStream()
    let serverEvents = AsyncStream<TCPListenerEvent>.makeStream()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let clock = TestClock<Duration>()
    let initial = TransportEndpoint.State(
        tcpClients: [TCPEndpoint.State(host: "peer", port: 4242, reconnectOnDrop: false)],
        tcpServer: TCPServerEndpoint.State(port: 5252, profile: .tcp))
    let store = TestStore(initialState: initial) {
        MaintenanceRecorder(log: log) { TransportEndpoint() }
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in clientEvents.stream }, send: { _ in }, close: { })
        $0.tcpListener = TCPListener(listen: { _ in serverEvents.stream },
                                     send: { _, _ in }, close: { _ in }, stop: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { now.value }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    let conn = TCPConnID(1)

    await store.send(.start)
    clientEvents.continuation.yield(.connected)
    serverEvents.continuation.yield(.started)
    serverEvents.continuation.yield(.accepted(conn))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.count == 2)

    let (announceRaw, destHash) = makeAnnouncePacket(identity: Identity(), appName: "app",
                                                     aspects: ["svc"], hops: 3, emitted: 1000)
    serverEvents.continuation.yield(.data(conn, HDLC.frame(announceRaw)))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    // Stop ONLY the server; the client stays up.
    await store.send(.tcpServer(.stop))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.interfaces.count == 1, "only the client interface remains")
    #expect(store.state.interfaces[tcpServerInterfaceID(conn)] == nil)
    #expect(log.value.filter { $0 == "stop" }.isEmpty, "a live client keeps the shared loop running")

    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.learned[destHash] == nil, "the loop is alive, so the tick sweeps the expired path")

    await store.send(.stop)
    await store.skipReceivedActions(strict: false)
}
