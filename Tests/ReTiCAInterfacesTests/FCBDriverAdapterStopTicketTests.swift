import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import FCBComposable

/// Powers on and counts every `startAdvertising` that lands after `stopReturned` was set.
@MainActor
private func zombieWatchingPeripheralClient(stopReturned: LockIsolated<Bool>,
                                            zombieAdvertises: LockIsolated<Int>) -> BluetoothPeripheralClient {
    var client = noopPeripheralClient()
    client.state = { AsyncStream { $0.yield(.poweredOn) } }
    client.startAdvertising = { _ in
        if stopReturned.value { zombieAdvertises.withValue { $0 += 1 } }
    }
    return client
}

extension FCBDriverAdapterCBMTests {
    /// `start()` only spawns the session's bring-up; a `stop()` called after it may run on the
    /// actor before that bring-up does, or before its state tasks first run. Either way the stop
    /// must win: no advertising and no scanning once it returned.
    @Suite @MainActor
    struct FCBDriverAdapterStopTicketTests {
        /// `gateBegin`: `begin` is held until `stop()` returned, so the stop deterministically
        /// reaches the actor first (pins the tickets). Ungated, with the stop from its own task as
        /// the interface issues it: the stop usually lands after `begin` but before the session's
        /// state tasks first run (pins the epoch those tasks capture at spawn).
        @Test(arguments: [true, false])
        func aStopCalledRightAfterStartNeverLeavesASessionUp(gateBegin: Bool) async {
            let rig = await makeCoexistRig(bleInterval: 0.01)
            var zombies: [Int] = []
            for run in 0..<40 {
                let stopReturned = LockIsolated(false)
                let zombieAdvertises = LockIsolated(0)
                let adapter = FCBDriverAdapter(
                    central: rig.central,
                    peripheral: zombieWatchingPeripheralClient(stopReturned: stopReturned,
                                                               zombieAdvertises: zombieAdvertises),
                    beforeBegin: {
                        guard gateBegin else { return }
                        while !stopReturned.value { await Task.yield() }
                    })
                let log = DriverEventLog(adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity)))
                await Task { await adapter.stop() }.value
                stopReturned.setValue(true)
                try? await Task.sleep(for: .milliseconds(150))
                if zombieAdvertises.value > 0 || rig.manager.isScanning { zombies.append(run) }
                log.cancel()
                // A zombie would otherwise leak into the next run's observations.
                if rig.manager.isScanning { await adapter.stop() }
            }
            #expect(zombies.isEmpty, "a session came up after stop() returned in runs \(zombies)")
        }
    }
}
