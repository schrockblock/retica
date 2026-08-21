# Transport path persistence Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove the dead window after every launch where ReTiCA knows no paths and can reach nobody until announces arrive.

**Architecture:** Same pattern as the LXMF durability slice, which is now built and proven: **the library holds state, the app persists it and replays it by sending an action.** ReTiCA gains no storage dependency.

**Tech Stack:** Swift 6, swift-testing, The Composable Architecture 1.26, GRDB (app side only).

## Global Constraints

- Platform floor **iOS 17 / macOS 13 / macCatalyst 17**.
- **No new ReTiCA dependencies.** `ReTiCATransport` is interface-agnostic and has no storage of any kind. Serialization may live in the library; **storage must not**.
- **Wire compatibility with Python-RNS 1.4.1/1.4.2 mandatory — no emitted byte may change.** This slice adds no wire format.
- `swift-testing`, not XCTest. `#expect(optional?.field == x)` **aborts** when nil — use `try #require`, or `#expect(x != nil)` then `if let`.
- Durable records **name the enclosing function**.
- Reference: `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/RNS` is **stock 1.4.2**; `/Users/ell/development/python/Reticulum/RNS` is a 1.4.1 **fork** whose extra import at `Reticulum.py:37` shifts later lines +1. **Cite the version with the line, and verify every reference claim below** — I got one wrong while writing this plan (see Background) and reference claims in this workspace have been wrong repeatedly.
- Mutation-verify **per test, individually**. A whole-block mutation failing three tests cannot show which test pins what; that has been misreported twice in this project.
- Gate (`Scripts/check-wire-narrowing.swift --fail-on-open`) stays at zero known-open.
- Commit trailers at **column 0**:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Background — verified 2026-08-21, including one thing I initially got wrong

`Transport.State` holds four candidate pieces (`Sources/ReTiCATransport/Transport.swift`):

| field | line | size | persist? |
|---|---|---|---|
| `learned: [Data: LearnedDestination]` | `:38` | ~100 B × destinations heard | **yes — this is the slice** |
| `seenPacketHashes: RingSet` | `:41` | `seenPacketRingSize = 262_144` ⇒ **~8.4 MB** | **no — see below** |
| `announceBlobs: [Data: RingSet]` | `:47` | per-destination rings | no |
| `announceCache: [Data: CachedAnnounce]` | `:71` | cached announces | no |

**Reference persists the path table and the packet hashlist**, via `Transport.save_path_table` (stock 1.4.2 `Transport.py:3335`) and `save_packet_hashlist` (`:3292`), both driven from `persist_data` (`:3508`). `save_tunnel_table` (`:3425`) is out of scope — tunnels are a separate Tier 6 item.

**Its triggers, all three:** a 12-hour timer in the jobs loop (`Reticulum.py:386-387`, `PERSIST_INTERVAL = 60*60*12`, `:157`); an opportunistic save gated at 5 minutes when a shared-instance client disconnects (`_should_persist_data`, `:1187-1191`, `GRACIOUS_PERSIST_INTERVAL`, `:158`); and `exit_handler` (`Transport.py:3527`).

> **A correction worth reading before you trust anything above.** I first concluded "reference persists only at exit" — because I grepped `Transport.py` alone, where `persist_data` has exactly one caller. The periodic driver lives in `Reticulum.py`. **A grep returning nothing proves absence only from what you grepped.** Re-derive rather than inherit; that mistake is one command wide.

**None of reference's triggers transfers.** iOS rarely runs exit handlers, 12 hours is effectively never before a kill, and we have no shared-instance disconnect.

### Ruling 2026-08-21 — debounced writes

**Write when dirty, at most every ~30 s, plus a flush on background/terminate.** This deliberately differs from the LXMF slice's write-per-event, and the reason is the write *rate*, not a change of principle: a delivered message is discrete and rare, whereas the path table updates on **every announce that improves a path**. The loss window is bounded at ~30 s of path learning, which the next announce re-learns anyway.

### The packet-hash ring is deliberately NOT persisted

At `262_144` entries it is roughly **8.4 MB** — writing that on a 30 s debounce is untenable. Reference's equivalent is *larger* (`hashlist_maxsize = 1_000_000`, `Transport.py:177`) and it persists only on a 12-hour timer, precisely because each write is expensive.

The cost of losing it is also low **for us specifically**: `LXMFRouter.seen` now persists (previous slice), so a replayed *message* is still deduplicated at the LXMF layer. Losing the transport ring costs re-processing work and briefly reopens announce-loop damping — self-limiting, not data loss.

**This is a deliberate divergence from reference. Record it as one.**

---

## File Structure

- `Sources/ReTiCATransport/Transport.swift` — a rehydration action for `learned`.
- `Tests/ReTiCATransportTests/` — library tests.
- `ReTiCaMsgr/ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/` — row type, migration, debounced write, launch replay.

---

### Task 1: `Transport.learned` is rehydratable

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift`
- Test: `Tests/ReTiCATransportTests/`

**Interfaces:**
- Produces: a rehydration action carrying previously-learned destinations. Task 2 sends it at launch.

- [ ] **Step 1: Read the two existing rehydration actions first** — `LXMFRouter.rehydrateDedup(seenHashes:downloadedTransientIds:)` and `LXMFNode.rehydrateLearnedPeers([Data: LearnedPeer])`. Match their shape; the app should see one pattern, not three. Note that the second one carries a **library struct** and the first carries plain `[Data]`; pick whichever fits `LearnedDestination` and say why.

- [ ] **Step 2: Decide what a restored entry must NOT do**, and mirror the precedent. `.rehydrateLearnedPeers` learned two rules the hard way (`LXMFNode.swift`, in the `.rehydrateLearnedPeers` case): a restored entry never overwrites a **fresher live** one, because rehydration can land after the network has already started; and rows with a malformed or **future-dated** timestamp are dropped rather than restored, because clamping them to `now` makes them look fresh and therefore immortal. **`LearnedDestination` carries its own `learnedAt`** — check whether the same two hazards apply here, and if they do, handle them the same way rather than rediscovering them.

- [ ] **Step 3: Establish what expiry applies, if any.** `Transport.maintenanceTick` already expires `learned` and piggybacks `announceBlobs`/`announceCache` on that sweep (`Transport.swift`, the `.maintenanceTick` case). Find the expiry it uses and confirm whether a restored entry should be swept on the same terms at rehydration time — reference sweeps its path table on load. Cite what you find.

- [ ] **Step 4:** Write the failing tests: a rehydrated destination is reachable without waiting for an announce; a restored entry does not clobber a fresher live one (if Step 2 finds that hazard applies); an expired entry is not restored.

- [ ] **Step 5:** RED, implement, green. **Step 6:** Full suite + gate. Mutation-verify per test. Commit.

---

### Task 2: The app persists and replays the path table

**Files:**
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/` — `Database.swift`, `AppFeature.swift`, a new row type
- Test: `ReTiCaMsgrCore/Tests/`

- [ ] **Step 1: Follow `SeenHashRow` / `LearnedPeerRow` exactly** — table, migration, `.onLaunch` read that sends the rehydrate action. Third instance of this pattern; do not invent a fourth style.

- [ ] **Step 2: Implement the debounce.** Write when dirty, at most every ~30 s, plus a flush on background/terminate. Use the `\.continuousClock` dependency so it is testable — a debounce driven by a real clock is a flaky test waiting to happen. Say in the code that this differs from the per-event policy used for messages, and why (write rate, not principle).

- [ ] **Step 3: Bound the table.** `learned` is swept by `maintenanceTick`, so the table must be pruned on the same terms or the DB outgrows the state it mirrors — the disk-side omission that had to be fixed for `LearnedPeerRow` in the previous slice. Delete expired rows at launch, before the read.

- [ ] **Step 4: Write the failing tests** — a destination learned before "restart" is reachable immediately after, with **no announce in between**; that is the whole point of the slice, so make it the headline test. Build the restart as a **new store over the same database**, as `deliveredMessageIsNotReDeliveredAfterRestart` does. Also: the debounce coalesces rapid updates into one write; a flush persists immediately.

- [ ] **Step 5:** RED, implement, green. Run `swift test --package-path …/ReTiCaMsgrCore` **and** build the app target (`xcodebuild -project ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination 'generic/platform=iOS Simulator' build`; note `xcodebuild -scheme ReTiCaMsgrCore` is **not** configured for testing). Commit.

**Before committing, check `git status` and confirm every staged file is yours.** Parallel agents have collided in this repo three times; one commit there already carries an unrelated feature swept in by accident.

---

### Task 3: Tick, and record the divergence

- [ ] **Step 1:** Tick the Tier 4 transport-core item, recording fixing commit SHAs **inline** across both repos — never "see the task report", since `.superpowers/sdd/` is gitignored.

- [ ] **Step 2: State plainly what is still not persisted, and why**, each checked against a run:
  - the **packet-hash ring** (~8.4 MB at `seenPacketRingSize = 262_144`) — a deliberate divergence from reference, which persists its larger equivalent on a 12-hour timer. Losing it costs re-processing and briefly reopens announce-loop damping; it is not data loss, because `LXMFRouter.seen` persists at the LXMF layer.
  - the **announce cache** and **announce blobs** — transient by design; reference does not persist its equivalents either. Verify that claim before writing it.
  - **tunnels** remain absent entirely (Tier 6).
  - the **debounce loss window** — up to ~30 s of path learning, re-learned from the next announce.
- [ ] **Step 3:** Update the summary table's **Durability** row, which currently says the transport core persists nothing. It will then be half-true, which is its own kind of wrong — say which half.

  *Seven documentation overclaims in this repo in three weeks have been the same shape: a summary sentence wider than the evidence beneath it, several of them inside corrections. Write the tick so its qualifications are load-bearing.*

---

## Self-review notes for the implementer

- **Do not persist the packet-hash ring** because reference does. Reference writes it every 12 hours; we would be writing it every 30 seconds, and ours is 8.4 MB.
- **Do not add a storage dependency to ReTiCA.** If you think you need one, stop and say why — the app-side pattern already exists in three places.
- **A rehydrate action nothing sends is the same as no persistence.** Task 2 is what makes Task 1 real.
