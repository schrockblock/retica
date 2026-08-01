# LXMF Propagation P4b-2 — PNNode Mesh Initiator — Design

**Date:** 2026-08-01
**Status:** Approved (design)

## Context

P4a made `PNNode` a mesh **responder** (accept an `/offer`, return wanted,
ingest the transfer). P4b-2 makes it a mesh **initiator**: actively sync its
stored messages *out* to a peer PN. This is `PNNode`'s first **outbound**
link-initiation (so far it only responds to inbound links). Completing it, with
the 2-`PNNode` integration test, proves the **full bidirectional mesh**
(initiator P4b + responder P4a) end-to-end.

Reference: `LXMPeer.sync` → link + `identify` + `request("/offer",
[peering_key, unhandled_ids])` → `offer_response` parses `False`/`True`/list →
transfer wanted as `Resource(msgpack([ts, [lxmf_data]]))`.

## Scope

**In scope:** `PNNode` outbound sync — a `syncToPeer` trigger, outbound
`linkEstablished` handling (IDENTIFY + offer), and `responseReceived` handling
(parse `True`/`False`/list → gather via P4b-1 → transfer as a Resource). Plus
injected-delegate unit tests and a 2-`PNNode` integration test.

**Out of scope / deferred to P4c:**
- Per-peer *unhandled-message* tracking — P4b-2 offers **all**
  `store.transientIds` on every sync.
- PoW peering-key generation — P4b-2 sends a trivial cost-0 `.bin` key (the P4a
  responder validates it at cost 0).
- Peer registry, sync scheduling/throttle, link teardown after transfer.

## Architecture

No `Endpoint`/`PropagationNode`/core changes — all the transport actions exist;
the transfer ingests on the peer via P4a→P3b's `resourceReceived →
ingestContainer`.

### State (added to `PNNode.State`)

```swift
public var pendingSyncPeers: Set<Data> = []      // peer dests we've openLink'd, awaiting linkEstablished
public var offerLinks: [Data: [Data]] = [:]      // outbound offer linkID → offeredIds we sent
```

`pendingSyncPeers` gates outbound `linkEstablished` (an inbound responder link
is not in this set, so it still falls through to `.none`). `offerLinks`
identifies an offer-response link and stashes the offered ids (needed for the
`True` = "wants all" response).

### `syncToPeer` trigger

```swift
case syncToPeer(destinationHash: Data)
```
```swift
case let .syncToPeer(destinationHash):
    state.pendingSyncPeers.insert(destinationHash)
    return .send(.endpoint(.openLink(destinationHash: destinationHash)))
```

The caller supplies the peer dest (no registry — P4c) and must have the peer's
path learned (as with any `openLink`).

### Outbound `linkEstablished` → IDENTIFY + offer

`PNNode` does not currently handle `linkEstablished` (inbound responder links
don't need it). Add a case that acts only on a pending sync peer:

```swift
case let .endpoint(.delegate(.linkEstablished(linkID, dest))):
    guard state.pendingSyncPeers.contains(dest) else { return .none }   // inbound link → ignore (as before)
    state.pendingSyncPeers.remove(dest)
    let offeredIds = state.node.store.transientIds
    state.offerLinks[linkID] = offeredIds
    let offer = MsgPack.encode(.array([.bin(Data([0x01])),                       // trivial cost-0 peering key
                                       .array(offeredIds.map { .bin($0) })]))
    return .merge(.send(.endpoint(.identifyOverLink(linkID: linkID, identity: state.identity))),
                  .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/offer", data: offer))))
```

IDENTIFY is emitted **first** so its link packet precedes the `/offer` request
(the P4a responder requires `clientIdentities[linkID]` set by the time it
handles the request — in-order link delivery guarantees this).

### `responseReceived` → parse + transfer

```swift
case let .endpoint(.delegate(.responseReceived(linkID, _, data))):
    guard let offeredIds = state.offerLinks[linkID] else { return .none }   // not an outbound offer link
    state.offerLinks[linkID] = nil
    let wanted: [Data]
    switch MsgPack.decodeValue(data) {
    case .bool(false):        wanted = []                         // peer has all → nothing to transfer
    case .bool(true):         wanted = offeredIds                 // peer wants all offered
    case let .array(items):   wanted = items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
    default:                  return .none                        // malformed
    }
    guard !wanted.isEmpty else { return .none }
    let entries = state.node.store.entries(forTransientIds: wanted).map(\.lxmfData)
    let container = LXMFPropagation.container(timestamp: date.now.timeIntervalSince1970, entries: entries)
    return .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: container)))
```

`True`/`False` are RNS wire-interop (our own P4a responder always returns a
list). `entries(forTransientIds:)` is P4b-1; `container(timestamp:entries:)`
builds the transfer; `@Dependency(\.date)` (already on `PNNode`) supplies the
timestamp.

### Data flow (A syncs to B)

```
A.syncToPeer(B.propDest) → openLink → link handshake (A initiator ↔ B responder)
  → A linkEstablished(link, B) [pending] → identify + request("/offer", [key, A.transientIds])
  → B (P4a): linkIdentified + requestReceived("/offer") → validatePeeringKey(0) → peerOffered
    → requestFromPeer(wanted = B lacks) → sendResponseOverLink([wanted])
  → A responseReceived([wanted]) → store.entries(forTransientIds: wanted) → container → sendResourceOverLink
  → B resourceReceived → ingestContainer → stored  (bidirectional mesh proven)
```

## Testing

### Task 1 — initiator wiring + injected-delegate unit tests

Drive `PNNode` by injecting Endpoint delegate actions (no handshake). Pre-populate
A's store via an injected `resourceReceived(container)` so it has ids to offer.

1. `syncToPeer(peerDest)` → `openLink(peerDest)` and `pendingSyncPeers.contains(peerDest)`.
2. inject `linkEstablished(link, peerDest)` (peer in pending) → asserts
   `identifyOverLink(link, A.identity)` **and** `sendRequestOverLink(link, "/offer",
   MsgPack([.bin(key), .array(offeredIds→.bin)]))`; `offerLinks[link] == offeredIds`.
3. inject `responseReceived(link, _, MsgPack([.bin(id)]))` (id = a held tid) →
   `sendResourceOverLink(link, container)` where `parseContainer(container).entries == [heldLxmfData]`.
4. inject `responseReceived(link, _, .bool(true))` → transfers **all** offered entries.
5. inject `responseReceived(link, _, .bool(false))` → **no** `sendResourceOverLink` (flip `.on` last).
6. inject `linkEstablished(link, otherDest)` with `otherDest` NOT pending → no offer (inbound ignored; flip `.on` last).

Mutation verification (e.g. drop the IDENTIFY from the merge → responder would
reject, but at the unit level assert the identify action is emitted; break the
`responseReceived` gather → no transfer).

### Task 2 — 2-PNNode mesh integration test (capstone)

PN-A and PN-B are both `PNNode`s. Pre-populate A's store (inject a container so A
holds a message for some recipient). `B.registerPropagation` → announce bridged
to A so A learns B's propagation dest. `A.syncToPeer(B.propDest)` → real link
handshake (A initiator ↔ B responder) → A IDENTIFYs → A offers `[key,
A.transientIds]` → **B's P4a responder** validates (cost 0) + returns the wanted
list → A gathers + transfers the Resource → **B ingests** → assert
`B.delegate.messagesStored` and `B.state.node.store.contains(transientId: tid)`
for A's message. Model the link handshake + IDENTIFY + request/response +
Resource bridges on `EndpointTests` / `LXMFNodePropagationTests` /
`PNNodeIntegrationTests`; reconcile the exact receive interleaving by running
(recall the synchronous-multi-send index gotcha). Mutation: break A's
`responseReceived → transfer` → B never ingests.

## Known Limitations (P4b-2)

- Offers all `transientIds` every sync (no per-peer unhandled tracking) — P4c.
- Trivial cost-0 peering key (no PoW generation) — P4c.
- No registry/scheduling/throttle; no link teardown after transfer — P4c.
