import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radioA = UUID(uuidString: "0000AAAA-0000-0000-0000-0000000000A1")!
private let radioB = UUID(uuidString: "0000BBBB-0000-0000-0000-0000000000B2")!
private let nodeA: UInt32 = 0xA1A1_A1A1
private let nodeB: UInt32 = 0xB2B2_B2B2
private let hop: Duration = .seconds(5)

private typealias MeshRadioStream = (stream: AsyncStream<MeshtasticDriverEvent>,
                                     continuation: AsyncStream<MeshtasticDriverEvent>.Continuation)

/// An LXMFNode on a Meshtastic radio whose every sent frame is heard by `peer` as node `nodeNum`.
@MainActor
private func makeMeshNode(identity: Identity, radio: UUID, nodeNum: UInt32, own: MeshRadioStream,
                          peer: AsyncStream<MeshtasticDriverEvent>.Continuation,
                          onAir: LockIsolated<[Data]>, ifac: IFAC?)
    -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var profile = InterfaceProfile.meshtastic(modemPreset: nil)
    profile.ifac = ifac
    let endpoint = TransportEndpoint.State.meshtastic(
        MeshtasticEndpoint.State(config: MeshtasticDriverConfig(radio: radio), profile: profile))
    let store = TestStore(initialState: LXMFNode.State(identity: identity, endpoint: endpoint)) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000.5))
        $0.uuid = .incrementing
        $0.meshtasticClock = ImmediateClock()
        $0.meshtasticDriver = MeshtasticDriver(
            start: { _ in own.stream },
            send: { frame in
                onAir.withValue { $0.append(frame) }
                peer.yield(.fragment(from: nodeNum, frame))
                return true
            },
            stop: {})
    }
    store.exhaustivity = .off
    return store
}

private struct ProbeResult {
    var content: Data?
    var aOnAir: [Data]
}

/// A and B come online, both register (each announce crosses the channel and teaches the other a
/// path), then A sends B an opportunistic message.
@MainActor
private func runMeshProbe(ifac: IFAC?) async -> ProbeResult {
    let aIdentity = Identity(), bIdentity = Identity()
    let aRadio = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let bRadio = AsyncStream<MeshtasticDriverEvent>.makeStream()
    let aOnAir = LockIsolated<[Data]>([])
    let a = makeMeshNode(identity: aIdentity, radio: radioA, nodeNum: nodeA, own: aRadio,
                         peer: bRadio.continuation, onAir: aOnAir, ifac: ifac)
    let b = makeMeshNode(identity: bIdentity, radio: radioB, nodeNum: nodeB, own: bRadio,
                         peer: aRadio.continuation, onAir: LockIsolated([]), ifac: ifac)   // only A's air is inspected

    await a.send(.endpoint(.start))
    await b.send(.endpoint(.start))
    aRadio.continuation.yield(.connected(myNodeNum: nodeA, modemPreset: 8))
    bRadio.continuation.yield(.connected(myNodeNum: nodeB, modemPreset: 8))
    await a.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false }, timeout: hop)
    await b.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false }, timeout: hop)

    // Interleaved, not send-send-receive-receive: A's announce reaches B during A's send, and a
    // non-exhaustive `b.send` would discard B's already-received, unasserted `.pathLearned`.
    await a.send(.registerDelivery)
    await b.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }, timeout: hop)
    await b.send(.registerDelivery)
    await a.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }, timeout: hop)

    let bDelivery = LXMessage.deliveryHash(identityHash: bIdentity.hash)
    await a.send(.send(destinationHash: bDelivery, title: Data("hi".utf8),
                       content: Data("hello over meshtastic".utf8), method: .opportunistic))
    let received = LockIsolated<Data?>(nil)
    await b.receive({ action in
        if case let .delegate(.messageReceived(message, _, _)) = action {
            received.setValue(message.content)
            return true
        }
        return false
    }, timeout: hop)

    await a.send(.endpoint(.stop))
    await b.send(.endpoint(.stop))
    await a.skipReceivedActions(strict: false)
    await b.skipReceivedActions(strict: false)
    return ProbeResult(content: received.value, aOnAir: aOnAir.value)
}

/// What a listener on the channel reassembles from A's frames.
private func reassembledOnAir(_ frames: [Data], from node: UInt32) -> [Data] {
    let codec = LandandairCodec()
    var reassembler = MeshtasticReassembler()
    var packets: [Data] = []
    for frame in frames {
        guard case let .data(index, pos, body)? = codec.parse(frame) else { continue }
        if let packet = reassembler.receive(from: node, index: index, pos: pos, body: body,
                                            now: Date(timeIntervalSince1970: 0)) {
            packets.append(packet)
        }
    }
    return packets
}

@MainActor @Suite struct MeshtasticWholeSliceTests {
    @Test func opportunisticMessageCrossesAnOpenMeshtasticChannel() async {
        let result = await runMeshProbe(ifac: nil)
        #expect(result.content == Data("hello over meshtastic".utf8))
    }

    @Test func opportunisticMessageCrossesAnIFACProtectedMeshtasticChannel() async {
        let result = await runMeshProbe(ifac: MeshtasticEndpoint.ifac(networkName: "mesh-probe", passphrase: "probe-pass"))
        #expect(result.content == Data("hello over meshtastic".utf8))
    }

    @Test func ifacProtectedChannelCarriesOnlyIFACFlaggedPackets() async {
        let result = await runMeshProbe(ifac: MeshtasticEndpoint.ifac(networkName: "mesh-probe", passphrase: "probe-pass"))
        let packets = reassembledOnAir(result.aOnAir, from: nodeA)
        #expect(!packets.isEmpty, "A put nothing reassemblable on the air")
        #expect(packets.allSatisfy { ($0.first ?? 0) & 0x80 == 0x80 }, "an unmasked packet went on the air")
    }
}
