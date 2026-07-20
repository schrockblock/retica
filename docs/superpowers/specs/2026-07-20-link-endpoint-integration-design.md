# Link ↔ Endpoint Integration — Design (slice 5-links-e)

**Status:** Approved
**Date:** 2026-07-20
**Depends on:** 5-links-b/c/d (`LinkSession` establish + data + close + watchdog), Transport (#4), Endpoint (#5) — all merged.

## Goal

Wire the standalone `LinkSession` reducer into the running `Endpoint` so links are usable
end-to-end: the endpoint can open a link to a learned destination, accept inbound link
requests to its local destinations, route inbound link packets to the right link by `link_id`,
send/close data over a link, and surface link lifecycle events. Two `Endpoint`s can establish a
link with each other. Wire-compatible with reference RNS 1.3.8 (no new wire formats — this is
composition/routing).

## Scope

**In scope**
- `Transport` recognizes link-addressed traffic and surfaces it via two new delegates
  (`linkPacket`, `linkRequest`), bypassing the announce/data dedup for link traffic.
- `LinkSession.State` becomes `Identifiable` (`id: UUID`), enabling a `.forEach` collection.
- `Endpoint` holds `links: IdentifiedArrayOf<LinkSession.State>` composed via `.forEach`, and:
  - routes inbound link packets to the matching link by `link_id`;
  - creates a responder link on an inbound LINKREQUEST to a local destination;
  - `openLink(destinationHash:)` creates an initiator link to a learned destination;
  - forwards each link's `transmit` to the interface;
  - `sendOverLink(linkID:data:)` / `closeLink(linkID:)`;
  - bubbles link lifecycle up as `Endpoint.delegate(.linkEstablished/.linkDataReceived/.linkClosed/.linkFailed)`.
- End-to-end: two `Endpoint`s establish a link, exchange data, and close.

**Explicitly out of scope** (future)
- Garbage-collecting closed links from the collection (they stay inert — timers self-cancel).
- Multiple interfaces per endpoint (single TCP interface, as today).
- `identify()`, requests/responses, resources.
- RTT-adaptive keepalive, STALE state (already deferred in the watchdog slice).

## Architecture

Two layers change; each keeps its existing responsibility.

### Transport — recognize link traffic (`Sources/ReTiCATransport/Transport.swift`)

Add two `Delegate` cases:

```
case linkPacket(linkID: Data, data: Data)     // a .link-addressed packet (proof/rtt/keepalive/close/link-data)
case linkRequest(destinationHash: Data, data: Data)  // an inbound LINKREQUEST to a local destination
```

In `received(interfaceID, data)`, after parsing the packet but BEFORE the `seenPacketHashes`
dedup and the announce/data switch:

- If `packet.destinationType == .link` → `return .send(.delegate(.linkPacket(linkID:
  packet.destinationHash, data: data)))`. (Bypasses dedup — byte-identical keepalives share a
  packet hash and must not be deduped.)
- Else if `packet.packetType == .linkRequest`, and `state.localDestinations[packet.destinationHash]
  != nil` → `return .send(.delegate(.linkRequest(destinationHash: packet.destinationHash, data:
  data)))`. (Also pre-dedup: a retried link request should still reach us.)
- Else: existing behavior (dedup via `seenPacketHashes.insert`, then the announce/data switch).

Link traffic carries the raw `data` (the whole packet); `LinkSession` re-parses it. Transport
does not decrypt or interpret link payloads.

### LinkSession — Identifiable (`Sources/ReTiCATransport/LinkSession.swift`)

Add a stable collection id (the `link_id` is empty until establish/accept, so it cannot key the
collection):

```
public let id: UUID
```

Both initializers gain `id: UUID = UUID()` (defaulted so the existing standalone Link tests are
unchanged; the `Endpoint` passes a controlled id from `@Dependency(\.uuid)`). Conform:
`extension LinkSession.State: Identifiable {}`. No behavioral change to the reducer.

### Endpoint — own the link collection (`Sources/ReTiCANode/Endpoint.swift`)

State:

```
public var links: IdentifiedArrayOf<LinkSession.State> = []
```

Body: add `.forEach(\.links, action: \.link) { LinkSession() }` to the composition, and
`@Dependency(\.uuid) var uuid`.

New `Endpoint.Action` cases:

```
case link(IdentifiedActionOf<LinkSession>)     // the .forEach child action
case openLink(destinationHash: Data)
case sendOverLink(linkID: Data, data: Data)
case closeLink(linkID: Data)
```

New `Endpoint.Delegate` cases:

```
case linkEstablished(linkID: Data)
case linkDataReceived(linkID: Data, data: Data)
case linkClosed(linkID: Data, reason: LinkSession.CloseReason)
case linkFailed(destinationHash: Data)         // couldn't open (unknown destination) or handshake failed
```

## Data flow / routing

Let `id = state.interfaceID`.

**Inbound link packet** — `transport(.delegate(.linkPacket(linkID, data)))`:
- Find `element = state.links.first { $0.linkID == linkID }`. If found → `.send(.link(.element(id:
  element.id, action: .received(data))))`. If none → `.none` (a link packet for a link we don't
  hold; ignore).

**Inbound link request** — `transport(.delegate(.linkRequest(destHash, data)))`:
- `guard let owner = state.transport.localDestinations[destHash]?.identity, owner.privateKey != nil`
  else `.none`.
- Create `var s = LinkSession.State(responderFor: owner, destinationHash: destHash, interfaceID:
  id, id: uuid())`, `state.links.append(s)`, and `.send(.link(.element(id: s.id, action:
  .acceptRequest(data))))`.

**Open a link** — `openLink(destinationHash:)`:
- `guard let learned = state.transport.learned[destinationHash]` else `.send(.delegate(.linkFailed(
  destinationHash: destinationHash)))`.
- Create `var s = LinkSession.State(initiatorTo: learned.identity, destinationHash:
  destinationHash, interfaceID: id, id: uuid())`, `state.links.append(s)`, `.send(.link(.element(id:
  s.id, action: .establish)))`.

**Link transmit → interface** — `link(.element(_, .delegate(.transmit(txID, raw))))`:
- `guard txID == id else { return .none }` → `.send(.interface(.send(raw)))`.

**Link lifecycle bubbling** — `link(.element(elementID, .delegate(X)))`:
- `.established(linkID, _)` → `.send(.delegate(.linkEstablished(linkID: linkID)))`.
- `.dataReceived(data)` → look up `linkID = state.links[id: elementID]?.linkID` → `.send(
  .delegate(.linkDataReceived(linkID: linkID, data: data)))`.
- `.closed(reason)` → `.send(.delegate(.linkClosed(linkID: <linkID from element>, reason: reason)))`.
  The element stays in `links` (inert; its timers were cancelled by the LinkSession's own
  `cancelAll`). Not removed this slice (removal risks dropping the in-flight LINKCLOSE transmit).
- `.establishmentFailed` → `.send(.delegate(.linkFailed(destinationHash: <element.destinationHash>)))`.

**Send / close over a link:**
- `sendOverLink(linkID, data)` → find `element` by `linkID`; if found → `.send(.link(.element(id:
  element.id, action: .send(data))))`, else `.none`.
- `closeLink(linkID)` → find `element` by `linkID`; if found → `.send(.link(.element(id:
  element.id, action: .close)))`, else `.none`.

The existing interface/transport wiring is unchanged. `interface.packetReceived → transport.received`
still feeds Transport, which now forwards link traffic back up as `linkPacket`/`linkRequest`.

## Error handling

- `openLink` to an unlearned destination → `.delegate(.linkFailed(destinationHash:))`, no link created.
- Inbound `linkRequest` for a destination we don't own or that lacks a private key → ignored.
- Inbound `linkPacket` for an unknown `link_id` → ignored.
- A link that fails its handshake emits `.establishmentFailed` → bubbled as `.linkFailed`; the
  element remains (inert). Timers are cancelled by the LinkSession on any terminal transition.
- `sendOverLink`/`closeLink` on an unknown `linkID` → ignored.

## Testing

- **Transport unit tests** (`TestStore`): a `.link`-type inbound packet → `.delegate(.linkPacket(
  linkID:data:))`; a LINKREQUEST to a registered local destination → `.delegate(.linkRequest(
  destinationHash:data:))`; a LINKREQUEST to an unknown destination → NOT surfaced; two byte-identical
  keepalive-style `.link` packets both surface (dedup bypass), whereas two identical DATA packets to a
  local destination dedup to one delivery (existing behavior preserved).
- **Endpoint unit tests** (`TestStore`, `@Dependency(\.uuid) = .incrementing`, `TestClock`):
  - `openLink` to a learned destination creates a link and emits a LINKREQUEST via `interface.send`.
  - `openLink` to an unlearned destination → `.delegate(.linkFailed)`.
  - An inbound `transport.linkRequest` creates a responder link and emits an LRPROOF via `interface.send`.
  - An inbound `transport.linkPacket` for a held link routes to that link (`.link(.element(id:,
    .received)))`).
  - A link `delegate(.established)` bubbles `Endpoint.delegate(.linkEstablished(linkID:))`;
    `.dataReceived` bubbles `.linkDataReceived(linkID:data:)`; `.closed` bubbles `.linkClosed(linkID:reason:)`.
  - `sendOverLink`/`closeLink` dispatch to the right element.
- **End-to-end test:** two `Endpoint`s (A initiator-capable, B with a registered local destination),
  each with a mock interface. B announces its destination; A learns it; A `openLink`s. Shuttle each
  endpoint's `interface.send` bytes into the other's `interface.connectionEvent(.data(HDLC.frame(...)))`.
  Assert both reach `.linkEstablished` with the same `link_id`; A `sendOverLink` → B
  `.linkDataReceived`; A `closeLink` → B `.linkClosed`. Uses the capture idiom + shared `TestClock`.
- **Mutation testing** per the project three-step discipline for every new/changed test.

## Global constraints

- No new wire formats; wire compatibility is inherited from the composed `LinkSession`/`Transport`.
- The `ReTiCA` core stays dependency-free. TCA (incl. `uuid`/`continuousClock`) confined to the
  non-core targets. Swift 6 strict concurrency; all State remains `Equatable`; `LinkSession.State`
  gains `Identifiable`.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.
- `Endpoint` remains a thin composition/wiring layer; packet-parsing for link recognition lives in
  `Transport`.

## Non-goals recap

Closed-link GC, multiple interfaces, identify/requests/resources, and RTT-adaptive keepalive are
deferred. This slice makes the Link stack usable inside the running endpoint: open, accept,
route, use, and close links — with two endpoints able to link end-to-end.
