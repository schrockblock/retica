import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
import FCBComposable
import MeshCoreKit
import MeshCoreMock
import ReTiCAInterfaces

/// Our channel key in the live MeshCore tests. Non-zero, and different from every other key.
let liveCoreKey = Data((0..<16).map { UInt8(0x40 &+ $0) })
/// A key another app or person put on the radio.
let liveCoreOtherKey = Data((0..<16).map { UInt8(0x70 &+ $0) })
/// A key this app used before a key change.
let liveCoreRetiredKey = Data((0..<16).map { UInt8(0x90 &+ $0) })
/// What a cleared (or never used) slot holds.
let liveCoreZeroKey = Data(count: 16)

/// Firmware reports `max_channels` 8 (the mock always does), and `channels()` reads 0..<8.
let liveCoreSlotCount = 8

func liveCoreEmptySlot(_ index: Int) -> MeshCoreChannel {
    MeshCoreChannel(index: UInt8(index), name: "", secret: liveCoreZeroKey)
}

let liveCorePublicSlot = MeshCoreChannel(index: 0, name: "Public", secret: MeshCoreGATT.publicChannelSecret)

/// A non-empty slot holding another key, distinct per index.
func liveCoreForeignSlot(_ index: Int) -> MeshCoreChannel {
    MeshCoreChannel(index: UInt8(index), name: "Other\(index)",
                    secret: Data((0..<16).map { UInt8(0x10 &+ $0 &+ UInt8(index) &* 0x11) }))
}

/// Public at 0 and every other slot foreign: no free slot.
func liveCoreFullRadio() -> [MeshCoreChannel] {
    [liveCorePublicSlot] + (1..<liveCoreSlotCount).map(liveCoreForeignSlot)
}

/// One simulated MeshCore radio plus the LIVE FCB client that drives it through CBM.
struct LiveCoreRadio {
    let id: UUID
    let device: MockMeshCoreDevice
    let spec: CBMPeripheralSpec
    let central: BluetoothCentralClient

    func config(secret: Data = liveCoreKey, retired: [Data] = []) -> MeshCoreDriverConfig {
        MeshCoreDriverConfig(radio: id, channelSecret: secret, retiredChannelSecrets: retired)
    }

    /// Every `CMD_SET_CHANNEL` written so far, decoded.
    var setChannelFrames: [LiveCoreSetChannel] { liveCoreSetChannelFrames(device.receivedFrames) }

    /// How many frames with this opcode the radio has received.
    func frames(_ code: UInt8) -> Int {
        device.receivedFrames.filter { $0.first == code }.count
    }
}

/// One decoded `0x20` frame: index, name (up to the first NUL), 16-byte secret.
struct LiveCoreSetChannel: Equatable, CustomStringConvertible {
    var index: UInt8
    var name: String
    var secret: Data

    init(_ index: UInt8, _ name: String, _ secret: Data) {
        self.index = index
        self.name = name
        self.secret = secret
    }

    var description: String { "(\(index), \"\(name)\", \(secret.map { String(format: "%02x", $0) }.joined()))" }
}

/// Decodes the `0x20` frames among `frames`: `20 idx name(32, NUL padded) secret(16)`.
func liveCoreSetChannelFrames(_ frames: [Data]) -> [LiveCoreSetChannel] {
    frames.compactMap { frame in
        let bytes = [UInt8](frame)
        guard bytes.first == 0x20, bytes.count >= 50 else { return nil }
        let name = String(decoding: bytes[2..<34].prefix { $0 != 0 }, as: UTF8.self)
        return LiveCoreSetChannel(bytes[1], name, Data(bytes[34..<50]))
    }
}

/// Resets the CBM simulation and stands up one mock MeshCore radio. `channels` overrides slots
/// from 0 by position and is padded to exactly 8 (Public at 0 unless overridden, the rest empty),
/// because the mock always reports `max_channels` 8 and `channels()` reads every one.
@MainActor
func makeLiveCoreRadio(channels: [MeshCoreChannel] = [], fwVer: UInt8 = 13,
                       initialState: CBMManagerState = .poweredOn) async -> LiveCoreRadio {
    precondition(channels.count <= liveCoreSlotCount, "the mock radio has 8 channel slots")
    CBMCentralManagerMock.tearDownSimulation()
    CBMCentralManagerMock.simulateInitialState(initialState)
    let id = UUID()
    let device = MockMeshCoreDevice(now: { Date(timeIntervalSince1970: 2_000_000_000) }, fwVer: fwVer)
    var slots = [liveCorePublicSlot] + (1..<liveCoreSlotCount).map(liveCoreEmptySlot)
    for (offset, channel) in channels.enumerated() {
        slots[offset] = MeshCoreChannel(index: UInt8(offset), name: channel.name, secret: channel.secret)
    }
    device.channelSlots = slots
    let spec = device.makeSpec(identifier: id)
    CBMCentralManagerMock.simulatePeripherals([spec])
    let central = BluetoothCentralClient.mocked()
    if initialState == .poweredOn { #expect(await liveWaitUntilPoweredOn(central), "precondition: powered on") }
    return LiveCoreRadio(id: id, device: device, spec: spec, central: central)
}

/// `slots` with `channel` placed at its own index (the rest as given, padded like `makeLiveCoreRadio`).
func liveCoreSlots(_ placed: MeshCoreChannel...) -> [MeshCoreChannel] {
    var slots = [liveCorePublicSlot] + (1..<liveCoreSlotCount).map(liveCoreEmptySlot)
    for channel in placed { slots[Int(channel.index)] = channel }
    return slots
}

/// The session's CURRENT connection state is `state` (the hub replays it to a new subscriber).
func liveCoreSessionIs(_ session: MeshCoreSession, _ state: MeshCoreConnectionState,
                       timeout: Duration = .seconds(5)) async -> Bool {
    let seen = LockIsolated(false)
    let stream = session.events()
    let watcher = Task {
        for await event in stream where event == .connection(state) {
            seen.setValue(true)
            return
        }
    }
    defer { watcher.cancel() }
    return await liveWaitUntil(timeout: timeout) { seen.value }
}

/// A MeshCore driver stream consumed in the background. `onEvent` runs on each event as it is
/// consumed, before it is recorded.
final class LiveCoreDriverRun: Sendable {
    let events = LockIsolated<[MeshCoreDriverEvent]>([])
    /// The stream ended (the adapter finished it).
    let finished = LockIsolated(false)
    private let task = LockIsolated<Task<Void, Never>?>(nil)

    init(_ stream: AsyncStream<MeshCoreDriverEvent>,
         onEvent: @escaping @Sendable (MeshCoreDriverEvent) -> Void = { _ in }) {
        let events = self.events
        let finished = self.finished
        task.setValue(Task {
            for await event in stream {
                onEvent(event)
                events.withValue { $0.append(event) }
            }
            finished.setValue(true)
        })
    }

    func cancel() { task.value?.cancel() }

    func waitFor(timeout: Duration = .seconds(10),
                 _ match: @escaping @Sendable (MeshCoreDriverEvent) -> Bool) async -> Bool {
        await liveWaitUntil(timeout: timeout) { self.events.value.contains(where: match) }
    }

    func count(_ match: @Sendable (MeshCoreDriverEvent) -> Bool) -> Int {
        events.value.filter(match).count
    }

    func index(_ match: @Sendable (MeshCoreDriverEvent) -> Bool) -> Int? {
        events.value.firstIndex(where: match)
    }
}

func isLiveCoreConnected(_ event: MeshCoreDriverEvent) -> Bool {
    if case .connected = event { return true }
    return false
}

func isLiveCoreUnavailable(_ event: MeshCoreDriverEvent) -> Bool {
    if case .unavailable = event { return true }
    return false
}

func isLiveCoreDatagram(_ event: MeshCoreDriverEvent) -> Bool {
    if case .datagram = event { return true }
    return false
}
