import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// LXMF 1.3.0 stamp tickets in `LXMFNode` (tickets plan, Task 2): issuing tickets in outbound messages,
// recording their delivery, and restoring ticket state at launch.
// Reference: LXMRouter.py:1205-1228 (generate_ticket), :2098-2102 (set before pack), :3060-3067
// (delivered), :1498-1512 (clean), Storage.py:132-137 / :228-321 (LXMF 1.3.0).

private let iface = InterfaceID("ticket-issue-iface")
private let now: TimeInterval = 1700000000.5
private let day: TimeInterval = 86400
private let ticketA = Data((0..<16).map { UInt8($0) })
private let ticketB = Data((0..<16).map { UInt8(0xF0 - $0) })
private let ticketC = Data(repeating: 0x5C, count: 16)

private func at(_ offset: TimeInterval) -> Date { Date(timeIntervalSince1970: now + offset) }

/// The bytes the `randomBytes` dependency yields in these tests, so a minted ticket is known. Not the
/// dependency's test ramp (00 01 … 0f), which equals `ticketA`.
private let mintedBytes = Data(repeating: 0xA5, count: 16)
private let mintedRandom = RandomBytesGenerator { Data(repeating: 0xA5, count: $0) }

/// Counted in a reducer: with exhaustivity off, `store.send` skips actions a later `receive` could see.
private final class Recorded: Sendable {
    let issued = LockIsolated<[(Data, LXMFNode.Ticket)]>([])
    let delivered = LockIsolated<[(Data, Date)]>([])
    let handedOver = LockIsolated<[LXMessage]>([])
}

private struct RecordingNode: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let recorded: Recorded

    var body: some Reducer<State, Action> {
        Reduce { _, action in
            switch action {
            case let .delegate(.ticketIssued(dest, ticket)): recorded.issued.withValue { $0.append((dest, ticket)) }
            case let .delegate(.ticketDelivered(dest, at)): recorded.delivered.withValue { $0.append((dest, at)) }
            case let .router(.send(m, _)): recorded.handedOver.withValue { $0.append(m) }
            default: break
            }
            return .none
        }
        LXMFNode()
    }
}

private func deliveryHash(_ identity: Identity) -> Data { LXMessage.deliveryHash(identityHash: identity.hash) }

/// A node that knows `peer` asks no stamp cost, so a send to it reaches the router at once.
@MainActor
private func makeNode(_ me: Identity, peer: Identity, _ recorded: Recorded,
                      seed: (inout LXMFNode.State) -> Void = { _ in }) async -> TestStoreOf<LXMFNode> {
    var initial = LXMFNode.State(identity: me, endpoint: TransportEndpoint.State())
    initial.learnedPeers[deliveryHash(peer)] = LXMFNode.LearnedPeer(displayName: nil, stampCost: nil,
                                                                    supportsCompression: false, learnedAt: at(0))
    seed(&initial)
    let store = TestStore(initialState: initial) { RecordingNode(recorded: recorded) } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: now))
        $0.uuid = .incrementing
        $0.randomBytes = mintedRandom
    }
    store.exhaustivity = .off
    await store.send(.endpoint(.transport(.interfaceConnected(iface, .tcp))))
    return store
}

@MainActor
private func send(_ store: TestStoreOf<LXMFNode>, to peer: Identity, _ text: String = "hi") async {
    await store.send(.send(destinationHash: deliveryHash(peer), title: Data(), content: Data(text.utf8),
                           method: .opportunistic))
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func confirm(_ store: TestStoreOf<LXMFNode>, _ hash: Data) async {
    await store.send(.router(.delegate(.deliveryConfirmed(messageHash: hash))))
    await store.skipReceivedActions(strict: false)
}

// MARK: - Issuing in messages the node builds

@Suite @MainActor struct LXMFNodeTicketIssueTests {
    @Test func issuingIsOffByDefault() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded)
        #expect(store.state.issueTickets == false)
        await send(store, to: peer)
        #expect(recorded.handedOver.value.count == 1)
        #expect(recorded.handedOver.value.first?.fields.isEmpty == true)
        #expect(store.state.inboundTickets.isEmpty)
        #expect(recorded.issued.value.isEmpty)
    }

    /// The first send mints a 21-day ticket inside the signed payload, records it and reports it.
    @Test func aSendMintsATicketThatTheMessageCarriesAndTheNodeRecords() async throws {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded)
        await store.send(.setIssueTickets(true))
        await send(store, to: peer)

        let m = try #require(recorded.handedOver.value.first)
        let entry = try #require(m.ticketField)
        #expect(entry.expires == now + LXMessage.ticketExpiry)
        #expect(entry.ticket == mintedBytes, "the bytes come from the randomBytes dependency")
        let minted = LXMFNode.Ticket(ticket: entry.ticket, expires: at(LXMessage.ticketExpiry))
        #expect(store.state.inboundTickets == [deliveryHash(peer): [minted]])
        #expect(recorded.issued.value.map(\.0) == [deliveryHash(peer)])
        #expect(recorded.issued.value.map(\.1) == [minted])
        // The field is in the hashed, signed payload: the message still verifies as sent.
        let reparsed = try #require(LXMessage.unpack(m.packed))
        #expect(reparsed.hash == m.hash)
        #expect(reparsed.ticketField?.ticket == entry.ticket)
        #expect(reparsed.validateSignature(source: me))
    }

    /// Reference step 2: a ticket already issued with more than 14 days left is reused, not re-minted
    /// or re-reported — the one with the latest expiry.
    @Test func theNextSendReusesTheTicketWithTheLatestExpiryAndReportsNothing() async throws {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded) {
            $0.issueTickets = true
            $0.inboundTickets[deliveryHash(peer)] = [
                LXMFNode.Ticket(ticket: ticketA, expires: at(15 * day)),
                LXMFNode.Ticket(ticket: ticketB, expires: at(20 * day)),
                LXMFNode.Ticket(ticket: ticketC, expires: at(16 * day)),
            ]
        }
        let before = store.state.inboundTickets
        await send(store, to: peer)
        let entry = try #require(recorded.handedOver.value.first?.ticketField)
        #expect(entry.ticket == ticketB)
        #expect(entry.expires == now + 20 * day)
        #expect(store.state.inboundTickets == before)
        #expect(recorded.issued.value.isEmpty)
    }

    /// Reference reuses only `expires > now + TICKET_RENEW`: exactly 14 days left is not enough.
    @Test func aTicketWithExactlyFourteenDaysLeftIsNotReusedAndANewOneIsMinted() async throws {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded) {
            $0.issueTickets = true
            $0.inboundTickets[deliveryHash(peer)] = [LXMFNode.Ticket(ticket: ticketA, expires: at(LXMessage.ticketRenew))]
        }
        await send(store, to: peer)
        let entry = try #require(recorded.handedOver.value.first?.ticketField)
        #expect(entry.ticket == mintedBytes)
        #expect(entry.expires == now + LXMessage.ticketExpiry)
        #expect(store.state.inboundTickets[deliveryHash(peer)]?.map(\.ticket) == [ticketA, entry.ticket])
        #expect(recorded.issued.value.map(\.1.ticket) == [entry.ticket])
    }

    /// Reference step 1: none while the last delivered ticket is less than a day old; one once it is.
    @Test func noTicketIsIncludedWithinADayOfTheLastDeliveredOne() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded) {
            $0.issueTickets = true
            $0.lastTicketDeliveries[deliveryHash(peer)] = at(-day + 1)
        }
        await send(store, to: peer, "too soon")
        #expect(recorded.handedOver.value.last?.ticketField == nil)
        #expect(store.state.inboundTickets.isEmpty)

        var state = store.state
        state.lastTicketDeliveries[deliveryHash(peer)] = at(-day)
        #expect(state.ticketFieldToIssue(destinationHash: deliveryHash(peer), now: at(0)) != nil,
                "exactly a day later a ticket is included again")
    }

    /// Reference sets `include_ticket` per message, for propagated messages too (`handle_outbound`).
    @Test func anExplicitPropagatedSendCarriesTheTicketToo() async throws {
        let recipient = Identity(), recorded = Recorded()
        let store = makePropagationNode(recipient: recipient, recorded: recorded)
        await store.send(.sendViaPropagation(destinationHash: deliveryHash(recipient), title: Data("t".utf8),
                                             content: Data("c".utf8)))
        let opened = try await openedPropagatedCopy(store, recipient)
        let entry = try #require(opened.ticketField)
        #expect(store.state.inboundTickets[deliveryHash(recipient)]?.map(\.ticket) == [entry.ticket])
        #expect(recorded.issued.value.map(\.0) == [deliveryHash(recipient)])
    }
}

// MARK: - Delivery of an issued ticket

@Suite @MainActor struct LXMFNodeTicketDeliveryTests {
    @Test func aConfirmedTicketCarryingMessageRecordsTheDeliveryAndTheNextSendCarriesNone() async throws {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded) { $0.issueTickets = true }
        await send(store, to: peer)
        let m = try #require(recorded.handedOver.value.first)
        #expect(m.ticketField != nil)

        await confirm(store, m.hash)
        #expect(store.state.lastTicketDeliveries == [deliveryHash(peer): at(0)])
        #expect(recorded.delivered.value.map(\.0) == [deliveryHash(peer)])
        #expect(recorded.delivered.value.map(\.1) == [at(0)])
        #expect(store.state.ticketCarryingMessages.isEmpty)

        await send(store, to: peer, "again")
        #expect(recorded.handedOver.value.count == 2)
        #expect(recorded.handedOver.value.last?.ticketField == nil)
    }

    @Test func aConfirmedMessageWithoutATicketRecordsNoDelivery() async throws {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded)
        await send(store, to: peer)
        let m = try #require(recorded.handedOver.value.first)
        await confirm(store, m.hash)
        #expect(store.state.lastTicketDeliveries.isEmpty)
        #expect(recorded.delivered.value.isEmpty)
    }

    /// A message the app cancels ends through the router's real path and is forgotten, so a late
    /// confirmation for it counts as no delivery.
    @Test func aCancelledTicketCarryingMessageIsForgottenWithoutADelivery() async throws {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded) { $0.issueTickets = true }
        await send(store, to: peer)
        let m = try #require(recorded.handedOver.value.first)
        #expect(store.state.ticketCarryingMessages == [m.hash: deliveryHash(peer)])

        await store.send(.cancelOutbound(messageHash: m.hash))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.router.hasOutboundState(for: m.hash) == false)
        #expect(store.state.ticketCarryingMessages.isEmpty)
        await confirm(store, m.hash)
        #expect(store.state.lastTicketDeliveries.isEmpty)
        #expect(recorded.delivered.value.isEmpty)
    }
}

// MARK: - Forgetting ticket-carrying messages

private let staleHash = Data(repeating: 0x51, count: 32)
private let otherHash = Data(repeating: 0x0E, count: 32)
private let someDest = Data(repeating: 0xDE, count: 16)

/// The terminal outcomes the node reports; each must sweep.
enum TicketSweepTerminal: CaseIterable, Sendable {
    case failed, rejected, cancelled, confirmed, propagationAccepted

    func action(_ hash: Data) -> LXMFNode.Action {
        switch self {
        case .failed:              return .delegate(.deliveryFailed(messageHash: hash))
        case .rejected:            return .delegate(.deliveryRejected(messageHash: hash))
        case .cancelled:           return .delegate(.deliveryCancelled(messageHash: hash))
        case .confirmed:           return .delegate(.deliveryConfirmed(messageHash: hash))
        case .propagationAccepted: return .delegate(.propagationAccepted(messageHash: hash))
        }
    }
}

@Suite @MainActor struct LXMFNodeTicketSweepTests {
    /// Each terminal outcome — of ANY message — collects a ticket-carrying message nothing holds any
    /// more. This is how a delivery copy that ended silently is collected.
    @Test(arguments: TicketSweepTerminal.allCases)
    func everyTerminalOutcomeForgetsAMessageThatCanNoLongerBeConfirmed(_ terminal: TicketSweepTerminal) async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded) { $0.ticketCarryingMessages = [staleHash: someDest] }
        await store.send(terminal.action(otherHash))
        #expect(store.state.ticketCarryingMessages.isEmpty)
    }

    // The "kept" tests below sweep through a new ticket-carrying send, the other sweep trigger.
    // The last one also shows that send does sweep: it drops a message nothing holds.

    /// A message the router still holds is kept by a sweep.
    @Test func aMessageTheRouterStillHoldsIsKept() async throws {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded) { $0.issueTickets = true }
        await send(store, to: peer)
        let m = try #require(recorded.handedOver.value.first)
        #expect(store.state.router.hasOutboundState(for: m.hash))

        await send(store, to: peer, "sweep")   // a new ticket-carrying send sweeps
        #expect(store.state.ticketCarryingMessages[m.hash] == deliveryHash(peer))
    }

    /// A message still waiting in the node for its recipient's announce (not yet in the router) is kept.
    @Test func aMessageStillWaitingInTheNodeIsKept() async throws {
        let me = Identity(), peer = Identity(), stranger = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded) { $0.issueTickets = true }
        await send(store, to: stranger)    // no path, no cost: it waits for the announce
        let hash = try #require(store.state.ticketCarryingMessages.keys.first)
        #expect(store.state.router.hasOutboundState(for: hash) == false)
        #expect(store.state.waitingForPeerCost[deliveryHash(stranger)]?.count == 1)

        await send(store, to: peer, "sweep")   // a new ticket-carrying send sweeps
        #expect(store.state.ticketCarryingMessages[hash] == deliveryHash(stranger))
        await store.send(.cancelDeliveryStamps)
        await store.skipReceivedActions(strict: false)
    }

    /// The router has settled a delivery success whose confirmation the node has not handled yet:
    /// a sweep in between must not lose it.
    @Test func aSuccessTheNodeHasNotHandledYetIsKeptAndStillCounts() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let pending = Data(repeating: 0x77, count: 32)
        let store = await makeNode(me, peer: peer, recorded) {
            $0.issueTickets = true
            $0.ticketCarryingMessages = [pending: someDest, staleHash: someDest]
            $0.router.succeededMessages.insert(pending)
        }
        await send(store, to: peer, "sweep")   // a new ticket-carrying send sweeps
        #expect(store.state.ticketCarryingMessages[pending] == someDest)
        #expect(store.state.ticketCarryingMessages[staleHash] == nil, "the send swept")
        await confirm(store, pending)
        #expect(store.state.lastTicketDeliveries[someDest] == at(0))
        #expect(store.state.ticketCarryingMessages[pending] == nil)
    }

    /// The fallback's propagated copy is accepted while the delivery copy is still out: the entry
    /// is kept, and the delivery copy's later confirmation still records the ticket's delivery.
    @Test func afterThePropagatedCopyIsAcceptedTheDeliveryCopysConfirmationStillCounts() async throws {
        let recipient = Identity(), recorded = Recorded(), clock = TestClock()
        let store = makePropagationNode(recipient: recipient, recorded: recorded, clock: clock, pnLinkActive: true)
        let m = try await sendFallbackUntilThePropagatedCopyIsAccepted(store, recipient, clock)
        #expect(store.state.ticketCarryingMessages[m.hash] == deliveryHash(recipient))
        #expect(store.state.ticketMessagesAccepted == [m.hash])

        await store.send(.router(.opportunisticDelivered(messageHash: m.hash)))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.lastTicketDeliveries == [deliveryHash(recipient): at(0)])
        #expect(store.state.ticketCarryingMessages.isEmpty)
        #expect(store.state.ticketMessagesAccepted.isEmpty)
    }

    /// The same, but the delivery copy then runs out. The router reports nothing for it (a copy
    /// already succeeded), so the entry is collected by the next terminal outcome of any message,
    /// and no delivery is recorded.
    @Test func afterThePropagatedCopyIsAcceptedADeliveryCopyThatEndsSilentlyIsCollected() async throws {
        let recipient = Identity(), recorded = Recorded(), clock = TestClock()
        let store = makePropagationNode(recipient: recipient, recorded: recorded, clock: clock, pnLinkActive: true)
        let m = try await sendFallbackUntilThePropagatedCopyIsAccepted(store, recipient, clock)

        for _ in 0..<(LXMFDelivery.maxAttempts + 2) {
            await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
            await store.skipReceivedActions(strict: false)
        }
        #expect(store.state.router.hasOutboundState(for: m.hash) == false, "the delivery copy has ended")
        #expect(store.state.ticketCarryingMessages[m.hash] != nil, "silently: nothing has swept it yet")

        await store.send(TicketSweepTerminal.failed.action(otherHash))
        #expect(store.state.ticketCarryingMessages.isEmpty)
        #expect(store.state.ticketMessagesAccepted.isEmpty)
        #expect(store.state.lastTicketDeliveries.isEmpty)
    }
}

/// Send a ticket-carrying fallback message, let its delivery copy stall until the propagated copy
/// is handed to the (active) node link, and have the router accept that copy.
@MainActor
private func sendFallbackUntilThePropagatedCopyIsAccepted(_ store: TestStoreOf<LXMFNode>, _ recipient: Identity,
                                                          _ clock: TestClock<Duration>) async throws -> LXMessage {
    let dest = deliveryHash(recipient)
    let field = try #require(store.state.ticketFieldToIssue(destinationHash: dest, now: at(0), newTicket: mintedBytes))
    let m = LXMessage.create(source: store.state.identity, destinationHash: dest, timestamp: now,
                             title: Data("t".utf8), content: Data("both ways".utf8), fields: [field])
    await store.send(.sendMessage(message: m, fallbackToPropagation: true))
    await store.skipReceivedActions(strict: false)
    for _ in 0..<(LXMFDelivery.propagationFallbackAfterAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.receive({ action in
        if case .router(.sendViaPropagation) = action { return true }
        return false
    }, timeout: .seconds(30))
    await store.skipReceivedActions(strict: false)
    await store.send(.router(.delivered(messageHash: m.hash, leg: .propagated)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.router.hasOutboundState(for: m.hash), "the delivery copy is still out")
    return m
}

// MARK: - Host-built messages

@Suite @MainActor struct LXMFNodeTicketHostHelperTests {
    @Test func theHelperReturnsNothingWhileIssuingIsOff() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded)
        #expect(store.state.ticketFieldToIssue(destinationHash: deliveryHash(peer), now: at(0)) == nil)
    }

    /// The no-bytes helper draws a fresh 16-byte ticket each call; bytes of the wrong length mint nothing.
    @Test func theHelperMintsSixteenFreshBytesAndRefusesWrongLengthBytes() async throws {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded) { $0.issueTickets = true }
        let dest = deliveryHash(peer)
        func ticket(_ field: MsgPackValue.IntPair?) -> Data? {
            guard case let .array(items)? = field?.value, items.count == 2, case let .bin(t) = items[1] else { return nil }
            return t
        }
        let one = try #require(ticket(store.state.ticketFieldToIssue(destinationHash: dest, now: at(0))))
        let two = try #require(ticket(store.state.ticketFieldToIssue(destinationHash: dest, now: at(0))))
        #expect(one.count == LXMessage.ticketLength)
        #expect(one != two)
        #expect(store.state.ticketFieldToIssue(destinationHash: dest, now: at(0), newTicket: Data(count: 15)) == nil)
    }

    /// The host builds its message with the helper's field; `.sendMessage` records the mint, and the
    /// delivery counts.
    @Test func aHostMessageWithTheHelpersFieldIsRecordedAsIssuedAndItsDeliveryCounted() async throws {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded) { $0.issueTickets = true }
        let field = try #require(store.state.ticketFieldToIssue(destinationHash: deliveryHash(peer), now: at(0)))
        #expect(store.state.inboundTickets.isEmpty, "asking records nothing")
        let m = LXMessage.create(source: me, destinationHash: deliveryHash(peer), timestamp: now, title: Data(),
                                 content: Data("hi".utf8), fields: [field])
        let entry = try #require(m.ticketField)

        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await store.skipReceivedActions(strict: false)
        let minted = LXMFNode.Ticket(ticket: entry.ticket, expires: at(LXMessage.ticketExpiry))
        #expect(store.state.inboundTickets == [deliveryHash(peer): [minted]])
        #expect(recorded.issued.value.map(\.1) == [minted])

        // The helper now reuses that ticket.
        #expect(store.state.ticketFieldToIssue(destinationHash: deliveryHash(peer), now: at(0)) == field)

        await confirm(store, m.hash)
        #expect(store.state.lastTicketDeliveries == [deliveryHash(peer): at(0)])
        #expect(recorded.delivered.value.map(\.0) == [deliveryHash(peer)])
    }

    /// Only a message from our own delivery destination is ours to record.
    @Test func aTicketInAMessageFromAnotherSourceIsNotRecorded() async {
        let me = Identity(), peer = Identity(), other = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded)
        let m = LXMessage.create(source: other, destinationHash: deliveryHash(peer), timestamp: now, title: Data(),
                                 content: Data("hi".utf8),
                                 fields: [.init(LXMessage.fieldTicket, .array([.double(now + day), .bin(ticketA)]))])
        await store.send(.sendMessage(message: m, fallbackToPropagation: false))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.inboundTickets.isEmpty)
        #expect(store.state.ticketCarryingMessages.isEmpty)
        #expect(recorded.issued.value.isEmpty)
    }
}

// MARK: - Rehydrating

@Suite @MainActor struct LXMFNodeTicketRehydrateTests {
    /// Reference culls `expires < cutoff` with cutoff now (outbound) and now - 5 d (inbound);
    /// malformed rows and future delivery times are dropped too.
    @Test func rehydrateRestoresInBoundRowsAndDropsExpiredMalformedAndFutureOnes() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let store = await makeNode(me, peer: peer, recorded)
        let p1 = Data(repeating: 1, count: 16), p2 = Data(repeating: 2, count: 16), p3 = Data(repeating: 3, count: 16)
        let p4 = Data(repeating: 4, count: 16), p5 = Data(repeating: 5, count: 16)
        let nan = Date(timeIntervalSinceReferenceDate: .nan)
        await store.send(.rehydrateTickets(
            outbound: [
                p1: LXMFNode.Ticket(ticket: ticketA, expires: at(0)),        // exactly at expiry: kept
                p2: LXMFNode.Ticket(ticket: ticketA, expires: at(-1)),       // expired
                p3: LXMFNode.Ticket(ticket: Data(repeating: 9, count: 15), expires: at(day)),   // malformed
                p4: LXMFNode.Ticket(ticket: ticketB, expires: nan),          // non-finite
            ],
            inbound: [
                p1: [LXMFNode.Ticket(ticket: ticketA, expires: at(-LXMessage.ticketGrace)),      // in grace: kept
                     LXMFNode.Ticket(ticket: ticketB, expires: at(-LXMessage.ticketGrace - 1)),  // past grace
                     LXMFNode.Ticket(ticket: ticketC, expires: nan)],
                p2: [LXMFNode.Ticket(ticket: Data(repeating: 7, count: 17), expires: at(day))],
            ],
            lastDeliveries: [p1: at(-day), p2: at(1), p3: nan, p5: at(0)]))

        #expect(store.state.outboundTickets == [p1: LXMFNode.Ticket(ticket: ticketA, expires: at(0))])
        #expect(store.state.inboundTickets == [p1: [LXMFNode.Ticket(ticket: ticketA, expires: at(-LXMessage.ticketGrace))]])
        #expect(store.state.lastTicketDeliveries == [p1: at(-day), p5: at(0)])
    }

    /// Rehydration may land after the network: live state is never replaced by a restored row.
    @Test func rehydrateNeverReplacesLiveState() async {
        let me = Identity(), peer = Identity(), recorded = Recorded()
        let p1 = Data(repeating: 1, count: 16), p2 = Data(repeating: 2, count: 16)
        let store = await makeNode(me, peer: peer, recorded) {
            $0.outboundTickets[p1] = LXMFNode.Ticket(ticket: ticketA, expires: at(day))
            $0.inboundTickets[p1] = [LXMFNode.Ticket(ticket: ticketA, expires: at(10 * day))]
            $0.lastTicketDeliveries[p1] = at(-10)
            $0.lastTicketDeliveries[p2] = at(-100)
        }
        await store.send(.rehydrateTickets(
            outbound: [p1: LXMFNode.Ticket(ticket: ticketB, expires: at(20 * day))],   // later expiry, still older
            inbound: [p1: [LXMFNode.Ticket(ticket: ticketA, expires: at(3 * day)),     // the same ticket again
                           LXMFNode.Ticket(ticket: ticketB, expires: at(5 * day))]],
            lastDeliveries: [p1: at(-20), p2: at(-50)]))

        #expect(store.state.outboundTickets == [p1: LXMFNode.Ticket(ticket: ticketA, expires: at(day))])
        #expect(store.state.inboundTickets == [p1: [LXMFNode.Ticket(ticket: ticketA, expires: at(10 * day)),
                                                    LXMFNode.Ticket(ticket: ticketB, expires: at(5 * day))]])
        #expect(store.state.lastTicketDeliveries == [p1: at(-10), p2: at(-50)], "a newer restored time wins")
    }
}

// MARK: - Cross-validation against reference

/// Pasted from `Vectors/generate_lxmf_ticket_issue_fixtures.py` (LXMF 1.3.0): reference's message with
/// `fields[FIELD_TICKET] = [now + TICKET_EXPIRY, ticket]`, built from these fixed inputs.
private enum IssueFixture {
    static let sourcePrivateKey = String(repeating: "33", count: 32) + String(repeating: "44", count: 32)
    static let destinationHash = "8deeea53a19d94d6c4852f5f3c9f65db"
    static let now: TimeInterval = 1700000000.5
    static let ticket = "a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
    static let messageId = "9c88058f793a053d4fa37dbb6fd8d7c14cdb96fa2dc1345c2e245163123f1e25"
    static let payload = "94cb41d954fc40200000c40174c40d686176652061207469636b6574810c92cb41d95be820200000c410a0a1a2a3a4a5a6a7a8a9aaabacadaeaf"
}

@Test func theIssuedTicketFieldMakesTheMessageReferenceMakes() throws {
    let source = try #require(Identity(privateKey: Data(hexString: IssueFixture.sourcePrivateKey)!))
    let dest = Data(hexString: IssueFixture.destinationHash)!
    var state = LXMFNode.State(identity: source, endpoint: TransportEndpoint.State())
    state.issueTickets = true
    let field = try #require(state.ticketFieldToIssue(destinationHash: dest,
                                                      now: Date(timeIntervalSince1970: IssueFixture.now),
                                                      newTicket: Data(hexString: IssueFixture.ticket)!))
    let m = LXMessage.create(source: source, destinationHash: dest, timestamp: IssueFixture.now,
                             title: Data("t".utf8), content: Data("have a ticket".utf8), fields: [field])
    #expect(m.hash == Data(hexString: IssueFixture.messageId)!)
    let headerLength = 2 * LXMessage.destinationLength + LXMessage.signatureLength
    #expect(Data(m.packed.dropFirst(headerLength)) == Data(hexString: IssueFixture.payload)!)
}

// MARK: - Propagated-copy helpers

private let pnHash = Data(repeating: 0xC0, count: 16)

@MainActor
private func makePropagationNode(recipient: Identity, recorded: Recorded, clock: TestClock<Duration> = TestClock(),
                                 pnLinkActive: Bool = false) -> TestStoreOf<LXMFNode> {
    let dest = deliveryHash(recipient)
    var ep = TransportEndpoint.State.tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ep.transport.learned[dest] = LearnedDestination(identity: recipient, appData: nil, ratchet: nil,
                                                    interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil,
                                                    announceEmitted: 0)
    ep.transport.learned[pnHash] = LearnedDestination(
        identity: Identity(),
        appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 0, perSyncLimit: 0,
                            targetStampCost: 2, stampCostFlexibility: 0, peeringCost: 0).packed,
        ratchet: nil, interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    var node = LXMFNode.State(identity: Identity(), endpoint: ep)
    node.router.outboundPropagationNode = pnHash
    node.router.knownPaths.insert(dest)
    node.issueTickets = true
    if pnLinkActive { node.router.directLinks[pnHash] = .active(linkID: Data(repeating: 0x1D, count: 16)) }
    let store = TestStore(initialState: node) { RecordingNode(recorded: recorded) } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: now))
        $0.continuousClock = clock
        $0.uuid = .incrementing
        $0.randomBytes = mintedRandom
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

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
