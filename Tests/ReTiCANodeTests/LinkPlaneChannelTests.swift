import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCATransport
@testable import ReTiCA

// Channel actions reach the link they name, and its delegates come back carrying that link's id,
// through `LinkPlane` and on through `TransportEndpoint` (the route `sendWithReceiptOverLink` /
// `packetDelivered` take).

private func activeResponder(linkID: Data, interface: InterfaceID, peer: Identity) -> LinkSession.State {
    var s = LinkSession.State(responderFor: Identity(), destinationHash: Data(repeating: 0x31, count: 16),
                              interfaceID: interface)
    s.status = .active
    s.linkID = linkID
    s.sessionKey = Data(repeating: linkID[0], count: 64)
    s.rtt = 0.125
    // What `acceptRequest` loads from the link request: the initiator's keys.
    s.peerX25519Pub = Data(peer.publicKey.prefix(32))
    s.peerSigningPub = Data(peer.publicKey.suffix(32))
    return s
}

private func linkPacket(_ s: LinkSession.State, _ type: PacketType, _ context: PacketContext, _ payload: Data) -> Data {
    try! Packet(headerType: .header1, packetType: type, transportType: .broadcast,
                destinationType: .link, context: context, contextFlag: false, hops: 0,
                destinationHash: s.linkID, transportId: nil, payload: payload).packed()
}

@Test @MainActor func channelActionsAndDelegatesRouteByLinkID() async throws {
    let peer = Identity()
    let a = activeResponder(linkID: Data(repeating: 0xA1, count: 16), interface: InterfaceID("a"), peer: peer)
    let b = activeResponder(linkID: Data(repeating: 0xB2, count: 16), interface: InterfaceID("b"), peer: peer)
    let store = TestStore(initialState: TransportEndpoint.State(linkPlane: LinkPlane.State(links: [a, b]))) {
        TransportEndpoint()
    } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let type = ChannelMessageType(0x0042)!
    let token = Data(repeating: 0x70, count: 16)

    await store.send(.openChannelOverLink(linkID: b.linkID))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.links[id: b.id]?.channel != nil)
    #expect(store.state.links[id: a.id]?.channel == nil)

    await store.send(.registerChannelMessageTypeOverLink(linkID: b.linkID, type: type))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.links[id: b.id]?.channel?.registered == [type.rawValue])

    // A send on the link without a channel is rejected under ITS id.
    await store.send(.sendChannelMessageOverLink(linkID: a.linkID, type: type, payload: Data("x".utf8), token: token))
    await store.receive(.delegate(.channelSendRejected(linkID: a.linkID, token: token, reason: .noChannel)))

    await store.send(.sendChannelMessageOverLink(linkID: b.linkID, type: type, payload: Data("out".utf8), token: token))
    await store.receive(.delegate(.channelMessageSent(linkID: b.linkID, token: token, sequence: 0)))
    let sentHash = try #require(store.state.links[id: b.id]?.channel?.tx.first?.packetHash)

    // Inbound on b: delivered with b's id.
    let inbound = linkPacket(b, .data, .channel,
                             Link.encrypt(ChannelEnvelope(msgType: type.rawValue, sequence: 0, payload: Data("in".utf8)).packed(),
                                          sessionKey: b.sessionKey))
    await store.send(.linkPlane(.routeLinkPacket(linkID: b.linkID, arrivalInterface: InterfaceID("b"), data: inbound)))
    await store.receive(.delegate(.channelMessageReceived(linkID: b.linkID, msgType: type.rawValue, payload: Data("in".utf8))))

    // The peer's proof of our send: delivered with b's id.
    let proof = linkPacket(b, .proof, .none, sentHash + peer.sign(sentHash))
    await store.send(.linkPlane(.routeLinkPacket(linkID: b.linkID, arrivalInterface: InterfaceID("b"), data: proof)))
    await store.receive(.delegate(.channelMessageDelivered(linkID: b.linkID, token: token)))
    #expect(store.state.links[id: b.id]?.channel?.tx.isEmpty == true)

    await store.send(.closeLink(linkID: a.linkID))
    await store.send(.closeLink(linkID: b.linkID))
}
