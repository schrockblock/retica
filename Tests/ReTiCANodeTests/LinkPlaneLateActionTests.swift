import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCATransport
@testable import ReTiCA

// Late actions for a link (or a transfer) that has already been removed.
//
// Nbhd's live suite hit "A forEach ... received an action for a missing element" at LinkPlane's
// `.forEach` once Nbhd began closing request links promptly: a resource-carried response's proof
// and the LINKCLOSE behind it arrive together, and the close removed the link before the transfer's
// `.concluded` got there. `forEach` reports that through `reportIssue`, which fails a test.
//
// The reproduction has to deliver both packets in ONE store turn, as `TCPClientInterface` does for
// frames from one socket read (`.merge` of one `.send` per frame). TCA drains effect actions
// breadth-first, so the close chain (route → received → closed) removes the element one level
// before the proof chain (route → received → transfer.received → transfer.concluded) finishes.
// `OneReadDelivery` is that one-read delivery, and nothing more.

@Reducer
struct OneReadDelivery {
    @ObservableState
    struct State: Equatable { var plane = LinkPlane.State() }
    enum Action: Equatable {
        case plane(LinkPlane.Action)
        case deliver(linkID: Data, arrival: InterfaceID, packets: [Data])
    }
    var body: some ReducerOf<Self> {
        Scope(state: \.plane, action: \.plane) { LinkPlane() }
        Reduce { _, action in
            guard case let .deliver(linkID, arrival, packets) = action else { return .none }
            return .merge(packets.map {
                .send(.plane(.routeLinkPacket(linkID: linkID, arrivalInterface: arrival, data: $0)))
            })
        }
    }
}

private func linkPacket(_ type: PacketType, _ context: PacketContext, _ linkID: Data, _ payload: Data) -> Data {
    try! Packet(headerType: .header1, packetType: type, transportType: .broadcast,
                destinationType: .link, context: context, contextFlag: false, hops: 0,
                destinationHash: linkID, transportId: nil, payload: payload).packed()
}

/// An ACTIVE responder link inside the plane (real handshake: the session key must be genuine).
@MainActor
private func activeResponder(_ store: TestStore<OneReadDelivery.State, OneReadDelivery.Action>, interfaceID: InterfaceID)
    async -> (id: UUID, linkID: Data, key: Data)
{
    let destHash = Data(repeating: 0x5A, count: 16)
    let request = try! Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                              destinationType: .single, context: .none, contextFlag: false, hops: 0,
                              destinationHash: destHash, transportId: nil,
                              payload: Identity().publicKey + Link.signallingBytes).packed()
    await store.send(.plane(.acceptLinkRequest(owner: Identity(), destinationHash: destHash,
                                               interfaceID: interfaceID, data: request)))
    await store.receive { if case .plane(.link(.element(_, .acceptRequest))) = $0 { return true }; return false }
    let element = store.state.plane.links.first { $0.status == .handshake }!
    let rtt = linkPacket(.data, .linkRequestRTT, element.linkID,
                         Link.encrypt(MsgPack.encode(0.0), sessionKey: element.sessionKey))
    await store.send(.plane(.routeLinkPacket(linkID: element.linkID, arrivalInterface: interfaceID, data: rtt)))
    await store.receive { if case .plane(.delegate(.linkEstablished)) = $0 { return true }; return false }
    return (element.id, element.linkID, element.sessionKey)
}

@MainActor
private func makeStore() -> TestStore<OneReadDelivery.State, OneReadDelivery.Action> {
    let store = TestStore(initialState: OneReadDelivery.State()) { OneReadDelivery() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    return store
}

/// The live-suite shape: a resource's proof and the LINKCLOSE right behind it, in one read. The
/// link must close cleanly and no action may reach the removed link or its removed transfer.
/// (Any such action is a `reportIssue` from a `.forEach`, which fails this test by itself.)
@Test @MainActor func proofAndCloseInOneReadDoNotReachARemovedLink() async {
    let ifID = InterfaceID("tcp")
    let store = makeStore()
    let link = await activeResponder(store, interfaceID: ifID)

    await store.send(.plane(.sendResourceOverLink(linkID: link.linkID, data: Data(repeating: 0xCD, count: 64))))
    await store.receive { if case .plane(.delegate(.transmit)) = $0 { return true }; return false }   // advertisement
    let transfer = store.state.plane.links[id: link.id]!.transfers[0]

    let proof = linkPacket(.proof, .resourceProof, link.linkID, transfer.resourceHash + transfer.expectedProof)
    let close = linkPacket(.data, .linkClose, link.linkID, Link.encrypt(link.linkID, sessionKey: link.key))
    await store.send(.deliver(linkID: link.linkID, arrival: ifID, packets: [proof, close]))

    await store.receive { if case .plane(.delegate(.linkClosed)) = $0 { return true }; return false }
    #expect(store.state.plane.links.isEmpty)
}

/// A late action for a link that is already gone — e.g. a timer whose action was emitted just
/// before the removal cancelled it — is a quiet no-op, not a `forEach` issue.
@Test @MainActor func lateActionForARemovedLinkIsIgnoredQuietly() async {
    let store = makeStore()
    let link = await activeResponder(store, interfaceID: InterfaceID("tcp"))
    await store.send(.plane(.closeLink(linkID: link.linkID)))
    await store.receive { if case .plane(.delegate(.linkClosed)) = $0 { return true }; return false }
    #expect(store.state.plane.links[id: link.id] == nil)

    await store.send(.plane(.link(.element(id: link.id, action: .inactivityDeadline))))
    await store.send(.plane(.link(.element(id: link.id, action: .transfer(.element(id: UUID(), action: .receiverDeadline))))))
    #expect(store.state.plane.links.isEmpty)
}
