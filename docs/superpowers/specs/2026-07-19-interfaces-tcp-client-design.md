# Interfaces — TCP Client — Design

**Date:** 2026-07-19
**Status:** Approved
**Sub-project:** #3 of the native iOS Reticulum (RNS) implementation

## Context

Sub-projects #1 (Crypto + Identity core) and #2 (Packet + Destination) are complete and
merged: the pure Swift `ReTiCA` core provides crypto, `Identity`, `Packet` framing,
`Destination`, and `Announce`, all wire-compatible with reference Reticulum
(`markqvist/Reticulum`) and proven against Python-RNS 1.3.8 fixtures.

This slice introduces **the TCA layer** for the first time — the two-layer architecture
promised from the start. It delivers a single **TCP client interface**: the seam between
raw bytes on a socket and the Reticulum packet stream.

Inherited constraints:
- **Full wire compatibility** with reference Reticulum — byte-for-byte (HDLC framing here).
- **Byte-exactness validated against Python-RNS 1.3.8** cross-validation fixtures.

New for this slice:
- **TCA enters, but only in a new target.** The pure `ReTiCA` core stays dependency-free.
  A new `ReTiCAInterfaces` library target depends on `ReTiCA` + The Composable
  Architecture. Consumers who want only the crypto/packet core keep zero dependencies.
- **Socket I/O uses Apple's Network.framework** (`NWConnection`), wrapped behind a TCA
  `@Dependency` so tests never touch a real socket.

Scope decision: **TCP client only** (connect out to an existing Reticulum TCP node).
TCP server, UDP, AutoInterface, RNode, and other transports are deferred.

## Reference constructions (confirmed against `markqvist/Reticulum`)

Line references are to `/tmp/ReTiCA/Reticulum-ref/RNS/Interfaces/TCPInterface.py` and
`RNS/Reticulum.py`.

### HDLC framing

```
FLAG     = 0x7E
ESC      = 0x7D
ESC_MASK = 0x20
```

- **escape(data):** replace every `ESC` (0x7D) byte with `ESC, ESC^ESC_MASK` (`7D 5D`),
  then replace every `FLAG` (0x7E) byte with `ESC, FLAG^ESC_MASK` (`7D 5E`). Order
  matters: ESC is escaped first, then FLAG.
- **frame(data):** `FLAG ‖ escape(data) ‖ FLAG`.
- **unescape(frame):** reverse — replace `ESC, FLAG^ESC_MASK` (`7D 5E`) with `FLAG`, and
  `ESC, ESC^ESC_MASK` (`7D 5D`) with `ESC`.

### Deframe read loop (`read_loop`, HDLC branch, lines 380–398)

```
frame_buffer += incoming_bytes
loop:
    frame_start = frame_buffer.find(FLAG)
    if frame_start == -1: break                       # no opening flag yet
    frame_end = frame_buffer.find(FLAG, frame_start+1)
    if frame_end == -1: break                          # incomplete frame; wait for more
    frame = unescape(frame_buffer[frame_start+1 : frame_end])
    if len(frame) > HEADER_MINSIZE: deliver(frame)     # HEADER_MINSIZE = 19; STRICTLY greater
    frame_buffer = frame_buffer[frame_end:]            # keep closing FLAG as next opening FLAG
```

Key details:
- `HEADER_MINSIZE = 2 + 1 + (TRUNCATED_HASHLENGTH//8) = 19`. Frames of length ≤ 19 are
  **dropped** (noise / header-only). Deliver only when `len(frame) > 19`.
- The buffer advances to `frame_end` (NOT `frame_end+1`): consecutive frames share a
  single FLAG byte (`FLAG a FLAG b FLAG` yields frames `a` and `b`).
- Leading garbage before the first FLAG is discarded once a complete frame is found.

### Interface boundary (`process_incoming`/`process_outgoing`, lines 304–334)

- Inbound: a complete de-framed frame is a packet's **raw bytes**, handed to
  `owner.inbound(data, self)` (i.e. up to Transport, which parses it). The interface does
  not parse packets.
- Outbound: `process_outgoing(data)` frames `data` (a packet's raw bytes) with HDLC and
  writes it to the socket. On write failure the interface tears down (and, for
  initiators, reconnects).

### Connection lifecycle (TCPClientInterface)

- An initiator connects to a target `host:port`, runs a read loop, and maintains
  `online`/`detached` state. On socket close or error, an initiator **reconnects**
  (the reference retries with logging); a non-initiator tears down.

## Package structure

```
Package.swift  (modified)
  dependencies: + swift-composable-architecture (~1.15+, latest 1.x, Swift 6 compatible)
  products:     + .library(name: "ReTiCAInterfaces", targets: ["ReTiCAInterfaces"])
  targets:
    ReTiCA               (unchanged — zero third-party deps)
    + Framing/HDLC.swift (pure HDLC lives in the core)
    ReTiCAInterfaces     (new) depends on ["ReTiCA", ComposableArchitecture]
    ReTiCATests          (unchanged)
    + ReTiCAInterfacesTests (new) depends on ["ReTiCAInterfaces", ComposableArchitecture]

Sources/ReTiCA/Framing/HDLC.swift
Sources/ReTiCAInterfaces/TCPConnection.swift        // @Dependency (NWConnection live, mock test)
Sources/ReTiCAInterfaces/TCPClientInterface.swift   // @Reducer
Tests/ReTiCATests/Framing/HDLCTests.swift
Tests/ReTiCAInterfacesTests/TCPClientInterfaceTests.swift
Tests/ReTiCATests/Vectors/ (extend generator + fixtures + a HDLC cross-validation test)
```

**HDLC placement:** pure and dependency-free, so it lives in the core `ReTiCA` target
(reusable by any transport, TCA or not). Everything that touches TCA or Network.framework
lives in `ReTiCAInterfaces`.

## Public API sketch

### Core (ReTiCA) — pure HDLC

```swift
public enum HDLC {
    public static let flag: UInt8 = 0x7E
    public static let esc: UInt8 = 0x7D
    public static let escMask: UInt8 = 0x20
    public static let minFrameSize = 19 // HEADER_MINSIZE; frames must be strictly larger

    public static func escape(_ data: Data) -> Data
    public static func unescape(_ data: Data) -> Data
    public static func frame(_ data: Data) -> Data          // FLAG ‖ escape ‖ FLAG
}

/// Streaming HDLC deframer. Accumulates bytes and yields complete, unescaped frames
/// longer than `minFrameSize`, matching the reference read loop (shared-FLAG framing).
public struct HDLCDeframer: Equatable {
    public init(minFrameSize: Int = HDLC.minFrameSize)
    public mutating func ingest(_ bytes: Data) -> [Data]
}
```

### ReTiCAInterfaces — TCA

```swift
import ComposableArchitecture

public enum TCPEvent: Sendable, Equatable {
    case connected
    case data(Data)
    case disconnected(reason: String?)
}

/// Socket dependency. Live value wraps NWConnection; test value is an injected mock.
public struct TCPConnection: Sendable {
    public var open: @Sendable (_ host: String, _ port: UInt16) -> AsyncStream<TCPEvent>
    public var send: @Sendable (Data) async -> Void
    public var close: @Sendable () async -> Void
}
extension TCPConnection: DependencyKey {
    public static let liveValue: TCPConnection    // NWConnection-backed
    public static let testValue: TCPConnection    // unimplemented by default
}
extension DependencyValues {
    public var tcpConnection: TCPConnection { get set }
}

@Reducer
public struct TCPClientInterface {
    @ObservableState
    public struct State: Equatable {
        public var host: String
        public var port: UInt16
        public var status: Status
        public var reconnectOnDrop: Bool
        var deframer: HDLCDeframer
        public init(host: String, port: UInt16, reconnectOnDrop: Bool = true)
    }
    public enum Status: Equatable { case disconnected, connecting, online }

    public enum Action {
        case connect
        case disconnect
        case connectionEvent(TCPEvent)
        case send(Data)                              // outbound raw packet bytes
        case delegate(Delegate)
        public enum Delegate: Equatable { case packetReceived(Data) } // deframed frame up to Transport
    }

    @Dependency(\.tcpConnection) var tcpConnection
    @Dependency(\.continuousClock) var clock

    public init()
    public var body: some ReducerOf<Self>
}
```

## Behavior

- **`.connect`:** set `status = .connecting`; start a long-lived effect that iterates
  `tcpConnection.open(host, port)` and maps each `TCPEvent` to `.connectionEvent`. The
  effect is cancellable (id keyed to the connection) so `.disconnect` can stop it.
- **`.connectionEvent(.connected)`:** `status = .online`.
- **`.connectionEvent(.data(bytes))`:** `deframer.ingest(bytes)` → emit one
  `.delegate(.packetReceived(frame))` per complete frame (order preserved).
- **`.connectionEvent(.disconnected(reason))`:** `status = .disconnected`; if
  `reconnectOnDrop`, sleep a bounded backoff on `clock` then send `.connect`.
- **`.send(raw)`:** run `tcpConnection.send(HDLC.frame(raw))`.
- **`.disconnect`:** cancel the connection effect, run `tcpConnection.close()`, set
  `status = .disconnected`, and suppress reconnect.

The interface never parses packets; `.delegate(.packetReceived(Data))` carries raw packet
bytes for Transport (#4) to parse via `Packet(raw:)`. `.send`/`.delegate` are the
**provisional Transport-facing contract**; #4 may refine it.

## Data flow

- **Inbound:** `NWConnection` receive → `.data(bytes)` → `HDLCDeframer.ingest` →
  `.delegate(.packetReceived(rawPacketBytes))`.
- **Outbound:** `.send(rawPacketBytes)` → `HDLC.frame` → `NWConnection.send`.
- **Lifecycle:** `.connect` → `.connecting` → (socket) `.connected` → `.online`;
  `.disconnected` → `.disconnected` → (optional) reconnect.

## Error handling

- `HDLCDeframer` never throws: malformed/partial input accumulates or is discarded per
  the read-loop rules; it cannot trap on any byte sequence.
- Socket failures surface as `TCPEvent.disconnected(reason:)`; the reducer transitions to
  `.disconnected` and optionally reconnects. No socket error propagates as a Swift throw
  into the reducer.
- Reconnect backoff is bounded and driven by the injected `continuousClock` (test clock in
  tests), so there is no unbounded busy-loop.

## Verification strategy

Under the project's mutation-testing discipline (write → pass → mutate → fail → revert →
pass).

1. **HDLC unit tests** (core, `ReTiCATests`):
   - `frame` = `FLAG ‖ escape ‖ FLAG`; empty and non-empty payloads.
   - Escaping: a `FLAG` byte in the payload becomes `7D 5E`; an `ESC` byte becomes
     `7D 5D`; `frame`→deframe round-trips a payload containing both.
   - `HDLCDeframer`: single frame; two frames in one `ingest` (shared FLAG); a frame split
     across two `ingest` calls; leading garbage before the first FLAG discarded; a frame of
     length ≤ 19 dropped, length > 19 delivered.
2. **HDLC cross-validation vs Python-RNS 1.3.8** (extend `generate_fixtures.py` — `HDLC`
   escape/frame are pure statics, headless-safe): frame the existing `plain_packet_raw` in
   Python (`HDLC.FLAG + HDLC.escape(raw) + HDLC.FLAG`), commit as `hdlc_framed`; assert
   Swift `HDLC.frame(plainPacketRaw)` equals `hdlc_framed` byte-for-byte, and Swift
   `HDLCDeframer.ingest(hdlc_framed)` recovers `plain_packet_raw`. (Also include a payload
   whose bytes contain FLAG/ESC to exercise escaping across the boundary — a synthetic
   `escape_input`/`escape_framed` pair.)
3. **Reducer tests** (`ReTiCAInterfacesTests`, `TestStore` + mock `TCPConnection` + test
   clock):
   - `.connect` → `status == .connecting`; inject `.connected` → `.online`.
   - inject `.data(HDLC.frame(rawPacket))` → receive `.delegate(.packetReceived(rawPacket))`.
   - `.send(raw)` → the mock records `HDLC.frame(raw)` as sent.
   - inject `.disconnected` with `reconnectOnDrop` → `status == .disconnected`, advance the
     test clock → `.connect` re-issued.
   - `.disconnect` → effect cancelled, `close()` called, `status == .disconnected`, no
     reconnect.
   The mock `TCPConnection` uses an `AsyncStream` whose continuation the test drives to
   inject events, and records sent frames in an actor the test inspects.
4. **Optional live integration** (manual, OFF by default, needs network): a documented,
   skipped-by-default test that opens a real `NWConnection` to a Reticulum TCP node (e.g. a
   local `rnsd` TCP server), deframes the inbound stream, and parses at least one live
   **announce** via `Announce.parse` — true end-to-end proof. Not a CI gate.

Fixture generation uses the conda `rns` env by absolute-path Python (see project RNS
reference notes).

## Success criteria

- `HDLC.frame` reproduces the reference framing byte-for-byte (including escaping); the
  deframer recovers the original packet bytes, matching Python-RNS output.
- `HDLCDeframer` handles partial frames, shared FLAGs, leading garbage, and the > 19 size
  gate exactly per the reference; it never traps.
- The `TCPClientInterface` reducer passes deterministic `TestStore` tests for connect,
  inbound deframe → delegate, outbound frame → send, disconnect, and clock-driven
  reconnect — with no real socket.
- The pure `ReTiCA` core remains dependency-free; TCA is confined to `ReTiCAInterfaces`.
- (Optional) a live connection to a real node yields a parseable announce.
