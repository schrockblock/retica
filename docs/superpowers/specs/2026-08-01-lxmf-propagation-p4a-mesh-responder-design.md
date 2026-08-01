# LXMF Propagation P4a — PN↔PN Mesh Responder — Design

**Date:** 2026-08-01
**Status:** Approved (design)

## Context

P4 is PN↔PN mesh sync (the `/offer` protocol), letting propagation nodes
gossip stored messages to each other. Researched from reference LXMF
(`LXMPeer.sync` / `LXMRouter.offer_request`, `LXMPeer.OFFER_REQUEST_PATH =
"/offer"`):

1. Initiator PN links to a peer PN's `lxmf.propagation` dest, `IDENTIFY`s, and
   sends `request("/offer", [peering_key, offered_transient_ids])`.
2. The peer's `/offer` handler requires IDENTIFY, validates the **peering key**
   (`peering_id = self.identity.hash + remote_identity.hash`, cost =
   `peering_cost`), computes `wanted` = offered ids it lacks, and responds
   `False` (has all) / `True` (wants all) / `[wanted ids]`.
3. The initiator transfers the wanted messages as a **Resource** —
   `msgpack([timestamp, [lxmf_data…]])`, the **same container format** — which
   the peer ingests.

P4 decomposes: **P4a (this slice)** the responder (accept an offer + ingest);
**P4b** the initiator (send an offer + transfer); **P4c** policy (peering-cost
enforcement, PoW peering-key generation, peer registry, scheduling/throttle).

## Scope (P4a)

**In scope:** `PNNode`'s `/offer` request handler — require IDENTIFY, validate
the peering key (at cost 0), compute `wanted`, respond with the wanted list.
The follow-up Resource transfer ingests via P3b's existing
`resourceReceived → ingestContainer` wire (unchanged).

**Out of scope / deferred:**
- Peering-*cost* enforcement (cost 0 = open mesh here) + initiator PoW
  peering-key generation → P4c.
- The initiator side (send `/offer`, transfer wanted messages) → P4b.
- Peer registry, sync scheduling, throttling (`ERROR_THROTTLED`), `from_static_only`
  access control → P4c.
- `True`/`False` response optimizations — P4a always returns an explicit list
  (wire-compatible; empty list = "peer has all").

## Architecture

Reuses: the gossip primitive (`PropagationNode.peerOffered → requestFromPeer`
via `store.wanted(fromOffered:)`), `PropagationNode.validatePeeringKey →
peerValidated` (LXStamper), and P3b's ingest wire for the transfer. The
`/offer` handler mirrors P3b's `/get` unregistered-surface pattern, but with a
**two-hop** correlation (validate → wanted).

### State

```swift
public var pendingOffer: [Data: PendingOffer] = [:]   // peerHash → (linkID, requestID, offeredIds)
```
```swift
public struct PendingOffer: Equatable {
    public var linkID: Data
    public var requestID: Data
    public var offeredIds: [Data]
}
```

`peeringCost` is **0** for P4a (open mesh) — a local constant with a comment;
P4c makes it configurable and enforced.

### `/offer` handler (extend `requestReceived` to dispatch by path)

The existing `requestReceived` guards `pathHash == truncatedHash("/get")`.
Restructure to dispatch:

```swift
case let .endpoint(.delegate(.requestReceived(linkID, requestID, pathHash, data))):
    guard let clientIdentity = state.clientIdentities[linkID] else { return .none }   // no IDENTIFY → drop
    if pathHash == Crypto.truncatedHash(Data("/get".utf8)) {
        // … existing P3b /get dispatch (clientHash, pendingGet, messageListRequested / messagesRequested) …
    }
    if pathHash == Crypto.truncatedHash(Data("/offer".utf8)) {
        guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2,
              case let .bin(peeringKey) = items[0] else { return .none }
        let offeredIds = PNNode.arrayOfBin(items[1])
        let peerHash = Destination.hash(identityHash: clientIdentity.hash,
                                        appName: LXMessage.appName, aspects: ["propagation"])
        let peeringId = state.identity.hash + clientIdentity.hash
        state.pendingOffer[peerHash] = PendingOffer(linkID: linkID, requestID: requestID, offeredIds: offeredIds)
        return .send(.node(.validatePeeringKey(peerHash: peerHash, peeringId: peeringId,
                                               peeringKey: peeringKey, targetCost: 0)))
    }
    return .none
```

(The identity guard now covers both paths — RNS `/get` and `/offer` both
require IDENTIFY. This is a benign tightening of `/get`, which already dropped
on no-identity. P3b's `/get` body moves inside the `if` unchanged.)

### Two-hop correlation

```swift
case let .node(.delegate(.peerValidated(peerHash, valid))):
    guard let pending = state.pendingOffer[peerHash] else { return .none }
    if valid { return .send(.node(.peerOffered(peerHash: peerHash, transientIds: pending.offeredIds))) }
    state.pendingOffer[peerHash] = nil                     // invalid key → drop (dead path at cost 0)
    return .none

case let .node(.delegate(.requestFromPeer(peerHash, wanted))):
    guard let pending = state.pendingOffer[peerHash] else { return .none }
    state.pendingOffer[peerHash] = nil
    return .send(.endpoint(.sendResponseOverLink(linkID: pending.linkID, requestID: pending.requestID,
                                                 data: MsgPack.encode(.array(wanted.map { .bin($0) })))))
```

`peerOffered` computes `wanted = store.wanted(fromOffered: offeredIds)` (offered
ids the store lacks) and emits `requestFromPeer`. The transfer that follows is
ingested by the existing `resourceReceived → ingestContainer` wire.

### Data flow

```
Peer initiator: identify → PN linkIdentified (clientIdentities[link])
  request("/offer", [peeringKey, offeredIds]) → PN requestReceived (/offer)
    → validatePeeringKey(peerHash, id, key, cost 0) → peerValidated(valid)
    → peerOffered(peerHash, offeredIds) → requestFromPeer(peerHash, wanted=store lacks)
    → sendResponseOverLink([wanted])
  Resource transfer(msgpack([ts,[lxmf_data]])) → PN resourceReceived → ingestContainer → stored
```

## Testing

Injected-delegate unit tests in `PNNodeTests` (no link handshake, like P3b):

1. **Offer, store lacks all → wants all:** `linkIdentified(link, peerIdentity)`;
   `requestReceived(link, rid, hash("/offer"), MsgPack([.bin(key),
   .array([.bin(id1), .bin(id2)])]))` → assert
   `sendResponseOverLink(link, rid, MsgPack([.bin(id1), .bin(id2)]))`.
2. **Offer, store already has one → wants the other:** ingest a container whose
   single entry's `transientId == id1` first (via `resourceReceived`), then the
   same offer → response `[id2]`.
3. **`/offer` without IDENTIFY → drop:** `requestReceived(/offer)` with no prior
   `linkIdentified` → no `sendResponseOverLink` (flip `.on` last).
4. **Regression:** the P3b `/get` tests still pass (the identity-guard hoist and
   path dispatch don't change `/get` behavior).

(The transfer-ingest path is already covered by P3b's `resourceReceived →
ingestContainer` tests; note it, don't re-test.)

Mutation verification, one at a time (e.g. drop the `peerValidated → peerOffered`
hop → no response; break the `requestFromPeer` correlation → no response).

## Known Limitations (P4a)

- Cost-0 open mesh; the invalid-key branch is wired but unexercised (cost-0
  validation always passes) — P4c enforces a real cost.
- Response is always an explicit list (no `True`/`False` optimization).
- Initiator side, peer registry, scheduling/throttle → P4b/P4c.
