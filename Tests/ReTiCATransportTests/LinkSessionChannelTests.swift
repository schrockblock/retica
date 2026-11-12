import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// RNS 1.6.0 `Channel` inside `LinkSession`. Reference behaviour (spec "Reference behaviour"):
// a CHANNEL packet is proven BEFORE it is decrypted and only when a channel is open
// (Link.py:1234-1242); an unregistered msgtype raises before the ring (Channel.py:355); a send is
// tracked by its packet's receipt and retried with a re-packed packet, so a new hash
// (Channel.py:459-493, Packet.py:318-330); five tries tear the link down (Channel.py:469-483).

private let epoch = Date(timeIntervalSince1970: 0)
private let msgType = ChannelMessageType(0x0101)!
private typealias Delegate = LinkSession.Action.Delegate

/// Records every delegate a session emits, and every channel timer that fires, so a test can
/// assert that something did NOT happen.
@Reducer
struct ChannelHarness {
    @ObservableState
    struct State: Equatable {
        var session: LinkSession.State
        var events: [LinkSession.Action.Delegate] = []
        var deadlinesFired = 0
        /// `.streamEOFDeadline` actions that reached the session (LinkSessionStreamTests).
        var streamEOFDeadlinesFired = 0
    }
    enum Action: Equatable { case session(LinkSession.Action) }
    var body: some ReducerOf<Self> {
        Scope(state: \.session, action: \.session) { LinkSession() }
        Reduce { state, action in
            switch action {
            case let .session(.delegate(event)): state.events.append(event)
            case .session(.channelDeadline): state.deadlinesFired += 1
            case .session(.streamEOFDeadline): state.streamEOFDeadlinesFired += 1
            default: break
            }
            return .none
        }
    }
}

private typealias Harness = TestStore<ChannelHarness.State, ChannelHarness.Action>

/// A test clock and a `date` that reads it, so a timer's firing time and `date.now` agree.
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

/// Sends `action` and drains what follows; returns only the delegates this action caused.
@MainActor @discardableResult
private func act(_ store: Harness, _ action: LinkSession.Action) async -> [Delegate] {
    let before = store.state.events.count
    await store.send(.session(action))
    await store.skipReceivedActions(strict: false)
    return Array(store.state.events[before...])
}

@MainActor
private func eventsSince(_ store: Harness, _ mark: Int) -> [Delegate] {
    Array(store.state.events[mark...])
}

private func transmits(_ events: [Delegate]) -> [Data] {
    events.compactMap { if case let .transmit(_, raw) = $0 { return raw }; return nil }
}

private func packets(_ events: [Delegate], _ type: PacketType, _ context: PacketContext) -> [Packet] {
    transmits(events).compactMap(Packet.init(raw:)).filter { $0.packetType == type && $0.context == context }
}

private func received(_ events: [Delegate]) -> [ChannelEnvelope] {
    events.compactMap {
        if case let .channelMessageReceived(t, p) = $0 { return ChannelEnvelope(msgType: t, sequence: 0, payload: p) }
        return nil
    }
}

private func delivered(_ events: [Delegate]) -> [Data] {
    events.compactMap { if case let .channelMessageDelivered(t) = $0 { return t }; return nil }
}

/// Two sessions taken through a REAL handshake, with an RTT of 0.125 s (exact in binary).
@MainActor
private func activePair(_ env: Env) async throws -> (i: Harness, r: Harness, owner: Identity) {
    let owner = Identity()
    let destHash = Data(repeating: 0x5C, count: 16)
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
    #expect(i.state.session.rtt == 0.125)
    #expect(r.state.session.rtt == 0.125)
    return (i, r, owner)
}

@MainActor
private func openWithType(_ s: Harness) async {
    await act(s, .openChannel)
    await act(s, .registerChannelMessageType(msgType))
}

/// A CHANNEL-context link packet carrying `plaintext`, encrypted for `session`.
private func channelPacket(_ session: LinkSession.State, _ plaintext: Data) -> Data {
    try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                destinationType: .link, context: .channel, contextFlag: false, hops: 0,
                destinationHash: session.linkID, transportId: nil,
                payload: Link.encrypt(plaintext, sessionKey: session.sessionKey)).packed()
}

private func envelope(_ type: UInt16, _ seq: UInt16, _ payload: String) -> Data {
    ChannelEnvelope(msgType: type, sequence: seq, payload: Data(payload.utf8)).packed()
}

/// `proofs` holds exactly one proof of `raw`, validly signed by `signer`.
private func expectProof(of raw: Data, in events: [Delegate], signedBy signer: Identity,
                         sourceLocation: SourceLocation = #_sourceLocation) {
    let proofs = packets(events, .proof, .none)
    #expect(proofs.count == 1, sourceLocation: sourceLocation)
    guard let proof = proofs.first, let hash = Packet(raw: raw)?.packetHash else { return }
    #expect(proof.payload.count == 96, sourceLocation: sourceLocation)
    #expect(Data(proof.payload.prefix(32)) == hash, sourceLocation: sourceLocation)
    #expect(signer.validate(signature: Data(proof.payload.suffix(64)), message: hash), sourceLocation: sourceLocation)
}

private func token(_ n: UInt8) -> Data { Data(repeating: n, count: 16) }

// MARK: - Receive

@Test @MainActor func channelPacketsAreNotProvenWithoutAnOpenChannel() async throws {
    let env = Env()
    let (i, r, owner) = try await activePair(env)
    await openWithType(i)
    let raw = try #require(transmits(await act(i, .sendChannelMessage(type: msgType, payload: Data("hi".utf8),
                                                                     token: token(1)))).first)

    let silent = await act(r, .received(raw))
    #expect(transmits(silent).isEmpty)
    #expect(received(silent).isEmpty)
    #expect(r.state.session.channel == nil)

    // The same bytes, once the receiver opens its channel: proven and delivered. So the silence
    // above was the channel gate, not a bad packet.
    await openWithType(r)
    let heard = await act(r, .received(raw))
    expectProof(of: raw, in: heard, signedBy: owner)
    #expect(received(heard).map(\.payload) == [Data("hi".utf8)])
}

@Test @MainActor func anOpenChannelProvesBeforeItParses() async throws {
    let env = Env()
    let (_, r, owner) = try await activePair(env)
    await act(r, .openChannel)
    let raw = channelPacket(r.state.session, Data([0x01, 0x02, 0x03]))   // shorter than the 6-byte header

    let events = await act(r, .received(raw))
    expectProof(of: raw, in: events, signedBy: owner)
    #expect(received(events).isEmpty)
    #expect(r.state.session.channel?.rx.nextSequence == 0)
}

@Test @MainActor func anUnregisteredTypeIsProvenButStallsTheRing() async throws {
    let env = Env()
    let (_, r, owner) = try await activePair(env)
    await openWithType(r)

    let unregistered = channelPacket(r.state.session, envelope(0x0202, 0, "nobody listens"))
    let first = await act(r, .received(unregistered))
    expectProof(of: unregistered, in: first, signedBy: owner)
    #expect(received(first).isEmpty)

    let registered = channelPacket(r.state.session, envelope(msgType.rawValue, 1, "waits for 0"))
    let second = await act(r, .received(registered))
    expectProof(of: registered, in: second, signedBy: owner)
    #expect(received(second).isEmpty)
    #expect(r.state.session.channel?.rx.nextSequence == 0)
}

@Test @MainActor func messagesDeliverInOrderAcrossAGap() async throws {
    let env = Env()
    let (_, r, _) = try await activePair(env)
    await openWithType(r)
    let t = msgType.rawValue

    #expect(received(await act(r, .received(channelPacket(r.state.session, envelope(t, 0, "zero"))))).map(\.payload)
            == [Data("zero".utf8)])
    #expect(received(await act(r, .received(channelPacket(r.state.session, envelope(t, 2, "two"))))).isEmpty)
    let filled = await act(r, .received(channelPacket(r.state.session, envelope(t, 1, "one"))))
    #expect(received(filled).map(\.payload) == [Data("one".utf8), Data("two".utf8)])
    #expect(received(filled).map(\.msgType) == [t, t])
    #expect(r.state.session.channel?.rx.nextSequence == 3)
}

/// The proof is transmitted ahead of the delivery it accompanies.
@Test @MainActor func theProofGoesOutBeforeTheMessageIsDelivered() async throws {
    let env = Env()
    let (_, r, _) = try await activePair(env)
    await openWithType(r)
    let events = await act(r, .received(channelPacket(r.state.session, envelope(msgType.rawValue, 0, "x"))))
    let proofIndex = events.firstIndex { if case .transmit = $0 { return true }; return false }
    let deliveryIndex = events.firstIndex { if case .channelMessageReceived = $0 { return true }; return false }
    #expect(proofIndex != nil && deliveryIndex != nil)
    if let proofIndex, let deliveryIndex { #expect(proofIndex < deliveryIndex) }
}

// MARK: - Send

@Test @MainActor func aSendIsRejectedWhenTheWindowIsFull() async throws {
    let env = Env()
    let (i, _, _) = try await activePair(env)
    await openWithType(i)
    #expect(i.state.session.channel?.window.window == 2)

    let first = await act(i, .sendChannelMessage(type: msgType, payload: Data("a".utf8), token: token(1)))
    let second = await act(i, .sendChannelMessage(type: msgType, payload: Data("b".utf8), token: token(2)))
    #expect(first.contains(.channelMessageSent(token: token(1), sequence: 0)))
    #expect(second.contains(.channelMessageSent(token: token(2), sequence: 1)))
    #expect(i.state.session.channel?.isReadyToSend == false)

    let third = await act(i, .sendChannelMessage(type: msgType, payload: Data("c".utf8), token: token(3)))
    #expect(third == [.channelSendRejected(token: token(3), reason: .notReady)])
    #expect(i.state.session.channel?.nextSequence == 2)
    #expect(i.state.session.channel?.tx.count == 2)
}

@Test @MainActor func aSendWithoutAChannelOrOnAnInactiveLinkIsRejected() async throws {
    let env = Env()
    let (i, _, _) = try await activePair(env)
    #expect(await act(i, .sendChannelMessage(type: msgType, payload: Data("a".utf8), token: token(1)))
            == [.channelSendRejected(token: token(1), reason: .noChannel)])

    let pending = env.store(LinkSession.State(initiatorTo: Identity(), destinationHash: Data(repeating: 1, count: 16),
                                              interfaceID: InterfaceID("p")))
    await act(pending, .establish)   // a link id, so a packet COULD be built: only status refuses it
    await act(pending, .openChannel)
    #expect(pending.state.session.status == .pending)
    #expect(await act(pending, .sendChannelMessage(type: msgType, payload: Data("a".utf8), token: token(2)))
            == [.channelSendRejected(token: token(2), reason: .linkNotActive)])
    #expect(pending.state.session.channel?.nextSequence == 0)
}

@Test @MainActor func aTooBigSendIsRejected() async throws {
    let env = Env()
    let (i, _, _) = try await activePair(env)
    await openWithType(i)
    #expect(i.state.session.channel?.mdu == 425)

    let tooBig = await act(i, .sendChannelMessage(type: msgType, payload: Data(repeating: 0xAA, count: 426), token: token(1)))
    #expect(tooBig == [.channelSendRejected(token: token(1), reason: .tooBig)])
    #expect(i.state.session.channel?.nextSequence == 0)
    #expect(i.state.session.channel?.tx.isEmpty == true)

    let fits = await act(i, .sendChannelMessage(type: msgType, payload: Data(repeating: 0xAA, count: 425), token: token(2)))
    #expect(fits.contains(.channelMessageSent(token: token(2), sequence: 0)))
}

@Test @MainActor func aSendIsDeliveredByTheCurrentHashProofOnly() async throws {
    let env = Env()
    let (i, r, _) = try await activePair(env)
    await openWithType(i)
    await openWithType(r)

    let firstRaw = try #require(packets(await act(i, .sendChannelMessage(type: msgType, payload: Data("m".utf8),
                                                                        token: token(7))), .data, .channel).first)
    let mark = i.state.events.count
    await env.advance(ChannelSendWindow.timeout(tries: 1, linkRTT: 0.125, txRingCount: 1), i)
    let resent = try #require(packets(eventsSince(i, mark), .data, .channel).first)
    #expect(i.state.session.channel?.tx.first?.tries == 2)

    let oldProof = try #require(packets(await act(r, .received(try firstRaw.packed())), .proof, .none).first)
    let newProof = try #require(packets(await act(r, .received(try resent.packed())), .proof, .none).first)

    let late = await act(i, .received(try oldProof.packed()))
    #expect(delivered(late).isEmpty)
    #expect(i.state.session.channel?.tx.count == 1)

    let current = await act(i, .received(try newProof.packed()))
    #expect(delivered(current) == [token(7)])
    #expect(i.state.session.channel?.tx.isEmpty == true)
}

@Test @MainActor func aResendCarriesTheSameEnvelopeUnderANewHash() async throws {
    let env = Env()
    let (i, _, _) = try await activePair(env)
    await openWithType(i)

    let first = try #require(packets(await act(i, .sendChannelMessage(type: msgType, payload: Data("again".utf8),
                                                                     token: token(4))), .data, .channel).first)
    let mark = i.state.events.count
    await env.advance(ChannelSendWindow.timeout(tries: 1, linkRTT: 0.125, txRingCount: 1), i)
    let second = try #require(packets(eventsSince(i, mark), .data, .channel).first)

    let key = i.state.session.sessionKey
    let plainA = try #require(Link.decrypt(first.payload, sessionKey: key))
    let plainB = try #require(Link.decrypt(second.payload, sessionKey: key))
    #expect(plainA == plainB)
    #expect(ChannelEnvelope.parse(plainA) == ChannelEnvelope(msgType: msgType.rawValue, sequence: 0, payload: Data("again".utf8)))
    #expect(first.packetHash != second.packetHash)
    #expect(i.state.session.channel?.tx.first?.packetHash == second.packetHash)
}

@Test @MainActor func timeoutsOnlyEverGrow() async throws {
    let env = Env()
    let (i, r, _) = try await activePair(env)
    await openWithType(i)
    await openWithType(r)
    func timeout(_ tries: Int, _ count: Int) -> TimeInterval {
        ChannelSendWindow.timeout(tries: tries, linkRTT: 0.125, txRingCount: count)
    }
    func send(_ n: UInt8) async throws -> Packet {
        try #require(packets(await act(i, .sendChannelMessage(type: msgType, payload: Data([n]), token: token(n))),
                             .data, .channel).first)
    }
    func prove(_ p: Packet) async throws {
        let proof = try #require(packets(await act(r, .received(try p.packed())), .proof, .none).first)
        #expect(delivered(await act(i, .received(try proof.packed()))).count == 1)
    }

    // Grow: m0 is sent alone, then m1 joins it, and m0's timeout is extended to the 2-ring value.
    let m0 = try await send(0)
    #expect(i.state.session.channel?.tx[0].timeout == timeout(1, 1))
    let m1 = try await send(1)
    #expect(i.state.session.channel?.tx.map(\.timeout) == [timeout(1, 2), timeout(1, 2)])

    // ...and its timer was re-armed: nothing fires at the old deadline, the resend comes at the new.
    let mark = i.state.events.count
    await env.advance(timeout(1, 1) + 0.01, i)
    #expect(packets(eventsSince(i, mark), .data, .channel).isEmpty)
    await env.advance(timeout(1, 2) - timeout(1, 1) - 0.01, i)
    #expect(packets(eventsSince(i, mark), .data, .channel).count == 2)   // m0 and m1 share the deadline

    // Never shrink: with three outstanding, then two delivered, a send into a 2-ring must leave the
    // survivor's 3-ring timeout alone.
    func current(_ n: UInt8) throws -> Packet {   // the packet now carrying message n (after resends)
        let hash = try #require(i.state.session.channel?.tx.first { $0.token == token(n) }?.packetHash)
        return try #require(transmits(i.state.events).compactMap(Packet.init(raw:)).last { $0.packetHash == hash })
    }
    #expect(try current(0).packetHash != m0.packetHash)
    #expect(try current(1).packetHash != m1.packetHash)
    try await prove(try current(0))
    let m2 = try await send(2)
    _ = try await send(3)
    let survivorTimeout = try #require(i.state.session.channel?.tx.last?.timeout)
    #expect(survivorTimeout == timeout(1, 3))
    try await prove(try current(1))
    try await prove(m2)
    #expect(i.state.session.channel?.tx.map(\.token) == [token(3)])
    _ = try await send(4)
    #expect(i.state.session.channel?.tx.first { $0.token == token(3) }?.timeout == survivorTimeout)
    #expect(timeout(1, 2) < survivorTimeout)
}

// MARK: - Retry exhaustion and close

@Test @MainActor func fiveTriesTearTheLinkDown() async throws {
    let env = Env()
    let (i, _, _) = try await activePair(env)
    await openWithType(i)
    let mark = i.state.events.count
    await act(i, .sendChannelMessage(type: msgType, payload: Data("lost".utf8), token: token(9)))

    var total = 0.0
    for tries in 1...5 { total += ChannelSendWindow.timeout(tries: tries, linkRTT: 0.125, txRingCount: 1) }
    await env.advance(total + 0.5, i)

    let events = eventsSince(i, mark)
    #expect(packets(events, .data, .channel).count == 5)        // the send and four resends
    #expect(packets(events, .data, .linkClose).count == 1)
    #expect(events.filter { $0 == .closed(.channelRetriesExhausted) }.count == 1)
    #expect(events.filter { if case .closed = $0 { return true }; return false }.count == 1)
    #expect(i.state.session.channel == nil)
    #expect(i.state.session.status == .closed)

    let after = i.state.events.count
    let fired = i.state.deadlinesFired
    await env.advance(3_600, i)
    #expect(i.state.events.count == after)
    #expect(i.state.deadlinesFired == fired)
}

@Test @MainActor func closingWithSendsOutstandingSilencesTheChannel() async throws {
    enum Path: CaseIterable { case local, peer, inactivity }
    for path in Path.allCases {
        let env = Env()
        let (i, r, _) = try await activePair(env)
        await openWithType(i)
        await openWithType(r)
        let a = try #require(packets(await act(i, .sendChannelMessage(type: msgType, payload: Data("a".utf8),
                                                                     token: token(1))), .data, .channel).first)
        await act(i, .sendChannelMessage(type: msgType, payload: Data("b".utf8), token: token(2)))
        let lateProof = try #require(packets(await act(r, .received(try a.packed())), .proof, .none).first)

        let mark = i.state.events.count
        switch path {
        case .local:
            await act(i, .close)
        case .peer:
            let close = try #require(packets(await act(r, .close), .data, .linkClose).first)
            await act(i, .received(try close.packed()))
        case .inactivity:
            await act(i, .inactivityDeadline)
        }
        let closing = eventsSince(i, mark)
        #expect(closing.filter { if case .closed = $0 { return true }; return false }.count == 1, "\(path)")
        #expect(packets(closing, .data, .linkClose).count == (path == .peer ? 0 : 1), "\(path)")
        #expect(i.state.session.channel == nil, "\(path)")

        let after = i.state.events.count
        await act(i, .received(try lateProof.packed()))
        await env.advance(3_600, i)
        #expect(i.state.events.count == after, "\(path): nothing may follow .closed")
        #expect(i.state.deadlinesFired == 0, "\(path): every channel timer was cancelled")
    }
}

@Test @MainActor func anEstablishmentFailureDropsAChannelOpenedEarly() async throws {
    let env = Env()
    let s = env.store(LinkSession.State(initiatorTo: Identity(), destinationHash: Data(repeating: 2, count: 16),
                                        interfaceID: InterfaceID("p")))
    await act(s, .openChannel)
    await act(s, .establish)
    #expect(s.state.session.channel != nil)
    await env.advance(LinkTiming.defaultEstablishmentTimeout + 1, s)
    #expect(s.state.session.status == .closed)
    #expect(s.state.session.channel == nil)
}

// MARK: - Handshake backlog

@Test @MainActor func aChannelPacketDuringHandshakeIsReplayedAfterActivation() async throws {
    let env = Env()
    let owner = Identity()
    let destHash = Data(repeating: 0x68, count: 16)
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: destHash, transportId: nil,
                         payload: Identity().publicKey + Link.signallingBytes)
    let r = env.store(LinkSession.State(responderFor: owner, destinationHash: destHash, interfaceID: InterfaceID("i")))
    await act(r, .acceptRequest(try request.packed()))
    #expect(r.state.session.status == .handshake)
    await openWithType(r)

    let early = channelPacket(r.state.session, envelope(msgType.rawValue, 0, "early"))
    let held = await act(r, .received(early))
    #expect(transmits(held).isEmpty)
    #expect(r.state.session.handshakeBacklog.count == 1)

    let rtt = try Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                         destinationType: .link, context: .linkRequestRTT, contextFlag: false, hops: 0,
                         destinationHash: r.state.session.linkID, transportId: nil,
                         payload: Link.encrypt(MsgPack.encode(0.125), sessionKey: r.state.session.sessionKey)).packed()
    let activated = await act(r, .received(rtt))
    #expect(r.state.session.status == .active)
    expectProof(of: early, in: activated, signedBy: owner)
    #expect(received(activated).map(\.payload) == [Data("early".utf8)])
}

// MARK: - End to end

@Test @MainActor func twoSessionsExchangeChannelMessagesBothWays() async throws {
    let env = Env()
    let (i, r, _) = try await activePair(env)
    await openWithType(i)
    await openWithType(r)

    for (sender, receiver, label) in [(i, r, "up"), (r, i, "down")] {
        let sent = await act(sender, .sendChannelMessage(type: msgType, payload: Data(label.utf8), token: Data(label.utf8)))
        #expect(sent.contains(.channelMessageSent(token: Data(label.utf8), sequence: 0)), "\(label)")
        let data = try #require(packets(sent, .data, .channel).first)
        let heard = await act(receiver, .received(try data.packed()))
        #expect(received(heard).map(\.payload) == [Data(label.utf8)], "\(label)")
        #expect(received(heard).map(\.msgType) == [msgType.rawValue], "\(label)")
        let proof = try #require(packets(heard, .proof, .none).first)
        #expect(delivered(await act(sender, .received(try proof.packed()))) == [Data(label.utf8)], "\(label)")
        #expect(sender.state.session.channel?.tx.isEmpty == true, "\(label)")
        #expect(sender.state.session.channel?.window.window == 3, "\(label)")
    }
}
