import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

#if canImport(Network)
import Network

// Real-socket tests for the LIVE `TCPListener` (`NWListenerActor`). Like `TCPConnectionReconnectTests`,
// these are the only tests that drive the live value over a socket, and the exception is deliberate:
// the defect class they guard against — a callback from a stale/closed connection yielding into, or
// finishing the stream on behalf of, a LATER connection — lives entirely in `NWListenerActor`'s
// per-connection generation-checked callbacks and its `connections[id] != nil` staleness gate. That
// is exactly the layer a mocked `TCPListener` replaces wholesale, so the whole class is invisible to
// the rest of the suite. On this project a mocked `TCPConnection` let precisely this shape of bug
// survive ~996 passing tests and brick the app on device.
//
// Everything here is loopback on an OS-assigned ephemeral port; nothing leaves the machine.
@Suite(.serialized)
struct TCPListenerLiveTests {

    /// Bind and immediately release a loopback `NWListener` to discover a free ephemeral port.
    /// `TCPListener.listen` binds a caller-given port and never reports the actually-bound port
    /// (`.started` carries no port and `NWListenerActor` is private), so port 0 is undiscoverable
    /// through the dependency's API — we must pick the port ourselves. There is a tiny reuse race
    /// between releasing this throwaway listener and `TCPListener.liveValue.listen` re-binding it;
    /// the reconnect suite accepts the same and the suite is `.serialized`.
    ///
    /// Mirrors `TCPConnectionReconnectTests.Loopback`: `NWListener.port` is nil until the listener
    /// reaches `.ready`, so we must poll after `start`. Returning the port also CANCELS the
    /// throwaway listener so `TCPListener.liveValue` can bind it.
    private func freePort() async throws -> UInt16 {
        let l = try NWListener(using: .tcp, on: .any)
        // A `newConnectionHandler` MUST be set before `start`, or Network.framework never drives the
        // listener to `.ready` and `port` stays nil forever. (The precedent's `Loopback` sets one too.)
        l.newConnectionHandler = { $0.cancel() }
        l.start(queue: .global(qos: .userInitiated))
        for _ in 0..<300 {
            if let p = l.port?.rawValue, p != 0 {
                l.cancel()
                return p
            }
            try await Task.sleep(for: .milliseconds(10))
        }
        l.cancel()
        throw CancellationError()
    }

    /// Await the next event on a listener stream, giving up after `timeout` so a finished-or-silent
    /// stream FAILS the test instead of hanging it. Returns nil on stream end or timeout — callers
    /// must treat nil as a failure, never as a satisfied assertion.
    private func next(
        _ stream: AsyncStream<TCPListenerEvent>,
        timeout: Duration = .seconds(3)
    ) async -> TCPListenerEvent? {
        await withTaskGroup(of: TCPListenerEvent?.self) { group in
            group.addTask {
                for await event in stream { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Same helper for the client-side `TCPConnection` stream (the dialing peer).
    private func nextClient(
        _ stream: AsyncStream<TCPEvent>,
        timeout: Duration = .seconds(3)
    ) async -> TCPEvent? {
        await withTaskGroup(of: TCPEvent?.self) { group in
            group.addTask {
                for await event in stream { return event }
                return nil
            }
            group.addTask {
                try? await Task.sleep(for: timeout)
                return nil
            }
            let first = await group.next() ?? nil
            group.cancelAll()
            return first
        }
    }

    /// Drive the listener stream until an `.accepted(id)` arrives (skipping any earlier `.started`),
    /// returning the real minted id. Fails via nil on timeout.
    private func awaitAccepted(_ stream: AsyncStream<TCPListenerEvent>) async -> TCPConnID? {
        for _ in 0..<5 {
            let ev = await next(stream)
            switch ev {
            case let .accepted(id): return id
            case .started: continue          // ignore the one-time bind event
            default: return nil
            }
        }
        return nil
    }

    /// Bring up a LIVE listener on a fresh free port and confirm it reached `.started`, returning
    /// the port, the started listener, and its event stream. Because `freePort` releases the port
    /// before we re-bind it (see the reuse-race note there), an occasional bind collides and the
    /// live listener reports `.failed` instead of `.started`; we retry with a brand-new port rather
    /// than paper over it with a weak assertion. Deterministic once bound: no assertion here is
    /// satisfied by a timed-out nil.
    private func startedListener() async throws -> (UInt16, TCPListener, AsyncStream<TCPListenerEvent>) {
        for _ in 0..<10 {
            let port = try await freePort()
            let listener = TCPListener.liveValue
            let events = listener.listen(port)
            if await next(events) == .started { return (port, listener, events) }
            await listener.stop()                       // failed bind — release and try a new port
            try await Task.sleep(for: .milliseconds(50))
        }
        throw CancellationError()
    }

    // 1. Accept + inbound data path. Drives `handleListenerState(.ready)->.started`,
    //    `accept`/`handleConnState(.ready)->.accepted(id)`, and `handleReceive->.data(id, ...)`.
    @Test func acceptsConnectionAndDeliversInboundBytesWithMatchingID() async throws {
        let (port, listener, events) = try await startedListener()
        defer { Task { await listener.stop() } }

        let client = TCPConnection.liveValue
        defer { Task { await client.close() } }
        let clientEvents = client.open("127.0.0.1", port)
        #expect(await nextClient(clientEvents) == .connected)

        let id = try #require(await awaitAccepted(events), "listener never reported .accepted")

        let frame = Data([0x01, 0x02, 0x03, 0x04, 0xFE])
        await client.send(frame)
        #expect(await next(events) == .data(id, frame))
    }

    // 2. Outbound server->client. Drives `NWListenerActor.send` over the accepted NWConnection's
    //    send path (not just its receive path).
    @Test func sendsOutboundBytesToClient() async throws {
        let (port, listener, events) = try await startedListener()
        defer { Task { await listener.stop() } }

        let client = TCPConnection.liveValue
        defer { Task { await client.close() } }
        let clientEvents = client.open("127.0.0.1", port)
        #expect(await nextClient(clientEvents) == .connected)

        let id = try #require(await awaitAccepted(events), "listener never reported .accepted")

        let payload = Data([0xAB, 0xCD, 0xEF, 0x10, 0x20])
        await listener.send(id, payload)
        #expect(await nextClient(clientEvents) == .data(payload))
    }

    // 3. Two simultaneous connections are independent over real sockets. Directly exercises the
    //    per-connection `connections[id]` routing in `NWListenerActor`: data from client A must
    //    surface as `.data(idA, ...)` (never idB) and vice versa, and closing one must emit
    //    `.closed(idClosed, ...)` while the other keeps delivering.
    @Test func twoConnectionsAreIndependentAndRouteByID() async throws {
        let (port, listener, events) = try await startedListener()
        defer { Task { await listener.stop() } }

        let clientA = TCPConnection.liveValue
        defer { Task { await clientA.close() } }
        let aEvents = clientA.open("127.0.0.1", port)
        #expect(await nextClient(aEvents) == .connected)
        let idA = try #require(await awaitAccepted(events), "listener never accepted client A")

        let clientB = TCPConnection.liveValue
        defer { Task { await clientB.close() } }
        let bEvents = clientB.open("127.0.0.1", port)
        #expect(await nextClient(bEvents) == .connected)
        let idB = try #require(await awaitAccepted(events), "listener never accepted client B")

        #expect(idA != idB)

        // Data from A must arrive tagged idA, byte-exact.
        let frameA = Data([0xA0, 0xA1, 0xA2])
        await clientA.send(frameA)
        #expect(await next(events) == .data(idA, frameA))

        // Data from B must arrive tagged idB, byte-exact — proving routing is per-connection.
        let frameB = Data([0xB0, 0xB1, 0xB2, 0xB3])
        await clientB.send(frameB)
        #expect(await next(events) == .data(idB, frameB))

        // Close A from the listener side; expect `.closed(idA, ...)`.
        await listener.close(idA)
        let closeEv = await next(events)
        guard case let .closed(closedID, _) = closeEv, closedID == idA else {
            Issue.record("expected .closed(idA), got \(String(describing: closeEv))")
            return
        }

        // B must still deliver data after A closed.
        let frameB2 = Data([0xBB, 0xBC])
        await clientB.send(frameB2)
        #expect(await next(events) == .data(idB, frameB2))
    }

    // 4. Client disconnect -> `.closed(id)` surfaces on the listener. Drives `handleReceive`'s
    //    `isComplete`/error path into `dropAndReport`.
    @Test func clientDisconnectSurfacesClosedOnListener() async throws {
        let (port, listener, events) = try await startedListener()
        defer { Task { await listener.stop() } }

        let client = TCPConnection.liveValue
        let clientEvents = client.open("127.0.0.1", port)
        #expect(await nextClient(clientEvents) == .connected)
        let id = try #require(await awaitAccepted(events), "listener never reported .accepted")

        await client.close()

        let ev = await next(events)
        guard case let .closed(closedID, _) = ev, closedID == id else {
            Issue.record("expected .closed(\(id)) on client disconnect, got \(String(describing: ev))")
            return
        }
    }
}
#endif
