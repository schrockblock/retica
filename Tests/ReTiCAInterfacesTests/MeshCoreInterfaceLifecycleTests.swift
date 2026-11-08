import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCA
@testable import ReTiCAInterfaces

private let foreignPrefix = Data([0xEE, 0xEE, 0xEE, 0xEE])

@MainActor @Suite struct MeshCoreInterfaceLifecycleTests {
    // MARK: - Lifecycle

    @Test func startHandsTheConfigToTheDriver() async {
        let h = await makeOnlineMeshCoreInterface()
        #expect(h.calls.value == [.start(meshCoreTestConfig)])
        await stopMeshCoreInterface(h)
    }

    @Test func connectedEventReportsOnlineWithItsParams() async {
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        h.radio.yield(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: meshCoreTestParams))
        await h.store.receive {
            $0 == .delegate(.online(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: meshCoreTestParams))
        }
        #expect(h.store.state.params == meshCoreTestParams)
        #expect(h.store.state.status == .online(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey,
                                                params: meshCoreTestParams))
        await stopMeshCoreInterface(h)
    }

    @Test func connectedEventWithNilParamsIsOnline() async {
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        h.radio.yield(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: nil))
        await h.store.receive {
            $0 == .delegate(.online(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: nil))
        }
        #expect(h.store.state.isOnline)
        #expect(h.store.state.params == nil)
        await stopMeshCoreInterface(h)
    }

    @Test func unavailableSurfacesTheCause() async {
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        h.radio.yield(.unavailable(.poweredOff))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(.poweredOff)) }
        await stopMeshCoreInterface(h)
    }

    @Test func noFreeSlotMessageSurfacesVerbatim() async {
        let cause = BLEAdapterUnavailable.other("No free channel slot on this radio")
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        h.radio.yield(.unavailable(cause))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(cause)) }
        #expect(h.store.state.status == .unavailable(cause))
        await stopMeshCoreInterface(h)
    }

    @Test func firmwareTooOldMessageSurfacesVerbatim() async {
        let cause = BLEAdapterUnavailable.other("This radio's firmware is too old; update to v1.15 or later")
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        h.radio.yield(.unavailable(cause))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(cause)) }
        #expect(h.store.state.status == .unavailable(cause))
        await stopMeshCoreInterface(h)
    }

    /// After `.unavailable(.poweredOff)` a `.disconnected(nil)` (the session retrying) means the
    /// adapter is back: status is `.connecting`, and a `.start` must not restart the driver.
    @Test func aReconnectAttemptAfterUnavailableIsConnectingAndBlocksStart() async {
        let h = await makeOnlineMeshCoreInterface()
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .driverEvent(.disconnected(reason: nil)) }
        h.radio.yield(.unavailable(.poweredOff))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(.poweredOff)) }
        #expect(h.store.state.status == .unavailable(.poweredOff))
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .driverEvent(.disconnected(reason: nil)) }
        #expect(h.store.state.status == .connecting)
        let startsBefore = h.calls.value.meshCoreStartCount
        await h.store.send(.start)
        #expect(h.calls.value.meshCoreStartCount == startsBefore)
        await stopMeshCoreInterface(h)
    }

    @Test func unavailableWhileOnlineReportsOffline() async {
        let h = await makeOnlineMeshCoreInterface()
        h.radio.yield(.unavailable(.unauthorized))
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await stopMeshCoreInterface(h)
    }

    @Test func stopStopsTheDriver() async {
        let h = await makeOnlineMeshCoreInterface()
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await Task.megaYield()
        #expect(h.calls.value.contains(.stop))
    }

    /// Contract 3: the host sends `.stop` and WAITS for offline, so a radio that never came
    /// online must report it too.
    @Test func stopWhileConnectingReportsOffline() async {
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
    }

    @Test func startDuringASlowStopReachesTheDriverAfterTheStop() async {
        let h = await makeSlowStopMeshCoreInterface()
        await h.store.send(.stop)
        await h.store.send(.start)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        await h.waitForStarts(2)
        #expect(h.calls.value.last == .start(meshCoreTestConfig), "driver calls: \(h.calls.value)")
        await h.shutdown()
    }

    @Test func startDuringASlowStopBringsTheRadioOnline() async {
        let h = await makeSlowStopMeshCoreInterface()
        await h.store.send(.stop)
        await h.store.send(.start)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        await h.waitForStarts(2)
        h.yieldToLatest(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: nil))
        await h.store.receive {
            $0 == .delegate(.online(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: nil))
        }
        #expect(h.store.state.isOnline)
        await h.shutdown()
    }

    @Test func stopCancelsAStartDeferredBehindASlowStop() async {
        let h = await makeSlowStopMeshCoreInterface()
        await h.store.send(.stop)
        await h.store.send(.start)
        await h.store.send(.stop)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        await Task.megaYield()
        #expect(h.calls.value.meshCoreStartCount == 1, "driver calls: \(h.calls.value)")
        #expect(h.store.state.status == .stopped)
    }

    @Test func eventsAfterStopAreIgnored() async {
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.send(.driverEvent(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey,
                                                   params: nil)))
        await Task.megaYield()
        #expect(h.store.state.status == .stopped)
        #expect(!h.delegates.value.contains { if case .online = $0 { return true }; return false })
    }

    @Test func disconnectReportsOfflineWithTheReason() async {
        let h = await makeOnlineMeshCoreInterface()
        h.radio.yield(.disconnected(reason: "link lost"))
        await h.store.receive { $0 == .delegate(.offline(reason: "link lost")) }
        await stopMeshCoreInterface(h)
    }

    @Test func disconnectDiscardsPartialReassembly() async {
        let h = await makeOnlineMeshCoreInterface()
        let datagrams = meshCoreDatagrams(meshCorePattern(200, seed: 2))
        h.radio.yield(.datagram(datagrams[0]))
        h.radio.yield(.disconnected(reason: nil))
        h.radio.yield(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: nil))
        h.radio.yield(.datagram(datagrams[1]))
        await h.store.receive { $0 == .driverEvent(.datagram(datagrams[1])) }
        // Only the second fragment is buffered: the first went with the drop.
        #expect(h.store.state.reassembler.bufferCount == 1)
        #expect(h.store.state.reassembler.counters.completed == 0)
        await stopMeshCoreInterface(h)
    }

    @Test func limiterSurvivesADisconnect() async {
        var initial = MeshCoreInterface.State(config: meshCoreTestConfig)
        _ = initial.limiter.admit(unmasked: limiterAnnounce(hops: 0), now: Date(timeIntervalSince1970: 1_000))
        _ = initial.limiter.admit(unmasked: limiterAnnounce(hops: 3), now: Date(timeIntervalSince1970: 1_000))
        let seeded = initial.limiter
        let h = await makeOnlineMeshCoreInterface(initial: initial)
        h.radio.yield(.disconnected(reason: nil))
        await h.store.receive { $0 == .driverEvent(.disconnected(reason: nil)) }
        #expect(h.store.state.limiter == seeded)
        #expect(h.store.state.limiter != MeshCoreAnnounceLimiter())
        await stopMeshCoreInterface(h)
    }

    // MARK: - Receive rules (§5.2)

    @Test func datagramBeforeTheRadioIsOnlineIsDropped() async {
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        let datagrams = meshCoreDatagrams(meshCorePattern(200, seed: 1))
        h.radio.yield(.datagram(datagrams[0]))
        h.radio.yield(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: nil))
        h.radio.yield(.datagram(datagrams[1]))
        await h.store.receive { $0 == .driverEvent(.datagram(datagrams[1])) }
        // The early fragment reached no rule: nothing counted, nothing completed.
        #expect(h.store.state.diagnostics == MeshCoreCounters())
        #expect(h.store.state.reassembler.bufferCount == 1)
        #expect(h.packets.isEmpty)
        await stopMeshCoreInterface(h)
    }

    @Test func peerDatagramsReassembleIntoOnePacket() async {
        let h = await makeOnlineMeshCoreInterface()
        let packet = meshCorePattern(500, seed: 9)
        let datagrams = meshCoreDatagrams(packet)
        #expect(datagrams.count == 4)
        for datagram in datagrams { h.radio.yield(.datagram(datagram)) }
        await h.store.receive { $0 == .delegate(.packetReceived(packet)) }
        #expect(h.packets == [packet])
        await stopMeshCoreInterface(h)
    }

    @Test func malformedDatagramIncrementsMalformed() async {
        let h = await makeOnlineMeshCoreInterface()
        let bytes = Data([0x52, 0x00, 0x01])
        h.radio.yield(.datagram(bytes))
        await h.store.receive { $0 == .driverEvent(.datagram(bytes)) }
        #expect(h.store.state.reassembler.counters.malformed == 1)
        await stopMeshCoreInterface(h)
    }

    @Test func ownDatagramIsDropped() async {
        let h = await makeOnlineMeshCoreInterface()
        let packet = meshCorePattern(30, seed: 3)
        h.radio.yield(.datagram(meshCoreDatagrams(packet, src: meshCoreOwnPrefix)[0]))
        await h.flush()
        #expect(h.packets == [meshCoreSentinelPacket])
        #expect(h.store.state.diagnostics.notAddressed == 0)
        await stopMeshCoreInterface(h)
    }

    @Test func datagramForAnotherPrefixCountsNotAddressed() async {
        let h = await makeOnlineMeshCoreInterface()
        let packet = meshCorePattern(30, seed: 4)
        h.radio.yield(.datagram(meshCoreDatagrams(packet, dst: foreignPrefix)[0]))
        await h.flush()
        #expect(h.store.state.diagnostics.notAddressed == 1)
        #expect(h.packets == [meshCoreSentinelPacket])
        await stopMeshCoreInterface(h)
    }

    @Test func datagramAddressedToOurPrefixIsDelivered() async {
        let h = await makeOnlineMeshCoreInterface()
        let packet = meshCorePattern(30, seed: 5)
        h.radio.yield(.datagram(meshCoreDatagrams(packet, dst: meshCoreOwnPrefix)[0]))
        await h.store.receive { $0 == .delegate(.packetReceived(packet)) }
        #expect(h.store.state.diagnostics.notAddressed == 0)
        await stopMeshCoreInterface(h)
    }

    @Test func broadcastDatagramIsDelivered() async {
        let h = await makeOnlineMeshCoreInterface()
        let packet = meshCorePattern(30, seed: 6)
        h.radio.yield(.datagram(meshCoreDatagrams(packet, dst: ScotMeshRawCodec.broadcast)[0]))
        await h.store.receive { $0 == .delegate(.packetReceived(packet)) }
        #expect(h.store.state.diagnostics.notAddressed == 0)
        await stopMeshCoreInterface(h)
    }

    @Test func bindFrameIsIgnored() async {
        let h = await makeOnlineMeshCoreInterface()
        h.radio.yield(.datagram(meshCoreDatagrams(meshCoreOwnKey, type: .bind)[0]))
        await h.flush()
        await Task.megaYield()
        #expect(h.packets == [meshCoreSentinelPacket])
        #expect(h.calls.value.meshCoreSentDatagrams.isEmpty)
        await stopMeshCoreInterface(h)
    }

    @Test func unknownTypeIsIgnored() async {
        let h = await makeOnlineMeshCoreInterface()
        h.radio.yield(.datagram(meshCoreDatagrams(meshCorePattern(30, seed: 7), type: .other(3))[0]))
        await h.flush()
        await Task.megaYield()
        #expect(h.packets == [meshCoreSentinelPacket])
        #expect(h.calls.value.meshCoreSentDatagrams.isEmpty)
        await stopMeshCoreInterface(h)
    }

    @Test func malformedComesBeforeTheAddressCheck() async {
        let h = await makeOnlineMeshCoreInterface()
        var bytes = meshCoreDatagrams(meshCorePattern(30, seed: 8), dst: foreignPrefix)[0]
        bytes[0] = 0x53
        h.radio.yield(.datagram(bytes))
        await h.store.receive { $0 == .driverEvent(.datagram(bytes)) }
        #expect(h.store.state.diagnostics.malformed == 1)
        #expect(h.store.state.diagnostics.notAddressed == 0)
        await stopMeshCoreInterface(h)
    }

    @Test func addressCheckComesBeforeReassembly() async {
        let h = await makeOnlineMeshCoreInterface()
        let first = meshCoreDatagrams(meshCorePattern(200, seed: 10), dst: foreignPrefix)[0]
        h.radio.yield(.datagram(first))
        await h.store.receive { $0 == .driverEvent(.datagram(first)) }
        #expect(h.store.state.reassembler.bufferCount == 0)
        await stopMeshCoreInterface(h)
    }

    // MARK: - Diagnostics

    @Test func diagnosticsCarryEveryCounter() {
        var state = MeshCoreInterface.State(config: meshCoreTestConfig)
        let t0 = Date(timeIntervalSince1970: 1_000)
        state.reassembler.recordMalformed()                                            // malformed 1
        for id: UInt16 in 1...2 {                                                      // completed 2
            state.reassembler.receive(src: Data([2, 2, 2, 2]), packetID: id, index: 0, total: 1,
                                      body: Data(repeating: 1, count: 10), now: t0)
        }
        for id: UInt16 in 1...3 {                                                      // oversize 3
            state.reassembler.receive(src: Data([3, 3, 3, 3]), packetID: id, index: 0, total: 2,
                                      body: Data(repeating: 1, count: 509), now: t0)
        }
        for id: UInt16 in 1...12 {                                                     // evicted 4
            state.reassembler.receive(src: Data([1, 1, 1, 1]), packetID: id, index: 0, total: 2,
                                      body: Data([1]), now: t0)
        }
        state.reassembler.receive(src: Data([4, 4, 4, 4]), packetID: 1, index: 0, total: 2,  // timedOut 8
                                  body: Data([1]), now: t0.addingTimeInterval(60))
        state.counters.notAddressed = 5
        state.counters.queueFull = 6
        state.counters.sendFailed = 7
        for _ in 0..<9 {                                                               // announcesLimited 9
            _ = state.limiter.admit(unmasked: limiterAnnounce(hops: 3), now: t0)
        }
        _ = state.limiter.admit(unmasked: limiterPathRequest(), now: t0)
        for second in 61...70 {                                                        // pathRequestsLimited 10
            _ = state.limiter.admit(unmasked: limiterPathRequest(), now: t0.addingTimeInterval(TimeInterval(second)))
        }
        #expect(state.diagnostics == MeshCoreCounters(
            malformed: 1, notAddressed: 5, evicted: 4, timedOut: 8, oversize: 3, completed: 2,
            queueFull: 6, sendFailed: 7, announcesLimited: 9, pathRequestsLimited: 10))
    }

    // MARK: - Retired channels

    @Test func retiredChannelsClearedSurfacesWhileConnecting() async {
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        h.radio.yield(.retiredChannelsCleared)
        await h.store.receive { $0 == .delegate(.retiredChannelsCleared) }
        #expect(h.store.state.status == .connecting)
        await stopMeshCoreInterface(h)
    }

    @Test func retiredChannelsClearedIsIgnoredAfterStop() async {
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.send(.driverEvent(.retiredChannelsCleared))
        await Task.megaYield()
        #expect(!h.delegates.value.contains(.retiredChannelsCleared))
    }

    // MARK: - Channel removal

    @Test func removeChannelCallsTheDriverOnce() async {
        let h = await makeOnlineMeshCoreInterface()
        await h.store.send(.removeChannel)
        await h.store.receive { $0 == .delegate(.channelRemoved(true)) }
        #expect(h.calls.value.filter { $0 == .removeChannel }.count == 1)
        await stopMeshCoreInterface(h)
    }

    @Test func channelRemovedReportsTheDriverResult() async {
        for result in [true, false] {
            let h = makeMeshCoreInterface(removeResult: result)
            await h.store.send(.start)
            h.radio.yield(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: nil))
            await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
            await h.store.send(.removeChannel)
            await h.store.receive { $0 == .delegate(.channelRemoved(result)) }
            #expect(h.delegates.value.contains(.channelRemoved(result)))
            await stopMeshCoreInterface(h)
        }
    }

    @Test func removeChannelWhileOfflineReportsFalseWithoutCallingTheDriver() async {
        let h = makeMeshCoreInterface()
        await h.store.send(.start)
        await h.store.send(.removeChannel)
        await h.store.receive { $0 == .delegate(.channelRemoved(false)) }
        await Task.megaYield()
        #expect(!h.calls.value.contains(.removeChannel))
        await stopMeshCoreInterface(h)
    }

    @Test func secondRemoveChannelDuringARemovalDoesNotCallTheDriverAgain() async {
        let h = await makeSlowRemovalMeshCoreInterface(holdStops: false)
        await h.store.send(.removeChannel)
        await h.waitForCall(.removeChannel)
        await h.store.send(.removeChannel)
        h.releaseRemoval()
        await h.store.receive { $0 == .delegate(.channelRemoved(true)) }
        for _ in 0..<10 { await Task.megaYield() }
        #expect(h.calls.value.filter { $0 == .removeChannel }.count == 1, "driver calls: \(h.calls.value)")
        await h.shutdown()
    }

    /// Review Focus 5: the feature is turned off and `.stop` lands while `removeChannel` runs.
    @Test func stopDuringARemovalWaitsForTheRemovalToFinish() async {
        let h = await makeSlowRemovalMeshCoreInterface(holdStops: true)
        await h.store.send(.removeChannel)
        await h.waitForCall(.removeChannel)
        await h.store.send(.stop)
        for _ in 0..<10 { await Task.megaYield() }
        #expect(h.calls.value == [.start(meshCoreTestConfig), .removeChannel], "held: \(h.calls.value)")
        #expect(!h.store.state.isIdle)
        h.releaseRemoval()
        await h.store.receive { $0 == .delegate(.channelRemoved(true)) }
        await h.store.receive { $0 == .stop }
        await h.waitForCall(.stop)
        #expect(h.calls.value == [.start(meshCoreTestConfig), .removeChannel, .stop])
        #expect(!h.store.state.isIdle)
        h.releaseStop()
        await h.store.receive { $0 == .driverStopped }
        #expect(h.store.state.isIdle)
    }

    /// Review Focus 5: offline comes last, so the host can't nil the slot under a running removal.
    @Test func channelRemovedPrecedesOfflineWhenStoppedDuringARemoval() async {
        let h = await makeSlowRemovalMeshCoreInterface(holdStops: false)
        await h.store.send(.removeChannel)
        await h.waitForCall(.removeChannel)
        await h.store.send(.stop)
        for _ in 0..<10 { await Task.megaYield() }
        h.releaseRemoval()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        let order = h.delegates.value.compactMap { delegate -> String? in
            switch delegate {
            case .channelRemoved: return "channelRemoved"
            case .offline: return "offline"
            default: return nil
            }
        }
        #expect(order == ["channelRemoved", "offline"])
    }

    /// Feature off then on while `removeChannel` runs: the start reaches the driver after the
    /// held stop, never lost to the still-online status.
    @Test func startAfterAHeldStopRestartsTheDriver() async {
        let h = await makeSlowRemovalMeshCoreInterface(holdStops: false)
        await h.store.send(.removeChannel)
        await h.waitForCall(.removeChannel)
        await h.store.send(.stop)
        await h.store.send(.start)
        h.releaseRemoval()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.waitForStarts(2)
        #expect(h.calls.value == [.start(meshCoreTestConfig), .removeChannel, .stop, .start(meshCoreTestConfig)],
                "driver calls: \(h.calls.value)")
        await h.shutdown()
    }

    @Test func stopStartStopDuringARemovalEndsStopped() async {
        let h = await makeSlowRemovalMeshCoreInterface(holdStops: false)
        await h.store.send(.removeChannel)
        await h.waitForCall(.removeChannel)
        await h.store.send(.stop)
        await h.store.send(.start)
        await h.store.send(.stop)
        h.releaseRemoval()
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        for _ in 0..<50 { await Task.megaYield() }
        await h.store.skipReceivedActions(strict: false)
        #expect(h.calls.value == [.start(meshCoreTestConfig), .removeChannel, .stop], "driver calls: \(h.calls.value)")
        #expect(h.store.state.isIdle)
    }

    /// The radio went `.unavailable` during the removal, so `.start` would otherwise launch the
    /// driver at once, only for the held stop to tear it down.
    @Test func startDuringAHeldStopWhileUnavailableDoesNotLaunchTheDriverEarly() async {
        let h = await makeSlowRemovalMeshCoreInterface(holdStops: false)
        await h.store.send(.removeChannel)
        await h.waitForCall(.removeChannel)
        h.yieldToLatest(.unavailable(.poweredOff))
        await h.store.receive { $0 == .delegate(.adapterUnavailable(.poweredOff)) }
        await h.store.send(.stop)
        await h.store.send(.start)
        for _ in 0..<10 { await Task.megaYield() }
        #expect(h.startCount == 1, "driver calls while the stop is held: \(h.calls.value)")
        await h.shutdown()
    }
}

// MARK: - Packets for the limiter

private func limiterAnnounce(hops: UInt8) -> Data {
    try! Packet(
        headerType: .header1, packetType: .announce, transportType: .broadcast, destinationType: .single,
        context: .none, hops: hops, destinationHash: Data(repeating: 0xD1, count: 16), transportId: nil,
        payload: Data(repeating: 0xA5, count: 40)
    ).packed()
}

private func limiterPathRequest() -> Data {
    try! Packet(
        packetType: .data, destinationType: .plain, destinationHash: Data(repeating: 0xC7, count: 16),
        payload: Data(repeating: 0xD2, count: 16) + Data(repeating: 0x7A, count: 16)
    ).packed()
}

// MARK: - Slow-stop harness

/// A mock radio modelled on the live adapter: every `start` opens a FRESH session stream, and
/// `stop` blocks until released, then tears down whichever session is current at that moment.
@MainActor
private struct SlowStopMeshCoreHarness {
    let store: TestStore<MeshCoreInterface.State, MeshCoreInterface.Action>
    let calls: LockIsolated<[MeshCoreMockCall]>
    let sessions: LockIsolated<[AsyncStream<MeshCoreDriverEvent>.Continuation]>
    let released: LockIsolated<Bool>

    func releaseStop() { released.setValue(true) }

    func yieldToLatest(_ event: MeshCoreDriverEvent) {
        sessions.value.last?.yield(event)
    }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<100 where sessions.value.count < count { await Task.megaYield() }
    }

    func shutdown() async {
        released.setValue(true)
        await store.send(.stop)
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
}

/// Started and online; the next `stop` waits for `releaseStop()`.
@MainActor
private func makeSlowStopMeshCoreInterface() async -> SlowStopMeshCoreHarness {
    let calls = LockIsolated<[MeshCoreMockCall]>([])
    let sessions = LockIsolated<[AsyncStream<MeshCoreDriverEvent>.Continuation]>([])
    let released = LockIsolated(false)
    let store = TestStore(initialState: MeshCoreInterface.State(config: meshCoreTestConfig)) {
        MeshCoreInterface()
    } withDependencies: {
        $0.meshCoreDriver = MeshCoreDriver(
            start: { config in
                let session = AsyncStream<MeshCoreDriverEvent>.makeStream()
                calls.withValue { $0.append(.start(config)) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { _ in true },
            removeChannel: { true },
            stop: {
                while !released.value { await Task.yield() }
                sessions.value.last?.finish()
                calls.withValue { $0.append(.stop) }
            }
        )
        $0.meshCoreClock = TestClock<Duration>()
        $0.meshCoreDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
    }
    store.exhaustivity = .off
    store.timeout = .seconds(5)
    await store.send(.start)
    for _ in 0..<200 where sessions.value.isEmpty { await Task.megaYield() }
    sessions.value.last?.yield(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: nil))
    await store.receive { if case .delegate(.online) = $0 { return true }; return false }
    return SlowStopMeshCoreHarness(store: store, calls: calls, sessions: sessions, released: released)
}

// MARK: - Slow-removal harness

/// `removeChannel` blocks until `releaseRemoval()`. `stop` records `.stop` when CALLED, then (with
/// `holdStops`) blocks until `releaseStop()`, so a test sees exactly when the driver was asked.
@MainActor
private struct SlowRemovalMeshCoreHarness {
    let store: TestStore<MeshCoreInterface.State, MeshCoreInterface.Action>
    let calls: LockIsolated<[MeshCoreMockCall]>
    let delegates: LockIsolated<[MeshCoreInterface.Action.Delegate]>
    /// One FRESH session per `start`; `stop` ends the latest.
    let sessions: LockIsolated<[AsyncStream<MeshCoreDriverEvent>.Continuation]>
    let removalHeld: LockIsolated<Bool>
    let stopHeld: LockIsolated<Bool>

    var startCount: Int { calls.value.meshCoreStartCount }

    func releaseRemoval() { removalHeld.setValue(false) }
    func releaseStop() { stopHeld.setValue(false) }

    func yieldToLatest(_ event: MeshCoreDriverEvent) { sessions.value.last?.yield(event) }

    func waitForStarts(_ count: Int) async {
        for _ in 0..<200 where startCount < count { await Task.megaYield() }
    }

    func waitForCall(_ call: MeshCoreMockCall) async {
        for _ in 0..<200 where !calls.value.contains(call) { await Task.megaYield() }
    }

    func shutdown() async {
        removalHeld.setValue(false)
        stopHeld.setValue(false)
        await store.send(.stop)
        await Task.megaYield()
        await store.skipReceivedActions(strict: false)
    }
}

/// Started and online over a radio whose `removeChannel` returns true once released.
@MainActor
private func makeSlowRemovalMeshCoreInterface(holdStops: Bool) async -> SlowRemovalMeshCoreHarness {
    let calls = LockIsolated<[MeshCoreMockCall]>([])
    let delegates = LockIsolated<[MeshCoreInterface.Action.Delegate]>([])
    let removalHeld = LockIsolated(true)
    let stopHeld = LockIsolated(holdStops)
    let sessions = LockIsolated<[AsyncStream<MeshCoreDriverEvent>.Continuation]>([])
    let store = TestStore(initialState: MeshCoreInterface.State(config: meshCoreTestConfig)) {
        MeshCoreDelegateRecorder(delegates: delegates)
    } withDependencies: {
        $0.meshCoreDriver = MeshCoreDriver(
            start: { config in
                let session = AsyncStream<MeshCoreDriverEvent>.makeStream()
                calls.withValue { $0.append(.start(config)) }
                sessions.withValue { $0.append(session.continuation) }
                return session.stream
            },
            send: { _ in true },
            removeChannel: {
                calls.withValue { $0.append(.removeChannel) }
                while removalHeld.value { await Task.yield() }
                return true
            },
            stop: {
                calls.withValue { $0.append(.stop) }
                while stopHeld.value { await Task.yield() }
                sessions.value.last?.finish()
            }
        )
        $0.meshCoreClock = TestClock<Duration>()
        $0.meshCoreDate = DateGenerator { Date(timeIntervalSince1970: 1_000) }
    }
    store.exhaustivity = .off
    store.timeout = .seconds(5)
    await store.send(.start)
    for _ in 0..<200 where sessions.value.isEmpty { await Task.megaYield() }
    sessions.value.last?.yield(.connected(selfPrefix: meshCoreOwnPrefix, publicKey: meshCoreOwnKey, params: nil))
    await store.receive { if case .delegate(.online) = $0 { return true }; return false }
    return SlowRemovalMeshCoreHarness(store: store, calls: calls, delegates: delegates,
                                      sessions: sessions, removalHeld: removalHeld, stopHeld: stopHeld)
}
