import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

// Validates the dependency's shape and the test-double pattern the reducer tests rely on.
@Test func mockConnectionYieldsEventsAndRecordsSends() async {
    let events = AsyncStream<TCPEvent>.makeStream()
    let sent = LockIsolated<[Data]>([])
    let closed = LockIsolated(false)
    let conn = TCPConnection(
        open: { _, _ in events.stream },
        send: { data in sent.withValue { $0.append(data) } },
        close: { closed.setValue(true) }
    )

    events.continuation.yield(.connected)
    events.continuation.yield(.data(Data([0xAA])))
    events.continuation.finish()

    var received: [TCPEvent] = []
    for await event in conn.open("host", 4242) { received.append(event) }
    #expect(received == [.connected, .data(Data([0xAA]))])

    await conn.send(Data([1, 2, 3]))
    #expect(sent.value == [Data([1, 2, 3])])

    await conn.close()
    #expect(closed.value == true)
}
