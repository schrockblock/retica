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
// The fake connection makes the race deterministic instead of probabilistic: the FIRST write is
// held on a gate the test opens, and a write counts as "on the wire" only once it returns. Any
// design that lets a later frame be written while an earlier one is still being written puts the
// later frame on the wire first. No sleeps: the test only ever waits on the gate and on actions.

private struct GatedWire: Sendable {
    let wire = LockIsolated<[Data]>([])
    let calls = LockIsolated(0)
    let gate = AsyncStream<Void>.makeStream()

    func write(_ data: Data) async {
        let n = calls.withValue { $0 += 1; return $0 }
        if n == 1 { for await _ in gate.stream { break } }   // hold the first write open
        wire.withValue { $0.append(data) }
    }
    func release() { gate.continuation.yield() }
}

@Test @MainActor func tcpClientWritesFramesInReducedOrder() async {
    let fake = GatedWire()
    let store = TestStore(initialState: TCPClientInterface.State(host: "node", port: 4242)) {
        TCPClientInterface()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } },
                                         send: { await fake.write($0) },
                                         close: {})
    }
    let raws = (0..<6).map { Data([0x08, 0x00, UInt8($0)]) }
    let frames = raws.map(HDLC.frame)

    // Frame 0 starts the single writer; frames 1...5 are reduced while it is still writing, so
    // they must queue behind it rather than race it.
    await store.send(.send(raws[0])) { $0.isWriting = true }
    for i in 1..<raws.count {
        await store.send(.send(raws[i])) { $0.outbox.append(frames[i]) }
    }

    fake.release()
    await store.receive(\.writerFinished) {       // batch [0] done → the queued batch starts
        $0.outbox = []
    }
    await store.receive(\.writerFinished) { $0.isWriting = false }

    #expect(fake.wire.value == frames)
}

@Test @MainActor func tcpServerWritesFramesInReducedOrder() async {
    let fake = GatedWire()
    let store = TestStore(initialState: TCPServerInterface.State(port: 4242)) {
        TCPServerInterface()
    } withDependencies: {
        $0.tcpListener = TCPListener(listen: { _ in AsyncStream { _ in } },
                                     send: { _, data in await fake.write(data) },
                                     close: { _ in }, stop: {})
    }
    let conns = [TCPConnID(1), TCPConnID(2)]
    let raws = (0..<6).map { Data([0x08, 0x00, UInt8($0)]) }
    let frames = raws.map(HDLC.frame)

    await store.send(.send(conn: conns[0], raws[0])) { $0.isWriting = true }
    for i in 1..<raws.count {
        await store.send(.send(conn: conns[i % 2], raws[i])) {
            $0.outbox.append(.init(conn: conns[i % 2], framed: frames[i]))
        }
    }

    fake.release()
    await store.receive(\.writerFinished) { $0.outbox = [] }
    await store.receive(\.writerFinished) { $0.isWriting = false }

    #expect(fake.wire.value == frames)
}
