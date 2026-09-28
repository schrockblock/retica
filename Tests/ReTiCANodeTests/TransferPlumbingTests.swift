import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Transfer-aware delivery, Task 2: the plane names the link for progress and failures, and a cancel
// addressed by link ID reaches the session that owns it.

private let plumbElement = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
private let plumbLink = Data(repeating: 0x4C, count: 16)
private let plumbHash = Data(repeating: 0x07, count: 32)

private func plumbSession() -> LinkSession.State {
    var s = LinkSession.State(id: plumbElement, responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16), interfaceID: InterfaceID("tcp"))
    s.status = .active
    s.linkID = plumbLink
    s.sessionKey = Data(repeating: 0x01, count: 64)
    s.rtt = 1
    return s
}

@MainActor
private func plumbEndpoint() -> TestStore<TransportEndpoint.State, TransportEndpoint.Action> {
    let store = TestStore(initialState: TransportEndpoint.State(
        linkPlane: LinkPlane.State(links: [plumbSession()]),
        tcpClient: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
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

@Test @MainActor func linkPlumbingPlaneReportsSessionProgressUnderTheLinkID() async {
    let store = plumbEndpoint()
    await store.send(.link(.element(id: plumbElement, action: .delegate(.resourceProgress(
        hash: plumbHash, role: .receiver, bytesDone: 5, bytesTotal: 10, segment: 2, segments: 3)))))
    await store.receive(.delegate(.resourceProgress(linkID: plumbLink, resourceHash: plumbHash, role: .receiver,
                                                    bytesDone: 5, bytesTotal: 10, segment: 2, segments: 3)))
}

@Test @MainActor func linkPlumbingPlaneCarriesTheRejectedFlag() async {
    let store = plumbEndpoint()
    await store.send(.link(.element(id: plumbElement, action: .delegate(.resourceFailed(plumbHash, rejected: true)))))
    await store.receive(.delegate(.resourceFailed(linkID: plumbLink, resourceHash: plumbHash, rejected: true)))
}

@Test @MainActor func linkPlumbingEndpointCancelResourceReachesTheSession() async {
    let store = plumbEndpoint()
    await store.send(.cancelResource(linkID: plumbLink, hash: plumbHash))
    await store.receive(.link(.element(id: plumbElement, action: .cancelResource(hash: plumbHash))))
}
