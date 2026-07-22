# Link / Transfer / Pending-Request GC Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Purge terminal state reactively — remove concluded/failed transfers from `LinkSession.transfers`, clear `pendingRequests` + cancel their timers on close, and remove closed/failed links from `Endpoint.links` — so dead state and leaked timers don't accumulate.

**Architecture:** Reactive removal at the terminal transition. Removing an element from a `.forEach` `IdentifiedArray` auto-cancels that element's in-flight effects, so removing a closed `LinkSession` also cancels its link timers, request timers, and hosted transfers' watchdogs. Delegates fire before removal (they carry the identifying data); the LINKCLOSE transmit precedes the `.closed` delegate. Zero wire changes.

**Tech Stack:** Swift 6, The Composable Architecture (~1.26) — `Reduce`/`.forEach`/`IdentifiedArrayOf.remove(id:)`, cancellable effects, `TestStore`/`TestClock`. Changes are confined to `LinkSession` (ReTiCATransport) and `Endpoint` (ReTiCANode); the `ReTiCA` core is untouched.

## Global Constraints

- **Zero wire changes; no new dependencies; no new cross-validation fixture.** Pure state hygiene.
- **Removal happens AFTER the surfacing delegate is computed/sent** — read `linkID`/`destHash`/`advertisement`/`resourceHash`/pending state BEFORE `remove(id:)`. The `IdentifiedArray` subscript returns a value copy, so a local `let` captured before removal stays valid.
- **All four link-close paths** (`.close`, `.establishmentDeadline`, `.inactivityDeadline`, inbound `.linkClose`) clear `pendingRequests` and cancel their `CancelID.request(rid)` timers.
- **All terminal transfer exits** (`.concluded` and every branch of `.failed`, including the internal request/response branches that currently `return .none`) remove the transfer element.
- **Existing behavior preserved:** the same delegates (`linkClosed`/`linkFailed`/`resourceConcluded`/`resourceFailed`/`requestFailed`) fire with the same values as today, and the LINKCLOSE packet is still transmitted on close. GC only ADDS removal afterward.
- **Regression watch:** some existing tests may assert a closed link / terminal transfer still exists (e.g. `state.links.count == 1` after close, or inspecting `state.links[0]`/`state.transfers` post-terminal). Those now change — update such assertions to expect removal. Do NOT weaken a test to hide a real behavior change; update it to assert the new (correct) removed state.
- Build gotcha: signal-11/SIGILL during `swift test` → `swift package clean` then retry (stale cache); never delete State fields to "fix" a crash.
- **Mutation-test discipline** for every new/changed test: run-pass → batch-mutate-fail → revert-pass, before commit.
- **Commit directly to `main`** (no feature branch). **Commit trailers:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCATransport/LinkSession.swift` (**modify**, Task 1) — `cancelPending` helper + close-path merges + transfer-terminal removal.
- `Tests/ReTiCATransportTests/LinkSessionTests.swift` and/or `LinkSessionResourceTests.swift` (**modify**, Task 1).
- `Sources/ReTiCANode/Endpoint.swift` (**modify**, Task 2) — remove closed/establishment-failed links.
- `Tests/ReTiCANodeTests/EndpointTests.swift` (**modify**, Task 2).
- `README.md` (**modify**, Task 2) — update any "closed links stay inert / GC deferred" note.

---

### Task 1: `LinkSession` — remove terminal transfers + close-path pending cleanup

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift` (transfer removal) and `LinkSessionTests.swift` (close pending cleanup) — use whichever file already hosts the closest existing tests.

**Interfaces:**
- Consumes: the existing `CancelID.request(Data)`, `state.pendingRequests`, `state.transfers` (`IdentifiedArrayOf<ResourceTransfer.State>`), the `.transfer(.element(_, .delegate(.concluded/.failed)))` cases, and the four close paths.
- Produces: a closed link has empty `pendingRequests` with its request timers cancelled; a concluded/failed transfer is removed from `state.transfers`.

- [ ] **Step 1: Add the `cancelPending` helper**

In `Sources/ReTiCATransport/LinkSession.swift`, immediately after the `cancelAll` definition (the `let cancelAll = Effect<Action>.merge(...)` at ~line 154-156), add a nested function:

```swift
            func cancelPending(_ state: inout State) -> Effect<Action> {
                let cancels = state.pendingRequests.map { Effect<Action>.cancel(id: CancelID.request($0)) }
                state.pendingRequests.removeAll()
                return .merge(cancels)
            }
```

- [ ] **Step 2: Merge `cancelPending` into the four close paths**

**`.close`** (replace the whole case, ~lines 434-443):

```swift
            case .close:
                guard state.status == .active else { return .none }
                let cipher = Link.encrypt(state.linkID, sessionKey: state.sessionKey)
                state.status = .closed
                let reason: CloseReason = state.role == .initiator ? .initiatorClosed : .destinationClosed
                let closedAction = Action.delegate(.closed(reason))
                let pending = cancelPending(&state)
                guard let raw = linkPacket(state.linkID, .linkClose, cipher) else {
                    return .merge(.send(closedAction), cancelAll, pending)
                }
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(closedAction), cancelAll, pending)
```

**`.establishmentDeadline`** (replace, ~lines 445-448):

```swift
            case .establishmentDeadline:
                guard state.status == .pending || state.status == .handshake else { return .none }
                state.status = .closed
                return .merge(.send(.delegate(.closed(.timedOut))), cancelAll, cancelPending(&state))
```

**`.inactivityDeadline`** (replace, ~lines 456-464):

```swift
            case .inactivityDeadline:
                guard state.status == .active else { return .none }
                let cipher = Link.encrypt(state.linkID, sessionKey: state.sessionKey)
                state.status = .closed
                let closedAction = Action.delegate(.closed(.timedOut))
                let pending = cancelPending(&state)
                guard let raw = linkPacket(state.linkID, .linkClose, cipher) else {
                    return .merge(.send(closedAction), cancelAll, pending)
                }
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), .send(closedAction), cancelAll, pending)
```

**Inbound `.linkClose`** (replace, ~lines 254-260):

```swift
                case (_, .active, .data, .linkClose):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          plain == state.linkID
                    else { return .none }
                    state.status = .closed
                    let reason: CloseReason = state.role == .initiator ? .destinationClosed : .initiatorClosed
                    return .merge(.send(.delegate(.closed(reason))), cancelAll, cancelPending(&state))
```

- [ ] **Step 3: Remove the transfer element on `.concluded` / `.failed`**

Replace the `.concluded` case (~lines 489-493):

```swift
            case let .transfer(.element(elementID, .delegate(.concluded))):
                let adv = state.transfers[id: elementID]?.advertisement
                let hash = state.transfers[id: elementID]?.resourceHash
                state.transfers.remove(id: elementID)
                if adv?.isRequest == true || adv?.isResponse == true { return .none }   // internal req/resp delivery
                guard let hash else { return .none }
                return .send(.delegate(.resourceConcluded(hash)))
```

Replace the `.failed` case (~lines 494-503):

```swift
            case let .transfer(.element(elementID, .delegate(.failed))):
                let t = state.transfers[id: elementID]
                state.transfers.remove(id: elementID)
                if let rid = t?.advertisement?.requestID, state.pendingRequests.contains(rid) {
                    state.pendingRequests.remove(rid)
                    return .merge(.cancel(id: CancelID.request(rid)),
                                  .send(.delegate(.requestFailed(requestID: rid))))
                }
                if t?.advertisement?.isRequest == true || t?.advertisement?.isResponse == true { return .none }
                guard let hash = t?.resourceHash else { return .none }
                return .send(.delegate(.resourceFailed(hash)))
```

(`t` and `hash`/`adv` are value copies captured before `remove`, so they stay valid. The `.received` case is NOT terminal and is left unchanged — a receiver surfaces `.received` first, then concludes.)

- [ ] **Step 4: Write the tests**

Append to `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift` (transfer removal) — reuse the file's existing active-store + spawned-transfer helpers; build a store whose state already hosts a transfer with a `resourceHash` set and no request/response advertisement, then fire its terminal delegate:

```swift
@Test @MainActor func concludedTransferIsRemovedFromState() async {
    // Build an active link hosting one plain receiver transfer with a resourceHash.
    let (store, tid, hash) = activeLinkHostingPlainTransfer()   // see note below
    await store.send(.transfer(.element(id: tid, action: .delegate(.concluded))))
    await store.receive { if case .delegate(.resourceConcluded(hash)) = $0 { return true }; return false }
    #expect(store.state.transfers[id: tid] == nil)              // removed
}

@Test @MainActor func failedTransferIsRemovedFromState() async {
    let (store, tid, hash) = activeLinkHostingPlainTransfer()
    await store.send(.transfer(.element(id: tid, action: .delegate(.failed))))
    await store.receive { if case .delegate(.resourceFailed(hash)) = $0 { return true }; return false }
    #expect(store.state.transfers[id: tid] == nil)              // removed
}
```

Append to `Tests/ReTiCATransportTests/LinkSessionTests.swift` (close clears pending) — reuse the file's active-store helper + `TestClock`:

```swift
@Test @MainActor func closeClearsPendingRequestsAndCancelsTheirTimers() async {
    let clock = TestClock<Duration>()
    let store = activeInitiatorStore(clock)                     // existing helper / pattern in this file
    store.exhaustivity = .off
    await store.send(.sendRequest(path: "svc/x", data: Data([1, 2])))   // small → inline; arms pendingRequests + timer
    #expect(store.state.pendingRequests.isEmpty == false)
    await store.send(.close)                                    // emits LINKCLOSE + .closed; clears pending
    #expect(store.state.pendingRequests.isEmpty == true)
    // The request timer was cancelled: advancing well past rtt*6+11.25 fires no requestFailed and leaves no dangling effect.
    await clock.advance(by: .seconds(120))
}
```

> Implementer notes:
> - Build the test helpers to match the REAL `LinkSession.State` API used elsewhere in each file. `activeLinkHostingPlainTransfer()` should produce an active-link store whose `state.transfers` holds one `ResourceTransfer.State` with `resourceHash` set and `advertisement` either nil or a PLAIN (non-request/response) advertisement, and return `(store, transferID, resourceHash)`. The existing `LinkSessionResourceTests` already spawn receiver transfers (`inboundAdvertisementSpawnsReceiverAndRequests`, `sendResourceSpawnsSender…`) — mirror how they place a transfer in state; if it's easier, drive an inbound ADV to spawn the receiver, capture its id + hash, then fire `.concluded`/`.failed`.
> - `activeInitiatorStore(clock)` mirrors the existing active-link setup in `LinkSessionTests`/`LinkSessionRequestTests` (status `.active`, a `sessionKey`, a `linkID`, `rtt`), with `$0.continuousClock = clock`. Reuse the existing helper if one exists rather than inventing a new one.
> - The REQUIRED assertions (do NOT weaken): the terminal transfer is `== nil` after its delegate; `pendingRequests` is empty after close AND advancing past the timeout fires no `requestFailed` (proving the timer was cancelled — a `TestStore` also fails at teardown if the timer effect still dangled, so the clock-advance both asserts behavior and guarantees quiescence).

- [ ] **Step 5: Run to verify**

Run: `swift test --filter LinkSession`
Expected: PASS — the new tests plus all existing `LinkSession*` tests. If an existing test asserted a terminal transfer or closed-link internal state that is now removed, update it to expect removal (do not weaken it).

- [ ] **Step 6: Mutation sweep**

Apply each, run `swift test --filter LinkSession`, confirm the named test fails, revert; final green:
- Remove `state.transfers.remove(id: elementID)` from `.concluded` → `concludedTransferIsRemovedFromState` fails.
- Remove `state.transfers.remove(id: elementID)` from `.failed` → `failedTransferIsRemovedFromState` fails.
- In `cancelPending`, drop `state.pendingRequests.removeAll()` → `closeClearsPendingRequestsAndCancelsTheirTimers` fails (pending not empty).
- In `cancelPending`, return `.none` instead of `.merge(cancels)` (timer not cancelled) → `closeClearsPendingRequestsAndCancelsTheirTimers` fails (a `requestFailed` fires on the clock-advance / effect dangles at teardown).

- [ ] **Step 7: Commit**

```
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionResourceTests.swift Tests/ReTiCATransportTests/LinkSessionTests.swift
git commit -F /tmp/ReTiCA/commit-gc1.txt
```
(`/tmp/ReTiCA/commit-gc1.txt` first line: `feat: LinkSession GCs terminal transfers + clears pending requests on close`, blank line, trailers.)

---

### Task 2: `Endpoint` — remove closed/establishment-failed links + gate + README

**Files:**
- Modify: `Sources/ReTiCANode/Endpoint.swift`
- Test: `Tests/ReTiCANodeTests/EndpointTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1's changes (unchanged public delegates); `state.links` (`IdentifiedArrayOf<LinkSession.State>`), the `.link(.element(_, .delegate(.closed/.establishmentFailed)))` cases.
- Produces: a closed or establishment-failed link is removed from `state.links` (which auto-cancels its remaining in-flight effects).

- [ ] **Step 1: Remove the link element on `.closed` / `.establishmentFailed`**

In `Sources/ReTiCANode/Endpoint.swift`, replace the two cases (~lines 165-171):

```swift
            case let .link(.element(elementID, .delegate(.closed(reason)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                state.links.remove(id: elementID)
                return .send(.delegate(.linkClosed(linkID: linkID, reason: reason)))

            case let .link(.element(elementID, .delegate(.establishmentFailed))):
                guard let destHash = state.links[id: elementID]?.destinationHash else { return .none }
                state.links.remove(id: elementID)
                return .send(.delegate(.linkFailed(destinationHash: destHash)))
```

(`linkID`/`destHash` are captured before removal; removing the `.forEach` element auto-cancels the link's timers, request timers, and hosted transfer watchdogs. The `.link(.element(_, .delegate(.transmit)))` relay case does not look up the element, so the LINKCLOSE is still relayed regardless of removal order.)

- [ ] **Step 2: Write the tests**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift`. Reuse the existing active-link store helper (e.g. `endpointWithActiveLink(...)` from the request-handler slice, or the two-store establish helper) to place an active link into `state.links`, then fire the terminal delegate directly:

```swift
@Test @MainActor func closedLinkIsRemovedFromEndpoint() async {
    let clock = TestClock()
    let linkID = Data(repeating: 0xAB, count: 16)
    let (store, elementID) = endpointWithActiveLink(linkID: linkID, remoteIdentity: nil,
                                                    registrations: [:], responder: .testValue, clock)
    await store.send(.link(.element(id: elementID, action: .delegate(.closed(.initiatorClosed)))))
    await store.receive { action in
        if case let .delegate(.linkClosed(lid, reason)) = action { return lid == linkID && reason == .initiatorClosed }
        return false
    }
    #expect(store.state.links[id: elementID] == nil)           // removed
}

@Test @MainActor func establishmentFailedLinkIsRemovedFromEndpoint() async {
    let clock = TestClock()
    let linkID = Data(repeating: 0xAB, count: 16)
    let (store, elementID) = endpointWithActiveLink(linkID: linkID, remoteIdentity: nil,
                                                    registrations: [:], responder: .testValue, clock)
    let destHash = store.state.links[id: elementID]!.destinationHash
    await store.send(.link(.element(id: elementID, action: .delegate(.establishmentFailed))))
    await store.receive { action in
        if case let .delegate(.linkFailed(dh)) = action { return dh == destHash }
        return false
    }
    #expect(store.state.links[id: elementID] == nil)           // removed
}
```

> Implementer note: `endpointWithActiveLink(...)` already exists in `EndpointTests.swift` (added in the request-handler slice) and returns `(store, elementID)`. Confirm its exact signature and the `RequestResponder.testValue` symbol; if the helper differs, adapt. The REQUIRED assertions (do NOT weaken): after the terminal delegate, `state.links[id: elementID] == nil`, and the `linkClosed`/`linkFailed` delegate still surfaces with the correct `linkID`/`reason`/`destHash`.

- [ ] **Step 3: Run to verify + fix regressions**

Run: `swift test --filter Endpoint`
Expected: PASS. **If a pre-existing two-store test closes a link and then asserts `state.links.count == 1` (or inspects `state.links[0]`) afterward, that assertion now flips** — update it to assert the link was removed (`state.links.isEmpty` / `count == 0`), because that is the new correct behavior. Confirm the existing `twoEndpointsEstablishLinkExchangeDataAndClose` (or equivalent) still verifies the LINKCLOSE packet is transmitted before the link vanishes.

- [ ] **Step 4: Full-suite gate**

Run: `swift test`
Expected: PASS. Report the pass/skip counts. Fix any other file that asserted a terminal element lingers (same rule: update to expect removal, never weaken).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter Endpoint`, confirm the named test fails, revert; final full `swift test` green:
- Remove `state.links.remove(id: elementID)` from the `.closed` case → `closedLinkIsRemovedFromEndpoint` fails.
- Remove `state.links.remove(id: elementID)` from the `.establishmentFailed` case → `establishmentFailedLinkIsRemovedFromEndpoint` fails.

- [ ] **Step 6: Commit the tests + source**

```
git add Sources/ReTiCANode/Endpoint.swift Tests/ReTiCANodeTests/EndpointTests.swift
git commit -F /tmp/ReTiCA/commit-gc2a.txt
```
(First line: `feat: Endpoint removes closed/failed links from its collection`, blank line, trailers.)

- [ ] **Step 7: Update the README**

In `README.md`, find any note stating that closed links (or terminal transfers) stay inert / that GC is a future/deferred slice, and replace it with the current behavior:

```markdown
Closed and establishment-failed links are removed from the endpoint's link collection as soon as their
terminal delegate fires (`linkClosed` / `linkFailed`), and concluded or failed resource transfers are
removed from their link. Removing a link also cancels any of its in-flight timers (keepalive/inactivity)
and outstanding request timers, and clears its pending requests — so terminal state and timers do not
accumulate.
```

- [ ] **Step 8: Commit the README**

```
git add README.md
git commit -F /tmp/ReTiCA/commit-gc2b.txt
```
(First line: `docs: reactive GC of closed links + terminal transfers`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- Remove concluded/failed transfers from `LinkSession.transfers` → Task 1 Step 3. ✓
- Clear `pendingRequests` + cancel request timers on all four close paths → Task 1 Steps 1-2. ✓
- Remove closed / establishment-failed links from `Endpoint.links` → Task 2 Step 1. ✓
- Delegates fire before removal with unchanged values; LINKCLOSE still transmits → preserved (delegate values captured pre-removal; transmit action precedes `.closed`; relay case is element-independent). ✓
- Regression: update any test asserting a lingering terminal element → Task 1 Step 5 + Task 2 Steps 3-4. ✓
- Zero wire change / no cross-val / no new dependency → Global Constraints. ✓
- Deferred (resourceFailed-on-close, janitor/grace-window) → untouched. ✓

**Placeholder scan:** No TBD/TODO in production steps. The test-helper notes are explicit implementer guidance (helper construction must match the real per-file `LinkSession.State`/`endpointWithActiveLink` APIs) with the assertions locked — not missing implementation.

**Type consistency:** `cancelPending(_ state: inout State) -> Effect<Action>`, `CancelID.request(Data)`, `state.pendingRequests.removeAll()`, `state.transfers.remove(id:)`, `state.links.remove(id:)`, and the unchanged `resourceConcluded(_:)`/`resourceFailed(_:)`/`requestFailed(requestID:)`/`linkClosed(linkID:reason:)`/`linkFailed(destinationHash:)` delegates are used identically across both tasks. The four close paths and both terminal-transfer branches all follow the read-then-remove ordering. `endpointWithActiveLink(...)` / `RequestResponder.testValue` reuse the request-handler slice's existing test helpers.
