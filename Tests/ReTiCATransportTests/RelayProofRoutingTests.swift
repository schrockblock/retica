import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCA
@testable import ReTiCATransport

// A relay that forwards a single packet must carry that packet's proof of receipt back to where the
// packet came from (reference `Transport.reverse_table`, RNS Transport.py). Without it, a short
// message through the relay arrives but its sender is never told.
//
// Every assertion is on what the relay transmits. The fixture records each `.delegate(.transmit)`
// in a reducer wrapped around `Transport`, so "nothing was sent" is read from that record, not
// inferred from an action the test did not receive.

private let inSide = InterfaceID("in"), outSide = InterfaceID("out"), elsewhere = InterfaceID("elsewhere")

private struct Sent: Equatable, Sendable {
    var interface: InterfaceID
    var raw: Data
    var packet: Packet? { Packet(raw: raw) }
}

@Reducer
private struct RecordingTransport {
    let sent: LockIsolated<[Sent]>
    var body: some Reducer<Transport.State, Transport.Action> {
        Reduce { _, action in
            if case let .delegate(.transmit(interface, raw)) = action {
                sent.withValue { $0.append(Sent(interface: interface, raw: raw)) }
            }
            return .none
        }
        Transport()
    }
}

@MainActor
private struct RelayFixture {
    let store: TestStore<Transport.State, Transport.Action>
    let relay: Identity
    let destHash: Data
    let now: LockIsolated<Date>
    let sent: LockIsolated<[Sent]>

    /// A relay with three interfaces that learned `destHash` directly on `outSide`.
    static func make() async -> RelayFixture {
        let relay = Identity(), remote = Identity()
        let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
        let sent = LockIsolated<[Sent]>([])
        let destHash = Destination.hash(identityHash: remote.hash, appName: "app", aspects: ["proofs"])
        let payload = Announce.buildPayload(
            identity: remote, destinationHash: destHash,
            nameHash: Destination.nameHash(appName: "app", aspects: ["proofs"]),
            randomHash: Announce.randomHash(now: 1_000, randomPrefix: Data(repeating: 0xC1, count: 5)),
            appData: nil)
        let announce = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                              destinationType: .single, context: .none, contextFlag: false, hops: 0,
                              destinationHash: destHash, transportId: nil, payload: payload)
        let store = TestStore(initialState: Transport.State()) { RecordingTransport(sent: sent) } withDependencies: {
            $0.continuousClock = TestClock()
            $0.transportDate = DateGenerator { now.value }
            $0.randomBytes = RandomBytesGenerator { _ in Data([0]) }
        }
        store.exhaustivity = .off
        await store.send(.interfaceConnected(outSide))
        await store.send(.setTransportIdentity(relay))
        await store.send(.received(outSide, try! announce.packed()))
        await store.send(.interfaceConnected(inSide))
        await store.send(.interfaceConnected(elsewhere))
        return RelayFixture(store: store, relay: relay, destHash: destHash, now: now, sent: sent)
    }

    /// Hands the relay a packet and returns what it transmitted in response.
    func receive(_ raw: Data, on interface: InterfaceID) async -> [Sent] {
        let before = sent.value.count
        await store.send(.received(interface, raw))
        return Array(sent.value.dropFirst(before))
    }

    /// Has the relay forward one data packet from `inSide` and returns the address its proof goes to.
    func forwardOnePacket(payload: Data) async -> Data {
        let packet = Packet(headerType: .header2, packetType: .data, transportType: .transport,
                            destinationType: .single, context: .none, contextFlag: false, hops: 0,
                            destinationHash: destHash, transportId: relay.hash, payload: payload)
        let forwarded = await receive(try! packet.packed(), on: inSide)
        #expect(forwarded.map(\.interface) == [outSide], "the fixture's packet was forwarded")
        return Data(packet.packetHash.prefix(16))
    }

    func proof(to address: Data) -> Data {
        try! Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                    destinationType: .single, context: .none, contextFlag: false, hops: 0,
                    destinationHash: address, transportId: nil,
                    payload: Data(repeating: 0x7E, count: 64)).packed()
    }
}

@Test @MainActor func relayReturnsTheProofOfAPacketItForwardedToWhereThePacketCameFrom() async {
    let fixture = await RelayFixture.make()
    let address = await fixture.forwardOnePacket(payload: Data([1, 2, 3]))

    let returned = await fixture.receive(fixture.proof(to: address), on: outSide)

    #expect(returned.map(\.interface) == [inSide])
    #expect(returned.first?.packet?.packetType == .proof)
    #expect(returned.first?.packet?.destinationHash == address)
    #expect(returned.first?.packet?.payload == Data(repeating: 0x7E, count: 64))
    #expect(returned.first?.packet?.hops == 1)
}

@Test @MainActor func relayPassesTheProofOnOnlyOnce() async {
    let fixture = await RelayFixture.make()
    let address = await fixture.forwardOnePacket(payload: Data([1, 2, 3]))
    let first = await fixture.receive(fixture.proof(to: address), on: outSide)
    #expect(first.count == 1)

    let second = await fixture.receive(fixture.proof(to: address), on: outSide)
    #expect(second.isEmpty)
}

/// Only the side the packet was sent out on can answer for it. A proof from anywhere else is not
/// passed on, and does not use up the route: the genuine proof still gets back afterwards.
@Test @MainActor func relayIgnoresAProofThatComesFromTheWrongSide() async {
    let fixture = await RelayFixture.make()
    let address = await fixture.forwardOnePacket(payload: Data([1, 2, 3]))

    #expect(await fixture.receive(fixture.proof(to: address), on: elsewhere).isEmpty)
    #expect(await fixture.receive(fixture.proof(to: address), on: inSide).isEmpty)

    #expect(await fixture.receive(fixture.proof(to: address), on: outSide).map(\.interface) == [inSide])
}

@Test @MainActor func relayIgnoresAProofForAPacketItNeverForwarded() async {
    let fixture = await RelayFixture.make()
    _ = await fixture.forwardOnePacket(payload: Data([1, 2, 3]))

    #expect(await fixture.receive(fixture.proof(to: Data(repeating: 0xEE, count: 16)), on: outSide).isEmpty)
}

@Test @MainActor func relayStopsWaitingForAProofAfterTheReverseTimeout() async {
    let fixture = await RelayFixture.make()
    let early = await fixture.forwardOnePacket(payload: Data([1]))
    fixture.now.withValue { $0 += Transport.reverseTableExpiry - 1 }
    await fixture.store.send(.maintenanceTick)
    let late = await fixture.forwardOnePacket(payload: Data([2]))
    fixture.now.withValue { $0 += 2 }   // the first is now past the timeout, the second is not
    await fixture.store.send(.maintenanceTick)

    #expect(await fixture.receive(fixture.proof(to: early), on: outSide).isEmpty)
    #expect(await fixture.receive(fixture.proof(to: late), on: outSide).map(\.interface) == [inSide])
}

/// A flood of forwarded packets cannot grow the table without limit: past the cap, the packet that
/// has waited longest for its proof gives up its place.
@Test @MainActor func relayRemembersABoundedNumberOfForwardedPackets() async {
    let fixture = await RelayFixture.make()
    let oldest = await fixture.forwardOnePacket(payload: Data([0xFF, 0xFF, 0xFF, 0xFF]))
    var newest = Data()
    for index in 0..<Transport.maxReverseEntries {
        fixture.now.withValue { $0 += 0.001 }
        newest = await fixture.forwardOnePacket(payload: withUnsafeBytes(of: UInt32(index)) { Data($0) })
    }

    #expect(fixture.store.state.reverseTable.count == Transport.maxReverseEntries)
    #expect(await fixture.receive(fixture.proof(to: oldest), on: outSide).isEmpty)
    #expect(await fixture.receive(fixture.proof(to: newest), on: outSide).map(\.interface) == [inSide])
}

@Test @MainActor func aNodeThatStopsRelayingForgetsThePacketsItForwarded() async {
    let fixture = await RelayFixture.make()
    let address = await fixture.forwardOnePacket(payload: Data([1, 2, 3]))
    await fixture.store.send(.setTransportIdentity(nil))

    #expect(await fixture.receive(fixture.proof(to: address), on: outSide).isEmpty)
}
