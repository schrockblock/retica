# LXMF Propagation P4c-1 — LXStamper.generatePeeringKey — Design

**Date:** 2026-08-01
**Status:** Approved (design)

## Context

P4c is mesh policy/hardening. The mesh currently runs open (peering-cost 0):
the P4b-2 initiator sends a trivial cost-0 key and the P4a responder validates
at cost 0. Real cost enforcement needs the initiator to **generate** a peering
key that validates at the peer's target cost — a PoW search `LXStamper` does
not yet have (it has `generateStamp` and `validatePeeringKey`, but no
`generatePeeringKey`).

P4c-1 (this slice) adds that one primitive. P4c-2 (next) wires it into `PNNode`
with a configurable cost on both ends. P4c-3 is link teardown/cleanup. Peer
registry + scheduling are app-layer (out of the library).

## Scope

**In scope:** one pure `LXStamper` static method + its unit test. No reducer,
composition, or transport.

**Out of scope:** cost enforcement in `PNNode`, announce-cost parsing, the
async-effect wiring (all P4c-2).

## Design

Mirror the existing `generateStamp`, but over the **25-round peering
workblock** (the same one `validatePeeringKey` uses), so a generated key
validates by construction:

```swift
/// Generate a peering key: search random 32-byte stamps until one is valid for `targetCost` over
/// `peeringId`'s short (25-round) peering workblock — the initiator's counterpart to
/// `validatePeeringKey` (RNS LXMPeer.generate_peering_key). Mirrors `generateStamp`.
public static func generatePeeringKey(peeringId: Data, targetCost: Int) -> Data {
    let wb = stampWorkblock(material: peeringId, expandRounds: workblockExpandRoundsPeering)
    while true {
        let s = SecureRandom.bytes(stampSize)
        if stampValid(stamp: s, targetCost: targetCost, workblock: wb) { return s }
    }
}
```

- `workblockExpandRoundsPeering` (25) and `stampSize` (32) already exist; the
  workblock and `stampValid` match `validatePeeringKey`, so the round-trip is
  guaranteed.
- PoW cost: generation averages ~`2^targetCost` hash iterations — fine for the
  low costs used in tests and typical peering.

## Testing

Unit test in `LXStamperTests` (place near the peering-key validation tests):

1. **Round-trip invariant (deterministic, load-bearing):** for a `peeringId`
   and a modest cost (e.g. 16 — a fast sub-second search), `let key =
   generatePeeringKey(peeringId, targetCost: 16)`; `#expect(validatePeeringKey(
   peeringId: peeringId, peeringKey: key, targetCost: 16))`. Always true by
   construction.
2. **Cost 0 sanity:** `generatePeeringKey(peeringId, targetCost: 0)` returns a
   key that validates at cost 0 (any key does).

Mutation verification, one at a time:
- Drop the search guard — `return SecureRandom.bytes(stampSize)` (no
  `stampValid` check). At cost 16 the returned key validates only with
  probability 2⁻¹⁶, so the round-trip test reliably FAILS. Revert → PASS.
- Wrong workblock — use `stampWorkblock(material: peeringId)` (default rounds,
  not the 25-round peering rounds). The generated key is valid for the wrong
  workblock; `validatePeeringKey` (25-round) then fails at cost 16 (2⁻¹⁶
  false-pass). Reliably FAILS. Revert → PASS.

(The positive round-trip assertion is deterministic — no flake. The mutations'
reliability rests on the vanishing 2⁻¹⁶ false-pass probability at cost 16.)

## Known Limitations (P4c-1)

- The primitive only; cost enforcement / announce-cost parsing / async-effect
  wiring are P4c-2.
