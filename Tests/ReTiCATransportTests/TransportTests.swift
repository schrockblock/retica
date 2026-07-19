import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

@Test func ringSetInsertReportsNoveltyAndDedups() {
    var set = RingSet(capacity: 3)
    #expect(set.insert(Data([1])) == true)
    #expect(set.insert(Data([1])) == false) // duplicate
    #expect(set.contains(Data([1])) == true)
}

@Test func ringSetEvictsOldestPastCapacity() {
    var set = RingSet(capacity: 2)
    _ = set.insert(Data([1]))
    _ = set.insert(Data([2]))
    _ = set.insert(Data([3]))          // evicts Data([1])
    #expect(set.contains(Data([1])) == false)
    #expect(set.contains(Data([2])) == true)
    #expect(set.contains(Data([3])) == true)
}

@Test func interfaceIDIsHashable() {
    #expect(InterfaceID("a") == InterfaceID("a"))
    #expect(Set([InterfaceID("a"), InterfaceID("a"), InterfaceID("b")]).count == 2)
}

@Test func destinationIsEquatable() {
    let id = Identity()
    let a = Destination(kind: .single, direction: .in, appName: "app", aspects: ["x"], identity: id)
    let b = Destination(kind: .single, direction: .in, appName: "app", aspects: ["x"], identity: id)
    #expect(a == b)
}

@Test func learnedDestinationIsEquatable() {
    let id = Identity()
    let a = LearnedDestination(identity: id, appData: nil, ratchet: nil,
                               interfaceID: InterfaceID("i"), hops: 2, nextHop: nil, announceEmitted: 10)
    let b = a
    #expect(a == b)
}

@Test @MainActor func registersInterfacesAndLocalDestinations() async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: Identity())!
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off

    await store.send(.interfaceConnected(InterfaceID("i1"))) {
        $0.interfaces = [InterfaceID("i1")]
    }
    await store.send(.registerLocalDestination(dest)) {
        $0.localDestinations = [dest.hash: dest]
    }
    await store.send(.interfaceDisconnected(InterfaceID("i1"))) {
        $0.interfaces = []
    }
}
