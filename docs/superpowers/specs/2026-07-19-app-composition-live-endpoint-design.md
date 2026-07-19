# App Composition (ReTiCANode) + Live Endpoint Proof — Design

**Date:** 2026-07-19
**Status:** Approved
**Sub-project:** #5 (consolidation slice) of the native iOS Reticulum (RNS) implementation

## Context

Sub-projects #1–#4 are complete and merged: the pure `ReTiCA` core (crypto, Identity,
Packet, Destination, Announce, HDLC), `ReTiCAInterfaces` (TCA `TCPClientInterface` over
`NWConnection`), and `ReTiCATransport` (endpoint-core `Transport` reducer: announce ingest
→ path/known-destination table, inbound DATA delivery, outbound routing, self-announce).

`ReTiCAInterfaces` and `ReTiCATransport` do not depend on each other — Transport is
interface-agnostic (`InterfaceID` handles) and exchanges `.received(InterfaceID, Data)` /
`.delegate(.transmit(InterfaceID, Data))`. Nothing yet wires them into a runnable endpoint.

This slice adds that wiring — a thin **composition reducer** — plus a **live integration
test** that runs the whole stack against a real Reticulum node. It is the first time the
library functions as a complete endpoint on a real network. It adds no new protocol
behavior; it assembles what exists.

Inherited constraints:
- TCA confined to non-core targets; the `ReTiCA` core stays dependency-free.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / Mac Catalyst 16.

### Decisions

- **New `ReTiCANode` target** depending on `ReTiCAInterfaces` + `ReTiCATransport` (+ core +
  TCA). The top-level "assemble a working endpoint" layer.
- **Single TCP interface** this slice (multi-interface via `IdentifiedArray` deferred).
- **Live test off by default**, gated on `RETICA_LIVE_HOST` — never a CI gate.

## Existing contracts consumed

`TCPClientInterface` (ReTiCAInterfaces):
- `State(host: String, port: UInt16, reconnectOnDrop: Bool = true)`.
- `Action`: `.connect`, `.disconnect`, `.connectionEvent(TCPEvent)`, `.send(Data)`,
  `.delegate(.packetReceived(Data))`. `TCPEvent`: `.connected`/`.data(Data)`/
  `.disconnected(reason: String?)`.

`Transport` (ReTiCATransport):
- `State()` with `localDestinations`/`learned`/`interfaces`.
- `Action`: `.interfaceConnected(InterfaceID)`, `.interfaceDisconnected(InterfaceID)`,
  `.registerLocalDestination(Destination)`, `.received(InterfaceID, Data)`,
  `.announce(destinationHash: Data, appData: Data?)`, `.send(destinationHash: Data,
  plaintext: Data)`, `.delegate(.transmit(InterfaceID, Data) / .received(destinationHash:
  plaintext:) / .pathLearned(destinationHash: hops:) / .sendFailed(destinationHash:
  reason:))`.

## Target & module structure

```
Package.swift (modified): + product ReTiCANode; + target ReTiCANode
  (deps: ReTiCAInterfaces, ReTiCATransport, ComposableArchitecture);
  + test target ReTiCANodeTests.

Sources/ReTiCANode/Endpoint.swift        // @Reducer composition
Tests/ReTiCANodeTests/EndpointTests.swift     // deterministic TestStore wiring tests
Tests/ReTiCANodeTests/LiveEndpointTests.swift // off-by-default live integration test
```

## `Endpoint` reducer

```swift
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

@Reducer
public struct Endpoint {
    @ObservableState
    public struct State: Equatable {
        public var interface: TCPClientInterface.State
        public var transport: Transport.State
        public let interfaceID: InterfaceID

        public init(host: String, port: UInt16, reconnectOnDrop: Bool = true,
                    interfaceID: InterfaceID = InterfaceID("tcp")) {
            self.interface = TCPClientInterface.State(host: host, port: port,
                                                      reconnectOnDrop: reconnectOnDrop)
            self.transport = Transport.State()
            self.interfaceID = interfaceID
        }
    }

    public enum Action {
        case interface(TCPClientInterface.Action)
        case transport(Transport.Action)

        // App-facing sugar (forward to the children):
        case connect
        case disconnect
        case registerLocalDestination(Destination)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)

        case delegate(Delegate)
        public enum Delegate: Equatable {
            case messageReceived(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: Transport.SendFailure)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { TCPClientInterface() }
        Scope(state: \.transport, action: \.transport) { Transport() }
        Reduce { state, action in
            let id = state.interfaceID
            switch action {
            // App sugar → children
            case .connect:                        return .send(.interface(.connect))
            case .disconnect:                     return .send(.interface(.disconnect))
            case let .registerLocalDestination(d): return .send(.transport(.registerLocalDestination(d)))
            case let .announce(h, a):             return .send(.transport(.announce(destinationHash: h, appData: a)))
            case let .send(h, p):                 return .send(.transport(.send(destinationHash: h, plaintext: p)))

            // Interface → Transport wiring
            case let .interface(.delegate(.packetReceived(data))):
                return .send(.transport(.received(id, data)))
            case .interface(.connectionEvent(.connected)):
                return .send(.transport(.interfaceConnected(id)))
            case .interface(.connectionEvent(.disconnected)):
                return .send(.transport(.interfaceDisconnected(id)))

            // Transport → Interface wiring + bubble-up
            case let .transport(.delegate(.transmit(txID, raw))):
                guard txID == id else { return .none }
                return .send(.interface(.send(raw)))
            case let .transport(.delegate(.received(h, p))):
                return .send(.delegate(.messageReceived(destinationHash: h, plaintext: p)))
            case let .transport(.delegate(.pathLearned(h, hops))):
                return .send(.delegate(.pathLearned(destinationHash: h, hops: hops)))
            case let .transport(.delegate(.sendFailed(h, r))):
                return .send(.delegate(.sendFailed(destinationHash: h, reason: r)))

            case .interface, .transport, .delegate:
                return .none
            }
        }
    }
}
```

Reducer order: the two `Scope`s run the children first, then the parent `Reduce` reacts to
the (already child-processed) delegate/event actions and forwards. Reconnect is transparent:
on reconnect the interface re-emits `.connectionEvent(.connected)`, so `interfaceConnected`
is re-sent (idempotent — `Set.insert`).

## Data flow

- **Inbound:** socket → `interface` deframes → `.interface(.delegate(.packetReceived))` →
  parent → `.transport(.received(id, ·))` → learn / deliver → `.transport(.delegate(...))` →
  parent → `Endpoint.delegate(.messageReceived / .pathLearned)`.
- **Outbound:** app `.send`/`.announce` → `.transport(.send/.announce)` →
  `.transport(.delegate(.transmit(id, raw)))` → parent → `.interface(.send(raw))` → frame +
  socket.
- **Lifecycle:** `.connect` → interface connects → `.connectionEvent(.connected)` →
  `.transport(.interfaceConnected(id))`.

## Verification strategy

1. **Deterministic `TestStore` wiring tests** (`EndpointTests`, mock `TCPConnection` + test
   clock, no real socket; `@MainActor`, non-exhaustive where child internals are incidental):
   - `.connect` then inject `.connected` → interface `.online` AND
     `state.transport.interfaces` contains `interfaceID` (connected wiring).
   - Inject `.data(HDLC.frame(announcePacket))` (a self-built or reference announce packet) →
     interface deframes → parent forwards → transport learns → `Endpoint.delegate(.pathLearned)`
     and `state.transport.learned[destHash]` populated (inbound wiring end-to-end).
   - `.registerLocalDestination` + a DATA packet encrypted to it, injected as `.data` →
     `Endpoint.delegate(.messageReceived(destHash, plaintext))` (delivery wiring).
   - `.announce(destHash)` (after connect) → the mock `TCPConnection` records a framed packet
     whose deframed contents parse as a valid announce (outbound wiring: transport → interface
     → socket).
   - `.send` to an unlearned destination → `Endpoint.delegate(.sendFailed(_, .notLearned))`.
   These prove the composition wiring without any network.
2. **Live integration test** (`LiveEndpointTests`, off by default): guarded by
   `@Test(.enabled(if: ProcessInfo.processInfo.environment["RETICA_LIVE_HOST"] != nil))`.
   Builds a real `Store<Endpoint>` with live dependencies (real `NWConnection`), reads
   `RETICA_LIVE_HOST` / `RETICA_LIVE_PORT` (default port 4242), sends `.connect`, waits a few
   seconds, and asserts `store.state.transport.learned` is non-empty (real announces were
   learned) — proving the full stack against a real node. Point it at a local `rnsd` running a
   `TCPServerInterface`, or a public testnet node. Skipped in CI (env var unset).

## Error handling

- Wiring never traps: malformed inbound bytes are already dropped by `Transport`/`Packet`;
  the parent only forwards actions.
- The `.transmit` guard (`txID == id`) ignores transmit requests for other interface IDs
  (none in the single-interface slice, but future-proof).
- The live test tolerates a slow/empty network: it asserts a non-empty learned table after a
  bounded wait; if the node sends no announces in the window it fails loudly (which is the
  correct signal that the connection or node is misconfigured), but only runs when explicitly
  enabled.

## Success criteria

- `Endpoint` composes `TCPClientInterface` + `Transport` with correct bidirectional wiring,
  proven by deterministic `TestStore` tests (inbound deframe→learn/deliver, outbound
  transport→interface→socket, connect→interfaceConnected).
- A real `Store<Endpoint>` connected to a live Reticulum TCP node populates its path table
  from real announces (live test, opt-in).
- `ReTiCANode` depends on `ReTiCAInterfaces` + `ReTiCATransport` (+ core + TCA); the core
  stays dependency-free.
