# Stale Learned-Path Interface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** After a BLE peer restarts, sending to it and opening a link to it stop failing silently or slowly — and `openLink` fails fast enough to trigger the path-request recovery loop that already exists.

**Architecture:** One non-destructive liveness helper on `Transport.State`, applied at the two user-facing readers of `learned[dest].interfaceID` (`Transport.send`, and both endpoints' `openLink`). No table is purged.

**Tech Stack:** Swift 6 / TCA / swift-testing. Repo: `/Users/ell/development/ios/pods/ReTiCA`.

## Why this exists

`LearnedDestination.interfaceID` is captured from the announce arrival (`Transport.swift:414`) and replaced only by a strictly-newer announce (`Transport.shouldReplace`, `:977-982`). `interfaceDisconnected` never purges it (`:219-228`).

On BLE an `InterfaceID` derives from the peer's HELLO session token, so a restarted peer is a *different interface*. `shouldReplace` does accept its re-announce (announces carry a newer emitted timestamp), so `learned` self-heals — **but only at the next announce, which is minutes away.** In that window:

- `Transport.send` (`:769`) transmits to a dead interface. Since the drop-visibility slice this reports `sendFailed(.interfaceUnavailable)` from the endpoint, but only after the packet has been built and routed.
- `BLEEndpoint.openLink` (`:188-196`) reads `learned.interfaceID` with **no liveness check at all**, opens a link on a dead interface, and fails ~15 s later at `establishmentDeadline` — reported as `linkFailed`.

This is the same class of defect as the link re-homing slice, one table over: a binding captured once and read forever.

## The recovery loop this unlocks

`LXMFRouter` already consumes `linkFailed` and requests a path when it does not know one (`LXMFRouter.swift:311-313`), tracking `knownPaths` (`:27`, inserted on `.pathLearned` at `:280`). So making `openLink` fail *fast* completes a loop that currently cannot start:

`openLink` → immediate `linkFailed` → router requests a path → peer answers → `learned` refreshes with the **live** interface → retry succeeds.

C4's ingress-control exemption already protects that path request from being held under a burst. The pieces compose; only the fast failure is missing.

## Scoping decision (recorded)

There are five readers of `entry.interfaceID` in `Transport.swift`. Only the user-facing ones get the check:

| site | role | check? |
|---|---|---|
| `:769` `Transport.send` | user-facing send | **yes** |
| `BLEEndpoint.openLink` / `TCPEndpoint.openLink` | user-facing link open | **yes** |
| `:531`, `:551` | relay forwarding *another node's* packet toward its destination | **no** — there is no caller to report to, and it already effectively drops. Adding a check would change relay behaviour for no consumer's benefit. |
| `:549` | records `nhIf` into `linkTable` for reverse routing | **no** — a separate table with its own 900 s expiry; latent staleness there is a distinct concern. |
| `:573` | read-only mode lookup for path expiry, already optional-chained | **no** — not a transmit. |

**Rejected alternative — purge `learned` on `interfaceDisconnected`.** TCP's `InterfaceID` is fixed, so it returns after any network blip; purging would discard every learned path on every TCP reconnect. Destructive, and wrong for the transport that reconnects most often. The liveness check is non-destructive: path knowledge is retained and becomes usable again the moment the interface returns (TCP) or the peer re-announces (BLE).

**Failure reason for `send`: `.interfaceUnavailable`, not `.notLearned`.** The path *is* learned; we simply cannot use it right now. Reporting `.notLearned` would be a convenient lie, and the `openLink` → `linkFailed` route already gives the router its recovery trigger without `send` having to misreport. Nothing consumes `sendFailed` today, so this choice only decides what a future consumer sees — which is exactly why it should be accurate.

## Global Constraints

- Commit directly to `main`. No branches, merges, rebases, resets.
- **You are the implementer, NOT the controller. Do NOT invoke the `superpowers:subagent-driven-development` skill or run any of its scripts** — an implementer that loaded it executed the skill's finish step and deleted a plan workspace.
- The user commits CONCURRENTLY. `git add` ONLY the files each task names — never `-A`, never `.`.
- One command per Bash invocation — no `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreter scripts. Multi-step work = a script under `/tmp/ReTiCA/`.
- Commit trailers MUST start at column 0:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```
- Mutation discipline every task, **failing through DISJOINT observation points**.
- Baseline: 737/737. Known flakes — `PNNode*`, `LXMFNodeSync*`, `twoEndpointsTransferMultiSegmentResourceOverALink`, `pairedModePublishesWithEncryptionAndEncryptedReadPerms` — pass in isolation; classify with `--filter` before reporting. Never say "pre-existing failures" without that classification.
- `skipInFlightEffects()` records a KNOWN issue by design; a test whose only issues are known ones still PASSES.
- GOTCHA: after touching `Transport.swift`, incremental builds can stale-link into a spurious SIGABRT in `LXMFNodeSyncTests` — `swift package clean` once and re-run; report if it happens.

## TestStore trap — read before writing any absence assertion

`store.exhaustivity = .off` is `.off(showSkippedAssertions: false)`, and `TestStore.send` runs `self.reducer.receivedActions = []` on **every** send (`TestStore.swift:921-928`). So an "assert nothing was emitted" test is vacuous by default, and a trailing `store.exhaustivity = .on` as the **last** statement is a **no-op**. Make the send whose consequence you are asserting the **last** `store.send`, or capture the effect in a dependency stub and assert on that.

---

### Task 1: Liveness helper + `Transport.send`

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (a helper on `State`; the `.send` case ≈:760-770)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: `State.learned`, `State.interfaces` (C1's `[InterfaceID: InterfaceProfile]`).
- Produces: a liveness accessor on `Transport.State` — name it for what it means (e.g. `reachableLearned(_ destinationHash: Data) -> LearnedDestination?`), returning the entry only when `interfaces[entry.interfaceID] != nil`. Task 2 uses it from the endpoints, so it must be `public`.

- [ ] **Step 1: Write the failing tests**

```swift
/// A learned path whose interface has since disconnected is not usable: sending reports
/// interfaceUnavailable rather than building a packet and routing it into the void. The path
/// itself is RETAINED — it becomes usable again when the interface returns (TCP) or the peer
/// re-announces (BLE).
@Test @MainActor func sendToADestinationOnADepartedInterfaceReportsInterfaceUnavailable() async {
    // Connect "i0", learn a path via an announce, then send .interfaceDisconnected("i0").
    // Send to that destination. Assert:
    //   - .delegate(.sendFailed(destinationHash: dest, reason: .interfaceUnavailable))
    //   - NO .delegate(.transmit(...)) occurs
    //   - store.state.learned[dest] is still present (non-destructive)
    // ABSENCE ASSERTION: make the .send the LAST store.send, per the TestStore trap above.
}

/// The happy path is unchanged: a learned destination on a live interface still transmits.
@Test @MainActor func sendToADestinationOnALiveInterfaceStillTransmits() async {
    // Connect "i0", learn a path, send. Assert .delegate(.transmit(InterfaceID("i0"), _)) fires
    // and no sendFailed is emitted.
}

/// An unknown destination still reports notLearned — the new check must not swallow or
/// re-label the pre-existing case.
@Test @MainActor func sendToAnUnknownDestinationStillReportsNotLearned() async {
    // Send to a destination never announced. Assert reason == .notLearned.
}
```

Read the file for its existing announce-learning helpers (`makeAnnouncePacket`) and store setup; reuse them.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter TransportTests`
Expected: the first test FAILS (today it transmits rather than reporting); the other two PASS already.

- [ ] **Step 3: Implement**

Add the accessor to `Transport.State`:

```swift
/// The learned path to `destinationHash`, but only when its interface is currently connected.
///
/// `LearnedDestination.interfaceID` is captured at announce time and replaced only by a
/// strictly-newer announce, so after a BLE peer restarts (its InterfaceID derives from the
/// HELLO session token, making a reconnected peer a DIFFERENT interface) the stored binding
/// names a dead interface until that peer's next announce — minutes away.
///
/// Deliberately NON-DESTRUCTIVE: the entry is retained, not purged. Purging on
/// `interfaceDisconnected` would discard every path on every TCP reconnect, since TCP's
/// InterfaceID is fixed and returns after a blip.
public func reachableLearned(_ destinationHash: Data) -> LearnedDestination? {
    guard let entry = learned[destinationHash], interfaces[entry.interfaceID] != nil
    else { return nil }
    return entry
}
```

Then in the `.send` case (≈:760), distinguish the two failures — an unknown destination is still `.notLearned`; a known-but-unreachable one is `.interfaceUnavailable`:

```swift
case let .send(destinationHash, plaintext):
    guard let entry = state.learned[destinationHash] else {
        return .send(.delegate(.sendFailed(destinationHash: destinationHash, reason: .notLearned)))
    }
    guard state.reachableLearned(destinationHash) != nil else {
        return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                           reason: .interfaceUnavailable)))
    }
    …unchanged from here…
```

Leave the relay-forwarding readers (`:531`, `:551`), the `linkTable` `nhIf` capture (`:549`), and the path-expiry mode lookup (`:573`) ALONE — see the plan's scoping table.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter TransportTests`
Expected: all three pass.

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: 740/740 (737 + 3). **If a pre-existing test fails, STOP and report** — a test that learned a path and then disconnected its interface before sending would now get a different result, and that is worth surfacing rather than silently adjusting.

- [ ] **Step 6: Mutation verification (batch — disjoint tests)**

Apply both at once:
1. Make `reachableLearned` ignore the liveness check (return `learned[destinationHash]`) → `sendToADestinationOnADepartedInterfaceReportsInterfaceUnavailable` fails.
2. In `.send`, report `.notLearned` for the unreachable case → the same test fails on the reason, while `sendToAnUnknownDestinationStillReportsNotLearned` still passes.
Because both target the same test, run them SEPARATELY and report each verbatim so neither masks the other. Revert; re-run; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/stale-task1-msg.txt` (subject `feat: do not send to a learned path whose interface has departed`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/stale-task1-msg.txt
```

---

### Task 2: `openLink` fails fast, unlocking the path-request recovery loop

**Files:**
- Modify: `Sources/ReTiCANode/BLEEndpoint.swift` (`openLink` ≈:187-196), `Sources/ReTiCANode/TCPEndpoint.swift` (its `openLink`)
- Test: `Tests/ReTiCANodeTests/BLEEndpointLinkTests.swift`

**Interfaces:**
- Consumes: `Transport.State.reachableLearned(_:)` from Task 1.
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

`BLEEndpointLinkTests.swift` already has the multi-peer harness (`bringPeerOnline` with `token:`/`channelID:` parameters, and a driver stub that maps channel → token). Reuse it.

```swift
/// Opening a link to a destination learned on a departed interface fails IMMEDIATELY rather
/// than minting a link on a dead interface and waiting ~15s for establishmentDeadline.
/// The fast failure is what lets LXMFRouter request a path and recover (LXMFRouter.swift:311-313).
@Test @MainActor func openLinkToADepartedInterfaceFailsImmediately() async {
    // Peer online under tokenA; learn a path over that peer's interface via an announce.
    // Take the peer offline. Then send .openLink(destinationHash:).
    // Assert .delegate(.linkFailed(destinationHash:)) is emitted, and NO link was minted
    // (store.state.links is empty) — the point is that no session is created on a dead interface.
    // Do NOT advance the clock: the whole claim is that this does not wait for a timeout.
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BLEEndpointLinkTests`
Expected: FAIL — today a link IS minted on the dead interface, so `store.state.links` is non-empty and `linkFailed` does not arrive without advancing the clock ~15 s.

- [ ] **Step 3: Implement**

In `BLEEndpoint.swift`'s `openLink` (≈:188), swap the lookup for the liveness-checked one:

```swift
case let .openLink(destinationHash):
    // Fail fast when the learned interface has departed, rather than minting a link on a dead
    // interface and waiting ~15s for establishmentDeadline. The prompt linkFailed is what lets
    // LXMFRouter request a path (LXMFRouter.swift:311-313), which refreshes `learned` with the
    // live interface and makes a retry succeed.
    guard let learned = state.transport.reachableLearned(destinationHash) else {
        return .send(.delegate(.linkFailed(destinationHash: destinationHash)))
    }
    …unchanged from here…
```

Apply the same change to `TCPEndpoint`'s `openLink`. TCP has one fixed `InterfaceID`, so this only fires while TCP is disconnected — which is correct, and should be inert for every existing test.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter BLEEndpointLinkTests`, then `swift test --filter TCPEndpointTests`
Expected: pass. **If a pre-existing TCP test fails, STOP and report** — it would mean a test opens a link while disconnected, which is worth understanding rather than accommodating.

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: 741/741 (740 + 1).

- [ ] **Step 6: Mutation verification**

Revert `BLEEndpoint.openLink` to `state.transport.learned[destinationHash]` → the new test must FAIL (a link is minted; no immediate `linkFailed`). Report verbatim. Revert; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/stale-task2-msg.txt` (subject `feat: openLink fails fast when the learned interface has departed`), then:

```bash
git add Sources/ReTiCANode/BLEEndpoint.swift Sources/ReTiCANode/TCPEndpoint.swift Tests/ReTiCANodeTests/BLEEndpointLinkTests.swift
git commit -F /tmp/ReTiCA/stale-task2-msg.txt
```

---

## Final verification (after Task 2)

- [ ] `swift test` — full suite green; report the exact count.
- [ ] `grep -n "reachableLearned" Sources` — the definition plus exactly three call sites (`Transport.send`, both `openLink`s).
- [ ] Confirm by reading that the relay readers (`Transport.swift:531, 551`), the `linkTable` `nhIf` capture (`:549`), and the path-expiry mode lookup (`:573`) are UNCHANGED.
- [ ] Confirm `learned` is never purged — `grep -n "learned\[.*\] = nil" Sources/ReTiCATransport/Transport.swift` should show only the pre-existing `maintenanceTick` expiry sweep.
- [ ] `git log --format='%(trailers:key=Claude-Session)' -2` — both task commits' trailers parse.
