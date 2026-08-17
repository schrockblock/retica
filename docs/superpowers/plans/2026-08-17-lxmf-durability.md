# LXMF durability — surviving a cold start Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a process restart from re-delivering every message and from un-learning every peer's stamp cost.

**Architecture:** ReTiCA stays storage-free. The established pattern in this workspace is **library holds state, app persists it and rehydrates by sending an action** — see `AppFeature.rehydratePropagationStore([Data])` (`ReTiCaMsgr/…/AppFeature.swift`), where the app owns `@Dependency(\.defaultDatabase)` and the library owns the state. This slice extends that pattern to three more pieces of state rather than inventing a second mechanism.

**Tech Stack:** Swift 6, swift-testing, The Composable Architecture 1.26, GRDB (app side only).

## Global Constraints

- Platform floor **iOS 17 / macOS 13 / macCatalyst 17** (`Package.swift:6-10`).
- **No new ReTiCA dependencies.** The library has *zero* persistence today — no `UserDefaults`, no `FileManager`, no storage library — and `ReTiCATransport` is interface-agnostic. Keep it that way: serialization may live in the library; **storage must not**.
- **Wire compatibility with Python-RNS 1.4.1/1.4.2 and LXMF 1.1.0 mandatory — no emitted byte may change.** This slice adds no wire format.
- `swift-testing`, not XCTest. `#expect(optional?.field == x)` **aborts** when nil — use `#expect(x != nil)` then `if let`, or `try #require`.
- Durable records **name the enclosing function**, not a bare line.
- Reference: `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/{RNS,LXMF}` is stock 1.4.2 / LXMF 1.1.0; `/Users/ell/development/python/Reticulum/RNS` is a 1.4.1 **fork** whose extra import at `Reticulum.py:37` shifts later lines +1. **Cite the version with the line and verify every reference claim in this plan** — claims in recent slices were wrong repeatedly, including two corrections-of-corrections.
- Mutation-verify **per test, accounting for each individually**. A whole-block mutation failing three tests together cannot show which test pins what.
- Gate (`Scripts/check-wire-narrowing.swift --fail-on-open`) stays at zero known-open.
- Commit trailers at **column 0**:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Background — why this matters more than it looks

**On iOS the process is killed constantly, so a cold start is the NORMAL path, not an edge case.** Everything below therefore happens routinely, not rarely.

1. **Duplicate delivery.** `LXMFRouter.State.seen` (`LXMFRouter.swift:20`, a `RingSet(capacity: 10_000)`) and `downloadedTransientIds` (`:43`) both reset. The next propagation-node sync re-downloads everything the node still holds and re-delivers it as new. Reference avoids this with `local_deliveries` / `locally_processed`.

2. **Stamps stop working.** `LXMFNode.State.learnedPeers` is in-memory only, so after a restart we send **unstamped to every peer** until we re-hear each announce — which is exactly the "a peer running `enforce_stamps()` drops our messages" failure the delivery-stamp slice just closed. Reference persists `outbound_stamp_costs` to disk (`LXMRouter.py:1287-1296`) and expires at `STAMP_COST_EXPIRY = 45*24*60*60` (`:39`, swept at `:1272-1281`).

3. **Staleness is no longer benign, and the checklist still says it is.** `docs/reference-parity-checklist.md:477` reads *"nothing spends the value today"*. That was true when written on 2026-08-15 and became false the next day: `LXMFNode.deliverySend` now spends `learnedPeers[…].stampCost`. A stale cost means we stamp at the wrong price — under-paying gets us dropped by the very peers this is for. **Fix that sentence as part of Task 3.**

**Not in scope:** transport-core persistence (path table, announce cache, packet-hash ring — checklist `:465`). Paths are re-learned from announces, so the cost of losing them is delay rather than incorrectness. Keep it filed; this slice is the LXMF layer.

---

## File Structure

- `Sources/ReTiCANode/LXMFRouter.swift` — rehydration for the two dedup sets.
- `Sources/ReTiCANode/LXMFNode.swift` — rehydration and expiry for `learnedPeers`.
- `ReTiCaMsgr/ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/` — GRDB tables, launch rehydration, save-on-change.

---

### Task 1: `LXMFRouter`'s dedup sets survive a restart

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift`
- Test: `Tests/ReTiCANodeTests/`

**Interfaces:**
- Produces: a rehydration action carrying previously-delivered message hashes and downloaded transient IDs. Task 4 (app) sends it on launch.

- [ ] **Step 1: Read `PropagationNode`'s existing rehydration first** — the app already rehydrates the propagation store via `.rehydratePropagationStore([Data])`. Match that shape (an action taking plain `[Data]`), not a new mechanism. Note the *ordering* comment at the app's call site: entries are replayed oldest-first so eviction at the cap is deterministic across launches. The same concern applies to `seen`.

- [ ] **Step 2: Note the asymmetry between the two sets, and handle it deliberately.**
  - `seen` is a **bounded** `RingSet(capacity: 10_000)` and is **not public**. Rehydration must go through an action, not by exposing the field — and replaying more than the capacity must evict in the same order it would have live. Say in the code what order the caller must supply.
  - `downloadedTransientIds` is a **public, unbounded `Set<Data>`**. Persisting it as-is grows forever. Decide a bound and justify it against reference's own behaviour — check what `locally_processed` / the PN download bookkeeping does about growth before choosing, and if reference is also unbounded, say so and bound ours anyway with the reason.

- [ ] **Step 3: Write the failing tests.** At minimum: a rehydrated hash is treated as already-seen (the message is dropped as a duplicate, not delivered); a rehydrated transient ID is not re-requested in the next sync (it appears in `haves`, not `wants` — see `:400-401`); rehydrating more than `RingSet` capacity keeps the newest and evicts the oldest.

- [ ] **Step 4:** Confirm RED. **Step 5:** Implement. **Step 6:** Confirm green.

- [ ] **Step 7:** Full suite + gate. Mutation-verify per test. Commit.

---

### Task 2: `learnedPeers` survives a restart, and expires

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Test: `Tests/ReTiCANodeTests/`

**Interfaces:**
- Consumes: nothing from Task 1. Produces: a rehydration action for `[Data: LearnedPeer]`, and an expiry sweep.

- [ ] **Step 1: Verify reference's expiry** — `STAMP_COST_EXPIRY = 45*24*60*60` (`LXMRouter.py:39`), swept in `clean_outbound_stamp_costs` (`:1272-1281`), persisted in `save_outbound_stamp_costs` (`:1287-1296`). Confirm all three, and confirm *when* the sweep runs — a sweep that never fires is the same as no sweep.

- [ ] **Step 2:** Add the expiry. `LearnedPeer.learnedAt` already exists **precisely so this needs no schema change** (see its docstring). Use the `\.date` dependency, not `Date()`, so it is testable.

- [ ] **Step 3:** Add rehydration mirroring Task 1's shape.

- [ ] **Step 4: Write the failing tests** — a rehydrated peer's stamp cost is spent by `deliverySend` (the whole point: after restart we stamp correctly); an entry older than the expiry is swept; an entry younger is kept; the sweep uses injected time.

- [ ] **Step 5:** RED, implement, green. **Step 6:** Full suite + gate, mutation-verify per test, commit.

---

### Task 3: App-side persistence and launch rehydration

**Files:**
- Modify: `ReTiCaMsgr/ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/` — `Database.swift`, `AppFeature.swift`, plus a row type per store
- Test: `ReTiCaMsgrCore/Tests/`

- [ ] **Step 1: Follow `PropagationEntryRow` exactly** — table definition, migration, and the `.onLaunch` read that sends the rehydrate action. Do not invent a second persistence style.

- [ ] **Step 2: Decide when writes happen, and say why.** Reference saves `outbound_stamp_costs` on a background thread at each update (`LXMRouter.py:1031-1032`). Writing on every delivered message may be too chatty; batching risks losing the tail on a kill. **On iOS the kill is the normal path**, so bias toward durability and justify the choice.

- [ ] **Step 3:** Prune persisted rows to the same bounds the in-memory structures use, or the DB outgrows the state it mirrors.

- [ ] **Step 4: Write the failing tests** — a message delivered before "restart" is not re-delivered after; a peer's stamp cost survives a restart and is spent. Build the restart as a *new store from the same database*, the way `propagationStoreRehydratesOnLaunch` does.

- [ ] **Step 5:** RED, implement, green. Run **both** the app target and `ReTiCaMsgrCore` (`swift test --package-path …`; `xcodebuild -scheme ReTiCaMsgrCore` is **not** configured for testing). Commit.

---

### Task 4: Tick, and correct the stale claim

- [ ] **Step 1: Fix `docs/reference-parity-checklist.md:477`.** It says *"nothing spends the value today"*; `LXMFNode.deliverySend` has spent it since the delivery-stamps slice. Correct the sentence and say what staleness now costs (stamping at an outdated price; under-paying gets us dropped).

- [ ] **Step 2:** Tick the two Tier 4 items this slice closes, recording fixing commit SHAs **inline** — never "see the task report", since `.superpowers/sdd/` is gitignored.

- [ ] **Step 3: State plainly what is NOT closed**, each checked against a run:
  - **transport-core persistence** remains absent — no path table, announce cache, or packet-hash ring, so after a restart there are no known paths until announces arrive
  - whether anything now bounds the persisted tables, and what happens when they fill
  - **Six documentation overclaims in this repo in three weeks have been the same shape** — a summary sentence wider than the evidence beneath it, several inside *corrections*. Write the tick so its qualifications are load-bearing.

---

## Self-review notes for the implementer

- **Do not add a storage dependency to ReTiCA.** If you believe you need one, stop and say why — the answer is almost certainly the app-side pattern that already exists.
- **Rehydration is hostile-input-adjacent.** The rows come from our own database, but a corrupted or hand-edited store should degrade, not crash. Bound what you read.
- **A rehydrate action that nothing sends is the same as no persistence.** Task 3 is what makes Tasks 1 and 2 real; do not let the library half look finished on its own.
