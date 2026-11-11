import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport
@testable import ReTiCAInterfaces

// A propagation node's upload signal: `[ERROR_INVALID_STAMP]` sent back as a link packet on our
// outbound propagation link rejects the propagated copy (reference
// `LXMRouter.propagation_transfer_signalling_packet`, LXMRouter.py:3035-3048), and is never taken
// for an incoming message. Cross-validated by `Vectors/generate_lxmf_pn_upload_signal_fixtures.py`
// (lxmf_pn_upload_signal_fixtures.json).

/// The generator's output, as the tests read it.
enum UploadSignalFixtures {
    struct Case: Sendable, CustomTestStringConvertible {
        var name: String
        var data: Data
        var rejected: Bool
        var testDescription: String { name }
    }

    nonisolated(unsafe) static let json: [String: Any] = {
        let url = Bundle.module.url(forResource: "lxmf_pn_upload_signal_fixtures", withExtension: "json")!
        return try! JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
    }()

    static let cases: [Case] = (json["cases"] as! [[String: Any]]).map { c in
        Case(name: c["name"] as! String, data: Data(hexString: c["data"] as! String)!, rejected: c["rejected"] as! Bool)
    }
    /// What a reference PN sends for an upload with an invalid stamp (LXMRouter.py:2593).
    static let pnRejectData = Data(hexString: json["pn_reject_data"] as! String)!
}

private let pn = Data(repeating: 0x5E, count: 16)
private let pnLink = Data(repeating: 0xA1, count: 16)
private let inboundLink = Data(repeating: 0x7A, count: 16)
private let ours = Data(repeating: 0x0D, count: 16)
private let packetHash = Data(repeating: 0x33, count: 32)
private let smallContainer = Data(repeating: 0xAA, count: 100)     // fits a link packet
private let largeContainer = Data(repeating: 0xAB, count: 1000)    // goes as a Resource

/// What these tests look for among the actions `LXMFNode` sees.
private enum Seen: Equatable, Sendable {
    case received(Data)
    case packet(token: Data)
    case rejected(Data)
    case failed(Data)
    case openLink(Data)
    case retryDue(Data)
}

private struct Recorded: Reducer {
    typealias State = LXMFNode.State
    typealias Action = LXMFNode.Action
    let log: LockIsolated<[Seen]>
    var body: some ReducerOf<Self> {
        Reduce { _, action in
            let seen: Seen?
            switch action {
            case let .router(.received(_, _, data)): seen = .received(data)
            case let .endpoint(.sendWithReceiptOverLink(_, _, token)): seen = .packet(token: token)
            case let .delegate(.deliveryRejected(hash)): seen = .rejected(hash)
            case let .delegate(.deliveryFailed(hash)): seen = .failed(hash)
            case let .endpoint(.openLink(dest)): seen = .openLink(dest)
            case let .router(.retryDue(hash, _)): seen = .retryDue(hash)
            default: seen = nil
            }
            if let seen { log.withValue { $0.append(seen) } }
            return .none
        }
        LXMFNode()
    }
}

/// A node with an active link to its propagation node, `pnLink`, and `ours` as its delivery destination.
@MainActor
private func pnStore(log: LockIsolated<[Seen]>, clock: TestClock<Duration> = TestClock()) -> TestStoreOf<Recorded> {
    var state = LXMFNode.State(identity: Identity(),
                               endpoint: tcpDriverEndpoint(host: "h", port: 4242, reconnectOnDrop: false))
    state.deliveryDestinationHash = ours
    state.router.outboundPropagationNode = pn
    state.router.knownPaths.insert(pn)
    state.router.directLinks[pn] = .active(linkID: pnLink)
    state.directLinks[pn] = pnLink
    state.linkDestinations[pnLink] = pn
    state.linkDestinations[inboundLink] = ours        // a peer linked to OUR delivery destination
    let store = TestStore(initialState: state) { Recorded(log: log) } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

private func message(_ fill: String, to dest: Data = Data(repeating: 0xD5, count: 16)) -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data(fill.utf8))
}

@MainActor
private func propagate(_ store: TestStoreOf<Recorded>, _ m: LXMessage, _ container: Data = smallContainer) async {
    await store.send(.router(.sendViaPropagation(message: m, propagationPacked: container)))
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func signal(_ store: TestStoreOf<Recorded>, _ data: Data, on linkID: Data = pnLink) async {
    await store.send(.endpoint(.delegate(.linkDataReceived(linkID: linkID, data: data, packetHash: packetHash))))
    await store.skipReceivedActions(strict: false)
}

private func packets(_ log: LockIsolated<[Seen]>, _ hash: Data) -> Int {
    log.value.filter { $0 == .packet(token: hash) }.count
}

@Suite @MainActor struct LXMFPropagationUploadRejectTests {
    /// The PN rejects the upload: the copy whose packet is the oldest still awaiting its receipt ends
    /// REJECTED (`deliveryRejected`), with no retry timer left, and the PN's teardown that follows
    /// does not bring it back. A second copy on the same link is untouched and keeps retrying.
    @Test func invalidStampSignalRejectsTheOutstandingPropagatedCopy() async {
        let log = LockIsolated<[Seen]>([])
        let clock = TestClock()
        let store = pnStore(log: log, clock: clock)
        let first = message("first"), second = message("second")
        await propagate(store, first)
        await propagate(store, second)
        #expect(packets(log, first.hash) == 1 && packets(log, second.hash) == 1)

        await signal(store, UploadSignalFixtures.pnRejectData)
        #expect(log.value.contains(.rejected(first.hash)))
        #expect(!log.value.contains(.rejected(second.hash)))
        #expect(store.state.router.pendingDeliveries[.propagated(first.hash)] == nil)
        #expect(store.state.router.pendingDeliveries[.propagated(second.hash)] != nil)

        // No retry timer for the rejected copy: a full retry wait resends only the other one.
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
        await store.skipReceivedActions(strict: false)
        #expect(packets(log, first.hash) == 1)
        #expect(!log.value.contains(.retryDue(first.hash)))
        #expect(packets(log, second.hash) == 2)

        // Reference's PN tears the link down after the signal (LXMRouter.py:2595).
        await store.send(.endpoint(.delegate(.linkClosed(linkID: pnLink, reason: .destinationClosed))))
        await store.skipReceivedActions(strict: false)
        for _ in 0..<(LXMFDelivery.maxAttempts + 1) {
            await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
            await store.skipReceivedActions(strict: false)
        }
        #expect(packets(log, first.hash) == 1)
        #expect(log.value.filter { $0 == .rejected(first.hash) }.count == 1)
        #expect(!log.value.contains(.retryDue(first.hash)))
        #expect(!log.value.contains(.failed(first.hash)))
    }

    /// Every signal the reference generator drove: only the ones reference cancels as REJECTED reject
    /// (`[0xF5]`, with more elements or trailing bytes, or 0xF5 as a float), and none is delivered.
    @Test(arguments: UploadSignalFixtures.cases)
    func signalRejectsExactlyWhereReferenceDoes(_ c: UploadSignalFixtures.Case) async {
        let log = LockIsolated<[Seen]>([])
        let store = pnStore(log: log)
        let m = message("one")
        await propagate(store, m)
        await signal(store, c.data)
        #expect(log.value.contains(.rejected(m.hash)) == c.rejected)
        #expect((store.state.router.pendingDeliveries[.propagated(m.hash)] == nil) == c.rejected)
        #expect(!log.value.contains(.received(c.data)))
    }

    /// Nothing that arrives as a link packet on the outbound PN link is a message for us, not even a
    /// well-formed one addressed to our delivery destination. The same bytes on a delivery link are.
    @Test func signalOnOutboundPNLinkIsNeverDeliveredAsAMessage() async {
        let log = LockIsolated<[Seen]>([])
        let store = pnStore(log: log)
        let forUs = message("hello", to: ours).packed
        await signal(store, UploadSignalFixtures.pnRejectData)
        await signal(store, forUs)
        #expect(!log.value.contains { if case .received = $0 { return true }; return false })

        await signal(store, forUs, on: inboundLink)      // control: a delivery link does deliver
        #expect(log.value.contains(.received(forUs)))
    }

    /// No packet copy awaiting its receipt on the link: nothing is rejected. A copy that went as a
    /// Resource has its own rejection path; a packet copy whose receipt arrived is settled.
    @Test func invalidStampSignalWithNoOutstandingPacketRejectsNothing() async {
        let log = LockIsolated<[Seen]>([])
        let store = pnStore(log: log)
        let big = message("big")
        await propagate(store, big, largeContainer)
        #expect(store.state.router.pendingDeliveries[.propagated(big.hash)]?.phase == .transferring)
        await signal(store, UploadSignalFixtures.pnRejectData)
        #expect(!log.value.contains { if case .rejected = $0 { return true }; return false })
        #expect(store.state.router.pendingDeliveries[.propagated(big.hash)]?.phase == .transferring)

        let small = message("small")
        await propagate(store, small)
        #expect(packets(log, small.hash) == 1)
        await store.send(.endpoint(.delegate(.packetDelivered(token: small.hash))))
        await store.skipReceivedActions(strict: false)
        await signal(store, UploadSignalFixtures.pnRejectData)
        #expect(!log.value.contains { if case .rejected = $0 { return true }; return false })
        #expect(store.state.router.pendingDeliveries[.propagated(big.hash)]?.phase == .transferring)
    }
}
