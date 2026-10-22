import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// Deregistering a local destination (RNS `Transport.deregister_destination`, Transport.py:2520-2527):
// once removed, the router no longer delivers its packets, surfaces link requests for it, answers
// path requests for it, or announces it.

/// Every `.delegate` action the store sees, in order, as a short tag ("received:<text>", "linkRequest",
/// "transmit", …) — so a test can assert one was NOT emitted.
private typealias DelegateLog = LockIsolated<[String]>

private func tag(_ action: Transport.Action) -> String? {
    guard case let .delegate(d) = action else { return nil }
    switch d {
    case let .received(_, p, _, _): return "received:" + String(decoding: p, as: UTF8.self)
    case .linkRequest: return "linkRequest"
    case .transmit: return "transmit"
    default: return "other"
    }
}

/// `Transport`, logging each delegate action it emits.
private struct ObservedTransport: Reducer {
    typealias State = Transport.State
    typealias Action = Transport.Action
    let log: DelegateLog

    var body: some Reducer<State, Action> {
        Reduce<State, Action> { _, action in
            if let t = tag(action) {
                log.withValue { $0.append(t) }
            }
            return .none
        }
        Transport()
    }
}

@MainActor
private func observedTransport(_ log: DelegateLog) -> TestStoreOf<Transport> {
    let store = TestStore(initialState: Transport.State()) {
        ObservedTransport(log: log)
    }
    store.exhaustivity = .off
    return store
}

private func dataPacket(to dest: Destination, _ text: String) -> Data {
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil,
                        payload: Identity(publicKey: dest.identity!.publicKey)!.encrypt(Data(text.utf8)))
    return try! packet.packed()
}

private func linkRequest(to dest: Destination) -> Data {
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: dest.hash, transportId: nil,
                        payload: Identity().publicKey + Link.signallingBytes)
    return try! packet.packed()
}

private func pathRequest(for destHash: Data, tag: UInt8) -> Data {
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                        payload: destHash + Data(repeating: tag, count: 16))
    return try! packet.packed()
}

private func received(_ log: DelegateLog) -> [String] {
    log.value.filter { $0.hasPrefix("received:") }.map { String($0.dropFirst("received:".count)) }
}

private func linkRequests(_ log: DelegateLog) -> Int { log.value.filter { $0 == "linkRequest" }.count }

private func transmits(_ log: DelegateLog) -> Int { log.value.filter { $0 == "transmit" }.count }

@Suite struct DeregisterDestinationTests {

@Test @MainActor func aDeregisteredDestinationNoLongerReceivesDataUntilRegisteredAgain() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: Identity())!
    let log = DelegateLog([])
    let store = observedTransport(log)
    let i = InterfaceID("i1")
    await store.send(.interfaceConnected(i, .default))
    await store.send(.registerLocalDestination(dest))

    await store.send(.received(i, dataPacket(to: dest, "before")))
    await store.skipReceivedActions(strict: false)
    #expect(received(log) == ["before"])

    await store.send(.deregisterLocalDestination(destinationHash: dest.hash))
    #expect(store.state.localDestinations[dest.hash] == nil)
    await store.send(.received(i, dataPacket(to: dest, "after")))
    await store.skipReceivedActions(strict: false)
    #expect(received(log) == ["before"])                              // dropped, not delivered

    await store.send(.registerLocalDestination(dest))                 // a fresh registration works again
    await store.send(.received(i, dataPacket(to: dest, "again")))
    await store.skipReceivedActions(strict: false)
    #expect(received(log) == ["before", "again"])
}

@Test @MainActor func aDeregisteredDestinationNoLongerSurfacesLinkRequests() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: Identity())!
    let log = DelegateLog([])
    let store = observedTransport(log)
    let i = InterfaceID("i1")
    await store.send(.interfaceConnected(i, .default))
    await store.send(.registerLocalDestination(dest))
    await store.send(.received(i, linkRequest(to: dest)))
    await store.skipReceivedActions(strict: false)
    #expect(linkRequests(log) == 1)

    await store.send(.deregisterLocalDestination(destinationHash: dest.hash))
    await store.send(.received(i, linkRequest(to: dest)))
    await store.skipReceivedActions(strict: false)
    #expect(linkRequests(log) == 1)
}

/// No announce, no path response, and the sticky app data is forgotten (so a later re-registration
/// does not replay it — the same clear `.registerLocalDestination` performs).
@Test @MainActor func aDeregisteredDestinationIsNeitherAnnouncedNorAnsweredForAndForgetsItsAppData() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: Identity())!
    let log = DelegateLog([])
    let store = observedTransport(log)
    let i = InterfaceID("i1")
    await store.send(.interfaceConnected(i, .default))
    await store.send(.registerLocalDestination(dest))
    await store.send(.announce(destinationHash: dest.hash, appData: Data("name".utf8)))
    await store.send(.received(i, pathRequest(for: dest.hash, tag: 1)))
    await store.skipReceivedActions(strict: false)
    #expect(transmits(log) == 2)                                      // the announce + the path response
    #expect(store.state.localAppData[dest.hash] == Data("name".utf8))

    await store.send(.deregisterLocalDestination(destinationHash: dest.hash))
    #expect(store.state.localAppData[dest.hash] == nil)
    await store.send(.announce(destinationHash: dest.hash, appData: nil))
    await store.send(.received(i, pathRequest(for: dest.hash, tag: 2)))
    await store.skipReceivedActions(strict: false)
    #expect(transmits(log) == 2)                                      // nothing more went out
}

/// Deregistering a hash that is not registered changes nothing.
@Test @MainActor func deregisteringAnUnknownHashIsANoOp() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: Identity())!
    let log = DelegateLog([])
    let store = observedTransport(log)
    await store.send(.registerLocalDestination(dest))
    await store.send(.deregisterLocalDestination(destinationHash: Data(repeating: 0x33, count: 16)))
    #expect(store.state.localDestinations[dest.hash] == dest)
}

}
