# LinkPlane — Shared Link/Resource/Request Wiring for BLEEndpoint — Design

**Date:** 2026-08-03
**Status:** Approved
**Sub-project:** A of 2. (B — generalizing `LXMFNode` over a transport-endpoint protocol so full
LXMF runs over TCP *or* BLE — is a separate later cycle that builds on this.)
**Depends on:** the packet-plane `BLEEndpoint`
(`docs/superpowers/specs/2026-08-02-ble-endpoint-wiring-design.md`), complete and merged.

## Context

`BLEEndpoint` composes `BLEInterface` + `Transport` but is **packet plane only** — no links,
resources, requests, or responses. LXMF's direct-over-link delivery and propagation sync both
require that machinery, so full LXMF cannot yet run over BLE. The TCP `Endpoint` already has the
full link/request surface; the goal of this sub-project is to give `BLEEndpoint` the same
surface **without duplicating** `Endpoint`'s ~120-line link/request Reduce body.

The link/request logic is ~95% interface-agnostic. It reads `transport.learned` /
`transport.localDestinations`, drives an `IdentifiedArray` of `LinkSession`s, hosts a
request-handler registry with allow-gated auto-response, and surfaces link/resource/request
delegates. The **only** genuinely interface-specific edge is routing a link's outbound packet
back to a concrete interface: TCP has one `InterfaceID`; BLE has one per peer.

Decisions made during brainstorming:
- **Factor, don't duplicate:** extract a shared `LinkPlane` reducer both `Endpoint` and
  `BLEEndpoint` embed. This also pre-shapes sub-project B's transport-endpoint protocol.
- **Full parity:** `BLEEndpoint` gets everything `Endpoint` exposes, including the
  request-handler registry (serving), so B's protocol is symmetric across transports.
- **One Transport enabler:** `Transport.delegate.linkRequest` must carry the arrival interface
  so a BLE responder link replies to the right peer.
- **Rename deferred:** renaming `Endpoint` → `TCPEndpoint` (to match `BLEEndpoint`) is a separate
  later pass — it touches many `LXMF*`/`PN*` files the user is editing concurrently. Out of scope
  here; this sub-project keeps the `Endpoint` name.

## Architecture

Three stages, each an independently reviewable deliverable.

### A1 — Transport enabler: arrival interface on `linkRequest`

`Transport.Action.Delegate.linkRequest` becomes
`linkRequest(destinationHash: Data, arrivalInterface: InterfaceID, data: Data)`. At the emit site
(`Transport.swift:196`) the arriving `interfaceID` is already in scope; pass it through. Update
the `Endpoint` handler to accept the new field and **ignore it** (it keeps using its single `id`),
so `Endpoint` behavior is unchanged. Update the Transport tests and the Endpoint tests that
pattern-match `linkRequest` to the new arity.

This is purely additive: no behavior change for TCP. Ongoing link packets already route via each
link's stored `interfaceID`, so only responder-link *creation* needs the arrival interface.

### A2 — Extract `LinkPlane` from `Endpoint` (behavior-preserving refactor)

Create `Sources/ReTiCANode/LinkPlane.swift`: a `@Reducer LinkPlane` owning the interface-agnostic
link/request machinery, and refactor `Endpoint` to embed and delegate to it. **Success criterion:
every existing `EndpointTests` passes unchanged** — this stage is a pure refactor.

`LinkPlane.State`:
- `links: IdentifiedArrayOf<LinkSession.State>`
- `registrations: [Data: RequestRegistration]`

`LinkPlane` does NOT hold or read `Transport` state. The host passes in the data a link needs at
creation time (see the trigger actions below), so `LinkPlane` stays transport-agnostic.

`LinkPlane.Action` (management — forwarded verbatim from the host's public actions):
- `openLink(initiatorTo: Identity, destinationHash: Data, interfaceID: InterfaceID, relayNextHop: Data?)`
- `acceptLinkRequest(owner: Identity, destinationHash: Data, interfaceID: InterfaceID, data: Data)`
- `routeLinkPacket(linkID: Data, data: Data)`
- `sendOverLink(linkID: Data, data: Data)`, `sendResourceOverLink(linkID: Data, data: Data)`,
  `identifyOverLink(linkID: Data, identity: Identity)`,
  `sendRequestOverLink(linkID: Data, path: String, data: Data)`,
  `sendResponseOverLink(linkID: Data, requestID: Data, data: Data)`,
  `sendWithReceiptOverLink(linkID: Data, data: Data, token: Data)`,
  `closeLink(linkID: Data)`
- `registerRequestHandler(path: String, policy: RequestPolicy)`,
  `deregisterRequestHandler(path: String)`
- `link(IdentifiedActionOf<LinkSession>)` (the `.forEach` element action)
- `delegate(Delegate)`

`LinkPlane.Action.Delegate` (surfaced to the host):
- `transmit(InterfaceID, Data)` — **the routing delegate**: the host sends `raw` on the interface
  identified by the `InterfaceID`.
- `linkEstablished(linkID: Data, destinationHash: Data)`, `linkDataReceived(linkID: Data, data: Data)`,
  `linkClosed(linkID: Data, reason: LinkSession.CloseReason)`, `linkFailed(destinationHash: Data)`,
  `resourceReceived(linkID: Data, data: Data)`, `resourceConcluded(linkID: Data, resourceHash: Data)`,
  `resourceFailed(linkID: Data, resourceHash: Data)`,
  `linkIdentified(linkID: Data, remoteIdentity: Identity)`,
  `requestReceived(linkID: Data, requestID: Data, pathHash: Data, data: Data)`,
  `responseReceived(linkID: Data, requestID: Data, data: Data)`,
  `requestFailed(linkID: Data, requestID: Data)`.

`LinkPlane` internals: `.forEach(\.links, action: \.link) { LinkSession() }`; on `openLink` /
`acceptLinkRequest` it mints a `LinkSession.State` (initiator/responder) with the passed
`interfaceID` and sends `.establish` / `.acceptRequest`; on `routeLinkPacket` it routes to the
held link; on each `LinkSession` element `.delegate` it maps to the corresponding `LinkPlane`
delegate — including `.transmit(txID, raw)` → `.delegate(.transmit(txID, raw))`; the request-handler
auto-response (allow-gate via `RequestPolicy` + the `@Dependency(\.requestResponder)`) lives here,
emitting `sendResponseOverLink` internally. `@Dependency(\.uuid)` mints link element ids.

**`Endpoint` after A2** keeps its full public action/delegate surface unchanged. Its body becomes:
`Scope(\.interface)` + `Scope(\.transport)` + `Scope(\.linkPlane) { LinkPlane() }` + a thin
`Reduce` that:
- maps its public link actions → the matching `LinkPlane` action, translating
  `openLink(destinationHash:)` by reading `transport.learned[dest]` (as today: if not learned →
  emit `.delegate(.linkFailed(dest))` and do NOT call `LinkPlane`; else compute
  `interfaceID = id`, `relayNextHop` and call `LinkPlane.openLink`), and
  `.transport(.delegate(.linkRequest(dest, arrival, data)))` →
  `acceptLinkRequest(owner:, destinationHash:, interfaceID: id, data:)` by reading
  `transport.localDestinations[dest].identity` (guarding `privateKey != nil` as today);
- routes `LinkPlane.delegate.transmit(txID, raw)` → `guard txID == id → .interface(.send(raw))`;
- forwards every other `LinkPlane` delegate to the identical `Endpoint` delegate.

`Endpoint.State` embeds `linkPlane: LinkPlane.State` in place of its current `links` + `registrations`
(those move into `LinkPlane.State`). `LinkSession.State`'s `interfaceID` for `Endpoint` links stays
`id` (equivalently `learned.interfaceID`), preserving behavior.

### A3 — `BLEEndpoint` gains `LinkPlane`

`BLEEndpoint.State` embeds `linkPlane: LinkPlane.State`. Its body adds
`Scope(\.linkPlane) { LinkPlane() }` and the same thin mapping as `Endpoint`, with two BLE
specifics:
- **Public link actions** (new on `BLEEndpoint`, mirroring `Endpoint`): `openLink`, `sendOverLink`,
  `sendResourceOverLink`, `identifyOverLink`, `sendRequestOverLink`, `sendResponseOverLink`,
  `sendWithReceiptOverLink`, `closeLink`, `registerRequestHandler`, `deregisterRequestHandler`, plus
  the new link/resource/request delegates (identical shapes to `Endpoint`'s).
- **Link creation:** `openLink(dest)` reads `transport.learned[dest]` and passes
  `interfaceID = learned.interfaceID` (which for BLE is `bleInterfaceID(peerToken)`); the responder
  path passes `interfaceID = arrivalInterface` (from the A1-enabled `linkRequest`). No `id`.
- **Routing:** `LinkPlane.delegate.transmit(txID, raw)` → `guard let peer = peerInterfaces[txID]`
  → `.ble(.send(peer: peer, packet: raw))` (drop if `txID` isn't a live peer).
- `.transport(.delegate(.linkPacket(linkID, data)))` → `routeLinkPacket(linkID:, data:)`;
  `.transport(.delegate(.linkRequest(dest, arrival, data)))` → `acceptLinkRequest(...)` with the
  arrival interface.

## Data flow (BLE link, responder example)

Peer's LINKREQUEST arrives as `channelData` → `BLEInterface` deframes → `.packetReceived(token, raw)`
→ `.transport(.received(bleInterfaceID(token), raw))` → Transport emits
`.linkRequest(dest, arrivalInterface: bleInterfaceID(token), data)` → `BLEEndpoint` →
`LinkPlane.acceptLinkRequest(owner, dest, interfaceID: bleInterfaceID(token), data)` → responder
`LinkSession` created with that `interfaceID`, emits `.delegate(.transmit(that-id, LRPROOF))` →
`BLEEndpoint` maps the id back to the peer token → `.ble(.send(peer, LRPROOF))` → framed to the
peer's channel. Subsequent link packets route via the link's stored `interfaceID` identically.

## Error handling

No new failure modes. A `transmit` whose `InterfaceID` is not a live BLE peer (peer dropped
mid-link) is dropped by the routing guard; the `LinkSession`'s own watchdog/close handling
proceeds independently, and `BLEEndpoint` surfaces `linkClosed`/`linkFailed` as today. `Endpoint`'s
`txID == id` guard is unchanged.

## Testing

Mutation-testing discipline throughout; `.off` TestStores asserting behavior.

- **A1:** existing Transport + Endpoint tests updated to the new `linkRequest` arity and still green;
  a focused assertion that the emitted `linkRequest` carries the correct `arrivalInterface`.
- **A2:** the **entire existing `EndpointTests` suite passes unchanged** (the refactor's proof —
  including the two-endpoint link establish/data/close, resource transfer, large request/response,
  identify, and the request-handler registry tests). Plus focused `LinkPlaneTests` for the routing
  delegate: a link element `.transmit(txID, raw)` surfaces as `LinkPlane.delegate.transmit(txID, raw)`;
  `openLink`/`acceptLinkRequest` mint a link with the passed `interfaceID`.
- **A3:** a single-store BLE link integration test mirroring `EndpointTests`' responder path over the
  BLE seam: bring a peer online (driver handshake), register a local destination, inject a crafted
  LINKREQUEST as `channelData` → assert an LRPROOF is emitted to that peer via `.ble(.send)`, and a
  crafted link-data packet routes to the held link. Plus `BLEEndpoint` unit tests for the new link
  action forwarding + the per-peer transmit routing (transmit to a live peer → `ble.send`; transmit
  to an unknown id → dropped).

## Deliverables

- Modify: `Sources/ReTiCATransport/Transport.swift` (linkRequest delegate arity) + its tests.
- Create: `Sources/ReTiCANode/LinkPlane.swift`; `Tests/ReTiCANodeTests/LinkPlaneTests.swift`.
- Modify: `Sources/ReTiCANode/Endpoint.swift` (embed `LinkPlane`); existing `EndpointTests` stay green.
- Modify: `Sources/ReTiCANode/BLEEndpoint.swift` (embed `LinkPlane` + link surface + per-peer routing);
  extend `Tests/ReTiCANodeTests/BLEEndpointTests.swift` + add a BLE link integration test.

## Out of scope (follow-ons)

- **Renaming `Endpoint` → `TCPEndpoint`** — deferred to a later pass once the user's concurrent
  `LXMF*` WIP has landed (it touches many `LXMF*`/`PN*` files).
- **Sub-project B** — generalizing `LXMFNode` over a transport-endpoint protocol so full LXMF
  (opportunistic + direct + propagation) runs over TCP or BLE. `LinkPlane`'s delegate surface is the
  shared piece B builds on.
- Any change to `LinkSession`, `BLEInterface`, `FCBDriverAdapter`, or the wire protocol.
- A node running TCP and BLE simultaneously (mixed-transport routing).
