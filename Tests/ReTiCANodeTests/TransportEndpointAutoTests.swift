import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// MARK: - AutoInterface slot wiring in TransportEndpoint (spec 2026-11-10-autointerface §5.7, §7.2.10)
//
// Each discovered AutoInterface peer is its own Transport interface (`auto:<nic>/<addr>`). These
// tests drive the REAL `AutoInterface` reducer through a mock `AutoInterfaceDriver` (discovery and
// data datagrams on its event stream), so a peer is added and evicted the way it is in production,
// and observe the container through a recorder that logs every action it processes exactly once.

private let en0 = AutoNIC(name: "en0", index: 4, linkLocals: ["fe80::1"])
private let en1 = AutoNIC(name: "en1", index: 5, linkLocals: ["fe80::2"])
private let peerA = "fe80::a"
private let peerB = "fe80::b"
private let idA = AutoEndpoint.autoInterfaceID(nic: "en0", addr: peerA)
private let idB = AutoEndpoint.autoInterfaceID(nic: "en1", addr: peerB)

/// One call the container's slot made on the mock driver, or one action the container processed.
private enum Event: Equatable, Sendable {
    case run, stop, unicast(addr: String, index: UInt32, port: UInt16, datagram: Data)
    case startMaintenance, stopMaintenance
    case connected(InterfaceID), disconnected(InterfaceID), linkDisconnected(InterfaceID)
    case received(InterfaceID, Data)
    case sendFailed(Data)
    case autoDelegate(AutoInterface.Action.Delegate)
    /// Any unified `.delegate(...)` (its payload is not Sendable).
    case unified
}

/// Logs every action the wrapped `TransportEndpoint` processes, exactly once, before reducing it.
private struct Recorder: Reducer {
    let log: LockIsolated<[Event]>
    func reduce(into state: inout TransportEndpoint.State, action: TransportEndpoint.Action)
        -> Effect<TransportEndpoint.Action> {
        switch action {
        case .transport(.startMaintenance): log.withValue { $0.append(.startMaintenance) }
        case .transport(.stopMaintenance): log.withValue { $0.append(.stopMaintenance) }
        case let .transport(.interfaceConnected(id, _)): log.withValue { $0.append(.connected(id)) }
        case let .transport(.interfaceDisconnected(id)): log.withValue { $0.append(.disconnected(id)) }
        case let .linkPlane(.interfaceDisconnected(id)): log.withValue { $0.append(.linkDisconnected(id)) }
        case let .transport(.received(id, data)): log.withValue { $0.append(.received(id, data)) }
        case let .auto(.interface(.delegate(d))): log.withValue { $0.append(.autoDelegate(d)) }
        case let .delegate(d):
            if case let .sendFailed(h, _) = d { log.withValue { $0.append(.sendFailed(h)) } }
            log.withValue { $0.append(.unified) }
        default: break
        }
        return TransportEndpoint().reduce(into: &state, action: action)
    }
}

@MainActor
private final class AutoEndpointHarness {
    typealias Store = TestStore<TransportEndpoint.State, TransportEndpoint.Action>
    let store: Store
    let clock = TestClock<Duration>()
    let start: TestClock<Duration>.Instant
    let log = LockIsolated<[Event]>([])
    let sessions = LockIsolated<[AsyncStream<AutoSocketEvent>.Continuation]>([])
    let holdStop = LockIsolated(false)
    /// What the mock driver's `interfaces()` reports.
    let nics = LockIsolated([en0, en1])
    let transportNow = LockIsolated(Date(timeIntervalSince1970: 0))
    let tcpEvents = AsyncStream<TCPEvent>.makeStream()
    static let base = Date(timeIntervalSince1970: 1_000_000)

    init(withTCPClient: Bool = false, ifac: (String, String)? = nil) {
        start = clock.now
        let clock = self.clock, start = self.start, log = self.log, sessions = self.sessions
        let hold = self.holdStop, transportNow = self.transportNow, tcp = self.tcpEvents.stream
        let nics = self.nics
        let slot = AutoEndpoint.State(ifacNetworkName: ifac?.0, ifacPassphrase: ifac?.1)
        let initial = TransportEndpoint.State(
            tcpClients: withTCPClient ? [TCPEndpoint.State(host: "peer", port: 4242, reconnectOnDrop: false)] : [],
            auto: slot)
        store = TestStore(initialState: initial) {
            Recorder(log: log)
        } withDependencies: {
            $0.autoInterfaceDriver = AutoInterfaceDriver(
                interfaces: { nics.value },
                run: { _ in
                    log.withValue { $0.append(.run) }
                    let s = AsyncStream<AutoSocketEvent>.makeStream()
                    sessions.withValue { $0.append(s.continuation) }
                    return s.stream
                },
                rebind: { _ in }, unbind: { _ in },
                sendMulticast: { _, _, _ in .sent },
                sendUnicast: { addr, index, port, d in
                    log.withValue { $0.append(.unicast(addr: addr, index: index, port: port, datagram: d)) }
                    return .sent
                },
                stop: {
                    while hold.value { await Task.yield() }
                    sessions.value.last?.finish()
                    log.withValue { $0.append(.stop) }
                })
            $0.tcpConnection = TCPConnection(open: { _, _ in tcp }, send: { _ in }, close: { })
            $0.continuousClock = clock
            $0.date = DateGenerator {
                let d = start.duration(to: clock.now).components
                return AutoEndpointHarness.base.addingTimeInterval(Double(d.seconds) + Double(d.attoseconds) / 1e18)
            }
            $0.transportDate = DateGenerator { transportNow.value }
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
    }

    func settle() async {
        for _ in 0..<30 { await Task.megaYield() }
        await store.skipReceivedActions(strict: false)
    }

    func advance(to seconds: Double) async {
        await clock.advance(to: start.advanced(by: .seconds(seconds)))
        await settle()
    }

    /// Starts the endpoint and passes the 1.92 s initial peering wait, so discovery is accepted.
    func startAndAccept() async {
        await store.send(.start)
        await settle()
        await advance(to: AutoInterfaceWire.initialPeeringWait)
    }

    func socket(_ event: AutoSocketEvent) async {
        sessions.value.last?.yield(event)
        await settle()
    }

    func discover(_ addr: String, on nic: AutoNIC) async {
        await socket(.datagram(nic: nic.name, plane: .multicastDiscovery, source: addr, sourceScope: nic.index,
                               payload: AutoInterfaceWire.discoveryToken(groupID: AutoInterfaceWire.defaultGroupID,
                                                                         linkLocal: addr)))
    }

    func data(_ payload: Data, from addr: String, on nic: AutoNIC) async {
        await socket(.datagram(nic: nic.name, plane: .data, source: addr, sourceScope: nic.index, payload: payload))
    }

    func count(_ e: Event) -> Int { log.value.filter { $0 == e }.count }
    /// Unicasts to the DATA port (reverse announces go to the discovery port + 1).
    var unicasts: [Event] {
        log.value.filter {
            if case let .unicast(_, _, port, _) = $0 { port == AutoInterfaceWire.defaultDataPort } else { false }
        }
    }

    func finish() async {
        holdStop.setValue(false)
        await store.send(.stop)
        for _ in 0..<200 where store.state.auto.map({ !$0.interface.isIdle }) ?? false { await Task.megaYield() }
        await store.skipReceivedActions(strict: false)
    }
}

private func makeAnnounce(hops: UInt8 = 3) -> (raw: Data, destHash: Data) {
    let identity = Identity()
    let nameHash = Destination.nameHash(appName: "app", aspects: ["svc"])
    let destHash = Destination.hash(identityHash: identity.hash, appName: "app", aspects: ["svc"])
    let randomHash = Announce.randomHash(now: 1000, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: destHash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let packet = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: hops,
                        destinationHash: destHash, transportId: nil, payload: payload)
    return (try! packet.packed(), destHash)
}

/// A parseable header-1 data packet to `destHash`.
private func dataPacket(to destHash: Data) -> Data {
    Data([0x00, 0x00]) + destHash + Data([0x00, 0xEE, 0xEF])
}

// ═════════════════════════════════════════════════════════════════════════════
// Register / deregister
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func autoPeerAddedRegistersItsOwnInterfaceWithTheAutoProfileAndArmsMaintenanceOnce() async {
    let h = AutoEndpointHarness()
    await h.startAndAccept()
    #expect(h.count(.run) == 1, "the endpoint's .start must start the auto slot")

    await h.discover(peerA, on: en0)
    #expect(idA == InterfaceID("auto:en0/fe80::a"))
    #expect(h.store.state.interfaces[idA] == .auto, "the peer registers as its own interface with the auto profile")
    #expect(h.store.state.auto?.peerInterfaces[idA] == AutoEndpoint.AutoPeer(addr: peerA, nic: "en0"))

    await h.discover(peerB, on: en1)
    #expect(h.store.state.interfaces[idB] == .auto)
    #expect(h.store.state.interfaces.count == 2, "the parent is never registered: one interface per peer")
    #expect(h.count(.startMaintenance) == 1, "maintenance arms on the node's first interface only")
    await h.finish()
}

@Test @MainActor func autoPeerEvictionDeregistersFromRouterAndLinkPlaneAndTheLastStopsMaintenance() async {
    let h = AutoEndpointHarness()
    await h.startAndAccept()
    await h.discover(peerA, on: en0)
    #expect(h.store.state.interfaces[idA] != nil)

    // Heard at 1.92 s: evicted at the first peer-job tick past 22 s (24 s).
    await h.advance(to: 26)
    #expect(h.store.state.interfaces[idA] == nil, "an evicted peer leaves the router")
    #expect(h.store.state.auto?.peerInterfaces.isEmpty == true, "and the slot's map")
    #expect(h.count(.disconnected(idA)) == 1)
    #expect(h.count(.linkDisconnected(idA)) == 1, "the link plane hears the departure too")
    #expect(h.count(.stopMaintenance) == 1, "the node's last interface stops maintenance")
    await h.finish()
}

/// Two peers evicted in ONE peer-job tick, and they are the node's only interfaces. Reported one
/// delegate per peer, each container arm still saw the other peer registered and neither stopped the
/// shared loop: it ran on with nothing registered. One batched removal sees both leave together.
@Test @MainActor func twoAutoPeersEvictedInOneTickAsTheLastInterfacesStopMaintenance() async {
    let h = AutoEndpointHarness()
    await h.startAndAccept()
    await h.discover(peerA, on: en0)
    await h.discover(peerB, on: en1)
    #expect(h.store.state.interfaces.count == 2)

    // Both heard at 1.92 s: both evicted at the 24 s tick.
    await h.advance(to: 26)
    #expect(h.store.state.interfaces.isEmpty, "both peers left the router")
    #expect(h.count(.disconnected(idA)) == 1 && h.count(.disconnected(idB)) == 1)
    #expect(h.count(.linkDisconnected(idA)) == 1 && h.count(.linkDisconnected(idB)) == 1)
    #expect(h.count(.stopMaintenance) == 1, "the last interfaces left together: maintenance stops once")
    await h.finish()
}

/// The same burst with a TCP client up: it keeps the shared loop running.
@Test @MainActor func twoAutoPeersEvictedInOneTickWithATCPClientUpKeepMaintenanceRunning() async {
    let h = AutoEndpointHarness(withTCPClient: true)
    await h.startAndAccept()
    h.tcpEvents.continuation.yield(.connected)
    await h.settle()
    await h.discover(peerA, on: en0)
    await h.discover(peerB, on: en1)
    #expect(h.store.state.interfaces.count == 3)

    await h.advance(to: 26)
    #expect(h.store.state.interfaces.count == 1, "only the TCP client remains")
    #expect(h.count(.stopMaintenance) == 0, "a live TCP client keeps the shared loop running")
    await h.finish()
}

/// Both NICs vanish in one tick (D2), each taking its peer: the same single batched removal.
@Test @MainActor func twoNICsVanishingInOneTickWithTheLastPeersStopMaintenance() async {
    let h = AutoEndpointHarness()
    await h.startAndAccept()
    await h.discover(peerA, on: en0)
    await h.discover(peerB, on: en1)
    #expect(h.store.state.interfaces.count == 2)

    h.nics.setValue([])
    await h.advance(to: 4)
    #expect(h.store.state.interfaces.isEmpty, "both peers left with their NICs")
    #expect(h.count(.disconnected(idA)) == 1 && h.count(.disconnected(idB)) == 1)
    #expect(h.count(.stopMaintenance) == 1, "the last interfaces left together: maintenance stops once")
    await h.finish()
}

@Test @MainActor func autoPacketFromAPeerReachesTransportOnThatPeersInterfaceAndAStrangerIsDropped() async {
    let h = AutoEndpointHarness()
    await h.startAndAccept()
    await h.discover(peerA, on: en0)
    await h.discover(peerB, on: en1)

    let packet = dataPacket(to: Data(repeating: 0x11, count: 16))
    await h.data(packet, from: peerB, on: en1)
    #expect(h.count(.received(idB, packet)) == 1, "inbound bytes are tagged with the arriving peer's id")
    #expect(h.count(.received(idA, packet)) == 0)

    // A `packetReceived` for an address the slot never registered is not handed to Transport.
    await h.store.send(.auto(.interface(.delegate(.packetReceived(addr: "fe80::dead", data: packet)))))
    await h.settle()
    #expect(!h.log.value.contains { if case let .received(id, _) = $0 { id.rawValue.contains("dead") } else { false } })
    await h.finish()
}

@Test @MainActor func aStalePeerAddedForAnAddressTheInterfaceDoesNotHoldIsNotRegistered() async {
    let h = AutoEndpointHarness()
    await h.startAndAccept()
    // A peerAdded the interface no longer backs (it was stopped, or never saw the peer): registering
    // it would leave an interface nothing deregisters, and with it the maintenance loop running.
    await h.store.send(.auto(.interface(.delegate(.peerAdded(addr: "fe80::9", nic: "en0")))))
    await h.settle()
    #expect(h.store.state.interfaces.isEmpty)
    #expect(h.store.state.auto?.peerInterfaces.isEmpty == true)
    #expect(h.count(.startMaintenance) == 0)
    await h.finish()
}

// ═════════════════════════════════════════════════════════════════════════════
// Transmit
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func autoTransmitIsIFACMaskedWithSize16AndGoesToTheRightPeer() async throws {
    let h = AutoEndpointHarness(ifac: ("auto-net", "secret"))
    await h.startAndAccept()
    await h.discover(peerA, on: en0)
    await h.discover(peerB, on: en1)
    let ifac = try #require(IFAC(networkName: "auto-net", passphrase: "secret", size: 16))
    #expect(h.store.state.interfaces[idB]?.ifac == ifac, "every peer carries the slot's IFAC at size 16")

    let raw = dataPacket(to: Data(repeating: 0x22, count: 16))
    await h.store.send(.transport(.delegate(.transmit(idB, raw))))
    await h.settle()
    let masked = ifac.protect(raw)
    #expect(masked.count == raw.count + 16)
    #expect(h.unicasts == [.unicast(addr: peerB, index: en1.index, port: AutoInterfaceWire.defaultDataPort,
                                    datagram: masked)],
            "one masked datagram, to peer B's address on its NIC's scope, at the data port")
    #expect(h.log.value.allSatisfy { if case .sendFailed = $0 { false } else { true } })
    await h.finish()
}

@Test @MainActor func autoTransmitToAnEvictedPeersIDReportsSendFailedAndSendsNothing() async {
    let h = AutoEndpointHarness()
    await h.startAndAccept()
    await h.discover(peerA, on: en0)
    await h.advance(to: 26)
    #expect(h.store.state.interfaces[idA] == nil)

    let destHash = Data(repeating: 0x33, count: 16)
    await h.store.send(.transport(.delegate(.transmit(idA, dataPacket(to: destHash)))))
    await h.settle()
    #expect(h.count(.sendFailed(destHash)) == 1, "a stale auto binding surfaces as interfaceUnavailable")
    #expect(h.unicasts.isEmpty)
    await h.finish()
}

// ═════════════════════════════════════════════════════════════════════════════
// Stop and removal
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func autoStopDeregistersEveryPeerOnceAndStopsMaintenanceOnce() async {
    let h = AutoEndpointHarness()
    await h.startAndAccept()
    await h.discover(peerA, on: en0)
    await h.discover(peerB, on: en1)
    #expect(h.store.state.interfaces.count == 2)

    await h.store.send(.stop)
    await h.settle()
    #expect(h.store.state.interfaces.isEmpty, "a stop reports no peerRemoved: the container deregisters from its map")
    #expect(h.store.state.auto?.peerInterfaces.isEmpty == true)
    #expect(h.count(.disconnected(idA)) == 1 && h.count(.disconnected(idB)) == 1)
    #expect(h.count(.linkDisconnected(idA)) == 1 && h.count(.linkDisconnected(idB)) == 1)
    #expect(h.count(.stopMaintenance) == 1)
    #expect(h.count(.stop) == 1, "the driver is stopped")

    // A second stop finds nothing left to report.
    await h.store.send(.auto(.stop))
    await h.settle()
    #expect(h.count(.disconnected(idA)) == 1 && h.count(.stopMaintenance) == 1)
}

@Test @MainActor func removeAutoDeregistersPeersAndClearsTheSlotOnlyAfterTheDriverStopReturns() async {
    let h = AutoEndpointHarness()
    await h.startAndAccept()
    await h.discover(peerA, on: en0)
    h.holdStop.setValue(true)

    await h.store.send(.removeAuto)
    await h.settle()
    #expect(h.store.state.interfaces.isEmpty, "peers are deregistered at once")
    #expect(h.count(.disconnected(idA)) == 1)
    #expect(h.count(.stopMaintenance) == 1)
    #expect(h.store.state.auto != nil, "the slot stays while driver.stop() has not returned")
    #expect(h.store.state.auto?.removalPending == true)
    #expect(h.count(.stop) == 0)

    // A start while the removal is pending must not restart the interface.
    await h.store.send(.start)
    await h.settle()

    h.holdStop.setValue(false)
    for _ in 0..<200 where h.store.state.auto != nil { await Task.megaYield(); await h.store.skipReceivedActions(strict: false) }
    #expect(h.count(.stop) == 1, "driver.stop() ran")
    #expect(h.store.state.auto == nil, "and only then is the slot cleared")
    #expect(h.count(.run) == 1, "the start sent during removal never reached the driver")
    #expect(h.count(.disconnected(idA)) == 1, "nothing is deregistered twice")
}

@Test @MainActor func removeAutoOnAnIdleSlotClearsItAtOnce() async {
    let h = AutoEndpointHarness()
    await h.store.send(.removeAuto)
    await h.settle()
    #expect(h.store.state.auto == nil)
    #expect(h.count(.stop) == 0, "an idle slot has no driver session to stop")
}

// ═════════════════════════════════════════════════════════════════════════════
// Review Focus 5: data port in use
// ═════════════════════════════════════════════════════════════════════════════

@Test @MainActor func dataPortInUseSurfacesOnTheAutoHatchAndTheSlotStillStopsAndRemoves() async {
    let h = AutoEndpointHarness()
    await h.startAndAccept()
    await h.socket(.bindFailed(nic: "en0", plane: .data, errno: EADDRINUSE))
    #expect(h.count(.autoDelegate(.dataPortInUse(nic: "en0"))) == 1,
            "the clash surfaces once on the auto hatch")
    #expect(!h.log.value.contains(.unified),
            "and never on the unified surface")
    #expect(h.store.state.interfaces.isEmpty)

    // The other NIC still peers.
    await h.discover(peerB, on: en1)
    #expect(h.store.state.interfaces[idB] != nil)

    // Stop completes (no hang), and removal clears the slot.
    await h.store.send(.removeAuto)
    for _ in 0..<200 where h.store.state.auto != nil { await Task.megaYield(); await h.store.skipReceivedActions(strict: false) }
    #expect(h.store.state.auto == nil)
    #expect(h.store.state.interfaces.isEmpty)
    #expect(h.count(.stop) == 1)
}

// ═════════════════════════════════════════════════════════════════════════════
// Review Focus 4: whole-slice probe — an auto peer and a TCP client on ONE shared router
// ═════════════════════════════════════════════════════════════════════════════

/// Learns a path over the TCP client, then brings an auto peer up and lets it be evicted. Under the
/// per-driver bug the auto slot's last peer leaving stops the ONE maintenance loop while the TCP
/// client is still up. Proven behaviourally: the expired TCP path is swept by a later tick.
@Test @MainActor func lastAutoPeerLeavingWhileATCPClientIsUpKeepsSharedMaintenanceRunning() async {
    let h = AutoEndpointHarness(withTCPClient: true)
    await h.startAndAccept()
    h.tcpEvents.continuation.yield(.connected)
    await h.settle()
    let (announce, destHash) = makeAnnounce()
    h.tcpEvents.continuation.yield(.data(HDLC.frame(announce)))
    await h.settle()
    #expect(h.store.state.learned[destHash]?.interfaceID == InterfaceID("tcp"))

    await h.discover(peerA, on: en0)
    #expect(h.store.state.interfaces.count == 2)
    await h.advance(to: 26)
    #expect(h.store.state.interfaces[idA] == nil, "the auto peer was evicted")
    #expect(h.store.state.interfaces.count == 1, "the TCP client is still up")
    #expect(h.count(.stopMaintenance) == 0, "a live TCP client keeps the shared loop running")

    h.transportNow.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await h.advance(to: 26 + Transport.maintenanceTickInterval + 1)
    #expect(h.store.state.learned[destHash] == nil, "the loop is alive: the tick sweeps the expired TCP path")
    #expect(h.count(.startMaintenance) == 1, "armed once across both drivers")
    await h.finish()
}

/// The same with the auto slot STOPPED (its bulk deregistration) while the TCP client stays up.
@Test @MainActor func stoppingOnlyTheAutoSlotLeavesSharedMaintenanceRunningForALiveTCPClient() async {
    let h = AutoEndpointHarness(withTCPClient: true)
    await h.startAndAccept()
    h.tcpEvents.continuation.yield(.connected)
    await h.settle()
    let (announce, destHash) = makeAnnounce()
    h.tcpEvents.continuation.yield(.data(HDLC.frame(announce)))
    await h.settle()
    await h.discover(peerA, on: en0)
    await h.discover(peerB, on: en1)
    #expect(h.store.state.interfaces.count == 3)

    await h.store.send(.auto(.stop))
    await h.settle()
    #expect(h.store.state.interfaces.count == 1, "only the TCP client remains")
    #expect(h.count(.stopMaintenance) == 0)

    h.transportNow.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await h.advance(to: Transport.maintenanceTickInterval + 2)
    #expect(h.store.state.learned[destHash] == nil, "the loop is alive: the tick sweeps the expired TCP path")
    await h.finish()
}

/// And the converse: the TCP client dropping while an auto peer is up keeps the loop running, and
/// the auto peer then leaving as the node's last interface stops it.
@Test @MainActor func tcpClientDroppingWhileAnAutoPeerIsUpKeepsMaintenanceAndTheAutoPeerLastStopsIt() async {
    let h = AutoEndpointHarness(withTCPClient: true)
    await h.startAndAccept()
    h.tcpEvents.continuation.yield(.connected)
    await h.settle()
    await h.discover(peerA, on: en0)
    h.tcpEvents.continuation.yield(.disconnected(reason: nil))
    await h.settle()
    #expect(h.store.state.interfaces.keys.sorted { $0.rawValue < $1.rawValue } == [idA])
    #expect(h.count(.stopMaintenance) == 0, "the auto peer is still live")

    await h.advance(to: 26)
    #expect(h.store.state.interfaces.isEmpty)
    #expect(h.count(.stopMaintenance) == 1, "the auto peer was the node's last interface")
    await h.finish()
}
