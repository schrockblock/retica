import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// A responder in `.handshake` must not lose authenticated traffic that overtakes the LRRTT.
//
// The initiator goes `.active` as soon as it validates the proof and may transmit LINKIDENTIFY and
// a REQUEST right behind its LRRTT; nothing guarantees they arrive after it. Before the backlog,
// those packets fell to `dispatch`'s `default: .none` — the request was silently lost, and the
// initiator's request timed out ~11 s later (Nbhd live smoke, ~1 in 6 sync requests).

private let epoch = Date(timeIntervalSince1970: 0)

private func linkData(_ linkID: Data, _ context: PacketContext, _ payload: Data) -> Data {
    try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                destinationType: .link, context: context, contextFlag: false, hops: 0,
                destinationHash: linkID, transportId: nil, payload: payload).packed()
}

@Test @MainActor func responderReplaysIdentifyAndRequestThatArriveBeforeTheRTT() async throws {
    let clock = TestClock<Duration>()
    let owner = Identity()
    let initEph = Identity()
    let destHash = Data(repeating: 0x66, count: 16)
    let linkRequest = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                             destinationType: .single, context: .none, contextFlag: false, hops: 0,
                             destinationHash: destHash, transportId: nil,
                             payload: initEph.publicKey + Link.signallingBytes)
    let store = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.acceptRequest(try linkRequest.packed()))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }   // LRPROOF
    #expect(store.state.status == .handshake)

    let linkID = store.state.linkID
    let key = store.state.sessionKey

    // What the initiator transmits right after its LRRTT, delivered AHEAD of it.
    let peer = Identity()
    let identify = linkData(linkID, .linkIdentify,
                            Link.encrypt(peer.publicKey + peer.sign(linkID + peer.publicKey), sessionKey: key))
    let pathHash = Crypto.truncatedHash(Data("/nbhd/sync".utf8))
    let body = MsgPack.encode(.array([.string("hello")]))
    let requestPlain = MsgPack.encode(.array([.double(0), .bin(pathHash), MsgPack.decodeValue(body)!]))
    let request = linkData(linkID, .request, Link.encrypt(requestPlain, sessionKey: key))
    let requestID = Packet(raw: request)!.truncatedHash
    // Injected junk at the (cleartext) linkID must not be held: only traffic that authenticates is.
    let junk = linkData(linkID, .request, Data(repeating: 0x00, count: 48))

    // Exhaustive across the early arrivals: none of them may emit anything (no delegate, no
    // establishment failure) — they are held, not processed and not dropped.
    store.exhaustivity = .on
    await store.send(.received(identify, arrivalInterface: InterfaceID("i"))) {
        $0.handshakeBacklog = [.init(data: identify, arrivalInterface: InterfaceID("i"))]
    }
    await store.send(.received(junk, arrivalInterface: InterfaceID("i")))
    await store.send(.received(request, arrivalInterface: InterfaceID("i"))) {
        $0.handshakeBacklog.append(.init(data: request, arrivalInterface: InterfaceID("i")))
    }
    store.exhaustivity = .off
    #expect(store.state.status == .handshake)

    // The LRRTT lands: the link activates, `.established` goes out FIRST, then the held packets
    // are processed in arrival order by the ordinary `.active` branches.
    let rtt = linkData(linkID, .linkRequestRTT, Link.encrypt(MsgPack.encode(0.0), sessionKey: key))
    await store.send(.received(rtt))
    #expect(store.state.status == .active)
    #expect(store.state.handshakeBacklog.isEmpty)
    await store.receive { if case .delegate(.established) = $0 { return true }; return false }
    await store.receive { if case let .delegate(.identified(who)) = $0 { return who.publicKey == peer.publicKey }; return false }
    #expect(store.state.remoteIdentity?.publicKey == peer.publicKey)
    await store.receive(.delegate(.requestReceived(requestID: requestID, pathHash: pathHash, data: body)))

    await store.send(.close)
}
