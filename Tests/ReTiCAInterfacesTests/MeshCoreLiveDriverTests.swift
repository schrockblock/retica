import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import FCBComposable
import MeshCoreKit
import MeshCoreMock
import ReTiCAInterfaces
@testable import ReTiCAMeshCoreLive

private let liveCoreRadioNotFound = MeshCoreDriverEvent.unavailable(.other("radio not found"))
private let liveCoreSetupFailed = MeshCoreDriverEvent.unavailable(.other(MeshCoreLiveMessage.channelSetupFailed))
private let liveCoreNoFreeSlot = MeshCoreDriverEvent.unavailable(.other("No free channel slot on this radio"))
private let liveCoreTooOld =
    MeshCoreDriverEvent.unavailable(.other("This radio's firmware is too old; update to v1.15 or later"))
private let liveCoreKeyMissing = MeshCoreDriverEvent.unavailable(.other("The channel key is missing"))

/// A `.disconnected(reason: nil)` AFTER the first `.connected`: the drop of a link that was up.
private func liveCoreDroppedAfterConnecting(_ events: [MeshCoreDriverEvent]) -> Bool {
    guard let up = events.firstIndex(where: isLiveCoreConnected) else { return false }
    return events[(up + 1)...].contains(.disconnected(reason: nil))
}

/// The bytes `send` must write on `slot`: `3E slot FF` (flood), data type 0xFFFF LE, payload.
private func liveCoreChannelDataFrame(_ slot: UInt8, _ payload: Data) -> Data {
    Data([0x3E, slot, 0xFF, 0xFF, 0xFF]) + payload
}

/// One adapter over one session, started on `config`.
private struct LiveCoreStarted {
    let session: MeshCoreSession
    let driver: MeshCoreDriver
    let run: LiveCoreDriverRun

    func end() async {
        await driver.stop()
        run.cancel()
    }
}

private func startLiveCore(_ radio: LiveCoreRadio, _ config: MeshCoreDriverConfig,
                           details: @escaping @Sendable (MeshCoreRadioDetails?) -> Void = { _ in },
                           onEvent: @escaping @Sendable (MeshCoreDriverEvent) -> Void = { _ in }) -> LiveCoreStarted {
    let session = MeshCoreSession(central: radio.central, appName: "ReTiCATests")
    let driver = MeshCoreDriver.live(session: session, details: details)
    let run = LiveCoreDriverRun(driver.start(config), onEvent: onEvent)
    return LiveCoreStarted(session: session, driver: driver, run: run)
}

/// Arguments for `liveCoreNeverClearsAnotherSecret`: our key already on the radio, a free slot,
/// or no free slot.
enum LiveCoreNeighbourCase: String, CaseIterable, CustomTestStringConvertible, Sendable {
    case match, empty, full
    var testDescription: String { rawValue }
}

/// `MeshCoreDriver.live(session:details:)` over a REAL `MeshCoreSession` over FCB's LIVE client
/// (`mocked()`) against `MeshCoreMock`. Sessions use the default ContinuousClock: the 30 s
/// handshake timeout would fire at once on an ImmediateClock.
extension FCBDriverAdapterCBMTests {
    @Suite @MainActor
    struct MeshCoreLiveDriverTests {
        // MARK: Handshake and traffic

        @Test func liveCoreConnectsWithPrefixKeyAndParams() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            let expected = MeshCoreDriverEvent.connected(
                selfPrefix: MockMeshCoreDevice.selfKey.prefix(4), publicKey: MockMeshCoreDevice.selfKey,
                params: MeshCoreLinkParams(spreadingFactor: 10, bandwidthHz: 250_000, codingRate: 5))
            #expect(await live.run.waitFor { $0 == expected }, "events: \(live.run.events.value)")
            await live.end()
        }

        @Test func liveCoreRecordsDetailsBeforeConnected() async {
            let radio = await makeLiveCoreRadio()
            let recorded = LockIsolated<MeshCoreRadioDetails?>(nil)
            let atConnected = LockIsolated<MeshCoreRadioDetails?>(nil)
            let live = startLiveCore(radio, radio.config(),
                                     details: { recorded.setValue($0) },
                                     onEvent: { if isLiveCoreConnected($0) { atConnected.setValue(recorded.value) } })
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            #expect(atConnected.value == MeshCoreRadioDetails(name: "MockCore", firmwareCode: 13, channelSlot: 1))
            await live.end()
        }

        @Test func liveCoreDeliversChannelDataFromOurSlot() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            let payload = Data([0x52, 0x01]) + Data(repeating: 0x33, count: 40)
            radio.device.injectChannelData(payload, channelIndex: 1)
            #expect(await live.run.waitFor { $0 == .datagram(payload) }, "events: \(live.run.events.value)")
            await live.end()
        }

        @Test func liveCoreDropsChannelDataFromOtherSlots() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            radio.device.injectChannelData(Data([0x01]), channelIndex: 0)
            radio.device.injectChannelData(Data([0x02]), channelIndex: 2)
            radio.device.injectChannelData(Data([0x03]), channelIndex: 1, dataType: 0x0001)
            let marker = Data([0x52, 0x7E])
            radio.device.injectChannelData(marker, channelIndex: 1)
            #expect(await live.run.waitFor { $0 == .datagram(marker) }, "precondition: the marker arrived")
            #expect(live.run.count(isLiveCoreDatagram) == 1, "events: \(live.run.events.value)")
            await live.end()
        }

        @Test func liveCoreDeliversARawPush() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            let payload = Data([0x52, 0x02, 0xAA, 0xBB])
            radio.device.injectRawData(payload)
            #expect(await live.run.waitFor { $0 == .datagram(payload) }, "events: \(live.run.events.value)")
            await live.end()
        }

        /// Every frame also arrives as `.frame`: if that were mapped too, the duplicate would land
        /// between the first datagram and the marker.
        @Test func liveCoreDeliversOneDatagramPerFrame() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            let first = Data([0x52, 0x03])
            radio.device.injectChannelData(first, channelIndex: 1)
            #expect(await live.run.waitFor { $0 == .datagram(first) }, "precondition: the first arrived")
            let raw = Data([0x52, 0x04])
            radio.device.injectRawData(raw)
            #expect(await live.run.waitFor { $0 == .datagram(raw) }, "precondition: the raw push arrived")
            let marker = Data([0x52, 0x05])
            radio.device.injectChannelData(marker, channelIndex: 1)
            #expect(await live.run.waitFor { $0 == .datagram(marker) }, "precondition: the marker arrived")
            #expect(live.run.count { $0 == .datagram(first) } == 1, "events: \(live.run.events.value)")
            #expect(live.run.count { $0 == .datagram(raw) } == 1, "events: \(live.run.events.value)")
            await live.end()
        }

        @Test func liveCoreSendsTheChannelDataBytes() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            let payload = Data([0x52, 0x06]) + Data(repeating: 0x5A, count: 100)
            #expect(await live.driver.send(payload))
            #expect(radio.device.receivedFrames.last == liveCoreChannelDataFrame(1, payload))
            await live.end()
        }

        /// 162 B is the largest datagram (spec): a 167-byte frame.
        @Test func liveCoreSendOfTheLargestDatagramSucceeds() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            let payload = Data(repeating: 0x01, count: 162)
            #expect(await live.driver.send(payload))
            #expect(radio.device.receivedFrames.last == liveCoreChannelDataFrame(1, payload))
            await live.end()
        }

        /// 169 B makes a 174-byte frame, over the 173-byte limit: refused before any write.
        @Test func liveCoreSendOfAnOversizedFrameReturnsFalse() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            let written = radio.device.receivedFrames.count
            #expect(!(await live.driver.send(Data(repeating: 0x01, count: 169))))
            #expect(radio.device.receivedFrames.count == written)
            await live.end()
        }

        @Test func liveCoreSendBeforeConnectedReturnsFalse() async {
            let radio = await makeLiveCoreRadio()
            radio.device.silentCommands = [0x01]   // APP_START never answered: the handshake hangs
            let live = startLiveCore(radio, radio.config())
            #expect(await liveCoreSessionIs(live.session, .configuring), "precondition: the handshake started")
            #expect(!(await live.driver.send(Data([0x52, 0x07]))))
            #expect(radio.frames(0x3E) == 0)
            await live.end()
        }

        @Test func liveCoreSendRefusedByTheRadioReturnsFalse() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            radio.device.errorReplies = [0x3E: 3]   // 3 = firmware ERR_CODE_TABLE_FULL (the mock has no constant)
            #expect(!(await live.driver.send(Data([0x52, 0x08]))))
            #expect(radio.frames(0x3E) == 1, "control: the send reached the radio")
            await live.end()
        }

        /// Carry-over 2: a send from before a drop, whether before the reconnect or after a new
        /// handshake but before the policy has re-checked the slot, returns false and writes nothing.
        @Test func liveCoreSendAfterADropReturnsFalse() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            let reads = radio.frames(0x1F)
            radio.spec.simulateDisconnection()
            radio.device.silentCommands = [0x1F]   // the next policy pass hangs in channels()
            let dropped = await liveWaitUntil(timeout: .seconds(10)) { liveCoreDroppedAfterConnecting(live.run.events.value) }
            #expect(dropped, "precondition: events: \(live.run.events.value)")
            #expect(!(await live.driver.send(Data([0x52, 0x09]))), "before the reconnect")
            let rereading = await liveWaitUntil(timeout: .seconds(10)) { radio.frames(0x1F) > reads }
            #expect(rereading, "precondition: reconnected and the policy started")
            // A send that used a stale slot would queue behind the silent read (5 s command
            // timeout) and might then go out; with no slot it answers false at once.
            let result = LockIsolated<Bool?>(nil)
            let driver = live.driver
            Task {
                let ok = await driver.send(Data([0x52, 0x0A]))
                result.setValue(ok)
            }
            let answered = await liveWaitUntil(timeout: .seconds(2)) { result.value != nil }
            #expect(answered, "after the handshake, before the policy finished: answered at once")
            #expect(result.value == false, "after the handshake, before the policy finished")
            #expect(radio.frames(0x3E) == 0)
            await live.end()
        }

        // MARK: Policy

        @Test func liveCorePolicyReusesASlotHoldingOurKey() async {
            let radio = await makeLiveCoreRadio(channels: liveCoreSlots(
                MeshCoreChannel(index: 4, name: "RNSTunnel", secret: liveCoreKey)))
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            #expect(radio.setChannelFrames == [])
            let payload = Data([0x52, 0x0B])
            #expect(await live.driver.send(payload))
            #expect(radio.device.receivedFrames.last == liveCoreChannelDataFrame(4, payload))
            await live.end()
        }

        @Test func liveCorePolicyWritesTheFirstEmptySlot() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            #expect(radio.setChannelFrames == [LiveCoreSetChannel(1, "RNSTunnel", liveCoreKey)])
            let payload = Data([0x52, 0x0C])
            #expect(await live.driver.send(payload))
            #expect(radio.device.receivedFrames.last == liveCoreChannelDataFrame(1, payload))
            await live.end()
        }

        @Test func liveCoreNoFreeSlotReportsTheContractMessage() async {
            let radio = await makeLiveCoreRadio(channels: liveCoreFullRadio())
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor { $0 == liveCoreNoFreeSlot }, "events: \(live.run.events.value)")
            #expect(await liveWaitUntil { live.run.finished.value }, "the stream ends")
            #expect(live.run.count(isLiveCoreConnected) == 0, "events: \(live.run.events.value)")
            #expect(radio.setChannelFrames == [])
            await live.end()
        }

        /// Review Focus 1: the radio has one BLE client, so the person can only free a slot in the
        /// MeshCore app if we let go; staying connected would also drain its queue.
        @Test func liveCoreNoFreeSlotReleasesTheRadio() async {
            let radio = await makeLiveCoreRadio(channels: liveCoreFullRadio())
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor { $0 == liveCoreNoFreeSlot }, "precondition: events: \(live.run.events.value)")
            #expect(await liveCoreSessionIs(live.session, .disconnected(reason: nil)), "released within 5 s")
            #expect(await liveWaitUntil { live.run.finished.value }, "the stream ends")
            let syncs = radio.frames(0x0A)
            radio.device.injectMsgWaiting()
            let drained = await liveWaitUntil(timeout: .milliseconds(500)) { radio.frames(0x0A) > syncs }
            #expect(!drained, "a push after the release draws no sync")
            await live.end()
        }

        /// Public at 0, slot 1 holds another key under our name, slot 2 is named but has a zero
        /// secret (not empty). None of them is ever written, whatever the outcome.
        @Test(arguments: LiveCoreNeighbourCase.allCases)
        func liveCoreNeverClearsAnotherSecret(_ neighbourCase: LiveCoreNeighbourCase) async {
            let neighbours = [
                liveCorePublicSlot,
                MeshCoreChannel(index: 1, name: "RNSTunnel", secret: liveCoreOtherKey),
                MeshCoreChannel(index: 2, name: "Friends", secret: liveCoreZeroKey),
            ]
            let rest: [MeshCoreChannel]
            switch neighbourCase {
            case .match:
                rest = (3..<liveCoreSlotCount).map { $0 == 5 ? MeshCoreChannel(index: 5, name: "RNSTunnel", secret: liveCoreKey)
                                                             : liveCoreEmptySlot($0) }
            case .empty:
                rest = (3..<liveCoreSlotCount).map(liveCoreEmptySlot)
            case .full:
                rest = (3..<liveCoreSlotCount).map(liveCoreForeignSlot)
            }
            let radio = await makeLiveCoreRadio(channels: neighbours + rest)
            let live = startLiveCore(radio, radio.config())
            let settled = await live.run.waitFor { isLiveCoreConnected($0) || isLiveCoreUnavailable($0) }
            #expect(settled, "precondition: events: \(live.run.events.value)")
            switch neighbourCase {
            case .match, .empty: #expect(live.run.count(isLiveCoreConnected) == 1, "events: \(live.run.events.value)")
            case .full: #expect(live.run.events.value.contains(liveCoreNoFreeSlot), "events: \(live.run.events.value)")
            }
            #expect(Array(radio.device.channelSlots.prefix(3)) == neighbours)
            #expect(radio.setChannelFrames.allSatisfy { $0.index > 2 }, "frames: \(radio.setChannelFrames)")
            await live.end()
        }

        // MARK: Retired keys

        @Test func liveCoreClearsARetiredSlot() async {
            let radio = await makeLiveCoreRadio(channels: liveCoreSlots(
                MeshCoreChannel(index: 3, name: "RNSTunnel", secret: liveCoreRetiredKey)))
            let live = startLiveCore(radio, radio.config(retired: [liveCoreRetiredKey]))
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            #expect(radio.setChannelFrames.contains(LiveCoreSetChannel(3, "", liveCoreZeroKey)),
                    "frames: \(radio.setChannelFrames)")
            #expect(radio.device.channelSlots[3] == liveCoreEmptySlot(3))
            await live.end()
        }

        @Test func liveCoreReportsRetiredClearedBeforeConnected() async {
            let radio = await makeLiveCoreRadio(channels: liveCoreSlots(
                MeshCoreChannel(index: 3, name: "RNSTunnel", secret: liveCoreRetiredKey)))
            let live = startLiveCore(radio, radio.config(retired: [liveCoreRetiredKey]))
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            let cleared = live.run.index { $0 == .retiredChannelsCleared }
            let connected = live.run.index(isLiveCoreConnected)
            #expect(cleared != nil && connected != nil && cleared! < connected!, "events: \(live.run.events.value)")
            await live.end()
        }

        @Test func liveCoreReportsNothingWithNoRetiredKeys() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config(retired: []))
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            #expect(live.run.count { $0 == .retiredChannelsCleared } == 0, "events: \(live.run.events.value)")
            await live.end()
        }

        @Test func liveCoreReportsClearedWhenNoSlotHeldARetiredKey() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config(retired: [liveCoreRetiredKey]))
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            let cleared = live.run.index { $0 == .retiredChannelsCleared }
            let connected = live.run.index(isLiveCoreConnected)
            #expect(cleared != nil && connected != nil && cleared! < connected!, "events: \(live.run.events.value)")
            #expect(radio.setChannelFrames == [LiveCoreSetChannel(1, "RNSTunnel", liveCoreKey)])
            await live.end()
        }

        @Test func liveCoreARefusedClearReportsAndReleases() async {
            let radio = await makeLiveCoreRadio(channels: liveCoreSlots(
                MeshCoreChannel(index: 3, name: "RNSTunnel", secret: liveCoreRetiredKey)))
            radio.device.errorReplies = [0x20: 6]
            let live = startLiveCore(radio, radio.config(retired: [liveCoreRetiredKey]))
            #expect(await live.run.waitFor { $0 == liveCoreSetupFailed }, "events: \(live.run.events.value)")
            #expect(await liveCoreSessionIs(live.session, .disconnected(reason: nil)), "released within 5 s")
            #expect(live.run.count { $0 == .retiredChannelsCleared } == 0, "events: \(live.run.events.value)")
            #expect(live.run.count(isLiveCoreConnected) == 0, "events: \(live.run.events.value)")
            await live.end()
        }

        /// Carry-over 5: a failed channel read never leads to a guessed slot.
        @Test func liveCoreAFailedChannelReadReportsAndReleases() async {
            let radio = await makeLiveCoreRadio()
            radio.device.errorReplies = [0x1F: 2]
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor { $0 == liveCoreSetupFailed }, "events: \(live.run.events.value)")
            #expect(await liveCoreSessionIs(live.session, .disconnected(reason: nil)), "released within 5 s")
            #expect(live.run.count(isLiveCoreConnected) == 0, "events: \(live.run.events.value)")
            #expect(radio.setChannelFrames == [])
            await live.end()
        }

        @Test func liveCoreClearingARetiredSlotMakesRoomForTheNewKey() async {
            var slots = liveCoreFullRadio()
            slots[5] = MeshCoreChannel(index: 5, name: "RNSTunnel", secret: liveCoreRetiredKey)
            let radio = await makeLiveCoreRadio(channels: slots)
            let live = startLiveCore(radio, radio.config(retired: [liveCoreRetiredKey]))
            #expect(await live.run.waitFor(isLiveCoreConnected), "events: \(live.run.events.value)")
            #expect(radio.device.channelSlots[5] == MeshCoreChannel(index: 5, name: "RNSTunnel", secret: liveCoreKey))
            let payload = Data([0x52, 0x0D])
            #expect(await live.driver.send(payload))
            #expect(radio.device.receivedFrames.last == liveCoreChannelDataFrame(5, payload))
            await live.end()
        }

        @Test func liveCoreRetiredKeyEqualToTheCurrentKeyStays() async {
            let ours = MeshCoreChannel(index: 2, name: "RNSTunnel", secret: liveCoreKey)
            let radio = await makeLiveCoreRadio(channels: liveCoreSlots(ours))
            let live = startLiveCore(radio, radio.config(retired: [liveCoreKey]))
            #expect(await live.run.waitFor(isLiveCoreConnected), "events: \(live.run.events.value)")
            #expect(radio.setChannelFrames == [])
            #expect(radio.device.channelSlots[2] == ours)
            await live.end()
        }

        // MARK: Firmware and bad keys

        @Test func liveCoreFirmwareBelow11ReportsTheContractMessage() async {
            let radio = await makeLiveCoreRadio(fwVer: 10)
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor { $0 == liveCoreTooOld }, "events: \(live.run.events.value)")
            #expect(await liveCoreSessionIs(live.session, .disconnected(reason: nil)), "released within 5 s")
            #expect(live.run.count(isLiveCoreConnected) == 0, "events: \(live.run.events.value)")
            #expect(radio.frames(0x1F) == 0, "the channels were never read")
            #expect(radio.setChannelFrames == [])
            await live.end()
        }

        /// The session itself ends on firmware below 3; the mapper turns its reason into Contract 2's text.
        @Test func liveCoreFirmwareBelow3ReportsTheContractMessage() async {
            let radio = await makeLiveCoreRadio(fwVer: 2)
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor { $0 == liveCoreTooOld }, "events: \(live.run.events.value)")
            #expect(live.run.count(isLiveCoreConnected) == 0, "events: \(live.run.events.value)")
            await live.end()
        }

        @Test(arguments: [Data(), Data(repeating: 0x41, count: 15), Data(repeating: 0x41, count: 17), Data(count: 16)])
        func liveCoreABadSecretIsRefusedLoudly(_ secret: Data) async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config(secret: secret))
            #expect(await live.run.waitFor { $0 == liveCoreKeyMissing }, "events: \(live.run.events.value)")
            #expect(await liveCoreSessionIs(live.session, .disconnected(reason: nil)), "released within 5 s")
            #expect(live.run.count(isLiveCoreConnected) == 0, "events: \(live.run.events.value)")
            #expect(radio.setChannelFrames == [])
            await live.end()
        }

        // MARK: Reconnect

        @Test func liveCoreReconnectReusesTheSlotItAdded() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            radio.spec.simulateDisconnection()
            let dropped = await liveWaitUntil(timeout: .seconds(10)) { liveCoreDroppedAfterConnecting(live.run.events.value) }
            #expect(dropped, "events: \(live.run.events.value)")
            let back = await liveWaitUntil(timeout: .seconds(10)) { live.run.count(isLiveCoreConnected) == 2 }
            #expect(back, "events: \(live.run.events.value)")
            #expect(radio.setChannelFrames.count == 1, "frames: \(radio.setChannelFrames)")
            await live.end()
        }

        /// Review Focus 2: the link drops between `channels()` and `setChannel`.
        @Test func liveCoreLinkLostDuringThePolicyReportsNoConnected() async {
            let radio = await makeLiveCoreRadio()
            radio.device.silentCommands = [0x20]   // the write is recorded, never answered or stored
            let live = startLiveCore(radio, radio.config())
            let writing = await liveWaitUntil { radio.frames(0x20) == 1 }
            #expect(writing, "precondition: the policy is writing our slot")
            radio.device.silentCommands = []
            radio.spec.simulateDisconnection()
            let back = await live.run.waitFor(timeout: .seconds(15), isLiveCoreConnected)
            #expect(back, "a later attempt connects: events: \(live.run.events.value)")
            let events = live.run.events.value
            #expect(live.run.count(isLiveCoreConnected) == 1, "events: \(events)")
            #expect(live.run.count(isLiveCoreUnavailable) == 0, "events: \(events)")
            let drop = events.firstIndex(of: .disconnected(reason: nil))
            let up = events.firstIndex(where: isLiveCoreConnected)
            #expect(drop != nil && up != nil && drop! < up!, "the only .connected follows the drop: \(events)")
            #expect(radio.device.channelSlots.filter { $0.secret == liveCoreKey }
                    == [MeshCoreChannel(index: 1, name: "RNSTunnel", secret: liveCoreKey)], "added once")
            await live.end()
        }

        @Test func liveCoreComesBackAfterABluetoothPowerCycle() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            CBMCentralManagerMock.simulatePowerOff()
            let dropped = await liveWaitUntil(timeout: .seconds(10)) { liveCoreDroppedAfterConnecting(live.run.events.value) }
            #expect(dropped, "events: \(live.run.events.value)")
            CBMCentralManagerMock.simulatePowerOn()
            let back = await liveWaitUntil(timeout: .seconds(15)) { live.run.count(isLiveCoreConnected) == 2 }
            #expect(back, "events: \(live.run.events.value)")
            await live.end()
        }

        // MARK: Removal

        @Test func liveCoreRemoveChannelClearsOurSlot() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            #expect(radio.device.channelSlots[1].secret == liveCoreKey, "precondition: our slot")
            #expect(await live.driver.removeChannel())
            #expect(radio.device.channelSlots[1] == liveCoreEmptySlot(1))
            await live.end()
        }

        @Test func liveCoreRemoveChannelClearsNothingElse() async {
            let radio = await makeLiveCoreRadio(channels: liveCoreSlots(liveCoreForeignSlot(2), liveCoreForeignSlot(3)))
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            let before = radio.device.channelSlots
            let written = radio.setChannelFrames.count
            #expect(await live.driver.removeChannel())
            let after = radio.device.channelSlots
            #expect(after.indices.filter { $0 != 1 }.allSatisfy { after[$0] == before[$0] }, "slots: \(after)")
            #expect(Array(radio.setChannelFrames.dropFirst(written)) == [LiveCoreSetChannel(1, "", liveCoreZeroKey)])
            await live.end()
        }

        /// The person moved our channel in the MeshCore app: clear where it is now.
        @Test func liveCoreRemoveChannelRereadsTheRadio() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            radio.device.channelSlots = liveCoreSlots(MeshCoreChannel(index: 4, name: "RNSTunnel", secret: liveCoreKey))
            let written = radio.setChannelFrames.count
            #expect(await live.driver.removeChannel())
            #expect(Array(radio.setChannelFrames.dropFirst(written)) == [LiveCoreSetChannel(4, "", liveCoreZeroKey)])
            #expect(radio.device.channelSlots[4] == liveCoreEmptySlot(4))
            await live.end()
        }

        @Test func liveCoreRemoveChannelBeforeConnectedReturnsFalse() async {
            let radio = await makeLiveCoreRadio()
            radio.device.silentCommands = [0x01]
            let live = startLiveCore(radio, radio.config())
            #expect(await liveCoreSessionIs(live.session, .configuring), "precondition: the handshake started")
            #expect(!(await live.driver.removeChannel()))
            #expect(radio.setChannelFrames == [])
            await live.end()
        }

        @Test func liveCoreRemoveChannelRefusedReturnsFalse() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            radio.device.errorReplies = [0x20: 6]
            #expect(!(await live.driver.removeChannel()))
            await live.end()
        }

        @Test func liveCoreRemoveChannelReturnsWhenTheRadioIsSilent() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor(isLiveCoreConnected), "precondition: connected")
            radio.device.silentCommands = [0x1F]
            let result = LockIsolated<Bool?>(nil)
            let driver = live.driver
            Task {
                let ok = await driver.removeChannel()
                result.setValue(ok)
            }
            // The session's command timeout is 5 s.
            let returned = await liveWaitUntil(timeout: .seconds(10)) { result.value != nil }
            #expect(returned)
            #expect(result.value == false)
            await live.end()
        }

        // MARK: Stop and retry

        @Test func liveCoreStopReturnsWhileTheHandshakeIsStuck() async {
            let radio = await makeLiveCoreRadio()
            radio.device.silentCommands = [0x01]
            let live = startLiveCore(radio, radio.config())
            #expect(await liveCoreSessionIs(live.session, .configuring), "precondition: the handshake started")
            let driver = live.driver
            #expect(await returnsWithin(.seconds(5)) { await driver.stop() })
            live.run.cancel()
        }

        /// CoreBluetooth connects never time out.
        @Test func liveCoreStopReturnsWhileTheRadioIsOutOfRange() async {
            let radio = await makeLiveCoreRadio()
            radio.spec.simulateProximityChange(.outOfRange)
            let live = startLiveCore(radio, radio.config())
            #expect(await liveCoreSessionIs(live.session, .connecting), "precondition: the connect is pending")
            let driver = live.driver
            #expect(await returnsWithin(.seconds(5)) { await driver.stop() })
            live.run.cancel()
        }

        /// The adapter's connect is an unstructured hop onto the session actor; a stop issued at
        /// once must still leave nothing connected. Whether the connect lands before or after
        /// stop's first disconnect is a race, so the cycle runs 20 times; each start is at
        /// background priority, so its connect task (which inherits it) tends to arrive AFTER
        /// that disconnect: the case the drain loop exists for. After each stop the session must
        /// stay disconnected for a bounded 200 ms watch.
        @Test func liveCoreStopRightAfterStartLeavesTheSessionDisconnected() async {
            let radio = await makeLiveCoreRadio()
            let config = radio.config()
            var cameBack: [Int: [MeshCoreEvent]] = [:]
            for attempt in 0..<20 {
                let session = MeshCoreSession(central: radio.central, appName: "ReTiCATests")
                let driver = MeshCoreDriver.live(session: session)
                let stream = await Task(priority: .background) { driver.start(config) }.value
                let run = LiveCoreDriverRun(stream)
                await driver.stop()
                let other = LockIsolated<[MeshCoreEvent]>([])
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

        @Test func liveCoreUnknownRadioIsUnavailable() async {
            let radio = await makeLiveCoreRadio()
            let live = startLiveCore(radio, MeshCoreDriverConfig(radio: UUID(), channelSecret: liveCoreKey))
            #expect(await live.run.waitFor { $0 == liveCoreRadioNotFound }, "events: \(live.run.events.value)")
            await live.end()
        }

        /// `MeshCoreInterface` restarts from `.unavailable` without a stop, and the hub replays the
        /// terminal `.disconnected("radio not found")` to the retry's new subscription. The retry
        /// reports its own end only. `stop` ends the retry's stream with a `.disconnected`, ordered
        /// after everything the retry could have reported.
        @Test func liveCoreRetryOfAnUnknownRadioReportsOnlyItsOwnEnd() async {
            let radio = await makeLiveCoreRadio()
            let session = MeshCoreSession(central: radio.central, appName: "ReTiCATests")
            let driver = MeshCoreDriver.live(session: session)
            let unknown = MeshCoreDriverConfig(radio: UUID(), channelSecret: liveCoreKey)
            let first = LiveCoreDriverRun(driver.start(unknown))
            #expect(await first.waitFor { $0 == liveCoreRadioNotFound }, "events: \(first.events.value)")
            let retry = LiveCoreDriverRun(driver.start(unknown))
            #expect(await retry.waitFor { $0 == liveCoreRadioNotFound }, "events: \(retry.events.value)")
            await driver.stop()
            #expect(await retry.waitFor { $0 == .disconnected(reason: nil) }, "events: \(retry.events.value)")
            #expect(retry.count(isLiveCoreUnavailable) == 1, "events: \(retry.events.value)")
            first.cancel()
            retry.cancel()
        }

        @Test func liveCoreReportsAPoweredOffAdapter() async {
            let radio = await makeLiveCoreRadio(initialState: .poweredOff)
            let live = startLiveCore(radio, radio.config())
            #expect(await live.run.waitFor { $0 == .unavailable(.poweredOff) }, "events: \(live.run.events.value)")
            await live.end()
        }
    }
}
