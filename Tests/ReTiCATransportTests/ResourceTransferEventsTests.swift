import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// Transfer-aware delivery, Task 1: `ResourceTransfer` reports progress and says whether a failure
// was the peer refusing the transfer. `TransferEventRecorder` wraps one transfer and records those
// two delegate kinds in its own state, so a test can compare the exact sequence — a
// non-exhaustive `TestStore` can only look for one action at a time, never count them.

private let eventsKey = Data(repeating: 0x01, count: 64)
private let eventsLinkID = Data(repeating: 0xAB, count: 16)

@Reducer
struct TransferEventRecorder {
    @ObservableState
    struct State: Equatable {
        var transfer: ResourceTransfer.State
        var progress: [Progress] = []
        var failures: [Bool] = []
    }
    struct Progress: Equatable { var done: Int; var total: Int; var segment: Int; var segments: Int }
    enum Action: Equatable { case transfer(ResourceTransfer.Action) }
    var body: some ReducerOf<Self> {
        Scope(state: \.transfer, action: \.transfer) { ResourceTransfer() }
        Reduce { state, action in
            switch action {
            case let .transfer(.delegate(.progress(done, total, segment, segments))):
                state.progress.append(Progress(done: done, total: total, segment: segment, segments: segments))
            case let .transfer(.delegate(.failed(rejected))):
                state.failures.append(rejected)
            case .transfer:
                break
            }
            return .none
        }
    }
}

/// SHA-256-derived bytes: bzip2 cannot shrink them, so the part count is predictable.
private func eventsIncompressible(count: Int) -> Data {
    var result = Data()
    var i = 0
    while result.count < count {
        let chunk = Crypto.fullHash(Data([0x5E, UInt8(i & 0xff), UInt8((i >> 8) & 0xff), UInt8((i >> 16) & 0xff)]))
        result.append(contentsOf: chunk.prefix(min(chunk.count, count - result.count)))
        i += 1
    }
    return result
}

private func eventsSender(_ data: Data, sdu: Int = 24, segmentIndex: UInt64 = 1, totalSegments: UInt64 = 1,
                          totalDataSize: UInt64? = nil) -> ResourceTransfer.State {
    ResourceTransfer.State(sending: data, linkID: eventsLinkID, sessionKey: eventsKey, interfaceID: InterfaceID("s"),
                           prefix: Data([0x0A, 0x0B, 0x0C, 0x0D]), randomHash: Data([0x01, 0x02, 0x03, 0x04]),
                           sdu: sdu, segmentIndex: segmentIndex, totalSegments: totalSegments,
                           totalDataSize: totalDataSize)
}

private func eventsReceiver() -> ResourceTransfer.State {
    ResourceTransfer.State(receivingOn: eventsLinkID, sessionKey: eventsKey, interfaceID: InterfaceID("r"))
}

private func eventsPacket(_ context: PacketContext, _ payload: Data) -> Data {
    try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast, destinationType: .link,
                context: context, contextFlag: false, hops: 0, destinationHash: eventsLinkID,
                transportId: nil, payload: payload).packed()
}

/// A RESOURCE_REQ for exactly the parts in `indices`. Each call encrypts afresh (random IV), so two
/// requests for the same parts are two distinct packets and both are served.
private func eventsRequest(_ s: ResourceTransfer.State, _ indices: Range<Int>) -> Data {
    let hashes = s.partMapHashes[indices].reduce(Data()) { $0 + $1 }
    return eventsPacket(.resourceRequest, Link.encrypt(Data([0x00]) + s.resourceHash + hashes, sessionKey: eventsKey))
}

private func eventsAdvertisement(_ s: ResourceTransfer.State) -> Data {
    eventsPacket(.resourceAdvertisement, Link.encrypt(s.advertisement!.pack(), sessionKey: eventsKey))
}

private func eventsCancel(_ context: PacketContext, _ hash: Data) -> Data {
    eventsPacket(context, Link.encrypt(hash, sessionKey: eventsKey))
}

private func eventsBytes(_ s: ResourceTransfer.State, _ indices: Range<Int>) -> Int {
    s.parts[indices].reduce(0) { $0 + $1.count }
}

@MainActor
private func eventsStore(_ transfer: ResourceTransfer.State)
    -> TestStore<TransferEventRecorder.State, TransferEventRecorder.Action> {
    let store = TestStore(initialState: TransferEventRecorder.State(transfer: transfer)) {
        TransferEventRecorder()
    } withDependencies: { $0.continuousClock = TestClock() }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func transferEventsSenderReportsNothingDoneOnAdvertise() async {
    let s = eventsSender(eventsIncompressible(count: 160))
    let total = eventsBytes(s, 0..<s.parts.count)
    #expect(total == Int(s.advertisement!.transferSize))
    let store = eventsStore(s)
    await store.send(.transfer(.advertise))
    // `TestStore.state` only reflects delegate actions dispatched via effects (TCA "received"
    // actions) once they are explicitly consumed — see `TestStore.skipReceivedActions` in
    // ComposableArchitecture's TestStore.swift. Non-exhaustive mode never requires them to be
    // named one at a time (that's the whole point of `TransferEventRecorder`), but the mirror
    // still needs an explicit flush before each read, per TCA's own documented pattern.
    await store.skipReceivedActions(strict: false)
    #expect(store.state.progress == [.init(done: 0, total: total, segment: 1, segments: 1)])
}

@Test @MainActor func transferEventsSenderReportsTheBytesItHasServed() async {
    let s = eventsSender(eventsIncompressible(count: 160))
    #expect(s.parts.count > 4)
    let total = eventsBytes(s, 0..<s.parts.count)
    let store = eventsStore(s)
    await store.send(.transfer(.advertise))
    await store.send(.transfer(.received(eventsRequest(s, 0..<4))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.progress.last == .init(done: eventsBytes(s, 0..<4), total: total, segment: 1, segments: 1))
    await store.send(.transfer(.received(eventsRequest(s, 4..<s.parts.count))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.progress.last == .init(done: total, total: total, segment: 1, segments: 1))
}

/// Spec §3: an event only when the done fraction crosses a new whole percent (or on the final
/// part). One part per request makes the step visible: there are more parts than percent steps.
@Test @MainActor func transferEventsSenderReportsOnlyWholePercentSteps() async {
    let s = eventsSender(eventsIncompressible(count: 1600), sdu: 8)
    let n = s.parts.count
    #expect(n > 150)
    let total = eventsBytes(s, 0..<n)
    // The rule, replayed: 0 on advertise, then an event whenever a new whole percent is reached.
    var expected: [TransferEventRecorder.Progress] = [.init(done: 0, total: total, segment: 1, segments: 1)]
    var last = 0
    for i in 0..<n {
        let done = eventsBytes(s, 0..<(i + 1))
        let percent = Int(Double(done) * 100 / Double(total))
        if percent > last {
            expected.append(.init(done: done, total: total, segment: 1, segments: 1))
            last = percent
        }
    }
    let store = eventsStore(s)
    await store.send(.transfer(.advertise))
    for i in 0..<n { await store.send(.transfer(.received(eventsRequest(s, i..<(i + 1))))) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.progress == expected)
    #expect(store.state.progress.count < n)
    #expect(store.state.progress.last?.done == total)
}

@Test @MainActor func transferEventsReceiverReportsZeroOnAcceptThenEveryPartsBytes() async {
    let sender = eventsSender(eventsIncompressible(count: 160))
    let total = eventsBytes(sender, 0..<sender.parts.count)
    let store = eventsStore(eventsReceiver())
    await store.send(.transfer(.accept(eventsAdvertisement(sender))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.progress == [.init(done: 0, total: total, segment: 1, segments: 1)])
    for chunk in sender.parts { await store.send(.transfer(.received(eventsPacket(.resource, chunk)))) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.transfer.status == .complete)
    let dones = store.state.progress.map(\.done)
    #expect(dones == dones.sorted())
    // Ten-ish parts: every part is more than one percent, so every part reports.
    #expect(store.state.progress.count == sender.parts.count + 1)
    #expect(store.state.progress.last == .init(done: total, total: total, segment: 1, segments: 1))
}

@Test @MainActor func transferEventsReportTheSegmentOfASplitResource() async {
    let segment = eventsSender(eventsIncompressible(count: 160), segmentIndex: 2, totalSegments: 3, totalDataSize: 480)
    let receiver = eventsStore(eventsReceiver())
    await receiver.send(.transfer(.accept(eventsAdvertisement(segment))))
    await receiver.skipReceivedActions(strict: false)
    #expect(receiver.state.progress.first?.segment == 2)
    #expect(receiver.state.progress.first?.segments == 3)
    let sender = eventsStore(segment)
    await sender.send(.transfer(.advertise))
    await sender.skipReceivedActions(strict: false)
    #expect(sender.state.progress.first?.segment == 2)
    #expect(sender.state.progress.first?.segments == 3)
}

@Test @MainActor func transferEventsARejectedAdvertisementIsRejected() async {
    let s = eventsSender(eventsIncompressible(count: 100))
    let store = eventsStore(s)
    await store.send(.transfer(.advertise))
    await store.send(.transfer(.received(eventsCancel(.resourceReceiverCancel, s.resourceHash))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.failures == [true])
}

@Test @MainActor func transferEventsAReceiverCancelMidTransferIsRejected() async {
    let s = eventsSender(eventsIncompressible(count: 160))
    let store = eventsStore(s)
    await store.send(.transfer(.advertise))
    await store.send(.transfer(.received(eventsRequest(s, 0..<2))))
    #expect(store.state.transfer.status == .transferring)
    await store.send(.transfer(.received(eventsCancel(.resourceReceiverCancel, s.resourceHash))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.failures == [true])
    #expect(store.state.transfer.status == .failed)
}

@Test @MainActor func transferEventsASenderTimeoutIsNotRejected() async {
    let store = eventsStore(eventsSender(eventsIncompressible(count: 100)))
    await store.send(.transfer(.advertise))
    for _ in 0...ResourceTransfer.Const.maxAdvRetries { await store.send(.transfer(.senderDeadline)) }
    await store.skipReceivedActions(strict: false)
    #expect(store.state.failures == [false])
}

@Test @MainActor func transferEventsAnInitiatorCancelAtTheReceiverIsNotRejected() async {
    let sender = eventsSender(eventsIncompressible(count: 100))
    let store = eventsStore(eventsReceiver())
    await store.send(.transfer(.accept(eventsAdvertisement(sender))))
    await store.send(.transfer(.received(eventsCancel(.resourceInitiatorCancel, sender.resourceHash))))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.failures == [false])
}
