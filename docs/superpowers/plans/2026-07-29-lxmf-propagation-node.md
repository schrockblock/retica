# LXMF-4d-3b: Propagation Node reducer Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A decoupled `PropagationNode` reducer wrapping `PropagationStore` — ingest client containers, serve a client's messages by recipient, and drop delivered messages.

**Architecture:** New `@Reducer` in ReTiCANode mirroring `LXMFRouter`'s decoupled shape. Pure orchestration over the cross-validated `PropagationStore` (4d-3) + `LXMFPropagation` (4d-1); the app wires the delegates/actions to the `lxmf.propagation` destination.

**Tech Stack:** Swift, The Composable Architecture (TCA), swift-testing (`@Test`).

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: `PropagationNode` reducer + tests

**Files:**
- Create: `Sources/ReTiCANode/PropagationNode.swift`
- Create: `Tests/ReTiCANodeTests/PropagationNodeTests.swift`

**Interfaces:**
- Consumes (existing): `PropagationStore` (`init(storageLimitBytes:)`, `ingest(container:) -> [Data]`, `entries(forDestination:) -> [PropagationStore.Entry]` with public `.lxmfData`, `remove(transientId:)`, `count`, `contains(transientId:)`); `LXMFPropagation.container(timestamp:entries:)`/`.transientId(lxmfData:)`; `LXMessage.destinationLength`.
- Produces: `PropagationNode` (`@Reducer`), `PropagationNode.State`, `PropagationNode.Action` (`.ingestContainer`, `.messagesRequested`, `.messagesDelivered`, `.delegate`), `PropagationNode.Action.Delegate` (`.stored`, `.deliverMessages`).

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/PropagationNodeTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA

private func entry(dest: UInt8, tail: String) -> Data {
    Data(repeating: dest, count: LXMessage.destinationLength) + Data(tail.utf8)
}
private func container(_ entries: [Data]) -> Data {
    LXMFPropagation.container(timestamp: 1700000000.5, entries: entries)
}

@Test @MainActor func propagationNodeIngestsAndReportsIds() async {
    let e = entry(dest: 0xAA, tail: "one")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e])))
    await store.receive { action in
        if case let .delegate(.stored(ids)) = action { #expect(ids == [tid]); return true }
        return false
    }
    #expect(store.state.store.count == 1)
    #expect(store.state.store.contains(transientId: tid))
}

@Test @MainActor func propagationNodeDedupsOnReingest() async {
    let e = entry(dest: 0xAA, tail: "one")
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    await store.send(.ingestContainer(container([e])))   // identical → dedup
    await store.receive { action in
        if case let .delegate(.stored(ids)) = action { #expect(ids.isEmpty); return true }
        return false
    }
    #expect(store.state.store.count == 1)
}

@Test @MainActor func propagationNodeServesByDestination() async {
    let a1 = entry(dest: 0xAA, tail: "a1"), a2 = entry(dest: 0xAA, tail: "a2")
    let b1 = entry(dest: 0xBB, tail: "b1")
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([a1, b1, a2])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    await store.send(.messagesRequested(destinationHash: destA))
    await store.receive { action in
        if case let .delegate(.deliverMessages(dest, entries)) = action {
            #expect(dest == destA); #expect(entries == [a1, a2]); return true   // only A's, oldest-first
        }
        return false
    }
}

@Test @MainActor func propagationNodeServesEmptyWhenNoneAddressed() async {
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    let dest = Data(repeating: 0xCC, count: LXMessage.destinationLength)
    await store.send(.messagesRequested(destinationHash: dest))
    await store.receive { action in
        if case let .delegate(.deliverMessages(d, entries)) = action {
            #expect(d == dest); #expect(entries.isEmpty); return true
        }
        return false
    }
}

@Test @MainActor func propagationNodeDropsDeliveredMessages() async {
    let e = entry(dest: 0xAA, tail: "one")
    let tid = LXMFPropagation.transientId(lxmfData: e)
    let destA = Data(repeating: 0xAA, count: LXMessage.destinationLength)
    let store = TestStore(initialState: PropagationNode.State()) { PropagationNode() }
    store.exhaustivity = .off
    await store.send(.ingestContainer(container([e])))
    await store.receive { if case .delegate(.stored) = $0 { return true }; return false }
    await store.send(.messagesDelivered(transientIds: [tid]))
    #expect(store.state.store.count == 0)
    await store.send(.messagesRequested(destinationHash: destA))
    await store.receive { action in
        if case let .delegate(.deliverMessages(_, entries)) = action { #expect(entries.isEmpty); return true }
        return false
    }
}
```

- [ ] **Step 2: Run them — verify they fail**

Run: `swift test --filter PropagationNodeTests`
Expected: BUILD FAILURE — `PropagationNode` does not exist yet. Expected red.

- [ ] **Step 3: Implement `PropagationNode`**

Create `Sources/ReTiCANode/PropagationNode.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA

/// LXMF propagation node — the store-and-forward server role (LXMF-4d-3b). A decoupled reducer holding
/// a `PropagationStore`: the app forwards `lxmf.propagation` events in as actions (a client's concluded
/// container, a client's message request, a client's delivery confirmation) and wires the delegates back
/// out to the transport. The literal Endpoint registration, resource framing, and IDENTIFY resolution are
/// app glue. Mirrors lxmf 1.1.0 LXMRouter (propagation_resource_concluded / message_get_request /
/// save_locally_delivered_transient_ids); peering, stamps, and the PN↔PN mesh are separate.
@Reducer
public struct PropagationNode {
    @ObservableState
    public struct State: Equatable {
        public var store: PropagationStore
        public init(storageLimitBytes: Int? = nil) {
            store = PropagationStore(storageLimitBytes: storageLimitBytes)
        }
    }

    public enum Action: Equatable {
        case ingestContainer(Data)
        case messagesRequested(destinationHash: Data)
        case messagesDelivered(transientIds: [Data])
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case stored(transientIds: [Data])
            case deliverMessages(destinationHash: Data, entries: [Data])
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .ingestContainer(data):
                let added = state.store.ingest(container: data)
                return .send(.delegate(.stored(transientIds: added)))

            case let .messagesRequested(destinationHash):
                let entries = state.store.entries(forDestination: destinationHash).map(\.lxmfData)
                return .send(.delegate(.deliverMessages(destinationHash: destinationHash, entries: entries)))

            case let .messagesDelivered(transientIds):
                for tid in transientIds { state.store.remove(transientId: tid) }
                return .none

            case .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 4: Run them — verify they pass**

Run: `swift test --filter PropagationNodeTests`
Expected: PASS (5).

- [ ] **Step 5: Mutation verification (one at a time)**

Apply each in `Sources/ReTiCANode/PropagationNode.swift`, run `swift test --filter PropagationNodeTests`, confirm the named test fails, revert, confirm pass.

1. **Ingest doesn't store** — in `.ingestContainer`, replace `let added = state.store.ingest(container: data)` with `let added: [Data] = []` (don't touch the store).
   → `propagationNodeIngestsAndReportsIds` FAILS (`stored` empty, `store.count == 0`); `propagationNodeServesByDestination` FAILS (nothing to serve).
2. **Serve ignores the destination filter** — in `.messagesRequested`, replace `state.store.entries(forDestination: destinationHash)` with `state.store.entries(forDestination: Data())` (wrong dest → empty).
   → `propagationNodeServesByDestination` FAILS (`entries` empty, not `[a1, a2]`).
3. **Delivered doesn't remove** — in `.messagesDelivered`, replace the loop body with nothing (`return .none` without removing).
   → `propagationNodeDropsDeliveredMessages` FAILS (`store.count == 1`, and the re-request still returns the entry).

After each: revert, re-run, expect PASS.

- [ ] **Step 6: Full test gate**

Run: `swift test`
Expected: PASS. The LXMF-5c baseline was 466 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 5 tests → 471 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 7: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-pn.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCANode/PropagationNode.swift Tests/ReTiCANodeTests/PropagationNodeTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-pn.txt
```

Commit message body:

```
feat: LXMF-4d-3b — PropagationNode reducer

Decoupled TCA reducer wrapping PropagationStore: .ingestContainer →
store.ingest + .stored delegate; .messagesRequested(destHash) →
.deliverMessages(entries) via store.entries(forDestination);
.messagesDelivered → store.remove. The store-and-forward server role's
orchestration, unit-tested; Endpoint glue + PN announce + mesh remain
follow-ons. 5 tests.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec `PropagationNode` State (`store`) + Action (`ingestContainer`/`messagesRequested`/`messagesDelivered`/`delegate`) + Delegate (`stored`/`deliverMessages`) → Step 3. ✓
- Spec reducer behavior (ingest→store.ingest+stored; request→entries(forDestination) mapped to lxmfData→deliverMessages; delivered→remove) → Step 3. ✓
- Spec test 1 (ingest+ids) → `propagationNodeIngestsAndReportsIds`. ✓
- Spec test 2 (dedup) → `propagationNodeDedupsOnReingest`. ✓
- Spec test 3 (serve by dest) → `propagationNodeServesByDestination`. ✓
- Spec test 4 (serve empty) → `propagationNodeServesEmptyWhenNoneAddressed`. ✓
- Spec test 5 (delivered drops) → `propagationNodeDropsDeliveredMessages`. ✓

**Placeholder scan:** none.

**Type consistency:** `Action.ingestContainer(Data)` / `.messagesRequested(destinationHash:)` / `.messagesDelivered(transientIds:)` and `Delegate.stored(transientIds:)` / `.deliverMessages(destinationHash:entries:)` match the test call sites. `State.store: PropagationStore` (public) is read in tests via `store.state.store.count`/`.contains`. Consumes the exact 4d-3 `PropagationStore` + 4d-1 `LXMFPropagation` signatures.
