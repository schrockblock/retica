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

/// The hub's stderr goes here (`/tmp/ReTiCA`, the repo's temp folder), so a failure can be read.
private let hubLogDirectory = "/tmp/ReTiCA"

@Suite(.serialized, .enabled(if: pythonPath != nil), .timeLimit(.minutes(2)))
@MainActor struct LiveTunnelSynthesisTests {
    @Test func aRealHubFilesOurTunnelOnConnect() async throws {
        let dir = NSTemporaryDirectory() + "retica-tunnel-\(UUID().uuidString.prefix(8))"
        try FileManager.default.createDirectory(atPath: hubLogDirectory, withIntermediateDirectories: true)
        let stderrPath = "\(hubLogDirectory)/live-tunnel-hub-\(UUID().uuidString.prefix(8)).stderr"
        FileManager.default.createFile(atPath: stderrPath, contents: nil)
        let stderr = try #require(FileHandle(forWritingAtPath: stderrPath))
        let hub = Process()
        hub.executableURL = URL(fileURLWithPath: pythonPath!)
        hub.arguments = ["-u", hubScript, "--dir", dir, "--listen", "\(hubPort)"]
        hub.standardOutput = FileHandle.nullDevice
        hub.standardError = stderr
        try hub.run()
        defer {
            if hub.isRunning { hub.terminate() }
            hub.waitUntilExit()
            try? stderr.close()
            try? FileManager.default.removeItem(atPath: dir)
        }
        func tunnels() -> [String]? {
            (try? String(contentsOfFile: "\(dir)/tunnels", encoding: .utf8))
                .map { $0.split(separator: "\n").map(String.init) }
        }
        /// The hub's stderr so far, for a failure message.
        func hubErrors() -> String {
            (try? String(contentsOfFile: stderrPath, encoding: .utf8)) ?? "(\(stderrPath) unreadable)"
        }
        // The hub is up (it writes the file from its first loop), with no tunnel yet. A hub that
        // exits instead (port in use, interface down: hub.py's HUB-FAILED) ends the wait at once.
        let started = await poll(seconds: 30) { () -> Bool? in
            if tunnels() != nil { return true }
            return hub.isRunning ? nil : false
        }
        guard started == true else {
            let reason = hub.isRunning ? "no tunnels file after 30 s" : "exited with status \(hub.terminationStatus)"
            Issue.record("The hub did not start (\(reason)). Its stderr, \(stderrPath):\n\(hubErrors())")
            return
        }
        #expect(tunnels()?.isEmpty == true)

        let tunnel = Identity()
        let client = TCPEndpoint.State(host: "127.0.0.1", port: hubPort, reconnectOnDrop: true)
        let store = Store(initialState: .tcp(client)) {
            TransportEndpoint()
        } withDependencies: { $0.context = .live }
        store.send(.setTunnelIdentity(tunnel))
        store.send(.start)
        defer { store.send(.stop) }

        // Ruling 9c': under the client's own interface id.
        let expected = Transport.tunnelID(publicKey: tunnel.publicKey,
                                          interfaceHash: Transport.tunnelInterfaceHash(interfaceID: client.interfaceID)).hexString
        let filed = await poll(seconds: 30) { tunnels()?.contains(expected) == true ? true : nil }
        #expect(filed == true, "the hub's Transport.tunnels never listed \(expected); hub stderr: \(hubErrors())")
        #expect(store.state.transport.transportIdentity == nil)
    }
}
