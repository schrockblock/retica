import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

@MainActor
private func makeEndpoint() -> TestStore<TransportEndpoint.State, TransportEndpoint.Action> {
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

@Test @MainActor func inboundProvingEndpointForwardsProveSinglePacketToTransport() async {
    let store = makeEndpoint()
    let packetHash = Data(repeating: 0x44, count: 32)
    let prover = Identity()
    await store.send(.proveSinglePacket(packetHash: packetHash, interfaceID: InterfaceID("tcp"),
                                        identity: prover))
    await store.receive(.transport(.proveSingle(packetHash: packetHash, interfaceID: InterfaceID("tcp"),
                                                identity: prover)))
}

@Test @MainActor func inboundProvingEndpointSurfacesPacketHashAndInterface() async {
    let store = makeEndpoint()
    let dest = Data(repeating: 0x22, count: 16)
    let packetHash = Data(repeating: 0x55, count: 32)
    await store.send(.transport(.delegate(.received(destinationHash: dest, plaintext: Data([7]),
                                                    packetHash: packetHash, interfaceID: InterfaceID("x")))))
    await store.receive(.delegate(.messageReceived(destinationHash: dest, plaintext: Data([7]),
                                                   packetHash: packetHash, interfaceID: InterfaceID("x"))))
}

@Test @MainActor func receiptTableEndpointPassesTheTokenToTransport() async {
    let store = makeEndpoint()
    let dest = Data(repeating: 0x11, count: 16)
    let plaintext = Data("hi".utf8)
    let token = Data([0xAB])
    await store.send(.send(destinationHash: dest, plaintext: plaintext, receiptToken: token))
    await store.receive(.transport(.send(destinationHash: dest, plaintext: plaintext, receiptToken: token)))
}

@Test @MainActor func proofValidationEndpointForwardsSinglePacketDelivered() async {
    let store = makeEndpoint()
    let token = Data([0xCD])
    await store.send(.transport(.delegate(.singlePacketDelivered(token: token))))
    await store.receive(.delegate(.singlePacketDelivered(token: token)))
}
