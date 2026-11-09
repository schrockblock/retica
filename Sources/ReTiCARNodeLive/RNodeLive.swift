import Foundation
@preconcurrency import CoreBluetooth
import FCBComposable
import RNodeKit

/// What an app needs to run an RNode live, without naming FCB itself.
public enum RNodeLive {
    /// A session over FCB's process-wide live central, the same `BluetoothCentralClient.liveValue`
    /// `BLEDriver.liveValue` uses, so BLE and every radio share the ONE central (spec §2). The
    /// session keeps its own `ContinuousClock`: its 30 s handshake and 60 s subscribe bounds sleep on
    /// it, so no clock is ever passed in. The caller owns the session and must `disconnect()` it
    /// before dropping it (its reconnect loop retains it).
    public static func makeSession() -> RNodeSession {
        RNodeSession(central: .liveValue)
    }

    /// `scanRadios(central:)` over the live central.
    public static func scanRadios() -> AsyncStream<DiscoveredRNode> {
        scanRadios(central: .liveValue)
    }

    /// `RNodeScanner.scan(central:)`, plus the end it lacks: the stream FINISHES when the adapter is
    /// unauthorized or unsupported (the scanner waits for `.poweredOn` forever), so a radio picker
    /// never spins on an adapter that cannot scan. Powered off is not terminal: the person can turn
    /// Bluetooth on. It also finishes when the scanner does. Cancelling the consumer ends the FCB scan.
    public static func scanRadios(central: BluetoothCentralClient) -> AsyncStream<DiscoveredRNode> {
        AsyncStream { continuation in
            let scan = Task {
                for await radio in RNodeScanner.scan(central: central) { continuation.yield(radio) }
                continuation.finish()
            }
            let watch = Task {
                for await state in central.state() where state == .unauthorized || state == .unsupported {
                    continuation.finish()
                    return
                }
            }
            continuation.onTermination = { _ in
                scan.cancel()
                watch.cancel()
            }
        }
    }
}
