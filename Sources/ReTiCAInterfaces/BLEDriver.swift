import Foundation
import Security
import ComposableArchitecture

/// Locally-scoped handle for a remote device (wraps the CBPeer UUID). Pre-HELLO identity —
/// plays the role the bdaddr plays in the Python implementation.
public struct BLEPeerHandle: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

/// Opaque per-channel handle minted by the driver.
public struct BLEChannelID: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

public enum BLEPairingMode: String, Equatable, Sendable {
    case open, paired
}

public struct BLEDriverConfig: Equatable, Sendable {
    public var version: UInt8
    public var pairingMode: BLEPairingMode
    public init(version: UInt8, pairingMode: BLEPairingMode) {
        self.version = version
        self.pairingMode = pairingMode
    }
}

public enum BLEDriverEvent: Equatable, Sendable {
    case ready
    case unavailable(reason: String?)
    case peerDiscovered(BLEPeerHandle)
    case directoryRead(BLEPeerHandle, version: UInt8, psm: UInt16)
    case directoryFailed(BLEPeerHandle, reason: String?)
    case channelOpened(BLEChannelID, BLEPeerHandle, direction: BLEChannelDirection)
    case channelFailed(BLEPeerHandle, reason: String?)
    case channelData(BLEChannelID, Data)
    case channelClosed(BLEChannelID, reason: String?)
}

/// BLE driver dependency. Mechanism only — no policy, no retries, no framing.
/// The live value wraps CoreBluetooth (Task 8); tests inject a mock.
public struct BLEDriver: Sendable {
    public var start: @Sendable (BLEDriverConfig) -> AsyncStream<BLEDriverEvent>
    public var readDirectory: @Sendable (BLEPeerHandle) async -> Void
    public var openChannel: @Sendable (BLEPeerHandle, UInt16) async -> Void
    public var send: @Sendable (BLEChannelID, Data) async -> Void
    public var closeChannel: @Sendable (BLEChannelID) async -> Void
    public var stop: @Sendable () async -> Void

    public init(
        start: @escaping @Sendable (BLEDriverConfig) -> AsyncStream<BLEDriverEvent>,
        readDirectory: @escaping @Sendable (BLEPeerHandle) async -> Void,
        openChannel: @escaping @Sendable (BLEPeerHandle, UInt16) async -> Void,
        send: @escaping @Sendable (BLEChannelID, Data) async -> Void,
        closeChannel: @escaping @Sendable (BLEChannelID) async -> Void,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.start = start
        self.readDirectory = readDirectory
        self.openChannel = openChannel
        self.send = send
        self.closeChannel = closeChannel
        self.stop = stop
    }
}

extension BLEDriver: DependencyKey {
    public static var liveValue: BLEDriver {
        #if canImport(CoreBluetooth) && (os(iOS) || os(macOS))
        return .fcb(central: .liveValue, peripheral: .liveValue)
        #else
        return BLEDriver(start: { _ in .finished }, readDirectory: { _ in },
                         openChannel: { _, _ in }, send: { _, _ in },
                         closeChannel: { _ in }, stop: {})
        #endif
    }

    public static let testValue = BLEDriver(
        start: unimplemented("BLEDriver.start", placeholder: AsyncStream { $0.finish() }),
        readDirectory: unimplemented("BLEDriver.readDirectory"),
        openChannel: unimplemented("BLEDriver.openChannel"),
        send: unimplemented("BLEDriver.send"),
        closeChannel: unimplemented("BLEDriver.closeChannel"),
        stop: unimplemented("BLEDriver.stop")
    )
}

extension DependencyValues {
    public var bleDriver: BLEDriver {
        get { self[BLEDriver.self] }
        set { self[BLEDriver.self] = newValue }
    }
}

// "now" for greylist arithmetic. \.date's testValue is unimplemented in this TCA
// version, so a custom key (same pattern as Transport's \.transportDate).
private enum BLEDateKey: DependencyKey {
    static let liveValue = DateGenerator { Date() }
    static let testValue = DateGenerator { Date(timeIntervalSince1970: 0) }
    static let previewValue = liveValue
}
extension DependencyValues {
    public var bleDate: DateGenerator {
        get { self[BLEDateKey.self] }
        set { self[BLEDateKey.self] = newValue }
    }
}

/// Session-token generation. Live is CSPRNG-backed; test is a deterministic ramp.
/// (ReTiCAInterfaces cannot see ReTiCATransport's RandomBytesGenerator.)
public struct BLERandomBytesGenerator: Sendable {
    public var generate: @Sendable (Int) -> Data
    public init(generate: @escaping @Sendable (Int) -> Data) { self.generate = generate }
    public func callAsFunction(_ count: Int) -> Data { generate(count) }
}
extension BLERandomBytesGenerator: DependencyKey {
    public static let liveValue = BLERandomBytesGenerator { count in
        var bytes = [UInt8](repeating: 0, count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return Data(bytes)
    }
    public static let testValue = BLERandomBytesGenerator { count in
        Data((0..<count).map { UInt8($0 & 0xff) })
    }
    public static let previewValue = testValue
}
extension DependencyValues {
    public var bleRandomBytes: BLERandomBytesGenerator {
        get { self[BLERandomBytesGenerator.self] }
        set { self[BLERandomBytesGenerator.self] = newValue }
    }
}
