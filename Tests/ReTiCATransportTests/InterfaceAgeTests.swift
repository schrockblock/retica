import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCA
@testable import ReTiCATransport

private func ageAnnounce(emitted: UInt64, prefix: UInt8) -> (raw: Data, destinationHash: Data) {
    let identity = Identity()
    let nameHash = Destination.nameHash(appName: "age", aspects: ["probe"])
    let destHash = Destination.hash(identityHash: identity.hash, appName: "age", aspects: ["probe"])
    let randomHash = Announce.randomHash(now: emitted, randomPrefix: Data([prefix, 0, 0, 0, 0]))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 1,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

@MainActor
private func makeAgeStore(now: LockIsolated<Date>) -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = TestClock()            // held-announce releases never fire
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    return store
}

/// Three signature-valid announces for unknown destinations, 0.2 s apart from `start`. The third
/// arrives at 7.5 Hz: above a NEW interface's 3 Hz burst threshold (`icBurstFreqNew`), below an
/// ESTABLISHED one's 10 Hz (`icBurstFreq`). Returns their destination hashes.
@MainActor
private func feed(_ store: TestStore<Transport.State, Transport.Action>, on id: InterfaceID,
                  now: LockIsolated<Date>, start: TimeInterval, prefix: UInt8) async -> [Data] {
    var dests: [Data] = []
    for k in 0..<3 {
        now.setValue(Date(timeIntervalSince1970: start + 0.2 * Double(k)))
        let (raw, dest) = ageAnnounce(emitted: UInt64(start) + UInt64(k), prefix: prefix &+ UInt8(k))
        dests.append(dest)
        await store.send(.received(id, raw))
    }
    return dests
}

@MainActor @Suite struct InterfaceAgeTests {
    /// Spec §7 E.0(b): a repeated `.interfaceConnected` for a registered id (a radio preset change)
    /// must not reopen the 2 h new-interface ingress window.
    @Test func aRepeatedConnectKeepsAnEstablishedInterfaceEstablished() async {
        let now = LockIsolated(Date(timeIntervalSince1970: 0))
        let store = makeAgeStore(now: now)
        let radio = InterfaceID("radio")
        let fresh = InterfaceID("fresh")
        await store.send(.interfaceConnected(radio, .default))
        now.setValue(Date(timeIntervalSince1970: 7_300))       // past icNewTime (7 200 s)
        await store.send(.interfaceConnected(radio, .default))   // re-registered without a drop
        await store.send(.interfaceConnected(fresh, .default))   // control: genuinely new
        let young = await feed(store, on: fresh, now: now, start: 7_300, prefix: 0x10)
        #expect(store.state.heldAnnounces[fresh]?[young[2]] != nil,
                "precondition: a NEW interface holds a 7.5 Hz burst")
        let established = await feed(store, on: radio, now: now, start: 7_301, prefix: 0x20)
        #expect(store.state.heldAnnounces[radio]?.isEmpty ?? true)
        #expect(established.allSatisfy { store.state.learned[$0] != nil })
    }

    /// Decision recorded in the plan: a disconnect → reconnect of the same id keeps the original
    /// time (reference `Interface.created`, Interface.py:101, survives TCPInterface.reconnect).
    @Test func aReconnectResumesTheConnectTimeOfTheFirstConnect() async {
        let now = LockIsolated(Date(timeIntervalSince1970: 0))
        let store = makeAgeStore(now: now)
        let radio = InterfaceID("radio")
        let fresh = InterfaceID("fresh")
        await store.send(.interfaceConnected(radio, .default))
        now.setValue(Date(timeIntervalSince1970: 7_250))
        await store.send(.interfaceDisconnected(radio))
        now.setValue(Date(timeIntervalSince1970: 7_300))
        await store.send(.interfaceConnected(radio, .default))
        await store.send(.interfaceConnected(fresh, .default))
        let young = await feed(store, on: fresh, now: now, start: 7_300, prefix: 0x30)
        #expect(store.state.heldAnnounces[fresh]?[young[2]] != nil,
                "precondition: a NEW interface holds a 7.5 Hz burst")
        let resumed = await feed(store, on: radio, now: now, start: 7_301, prefix: 0x40)
        #expect(store.state.heldAnnounces[radio]?.isEmpty ?? true)
        #expect(resumed.allSatisfy { store.state.learned[$0] != nil })
    }

    @Test func departedAgesAreCappedSoChurnedIDsCannotGrowState() async {
        let now = LockIsolated(Date(timeIntervalSince1970: 0))
        let store = makeAgeStore(now: now)
        let ids = (0...Transport.maxDepartedInterfaceAges).map { InterfaceID("churn-\($0)") }
        for id in ids {
            await store.send(.interfaceConnected(id, .default))
            await store.send(.interfaceDisconnected(id))
        }
        #expect(store.state.departedInterfaceAges.count == Transport.maxDepartedInterfaceAges)
        #expect(store.state.departedInterfaceAges.first?.id == ids[1], "the OLDEST departure is evicted")
    }
}
