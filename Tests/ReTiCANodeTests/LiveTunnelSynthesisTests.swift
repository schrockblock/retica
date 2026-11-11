import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCATransport
@testable import ReTiCA

// LIVE INTEROP: a ReTiCA TCP client synthesizes a tunnel on a real RNS 1.6.0 transport hub. Off by
// default:
//
//   RETICA_LIVE_TUNNEL_PYTHON=/Users/ell/opt/anaconda3/envs/rns-latest/bin/python \
//     swift test --no-parallel --filter LiveTunnelSynthesisTests
//
// The hub is Scripts/tunnelprobe/hub.py on the fixed port 49731, unpatched; it lists the ids in
// `Transport.tunnels`, which only the real `tunnel_synthesize_handler` → `handle_tunnel` fills.

private let pythonPath = ProcessInfo.processInfo.environment["RETICA_LIVE_TUNNEL_PYTHON"]
private let hubScript = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
    .appendingPathComponent("Scripts/tunnelprobe/hub.py").path
private let hubPort: UInt16 = 49731

@MainActor
private func poll<T>(seconds: Double, _ value: () -> T?) async -> T? {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let found = value() { return found }
        try? await Task.sleep(for: .milliseconds(100))
    }
    return value()
}

@Suite(.serialized, .enabled(if: pythonPath != nil), .timeLimit(.minutes(2)))
@MainActor struct LiveTunnelSynthesisTests {
    @Test func aRealHubFilesOurTunnelOnConnect() async throws {
        let dir = NSTemporaryDirectory() + "retica-tunnel-\(UUID().uuidString.prefix(8))"
        let hub = Process()
        hub.executableURL = URL(fileURLWithPath: pythonPath!)
        hub.arguments = ["-u", hubScript, "--dir", dir, "--listen", "\(hubPort)"]
        hub.standardOutput = FileHandle.nullDevice
        hub.standardError = FileHandle.nullDevice
        try hub.run()
        defer {
            hub.terminate()
            hub.waitUntilExit()
            try? FileManager.default.removeItem(atPath: dir)
        }
        func tunnels() -> [String]? {
            (try? String(contentsOfFile: "\(dir)/tunnels", encoding: .utf8))
                .map { $0.split(separator: "\n").map(String.init) }
        }
        // The hub is up (it writes the file from its first loop), with no tunnel yet.
        let before = try #require(await poll(seconds: 30) { tunnels() })
        #expect(before.isEmpty)

        let tunnel = Identity()
        let store = Store(initialState: .tcp(TCPEndpoint.State(host: "127.0.0.1", port: hubPort,
                                                               reconnectOnDrop: true))) {
            TransportEndpoint()
        } withDependencies: { $0.context = .live }
        store.send(.setTunnelIdentity(tunnel))
        store.send(.start)
        defer { store.send(.stop) }

        let expected = Transport.tunnelID(publicKey: tunnel.publicKey,
                                          interfaceHash: Transport.tunnelInterfaceHash(profileName: "tcp")).hexString
        let filed = await poll(seconds: 30) { tunnels()?.contains(expected) == true ? true : nil }
        #expect(filed == true, "the hub's Transport.tunnels never listed \(expected)")
        #expect(store.state.transport.transportIdentity == nil)
    }
}
