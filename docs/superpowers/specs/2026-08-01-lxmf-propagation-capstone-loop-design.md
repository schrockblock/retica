# LXMF Propagation — 3-Store Client↔Server Capstone Loop — Design

**Date:** 2026-08-01
**Status:** Approved (design)

## Context

The propagation subsystem is complete as tested components, but each half was
proven only against a stub of the other:
- P1 client-send + P3b PN-ingest were each tested vs a bare-`Endpoint` stub.
- P2 client-sync + P3b PN-serve were each tested vs a stub.

The capstone wires all **three real compositions** end-to-end in one test —
`LXMFNode` sender → `PNNode` ingest → `LXMFNode` recipient sync — proving the
full store-and-forward loop over real transport and surfacing any stub-fidelity
gap.

## Scope

**In scope:** one test-only integration test. No production code (everything
exists: `LXMFNode` send/sync, `PNNode` ingest/serve).

**Out of scope:** any production change; mesh (already proven separately);
registry/scheduling (app-layer).

## Architecture

Three `TestStore`s over the mock-TCP harness, bridged frame-by-frame:
- **S** = `LXMFNode` (sender) — uses `setPropagationNode` + `sendViaPropagation`.
- **PN** = `PNNode` (server) — `registerPropagation`, ingests, serves `/get`.
- **R** = `LXMFNode` (recipient) — uses `setPropagationNode` +
  `syncFromPropagationNode`, surfaces `.delegate.messageReceived`.

### Announce bridging (who learns whom)

- **S needs R's identity** (to encrypt the container to R): R `registerDelivery`
  → announce → bridge to S.
- **S needs PN** (path+identity, to link): PN `registerPropagation` → announce →
  bridge to S.
- **R needs PN** (to sync): PN announce → bridge to R.
- **R needs S's identity** (to validate S's signature): S `registerDelivery` →
  announce → bridge to R.

### Flow

```
1. connect S, PN, R
2. announces: R.delivery → S ; S.delivery → R ; PN.propagation → S and → R
3. SEND:  S.setPropagationNode(PN.propDest); S.sendViaPropagation(R.deliveryHash, title, content)
          → S↔PN link handshake → Resource transfer(container) → PN.resourceReceived → ingestContainer
          → PN.delegate.messagesStored([tid])            (P1 send + P3b ingest, both real)
4. SYNC:  R.setPropagationNode(PN.propDest); R.syncFromPropagationNode
          → R↔PN link handshake → R IDENTIFY → /get [null,null] → PN serves list([tid])
          → R /get [[tid],[]] → PN serves blob([entry]) → R recoverPacked+received(.direct)
          → R.delegate.messageReceived(S's message, validated)   (P2 sync + P3b serve, both real)
5. ASSERT: R received S's message — content/title/sourceHash correct, signatureValidated == true
```

Two independent link sessions (S↔PN for ingest, R↔PN for sync) share the mesh
of three stores. The container S packs is encrypted to R; R (the recipient)
decrypts it on sync — the same identity used for both encryption (S's view of R,
learned via announce) and decryption (R's own identity), as in P2b.

## Testing

One `@Test` (e.g. `lxmfPropagationCapstoneSenderPnRecipient`) in a new
`Tests/ReTiCANodeTests/LXMFPropagationCapstoneTests.swift`:

- Harnesses: an `LXMFNode` `makeNode` (S, R) and a `PNNode` `makePN`, each with
  the mock `TCPConnection`, `TestClock`, fixed `$0.date`, `$0.uuid =
  .incrementing`, `exhaustivity = .off`.
- Reuse the bridge patterns: the S↔PN Resource ingest from
  `LXMFNodePropagationTests.swift`; the R↔PN `/get` request/response from
  `LXMFNodeSyncTests.swift` / `PNNodeIntegrationTests.swift`; link handshakes
  from the direct/mesh tests. Recall the synchronous-multi-send index gotcha
  (capture co-emitted frames by index).
- **Load-bearing final assertions (must not change):** R's
  `.delegate.messageReceived(m, v)` with `m.content`/`m.title` == what S sent,
  `m.sourceHash == LXMessage.deliveryHash(identityHash: sIdentity.hash)`, and
  `v == true` (R learned S's identity → signature validates). Optionally assert
  `PN.delegate.messagesStored` contained the ingested `tid` en route.
- The exact `receive`/bridge interleaving is reconciled by running; the assertions
  are fixed.

Mutation verification (mutate production, confirm the capstone breaks, revert):
e.g. break `PNNode`'s `/get` phase-2 serve (`messagesRequested` deliver) → R
never gets the blob → no `messageReceived`; or break `LXMFNode`'s
`resourceConcluded`/sync open → R can't reconstruct. One at a time.

## Known Limitations

- Single message, single sender/recipient (the loop, not load).
- Mesh (PN↔PN) is proven separately (P4a/P4b), not re-exercised here.
