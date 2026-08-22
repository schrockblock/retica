import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// MARK: – LXMF-3 Task 2: direct delivery over a link (packet + resource)

/// Small LXMF message (packed ≤ Link.mdu = 431) delivered as a raw link packet.
@Test @MainActor func directLXMFSmallMessageDeliversAsLinkPacket() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let bDelivery = Destination(kind: .single, direction: .in, appName: "lxmf", aspects: ["delivery"], identity: bIdentity)!

    func make(_ host: String, _ sent: LockIsolated<[Data]>) -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: tcpDriverEndpoint(host: host, port: 4242, reconnectOnDrop: false)) {
            TransportEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", sentA)
    let (b, eventsB) = make("b", sentB)

    // --- Establish the link (mirrors twoEndpointsEstablishLinkExchangeDataAndClose steps 1–4) ---
    await a.send(.start); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(bDelivery))
    await b.send(.start); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)

    // 1. B announces its lxmf.delivery destination; A learns it.
    await b.send(.announce(destinationHash: bDelivery.hash, appData: nil))
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive(\.delegate.pathLearned)

    // 2. A opens the link → LINKREQUEST out to B.
    await a.send(.openLink(destinationHash: bDelivery.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }  // LRPROOF out

    // 3. B's LRPROOF → A → A active, emits LRRTT.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }  // LRRTT out
    await a.receive(\.delegate.linkEstablished)
    #expect(a.state.links[0].status == .active)

    // 4. A's LRRTT → B → B active.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive(\.delegate.linkEstablished)
    #expect(b.state.links[0].status == .active)
    let linkID = a.state.links[0].linkID
    #expect(a.state.links[0].linkID == b.state.links[0].linkID)

    // 5. A sends a small LXMF message over the link; B receives it as a link packet.
    let msg = LXMessage.create(source: aIdentity, destinationHash: bDelivery.hash,
                               timestamp: 1700000000.5, title: Data("hi".utf8), content: Data("small direct".utf8))
    #expect(msg.directRepresentation == .packet)    // packed ≤ 431 bytes
    await a.send(.sendOverLink(linkID: linkID, data: msg.packed))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }

    let got = LockIsolated<Data?>(nil)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive { action in
        if case let .delegate(.linkDataReceived(lid, d, _)) = action, lid == linkID { got.setValue(d); return true }
        return false
    }

    let recovered = LXMessage.unpack(got.value!)
    #expect(recovered != nil)
    #expect(recovered?.content == Data("small direct".utf8))
    #expect(recovered?.title == Data("hi".utf8))
    #expect(recovered?.hash == msg.hash)
    #expect(recovered?.validateSignature(source: aIdentity) == true)

    await a.send(.stop); await b.send(.stop)
}

/// Large LXMF message (packed > Link.mdu = 431) delivered as a Resource over the link.
@Test @MainActor func directLXMFLargeMessageDeliversAsResource() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let bDelivery = Destination(kind: .single, direction: .in, appName: "lxmf", aspects: ["delivery"], identity: bIdentity)!

    func make(_ host: String, _ sent: LockIsolated<[Data]>) -> (TestStore<TransportEndpoint.State, TransportEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: tcpDriverEndpoint(host: host, port: 4242, reconnectOnDrop: false)) {
            TransportEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", sentA)
    let (b, eventsB) = make("b", sentB)

    // --- Establish the link (mirrors twoEndpointsTransferAResourceOverALink steps 1–4) ---
    await a.send(.start); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.registerLocalDestination(bDelivery))
    await b.send(.start); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)

    // 1. B announces its lxmf.delivery destination; A learns it.
    await b.send(.announce(destinationHash: bDelivery.hash, appData: nil))
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive(\.delegate.pathLearned)

    // 2. A opens the link → LINKREQUEST out to B.
    await a.send(.openLink(destinationHash: bDelivery.hash))
    await a.receive { if case .link(.element(_, .establish)) = $0 { return true }; return false }
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive(\.transport.delegate.linkRequest)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }  // LRPROOF out

    // 3. B's LRPROOF → A → A active, emits LRRTT.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }  // LRRTT out
    await a.receive(\.delegate.linkEstablished)
    #expect(a.state.links[0].status == .active)

    // 4. A's LRRTT → B → B active.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive(\.delegate.linkEstablished)
    #expect(b.state.links[0].status == .active)
    let linkID = a.state.links[0].linkID
    #expect(a.state.links[0].linkID == b.state.links[0].linkID)

    // 5. A sends a large LXMF message as a Resource over the link.
    let bigContent = Data((0..<800).map { UInt8($0 & 0xff) })
    let msg = LXMessage.create(source: aIdentity, destinationHash: bDelivery.hash,
                               timestamp: 1700000000.5, title: Data("big".utf8), content: bigContent)
    #expect(msg.directRepresentation == .resource)  // packed > 431 bytes

    await a.send(.sendResourceOverLink(linkID: linkID, data: msg.packed))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }  // RESOURCE_ADV out

    // ADV → B: spawns a receiver, emits RESOURCE_REQ.
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }  // RESOURCE_REQ out

    // REQ → A: A serves its parts.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    let partCount = a.state.links[0].transfers[0].parts.count
    for _ in 0..<partCount {
        await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    }

    // Deliver every part frame A emitted (the last `partCount` frames in sentA) to B.
    let parts = Array(sentA.value.suffix(partCount))
    let got = LockIsolated<Data?>(nil)
    for (i, frame) in parts.enumerated() {
        eventsB.yield(.data(frame))
        await b.receive(\.transport.received)
        if i == partCount - 1 {
            await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }  // RESOURCE_PRF out
            await b.receive { action in
                if case let .delegate(.resourceReceived(lid, d)) = action, lid == linkID { got.setValue(d); return true }
                return false
            }
        }
    }

    // PRF → A: A validates and concludes.
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received)
    await a.receive { action in
        if case let .delegate(.resourceConcluded(lid, _)) = action, lid == linkID { return true }
        return false
    }

    let recovered = LXMessage.unpack(got.value!)
    #expect(recovered != nil)
    #expect(recovered?.content == bigContent)
    #expect(recovered?.title == Data("big".utf8))
    #expect(recovered?.hash == msg.hash)
    #expect(recovered?.validateSignature(source: aIdentity) == true)

    await a.send(.stop); await b.send(.stop)
}
