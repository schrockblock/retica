# F11 — Stalled-Advertiser Link-Pin Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop an authenticated peer from pinning a capped responder-link slot by advertising resources it never sends, without harming genuine large transfers.

**Architecture:** Two changes to the eviction policy, which measures the wrong signal today. Fix #1 (`LinkPlane`): a link is eviction-immune only if a transfer has actually received a part (`receivedFirstPart`), not merely because `transfers` is non-empty. Fix #2 (`LinkSession`): resource *advertisements* no longer advance the `lastData` eviction clock (they still authenticate, for re-home), so a stalled re-advertiser sorts as the eviction victim. No per-link cap; transient growth self-reaps via the existing receiver watchdog.

**Tech Stack:** Swift, The Composable Architecture (TCA / swift-testing). Package: ReTiCA (`/Users/ell/development/ios/pods/ReTiCA`), targets `ReTiCATransport` (`LinkSession`, `ResourceTransfer`) and `ReTiCANode` (`LinkPlane`).

## Global Constraints

- Repo: `/Users/ell/development/ios/pods/ReTiCA`. Edits in `Sources/ReTiCATransport` and `Sources/ReTiCANode` only. No wire-format change. **No per-link cap on `transfers`** (deliberately declined — reference has none).
- Commit directly to `main`. No feature branch.
- Commit trailers must start at **column 0**. End every commit with exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
  ```
  Write the message to a file, `git commit -F <file>`, then verify: `git -C /Users/ell/development/ios/pods/ReTiCA log -1 --format='%(trailers:key=Claude-Session)'` must echo the trailer.
- **One command per shell invocation.** No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`. Redirect a single command's output to a file under /tmp/ReTiCA/ (create with one `mkdir -p`) and Read it back.
- Run tests: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter <TestName>` (single) or without `--filter` for the full suite (expect the 1 known-issue test `holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood` — not your failure). First build takes minutes; timeout up to 600000ms. On a spurious signal-11/signal-10 or stale-link `LinkSessionRequestTests` failure, run `swift package clean --package-path /Users/ell/development/ios/pods/ReTiCA` once and retry.
- **Mutation verification mandatory** per task (three-step rule): green → apply the stated behavioral mutation → confirm red → revert → confirm green, before committing.
- Tests keep `store.exhaustivity = .off`. Line numbers in this plan are approximate — locate code by the quoted surrounding lines and report drift.

---

### Task 1: Fix #1 — progress-aware eviction immunity

A link is immune to eviction only if a transfer has received a part; an advertised-but-stalled transfer no longer confers immunity, so a stalled advertiser becomes an eviction candidate.

**Files:**
- Modify: `Sources/ReTiCANode/LinkPlane.swift` — the evictable filter (`:322`) and its comment (`:305-311`).
- Test: `Tests/ReTiCANodeTests/LinkPlaneTests.swift` — rewrite one test, add one.

**Interfaces:**
- Consumes (existing): `ResourceTransfer.State.receivedFirstPart: Bool` (public, `ResourceTransfer.swift:39`), reachable as `$0.receivedFirstPart` on transfers in `LinkSession.State.transfers`; test helpers `activeResponderInPlane(_:owner:destHash:interfaceID:)`, `acceptAndActivateResponder(_:owner:destHash:iface:)`, `advertisementPacket(linkID:sessionKey:resourceHash:)`.
- Produces: the corrected evictable filter (no new symbols).

- [ ] **Step 1: Rewrite the pinning test to assert the fixed behavior**

Replace the existing `distinctAdvertisementsGrowTransfersAndPinTheLinkAgainstEviction` in `LinkPlaneTests.swift` with this (same setup, inverted final assertions — the advertiser is now the one evicted):

```swift
@Test @MainActor func stalledAdvertiserIsEvictedNotThePinnedNewcomer() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x63, count: 16)
    let iface = InterfaceID("advertiser")
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: 1)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let session = await activeResponderInPlane(store, owner: owner,
                                               destHash: destHash, interfaceID: iface)

    // Three DISTINCT-hash advertisements, no segment ever sent → three no-parts transfers.
    for i: UInt8 in 1 ... 3 {
        let adv = advertisementPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                      resourceHash: Data(repeating: i, count: 32))
        await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: iface, data: adv))
        await store.receive { if case .link(.element(_, .received)) = $0 { return true }; return false }
    }
    #expect(store.state.links[id: session.id]?.transfers.count == 3)

    // A newcomer completes a full handshake at the cap. Because none of the advertiser's transfers
    // has received a part, the advertiser is now the eviction candidate — it is closed, not the
    // newcomer.
    let newcomer = await acceptAndActivateResponder(store, owner: owner, destHash: destHash,
                                                    iface: InterfaceID("newcomer"))
    await store.receive { action in
        if case let .link(.element(id, .close)) = action { return id == session.id }
        return false
    }
    #expect(store.state.links[id: session.id]?.status != .active
            || store.state.links[id: session.id] == nil,
            "a stalled advertiser must be evicted, not immune")
    #expect(store.state.links[id: newcomer]?.status == .active,
            "the newcomer that paid for a handshake keeps the slot")
}
```

- [ ] **Step 2: Add the immunity-preserved test (genuine transfer is not evicted)**

Add this test. It seeds two active responder links — one whose transfer has received a part (immune), one bare — then promotes a newcomer at a cap of 2, and asserts the bare link is the victim. The seed mirrors the existing `withLink` pattern used in `TransportEndpointTests.swift`.

```swift
@Test @MainActor func aTransferThatReceivedAPartIsNotEvicted() async {
    let iface = InterfaceID("seed")
    // Link A: active responder, holds a transfer that has received a part → immune.
    var linkA = LinkSession.State(id: UUID(1), responderFor: Identity(),
                                  destinationHash: Data(repeating: 0x0A, count: 16), interfaceID: iface)
    linkA.status = .active
    linkA.sessionKey = Data(repeating: 0x01, count: 64)
    linkA.linkID = Data(repeating: 0xAA, count: 16)
    linkA.activatedAt = 10          // older than link B, so a naive LRU would pick A
    var partTransfer = ResourceTransfer.State(receivingOn: linkA.linkID, sessionKey: linkA.sessionKey,
                                              interfaceID: iface, rtt: .seconds(1), id: UUID(101))
    partTransfer.receivedFirstPart = true
    linkA.transfers.append(partTransfer)

    // Link B: active responder, bare (no transfers) → evictable.
    var linkB = LinkSession.State(id: UUID(2), responderFor: Identity(),
                                  destinationHash: Data(repeating: 0x0B, count: 16), interfaceID: iface)
    linkB.status = .active
    linkB.sessionKey = Data(repeating: 0x02, count: 64)
    linkB.linkID = Data(repeating: 0xBB, count: 16)
    linkB.activatedAt = 20

    let owner = Identity()
    let destHash = Data(repeating: 0x63, count: 16)
    let store = TestStore(
        initialState: LinkPlane.State(links: [linkA, linkB], maxResponderLinks: 2)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let newcomer = await acceptAndActivateResponder(store, owner: owner, destHash: destHash,
                                                    iface: InterfaceID("newcomer"))
    await store.receive { action in
        if case let .link(.element(id, .close)) = action { return id == linkB.id }
        return false
    }
    #expect(store.state.links[id: linkA.id]?.status == .active,
            "a link with a part-receiving transfer must stay immune, even as the oldest link")
    #expect(store.state.links[id: newcomer]?.status == .active)
}
```

- [ ] **Step 3: Run both tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter stalledAdvertiserIsEvictedNotThePinnedNewcomer`
Expected: FAIL — currently the advertiser is immune (non-empty transfers), so the newcomer is closed, not `session.id`.
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter aTransferThatReceivedAPartIsNotEvicted`
Expected: PASS already (link A is immune today because its transfers is non-empty). This is a guard test — it must still pass after the change, proving the fix doesn't over-evict.

- [ ] **Step 4: Apply Fix #1 — the filter**

In `LinkPlane.swift`, change the evictable filter (`:322`) from:
```swift
                    .filter { $0.id != elementID && $0.transfers.isEmpty }
```
to:
```swift
                    .filter { $0.id != elementID && $0.transfers.allSatisfy { !$0.receivedFirstPart } }
```
(`allSatisfy` is true for an empty `transfers` — a bare link stays evictable, as before — and true when every transfer is still partless — the stalled advertiser is now evictable — but false once any transfer has received a part — a genuine transfer stays immune.)

- [ ] **Step 5: Update the comment**

Replace the trade-off paragraph in the comment block (`LinkPlane.swift:305-311`, the "Also skip links with in-flight transfers … bounding transfers per link is the real fix." region) with:
```swift
                // Skip links with a transfer that has RECEIVED A PART (`receivedFirstPart`), not
                // merely a non-empty `transfers`. Resource SEGMENT contexts forward raw bytes to
                // `ResourceTransfer` children that decrypt internally, so a link genuinely receiving
                // a large resource never advances `lastData` and would otherwise look idle — the
                // part-receiving transfer is what marks it as busy and protects it mid-transfer.
                // A transfer that was only ADVERTISED (no part yet) confers no immunity: otherwise a
                // peer could advertise a resource it never sends and pin this slot forever (F11).
```

- [ ] **Step 6: Run both tests to verify they pass**

Run each by name. Expected: both PASS.

- [ ] **Step 7: Mutation-verify**

Temporarily change the filter to the old `$0.transfers.isEmpty`. Run `stalledAdvertiserIsEvictedNotThePinnedNewcomer` → FAIL. Then over-broaden it to `true` (evict regardless of transfers): run `aTransferThatReceivedAPartIsNotEvicted` → FAIL. Revert to the correct `allSatisfy { !$0.receivedFirstPart }`. Run both → PASS.

- [ ] **Step 8: Full suite + commit**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA` — all pass except the known issue.
Stage only `Sources/ReTiCANode/LinkPlane.swift` and `Tests/ReTiCANodeTests/LinkPlaneTests.swift`. Commit:
```
fix: F11 — eviction immunity requires a received part, not a bare advertisement

An advertised-but-stalled transfer no longer makes a responder link immune to
eviction; only a transfer that has received a part does. A peer advertising
resources it never sends is now an eviction candidate instead of pinning the
slot. Genuine large transfers stay protected.
```
Verify the trailer parses.

---

### Task 2: Fix #2 — advertisements do not advance the eviction clock

Resource advertisements still authenticate (so re-home is unchanged), but they no longer advance `lastData`, so a stalled re-advertiser sorts as the eviction victim rather than looking recently active.

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — add a `sawGenuineData` flag (`~:413`), a non-genuine decrypt for advertisements, use it in the `.resourceAdvertisement` branch (`~:514`), and gate `lastData` on the new flag (`~:638`).
- Test: `Tests/ReTiCANodeTests/LinkPlaneTests.swift` — add two tests.

**Interfaces:**
- Consumes (existing): `Link.decrypt(_:sessionKey:)`; the local `authDecrypt` helper and `sawAuthenticatedData` var in `LinkSession.received`; `advertisementPacket(...)`, `authenticatedPacket(linkID:sessionKey:body:)`, `activeResponderInPlane(...)` test helpers.
- Produces: unchanged public surface; behavior change to `lastData` only.

- [ ] **Step 1: Write the failing tests**

Add to `LinkPlaneTests.swift`. Test 2a uses a mutable date so "advanced" vs "unchanged" is observable; it asserts an advertisement leaves `lastData` where it was while a genuine data message advances it.

```swift
@Test @MainActor func advertisementDoesNotAdvanceLastDataButGenuineDataDoes() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x71, count: 16)
    let iface = InterfaceID("clock")
    let dateBox = LockIsolated(Date(timeIntervalSince1970: 100))
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: 4)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .init { dateBox.value }
    }
    store.exhaustivity = .off

    let session = await activeResponderInPlane(store, owner: owner,
                                               destHash: destHash, interfaceID: iface)

    // Advance the clock, then deliver an advertisement. lastData must NOT move to this time.
    dateBox.setValue(Date(timeIntervalSince1970: 500))
    let before = store.state.links[id: session.id]?.lastData
    let adv = advertisementPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                  resourceHash: Data(repeating: 0x01, count: 32))
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: iface, data: adv))
    await store.receive { if case .link(.element(_, .received)) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.lastData == before,
            "an advertisement must not advance the eviction clock")

    // Advance again, then deliver genuine application data. lastData MUST move to this time.
    dateBox.setValue(Date(timeIntervalSince1970: 900))
    let data = authenticatedPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                   body: Data([0x01, 0x02]))
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: iface, data: data))
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.lastData == 900,
            "genuine application data must advance the eviction clock")
}
```

Test 2b pins the self-reap (Section 2 of the spec): a no-parts transfer is removed after its watchdog exhausts.

```swift
@Test @MainActor func aStalledTransferSelfReapsAfterItsWatchdogExhausts() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x72, count: 16)
    let iface = InterfaceID("reap")
    let clock = TestClock()
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: 4)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let session = await activeResponderInPlane(store, owner: owner,
                                               destHash: destHash, interfaceID: iface)
    let adv = advertisementPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                  resourceHash: Data(repeating: 0x01, count: 32))
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: iface, data: adv))
    await store.receive { if case .link(.element(_, .received)) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.transfers.count == 1)

    // No segment ever arrives. Advance well past the receiver watchdog's full retry budget
    // (16 retries, each rtt*4 + grace + growing per-retry delay). The transfer must self-reap.
    await clock.advance(by: .seconds(600))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.links[id: session.id]?.transfers.isEmpty == true,
            "a no-parts transfer must be removed after its watchdog exhausts — not held forever")
}
```

- [ ] **Step 2: Run the tests to verify they fail (2a) / characterize (2b)**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter advertisementDoesNotAdvanceLastDataButGenuineDataDoes`
Expected: FAIL — today an advertisement advances `lastData` (the first `#expect` fails).
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter aStalledTransferSelfReapsAfterItsWatchdogExhausts`
Expected: PASS already (this pins existing self-reap behavior). If it FAILS, stop and report — it means the watchdog does not reap a no-parts transfer, which contradicts the spec's Section 2 and must be resolved before proceeding.

- [ ] **Step 3: Apply Fix #2 — the `sawGenuineData` flag**

In `LinkSession.received`, where `sawAuthenticatedData` and `authDecrypt` are defined (`~:413-418`), add a genuine-data flag and an advertisement-only decrypt. Replace:
```swift
                var sawAuthenticatedData = false
                func authDecrypt(_ payload: Data, _ key: Data) -> Data? {
                    guard let plain = Link.decrypt(payload, sessionKey: key) else { return nil }
                    sawAuthenticatedData = true
                    return plain
                }
```
with:
```swift
                var sawAuthenticatedData = false
                // `sawGenuineData` gates ONLY the `lastData` eviction clock (below). It is a strict
                // subset of `sawAuthenticatedData`, which still gates re-home authentication and must
                // stay set for advertisements. Advertisements authenticate but are not genuine use of
                // the slot, so they set `sawAuthenticatedData` but NOT `sawGenuineData` — otherwise a
                // peer advertising resources it never sends would look "recently active" and outrank
                // quiet legitimate peers in the eviction LRU (F11).
                var sawGenuineData = false
                func authDecrypt(_ payload: Data, _ key: Data) -> Data? {
                    guard let plain = Link.decrypt(payload, sessionKey: key) else { return nil }
                    sawAuthenticatedData = true
                    sawGenuineData = true
                    return plain
                }
                func authDecryptAdvertisement(_ payload: Data, _ key: Data) -> Data? {
                    guard let plain = Link.decrypt(payload, sessionKey: key) else { return nil }
                    sawAuthenticatedData = true    // still counts for re-home
                    return plain                   // NOT sawGenuineData → does not advance lastData
                }
```

- [ ] **Step 4: Use the advertisement decrypt in the `.resourceAdvertisement` branch**

In the `.resourceAdvertisement` branch (`~:514`), change the first line from:
```swift
                    guard let plain = authDecrypt(packet.payload, state.sessionKey),
```
to:
```swift
                    guard let plain = authDecryptAdvertisement(packet.payload, state.sessionKey),
```

- [ ] **Step 5: Gate `lastData` on the genuine-data flag**

At the `lastData` update (`~:638`), change:
```swift
                if sawAuthenticatedData { state.lastData = now }
```
to:
```swift
                if sawGenuineData { state.lastData = now }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run each new test by name. Expected: both PASS. `aStalledTransferSelfReapsAfterItsWatchdogExhausts` still passes (no production change to the watchdog).

- [ ] **Step 7: Mutation-verify**

Change the advertisement branch back to `authDecrypt` (so it sets `sawGenuineData`): run `advertisementDoesNotAdvanceLastDataButGenuineDataDoes` → FAIL (advertisement advances lastData). Revert. Then change the `lastData` gate back to `sawAuthenticatedData`: run the same test → FAIL again (advertisement, which still sets sawAuthenticatedData, advances lastData). Revert both. Run → PASS.

- [ ] **Step 8: Full suite + commit**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA` — all pass except the known issue. Re-home tests must stay green (advertisements still set `sawAuthenticatedData`; re-home at `:711` is unchanged). Watch for any test that asserted `lastData` advanced on an advertisement — if one exists and now fails, that test encoded the bug; update it to the new behavior and note it.
Stage only `Sources/ReTiCATransport/LinkSession.swift` and `Tests/ReTiCANodeTests/LinkPlaneTests.swift`. Commit:
```
fix: F11 — resource advertisements no longer advance the eviction clock

An advertisement authenticates (so re-home is unchanged) but is not genuine use
of the link's slot, so it must not advance lastData. Otherwise a re-advertising
peer looks recently active and outranks quiet legitimate peers in the eviction
LRU. lastData now gates on a sawGenuineData flag that advertisements do not set.
```
Verify the trailer parses.

---

## Notes for the executor

- **No per-link cap** — if a step seems to want one, stop; the spec deliberately declines it (reference has none). Transient growth self-reaps (Task 2, test 2b).
- **Accepted residual (do not "fix"):** an attacker who continuously sends *real* parts can still hold a slot like any long transfer — the fix only eliminates the zero-cost pin. Closing that needs a transfer-completion deadline, out of scope.
- **Fix #1 and Fix #2 are separable and independently reviewable**, but both are needed for the full property: #1 makes the advertiser evictable, #2 makes it the one chosen when there are multiple evictable links.
- If `LinkSession.State`'s init parameters or the `activatedAt`/`lastData` field names differ from those quoted here, match the real code and report the drift; do not invent fields.
