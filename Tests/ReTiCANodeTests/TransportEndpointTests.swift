import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Task-1b: `TransportEndpoint.State` is now a struct product with a SHARED `transport`/`linkPlane`
// and kind-indexed driver slots (`tcpClient`, `ble`). These tests pin the container-level routing:
// unified verbs reach the shared router / link plane; driver lifecycle verbs reach the driver slot;
// shared-machinery delegates surface unified; BLE-only peer delegates stay OFF the unified surface;
// and the unified accessors read straight off the shared machinery.

@MainActor
private func makeTCP() -> TestStore<TransportEndpoint.State, TransportEndpoint.Action> {
    let store = TestStore(
        initialState: .tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

@MainActor
private func makeBLE() -> TestStore<TransportEndpoint.State, TransportEndpoint.Action> {
    let store = TestStore(initialState: .ble(BLEEndpoint.State())) {
        TransportEndpoint()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.bleDriver = BLEDriver(
            start: { _ in AsyncStream { $0.finish() } },
            readDirectory: { _ in }, openChannel: { _, _ in },
            send: { _, _ in }, closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func startAndStopMapToEachDriversLifecycle() async {
    let tcp = makeTCP()
    await tcp.send(.start)
    await tcp.receive(.tcpClient(.connect))
    await tcp.send(.stop)
    await tcp.receive(.tcpClient(.disconnect))

    let ble = makeBLE()
    await ble.send(.start)
    await ble.receive(.ble(.start))
    await ble.send(.stop)
    await ble.receive(.ble(.stop))
}

@Test @MainActor func sharedVerbsReachTheSharedRouterAndLinkPlaneOnBothConfigs() async {
    let dest = Data(repeating: 0x11, count: 16)
    let plaintext = Data("hi".utf8)

    // The router verbs are forwarded explicitly by the container's Reduce; the link verbs are
    // aliased straight into the shared LinkPlane by `linkPlaneRoute` (consumed by the Scope, so
    // they do NOT re-surface under `.linkPlane(...)`). To observe the link verb reaching the
    // plane, seed a live link and watch for the plane forwarding it to the element.
    let linkID = dest
    func withLink(_ base: TransportEndpoint.State) -> TransportEndpoint.State {
        var s = base
        var link = LinkSession.State(id: UUID(0), responderFor: Identity(),
                                     destinationHash: Data(repeating: 0x02, count: 16),
                                     interfaceID: InterfaceID("tcp"))
        link.status = .active
        link.sessionKey = Data(repeating: 0x01, count: 64)
        link.linkID = linkID
        link.rtt = 1.0
        s.linkPlane.links.append(link)
        return s
    }

    let tcp = makeTCP()
    await tcp.send(.send(destinationHash: dest, plaintext: plaintext))
    await tcp.receive(.transport(.send(destinationHash: dest, plaintext: plaintext)))
    await tcp.send(.requestPath(destinationHash: dest))
    await tcp.receive(.transport(.requestPath(destinationHash: dest)))

    let ble = makeBLE()
    await ble.send(.send(destinationHash: dest, plaintext: plaintext))
    await ble.receive(.transport(.send(destinationHash: dest, plaintext: plaintext)))
    await ble.send(.requestPath(destinationHash: dest))
    await ble.receive(.transport(.requestPath(destinationHash: dest)))

    // Link verb via the alias: reaches the plane, which forwards to the element by linkID.
    let linked = TestStore(initialState: withLink(.tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false)))) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    linked.exhaustivity = .off
    await linked.send(.sendOverLink(linkID: linkID, data: plaintext))
    await linked.receive { if case .link(.element(_, .send)) = $0 { return true }; return false }
}

@Test @MainActor func sharedMachineryDelegatesSurfaceAsUnifiedDelegates() async {
    let h = Data(repeating: 0x22, count: 16)

    let tcp = makeTCP()
    await tcp.send(.transport(.delegate(.received(destinationHash: h, plaintext: Data([0x01])))))
    await tcp.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x01]))))
    await tcp.send(.transport(.delegate(.pathLearned(destinationHash: h, hops: 2))))
    await tcp.receive(.delegate(.pathLearned(destinationHash: h, hops: 2)))
    await tcp.send(.linkPlane(.delegate(.linkEstablished(linkID: h, destinationHash: h))))
    await tcp.receive(.delegate(.linkEstablished(linkID: h, destinationHash: h)))

    let ble = makeBLE()
    await ble.send(.transport(.delegate(.received(destinationHash: h, plaintext: Data([0x02])))))
    await ble.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x02]))))
    await ble.send(.linkPlane(.delegate(.resourceConcluded(linkID: h, resourceHash: h))))
    await ble.receive(.delegate(.resourceConcluded(linkID: h, resourceHash: h)))
}

@Test @MainActor func bleOnlyDelegatesDoNotSurfaceOnTheUnifiedSurface() async {
    let ble = makeBLE()  // .off
    let token = Data(repeating: 0xC7, count: 16)
    // Record every UNIFIED top-level `.delegate(...)` the store surfaces across a full BLE peer
    // online→offline cycle. peerOnline/peerOffline are BLE-specific and must map to NO unified
    // delegate — they surface only under `.ble(.delegate)`. The scan records any unified
    // `.delegate` it is OFFERED (the predicate runs per action even when it returns false) and its
    // sentinel is the BLE-only `.peerOffline` re-emission, which comes LAST — so any unified
    // delegate emitted by the peer transitions before it would be recorded too. (The 1a
    // characterization test pins the same property with a positive `pathLearned` sentinel.)
    let unifiedDelegates = LockIsolated<[String]>([])
    await ble.send(.ble(.ble(.delegate(.peerOnline(token)))))
    await ble.send(.ble(.ble(.delegate(.peerOffline(token)))))
    await ble.receive { action in
        if case .delegate = action { unifiedDelegates.withValue { $0.append("delegate") } }
        if case .ble(.delegate(.peerOffline)) = action { return true }
        return false
    }
    await ble.skipReceivedActions(strict: false)
    #expect(unifiedDelegates.value.isEmpty,
            "BLE peer lifecycle must add NO unified delegate; saw \(unifiedDelegates.value)")
}

@Test @MainActor func stateReadsPassThroughToTheSharedMachinery() async {
    // learned: seed the shared router table and read it transport-agnostically.
    let dest = Data(repeating: 0x33, count: 16)
    let identity = Identity()
    let learned = LearnedDestination(identity: identity,
                                     appData: Data("meta".utf8),
                                     ratchet: nil,
                                     interfaceID: InterfaceID("tcp"),
                                     hops: 1,
                                     nextHop: dest,
                                     announceEmitted: 0,
                                     learnedAt: Date(timeIntervalSince1970: 0))

    var tcpState = TransportEndpoint.State.tcp(TCPEndpoint.State(host: "h", port: 1, reconnectOnDrop: false))
    tcpState.transport.learned[dest] = learned
    #expect(tcpState.learned[dest]?.identity.hash == identity.hash)
    #expect(tcpState.learned[dest]?.appData == Data("meta".utf8))
    #expect(tcpState.links.isEmpty)
    #expect(tcpState.registrations.isEmpty)

    var bleState = TransportEndpoint.State.ble(BLEEndpoint.State())
    bleState.transport.learned[dest] = learned
    #expect(bleState.learned[dest]?.identity.hash == identity.hash)
    #expect(bleState.links.isEmpty)
    #expect(bleState.registrations.isEmpty)
}

// The unified surface exposes `learned`, `links`, `registrations` AND `interfaces`, read directly
// off the shared router / link plane — no switch on transport kind.
@Test @MainActor func interfacesAreExposedOnTheUnifiedSurfaceForBothConfigs() {
    var tcp = TransportEndpoint.State.tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    tcp.transport.interfaces[InterfaceID("tcp")] = .tcp
    #expect(tcp.interfaces == [InterfaceID("tcp"): .tcp])

    var ble = TransportEndpoint.State.ble(BLEEndpoint.State())
    ble.transport.interfaces[InterfaceID("ble-1")] = .ble
    #expect(ble.interfaces == [InterfaceID("ble-1"): .ble])
}

// `PendingDelivery` gained an explicit `public init` because the synthesised memberwise init
// on a `public struct` is INTERNAL — the type was public in name only. This test asserts the
// init ASSIGNS ITS PARAMETERS; it deliberately does NOT claim to prove accessibility.
//
// This file carries `@testable import ReTiCANode`, which makes internal members visible, so
// the module boundary is erased here: the body below would compile and pass even if the
// `public init` were deleted and the internal memberwise init used instead. A test named for
// cross-module construction would therefore be a false coverage claim. The genuine boundary
// proof is a construction from a target that imports ReTiCANode WITHOUT `@testable` — no such
// target exists in this package, so it lands in the app's test target instead.
@Test func pendingDeliveryInitAssignsItsParameters() {
    let resend = LXMFRouter.ResendInfo.opportunistic(
        destinationHash: Data(repeating: 0x01, count: 16), payload: Data())
    let pending = LXMFRouter.PendingDelivery(resend: resend, attempts: 3)
    #expect(pending.attempts == 3)
    #expect(pending.resend == resend)
}

@Test @MainActor func openingAnInitiatorLinkRegistersItsLinkIDWithTransport() async {
    let store = makeTCP()
    await store.send(.linkPlane(.openLink(initiatorTo: Identity(),
                                          destinationHash: Data(repeating: 0x02, count: 16),
                                          interfaceID: InterfaceID("tcp"), relayNextHop: nil)))
    await store.skipReceivedActions(strict: false)
    let linkID = store.state.linkPlane.links[0].linkID
    #expect(!linkID.isEmpty)
    #expect(store.state.transport.localLinkIDs.contains(linkID),
            "opening an initiator link must register its linkID with Transport")
    await store.finish()
}

@Test @MainActor func acceptingAResponderLinkRegistersItsLinkIDWithTransport() async {
    let store = makeTCP()
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    await store.send(.linkPlane(.acceptLinkRequest(owner: owner, destinationHash: dest.hash,
                                                   interfaceID: InterfaceID("tcp"), data: try! request.packed())))
    await store.skipReceivedActions(strict: false)
    let linkID = store.state.linkPlane.links[0].linkID
    #expect(!linkID.isEmpty)
    #expect(store.state.transport.localLinkIDs.contains(linkID),
            "accepting a responder link must register its linkID with Transport")
    await store.finish()
}

@Test @MainActor func aFailedInitiatorLinkUnregistersItsLinkID() async {
    // Drive an initiator link to establishment timeout; LinkPlane removes the element and must
    // unregister its linkID from Transport.
    let clock = TestClock()
    let store = TestStore(
        initialState: TransportEndpoint.State.tcp(
            TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) { TransportEndpoint() } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.linkPlane(.openLink(initiatorTo: Identity(),
                                          destinationHash: Data(repeating: 0x02, count: 16),
                                          interfaceID: InterfaceID("tcp"), relayNextHop: nil)))
    await store.skipReceivedActions(strict: false)
    let linkID = store.state.linkPlane.links[0].linkID
    #expect(store.state.transport.localLinkIDs.contains(linkID))
    // Establishment timeout is 15s; advance past it.
    await clock.advance(by: .seconds(16))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkPlane.links.isEmpty, "the link element is removed on timeout")
    #expect(!store.state.transport.localLinkIDs.contains(linkID),
            "a removed link must be unregistered from Transport")
    await store.finish()
}
