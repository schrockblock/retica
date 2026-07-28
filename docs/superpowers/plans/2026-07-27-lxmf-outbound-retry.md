# LXMF-4c-1: Outbound Retry Timer + Terminal Outcomes — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give the `LXMFRouter` a per-message retry timer and terminal delivery outcomes — retry every `retryWaitSeconds` up to `maxAttempts`, confirm on a forwarded `.delivered`, and surface `deliveryConfirmed`/`deliveryFailed`.

**Architecture:** Core `LXMFDelivery` constants (ReTiCA, cross-validated) + a retry extension to the `LXMFRouter` reducer (ReTiCANode): a `pendingDeliveries` table + `ResendInfo`, a `continuousClock`-driven cancellable retry timer armed whenever a send delegate is emitted, `.delivered`/`.retryDue` actions, `.deliveryConfirmed`/`.deliveryFailed` delegates. Decoupled — delivery outcome is a forwarded action.

**Tech Stack:** Swift, The Composable Architecture (timers via `\.continuousClock` + `TestClock`), Swift Testing, genuine `lxmf 1.1.0` for the constant cross-val.

## Global Constraints

- Commit directly to `main`; no feature branch.
- No compound shell commands (no `&&`, `||`, `;`, `xargs`, inline interpreter scripts). One command per Bash call. A single `>` redirect allowed. Never use echo/printf/heredoc to write files — use editor tools.
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Timer tests inject a `TestClock` (swift-dependencies `\.continuousClock` testValue is unimplemented → using it without injection fails). A `.off` TestStore tolerates an in-flight timer at teardown.
- Cross-val fixtures MUST derive from genuine LXMF; extend the committed `lxmf_fixtures.json` (regeneration churns it — LXMF-1/2/3/4b cross-vals re-derive and still pass; confirm).
- Signatures validated, never byte-compared.
- New production: `Sources/ReTiCA/LXMF/LXMFDelivery.swift` (constants) + `LXMFRouter` retry extension (ReTiCANode). Tests in `ReTiCATests/Vectors` (constant cross-val) + `ReTiCANodeTests` (reducer).
- Wire pin (probed): `DELIVERY_RETRY_WAIT = 10`, `MAX_DELIVERY_ATTEMPTS = 5`. Attempts arithmetic: armed at 1; each `retryDue` increments; `> maxAttempts` (i.e. 6) → fail. So 5 total sends (1 initial + 4 re-emits), then `deliveryFailed`.
- Build gotcha: signal-11/10/SIGILL → `swift package clean` then retry.
- Commit trailers, exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

**Spec:** `docs/superpowers/specs/2026-07-27-lxmf-outbound-retry-design.md`
**Base:** this plan's own commit (verify with `git log --oneline <planCommit>..HEAD`, never `HEAD~1`).

---

## File Structure

- **Create** `Sources/ReTiCA/LXMF/LXMFDelivery.swift` — `retryWaitSeconds` + `maxAttempts` constants.
- **Modify** `Tests/ReTiCATests/Vectors/{generate_lxmf_fixtures.py, LXMFVectorFixtures.swift, LXMessageCrossValidationTests.swift}` (+ regenerate `lxmf_fixtures.json`) — constant cross-val.
- **Modify** `Sources/ReTiCANode/LXMFRouter.swift` — retry state/actions/delegates/reducer.
- **Modify** `Tests/ReTiCANodeTests/LXMFRouterTests.swift` — 4b `.send` test migration + timer tests.

---

## Task 1: `LXMFDelivery` constants + cross-val

**Files:**
- Create: `Sources/ReTiCA/LXMF/LXMFDelivery.swift`
- Test: `Tests/ReTiCATests/Vectors/*`

**Interfaces:**
- Produces: `LXMFDelivery.retryWaitSeconds: Int`, `LXMFDelivery.maxAttempts: Int`. Task 2 uses both.

- [ ] **Step 1: Create the constants**

Create `Sources/ReTiCA/LXMF/LXMFDelivery.swift`:

```swift
import Foundation

/// LXMF outbound delivery timing (RNS LXMRouter). Kept in core so the wire/behavior cross-validation
/// (which lives in the ReTiCA test target) can pin them against genuine LXMF; the LXMFRouter reducer
/// (ReTiCANode) references them.
public enum LXMFDelivery {
    /// Seconds between outbound delivery retries (RNS `LXMRouter.DELIVERY_RETRY_WAIT`).
    public static let retryWaitSeconds = 10
    /// Max delivery attempts before a message is failed (RNS `LXMRouter.MAX_DELIVERY_ATTEMPTS`).
    public static let maxAttempts = 5
}
```

- [ ] **Step 2: Add the cross-val**

In `Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py`, add to the emitted dict:

```python
    "delivery_retry_wait": LXMF.LXMRouter.DELIVERY_RETRY_WAIT,
    "max_delivery_attempts": LXMF.LXMRouter.MAX_DELIVERY_ATTEMPTS,
```

Regenerate: `/Users/ell/opt/anaconda3/envs/rns/bin/python Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py > Tests/ReTiCATests/Vectors/lxmf_fixtures.json`
(Expected: exit 0; `delivery_retry_wait: 10`, `max_delivery_attempts: 5` present. Whole fixture regenerated — LXMF-1/2/3/4b cross-vals re-derive; confirm in Step 4.)

Add to `Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift`: `let deliveryRetryWait: Int` + `let maxDeliveryAttempts: Int`, and CodingKeys `case deliveryRetryWait = "delivery_retry_wait"`, `case maxDeliveryAttempts = "max_delivery_attempts"`.

Add to `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift`:

```swift
/// Our LXMF delivery timing constants match genuine RNS LXMRouter.
@Test func lxmfDeliveryConstantsMatchRns() throws {
    let f = try LXMFVectorFixtures.load()
    #expect(LXMFDelivery.retryWaitSeconds == f.deliveryRetryWait)
    #expect(LXMFDelivery.maxAttempts == f.maxDeliveryAttempts)
}
```

- [ ] **Step 3: Run to verify it fails then passes**

Run: `swift test --filter "lxmfDeliveryConstants" 2>&1 | tail -10`
Expected: FAIL before the fixture/struct fields exist (compile), PASS after regeneration + struct fields.

- [ ] **Step 4: Confirm siblings**

Run: `swift test --filter "lxMessage" 2>&1 | tail -10` and `swift test --filter "encryptedPacketMdu\|linkMdu" 2>&1 | tail -10` (separately if the regex is fiddly).
Expected: all LXMF-1/2/3/4b cross-val + unit tests still PASS after regeneration.

- [ ] **Step 5: Mutation-verify (three-step)**

Mutate: `retryWaitSeconds = 10` → `11` and `maxAttempts = 5` → `4` (one at a time). Run `swift test --filter "lxmfDeliveryConstants"`. Confirm the test fails on each. Revert; run again; PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCA/LXMF/LXMFDelivery.swift Tests/ReTiCATests/
git commit -F /tmp/ReTiCA/commit-lxmf4c1-t1.txt
```

(Message e.g. `feat: LXMF-4c-1 task 1 — LXMFDelivery retry constants + cross-val` plus trailers.)

---

## Task 2: LXMFRouter retry state machine + 4b test migration

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift`
- Test: `Tests/ReTiCANodeTests/LXMFRouterTests.swift`

**Interfaces:**
- Consumes: `LXMFDelivery.retryWaitSeconds`/`.maxAttempts` (Task 1); the 4b `.send`/`.linkEstablished` handlers; `LXMessage.hash`/`opportunisticPayload`/`packed`/`directRepresentation`/`destinationHash`.
- Produces: `LXMFRouter.ResendInfo`/`PendingDelivery`, `State.pendingDeliveries`, actions `.delivered`/`.retryDue`, delegates `.deliveryConfirmed`/`.deliveryFailed`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (import `Clocks`/TCA TestClock is available via ComposableArchitecture):

```swift
// MARK: - LXMF-4c-1 outbound retry

@Test @MainActor func routerArmsRetryTimerOnOpportunisticSend() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }
    #expect(store.state.pendingDeliveries[msg.hash]?.attempts == 1)
    await store.send(.delivered(messageHash: msg.hash))   // clean up the pending timer before teardown
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
}

@Test @MainActor func routerDeliveredConfirmsAndCancelsRetry() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }
    await store.send(.delivered(messageHash: msg.hash))
    await store.receive { action in
        if case let .delegate(.deliveryConfirmed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[msg.hash] == nil)
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))   // retry timer was cancelled → no retryDue
    store.exhaustivity = .on
}

@Test @MainActor func routerRetriesThenFailsAtMaxAttempts() async {
    let msg = makeMessage(source: Identity(), content: "small")
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }
    // 4 retries re-emit the send (attempts 2..5); the 5th advance (attempts → 6 > max) fails.
    for _ in 0..<(LXMFDelivery.maxAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
        await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }   // re-emit
    }
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.deliveryFailed(h)) = action { #expect(h == msg.hash); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[msg.hash] == nil)
}

@Test @MainActor func routerArmsRetryForDrainedResourceMessage() async {
    let big = makeMessage(source: Identity(), content: String(repeating: "x", count: 2000))
    #expect(big.directRepresentation == .resource)
    let clock = TestClock()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = clock
    }
    store.exhaustivity = .off
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.receive { if case .delegate(.requestLink) = $0 { return true }; return false }
    let linkID = Data(repeating: 0xCD, count: 16)
    await store.send(.linkEstablished(destinationHash: big.destinationHash, linkID: linkID))
    await store.receive { action in
        if case let .delegate(.sendDirect(_, _, asResource)) = action { #expect(asResource == true); return true }
        return false
    }
    #expect(store.state.pendingDeliveries[big.hash]?.attempts == 1)   // drained send armed a retry
    // A retry re-emits sendDirect with asResource preserved.
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in
        if case let .delegate(.sendDirect(lid, _, asResource)) = action {
            #expect(lid == linkID); #expect(asResource == true); return true
        }
        return false
    }
    await store.send(.delivered(messageHash: big.hash))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
}
```

Then MIGRATE the three 4b tests that emit a send delegate — add `withDependencies: { $0.continuousClock = TestClock() }` to their `TestStore` (so the now-armed retry timer resolves; it sits pending, unadvanced): `routerSendsSmallMessageOpportunistically`, `routerLinkEstablishedDrainsQueueAsSendDirect`, `routerDirectWithActiveLinkSendsImmediately`. (The `requestLink`-only tests — fallback / no-link / establish-once — emit no send delegate, arm no timer, and need no clock.)

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "router" 2>&1 | tail -40`
Expected: the new retry tests fail (actions/state don't exist); the three un-migrated 4b send tests fail with an unimplemented-clock error once the timer is added (they're migrated in Step 1).

- [ ] **Step 3: Extend the reducer**

In `Sources/ReTiCANode/LXMFRouter.swift`:

Add after the imports' `@Reducer public struct LXMFRouter {` dependency area (inside the struct, before `body`):
```swift
    @Dependency(\.continuousClock) var clock
    private enum CancelID: Hashable { case retry(Data) }
```

Add the types (next to `LinkStatus`):
```swift
    public enum ResendInfo: Equatable {
        case opportunistic(destinationHash: Data, payload: Data)
        case direct(linkID: Data, data: Data, asResource: Bool)
    }
    public struct PendingDelivery: Equatable { public var resend: ResendInfo; public var attempts: Int }
```

Add to `State`:
```swift
        /// message.hash → in-flight send awaiting a delivery outcome (with its resend info + attempts).
        var pendingDeliveries: [Data: PendingDelivery] = [:]
```

Add to `Action`:
```swift
        case delivered(messageHash: Data)
        case retryDue(messageHash: Data)
```
Add to `Action.Delegate`:
```swift
            case deliveryConfirmed(messageHash: Data)
            case deliveryFailed(messageHash: Data)
```

Capture the clock in the `Reduce` and add a retry-timer helper. Change `Reduce { state, action in` to `Reduce { [clock] state, action in` and add at the top of the closure:
```swift
            func retryTimer(_ hash: Data) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(LXMFDelivery.retryWaitSeconds))
                    await send(.retryDue(messageHash: hash))
                }.cancellable(id: CancelID.retry(hash), cancelInFlight: true)
            }
            func arm(_ state: inout State, _ hash: Data, _ resend: ResendInfo) {
                state.pendingDeliveries[hash] = PendingDelivery(resend: resend, attempts: 1)
            }
```

Change the `.send` opportunistic path to arm + merge the timer:
```swift
                case .opportunistic:
                    let resend = ResendInfo.opportunistic(destinationHash: message.destinationHash,
                                                          payload: message.opportunisticPayload)
                    arm(&state, message.hash, resend)
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: message.destinationHash,
                                                                     payload: message.opportunisticPayload))),
                                  retryTimer(message.hash))
```

Change the `.send` direct-active path:
```swift
                    if case let .active(linkID) = state.directLinks[dest] {
                        let asResource = message.directRepresentation == .resource
                        arm(&state, message.hash, .direct(linkID: linkID, data: message.packed, asResource: asResource))
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                                  asResource: asResource))),
                                      retryTimer(message.hash))
                    }
```

Change the `.linkEstablished` drain to arm each:
```swift
            case let .linkEstablished(dest, linkID):
                state.directLinks[dest] = .active(linkID: linkID)
                let queued = state.outboundQueue[dest] ?? []
                state.outboundQueue[dest] = nil
                var effects: [Effect<Action>] = []
                for m in queued {
                    let asResource = m.directRepresentation == .resource
                    arm(&state, m.hash, .direct(linkID: linkID, data: m.packed, asResource: asResource))
                    effects.append(.send(.delegate(.sendDirect(linkID: linkID, data: m.packed, asResource: asResource))))
                    effects.append(retryTimer(m.hash))
                }
                return effects.isEmpty ? .none : .merge(effects)
```

Add the two new cases (before `case .delegate`):
```swift
            case let .delivered(hash):
                guard state.pendingDeliveries[hash] != nil else { return .none }
                state.pendingDeliveries[hash] = nil
                return .merge(.cancel(id: CancelID.retry(hash)),
                              .send(.delegate(.deliveryConfirmed(messageHash: hash))))

            case let .retryDue(hash):
                guard var pending = state.pendingDeliveries[hash] else { return .none }
                pending.attempts += 1
                if pending.attempts > LXMFDelivery.maxAttempts {
                    state.pendingDeliveries[hash] = nil
                    return .send(.delegate(.deliveryFailed(messageHash: hash)))
                }
                state.pendingDeliveries[hash] = pending
                let resendDelegate: Effect<Action>
                switch pending.resend {
                case let .opportunistic(destinationHash, payload):
                    resendDelegate = .send(.delegate(.sendOpportunistic(destinationHash: destinationHash, payload: payload)))
                case let .direct(linkID, data, asResource):
                    resendDelegate = .send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource)))
                }
                return .merge(resendDelegate, retryTimer(hash))
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --filter "router" 2>&1 | tail -40`
Expected: all router tests (4a + 4b migrated + 4c new) PASS.

- [ ] **Step 5: Mutation-verify (three-step)**

Verify one at a time (revert between):
1. Don't arm on opportunistic send (skip `arm(...)` + the timer): `routerArmsRetryTimerOnOpportunisticSend` fails (no `pendingDeliveries`).
2. In `.delivered`, don't cancel the timer (drop the `.cancel`): `routerDeliveredConfirmsAndCancelsRetry` fails (advancing the clock after confirm emits a stray `sendOpportunistic`/`retryDue` caught by the `.on` teardown).
3. In `.retryDue`, change `> maxAttempts` to `> maxAttempts + 10` (never fail): `routerRetriesThenFailsAtMaxAttempts` fails (no `deliveryFailed`).
4. In the drain, don't arm (skip `arm`): `routerArmsRetryForDrainedResourceMessage` fails (no `pendingDeliveries[big.hash]`).

Run `swift test --filter "router"` after each; confirm the named test fails; revert; final run PASSES.

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift
git commit -F /tmp/ReTiCA/commit-lxmf4c1-t2.txt
```

(Message e.g. `feat: LXMF-4c-1 task 2 — LXMFRouter outbound retry timer + terminal outcomes` plus trailers.)

---

## Self-Review

- **Spec coverage:** constants + cross-val (Task 1); arm-on-send + `.delivered` confirm/cancel + `.retryDue` retry/fail + drain-arms + 4b migration (Task 2). Path-request (4c-2), link-CLOSED recovery + inactivity (4c-3) deferred (spec §Scope) — no task.
- **Placeholder scan:** none — full constants, cross-val, reducer, and tests.
- **Type consistency:** `LXMFDelivery.retryWaitSeconds`/`.maxAttempts`; `LXMFRouter.ResendInfo`/`PendingDelivery`/`State.pendingDeliveries`/`.delivered`/`.retryDue`/`.deliveryConfirmed`/`.deliveryFailed`; reuses `LXMessage.hash`/`opportunisticPayload`/`packed`/`directRepresentation`/`destinationHash`; `@Dependency(\.continuousClock)` + `CancelID.retry` mirror `Transport.swift`'s timer pattern; fixture `deliveryRetryWait`/`maxDeliveryAttempts` consistent across generator/struct/CodingKeys/test.
- **Behavior:** armed attempts=1; `> maxAttempts (6)` → fail → 5 total sends (1 + 4 re-emits); `.delivered` cancels; timers cancellable-by-hash (`cancelInFlight`); matches the scoped RNS `process_outbound` retry loop.
