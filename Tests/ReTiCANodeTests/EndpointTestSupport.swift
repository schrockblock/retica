import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport
@testable import ReTiCANode

// MARK: - Task-1b endpoint-internal test support
//
// The Task-1b hoist turned `TransportEndpoint.State` from a sum (.tcp/.ble) into a struct
// product with a SHARED `transport`/`linkPlane` and thin, kind-indexed driver slots. The
// endpoint-internal test suites (`TCPEndpointTests`, `BLEEndpointTests`, `BLEEndpointLinkTests`,
// `BLEEndpointIntegrationTests`, `PNNode*Tests`) previously drove the drivers STANDALONE, reading
// the driver's own `transport`/`linkPlane`. They now drive the unified `TransportEndpoint`
// surface instead. These constructors wrap a bare driver into a `TransportEndpoint.State` so the
// suites' construction lines change in ONE place per call, and behavioural coverage is preserved
// against the shared router / link plane.

/// A `TransportEndpoint.State` running a single TCP-client driver. Same argument shape as the old
/// `TCPEndpoint.State(host:port:...)` so construction sites only swap the type name.
func tcpDriverEndpoint(host: String, port: UInt16, reconnectOnDrop: Bool = true,
                       interfaceID: InterfaceID = InterfaceID("tcp"),
                       profile: InterfaceProfile = .tcp) -> TransportEndpoint.State {
    .tcp(TCPEndpoint.State(host: host, port: port, reconnectOnDrop: reconnectOnDrop,
                           interfaceID: interfaceID, profile: profile))
}

/// A `TransportEndpoint.State` running a BLE driver keyed by `localIdentity`.
func bleDriverEndpoint(localIdentity: Data = Data(repeating: 0x5A, count: 16),
                       maxPeers: Int = BLEInterface.defaultMaxPeers,
                       profile: InterfaceProfile = .ble) -> TransportEndpoint.State {
    .ble(BLEEndpoint.State(localIdentity: localIdentity, maxPeers: maxPeers, profile: profile))
}
