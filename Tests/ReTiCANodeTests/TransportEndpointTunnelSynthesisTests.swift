import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Container wiring for tunnel synthesis (Task 9): an outbound TCP client's profile wants a tunnel,
// an accepted server connection's does not, and `.setTunnelIdentity` reaches the shared router
// without touching relay mode. A connecting client sends one synthesis packet out ITS socket only.

private let idA = InterfaceID("tcp:a:4242")
private let idB = InterfaceID("tcp:b:4242")

/// Bytes each mock socket was asked to send, keyed "host:port".
private struct Pool {
    let a = AsyncStream<TCPEvent>.makeStream()
    let b = AsyncStream<TCPEvent>.makeStream()
    let sends = LockIsolated<[String: [Data]]>([:])

    var pool: TCPConnectionPool {
        let streams = ["a:4242": a.stream, "b:4242": b.stream]
        let sends = self.sends
        return TCPConnectionPool(
            connection: { key in
                TCPConnection(open: { _, _ in streams[key] ?? .finished },
                              send: { d in sends.withValue { $0[key, default: []].append(d) } },
                              close: { })
            },
            evict: { _ in })
    }
}

/// Every `.transport(.delegate(.transmit))` the container processes.
private struct TransmitLog<Wrapped: Reducer>: Reducer
where Wrapped.State == TransportEndpoint.State, Wrapped.Action == TransportEndpoint.Action {
    let log: LockIsolated<[(InterfaceID, Data)]>
    let wrapped: Wrapped
    init(log: LockIsolated<[(InterfaceID, Data)]>, @ReducerBuilder<State, Action> _ wrapped: () -> Wrapped) {
        self.log = log
        self.wrapped = wrapped()
    }
    func reduce(into state: inout TransportEndpoint.State, action: TransportEndpoint.Action)
        -> Effect<TransportEndpoint.Action> {
        if case let .transport(.delegate(.transmit(id, raw))) = action { log.withValue { $0.append((id, raw)) } }
        return wrapped.reduce(into: &state, action: action)
    }
}

private func syntheses(_ log: LockIsolated<[(InterfaceID, Data)]>) -> [InterfaceID] {
    log.value.compactMap { id, raw in
        Packet(raw: raw)?.destinationHash == Transport.tunnelSynthesizeDestinationHash ? id : nil
    }
}

@Suite @MainActor struct TransportEndpointTunnelSynthesisTests {
    @Test func onlyOutboundClientProfilesWantATunnel() {
        #expect(TCPEndpoint.State(host: "h", port: 4242).profile.wantsTunnel)
        #expect(TCPEndpoint.State(host: "h", port: 4242).profile == .tcpClient)
        #expect(InterfaceProfile.tcpClient.wantsTunnel)
        #expect(TCPEndpoint.State(host: "h", port: 4242, profile: .tcp).profile.wantsTunnel,
                "a client given the plain .tcp profile still synthesizes")
        #expect(TCPServerEndpoint.State(port: 4242).profile.wantsTunnel == false)
        #expect(InterfaceProfile.tcp.wantsTunnel == false)
        #expect(InterfaceProfile.ble.wantsTunnel == false)
        #expect(InterfaceProfile.auto.wantsTunnel == false)
    }

    @Test func aConnectingClientSynthesizesOnItsOwnSocketAndAcceptedConnectionsNever() async throws {
        let tunnel = Identity()
        let pool = Pool()
        let listener = AsyncStream<TCPListenerEvent>.makeStream()
        let serverSends = LockIsolated<[Data]>([])
        let log = LockIsolated<[(InterfaceID, Data)]>([])
        let initial = TransportEndpoint.State(
            tcpClients: [TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false, interfaceID: idA),
                         TCPEndpoint.State(host: "b", port: 4242, reconnectOnDrop: false, interfaceID: idB)],
            tcpServer: TCPServerEndpoint.State(port: 4243))
        let store = TestStore(initialState: initial) {
            TransmitLog(log: log) { TransportEndpoint() }
        } withDependencies: {
            $0.tcpConnectionPool = pool.pool
            $0.tcpListener = TCPListener(listen: { _ in listener.stream },
                                         send: { _, d in serverSends.withValue { $0.append(d) } },
                                         close: { _ in }, stop: { })
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 0) }
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off

        await store.send(.setTunnelIdentity(tunnel))
        await store.receive(\.transport.setTunnelIdentity)
        #expect(store.state.transport.tunnelIdentity == tunnel)
        #expect(store.state.transport.transportIdentity == nil, "Ruling 9b: not a relay identity")

        await store.send(.start)
        listener.continuation.yield(.started)
        listener.continuation.yield(.accepted(TCPConnID(1)))
        await store.receive(\.transport.interfaceConnected)
        pool.a.continuation.yield(.connected)
        await store.receive(\.transport.interfaceConnected)
        await store.receive { if case .tcpClients(.element(id: idA, action: .interface(.send))) = $0 { return true }; return false }
        await store.skipReceivedActions(strict: false)

        #expect(syntheses(log) == [idA], "client A only, not the accepted connection")
        #expect(serverSends.value.isEmpty)
        #expect((pool.sends.value["a:4242"] ?? []).count == 1, "the synthesis left over A's socket")
        #expect(pool.sends.value["b:4242"] == nil)

        // B connects too: its own synthesis, over its own socket, and nothing more over A's or the
        // accepted connection's.
        pool.b.continuation.yield(.connected)
        await store.receive(\.transport.interfaceConnected)
        await store.receive { if case .tcpClients(.element(id: idB, action: .interface(.send))) = $0 { return true }; return false }
        await store.skipReceivedActions(strict: false)
        #expect(syntheses(log) == [idA, idB])
        #expect((pool.sends.value["a:4242"] ?? []).count == 1)
        #expect((pool.sends.value["b:4242"] ?? []).count == 1, "the synthesis left over B's socket")
        #expect(serverSends.value.isEmpty)

        // Each under its own interface id's hash (Ruling 9c'), so the two clients get two tunnels.
        for id in [idA, idB] {
            let sent = try #require(log.value.first { $0.0 == id }?.1)
            let packet = try #require(Packet(raw: sent))
            #expect(Data(packet.payload.prefix(64)) == tunnel.publicKey)
            #expect(Data(packet.payload.dropFirst(64).prefix(32)) == Transport.tunnelInterfaceHash(interfaceID: id))
        }
        #expect(Transport.tunnelInterfaceHash(interfaceID: idA) != Transport.tunnelInterfaceHash(interfaceID: idB))
    }

    /// The synthesis goes out on a connecting interface BEFORE the announce a host sends in reaction to
    /// that connect (ReTiCaMsgr re-announces its delivery destination on every `interfaceConnected`),
    /// so the hub has filed the tunnel when our announce arrives over it, as reference orders it
    /// (`synthesize_tunnel` from the interface's connect, before any announce goes out on it).
    @Test func theSynthesisPrecedesTheHostsAnnounceOnThatInterface() async throws {
        let pool = Pool()
        let log = LockIsolated<[(InterfaceID, Data)]>([])
        let ours = try #require(Destination(kind: .single, direction: .in, appName: "retica", aspects: ["order"],
                                            identity: Identity()))
        let initial = TransportEndpoint.State(
            tcpClients: [TCPEndpoint.State(host: "a", port: 4242, reconnectOnDrop: false, interfaceID: idA)])
        let store = TestStore(initialState: initial) {
            TransmitLog(log: log) {
                CombineReducers {
                    TransportEndpoint()
                    // The host: announce on every interface that comes up, as the app does.
                    Reduce<TransportEndpoint.State, TransportEndpoint.Action> { _, action in
                        guard case let .transport(.interfaceConnected(id, _)) = action else { return .none }
                        return .send(.announceOn(interface: id, destinationHash: ours.hash, appData: nil))
                    }
                }
            }
        } withDependencies: {
            $0.tcpConnectionPool = pool.pool
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.transportDate = DateGenerator { Date(timeIntervalSince1970: 0) }
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off

        await store.send(.setTunnelIdentity(Identity()))
        await store.send(.registerLocalDestination(ours))
        await store.send(.start)
        pool.a.continuation.yield(.connected)
        await store.receive(\.transport.interfaceConnected)
        await store.receive(\.announceOn)
        await store.skipReceivedActions(strict: false)

        let onA = log.value.filter { $0.0 == idA }.compactMap { Packet(raw: $0.1) }
        let synthesis = onA.firstIndex { $0.destinationHash == Transport.tunnelSynthesizeDestinationHash }
        let announce = onA.firstIndex { $0.packetType == .announce && $0.destinationHash == ours.hash }
        #expect(synthesis != nil)
        #expect(announce != nil)
        if let synthesis, let announce { #expect(synthesis < announce, "the tunnel first, then the announce") }
        #expect((pool.sends.value["a:4242"] ?? []).count >= 2, "both left over A's socket")
    }
}
