import Foundation
@preconcurrency import CoreBluetooth
import FCBComposable
import MeshtasticKit

/// What an app needs to run Meshtastic live, without naming FCB itself.
public enum MeshtasticLive {
    /// A session over FCB's process-wide live central — the same `BluetoothCentralClient.liveValue`
    /// `BLEDriver.liveValue` uses, so BLE and the radio share the ONE central (spec §2). The caller
    /// owns it and must `disconnect()` it before dropping it (its reconnect loop retains it).
    public static func makeSession() -> MeshtasticSession {
        MeshtasticSession(central: .liveValue)
    }

    /// `scanRadios(central:)` over the live central.
    public static func scanRadios() -> AsyncStream<DiscoveredRadio> {
        scanRadios(central: .liveValue)
    }

    /// `MeshtasticScanner.scan(central:)`, plus the end it lacks: the stream FINISHES when the
    /// adapter is unauthorized or unsupported (MeshtasticScanner waits for `.poweredOn` forever),
    /// so a radio picker never spins on an adapter that cannot scan. It also finishes when the
    /// scanner does. Cancelling the consumer ends the FCB scan.
    public static func scanRadios(central: BluetoothCentralClient) -> AsyncStream<DiscoveredRadio> {
        AsyncStream { continuation in
            let scan = Task {
                for await radio in MeshtasticScanner.scan(central: central) { continuation.yield(radio) }
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
