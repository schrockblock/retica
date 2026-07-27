# LXMF-4a: Inbound Router + Dedup — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A dedicated `LXMFRouter` TCA reducer that ingests inbound LXMF deliveries (from any arrival method), validates + de-duplicates by `message.hash`, and surfaces each unique message once.

**Architecture:** New reducer `Sources/ReTiCANode/LXMFRouter.swift`, decoupled from `Endpoint` — the app forwards Endpoint's delivery/announce events in as `.received`/`.learnedIdentity` actions. Reconstruct by method (`.opportunistic` → `fromOpportunistic`; `.direct` → `unpack` whole) → `unpack` (malformed → drop) → dedup (`seen.insert(message.hash)`) → deliver with a `signatureValidated` flag (never dropped on bad signature). Uses `RingSet` (ReTiCATransport), `LXMessage`/`Identity` (ReTiCA).

**Tech Stack:** Swift, The Composable Architecture, Swift Testing.

## Global Constraints

- Commit directly to `main`; no feature branch.
- No compound shell commands (no `&&`, `||`, `;`, `xargs`, inline interpreter scripts). One command per Bash call. A single `>` redirect allowed. Never use echo/printf/heredoc to write files — use editor tools.
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- TCA tests non-exhaustive (`store.exhaustivity = .off`), asserting outcomes; for "no delivery" assertions use the flip-`.on`-last idiom (send in `.off`, then set `.on` as the last statement so a stray delegate is caught at teardown).
- Signatures validated, never byte-compared (`ed25519-hedged-nondeterministic`).
- New production is `Sources/ReTiCANode/LXMFRouter.swift` only; tests in `Tests/ReTiCANodeTests/`. No Endpoint/Transport/core changes.
- Build gotcha: signal-11/10/SIGILL → `swift package clean` then retry.
- Commit trailers, exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

**Spec:** `docs/superpowers/specs/2026-07-27-lxmf-inbound-router-design.md`
**Base:** this plan's own commit (verify with `git log --oneline <planCommit>..HEAD`, never `HEAD~1`).

---

## File Structure

- **Create** `Sources/ReTiCANode/LXMFRouter.swift` — the reducer.
- **Create** `Tests/ReTiCANodeTests/LXMFRouterTests.swift` — reducer tests (both tasks add to this file).

---

## Task 1: LXMFRouter reducer + delivery/validation/malformed/dedup tests

**Files:**
- Create: `Sources/ReTiCANode/LXMFRouter.swift`
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift`

**Interfaces:**
- Produces: `LXMFRouter` reducer with `State { seen, knownIdentities }`, `Action { learnedIdentity, received, delegate }`, `DeliveryMethod { opportunistic, direct }`, `Delegate { messageDelivered(message:signatureValidated:), duplicateDropped(hash:) }`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFRouterTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA

/// Helper: a signed LXMessage from `source` to a recipient delivery hash.
private func makeMessage(source: Identity, recipientIdentityHash: Data = Identity().hash,
                         content: String = "hello router") -> LXMessage {
    LXMessage.create(source: source,
                     destinationHash: LXMessage.deliveryHash(identityHash: recipientIdentityHash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data(content.utf8))
}

@Test @MainActor func routerDeliversOpportunisticMessageValidatedWhenSourceKnown() async {
    let sender = Identity()
    let msg = makeMessage(source: sender)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedIdentity(destinationHash: msg.sourceHash, identity: sender))
    await store.send(.received(method: .opportunistic, destinationHash: msg.destinationHash,
                               data: msg.opportunisticPayload))
    await store.receive { action in
        if case let .delegate(.messageDelivered(m, validated)) = action {
            #expect(m.hash == msg.hash)
            #expect(m.content == Data("hello router".utf8))
            #expect(validated == true)
            return true
        }
        return false
    }
}

@Test @MainActor func routerDeliversDirectMessage() async {
    let sender = Identity()
    let msg = makeMessage(source: sender)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedIdentity(destinationHash: msg.sourceHash, identity: sender))
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(m, validated)) = action {
            #expect(m.hash == msg.hash); #expect(validated == true); return true
        }
        return false
    }
}

@Test @MainActor func routerDeliversUnknownSourceUnvalidated() async {
    let msg = makeMessage(source: Identity())
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    // No .learnedIdentity for the sender.
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(m, validated)) = action {
            #expect(m.hash == msg.hash); #expect(validated == false); return true
        }
        return false
    }
}

@Test @MainActor func routerDropsMalformedData() async {
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.received(method: .direct, destinationHash: Data(), data: Data(count: 20)))
    store.exhaustivity = .on   // no delegate emitted — a stray one fails teardown
}

@Test @MainActor func routerDropsDuplicateSameMethod() async {
    let sender = Identity()
    let msg = makeMessage(source: sender)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedIdentity(destinationHash: msg.sourceHash, identity: sender))
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))
    await store.receive { if case .delegate(.messageDelivered) = $0 { return true }; return false }
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))   // dup
    await store.receive { action in
        if case let .delegate(.duplicateDropped(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "LXMFRouter\|router" 2>&1 | tail -20`
Expected: compile failure — `LXMFRouter` doesn't exist.

- [ ] **Step 3: Implement the reducer**

Create `Sources/ReTiCANode/LXMFRouter.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// LXMF inbound router (LXMF-4a): ingests inbound LXMF deliveries from any arrival method, validates
/// and de-duplicates them by `message.hash`, and surfaces each unique message once. Decoupled from
/// `Endpoint` — the app forwards Endpoint's delivery/announce events in as `.received`/`.learnedIdentity`.
/// Mirrors reference LXMRouter.lxmf_delivery (LXMRouter.py:1837-1919): always deliver a well-formed,
/// non-duplicate message (flagging signature validity), never drop on a bad/unknown signature.
@Reducer
public struct LXMFRouter {
    @ObservableState
    public struct State: Equatable {
        /// Dedup of already-delivered LXMF message IDs (`message.hash`). Bounded (RNS uses age-based
        /// expiry; a bounded ring is the LXMF-4a approximation).
        var seen = RingSet(capacity: 10_000)
        /// sourceHash (sender's lxmf.delivery destination hash) → identity, for signature validation.
        public var knownIdentities: [Data: Identity] = [:]
        public init() {}
    }

    public enum DeliveryMethod: Equatable { case opportunistic, direct }

    public enum Action: Equatable {
        case learnedIdentity(destinationHash: Data, identity: Identity)
        case received(method: DeliveryMethod, destinationHash: Data, data: Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case messageDelivered(message: LXMessage, signatureValidated: Bool)
            case duplicateDropped(hash: Data)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .learnedIdentity(destinationHash, identity):
                state.knownIdentities[destinationHash] = identity
                return .none

            case let .received(method, destinationHash, data):
                let reconstructed: LXMessage?
                switch method {
                case .opportunistic:
                    reconstructed = LXMessage.fromOpportunistic(destinationHash: destinationHash, payload: data)
                case .direct:
                    reconstructed = LXMessage.unpack(data)
                }
                guard let message = reconstructed else { return .none }   // malformed → drop
                guard state.seen.insert(message.hash) else {
                    return .send(.delegate(.duplicateDropped(hash: message.hash)))
                }
                let validated = state.knownIdentities[message.sourceHash]
                    .map { message.validateSignature(source: $0) } ?? false
                return .send(.delegate(.messageDelivered(message: message, signatureValidated: validated)))

            case .delegate:
                return .none
            }
        }
    }
}
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter "router" 2>&1 | tail -20`
Expected: the five tests PASS.

- [ ] **Step 5: Mutation-verify (three-step)**

Verify one at a time (revert between):
1. Remove the dedup guard (`state.seen.insert(...)` without `guard ... else`): `routerDropsDuplicateSameMethod` fails (the dup is delivered again instead of `duplicateDropped`).
2. Change the validated computation to always `true` (`?? true` or drop the `.map`): `routerDeliversUnknownSourceUnvalidated` fails (unknown source now `true`).
3. Change the malformed `guard let ... else { return .none }` to force-deliver / remove: `routerDropsMalformedData` fails (a delegate is emitted; caught by the `.on` teardown) — or the reducer crashes, which also fails the test.
4. Swap the reconstruct branches (`.opportunistic` uses `unpack(data)`): `routerDeliversOpportunisticMessageValidatedWhenSourceKnown` fails (unpack of the stripped payload → nil or wrong message).

Run `swift test --filter "router"` after each; confirm the named test fails; revert; final run PASSES.

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
git commit -F /tmp/ReTiCA/commit-lxmf4a-t1.txt
```

(Message e.g. `feat: LXMF-4a task 1 — LXMFRouter inbound reducer (reconstruct/validate/dedup/deliver)` plus trailers.)

---

## Task 2: Cross-method dedup + tampered-signature + identity-transition tests

**Files:**
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (add to it)

**Interfaces:**
- Consumes: `LXMFRouter` (Task 1). No production change — these tests strengthen behavioral coverage.

- [ ] **Step 1: Write the tests**

Add to `Tests/ReTiCANodeTests/LXMFRouterTests.swift`:

```swift
/// The headline: the SAME message arriving via two different methods (opportunistic then direct)
/// reconstructs to the same message.hash and is delivered exactly once.
@Test @MainActor func routerDedupsAcrossArrivalMethods() async {
    let sender = Identity()
    let msg = makeMessage(source: sender)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedIdentity(destinationHash: msg.sourceHash, identity: sender))
    await store.send(.received(method: .opportunistic, destinationHash: msg.destinationHash,
                               data: msg.opportunisticPayload))
    await store.receive { action in
        if case let .delegate(.messageDelivered(m, _)) = action { #expect(m.hash == msg.hash); return true }
        return false
    }
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))   // same msg, other path
    await store.receive { action in
        if case let .delegate(.duplicateDropped(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
}

/// A tampered payload (byte flipped in the content region) still parses but fails signature validation
/// against the known sender identity → delivered with signatureValidated == false.
@Test @MainActor func routerDeliversTamperedMessageUnvalidated() async {
    let sender = Identity()
    let msg = makeMessage(source: sender, content: "hello world")
    var bytes = Array(msg.packed)
    bytes[bytes.count - 2] ^= 0x01     // flip last content byte (before the trailing empty-map 0x80)
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.learnedIdentity(destinationHash: msg.sourceHash, identity: sender))
    await store.send(.received(method: .direct, destinationHash: Data(), data: Data(bytes)))
    await store.receive { action in
        if case let .delegate(.messageDelivered(_, validated)) = action { #expect(validated == false); return true }
        return false
    }
}

/// learnedIdentity flips a message from unvalidated to validated: the same sender's message is
/// signatureValidated == false before the identity is learned and true after.
@Test @MainActor func routerValidationDependsOnLearnedIdentity() async {
    let sender = Identity()
    let before = makeMessage(source: sender, content: "before")
    let after = makeMessage(source: sender, content: "after")   // distinct hash → not a dup
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    await store.send(.received(method: .direct, destinationHash: Data(), data: before.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(_, v)) = action { #expect(v == false); return true }; return false
    }
    // Both messages are from `sender`, so before.sourceHash == after.sourceHash.
    await store.send(.learnedIdentity(destinationHash: after.sourceHash, identity: sender))
    await store.send(.received(method: .direct, destinationHash: Data(), data: after.packed))
    await store.receive { action in
        if case let .delegate(.messageDelivered(_, v)) = action { #expect(v == true); return true }; return false
    }
}
```

- [ ] **Step 2: Run to verify they pass**

Run: `swift test --filter "router" 2>&1 | tail -20`
Expected: all three new tests PASS (the reducer already implements this behavior).

- [ ] **Step 3: Mutation-verify (three-step)**

Verify one at a time (revert between):
1. Remove the dedup guard: `routerDedupsAcrossArrivalMethods` fails (the second-path arrival is delivered instead of `duplicateDropped`).
2. Change validated to always `true`: `routerDeliversTamperedMessageUnvalidated` and the before-branch of `routerValidationDependsOnLearnedIdentity` fail.
3. Make `.learnedIdentity` a no-op (don't write `knownIdentities`): `routerValidationDependsOnLearnedIdentity` fails (the after-message stays `false`).

Run `swift test --filter "router"` after each; confirm; revert; final run PASSES.

- [ ] **Step 4: Commit**

```bash
git add Tests/ReTiCANodeTests/LXMFRouterTests.swift
git commit -F /tmp/ReTiCA/commit-lxmf4a-t2.txt
```

(Message e.g. `test: LXMF-4a task 2 — cross-method dedup + tampered + identity-transition` plus trailers.)

---

## Self-Review

- **Spec coverage:** reducer (State/Action/DeliveryMethod/Delegate) + reconstruct-by-method + unpack + dedup + deliver-with-flag (Task 1, tests 1-3,5-6); malformed drop (Task 1 test 4/"routerDropsMalformedData"); tampered + cross-method dedup + identity-transition (Task 2). Outbound/receipts/propagation/stamps deferred (spec §Deferred) — no task, by design.
- **Placeholder scan:** none — full reducer + full tests. The Task 2 identity-transition test uses `after.sourceHash` for `.learnedIdentity` (both messages share the sender, so the source hash matches).
- **Type consistency:** `LXMFRouter.State/Action/DeliveryMethod/Delegate`; `LXMessage.create/deliveryHash/opportunisticPayload/packed/unpack/fromOpportunistic/validateSignature/hash/sourceHash/destinationHash/content` (LXMF-1/2); `Identity` `Equatable`; `RingSet(capacity:)`/`insert` (ReTiCATransport). `@Reducer`/`@ObservableState`/`Reduce` match `Endpoint.swift` conventions.
- **Behavior correctness:** always-deliver-well-formed-with-flag + dedup-by-`message.hash` (path-independent) + never-drop-on-bad-signature match RNS `lxmf_delivery` (LXMRouter.py:1906-1919).
