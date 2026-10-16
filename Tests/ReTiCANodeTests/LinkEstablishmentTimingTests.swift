import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let mesh = InterfaceID("timing-iface")
private let slow202 = InterfaceProfile(name: "slow-202", bitrate: 202)

private func approx(_ a: TimeInterval?, _ b: TimeInterval) -> Bool {
    guard let a else { return false }
    return abs(a - b) < 1e-9
}

/// A driverless endpoint: interfaces are registered straight on the shared router, and transmits
/// to them go nowhere (no driver owns the id), which is all a timing test needs.
@MainActor
private func makeEndpoint(clock: TestClock<Duration> = TestClock()) -> TestStoreOf<TransportEndpoint> {
    let store = TestStore(initialState: TransportEndpoint.State()) { TransportEndpoint() } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// A signed announce for a fresh SINGLE destination, as heard `wireHops` relays away.
private func announce(wireHops: UInt8) -> (raw: Data, destinationHash: Data) {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["timing"], identity: identity)!
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0x01, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: dest.hash,
                                        nameHash: dest.nameHash, randomHash: randomHash)
    var packet = Packet.announce(from: dest, payload: payload)
    packet.hops = wireHops
    return (try! packet.packed(), dest.hash)
}

/// Learn a path the production way: register `profile` under `mesh`, then deliver an announce on it.
@MainActor
private func learnPath(_ store: TestStoreOf<TransportEndpoint>, over profile: InterfaceProfile,
                       wireHops: UInt8) async -> Data {
    let (raw, destHash) = announce(wireHops: wireHops)
    await store.send(.transport(.interfaceConnected(mesh, profile)))
    await store.send(.transport(.received(mesh, raw)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.transport.learned[destHash]?.hops == wireHops, "the path must come off the wire")
    return destHash
}

@MainActor
private func initiatorTimeout(over profile: InterfaceProfile, wireHops: UInt8) async -> TimeInterval? {
    let store = makeEndpoint()
    let destHash = await learnPath(store, over: profile, wireHops: wireHops)
    await store.send(.openLink(destinationHash: destHash))
    await store.skipReceivedActions(strict: false)
    return store.state.linkPlane.links.first?.establishmentTimeout
}

/// Contract 4, initiator, driven end to end: announce → learned path → `.openLink` → LinkSession.
/// Wire hops; h = max(1, wire).
@Suite @MainActor struct InitiatorEstablishmentTimingTests {
    @Test func fastLinksKeepFifteenSecondsUpToOneWireHop() async {
        #expect(await initiatorTimeout(over: .tcp, wireHops: 0) == 15)
        #expect(await initiatorTimeout(over: .tcp, wireHops: 1) == 15)
        #expect(await initiatorTimeout(over: .ble, wireHops: 0) == 15)
        #expect(await initiatorTimeout(over: .ble, wireHops: 1) == 15)
    }

    @Test func eachFurtherHopAddsSixSeconds() async {
        #expect(approx(await initiatorTimeout(over: .tcp, wireHops: 2), 18.0004))
        #expect(approx(await initiatorTimeout(over: .tcp, wireHops: 3), 24.0004))
        #expect(approx(await initiatorTimeout(over: .ble, wireHops: 2), 18.05))
    }

    @Test func aSlowNextHopStretchesTheTimeout() async {
        #expect(approx(await initiatorTimeout(over: slow202, wireHops: 0), 31.801980198019802))
        #expect(approx(await initiatorTimeout(over: slow202, wireHops: 1), 31.801980198019802))
        #expect(approx(await initiatorTimeout(over: slow202, wireHops: 2), 37.801980198019802))
    }

    @Test func aReRegisteredInterfaceBitrateIsReadWhenTheLinkOpens() async {
        let store = makeEndpoint()
        let destHash = await learnPath(store, over: .tcp, wireHops: 1)
        await store.send(.transport(.interfaceConnected(mesh, slow202)))   // same id, new bitrate
        await store.send(.openLink(destinationHash: destHash))
        await store.skipReceivedActions(strict: false)
        #expect(approx(store.state.linkPlane.links.first?.establishmentTimeout, 31.801980198019802))
    }

    @Test func aSlowNextHopKeepsTheLinkAliveUntilItsStretchedDeadline() async {
        let clock = TestClock()
        let store = makeEndpoint(clock: clock)
        let destHash = await learnPath(store, over: slow202, wireHops: 2)      // 37.80 s
        await store.send(.openLink(destinationHash: destHash))
        await store.skipReceivedActions(strict: false)
        await clock.advance(by: .seconds(37.7))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.linkPlane.links.count == 1, "the old fixed 15 s would already have failed this link")
        await clock.advance(by: .seconds(0.2))
        await store.receive {
            if case .delegate(.linkFailed(destinationHash: _, reason: .establishmentTimedOut)) = $0 { return true }
            return false
        }
        #expect(store.state.linkPlane.links.isEmpty)
    }
}

/// An inbound LINKREQUEST for `dest`, carrying `wireHops` (unauthenticated) on the wire.
private func linkRequest(to dest: Destination, wireHops: UInt8) -> Data {
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: wireHops,
                         destinationHash: dest.hash, transportId: nil,
                         payload: Identity().publicKey + Link.signallingBytes)
    return try! request.packed()
}

/// Register a local destination and deliver a LINKREQUEST for it on `mesh` (registered as `profile`).
@MainActor
private func acceptRequest(_ store: TestStoreOf<TransportEndpoint>, arrivingOver profile: InterfaceProfile,
                           wireHops: UInt8) async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["responder"],
                           identity: Identity())!
    await store.send(.registerLocalDestination(dest))
    await store.send(.transport(.interfaceConnected(mesh, profile)))
    await store.send(.transport(.received(mesh, linkRequest(to: dest, wireHops: wireHops))))
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func responderTimeout(arrivingOver profile: InterfaceProfile, wireHops: UInt8) async -> TimeInterval? {
    let store = makeEndpoint()
    await acceptRequest(store, arrivingOver: profile, wireHops: wireHops)
    return store.state.linkPlane.links.first?.establishmentTimeout
}

/// Amended Contract 4, responder: max(15, 2·4000/b_recv + 6), NO hop term. Driven end to end:
/// LINKREQUEST on the wire → Transport → TransportEndpoint → LinkPlane.acceptLinkRequest → LinkSession.
@Suite @MainActor struct ResponderEstablishmentTimingTests {
    @Test func fastArrivalInterfacesAlwaysGiveFifteenSeconds() async {
        #expect(await responderTimeout(arrivingOver: .tcp, wireHops: 0) == 15)
        #expect(await responderTimeout(arrivingOver: .tcp, wireHops: 3) == 15)
        #expect(await responderTimeout(arrivingOver: .ble, wireHops: 0) == 15)
    }

    @Test func aSlowArrivalInterfaceStretchesTheTimeout() async {
        #expect(approx(await responderTimeout(arrivingOver: slow202, wireHops: 0), 45.603960396039604))
    }

    @Test func hopsNeverStretchTheResponder() async {
        // A LINKREQUEST's hop count is attacker-controlled. 127 is the largest value Packet.parse
        // accepts (maxHops = 128): it must change nothing.
        #expect(await responderTimeout(arrivingOver: .tcp, wireHops: 127) == 15)
        #expect(approx(await responderTimeout(arrivingOver: slow202, wireHops: 127), 45.603960396039604))
        // 255 never reaches the plane (Packet.parse drops hops >= 128): no link, and no trap.
        #expect(await responderTimeout(arrivingOver: slow202, wireHops: 255) == nil)
    }

    @Test func anUnknownArrivalBitrateKeepsFifteenSeconds() async {
        let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }
        store.exhaustivity = .off
        let owner = Identity()
        let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["responder"], identity: owner)!
        await store.send(.acceptLinkRequest(owner: owner, destinationHash: dest.hash, interfaceID: mesh,
                                            data: linkRequest(to: dest, wireHops: 3)))
        #expect(store.state.links.first?.establishmentTimeout == 15)
    }

    @Test func aSlowArrivalKeepsTheHalfOpenLinkUntilItsStretchedDeadline() async {
        let clock = TestClock()
        let store = makeEndpoint(clock: clock)
        await acceptRequest(store, arrivingOver: slow202, wireHops: 0)
        #expect(store.state.linkPlane.links.count == 1)
        await clock.advance(by: .seconds(45.5))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.linkPlane.links.count == 1, "the old fixed 15 s would already have reaped it")
        await clock.advance(by: .seconds(0.2))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.linkPlane.links.isEmpty, "a half-open responder still leaves on its deadline")
    }
}
