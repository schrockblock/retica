import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// Transfer-aware delivery, Task 2: `LinkSession` reports transfer progress, carries the rejection
// flag, and cancels one of our outbound Resources by hash. `SessionEventRecorder` keeps every
// progress, failure and transmit delegate in state so a test can compare the exact sequence.

private let plumbKey = Data(repeating: 0x01, count: 64)
private let plumbLinkID = Data(repeating: 0xAB, count: 16)

@Reducer
struct SessionEventRecorder {
    @ObservableState
    struct State: Equatable {
        var session: LinkSession.State
        var progress: [LinkSession.Action.Delegate] = []
        var failures: [LinkSession.Action.Delegate] = []
        var transmits: [Data] = []
    }
    enum Action: Equatable { case session(LinkSession.Action) }
    var body: some ReducerOf<Self> {
        Scope(state: \.session, action: \.session) { LinkSession() }
        Reduce { state, action in
            guard case let .session(.delegate(event)) = action else { return .none }
            switch event {
            case .resourceProgress: state.progress.append(event)
            case .resourceFailed: state.failures.append(event)
            case let .transmit(_, raw): state.transmits.append(raw)
            default: break
            }
            return .none
        }
    }
}

private func plumbActiveSession() -> LinkSession.State {
    var s = LinkSession.State(responderFor: Identity(), destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = plumbKey
    s.linkID = plumbLinkID
    s.rtt = 1.0
    return s
}

@MainActor
private func plumbStore(_ session: LinkSession.State = plumbActiveSession())
    -> TestStore<SessionEventRecorder.State, SessionEventRecorder.Action> {
    let store = TestStore(initialState: SessionEventRecorder.State(session: session)) {
        SessionEventRecorder()
    } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// SHA-256-derived bytes: bzip2 cannot shrink them, so a payload above `maxEfficientSize` splits.
private func plumbIncompressible(count: Int) -> Data {
    var result = Data()
    var i = 0
    while result.count < count {
        let chunk = Crypto.fullHash(Data([0x71, UInt8(i & 0xff), UInt8((i >> 8) & 0xff), UInt8((i >> 16) & 0xff)]))
        result.append(contentsOf: chunk.prefix(min(chunk.count, count - result.count)))
        i += 1
    }
    return result
}

private func plumbTotal(_ t: ResourceTransfer.State) -> Int { t.parts.reduce(0) { $0 + $1.count } }

@Test @MainActor func linkPlumbingSenderProgressCarriesTheResourceHash() async {
    let store = plumbStore()
    await store.send(.session(.sendResource(Data("a resource sent out over the link".utf8))))
    let t = store.state.session.transfers[0]
    // `.sendResource` only APPENDS the transfer synchronously; the ADV (and its progress delegate)
    // fire from the `.advertise` effect it schedules, so read `progress` only after draining.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.progress == [.resourceProgress(hash: t.resourceHash, role: .sender, bytesDone: 0,
                                                       bytesTotal: plumbTotal(t), segment: 1, segments: 1)])
}

/// A split send reports every segment under the ORIGINAL hash — the one `resourceConcluded` and
/// `resourceFailed` carry for it — so the node can tell it is still the same transfer.
@Test @MainActor func linkPlumbingSegmentedSendReportsTheOriginalHash() async {
    let store = plumbStore()
    await store.send(.session(.sendResource(plumbIncompressible(count: LinkSession.maxEfficientSize + 100))))
    let oh = store.state.session.segmentedSend!.originalHash
    let first = store.state.session.transfers[0]
    await store.send(.session(.transfer(.element(id: first.id, action: .delegate(.concluded)))))
    let second = store.state.session.transfers.first { $0.advertisement?.segmentIndex == 2 }!
    #expect(second.resourceHash != oh)
    // Segment 2's own ADV/progress fire from the `.advertise` effect `.concluded` schedules.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.progress.last == .resourceProgress(hash: oh, role: .sender, bytesDone: 0,
                                                           bytesTotal: plumbTotal(second), segment: 2, segments: 2))
}

@Test @MainActor func linkPlumbingInboundProgressIsReceiverRole() async {
    let sender = ResourceTransfer.State(sending: Data(repeating: 0x33, count: 100), linkID: plumbLinkID,
                                        sessionKey: plumbKey, interfaceID: InterfaceID("i"),
                                        prefix: Data([0, 1, 2, 3]), randomHash: Data([4, 5, 6, 7]), sdu: 24)
    let adv = try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                          destinationType: .link, context: .resourceAdvertisement, contextFlag: false, hops: 0,
                          destinationHash: plumbLinkID, transportId: nil,
                          payload: Link.encrypt(sender.advertisement!.pack(), sessionKey: plumbKey)).packed()
    let store = plumbStore()
    await store.send(.session(.received(adv)))
    // The receiver's own progress delegate fires from the `.accept` effect `.received` schedules.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.progress == [.resourceProgress(hash: sender.resourceHash, role: .receiver, bytesDone: 0,
                                                       bytesTotal: Int(sender.advertisement!.transferSize),
                                                       segment: 1, segments: 1)])
}

/// Request and response Resources are the link's own plumbing, not messages: no progress for them.
@Test @MainActor func linkPlumbingRequestResourcesReportNoProgress() async {
    let store = plumbStore()
    await store.send(.session(.sendRequest(path: "/big", data: MsgPack.encode(.bin(Data(repeating: 0x41, count: 1000))))))
    #expect(store.state.session.transfers.first?.advertisement?.isRequest == true)   // a Resource did start
    // Drain the `.advertise` effect's cascade before trusting the ABSENCE of a progress event —
    // otherwise this assertion would hold vacuously whether or not the guard exists.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.progress.isEmpty)
}

@Test @MainActor func linkPlumbingRejectedFailureCarriesTheFlag() async {
    var session = plumbActiveSession()
    let t = ResourceTransfer.State(sending: Data("plain resource payload".utf8), linkID: plumbLinkID,
                                   sessionKey: plumbKey, interfaceID: InterfaceID("i"),
                                   prefix: Data([0, 1, 2, 3]), randomHash: Data([4, 5, 6, 7]), sdu: 24)
    session.transfers.append(t)
    let store = plumbStore(session)
    await store.send(.session(.transfer(.element(id: t.id, action: .delegate(.failed(rejected: true))))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.failures == [.resourceFailed(t.resourceHash, rejected: true)])
}

@Test @MainActor func linkPlumbingCancelResourceSendsTheCancelPacketAndNoFailure() async {
    let store = plumbStore()
    await store.send(.session(.sendResource(Data("cancel me".utf8))))
    let hash = store.state.session.transfers[0].resourceHash
    await store.send(.session(.cancelResource(hash: hash)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.transmits.count == 2)                                  // ADV, then ICL
    let icl = Packet(raw: store.state.transmits[1])!
    #expect(icl.context == .resourceInitiatorCancel)
    #expect(Link.decrypt(icl.payload, sessionKey: plumbKey) == hash)
    #expect(store.state.session.transfers.isEmpty)
    #expect(store.state.failures.isEmpty)                                      // the owner asked: not news
}

@Test @MainActor func linkPlumbingCancelResourceOnASegmentedSendDropsTheRemainingSegments() async {
    let store = plumbStore()
    await store.send(.session(.sendResource(plumbIncompressible(count: LinkSession.maxEfficientSize + 100))))
    let oh = store.state.session.segmentedSend!.originalHash
    await store.send(.session(.cancelResource(hash: oh)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.session.segmentedSend == nil)
    #expect(store.state.session.transfers.isEmpty)
    #expect(store.state.transmits.count == 2)                                  // segment 1's ADV, then its ICL
    #expect(Packet(raw: store.state.transmits[1])?.context == .resourceInitiatorCancel)
    #expect(store.state.failures.isEmpty)
}

/// A split send whose segment in flight is already gone: clearing the rest needs no packet.
@Test @MainActor func linkPlumbingCancelResourceWithNoSegmentInFlightClearsWithoutAPacket() async {
    var session = plumbActiveSession()
    let oh = Data(repeating: 0x5A, count: 32)
    session.segmentedSend = LinkSession.State.SegmentedSend(remaining: [Data([0x01])], nextIndex: 2, total: 2,
                                                            originalHash: oh, totalDataSize: 10,
                                                            currentTransferID: UUID())
    let store = plumbStore(session)
    await store.send(.session(.cancelResource(hash: oh)))
    #expect(store.state.session.segmentedSend == nil)
    await store.skipReceivedActions(strict: false)                             // a transmit would land here
    #expect(store.state.transmits.isEmpty)
}

@Test @MainActor func linkPlumbingCancelResourceForAnUnknownHashDoesNothing() async {
    let store = plumbStore()
    await store.send(.session(.sendResource(Data("keep me".utf8))))
    await store.send(.session(.cancelResource(hash: Data(repeating: 0xEE, count: 32))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.transmits.count == 1)                                  // the ADV only
    #expect(store.state.session.transfers.count == 1)
}
