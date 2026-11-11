import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport
@testable import ReTiCAInterfaces

// Propagation sync state on reference's `PR_*` scale, cross-validated against a real LXMF 1.3.0
// `LXMRouter` by `Vectors/generate_lxmf_sync_state_fixtures.py` (lxmf_sync_state_fixtures.json).

/// The generator's output, as the tests read it.
enum SyncStateFixtures {
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var phase: String
        var response: Data
        var stateBeforeResponse: UInt8
        var stateAfterResponse: UInt8
        var lastResultAfterResponse: Int?
        var teardown: Bool
        var followUp: Data?
        var stateAfterClose: UInt8
        var lastResultAfterClose: Int?
        var testDescription: String { name }
    }

    nonisolated(unsafe) static let json: [String: Any] = {
        let url = Bundle.module.url(forResource: "lxmf_sync_state_fixtures", withExtension: "json")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    static func section(_ name: String) -> [String: Any] { json[name] as! [String: Any] }
    static func int(_ any: Any?) -> Int? { any is NSNull ? nil : (any as? Int) }
    static func byte(_ any: Any?) -> UInt8 { UInt8(any as! Int) }
    static func hex(_ any: Any?) -> Data? { (any as? String).flatMap { Data(hexString: $0) } }

    static let cases: [Case] = (json["cases"] as! [[String: Any]]).map { c in
        Case(name: c["name"] as! String, phase: c["phase"] as! String, response: hex(c["response"])!,
             stateBeforeResponse: byte(c["state_before_response"]),
             stateAfterResponse: byte(c["state_after_response"]),
             lastResultAfterResponse: int(c["last_result_after_response"]),
             teardown: c["teardown"] as! Bool, followUp: hex(c["follow_up"]),
             stateAfterClose: byte(c["state_after_close"]),
             lastResultAfterClose: int(c["last_result_after_close"]))
    }
}

private let pn = Data(repeating: 0x5E, count: 16)
private let syncLink = Data(repeating: 0xA1, count: 16)
private let requestID = Data(repeating: 0x01, count: 16)

/// What these tests look for among the actions `LXMFNode` sees.
private enum Seen: Equatable, Sendable {
    case closeLink(Data)
    case openLink(Data)
    case request(linkID: Data, data: Data)
    case report(LXMFRouter.TransferReport)
}

/// `LXMFNode`, logging the actions these tests look for.
private struct Recorded: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let log: LockIsolated<[Seen]>
    var body: some ReducerOf<Self> {
        Reduce { _, action in
            let seen: Seen?
            switch action {
            case let .endpoint(.closeLink(linkID)): seen = .closeLink(linkID)
            case let .endpoint(.openLink(dest)): seen = .openLink(dest)
            case let .endpoint(.sendRequestOverLink(linkID, "/get", data)): seen = .request(linkID: linkID, data: data)
            case let .delegate(.propagationTransferStateChanged(s, r)): seen = .report(.init(state: s, lastResult: r))
            default: seen = nil
            }
            if let seen { log.withValue { $0.append(seen) } }
            return .none
        }
        LXMFNode()
    }
}

/// A node whose router has an active link to its propagation node, `syncLink`, with a sync on it in
/// `phase` and the router in `transfer`.
@MainActor
private func syncStore(phase: LXMFNode.SyncPhase?, transfer: LXMFRouter.PropagationTransferState,
                       log: LockIsolated<[Seen]>, clock: TestClock<Duration> = TestClock())
    -> TestStoreOf<Recorded> {
    var state = LXMFNode.State(identity: Identity(),
                               endpoint: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false))
    state.router.outboundPropagationNode = pn
    state.router.knownPaths.insert(pn)
    state.router.directLinks[pn] = .active(linkID: syncLink)
    state.directLinks[pn] = syncLink
    state.linkDestinations[syncLink] = pn
    state.syncPhase[syncLink] = phase
    state.router.propagationTransferState = transfer
    state.router.reportedTransfer = .init(state: transfer, lastResult: nil)
    let store = TestStore(initialState: state) { Recorded(log: log) } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

private func closedSyncLink(_ log: LockIsolated<[Seen]>) -> Bool { log.value.contains(.closeLink(syncLink)) }

private func syncRequests(_ log: LockIsolated<[Seen]>) -> [Data] {
    log.value.compactMap { if case .request(syncLink, let data) = $0 { return data }; return nil }
}

private func reported(_ log: LockIsolated<[Seen]>) -> [LXMFRouter.TransferReport] {
    log.value.compactMap { if case let .report(r) = $0 { return r }; return nil }
}

@MainActor
private func closeSyncLink(_ store: TestStoreOf<Recorded>) async {
    await store.send(.endpoint(.delegate(.linkClosed(linkID: syncLink, reason: .destinationClosed))))
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func respond(_ store: TestStoreOf<Recorded>, _ data: Data) async {
    await store.send(.endpoint(.delegate(.responseReceived(linkID: syncLink, requestID: requestID, data: data))))
    await store.skipReceivedActions(strict: false)
}

@Suite @MainActor struct LXMFNodeSyncStateTests {
    /// Every PN response kind lands where reference's `message_list_response` / `message_get_response`
    /// put it, tears down when it does, asks the same follow-up, and the close that follows ends where
    /// reference's `clean_links` ends.
    @Test(arguments: SyncStateFixtures.cases)
    func syncResponseLandsInReferenceState(_ c: SyncStateFixtures.Case) async throws {
        let log = LockIsolated<[Seen]>([])
        let before = try #require(LXMFRouter.PropagationTransferState(rawValue: c.stateBeforeResponse))
        let store = syncStore(phase: c.phase == "list" ? .awaitingList : .awaitingMessages, transfer: before, log: log)

        await respond(store, c.response)
        #expect(store.state.router.propagationTransferState.rawValue == c.stateAfterResponse)
        #expect(store.state.router.propagationTransferLastResult == c.lastResultAfterResponse)
        #expect(closedSyncLink(log) == c.teardown)
        // The follow-up request reference sends, byte for byte: `[wants, haves, limit]` after an offer,
        // the purge `[None, haves]` after a download. None after an error, an empty answer or garbage.
        #expect(syncRequests(log) == (c.followUp.map { [$0] } ?? []))

        await closeSyncLink(store)
        #expect(store.state.router.propagationTransferState.rawValue == c.stateAfterClose)
        #expect(store.state.router.propagationTransferLastResult == c.lastResultAfterClose)
    }

    /// Review Focus 1. Wire 0xF1 (`ERROR_NO_ACCESS`) is `noAccess` (0xF4), never `linkFailed` (0xF1 in
    /// the state space), and the close the teardown causes keeps it.
    @Test func noAccessIsStickyThroughTheClose() async {
        let log = LockIsolated<[Seen]>([])
        let store = syncStore(phase: .awaitingList, transfer: .requestSent, log: log)
        await respond(store, MsgPack.encode(.uint(LXMFPropagation.errorNoAccess)))
        #expect(store.state.router.propagationTransferState == .noAccess)
        #expect(store.state.router.propagationTransferState.rawValue == 0xF4)
        #expect(closedSyncLink(log))
        #expect(store.state.syncPhase[syncLink] == nil)

        await closeSyncLink(store)
        #expect(store.state.router.propagationTransferState == .noAccess)
        #expect(!reported(log).contains { $0.state == .linkFailed || $0.state == .transferFailed })
    }

    /// The propagation node was switched mid-sync and both have active links. The OLD node's link
    /// answering `ERROR_NO_ACCESS` tears down that link only, and the new node's sync state is
    /// untouched, by the answer and by the old link's close.
    @Test func aSwitchedAwayNodesErrorClosesOnlyItsOwnLink() async {
        let log = LockIsolated<[Seen]>([])
        let store = syncStore(phase: .awaitingList, transfer: .requestSent, log: log)
        let newPN = Data(repeating: 0x6F, count: 16)
        let newLink = Data(repeating: 0xC3, count: 16)
        // Set up through the router's own events: the new PN, then its link.
        await store.send(.router(.setOutboundPropagationNode(newPN)))
        await store.send(.endpoint(.delegate(.linkEstablished(linkID: newLink, destinationHash: newPN))))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.router.directLinks[newPN] == .active(linkID: newLink))
        #expect(store.state.router.propagationTransferState == .requestSent)

        await respond(store, MsgPack.encode(.uint(LXMFPropagation.errorNoAccess)))
        #expect(closedSyncLink(log))
        #expect(!log.value.contains(.closeLink(newLink)))
        #expect(store.state.router.propagationTransferState == .requestSent)

        await closeSyncLink(store)
        #expect(store.state.router.propagationTransferState == .requestSent)
        #expect(store.state.router.directLinks[newPN] == .active(linkID: newLink))
        #expect(!reported(log).contains { $0.state == .noAccess || $0.state == .transferFailed })
    }

    /// Review Focus 2. The link drops after the download completes, before the purge lands: idle, the
    /// downloaded ids stay downloaded, and no failure is reported.
    @Test func completeThenCloseGoesIdleAndKeepsDownloaded() async throws {
        let log = LockIsolated<[Seen]>([])
        let store = syncStore(phase: .awaitingMessages, transfer: .requestSent, log: log)
        let blob = try #require(SyncStateFixtures.hex(SyncStateFixtures.json["blob"]))
        let tid = LXMFPropagation.transientId(lxmfData: blob)
        await respond(store, MsgPack.encode(.array([.bin(blob)])))
        #expect(store.state.router.propagationTransferState == .complete)
        #expect(syncRequests(log) == [MsgPack.encode(.array([.null, .array([.bin(tid)])]))])  // the purge is out

        await closeSyncLink(store)
        #expect(store.state.router.propagationTransferState == .idle)
        #expect(store.state.router.propagationTransferLastResult == nil)
        #expect(store.state.router.downloadedTransientIds.contains(tid))
        #expect(reported(log) == [.init(state: .complete, lastResult: 1), .init(state: .idle, lastResult: nil)])
    }

    /// A failed sync request tears its link down (`message_get_failed`) and the close reports
    /// `transferFailed`. A failed request on a link with no sync is not ours to tear down.
    @Test func requestFailedOnSyncLinkTearsDownThenTransferFailed() async {
        let fixture = SyncStateFixtures.section("request_failed")
        let log = LockIsolated<[Seen]>([])
        let store = syncStore(phase: .awaitingList, transfer: .requestSent, log: log)

        let otherLink = Data(repeating: 0xB2, count: 16)
        await store.send(.endpoint(.delegate(.requestFailed(linkID: otherLink, requestID: requestID))))
        await store.skipReceivedActions(strict: false)
        #expect(!log.value.contains { if case .closeLink = $0 { return true }; return false })

        await store.send(.endpoint(.delegate(.requestFailed(linkID: syncLink, requestID: requestID))))
        await store.skipReceivedActions(strict: false)
        #expect(closedSyncLink(log) == (fixture["teardown"] as! Bool))
        #expect(store.state.router.propagationTransferState.rawValue == SyncStateFixtures.byte(fixture["state_after_failure"]))

        await closeSyncLink(store)
        #expect(store.state.router.propagationTransferState.rawValue == SyncStateFixtures.byte(fixture["state_after_close"]))
        #expect(store.state.router.propagationTransferState == .transferFailed)
    }

    /// A sticky failure lasts until the next sync request, which overwrites it: `requestSent` over a
    /// live link (the fixture's `next_request`), `linkEstablishing` when the link must be opened first.
    @Test func nextSyncRequestClearsAStickyFailure() async {
        let fixture = SyncStateFixtures.section("next_request")
        let sticky = SyncStateFixtures.byte(fixture["sticky_state"])

        let liveLog = LockIsolated<[Seen]>([])
        let live = syncStore(phase: nil, transfer: LXMFRouter.PropagationTransferState(rawValue: sticky)!, log: liveLog)
        await live.send(.syncFromPropagationNode)
        await live.skipReceivedActions(strict: false)
        #expect(live.state.router.propagationTransferState.rawValue == SyncStateFixtures.byte(fixture["state_after_next_request"]))

        let downLog = LockIsolated<[Seen]>([])
        let down = syncStore(phase: nil, transfer: .noAccess, log: downLog)
        await closeSyncLink(down)
        #expect(down.state.router.propagationTransferState == .noAccess)
        await down.send(.syncFromPropagationNode)
        await down.skipReceivedActions(strict: false)
        // The router knows a path, so it opens a link; this endpoint has none, so that fails path-shaped
        // and the router parks for a path request. Both are reported, and neither is the old failure.
        #expect(downLog.value.contains(.openLink(pn)))
        #expect(reported(downLog).map(\.state) == [.linkEstablishing, .pathRequested])
        #expect(down.state.router.propagationTransferState == .pathRequested)
    }

    /// Plan ruling 1a: ReTiCA keeps its establishment retries, and only the give-up is terminal. The
    /// park running out is reference's path timeout (`noPath`); the establishment ceiling is the
    /// closed link reference fails on at once (`linkFailed`).
    @Test func pathDeadlineGivesNoPathAndEstablishCeilingGivesLinkFailed() async {
        // Path timeout: no path known.
        let pathFixture = SyncStateFixtures.section("path_timeout")
        let clock = TestClock()
        var parkedState = LXMFRouter.State()
        parkedState.outboundPropagationNode = pn
        let parked = TestStore(initialState: parkedState) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
        parked.exhaustivity = .off
        await parked.send(.syncFromPropagationNode)
        #expect(parked.state.propagationTransferState.rawValue == SyncStateFixtures.byte(pathFixture["state_before_deadline"]))
        for _ in 1...LXMFDelivery.maxAttempts {
            await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
            await parked.receive(\.pathRequestDeadline)
            #expect(parked.state.propagationTransferState == .pathRequested)
        }
        await clock.advance(by: .seconds(LXMFDelivery.pathRequestWaitSeconds))
        await parked.receive(\.pathRequestDeadline)
        #expect(parked.state.propagationTransferState.rawValue == SyncStateFixtures.byte(pathFixture["state_after_deadline"]))
        #expect(parked.state.propagationTransferState == .noPath)
        #expect(parked.state.pendingDownloadFromPN == false)

        // Establishment ceiling: a path, but every link closes before it is established.
        let linkFixture = SyncStateFixtures.section("establishing_close")
        var linkingState = LXMFRouter.State()
        linkingState.outboundPropagationNode = pn
        linkingState.knownPaths.insert(pn)
        let linking = TestStore(initialState: linkingState) { LXMFRouter() } withDependencies: { $0.continuousClock = TestClock() }
        linking.exhaustivity = .off
        await linking.send(.syncFromPropagationNode)
        #expect(linking.state.propagationTransferState.rawValue == SyncStateFixtures.byte(linkFixture["state_before_close"]))
        for _ in 1..<LXMFDelivery.maxAttempts {
            await linking.send(.linkClosed(destinationHash: pn))
            #expect(linking.state.propagationTransferState == .linkEstablishing)   // retried, not failed
        }
        await linking.send(.linkClosed(destinationHash: pn))
        #expect(linking.state.propagationTransferState.rawValue == SyncStateFixtures.byte(linkFixture["state_after_close"]))
        #expect(linking.state.propagationTransferState == .linkFailed)
        #expect(linking.state.pendingDownloadFromPN == false)
    }

    /// One `propagationTransferStateChanged` per change, from `LXMFNode`: none for an action that
    /// leaves the state and result as they were.
    @Test func stateChangeEmitsOneDelegatePerChange() async {
        let log = LockIsolated<[Seen]>([])
        let store = syncStore(phase: .awaitingList, transfer: .requestSent, log: log)
        await respond(store, MsgPack.encode(.array([])))
        #expect(reported(log) == [.init(state: .complete, lastResult: 0)])

        await store.send(.router(.offeredMessageList(transientIds: [])))     // complete, 0 again
        await store.skipReceivedActions(strict: false)
        await store.send(.router(.learnedPath(destinationHash: Data(repeating: 0x77, count: 16))))
        await store.skipReceivedActions(strict: false)
        #expect(reported(log) == [.init(state: .complete, lastResult: 0)])

        await closeSyncLink(store)
        #expect(reported(log) == [.init(state: .complete, lastResult: 0), .init(state: .idle, lastResult: nil)])
    }

    /// Deliberate departure from `clean_links`: the PN link closing with no sync run (it carried only
    /// propagated sends, or idled out) is not a sync failure. Reference would report `linkFailed`.
    @Test func aCloseWithNoSyncStaysIdle() async {
        let log = LockIsolated<[Seen]>([])
        let store = syncStore(phase: nil, transfer: .idle, log: log)
        await closeSyncLink(store)
        #expect(store.state.router.propagationTransferState == .idle)
        #expect(reported(log).isEmpty)
    }
}
