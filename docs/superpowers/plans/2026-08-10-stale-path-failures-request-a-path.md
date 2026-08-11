# Stale-Path Link Failures Request a Path Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When a link cannot be opened because our *path* is stale — not because the peer refused — the router requests a fresh path instead of burning its whole establishment budget against a route already known to be dead. This is what makes a BLE peer that reconnects (and therefore has a new `InterfaceID`) recover on the next message rather than after ~75s and a failed delivery.

**Architecture:** Give `linkFailed` a reason. Endpoints classify the failure they already detect; `LXMFNode` clears `knownPaths` for the path-shaped reasons before forwarding to the router, so `establish` takes its `requestPath` branch. No new retry mechanism — it reuses the `.awaitingPath` park bounded by the previous slice.

**Tech Stack:** Swift 6 / TCA / swift-testing. Repo: `/Users/ell/development/ios/pods/ReTiCA`.

## Background: three verified facts

**1. `BLEEndpoint.openLink` binds links to dead interfaces.** `BLEEndpoint.swift:187-196` reads raw `state.transport.learned[destinationHash]` and mints a `LinkSession` on `learned.interfaceID`. A BLE peer that reconnects gets a **new `InterfaceID` by construction** (it is derived from the HELLO session token), and `BLEEndpoint` does register/unregister interfaces with Transport (`:127`, `:137`) — so after a reconnect the learned entry names an interface that is gone.

`Transport.State.reachableLearned` (`Transport.swift:130-134`) exists precisely to catch this — `guard let entry = learned[...], interfaces[entry.interfaceID] != nil` — and its own doc comment describes this case. **It has exactly one production caller**, `Transport.swift:768`, inside `.send`. Verified by repo-wide grep. `openLink` does not use it.

Consequence today: every transmit for that link hits `BLEEndpoint.swift:223-235` and yields `.sendFailed(destinationHash:, .interfaceUnavailable)`, **which nothing consumes** — `sendFailed` is emitted at 6 sites and has no handler in `LXMFNode` (verified by grep). So the 15s establishment deadline is the only exit, ×5 attempts = ~75s burned against a peer that is physically connected.

**2. The same shape exists on TCP, hot rather than slow.** `TCPEndpoint.swift:149-151` returns `linkFailed` *immediately* when `transport.learned[dest]` is missing. The router's `knownPaths` can outlive Transport's `learned` table, so this is the zero-delay spin already documented at `LXMFRouter.swift:53-55`. Bounded since the previous slices, but still 5 useless attempts before recovery.

**3. Both are the same bug: the router retries a LINK when the problem is the PATH.** `establish` (`LXMFRouter.swift:176-200`) branches on `knownPaths.contains(dest)`. When our path is stale, `knownPaths` still says we have one, so it takes the `requestLink` branch every time. The `requestPath` branch — the one that actually recovers — is unreachable until `giveUp` clears `knownPaths`, which costs a failed message first.

## Why this is safe NOW and was not before

An earlier attempt at "fail fast on a stale path" (`f0c4670`) was **reverted** (`e01f0ce`) because it turned a paced retry into an unbounded zero-delay spin: nothing bounded the establishment cycle, and the message sat in `outboundQueue` where `maxAttempts` never reached it.

Both halves are now bounded:
- the `requestLink` cycle, by `establishAttempts` (`LXMFRouter.swift:176-200`)
- the `.awaitingPath` park this plan routes INTO, by `pathRequestTimer` + the same shared budget (`LXMFRouter.swift:485-495`)

So a path request is a bounded terminus, not a hole. **Do not weaken either bound in this slice.** If a change here would only be safe because "the timeout will catch it", stop and report.

## Global Constraints

- Commit directly to `main`. No branches, merges, rebases, resets.
- **You are the implementer, NOT the controller. Do NOT invoke the `superpowers:subagent-driven-development` skill or run any of its scripts.**
- The user commits CONCURRENTLY. `git add` ONLY the files each task names — never `-A`, never `.`.
- **One command per Bash invocation** — no `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreter scripts. Redirect output to a file under `/tmp/ReTiCA/` and read it.
- Commit trailers MUST start at column 0:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```
- Baseline: **751/751 serially**, 1 known issue (`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`). Use `swift test --no-parallel`; parallel runs flake `PNNode*`, `LXMFNodeSync*`, `twoEndpointsTransferMultiSegmentResourceOverALink`, `pairedModePublishesWithEncryptionAndEncryptedReadPerms`. Classify with `--filter` before reporting a failure.
- **If a PRE-EXISTING test fails, STOP and report — do not fix it.**
- Mutation discipline every task, run SEPARATELY when mutations would mask each other.

## Verification discipline for this slice

Citations in this plan were verified by repo-wide grep, not by reading one file. Hold yourself to the same standard: **a claim of the form "only X does Y" or "nothing consumes Z" needs a `grep -rn` over `Sources/`, not a look at the file you already have open.** Several defects this month came from property claims that were checked in one place and were false in another.

## TestStore traps (both corrected — read carefully)

1. **A trailing `.on` flip is NOT a no-op.** Teardown (`deinit` → `completed()` → `assertNoReceivedActions`) routes through `reportIssueHelper` (`TestStore.swift:2191`), which reads exhaustivity **at call time** — so a trailing flip DOES catch stray received actions. It also asserts no in-flight effects, so it fails if a timer is armed. **Prefer flip-then-send** (`.on`, then one more `send`, then `.off`) because it tolerates armed timers — not because the trailing form does nothing.
2. **Do NOT count actions with a `LockIsolated` mutated inside a `store.receive` predicate** — the predicate is invoked in four places including an unbounded polling loop (`TestStore.swift:1855-1863`), so counts inflate. Assert via ordered `receive` and/or `store.state`.
3. **Do not seed the state you claim to prove.**

---

### Task 1: Give `linkFailed` a reason, and gate BLE's `openLink` on reachability

**Files:**
- Modify: `Sources/ReTiCANode/LinkPlane.swift` (`:58`, `:192`)
- Modify: `Sources/ReTiCANode/TCPEndpoint.swift` (`:85`, `:151`, `:175-176`)
- Modify: `Sources/ReTiCANode/BLEEndpoint.swift` (`:90`, `:187-196`, `:245-246`)
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift` (`:79`, `:182`, `:205`)
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (`:267` — bind and IGNORE the reason this task)
- Modify: `Sources/ReTiCANode/PNNode.swift` (`:194` — bind and IGNORE the reason)
- Test: `Tests/ReTiCANodeTests/BLEEndpointLinkTests.swift` (check the actual file for BLE endpoint tests)

**Interfaces:**
- Produces: `LinkFailure` enum and `linkFailed(destinationHash:reason:)` on `LinkPlane`, `TCPEndpoint`, `BLEEndpoint`, `TransportEndpoint`. Task 2 consumes the reason in `LXMFNode`.

- [ ] **Step 1: Write the failing test**

```swift
/// A BLE peer that reconnects gets a NEW InterfaceID by construction, so a learned entry from
/// before the reconnect names an interface that is gone. Opening a link on it mints a session
/// bound to a dead interface: every transmit yields .sendFailed (which nothing consumes), so the
/// 15s establishment deadline is the only exit — ~75s across the budget, against a peer that is
/// physically connected. Gate on reachableLearned instead, and say WHY it failed.
@Test @MainActor func bleOpenLinkOnStaleInterfaceFailsImmediatelyAsPathStale() async {
    // Drive: interface connects, announce learned on it, interface DISCONNECTS
    // (so transport.interfaces loses the ID while transport.learned keeps the entry),
    // then .openLink(dest).
    // Assert: .delegate(.linkFailed(destinationHash: dest, reason: .pathStale)) immediately,
    //         and NO .linkPlane(.openLink) — nothing was minted.
    // Drive the disconnect through the real action; do not seed transport.interfaces.
}
```

Read the existing BLE endpoint tests first for the harness/driver-stub pattern.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter bleOpenLinkOnStaleInterfaceFailsImmediatelyAsPathStale`
Expected: FAIL to compile (`reason:` does not exist).

- [ ] **Step 3: Implement**

Add the reason type next to the `LinkPlane.Delegate` declaration:

```swift
/// Why a link could not be opened. Distinguishes failures that mean "our PATH is wrong"
/// (recoverable by requesting a fresh one) from "the PEER did not complete" (recoverable only
/// by retrying the link). `LXMFNode` routes on this — see its `linkFailed` handler.
public enum LinkFailure: Equatable, Sendable {
    /// No learned path at all for the destination.
    case noPath
    /// A learned path exists but names an interface that is gone (BLE peer reconnected with a
    /// new InterfaceID, interface removed). `Transport.reachableLearned` is the detector.
    case pathStale
    /// A link was minted and the handshake did not complete (timeout, bad proof).
    case establishmentFailed
}
```

Thread `reason:` through every `linkFailed` case and forwarder at the sites listed under **Files**. Assign reasons at the points that already detect the condition:
- `TCPEndpoint.swift:151` (no `learned` entry) → `.noPath`
- `BLEEndpoint` `openLink`: replace the raw `learned` lookup with the two-step gate below
- `LinkPlane.swift:192` (from `LinkSession.establishmentFailed`) → `.establishmentFailed`

`BLEEndpoint.openLink` becomes:

```swift
case let .openLink(destinationHash):
    guard let learned = state.transport.learned[destinationHash] else {
        return .send(.delegate(.linkFailed(destinationHash: destinationHash, reason: .noPath)))
    }
    // A BLE peer that reconnects gets a NEW InterfaceID (derived from the HELLO session token),
    // so a learned entry from before the reconnect names an interface that no longer exists.
    // Minting a session on it produces a link whose every transmit fails with .sendFailed —
    // which nothing consumes — leaving the 15s establishment deadline as the only exit.
    // Transport.send already gates on this (Transport.swift:768); openLink must too.
    guard state.transport.reachableLearned(destinationHash) != nil else {
        return .send(.delegate(.linkFailed(destinationHash: destinationHash, reason: .pathStale)))
    }
    let relayNextHop: Data? = learned.nextHop == destinationHash ? nil : learned.nextHop
    return .send(.linkPlane(.openLink(initiatorTo: learned.identity,
                                      destinationHash: destinationHash,
                                      interfaceID: learned.interfaceID,
                                      relayNextHop: relayNextHop)))
```

In `LXMFNode.swift:267` and `PNNode.swift:194`, bind the reason and **ignore it** (`case let .endpoint(.delegate(.linkFailed(dest, _)))`). Behaviour must not change in this task — Task 2 owns the routing.

**Consider whether `TCPEndpoint.openLink` should also gate on `reachableLearned`.** Read `Transport`'s interface lifecycle for TCP before deciding, and say what you concluded in your report. Do NOT change TCP behaviour on a guess — if it is not clearly right, leave it and report.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter BLEEndpoint`
Expected: the new test passes; existing BLE link tests still pass.

- [ ] **Step 5: Full suite**

Run: `swift test --no-parallel > /tmp/ReTiCA/stale-task1.txt 2>&1` then read it.
Expected: 752/752, 1 known issue. Behaviour is unchanged everywhere except BLE `openLink` on a stale binding.

- [ ] **Step 6: Mutation verification (run SEPARATELY)**

1. Remove the `reachableLearned` gate from `BLEEndpoint.openLink` → the new test fails (a link is minted, no immediate `linkFailed`).
2. Change `TCPEndpoint.swift:151`'s reason from `.noPath` to `.establishmentFailed` → whatever test pins that reason must fail. If no test pins it, ADD one — an unpinned reason is a silent contract.

Report each verbatim. Revert; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/stale-task1-msg.txt` (subject `feat: linkFailed carries a reason; BLE openLink gates on reachability`), `git add` the files you touched, `git commit -F`.

---

### Task 2: A path-shaped failure requests a path

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (the `linkFailed` handler at `:267`)
- Test: `Tests/ReTiCANodeTests/LXMFNodeDirectTests.swift`

**Interfaces:**
- Consumes: `LinkFailure` from Task 1.
- Produces: nothing new; changes which `LXMFRouter` branch a stale-path failure reaches.

- [ ] **Step 1: Write the failing test**

```swift
/// A path-shaped link failure must make the router request a PATH, not retry the LINK. Before
/// this, `knownPaths` still claimed a path existed, so `establish` took the requestLink branch
/// every time and burned the whole budget against a route already known to be dead — costing a
/// failed message before `giveUp` cleared `knownPaths` and recovery could begin.
@Test @MainActor func staleePathLinkFailureRequestsAPathInsteadOfRetryingTheLink() async {
    // Drive a real LXMFNode store to the point where the router has knownPaths for a dest and a
    // queued direct message, then deliver .linkFailed(dest, reason: .pathStale).
    // Assert: .requestPath is emitted, NOT .requestLink.
    // ABSENCE HALF: use flip-then-send (a park timer will be armed, so a trailing .on would fail
    // on the in-flight effect rather than on a stray).
}

/// An establishment failure is NOT path-shaped: the peer was reachable enough to mint a link and
/// simply did not complete. That must still retry the link, on the bounded budget.
@Test @MainActor func establishmentFailureStillRetriesTheLink() async {
    // Same setup, deliver .linkFailed(dest, reason: .establishmentFailed).
    // Assert: .requestLink, NOT .requestPath. This is the regression guard for over-routing.
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter LXMFNodeDirect`
Expected: the first FAILS (`requestLink` is emitted today); the second PASSES already (it pins current behaviour and must keep passing).

- [ ] **Step 3: Implement**

```swift
case let .endpoint(.delegate(.linkFailed(dest, reason))):
    state.directLinks[dest] = nil
    switch reason {
    case .noPath, .pathStale:
        // Our PATH is wrong, not the peer. Clear the router's belief that a path exists so
        // `establish` takes its requestPath branch instead of retrying links against a route
        // already known to be dead. The park it lands in is bounded (pathRequestTimer + the
        // shared establishAttempts budget), so this is a bounded terminus, not a hole — which
        // is why an earlier attempt at this (f0c4670, reverted e01f0ce) was unsafe and this
        // is not.
        return .merge(.send(.router(.pathLost(destinationHash: dest))),
                      .send(.router(.linkClosed(destinationHash: dest))))
    case .establishmentFailed:
        // The peer was reachable enough to mint a link and did not complete. Retrying the link
        // is correct; the budget bounds it.
        return .send(.router(.linkClosed(destinationHash: dest)))
    }
```

This needs a new `LXMFRouter` action `pathLost(destinationHash:)` that removes from `knownPaths`. Add it beside `learnedPath`, and give it a doc comment stating it is the inverse and that ordering matters — `pathLost` must be reduced **before** `linkClosed`, or `establish` will read a stale `knownPaths` and take the wrong branch. If `.merge` does not guarantee that ordering, use a single action or sequence it explicitly; **verify the ordering you rely on rather than assuming it**, and say in your report how you verified.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter LXMFNode`
Expected: both pass; all existing `LXMFNode` tests still pass.

- [ ] **Step 5: Full suite**

Run: `swift test --no-parallel > /tmp/ReTiCA/stale-task2.txt 2>&1` then read it.
Expected: 754/754, 1 known issue.

- [ ] **Step 6: Mutation verification (run SEPARATELY)**

1. Route `.establishmentFailed` through the path-clearing branch too → `establishmentFailureStillRetriesTheLink` must fail. This is the over-routing guard.
2. Drop the `pathLost` send, keeping only `linkClosed` → the first test must fail with `requestLink`.
3. Reverse the order so `linkClosed` reduces before `pathLost` → the first test must fail. If it does NOT, your ordering is not actually load-bearing and the doc comment is wrong — say so.

Report each verbatim. Revert; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/stale-task2-msg.txt` (subject `fix: a stale-path link failure requests a path instead of retrying the link`), `git add` the two files, `git commit -F`.

---

### Task 3: End-to-end proof over a real BLE reconnect

The evidence neither previous slice had: the whole chain, driven through real actions.

**Files:**
- Test: `Tests/ReTiCANodeTests/BLEEndpointLinkTests.swift` (or wherever the two-node BLE harness lives)

**Interfaces:**
- Consumes: Tasks 1 and 2. Produces nothing.

- [ ] **Step 1: Write the test**

```swift
/// The whole point of this slice: a BLE peer that drops and reconnects is deliverable again on
/// the NEXT message, not after ~75s and a failed one. Drives the real chain — announce learned on
/// interface A, A disconnects, peer returns as interface B, a queued direct message reaches the
/// peer — with no seeded state.
@Test @MainActor func bleReconnectedPeerIsDeliverableOnTheNextMessage() async {
    // 1. Peer connects as interface A; announce heard; router learns the path.
    // 2. Peer disconnects (interface A removed from transport.interfaces).
    // 3. Send a direct message -> assert it does NOT burn the link budget: expect .pathStale ->
    //    requestPath, not a mint + 15s deadline.
    // 4. Peer reconnects as interface B and announces -> path re-learned on B.
    // 5. Assert the message is delivered (or a link to the peer is established on B).
    // Assert on OBSERVABLE outcomes, not internal enums.
}
```

If the existing BLE harness cannot express a disconnect/reconnect with a changed `InterfaceID`, extend it — but say so in your report, and do NOT fake the reconnect by mutating transport state directly. A test that seeds the post-reconnect world proves nothing about reachability, which is the exact failure mode this slice exists to fix.

- [ ] **Step 2: Run**

Run: `swift test --filter bleReconnectedPeerIsDeliverableOnTheNextMessage`
Expected: PASS on the merged Tasks 1+2.

- [ ] **Step 3: Prove it is not vacuous**

It is expected to pass immediately, which is **not evidence**. Temporarily revert Task 1's `reachableLearned` gate and confirm this test FAILS. Restore. Report verbatim.

- [ ] **Step 4: Full suite**

Run: `swift test --no-parallel > /tmp/ReTiCA/stale-task3.txt 2>&1` then read it.
Expected: 755/755, 1 known issue.

- [ ] **Step 5: Commit**

Write `/tmp/ReTiCA/stale-task3-msg.txt` (subject `test: a reconnected BLE peer is deliverable on the next message`), `git add` the test file, `git commit -F`.

---

## Final verification (after Task 3)

- [ ] `swift test --no-parallel` — report the exact count.
- [ ] `grep -rn "linkFailed" Sources/` — every emitter and forwarder carries a reason; no site lost one.
- [ ] `grep -rn "reachableLearned" Sources/` — now has callers in both `Transport.send` and `BLEEndpoint.openLink`. Note whether TCP was changed and why.
- [ ] Confirm both bounds are intact: `establishAttempts` still bounds the `requestLink` cycle, and the `.awaitingPath` park still arms `pathRequestTimer`. This slice routes INTO the park; if the park were unbounded, this would be the reverted `f0c4670` again.
- [ ] `git log --format='%(trailers:key=Claude-Session)' -3` — all three commits' trailers parse.
