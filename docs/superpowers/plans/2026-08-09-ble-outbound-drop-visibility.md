# BLE Outbound Drop Visibility Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An outbound packet that BLE cannot deliver stops vanishing silently — it surfaces as `sendFailed`, so a stale interface binding is diagnosable instead of presenting as a link that mysteriously dies 60 seconds later.

**Architecture:** One new `Transport.SendFailure` case, emitted at the two `BLEEndpoint` transmit guards (which already have the raw bytes to recover a destination hash), plus splitting one compound guard in `BLEInterface` so a framing failure is distinguishable from an absent channel.

**Tech Stack:** Swift 6 / TCA / swift-testing. Repo: `/Users/ell/development/ios/pods/ReTiCA`.

## Why this exists

A `LinkSession` binds `interfaceID` once at creation (`LinkSession.swift:30`) and uses it for 20+ outbound transmits. On BLE an `InterfaceID` is derived from the peer's HELLO session token, so **a reconnecting peer is a different interface by construction**. The link's stored ID then names a dead interface and every outbound transmit hits `guard let peer = state.peerInterfaces[txID] else { return .none }` — dropped, with nothing emitted. Inbound keeps working (routing is by `linkID`, interface-agnostic), so the link sits half-alive until the ~60 s inactivity watchdog kills it.

This slice does not fix that binding — a follow-up slice adds re-homing. It makes the failure **observable**, which is the diagnostic that would have made the underlying bug obvious.

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
- Mutation discipline every task, **failing through DISJOINT observation points**. Each task's mutations are specified — apply them exactly, separately if one would crash the process and mask another.
- Baseline: 725/725 green in ReTiCA. Classify any `PNNode*`/`LXMFNodeSync*`/`twoEndpointsTransferMultiSegment*` failure by isolated `--filter` re-run; report real numbers, never "pre-existing failures".
- `skipInFlightEffects()` records a KNOWN issue by design; a test whose only issues are known ones still PASSES. Do not report that as a failure.
- GOTCHA: after touching `Transport.swift`, incremental builds can stale-link into a spurious SIGABRT in `LXMFNodeSyncTests` — run `swift package clean` once and re-run; report if it happens.

## Explicitly out of scope (recorded decisions)

- **`FCBDriverAdapter.swift:277-279`'s `try?`** swallowing L2CAP write errors. Surfacing it needs a new `BLEDriverEvent` case and touches the driver contract plus its FCB-backed adapter — its own slice, and a mechanism-layer concern rather than a routing one.
- **Notifying the LINK** so it can close or retry early instead of waiting out the watchdog. That needs a new `LinkSession` action and a policy decision (close vs retry vs mark-degraded). The follow-up re-homing slice makes this failure mostly disappear; decide then, with evidence.
- **Re-homing itself.** Next slice.

---

### Task 1: `SendFailure.interfaceUnavailable` surfaced at both BLEEndpoint transmit guards

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (the `SendFailure` enum)
- Modify: `Sources/ReTiCANode/BLEEndpoint.swift` (the two transmit guards)
- Test: `Tests/ReTiCANodeTests/BLEEndpointTests.swift`

**Interfaces:**
- Consumes: `Transport.Action.Delegate.sendFailed(destinationHash:reason:)`, already forwarded to the endpoint's own delegate at `BLEEndpoint.swift:159-160` and unified by `TransportEndpoint.swift:178, 201`.
- Produces: `Transport.SendFailure.interfaceUnavailable`.

- [ ] **Step 1: Write the failing tests**

The existing `BLEEndpointTests.swift` already has helpers that bring a peer online and drive transmits — read the file first and reuse its store setup rather than inventing one. Both tests deliberately transmit to an interface that is NOT in `peerInterfaces`, which is exactly the stale-binding condition.

```swift
/// A Transport-level transmit to an interface that is no longer connected surfaces as
/// sendFailed rather than vanishing. This is the stale-binding case: a BLE InterfaceID is
/// derived from the peer's session token, so a reconnected peer is a different interface
/// and any link still bound to the old one transmits into the void.
@Test @MainActor func transportTransmitToUnknownInterfaceReportsSendFailed() async {
    // Build the same store the other BLEEndpoint tests use, with one peer online.
    // Then drive a transport transmit addressed to a DIFFERENT (never-connected) interface.
    // Assert: .delegate(.sendFailed(destinationHash: <the packet's destHash>,
    //                               reason: .interfaceUnavailable)) is emitted,
    // and NO .ble(.send(...)) occurs.
}

/// The same for link-plane traffic. For a link packet the packet's destination hash IS the
/// link ID (Transport.swift:291 derives `linkID: packet.destinationHash`), so the reported
/// destinationHash correlates the failure to the link exactly.
@Test @MainActor func linkPlaneTransmitToUnknownInterfaceReportsSendFailed() async {
    // As above but drive `.linkPlane(.delegate(.transmit(unknownID, raw)))`.
    // Assert the emitted destinationHash equals the raw packet's destination hash.
}

/// Regression: a transmit to a LIVE interface still goes out, unchanged, and emits no failure.
@Test @MainActor func transmitToLiveInterfaceStillSendsAndReportsNoFailure() async {
    // Peer online; transmit to its real InterfaceID.
    // Assert `.ble(.send(peer:packet:))` occurs and NO sendFailed is emitted.
    // Flip `store.exhaustivity = .on` as the LAST statement so teardown catches a stray failure.
}
```

Write the bodies against the real helpers in that file. If a helper does not exist for driving a raw transmit, add a minimal one rather than reshaping existing tests.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter BLEEndpointTests`
Expected: the two failure tests FAIL (nothing is emitted today — the guards return `.none`); the live-interface regression test PASSES already.

- [ ] **Step 3: Implement**

In `Sources/ReTiCATransport/Transport.swift`, extend the enum:

```swift
public enum SendFailure: Equatable, Sendable {
    case notLearned
    case tooLarge
    /// The packet was addressed to an interface that is not currently connected. On BLE an
    /// InterfaceID is derived from the peer's HELLO session token, so a reconnected peer is a
    /// DIFFERENT interface — anything still bound to the old one (notably a LinkSession, which
    /// binds its interfaceID once at creation) lands here. Previously a silent drop.
    case interfaceUnavailable
}
```

In `Sources/ReTiCANode/BLEEndpoint.swift`, at the transport transmit guard (currently `guard let token = state.peerInterfaces[txID] else { return .none }`, ≈:152):

```swift
guard let token = state.peerInterfaces[txID] else {
    // Not deliverable: the interface is gone. Surface it rather than dropping — a stale
    // binding otherwise presents as a link that dies on the ~60s inactivity watchdog with
    // no indication why. `Packet(raw:)` recovers the destination hash; for a link packet
    // that value IS the link ID (Transport.swift:291), so the failure correlates exactly.
    guard let destHash = Packet(raw: raw)?.destinationHash else { return .none }
    return .send(.delegate(.sendFailed(destinationHash: destHash,
                                       reason: .interfaceUnavailable)))
}
```

Apply the identical treatment to the linkPlane transmit guard (≈:210). Keep both IFAC-masking lines exactly as they are — this task changes only the failure path.

Note the inner `guard`: an unparseable packet still drops silently, because there is no destination to report. That is a deliberate, narrow residue — document it in the comment.

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter BLEEndpointTests`
Expected: all three pass.

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: 728/728 (725 + 3). **If a pre-existing test fails, STOP and report** — emitting a new delegate where nothing was emitted before can surface in exhaustive stores.

- [ ] **Step 6: Mutation verification (batch — disjoint tests)**

Apply both at once:
1. Revert ONLY the transport-transmit guard to `return .none` → `transportTransmitToUnknownInterfaceReportsSendFailed` fails; the linkPlane test still passes.
2. In the linkPlane guard, emit `.notLearned` instead of `.interfaceUnavailable` → `linkPlaneTransmitToUnknownInterfaceReportsSendFailed` fails on the reason.
Different tests, no shared state. Report each failure verbatim, labelled. Confirm `transmitToLiveInterfaceStillSendsAndReportsNoFailure` stays green under both. Revert; re-run; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/drop-task1-msg.txt` (subject `feat: report BLE transmits to a departed interface as sendFailed`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Sources/ReTiCANode/BLEEndpoint.swift Tests/ReTiCANodeTests/BLEEndpointTests.swift
git commit -F /tmp/ReTiCA/drop-task1-msg.txt
```

---

### Task 2: Split BLEInterface's compound send guard

**Files:**
- Modify: `Sources/ReTiCAInterfaces/BLEInterface.swift` (≈:243-246)
- Test: `Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1 — independent.
- Produces: nothing downstream.

- [ ] **Step 1: Write the failing test**

The current guard collapses two unrelated failures:

```swift
case let .send(peer, packet):
    guard let channelID = state.peers[peer],
          let framed = try? BLEFraming.frame(packet)
    else { return .none }
```

"No channel for this peer" is a lifecycle race (the peer went away). "This packet will not frame" is a programmer error — `BLEFraming.frame` throws only when the packet exceeds `BLEFraming.maxFrameLength` (1196) or is empty. Conflating them means an oversized packet looks exactly like a departed peer.

Read `Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift` for the established store setup (bringing a peer online requires `.ready` before `channelOpened`, and the mock `bleRandomBytes` token must differ from the injected peer HELLO token — see the existing tests). Then:

```swift
/// A send to a peer with no channel is a lifecycle race and drops quietly.
@Test @MainActor func sendToUnknownPeerDropsQuietly() async {
    // Peer online. Send to a DIFFERENT token. Assert no driver send occurred.
}

/// An oversized packet is a programmer error, not a lifecycle race: it must be
/// distinguishable rather than silently identical to a departed peer.
@Test @MainActor func sendOfUnframablePacketIsDistinguishedFromAbsentChannel() async {
    // Peer online. Send a packet longer than BLEFraming.maxFrameLength to that LIVE peer.
    // Assert no driver send occurred AND that the two cases are distinguishable —
    // see Step 3 for the mechanism chosen.
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter BLEInterfaceTests`
Expected: the second test fails — today both paths are indistinguishable.

- [ ] **Step 3: Implement**

Split the guard so the two conditions are separate statements with distinct handling:

```swift
case let .send(peer, packet):
    // Lifecycle race: the peer's channel is gone. Nothing to report at this layer —
    // BLEEndpoint already surfaces undeliverability as sendFailed.
    guard let channelID = state.peers[peer] else { return .none }
    // Programmer error: the packet cannot be framed (empty, or over
    // BLEFraming.maxFrameLength). Distinct from a departed peer.
    guard let framed = try? BLEFraming.frame(packet) else {
        return .send(.delegate(.sendFailed(peer: peer, reason: .unframable)))
    }
    return .run { [bleDriver] _ in await bleDriver.send(channelID, framed) }
```

Add whatever minimal delegate case that requires to `BLEInterface.Action.Delegate`, following the existing naming in that enum. If `BLEInterface` has no delegate suited to this, add one named for the layer it belongs to rather than reusing a Transport-level concept — `BLEInterface` sits below `Transport` and must not depend on it.

Then wire it through `BLEEndpoint` only if a consumer needs it; if nothing consumes it yet, leave it unforwarded and say so in the report rather than inventing a consumer.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter BLEInterfaceTests`
Expected: both pass.

- [ ] **Step 5: Full suite**

Run: `swift test`
Expected: 730/730 (728 + 2).

- [ ] **Step 6: Mutation verification**

Apply one mutation: restore the compound guard (both conditions in one `guard ... else { return .none }`).
Expected: `sendOfUnframablePacketIsDistinguishedFromAbsentChannel` fails; `sendToUnknownPeerDropsQuietly` still passes. Report verbatim. Revert; green.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/drop-task2-msg.txt` (subject `refactor: distinguish an unframable packet from an absent BLE channel`), then:

```bash
git add Sources/ReTiCAInterfaces/BLEInterface.swift Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift
git commit -F /tmp/ReTiCA/drop-task2-msg.txt
```

---

## Final verification (after Task 2)

- [ ] `swift test` — full suite green; report the exact count.
- [ ] `grep -n "else { return .none }" Sources/ReTiCANode/BLEEndpoint.swift` — the two transmit guards no longer match; any remaining hits are unrelated cases (verify each by reading).
- [ ] Confirm by reading that both IFAC masking calls in `BLEEndpoint` are unchanged.
- [ ] `git log --format='%(trailers:key=Claude-Session)' -2` — both task commits' trailers parse.
- [ ] `git diff <plan-base> HEAD --stat` — only the files named in the two tasks, plus this plan.
