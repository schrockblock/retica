import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import ReTiCA

// Outbound TCP frames must reach the connection in the order their `.send`s were reduced.
//
// They used to be written by one `.run` Task PER FRAME, and independent Tasks reach the
// connection actor in no guaranteed order — on a link initiator that let LINKIDENTIFY/REQUEST
// overtake the LRRTT, and the responder (still in `.handshake`) dropped the request.
//
// The fake connection makes the races deterministic instead of probabilistic: chosen frames are
// held on gates the test opens, and a write counts as "on the wire" only once it returns. Like the
// live `NWConnectionActor.send`, the fake IGNORES cancellation — a write that has been issued lands
// even if its writer was cancelled meanwhile. (An earlier fake dropped cancelled writes, and that
// hid a writer that kept going after it was superseded.) No sleeps: the tests only ever wait on
// gates, actions, and `store.finish()`.

/// A one-shot gate that, unlike an `AsyncStream` wait, is NOT released by task cancellation.
private final class Gate: Sendable {
    private let state = LockIsolated<(open: Bool, waiter: CheckedContinuation<Void, Never>?)>((false, nil))

    func wait() async {
        await withCheckedContinuation { (c: CheckedContinuation<Void, Never>) in
            let openAlready = state.withValue { s -> Bool in
                if s.open { return true }
                s.waiter = c
                return false
            }
            if openAlready { c.resume() }
        }
    }

    func open() {
        let waiter = state.withValue { s -> CheckedContinuation<Void, Never>? in
            s.open = true
            defer { s.waiter = nil }
            return s.waiter
        }
        waiter?.resume()
    }
}

/// A connection whose writes of the `gated` frames block until released; every other write lands
/// at once. Cancellation is ignored throughout.
private final class GatedWire: Sendable {
    let wire = LockIsolated<[Data]>([])
    private let gates: [Data: Gate]

    init(gated: [Data]) { gates = Dictionary(uniqueKeysWithValues: gated.map { ($0, Gate()) }) }

    func write(_ data: Data) async {
        if let gate = gates[data] { await gate.wait() }
        wire.withValue { $0.append(data) }
    }
    func release(_ frame: Data) { gates[frame]?.open() }
}

private let raws = (0..<6).map { Data([0x08, 0x00, UInt8($0)]) }
private let frames = raws.map(HDLC.frame)

@MainActor
private func clientStore(_ fake: GatedWire) -> TestStore<TCPClientInterface.State, TCPClientInterface.Action> {
    TestStore(initialState: TCPClientInterface.State(host: "node", port: 4242)) {
        TCPClientInterface()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } },
                                         send: { await fake.write($0) },
                                         close: {})
    }
}

@MainActor
private func serverStore(_ fake: GatedWire) -> TestStore<TCPServerInterface.State, TCPServerInterface.Action> {
    TestStore(initialState: TCPServerInterface.State(port: 4242)) {
        TCPServerInterface()
    } withDependencies: {
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } },
                                     send: { _, data in await fake.write(data) },
                                     close: { _ in }, stop: {})
    }
}

@Test @MainActor func tcpClientWritesFramesInReducedOrder() async {
    let fake = GatedWire(gated: [frames[0]])
    let store = clientStore(fake)

    // Frame 0 starts the single writer; frames 1...5 are reduced while it is still writing, so
    // they must queue behind it rather than race it.
    await store.send(.send(raws[0])) { $0.isWriting = true }
    for i in 1..<raws.count {
        await store.send(.send(raws[i])) { $0.outbox.append(frames[i]) }
    }

    fake.release(frames[0])
    await store.receive(\.writerFinished) {       // batch [0] done → the queued batch starts
        $0.outbox = []
    }
    await store.receive(\.writerFinished) { $0.isWriting = false }

    #expect(fake.wire.value == frames)
}

@Test @MainActor func tcpServerWritesFramesInReducedOrder() async {
    let fake = GatedWire(gated: [frames[0]])
    let store = serverStore(fake)
    let conns = [TCPConnID(1), TCPConnID(2)]

    await store.send(.send(conn: conns[0], raws[0])) { $0.isWriting = true }
    for i in 1..<raws.count {
        await store.send(.send(conn: conns[i % 2], raws[i])) {
            $0.outbox.append(.init(conn: conns[i % 2], framed: frames[i]))
        }
    }

    fake.release(frames[0])
    await store.receive(\.writerFinished) { $0.outbox = [] }
    await store.receive(\.writerFinished) { $0.isWriting = false }

    #expect(fake.wire.value == frames)
}

// MARK: - Writer self-heal (Task 9 follow-up)
//
// A writer that never reports `.writerFinished` (hung, or cancelled from outside) used to leave
// `isWriting` true for ever: every later frame queued and nothing was ever written again. Here the
// first write hangs — its gate stays shut until the very end — which is exactly that lost report.
// A new connection must reset the writer, and what was queued behind the hung write, plus
// everything after, is written in order. The hung write itself was already issued, so (as with the
// live connection) it still lands when it finally completes — last.

@Test @MainActor func tcpClientWriterSelfHealsOnReconnectAfterALostWriterFinished() async {
    let fake = GatedWire(gated: [frames[0]])
    let store = clientStore(fake)

    await store.send(.send(raws[0])) { $0.isWriting = true }            // hangs
    await store.send(.send(raws[1])) { $0.outbox = [frames[1]] }        // stuck behind it

    await store.send(.connectionEvent(.connected)) {
        $0.status = .online
        $0.writerGeneration = 1
        $0.outbox = []                                                   // drained by the new writer
    }
    await store.receive(.writerFinished(generation: 1)) { $0.isWriting = false }

    await store.send(.send(raws[2])) { $0.isWriting = true }
    await store.receive(.writerFinished(generation: 1)) { $0.isWriting = false }
    await store.send(.send(raws[3])) { $0.isWriting = true }
    await store.receive(.writerFinished(generation: 1)) { $0.isWriting = false }
    #expect(fake.wire.value == [frames[1], frames[2], frames[3]])

    fake.release(frames[0])
    await store.finish()
    #expect(fake.wire.value == [frames[1], frames[2], frames[3], frames[0]])
}

@Test @MainActor func tcpServerWriterSelfHealsOnRestartAfterALostWriterFinished() async {
    let fake = GatedWire(gated: [frames[0]])
    let store = serverStore(fake)
    let conn = TCPConnID(1)

    await store.send(.send(conn: conn, raws[0])) { $0.isWriting = true }
    await store.send(.send(conn: conn, raws[1])) { $0.outbox = [.init(conn: conn, framed: frames[1])] }

    await store.send(.listenerEvent(.started)) {
        $0.status = .listening
        $0.writerGeneration = 1
        $0.outbox = []
    }
    await store.receive(.writerFinished(generation: 1)) { $0.isWriting = false }

    await store.send(.send(conn: conn, raws[2])) { $0.isWriting = true }
    await store.receive(.writerFinished(generation: 1)) { $0.isWriting = false }
    await store.send(.send(conn: conn, raws[3])) { $0.isWriting = true }
    await store.receive(.writerFinished(generation: 1)) { $0.isWriting = false }
    #expect(fake.wire.value == [frames[1], frames[2], frames[3]])

    fake.release(frames[0])
    await store.finish()
    #expect(fake.wire.value == [frames[1], frames[2], frames[3], frames[0]])
}

// MARK: - A superseded writer stops (Task 9 follow-up, round 2)
//
// Cancelling a writer does not stop its loop by itself: the send ignores cancellation. Without a
// per-frame check, a writer superseded MID-BATCH kept writing the rest of its batch while the next
// generation's writer was already writing — two writers, frames interleaved (A3, B1, A4). Here the
// old writer is held on the first frame of a three-frame batch (A1 A2 A3) while a reset happens and
// the new generation writes B1; then the hold is released. A1 was already issued and lands; A2 and
// A3 must NOT follow B1 onto the wire.

@Test @MainActor func tcpClientSupersededWriterStopsMidBatch() async {
    let fake = GatedWire(gated: [frames[0], frames[1]])
    let store = clientStore(fake)

    await store.send(.send(raws[0])) { $0.isWriting = true }            // batch [A0], held
    for i in 1...3 { await store.send(.send(raws[i])) { $0.outbox.append(frames[i]) } }
    fake.release(frames[0])
    await store.receive(.writerFinished(generation: 0)) { $0.outbox = [] }   // batch [A1 A2 A3], held on A1

    await store.send(.connectionEvent(.connected)) {
        $0.status = .online
        $0.writerGeneration = 1
        $0.isWriting = false
    }
    await store.send(.send(raws[4])) { $0.isWriting = true }            // B1, generation 1
    await store.receive(.writerFinished(generation: 1)) { $0.isWriting = false }
    #expect(fake.wire.value == [frames[0], frames[4]])

    fake.release(frames[1])
    await store.finish()
    #expect(fake.wire.value == [frames[0], frames[4], frames[1]])
}

@Test @MainActor func tcpServerSupersededWriterStopsMidBatch() async {
    let fake = GatedWire(gated: [frames[0], frames[1]])
    let store = serverStore(fake)
    let conn = TCPConnID(1)

    await store.send(.send(conn: conn, raws[0])) { $0.isWriting = true }
    for i in 1...3 {
        await store.send(.send(conn: conn, raws[i])) { $0.outbox.append(.init(conn: conn, framed: frames[i])) }
    }
    fake.release(frames[0])
    await store.receive(.writerFinished(generation: 0)) { $0.outbox = [] }

    await store.send(.listenerEvent(.started)) {
        $0.status = .listening
        $0.writerGeneration = 1
        $0.isWriting = false
    }
    await store.send(.send(conn: conn, raws[4])) { $0.isWriting = true }
    await store.receive(.writerFinished(generation: 1)) { $0.isWriting = false }
    #expect(fake.wire.value == [frames[0], frames[4]])

    fake.release(frames[1])
    await store.finish()
    #expect(fake.wire.value == [frames[0], frames[4], frames[1]])
}
