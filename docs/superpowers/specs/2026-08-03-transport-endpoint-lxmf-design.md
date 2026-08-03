# TransportEndpoint — LXMF over TCP or BLE — Design

**Date:** 2026-08-03
**Status:** Approved
**Sub-project:** B of 2 (A — `LinkPlane` / `BLEEndpoint` link wiring — is complete and merged:
`docs/superpowers/specs/2026-08-03-ble-link-plane-design.md`).

## Context

`LXMFNode` is the production composition that drives LXMF messaging (opportunistic + direct
over link + propagation sync). It hardwires the TCP `Endpoint`: its state holds an
`Endpoint.State`, it sends `.endpoint(.foo)` actions, and it reads
`state.endpoint.transport.learned[…]` for a recipient's identity and a propagation node's
`appData`.

After sub-project A, `BLEEndpoint` has the same link/resource/request surface as the TCP
endpoint. Comparing the two public surfaces:

- **17 public actions are already identical:** `registerLocalDestination`, `announce`, `send`,
  `enableRelay`, `requestPath`, `openLink`, `sendOverLink`, `sendResourceOverLink`,
  `identifyOverLink`, `sendRequestOverLink`, `sendResponseOverLink`, `sendWithReceiptOverLink`,
  `closeLink`, `registerRequestHandler`, `deregisterRequestHandler`, plus the `transport` and
  `linkPlane` children and `delegate`.
- **All 16 shared delegates are identical:** `messageReceived`, `pathLearned`, `sendFailed`,
  `linkEstablished`, `linkDataReceived`, `linkClosed`, `linkFailed`, `resourceReceived`,
  `resourceConcluded`, `resourceFailed`, `linkIdentified`, `requestReceived`, `responseReceived`,
  `requestFailed`, `packetDelivered`, `packetDeliveryFailed`.
- **Only three things differ:** lifecycle naming (`connect`/`disconnect` vs `start`/`stop`), the
  child-interface case (`.interface(TCPClientInterface.Action)` vs `.ble(BLEInterface.Action)`),
  and BLE's extra `peerOnline`/`peerOffline` delegates.

That near-symmetry is what makes this slice small.

Decisions made during brainstorming:
- **Sum type, not generics.** A concrete `TransportEndpoint` enum reducer with `.tcp`/`.ble`
  cases and one unified surface. `LXMFNode` stays concrete — no generic parameter going viral
  through its `Action`, tests, and consumers.
- **`LXMFNode` only.** `PNNode` (which also hardwires the endpoint) is a follow-on.
- **Rename first.** `Endpoint` → `TCPEndpoint` lands as its own commit before the rest, so B is
  written against final names.

## Staging

Four stages, each an independently reviewable deliverable.

### B0 — Rename `Endpoint` → `TCPEndpoint`

Mechanical, no behavior change: `Endpoint` → `TCPEndpoint` everywhere (type, `State`, `Action`,
call sites in `LXMFNode`, `PNNode`, and ~15 test files), and
`Tests/ReTiCANodeTests/EndpointTests.swift` → `TCPEndpointTests.swift`. The name now matches
`BLEEndpoint` and the existing `TCPConnection`/`TCPClientInterface`/`TCPEvent` convention.

**Success criterion:** the entire suite passes unchanged — that is the proof the rename is
purely mechanical.

### B1 — `TransportEndpoint`

Create `Sources/ReTiCANode/TransportEndpoint.swift`:

```swift
@Reducer
public struct TransportEndpoint {
    @ObservableState
    public enum State: Equatable {
        case tcp(TCPEndpoint.State)
        case ble(BLEEndpoint.State)

        /// Transport-agnostic reads, switching on the active case.
        public var learned: [Data: LearnedDestination] { … }
        public var links: IdentifiedArrayOf<LinkSession.State> { … }
        public var registrations: [Data: RequestRegistration] { … }
    }

    public enum Action: Equatable {
        case tcp(TCPEndpoint.Action)   // escape hatch for transport-specific driving
        case ble(BLEEndpoint.Action)

        case start                      // → tcp .connect / ble .start
        case stop                       // → tcp .disconnect / ble .stop
        case registerLocalDestination(Destination)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case enableRelay(Identity)
        case requestPath(destinationHash: Data)
        case openLink(destinationHash: Data)
        case sendOverLink(linkID: Data, data: Data)
        case sendResourceOverLink(linkID: Data, data: Data)
        case identifyOverLink(linkID: Data, identity: Identity)
        case sendRequestOverLink(linkID: Data, path: String, data: Data)
        case sendResponseOverLink(linkID: Data, requestID: Data, data: Data)
        case sendWithReceiptOverLink(linkID: Data, data: Data, token: Data)
        case closeLink(linkID: Data)
        case registerRequestHandler(path: String, policy: RequestPolicy)
        case deregisterRequestHandler(path: String)

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            // Exactly the 16 shared delegates enumerated in Context above,
            // with payload shapes copied verbatim from the two endpoints.
        }
    }
}
```

Body: `Scope`s onto the two state cases (enum-state scoping) hosting `TCPEndpoint()` and
`BLEEndpoint()`, plus a `Reduce` that (a) maps each unified action **down** to the active case's
equivalent action, and (b) maps each child `.delegate(…)` **up** to the unified `.delegate(…)`.

The `learned`/`links`/`registrations` computed passthroughs are what let consumers read endpoint
state without knowing the transport; `learned` in particular is how `LXMFNode` resolves a
recipient's identity and a propagation node's `appData`.

BLE's `peerOnline`/`peerOffline` are deliberately **not** on the unified surface (LXMF has no use
for them); a BLE-aware app can still observe them through the `.ble` case.

### B2 — `LXMFNode` composes `TransportEndpoint`

- `LXMFNode.State.endpoint` becomes `TransportEndpoint.State`; `LXMFNode.Action.endpoint`
  carries `TransportEndpoint.Action`.
- The ~10 `.endpoint(.foo)` sends keep working verbatim — the unified action names match what
  `LXMFNode` already sends.
- The four `state.endpoint.transport.learned[…]` reads become `state.endpoint.learned[…]`.
- The primary init takes a `TransportEndpoint.State`
  (`LXMFNode.State(identity:endpoint: TransportEndpoint.State)`). **Additionally** provide two
  convenience overloads that wrap the concrete case —
  `LXMFNode.State(identity:endpoint: TCPEndpoint.State)` → `.tcp(…)` and
  `LXMFNode.State(identity:endpoint: BLEEndpoint.State)` → `.ble(…)` — so existing tests need only
  mechanical touch-ups rather than restructuring, and B3's BLE test reads naturally.

**Test churn (unavoidable, and the honest cost of this slice):** unlike sub-project A — where
`EndpointTests` staying frozen was the proof — the LXMF test files *are* edited here, because the
endpoint type genuinely changes. The churn is held to:
- `Endpoint.State(…)` → `TCPEndpoint.State(…)` (already done by B0), and
- `.endpoint(.connect)` / `.endpoint(.disconnect)` → `.endpoint(.start)` / `.endpoint(.stop)`.

The three deep reads (`LXMFPropagationCapstoneTests.swift:161`,
`LXMFNodePropagationTests.swift:112`, `LXMFNodeDirectTests.swift:107` — all
`state.endpoint.links[…]`) keep working verbatim via the `links` passthrough.

### B3 — LXMF over BLE proof

A test file demonstrating `LXMFNode` driving a `BLEEndpoint`, mirroring the single-store
directional style of `BLEEndpointIntegrationTests`: bring a peer online through the driver
handshake, register + announce an `lxmf.delivery` destination, then
- **inbound:** feed a crafted opportunistic LXMF packet as `channelData` → assert
  `LXMFNode.delegate.messageReceived` surfaces the reconstructed message;
- **outbound:** `LXMFNode.send(…, method: .opportunistic)` to a learned destination → assert the
  framed packet reaches that peer via the driver.

## Data flow (LXMF opportunistic over BLE)

`LXMFNode.send(…)` → `LXMFRouter` builds + emits `.sendOpportunistic(dest, payload)` →
`LXMFNode` maps to `.endpoint(.send(destinationHash:plaintext:))` → `TransportEndpoint` routes to
the active case → `BLEEndpoint` → `Transport` → per-peer `transmit` → `BLEInterface` frames →
the peer's L2CAP channel. Inbound mirrors it: `channelData` → deframe →
`transport.received(peerInterfaceID, …)` → decrypt → `messageReceived` → unified delegate →
`LXMFRouter.received` → `LXMFNode.delegate.messageReceived`.

**`LXMFRouter` does not change** — it was always transport-agnostic. Only the composition layer
moves.

## Error handling

No new failure modes. `TransportEndpoint` is a pure routing layer: each unified action maps to
exactly one child action, and each unified delegate maps up from exactly one child; the state
enum guarantees exactly one active case, so a unified action is always deliverable.
Transport-specific failures surface through the same `sendFailed` / `linkFailed` / `linkClosed`
delegates as today.

**Carried-over BLE limitations (documented, NOT fixed here)** — from sub-project A's final review:
- `Transport.delegate.linkPacket` carries no arrival interface, so a BLE link cannot re-home when
  a peer reconnects under a new session token; the link dies on `LinkSession`'s ~60 s inactivity
  watchdog. LXMF's direct-delivery retry saga is ~50 s — the same order of magnitude, so this is
  the first thing to revisit if BLE direct delivery proves flaky in practice.
- `peerOffline` does not proactively close links riding that peer.

Both are pre-existing and out of scope; they are called out so the next slice can weigh them.

## Testing

Mutation-testing discipline throughout; `.off` TestStores asserting behavior.

- **B0:** entire suite passes unchanged (the rename's proof).
- **B1:** focused `TransportEndpointTests` — each unified action reaches the active child for
  BOTH cases; each child delegate surfaces as the unified delegate; the lifecycle mapping
  (`.start` → `connect` on `.tcp`, → `start` on `.ble`); the `learned`/`links`/`registrations`
  passthroughs return the active case's values.
- **B2:** the existing LXMF suites pass with only the mechanical touch-ups above — the
  behavior-preservation proof.
- **B3:** the LXMF-over-BLE inbound + outbound tests described above.

## Deliverables

- B0: rename across `Sources/ReTiCANode/*` and `Tests/ReTiCANodeTests/*`; `EndpointTests.swift`
  → `TCPEndpointTests.swift`.
- B1: `Sources/ReTiCANode/TransportEndpoint.swift`; `Tests/ReTiCANodeTests/TransportEndpointTests.swift`.
- B2: `Sources/ReTiCANode/LXMFNode.swift`; mechanical touch-ups in the LXMF test files.
- B3: `Tests/ReTiCANodeTests/LXMFNodeBLETests.swift`.

## Out of scope

- `PNNode` generalization (follow-on; it hardwires the endpoint and reads `transport.learned` the
  same way `LXMFNode` did).
- A node running TCP **and** BLE simultaneously (mixed-transport routing).
- The BLE link re-homing fix (`linkPacket` arrival interface) and proactive link teardown on
  `peerOffline`.
- Any change to `LXMFRouter`, `LinkPlane`, `LinkSession`, `BLEInterface`, or the wire protocol.
