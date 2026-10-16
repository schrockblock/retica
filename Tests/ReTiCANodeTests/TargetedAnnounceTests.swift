import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let i1 = InterfaceID("ann-i1")
private let i2 = InterfaceID("ann-i2")
private let i3 = InterfaceID("ann-i3-never-connected")

@MainActor
private func routerWithTwoInterfaces() async -> (TestStoreOf<Transport>, Destination) {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"], identity: Identity())!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(i1, .tcp))
    await store.send(.interfaceConnected(i2, .tcp))
    await store.send(.registerLocalDestination(dest))
    return (store, dest)
}

/// No-transmit assertions follow the repo pattern: send under `.off`, then flip to `.on`. Under
/// `.on`, `receive` must match the NEXT queued action and teardown fails on any leftover, so a
/// stray transmit is caught whatever order the `.merge` produced. (An `.off` receive would skip it.)
@Suite @MainActor struct TargetedAnnounceTests {
    @Test func aTargetedAnnounceTransmitsOnlyOnTheNamedInterface() async {
        let (store, dest) = await routerWithTwoInterfaces()
        await store.send(.announce(destinationHash: dest.hash, appData: nil, interface: i1))
        store.exhaustivity = .on
        await store.receive { action in
            if case let .delegate(.transmit(id, _)) = action { return id == i1 }
            return false
        }
    }

    @Test func aTargetedAnnounceToADisconnectedInterfaceTransmitsNothing() async {
        let (store, dest) = await routerWithTwoInterfaces()
        store.exhaustivity = .on
        await store.send(.announce(destinationHash: dest.hash, appData: nil, interface: i3))   // nothing may follow
        // Control: the same destination DOES announce, so the silence above is not vacuous.
        await store.send(.announce(destinationHash: dest.hash, appData: nil, interface: i1))
        await store.receive { action in
            if case let .delegate(.transmit(id, _)) = action { return id == i1 }
            return false
        }
    }

    @Test func theEndpointThreadsTheInterfaceToTheRouter() async {
        let store = TestStore(initialState: TransportEndpoint.State()) { TransportEndpoint() } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        let h = Data(repeating: 0x21, count: 16)
        await store.send(.announceOn(interface: i1, destinationHash: h, appData: Data([0x01])))
        await store.receive(.transport(.announce(destinationHash: h, appData: Data([0x01]), interface: i1)))
    }

    @Test func announceDeliveryOnInterfaceGoesOutOnlyThatInterface() async {
        let store = TestStore(initialState: LXMFNode.State(identity: Identity(), endpoint: TransportEndpoint.State())) {
            LXMFNode()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        await store.send(.endpoint(.transport(.interfaceConnected(i1, .tcp))))
        await store.send(.endpoint(.transport(.interfaceConnected(i2, .tcp))))
        await store.send(.registerDelivery)                       // announces on both; skipped below
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.send(.announceDeliveryOnInterface(i1))
        await store.receive { if case let .endpoint(.announceOn(id, _, _)) = $0 { return id == i1 }; return false }
        await store.receive { if case let .endpoint(.transport(.announce(_, _, id))) = $0 { return id == i1 }; return false }
        await store.receive { if case let .endpoint(.transport(.delegate(.transmit(id, _)))) = $0 { return id == i1 }; return false }
    }
}
