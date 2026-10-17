import Testing
import Foundation
import MeshProto
import MeshtasticKit
import ReTiCAInterfaces
@testable import ReTiCAMeshtasticLive

private let mappingOwn: UInt32 = 0x0000_A0A0
private let mappingPeer: UInt32 = 0x0000_B001

private func mapped(_ event: MeshtasticEvent, ownNode: UInt32? = mappingOwn) -> MeshtasticDriverEvent? {
    MeshtasticDriver.driverEvent(for: event, ownNode: ownNode)
}

private func port76(from: UInt32, _ payload: Data) -> MeshtasticEvent {
    .packet(from: from, to: 0xFFFF_FFFF, channel: 0, portnum: 76, payload: payload, id: 9)
}

/// Contract 2's live mapping: `.configured` → `.connected`, a lost link → `.disconnected`,
/// `.packet(portnum 76, from ≠ myNodeNum)` → `.fragment`, adapter → `.unavailable`. The adapter
/// maps `.packet`, never `.frame` (Contract 1).
@Suite struct MeshtasticLiveMappingTests {
    @Test func configuredMapsToConnectedWithTheNodeAndPreset() {
        #expect(mapped(.configured(myNodeNum: mappingOwn, modemPreset: 6))
                == .connected(myNodeNum: mappingOwn, modemPreset: 6))
    }

    @Test func aPeersPort76PacketMapsToAFragment() {
        let payload = Data([0x01, 0xFF, 0xAB])
        #expect(mapped(port76(from: mappingPeer, payload)) == .fragment(from: mappingPeer, payload))
    }

    @Test func aPacketFromOurOwnNodeIsDropped() {
        #expect(mapped(port76(from: mappingOwn, Data([0x01, 0xFF, 0xAB]))) == nil)
    }

    /// Before the first `.configured` the node number is unknown: nothing is dropped as "own".
    @Test func aPacketBeforeTheNodeIsKnownIsKept() {
        let payload = Data([0x02, 0xFF, 0xCD])
        #expect(mapped(port76(from: mappingPeer, payload), ownNode: nil) == .fragment(from: mappingPeer, payload))
    }

    @Test(arguments: [UInt32(1), 3, 5, 75, 77, 256])
    func otherPortsAreDropped(port: UInt32) {
        let event = MeshtasticEvent.packet(from: mappingPeer, to: 0xFFFF_FFFF, channel: 0, portnum: port,
                                           payload: Data([0x01, 0xFF, 0xAB]), id: 3)
        #expect(mapped(event) == nil)
    }

    @Test(arguments: [1, 4])
    func aLostLinkMapsToDisconnected(attempt: Int) {
        #expect(mapped(.connection(.reconnecting(attempt: attempt))) == .disconnected(reason: nil))
    }

    @Test func anExplicitDisconnectMapsToDisconnected() {
        #expect(mapped(.connection(.disconnected(reason: nil))) == .disconnected(reason: nil))
    }

    /// Review Focus 1: "radio not found" must reach Diagnostics, and an interface emits no delegate
    /// for a drop of a radio that never came online.
    @Test func aTerminalSessionEndIsReportedAsUnavailableWithItsReason() {
        #expect(mapped(.connection(.disconnected(reason: "radio not found"))) == .unavailable(.other("radio not found")))
    }

    /// MeshtasticKit emits `.adapterUnavailable` before ending with these; the `.unavailable` already
    /// told the interface, and a `.disconnected` after it would wedge it in `.connecting`.
    @Test(arguments: ["unauthorized", "unsupported"])
    func anAdapterTerminalEndMapsToNothing(reason: String) {
        #expect(mapped(.connection(.disconnected(reason: reason))) == nil)
    }

    @Test(arguments: [MeshtasticConnectionState.connecting, .configuring, .connected])
    func connectionProgressIsIgnored(state: MeshtasticConnectionState) {
        #expect(mapped(.connection(state)) == nil)
    }

    @Test func routingAndFramesAreIgnored() {
        #expect(mapped(.routing(packetID: 7, ok: true)) == nil)
        #expect(mapped(.frame(FromRadio())) == nil)
    }

    // MARK: - Replay gating (MeshtasticEventMapper)

    private func fold(_ events: [MeshtasticEvent]) -> [MeshtasticDriverEvent] {
        var mapper = MeshtasticEventMapper()
        return events.compactMap { mapper.map($0) }
    }

    /// A retry after "radio not found": the hub replays the stale terminal state first.
    @Test func aReplayedStaleTerminalEndIsDroppedAndOnlyTheNewOneCounts() {
        let out = fold([.connection(.disconnected(reason: "radio not found")),
                        .connection(.connecting),
                        .connection(.disconnected(reason: "radio not found"))])
        #expect(out == [.unavailable(.other("radio not found"))])
    }

    @Test func aReplayedStaleTerminalEndAloneReportsNothing() {
        #expect(fold([.connection(.disconnected(reason: "radio not found")), .connection(.connecting)]).isEmpty)
    }

    /// An already-up session replays only `.connection(.connected)` (never `.configured`); the
    /// connect then restarts the link, so the handshake's own events are what count.
    @Test func eventsAfterConnectingMapNormally() {
        let out = fold([.connection(.connected),
                        .connection(.connecting), .connection(.configuring),
                        .configured(myNodeNum: mappingOwn, modemPreset: 6),
                        port76(from: mappingPeer, Data([1])),
                        port76(from: mappingOwn, Data([2]))])
        #expect(out == [.connected(myNodeNum: mappingOwn, modemPreset: 6), .fragment(from: mappingPeer, Data([1]))])
    }

    @Test func aReplayedStaleReconnectingIsDropped() {
        #expect(fold([.connection(.reconnecting(attempt: 2)), .connection(.connecting)]).isEmpty)
    }

    @Test(arguments: zip([MeshtasticAdapterUnavailable.poweredOff, .unauthorized, .unsupported, .other("x")],
                         [BLEAdapterUnavailable.poweredOff, .unauthorized, .unsupported, .other("x")]))
    func adapterCausesMapOneToOne(kit: MeshtasticAdapterUnavailable, ble: BLEAdapterUnavailable) {
        #expect(mapped(.adapterUnavailable(kit)) == .unavailable(ble))
    }
}
