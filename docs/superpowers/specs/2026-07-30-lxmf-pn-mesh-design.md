# LXMF-4d-5b: Propagation Node Mesh (peer sync) — Design

**Sub-project:** LXMF-4d propagation, integration layer. Extends `PropagationNode` (4d-3b) with PN↔PN peering, using the 4d-5 gossip primitive and 5c peering-key validator. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMRouter.offer_request` (`wanted_ids` from an offer), `LXMPeer` sync (a peer offers its `transient_id`s; the receiver pulls what it lacks), `validate_peering_key`.

## Scope decision (autonomous)

The mesh's testable essence — and the only part that fits our pure/reducer pattern — is the **dedup exchange**: a peer offers its `transient_id` set; we compute the subset we're missing (`PropagationStore.wanted`, 4d-5) and request it; we offer our own ids (`PropagationStore.transientIds`); and we authorize a peer by validating its peering key (`LXStamper.validatePeeringKey`, 5c). Because peer sync operates on the **same message store** the node already holds (RNS's one `LXMRouter` serves clients *and* peers), this extends `PropagationNode` rather than adding a store-sharing sibling reducer. The literal peer link/transfer networking (connecting to a peer, moving the requested messages) stays app glue; a peer-fetched batch arrives back through the existing `.ingestContainer`.

## Architecture

Extend `Sources/ReTiCANode/PropagationNode.swift` (no new type, no new state — the exchange is stateless over the store; the app owns peer connections).

### Actions (additions)
- `case peerOffered(peerHash: Data, transientIds: [Data])` — a peer announced which `transient_id`s it holds.
- `case offerToPeer(peerHash: Data)` — the app wants our offer set to send to a peer.
- `case validatePeeringKey(peerHash: Data, peeringId: Data, peeringKey: Data, targetCost: Int)` — authorize a peer.

### Delegate (additions)
- `case requestFromPeer(peerHash: Data, transientIds: [Data])` — the ids we lack and want the app to fetch from that peer (fetched messages come back via `.ingestContainer`).
- `case offerTransientIds(peerHash: Data, transientIds: [Data])` — our offer set for the app to send.
- `case peerValidated(peerHash: Data, valid: Bool)` — the peering-key verdict.

### Reducer
- **`.peerOffered(peerHash, offered)`:** `return .send(.delegate(.requestFromPeer(peerHash: peerHash, transientIds: state.store.wanted(fromOffered: offered))))` — request only the ids we don't already have (convergence rests on `transient_id`).
- **`.offerToPeer(peerHash)`:** `return .send(.delegate(.offerTransientIds(peerHash: peerHash, transientIds: state.store.transientIds)))`.
- **`.validatePeeringKey(peerHash, peeringId, peeringKey, targetCost)`:** `let valid = LXStamper.validatePeeringKey(peeringId: peeringId, peeringKey: peeringKey, targetCost: targetCost); return .send(.delegate(.peerValidated(peerHash: peerHash, valid: valid)))`.

The existing client-facing cases (`.ingestContainer` / `.messagesRequested` / `.messagesDelivered`) are unchanged; a peer-fetched batch is ingested through `.ingestContainer` (deduped by the store).

## Data flow

```
peer announces ids → .peerOffered(peer, [ids]) → .delegate(.requestFromPeer(peer, store.wanted(offered)))
                     (app fetches those from the peer → container) → .ingestContainer → store.ingest (dedup)
we sync to a peer  → .offerToPeer(peer) → .delegate(.offerTransientIds(peer, store.transientIds))
peer authorizes    → .validatePeeringKey(peer, id, key, cost) → .delegate(.peerValidated(peer, valid))
```

Two nodes converge because each pulls only the `transient_id`s it lacks; identical messages carry identical ids.

## Testing

TCA `TestStore`, `exhaustivity = .off`, mutation-verified. Reuse the `PropagationNode` test helpers (`entry`/`container`).

1. **peerOffered requests only the missing ids.** Ingest entries `x`, `y`; a peer offers `[tid(x), tid(y), tid(z), tid(w)]` (z, w not held) → `.requestFromPeer(peer, [tid(z), tid(w)])` (offered order, deduped by `store.wanted`).
2. **offerToPeer offers our stored ids.** Ingest `e1, e2` → `.offerToPeer(peer)` → `.offerTransientIds(peer, [tid(e1), tid(e2)])` (oldest-first).
3. **validatePeeringKey routes the verdict.** With `targetCost: 0` any key validates → `.peerValidated(peer, valid: true)`; with a high `targetCost` (e.g. 250) an arbitrary key fails → `.peerValidated(peer, valid: false)`. (The PoW itself is cross-validated in 5c; this asserts the reducer forwards `LXStamper.validatePeeringKey`'s result.)
4. **Peer-fetched batch ingests + dedups (integration sanity).** After (1), feeding the fetched container via `.ingestContainer` stores the new ids and re-offering yields the same ids deduped — confirms the loop closes on the existing ingest path. *(Optional; fold in only if it adds signal beyond the 4d-3b ingest tests.)*

No cross-val (pure orchestration over the cross-validated `PropagationStore` gossip primitive + `LXStamper` validator).

## Deferred

- Peer link/transfer networking (connecting to a peer, moving requested messages) — Endpoint/Transport glue.
- Peer registry / lifecycle (auto-peering, unpeer, throttling, `max_peers`), and the "unauthorized peer may push only 1 message per transfer" enforcement — mesh policy on top of the exchange.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- Prefer non-exhaustive TCA tests (`exhaustivity = .off`).
- New production extends the `PropagationNode` reducer (ReTiCANode); tests in `ReTiCANodeTests`. Reuses `PropagationStore` (4d-3/4d-5) + `LXStamper` (5c). No core/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
