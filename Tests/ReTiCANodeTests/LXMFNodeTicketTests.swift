import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// LXMF 1.3.0 stamp tickets in `LXMFNode` (tickets plan, Task 1): remembering a ticket a peer gives
// us, stamping our sends to it with that ticket, and accepting a ticket stamp on inbound messages.
// Reference: LXMRouter.py:2089-2094 (use), :2176-2193 (remember, validate), LXMessage.py:280-310,
// Storage.py:228-301 (LXMF 1.3.0).

private let iface = InterfaceID("ticket-iface")
private let now: TimeInterval = 1700000000.5
private let cheapCost = 8
private let ticketA = Data((0..<16).map { UInt8($0) })
private let ticketB = Data((0..<16).map { UInt8(0xF0 - $0) })

/// Counted in a reducer: with exhaustivity off, `store.send` skips actions a later `receive` could see.
private final class Recorded: Sendable {
    let tickets = LockIsolated<[(Data, LXMFNode.Ticket)]>([])
    let phases = LockIsolated<[LXMFNode.PreparingPhase]>([])
    let handedOver = LockIsolated<[LXMessage]>([])
    let received = LockIsolated<[LXMessage]>([])
}

private struct RecordingNode: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let recorded: Recorded

    var body: some Reducer<State, Action> {
        Reduce { _, action in
            switch action {
            case let .delegate(.ticketReceived(dest, ticket)): recorded.tickets.withValue { $0.append((dest, ticket)) }
            case let .delegate(.deliveryPreparing(_, phase)): recorded.phases.withValue { $0.append(phase) }
            case let .delegate(.messageReceived(m, _, _)): recorded.received.withValue { $0.append(m) }
            case let .router(.send(m, _)): recorded.handedOver.withValue { $0.append(m) }
            default: break
            }
            return .none
        }
        LXMFNode()
    }
}

@MainActor
private func makeNode(_ me: Identity, _ recorded: Recorded, clock: TestClock<Duration> = TestClock(),
                      seed: (inout LXMFNode.State) -> Void = { _ in }) async -> TestStoreOf<LXMFNode> {
    var initial = LXMFNode.State(identity: me, endpoint: TransportEndpoint.State())
    seed(&initial)
    let store = TestStore(initialState: initial) { RecordingNode(recorded: recorded) } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: now))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.transport(.interfaceConnected(iface, .tcp))))
    return store
}

private func deliveryHash(_ identity: Identity) -> Data { LXMessage.deliveryHash(identityHash: identity.hash) }

private func ticketField(expires: MsgPackValue, ticket: Data) -> [MsgPackValue.IntPair] {
    [.init(LXMessage.fieldTicket, .array([expires, .bin(ticket)]))]
}

/// A message from `peer` to `me`, as the router delivers it.
private func inbound(from peer: Identity, to me: Identity, fields: [MsgPackValue.IntPair] = [],
                     stamp: ((Data) -> Data)? = nil) -> LXMessage {
    let m = LXMessage.create(source: peer, destinationHash: deliveryHash(me), timestamp: now,
                             title: Data(), content: Data("reply".utf8), fields: fields)
    return stamp.map { m.withStamp($0(m.hash)) } ?? m
}

private func outbound(from me: Identity, to peer: Identity) -> LXMessage {
    LXMessage.create(source: me, destinationHash: deliveryHash(peer), timestamp: now,
                     title: Data(), content: Data("hi".utf8))
}

@MainActor
private func deliver(_ store: TestStoreOf<LXMFNode>, _ m: LXMessage, validated: Bool) async {
    await store.send(.router(.delegate(.messageDelivered(message: m, signatureValidated: validated, method: .opportunistic))))
    await store.skipReceivedActions(strict: false)
}

private func deliveryAnnounce(of peer: Identity, stampCost: Int?) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: peer)!
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0x02, count: 5))
    let payload = Announce.buildPayload(identity: peer, destinationHash: dest.hash, nameHash: dest.nameHash,
                                        randomHash: randomHash,
                                        appData: LXMFAnnounceData.pack(displayName: "Peer", stampCost: stampCost))
    return try! Packet.announce(from: dest, payload: payload).packed()
}

@MainActor
private func hearAnnounce(_ store: TestStoreOf<LXMFNode>, of peer: Identity, stampCost: Int?) async {
    await store.send(.endpoint(.transport(.received(iface, deliveryAnnounce(of: peer, stampCost: stampCost)))))
    await store.receive({ action in
        if case .endpoint(.delegate(.pathLearned)) = action { return true }
        return false
    }, timeout: .seconds(5))
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func waitForHandOver(_ store: TestStoreOf<LXMFNode>) async {
    await store.receive({ action in
        if case .router(.send) = action { return true }
        return false
    }, timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
}

@Suite @MainActor struct LXMFNodeTicketRememberTests {
    @Test func aTicketFromAValidatedMessageIsRememberedAndReported() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, recorded)
        let m = inbound(from: peer, to: me, fields: ticketField(expires: .double(now + 1000), ticket: ticketA))

        await deliver(store, m, validated: true)
        let want = LXMFNode.Ticket(ticket: ticketA, expires: Date(timeIntervalSince1970: now + 1000))
        #expect(store.state.outboundTickets == [deliveryHash(peer): want])
        #expect(recorded.tickets.value.map(\.0) == [deliveryHash(peer)])
        #expect(recorded.tickets.value.map(\.1) == [want])
        #expect(recorded.received.value.map(\.hash) == [m.hash], "the message itself is still delivered")
    }

    /// Review Focus 1: an unvalidated sender is unauthenticated, so its ticket is never kept.
    @Test func aTicketFromAnUnvalidatedMessageIsIgnored() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, recorded)
        let m = inbound(from: peer, to: me, fields: ticketField(expires: .double(now + 1000), ticket: ticketA))

        await deliver(store, m, validated: false)
        #expect(store.state.outboundTickets.isEmpty)
        #expect(recorded.tickets.value.isEmpty)
        #expect(recorded.received.value.map(\.hash) == [m.hash])
    }

    /// Reference keeps a ticket only while `time.time() < expires`: one expiring right now is not kept.
    @Test func anExpiredTicketIsNotRemembered() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, recorded)
        await deliver(store, inbound(from: peer, to: me, fields: ticketField(expires: .double(now), ticket: ticketA)),
                      validated: true)
        #expect(store.state.outboundTickets.isEmpty)
        #expect(recorded.tickets.value.isEmpty)
    }

    /// Review Focus 2: a hostile entry is ignored without trapping and the message is still delivered.
    @Test func aHostileTicketFieldIsIgnoredAndTheMessageDelivered() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, recorded)
        let hostile: [[MsgPackValue.IntPair]] = [
            ticketField(expires: .double(.infinity), ticket: ticketA),
            ticketField(expires: .double(.nan), ticket: ticketA),
            ticketField(expires: .string("soon"), ticket: ticketA),
            ticketField(expires: .double(now + 1000), ticket: Data(repeating: 1, count: 15)),
            [.init(LXMessage.fieldTicket, .bin(ticketA))],
        ]
        for fields in hostile {
            await deliver(store, inbound(from: peer, to: me, fields: fields), validated: true)
        }
        #expect(store.state.outboundTickets.isEmpty)
        #expect(recorded.tickets.value.isEmpty)
        #expect(recorded.received.value.count == hostile.count)
    }

    /// One ticket per peer, the newest received wins; the same ticket again changes nothing.
    @Test func theNewestTicketReplacesTheOldAndARepeatIsNotReportedAgain() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, recorded)
        func carrying(_ t: Data, _ expires: Double, _ text: String) -> LXMessage {
            LXMessage.create(source: peer, destinationHash: deliveryHash(me), timestamp: now, title: Data(),
                             content: Data(text.utf8), fields: ticketField(expires: .double(expires), ticket: t))
        }
        await deliver(store, carrying(ticketA, now + 2000, "one"), validated: true)
        await deliver(store, carrying(ticketB, now + 1000, "two"), validated: true)    // newer, even if sooner
        await deliver(store, carrying(ticketB, now + 1000, "three"), validated: true)  // a repeat
        #expect(store.state.outboundTickets[deliveryHash(peer)]
                == LXMFNode.Ticket(ticket: ticketB, expires: Date(timeIntervalSince1970: now + 1000)))
        #expect(recorded.tickets.value.map(\.1.ticket) == [ticketA, ticketB])
    }

    /// Reference remembers the ticket before its ignore check (LXMRouter.py:2176 vs :2231).
    @Test func aTicketFromAnIgnoredSenderIsStillRememberedButTheMessageDropped() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, recorded) { $0.ignoredDestinations = [deliveryHash(peer)] }
        await deliver(store, inbound(from: peer, to: me, fields: ticketField(expires: .uint(UInt64(now) + 1000), ticket: ticketA)),
                      validated: true)
        #expect(store.state.outboundTickets[deliveryHash(peer)]?.ticket == ticketA)
        #expect(recorded.received.value.isEmpty)
    }
}

@Suite @MainActor struct LXMFNodeTicketUseTests {
    /// Review Focus 4, end to end: a ticket received from the peer is used for the next send to it,
    /// which has no path and no known cost — so without the ticket it would wait for the announce.
    @Test func aReceivedTicketStampsTheNextSendWithNoWaitAndNoPreparing() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, recorded)
        await deliver(store, inbound(from: peer, to: me, fields: ticketField(expires: .double(now + 1000), ticket: ticketA)),
                      validated: true)

        let m = outbound(from: me, to: peer)
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await waitForHandOver(store)
        #expect(recorded.handedOver.value.map(\.stamp) == [LXMessage.ticketStamp(ticket: ticketA, messageHash: m.hash)])
        #expect(recorded.phases.value.isEmpty, "no deliveryPreparing for a ticketed send")
        #expect(store.state.waitingForPeerCost.isEmpty)
        #expect(store.state.inFlightDeliveryStamps.isEmpty)
        #expect(store.state.preparingPhases.isEmpty)
    }

    /// A ticket that arrives while a first send waits for the peer's cost releases the send at once
    /// with the ticket stamp, with no clock advance. Nothing is kept for re-stamping and no stamp
    /// search is reported as preparing.
    @Test func aTicketLearnedDuringTheCostWaitStampsTheSendAtOnce() async {
        let me = Identity(), peer = Identity(), recorded = Recorded(), clock = TestClock()
        let store = await makeNode(me, recorded, clock: clock)
        let m = outbound(from: me, to: peer)
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        #expect(recorded.phases.value == [.waitingForPeer])
        #expect(recorded.handedOver.value.isEmpty)

        await deliver(store, inbound(from: peer, to: me, fields: ticketField(expires: .double(now + 1000), ticket: ticketA)),
                      validated: true)
        #expect(recorded.handedOver.value.map(\.stamp) == [LXMessage.ticketStamp(ticket: ticketA, messageHash: m.hash)])
        #expect(recorded.phases.value == [.waitingForPeer, .handedOver], "no .stamping was reported")
        #expect(store.state.waitingForPeerCost.isEmpty)
        #expect(store.state.inFlightDeliveryStamps.isEmpty)
        #expect(store.state.unstampedHandOvers.isEmpty)
    }

    /// The same release when the ticket comes from `.rehydrateTickets` (the app restoring its store).
    @Test func aRestoredTicketReleasesASendWaitingForTheCostAtOnce() async {
        let me = Identity(), peer = Identity(), recorded = Recorded(), clock = TestClock()
        let store = await makeNode(me, recorded, clock: clock)
        let m = outbound(from: me, to: peer)
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        #expect(recorded.handedOver.value.isEmpty)

        let ticket = LXMFNode.Ticket(ticket: ticketA, expires: Date(timeIntervalSince1970: now + 1000))
        await store.send(.rehydrateTickets(outbound: [deliveryHash(peer): ticket], inbound: [:], lastDeliveries: [:]))
        await store.skipReceivedActions(strict: false)
        #expect(recorded.handedOver.value.map(\.stamp) == [LXMessage.ticketStamp(ticket: ticketA, messageHash: m.hash)])
        #expect(recorded.phases.value == [.waitingForPeer, .handedOver], "no .stamping was reported")
        #expect(store.state.waitingForPeerCost.isEmpty)
        #expect(store.state.inFlightDeliveryStamps.isEmpty)
        #expect(store.state.unstampedHandOvers.isEmpty)
    }

    /// Review Focus 4: a peer with a cost and a ticket gets the ticket stamp, not a search.
    @Test func aTicketReplacesTheProofOfWorkForAPeerWithACost() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, recorded) {
            $0.outboundTickets[deliveryHash(peer)] = LXMFNode.Ticket(ticket: ticketA, expires: Date(timeIntervalSince1970: now + 1))
        }
        await hearAnnounce(store, of: peer, stampCost: cheapCost)

        let m = outbound(from: me, to: peer)
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        #expect(store.state.inFlightDeliveryStamps.isEmpty, "no search was started")
        await waitForHandOver(store)
        #expect(recorded.handedOver.value.map(\.stamp) == [LXMessage.ticketStamp(ticket: ticketA, messageHash: m.hash)])
        #expect(recorded.phases.value.isEmpty)
    }

    /// Reference attaches a ticket stamp even when the peer advertises no cost (LXMessage.py:306-316).
    @Test func aTicketIsUsedEvenWhenThePeerAdvertisesNoCost() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, recorded) {
            $0.outboundTickets[deliveryHash(peer)] = LXMFNode.Ticket(ticket: ticketA, expires: Date(timeIntervalSince1970: now + 1))
        }
        await hearAnnounce(store, of: peer, stampCost: nil)

        let m = outbound(from: me, to: peer)
        await store.send(.send(destinationHash: deliveryHash(peer), title: Data(), content: Data("hi".utf8), method: .opportunistic))
        await waitForHandOver(store)
        #expect(recorded.handedOver.value.map(\.stamp) == [LXMessage.ticketStamp(ticket: ticketA, messageHash: m.hash)])
        #expect(recorded.phases.value.isEmpty)
    }

    /// Review Focus 3: an expired ticket is not used; the first send waits for the peer's cost as usual.
    @Test func anExpiredTicketIsNotUsedAndTheFirstSendWaits() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, recorded) {
            $0.outboundTickets[deliveryHash(peer)] = LXMFNode.Ticket(ticket: ticketA, expires: Date(timeIntervalSince1970: now))
        }
        let m = outbound(from: me, to: peer)
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await store.skipReceivedActions(strict: false)
        #expect(recorded.handedOver.value.isEmpty)
        #expect(recorded.phases.value == [.waitingForPeer])
        #expect(store.state.waitingForPeerCost[deliveryHash(peer)]?.count == 1)
        await store.send(.cancelDeliveryStamps)
        await store.skipReceivedActions(strict: false)
    }

    /// Review Focus 3: with an expired ticket and a known cost, the proof-of-work is searched.
    @Test func anExpiredTicketFallsBackToTheProofOfWork() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, recorded) {
            $0.outboundTickets[deliveryHash(peer)] = LXMFNode.Ticket(ticket: ticketA, expires: Date(timeIntervalSince1970: now - 1))
        }
        await hearAnnounce(store, of: peer, stampCost: cheapCost)
        let m = outbound(from: me, to: peer)
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await waitForHandOver(store)
        let sent = recorded.handedOver.value.first
        #expect(sent?.stamp?.count == LXStamper.stampSize)
        #expect(sent?.validateStamp(targetCost: cheapCost) == true)
        #expect(recorded.phases.value == [.stamping, .handedOver])
    }
}

// MARK: - Propagated copies

private let pnHash = Data(repeating: 0xC0, count: 16)
private let pnStampCost = 2

/// A node that knows `recipient`'s identity and path, with a propagation node set.
@MainActor
private func makePropagationNode(recipient: Identity, recorded: Recorded, clock: TestClock<Duration>,
                                 seed: (inout LXMFNode.State) -> Void = { _ in }) -> TestStoreOf<LXMFNode> {
    let dest = deliveryHash(recipient)
    var ep = TransportEndpoint.State.tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ep.transport.learned[dest] = LearnedDestination(identity: recipient, appData: nil, ratchet: nil,
                                                    interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil,
                                                    announceEmitted: 0)
    ep.transport.learned[pnHash] = LearnedDestination(
        identity: Identity(),
        appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 0, perSyncLimit: 0,
                            targetStampCost: pnStampCost, stampCostFlexibility: 0, peeringCost: 0).packed,
        ratchet: nil, interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    var node = LXMFNode.State(identity: Identity(), endpoint: ep)
    node.router.outboundPropagationNode = pnHash
    node.router.knownPaths.insert(dest)
    // The recipient asks for a cost, so a missed ticket shows up as a 32-byte proof-of-work stamp.
    node.learnedPeers[dest] = LXMFNode.LearnedPeer(displayName: nil, stampCost: cheapCost, supportsCompression: false,
                                                   learnedAt: Date(timeIntervalSince1970: now))
    seed(&node)
    let store = TestStore(initialState: node) { RecordingNode(recorded: recorded) } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: now))
        $0.continuousClock = clock
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

/// The copy handed to the router, opened as its recipient would.
@MainActor
private func openedPropagatedCopy(_ store: TestStoreOf<LXMFNode>, _ recipient: Identity) async throws -> LXMessage {
    let packed = LockIsolated<Data?>(nil)
    await store.receive({ action in
        guard case let .router(.sendViaPropagation(_, bytes)) = action else { return false }
        packed.setValue(bytes)
        return true
    }, timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    let bytes = try #require(packed.value)
    let container = try #require(LXMFPropagation.parseContainer(bytes))
    let entry = try #require(container.entries.first)
    return try #require(LXMFPropagation.open(lxmfData: entry, recipientIdentity: recipient))
}

@Suite @MainActor struct LXMFNodeTicketPropagationTests {
    @Test func anExplicitPropagatedSendCarriesTheTicketStamp() async throws {
        let recipient = Identity(), recorded = Recorded()
        let store = makePropagationNode(recipient: recipient, recorded: recorded, clock: TestClock()) {
            $0.outboundTickets[deliveryHash(recipient)] = LXMFNode.Ticket(ticket: ticketA, expires: Date(timeIntervalSince1970: now + 1))
        }
        await store.send(.sendViaPropagation(destinationHash: deliveryHash(recipient), title: Data("t".utf8),
                                             content: Data("c".utf8)))
        let opened = try await openedPropagatedCopy(store, recipient)
        #expect(opened.stamp == LXMessage.ticketStamp(ticket: ticketA, messageHash: opened.hash))
        #expect(opened.validateStamp(targetCost: cheapCost, tickets: [ticketA]))
    }

    /// The delivery copy left unstamped by a ticket (none held yet); the peer's ticket arrived before
    /// the fallback came due, so the fallback copy carries the ticket stamp rather than a search's.
    @Test func aFallbackCopyCarriesATicketLearnedAfterTheDeliveryCopyLeft() async throws {
        let recipient = Identity(), recorded = Recorded(), clock = TestClock()
        // No cost while the delivery copy goes out, so it goes unstamped.
        let store = makePropagationNode(recipient: recipient, recorded: recorded, clock: clock) {
            $0.learnedPeers = [:]
        }
        let dest = deliveryHash(recipient)
        let m = LXMessage.create(source: store.state.identity, destinationHash: dest, timestamp: now,
                                 title: Data("t".utf8), content: Data("both ways".utf8))
        await store.send(.sendMessage(message: m, fallbackToPropagation: true))
        await store.skipReceivedActions(strict: false)
        #expect(recorded.handedOver.value.map(\.stamp) == [nil])

        await store.send(.rehydrateLearnedPeers([dest: LXMFNode.LearnedPeer(
            displayName: nil, stampCost: cheapCost, supportsCompression: false, learnedAt: Date(timeIntervalSince1970: now))]))
        await deliver(store, inbound(from: recipient, to: store.state.identity,
                                     fields: ticketField(expires: .double(now + 1000), ticket: ticketA)),
                      validated: true)
        #expect(store.state.outboundTickets[dest]?.ticket == ticketA)

        for _ in 0..<(LXMFDelivery.propagationFallbackAfterAttempts - 1) {
            await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
        }
        let opened = try await openedPropagatedCopy(store, recipient)
        #expect(opened.hash == m.hash)
        #expect(opened.stamp == LXMessage.ticketStamp(ticket: ticketA, messageHash: m.hash))
    }
}

// MARK: - Validating inbound ticket stamps

@Suite @MainActor struct LXMFNodeTicketValidationTests {
    private func store(_ me: Identity, _ recorded: Recorded, inbound tickets: [Data: [LXMFNode.Ticket]]) async -> TestStoreOf<LXMFNode> {
        await makeNode(me, recorded) {
            // High enough that a 16-byte stamp no ticket matches never passes the proof-of-work
            // fallback by luck (at cost 8 it would 1 time in 256). Checking costs the same at any cost.
            $0.deliveryStampCost = 64
            $0.enforceDeliveryStamps = true
            $0.inboundTickets = tickets
        }
    }

    @Test func aStampFromATicketWeIssuedToTheSenderIsValid() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let s = await store(me, recorded, inbound: [deliveryHash(peer): [
            LXMFNode.Ticket(ticket: ticketB, expires: Date(timeIntervalSince1970: now + 1)),
            LXMFNode.Ticket(ticket: ticketA, expires: Date(timeIntervalSince1970: now + 1)),
        ]])
        let m = inbound(from: peer, to: me) { LXMessage.ticketStamp(ticket: ticketA, messageHash: $0) }
        await deliver(s, m, validated: false)
        #expect(recorded.received.value.map(\.hash) == [m.hash])
        #expect(recorded.received.value.first?.stampChecked == true)
        #expect(recorded.received.value.first?.stampValid == true)
    }

    /// Review Focus 5: a ticket we issued to someone else does not validate this sender's stamp.
    @Test func aStampFromATicketIssuedToAnotherPeerIsDropped() async {
        let me = Identity(), peer = Identity(), other = Identity(), recorded = Recorded()
        let s = await store(me, recorded, inbound: [deliveryHash(other): [
            LXMFNode.Ticket(ticket: ticketA, expires: Date(timeIntervalSince1970: now + 1)),
        ]])
        await deliver(s, inbound(from: peer, to: me) { LXMessage.ticketStamp(ticket: ticketA, messageHash: $0) },
                      validated: false)
        #expect(recorded.received.value.isEmpty)
    }

    /// Reference consults only tickets with `expires > now` (Storage.py:295).
    @Test func aStampFromAnExpiredTicketIsDropped() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let s = await store(me, recorded, inbound: [deliveryHash(peer): [
            LXMFNode.Ticket(ticket: ticketA, expires: Date(timeIntervalSince1970: now)),
        ]])
        await deliver(s, inbound(from: peer, to: me) { LXMessage.ticketStamp(ticket: ticketA, messageHash: $0) },
                      validated: false)
        #expect(recorded.received.value.isEmpty)
    }
}
