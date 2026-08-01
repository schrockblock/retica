# LXMF Propagation P3a — PropagationNode Two-Phase Serve Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend the decoupled `PropagationNode` reducer to answer the RNS `/get` two-phase download: phase-1 lists a client's transient_ids; phase-2 serves the wanted blobs and purges the client's haves.

**Architecture:** Pure reducer logic over the existing `PropagationStore`. Add a phase-1 `messageListRequested` action + `deliverMessageList` delegate; extend `messagesRequested` with `wants`/`haves`. No `Endpoint`/core changes; the server composition is P3b.

**Tech Stack:** Swift, Point-Free Composable Architecture (TCA), Swift Testing (`@Test`/`#expect`), `swift test`.

## Global Constraints

- **Commit directly to `main`** — no feature branch, no merge dance.
- **No compound shell commands** — one command per invocation; no `&&`/`||`/`;`/`|`-chains/`xargs`/inline interpreter scripts. A single `>` redirect is allowed. Write files with the editor, not echo/heredoc.
- **Temp files** go in `/tmp/ReTiCA/`.
- **Commit trailers, verbatim**, via `git commit -F <file>` (never `-m`, the trailers contain `;`):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
- **Three-step mutation verification** for every new/changed test: run pass → mutate production to force fail + confirm → revert + confirm pass. One mutation at a time.
- **Non-exhaustive TCA tests** (`store.exhaustivity = .off`), asserting outcomes.
- **Scope:** the two-phase serve on `PropagationNode` only. Do NOT add the Endpoint composition, IDENTIFY, announce, the `/get` handler, or transfer-limit/`max_messages` capping.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: PropagationNode two-phase serve

Add the phase-1 list action/delegate and extend the phase-2 serve with `wants`/`haves`.

**Files:**
- Modify: `Sources/ReTiCANode/PropagationNode.swift`
- Test: `Tests/ReTiCANodeTests/PropagationNodeTests.swift`

**Interfaces:**
- Consumes: `PropagationStore.entries(forDestination:) -> [Entry]` (`Entry.transientId`, `.lxmfData`, sorted by sequence), `PropagationStore.remove(transientId:)`, `PropagationStore.contains(transientId:)`.
- Produces (for P3b): `PropagationNode.Action.messageListRequested(destinationHash: Data)`, `PropagationNode.Action.messagesRequested(destinationHash: Data, wants: [Data], haves: [Data])` (extended), `PropagationNode.Action.Delegate.deliverMessageList(destinationHash: Data, transientIds: [Data])`.

- [ ] **Step 1: Extend `messagesRequested` and add `messageListRequested`.**

In `PropagationNode.Action`, replace:
```swift
        case messagesRequested(destinationHash: Data)
```
with:
```swift
        case messagesRequested(destinationHash: Data, wants: [Data], haves: [Data])
        case messageListRequested(destinationHash: Data)
```

- [ ] **Step 2: Add the `deliverMessageList` delegate.**

In `Action.Delegate`, immediately after `case deliverMessages(destinationHash: Data, entries: [Data])`, add:
```swift
            case deliverMessageList(destinationHash: Data, transientIds: [Data])
```

- [ ] **Step 3: Rewrite the `messagesRequested` handler and add `messageListRequested`.**

Replace the existing handler:
```swift
            case let .messagesRequested(destinationHash):
                let entries = state.store.entries(forDestination: destinationHash).map(\.lxmfData)
                return .send(.delegate(.deliverMessages(destinationHash: destinationHash, entries: entries)))
```
with:
```swift
            case let .messagesRequested(destinationHash, wants, haves):
                for tid in haves { state.store.remove(transientId: tid) }          // purge what the client already has
                let wantSet = Set(wants)
                let entries = state.store.entries(forDestination: destinationHash)
                    .filter { wantSet.contains($0.transientId) }
                    .map(\.lxmfData)
                return .send(.delegate(.deliverMessages(destinationHash: destinationHash, entries: entries)))

            case let .messageListRequested(destinationHash):
                let ids = state.store.entries(forDestination: destinationHash).map(\.transientId)
                return .send(.delegate(.deliverMessageList(destinationHash: destinationHash, transientIds: ids)))
```

- [ ] **Step 4: Update the 3 existing `messagesRequested` call sites.**

In `Tests/ReTiCANodeTests/PropagationNodeTests.swift`:

- `propagationNodeServesByDestination` (serves A's two entries): change
  ```swift
      await store.send(.messagesRequested(destinationHash: destA))
  ```
  to
  ```swift
      let tidA1 = LXMFPropagation.transientId(lxmfData: a1)
      let tidA2 = LXMFPropagation.transientId(lxmfData: a2)
      await store.send(.messagesRequested(destinationHash: destA, wants: [tidA1, tidA2], haves: []))
  ```
  (The `#expect(entries == [a1, a2])` assertion is unchanged — both are wanted, served oldest-first.)

- `propagationNodeServesEmptyWhenNoneAddressed`: change
  ```swift
      await store.send(.messagesRequested(destinationHash: dest))
  ```
  to
  ```swift
      await store.send(.messagesRequested(destinationHash: dest, wants: [], haves: []))
  ```
  (Assertion `entries.isEmpty` unchanged.)

- `propagationNodeDropsDeliveredMessages`: change
  ```swift
      await store.send(.messagesRequested(destinationHash: destA))
  ```
  to
  ```swift
      await store.send(.messagesRequested(destinationHash: destA, wants: [tid], haves: []))
  ```
  (`tid` is already bound in that test; assertion `entries.isEmpty` unchanged — it was removed by the prior `messagesDelivered`.)

- [ ] **Step 5: Run the updated existing tests; confirm green.**

Run: `swift test --filter propagationNodeServesByDestination`
Then: `swift test --filter propagationNodeServesEmptyWhenNoneAddressed`
Then: `swift test --filter propagationNodeDropsDeliveredMessages`
Expected: all PASS.

- [ ] **Step 6: Write the new two-phase tests.**

Append to `Tests/ReTiCANodeTests/PropagationNodeTests.swift` (reuse the file's existing `entry(dest:tail:)` and `container([...])` helpers and `LXMessage.destinationLength`):

```swift
// MARK: - P3a two-phase serve (/get)

/// Phase-1: messageListRequested returns only the destination's transient_ids, oldest-first.
@Test @MainActor func propagationNodeListsTransientIdsByDestination() async {
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let b1 = entry(dest: 0xBB, tail: "b1")
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, b1, a2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    await store.send(.messageListRequested(destinationHash: destA))
    await store.receive { action in
        if case let .delegate(.deliverMessageList(dest, ids)) = action {
            #expect(dest == destA)
            #expect(ids == [LXMFPropagation.transientId(lxmfData: a1),
                            LXMFPropagation.transientId(lxmfData: a2)])   // A's only, oldest-first
            return true
        }
        return false
    }
}

/// Phase-2: only the WANTED subset is served; an unwanted entry for the same destination is withheld.
@Test @MainActor func propagationNodeServesOnlyWantedSubset() async {
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, a2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    await store.send(.messagesRequested(destinationHash: destA,
                                        wants: [LXMFPropagation.transientId(lxmfData: a1)], haves: []))
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action { #expect(entries == [a1]); return true }
        return false
    }
}

/// Phase-2: haves are purged from the store (client already has them).
@Test @MainActor func propagationNodePurgesHaves() async {
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let tidA1 = LXMFPropagation.transientId(lxmfData: a1)
    let tidA2 = LXMFPropagation.transientId(lxmfData: a2)
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, a2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    await store.send(.messagesRequested(destinationHash: destA, wants: [tidA2], haves: [tidA1]))
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action { #expect(entries == [a2]); return true }
        return false
    }
    #expect(store.state.store.contains(transientId: tidA1) == false)   // have purged
    #expect(store.state.store.contains(transientId: tidA2) == true)    // still stored (served, not delivered-acked)
}

/// Phase-2: a want for a foreign-destination or absent id is silently skipped.
@Test @MainActor func propagationNodeSkipsForeignOrAbsentWants() async {
    let a1 = entry(dest: 0xAA, tail: "a1")
    let b1 = entry(dest: 0xBB, tail: "b1")
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, b1])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    await store.send(.messagesRequested(destinationHash: destA,
                                        wants: [LXMFPropagation.transientId(lxmfData: b1),      // wrong dest
                                                Data(repeating: 0x99, count: 32)], haves: []))   // absent
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action { #expect(entries.isEmpty); return true }
        return false
    }
}
```

- [ ] **Step 7: Run the new tests; confirm green.**

Run: `swift test --filter propagationNode`
Expected: all PASS (new + updated existing).

- [ ] **Step 8: Mutation-verify (one at a time, revert between each).**

- Mutation A — drop the purge: in the `messagesRequested` handler, delete the `for tid in haves { state.store.remove(transientId: tid) }` line. Run `swift test --filter propagationNodePurgesHaves` → must FAIL (`contains(tidA1)` still true). Revert → PASS.
- Mutation B — invert the wants filter: change `wantSet.contains($0.transientId)` to `!wantSet.contains($0.transientId)`. Run `swift test --filter propagationNodeServesOnlyWantedSubset` → must FAIL (serves `[a2]` instead of `[a1]`). Revert → PASS.
- Mutation C — break phase-1: in `messageListRequested`, map `\.lxmfData` instead of `\.transientId`. Run `swift test --filter propagationNodeListsTransientIdsByDestination` → must FAIL (ids != transient_ids). Revert → PASS.

- [ ] **Step 9: Run the full ReTiCANode suite; confirm no regressions.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 10: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-p3a-task1.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCANode/PropagationNode.swift Tests/ReTiCANodeTests/PropagationNodeTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p3a-task1.txt
```

Suggested subject: `feat: LXMF propagation P3a — PropagationNode two-phase serve`

---

## Self-Review

**Spec coverage:**
- Phase-1 `messageListRequested` → `deliverMessageList` → Task 1 Steps 1-3, test 6.1. ✅
- Phase-2 `messagesRequested(wants, haves)`: purge haves + serve wanted subset → Steps 1, 3, tests 6.2-6.4. ✅
- Foreign/absent want skipped → Step 3 (`wantSet.contains` + dest filter), test 6.4. ✅
- 3 existing call sites updated → Step 4. ✅
- No Endpoint / IDENTIFY / announce / handler / transfer-limit → absent by construction; Global Constraints call it out. ✅

**Placeholder scan:** none — all steps carry concrete code or exact commands.

**Type consistency:** `messagesRequested(destinationHash: Data, wants: [Data], haves: [Data])`, `messageListRequested(destinationHash: Data)`, `deliverMessageList(destinationHash: Data, transientIds: [Data])`, `store.entries(forDestination:)`/`.transientId`/`.lxmfData`, `store.remove(transientId:)`, `store.contains(transientId:)`, `LXMFPropagation.transientId(lxmfData:)` all match the current `PropagationNode.swift`/`PropagationStore.swift` surfaces. New tests reuse the file's `entry`/`container` helpers.
