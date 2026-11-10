# Parity follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the follow-ups the 2026-11-08..10 parity plans deferred: PN offers honour the peer's transfer and sync limits, a bound on the inbound ratchet-decrypt cost, tickets that arrive while a stamp is pending, destination-stamp queue parity, and the deferred test/comment minors.

**Architecture:** Library changes in ReTiCA (PropagationStore, PNNode, Transport, LXMFNode) plus tests; no app change is expected (ReTiCAMsgr does not persist propagation entries — verify with a grep before closing Task 1).

**Tech Stack:** Swift 6, TCA, Swift Testing; reference RNS 1.6.0 / LXMF 1.3.0 in `/Users/ell/opt/anaconda3/envs/rns-latest/lib/python3.12/site-packages`.

**Spec:** the deferred items as recorded in `docs/superpowers/plans/2026-11-10-exact-stamp-costs.md` (Status, M3), `2026-11-09-ratchets.md` (Deferred follow-ups), `2026-11-09-lxmf-tickets.md` and `2026-11-10-stamp-priority.md` (Status lines), `docs/superpowers/stamp-followups-2026-11-08.md` ("Deferred by the 2026-11-08 plan's reviews"), and the reference source cited per task. Where a deferred note and reference disagree, reference wins unless this plan records a ruling.

## Global Constraints

- Same rules as the SDD workspace's `constraints.md` (one shell command per call, no inline scripts, temp files under `/tmp/ReTiCA/`, three-step mutation verification before every commit, commit straight to main, trailers at column 0).
- Reference values verbatim: offer `per_message_overhead = 16`, initial `cumulative_size = 24`, transfer limit test `lxm_transfer_size > transfer_limit*1000` (skip AND mark handled), sync limit test `next_size >= sync_limit*1000` (skip, `continue`, not stop), weight `priority_weight * max(1, age_seconds/60/60/24/4) * size` sorted ascending (LXMPeer.py:363-384, LXMRouter.py:1188-1199).
- Destination-stamp queue: an announce re-enqueued for the same key is removed and appended at the back; a full queue drops the NEW item and starts no search for it; the item being worked on does not count toward the size (RNS Transport.py:99-121, 1453-1473).
- The known flaky test `holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood` stays as is; any other failure is real until rerun alone.

## Review Focus

1. A peer announcing `perTransferLimit = 256` (KB) is never offered an entry of 256*1000-15 bytes or more, and is not offered it on the next sync either.
2. A peer with `perSyncLimit` smaller than the first entry still gets the later, smaller entries that fit (skip, not stop).
3. Under a junk flood to a ratchet-enabled destination, a legitimate packet encrypted to the newest ratchet still decrypts.
4. A ticket that arrives while a delivery stamp for that peer is queued or being searched ends that search and the message goes out with the ticket stamp, exactly once.
5. Re-announcing a destination whose stamped announce is queued keeps one queued item, at the back.

---

### Task 1: PN offers honour the peer's transfer and sync limits (library)

**Files:** `Sources/ReTiCA/LXMF/PropagationStore.swift` (Entry gains `receivedAt: Date`; `ingest(container:now:)`), `Sources/ReTiCANode/PNNode.swift` (per-peer handled set, offer selection), `Sources/ReTiCANode/PropagationNode.swift` (`offerToPeer` takes the peer's limits), `Sources/ReTiCA/LXMF/PNAnnounce.swift` (read-only: `perTransferLimit` / `perSyncLimit` are already parsed), tests.

**Interfaces:**
- `PropagationStore.Entry.receivedAt: Date` — set by `ingest` from its `now` argument; rehydration re-ingests, so a relaunch resets ages (record this in the doc comment; reference persists `lxm_rcvd`).
- `PropagationStore.offerCandidates(acceptedAt minimum: Double, transferLimitKB: Int?, syncLimitKB: Int?, excluding handled: Set<Data>, now: Date) -> (offer: [Data], oversized: [Data])` — the reference selection loop (Global Constraints values). No prioritised-destination list exists in ReTiCA, so `priority_weight` is always 1.0; say so in a comment.
- `PNNode.State.handledByPeer: [Data: Set<Data>]` (peer hash → transient ids). An id becomes handled for a peer when it is oversized for that peer, when the peer's offer response says it does not want it (reference `offer_response` adds to handled the ids not in the wanted list, and the wanted ones after they are sent — check LXMPeer.py `offer_response` and `resource_concluded` and match it), or when the peer offered it to us. In memory only; a relaunch costs one redundant offer (ruling — record in Status).

- [ ] Tests: Review Focus 1 and 2; weight order (an older entry of equal size sorts after a newer one; a smaller entry sorts first); a handled id is not offered again; an id the peer declined is not offered again. Cross-validate the selection against reference by driving `LXMPeer` selection logic from a committed generator in `Tests/Fixtures/` (or, if driving LXMPeer needs a live router, compute the expected subset with reference's own `get_weight` arithmetic in the generator and say so in its header).
- [ ] Grep ReTiCAMsgr for any persisted `PropagationStore.Entry` before deciding no app change is needed. Commit.

### Task 2: Bound the inbound ratchet-decrypt cost (library)

**Files:** `Sources/ReTiCATransport/Transport.swift` (decrypt site ~:1569-1591, constants near `ratchetCount`), the `Destination.decrypt` it calls, tests, README's ratchet section.

**Design (ruling — divergence from reference, which always scans the whole ring):**
- First try the newest `Transport.ratchetShallowDepth = 16` ratchets, then the identity key unless enforced. These succeed for any sender that heard one of our last 16 announces.
- Only if that fails, scan the rest of the ring, and only while the receiving interface's deep-scan budget allows: a token bucket per interface, capacity `ratchetDeepScanBurst = 8`, refilled at `ratchetDeepScanPerSecond = 1`, read from `\.transportDate`. A packet that finds the bucket empty is dropped after the shallow attempt.
- Cost if wrong: a sender holding a ratchet older than our 16th-newest, arriving during a flood on the same interface, has its packet dropped; LXMF retries it later. Record in Status and at the decrypt site; replace the existing cost comment rather than adding a second one.
- Trying the identity key before the deep scan changes no outcome: a ciphertext authenticates under one key at most.

- [ ] Tests: Review Focus 3 (budget exhausted by junk, newest-ratchet packet still decrypts); a packet to the 100th ratchet decrypts while the budget has tokens and is dropped when it has none; the bucket refills with time; enforcement still refuses the identity key at both depths; budgets are per interface. Commit.

### Task 3: Tickets that arrive while a stamp is pending; ticket sweep minors (library)

**Files:** `Sources/ReTiCANode/LXMFNode.swift` (ticket remember path, LXMF stamp queue from the stamp-priority plan, `ticketCarryingMessages` sweep), tests.

**Ruling (beyond reference, which fixes `outbound_ticket` at `handle_outbound`):** when a ticket for a destination is remembered, every delivery-stamp job for that destination that is queued or running is finished with the ticket stamp instead (the running search is cancelled); propagation-stamp jobs are untouched. A copy already handed to the router is not re-stamped (reference neither). Cost if wrong: none at the receiver (a ticket stamp is valid); only the PoW is saved.

- [ ] The `ticketCarryingMessages` sweep becomes O(entries) per terminal (index by message hash), and the two narrow orderings the tickets review found that miss a `lastTicketDeliveries` update are closed — read the tickets plan's Status and the ledger-free description there; write a failing test for each ordering first.
- [ ] Add the missing direct test: an explicit `sendViaPropagation` acceptance removes its own `ticketCarryingMessages` entry.
- [ ] Doc note on the `.stamping` phase: an explicit propagated send with a ticket still reports `.stamping` (its propagation stamp).
- [ ] Tests: Review Focus 4 for both the queued and the running case; exactly one hand-over. Commit.

### Task 4: Destination-stamp queue parity (library)

**Files:** `Sources/ReTiCATransport/Transport.swift` (destination-stamp queue), tests.

**Ruling:** announces stay keyed by destination plus interface (reference keys by destination only; ReTiCA announces on each interface as it connects, and destination-only keying would cancel those). Everything else follows the Global Constraints queue rules.

- [ ] Tests: Review Focus 5; a full queue drops the new item and no stamp search starts for it; the item being searched does not count toward 32. Commit.

### Task 5: Deferred test and comment minors (library, batch)

One dispatch, one review. Each item is from `docs/superpowers/stamp-followups-2026-11-08.md` "Deferred by the 2026-11-08 plan's reviews" — check each against current code first; drop one that no longer applies and say so in the report.
- [ ] De-flake `pnCopyAbandonWhileTheDeliveryStampIsSearchedDoesNotFailTheMessage` (make the cost-20 search unable to finish — e.g. a stamp generator dependency that never returns — rather than lowering odds).
- [ ] Make the TransportTests sender-ID check non-vacuous (stub returns different bytes per draw).
- [ ] A test that the `Task.isCancelled` guard in the path-request race actually drops a stale search end.
- [ ] LinkPlane driver stop tests: recheck `links.isEmpty` after the 3600 s advance and assert nothing was transmitted; the wiring test asserts the found key is the transmitted key.
- [ ] Verdict cache: a test for the enforcement guard on the valid-hit path.
- [ ] NetworkStamp: a test pinning `value` end to end at a bisect_right boundary; fix the "default announce cost" comment; assert "none of these hashes EQUALS the target".
- [ ] Comments: path request with no interface connected is dropped (reference queues; the router re-requests); split the overlong Transport.swift path-request gate comment and `hasLinkWork`'s doc.
- [ ] Commit (one or a few commits).

### Task 6: Opportunistic size limit is LXMF 1.3.0's (library)

Added after the 2026-11-10 parity survey (`/tmp/ReTiCA/parity-gap-report.md`): `LXMessage+Opportunistic.swift:14` uses 391 (`ENCRYPTED_PACKET_MDU` of the older reference); LXMF 1.3.0 derives its limit from RNS 1.6.0's `Packet.ENCRYPTED_MDU` (LXMessage.py:68, 79, 406-413). A payload between the two sizes builds an oversize packet that Transport refuses, so the message never goes out directly.
- [ ] Take the value from the rns-latest env (print it with a committed generator), fix the constant and every derived limit, and test that a payload one byte over the new limit falls back to a link while one at the limit goes opportunistically. Commit.

---

## Status

Not started.

- Task 2 (inbound ratchet-decrypt budget): done. Deliberate divergence from reference (RNS 1.6.0
  Destination.py:720-752 scans the whole ring): shallow 16 ratchets then the identity key, deep scan
  of the rest only with a per-interface token (burst 8, 1/s). Cost if wrong: a sender holding a
  ratchet older than our 16th-newest, arriving during a flood on the same interface, has its packet
  dropped. LXMF retries it later. Budgets are per registered interface (an unregistered id gets no
  deep scan) and dropped on disconnect, so each new remote connection starts with a full bucket.
  The LXMF propagated-download decrypt still scans the whole ring (host-pulled, out of scope).
