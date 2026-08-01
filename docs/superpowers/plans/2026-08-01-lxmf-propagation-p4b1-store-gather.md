# LXMF Propagation P4b-1 — PropagationStore Gather-by-Transient-Id Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a pure `PropagationStore` query that returns the entries for a set of transient-ids, so the mesh initiator (P4b-2) can gather a peer's wanted messages to build the transfer container.

**Architecture:** One method on `PropagationStore` (core), mirroring `entries(forDestination:)`. No reducer/composition/transport.

**Tech Stack:** Swift, Swift Testing (`@Test`/`#expect`), `swift test`.

## Global Constraints

- **Commit directly to `main`** — no feature branch, no merge dance.
- **No compound shell commands** — one command per invocation; no `&&`/`||`/`;`/`|`-chains/`xargs`/inline interpreter scripts. A single `>` redirect is allowed. Write files with the editor, not echo/heredoc.
- **Temp files** go in `/tmp/ReTiCA/`.
- **Commit trailers, verbatim**, via `git commit -F <file>` (never `-m`, the trailers contain `;`):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
- **Three-step mutation verification** for the new test: run pass → mutate production to force fail + confirm → revert + confirm pass. One mutation at a time.
- **Scope:** the one store query only. Do NOT add the `PNNode` initiator, offer/response, transfer, per-peer tracking, or transfer-limit filtering.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: PropagationStore.entries(forTransientIds:)

**Files:**
- Modify: `Sources/ReTiCA/LXMF/PropagationStore.swift`
- Test: `Tests/ReTiCATests/PropagationStoreTests.swift`

**Interfaces:**
- Consumes: the internal `stored: [Data: Entry]` dict; `Entry` (`.transientId`, `.lxmfData`).
- Produces (for P4b-2): `PropagationStore.entries(forTransientIds: [Data]) -> [Entry]`.

- [ ] **Step 1: Add the method.**

In `Sources/ReTiCA/LXMF/PropagationStore.swift`, immediately after the existing `entries(forDestination:)` method (the block ending `.sorted { $0.sequence < $1.sequence }`), add:

```swift
    /// The entries this store holds for a set of transient_ids — used to build a peer-sync transfer of the
    /// messages a peer requested (`/offer` wanted list). Preserves the requested order; silently skips ids
    /// not present (a peer may want an id we have since evicted).
    public func entries(forTransientIds ids: [Data]) -> [Entry] {
        ids.compactMap { stored[$0] }
    }
```

- [ ] **Step 2: Write the failing test.**

Append to `Tests/ReTiCATests/PropagationStoreTests.swift` (reuse the file's existing entry/container helpers and imports; if the file builds `lxmfData` inline, mirror that). The test ingests three entries, then gathers a reordered subset with one absent id:

```swift
@Test func propagationStoreGathersEntriesByTransientIdInOrder() {
    // Three distinct entries addressed to any destinations.
    let d1 = LXMFPropagation.lxmfData(destinationHash: Data(repeating: 0xA1, count: LXMessage.destinationLength),
                                      encryptedData: Data("one".utf8))
    let d2 = LXMFPropagation.lxmfData(destinationHash: Data(repeating: 0xA2, count: LXMessage.destinationLength),
                                      encryptedData: Data("two".utf8))
    let d3 = LXMFPropagation.lxmfData(destinationHash: Data(repeating: 0xA3, count: LXMessage.destinationLength),
                                      encryptedData: Data("three".utf8))
    let tid1 = LXMFPropagation.transientId(lxmfData: d1)
    let tid2 = LXMFPropagation.transientId(lxmfData: d2)
    let tid3 = LXMFPropagation.transientId(lxmfData: d3)
    let absent = Data(repeating: 0xFF, count: 32)

    var store = PropagationStore()
    _ = store.ingest(container: LXMFPropagation.container(timestamp: 1700000000.5, entries: [d1, d2, d3]))

    // Requested order [tid3, absent, tid1] → [d3, d1]: order preserved, absent skipped, tid2 excluded.
    let got = store.entries(forTransientIds: [tid3, absent, tid1]).map(\.lxmfData)
    #expect(got == [d3, d1])
    #expect(store.entries(forTransientIds: []).isEmpty)
}
```

(If the store's `Entry`/`transientId` or the `LXMFPropagation.lxmfData`/`container`/`transientId` helpers differ from the above, adjust to the actual APIs — the assertion `got == [d3, d1]` is load-bearing and must hold: requested order, absent skipped, unrequested excluded.)

- [ ] **Step 3: Run the test; confirm it passes.**

Run: `swift test --filter propagationStoreGathersEntriesByTransientIdInOrder`
Expected: PASS. (If it stale-links, run `swift package clean` first.)

- [ ] **Step 4: Mutation-verify (one at a time, revert between each).**

- Mutation A — ignore the order/filter: replace the body with `return Array(stored.values)`. Run the Step 3 filter → must FAIL (wrong set and order — includes d2, not in `[d3, d1]` order). Revert → PASS.
- Mutation B — wrong order: replace with `return ids.compactMap { stored[$0] }.sorted { $0.sequence < $1.sequence }`. Run → must FAIL (returns `[d1, d3]` in sequence order, not the requested `[d3, d1]`). Revert → PASS.

- [ ] **Step 5: Run the full ReTiCA store suite; confirm no regressions.**

Run: `swift test --filter PropagationStore`
Expected: all PASS.

- [ ] **Step 6: Commit.**

Write the message to `/tmp/ReTiCA/commit-msg-p4b1-task1.txt` (verbatim trailers), then:

```bash
git add Sources/ReTiCA/LXMF/PropagationStore.swift Tests/ReTiCATests/PropagationStoreTests.swift
git commit -F /tmp/ReTiCA/commit-msg-p4b1-task1.txt
```

Suggested subject: `feat: LXMF propagation P4b-1 — PropagationStore.entries(forTransientIds:)`

---

## Self-Review

**Spec coverage:**
- `entries(forTransientIds:)` order-preserving + skips absent → Task 1 Step 1. ✅
- Unit test: reordered subset with an absent id + empty input → Step 2. ✅
- No initiator / offer / transfer / limit → absent by construction; Global Constraints call it out. ✅

**Placeholder scan:** none — concrete code + commands. The test notes "adjust to actual APIs" only as a guard against helper-name drift; the load-bearing assertion is fixed.

**Type consistency:** `entries(forTransientIds: [Data]) -> [Entry]` mirrors `entries(forDestination:)`; `Entry.lxmfData`, `LXMFPropagation.lxmfData(destinationHash:encryptedData:)`, `.container(timestamp:entries:)`, `.transientId(lxmfData:)`, `PropagationStore.ingest(container:)`, `LXMessage.destinationLength` all match the current sources.
