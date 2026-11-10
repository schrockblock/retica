import Testing
import Foundation
@testable import ReTiCAInterfaces

#if canImport(Darwin)
import Darwin

// Real-socket tests for the LIVE `AutoInterfaceDriver` (spec 2026-11-10-autointerface §7.3). The
// reducer tests drive a mock driver, which replaces exactly the layer these guard: the socket table
// (§4.4), the `inet_ntop` source text and scope the token check depends on (§4.3), and the
// generation guard that keeps a superseded socket's datagram out of the current stream (§5.3.4).
//
// Everything runs on `lo0` (`fe80::1`, index 1), which carries link-local unicast and multicast with
// loopback. A NomadNet on this Mac holds the default ports 29716/29717/42671 on en0, so every test
// uses its own non-default ports and a test-only group id.
@Suite(.serialized)
struct AutoInterfaceDriverLiveTests {

    private static let loopbackAddress = "fe80::1"
    private static let loopbackIndex: UInt32 = 1
    private static let groupID = Data("retica-driver-live-test".utf8)

    private func binding(discoveryPort: UInt16, dataPort: UInt16) -> AutoBinding {
        AutoBinding(
            nic: "lo0", index: Self.loopbackIndex, linkLocal: Self.loopbackAddress,
            group: AutoInterfaceWire.groupAddress(groupID: Self.groupID, scope: .link, type: .temporary),
            linkScope: true, discoveryPort: discoveryPort, dataPort: dataPort)
    }

    private func datagram(_ plane: AutoPlane, _ payload: Data) -> AutoSocketEvent {
        .datagram(nic: "lo0", plane: plane, source: Self.loopbackAddress,
                  sourceScope: Self.loopbackIndex, payload: payload)
    }

    // 0. `interfaces()` reports lo0 raw: its index and its `fe80::1` link-local in inet_ntop text.
    @Test func interfacesListsLoopbackLinkLocal() {
        let nics = AutoInterfaceDriver.liveValue.interfaces()
        let lo0 = nics.first { $0.name == "lo0" }
        #expect(lo0?.index == Self.loopbackIndex)
        #expect(lo0?.linkLocals.contains(Self.loopbackAddress) == true)
        #expect(nics.allSatisfy { nic in nic.linkLocals.allSatisfy { $0.hasPrefix("fe80:") } })
    }

    // 1. Bind the trio, then a token sent to the group comes back on the multicast discovery socket
    //    and a unicast token on the unicast discovery socket, each with `source == "fe80::1"` and
    //    `sourceScope == 1` (§4.3.2, the exact text the token is derived from).
    @Test func bindsTrioAndRoundTripsDiscoveryTokens() async throws {
        let driver = AutoInterfaceDriver.liveValue
        let b = binding(discoveryPort: 39_716, dataPort: 52_671)
        let log = EventLog(driver.run([b]))
        defer { Task { await driver.stop() } }

        #expect(await log.waitFor { $0.contains(.bound(nic: "lo0")) }, "trio never bound: \(log.snapshot())")
        #expect(!log.snapshot().contains { if case .bindFailed = $0 { return true } else { return false } })

        let token = AutoInterfaceWire.discoveryToken(groupID: Self.groupID, linkLocal: Self.loopbackAddress)
        #expect(await driver.sendMulticast("lo0", token, b.discoveryPort) == .sent)
        #expect(await log.waitFor { $0.contains(datagram(.multicastDiscovery, token)) },
                "multicast token not looped back: \(log.snapshot())")

        let echo = Data(token.reversed())
        #expect(await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.discoveryPort + 1, echo) == .sent)
        #expect(await log.waitFor { $0.contains(datagram(.unicastDiscovery, echo)) },
                "unicast token not received: \(log.snapshot())")
    }

    // 2. A 1200-byte raw packet crosses the data plane as exactly one datagram (§4.8.1).
    @Test func dataDatagramOf1200BytesRoundTrips() async throws {
        let driver = AutoInterfaceDriver.liveValue
        let b = binding(discoveryPort: 39_726, dataPort: 52_681)
        let log = EventLog(driver.run([b]))
        defer { Task { await driver.stop() } }
        #expect(await log.waitFor { $0.contains(.bound(nic: "lo0")) }, "trio never bound: \(log.snapshot())")

        let payload = Data((0..<1200).map { UInt8(truncatingIfNeeded: $0 &* 7 &+ 3) })
        #expect(await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, payload) == .sent)
        #expect(await log.waitFor { $0.contains(datagram(.data, payload)) }, "data not received: \(log.snapshot())")
    }

    // 3. A datagram read by the socket that `rebind` replaced must never surface, even when its
    //    delivery reaches the actor after the rebind. The gate holds the first delivery (already
    //    read and stamped with the old generation) until the rebind has completed.
    @Test func rebindDropsEventsReadBeforeTheRebind() async throws {
        let gate = HoldFirst()
        let driver = AutoInterfaceDriver.live(deliveryGate: { await gate.pass() })
        let b = binding(discoveryPort: 39_736, dataPort: 52_691)
        let log = EventLog(driver.run([b]))
        defer { Task { await driver.stop() } }
        #expect(await log.waitFor { $0.contains(.bound(nic: "lo0")) }, "trio never bound: \(log.snapshot())")

        let stale = Data("pre-rebind".utf8)
        #expect(await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, stale) == .sent)
        #expect(await poll { await gate.didHold() }, "the old socket never read the stale datagram")

        await driver.rebind(b)
        #expect(await log.waitFor { $0.filter { $0 == .bound(nic: "lo0") }.count == 2 },
                "rebind did not rebind: \(log.snapshot())")
        await gate.release()

        let fresh = Data("post-rebind".utf8)
        #expect(await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, fresh) == .sent)
        #expect(await log.waitFor { $0.contains(datagram(.data, fresh)) }, "rebound socket silent: \(log.snapshot())")
        try await Task.sleep(for: .milliseconds(300))
        // Matched on payload alone, so no other field of the event can hide a stale delivery.
        let surfaced = log.snapshot().contains {
            if case let .datagram(_, _, _, _, payload) = $0 { return payload == stale } else { return false }
        }
        #expect(!surfaced, "stale datagram surfaced: \(log.snapshot())")
    }

    // 4. Same host, same data port: the second data bind fails `EADDRINUSE` (§4.10.2) because the data
    //    socket sets no reuse options, while both discovery sockets coexist (SO_REUSEPORT).
    @Test func secondDataBindOnSamePortReportsAddressInUse() async throws {
        let first = AutoInterfaceDriver.liveValue
        let second = AutoInterfaceDriver.liveValue
        let b = binding(discoveryPort: 39_746, dataPort: 52_701)
        let firstLog = EventLog(first.run([b]))
        defer { Task { await first.stop() } }
        #expect(await firstLog.waitFor { $0.contains(.bound(nic: "lo0")) }, "first never bound: \(firstLog.snapshot())")

        let secondLog = EventLog(second.run([b]))
        defer { Task { await second.stop() } }
        #expect(await secondLog.waitFor { $0.contains(.bindFailed(nic: "lo0", plane: .data, errno: EADDRINUSE)) },
                "second data bind did not fail EADDRINUSE: \(secondLog.snapshot())")
        try await Task.sleep(for: .milliseconds(100))
        let failures = secondLog.snapshot().filter { if case .bindFailed = $0 { return true } else { return false } }
        #expect(failures == [.bindFailed(nic: "lo0", plane: .data, errno: EADDRINUSE)])
        #expect(!secondLog.snapshot().contains(.bound(nic: "lo0")))
    }

    // 5. `stop` ends the stream and releases the sockets: nothing surfaces afterwards and the NIC's
    //    multicast sender is gone.
    @Test func stopEndsTheStreamAndSilencesTheSockets() async throws {
        let driver = AutoInterfaceDriver.liveValue
        let b = binding(discoveryPort: 39_756, dataPort: 52_711)
        let log = EventLog(driver.run([b]))
        #expect(await log.waitFor { $0.contains(.bound(nic: "lo0")) }, "trio never bound: \(log.snapshot())")
        let before = Data("before-stop".utf8)
        #expect(await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, before) == .sent)
        #expect(await log.waitFor { $0.contains(datagram(.data, before)) })

        await driver.stop()
        #expect(await poll { log.isFinished }, "stream not finished by stop")
        let count = log.snapshot().count
        // Outside a session a unicast send must not reopen (and so leak) the shared sender.
        #expect(await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, Data("after-stop".utf8))
                == .failed(errno: ENXIO))
        #expect(await driver.sendMulticast("lo0", Data(repeating: 1, count: 32), b.discoveryPort) != .sent)
        try await Task.sleep(for: .milliseconds(200))
        #expect(log.snapshot().count == count, "events after stop: \(log.snapshot())")

        // The data port is free again: a fresh driver binds it.
        let next = AutoInterfaceDriver.liveValue
        let nextLog = EventLog(next.run([b]))
        defer { Task { await next.stop() } }
        #expect(await nextLog.waitFor { $0.contains(.bound(nic: "lo0")) }, "port not released: \(nextLog.snapshot())")
    }

    // 6. Two back-to-back `run`s whose starts reach the actor out of order: the first (stale) start
    //    is held until the second session has bound. The stale start must finish only its own stream;
    //    the second session stays bound, unfinished and receiving.
    @Test func staleStartDoesNotTearDownTheSessionThatSupersededIt() async throws {
        let gate = HoldFirst()
        let driver = AutoInterfaceDriver.live(deliveryGate: nil, startGate: { await gate.pass() })
        let b = binding(discoveryPort: 39_766, dataPort: 52_721)
        let first = EventLog(driver.run([b]))
        #expect(await poll { await gate.didHold() }, "first start never reached the gate")
        let second = EventLog(driver.run([b]))
        defer { Task { await driver.stop() } }
        #expect(await second.waitFor { $0.contains(.bound(nic: "lo0")) }, "second never bound: \(second.snapshot())")

        await gate.release()
        #expect(await poll { first.isFinished }, "stale first stream not finished")
        try await Task.sleep(for: .milliseconds(200))
        #expect(first.snapshot().isEmpty, "stale session surfaced events: \(first.snapshot())")
        #expect(!second.isFinished, "the stale start finished the live session")

        let payload = Data("after-stale-start".utf8)
        #expect(await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, payload) == .sent)
        #expect(await second.waitFor { $0.contains(datagram(.data, payload)) },
                "live session lost its sockets: \(second.snapshot())")
    }

    // 7. `run` then `stop` before the run's start reaches the actor: the stream finishes and nothing
    //    binds (no `.bound`, no NIC entry, the data port free).
    @Test func stopBeforeTheStartReachesTheActorBindsNothing() async throws {
        let gate = HoldFirst()
        let driver = AutoInterfaceDriver.live(deliveryGate: nil, startGate: { await gate.pass() })
        let b = binding(discoveryPort: 39_776, dataPort: 52_731)
        let log = EventLog(driver.run([b]))
        #expect(await poll { await gate.didHold() }, "start never reached the gate")
        await driver.stop()
        await gate.release()

        #expect(await poll { log.isFinished }, "stream not finished: \(log.snapshot())")
        try await Task.sleep(for: .milliseconds(200))
        #expect(!log.snapshot().contains(.bound(nic: "lo0")), "bound after stop: \(log.snapshot())")
        #expect(await driver.sendMulticast("lo0", Data(repeating: 2, count: 32), b.discoveryPort) == .failed(errno: ENXIO))
        #expect(await bindsCleanly(b), "the late start left the data port bound")
        await driver.stop()
    }

    // 8. The consumer drops the stream (cancels its iteration) without `stop`: the session's sockets
    //    are released.
    @Test func droppingTheStreamReleasesTheSockets() async throws {
        let driver = AutoInterfaceDriver.liveValue
        let b = binding(discoveryPort: 39_786, dataPort: 52_741)
        let log = EventLog(driver.run([b]))
        #expect(await log.waitFor { $0.contains(.bound(nic: "lo0")) }, "trio never bound: \(log.snapshot())")

        log.cancel()
        #expect(await poll { log.isFinished }, "consumer did not end")
        #expect(await poll {
            await driver.sendMulticast("lo0", Data(repeating: 3, count: 32), b.discoveryPort) == .failed(errno: ENXIO)
        }, "NIC still bound after the stream was dropped")
        #expect(await bindsCleanly(b), "dropped stream left the data port bound")
        await driver.stop()
    }

    // 9. The consumer drops the stream before the run's start reaches the actor: that start binds
    //    nothing.
    @Test func droppingTheStreamBeforeTheStartBindsNothing() async throws {
        let gate = HoldFirst()
        let driver = AutoInterfaceDriver.live(deliveryGate: nil, startGate: { await gate.pass() })
        let b = binding(discoveryPort: 39_796, dataPort: 52_751)
        let log = EventLog(driver.run([b]))
        #expect(await poll { await gate.didHold() }, "start never reached the gate")
        log.cancel()
        #expect(await poll { log.isFinished }, "consumer did not end")
        await gate.release()

        // Give the released start time to reach the actor (it cannot be awaited from here).
        try await Task.sleep(for: .milliseconds(300))
        #expect(await driver.sendMulticast("lo0", Data(repeating: 4, count: 32), b.discoveryPort) == .failed(errno: ENXIO),
                "the start of a dropped stream bound the NIC")
        #expect(await bindsCleanly(b), "the start of a dropped stream left the data port bound")
        await driver.stop()
    }

    // 10. `unbind` closes that NIC's sockets: no NIC entry, its data never surfaces, the port is free,
    //     and the session's stream stays open.
    @Test func unbindClosesTheNICsSocketsAndKeepsTheSession() async throws {
        let driver = AutoInterfaceDriver.liveValue
        let b = binding(discoveryPort: 39_806, dataPort: 52_761)
        let log = EventLog(driver.run([b]))
        defer { Task { await driver.stop() } }
        #expect(await log.waitFor { $0.contains(.bound(nic: "lo0")) }, "trio never bound: \(log.snapshot())")

        await driver.unbind("lo0")
        #expect(await driver.sendMulticast("lo0", Data(repeating: 5, count: 32), b.discoveryPort) == .failed(errno: ENXIO))
        let after = Data("after-unbind".utf8)
        _ = await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, after)
        try await Task.sleep(for: .milliseconds(200))
        let surfaced = log.snapshot().contains {
            if case let .datagram(_, _, _, _, payload) = $0 { return payload == after } else { return false }
        }
        #expect(!surfaced, "datagram surfaced after unbind: \(log.snapshot())")
        #expect(!log.isFinished, "unbind finished the session")
        #expect(await bindsCleanly(b), "unbind left the data port bound")
    }

    // 11. A duplicate NIC name in one `run` replaces the first entry instead of leaking its sockets:
    //     both binds succeed (the first trio was closed before the second bound the data port), and
    //     after `stop` the port is free.
    @Test func duplicateNICInOneRunReplacesTheEarlierBinding() async throws {
        let driver = AutoInterfaceDriver.liveValue
        let b = binding(discoveryPort: 39_816, dataPort: 52_771)
        let log = EventLog(driver.run([b, b]))
        #expect(await log.waitFor { $0.filter { $0 == .bound(nic: "lo0") }.count == 2 },
                "duplicate binding did not rebind cleanly: \(log.snapshot())")
        #expect(!log.snapshot().contains { if case .bindFailed = $0 { return true } else { return false } })
        await driver.stop()
        #expect(await bindsCleanly(b), "the replaced binding leaked its data socket")
    }

    // 12. `discoveryPort` 65535 has no `+ 1`: the unicast discovery plane reports `EINVAL` instead of
    //     wrapping to port 0, and the other planes bind.
    @Test func discoveryPortAtMaximumFailsUnicastDiscoveryWithEINVAL() async throws {
        let driver = AutoInterfaceDriver.liveValue
        let b = binding(discoveryPort: UInt16.max, dataPort: 52_781)
        let log = EventLog(driver.run([b]))
        defer { Task { await driver.stop() } }
        #expect(await log.waitFor { $0.contains(.bindFailed(nic: "lo0", plane: .unicastDiscovery, errno: EINVAL)) },
                "no EINVAL for port 65535 + 1: \(log.snapshot())")
        try await Task.sleep(for: .milliseconds(100))
        let failures = log.snapshot().filter { if case .bindFailed = $0 { return true } else { return false } }
        #expect(failures == [.bindFailed(nic: "lo0", plane: .unicastDiscovery, errno: EINVAL)])
    }

    // 13. `rebind` closes the old data socket before binding the new one. The data plane has no reuse
    //     options, so binding while the old fd is still open fails EADDRINUSE. The old fd is closed
    //     by its source's cancel handler on the socket queue; the test parks a short block on that
    //     queue before each rebind, so the close cannot have happened by the time the new socket
    //     binds unless `rebind` waits for it. (Without the block the race still lost 60-166 of every
    //     100-200 rebinds, but not on every run.)
    @Test func rebindClosesTheOldDataSocketBeforeBindingTheNewOne() async throws {
        let queue = DispatchQueue(label: "retica.autointerface.sockets.test")
        let driver = AutoInterfaceDriver.live(deliveryGate: nil, socketQueue: queue)
        let b = binding(discoveryPort: 39_826, dataPort: 52_791)
        let log = EventLog(driver.run([b]))
        defer { Task { await driver.stop() } }
        #expect(await log.waitFor { $0.contains(.bound(nic: "lo0")) }, "trio never bound: \(log.snapshot())")
        for _ in 0..<10 {
            queue.async { usleep(20_000) }
            await driver.rebind(b)
        }
        #expect(await log.waitFor { $0.filter { $0 == .bound(nic: "lo0") }.count == 11 },
                "not every rebind bound: \(log.snapshot())")
        let failures = log.snapshot().filter { if case .bindFailed = $0 { return true } else { return false } }
        #expect(failures.isEmpty, "\(failures.count) of 10 rebinds failed: \(failures.prefix(3))")
    }

    /// Whether a fresh live driver can bind `b` fully (so no earlier socket still holds the data port).
    /// Retries for a while: a cancelled source closes its fd on the socket queue, asynchronously.
    private func bindsCleanly(_ b: AutoBinding) async -> Bool {
        await poll {
            let probe = AutoInterfaceDriver.liveValue
            let log = EventLog(probe.run([b]))
            _ = await log.waitFor(timeout: .seconds(1)) { events in
                events.contains { if case .bindFailed = $0 { return true } else { return $0 == .bound(nic: b.nic) } }
            }
            await probe.stop()
            return log.snapshot().contains(.bound(nic: b.nic))
        }
    }
}

/// Polls `condition` every 10 ms until it holds or `timeout` passes.
private func poll(timeout: Duration = .seconds(3), _ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + timeout
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}

/// Drains a driver stream into a buffer so a test can wait for an event, or assert that one never
/// arrives, without cancelling the stream (cancelling an `AsyncStream` consumer terminates it).
private final class EventLog: @unchecked Sendable {
    private let lock = NSLock()
    private var events: [AutoSocketEvent] = []
    private var finished = false
    private var consumer: Task<Void, Never>?

    init(_ stream: AsyncStream<AutoSocketEvent>) {
        let task = Task { [self] in
            for await event in stream { self.append(event) }
            self.markFinished()
        }
        lock.lock(); consumer = task; lock.unlock()
    }

    /// Cancels the consuming task, which terminates the stream (the consumer "drops" it).
    func cancel() { lock.lock(); let t = consumer; lock.unlock(); t?.cancel() }

    private func append(_ e: AutoSocketEvent) { lock.lock(); events.append(e); lock.unlock() }
    private func markFinished() { lock.lock(); finished = true; lock.unlock() }

    func snapshot() -> [AutoSocketEvent] { lock.lock(); defer { lock.unlock() }; return events }
    var isFinished: Bool { lock.lock(); defer { lock.unlock() }; return finished }

    func waitFor(timeout: Duration = .seconds(3), _ predicate: @escaping @Sendable ([AutoSocketEvent]) -> Bool) async -> Bool {
        await poll(timeout: timeout) { predicate(self.snapshot()) }
    }
}

/// Holds the first caller that passes it until `release()`. Later callers pass straight through.
private actor HoldFirst {
    private var armed = true
    private var held = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    func pass() async {
        guard armed else { return }
        armed = false
        held = true
        await withCheckedContinuation { waiters.append($0) }
    }

    func didHold() -> Bool { held }

    func release() {
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}
#endif
