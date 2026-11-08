import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let radioA = UUID(uuidString: "0000AAAA-0000-0000-0000-0000000000D1")!
private let radioB = UUID(uuidString: "0000BBBB-0000-0000-0000-0000000000D2")!
private let probeParams = RNodeLoRaParams(frequencyHz: 869_525_000, bandwidthHz: 125_000, txPowerDBm: 14,
                                          spreadingFactor: 8, codingRate: 5)
private let hop: Duration = .seconds(5)

private typealias RNodeRadioStream = (stream: AsyncStream<RNodeDriverEvent>,
                                      continuation: AsyncStream<RNodeDriverEvent>.Continuation)

/// An LXMFNode on an RNode whose every sent packet is heard whole by `peer`. `pathsLearned` counts
/// every `.pathLearned` the node reduces, at the transport and endpoint levels.
@MainActor
private func makeRNodeNode(identity: Identity, radio: UUID, own: RNodeRadioStream,
                           peer: AsyncStream<RNodeDriverEvent>.Continuation,
                           onAir: LockIsolated<[Data]>, pathsLearned: LockIsolated<Int>, ifac: IFAC?)
    -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var profile = InterfaceProfile.rnode(params: nil)
    profile.ifac = ifac
    let config = RNodeDriverConfig(radio: radio, params: probeParams)
    let endpoint = TransportEndpoint.State.rnode(RNodeEndpoint.State(config: config, profile: profile))
    let store = TestStore(initialState: LXMFNode.State(identity: identity, endpoint: endpoint)) {
        CombineReducers {
            Reduce<LXMFNode.State, LXMFNode.Action> { _, action in
                switch action {
                case .endpoint(.transport(.delegate(.pathLearned))), .endpoint(.delegate(.pathLearned)):
                    pathsLearned.withValue { $0 += 1 }
                default:
                    break
                }
                return .none
            }
            LXMFNode()
        }
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1_700_000_000.5))
        $0.uuid = .incrementing
        $0.rnodeDriver = RNodeDriver(
            start: { _ in own.stream },
            send: { packet in
                onAir.withValue { $0.append(packet) }
                peer.yield(.packet(packet, rssi: nil, snr: nil))
                return true
            },
            stop: {})
    }
    store.exhaustivity = .off
    return store
}

private struct RNodeProbeResult {
    var content: Data?
    var aOnAir: [Data]
}

private func rnodeProbeReport() -> RNodeRadioReport {
    RNodeRadioReport(firmwareMajor: 1, firmwareMinor: 74, platform: 0x80, params: probeParams)
}

/// Two nodes, each started on its own radio, until both register their interface.
@MainActor
private struct RNodeProbePair {
    let aIdentity = Identity(), bIdentity = Identity()
    let aOnAir = LockIsolated<[Data]>([])
    let aPathsLearned = LockIsolated(0), bPathsLearned = LockIsolated(0)
    let a: TestStore<LXMFNode.State, LXMFNode.Action>
    let b: TestStore<LXMFNode.State, LXMFNode.Action>

    init(aIFAC: IFAC?, bIFAC: IFAC?) async {
        let aRadio = AsyncStream<RNodeDriverEvent>.makeStream()
        let bRadio = AsyncStream<RNodeDriverEvent>.makeStream()
        a = makeRNodeNode(identity: aIdentity, radio: radioA, own: aRadio, peer: bRadio.continuation,
                          onAir: aOnAir, pathsLearned: aPathsLearned, ifac: aIFAC)
        b = makeRNodeNode(identity: bIdentity, radio: radioB, own: bRadio, peer: aRadio.continuation,
                          onAir: LockIsolated([]), pathsLearned: bPathsLearned, ifac: bIFAC)   // only A's air is inspected

        await a.send(.endpoint(.start))
        await b.send(.endpoint(.start))
        aRadio.continuation.yield(.connected(rnodeProbeReport()))
        bRadio.continuation.yield(.connected(rnodeProbeReport()))
        await a.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false }, timeout: hop)
        await b.receive({ if case .endpoint(.transport(.interfaceConnected)) = $0 { return true }; return false }, timeout: hop)
    }

    func stop() async {
        await a.send(.endpoint(.stop))
        await b.send(.endpoint(.stop))
        await a.skipReceivedActions(strict: false)
        await b.skipReceivedActions(strict: false)
    }
}

/// A and B come online, both register (each announce crosses the link and teaches the other a
/// path), then A sends B an opportunistic message.
@MainActor
private func runRNodeProbe(aIFAC: IFAC?, bIFAC: IFAC?) async -> RNodeProbeResult {
    let pair = await RNodeProbePair(aIFAC: aIFAC, bIFAC: bIFAC)
    let a = pair.a, b = pair.b

    // Interleaved, not send-send-receive-receive: A's announce reaches B during A's send, and a
    // non-exhaustive `b.send` would discard B's already-received, unasserted `.pathLearned`.
    await a.send(.registerDelivery)
    await b.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }, timeout: hop)
    await b.send(.registerDelivery)
    await a.receive({ if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }, timeout: hop)

    let bDelivery = LXMessage.deliveryHash(identityHash: pair.bIdentity.hash)
    await a.send(.send(destinationHash: bDelivery, title: Data("hi".utf8),
                       content: Data("hello over rnode".utf8), method: .opportunistic))
    let received = LockIsolated<Data?>(nil)
    await b.receive({ action in
        if case let .delegate(.messageReceived(message, _, _)) = action {
            received.setValue(message.content)
            return true
        }
        return false
    }, timeout: hop)

    await pair.stop()
    return RNodeProbeResult(content: received.value, aOnAir: pair.aOnAir.value)
}

/// True for the radio delivering `sender`'s announce of `destination` (decoded with the sender's
/// IFAC, which the test knows and the receiver may not).
private func rnodeIsAnnounce(_ action: LXMFNode.Action, of destination: Data, maskedWith sender: IFAC) -> Bool {
    guard case let .endpoint(.rnode(.interface(.delegate(.packetReceived(wire))))) = action,
          let raw = sender.unprotect(wire), let packet = Packet(raw: raw)
    else { return false }
    return packet.packetType == .announce && packet.destinationHash == destination
}

// What A puts on the air: an open link carries a 172 B announce and a 227 B data packet; an IFAC
// link (8-byte access code) 180 B and 235 B. A `maxPacketSize` mutation is set from these.

private func rnodeProbeIFAC(passphrase: String = "secret") -> IFAC? {
    RNodeEndpoint.ifac(networkName: "testnet", passphrase: passphrase)
}

@MainActor @Suite struct RNodeWholeSliceTests {
    @Test func opportunisticMessageCrossesAnOpenRNodeLink() async {
        let result = await runRNodeProbe(aIFAC: nil, bIFAC: nil)
        #expect(result.content == Data("hello over rnode".utf8))
    }

    @Test func opportunisticMessageCrossesAnIFACProtectedRNodeLink() async {
        let ifac = rnodeProbeIFAC()
        let result = await runRNodeProbe(aIFAC: ifac, bIFAC: ifac)
        #expect(result.content == Data("hello over rnode".utf8))
    }

    @Test func ifacProtectedLinkCarriesOnlyIFACFlaggedPackets() async {
        let ifac = rnodeProbeIFAC()
        let result = await runRNodeProbe(aIFAC: ifac, bIFAC: ifac)
        #expect(!result.aOnAir.isEmpty, "A put nothing on the air")
        #expect(result.aOnAir.allSatisfy { ($0.first ?? 0) & 0x80 == 0x80 }, "an unmasked packet went on the air")
    }

    @Test func everyPacketOnTheAirCarriesAnEightByteAccessCode() async {
        let ifac = rnodeProbeIFAC()
        let result = await runRNodeProbe(aIFAC: ifac, bIFAC: ifac)
        // Built independently of `RNodeEndpoint.ifac`: what a stock RNS RNodeInterface peer uses.
        let reference = IFAC(networkName: "testnet", passphrase: "secret", size: 8)!
        #expect(!result.aOnAir.isEmpty, "A put nothing on the air")
        for wire in result.aOnAir {
            #expect(reference.unprotect(wire) != nil, "a \(wire.count) B packet fails an 8-byte IFAC check")
        }
    }

    @Test func aMismatchedIFACDeliversNothing() async {
        let aIFAC = rnodeProbeIFAC(passphrase: "secret")!
        let bIFAC = rnodeProbeIFAC(passphrase: "other")!
        let pair = await RNodeProbePair(aIFAC: aIFAC, bIFAC: bIFAC)
        let a = pair.a, b = pair.b
        let aDelivery = LXMessage.deliveryHash(identityHash: pair.aIdentity.hash)
        let bDelivery = LXMessage.deliveryHash(identityHash: pair.bIdentity.hash)

        // A's announce reaches B's radio; B's router must refuse it. A non-exhaustive TestStore's
        // `state` is the last consumed action's, so after the yield, skipping the received actions
        // brings it up to what the router actually reduced.
        await a.send(.registerDelivery)
        await b.receive({ rnodeIsAnnounce($0, of: aDelivery, maskedWith: aIFAC) }, timeout: hop)
        await Task.megaYield()
        await b.skipReceivedActions(strict: false)
        #expect(b.state.endpoint.learned[aDelivery] == nil, "B learned a path to A through a foreign IFAC")
        #expect(pair.bPathsLearned.value == 0, "B reduced a pathLearned")

        // And the other way round.
        await b.send(.registerDelivery)
        await a.receive({ rnodeIsAnnounce($0, of: bDelivery, maskedWith: bIFAC) }, timeout: hop)
        await Task.megaYield()
        await a.skipReceivedActions(strict: false)
        #expect(a.state.endpoint.learned[bDelivery] == nil, "A learned a path to B through a foreign IFAC")
        #expect(pair.aPathsLearned.value == 0, "A reduced a pathLearned")

        await pair.stop()
    }
}
