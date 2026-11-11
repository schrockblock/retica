import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCATransport
@testable import ReTiCA
@testable import ReTiCAInterfaces

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

/// One lxmd with the configuration a fresh lxmd writes for a propagation node: `enable_node = yes`,
/// autopeer on at depth 6, peering cost 18, stamp cost 16 (flexibility 3). Logs at verbose (5) to
/// `log`, so a test can read "Peered with" and "Syncing N messages to peer ... completed".
@MainActor
private final class DefaultLXMD {
    let dir = NSTemporaryDirectory() + "retica-peer-pn-\(UUID().uuidString.prefix(8))"
    let port = Int.random(in: 42000..<48000)
    let identity = Identity()
    private var process: Process?
    var log: String { (try? String(contentsOfFile: "\(dir)/lxmd.log", encoding: .utf8)) ?? "" }
    var propagationHash: Data {
        Destination.hash(identityHash: identity.hash, appName: LXMessage.appName, aspects: ["propagation"])
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
          loglevel = 5

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
        announce_interval = 360
        announce_at_start = yes
        autopeer = yes
        autopeer_maxdepth = 6

        [lxmf]
        display_name = ReTiCA peering test
        announce_at_start = no

        [logging]
        loglevel = 5
        """.write(toFile: "\(dir)/lxmd/config", atomically: true, encoding: .utf8)
        try identity.privateKey!.write(to: URL(fileURLWithPath: "\(dir)/lxmd/identity"))
        fm.createFile(atPath: "\(dir)/lxmd.log", contents: nil)
    }

    func start() throws {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: pythonPath!)
        p.arguments = ["-u", "-m", "LXMF.Utilities.lxmd", "--config", "\(dir)/lxmd", "--rnsconfig", "\(dir)/rns"]
        let out = FileHandle(forWritingAtPath: "\(dir)/lxmd.log")
        p.standardOutput = out
        p.standardError = out
        try p.run()
        process = p
    }

    /// Whether lxmd's message store holds `transientId` (files are named `<tid hex>_<received>_…`).
    func stores(_ transientId: Data) -> Bool {
        let files = (try? FileManager.default.contentsOfDirectory(atPath: "\(dir)/lxmd/storage/lxmf/messagestore")) ?? []
        return files.contains { $0.hasPrefix(transientId.hexString) }
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

    /// A default lxmd and our service node, both propagation nodes, announce and peer with each other.
    /// A message a client stores at lxmd reaches our node through lxmd's offer (lxmd logs "Peered with"
    /// us and "Syncing 1 messages to peer … completed"); a message a client stores at our node reaches
    /// lxmd's message store through ours. The client is a ReTiCA `LXMFNode` on lxmd's interface, which
    /// reaches our node through lxmd's transport. Our peering cost is 12 so lxmd's key search is quick;
    /// lxmd keeps its default 18, which our node mines for.
    @Test func liveLxmdPeersWithServiceNode() async throws {
        let lxmd = try DefaultLXMD()
        defer { lxmd.stop(); lxmd.remove() }
        try lxmd.start()
        try await Task.sleep(for: .seconds(2))           // lxmd binds its port; it announces at 10 s

        let nodeIdentity = Identity()
        let ourProp = Destination.hash(identityHash: nodeIdentity.hash, appName: LXMessage.appName, aspects: ["propagation"])
        let node = Store(initialState: LXMFServiceNode.State(
            identity: nodeIdentity,
            endpoint: TCPEndpoint.State(host: "127.0.0.1", port: UInt16(lxmd.port), reconnectOnDrop: true),
            peering: .init(peeringCost: 12))) { LXMFServiceNode() } withDependencies: {
            $0.context = .live
            // Each store its own pool: the live pool is keyed by host:port, and two stores dialling
            // the same lxmd through one pool would share one socket and tear each other down.
            $0.tcpConnectionPool = TCPConnectionPool.liveValue
        }
        let client = Store(initialState: Harness.State(node: LXMFNode.State(
            identity: Identity(),
            endpoint: TCPEndpoint.State(host: "127.0.0.1", port: UInt16(lxmd.port), reconnectOnDrop: true)))) {
            Harness()
        } withDependencies: {
            $0.context = .live
            $0.tcpConnectionPool = TCPConnectionPool.liveValue
        }
        defer { node.send(.client(.endpoint(.stop))); client.send(.node(.endpoint(.stop))) }
        node.send(.client(.endpoint(.start)))
        client.send(.node(.endpoint(.start)))
        try await Task.sleep(for: .seconds(1))
        node.send(.setNodeMode(true))                     // announces, starts the 24 s job

        // Each peers with the other: lxmd from our announce, ours from lxmd's start announce.
        let peered = await poll(seconds: 60) { node.state.peering.peers[lxmd.propagationHash] != nil
            && lxmd.log.contains("Peered with \(RNSHex.pretty(ourProp))") ? true : nil }
        #expect(peered == true, "ours: \(node.state.peering.peers.keys.map(\.hexString)); lxmd log:\n\(lxmd.log)")

        let recipient = Identity()
        let recipientHash = LXMessage.deliveryHash(identityHash: recipient.hash)
        client.send(.node(.endpoint(.transport(.rehydrateKnownDestinations([
            recipientHash: KnownDestination(identity: Identity(publicKey: recipient.publicKey)!, appData: nil,
                                            lastHeard: Date()),
        ])))))

        // lxmd → ours.
        client.send(.node(.setPropagationNode(destinationHash: lxmd.propagationHash)))
        client.send(.node(.sendViaPropagation(destinationHash: recipientHash, title: Data("1".utf8),
                                              content: Data("stored at lxmd".utf8))))
        let first = await poll(seconds: 150) { node.state.pn.store.transientIds.first }
        #expect(first != nil, "lxmd log:\n\(lxmd.log)")
        let synced = await poll(seconds: 30) { lxmd.log.contains("Syncing 1 messages to peer \(RNSHex.pretty(ourProp)) completed") ? true : nil }
        #expect(synced == true)
        if let first {
            // Handled for lxmd, the peer it came from: never offered back.
            #expect(node.state.peering.peers[lxmd.propagationHash]?.handled.contains(first) == true)
        }

        // Ours → lxmd. The client reaches our node through lxmd's transport.
        let ourPath = await poll(seconds: 30) { client.state.node.endpoint.learned[ourProp] != nil ? true : nil }
        #expect(ourPath == true)
        client.send(.node(.setPropagationNode(destinationHash: ourProp)))
        client.send(.node(.sendViaPropagation(destinationHash: recipientHash, title: Data("2".utf8),
                                              content: Data("stored at ReTiCA".utf8))))
        let second = await poll(seconds: 150) { node.state.pn.store.transientIds.first { $0 != first } }
        #expect(second != nil)
        if let second {
            let atLxmd = await poll(seconds: 120) { lxmd.stores(second) ? true : nil }
            #expect(atLxmd == true, "ours: \(String(describing: node.state.peering.peers[lxmd.propagationHash])); lxmd log:\n\(lxmd.log)")
            #expect(node.state.peering.peers[lxmd.propagationHash]?.handled.contains(second) == true)
        }
    }
}

/// `RNS.prettyhexrep`: `<hex>` in angle brackets.
private enum RNSHex {
    static func pretty(_ data: Data) -> String { "<\(data.hexString)>" }
}
