# BLE Link Re-homing Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A link survives its BLE peer reconnecting under a new session token, instead of transmitting into the void until the ~60 s watchdog kills it.

**Architecture:** `Transport.Action.Delegate.linkPacket` gains `arrivalInterface` (mirroring `linkRequest`, which already carries it); `LinkPlane.routeLinkPacket` updates the session's `interfaceID` when the arrival differs, then forwards `.received` unchanged. None of `LinkSession`'s 20+ transmit sites change — they start reading a current value.

**Tech Stack:** Swift 6 / TCA / swift-testing. Repo: `/Users/ell/development/ios/pods/ReTiCA`. Spec: `docs/superpowers/specs/2026-08-09-ble-link-rehoming-design.md`.

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
- Mutation discipline every task, **failing through DISJOINT observation points**. Apply the specified mutations exactly; separate them if one would crash the process and mask another.
- Baseline: 732/732 green. Known flakes — `PNNode*`, `LXMFNodeSync*`, `twoEndpointsTransferMultiSegmentResourceOverALink`, `pairedModePublishesWithEncryptionAndEncryptedReadPerms` — pass in isolation; classify with `--filter` before reporting. Never say "pre-existing failures" without that classification.
- `skipInFlightEffects()` records a KNOWN issue by design; a test whose only issues are known ones still PASSES.
- GOTCHA: after touching `Transport.swift`, incremental builds can stale-link into a spurious SIGABRT in `LXMFNodeSyncTests` — `swift package clean` once and re-run; report if it happens.

## TestStore trap that has bitten this project repeatedly — read before writing any absence assertion

`store.exhaustivity = .off` is `.off(showSkippedAssertions: false)`, and `TestStore.send` runs `self.reducer.receivedActions = []` on **every** send (`TestStore.swift:921-928`). Consequences:

- An "assert nothing was emitted" test is **vacuous by default** — a later `store.send` wipes the stray action before teardown inspects it.
- A trailing `store.exhaustivity = .on` as the **last** statement is a **no-op**: the queue is already empty.
- **Fix:** make the send whose consequence you are asserting the **last** `store.send` in the test, or record the effect in a dependency stub and assert on that directly.

Task 2 asserts an absence (`sendFailed` must NOT fire). Get this right, and mutation-prove it.

---

### Task 1: `linkPacket` carries the arrival interface; `LinkPlane` re-homes

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (`Delegate.linkPacket` at :176; the emission site ≈:291)
- Modify: `Sources/ReTiCANode/LinkPlane.swift` (`routeLinkPacket` action :36 and handler :94-96)
- Modify: `Sources/ReTiCANode/BLEEndpoint.swift` (≈:163), `Sources/ReTiCANode/TCPEndpoint.swift` (≈:139)
- Test: `Tests/ReTiCANodeTests/LinkPlaneTests.swift`, `Tests/ReTiCATransportTests/TransportTests.swift`, `Tests/ReTiCANodeTests/TCPEndpointTests.swift`

**Interfaces:**
- Consumes: `LinkSession.State.interfaceID` (`LinkSession.swift:30`), `LinkSession.State.linkID` (:31).
- Produces: `Delegate.linkPacket(linkID:arrivalInterface:data:)` and `LinkPlane.Action.routeLinkPacket(linkID:arrivalInterface:data:)`. Task 2 drives these end-to-end.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCANodeTests/LinkPlaneTests.swift`. Read the file first for its established store setup and reuse it.

```swift
/// A link packet arriving on a DIFFERENT interface re-homes the session, so subsequent
/// outbound traffic goes to the new interface. This is the BLE peer-reconnect case: an
/// InterfaceID is derived from the peer's session token, so a reconnected peer is a
/// different interface and the link's stored binding is stale.
@Test @MainActor func linkPacketFromANewInterfaceReHomesTheSession() async {
    // Seed a LinkPlane whose single link has interfaceID "old".
    // Drive .routeLinkPacket(linkID:, arrivalInterface: InterfaceID("new"), data:).
    // Assert the session's interfaceID is now "new", AND that .received(data) was still
    // forwarded unchanged (re-homing must not swallow the packet).
}

/// A link packet arriving on the SAME interface changes nothing — the common case must not
/// churn state. This is also the TCP case: TCPEndpoint has one fixed InterfaceID, so the
/// arrival always equals the stored value and the assignment is inert.
@Test @MainActor func linkPacketFromTheSameInterfaceLeavesTheSessionUnchanged() async {
    // Seed with interfaceID "tcp"; route a packet with arrivalInterface "tcp".
    // Assert interfaceID is still "tcp" and .received(data) was forwarded.
}

/// Re-homing is keyed to the addressed link only: an unrelated session on another interface
/// is untouched.
@Test @MainActor func reHomingDoesNotDisturbOtherSessions() async {
    // Seed TWO links, A on "ifA" and B on "ifB". Route a packet for A arriving on "ifNew".
    // Assert A re-homed to "ifNew" and B is STILL on "ifB".
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter LinkPlaneTests`
Expected: FAIL to compile — `routeLinkPacket` has no `arrivalInterface`.

- [ ] **Step 3: Implement**

`Transport.swift` — the delegate case at :176 becomes:
```swift
case linkPacket(linkID: Data, arrivalInterface: InterfaceID, data: Data)
```
and the emission site (≈:291, currently `.send(.delegate(.linkPacket(linkID: packet.destinationHash, data: plain)))`) passes `arrivalInterface: interfaceID` — the value already bound by the enclosing `case let .received(interfaceID, data)`.

`LinkPlane.swift` — the action at :36 gains `arrivalInterface: InterfaceID`, and the handler at :94-96 becomes:

```swift
case let .routeLinkPacket(linkID, arrivalInterface, data):
    guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
    // Re-home: a BLE InterfaceID is derived from the peer's HELLO session token, so a
    // reconnected peer is a DIFFERENT interface and the binding taken at link creation is
    // stale — outbound would go to a dead interface until the ~60s watchdog closed the link.
    // Safe because this packet already decrypted and validated under THIS link's keys, so the
    // arrival is authenticated. Inert on TCP, whose single fixed InterfaceID always matches.
    if state.links[id: element.id]?.interfaceID != arrivalInterface {
        state.links[id: element.id]?.interfaceID = arrivalInterface
    }
    return .send(.link(.element(id: element.id, action: .received(data))))
```

Adapt the `IdentifiedArray` mutation to whatever accessor `LinkPlane` already uses for its links — read the surrounding cases and match them rather than assuming a subscript shape.

`BLEEndpoint.swift` ≈:163 and `TCPEndpoint.swift` ≈:139 — both currently destructure `(linkID, data)` and forward to `.linkPlane(.routeLinkPacket(linkID:data:))`. Thread the new value through both.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter LinkPlaneTests`
Expected: 3 PASS.

- [ ] **Step 5: Update the enumerated call sites**

These reference the changed cases and must be updated — find each by its quoted context:
- `Tests/ReTiCATransportTests/TransportTests.swift` — the `.delegate(.linkPacket(l, d))` destructuring at ≈:298 and ≈:1117 (case-only predicates at ≈:315, :318 need no change).
- `Tests/ReTiCANodeTests/LinkPlaneTests.swift:95` — the round-trip case-path check for `.routeLinkPacket`.
- `Tests/ReTiCANodeTests/TCPEndpointTests.swift:241` uses a KEY-PATH receive (`\.transport.delegate.linkPacket`) which matches any payload — verify it still compiles and leave it otherwise.

If a site not listed here needs changing, make the minimal edit and document it — do not reshape a test to accommodate the new payload.

- [ ] **Step 6: Full suite**

Run: `swift test`
Expected: 735/735 (732 + 3). **If a pre-existing test fails, STOP and report** — re-homing must be inert for every existing scenario, all of which are single-interface.

- [ ] **Step 7: Mutation verification (batch — disjoint tests)**

Apply both at once:
1. Delete the re-homing assignment (keep the forward) → `linkPacketFromANewInterfaceReHomesTheSession` fails; the same-interface and other-sessions tests still pass.
2. Re-home unconditionally on ALL sessions rather than the addressed one → `reHomingDoesNotDisturbOtherSessions` fails.
Different tests, no shared state. Report each verbatim, labelled. Revert; re-run; green.

- [ ] **Step 8: Commit**

Write `/tmp/ReTiCA/rehome-task1-msg.txt` (subject `feat: re-home a link when its peer reconnects on a new interface`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Sources/ReTiCANode/LinkPlane.swift Sources/ReTiCANode/BLEEndpoint.swift Sources/ReTiCANode/TCPEndpoint.swift Tests/ReTiCANodeTests/LinkPlaneTests.swift Tests/ReTiCATransportTests/TransportTests.swift Tests/ReTiCANodeTests/TCPEndpointTests.swift
git commit -F /tmp/ReTiCA/rehome-task1-msg.txt
```

---

### Task 2: Prove it end-to-end over a real BLE peer cycle

Task 1's tests drive `LinkPlane` directly. This task proves the whole path — that a peer genuinely reconnecting under a new token leaves a working link — using the previous slice's `sendFailed` diagnostic as the instrument.

**Files:**
- Test: `Tests/ReTiCANodeTests/BLEEndpointLinkTests.swift`

**Interfaces:**
- Consumes: everything from Task 1; the existing harness in that file (`bringPeerOnline`, `teardown`, `framedHello`, the `channel`/`handle`/`peerToken` constants).
- Produces: nothing.

- [ ] **Step 1: Write the failing test**

The existing harness hardcodes one `peerToken` and one `channel`. A peer cycle needs a SECOND token and channel — generalise `bringPeerOnline` to take them as parameters (defaulting to the current values so existing call sites are untouched) rather than duplicating it.

```swift
/// End-to-end: a link survives its peer reconnecting under a NEW session token.
/// Before re-homing this was the half-alive case — inbound kept working (LinkPlane routes by
/// linkID) while every outbound transmit hit a dead InterfaceID, until the ~60s watchdog.
@Test @MainActor func linkSurvivesPeerReconnectUnderANewToken() async {
    // 1. Peer online under tokenA; establish a link (reuse this file's LINKREQUEST flow).
    // 2. Peer offline (tokenA) — the link's stored interfaceID is now dead.
    // 3. Peer online under tokenB (a DIFFERENT token → a different InterfaceID).
    // 4. Deliver an inbound link packet over tokenB's channel.
    // 5. Assert outbound link traffic now reaches tokenB — capture the driver `send` calls and
    //    assert the peer is tokenB, NOT tokenA.
    // 6. Assert `sendFailed(reason: .interfaceUnavailable)` did NOT fire.
    //
    // ABSENCE ASSERTION — see the TestStore trap in Global Constraints. Do NOT rely on a
    // trailing `.on` flip; make the outbound-driving send the LAST `store.send`, or capture
    // sendFailed occurrences in a LockIsolated and assert the count is zero.
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BLEEndpointLinkTests`
Expected: with Task 1 already merged this test should PASS. That is a problem — it means the test cannot distinguish the fix. **Before proceeding, confirm it genuinely exercises re-homing** by temporarily reverting the `LinkPlane` assignment and checking the test FAILS. If it passes with re-homing removed, the test is not driving the path; fix the test before continuing and say so in the report.

- [ ] **Step 3: Full suite**

Run: `swift test`
Expected: 736/736 (735 + 1).

- [ ] **Step 4: Mutation verification**

Apply, separately:
1. Delete the re-homing assignment in `LinkPlane` → this test must FAIL on the outbound-peer assertion (traffic still addressed to tokenA's interface), and `sendFailed` should now fire.
2. Re-home to a hardcoded wrong interface → this test must FAIL.
Report both verbatim. Revert; green.

- [ ] **Step 5: Commit**

Write `/tmp/ReTiCA/rehome-task2-msg.txt` (subject `test: a link survives its BLE peer reconnecting under a new token`), then:

```bash
git add Tests/ReTiCANodeTests/BLEEndpointLinkTests.swift
git commit -F /tmp/ReTiCA/rehome-task2-msg.txt
```

---

## Final verification (after Task 2)

- [ ] `swift test` — full suite green; report the exact count.
- [ ] `grep -rn "linkPacket(linkID:" Sources` — every site carries `arrivalInterface`.
- [ ] Confirm by reading that `LinkSession` is UNCHANGED — this slice must not touch it; the 20+ transmit sites simply read a fresher `state.interfaceID`.
- [ ] Confirm the re-homing assignment is guarded by a difference check (no pointless state churn on the common same-interface path).
- [ ] `git log --format='%(trailers:key=Claude-Session)' -2` — both task commits' trailers parse.
- [ ] `git diff <plan-base> HEAD --stat` — only the files named in the two tasks, plus this plan.
