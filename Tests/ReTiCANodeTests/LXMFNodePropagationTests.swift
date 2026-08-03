import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// End-to-end through the LXMFNode composition: client A sends a message to recipient R VIA a propagation
/// node PN. A builds the propagation container (encrypted to R), establishes a link to PN's lxmf.propagation
/// destination, and ships the container as a Resource. PN (a bare TCPEndpoint stub — ingest is P3) receives it;
/// we verify the container is addressed to R and that opening it recovers A's signature-valid message.
/// Then PN's RESOURCE_PRF is bridged back to A, triggering resourceConcluded → propagationAccepted.
@Test @MainActor func lxmfNodeSendsViaPropagationNodeAndConfirmsAccept() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let rIdentity = Identity()
    let pnIdentity = Identity()
    let rDeliveryHash = LXMessage.deliveryHash(identityHash: rIdentity.hash)
    let rDelivery = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                aspects: LXMessage.deliveryAspects, identity: rIdentity)!
    let pnDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                             aspects: ["propagation"], identity: pnIdentity)!

    func makeNode(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>)
        -> (TestStore<LXMFNode.State, LXMFNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: LXMFNode.State(
            identity: identity, endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false))
        ) { LXMFNode() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func makeEndpoint(_ host: String, _ sent: LockIsolated<[Data]>)
        -> (TestStore<TCPEndpoint.State, TCPEndpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false)) {
            TCPEndpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } }, close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    func aSend(_ act: LXMFNode.Action) -> Bool { if case .endpoint(.tcp(.interface(.send))) = act { return true }; return false }
    func epSend(_ act: TCPEndpoint.Action) -> Bool { if case .interface(.send) = act { return true }; return false }

    let sentA = LockIsolated<[Data]>([]); let sentR = LockIsolated<[Data]>([]); let sentPN = LockIsolated<[Data]>([])
    let (a, eventsA) = makeNode("a", aIdentity, sentA)
    let (r, eventsR) = makeEndpoint("r", sentR)
    let (pn, eventsPN) = makeEndpoint("pn", sentPN)

    await a.send(.endpoint(.start)); eventsA.yield(.connected)
    await r.send(.connect); eventsR.yield(.connected)
    await pn.send(.connect); eventsPN.yield(.connected)

    // R announces its delivery destination → A learns R's identity (to encrypt the container tail).
    await r.send(.registerLocalDestination(rDelivery))
    await r.send(.announce(destinationHash: rDelivery.hash, appData: nil))
    await r.receive(epSend)
    eventsA.yield(.data(sentR.value.last!))
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // PN announces its lxmf.propagation destination → A learns PN's path + identity (to establish the link).
    // Use targetStampCost:4 so the async PoW in sendViaPropagation is fast.
    let pnAppData = PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 0, perSyncLimit: 0,
                               targetStampCost: 4, stampCostFlexibility: 0, peeringCost: 0).packed
    await pn.send(.registerLocalDestination(pnDest))
    await pn.send(.announce(destinationHash: pnDest.hash, appData: pnAppData))
    await pn.receive(epSend)
    eventsA.yield(.data(sentPN.value.last!))
    await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // Configure PN and send via propagation.
    // Use content large enough (> ~252 bytes) to produce a propagation container that exceeds Link.mdu
    // (431 bytes) so the test exercises the Resource path rather than the small-container packet path.
    let largeContent = Data(String(repeating: "X", count: 300).utf8)
    await a.send(.setPropagationNode(destinationHash: pnDest.hash))
    await a.send(.sendViaPropagation(destinationHash: rDeliveryHash, title: Data("t".utf8),
                                     content: largeContent))
    await a.receive(aSend)                                   // LINKREQUEST out to PN

    // Link handshake A ↔ PN (A = LXMFNode, PN = TCPEndpoint), mirroring the direct test.
    eventsPN.yield(.data(sentA.value.last!))
    await pn.receive(epSend)                                 // LRPROOF out
    let lrrttIdx = sentA.value.count
    eventsA.yield(.data(sentPN.value.last!))
    await a.receive(aSend)                                   // LRRTT out (RESOURCE_ADV also fires this chain)
    let lrrttBytes = sentA.value[lrrttIdx]
    let resourceAdvBytes = sentA.value[lrrttIdx + 1]
    eventsPN.yield(.data(lrrttBytes))
    await a.receive { if case .endpoint(.delegate(.linkEstablished)) = $0 { return true }; return false }
    await pn.receive(\.delegate.linkEstablished)
    await a.receive(aSend)                                   // RESOURCE_ADV (already queued in A's store)

    // ADV → PN: PN spawns a receiver, emits RESOURCE_REQ.
    eventsPN.yield(.data(resourceAdvBytes))
    await pn.receive(epSend)                                 // RESOURCE_REQ out
    eventsA.yield(.data(sentPN.value.last!))
    let partCount = a.state.endpoint.links[0].transfers[0].parts.count
    for _ in 0..<partCount { await a.receive(aSend) }

    // Deliver all part frames to PN; capture the concluded container from resourceReceived.
    // Also capture the RESOURCE_PRF emitted by PN so we can bridge it back to A.
    let parts = Array(sentA.value.suffix(partCount))
    let gotContainer = LockIsolated<Data?>(nil)
    let resourcePrfBytes = LockIsolated<Data?>(nil)
    for (i, frame) in parts.enumerated() {
        eventsPN.yield(.data(frame))
        if i == partCount - 1 {
            await pn.receive(epSend)                         // RESOURCE_PRF out
            resourcePrfBytes.setValue(sentPN.value.last!)    // capture RESOURCE_PRF before resourceReceived
            await pn.receive { action in
                if case let .delegate(.resourceReceived(_, d)) = action { gotContainer.setValue(d); return true }
                return false
            }
        }
    }

    // Verify the delivered container: addressed to R, and opens to A's signature-valid message.
    let container = gotContainer.value
    #expect(container != nil)
    let parsed = LXMFPropagation.parseContainer(container!)
    #expect(parsed != nil)
    #expect(parsed?.entries.count == 1)
    let entry = parsed!.entries[0]
    #expect(LXMFPropagation.destinationHash(lxmfData: entry) == rDeliveryHash)   // addressed to R
    let recovered = LXMFPropagation.open(lxmfData: entry, recipientIdentity: rIdentity)
    #expect(recovered != nil)
    #expect(recovered?.content == largeContent)
    #expect(recovered?.title == Data("t".utf8))
    #expect(recovered?.sourceHash == LXMessage.deliveryHash(identityHash: aIdentity.hash))
    #expect(recovered?.validateSignature(source: aIdentity) == true)             // real Ed25519 validation

    // PN's RESOURCE_PRF → A: A concludes the resource → router.resourceDeliveredOnLink → propagationAccepted.
    // Recover the deterministic message hash by rebuilding with the same fixed params.
    let sentHash = LXMessage.create(source: aIdentity, destinationHash: rDeliveryHash,
                                    timestamp: 1700000000.5, title: Data("t".utf8),
                                    content: largeContent).hash
    let gotAccepted = LockIsolated<Data?>(nil)
    eventsA.yield(.data(resourcePrfBytes.value!))            // PN's RESOURCE_PRF → A concludes the resource
    await a.receive { action in
        if case let .delegate(.propagationAccepted(hash)) = action { gotAccepted.setValue(hash); return true }
        return false
    }
    #expect(gotAccepted.value == sentHash)

    await a.send(.endpoint(.stop)); await r.send(.disconnect); await pn.send(.disconnect)
}
