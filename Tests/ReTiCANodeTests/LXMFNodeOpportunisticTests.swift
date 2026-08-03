import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end through the LXMFNode composition: node A opportunistically delivers an LXMF message to
/// node B, and B's LXMFNode surfaces the reconstructed, signature-validated message — with no hand-wiring
/// of LXMessage/TCPEndpoint (the router does it).
@Test @MainActor func lxmfNodeOpportunisticDeliversEndToEnd() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let bDeliveryHash = LXMessage.deliveryHash(identityHash: bIdentity.hash)

    func make(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFNode.State, LXMFNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: LXMFNode.State(
            identity: identity, endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false))
        ) {
            LXMFNode()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", aIdentity, sentA)
    let (b, eventsB) = make("b", bIdentity, sentB)

    await a.send(.endpoint(.start)); eventsA.yield(.connected)
    await b.send(.endpoint(.start)); eventsB.yield(.connected)

    // Both register + announce their lxmf.delivery destination; bridge announces so each learns the other
    // (path + identity — B needs A's identity to validate A's signature).
    await a.send(.registerDelivery)
    await a.receive { if case .endpoint(.tcp(.interface(.send))) = $0 { return true }; return false }
    await b.send(.registerDelivery)
    await b.receive { if case .endpoint(.tcp(.interface(.send))) = $0 { return true }; return false }
    eventsA.yield(.data(sentB.value.last!))                 // B's announce → A learns B
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))                 // A's announce → B learns A
    await b.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // A sends opportunistically to B; bridge the DATA packet to B.
    await a.send(.send(destinationHash: bDeliveryHash, title: Data("hi".utf8), content: Data("hello node".utf8), method: .opportunistic))
    await a.receive { if case .endpoint(.tcp(.interface(.send))) = $0 { return true }; return false }
    eventsB.yield(.data(sentA.value.last!))

    // B's LXMFNode surfaces the reconstructed + validated message.
    let gotContent = LockIsolated<Data?>(nil)
    let gotTitle = LockIsolated<Data?>(nil)
    let gotDestHash = LockIsolated<Data?>(nil)
    let gotSrcHash = LockIsolated<Data?>(nil)
    let gotValidated = LockIsolated<Bool>(false)
    await b.receive { action in
        if case let .delegate(.messageReceived(m, v)) = action {
            gotContent.setValue(m.content)
            gotTitle.setValue(m.title)
            gotDestHash.setValue(m.destinationHash)
            gotSrcHash.setValue(m.sourceHash)
            gotValidated.setValue(v)
            return true
        }
        return false
    }
    #expect(gotContent.value == Data("hello node".utf8))
    #expect(gotTitle.value == Data("hi".utf8))
    #expect(gotDestHash.value == bDeliveryHash)
    #expect(gotSrcHash.value == LXMessage.deliveryHash(identityHash: aIdentity.hash))
    #expect(gotValidated.value == true)                     // B learned A's identity → signature validates

    await a.send(.endpoint(.stop)); await b.send(.endpoint(.stop))
}
