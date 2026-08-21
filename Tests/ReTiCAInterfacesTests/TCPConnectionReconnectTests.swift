import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

#if canImport(Network)
import Network

// The ONLY tests in this suite that touch a real socket, and the exception is deliberate: the
// defect they pin lives in the live `NWConnectionActor`'s handling of Network.framework
// callbacks, which is exactly the layer a mocked `TCPConnection` replaces wholesale. A mock
// cannot express "a callback from the PREVIOUS NWConnection arrives after the next one was
// installed", so the whole class of stale-callback bugs is invisible to the rest of the suite —
// it survived 991 passing tests and only showed up on a device after a few background cycles.
//
// Everything here is loopback on an ephemeral port; nothing leaves the machine.
@Suite(.serialized)
struct TCPConnectionReconnectTests {

    /// A loopback TCP listener that keeps its accepted connections alive and can push bytes to
    /// the most recently accepted one.
    private final class Loopback: @unchecked Sendable {
        let listener: NWListener
        private let accepted = LockIsolated<[NWConnection]>([])

        init() throws {
            listener = try NWListener(using: .tcp, on: .any)
            listener.newConnectionHandler = { [accepted] conn in
                conn.start(queue: .global(qos: .userInitiated))
                accepted.withValue { $0.append(conn) }
            }
            listener.start(queue: .global(qos: .userInitiated))
        }

        /// Poll for the OS-assigned port. `NWListener.port` is nil until the listener is ready.
        func port() async throws -> UInt16 {
            for _ in 0..<200 {
                if let p = listener.port?.rawValue, p != 0 { return p }
                try await Task.sleep(for: .milliseconds(10))
            }
            throw CancellationError()
        }

        func acceptedCount() -> Int { accepted.value.count }

        func sendToLatest(_ data: Data) {
            accepted.value.last?.send(content: data, completion: .contentProcessed { _ in })
        }

        func cancel() {
            listener.cancel()
            accepted.withValue { for c in $0 { c.cancel() }; $0 = [] }
        }
    }

    /// Await the next event on `iterator`, giving up after `timeout` so a finished-or-silent
    /// stream fails the test instead of hanging it. Returns nil on stream end or timeout.
    private func next(
        _ stream: AsyncStream<TCPEvent>,
        timeout: Duration = .seconds(3)
    ) async -> TCPEvent? {
        await withTaskGroup(of: TCPEvent?.self) { group in
            group.addTask {
                for await event in stream { return event }
                return nil                                  // stream finished
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil                                  // timed out
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    // Reconnecting on the SAME TCPConnection dependency — which is what the app does after every
    // drop, since `liveValue` builds one `NWConnectionActor` and captures it in all three
    // closures — must deliver the new connection's events on the new stream.
    //
    // Before the generation guard this failed: `start` cancels the previous NWConnection and then,
    // with no suspension point, installs the new continuation. The cancelled connection's
    // `.cancelled` callback hops onto the actor AFTERWARDS and runs `continuation?.finish()` on
    // the continuation it now finds — the NEW one. The new connection then reports `.ready` into
    // an already-finished stream, so the interface's `for await` loop has exited and never sees
    // `.connected`. The socket is genuinely established the whole time; every inbound byte is
    // dropped. That is the "stuck on Disconnected while the node shows a client" symptom.
    @Test func reconnectOnTheSameDependencyStillReportsConnected() async throws {
        let loopback = try Loopback()
        defer { loopback.cancel() }
        let port = try await loopback.port()
        let tcp = TCPConnection.liveValue

        let first = tcp.open("127.0.0.1", port)
        #expect(await next(first) == .connected)

        // Reconnect. This is the exact call the reconnect timer makes.
        let second = tcp.open("127.0.0.1", port)
        #expect(await next(second) == .connected)

        await tcp.close()
    }

    // The stronger half: not just the `.connected` event, but the DATA path. A stale `.cancelled`
    // finishing the live continuation silently drops every inbound byte while `send` keeps working
    // (it writes to the new connection), which is why the node sees a healthy client and the app
    // sees nothing arriving.
    @Test func reconnectStillDeliversInboundBytes() async throws {
        let loopback = try Loopback()
        defer { loopback.cancel() }
        let port = try await loopback.port()
        let tcp = TCPConnection.liveValue

        let first = tcp.open("127.0.0.1", port)
        #expect(await next(first) == .connected)

        let second = tcp.open("127.0.0.1", port)
        #expect(await next(second) == .connected)

        // Wait for the listener to accept the SECOND connection before pushing to it.
        for _ in 0..<200 where loopback.acceptedCount() < 2 {
            try await Task.sleep(for: .milliseconds(10))
        }
        let payload = Data([0xDE, 0xAD, 0xBE, 0xEF])
        loopback.sendToLatest(payload)

        #expect(await next(second) == .data(payload))

        await tcp.close()
    }

    // An unreachable node must report SOMETHING. NWConnection reports connection-refused as
    // `.waiting`, not `.failed`, and `.waiting` used to fall into `default: break` — so dialling a
    // dead node emitted no event at all: the interface sat in `.connecting` for ever and, because
    // the reconnect is armed only by `.disconnected`, never retried. The node connection could then
    // only be recovered by killing the app.
    @Test func dialingAClosedPortReportsDisconnectedRatherThanSilence() async throws {
        // Bind and immediately release a loopback port to get one nothing is listening on.
        let loopback = try Loopback()
        let deadPort = try await loopback.port()
        loopback.cancel()
        try await Task.sleep(for: .milliseconds(50))

        let tcp = TCPConnection.liveValue
        let stream = tcp.open("127.0.0.1", deadPort)

        // Fails as a hang-then-nil if the state is swallowed; passes only on a real event.
        let event = await next(stream)
        guard case .disconnected = event else {
            Issue.record("expected a disconnect for an unreachable port, got \(String(describing: event))")
            await tcp.close()
            return
        }
        await tcp.close()
    }
}
#endif
