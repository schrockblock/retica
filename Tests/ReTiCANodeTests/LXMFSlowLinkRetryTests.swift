import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let stretched = 80        // LXMFDelivery.retryWait(nextHopBitrate: 202)
private let linkID = Data(repeating: 0x5C, count: 16)

private func message(_ content: Data = Data("small".utf8)) -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: content)
}
private let bigContent = Data((0..<800).map { UInt8($0 & 0xff) })   // > Link.mdu → sent as a Resource

@MainActor
private func makeRouter(_ initial: LXMFRouter.State, _ clock: TestClock<Duration>) -> TestStoreOf<LXMFRouter> {
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@MainActor
private func advance(_ store: TestStoreOf<LXMFRouter>, _ clock: TestClock<Duration>, _ seconds: Int) async {
    await clock.advance(by: .seconds(seconds))
    await store.skipReceivedActions(strict: false)
}

@Suite @MainActor struct LXMFSlowLinkRetryTests {
    // --- the formula: max(10, ⌈4 · 500·8 / b⌉) ---

    @Test func fastLinksKeepTheTenSecondRetry() {
        #expect(LXMFDelivery.retryWait(nextHopBitrate: InterfaceProfile.tcp.bitrate) == 10)
        #expect(LXMFDelivery.retryWait(nextHopBitrate: InterfaceProfile.ble.bitrate) == 10)
        #expect(LXMFDelivery.retryWait(nextHopBitrate: InterfaceProfile.default.bitrate) == 10)
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 1600) == 10)            // exactly 10.0
    }

    @Test func slowLinksStretchTheRetryToFourPacketAirtimesRoundedUp() {
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 202) == 80)             // 79.2
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 538) == 30)             // 29.7
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 107) == 150)            // 149.5
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 1599) == 11)            // 10.006
    }

    @Test func anUnknownBitrateKeepsTheTenSecondRetry() {
        #expect(LXMFDelivery.retryWait(nextHopBitrate: nil) == 10)
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 0) == 10)
        #expect(LXMFDelivery.retryWait(nextHopBitrate: -5) == 10)
    }

    // --- every retry-arming arm reads the destination's wait ---

    @Test func opportunisticSendAndResendBothWaitTheStretchedWait() async {
        let msg = message(); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.knownPaths.insert(msg.destinationHash)
        initial.nextHopRetryWaits[msg.destinationHash] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .opportunistic))
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)   // `.send` arm
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 2)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 3)   // `.retryDue` resend
    }

    @Test func aDirectLinkPacketAndItsResendBothWaitTheStretchedWait() async {
        let msg = message(); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.directLinks[msg.destinationHash] = .active(linkID: linkID)
        initial.nextHopRetryWaits[msg.destinationHash] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .direct))
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)   // `.send` direct arm
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 2)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 3)   // `.retryDue` direct resend
    }

    @Test func aPacketDrainedOnLinkEstablishedWaitsTheStretchedWait() async {
        let msg = message(); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.knownPaths.insert(msg.destinationHash)
        initial.nextHopRetryWaits[msg.destinationHash] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .direct))                 // queued; requestLink
        await store.send(.linkEstablished(destinationHash: msg.destinationHash, linkID: linkID))   // drain
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)
    }

    @Test func aFailedResourceAndItsLinkDownRecheckBothWaitTheStretchedWait() async {
        let msg = message(bigContent); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.directLinks[msg.destinationHash] = .active(linkID: linkID)
        initial.nextHopRetryWaits[msg.destinationHash] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .direct))                 // Resource in flight
        #expect(store.state.pendingDeliveries[key]?.phase == .transferring)
        await store.send(.resourceFailedOnLink(linkID: linkID, rejected: false))      // link torn down
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)   // failure arm
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 2)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 3)   // link-down re-check
    }

    @Test func aResourceOrphanedByALostLinkWaitsTheStretchedWait() async {
        let msg = message(bigContent); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.knownPaths.insert(msg.destinationHash)
        initial.directLinks[msg.destinationHash] = .active(linkID: linkID)
        initial.nextHopRetryWaits[msg.destinationHash] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .direct))
        await store.send(.linkClosed(destinationHash: msg.destinationHash))          // orphanTransfer
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)
    }

    @Test func aPropagatedPacketWaitsTheStretchedWaitWithAndWithoutItsLink() async {
        let msg = message()
        let clock = TestClock()
        let pn = Data(repeating: 0x9A, count: 16)
        var initial = LXMFRouter.State()
        initial.outboundPropagationNode = pn
        initial.directLinks[pn] = .active(linkID: linkID)
        initial.nextHopRetryWaits[pn] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.propagated(msg.hash)
        await store.send(.sendViaPropagation(message: msg, propagationPacked: Data(repeating: 0xAB, count: 100)))
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)   // `.sendViaPropagation` arm
        await store.send(.linkClosed(destinationHash: pn))                           // the PN link drops
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 2)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 3)   // resend (armed with link up)
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 3)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 4)   // link-down re-check
    }

    @Test func aDestinationWithNoEntryKeepsTenSeconds() async {
        let msg = message(); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.knownPaths.insert(msg.destinationHash)
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .opportunistic))
        await advance(store, clock, 9); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1); #expect(store.state.pendingDeliveries[key]?.attempts == 2)
    }
}
