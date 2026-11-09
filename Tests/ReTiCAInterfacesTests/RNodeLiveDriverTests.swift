import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import FCBComposable
import RNodeKit
import RNodeMock
import ReTiCAInterfaces
@testable import ReTiCARNodeLive

private let rnodeRadioNotFound = RNodeDriverEvent.unavailable(.other("radio not found"))

/// Spec §5.5 errors, constructed as CoreBluetooth reports them.
private let insufficientEncryption: any Error = CBATTError(.insufficientEncryption)
private let peerRemovedPairing: any Error = NSError(domain: CBErrorDomain, code: 14)

/// 30 dBm asked of a radio whose maximum is 22.
private let rnodeTooHotParams = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 30,
                                                spreadingFactor: 8, codingRate: 6)

/// A `.disconnected(reason: nil)` AFTER the first `.connected`: the drop of a link that was up.
private func rnodeDroppedAfterConnecting(_ events: [RNodeDriverEvent]) -> Bool {
    guard let up = events.firstIndex(where: isLiveRNodeConnected) else { return false }
    return events[(up + 1)...].contains(.disconnected(reason: nil))
}

/// What the mock reports for `params` with its default identity.
private func rnodeReport(_ params: RNodeLoRaParams) -> RNodeRadioReport {
    RNodeRadioReport(name: "RNode 1A2B", firmwareMajor: 1, firmwareMinor: 0x56, platform: 0x80, mcu: 0x81,
                     params: params)
}

/// Polls FCB's replaying state stream until the mock manager reports `state` (about 2 s).
private func liveRNodeWaitUntilState(_ central: BluetoothCentralClient, _ state: CBManagerState) async -> Bool {
    for _ in 0..<200 {
        var iterator = central.state().makeAsyncIterator()
        if await iterator.next() == state { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return false
}

/// One adapter over one session, started on `config`.
private struct LiveRNodeStarted {
    let session: RNodeSession
    let driver: RNodeDriver
    let run: LiveRNodeDriverRun

    func end() async {
        await driver.stop()
        run.cancel()
    }
}

private func startLiveRNode(_ radio: LiveRNodeRadio, _ config: RNodeDriverConfig) -> LiveRNodeStarted {
    let session = RNodeSession(central: radio.central)
    let driver = RNodeDriver.live(session: session)
    let run = LiveRNodeDriverRun(driver.start(config))
    return LiveRNodeStarted(session: session, driver: driver, run: run)
}

/// `RNodeDriver.live(session:)` over a REAL `RNodeSession` over FCB's LIVE client (`mocked()`)
/// against `RNodeMock`. Sessions use the default ContinuousClock: the 30 s handshake and 60 s
/// subscribe bounds would fire at once on an ImmediateClock.
extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct RNodeLiveDriverTests {
        // MARK: Handshake and traffic

        @Test func liveConnectsWithTheEchoedParams() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, radio.config())
            let expected = RNodeDriverEvent.connected(rnodeReport(rnodeLiveParams))
            #expect(await live.run.waitFor { $0 == expected }, "events: \(live.run.events.value)")
            await live.end()
        }

        /// Preflight M3: a second start writes ITS params, not the first start's.
        @Test func liveWritesTheConfigOnEveryConnect() async {
            let radio = await makeLiveRNodeRadio()
            let second = RNodeLoRaParams(frequencyHz: 869_525_000, bandwidthHz: 125_000, txPowerDBm: 17,
                                         spreadingFactor: 9, codingRate: 5)
            let session = RNodeSession(central: radio.central)
            let driver = RNodeDriver.live(session: session)
            let first = LiveRNodeDriverRun(driver.start(radio.config()))
            #expect(await first.waitFor(isLiveRNodeConnected), "precondition: events: \(first.events.value)")
            #expect(radio.setterFrames == rnodeSetterFrames(rnodeLiveParams))
            await driver.stop()
            first.cancel()
            let again = LiveRNodeDriverRun(driver.start(radio.config(second)))
            #expect(await again.waitFor(isLiveRNodeConnected), "precondition: events: \(again.events.value)")
            #expect(Array(radio.setterFrames.dropFirst(5)) == rnodeSetterFrames(second),
                    "frames: \(radio.setterFrames)")
            await driver.stop()
            again.cancel()
        }

        @Test func liveDeliversAPacketWithItsSignal() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, radio.config())
            #expect(await live.run.waitFor(isLiveRNodeConnected), "precondition: connected")
            let packet = Data([0x52, 0x01]) + Data(repeating: 0x33, count: 40)
            radio.device.injectPacket(packet)
            #expect(await live.run.waitFor { $0 == .packet(packet, rssi: -67, snr: 6.0) },
                    "events: \(live.run.events.value)")
            await live.end()
        }

        @Test func liveSendsAPacket() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, radio.config())
            #expect(await live.run.waitFor(isLiveRNodeConnected), "precondition: connected")
            let packet = Data([0x52, 0x02]) + Data(repeating: 0x5A, count: 100)
            #expect(await live.driver.send(packet))
            #expect(radio.device.receivedPackets.last == packet)
            await live.end()
        }

        @Test func liveSendOf508BytesSucceeds() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, radio.config())
            #expect(await live.run.waitFor(isLiveRNodeConnected), "precondition: connected")
            let packet = Data(repeating: 0x01, count: 508)
            #expect(await live.driver.send(packet))
            #expect(radio.device.receivedPackets.last == packet)
            await live.end()
        }

        @Test func liveSendOf509BytesReturnsFalse() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, radio.config())
            #expect(await live.run.waitFor(isLiveRNodeConnected), "precondition: connected")
            let writes = radio.device.receivedWrites.count
            #expect(!(await live.driver.send(Data(repeating: 0x01, count: 509))))
            #expect(radio.device.receivedWrites.count == writes, "nothing written")
            #expect(radio.device.receivedPackets.isEmpty)
            await live.end()
        }

        @Test func liveSendBeforeConnectedReturnsFalse() async {
            let radio = await makeLiveRNodeRadio()
            radio.device.silentCommands = [RNodeCommand.detect]   // the handshake hangs at detect
            let live = startLiveRNode(radio, radio.config())
            #expect(await liveRNodeSessionIs(live.session, .configuring), "precondition: the handshake started")
            #expect(!(await live.driver.send(Data([0x52, 0x03]))))
            #expect(radio.dataFrames == 0)
            await live.end()
        }

        /// Ledger carry 1: a send started after a drop, while the reconnect is stuck in its
        /// handshake, answers false at once and never waits for the next link.
        @Test func liveSendStartedAfterADropReturnsFalseAtOnce() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, radio.config())
            #expect(await live.run.waitFor(isLiveRNodeConnected), "precondition: connected")
            radio.device.silentCommands = [RNodeCommand.detect]   // the reconnect stalls in the handshake
            radio.device.simulateDisconnect()
            let dropped = await liveWaitUntil(timeout: .seconds(10)) { rnodeDroppedAfterConnecting(live.run.events.value) }
            #expect(dropped, "precondition: events: \(live.run.events.value)")
            #expect(await liveRNodeSessionIs(live.session, .configuring), "precondition: reconnecting, stuck at detect")
            let result = LockIsolated<Bool?>(nil)
            let driver = live.driver
            Task {
                let ok = await driver.send(Data([0x52, 0x04]))
                result.setValue(ok)
            }
            let answered = await liveWaitUntil(timeout: .seconds(1)) { result.value != nil }
            #expect(answered, "answered within 1 s")
            #expect(result.value == false)
            #expect(radio.device.receivedPackets.isEmpty)
            await live.end()
        }

        /// Ledger carry 1 / preflight B1: Bluetooth powers off during the DATA write and the send
        /// answers false within 2 s. This pins the outcome only: today's FCB fails the pending
        /// write itself, so the adapter's race against the link ending is defence-in-depth and
        /// not what this test decides.
        @Test func liveSendInFlightWhenBluetoothPowersOffReturnsFalse() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, radio.config())
            #expect(await live.run.waitFor(isLiveRNodeConnected), "precondition: connected")
            let poweredOff = LockIsolated(false)
            radio.device.onWrite = { data in
                let bytes = [UInt8](data)
                guard bytes.count > 1, bytes[0] == 0xC0, bytes[1] == RNodeCommand.data else { return }
                let first = poweredOff.withValue { done -> Bool in
                    defer { done = true }
                    return !done
                }
                if first { CBMCentralManagerMock.simulatePowerOff() }
            }
            let result = LockIsolated<Bool?>(nil)
            let driver = live.driver
            let returned = await returnsWithin(.seconds(2)) {
                let ok = await driver.send(Data([0x52, 0x05]))
                result.setValue(ok)
            }
            #expect(poweredOff.value, "precondition: the DATA write powered the adapter off")
            #expect(returned, "send returned within 2 s")
            #expect(result.value == false)
            await live.end()
        }

        @Test func liveReportsChannelLoad() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, radio.config())
            #expect(await live.run.waitFor(isLiveRNodeConnected), "precondition: connected")
            // 1.50 %, 2.25 %, 3.50 %, 4.75 %, then RSSI −90, noise floor −110, interference −95 (byte − 157).
            radio.device.injectChannelStats(Data([0x00, 0x96, 0x00, 0xE1, 0x01, 0x5E, 0x01, 0xDB, 67, 47, 62]))
            let expected = RNodeChannelLoad(airtimeShort: 1.5, airtimeLong: 2.25, channelLoadShort: 3.5,
                                            channelLoadLong: 4.75, noiseFloor: -110, interferenceRSSI: -95)
            #expect(await live.run.waitFor { $0 == .channelLoad(expected) }, "events: \(live.run.events.value)")
            await live.end()
        }

        @Test func liveReportsHardwareErrors() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, radio.config())
            #expect(await live.run.waitFor(isLiveRNodeConnected), "precondition: connected")
            radio.device.injectError(5)
            #expect(await live.run.waitFor { $0 == .hardwareError(5) }, "events: \(live.run.events.value)")
            #expect(await liveRNodeSessionIs(live.session, .connected), "still connected")
            #expect(!rnodeDroppedAfterConnecting(live.run.events.value), "events: \(live.run.events.value)")
            await live.end()
        }

        // MARK: Terminal ends

        /// Review Focus 1.
        @Test func liveClampedTXPowerReportsBothValues() async {
            let radio = await makeLiveRNodeRadio(maxTXPower: 22)
            let live = startLiveRNode(radio, radio.config(rnodeTooHotParams))
            let expected = RNodeDriverEvent.unavailable(.other(
                "The radio didn't accept these settings: TX power 22 dBm (asked for 30 dBm). Change them in Settings, then Connect."))
            #expect(await live.run.waitFor { $0 == expected }, "events: \(live.run.events.value)")
            #expect(live.run.count(isLiveRNodeConnected) == 0, "events: \(live.run.events.value)")
            #expect(!radio.device.radioOnline, "radio never on")
            let radioOn = radio.device.receivedFrames.contains {
                $0.command == RNodeCommand.radioState && $0.payload == Data([0x01])
            }
            #expect(!radioOn, "radio-on never written")
            await live.end()
        }

        @Test func liveOldFirmwareReportsTheContractMessage() async {
            let radio = await makeLiveRNodeRadio(firmware: (1, 51))
            let live = startLiveRNode(radio, radio.config())
            let expected = RNodeDriverEvent.unavailable(.other(
                "This RNode's firmware is too old. Update it to 1.52 or later."))
            #expect(await live.run.waitFor { $0 == expected }, "events: \(live.run.events.value)")
            #expect(live.run.count(isLiveRNodeConnected) == 0, "events: \(live.run.events.value)")
            await live.end()
        }

        @Test func liveRepeatedPairingFailureReportsTheContractMessage() async {
            let radio = await makeLiveRNodeRadio()
            radio.device.setNotifyErrors = [insufficientEncryption, insufficientEncryption]
            let live = startLiveRNode(radio, radio.config())
            let expected = RNodeDriverEvent.unavailable(.other(
                "Pairing didn't finish. Hold the RNode's button for 5 to 10 seconds until it shows a PIN, then Connect and enter that PIN."))
            #expect(await live.run.waitFor { $0 == expected }, "events: \(live.run.events.value)")
            #expect(live.run.count(isLiveRNodeConnected) == 0, "events: \(live.run.events.value)")
            await live.end()
        }

        @Test func livePeerRemovedPairingReportsTheContractMessage() async {
            let radio = await makeLiveRNodeRadio()
            radio.device.setNotifyErrors = [peerRemovedPairing]
            let live = startLiveRNode(radio, radio.config())
            let expected = RNodeDriverEvent.unavailable(.other(
                "This RNode no longer recognises this device. Forget the RNode in this device's Bluetooth settings, then pair again."))
            #expect(await live.run.waitFor { $0 == expected }, "events: \(live.run.events.value)")
            #expect(live.run.count(isLiveRNodeConnected) == 0, "events: \(live.run.events.value)")
            await live.end()
        }

        /// Review Focus 2: one pairing retry, then the firmware drops the freshly paired link
        /// (ledger: `simulateDisconnect()` replaces the deleted `disconnectAfterSubscribe`). The
        /// stream flips offline-online and ends online, never unavailable.
        @Test func liveThePostPairingDropComesBackOnline() async {
            let radio = await makeLiveRNodeRadio()
            radio.device.setNotifyErrors = [insufficientEncryption]
            let live = startLiveRNode(radio, radio.config())
            #expect(await live.run.waitFor(isLiveRNodeConnected), "precondition: events: \(live.run.events.value)")
            radio.device.simulateDisconnect()
            let back = await liveWaitUntil(timeout: .seconds(15)) { live.run.count(isLiveRNodeConnected) == 2 }
            #expect(back, "events: \(live.run.events.value)")
            #expect(rnodeDroppedAfterConnecting(live.run.events.value), "events: \(live.run.events.value)")
            #expect(live.run.count(isLiveRNodeUnavailable) == 0, "events: \(live.run.events.value)")
            #expect(live.run.events.value.last.map(isLiveRNodeConnected) == true, "ends online: \(live.run.events.value)")
            await live.end()
        }

        @Test func liveTerminalEndFinishesTheStream() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, radio.config(rnodeTooHotParams))
            #expect(await live.run.waitFor(isLiveRNodeUnavailable), "precondition: events: \(live.run.events.value)")
            #expect(await liveWaitUntil { live.run.finished.value }, "the stream ends")
            await live.end()
        }

        @Test func liveRestartAfterARejectionConnectsWithTheNewConfig() async {
            let radio = await makeLiveRNodeRadio()
            let lowered = RNodeLoRaParams(frequencyHz: 868_100_000, bandwidthHz: 62_500, txPowerDBm: 17,
                                          spreadingFactor: 8, codingRate: 6)
            let session = RNodeSession(central: radio.central)
            let driver = RNodeDriver.live(session: session)
            let rejected = LiveRNodeDriverRun(driver.start(radio.config(rnodeTooHotParams)))
            #expect(await rejected.waitFor(isLiveRNodeUnavailable), "precondition: events: \(rejected.events.value)")
            await driver.stop()
            rejected.cancel()
            let retry = LiveRNodeDriverRun(driver.start(radio.config(lowered)))
            let expected = RNodeDriverEvent.connected(rnodeReport(lowered))
            #expect(await retry.waitFor { $0 == expected }, "events: \(retry.events.value)")
            await driver.stop()
            retry.cancel()
        }

        @Test func liveComesBackAfterABluetoothPowerCycle() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, radio.config())
            #expect(await live.run.waitFor(isLiveRNodeConnected), "precondition: connected")
            CBMCentralManagerMock.simulatePowerOff()
            let dropped = await liveWaitUntil(timeout: .seconds(10)) { rnodeDroppedAfterConnecting(live.run.events.value) }
            #expect(dropped, "events: \(live.run.events.value)")
            CBMCentralManagerMock.simulatePowerOn()
            let back = await liveWaitUntil(timeout: .seconds(15)) { live.run.count(isLiveRNodeConnected) == 2 }
            #expect(back, "events: \(live.run.events.value)")
            await live.end()
        }

        // MARK: Stop and retry

        /// 2 s, not 5 s: the stuck detect step times out at 5 s and the connect then returns, so a
        /// stop that only waited for it (C11) would also land inside 5 s.
        @Test func liveStopReturnsWhileTheHandshakeIsStuck() async {
            let radio = await makeLiveRNodeRadio()
            radio.device.silentCommands = [RNodeCommand.detect]
            let live = startLiveRNode(radio, radio.config())
            #expect(await liveRNodeSessionIs(live.session, .configuring), "precondition: the handshake started")
            let driver = live.driver
            #expect(await returnsWithin(.seconds(2)) { await driver.stop() })
            live.run.cancel()
        }

        /// CoreBluetooth connects never time out.
        @Test func liveStopReturnsWhileTheRadioIsOutOfRange() async {
            let radio = await makeLiveRNodeRadio()
            radio.spec.simulateProximityChange(.outOfRange)
            let live = startLiveRNode(radio, radio.config())
            #expect(await liveRNodeSessionIs(live.session, .connecting), "precondition: the connect is pending")
            let driver = live.driver
            #expect(await returnsWithin(.seconds(5)) { await driver.stop() })
            live.run.cancel()
        }

        /// The adapter's connect is an unstructured hop onto the session actor; a stop issued at
        /// once must still leave nothing connected. Whether the connect lands before or after
        /// stop's first disconnect is a race, so the cycle runs 20 times; each start is at
        /// background priority, so its connect task tends to arrive AFTER that disconnect. After
        /// each stop the session must stay disconnected for a bounded 200 ms watch.
        @Test func liveStopRightAfterStartLeavesTheSessionDisconnected() async {
            let radio = await makeLiveRNodeRadio()
            let config = radio.config()
            var cameBack: [Int: [RNodeEvent]] = [:]
            for attempt in 0..<20 {
                let session = RNodeSession(central: radio.central)
                let driver = RNodeDriver.live(session: session)
                let stream = await Task(priority: .background) { driver.start(config) }.value
                let run = LiveRNodeDriverRun(stream)
                await driver.stop()
                let other = LockIsolated<[RNodeEvent]>([])
                let sessionEvents = session.events()   // replays the current state first
                let watcher = Task {
                    for await event in sessionEvents where event != .connection(.disconnected(reason: nil)) {
                        other.withValue { $0.append(event) }
                    }
                }
                // Bounded wait for something that must not happen.
                if await liveWaitUntil(timeout: .milliseconds(200), { !other.value.isEmpty }) {
                    cameBack[attempt] = other.value
                    await session.disconnect()   // don't let a leaked link spoil the next attempt
                }
                watcher.cancel()
                run.cancel()
            }
            #expect(cameBack.isEmpty, "attempts whose session came back after stop: \(cameBack)")
        }

        /// Ledger carry 2 / preflight M11: `RNodeInterface` starts again from `.unavailable` with
        /// no stop in between; a stop must then drain BOTH connects. The retry's start is at
        /// background priority so its connect sometimes lands after stop's first disconnect (a
        /// few times in 100 here: a stop that drained only one connect leaked 1–7 sessions per
        /// run); after power-on no session may come back.
        @Test func liveStartFromUnavailableWithoutStopThenStopLeavesTheSessionDisconnected() async {
            let radio = await makeLiveRNodeRadio(initialState: .poweredOff)
            let config = radio.config()
            let other = LockIsolated<[Int: [RNodeEvent]]>([:])
            var watchers: [Task<Void, Never>] = []
            for attempt in 0..<100 {
                let session = RNodeSession(central: radio.central)
                let driver = RNodeDriver.live(session: session)
                let first = LiveRNodeDriverRun(driver.start(config))
                #expect(await first.waitFor { $0 == .unavailable(.poweredOff) },
                        "precondition: events: \(first.events.value)")
                let stream = await Task(priority: .background) { driver.start(config) }.value
                let retry = LiveRNodeDriverRun(stream)
                await driver.stop()
                first.cancel()
                retry.cancel()
                let sessionEvents = session.events()   // replays the current state first
                watchers.append(Task {
                    for await event in sessionEvents where event != .connection(.disconnected(reason: nil)) {
                        other.withValue { $0[attempt, default: []].append(event) }
                    }
                })
            }
            CBMCentralManagerMock.simulatePowerOn()
            #expect(await liveWaitUntilPoweredOn(radio.central), "precondition: powered on")
            // Bounded wait for something that must not happen.
            let cameBack = await liveWaitUntil(timeout: .milliseconds(500)) { !other.value.isEmpty }
            #expect(!cameBack, "sessions that came back after stop: \(other.value)")
            for watcher in watchers { watcher.cancel() }
        }

        @Test func liveUnknownRadioIsUnavailable() async {
            let radio = await makeLiveRNodeRadio()
            let live = startLiveRNode(radio, RNodeDriverConfig(radio: UUID(), params: rnodeLiveParams))
            #expect(await live.run.waitFor { $0 == rnodeRadioNotFound }, "events: \(live.run.events.value)")
            await live.end()
        }

        /// Preflight B2 (precedent `liveDriverRetryOfARadioNowKnownReportsConnectedWithNoStaleUnavailable`):
        /// the radio becomes known between the not-found and a retry started with no stop (added
        /// to CBM while powered off, the only time CBM accepts new peripherals). The hub replays
        /// the terminal `.disconnected("radio not found")` to the retry's subscription; it must be
        /// dropped, so the retry reports `.connected` and no `.unavailable`.
        @Test func liveRetryOfARadioNowKnownReportsConnectedWithNoStaleUnavailable() async {
            let radio = await makeLiveRNodeRadio()
            let lateID = UUID()
            let lateDevice = MockRNodeDevice(name: "RNode 3C4D")
            let lateSpec = lateDevice.makeSpec(identifier: lateID)
            let driver = RNodeDriver.live(session: RNodeSession(central: radio.central))
            let late = RNodeDriverConfig(radio: lateID, params: rnodeLiveParams)
            let first = LiveRNodeDriverRun(driver.start(late))
            #expect(await first.waitFor { $0 == rnodeRadioNotFound }, "precondition: events: \(first.events.value)")
            CBMCentralManagerMock.simulatePowerOff()
            #expect(await liveRNodeWaitUntilState(radio.central, .poweredOff), "precondition: powered off")
            CBMCentralManagerMock.simulatePeripherals([radio.spec, lateSpec])
            CBMCentralManagerMock.simulatePowerOn()
            #expect(await liveWaitUntilPoweredOn(radio.central), "precondition: powered on")
            let retry = LiveRNodeDriverRun(driver.start(late))
            #expect(await retry.waitFor(isLiveRNodeConnected), "events: \(retry.events.value)")
            #expect(retry.count(isLiveRNodeUnavailable) == 0, "events: \(retry.events.value)")
            await driver.stop()
            first.cancel()
            retry.cancel()
        }

        @Test func liveReportsAPoweredOffAdapter() async {
            let radio = await makeLiveRNodeRadio(initialState: .poweredOff)
            let live = startLiveRNode(radio, radio.config())
            #expect(await live.run.waitFor { $0 == .unavailable(.poweredOff) }, "events: \(live.run.events.value)")
            await live.end()
        }
    }
}
