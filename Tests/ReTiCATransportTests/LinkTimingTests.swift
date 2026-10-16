import Testing
import Foundation
@testable import ReTiCATransport
@testable import ReTiCA

private let slow202 = InterfaceProfile(name: "slow-202", bitrate: 202)
private let tcp = InterfaceProfile.tcp.bitrate      // 10_000_000
private let ble = InterfaceProfile.ble.bitrate      // 80_000

private func approx(_ a: TimeInterval, _ b: TimeInterval) -> Bool { abs(a - b) < 1e-9 }

/// Amended Contract 4 formulas. Hop arguments are ReTiCA's ON-WIRE counts; h = max(1, wire).
@Suite struct LinkTimingTests {
    // --- initiator: max(15, 4000/b + 6 + 6h) ---

    @Test func initiatorFloorHoldsUpToOneWireHopOnFastLinks() {
        // wire 0 and 1 → h 1 → 4000/b + 12 < 15 on TCP and BLE: today's value is unchanged.
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: tcp, wireHops: 0) == 15)
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: tcp, wireHops: 1) == 15)
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: ble, wireHops: 0) == 15)
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: ble, wireHops: 1) == 15)
    }

    @Test func initiatorGrowsSixSecondsPerHopBeyondTheFirst() {
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: tcp, wireHops: 2), 18.0004))   // h 2
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: tcp, wireHops: 3), 24.0004))   // h 3
        // The latency term is pinned exactly, not rounded away: 4000/80_000 = 0.05 s.
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: ble, wireHops: 2), 18.05))
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: ble, wireHops: 3), 24.05))
    }

    // --- responder: max(15, 2·4000/b + 6), no hop term ---

    @Test func responderIsFifteenSecondsOnFastLinks() {
        #expect(LinkTiming.responderEstablishmentTimeout(bitrate: tcp) == 15)   // 6.0008 → floor
        #expect(LinkTiming.responderEstablishmentTimeout(bitrate: ble) == 15)   // 6.1 → floor
    }

    // --- slow links ---

    @Test func aSlowNextHopStretchesTheInitiator() {
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: slow202.bitrate, wireHops: 0), 31.801980198019802))
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: slow202.bitrate, wireHops: 1), 31.801980198019802))
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: slow202.bitrate, wireHops: 2), 37.801980198019802))
    }

    @Test func aSlowArrivalInterfaceStretchesTheResponder() {
        #expect(approx(LinkTiming.responderEstablishmentTimeout(bitrate: slow202.bitrate), 45.603960396039604))
    }

    // --- unknown bitrate: today's values ---

    @Test func anUnknownBitrateKeepsFifteenSecondsForTheInitiator() {
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: nil, wireHops: 5) == 15)
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: 0, wireHops: 5) == 15)
    }

    @Test func anUnknownBitrateKeepsFifteenSecondsForTheResponder() {
        #expect(LinkTiming.responderEstablishmentTimeout(bitrate: nil) == 15)
        #expect(LinkTiming.responderEstablishmentTimeout(bitrate: -1) == 15)
    }

    // --- hostile wire input ---

    @Test func hostileHopCountIsClampedForTheInitiator() {
        // Computed in Int (no UInt8 trap) and clamped at PATHFINDER_M = 128.
        #expect(LinkTiming.effectiveHops(wire: 255) == 128)
        #expect(LinkTiming.effectiveHops(wire: 0) == 1)
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: tcp, wireHops: 255), 774.0004))
    }

    // --- relay proof deadline extra term: 4000/b_recv, unknown → 0 ---

    @Test func theRelayProofExtraIsOneMTUOfAirtimeOrNothing() {
        #expect(approx(LinkTiming.relayProofExtraTimeout(bitrate: tcp), 0.0004))
        #expect(approx(LinkTiming.relayProofExtraTimeout(bitrate: slow202.bitrate), 19.801980198019802))
        #expect(LinkTiming.relayProofExtraTimeout(bitrate: nil) == 0)
        #expect(LinkTiming.relayProofExtraTimeout(bitrate: 0) == 0)
    }

    // --- next-hop profile query ---

    private func state(learnedOn interface: InterfaceID, dest: Data) -> Transport.State {
        var s = Transport.State()
        s.interfaces[InterfaceID("fast")] = .tcp
        s.interfaces[InterfaceID("slow")] = slow202
        s.learned[dest] = LearnedDestination(identity: Identity(), appData: nil, ratchet: nil,
                                             interfaceID: interface, hops: 0, nextHop: dest,
                                             announceEmitted: 0, learnedAt: Date(timeIntervalSince1970: 0))
        return s
    }

    @Test func theNextHopProfileIsTheProfileOfTheInterfaceThePathWasLearnedOn() {
        let dest = Data(repeating: 0x42, count: 16)
        #expect(state(learnedOn: InterfaceID("slow"), dest: dest).nextHopInterfaceProfile(dest) == slow202)
    }

    @Test func theNextHopProfileIsNilWithoutAReachablePath() {
        let dest = Data(repeating: 0x42, count: 16)
        var s = state(learnedOn: InterfaceID("slow"), dest: dest)
        s.interfaces[InterfaceID("slow")] = nil                                   // that interface went away
        #expect(s.nextHopInterfaceProfile(dest) == nil)
        #expect(s.nextHopInterfaceProfile(Data(repeating: 0x43, count: 16)) == nil)   // never learned
    }
}
