import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let inIf = InterfaceID("relay-in")
private let outIf = InterfaceID("relay-out")
private let slow202 = InterfaceProfile(name: "slow-202", bitrate: 202)
private let now = Date(timeIntervalSince1970: 1_700_000_000)

/// Drive a real relay: learn `dest` from an announce heard on `outIf` (as a leaf, so no re-broadcast
/// timer is scheduled), become a relay, then forward a HEADER_2 LINKREQUEST arriving on `inIf`.
/// Returns the forwarded link's proof deadline, in seconds after `now`.
///
/// The inbound and outbound profiles always DIFFER in these tests, so reading the wrong interface's
/// bitrate cannot pass by accident.
@MainActor
private func relayProofDeadline(in inProfile: InterfaceProfile, out outProfile: InterfaceProfile,
                                inStillConnected: Bool = true) async -> TimeInterval? {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(now)
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(inIf, inProfile))
    await store.send(.interfaceConnected(outIf, outProfile))

    let destIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["relayed"], identity: destIdentity)!
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0x07, count: 5))
    let payload = Announce.buildPayload(identity: destIdentity, destinationHash: dest.hash,
                                        nameHash: dest.nameHash, randomHash: randomHash)
    await store.send(.received(outIf, try! Packet.announce(from: dest, payload: payload).packed()))
    #expect(store.state.learned[dest.hash]?.interfaceID == outIf)

    let relay = Identity()
    await store.send(.setTransportIdentity(relay))
    // Transport does not drop `.received` for an unregistered id (Transport.swift:432-442), so a
    // request "arriving" on a deregistered interface still reaches the relay branch with no bitrate.
    if !inStillConnected { await store.send(.interfaceDisconnected(inIf)) }

    let request = Packet(headerType: .header2, packetType: .linkRequest, transportType: .transport,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: relay.hash,
                         payload: Identity().publicKey + Link.signallingBytes)
    await store.send(.received(inIf, try! request.packed()))
    await store.skipReceivedActions(strict: false)
    return store.state.linkTable[Link.linkID(requestPacket: request)]?.proofDeadline.timeIntervalSince(now)
}

private func approx(_ a: TimeInterval?, _ b: TimeInterval) -> Bool {
    guard let a else { return false }
    return abs(a - b) < 1e-6      // Date resolution at 2023 epochs is ~1e-7 s
}

/// Amended Contract 4: proof deadline = now + 6·max(1, hops) + 4000/b_recv (unknown b_recv → + 0),
/// b_recv = the interface the LINKREQUEST ARRIVED on (reference Transport.py:1643).
/// Learned hops here are 0 → 6 s base.
@Suite @MainActor struct RelayLinkProofDeadlineTests {
    @Test func aFastArrivalInterfaceAddsOnlyItsTinyMTUTime() async {
        #expect(approx(await relayProofDeadline(in: .tcp, out: slow202), 6.0004))
    }

    @Test func aSlowArrivalInterfaceAddsOneMTUOfAirtime() async {
        #expect(approx(await relayProofDeadline(in: slow202, out: .tcp), 25.801980198019802))
    }

    @Test func anUnknownArrivalBitrateAddsNothing() async {
        // The arrival interface is no longer registered, so its bitrate is unknown; the slow OUTBOUND
        // interface must not be used in its place.
        #expect(approx(await relayProofDeadline(in: .tcp, out: slow202, inStillConnected: false), 6))
    }
}
