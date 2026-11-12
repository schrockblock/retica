import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// RNS 1.6.0 Buffer over a `LinkSession` channel. Reference behaviour, observed against rns-latest with
// a real Channel and RawChannelReader: `StreamDataMessage.unpack` (header parse AND bz2 inflation) runs
// inside `Envelope.unpack` at Channel.py:355, BEFORE the envelope reaches the receive ring. So a bad
// chunk is proven (Link.py:1238) but never enters the ring, and the ring stalls on it exactly as on an
// unregistered type. A good chunk for a stream nobody reads is delivered to no handler, which still
// advances the ring.

private let epoch = Date(timeIntervalSince1970: 0)
private typealias Delegate = LinkSession.Action.Delegate
private typealias Harness = TestStore<ChannelHarness.State, ChannelHarness.Action>

@MainActor
private final class Env {
    let clock = TestClock<Duration>()

    func store(_ session: LinkSession.State) -> Harness {
        let clock = self.clock
        let store = TestStore(initialState: ChannelHarness.State(session: session)) { ChannelHarness() } withDependencies: {
            $0.date = DateGenerator {
                let c = TestClock<Duration>.Instant().duration(to: clock.now).components
                return epoch.addingTimeInterval(Double(c.seconds) + Double(c.attoseconds) / 1e18)
            }
            $0.continuousClock = clock
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return store
    }

    func advance(_ seconds: Double, _ stores: Harness...) async {
        await clock.advance(by: .seconds(seconds))
        for s in stores { await s.skipReceivedActions(strict: false) }
    }
}

@MainActor @discardableResult
private func act(_ store: Harness, _ action: LinkSession.Action) async -> [Delegate] {
    let before = store.state.events.count
    await store.send(.session(action))
    await store.skipReceivedActions(strict: false)
    return Array(store.state.events[before...])
}

private func transmits(_ events: [Delegate]) -> [Data] {
    events.compactMap { if case let .transmit(_, raw) = $0 { return raw }; return nil }
}

private func packets(_ events: [Delegate], _ type: PacketType, _ context: PacketContext) -> [Packet] {
    transmits(events).compactMap(Packet.init(raw:)).filter { $0.packetType == type && $0.context == context }
}

private struct Chunk: Equatable {
    var streamID: UInt16
    var data: Data
    var eof: Bool
}

private func chunks(_ events: [Delegate]) -> [Chunk] {
    events.compactMap {
        if case let .streamDataReceived(id, data, eof) = $0 { return Chunk(streamID: id, data: data, eof: eof) }
        return nil
    }
}

private func written(_ events: [Delegate]) -> [(token: Data, consumed: Int)] {
    events.compactMap { if case let .streamWritten(t, c) = $0 { return (t, c) }; return nil }
}

/// The stream header and data of every CHANNEL packet in `events`, decrypted with `key`.
private func sentStreamMessages(_ events: [Delegate], key: Data) -> [(StreamDataHeader, Data)] {
    packets(events, .data, .channel).compactMap { p in
        guard let plain = Link.decrypt(p.payload, sessionKey: key), let env = ChannelEnvelope.parse(plain),
              env.msgType == 0xFF00 else { return nil }
        return StreamDataHeader.parse(env.payload)
    }
}

/// Two sessions taken through a REAL handshake, RTT 0.125 s.
@MainActor
private func activePair(_ env: Env) async throws -> (i: Harness, r: Harness, owner: Identity) {
    let owner = Identity()
    let destHash = Data(repeating: 0x5D, count: 16)
    let i = env.store(LinkSession.State(initiatorTo: Identity(publicKey: owner.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("a")))
    let r = env.store(LinkSession.State(responderFor: owner, destinationHash: destHash, interfaceID: InterfaceID("b")))
    let request = try #require(transmits(await act(i, .establish)).first)
    let proof = try #require(transmits(await act(r, .acceptRequest(request))).first)
    await env.advance(0.125, i, r)
    let rtt = try #require(transmits(await act(i, .received(proof))).first)
    await act(r, .received(rtt))
    #expect(i.state.session.status == .active)
    #expect(r.state.session.status == .active)
    return (i, r, owner)
}

/// A CHANNEL packet carrying a `0xFF00` envelope of `sequence` whose payload is `streamPayload`.
private func streamPacket(_ session: LinkSession.State, _ sequence: UInt16, _ streamPayload: Data) -> Data {
    let envelope = ChannelEnvelope(msgType: 0xFF00, sequence: sequence, payload: streamPayload).packed()
    return try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                       destinationType: .link, context: .channel, contextFlag: false, hops: 0,
                       destinationHash: session.linkID, transportId: nil,
                       payload: Link.encrypt(envelope, sessionKey: session.sessionKey)).packed()
}

private func plain(_ id: UInt16, _ text: String, eof: Bool = false) -> Data {
    StreamDataHeader(streamID: id, eof: eof, compressed: false).packed() + Data(text.utf8)
}

private func token(_ n: UInt8) -> Data { Data(repeating: n, count: 16) }

/// Moves every transmit either store has made since the last pump to the other, until both are quiet.
@MainActor
private final class Wire {
    let a: Harness
    let b: Harness
    private var cursorA = 0
    private var cursorB = 0

    init(_ a: Harness, _ b: Harness) {
        self.a = a
        self.b = b
        cursorA = a.state.events.count
        cursorB = b.state.events.count
    }

    func pump() async {
        while true {
            let fromA = transmits(Array(a.state.events[cursorA...]))
            cursorA = a.state.events.count
            let fromB = transmits(Array(b.state.events[cursorB...]))
            cursorB = b.state.events.count
            if fromA.isEmpty && fromB.isEmpty { return }
            for raw in fromA { await act(b, .received(raw)) }
            for raw in fromB { await act(a, .received(raw)) }
        }
    }
}

// MARK: - Writer

/// A stream id above 14 bits is refused with `streamIDRejected`, never with `streamWritten(0)`,
/// which means "window full, retry" and would spin a write loop forever. The reference raises
/// ValueError (Buffer.py:74-75).
@Test @MainActor func streamIDsAboveFourteenBitsCannotBeWritten() async throws {
    let env = Env()
    let (i, _, _) = try await activePair(env)
    // The id is checked first, as the reference builds the message before it tries to send: no
    // channel is no excuse for an answer that reads "retry".
    #expect(await act(i, .writeStream(streamID: 0x4000, data: Data("x".utf8), token: token(1)))
            == [.streamIDRejected(streamID: 0x4000, token: token(1))])
    await act(i, .openChannel)
    for id: UInt16 in [0x4000, 0x8000, 0xFFFF] {
        let events = await act(i, .writeStream(streamID: id, data: Data("x".utf8), token: token(1)))
        #expect(events == [.streamIDRejected(streamID: id, token: token(1))], "\(id)")
        let close = await act(i, .closeStreamWriter(streamID: id, token: token(2)))
        #expect(close == [.streamIDRejected(streamID: id, token: token(2))], "\(id)")
    }
    #expect(i.state.session.channel?.nextSequence == 0)
    #expect(i.state.session.channel?.closedStreamWriters.isEmpty == true)
    #expect(i.state.session.channel?.pendingStreamEOFs.isEmpty == true)
    // The top 14-bit id is writable: the guard is the boundary.
    let top = await act(i, .writeStream(streamID: 0x3FFF, data: Data("x".utf8), token: token(3)))
    #expect(written(top).map(\.consumed) == [1])
    #expect(sentStreamMessages(top, key: i.state.session.sessionKey).map(\.0.streamID) == [0x3FFF])
}

@Test @MainActor func aWriteWithoutAChannelOrWhileNotReadyConsumesNothing() async throws {
    let env = Env()
    let (i, _, _) = try await activePair(env)
    #expect(await act(i, .writeStream(streamID: 1, data: Data("x".utf8), token: token(1)))
            == [.streamWritten(token: token(1), consumed: 0)])
    #expect(i.state.session.channel == nil)

    await act(i, .openChannel)
    for n: UInt8 in 2...3 {
        #expect(written(await act(i, .writeStream(streamID: 1, data: Data("ab".utf8), token: token(n)))).map(\.consumed) == [2])
    }
    #expect(i.state.session.channel?.isReadyToSend == false)
    let full = await act(i, .writeStream(streamID: 1, data: Data("cd".utf8), token: token(4)))
    #expect(full == [.streamWritten(token: token(4), consumed: 0)])
}

@Test @MainActor func closingAWriterSendsAnEmptyEOFAndLaterWritesCarryIt() async throws {
    let env = Env()
    let (i, r, _) = try await activePair(env)
    await act(i, .openChannel)
    await act(r, .openStreamReader(streamID: 7))
    let wire = Wire(i, r)
    let key = i.state.session.sessionKey

    let before = await act(i, .writeStream(streamID: 7, data: Data("body".utf8), token: token(1)))
    #expect(sentStreamMessages(before, key: key).map(\.0.eof) == [false])
    await wire.pump()

    let close = await act(i, .closeStreamWriter(streamID: 7, token: token(2)))
    #expect(written(close).map(\.consumed) == [0])
    #expect(written(close).map(\.token) == [token(2)])
    let eof = sentStreamMessages(close, key: key)
    #expect(eof.map(\.0) == [StreamDataHeader(streamID: 7, eof: true, compressed: false)])
    #expect(eof.map(\.1) == [Data()])
    await wire.pump()

    let after = await act(i, .writeStream(streamID: 7, data: Data("more".utf8), token: token(3)))
    #expect(written(after).map(\.consumed) == [4])
    #expect(sentStreamMessages(after, key: key).map(\.0.eof) == [true])
    await wire.pump()

    // Another stream on the same channel is not closed.
    let other = await act(i, .writeStream(streamID: 8, data: Data("x".utf8), token: token(4)))
    #expect(sentStreamMessages(other, key: key).map(\.0.eof) == [false])

    #expect(chunks(r.state.events) == [Chunk(streamID: 7, data: Data("body".utf8), eof: false),
                                       Chunk(streamID: 7, data: Data(), eof: true),
                                       Chunk(streamID: 7, data: Data("more".utf8), eof: true)])
}

@Test @MainActor func aWriterClosedWithTheWindowFullSendsEOFOnTheNextDelivery() async throws {
    let env = Env()
    let (i, r, _) = try await activePair(env)
    await act(i, .openChannel)
    await act(r, .openStreamReader(streamID: 3))
    let key = i.state.session.sessionKey
    var sent: [Packet] = []
    for n: UInt8 in 1...2 {
        sent += packets(await act(i, .writeStream(streamID: 3, data: Data([n]), token: token(n))), .data, .channel)
    }
    #expect(i.state.session.channel?.isReadyToSend == false)

    let close = await act(i, .closeStreamWriter(streamID: 3, token: token(9)))
    #expect(close.isEmpty)

    try #require(sent.count == 2)
    let proof = try #require(packets(await act(r, .received(try sent[0].packed())), .proof, .none).first)
    let delivered = await act(i, .received(try proof.packed()))
    let deliveredAt = try #require(delivered.firstIndex(of: .channelMessageDelivered(token: token(1))))
    let writtenAt = try #require(delivered.firstIndex(of: .streamWritten(token: token(9), consumed: 0)))
    #expect(deliveredAt < writtenAt)
    #expect(sentStreamMessages(delivered, key: key).map(\.0) == [StreamDataHeader(streamID: 3, eof: true, compressed: false)])

    // Tried once: its wait was cancelled, so its deadline never fires.
    let mark = i.state.events.count
    await env.advance(30, i)
    #expect(written(Array(i.state.events[mark...])).isEmpty)
    #expect(i.state.streamEOFDeadlinesFired == 0)
}

/// A delivery that frees two slots (one envelope leaves, the window grows 2 -> 3) releases both waiting
/// EOFs at once, in order, the second not held behind the first's retry timer.
@Test @MainActor func twoFreedSlotsReleaseBothWaitingEOFsAtOnce() async throws {
    let env = Env()
    let (i, r, _) = try await activePair(env)
    await act(i, .openChannel)
    await act(r, .openChannel)
    let key = i.state.session.sessionKey
    var sent: [Packet] = []
    for n: UInt8 in 1...2 {
        sent += packets(await act(i, .writeStream(streamID: 9, data: Data([n]), token: token(n))), .data, .channel)
    }
    try #require(sent.count == 2)
    await act(i, .closeStreamWriter(streamID: 1, token: token(0xA)))
    await act(i, .closeStreamWriter(streamID: 2, token: token(0xB)))
    #expect(i.state.session.channel?.pendingStreamEOFs.count == 2)

    let before = i.state.events.count
    let proof = try #require(packets(await act(r, .received(try sent[0].packed())), .proof, .none).first)
    await act(i, .received(try proof.packed()))
    await i.skipReceivedActions(strict: false)
    let events = Array(i.state.events[before...])
    #expect(sentStreamMessages(events, key: key).map(\.0) == [StreamDataHeader(streamID: 1, eof: true, compressed: false),
                                                             StreamDataHeader(streamID: 2, eof: true, compressed: false)])
    #expect(written(events).map(\.token) == [token(0xA), token(0xB)])
    #expect(i.state.session.channel?.pendingStreamEOFs.isEmpty == true)
}

/// Two closes wait on a full window. One freed slot releases ONE EOF; the other keeps waiting, with
/// its deadline still armed, as each reference `close` polls readiness on its own (Buffer.py:276-277).
@Test @MainActor func oneFreedSlotReleasesOnlyTheOldestWaitingEOF() async throws {
    enum Then { case secondDelivery, deadline }
    for then in [Then.secondDelivery, .deadline] {
        let env = Env()
        let (i, r, _) = try await activePair(env)
        await act(i, .openChannel)
        await act(r, .openChannel)   // the peer proves CHANNEL packets only with a channel open
        let key = i.state.session.sessionKey
        // Grow the window to its slow-link max (2 -> 5), so a delivery frees exactly one slot.
        let wire = Wire(i, r)
        for n: UInt8 in 1...3 {
            await act(i, .writeStream(streamID: 9, data: Data([n]), token: token(n)))
            await wire.pump()
        }
        #expect(i.state.session.channel?.window.window == 5, "\(then)")
        #expect(i.state.session.channel?.window.windowMax == 5, "\(then)")

        var sent: [Packet] = []
        for n: UInt8 in 10...14 {
            sent += packets(await act(i, .writeStream(streamID: 9, data: Data([n]), token: token(n))), .data, .channel)
        }
        try #require(sent.count == 5)
        #expect(i.state.session.channel?.isReadyToSend == false, "\(then)")
        #expect(await act(i, .closeStreamWriter(streamID: 1, token: token(0xA))).isEmpty, "\(then)")
        #expect(await act(i, .closeStreamWriter(streamID: 2, token: token(0xB))).isEmpty, "\(then)")

        func deliver(_ p: Packet) async throws -> [Delegate] {
            // Not `try #require`: inside this local function the compiler both warns that its `try`
            // covers nothing and errors without it.
            guard let proof = packets(await act(r, .received(try p.packed())), .proof, .none).first else {
                Issue.record("the peer did not prove the packet")
                return []
            }
            return await act(i, .received(try proof.packed()))
        }
        let beforeFirst = i.state.events.count
        _ = try await deliver(sent[0])
        await i.skipReceivedActions(strict: false)   // a concatenated tail may land after act's drain
        let first = Array(i.state.events[beforeFirst...])
        #expect(sentStreamMessages(first, key: key).map(\.0) == [StreamDataHeader(streamID: 1, eof: true, compressed: false)],
                "\(then): only A's EOF")
        #expect(written(first).map(\.token) == [token(0xA)], "\(then): B neither sent nor answered yet")
        #expect(i.state.session.channel?.pendingStreamEOFs == [PendingStreamEOF(streamID: 2, token: token(0xB))], "\(then)")

        switch then {
        case .secondDelivery:
            let second = try await deliver(sent[1])
            #expect(sentStreamMessages(second, key: key).map(\.0) == [StreamDataHeader(streamID: 2, eof: true, compressed: false)])
            #expect(written(second).map(\.token) == [token(0xB)])
            #expect(i.state.session.channel?.pendingStreamEOFs.isEmpty == true)
            let mark = i.state.events.count
            await env.advance(1.0, i)   // past both waits (0.125 x 5), short of any retry (~2 s)
            #expect(written(Array(i.state.events[mark...])).isEmpty)
            #expect(i.state.streamEOFDeadlinesFired == 0)
        case .deadline:
            // B's wait is 0.125 x 5 from its close; still full, so its one try is refused.
            let mark = i.state.events.count
            await env.advance(1.0, i)
            let fired = Array(i.state.events[mark...])
            #expect(i.state.streamEOFDeadlinesFired == 1, "B's wait was left armed; A's was cancelled")
            #expect(fired == [.streamWritten(token: token(0xB), consumed: 0)])
            #expect(i.state.session.channel?.pendingStreamEOFs.isEmpty == true)
        }
    }
}

@Test @MainActor func aWriterClosedWithTheWindowFullTriesOnceAtTheDeadline() async throws {
    // RTT known: the wait is rtt × tx ring length (Buffer.py:271-272), 0.125 × 2.
    do {
        let env = Env()
        let (i, _, _) = try await activePair(env)
        await act(i, .openChannel)
        for n: UInt8 in 1...2 { await act(i, .writeStream(streamID: 3, data: Data([n]), token: token(n))) }
        #expect(await act(i, .closeStreamWriter(streamID: 3, token: token(9))).isEmpty)
        let mark = i.state.events.count
        await env.advance(0.24, i)
        #expect(written(Array(i.state.events[mark...])).isEmpty)
        await env.advance(0.02, i)
        let fired = Array(i.state.events[mark...])
        // Still not ready, so the one try is refused and the EOF is lost silently (Buffer.py:264-267).
        #expect(fired == [.streamWritten(token: token(9), consumed: 0)])
        #expect(i.state.session.channel?.tx.count == 2)
    }
    // RTT unknown: 15 s (Buffer.py:273-274, where `None * n` raises). Pinned on the wait itself: on a
    // link with no RTT the channel's own retries (0.025 s floor) exhaust and close the link long
    // before 15 s, which drops the pending EOF.
    #expect(LinkSession.streamEOFWait(linkRTT: nil, txRingCount: 2) == 15)
    #expect(LinkSession.streamEOFWait(linkRTT: 0.5, txRingCount: 3) == 1.5)
    #expect(LinkSession.streamEOFWait(linkRTT: 0.5, txRingCount: 0) == 0)
}

@Test @MainActor func aPendingEOFDiesWithTheLink() async throws {
    let env = Env()
    let (i, _, _) = try await activePair(env)
    await act(i, .openChannel)
    for n: UInt8 in 1...2 { await act(i, .writeStream(streamID: 3, data: Data([n]), token: token(n))) }
    await act(i, .closeStreamWriter(streamID: 3, token: token(9)))
    #expect(i.state.session.channel?.pendingStreamEOFs.count == 1)

    let closing = await act(i, .close)
    #expect(closing.contains { if case .closed = $0 { return true }; return false })
    #expect(written(closing).isEmpty)
    #expect(i.state.session.channel == nil)
    let mark = i.state.events.count
    await env.advance(3_600, i)
    #expect(written(Array(i.state.events[mark...])).isEmpty)
    #expect(i.state.events.count == mark)
    #expect(i.state.streamEOFDeadlinesFired == 0, "the wait was cancelled with the channel")
}

// MARK: - Reader

@Test @MainActor func streamDataForAnUnopenedStreamIsDroppedButAdvances() async throws {
    let env = Env()
    let (_, r, _) = try await activePair(env)
    await act(r, .openStreamReader(streamID: 1))
    #expect(r.state.session.channel?.registered.contains(0xFF00) == true)
    #expect(r.state.session.channel?.streamReaders == [1])

    let other = await act(r, .received(streamPacket(r.state.session, 0, plain(2, "not yours"))))
    #expect(packets(other, .proof, .none).count == 1)
    #expect(chunks(other).isEmpty)
    #expect(r.state.session.channel?.rx.nextSequence == 1)

    let mine = await act(r, .received(streamPacket(r.state.session, 1, plain(1, "yours", eof: true))))
    #expect(chunks(mine) == [Chunk(streamID: 1, data: Data("yours".utf8), eof: true)])

    // A closed reader is as good as none; the type stays registered (RawChannelReader.close only
    // removes the handler, Buffer.py:188-191), so the ring still advances.
    await act(r, .closeStreamReader(streamID: 1))
    #expect(r.state.session.channel?.streamReaders.isEmpty == true)
    let closed = await act(r, .received(streamPacket(r.state.session, 2, plain(1, "late"))))
    #expect(chunks(closed).isEmpty)
    #expect(r.state.session.channel?.rx.nextSequence == 3)
}

/// A reader for an id above 14 bits could never match: unpack masks every inbound id to 14 bits
/// (Buffer.py:92). It is refused and registers nothing, not even the channel.
@Test @MainActor func aReaderForAnIDAboveFourteenBitsIsRefused() async throws {
    let env = Env()
    let (_, r, _) = try await activePair(env)
    for id: UInt16 in [0x4000, 0xFFFF] {
        #expect(await act(r, .openStreamReader(streamID: id)) == [.streamIDRejected(streamID: id, token: nil)], "\(id)")
    }
    #expect(r.state.session.channel == nil)

    await act(r, .openChannel)
    #expect(await act(r, .openStreamReader(streamID: 0x4001)) == [.streamIDRejected(streamID: 0x4001, token: nil)])
    #expect(r.state.session.channel?.registered.isEmpty == true)
    #expect(r.state.session.channel?.streamReaders.isEmpty == true)
    // The top 14-bit id opens: the guard is the boundary.
    #expect(await act(r, .openStreamReader(streamID: 0x3FFF)).isEmpty)
    #expect(r.state.session.channel?.streamReaders == [0x3FFF])
}

@Test @MainActor func streamDataBeforeAnyReaderIsOpenStallsTheRing() async throws {
    let env = Env()
    let (_, r, _) = try await activePair(env)
    await act(r, .openChannel)
    let early = await act(r, .received(streamPacket(r.state.session, 0, plain(1, "early"))))
    #expect(packets(early, .proof, .none).count == 1)
    #expect(r.state.session.channel?.rx.nextSequence == 0)
}

@Test @MainActor func aBadChunkStallsTheRingAsTheReferenceDoes() async throws {
    let bomb = try #require(Bzip2.compress(Data(repeating: 0, count: 17_000)))
    let whole = try #require(Bzip2.compress(Data(repeating: 0x61, count: 1000)))
    let compressedHeader = StreamDataHeader(streamID: 1, eof: false, compressed: true).packed()
    let bad: [(String, Data)] = [
        ("inflates past 16 KiB", compressedHeader + bomb),
        ("truncated bz2", compressedHeader + Data(whole.dropLast(5))),
        ("empty compressed body", compressedHeader),
        ("shorter than the header", Data([0x00])),
    ]
    for (label, payload) in bad {
        let env = Env()
        let (_, r, _) = try await activePair(env)
        await act(r, .openStreamReader(streamID: 1))
        #expect(chunks(await act(r, .received(streamPacket(r.state.session, 0, plain(1, "zero"))))).count == 1, "\(label)")

        let events = await act(r, .received(streamPacket(r.state.session, 1, payload)))
        #expect(packets(events, .proof, .none).count == 1, "\(label): still proven")
        #expect(chunks(events).isEmpty, "\(label)")
        #expect(r.state.session.channel?.rx.nextSequence == 1, "\(label): not advanced")

        let next = await act(r, .received(streamPacket(r.state.session, 2, plain(1, "two"))))
        #expect(packets(next, .proof, .none).count == 1, "\(label)")
        #expect(chunks(next).isEmpty, "\(label): stalled behind the bad chunk")
        #expect(r.state.session.channel?.rx.pending.map(\.sequence) == [2], "\(label)")
    }
}

@Test @MainActor func aCompressedChunkIsInflatedForTheReader() async throws {
    let env = Env()
    let (_, r, _) = try await activePair(env)
    await act(r, .openStreamReader(streamID: 4))
    let body = Data(repeating: 0x61, count: 1000)
    let payload = StreamDataHeader(streamID: 4, eof: true, compressed: true).packed() + Bzip2.compress(body)!
    let events = await act(r, .received(streamPacket(r.state.session, 0, payload)))
    #expect(chunks(events) == [Chunk(streamID: 4, data: body, eof: true)])
}

// MARK: - End to end

@Test @MainActor func aStreamRoundTripsBetweenTwoSessions() async throws {
    let env = Env()
    let (i, r, _) = try await activePair(env)
    await act(i, .openStreamReader(streamID: 9))
    await act(r, .openStreamReader(streamID: 5))
    let wire = Wire(i, r)

    // 20 KB that compresses, then 20 KB that does not (a fixed LCG).
    var lcg: UInt32 = 0x1234_5678
    let noise = Data((0..<20_000).map { _ -> UInt8 in
        lcg = lcg &* 1_664_525 &+ 1_013_904_223
        return UInt8(truncatingIfNeeded: lcg >> 24)
    })
    let up = Data(String(repeating: "up stream text ", count: 1_400).utf8.prefix(20_000)) + noise
    let down = Data(noise.reversed()) + Data(String(repeating: "down ", count: 4_000).utf8)
    #expect(up.count == 40_000 && down.count == 40_000)

    var upDone = 0, downDone = 0
    var n: UInt16 = 0
    var stuck = 0
    while upDone < up.count || downDone < down.count {
        n &+= 1
        let tok = Data([UInt8(truncatingIfNeeded: n >> 8), UInt8(truncatingIfNeeded: n)])
        var progressed = false
        if upDone < up.count {
            let c = written(await act(i, .writeStream(streamID: 5, data: Data(up[upDone...]), token: tok))).first?.consumed ?? 0
            upDone += c
            progressed = progressed || c > 0
        }
        if downDone < down.count {
            let c = written(await act(r, .writeStream(streamID: 9, data: Data(down[downDone...]), token: tok))).first?.consumed ?? 0
            downDone += c
            progressed = progressed || c > 0
        }
        await wire.pump()
        stuck = progressed ? 0 : stuck + 1
        try #require(stuck < 3, "no progress")
    }
    #expect(written(await act(i, .closeStreamWriter(streamID: 5, token: token(0xE1)))).map(\.consumed) == [0])
    #expect(written(await act(r, .closeStreamWriter(streamID: 9, token: token(0xE2)))).map(\.consumed) == [0])
    await wire.pump()

    for (receiver, expected, sender, id) in [(r, up, i, UInt16(5)), (i, down, r, UInt16(9))] {
        let got = chunks(receiver.state.events)
        #expect(got.allSatisfy { $0.streamID == id })
        #expect(Data(got.map(\.data).joined()) == expected, "stream \(id)")
        #expect(got.dropLast().allSatisfy { !$0.eof } && got.last?.eof == true, "stream \(id): EOF last, only")
        #expect(got.last?.data == Data(), "stream \(id)")
        let sent = sentStreamMessages(sender.state.events, key: sender.state.session.sessionKey)
        #expect(sent.contains { $0.0.compressed }, "stream \(id): some chunks compressed")
        #expect(sent.contains { !$0.0.compressed && !$0.1.isEmpty }, "stream \(id): some chunks not")
        #expect(sender.state.session.channel?.tx.isEmpty == true, "stream \(id)")
    }
}
