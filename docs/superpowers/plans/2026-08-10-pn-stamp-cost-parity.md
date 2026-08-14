# Propagation-Node Stamp-Cost Parity Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make every propagation node advertise exactly the stamp cost it enforces, and remove the duplicated state that let the two drift apart.

**Architecture:** `PropagationStore.minStampCost` is the single source of truth — it is what `ingest` actually enforces. Task 1 makes `PNNode` announce that value instead of a hardcoded `0`. Task 2 removes `LXMFServiceNode`'s mirrored copy so the same drift cannot recur there. Both are small, confined to `Sources/ReTiCANode/`.

**Tech Stack:** Swift 6, The Composable Architecture (`@Reducer`, `TestStore`), `swift-testing`.

## Global Constraints

- Platform floor: iOS 16 / macOS 13 (package-wide; do not raise).
- Wire compatibility with reference LXMF 1.1.0 is mandatory.
- Tests use `swift-testing` (`import Testing`, `@Test @MainActor func …`, `#expect`), not XCTest.
- House style: `store.exhaustivity = .off` for node-level TestStores.
- After any change under `Sources/ReTiCA/Support/MsgPack.swift` run `swift package clean` — incremental builds can stale-link `ReTiCATransport` and produce spurious `LinkSessionRequestTests` failures. This plan does not touch MsgPack, but `PNAnnounce.packed` sits on top of it; if you see unrelated failures, clean first.
- Verify tests per the three-step process: (a) run and confirm pass, (b) mutate the production code so they should fail and confirm they do, (c) revert and confirm pass again.
- Commit after each task. Trailers must start at column 0:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

### Task 1: `PNNode` advertises the stamp cost it enforces

**Why:** `PNNode.registerPropagation` announces `targetStampCost: 0` (`PNNode.swift:79`), but the store it constructed enforces `LXMFPropagation.defaultPropagationStampCost` = 16 (`PNNode.swift:24, 28`) and `PropagationStore.ingest` silently skips every entry that fails `validatePnStamp(targetCost: 16)` (`PropagationStore.swift:70-77`).

Reference clients read that advertised value and test `if not target_propagation_cost:` (`LXMRouter.py:428`) — **0 is falsy**, so the client path-requests, still reads 0, logs `"Propagation node stamp cost still unavailable"`, and returns `None`; the send then fails. So a reference client fails *every* propagated send to a `PNNode`, and any unstamped entry that did arrive would be silently blackholed with no error returned.

`LXMFServiceNode` already does this correctly, with the comment `// advertised == enforced` (`LXMFServiceNode.swift:124`) — `PNNode` is the outlier.

**Files:**
- Modify: `Sources/ReTiCANode/PNNode.swift:74-82`
- Test: `Tests/ReTiCANodeTests/` — add to the existing PNNode test file if there is one, otherwise create `PNNodeAnnounceTests.swift`

**Interfaces:**
- Consumes: `PropagationNode.State.store` (`public var`, `PropagationNode.swift:16`) and `PropagationStore.minStampCost` (`public var`, `PropagationStore.swift:41`).
- Produces: no new symbols.

- [ ] **Step 1: Write the failing test**

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA

// A propagation node MUST advertise the stamp cost it enforces. Reference clients treat an
// advertised 0 as "unavailable" (LXMRouter.py:428 — `if not target_propagation_cost`) and fail
// the send outright, so advertising 0 while enforcing 16 breaks every reference client.
@Test @MainActor func pnNodeAdvertisesTheStampCostItEnforces() async {
    let identity = Identity()
    let enforced = 18                                     // deliberately not the default
    let store = TestStore(
        initialState: PNNode.State(identity: identity,
                                   endpoint: TCPEndpoint.State(host: "h", port: 1),
                                   minStampCost: enforced)
    ) { PNNode() }
    store.exhaustivity = .off

    #expect(store.state.node.store.minStampCost == enforced)

    let captured = LockIsolated<Data?>(nil)
    await store.send(.registerPropagation)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action { captured.setValue(appData); return true }
        return false
    }

    let announced = PNAnnounce.parse(captured.value!)
    #expect(announced?.targetStampCost == enforced)
}
```

Adapt `TCPEndpoint.State(host:port:)` and the `.endpoint(.announce(destinationHash:appData:))` action shape to whatever `PNNode`/`TCPEndpoint` actually declare — read `Sources/ReTiCANode/PNNode.swift:74-82` and `Sources/ReTiCANode/TCPEndpoint.swift` first and match exactly. The load-bearing assertion is the last one.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter pnNodeAdvertisesTheStampCostItEnforces`
Expected: FAIL — `announced?.targetStampCost` is `0`, not `18`.

- [ ] **Step 3: Advertise the enforced value**

In `Sources/ReTiCANode/PNNode.swift`, replace lines 78-80:

```swift
                let appData = PNAnnounce(timebase: Int(date.now.timeIntervalSince1970), nodeState: true,
                                         perTransferLimit: 0, perSyncLimit: 0, targetStampCost: 0,
                                         stampCostFlexibility: 0, peeringCost: state.peeringCost).packed
```

with:

```swift
                // Advertise exactly what `PropagationStore.ingest` enforces. A reference client
                // reads this field and treats 0 as "cost unavailable" (LXMRouter.py:428 —
                // `if not target_propagation_cost`), path-requests once, then FAILS the send. So
                // advertising 0 while the store enforces 16 breaks every reference client, and any
                // unstamped entry that did arrive would be silently skipped with no error returned.
                // Read from the store rather than a mirrored copy: one source of truth, no drift.
                let appData = PNAnnounce(timebase: Int(date.now.timeIntervalSince1970), nodeState: true,
                                         perTransferLimit: 0, perSyncLimit: 0,
                                         targetStampCost: state.node.store.minStampCost,
                                         stampCostFlexibility: 0, peeringCost: state.peeringCost).packed
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter PNNode`
Expected: all pass. If an existing test asserts `targetStampCost == 0`, read it before changing it — it was encoding the bug. Update it to assert parity with `minStampCost`, and if it constructs a `PNNode.State` with the default cost, note that the expected value is now 16.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCANode/PNNode.swift Tests/ReTiCANodeTests/
git commit -m "fix: PNNode advertises the propagation stamp cost it actually enforces"
```

---

### Task 2: Remove `LXMFServiceNode`'s mirrored stamp cost

**Why:** `LXMFServiceNode` currently keeps `minStampCost` twice — once as `State.minStampCost` (`LXMFServiceNode.swift:27, 44`) and once inside `State.pn.store.minStampCost` (`:43`). It reads the mirror when announcing (`:124`) and when validating (`:152-154`), while `PropagationStore.ingest` reads the store's copy. The two are set from the same initialiser parameter today, so they agree — but nothing enforces that, and this is precisely the duplication that produced the Task 1 defect in the sibling type.

**Files:**
- Modify: `Sources/ReTiCANode/LXMFServiceNode.swift` — remove `State.minStampCost`, redirect its three readers to `state.pn.store.minStampCost`
- Test: `Tests/ReTiCANodeTests/` — the existing `LXMFServiceNode` tests

**Interfaces:**
- Consumes: `PropagationNode.State.store` and `PropagationStore.minStampCost`.
- Produces: removes `LXMFServiceNode.State.minStampCost`. This is a **public API removal** — check for external readers first (see Step 1).

- [ ] **Step 1: Confirm nothing outside the type reads the mirror**

Run:

```bash
grep -rn "\.minStampCost" /Users/ell/development/ios/pods/ReTiCA/Sources /Users/ell/development/ios/pods/ReTiCA/Tests
```

Every hit must be either inside `LXMFServiceNode.swift`, inside `PNNode.swift`, or a `PropagationStore`/`PropagationNode` declaration. If a test or another composition reads `serviceNodeState.minStampCost`, redirect it to `serviceNodeState.pn.store.minStampCost` as part of this task rather than leaving the property in place.

Also check the consuming app, which is outside this repo:

```bash
grep -rn "minStampCost" /Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore/Sources
```

If the app reads it, **stop and report** rather than breaking the app — the memory note records that a unified-surface change once broke `ReTiCaMsgr` while this suite stayed green.

- [ ] **Step 2: Write the failing test**

```swift
// The announced cost must track the store's enforced cost even if only the store is changed.
// This is a regression guard against re-introducing a mirrored copy that can drift.
@Test @MainActor func serviceNodeAnnouncesStoreEnforcedCostAfterMutation() async {
    let identity = Identity()
    var initial = LXMFServiceNode.State(identity: identity,
                                        endpoint: TCPEndpoint.State(host: "h", port: 1),
                                        minStampCost: 16)
    initial.pn.store.minStampCost = 21                    // mutate ONLY the store

    let store = TestStore(initialState: initial) { LXMFServiceNode() }
    store.exhaustivity = .off

    let captured = LockIsolated<Data?>(nil)
    await store.send(.registerPropagation)
    await store.receive { action in
        if case let .endpoint(.announce(_, appData)) = action { captured.setValue(appData); return true }
        return false
    }

    #expect(PNAnnounce.parse(captured.value!)?.targetStampCost == 21)
}
```

Match the `LXMFServiceNode.State` initialiser and the announce action shape to the real declarations at `LXMFServiceNode.swift:41-60` and `:118-128`.

- [ ] **Step 3: Run the test to verify it fails**

Run: `swift test --filter serviceNodeAnnouncesStoreEnforcedCostAfterMutation`
Expected: FAIL — the announce still carries `16` from the mirrored `State.minStampCost`.

- [ ] **Step 4: Remove the mirror**

In `Sources/ReTiCANode/LXMFServiceNode.swift`:

1. Delete `public var minStampCost: Int` (line 27).
2. Delete `self.minStampCost = minStampCost` (line 44). Leave the `minStampCost:` initialiser *parameters* (lines 41, 50, 58) — they still flow into `PropagationNode.State`, which is the point.
3. Line 124: change `targetStampCost: state.minStampCost,   // advertised == enforced` to:

```swift
                                         // Single source of truth: the value PropagationStore.ingest
                                         // actually enforces. A mirrored copy is what let PNNode
                                         // advertise 0 while enforcing 16.
                                         targetStampCost: state.pn.store.minStampCost,
```

4. Line 152: change `if state.minStampCost > 0 {` to `if state.pn.store.minStampCost > 0 {`.
5. Line 154: change `targetCost: state.minStampCost` to `targetCost: state.pn.store.minStampCost`.

- [ ] **Step 5: Run the tests**

Run: `swift test`
Expected: the whole suite passes. A full run (not `--filter`) is warranted here because this removes a public property.

- [ ] **Step 6: Verify the test set per the three-step process**

(a) `swift test --filter "PNNode|ServiceNode"` — all pass.
(b) Mutate: in `PNNode.swift` set `targetStampCost: 0` again; in `LXMFServiceNode.swift` hardcode `targetStampCost: 16`. Run once — both new tests must fail.
(c) Revert both, run again — all pass.

- [ ] **Step 7: Commit**

```bash
git add Sources/ReTiCANode/LXMFServiceNode.swift Tests/ReTiCANodeTests/
git commit -m "refactor: read the PN stamp cost from the store, not a mirrored copy"
```

---

## Self-review notes

- **Coverage:** §1.5 → Task 1. Task 2 is not in the gap analysis; it removes the duplication pattern that *caused* §1.5, so the same defect cannot reappear in the sibling type.
- **Ordering:** Task 1 is independent and should land first — it is the actual interop fix. Task 2 is hardening and can be dropped if Step 1 finds external readers of `LXMFServiceNode.State.minStampCost`.
- **Type consistency:** both tasks read `state.<node>.store.minStampCost`, where the property chain is `PropagationNode.State.store: PropagationStore` (`PropagationNode.swift:16`) → `PropagationStore.minStampCost: Int` (`PropagationStore.swift:41`). Both are `public var`, verified.
- **Out of scope, deliberately:** `stampCostFlexibility` stays hardcoded to `0` in both nodes. Reference supports `propagation_stamp_cost_flexibility` and accepts `max(0, cost - flex)` (`LXMRouter.py:2242, 2401`), and also enforces a `PROPAGATION_COST_MIN = 13` floor (`:52, 137`). Neither is implemented; both belong with the wider stamp-enforcement work in §6 of the gap analysis, not here.
- ~~**Not fixed here:** `perTransferLimit: 0, perSyncLimit: 0` are also advertised by both nodes. Unlike stamp cost, 0 correctly means "no limit" to a reference peer (`LXMF.py:234-236`) and matches reality, since ReTiCA has no inbound transfer cap.~~

  **CORRECTED 2026-08-11 — the above was wrong.** `LXMF.py:233-234` is only an `int()`-parseability check inside `pn_announce_data_is_valid`; it says nothing about the semantics of 0. The real consumer is `LXMPeer.py:370-373`:

  ```python
  if self.propagation_transfer_limit != None and lxm_transfer_size > (self.propagation_transfer_limit*1000):
      self.remove_unhandled_message(transient_id)
      self.add_handled_message(transient_id)
      continue
  ```

  With limit 0, `0 != None` holds and `lxm_transfer_size > 0` always holds, so **every** message is dropped *and permanently marked handled* — never retried. `None` is the true no-limit sentinel (`LXMPeer.py:192, 194`) and can never arrive from the wire, because `pn_announce_data_is_valid` requires `int(data[3])` to succeed. Reference defaults advertise 256 / 10240 (`LXMRouter.py:55, 59`).

  Effect: reference→ReTiCA **mesh sync** silently delivers nothing, forever, and is default-reachable (`AUTOPEER = True`, `AUTOPEER_MAXDEPTH = 4`, `LXMRouter.py:44-45`). Client `/get` downloads are unaffected — the client sends its own limit in the request body, which `LXMFServiceNode.swift:204-226` honours.

  ~~Note the fix is *not* simply "advertise 256": that is the same lie in the opposite direction until inbound transfer caps exist. Either advertise a large-but-real cap, or land the cap first.~~

  **CORRECTED 2026-08-14 — the struck sentence is wrong; fixed in `f2eb255`.** Advertising a real number *is* the complete fix. These fields are a request the **sender** honours, not something the receiver enforces: the peer stores our advertised value on its `LXMPeer` record for us (`Handlers.py:61` → `LXMRouter.py:2025/2041`) and filters its *own outbound offer* against it (`LXMPeer.py:370`, where `self` is the node being synced *to*). Reference advertises 256 and enforces nothing on receive. I recorded the opposite here without tracing the arrow, and it would have kept blocking the fix — the plan that closed it explicitly asked its implementer to falsify me.
