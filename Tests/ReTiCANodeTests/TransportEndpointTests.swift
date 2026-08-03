import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

@MainActor
private func makeTCP() -> TestStore<TransportEndpoint.State, TransportEndpoint.Action> {
    let store = TestStore(
        initialState: TransportEndpoint.State.tcp(
            TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
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
    let store = TestStore(initialState: TransportEndpoint.State.ble(BLEEndpoint.State())) {
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

@Test @MainActor func startAndStopMapToEachTransportsLifecycle() async {
    let tcp = makeTCP()
    await tcp.send(.start)
    await tcp.receive(.tcp(.connect))
    await tcp.send(.stop)
    await tcp.receive(.tcp(.disconnect))

    let ble = makeBLE()
    await ble.send(.start)
    await ble.receive(.ble(.start))
    await ble.send(.stop)
    await ble.receive(.ble(.stop))
}

@Test @MainActor func sharedVerbsReachTheActiveChildOnBothTransports() async {
    let dest = Data(repeating: 0x11, count: 16)
    let plaintext = Data("hi".utf8)

    let tcp = makeTCP()
    await tcp.send(.send(destinationHash: dest, plaintext: plaintext))
    await tcp.receive(.tcp(.send(destinationHash: dest, plaintext: plaintext)))
    await tcp.send(.requestPath(destinationHash: dest))
    await tcp.receive(.tcp(.requestPath(destinationHash: dest)))
    await tcp.send(.sendOverLink(linkID: dest, data: plaintext))
    await tcp.receive(.tcp(.sendOverLink(linkID: dest, data: plaintext)))

    let ble = makeBLE()
    await ble.send(.send(destinationHash: dest, plaintext: plaintext))
    await ble.receive(.ble(.send(destinationHash: dest, plaintext: plaintext)))
    await ble.send(.requestPath(destinationHash: dest))
    await ble.receive(.ble(.requestPath(destinationHash: dest)))
    await ble.send(.sendOverLink(linkID: dest, data: plaintext))
    await ble.receive(.ble(.sendOverLink(linkID: dest, data: plaintext)))
}

@Test @MainActor func childDelegatesSurfaceAsUnifiedDelegates() async {
    let h = Data(repeating: 0x22, count: 16)

    let tcp = makeTCP()
    await tcp.send(.tcp(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x01])))))
    await tcp.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x01]))))
    await tcp.send(.tcp(.delegate(.pathLearned(destinationHash: h, hops: 2))))
    await tcp.receive(.delegate(.pathLearned(destinationHash: h, hops: 2)))
    await tcp.send(.tcp(.delegate(.linkEstablished(linkID: h, destinationHash: h))))
    await tcp.receive(.delegate(.linkEstablished(linkID: h, destinationHash: h)))

    let ble = makeBLE()
    await ble.send(.ble(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x02])))))
    await ble.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x02]))))
    await ble.send(.ble(.delegate(.resourceConcluded(linkID: h, resourceHash: h))))
    await ble.receive(.delegate(.resourceConcluded(linkID: h, resourceHash: h)))
}

@Test @MainActor func bleOnlyDelegatesDoNotSurfaceOnTheUnifiedSurface() async {
    let ble = makeBLE()
    let token = Data(repeating: 0xC7, count: 16)
    // peerOnline/peerOffline are BLE-specific; they must NOT map to a unified delegate.
    await ble.send(.ble(.delegate(.peerOnline(token))))
    await ble.send(.ble(.delegate(.peerOffline(token))))
    await ble.finish()
}

@Test @MainActor func stateReadsPassThroughToTheActiveCase() async {
    // learned: seed each child's transport table and read it transport-agnostically.
    let dest = Data(repeating: 0x33, count: 16)
    let identity = Identity()
    // Real LearnedDestination init requires appData, ratchet, interfaceID, hops, nextHop,
    // announceEmitted, learnedAt — adjusted from the brief's abbreviated call.
    let learned = LearnedDestination(identity: identity,
                                     appData: Data("meta".utf8),
                                     ratchet: nil,
                                     interfaceID: InterfaceID("tcp"),
                                     hops: 1,
                                     nextHop: dest,
                                     announceEmitted: 0,
                                     learnedAt: Date(timeIntervalSince1970: 0))

    var tcpState = TCPEndpoint.State(host: "h", port: 1, reconnectOnDrop: false)
    tcpState.transport.learned[dest] = learned
    let tcpWrapped = TransportEndpoint.State.tcp(tcpState)
    #expect(tcpWrapped.learned[dest]?.identity.hash == identity.hash)
    #expect(tcpWrapped.learned[dest]?.appData == Data("meta".utf8))
    #expect(tcpWrapped.links.isEmpty)
    #expect(tcpWrapped.registrations.isEmpty)

    var bleState = BLEEndpoint.State()
    bleState.transport.learned[dest] = learned
    let bleWrapped = TransportEndpoint.State.ble(bleState)
    #expect(bleWrapped.learned[dest]?.identity.hash == identity.hash)
    #expect(bleWrapped.links.isEmpty)
    #expect(bleWrapped.registrations.isEmpty)
}
