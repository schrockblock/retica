# Exact (fractional) stamp costs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Use LXMF 1.3.0's exact fractional stamp costs everywhere ReTiCA rounds them today, so a peer advertising 8.5 costs 8.5's work (not 9's), our announces carry the exact cost, and as a propagation node we accept stamps at `cost - flex` as reference does.

**Architecture:** One fixed-point stamp primitive (RNS `Stamps.py`'s `cost_to_fp` / `target_from_fp` / TAB value, already implemented privately in `NetworkStamp`) is shared by network stamps and LXMF stamps; LXMF stamp validation, generation and value take a `Double` cost over LXMF workblocks with 32-byte stamps. Costs and stamp values become `Double` (quantized to 1/256) in announce data, node state and persistence.

**Tech Stack:** Swift 6, TCA, Swift Testing; reference RNS 1.6.0 / LXMF 1.3.0 in `/Users/ell/opt/anaconda3/envs/rns-latest`.

**Spec:** `docs/superpowers/research/2026-11-08-lxmf-1.3-parity.md` §4 (reference with file:line; ReTiCA's rounding sites; gap list 1-8) and the reference source.

## Global Constraints

- Same rules as the SDD workspace's `constraints.md`.
- Values verbatim from reference: `COST_FP_BITS = 8`; `cost_to_fp(c) = clamp(floor(c*256 + 0.5), 0, 100*256)`; integer costs must give exactly the old leading-zero rule; delivery announce emits `[name, ceil(cost) or nil, [SF_COMPRESSION], quantized cost]`; PN announce emits `[5] = [ceil(cost), ceil(flex), ceil(peering)]` and `[7] = [cost, flex, peering]`; PN accepts at `max(0, cost - flex)`; cost gate `0 < cost < 100`.
- Cross-validate every changed wire value and every stamp validity/value against reference via committed generators.
- Our outbound ceiling `maxDeliveryStampCost = 20` and propagation cap 20 stay (as Double).

## Review Focus

1. An integer cost behaves exactly as before (validity, value, generation, wire bytes in element [1]/[5]).
2. A fractional peer cost (e.g. 8.5) produces a stamp valid at 8.5 and not at 8.5 + 1/256 more often than chance — validated by reference.
3. A NaN / infinite / negative / >= 100 cost from the wire is handled as reference handles it, without trapping.
4. Old persisted integer costs (ReTiCAMsgr rows) still load.
5. As a PN with cost 16 and flex 3, a stamp of value 13.0 is accepted and 12.99 refused.

---

### Task 1: Shared fixed-point primitive and fractional LXMF stamps (library)

**Files:** `Sources/ReTiCA/Stamps/NetworkStamp.swift` (expose `fixedPoint(cost:)`, `target(fixedPoint:)`, the TAB value internally to the module or as a small public type), `Sources/ReTiCA/LXMF/LXStamper.swift` (`stampValid` / `stampValue` / `generateStamp` / `generatePnStamp` / `generatePeeringKey` / `validatePnStamp` take `Double` and use it), `LXMessage.validateStamp`, generators + fixtures, tests.
- [ ] Review Focus 1 and 2 at the stamp level, both directions against reference. Commit.

### Task 2: Fractional costs in announces, node state and PN serving (library)

**Files:** `Sources/ReTiCA/LXMF/LXMFAnnounceData.swift`, `PNAnnounce.swift`, `Sources/ReTiCANode/LXMFNode.swift` (`LearnedPeer.stampCost`, `State.deliveryStampCost`, `setDisplayName`, outbound cost, propagation cost), `PropagationStore.swift` / `PropagationNode.swift` / `LXMFServiceNode.swift` (target cost + flex + peering cost), README.
- [ ] Parse [3] / [7] exactly; emit the 4-element delivery data and the [5]+[7] PN data; PN validates at `max(0, cost - flex)` and advertises real flex/peering.
- [ ] Tests for Review Focus 3 and 5; cross-validate the emitted app data in reference (`stamp_cost_from_app_data`, `pn_announce_data_is_valid`, `pn_stamp_cost_from_app_data`). Commit.

### Task 3: ReTiCAMsgr stores fractional costs

**Files (app worktree):** `LearnedPeerRow` (stamp cost column → REAL via a new migration that converts existing integers), any other row storing a cost; tests.
- [ ] Review Focus 4: an old integer row loads as that Double; a fractional cost round-trips. Commit on the branch; app suite.

---

## Status

Tasks 1-3 landed (ReTiCA 2632744, 2d20a07; ReTiCAMsgr 66b09f9). The final review's fix landed after them:
I1 (predates the plan): a `PNNode` sync offers a peer only the entries whose recorded stamp value meets
the peer's `max(0, cost - flex)` from its announce, waits for that announce before opening a link, and
skips the key search and offer when nothing qualifies. `PropagationNode.offerToPeer` takes the peer's
minimum and filters the same way. Docs M1 and M2 are fixed in the same commit.

**Follow-up (review M3, predates the plan, not done):** offers still ignore the peer's per-transfer and
per-sync limits. Reference skips an entry larger than `propagation_transfer_limit*1000` and marks it
handled for that peer, and stops adding entries at `propagation_sync_limit*1000`, filling in weight
order (size times age, prioritised destinations lighter; LXMPeer.py:363-384, LXMRouter.py:1188-1199).
We keep no per-entry receive time and no per-peer handled set, so a version on the same line would
pick a different subset under the sync limit. It needs both before it can match.
