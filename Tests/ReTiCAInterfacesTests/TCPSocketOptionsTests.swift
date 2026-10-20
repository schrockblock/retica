import Testing
import Foundation
@testable import ReTiCAInterfaces

#if canImport(Network)
import Network

// Reference's client socket options (RNS 1.4.2 Interfaces/TCPInterface.py:84-87): without them a
// connection whose far end vanished while the app was suspended stayed `.ready` for ever on resume.
@Test func tcpSocketOptionsProbeAndTimeOutLikeReference() throws {
    let parameters = TCPSocketOptions.parameters()
    let tcp = try #require(parameters.defaultProtocolStack.transportProtocol as? NWProtocolTCP.Options)
    #expect(tcp.enableKeepalive)
    #expect(tcp.keepaliveIdle == 5)
    #expect(tcp.keepaliveInterval == 2)
    #expect(tcp.keepaliveCount == 12)
    #expect(tcp.connectionDropTime == 24)
}
#endif
