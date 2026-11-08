import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radioA = UUID(uuidString: "0000AAAA-0000-0000-0000-0000000000C1")!
private let radioB = UUID(uuidString: "0000BBBB-0000-0000-0000-0000000000C2")!
private let prefixA = Data([0xA1, 0xA1, 0xA1, 0xA1])
private let prefixB = Data([0xB2, 0xB2, 0xB2, 0xB2])
private let hop: Duration = .seconds(5)

private typealias MeshCoreRadioStream = (stream: AsyncStream<MeshCoreDriverEvent>,
                                         continuation: AsyncStream<MeshCoreDriverEvent>.Continuation)

/// An LXMFNode on a MeshCore radio whose every sent datagram is heard by `peer`.
@MainActor
private func makeMeshCoreNode(identity: Identity, radio: UUID, own: MeshCoreRadioStream,
                              peer: AsyncStream<MeshCoreDriverEvent>.Continuation,
                              onAir: LockIsolated<[Data]>, ifac: IFAC?)
    -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var profile = InterfaceProfile.meshCore(params: nil)
    profile.ifac = ifac
    let config = MeshCoreDriverConfig(radio: radio, channelSecret: Data(repeating: 0x22, count: 16))
    let endpoint = TransportEndpoint.State.meshCore(MeshCoreEndpoint.State(config: config, profile: profile))
    let store = TestStore(initialState: LXMFNode.State(identity: identity, endpoint: endpoint)) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000.5))
        $0.meshCoreDate = .constant(Date(timeIntervalSince1970: 1_700_000_000.5))
        $0.uuid = .incrementing
        $0.meshCoreClock = ImmediateClock()
        $0.meshCoreDriver = MeshCoreDriver(
            start: { _ in own.stream },
            send: { datagram in
                onAir.withValue { $0.append(datagram) }
                peer.yield(.datagram(datagram))
                return true
            },
            removeChannel: { true },
            stop: {})
    }
    store.exhaustivity = .off
    return store
}

private struct MeshCoreProbeResult {
    var content: Data?
    var aOnAir: [Data]
}

/// A and B come online, both register (each announce crosses the channel and teaches the other a
/// path), then A sends B an opportunistic message.
@MainActor
private func runMeshCoreProbe(ifac: IFAC?) async -> MeshCoreProbeResult {
    let aIdentity = Identity(), bIdentity = Identity()
    let aRadio = AsyncStream<MeshCoreDriverEvent>.makeStream()
    let bRadio = AsyncStream<MeshCoreDriverEvent>.makeStream()
    let aOnAir = LockIsolated<[Data]>([])
    let a = makeMeshCoreNode(identity: aIdentity, radio: radioA, own: aRadio,
                             peer: bRadio.continuation, onAir: aOnAir, ifac: ifac)
    let b = makeMeshCoreNode(identity: bIdentity, radio: radioB, own: bRadio,
                             peer: aRadio.continuation, onAir: LockIsolated([]), ifac: ifac)   // only A's air is inspected

    await a.send(.endpoint(.start))
    await b.send(.endpoint(.start))
    aRadio.continuation.yield(.connected(selfPrefix: prefixA, publicKey: prefixA + Data(repeating: 0xA1, count: 28),
                                         params: nil))
    bRadio.continuation.yield(.connected(selfPrefix: prefixB, publicKey: prefixB + Data(repeating: 0xB2, count: 28),
                                         params: nil))
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
                       content: Data("hello over meshcore".utf8), method: .opportunistic))
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
    return MeshCoreProbeResult(content: received.value, aOnAir: aOnAir.value)
}

private func meshCoreProbeIFAC() -> IFAC? {
    MeshCoreEndpoint.ifac(networkName: "meshcore-probe", passphrase: "probe-pass")
}

@MainActor @Suite struct MeshCoreWholeSliceTests {
    @Test func opportunisticMessageCrossesAnOpenMeshCoreChannel() async {
        let result = await runMeshCoreProbe(ifac: nil)
        #expect(result.content == Data("hello over meshcore".utf8))
    }

    @Test func opportunisticMessageCrossesAnIFACProtectedMeshCoreChannel() async {
        let result = await runMeshCoreProbe(ifac: meshCoreProbeIFAC())
        #expect(result.content == Data("hello over meshcore".utf8))
    }

    @Test func ifacProtectedChannelCarriesOnlyIFACFlaggedPackets() async {
        let result = await runMeshCoreProbe(ifac: meshCoreProbeIFAC())
        let packets = meshCoreReassembleOnAir(result.aOnAir)
        #expect(!packets.isEmpty, "A put nothing reassemblable on the air")
        #expect(packets.allSatisfy { ($0.first ?? 0) & 0x80 == 0x80 }, "an unmasked packet went on the air")
    }

    @Test func everyDatagramOnTheAirFitsTheLimit() async {
        let result = await runMeshCoreProbe(ifac: nil)
        let codec = ScotMeshRawCodec()
        #expect(!result.aOnAir.isEmpty, "A put nothing on the air")
        for datagram in result.aOnAir {
            #expect(datagram.count <= 162, "a \(datagram.count) B datagram went on the air")
            let parsed = codec.parse(datagram)
            #expect(parsed != nil, "an unparseable datagram went on the air")
            #expect(parsed?.dst == Data(repeating: 0, count: 4), "a datagram was addressed")
        }
    }

    @Test func aWholeSliceNeverSendsABindRequest() async {
        let result = await runMeshCoreProbe(ifac: nil)
        let codec = ScotMeshRawCodec()
        #expect(!result.aOnAir.isEmpty, "A put nothing on the air")
        #expect(!result.aOnAir.contains { codec.parse($0)?.type == .bindRequest }, "a BIND_REQ went on the air")
    }
}
