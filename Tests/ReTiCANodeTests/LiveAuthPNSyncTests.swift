import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCATransport
@testable import ReTiCA

// LIVE INTEROP: a real LXMFNode syncs over TCP from a real lxmd that requires authentication. Off by
// default.
//
//   RETICA_LIVE_PN_PYTHON=/Users/ell/opt/anaconda3/envs/rns-latest/bin/python \
//     swift test --no-parallel --filter LiveAuthPNSyncTests
//
// lxmd (LXMF 1.3.0) runs as its own transport-enabled TCP server. Its identity is ours to choose, so
// the test knows the node's propagation destination before it starts.

private let pythonPath = ProcessInfo.processInfo.environment["RETICA_LIVE_PN_PYTHON"]

/// One lxmd process with `auth_required = yes`, its `allowed` file holding `allowed`.
@MainActor
private final class AuthLXMD {
    let dir = NSTemporaryDirectory() + "retica-auth-pn-\(UUID().uuidString.prefix(8))"
    let port = Int.random(in: 42000..<48000)
    let identity = Identity()
    private var process: Process?

    var propagationHash: Data {
        Destination(kind: .single, direction: .in, appName: LXMessage.appName, aspects: ["propagation"],
                    identity: identity)!.hash
    }

    init() throws {
        let fm = FileManager.default
        try fm.createDirectory(atPath: "\(dir)/rns", withIntermediateDirectories: true)
        try fm.createDirectory(atPath: "\(dir)/lxmd", withIntermediateDirectories: true)
        try """
        [reticulum]
          enable_transport = yes
          share_instance = no

        [logging]
          loglevel = 4

        [interfaces]
          [[TCP]]
            type = TCPServerInterface
            listen_ip = 127.0.0.1
            listen_port = \(port)
            enabled = yes
        """.write(toFile: "\(dir)/rns/config", atomically: true, encoding: .utf8)
        try """
        [propagation]
        enable_node = yes
        auth_required = yes
        autopeer = no
        announce_at_start = yes

        [lxmf]
        display_name = ReTiCA auth test
        announce_at_start = no

        [logging]
        loglevel = 4
        """.write(toFile: "\(dir)/lxmd/config", atomically: true, encoding: .utf8)
        try identity.privateKey!.write(to: URL(fileURLWithPath: "\(dir)/lxmd/identity"))
    }

    func allow(_ identityHashes: [Data]) throws {
        try identityHashes.map(\.hexString).joined(separator: "\n")
            .write(toFile: "\(dir)/lxmd/allowed", atomically: true, encoding: .utf8)
    }

    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath!)
        p.arguments = ["-u", "-m", "LXMF.Utilities.lxmd", "--config", "\(dir)/lxmd", "--rnsconfig", "\(dir)/rns"]
        p.standardOutput = FileHandle(forWritingAtPath: "/dev/null")
        p.standardError = FileHandle(forWritingAtPath: "/dev/null")
        try p.run()
        process = p
    }

    func stop() {
        process?.terminate()
        process?.waitUntilExit()
        process = nil
    }

    func remove() { try? FileManager.default.removeItem(atPath: dir) }
}

@Reducer
private struct Harness {
    @ObservableState
    struct State: Equatable { var node: LXMFNode.State }
    enum Action { case node(LXMFNode.Action) }
    var body: some ReducerOf<Self> {
        Scope(state: \.node, action: \.node) { LXMFNode() }
    }
}

@MainActor
private func poll<T>(seconds: Double, _ value: () -> T?) async -> T? {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if let found = value() { return found }
        try? await Task.sleep(for: .milliseconds(200))
    }
    return value()
}

@Suite(.serialized, .enabled(if: pythonPath != nil), .timeLimit(.minutes(6)))
@MainActor struct LiveAuthPNSyncTests {
    /// An identity outside `allowed` gets `ERROR_NO_ACCESS` and lands in `noAccess`, which the close
    /// keeps. Allowed after a restart, the same identity syncs to `complete`.
    @Test func anAuthRequiredNodeRefusesThenServesOnceAllowed() async throws {
        let lxmd = try AuthLXMD()
        defer { lxmd.stop(); lxmd.remove() }
        try lxmd.allow([])
        try lxmd.start()

        let identity = Identity()
        let store = Store(initialState: Harness.State(node: LXMFNode.State(
            identity: identity,
            endpoint: TCPEndpoint.State(host: "127.0.0.1", port: UInt16(lxmd.port), reconnectOnDrop: true)))) {
            Harness()
        } withDependencies: { $0.context = .live }
        defer { store.send(.node(.endpoint(.stop))) }
        try await Task.sleep(for: .seconds(2))           // lxmd binds its port
        store.send(.node(.endpoint(.start)))
        store.send(.node(.setPropagationNode(destinationHash: lxmd.propagationHash)))

        func syncUntil(_ goal: LXMFRouter.PropagationTransferState, seconds: Double) async -> LXMFRouter.PropagationTransferState? {
            var lastSync = Date.distantPast
            return await poll(seconds: seconds) { () -> LXMFRouter.PropagationTransferState? in
                let current = store.state.node.router.propagationTransferState
                if current == goal { return current }
                let busy: Set<LXMFRouter.PropagationTransferState> = [.pathRequested, .linkEstablishing, .requestSent]
                if !busy.contains(current), Date().timeIntervalSince(lastSync) > 5 {
                    lastSync = Date()
                    store.send(.node(.syncFromPropagationNode))
                }
                return nil
            }
        }

        // Not allowed: ERROR_NO_ACCESS on the list request.
        let refused = await syncUntil(.noAccess, seconds: 120)
        #expect(refused == .noAccess, "got \(store.state.node.router.propagationTransferState)")
        // The teardown's close must not overwrite it.
        let closed = await poll(seconds: 20) { store.state.node.directLinks[lxmd.propagationHash] == nil ? true : nil }
        #expect(closed == true)
        #expect(store.state.node.router.propagationTransferState == .noAccess)

        // Allowed: restart lxmd with our identity hash in `allowed`.
        lxmd.stop()
        try lxmd.allow([identity.hash])
        try lxmd.start()
        let served = await syncUntil(.complete, seconds: 180)
        #expect(served == .complete, "got \(store.state.node.router.propagationTransferState)")
        #expect(store.state.node.router.propagationTransferLastResult == 0)
    }
}
