# Interfaces — TCP Client Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add pure HDLC framing to the ReTiCA core and a TCA-based `TCPClientInterface` (over a Network.framework socket dependency) in a new `ReTiCAInterfaces` target — wire-compatible HDLC vs `markqvist/Reticulum`, deterministically testable with no real socket.

**Architecture:** Pure `HDLC`/`HDLCDeframer` value types live in the dependency-free `ReTiCA` core. A new `ReTiCAInterfaces` library target depends on `ReTiCA` + The Composable Architecture and holds a `TCPConnection` `@Dependency` (live = `NWConnection`, test = injected mock) and a `TCPClientInterface` reducer that connects, deframes inbound bytes into packet frames (`delegate(.packetReceived)`), frames+sends outbound bytes (`.send`), and reconnects on drop via an injected clock.

**Tech Stack:** Swift 6.3 / Swift 6 language mode, Swift Testing, The Composable Architecture (~1.15, latest 1.x), Apple Network.framework.

## Global Constraints

- **Toolchain:** swift-tools-version 6.3; `swiftLanguageModes: [.v6]`.
- **Test framework:** Swift Testing (`import Testing`, `@Test`, `#expect`). TCA reducer tests use `TestStore`. Run with `swift test`.
- **The `ReTiCA` core stays dependency-free.** TCA appears ONLY in `ReTiCAInterfaces` (and its tests). HDLC is pure and lives in the core.
- **Byte-exact HDLC vs the reference** (`/tmp/ReTiCA/Reticulum-ref/RNS/Interfaces/TCPInterface.py`): `FLAG=0x7E`, `ESC=0x7D`, `ESC_MASK=0x20`; `escape` maps a raw `ESC`→`7D 5D` and a raw `FLAG`→`7D 5E`; `frame = FLAG ‖ escape(data) ‖ FLAG`. Deframe: split on FLAG…FLAG, unescape, deliver only frames of length **strictly greater than 19** (`HEADER_MINSIZE`), and advance the buffer to the closing FLAG (consecutive frames share a FLAG).
- **No real sockets in automated tests.** The live `NWConnection` implementation is validated only by the optional, off-by-default live integration test.
- **Value semantics** for the pure types; the reducer is a struct `@Reducer`. No shared mutable global state.
- **Mutation-testing discipline:** after each task's tests pass, batch-mutate the covered production code, confirm failure, revert, confirm green.

---

## File Structure

```
Package.swift                                     (modified in Task 2)
Sources/ReTiCA/Framing/HDLC.swift                 (Task 1) — pure HDLC + HDLCDeframer
Sources/ReTiCAInterfaces/TCPConnection.swift       (Task 2) — TCPEvent, TCPConnection @Dependency
Sources/ReTiCAInterfaces/TCPClientInterface.swift  (Task 3) — @Reducer
Tests/ReTiCATests/Framing/HDLCTests.swift          (Task 1)
Tests/ReTiCAInterfacesTests/TCPConnectionTests.swift    (Task 2)
Tests/ReTiCAInterfacesTests/TCPClientInterfaceTests.swift (Task 3)
Tests/ReTiCATests/Vectors/ (generator + fixtures + VectorFixtures + HDLC cross-validation) (Task 4)
README.md                                          (Task 5)
```

---

### Task 1: HDLC framing (pure, core)

**Files:**
- Create: `Sources/ReTiCA/Framing/HDLC.swift`
- Test: `Tests/ReTiCATests/Framing/HDLCTests.swift`

**Interfaces:**
- Consumes: nothing (pure).
- Produces:
  - `enum HDLC` with `flag=0x7E`, `esc=0x7D`, `escMask=0x20`, `minFrameSize=19`, `escape(_:)`, `unescape(_:)`, `frame(_:)`.
  - `struct HDLCDeframer: Equatable` with `init(minFrameSize:)` and `mutating func ingest(_:) -> [Data]`.

- [ ] **Step 1: Write the failing tests**

`Tests/ReTiCATests/Framing/HDLCTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func frameWrapsWithFlagsAndEscapes() {
    let framed = HDLC.frame(Data([0x01, 0x02]))
    #expect(framed == Data([0x7E, 0x01, 0x02, 0x7E]))
}

@Test func escapeReplacesFlagAndEscBytes() {
    // raw FLAG (0x7E) -> 7D 5E ; raw ESC (0x7D) -> 7D 5D
    #expect(HDLC.escape(Data([0x7E])) == Data([0x7D, 0x5E]))
    #expect(HDLC.escape(Data([0x7D])) == Data([0x7D, 0x5D]))
    #expect(HDLC.escape(Data([0x00, 0x7E, 0x7D, 0x01])) == Data([0x00, 0x7D, 0x5E, 0x7D, 0x5D, 0x01]))
}

@Test func frameDeframeRoundTripsPayloadContainingFlagAndEsc() {
    let payload = Data([0x00, 0x7E, 0x11, 0x7D, 0x22] + Array(repeating: 0xAB, count: 20))
    var deframer = HDLCDeframer()
    let frames = deframer.ingest(HDLC.frame(payload))
    #expect(frames == [payload])
}

@Test func deframerDeliversTwoFramesSharingAFlag() {
    let a = Data(repeating: 0xA1, count: 25)
    let b = Data(repeating: 0xB2, count: 30)
    // FLAG a FLAG b FLAG (consecutive frames share the middle FLAG)
    var buf = Data([HDLC.flag]); buf.append(HDLC.escape(a))
    buf.append(HDLC.flag); buf.append(HDLC.escape(b)); buf.append(HDLC.flag)
    var deframer = HDLCDeframer()
    #expect(deframer.ingest(buf) == [a, b])
}

@Test func deframerAccumulatesAcrossIngests() {
    let payload = Data(repeating: 0xC3, count: 40)
    let framed = HDLC.frame(payload)
    let mid = framed.count / 2
    var deframer = HDLCDeframer()
    #expect(deframer.ingest(framed.prefix(mid)) == [])          // incomplete
    #expect(deframer.ingest(framed.suffix(framed.count - mid)) == [payload])
}

@Test func deframerDiscardsLeadingGarbageAndTooShortFrames() {
    let payload = Data(repeating: 0xD4, count: 25)
    var buf = Data([0xFF, 0xFE])                 // leading garbage before first FLAG
    buf.append(HDLC.frame(payload))
    var deframer = HDLCDeframer()
    #expect(deframer.ingest(buf) == [payload])

    // A frame of exactly 19 bytes is dropped (must be > 19)
    let short = Data(repeating: 0x01, count: 19)
    var d2 = HDLCDeframer()
    #expect(d2.ingest(HDLC.frame(short)) == [])
    let ok = Data(repeating: 0x01, count: 20)
    var d3 = HDLCDeframer()
    #expect(d3.ingest(HDLC.frame(ok)) == [ok])
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HDLCTests`
Expected: FAIL — `HDLC` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Framing/HDLC.swift`:

```swift
import Foundation

/// HDLC framing used by byte-stream Reticulum interfaces (TCP, serial).
/// Matches `RNS/Interfaces/TCPInterface.py` `HDLC`.
public enum HDLC {
    public static let flag: UInt8 = 0x7E
    public static let esc: UInt8 = 0x7D
    public static let escMask: UInt8 = 0x20
    /// HEADER_MINSIZE. Deframed frames must be STRICTLY longer than this to be delivered.
    public static let minFrameSize = 19

    /// Escape a raw ESC byte to `ESC, ESC^ESC_MASK` and a raw FLAG byte to `ESC, FLAG^ESC_MASK`.
    /// Single pass over the original bytes (equivalent to the reference's ESC-then-FLAG replaces).
    public static func escape(_ data: Data) -> Data {
        var out = Data()
        out.reserveCapacity(data.count)
        for byte in data {
            switch byte {
            case esc:  out.append(esc); out.append(esc ^ escMask)
            case flag: out.append(esc); out.append(flag ^ escMask)
            default:   out.append(byte)
            }
        }
        return out
    }

    public static func unescape(_ data: Data) -> Data {
        let bytes = [UInt8](data)
        var out = [UInt8]()
        out.reserveCapacity(bytes.count)
        var i = 0
        while i < bytes.count {
            if bytes[i] == esc, i + 1 < bytes.count {
                let next = bytes[i + 1]
                if next == flag ^ escMask { out.append(flag); i += 2; continue }
                if next == esc ^ escMask  { out.append(esc);  i += 2; continue }
            }
            out.append(bytes[i]); i += 1
        }
        return Data(out)
    }

    public static func frame(_ data: Data) -> Data {
        var out = Data([flag])
        out.append(escape(data))
        out.append(flag)
        return out
    }
}

/// Streaming HDLC deframer. Accumulates bytes and yields complete, unescaped frames longer
/// than `minFrameSize`, mirroring the reference read loop (shared-FLAG framing).
public struct HDLCDeframer: Equatable {
    private var buffer: [UInt8] = []
    private let minFrameSize: Int

    public init(minFrameSize: Int = HDLC.minFrameSize) {
        self.minFrameSize = minFrameSize
    }

    public mutating func ingest(_ bytes: Data) -> [Data] {
        buffer.append(contentsOf: bytes)
        var frames: [Data] = []
        while true {
            guard let start = buffer.firstIndex(of: HDLC.flag) else { break }
            guard let end = buffer[(start + 1)...].firstIndex(of: HDLC.flag) else { break }
            let frame = HDLC.unescape(Data(buffer[(start + 1)..<end]))
            if frame.count > minFrameSize { frames.append(frame) }
            buffer = Array(buffer[end...]) // keep the closing FLAG as the next opening FLAG
        }
        return frames
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HDLCTests`
Expected: PASS (6 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Framing/HDLC.swift Tests/ReTiCATests/Framing/HDLCTests.swift
git commit -m "feat: pure HDLC framing and streaming deframer"
```

---

### Task 2: Package restructure + TCPConnection dependency

**Files:**
- Modify: `Package.swift`
- Create: `Sources/ReTiCAInterfaces/TCPConnection.swift`
- Test: `Tests/ReTiCAInterfacesTests/TCPConnectionTests.swift`

**Interfaces:**
- Consumes: ComposableArchitecture (`DependencyKey`, `DependencyValues`, `unimplemented`).
- Produces:
  - `enum TCPEvent: Sendable, Equatable { case connected; case data(Data); case disconnected(reason: String?) }`
  - `struct TCPConnection: Sendable` with `open`, `send`, `close`.
  - `extension TCPConnection: DependencyKey` (`liveValue` = NWConnection-backed, `testValue` = unimplemented).
  - `extension DependencyValues { var tcpConnection: TCPConnection }`

- [ ] **Step 1: Modify Package.swift**

Replace `Package.swift` with:

```swift
// swift-tools-version: 6.3
import PackageDescription

let package = Package(
    name: "ReTiCA",
    platforms: [
        .iOS(.v13),
        .macOS(.v10_15),
        .tvOS(.v13),
        .watchOS(.v6),
        .macCatalyst(.v13),
    ],
    products: [
        .library(name: "ReTiCA", targets: ["ReTiCA"]),
        .library(name: "ReTiCAInterfaces", targets: ["ReTiCAInterfaces"]),
    ],
    dependencies: [
        .package(url: "https://github.com/pointfreeco/swift-composable-architecture", from: "1.15.0"),
    ],
    targets: [
        .target(name: "ReTiCA"),
        .target(
            name: "ReTiCAInterfaces",
            dependencies: [
                "ReTiCA",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
        .testTarget(
            name: "ReTiCATests",
            dependencies: ["ReTiCA"],
            resources: [.process("Vectors/fixtures.json")]
        ),
        .testTarget(
            name: "ReTiCAInterfacesTests",
            dependencies: [
                "ReTiCAInterfaces",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
    ],
    swiftLanguageModes: [.v6]
)
```

- [ ] **Step 2: Write the failing test**

`Tests/ReTiCAInterfacesTests/TCPConnectionTests.swift`:

```swift
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
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter TCPConnectionTests`
Expected: FAIL — `TCPConnection` / `ReTiCAInterfaces` not defined (first build also resolves TCA).

- [ ] **Step 4: Write minimal implementation**

`Sources/ReTiCAInterfaces/TCPConnection.swift`:

```swift
import Foundation
import ComposableArchitecture
#if canImport(Network)
import Network
#endif

/// Events emitted by a TCP connection.
public enum TCPEvent: Sendable, Equatable {
    case connected
    case data(Data)
    case disconnected(reason: String?)
}

/// TCP socket dependency. The live value wraps `NWConnection`; tests inject a mock so no
/// automated test touches a real socket.
public struct TCPConnection: Sendable {
    public var open: @Sendable (_ host: String, _ port: UInt16) -> AsyncStream<TCPEvent>
    public var send: @Sendable (Data) async -> Void
    public var close: @Sendable () async -> Void

    public init(
        open: @escaping @Sendable (String, UInt16) -> AsyncStream<TCPEvent>,
        send: @escaping @Sendable (Data) async -> Void,
        close: @escaping @Sendable () async -> Void
    ) {
        self.open = open
        self.send = send
        self.close = close
    }
}

extension TCPConnection: DependencyKey {
    public static var liveValue: TCPConnection {
        #if canImport(Network)
        let actor = NWConnectionActor()
        return TCPConnection(
            open: { host, port in
                AsyncStream { continuation in
                    Task { await actor.start(host: host, port: port, continuation: continuation) }
                }
            },
            send: { await actor.send($0) },
            close: { await actor.close() }
        )
        #else
        return TCPConnection(open: { _, _ in .finished }, send: { _ in }, close: {})
        #endif
    }

    public static let testValue = TCPConnection(
        open: unimplemented("TCPConnection.open", placeholder: AsyncStream { $0.finish() }),
        send: unimplemented("TCPConnection.send"),
        close: unimplemented("TCPConnection.close")
    )
}

extension DependencyValues {
    public var tcpConnection: TCPConnection {
        get { self[TCPConnection.self] }
        set { self[TCPConnection.self] = newValue }
    }
}

#if canImport(Network)
/// Holds the current NWConnection so `send`/`close` act on it. One active connection per instance.
private actor NWConnectionActor {
    private var connection: NWConnection?
    private var continuation: AsyncStream<TCPEvent>.Continuation?

    func start(host: String, port: UInt16, continuation: AsyncStream<TCPEvent>.Continuation) {
        self.continuation = continuation
        guard let nwPort = NWEndpoint.Port(rawValue: port) else {
            continuation.yield(.disconnected(reason: "invalid port")); continuation.finish(); return
        }
        let conn = NWConnection(host: NWEndpoint.Host(host), port: nwPort, using: .tcp)
        self.connection = conn
        conn.stateUpdateHandler = { [weak self] state in
            Task { await self?.handleState(state) }
        }
        conn.start(queue: .global(qos: .userInitiated))
    }

    private func handleState(_ state: NWConnection.State) {
        switch state {
        case .ready:
            continuation?.yield(.connected)
            receiveNext()
        case let .failed(error):
            continuation?.yield(.disconnected(reason: error.localizedDescription))
            continuation?.finish()
        case .cancelled:
            continuation?.finish()
        default:
            break
        }
    }

    private func receiveNext() {
        connection?.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            Task { await self?.handleReceive(data: data, isComplete: isComplete, error: error) }
        }
    }

    private func handleReceive(data: Data?, isComplete: Bool, error: NWError?) {
        if let data, !data.isEmpty { continuation?.yield(.data(data)) }
        if let error {
            continuation?.yield(.disconnected(reason: error.localizedDescription)); continuation?.finish(); return
        }
        if isComplete {
            continuation?.yield(.disconnected(reason: nil)); continuation?.finish(); return
        }
        receiveNext()
    }

    func send(_ data: Data) {
        connection?.send(content: data, completion: .contentProcessed { _ in })
    }

    func close() {
        connection?.cancel()
        continuation?.finish()
        connection = nil
    }
}
#endif
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter TCPConnectionTests`
Expected: PASS (1 test). First run resolves and builds The Composable Architecture (slow once).

- [ ] **Step 6: Commit**

```bash
git add Package.swift Sources/ReTiCAInterfaces/TCPConnection.swift Tests/ReTiCAInterfacesTests/TCPConnectionTests.swift
git commit -m "feat: ReTiCAInterfaces target and NWConnection-backed TCPConnection dependency"
```

---

### Task 3: TCPClientInterface reducer

**Files:**
- Create: `Sources/ReTiCAInterfaces/TCPClientInterface.swift`
- Test: `Tests/ReTiCAInterfacesTests/TCPClientInterfaceTests.swift`

**Interfaces:**
- Consumes: `HDLC`/`HDLCDeframer` (core), `TCPConnection`/`TCPEvent`, ComposableArchitecture, `@Dependency(\.continuousClock)`.
- Produces: `@Reducer struct TCPClientInterface` with `State`, `Status`, `Action` (incl. `Delegate.packetReceived(Data)`), `static let reconnectDelay: Duration`.

- [ ] **Step 1: Write the failing test**

`Tests/ReTiCAInterfacesTests/TCPClientInterfaceTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import ReTiCA

// The mock returns the captured `first` stream on the first open() call and a harmless
// never-yielding stream on any later call (so reconnect's second open() doesn't try to
// re-consume an already-iterated AsyncStream). AsyncStream buffers yields, so the test can
// yield via `first.continuation` after `.connect` with no race. Each test ends with
// `.disconnect` to cancel the in-flight connection effect.
private func makeStore(reconnect: Bool = true)
    -> (TestStore<TCPClientInterface.State, TCPClientInterface.Action>,
        AsyncStream<TCPEvent>.Continuation, LockIsolated<[Data]>, TestClock<Duration>)
{
    let first = AsyncStream<TCPEvent>.makeStream()
    let calls = LockIsolated(0)
    let sent = LockIsolated<[Data]>([])
    let clock = TestClock()
    let store = TestStore(
        initialState: TCPClientInterface.State(host: "node", port: 4242, reconnectOnDrop: reconnect)
    ) {
        TCPClientInterface()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(
            open: { _, _ in
                let n = calls.withValue { $0 += 1; return $0 }
                return n == 1 ? first.stream : AsyncStream { _ in }
            },
            send: { data in sent.withValue { $0.append(data) } },
            close: { }
        )
        $0.continuousClock = clock
    }
    store.exhaustivity = .off // deframer buffer bookkeeping is covered exhaustively by core HDLC tests
    return (store, first.continuation, sent, clock)
}

@Test func connectsThenDeframesInboundIntoPacketDelegate() async {
    let (store, events, _, _) = makeStore()
    await store.send(.connect) { $0.status = .connecting }
    events.yield(.connected)
    await store.receive(.connectionEvent(.connected)) { $0.status = .online }

    let raw = Data(repeating: 0xAB, count: 30) // > 19
    events.yield(.data(HDLC.frame(raw)))
    await store.receive(.connectionEvent(.data(HDLC.frame(raw))))
    await store.receive(.delegate(.packetReceived(raw)))

    await store.send(.disconnect) { $0.status = .disconnected }
}

@Test func sendFramesOutboundBytes() async {
    let (store, events, sent, _) = makeStore()
    await store.send(.connect) { $0.status = .connecting }
    events.yield(.connected)
    await store.receive(.connectionEvent(.connected)) { $0.status = .online }

    let raw = Data([0x08, 0x00, 0x11])
    await store.send(.send(raw))
    #expect(sent.value == [HDLC.frame(raw)])

    await store.send(.disconnect) { $0.status = .disconnected }
}

@Test func reconnectsAfterDropWhenEnabled() async {
    let (store, events, _, clock) = makeStore(reconnect: true)
    await store.send(.connect) { $0.status = .connecting }
    events.yield(.connected)
    await store.receive(.connectionEvent(.connected)) { $0.status = .online }

    events.yield(.disconnected(reason: "closed"))
    await store.receive(.connectionEvent(.disconnected(reason: "closed"))) { $0.status = .disconnected }

    await clock.advance(by: TCPClientInterface.reconnectDelay)
    await store.receive(.connect) { $0.status = .connecting }

    await store.send(.disconnect) { $0.status = .disconnected }
}

@Test func noReconnectWhenDisabled() async {
    let (store, events, _, clock) = makeStore(reconnect: false)
    await store.send(.connect) { $0.status = .connecting }
    events.yield(.connected)
    await store.receive(.connectionEvent(.connected)) { $0.status = .online }

    events.yield(.disconnected(reason: nil))
    await store.receive(.connectionEvent(.disconnected(reason: nil))) { $0.status = .disconnected }

    await clock.advance(by: TCPClientInterface.reconnectDelay)
    // No .connect is issued; finish the connection stream so no effect remains in flight.
    await store.send(.disconnect) { $0.status = .disconnected }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TCPClientInterfaceTests`
Expected: FAIL — `TCPClientInterface` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCAInterfaces/TCPClientInterface.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA

/// A Reticulum TCP client interface: connects out to a node, deframes inbound bytes into
/// packet frames, frames+sends outbound bytes, and reconnects on drop. Framing is HDLC;
/// packet parsing is left to the Transport layer (this interface stays byte-level).
@Reducer
public struct TCPClientInterface {
    /// Delay before an automatic reconnect after an unexpected drop.
    public static let reconnectDelay: Duration = .seconds(5)

    @ObservableState
    public struct State: Equatable {
        public var host: String
        public var port: UInt16
        public var status: Status
        public var reconnectOnDrop: Bool
        var deframer: HDLCDeframer

        public init(host: String, port: UInt16, reconnectOnDrop: Bool = true) {
            self.host = host
            self.port = port
            self.status = .disconnected
            self.reconnectOnDrop = reconnectOnDrop
            self.deframer = HDLCDeframer()
        }
    }

    public enum Status: Equatable { case disconnected, connecting, online }

    public enum Action: Equatable {
        case connect
        case disconnect
        case connectionEvent(TCPEvent)
        case send(Data)
        case delegate(Delegate)
        public enum Delegate: Equatable { case packetReceived(Data) }
    }

    @Dependency(\.tcpConnection) var tcpConnection
    @Dependency(\.continuousClock) var clock

    private enum CancelID { case connection }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .connect:
                state.status = .connecting
                let host = state.host
                let port = state.port
                return .run { send in
                    for await event in tcpConnection.open(host, port) {
                        await send(.connectionEvent(event))
                    }
                }
                .cancellable(id: CancelID.connection, cancelInFlight: true)

            case .disconnect:
                state.status = .disconnected
                return .merge(
                    .cancel(id: CancelID.connection),
                    .run { _ in await tcpConnection.close() }
                )

            case .connectionEvent(.connected):
                state.status = .online
                return .none

            case let .connectionEvent(.data(bytes)):
                let frames = state.deframer.ingest(bytes)
                return .merge(frames.map { .send(.delegate(.packetReceived($0))) })

            case .connectionEvent(.disconnected):
                state.status = .disconnected
                guard state.reconnectOnDrop else { return .none }
                return .run { send in
                    try await clock.sleep(for: TCPClientInterface.reconnectDelay)
                    await send(.connect)
                }

            case let .send(raw):
                let framed = HDLC.frame(raw)
                return .run { _ in await tcpConnection.send(framed) }

            case .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TCPClientInterfaceTests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCAInterfaces/TCPClientInterface.swift Tests/ReTiCAInterfacesTests/TCPClientInterfaceTests.swift
git commit -m "feat: TCPClientInterface reducer (connect, deframe, send, reconnect)"
```

---

### Task 4: HDLC cross-validation vs Python-RNS

**Files:**
- Modify: `Tests/ReTiCATests/Vectors/generate_fixtures.py`
- Modify: `Tests/ReTiCATests/Vectors/fixtures.json` (regenerated)
- Modify: `Tests/ReTiCATests/Vectors/VectorFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/HDLCCrossValidationTests.swift`

**Interfaces:**
- Consumes: `HDLC`, `HDLCDeframer`, `Data(hexString:)`.
- Produces: `VectorFixtures` gains `hdlcFramed`, `escapeInput`, `escapeFramed`.

- [ ] **Step 1: Extend the generator**

Add to `Tests/ReTiCATests/Vectors/generate_fixtures.py`, after the announce block and before the `print(json.dumps(...))`:

```python
from RNS.Interfaces.TCPInterface import HDLC

# HDLC framing of the deterministic PLAIN packet raw.
hdlc_framed = bytes([HDLC.FLAG]) + HDLC.escape(plain_packet_raw) + bytes([HDLC.FLAG])

# A payload containing FLAG (0x7E) and ESC (0x7D) bytes to exercise escaping.
escape_input = bytes([0x00, HDLC.FLAG, 0x11, HDLC.ESC, 0x22]) + bytes([0xAB] * 20)
escape_framed = bytes([HDLC.FLAG]) + HDLC.escape(escape_input) + bytes([HDLC.FLAG])
```

And add to the printed dict:

```python
    "hdlc_framed": hdlc_framed.hex(),
    "escape_input": escape_input.hex(),
    "escape_framed": escape_framed.hex(),
```

- [ ] **Step 2: Regenerate fixtures**

Run (headless, from the conda `rns` env by absolute-path Python — the controller can run this directly):
`/Users/ell/opt/anaconda3/envs/rns/bin/python Tests/ReTiCATests/Vectors/generate_fixtures.py > Tests/ReTiCATests/Vectors/fixtures.json`
Expected: `fixtures.json` gains `hdlc_framed`, `escape_input`, `escape_framed` (all hex), keeping all prior fields. If the `from RNS.Interfaces.TCPInterface import HDLC` line errors, STOP and report — do not fabricate values.

- [ ] **Step 3: Extend the decoder**

Add to `Tests/ReTiCATests/Vectors/VectorFixtures.swift` (keep existing fields):

```swift
    let hdlcFramed: String
    let escapeInput: String
    let escapeFramed: String
```

CodingKeys additions:

```swift
        case hdlcFramed = "hdlc_framed"
        case escapeInput = "escape_input"
        case escapeFramed = "escape_framed"
```

- [ ] **Step 4: Write the failing cross-validation tests**

`Tests/ReTiCATests/Vectors/HDLCCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func swiftHDLCFrameMatchesReference() throws {
    let f = try VectorFixtures.load()
    #expect(HDLC.frame(Data(hexString: f.plainPacketRaw)!) == Data(hexString: f.hdlcFramed))
}

@Test func swiftHDLCDeframeRecoversReferencePacket() throws {
    let f = try VectorFixtures.load()
    var deframer = HDLCDeframer()
    #expect(deframer.ingest(Data(hexString: f.hdlcFramed)!) == [Data(hexString: f.plainPacketRaw)!])
}

@Test func swiftHDLCEscapingMatchesReference() throws {
    let f = try VectorFixtures.load()
    #expect(HDLC.frame(Data(hexString: f.escapeInput)!) == Data(hexString: f.escapeFramed))
    var deframer = HDLCDeframer()
    #expect(deframer.ingest(Data(hexString: f.escapeFramed)!) == [Data(hexString: f.escapeInput)!])
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter HDLCCrossValidation`
Expected: PASS (3 tests) — Swift HDLC matches Python-RNS byte-for-byte.

- [ ] **Step 6: Commit**

```bash
git add Tests/ReTiCATests/Vectors
git commit -m "test: HDLC cross-validation vs Python-RNS"
```

---

### Task 5: Full suite + mutation gate + README + live-test note

**Files:** `README.md` (modify); no new source.

- [ ] **Step 1: Run the full suite**

Run: `swift test`
Expected: PASS — all sub-project #1/#2/#3 tests across both test targets, pristine output.

- [ ] **Step 2: Mutation sweep (project convention)**

Batch-mutate one production line per new unit, run `swift test` once, confirm the covering tests fail, then revert all and confirm green. Commit nothing with mutations. Suggested mutations:
- `HDLC.escape`: change `flag ^ escMask` to `flag` (breaks escape + frame round-trip + cross-validation).
- `HDLCDeframer.ingest`: change `buffer = Array(buffer[end...])` to `buffer[(end + 1)...]` (breaks the shared-FLAG two-frame test).
- `HDLCDeframer.ingest`: change `frame.count > minFrameSize` to `>= minFrameSize` (breaks the 19-vs-20 drop test).
- `TCPClientInterface` `.connectionEvent(.connected)`: set `state.status = .connecting` instead of `.online` (breaks connect test).
- `TCPClientInterface` `.send`: send `raw` instead of `HDLC.frame(raw)` (breaks sendFramesOutboundBytes).
- `TCPClientInterface` `.connectionEvent(.disconnected)`: drop the reconnect effect (breaks reconnectsAfterDropWhenEnabled).

Record which tests failed per mutation. If any mutation is not caught, add a covering test. Revert all; confirm green.

- [ ] **Step 3: Update the README**

In `README.md`, add a "Sub-project #3: Interfaces (TCP client)" section and note the package now vends two products:

```markdown
## Sub-project #3: Interfaces (TCP client)

| Module | Target | What it implements |
|--------|--------|--------------------|
| `HDLC` / `HDLCDeframer` | `ReTiCA` (pure core) | Byte-exact HDLC framing/deframing for byte-stream interfaces |
| `TCPConnection` | `ReTiCAInterfaces` | Network.framework (`NWConnection`) socket behind a TCA `@Dependency` |
| `TCPClientInterface` | `ReTiCAInterfaces` | TCA reducer: connect, deframe inbound → `delegate(.packetReceived)`, frame+send outbound, reconnect on drop |

The Composable Architecture enters here, confined to the new **`ReTiCAInterfaces`** product; the `ReTiCA` core stays dependency-free. Socket I/O is behind a `@Dependency`, so the reducer is tested deterministically with `TestStore` and a mock connection — no real socket. HDLC framing is cross-validated against Python-RNS 1.3.8.

### Products
- **`ReTiCA`** — pure Swift core (crypto, Identity, Packet, Destination, Announce, HDLC). Zero third-party dependencies.
- **`ReTiCAInterfaces`** — TCA-based interfaces (TCP client). Depends on `ReTiCA` + The Composable Architecture.
```

Update the "Not Yet Implemented" section to keep Transport, Link establishment, and Resource delivery (interfaces beyond TCP client — server/UDP/RNode — can be noted as future). Update the test count note to "currently N".

- [ ] **Step 4: Document the optional live integration test**

Add a short "Live integration (manual)" subsection to the README noting that a real end-to-end check can point a `TCPClientInterface` (with the live `TCPConnection`) at a running Reticulum TCP node (e.g. a local `rnsd` TCP server), and that received frames parse as packets/announces via the core. This is manual and not part of `swift test`.

- [ ] **Step 5: Commit**

```bash
git add README.md
git commit -m "docs: document Interfaces (TCP client) sub-project"
```

---

## Self-Review

**Spec coverage:**
- Pure HDLC `frame`/`escape`/`unescape` + streaming `HDLCDeframer` (shared-FLAG, >19 gate) → Task 1.
- Package split (`ReTiCAInterfaces` target + product, TCA dependency, core stays dep-free) → Task 2.
- `TCPConnection` `@Dependency` (live `NWConnection`, test mock/unimplemented) → Task 2.
- `TCPClientInterface` reducer (connect/deframe→delegate/frame→send/disconnect/clock-driven reconnect) → Task 3.
- HDLC cross-validation vs Python-RNS → Task 4.
- Full-suite + mutation gate + README + optional live-test note → Task 5.
- Determinism (no real socket; injected clock) → Tasks 2, 3.
- Deferred (TCP server, UDP, AutoInterface, RNode, Transport integration/parsing) → not built, per scope.

**Placeholder scan:** No TBD/TODO; every code step has complete code; commands have expected output. The live `NWConnection` implementation is complete (not a stub); its only "test" is the optional live check, as designed.

**Type consistency:** `HDLC.frame`/`escape`/`unescape` and `HDLCDeframer.ingest` used identically in Tasks 1/3/4; `TCPEvent` and `TCPConnection(open:send:close:)` identical across Tasks 2/3; `TCPClientInterface.Action`/`.Delegate`/`reconnectDelay`/`Status` consistent between Task 3 impl and its tests; `Data(hexString:)`/`VectorFixtures.load()`/`.plainPacketRaw` reused from prior sub-projects; `@Dependency(\.tcpConnection)`/`\.continuousClock` consistent.

**Decisions recorded:** TCA confined to `ReTiCAInterfaces` (core dep-free); HDLC in core; socket behind a `@Dependency` (Network.framework live, mock test); reducer tests non-exhaustive on the internal deframer buffer (exhaustively covered by core HDLC tests); reconnect via injected `continuousClock` with a fixed `reconnectDelay`; interface stays byte-level (`delegate(.packetReceived(Data))`), Transport parses.
