import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

/// Checks on the mock driver itself (a harness check, not a production check).
@MainActor
struct RNodeInterfaceHarnessTests {
    /// After `waitForStarts(2)` returns, `h.radio` is the SECOND session's continuation, so a yield
    /// reaches the restarted interface (a yield into the finished first stream would be dropped
    /// and a negative test built on it would pass vacuously).
    @Test func waitForStartsReturnsOnlyOnceTheNewStreamIsInstalled() async {
        let h = await makeOnlineRNodeInterface()
        await h.store.send(.stop)
        await h.store.receive { $0 == .delegate(.offline(reason: nil)) }
        await h.store.send(.start)
        await h.waitForStarts(2)
        #expect(h.radios.value.count == 2, "sessions: \(h.radios.value.count)")
        h.radio.yield(.connected(rnodeTestReport))
        await h.store.receive { if case .delegate(.online) = $0 { return true }; return false }
        #expect(h.store.state.isOnline)
        await stopRNodeInterface(h)
    }
}
