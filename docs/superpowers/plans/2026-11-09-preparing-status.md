# "Preparing…" status Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** While a send is waiting for the peer's stamp cost or computing its stamp, ReTiCAMsgr shows "Preparing…" instead of "Sending…".

**Architecture:** ReTiCA's `LXMFNode` reports each phase a delivery goes through before the router has it, as one new delegate case. ReTiCAMsgr keeps the stored status `sending` (so retry, group status and relaunch logic are untouched) and holds the phase in memory only; the status label reads it.

**Tech Stack:** Swift 6, TCA, Swift Testing. ReTiCA at `/Users/ell/development/ios/pods/ReTiCA` (commit to `main`); ReTiCAMsgr at `/Users/ell/development/ios/apps/ReTiCAMsgr` (work in a sibling worktree on a branch, other sessions use its `main`).

**Spec:** this plan; the first-send wait and stamping it reports on are documented in `LXMFNode.deliverySend` and the README "Stamp work" section.

## Global Constraints

- Same rules as `.superpowers/sdd/2026-11-08-stamp-followups/constraints.md` (shell, trailers, three-step test verification, full suite).
- The new delegate case must not change any existing outcome or ordering: every existing test passes unchanged except where a test asserts the exact action list (update those, nothing else).
- The app never persists the phase. A relaunch shows "Sending…" for an unfinished send, as today.

## Review Focus

1. A send that is handed over without waiting or stamping (path known, no cost) must not flash "Preparing…".
2. A cancelled or failed send must not leave "Preparing…" behind: the phase is cleared on every terminal outcome.
3. A send re-stamped after a late announce (the router hands its copy back) must go back to "Preparing…" while it re-stamps, then leave it.
4. Group posts: each member copy has its own hash; the post shows "Preparing…" only while every unfinished copy is preparing.
5. An explicit propagated send (`sendViaPropagation`) stamps for minutes at a node's cost; it reports the stamping phase too.

---

### Task 1: ReTiCA — report a delivery's preparation phases

**Files:** `Sources/ReTiCANode/LXMFNode.swift` (Delegate, `deliverySend`, `waitForPeerCost`, `handOverWaitingSends`, `restampUnsentHandOvers`, `.router(.send)` branch, `sendViaPropagation`); tests in a new `Tests/ReTiCANodeTests/LXMFNodePreparingPhaseTests.swift`; README "Stamp work".

**Interfaces — Produces:**
```swift
// in LXMFNode.Action.Delegate
case deliveryPreparing(messageHash: Data, phase: PreparingPhase)
public enum PreparingPhase: Equatable, Sendable { case waitingForPeer, stamping, handedOver }
```
(`PreparingPhase` nested in `LXMFNode`.)

- [ ] `.waitingForPeer` when a send enters the first-send wait; `.stamping` when a delivery-stamp search starts (first time or a re-stamp) and when `sendViaPropagation` starts its stamp work; `.handedOver` when a message that had reported `.waitingForPeer` or `.stamping` reaches the router (`.router(.send)` / `.router(.sendViaPropagation)`). A send that goes straight to the router reports nothing.
- [ ] Each phase is reported once per transition (no duplicates when, e.g., several sends wait on one peer).
- [ ] Tests for each of Review Focus 1, 3, 5 at the library level, plus: wait → stamping → handedOver for a first send to a peer with a cost; a cancelled waiting send reports no `.handedOver`.
- [ ] README: document the case for hosts. Commit.

### Task 2: ReTiCAMsgr — show "Preparing…"

**Files:** `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift` (state + the delegate branch), `MessageStatusLabel.swift`, the views that render a row's status (grep `MessageStatusLabel.text`), `GroupRoster.swift` (derived group status); tests in `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/`.

**Interfaces — Consumes:** Task 1's `deliveryPreparing(messageHash:phase:)`.

- [ ] State: `preparingHashes: Set<String>` (hex message hashes), in memory only. Insert on `.waitingForPeer` / `.stamping`; remove on `.handedOver` and on every terminal outcome for that hash.
- [ ] Label: a row whose status is `sending` and whose hash (or, for a group post, every unfinished member copy's hash) is in `preparingHashes` reads "Preparing…". Everything else is unchanged.
- [ ] Tests for Review Focus 1, 2, 4 at the app level, and that a relaunch (fresh state) shows "Sending…".
- [ ] Commit on the branch; full `ReTiCAMsgrCore` suite.
