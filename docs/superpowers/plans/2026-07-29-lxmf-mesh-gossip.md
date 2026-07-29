# LXMF-4d-5: Mesh Gossip Primitive Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Extend `PropagationStore` with the PN↔PN gossip dedup primitive: the offer set (`transientIds`) and the missing-ids computation (`wanted(fromOffered:)`).

**Architecture:** Pure extension of `PropagationStore` (4d-3) — no new type, no TCA, no networking. Reuses `contains` and the entries' insertion `sequence`.

**Tech Stack:** Swift, SwiftPM, swift-testing (`@Test`).

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: `transientIds` + `wanted(fromOffered:)` on `PropagationStore`

**Files:**
- Modify: `Sources/ReTiCA/LXMF/PropagationStore.swift` (add an extension or two methods)
- Modify (add tests): `Tests/ReTiCATests/PropagationStoreTests.swift` (append)

**Interfaces:**
- Consumes (existing): `PropagationStore.contains(transientId:)`, the private `stored` dict + `Entry.sequence`/`.transientId`, `ingest`, plus the test helpers `entry(dest:tail:)` / `container(_:)` and `LXMFPropagation.transientId(lxmfData:)`.
- Produces: `PropagationStore.transientIds: [Data]`, `PropagationStore.wanted(fromOffered:) -> [Data]`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCATests/PropagationStoreTests.swift` (the `entry`/`container` helpers from 4d-3 are already in this file):

```swift
@Test func propagationStoreOffersAllTransientIdsOldestFirst() throws {
    var store = PropagationStore()
    let e1 = entry(dest: 0xAA, tail: "e1"), e2 = entry(dest: 0xAA, tail: "e2"), e3 = entry(dest: 0xBB, tail: "e3")
    store.ingest(container: container([e1, e2, e3]))
    #expect(store.transientIds == [e1, e2, e3].map { LXMFPropagation.transientId(lxmfData: $0) })
}

@Test func propagationStoreWantedReturnsMissingInOfferedOrder() throws {
    var store = PropagationStore()
    let e1 = entry(dest: 0xAA, tail: "e1"), e2 = entry(dest: 0xAA, tail: "e2")
    let x = entry(dest: 0xAA, tail: "xx"), y = entry(dest: 0xAA, tail: "yy")
    store.ingest(container: container([e1, e2]))
    let offered = [e1, e2, x, y].map { LXMFPropagation.transientId(lxmfData: $0) }
    #expect(store.wanted(fromOffered: offered) == [x, y].map { LXMFPropagation.transientId(lxmfData: $0) })
}

@Test func propagationStoreWantedDedupsWithinOffer() throws {
    let store = PropagationStore()   // empty
    let x = entry(dest: 0xAA, tail: "xx"), y = entry(dest: 0xAA, tail: "yy")
    let tx = LXMFPropagation.transientId(lxmfData: x), ty = LXMFPropagation.transientId(lxmfData: y)
    #expect(store.wanted(fromOffered: [tx, tx, ty]) == [tx, ty])
}

@Test func propagationStoreWantedEmptyWhenAllPresent() throws {
    var store = PropagationStore()
    let e1 = entry(dest: 0xAA, tail: "e1"), e2 = entry(dest: 0xAA, tail: "e2")
    store.ingest(container: container([e1, e2]))
    let offered = [e1, e2].map { LXMFPropagation.transientId(lxmfData: $0) }
    #expect(store.wanted(fromOffered: offered).isEmpty)
}
```

- [ ] **Step 2: Run them — verify they fail**

Run: `swift test --filter PropagationStoreTests`
Expected: BUILD FAILURE — `transientIds` / `wanted(fromOffered:)` don't exist yet. Expected red.

- [ ] **Step 3: Implement the primitives**

In `Sources/ReTiCA/LXMF/PropagationStore.swift`, add (inside the type, or as an extension in the same file):

```swift
    /// All stored transient_ids, oldest-first — a propagation node's "offer" set to a peer.
    public var transientIds: [Data] {
        stored.values.sorted { $0.sequence < $1.sequence }.map { $0.transientId }
    }

    /// Of a peer's offered transient_ids, the ones this store is missing (and would pull). Preserves the
    /// offered order and de-duplicates repeated ids within the offer. Mirrors LXMRouter.offer_request
    /// wanted_ids — the dedup heart of PN↔PN gossip (convergence rests on transient_id, LXMF-4d-1).
    public func wanted(fromOffered offered: [Data]) -> [Data] {
        var seen = Set<Data>()
        return offered.filter { !contains(transientId: $0) && seen.insert($0).inserted }
    }
```

- [ ] **Step 4: Run them — verify they pass**

Run: `swift test --filter PropagationStoreTests`
Expected: PASS (the 4d-3 tests plus the 4 new ones).

- [ ] **Step 5: Mutation verification (one mutation at a time)**

Apply each individually in `Sources/ReTiCA/LXMF/PropagationStore.swift`, run `swift test --filter PropagationStoreTests`, confirm the named test fails, revert, confirm pass, then the next.

1. **transientIds not ordered** — in `transientIds`, drop the `.sorted { $0.sequence < $1.sequence }` (map `stored.values` directly).
   → `propagationStoreOffersAllTransientIdsOldestFirst` FAILS (dictionary order ≠ insertion order for the fixed 3-entry input). *(If a run happens to match by chance, the assertion is order-exact, so re-running with the mutation still shows the discrepancy; treat any pass as a non-biting test and fix.)*
2. **wanted filter inverted** — change `!contains(transientId: $0)` to `contains(transientId: $0)`.
   → `propagationStoreWantedReturnsMissingInOfferedOrder` FAILS (returns the present ids instead of the missing) and `propagationStoreWantedEmptyWhenAllPresent` FAILS (returns all instead of none).
3. **wanted dedup removed** — change the filter to `!contains(transientId: $0)` only (drop the `&& seen.insert($0).inserted`).
   → `propagationStoreWantedDedupsWithinOffer` FAILS (returns `[tx, tx, ty]`).

After each: revert, re-run, expect PASS before the next.

- [ ] **Step 6: Full test gate**

Run: `swift test`
Expected: PASS. The 4d-4 baseline was 446 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 4 tests → 450 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 7: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-4d5.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCA/LXMF/PropagationStore.swift Tests/ReTiCATests/PropagationStoreTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4d5.txt
```

Commit message body:

```
feat: LXMF-4d-5 — mesh gossip primitive

Extends PropagationStore with transientIds (offer set, oldest-first) and
wanted(fromOffered:) (offered ids the store lacks, deduped, offered-
order) — the dedup heart of PN↔PN gossip (LXMRouter offer_request
wanted_ids). Completes the pure/core substance of LXMF-4d propagation;
peer registry, sync-over-link wiring, and peering-key PoW remain (needs a
PN component + LXMF-5). 4 unit tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec `transientIds` (oldest-first offer set) → Step 3. ✓
- Spec `wanted(fromOffered:)` (missing, offered-order, deduped) → Step 3. ✓
- Spec test 1 (transientIds oldest-first) → `propagationStoreOffersAllTransientIdsOldestFirst`. ✓
- Spec test 2 (wanted missing, offered-order) → `propagationStoreWantedReturnsMissingInOfferedOrder`. ✓
- Spec test 3 (wanted dedups) → `propagationStoreWantedDedupsWithinOffer`. ✓
- Spec test 4 (wanted empty when all present) → `propagationStoreWantedEmptyWhenAllPresent`. ✓

**Placeholder scan:** none.

**Type consistency:** `transientIds: [Data]` and `wanted(fromOffered:) -> [Data]` match the test call sites; both use the existing `stored`/`Entry.sequence`/`contains`. The tests reuse the 4d-3 `entry`/`container` helpers already in `PropagationStoreTests.swift` and `LXMFPropagation.transientId`.
