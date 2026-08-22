import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCATransport

/// End-to-end proof against a real Reticulum TCP node. OFF by default; runs only when
/// RETICA_LIVE_HOST is set. Point it at a local `rnsd` running a TCPServerInterface, or a
/// public testnet node:
///   RETICA_LIVE_HOST=127.0.0.1 RETICA_LIVE_PORT=4242 swift test --filter LiveEndpoint
@MainActor
@Test(.enabled(if: ProcessInfo.processInfo.environment["RETICA_LIVE_HOST"] != nil))
func liveEndpointLearnsAnnouncesFromRealNode() async throws {
    let host = ProcessInfo.processInfo.environment["RETICA_LIVE_HOST"]!
    let port = UInt16(ProcessInfo.processInfo.environment["RETICA_LIVE_PORT"] ?? "4242") ?? 4242

    let store = Store(initialState: .tcp(TCPEndpoint.State(host: host, port: port, reconnectOnDrop: true))) {
        TransportEndpoint()
    }
    store.send(.start)

    // Real Reticulum nodes announce periodically; wait a bounded window for the path table to fill.
    try await Task.sleep(for: .seconds(10))

    #expect(!store.state.transport.learned.isEmpty,
            "Expected to learn at least one announce from \(host):\(port) within 10s")
    store.send(.stop)
}
