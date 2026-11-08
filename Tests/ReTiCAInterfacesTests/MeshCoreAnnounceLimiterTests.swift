import Foundation
import Testing

@testable import ReTiCA
@testable import ReTiCAInterfaces

private func t(_ seconds: TimeInterval) -> Date {
    Date(timeIntervalSince1970: 1000 + seconds)
}

private func dest(_ n: Int) -> Data {
    var hash = Data(repeating: 0, count: 16)
    hash[0] = 0xD0
    hash[1] = UInt8(truncatingIfNeeded: n >> 8)
    hash[2] = UInt8(truncatingIfNeeded: n)
    return hash
}

/// Stand-in for the fixed path-request control hash: every path request carries it.
private let controlHash = Data(repeating: 0xC7, count: 16)
private let tag = Data(repeating: 0x7A, count: 16)

private func announce(
    dest: Data, hops: UInt8 = 0, pathResponse: Bool = false, header2: Bool = false
) -> Data {
    try! Packet(
        headerType: header2 ? .header2 : .header1, packetType: .announce,
        transportType: header2 ? .transport : .broadcast, destinationType: .single,
        context: pathResponse ? .pathResponse : .none, hops: hops, destinationHash: dest,
        transportId: header2 ? Data(repeating: 0x11, count: 16) : nil,
        payload: Data(repeating: 0xA5, count: 40)
    ).packed()
}

private func pathRequest(requested: Data, payloadTail: Data = tag) -> Data {
    try! Packet(
        packetType: .data, destinationType: .plain, destinationHash: controlHash,
        payload: requested + payloadTail
    ).packed()
}

private func singleData(_ to: Data) -> Data {
    try! Packet(
        packetType: .data, destinationType: .single, destinationHash: to,
        payload: Data(repeating: 0x01, count: 32)
    ).packed()
}

private func linkRequest(_ to: Data) -> Data {
    try! Packet(
        packetType: .linkRequest, destinationType: .single, destinationHash: to,
        payload: Data(repeating: 0x02, count: 64)
    ).packed()
}

private func proof(_ to: Data) -> Data {
    try! Packet(
        packetType: .proof, destinationType: .single, destinationHash: to,
        payload: Data(repeating: 0x03, count: 64)
    ).packed()
}

private func linkData(_ to: Data) -> Data {
    try! Packet(
        packetType: .data, destinationType: .link, destinationHash: to,
        payload: Data(repeating: 0x04, count: 32)
    ).packed()
}

extension MeshCoreAnnounceLimiter {
    /// `admit` at `t(seconds)`. Results are collected outside `#expect`, which can't mutate.
    fileprivate mutating func pass(_ unmasked: Data, at seconds: TimeInterval) -> Bool {
        admit(unmasked: unmasked, now: t(seconds))
    }

    fileprivate mutating func hear(_ unmasked: Data, at seconds: TimeInterval) {
        noteHeard(unmasked: unmasked, now: t(seconds))
    }
}

@Suite struct MeshCoreAnnounceLimiterTests {
    // MARK: - Hop cap

    @Test func announceAtHops2Passes() {
        var sut = MeshCoreAnnounceLimiter()
        let verdict = sut.pass(announce(dest: dest(1), hops: 2), at: 0)
        #expect(verdict)
    }

    @Test func announceAtHops3IsDropped() {
        var sut = MeshCoreAnnounceLimiter()
        let verdict = sut.pass(announce(dest: dest(1), hops: 3), at: 0)
        #expect(!verdict)
        #expect(sut.counters.announcesLimited == 1)
    }

    @Test func pathResponseAtHops3Passes() {
        var sut = MeshCoreAnnounceLimiter()
        let verdict = sut.pass(announce(dest: dest(1), hops: 3, pathResponse: true), at: 0)
        #expect(verdict)
    }

    @Test func hopCapReadsHeader2Packets() {
        var sut = MeshCoreAnnounceLimiter()
        let verdict = sut.pass(announce(dest: dest(1), hops: 3, header2: true), at: 0)
        #expect(!verdict)
    }

    // MARK: - Per-destination announce interval

    @Test func secondAnnounceWithin600SecondsIsDropped() {
        var sut = MeshCoreAnnounceLimiter()
        let packet = announce(dest: dest(1))
        let verdicts = [sut.pass(packet, at: 0), sut.pass(packet, at: 599.9)]
        #expect(verdicts == [true, false])
    }

    @Test func announceAt600SecondsPasses() {
        var sut = MeshCoreAnnounceLimiter()
        let packet = announce(dest: dest(1))
        let verdicts = [sut.pass(packet, at: 0), sut.pass(packet, at: 600)]
        #expect(verdicts == [true, true])
    }

    @Test func differentDestinationIsNotHeldByTheFirst() {
        var sut = MeshCoreAnnounceLimiter()
        let verdicts = [sut.pass(announce(dest: dest(1)), at: 0), sut.pass(announce(dest: dest(2)), at: 0)]
        #expect(verdicts == [true, true])
    }

    // MARK: - Heard path-request bypass

    @Test func announceWithin15SecondsOfAHeardRequestBypasses() {
        var sut = MeshCoreAnnounceLimiter()
        let stamped = sut.pass(announce(dest: dest(1)), at: 0)
        sut.hear(pathRequest(requested: dest(1)), at: 100)
        let answer = sut.pass(announce(dest: dest(1)), at: 114.9)
        #expect([stamped, answer] == [true, true])
    }

    @Test func heardRequestExpiresAt15Seconds() {
        var sut = MeshCoreAnnounceLimiter()
        let stamped = sut.pass(announce(dest: dest(1)), at: 0)
        sut.hear(pathRequest(requested: dest(1)), at: 100)
        let answer = sut.pass(announce(dest: dest(1)), at: 115)
        #expect([stamped, answer] == [true, false])
    }

    @Test func bypassIsConsumedByOneAnnounce() {
        var sut = MeshCoreAnnounceLimiter()
        let stamped = sut.pass(announce(dest: dest(1)), at: 0)
        sut.hear(pathRequest(requested: dest(1)), at: 100)
        let answers = [sut.pass(announce(dest: dest(1)), at: 101), sut.pass(announce(dest: dest(1)), at: 102)]
        #expect(stamped)
        #expect(answers == [true, false])
    }

    @Test func requestHeardForAnotherDestinationDoesNotBypass() {
        var sut = MeshCoreAnnounceLimiter()
        let stamped = sut.pass(announce(dest: dest(2)), at: 0)
        sut.hear(pathRequest(requested: dest(1)), at: 100)
        let answer = sut.pass(announce(dest: dest(2)), at: 101)
        #expect([stamped, answer] == [true, false])
    }

    @Test func hopCapAppliesWhenAnsweringAHeardRequest() {
        var sut = MeshCoreAnnounceLimiter()
        sut.hear(pathRequest(requested: dest(1)), at: 0)
        let answer = sut.pass(announce(dest: dest(1), hops: 3), at: 1)
        #expect(!answer)
    }

    // MARK: - Relayed announce and path-response pools

    @Test func ownAnnouncesAreExemptFromTheRelayedCap() {
        var sut = MeshCoreAnnounceLimiter()
        let verdicts = (0..<20).map { sut.pass(announce(dest: dest($0)), at: Double($0)) }
        #expect(verdicts == Array(repeating: true, count: 20))
    }

    @Test func seventhRelayedAnnounceIn10MinutesIsDropped() {
        var sut = MeshCoreAnnounceLimiter()
        let verdicts = (0..<7).map { sut.pass(announce(dest: dest($0), hops: 1), at: Double($0)) }
        #expect(verdicts == Array(repeating: true, count: 6) + [false])
    }

    @Test func relayedAnnounceCapReopensAt600Seconds() {
        var sut = MeshCoreAnnounceLimiter()
        for n in 0..<7 {
            _ = sut.pass(announce(dest: dest(n), hops: 1), at: Double(n))
        }
        let verdict = sut.pass(announce(dest: dest(100), hops: 1), at: 600)
        #expect(verdict)
    }

    @Test func thirteenthRelayedPathResponseIn10MinutesIsDropped() {
        var sut = MeshCoreAnnounceLimiter()
        let verdicts = (0..<13).map {
            sut.pass(announce(dest: dest($0), hops: 1, pathResponse: true), at: Double($0))
        }
        #expect(verdicts == Array(repeating: true, count: 12) + [false])
    }

    @Test func ownPathResponseIsExemptFromTheCap() {
        var sut = MeshCoreAnnounceLimiter()
        let verdicts = (0..<20).map {
            sut.pass(announce(dest: dest($0), hops: 0, pathResponse: true), at: Double($0))
        }
        #expect(verdicts == Array(repeating: true, count: 20))
    }

    @Test func relayedAnnounceAndPathResponseCapsAreCountedSeparately() {
        var sut = MeshCoreAnnounceLimiter()
        let announces = (0..<6).map { sut.pass(announce(dest: dest($0), hops: 1), at: Double($0)) }
        let responses = (6..<18).map {
            sut.pass(announce(dest: dest($0), hops: 1, pathResponse: true), at: Double($0))
        }
        #expect(announces == Array(repeating: true, count: 6))
        #expect(responses == Array(repeating: true, count: 12))
    }

    @Test func droppedByTheCapDoesNotStartItsDestinationInterval() {
        var sut = MeshCoreAnnounceLimiter()
        for n in 0..<6 {
            _ = sut.pass(announce(dest: dest(n), hops: 1), at: Double(n))
        }
        let packet = announce(dest: dest(6), hops: 1)
        let verdicts = [sut.pass(packet, at: 6), sut.pass(packet, at: 600)]
        #expect(verdicts == [false, true])
    }

    // MARK: - Path requests

    @Test func pathRequestsAreKeyedOnTheRequestedDestination() {
        var sut = MeshCoreAnnounceLimiter()
        let x = pathRequest(requested: dest(1))
        let y = pathRequest(requested: dest(2))
        #expect(x.subdata(in: 2..<18) == y.subdata(in: 2..<18))
        let verdicts = [sut.pass(x, at: 0), sut.pass(y, at: 61)]
        #expect(verdicts == [true, true])
    }

    @Test func pathRequestPassesInsideTheBurstWindow() {
        var sut = MeshCoreAnnounceLimiter()
        let x = pathRequest(requested: dest(1))
        let verdicts = [sut.pass(x, at: 0), sut.pass(x, at: 59.9)]
        #expect(verdicts == [true, true])
    }

    @Test func pathRequestIsDroppedAfterTheBurstWindow() {
        var sut = MeshCoreAnnounceLimiter()
        let x = pathRequest(requested: dest(1))
        let verdicts = [sut.pass(x, at: 0), sut.pass(x, at: 60)]
        #expect(verdicts == [true, false])
        #expect(sut.counters.pathRequestsLimited == 1)
    }

    @Test func pathRequestPassesAt1800SecondsAfterTheLast() {
        var sut = MeshCoreAnnounceLimiter()
        let x = pathRequest(requested: dest(1))
        let verdicts = [
            sut.pass(x, at: 0), sut.pass(x, at: 59), sut.pass(x, at: 1858.9), sut.pass(x, at: 1859),
        ]
        #expect(verdicts == [true, true, false, true])
    }

    @Test func aNewBurstStartsAfterTheInterval() {
        var sut = MeshCoreAnnounceLimiter()
        let x = pathRequest(requested: dest(1))
        let verdicts = [
            sut.pass(x, at: 0), sut.pass(x, at: 59), sut.pass(x, at: 1859), sut.pass(x, at: 1918),
        ]
        #expect(verdicts == [true, true, true, true])
    }

    @Test func seventhPathRequestIn10MinutesIsDropped() {
        var sut = MeshCoreAnnounceLimiter()
        let verdicts = (0..<7).map { sut.pass(pathRequest(requested: dest($0)), at: Double($0)) }
        #expect(verdicts == Array(repeating: true, count: 6) + [false])
    }

    @Test func pathRequestAggregateReopensAt600Seconds() {
        var sut = MeshCoreAnnounceLimiter()
        for n in 0..<7 {
            _ = sut.pass(pathRequest(requested: dest(n)), at: Double(n))
        }
        let verdict = sut.pass(pathRequest(requested: dest(100)), at: 600)
        #expect(verdict)
    }

    @Test func droppedByTheAggregateDoesNotStartTheBurstWindow() {
        var sut = MeshCoreAnnounceLimiter()
        for n in 0..<6 {
            _ = sut.pass(pathRequest(requested: dest(n)), at: Double(n))
        }
        let x = pathRequest(requested: dest(6))
        let verdicts = [sut.pass(x, at: 6), sut.pass(x, at: 600), sut.pass(x, at: 659)]
        #expect(verdicts == [false, true, true])
    }

    @Test func relayedPathRequestIsKeyedLikeALocalOne() {
        var sut = MeshCoreAnnounceLimiter()
        let relayed = pathRequest(requested: dest(1), payloadTail: Data(repeating: 0x55, count: 32))
        let local = pathRequest(requested: dest(1))
        #expect(relayed.count - local.count == 16)
        let verdicts = [sut.pass(relayed, at: 0), sut.pass(local, at: 1), sut.pass(local, at: 60)]
        #expect(verdicts == [true, true, false])
    }

    @Test func shortPlainPayloadDoesNotTrap() {
        var sut = MeshCoreAnnounceLimiter()
        let verdict = sut.pass(pathRequest(requested: Data([1, 2, 3]), payloadTail: Data()), at: 0)
        #expect(verdict)
    }

    // MARK: - Classification

    @Test func linkAndSingleTrafficIsNeverLimited() {
        var sut = MeshCoreAnnounceLimiter()
        var verdicts: [Bool] = []
        for packet in [singleData(dest(1)), linkRequest(dest(2)), proof(dest(3)), linkData(dest(4))] {
            for n in 0..<100 {
                verdicts.append(sut.pass(packet, at: Double(n)))
            }
        }
        #expect(verdicts == Array(repeating: true, count: 400))
        #expect(sut.counters == MeshCoreAnnounceLimiter.Counters())
    }

    @Test func unparseableBytesPassUncounted() {
        var sut = MeshCoreAnnounceLimiter()
        var badHops = announce(dest: dest(1))
        badHops[1] = 0xFF
        let verdicts = [sut.pass(Data([0x01]), at: 0), sut.pass(badHops, at: 1)]
        #expect(verdicts == [true, true])
        #expect(sut.counters == MeshCoreAnnounceLimiter.Counters())
    }

    @Test func nonZeroBasedSliceClassifiesTheSame() {
        let packets = [
            announce(dest: dest(1), hops: 2),
            announce(dest: dest(2), hops: 3),
            announce(dest: dest(3), hops: 3, header2: true),
            pathRequest(requested: dest(4)),
        ]
        for packet in packets {
            var plain = MeshCoreAnnounceLimiter()
            var sliced = MeshCoreAnnounceLimiter()
            let backing = Data([0xEE, 0xEE]) + packet
            let slice = backing.dropFirst(2)
            #expect(slice.startIndex == 2)
            let expected = [plain.pass(packet, at: 0), plain.pass(packet, at: 60)]
            let actual = [sliced.pass(slice, at: 0), sliced.pass(slice, at: 60)]
            #expect(actual == expected)
        }
    }

    @Test func heardIgnoresEverythingButPathRequests() {
        var sut = MeshCoreAnnounceLimiter()
        sut.hear(announce(dest: dest(1)), at: 0)
        #expect(sut.heardEntryCount == 0)
    }

    // MARK: - Bounds

    @Test func announceMapKeepsAtMost512Entries() {
        var sut = MeshCoreAnnounceLimiter()
        for n in 0..<513 {
            _ = sut.pass(announce(dest: dest(n)), at: Double(n))
        }
        #expect(sut.announceEntryCount == 512)
        // The newest destination is still held, and the drop doesn't restamp it.
        let newestHeld = sut.pass(announce(dest: dest(512)), at: 550)
        // The oldest was evicted, so it passes again.
        let oldestAgain = sut.pass(announce(dest: dest(0)), at: 550)
        let newestAt600 = sut.pass(announce(dest: dest(512)), at: 1112)
        #expect([newestHeld, oldestAgain, newestAt600] == [false, true, true])
    }

    @Test func pathRequestMapIsPrunedOnUse() {
        var sut = MeshCoreAnnounceLimiter()
        for n in 0..<513 {
            _ = sut.pass(pathRequest(requested: dest(n)), at: Double(n) * 100.1)
        }
        #expect(sut.pathRequestEntryCount <= 19)
    }

    @Test func heardMapKeepsAtMost512Entries() {
        var sut = MeshCoreAnnounceLimiter()
        for n in 0..<513 {
            sut.hear(pathRequest(requested: dest(n)), at: Double(n) * 0.01)
        }
        #expect(sut.heardEntryCount == 512)
    }

    // MARK: - Clock

    @Test func backwardsClockExpiresALimiterWindow() {
        var sut = MeshCoreAnnounceLimiter()
        let x = pathRequest(requested: dest(1))
        let requests = [sut.pass(x, at: 0), sut.pass(x, at: 60), sut.pass(x, at: -1000)]
        let a = announce(dest: dest(2))
        let announces = [sut.pass(a, at: 0), sut.pass(a, at: 60), sut.pass(a, at: -1000)]
        #expect(requests == [true, false, true])
        #expect(announces == [true, false, true])
    }
}
