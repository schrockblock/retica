# Stamp search priority Implementation Plan

**Status 2026-11-09: done.** ReTiCA 6bff1d4, 68cf0ca, 378bada, 82155af, 0fb0b8f; ReTiCAMsgr 0271f94. Rulings:
link-request key searches stay uncapped (one per link, reference); our own path requests preempt a running
destination-stamp search when they would run next (DIVERGENCE — the destination search is memoryless, and
waiting behind it broke first sends to new peers). Deferred minors: a queued delivery job is not switched to a
ticket stamp if a ticket arrives while it waits; announces stay keyed by destination plus interface (reference:
destination). Parity follow-up Task 4 (2026-11-10): the item whose destination search runs no longer counts
toward the 32 and is not replaced by a same-key re-announce (reference pops it); a dropped announce starts no
search. Items waiting behind the running one on the same destination still count.

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Schedule stamp work as reference does: one LXMF stamp search at a time, oldest message first (its delivery stamp, then its propagation stamp), and network stamps through one worker with path requests ahead of announces — so queued messages go out in order instead of all finishing late together.

**Architecture:** LXMFNode gets a FIFO stamp queue and a single running search; every place that starts an LXMF stamp search today enqueues instead. Transport gets one network-stamp worker over two bounded queues (path requests/responses first, then announces), keyed so a newer item replaces a queued one, as reference `WorkerQueues`. Link-request key searches stay concurrent per link, as reference.

**Tech Stack:** Swift 6, TCA, Swift Testing; reference RNS 1.6.0 / LXMF 1.3.0 in `/Users/ell/opt/anaconda3/envs/rns-latest`.

**Spec:** `docs/superpowers/research/2026-11-08-lxmf-1.3-parity.md` §3 and the reference source (LXMF/LXMRouter.py `handle_outbound` :2089-2123, `process_deferred_stamps` :2944-3033; RNS/Transport.py `WorkerQueues` :99-130, stamper thread :1444-1493).

## Global Constraints

- Same rules as the SDD workspace's `constraints.md`.
- Ruling: link-request key searches are NOT capped (reference runs one per link with a 15 s watchdog). This overrides the 2026-11-08 follow-ups plan's deferral of a cap to this plan.
- Do not copy reference's failed-callback bug (`LXMRouter.py:2965, 2994, 3024` reports the wrong message).
- Every existing outcome is preserved: cancels (`.cancelOutbound`, `.cancelDeliveryStamps`, `.cancelPropagationStamps`, a changed propagation node), Preparing phases, tickets (bypass), re-stamps after a late announce, one terminal per message.

## Review Focus

1. A queued (not yet started) message that is cancelled leaves the queue without a search ever starting, and gets exactly one terminal.
2. Cancelling the running search starts the next queued one.
3. A ticketed send or a send to a peer with no cost never waits behind the queue.
4. Order: with three sends queued, their hand-overs to the router happen in send order.
5. A path-request stamp waiting behind an announce stamp starts first when both are queued.

---

### Task 1: One LXMF stamp search at a time (library)

**Files:** `Sources/ReTiCANode/LXMFNode.swift` (queue state; `deliverySend`, `restampUnsentHandOvers`, `sendViaPropagation`, `startPropagatedCopy` enqueue; cancel paths), tests, README "Stamp work".

**Interfaces — Produces:** `LXMFNode.PreparingPhase.queued` (reported when a send enters the stamp queue behind another; `.stamping` when its own search starts).
- [ ] FIFO queue of stamp jobs keyed by message hash (delivery, then that message's propagation stamp if it needs one, as one job, as reference); exactly one runs; the next starts when it finishes, fails or is cancelled.
- [ ] Cancels remove queued jobs (reported exactly as today) and cancel the running one (then start the next).
- [ ] Tickets and no-cost sends bypass the queue.
- [ ] Tests for Review Focus 1-4, plus: the Preparing phases sequence `.queued` → `.stamping` → `.handedOver` for a second send. Commit.

### Task 2: One network-stamp worker (library)

**Files:** `Sources/ReTiCATransport/Transport.swift` (destination-stamp queue from the follow-ups Task 7, path-request stamp search), tests.

- [ ] One worker over two bounded queues (32 each): path requests and path responses first, announces second; a queued item with the same key is replaced (announce by destination, path request by destination); a full queue drops the new item (reference). The existing per-destination quota (8) stays.
- [ ] Tests: Review Focus 5; replacement; bound; a stop cancels the worker and empties both queues. Commit.

### Task 3: ReTiCAMsgr shows Preparing for a queued send

**Files (app worktree):** `AppFeature.swift` (`deliveryPreparing` handler), tests.

- [ ] `.queued` inserts into `preparingHashes` like `.waitingForPeer` / `.stamping`. Test. Commit on the branch; app suite.
