# Receiver-Transfer GC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Remove a completed *receiver* `ResourceTransfer` from `LinkSession.transfers` when it emits `.received`, so completed receivers don't accumulate (closing the leak amplified by multi-segment, where an N-segment resource leaves N inert receiver transfers).

**Architecture:** One localized change in `LinkSession`'s `.received` interception — capture the transfer's `advertisement` once, `state.transfers.remove(id: elementID)`, then route (request / response / split / plain) on the captured local. Mirrors the GC slice's existing `remove-on-.concluded/.failed`. Core `ReTiCA`, `ResourceTransfer`, and `Endpoint` are unchanged.

**Tech Stack:** Swift 6, The Composable Architecture (~1.26) — `Reduce`/`.forEach`/`IdentifiedArrayOf.remove(id:)`, `TestStore`/`TestClock`. Confined to `ReTiCATransport`.

## Global Constraints

- **No wire change, no new dependency, no cross-validation.** Pure state hygiene.
- **Capture before remove:** read `advertisement` (and any needed fields) into a local BEFORE `remove(id:)`; the `IdentifiedArray` subscript returns a value copy, so routing is unaffected. Remove ONCE, then branch on the local — every routing branch (request / response / split-buffering-`.none` / split-complete / plain) runs after removal.
- **Removal is safe:** a completed receiver is `.complete` with its watchdog already cancelled (no live effects to orphan) and never re-proves (its inbound guard excludes `.complete`); the proof `.transmit` is a separate child action relayed before `.received` is processed. Do NOT touch the `.transmit` relay case or sender GC.
- **Preserve all existing routing behavior:** the same delegates (`requestReceived`/`responseReceived`/`resourceReceived`) fire with the same values and the same `pendingRequests`/`incomingSegments` mutations; only the transfer element is additionally removed.
- Build gotcha: signal-11/SIGILL during `swift test` → `swift package clean` then retry; never delete State fields to "fix" a crash.
- **Mutation-test discipline** for every new/changed test. **Commit directly to `main`.** Trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCATransport/LinkSession.swift` (**modify**) — the `.received` interception.
- `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift` (**modify**) — plain + split removal tests.
- `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift` (**modify**, if large req/resp resource receive is tested there) — large request/response resource removal.
- `Tests/ReTiCANodeTests/EndpointTests.swift` (**modify**) — augment the existing multi-segment E2E with a `transfers.isEmpty` assertion.
- `README.md` (**modify**) — note receiver-transfer GC.

---

### Task 1: Remove completed receiver transfers on `.received`

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`, `Tests/ReTiCANodeTests/EndpointTests.swift` (+ `LinkSessionRequestTests.swift` if it exercises large req/resp resource receives)
- Modify: `README.md`

**Interfaces:**
- Consumes: the existing `.transfer(.element(_, .delegate(.received(payload))))` interception + `state.transfers` (`IdentifiedArrayOf<ResourceTransfer.State>`).
- Produces: a completed receiver transfer is removed from `state.transfers`; all delegate surfacing is unchanged.

- [ ] **Step 1: Write the failing test(s)**

Append to `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`. Reuse the file's existing helpers that inject a receiver transfer with an advertisement (the inbound-ADV tests, and the split-receiver helper from the multi-segment slice). Fire a receiver transfer's `.received` and assert it's gone from `state.transfers`.

```swift
@Test @MainActor func completedPlainReceiverIsRemovedFromTransfers() async {
    let clock = TestClock<Duration>()
    // Host one plain (non-split, non-req/resp) receiver transfer with an advertisement.
    let (store, tid) = activeLinkHostingPlainReceiver(clock)   // helper: see note
    store.exhaustivity = .off
    await store.send(.transfer(.element(id: tid, action: .delegate(.received(Data("payload".utf8))))))
    await store.receive { if case .delegate(.resourceReceived(Data("payload".utf8))) = $0 { return true }; return false }
    #expect(store.state.transfers[id: tid] == nil)             // GC'd
}

@Test @MainActor func completedSplitSegmentReceiversAreRemovedAsTheyArrive() async {
    let clock = TestClock<Duration>()
    let oh = Data(repeating: 0x11, count: 32)
    let seg1 = Data("hello ".utf8), seg2 = Data("world".utf8)
    let store = resourceStoreHostingSplitReceivers(oh: oh, total: 2, clock)   // existing helper (multi-seg slice)
    let (id1, id2) = (store.state.transfers[0].id, store.state.transfers[1].id)
    store.exhaustivity = .off
    await store.send(.transfer(.element(id: id1, action: .delegate(.received(seg1)))))
    #expect(store.state.transfers[id: id1] == nil)             // segment 1 receiver GC'd (payload buffered)
    #expect(store.state.incomingSegments[oh]?.parts.count == 1)
    await store.send(.transfer(.element(id: id2, action: .delegate(.received(seg2)))))
    await store.receive { if case let .delegate(.resourceReceived(d)) = $0 { return d == seg1 + seg2 }; return false }
    #expect(store.state.transfers[id: id2] == nil)             // segment 2 receiver GC'd
    #expect(store.state.transfers.isEmpty)                     // no inert receivers left
}
```

> Implementer note: build/reuse the helpers to match the file's real injection idiom. `activeLinkHostingPlainReceiver` produces an active-link store hosting ONE receiver `ResourceTransfer.State` whose stored `advertisement` is plain (NOT request/response/split — flags `0x01`), returning `(store, transferID)`; mirror how the file's inbound-ADV tests place a receiver transfer + advertisement into state (or drive an inbound ADV to spawn one, then capture its id). `resourceStoreHostingSplitReceivers` already exists from the multi-segment slice. If `LinkSessionRequestTests.swift` has a helper that drives a large request/response RESOURCE to completion (receiver side), add analogous `#expect(store.state.transfers[id:] == nil)` assertions there for `requestReceived`/`responseReceived` completions; if large req/resp resource RECEIVE isn't unit-tested at the LinkSession level, note that and rely on the plain + split coverage (the removal code path is shared). The REQUIRED assertions (do NOT weaken): after `.received`, the receiver transfer is `== nil` in `state.transfers`, AND the correct delegate (`resourceReceived`/`requestReceived`/`responseReceived`) still surfaces with the same value.

Run: `swift test --filter completedPlainReceiverIsRemovedFromTransfers` → FAIL (not removed today).

- [ ] **Step 2: Make the change**

In `Sources/ReTiCATransport/LinkSession.swift`, replace the `.received` interception (currently captures `adv` at the top, reads `advertisement` AGAIN as `advR` for the split branch, and never removes the element) with a capture-once / remove-once / branch version:

```swift
            case let .transfer(.element(elementID, .delegate(.received(payload)))):
                let adv = state.transfers[id: elementID]?.advertisement
                state.transfers.remove(id: elementID)          // GC the completed receiver
                if adv?.isRequest == true {
                    guard case let .array(items)? = MsgPack.decodeValue(payload), items.count == 3,
                          case let .bin(pathHash) = items[1], case let .bin(data) = items[2] else { return .none }
                    return .send(.delegate(.requestReceived(requestID: Crypto.truncatedHash(payload),
                                                            pathHash: pathHash, data: data)))
                } else if adv?.isResponse == true {
                    guard case let .array(items)? = MsgPack.decodeValue(payload), items.count == 2,
                          case let .bin(rid) = items[0], case let .bin(data) = items[1],
                          state.pendingRequests.contains(rid) else { return .none }
                    state.pendingRequests.remove(rid)
                    return .merge(.cancel(id: CancelID.request(rid)),
                                  .send(.delegate(.responseReceived(requestID: rid, data: data))))
                }
                if adv?.isSplit == true, let a = adv {
                    var acc = state.incomingSegments[a.originalHash] ?? State.SegmentAccumulator(total: a.totalSegments, parts: [:])
                    acc.parts[a.segmentIndex] = payload
                    if UInt64(acc.parts.count) == acc.total {
                        state.incomingSegments[a.originalHash] = nil
                        var whole = Data()
                        for i in 1...acc.total { whole.append(acc.parts[i] ?? Data()) }
                        return .send(.delegate(.resourceReceived(whole)))
                    }
                    state.incomingSegments[a.originalHash] = acc
                    return .none
                }
                return .send(.delegate(.resourceReceived(payload)))
```

(The only substantive change vs. the current code: `state.transfers.remove(id: elementID)` after capturing `adv`, and the split branch reads the already-captured `adv` instead of re-reading `state.transfers[id: elementID]?.advertisement` — which would now be nil. Routing logic, delegates, and `pendingRequests`/`incomingSegments` mutations are byte-for-byte identical.)

- [ ] **Step 3: Run to verify** — `swift test --filter LinkSessionResource` → the new tests + all existing resource tests pass. Also run `swift test --filter LinkSessionRequest` (large req/resp still surface correctly) and confirm no existing test asserted a completed receiver still PRESENT in `state.transfers` (if one did, update it to expect removal — do not weaken).

- [ ] **Step 4: Augment the multi-segment E2E**

In `Tests/ReTiCANodeTests/EndpointTests.swift`, in `twoEndpointsTransferMultiSegmentResourceOverALink` (the 2-segment round-trip), after B surfaces the final `resourceReceived` and `got.value == payload` is asserted, add: assert B's link has no lingering receiver transfers — e.g. `#expect(b.state.links[0].transfers.isEmpty)` (adapt to how the test references B's link). This directly asserts the leak is closed end-to-end. Do NOT weaken the existing `got.value == payload` assertion.

> Implementer note: confirm the exact way the test accesses B's `LinkSession` (index/id into `b.state.links`) and that by the assertion point both segment receivers have completed. If a sender transfer is momentarily present (unlikely at that point), scope the assertion to receiver-role transfers (`b.state.links[0].transfers.filter { $0.role == .receiver }.isEmpty`). The REQUIRED assertion: no completed receiver transfer lingers after the multi-segment receive.

- [ ] **Step 5: Run** — `swift test --filter Endpoint` → PASS (the multi-segment E2E now also asserts empty transfers). Then full-suite gate: `swift test` → PASS; report pass/skip counts.

- [ ] **Step 6: Mutation sweep**

Apply each, run the named filter, confirm the named test fails, revert; final full `swift test` green:
- Remove `state.transfers.remove(id: elementID)` from the `.received` case → `completedPlainReceiverIsRemovedFromTransfers` and `completedSplitSegmentReceiversAreRemovedAsTheyArrive` fail (`filter LinkSessionResource`), and the E2E `transfers.isEmpty` fails (`filter Endpoint`).
- In `completedSplitSegmentReceiversAreRemovedAsTheyArrive`, this also guards ordering: confirm the plain/split delegates still fire (so the mutation fails on the `== nil` assertion, not on a routing break — proving removal is additive, not a regression).

- [ ] **Step 7: Commit (source + tests)**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionResourceTests.swift Tests/ReTiCANodeTests/EndpointTests.swift
git commit -F /tmp/ReTiCA/commit-rgc1.txt
```
(If you added assertions to `LinkSessionRequestTests.swift`, include it in the `git add`.)
(First line: `feat: GC completed receiver transfers from LinkSession on .received`, blank line, trailers.)

- [ ] **Step 8: Update the README**

In `README.md`, near the resource/GC wording, note that BOTH sender and receiver resource transfers are now removed from a link's collection on completion (senders on proof-validated/failed, receivers on assembly-complete), so terminal transfers — including every segment of a multi-segment resource — do not accumulate.

- [ ] **Step 9: Commit (README)**

```
git add README.md
git commit -F /tmp/ReTiCA/commit-rgc2.txt
```
(First line: `docs: receiver-transfer GC`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- Remove completed receiver transfers on `.received`, for plain / request / response / split → Task 1 Step 2 (capture-remove-branch covers all routing branches). ✓
- Multi-segment leak closed end-to-end → Task 1 Step 4 (E2E `transfers.isEmpty`). ✓
- All existing delegate surfacing preserved (removal after routing) → Task 1 Steps 2-3. ✓
- No wire/core/`Endpoint`/sender change; no cross-val → Global Constraints. ✓

**Placeholder scan:** No TBD/TODO in production steps. The test-helper notes (`activeLinkHostingPlainReceiver`, the large-req/resp coverage conditionality, the E2E B-link access) are explicit implementer guidance (reuse the file's real injection idioms) with the assertions locked — not missing implementation.

**Type consistency:** `state.transfers.remove(id: elementID)`, `adv?.isRequest/.isResponse/.isSplit`, `State.SegmentAccumulator`, `state.incomingSegments[originalHash]`, and the unchanged `requestReceived`/`responseReceived`/`resourceReceived` delegates are used identically to the surrounding `.concluded`/`.failed` interceptions (which already capture-then-remove). The `.transmit` relay case and sender GC are untouched.
