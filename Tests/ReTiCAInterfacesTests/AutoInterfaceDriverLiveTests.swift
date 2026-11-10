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
    //    socket sets no reuse options. It is the only failure reported: the data plane binds first
    //    and a failed one opens no discovery socket (test 14).
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

    // 14. A co-running NomadNet (here `holder`) holds the data port, so our data bind fails. Our NIC
    //     must then open NO discovery socket, neither on the first bind nor on the D3 retry every
    //     peer-job tick. On Darwin the most recently bound SO_REUSEPORT socket receives all unicast
    //     to (ll, port), so a unicast discovery socket of ours, re-created every tick, took every
    //     reverse announce meant for the holder (0 of 20 reached it, /tmp/ReTiCA/reuseport_unicast_probe.py).
    @Test func aFailedDataBindOpensNoDiscoverySocketSoTheHolderKeepsItsUnicast() async throws {
        let holder = AutoInterfaceDriver.liveValue
        let ours = AutoInterfaceDriver.liveValue
        let b = binding(discoveryPort: 39_836, dataPort: 52_801)
        let holderLog = EventLog(holder.run([b]))
        defer { Task { await holder.stop() } }
        #expect(await holderLog.waitFor { $0.contains(.bound(nic: "lo0")) }, "holder never bound: \(holderLog.snapshot())")

        let ourLog = EventLog(ours.run([b]))
        defer { Task { await ours.stop() } }
        let clash = AutoSocketEvent.bindFailed(nic: "lo0", plane: .data, errno: EADDRINUSE)
        #expect(await ourLog.waitFor { $0.contains(clash) }, "our data bind did not clash: \(ourLog.snapshot())")
        await ours.rebind(b)   // the D3 retry
        #expect(await ourLog.waitFor { $0.filter { $0 == clash }.count == 2 }, "retry did not clash: \(ourLog.snapshot())")

        let reverse = (0..<20).map { Data("reverse-\($0)".utf8) }
        for d in reverse {
            #expect(await holder.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.discoveryPort + 1, d) == .sent)
        }
        #expect(await holderLog.waitFor { log in reverse.allSatisfy { log.contains(datagram(.unicastDiscovery, $0)) } },
                "the holder lost reverse announces to our socket: \(holderLog.snapshot().count) events")
        let ourDatagrams = ourLog.snapshot().filter { if case .datagram = $0 { return true } else { return false } }
        #expect(ourDatagrams.isEmpty, "a NIC whose data bind failed received \(ourDatagrams.count) datagrams")
        #expect(ourLog.snapshot() == [clash, clash], "only the two clashes: \(ourLog.snapshot())")
    }

    // 15. Spec R11 with the data plane bound first: a multicast join that fails (here the "group" is
    //     not a multicast address) is still reported as a failed `.multicastDiscovery` plane, so the
    //     reducer skips the NIC, and the data socket already bound stays open until it unbinds it.
    @Test func aFailedMulticastJoinAfterTheDataBindIsReportedAndDataStaysBound() async throws {
        let driver = AutoInterfaceDriver.liveValue
        var b = binding(discoveryPort: 39_846, dataPort: 52_811)
        b.group = [0xfe, 0x80] + [UInt8](repeating: 0, count: 13) + [0x01]   // fe80::1, unicast
        let log = EventLog(driver.run([b]))
        defer { Task { await driver.stop() } }
        #expect(await log.waitFor { $0.contains { if case .bindFailed(_, .multicastDiscovery, _) = $0 { true } else { false } } },
                "a failed join was not reported: \(log.snapshot())")
        let payload = Data("data-after-failed-join".utf8)
        #expect(await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, payload) == .sent)
        #expect(await log.waitFor { $0.contains(datagram(.data, payload)) }, "data plane not bound: \(log.snapshot())")
        let failures = log.snapshot().filter { if case .bindFailed = $0 { return true } else { return false } }
        #expect(failures.count == 1, "only the join failed: \(failures)")
        #expect(!log.snapshot().contains(.bound(nic: "lo0")))
        await driver.unbind("lo0")
        #expect(await bindsCleanly(binding(discoveryPort: 39_846, dataPort: 52_811)), "unbind left the data port bound")
    }

    // 16. Flood with a consumer that is not reading (the main actor busy): the stream buffers at most
    //     `eventBufferLimit` events, not one per datagram, and delivery resumes once it reads again.
    @Test func aFloodBuffersAtMostTheStreamBoundAndDeliveryResumesAfterwards() async throws {
        let batches = BatchCounter()
        let driver = AutoInterfaceDriver.live(deliveryGate: { batches.increment() })
        let b = binding(discoveryPort: 39_856, dataPort: 52_821)
        let stream = driver.run([b])
        defer { Task { await driver.stop() } }
        #expect(await isBound(driver, b), "never bound")

        await flood(driver, b, count: 3000)
        #expect(await batches.settled(), "deliveries never settled")
        let log = EventLog(stream)
        #expect(await log.drained(), "nothing was buffered")
        let flooded = log.snapshot().filter(isFlood).count
        let after = Data("after-flood".utf8)
        #expect(await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, after) == .sent)
        #expect(await log.waitFor { $0.contains(datagram(.data, after)) }, "delivery blocked after the flood")
        let limit = AutoInterfaceDriver.eventBufferLimit
        #expect(flooded < limit, "\(flooded) flood datagrams buffered, bound \(limit)")
        #expect(flooded >= limit / 2, "the flood never filled the buffer (\(flooded)), so the bound was not exercised")
    }

    // 17. While a delivery is held (the actor busy), a socket has at most ONE delivery Task pending:
    //     reads coalesce into it, up to `pendingDatagramLimit`, and the rest are dropped. One Task per
    //     read batch grew without bound. Once released, later datagrams are delivered.
    @Test func aHeldDeliveryKeepsOnePendingTaskPerSocketAndCoalescesUpToTheLimit() async throws {
        let gate = HoldAll()
        let driver = AutoInterfaceDriver.live(deliveryGate: { await gate.pass() })
        let b = binding(discoveryPort: 39_866, dataPort: 52_831)
        let log = EventLog(driver.run([b]))
        defer { Task { await driver.stop() } }
        #expect(await log.waitFor { $0.contains(.bound(nic: "lo0")) }, "trio never bound: \(log.snapshot())")

        await flood(driver, b, count: 3000)
        try await Task.sleep(for: .milliseconds(300))
        let pending = await gate.waiting
        #expect(pending == 1, "\(pending) delivery Tasks pending for one socket")
        await gate.open()
        let after = Data("after-hold".utf8)
        #expect(await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, after) == .sent)
        #expect(await log.waitFor { $0.contains(datagram(.data, after)) }, "delivery blocked after the hold")
        let flooded = log.snapshot().filter(isFlood).count
        let cap = AutoInterfaceDriver.maxDatagramsPerRead + AutoInterfaceDriver.pendingDatagramLimit
        #expect(flooded <= cap, "\(flooded) flood datagrams delivered from one held socket, cap \(cap)")
    }

    // 18. Bind and read outcomes are never lost to a full stream: a `.bound` from a rebind made while
    //     a flood fills it is held back and delivered, in order, once the consumer reads again.
    @Test func aControlEventDuringAFullStreamIsDeliveredOnceThereIsRoom() async throws {
        let batches = BatchCounter()
        let driver = AutoInterfaceDriver.live(deliveryGate: { batches.increment() })
        let b = binding(discoveryPort: 39_876, dataPort: 52_841)
        let stream = driver.run([b])
        defer { Task { await driver.stop() } }
        #expect(await isBound(driver, b), "never bound")
        await flood(driver, b, count: 3000)
        #expect(await batches.settled(), "deliveries never settled")
        await driver.rebind(b)

        let log = EventLog(stream)
        #expect(await log.drained(), "nothing was buffered")
        let after = Data("after-rebind".utf8)
        #expect(await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, after) == .sent)
        #expect(await log.waitFor { $0.contains(datagram(.data, after)) }, "delivery blocked: \(log.snapshot().count)")
        let events = log.snapshot()
        #expect(events.filter { $0 == .bound(nic: "lo0") }.count == 2, "the rebind's .bound was lost")
        if let second = events.lastIndex(of: .bound(nic: "lo0")), let fresh = events.firstIndex(of: datagram(.data, after)) {
            #expect(second < fresh, "the held .bound must come before later traffic")
        }
    }

    private func isFlood(_ e: AutoSocketEvent) -> Bool {
        if case let .datagram(_, _, _, _, payload) = e { return payload.starts(with: Data("flood".utf8)) }
        return false
    }

    /// The NIC has an entry (so `run` bound it) without reading the stream: a multicast to a port
    /// nothing listens on succeeds only for a bound NIC.
    private func isBound(_ driver: AutoInterfaceDriver, _ b: AutoBinding) async -> Bool {
        await poll { await driver.sendMulticast(b.nic, Data(repeating: 9, count: 32), 9) == .sent }
    }

    private func flood(_ driver: AutoInterfaceDriver, _ b: AutoBinding, count: Int) async {
        for i in 0..<count {
            _ = await driver.sendUnicast(Self.loopbackAddress, Self.loopbackIndex, b.dataPort, Data("flood-\(i)".utf8))
        }
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

    /// Something arrived, then nothing for 200 ms: the consumer has read what was buffered.
    func drained() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(5)
        var last = -1
        while ContinuousClock.now < deadline {
            let now = snapshot().count
            if now > 0, now == last { return true }
            last = now
            try? await Task.sleep(for: .milliseconds(200))
        }
        return false
    }
}

/// Holds every caller until `open()`, counting how many wait. After `open()` callers pass straight through.
private actor HoldAll {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    var waiting: Int { waiters.count }

    func pass() async {
        guard !isOpen else { return }
        await withCheckedContinuation { waiters.append($0) }
    }

    func open() {
        isOpen = true
        for w in waiters { w.resume() }
        waiters.removeAll()
    }
}

/// Counts delivery batches (the delivery gate's calls), so a test can wait until a flood's reads and
/// deliveries are over without reading the stream.
private final class BatchCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.lock(); count += 1; lock.unlock() }
    private var value: Int { lock.lock(); defer { lock.unlock() }; return count }

    /// Some batch arrived, then none for 300 ms.
    func settled() async -> Bool {
        let deadline = ContinuousClock.now + .seconds(10)
        var last = -1
        while ContinuousClock.now < deadline {
            let now = value
            if now > 0, now == last { return true }
            last = now
            try? await Task.sleep(for: .milliseconds(300))
        }
        return false
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
