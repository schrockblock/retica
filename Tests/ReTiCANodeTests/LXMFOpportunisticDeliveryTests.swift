import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end: sender A opportunistically delivers an LXMF message to recipient B's lxmf.delivery
/// destination over the real encrypt→route→decrypt path; B reconstructs, validates, and reads it.
@Test @MainActor func opportunisticLXMFMessageDeliversEndToEnd() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    // Both parties' lxmf.delivery destinations (SINGLE, IN — owned locally).
    let aDelivery = Destination(kind: .single, direction: .in, appName: "lxmf", aspects: ["delivery"], identity: aIdentity)!
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

    await a.send(.start); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.start); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)
    await a.send(.registerLocalDestination(aDelivery))
    await b.send(.registerLocalDestination(bDelivery))

    // B announces its lxmf.delivery destination; A learns it (so A can address + encrypt to B).
    await b.send(.announce(destinationHash: bDelivery.hash, appData: nil))
    await b.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received); await a.receive(\.delegate.pathLearned)

    // A announces its lxmf.delivery destination; B learns it (so B can resolve the sender identity).
    await a.send(.announce(destinationHash: aDelivery.hash, appData: nil))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received); await b.receive(\.delegate.pathLearned)

    // A builds an LXMF message to B's delivery destination and sends it opportunistically.
    let msg = LXMessage.create(source: aIdentity, destinationHash: bDelivery.hash,
                               timestamp: 1700000000.5, title: Data("hi".utf8), content: Data("hello lxmf".utf8))
    #expect(bDelivery.hash == LXMessage.deliveryHash(identityHash: bIdentity.hash))   // addressing sanity
    await a.send(.send(destinationHash: bDelivery.hash, plaintext: msg.opportunisticPayload))
    await a.receive { if case .tcpClient(.interface(.send)) = $0 { return true }; return false }

    // Bridge the DATA packet to B; B decrypts and surfaces the plaintext.
    let got = LockIsolated<(Data, Data)?>(nil)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive { action in
        if case let .delegate(.messageReceived(h, p, _, _)) = action { got.setValue((h, p)); return true }
        return false
    }
    let (deliveryHash, plaintext) = got.value!
    #expect(deliveryHash == bDelivery.hash)

    // B reconstructs the LXMF message and validates it against the sender identity it learned.
    let recovered = LXMessage.fromOpportunistic(destinationHash: deliveryHash, payload: plaintext)
    #expect(recovered != nil)
    #expect(recovered?.content == Data("hello lxmf".utf8))
    #expect(recovered?.title == Data("hi".utf8))
    let senderIdentity = b.state.transport.learned[recovered!.sourceHash]?.identity
    #expect(senderIdentity != nil)
    #expect(recovered?.validateSignature(source: senderIdentity!) == true)
    #expect(recovered?.hash == msg.hash)

    await a.send(.stop); await b.send(.stop)
}
