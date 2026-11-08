import Foundation
@preconcurrency import CoreBluetooth
import FCBComposable
import MeshCoreKit

/// What an app needs to run MeshCore live, without naming FCB itself.
public enum MeshCoreLive {
    /// A session over FCB's process-wide live central, the same `BluetoothCentralClient.liveValue`
    /// `BLEDriver.liveValue` uses, so BLE and the radio share the ONE central (spec §2). The session
    /// keeps its own `ContinuousClock`: its 30 s handshake timeout sleeps on it, so no clock is
    /// ever passed in. The caller owns the session and must `disconnect()` it before dropping it
    /// (its reconnect loop retains it).
    public static func makeSession(appName: String) -> MeshCoreSession {
        MeshCoreSession(central: .liveValue, appName: appName)
    }

    /// `scanRadios(central:)` over the live central.
    public static func scanRadios() -> AsyncStream<DiscoveredMeshCoreRadio> {
        scanRadios(central: .liveValue)
    }

    /// `MeshCoreScanner.scan(central:)`, plus the end it lacks: the stream FINISHES when the
    /// adapter is unauthorized or unsupported (the scanner waits for `.poweredOn` forever), so a
    /// radio picker never spins on an adapter that cannot scan. Powered off is not terminal: the
    /// person can turn Bluetooth on. It also finishes when the scanner does. Cancelling the
    /// consumer ends the FCB scan.
    public static func scanRadios(central: BluetoothCentralClient) -> AsyncStream<DiscoveredMeshCoreRadio> {
        AsyncStream { continuation in
            let scan = Task {
                for await radio in MeshCoreScanner.scan(central: central) { continuation.yield(radio) }
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
