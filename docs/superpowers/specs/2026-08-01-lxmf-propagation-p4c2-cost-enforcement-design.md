# LXMF Propagation P4c-2 — PNNode Peering-Cost Enforcement — Design

**Date:** 2026-08-01
**Status:** Approved (design)

## Context

The mesh currently runs open: the P4a responder validates peering keys at cost
0 (any key passes) and the P4b-2 initiator sends a trivial cost-0 key. P4c-1
added `LXStamper.generatePeeringKey`. P4c-2 wires real enforcement — a
`PNNode` validates at a configured cost, and the initiator generates a valid
key at the peer's cost (as an async effect, since PoW is blocking).

## Scope

**In scope:** a configurable `peeringCost` on `PNNode` (used in the announce +
the responder validation), the initiator generating a real key at the peer's
(caller-supplied) cost via an async effect, and the invalid-key rejection path
going live. Injected unit tests + a cost>0 integration test.

**Out of scope / deferred:**
- Auto-parsing the peer's cost from its `PNAnnounce` app-data — the **caller
  supplies** the peer cost to `syncToPeer` (the app parses `PNAnnounce` when
  discovering peers; peer discovery/registry is app-layer).
- `ERROR_INVALID_KEY` reply on rejection — the responder simply drops (no
  response). RNS returns the error int; deferred.
- Link teardown/cleanup — P4c-3.

## Architecture

### Config

```swift
public var peeringCost: Int = 0
public init(identity: Identity, endpoint: Endpoint.State, storageLimitBytes: Int? = nil, peeringCost: Int = 0) {
    … self.peeringCost = peeringCost …
}
```

Used in **two** places:
- `registerPropagation` → `PNAnnounce(… peeringCost: state.peeringCost …)` (the
  PN advertises its cost).
- The `/offer` responder validation (below).

### Responder — validate at the configured cost

In the P4a `/offer` `requestReceived` branch, change the hardcoded cost:

```swift
// before: targetCost: 0
return .send(.node(.validatePeeringKey(peerHash: peerHash, peeringId: peeringId,
                                       peeringKey: peeringKey, targetCost: state.peeringCost)))
```

The existing `peerValidated(peerHash, valid)` handler already drops on
`valid == false` (clears `pendingOffer`, no response). With `peeringCost > 0`
this path is now reachable — an invalid key is rejected.

### Initiator — caller-supplied cost + async key generation

`pendingSyncPeers` changes from `Set<Data>` to a cost map:

```swift
public var pendingSyncPeers: [Data: Int] = [:]   // peer dest → the peer's peering cost
```

**Trigger:**
```swift
case let .syncToPeer(destinationHash, peeringCost):
    state.pendingSyncPeers[destinationHash] = peeringCost
    return .send(.endpoint(.openLink(destinationHash: destinationHash)))
```

**Outbound `linkEstablished`** — generate the key off the main reducer:
```swift
case let .endpoint(.delegate(.linkEstablished(linkID, dest))):
    guard let cost = state.pendingSyncPeers[dest] else { return .none }   // inbound responder link → ignore
    state.pendingSyncPeers[dest] = nil
    guard let peerIdentity = state.endpoint.transport.learned[dest]?.identity else { return .none }
    state.offerLinks[linkID] = state.node.store.transientIds
    let peeringId = peerIdentity.hash + state.identity.hash              // responder-first, matches P4a
    let selfIdentity = state.identity
    return .merge(
        .send(.endpoint(.identifyOverLink(linkID: linkID, identity: selfIdentity))),
        .run { send in
            let key = LXStamper.generatePeeringKey(peeringId: peeringId, targetCost: cost)   // PoW, off-reducer
            await send(.offerKeyReady(linkID: linkID, key: key))
        })
```

**New action** `offerKeyReady(linkID:, key:)` — send the offer with the real key:
```swift
case let .offerKeyReady(linkID, key):
    guard let offeredIds = state.offerLinks[linkID] else { return .none }
    let offer = MsgPack.encode(.array([.bin(key), .array(offeredIds.map { .bin($0) })]))
    return .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/offer", data: offer)))
```

`responseReceived` (parse `true`/`false`/list → gather → transfer) is unchanged.

### peeringId ordering (interop-critical)

Both ends must compute the same `peeringId`. RNS `offer_request` (responder):
`peering_id = self.identity.hash + remote_identity.hash` = **responder.hash +
initiator.hash**. So:
- Responder (P4a): `state.identity.hash + clientIdentity.hash` — already correct.
- Initiator: `peerIdentity.hash + state.identity.hash` = peer(responder).hash +
  self(initiator).hash — same value.

### Data flow (cost C)

```
A.syncToPeer(B, C) → pendingSyncPeers[B]=C → openLink → handshake
  → A linkEstablished(link, B) → identify + .run generatePeeringKey(B.hash+A.hash, C) → offerKeyReady(link, key)
  → A sendRequestOverLink("/offer", [key, A.transientIds])
  → B (P4a): validatePeeringKey(B.hash+A.hash, key, targetCost: B.peeringCost=C) → valid → peerOffered → wanted
  → A transfers wanted Resource → B ingests
(invalid key → B.peerValidated(false) → drop, no response)
```

## Testing

### Task 1 — enforcement wiring + injected-delegate unit tests

Responder:
1. **Valid key accepted:** `makeStore(peeringCost: C)`; `linkIdentified(link,
   peer)`; build a valid key `k = generatePeeringKey(peeringId = pnIdentity.hash
   + peer.hash, C)`; inject `requestReceived(link, rid, hash("/offer"),
   MsgPack([.bin(k), .array([.bin(id1)])]))` → assert `sendResponseOverLink`
   with the wanted list.
2. **Invalid key rejected:** same, but with `k = Data([0])` at cost C (>0) →
   **no** `sendResponseOverLink` (flip `.on` last). Enforcement is live.

Initiator:
3. **Generates a valid key:** pre-seed `transport.learned[peerDest]` with the
   peer's identity (so `peeringId` resolves — construct the initial state or
   drive a bridged announce). `syncToPeer(peerDest, cost: C)` → `openLink` +
   `pendingSyncPeers[peerDest] == C`; inject `linkEstablished(link, peerDest)`
   → `identifyOverLink` + (await the async) `sendRequestOverLink("/offer",
   [.bin(key), …])`; **assert `validatePeeringKey(peeringId: peerDest-peer.hash
   + self.hash, peeringKey: key, targetCost: C) == true`** (the generated key is
   valid).

(`makeStore` gains a `peeringCost` argument; the responder tests use it, the
existing tests default to 0 so they're unaffected.)

Mutation verification (e.g. responder validates at `0` instead of
`state.peeringCost` → the invalid-key test wrongly accepts; initiator uses the
wrong `peeringId` ordering → the generated key fails validation).

### Task 2 — 2-PNNode cost>0 integration test

Parameterize / extend the P4b-2 mesh test with `peeringCost: C > 0` on PN-B:
PN-A `syncToPeer(B.propDest, peeringCost: C)` → A generates a valid key at C →
B (configured cost C) validates + accepts → A transfers → B ingests
(`contains(tid)`). Proves enforcement end-to-end and that A's generated key
genuinely passes B's validation. Mutation: initiator generates at cost 0 (or
wrong peeringId) → B rejects → B never ingests.

## Known Limitations (P4c-2)

- Caller supplies the peer cost (no `PNAnnounce`-app-data auto-parse).
- Invalid key → silent drop (no `ERROR_INVALID_KEY` reply).
- Registry/scheduling app-layer; teardown P4c-3.
