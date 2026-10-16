import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let slow202 = InterfaceProfile(name: "slow-202", bitrate: 202)
private let slowA = InterfaceID("slow-A")
private let slowB = InterfaceID("slow-B")
private let tcpIface = InterfaceID("tcp-T")

/// A well-formed LINKREQUEST for `destHash` with a fresh ephemeral (hence a fresh linkID).
private func freshLinkRequest(destHash: Data) -> Data {
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: destHash, transportId: nil,
                        payload: Identity().publicKey + Link.signallingBytes)
    return try! packet.packed()
}

@MainActor
private func makePlane(clock: TestClock<Duration> = TestClock()) -> TestStoreOf<LinkPlane> {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    return store
}

/// Hand the plane one LINKREQUEST arriving on `iface` at `bitrate`, and drain its accept.
@MainActor
private func offer(_ store: TestStoreOf<LinkPlane>, owner: Identity, destHash: Data,
                   on iface: InterfaceID, bitrate: Int?) async {
    await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash, interfaceID: iface,
                                        data: freshLinkRequest(destHash: destHash), arrivalBitrate: bitrate))
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func halfOpen(_ store: TestStoreOf<LinkPlane>, on iface: InterfaceID) -> Int {
    store.state.links.filter { $0.role == .responder && $0.status != .active && $0.interfaceID == iface }.count
}

@MainActor
private func endpointHalfOpen(_ store: TestStoreOf<TransportEndpoint>, on iface: InterfaceID) -> Int {
    store.state.linkPlane.links.filter {
        $0.role == .responder && $0.status != .active && $0.interfaceID == iface
    }.count
}

/// An inbound LINKREQUEST for `dest`, as Transport would receive it off the wire.
private func wireLinkRequest(to dest: Destination) -> Data {
    freshLinkRequest(destHash: dest.hash)
}

/// The shared half-open responder budget (`maxIncompleteResponderLinks` = 32) must not be pinnable
/// from one slow interface. A stretched (> 15 s) half-open responder spends a per-arrival-interface
/// budget of `maxStretchedIncompleteResponderLinksPerInterface` (8) as well; 15 s requests never do.
@Suite @MainActor struct SlowInterfaceHalfOpenBudgetTests {
    /// The whole-branch-review probe, inverted, driven end to end through TransportEndpoint:
    /// 32 LINKREQUESTs over a 202 bps interface at t=0 must not refuse a TCP LINKREQUEST at t=20 s,
    /// while the slow ones are still inside their ≈45.6 s hold.
    @Test func aSlowFloodHoldsAtMostEightAndATcpRequestIsStillAccepted() async {
        let clock = TestClock()
        let store = TestStore(initialState: TransportEndpoint.State()) { TransportEndpoint() } withDependencies: {
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["budget"],
                               identity: Identity())!
        await store.send(.registerLocalDestination(dest))
        await store.send(.transport(.interfaceConnected(slowA, slow202)))
        await store.send(.transport(.interfaceConnected(tcpIface, .tcp)))

        for _ in 0 ..< 32 {
            await store.send(.transport(.received(slowA, wireLinkRequest(to: dest))))
            await store.skipReceivedActions(strict: false)
        }
        #expect(endpointHalfOpen(store, on: slowA) == 8,
                "one slow interface may hold at most 8 stretched half-open links")

        await clock.advance(by: .seconds(20))
        await store.skipReceivedActions(strict: false)
        #expect(endpointHalfOpen(store, on: slowA) == 8, "the slow half-opens are still inside their hold")

        await store.send(.transport(.received(tcpIface, wireLinkRequest(to: dest))))
        await store.skipReceivedActions(strict: false)
        let tcpLinks = store.state.linkPlane.links.filter { $0.role == .responder && $0.interfaceID == tcpIface }
        #expect(tcpLinks.count == 1, "a TCP LINKREQUEST must not be refused behind a slow flood")
        #expect(tcpLinks.first?.establishmentTimeout == 15)
    }

    @Test func aFullSlowInterfaceDoesNotBlockADifferentSlowInterface() async {
        let store = makePlane()
        let owner = Identity()
        let destHash = Data(repeating: 0x61, count: 16)
        for _ in 0 ..< 16 {
            await offer(store, owner: owner, destHash: destHash, on: slowA, bitrate: 202)
        }
        #expect(halfOpen(store, on: slowA) == 8)

        await offer(store, owner: owner, destHash: destHash, on: slowB, bitrate: 202)
        #expect(halfOpen(store, on: slowB) == 1, "interface A's budget must not be spent by interface B")
    }

    @Test func fifteenSecondRequestsStillFillTheSharedCapExactlyAsBefore() async {
        let store = makePlane()
        let owner = Identity()
        let destHash = Data(repeating: 0x62, count: 16)
        for _ in 0 ..< 32 {
            await offer(store, owner: owner, destHash: destHash, on: tcpIface,
                        bitrate: InterfaceProfile.tcp.bitrate)
        }
        #expect(halfOpen(store, on: tcpIface) == 32, "the per-interface cap must not apply to 15 s links")
        #expect(store.state.links.allSatisfy { $0.establishmentTimeout == 15 })

        await offer(store, owner: owner, destHash: destHash, on: tcpIface,
                    bitrate: InterfaceProfile.tcp.bitrate)
        #expect(halfOpen(store, on: tcpIface) == 32, "the 33rd is refused by the shared cap")
    }

    @Test func aCompletedStretchedHalfOpenFreesItsSlot() async {
        let store = makePlane()
        let owner = Identity()
        let destHash = Data(repeating: 0x63, count: 16)
        for _ in 0 ..< 8 {
            await offer(store, owner: owner, destHash: destHash, on: slowA, bitrate: 202)
        }
        await offer(store, owner: owner, destHash: destHash, on: slowA, bitrate: 202)
        #expect(halfOpen(store, on: slowA) == 8, "the 9th stretched request is refused")

        // Complete one handshake: the initiator's RTT under the derived session key.
        let element = store.state.links.first!
        let rttCipher = Link.encrypt(MsgPack.encode(0.0), sessionKey: element.sessionKey)
        let rtt = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                         destinationType: .link, context: .linkRequestRTT, contextFlag: false, hops: 0,
                         destinationHash: element.linkID, transportId: nil, payload: rttCipher)
        await store.send(.routeLinkPacket(linkID: element.linkID, arrivalInterface: slowA,
                                          data: try! rtt.packed()))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.links[id: element.id]?.status == .active, "the handshake must really complete")
        #expect(halfOpen(store, on: slowA) == 7)

        await offer(store, owner: owner, destHash: destHash, on: slowA, bitrate: 202)
        #expect(halfOpen(store, on: slowA) == 8, "an ACTIVE link no longer counts against the budget")
    }

    @Test func aTimedOutStretchedHalfOpenFreesItsSlot() async {
        let clock = TestClock()
        let store = makePlane(clock: clock)
        let owner = Identity()
        let destHash = Data(repeating: 0x64, count: 16)
        for _ in 0 ..< 9 {
            await offer(store, owner: owner, destHash: destHash, on: slowA, bitrate: 202)
        }
        #expect(halfOpen(store, on: slowA) == 8, "the 9th stretched request is refused")

        await clock.advance(by: .seconds(45.7))     // past the ≈45.6 s responder deadline
        await store.skipReceivedActions(strict: false)
        #expect(store.state.links.isEmpty, "every half-open left on its deadline")

        await offer(store, owner: owner, destHash: destHash, on: slowA, bitrate: 202)
        #expect(halfOpen(store, on: slowA) == 1, "a timed-out link no longer counts against the budget")
    }
}
