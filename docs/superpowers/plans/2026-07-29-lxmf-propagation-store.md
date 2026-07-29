# LXMF-4d-3: Propagation Node Message Store Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure `PropagationStore` value type — ingest propagation containers, dedup by `transient_id`, evict under a storage limit, and query entries by recipient.

**Architecture:** New zero-dep pure type `Sources/ReTiCA/LXMF/PropagationStore.swift` (depends only on `LXMFPropagation` + `LXMessage.destinationLength`). Unit-tested; no cross-val (wire/`transient_id` pinned in 4d-1).

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

### Task 1: `PropagationStore` pure type + unit tests

**Files:**
- Create: `Sources/ReTiCA/LXMF/PropagationStore.swift`
- Create: `Tests/ReTiCATests/PropagationStoreTests.swift`

**Interfaces:**
- Consumes (existing): `LXMFPropagation.parseContainer(_:) -> (timestamp: Double, entries: [Data])?`, `.transientId(lxmfData:) -> Data`, `.destinationHash(lxmfData:) -> Data?`, `.container(timestamp:entries:) -> Data`; `LXMessage.destinationLength` (== 16).
- Produces: `PropagationStore` with `init(storageLimitBytes:)`, `mutating func ingest(container:) -> [Data]`, `contains(transientId:) -> Bool`, `var count: Int`, `var sizeBytes: Int`, `entries(forDestination:) -> [PropagationStore.Entry]`, `mutating func remove(transientId:)`; nested `PropagationStore.Entry`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCATests/PropagationStoreTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

/// Build a propagation container entry: destHash(16) ‖ arbitrary opaque tail (the store treats the
/// encrypted tail as opaque, so the tail content is irrelevant to store behavior).
private func entry(dest: UInt8, tail: String) -> Data {
    Data(repeating: dest, count: LXMessage.destinationLength) + Data(tail.utf8)
}
private func container(_ entries: [Data]) -> Data {
    LXMFPropagation.container(timestamp: 1700000000.5, entries: entries)
}

@Test func propagationStoreIngestsAndDedups() throws {
    var store = PropagationStore()
    let e = entry(dest: 0xAA, tail: "one")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let firstAdded = store.ingest(container: container([e]))
    #expect(firstAdded == [tid])
    #expect(store.count == 1)
    #expect(store.contains(transientId: tid))
    // Re-ingesting the identical container is a no-op (dedup by transient_id).
    let secondAdded = store.ingest(container: container([e]))
    #expect(secondAdded.isEmpty)
    #expect(store.count == 1)
}

@Test func propagationStoreQueriesByDestination() throws {
    var store = PropagationStore()
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let b1 = entry(dest: 0xBB, tail: "b1")
    store.ingest(container: container([a1, b1, a2]))
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let forA = store.entries(forDestination: destA)
    #expect(forA.count == 2)
    #expect(forA.allSatisfy { $0.destinationHash == destA })
    #expect(forA.map { $0.lxmfData } == [a1, a2])   // oldest-first by insertion
    let destB = Data(repeating: 0xBB, count: LXMessage.destinationLength)
    #expect(store.entries(forDestination: destB).count == 1)
}

@Test func propagationStoreRemoves() throws {
    var store = PropagationStore()
    let e = entry(dest: 0xAA, tail: "x")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    store.ingest(container: container([e]))
    store.remove(transientId: tid)
    #expect(store.count == 0)
    #expect(!store.contains(transientId: tid))
}

@Test func propagationStoreEvictsOldestOverLimit() throws {
    // Each entry is 16 + 4 = 20 bytes; a 45-byte limit holds at most 2.
    var store = PropagationStore(storageLimitBytes: 45)
    let e1 = entry(dest: 0xAA, tail: "aaaa")
    let e2 = entry(dest: 0xAA, tail: "bbbb")
    let e3 = entry(dest: 0xAA, tail: "cccc")
    store.ingest(container: container([e1]))
    store.ingest(container: container([e2]))
    store.ingest(container: container([e3]))   // pushes over the limit → evict oldest (e1)
    #expect(store.sizeBytes <= 45)
    #expect(store.count == 2)
    #expect(!store.contains(transientId: LXMFPropagation.transientId(lxmfData: e1)))   // oldest evicted
    #expect(store.contains(transientId: LXMFPropagation.transientId(lxmfData: e3)))    // newest retained
}

@Test func propagationStoreSkipsMalformedEntries() throws {
    var store = PropagationStore()
    // Short entry (< 16 bytes) is skipped; the well-formed one is stored.
    let shortEntry = Data([0x01, 0x02, 0x03])
    let good = entry(dest: 0xAA, tail: "ok")
    let added = store.ingest(container: container([shortEntry, good]))
    #expect(added == [LXMFPropagation.transientId(lxmfData: good)])
    #expect(store.count == 1)
    // A non-container blob ingests to nothing.
    #expect(store.ingest(container: Data([0xFF, 0xFF])).isEmpty)
    #expect(store.count == 1)
}
```

- [ ] **Step 2: Run them — verify they fail**

Run: `swift test --filter PropagationStoreTests`
Expected: BUILD FAILURE — `PropagationStore` does not exist yet. Expected red.

- [ ] **Step 3: Implement `PropagationStore`**

Create `Sources/ReTiCA/LXMF/PropagationStore.swift`:

```swift
import Foundation

/// A propagation node's store-and-forward message store (LXMF-4d-3). Ingests propagation containers
/// (msgpack([timestamp, [lxmf_data…]])), dedups entries by transient_id, evicts oldest under an optional
/// storage limit, and serves entries by recipient destination. Pure value type — a propagation node (or
/// its future reducer) holds one. Mirrors lxmf 1.1.0 LXMRouter message storage (propagation_resource_
/// concluded / clean_message_store); peering, stamps, and persistence are out of scope.
public struct PropagationStore: Equatable {
    public struct Entry: Equatable {
        public var transientId: Data
        public var destinationHash: Data
        public var lxmfData: Data
        var sequence: Int
    }

    private var stored: [Data: Entry] = [:]
    private var nextSequence: Int = 0
    /// Total-storage cap in bytes; nil = unbounded (RNS default). Sum of stored lxmf_data sizes.
    public var storageLimitBytes: Int?

    public init(storageLimitBytes: Int? = nil) {
        self.storageLimitBytes = storageLimitBytes
    }

    public var count: Int { stored.count }
    public var sizeBytes: Int { stored.values.reduce(0) { $0 + $1.lxmfData.count } }

    public func contains(transientId: Data) -> Bool { stored[transientId] != nil }

    @discardableResult
    public mutating func ingest(container: Data) -> [Data] {
        guard let (_, lxmfDatas) = LXMFPropagation.parseContainer(container) else { return [] }
        var added: [Data] = []
        for lxmfData in lxmfDatas {
            guard let dest = LXMFPropagation.destinationHash(lxmfData: lxmfData) else { continue }
            let tid = LXMFPropagation.transientId(lxmfData: lxmfData)
            if stored[tid] != nil { continue }   // dedup by transient_id
            stored[tid] = Entry(transientId: tid, destinationHash: dest, lxmfData: lxmfData, sequence: nextSequence)
            nextSequence += 1
            added.append(tid)
        }
        evictOverLimit()
        return added.filter { stored[$0] != nil }
    }

    public func entries(forDestination destinationHash: Data) -> [Entry] {
        stored.values.filter { $0.destinationHash == destinationHash }.sorted { $0.sequence < $1.sequence }
    }

    public mutating func remove(transientId: Data) {
        stored[transientId] = nil
    }

    private mutating func evictOverLimit() {
        guard let limit = storageLimitBytes else { return }
        while sizeBytes > limit, let oldest = stored.values.min(by: { $0.sequence < $1.sequence }) {
            stored[oldest.transientId] = nil
        }
    }
}
```

- [ ] **Step 4: Run them — verify they pass**

Run: `swift test --filter PropagationStoreTests`
Expected: PASS (all 5).

- [ ] **Step 5: Mutation verification (one mutation at a time)**

Apply each individually in `Sources/ReTiCA/LXMF/PropagationStore.swift`, run `swift test --filter PropagationStoreTests`, confirm the named test fails, revert, confirm pass, then the next.

1. **Dedup removed** — delete the `if stored[tid] != nil { continue }` guard in `ingest`.
   → `propagationStoreIngestsAndDedups` FAILS (second ingest re-adds; `count` becomes 2 / `secondAdded` non-empty). (Note: overwriting the same key keeps count 1 but `added` would include `tid` again → `secondAdded.isEmpty` fails.)
2. **Destination filter wrong** — in `entries(forDestination:)` change the filter to `stored.values` (ignore `destinationHash`).
   → `propagationStoreQueriesByDestination` FAILS (`forA.count` becomes 3, and destB count becomes 3).
3. **Eviction disabled** — make `evictOverLimit` return immediately (`return` at the top, before the guard).
   → `propagationStoreEvictsOldestOverLimit` FAILS (`count == 3`, `sizeBytes > 45`).
4. **Malformed guard removed** — in `ingest`, replace `guard let dest = ... else { continue }` with `let dest = LXMFPropagation.destinationHash(lxmfData: lxmfData) ?? Data()` (store short entries with an empty destHash).
   → `propagationStoreSkipsMalformedEntries` FAILS (`count == 2`; `added` has 2 ids).

After each: revert, re-run, expect PASS before the next.

- [ ] **Step 6: Full test gate**

Run: `swift test`
Expected: PASS. The 4d-2b baseline was 437 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 5 tests → 442 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 7: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-4d3.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCA/LXMF/PropagationStore.swift Tests/ReTiCATests/PropagationStoreTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4d3.txt
```

Commit message body:

```
feat: LXMF-4d-3 — propagation node message store

Pure PropagationStore: ingest propagation containers, dedup entries by
transient_id, evict oldest under an optional storageLimitBytes, query
entries by recipient destinationHash, and remove on delivery. The store-
and-forward heart of a propagation node; serve wiring + peering/stamps
deferred. Reuses LXMFPropagation (4d-1). 5 unit tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec `PropagationStore` API (init/ingest/contains/count/sizeBytes/entries/remove/Entry) → Step 3. ✓
- Spec ingest semantics (parse, dedup by transient_id, skip malformed, evict oldest over limit, return retained new ids) → Step 3. ✓
- Spec test 1 (ingest + dedup) → `propagationStoreIngestsAndDedups`. ✓
- Spec test 2 (query by destination, oldest-first) → `propagationStoreQueriesByDestination`. ✓
- Spec test 3 (remove) → `propagationStoreRemoves`. ✓
- Spec test 4 (eviction) → `propagationStoreEvictsOldestOverLimit`. ✓
- Spec test 5 (malformed skipped) → `propagationStoreSkipsMalformedEntries`. ✓

**Placeholder scan:** none.

**Type consistency:** `ingest` returns `[Data]`; `entries(forDestination:)` returns `[PropagationStore.Entry]` with `.destinationHash`/`.lxmfData` used in tests; `transientId`/`contains`/`count`/`sizeBytes`/`remove` match test call sites. Consumes the exact 4d-1 `LXMFPropagation` signatures.
