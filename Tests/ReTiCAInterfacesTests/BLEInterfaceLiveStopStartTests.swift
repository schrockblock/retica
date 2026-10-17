import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import FCBComposable

/// A peripheral client that powers on and records whether it is advertising.
private final class AdvertisingFlag: @unchecked Sendable {
    let on = LockIsolated(false)
}

@MainActor
private func advertisingPeripheralClient(_ flag: AdvertisingFlag) -> BluetoothPeripheralClient {
    var client = noopPeripheralClient()
    client.state = { AsyncStream { $0.yield(.poweredOn) } }
    client.startAdvertising = { _ in flag.on.setValue(true) }
    client.stopAdvertising = { flag.on.setValue(false) }
    return client
}

@MainActor
private func mainActorPoll(within seconds: Double, _ condition: @MainActor () -> Bool) async -> Bool {
    for _ in 0..<Int(seconds * 100) {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 10_000_000)
    }
    return condition()
}

extension FCBDriverAdapterCBMTests {
    /// BLEInterface over the LIVE FCB adapter. The adapter's `stop()` ends whatever session is
    /// live when it runs, so a stop that reaches it after the next start's session began kills
    /// that session: scanning and advertising stop, and the interface stays `.online` with no
    /// driver behind it.
    @Suite @MainActor
    struct BLEInterfaceLiveStopStartTests {
        @Test func aStartRightAfterAStopSurvivesAStopThatReachesTheAdapterLate() async {
            let rig = await makeCoexistRig(bleInterval: 0.01)
            let advertising = AdvertisingFlag()
            let live = BLEDriver.fcb(central: rig.central, peripheral: advertisingPeripheralClient(advertising))
            var driver = live
            // The stop reaches the adapter 100 ms after the reducer launched it: any scheduling
            // delay of that effect behaves the same way.
            driver.stop = {
                try? await Task.sleep(for: .milliseconds(100))
                await live.stop()
            }
            let store = Store(initialState: BLEInterface.State(localIdentity: adapterLocalIdentity, keepaliveInterval: nil)) {
                BLEInterface()
            } withDependencies: {
                $0.bleDriver = driver
                $0.continuousClock = ContinuousClock()
                $0.bleDate = DateGenerator { Date() }
            }
            store.send(.start)
            #expect(await mainActorPoll(within: 6) { store.status == .online },
                    "precondition: BLE came online")

            store.send(.stop)
            store.send(.start)
            // Polled, not a fixed sleep: under a loaded run the new session can take seconds to come up.
            let up = await mainActorPoll(within: 8) {
                store.status == .online && rig.manager.isScanning && advertising.on.value
            }
            #expect(up, "the new session never came up (status \(store.status))")
            // Long enough for a stop still in flight to land: the new session must outlive it.
            try? await Task.sleep(nanoseconds: 500_000_000)
            #expect(store.status == .online)
            #expect(rig.manager.isScanning, "the late stop killed the new session's scan")
            #expect(advertising.on.value, "the late stop killed the new session's advertisement")

            store.send(.stop)
            #expect(await mainActorPoll(within: 3) { store.isIdle }, "the final stop did not return")
        }
    }
}
