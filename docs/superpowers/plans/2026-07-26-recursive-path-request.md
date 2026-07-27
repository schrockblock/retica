# Transport #4c-3b: Recursive PATH_REQUEST Re-broadcast — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** When an opt-in relay receives a PATH_REQUEST for a destination it does not know, re-broadcast the request onward (all interfaces except the arrival one) for recursive path discovery.

**Architecture:** All changes in `Sources/ReTiCATransport/Transport.swift` (TCA state + reducer). Add an opt-in `recursivePathRequests` flag (+ `.setRecursivePathRequests` action), a `discoveryPathRequests: [Data: Date]` per-destination in-flight table (dedup + GC), and a recursive branch replacing the terminal `return .none` of the PATH_REQUEST responder — gated on relay mode + the flag + `learned[requested] == nil` (path genuinely unknown) + no in-flight search. The re-broadcast reuses the request's tag so loop-back copies die at the #4c-3a `discoveryPrTags` ring.

**Tech Stack:** Swift, The Composable Architecture (TCA), Swift Testing, genuine RNS 1.3.8 (conda `rns` env) for cross-validation.

## Global Constraints

- Commit directly to `main`; no feature branch.
- No compound shell commands (no `&&`, `||`, `;`, `xargs`, inline interpreter scripts). One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to write files — use editor tools.
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test: (a) run pass; (b) batch-mutate production to force fail + confirm each fails; (c) revert + confirm pass. When mutations interact, verify them one at a time.
- TCA tests are non-exhaustive (`store.exhaustivity = .off`), asserting outcomes. For "no re-broadcast" assertions, send in `.off` then flip `store.exhaustivity = .on` as the LAST statement (nothing after) so a stray transmit is an un-received delegate action caught at teardown.
- Data slicing is COUNT-based (`Data(payload.prefix(16))`, `Data(payload.dropFirst(16).prefix(16))`), never index-based.
- Pure core (`Sources/ReTiCA/*`) untouched; changes confined to `Transport.swift`, its tests, and the cross-val fixture generator/vectors.
- Cross-val fixtures MUST derive from genuine RNS values, never hand-rolled.
- RNS pins: recursive re-broadcast forwards to all interfaces except the requestor's (Transport.py:3063-3064); payload = `destination_hash + Transport.identity.hash + request_tag` reusing the inbound tag (Transport.py:2811, 3068-3070); recursion requires `transport_enabled()` (Transport.py:2945) → our relay mode; `discovery_path_requests` per-dest dedup (Transport.py:3045); `PATH_REQUEST_TIMEOUT = 15` (Transport.py:79); answer-from-cache is an `elif (dest in path_table)` so a known path never recurses (Transport.py:2972).
- Build gotcha: signal-11/SIGILL → `swift package clean` then retry.
- Commit trailers, exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

**Spec:** `docs/superpowers/specs/2026-07-26-recursive-path-request-design.md`
**Base:** this plan's own commit (verify with `git log --oneline <planCommit>..HEAD`, never `HEAD~1`).

---

## File Structure

- **Modify** `Sources/ReTiCATransport/Transport.swift`
  - `State`: add `recursivePathRequests` + `discoveryPathRequests` (after the `discoveryPrTags` field, ~line 47).
  - `Action`: add `case setRecursivePathRequests(Bool)` (after `setTransportIdentity`, ~line 85).
  - handler for `.setRecursivePathRequests` (near the `.setTransportIdentity` handler, ~line 149).
  - recursive branch: replace the terminal `return .none` of the PATH_REQUEST responder (~line 327).
  - static `pathRequestTimeout` (near `pathExpiry`, ~line 467); `discoveryPathRequests` GC in `.maintenanceTick` (~line 386).
- **Modify** `Tests/ReTiCATransportTests/TransportTests.swift`: recursive-branch behavioral tests; GC test.
- **Modify** `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`: emit a genuine RNS 48-byte relay path-request.
- **Regenerate** `Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`.
- **Modify** `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`: add fixture fields.
- **Modify** `Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift`: 48-byte relay-request slicing parity test.

---

## Task 1: Recursive re-broadcast branch + flag + dedup

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (State fields; Action case; setRecursivePathRequests handler; recursive branch)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Produces: `Transport.State.recursivePathRequests: Bool`, `Transport.State.discoveryPathRequests: [Data: Date]`, `Transport.Action.setRecursivePathRequests(Bool)`. Task 2 consumes `discoveryPathRequests` (GC).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCATransportTests/TransportTests.swift` (the `makePathRequest(for:tag:)` helper at ~line 1742 builds `destHash ‖ tag`, default tag `0x5A`×16):

```swift
// MARK: - #4c-3b recursive path request re-broadcast

/// An opt-in relay re-broadcasts an unknown-path request onto every interface except the arrival
/// one, with payload dest ‖ our transport_id ‖ the same tag (RNS path_request:3044-3070).
@Test @MainActor func recursiveRelayRebroadcastsUnknownPathRequest() async {
    let relay = Identity()
    let unknown = Data(repeating: 0x99, count: 16)
    let tag = Data(repeating: 0x5A, count: 16)          // makePathRequest default tag
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))
    await store.send(.setRecursivePathRequests(true))
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: unknown)))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action { captured.setValue((ifID, raw)); return true }
        return false
    }
    let (ifID, raw) = captured.value!
    #expect(ifID == InterfaceID("i1"))                  // re-broadcast on the non-arrival interface
    let p = Packet(raw: raw)!
    #expect(p.destinationHash == Transport.pathRequestDestinationHash)
    #expect(p.packetType == .data)
    #expect(p.payload == unknown + relay.hash + tag)    // dest ‖ our transport_id ‖ same tag
    #expect(store.state.discoveryPathRequests[unknown] != nil)
}

/// Recursion disabled (flag false) → no re-broadcast.
@Test @MainActor func recursionDisabledDoesNotRebroadcast() async {
    let relay = Identity()
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))       // flag stays false
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: Data(repeating: 0x99, count: 16))))
    store.exhaustivity = .on
}

/// A non-relay (transportIdentity == nil) never re-broadcasts, even with the flag set.
@Test @MainActor func nonRelayDoesNotRebroadcast() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setRecursivePathRequests(true))    // flag on, but no transport identity
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: Data(repeating: 0x99, count: 16))))
    store.exhaustivity = .on
}

/// A known path (learned) never recurses — even if its announce cache is empty (RNS elif structure:
/// a path_table hit never falls through to should_search_for_unknown).
@Test @MainActor func knownButUncachedPathDoesNotRecurse() async {
    let relay = Identity()
    let dest = Data(repeating: 0x99, count: 16)
    var initial = Transport.State()
    initial.interfaces = [InterfaceID("i0"), InterfaceID("i1")]
    initial.transportIdentity = relay
    initial.recursivePathRequests = true
    initial.learned[dest] = LearnedDestination(
        identity: Identity(), appData: nil, ratchet: nil, interfaceID: InterfaceID("i1"),
        hops: 2, nextHop: nil, announceEmitted: 1000, learnedAt: Date(timeIntervalSince1970: 1000))
    // Note: announceCache[dest] is intentionally absent → the #4c-2 relay-cache branch is skipped.
    let store = TestStore(initialState: initial) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: dest)))
    store.exhaustivity = .on          // learned != nil → recursion suppressed → no transmit
}

/// A second unknown-path request for the SAME destination (fresh tag) does not re-broadcast again
/// while the first search is in flight (RNS discovery_path_requests dedup, Transport.py:3045).
@Test @MainActor func duplicateDestinationDoesNotRebroadcastTwice() async {
    let relay = Identity()
    let unknown = Data(repeating: 0x99, count: 16)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))
    await store.send(.setRecursivePathRequests(true))
    // First unknown request (tag A) → re-broadcasts.
    await store.send(.received(InterfaceID("i0"),
                               makePathRequest(for: unknown, tag: Data(repeating: 0xA1, count: 16))))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    // Second unknown request, same dest, different tag → deduped by discoveryPathRequests, no re-broadcast.
    await store.send(.received(InterfaceID("i0"),
                               makePathRequest(for: unknown, tag: Data(repeating: 0xB2, count: 16))))
    store.exhaustivity = .on
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "ecursi\|nonRelayDoesNotRebroadcast\|duplicateDestination\|knownButUncached" 2>&1 | tail -40`
Expected: compile failure (no `recursivePathRequests` / `setRecursivePathRequests` / `discoveryPathRequests` yet), or once those exist, the recursion tests fail (no re-broadcast produced).

- [ ] **Step 3: Add the state fields**

In `State`, after the `discoveryPrTags` field (~line 47):

```swift

        /// Opt-in: when set (and in relay mode), a PATH_REQUEST for an unknown destination is
        /// re-broadcast onward for recursive discovery (RNS recursive_prs, Transport.py:2946).
        public var recursivePathRequests = false

        /// destHash → when a recursive search for it began. Coalesces concurrent searches for the
        /// same destination; GC'd after pathRequestTimeout (RNS discovery_path_requests, Transport.py:3060).
        public var discoveryPathRequests: [Data: Date] = [:]
```

- [ ] **Step 4: Add the action + handler**

In `Action`, after `case setTransportIdentity(Identity?)` (~line 85):

```swift
        case setRecursivePathRequests(Bool)
```

In the reducer, after the `.setTransportIdentity` handler's `return` (~line 157), add:

```swift
            case let .setRecursivePathRequests(enabled):
                state.recursivePathRequests = enabled
                return .none
```

- [ ] **Step 5: Add the recursive branch**

In the PATH_REQUEST responder, replace the terminal `return .none` (~line 327, immediately after the #4c-2 relay-cache `if` block closes and before the `}` that ends the `if packet.destinationHash == Transport.pathRequestDestinationHash` block) with:

```swift
                        // (3) Path unknown: if recursion is enabled (relay + opt-in) and we are not
                        // already searching for this destination, re-broadcast onward for recursive
                        // discovery (RNS path_request:3044-3070). Reusing the tag makes a looped-back
                        // copy die at the #4c-3a discoveryPrTags ring.
                        if let relayID = state.transportIdentity, state.recursivePathRequests,
                           state.learned[requested] == nil,
                           state.discoveryPathRequests[requested] == nil {
                            state.discoveryPathRequests[requested] = date.now
                            let fwd = Packet(
                                headerType: .header1, packetType: .data, transportType: .broadcast,
                                destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                                destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                                payload: requested + relayID.hash + tag)
                            guard let raw = try? fwd.packed() else { return .none }
                            let sends = state.interfaces.filter { $0 != interfaceID }
                                .map { Effect<Action>.send(.delegate(.transmit($0, raw))) }
                            return sends.isEmpty ? .none : .merge(sends)
                        }
                        return .none
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter "ecursi\|nonRelayDoesNotRebroadcast\|duplicateDestination\|knownButUncached" 2>&1 | tail -40`
Expected: all five new tests PASS; existing PATH_REQUEST tests (owner/relay answers, entry gate) still PASS.

- [ ] **Step 7: Mutation-verify (three-step)**

Verify these mutations ONE AT A TIME (reverting between — they gate the same branch):
1. Remove the `state.recursivePathRequests` condition (always recurse in relay mode): `recursionDisabledDoesNotRebroadcast` fails (a disabled relay now re-broadcasts).
2. Remove the `state.learned[requested] == nil` condition: `knownButUncachedPathDoesNotRecurse` fails (a known path now recurses).
3. Remove the `state.discoveryPathRequests[requested] == nil` condition (and the record line stays): `duplicateDestinationDoesNotRebroadcastTwice` fails (the second same-dest request re-broadcasts).
4. Change the fan-out filter `{ $0 != interfaceID }` to `{ _ in true }`: `recursiveRelayRebroadcastsUnknownPathRequest` fails (re-broadcast now also goes to the arrival interface — an extra transmit).

For each: apply, `swift test --filter "ecursi\|nonRelay\|duplicateDestination\|knownButUncached"`, confirm the named test fails, revert. Then a clean run: all PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/commit-4c3b-t1.txt
```

(Message e.g. `feat: transport #4c-3b task 1 — recursive PATH_REQUEST re-broadcast (opt-in relay)` plus trailers.)

---

## Task 2: discoveryPathRequests GC

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (static constant; `.maintenanceTick` sweep)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: `State.discoveryPathRequests` (Task 1).

- [ ] **Step 1: Write the failing test**

Add to `Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
/// An in-flight recursive search older than pathRequestTimeout is swept by maintenanceTick; a fresh
/// one survives (RNS stale discovery_path_requests cull, Transport.py:3060).
@Test @MainActor func staleRecursiveSearchIsSweptByMaintenanceTick() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let relay = Identity()
    let unknown = Data(repeating: 0x99, count: 16)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))
    await store.send(.setRecursivePathRequests(true))
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: unknown)))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.discoveryPathRequests[unknown] != nil)

    await store.send(.startMaintenance)
    // Not yet expired: a tick within the window keeps the entry.
    now.setValue(Date(timeIntervalSince1970: 5))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.discoveryPathRequests[unknown] != nil)
    // Past the timeout: the next tick sweeps it.
    now.setValue(Date(timeIntervalSince1970: Transport.pathRequestTimeout + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(.maintenanceTick)
    #expect(store.state.discoveryPathRequests[unknown] == nil)
    await store.send(.stopMaintenance)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter "staleRecursiveSearch" 2>&1 | tail -20`
Expected: FAIL — `pathRequestTimeout` does not exist yet / the entry is never swept.

- [ ] **Step 3: Add the constant**

In `Sources/ReTiCATransport/Transport.swift`, near `pathExpiry` (~line 467):

```swift
    static let pathRequestTimeout: TimeInterval = 15      // RNS PATH_REQUEST_TIMEOUT (Transport.py:79)
```

- [ ] **Step 4: Add the GC sweep**

In the `.maintenanceTick` handler, after the `linkTable` expiry loop (~line 386, before `return .none`):

```swift
                for (dest, startedAt) in state.discoveryPathRequests
                where now.timeIntervalSince(startedAt) > Transport.pathRequestTimeout {
                    state.discoveryPathRequests[dest] = nil
                }
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter "staleRecursiveSearch" 2>&1 | tail -20`
Expected: PASS.

- [ ] **Step 6: Mutation-verify (three-step)**

Mutate: comment out the `state.discoveryPathRequests[dest] = nil` line. Run `swift test --filter "staleRecursiveSearch"`. Expected: FAIL (the stale entry is not swept). Revert; run again; expected PASS.

- [ ] **Step 7: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/commit-4c3b-t2.txt
```

(Message e.g. `feat: transport #4c-3b task 2 — discoveryPathRequests GC (15s timeout)` plus trailers.)

---

## Task 3: Cross-validate the 48-byte relay request slicing vs genuine RNS

**Files:**
- Modify: `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`
- Regenerate: `Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`
- Modify: `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`
- Modify: `Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift`

**Interfaces:**
- Consumes: the payload composition/parse offsets used by the recursive branch (Task 1) and the #4c-2 relay loop-guard.

**Context:** The recursive re-broadcast emits a 48-byte relay request `dest ‖ transport_id ‖ tag` (RNS `request_path` with `transport_enabled()`, Transport.py:2811). #4c-3a cross-validated tag slicing only for the 32-byte non-relay request. This task extends that to the 48-byte relay layout — validating the transport_id offset (bytes 16..32) and tag offset (bytes 32..48) against genuine-RNS-shaped request bytes, which is exactly what our recursive branch produces and our #4c-2 loop-guard parses.

- [ ] **Step 1: Extend the generator**

In `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`, after the `pr_tag` block (added in #4c-3a), add:

```python
# --- #4c-3b recursive (relay) path request cross-validation ---
# Genuine RNS relay path-request payload: dest ‖ transport_id ‖ tag (RNS request_path with
# transport_enabled, Transport.py:2811). transport_id is a genuine RNS identity hash.
_pr_recursive_relay = RNS.Identity()
_pr_recursive_payload = dest_hash + _pr_recursive_relay.hash + _pr_tag
```

and add to the `json.dumps({...})` dict:

```python
    "pr_recursive_relay_hash": _pr_recursive_relay.hash.hex(),
    "pr_recursive_payload": _pr_recursive_payload.hex(),
```

- [ ] **Step 2: Regenerate the fixture JSON**

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py > Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`
Expected: exit 0; JSON now has `pr_recursive_relay_hash` (16-byte hex) and `pr_recursive_payload` (48-byte hex), with `pr_recursive_payload == pr_requested_dest ‖ pr_recursive_relay_hash ‖ pr_tag`.

- [ ] **Step 3: Add fixture fields to the Swift struct**

In `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`, add properties near `prTag`:

```swift
    let prRecursiveRelayHash: String
    let prRecursivePayload: String
```

and CodingKeys:

```swift
        case prRecursiveRelayHash = "pr_recursive_relay_hash"
        case prRecursivePayload = "pr_recursive_payload"
```

- [ ] **Step 4: Write the cross-val test**

In `Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift`, add:

```swift
/// Our slicing of a 48-byte relay PATH_REQUEST (dest ‖ transport_id ‖ tag) matches genuine RNS's
/// layout — the transport_id (bytes 16..32, our #4c-2 loop guard) and tag (bytes 32..48, our #4c-3a
/// gate) offsets. Extends the 32-byte non-relay slicing check to the relay case.
@Test func relayPathRequestSlicingMatchesRns() throws {
    let f = try TransportVectorFixtures.load()
    let payload = Data(hexString: f.prRecursivePayload)!          // genuine RNS relay request (48 bytes)
    #expect(Data(payload.prefix(16)) == Data(hexString: f.prRequestedDest)!)
    #expect(Data(payload.dropFirst(16).prefix(16)) == Data(hexString: f.prRecursiveRelayHash)!)  // transport_id
    #expect(Data(payload.dropFirst(32).prefix(16)) == Data(hexString: f.prTag)!)                  // tag
    // And the recursive re-broadcast composes the payload the same way.
    #expect(Data(hexString: f.prRequestedDest)! + Data(hexString: f.prRecursiveRelayHash)!
            + Data(hexString: f.prTag)! == payload)
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter "TransportCrossValidation" 2>&1 | tail -20`
Expected: `relayPathRequestSlicingMatchesRns` PASSES; sibling cross-val tests still pass.

- [ ] **Step 6: Mutation-verify**

Mutate the test's transport_id slice (`dropFirst(16)` → `dropFirst(17)`) and confirm the assertion fails; revert and confirm it passes.

- [ ] **Step 7: Commit**

```bash
git add Tests/ReTiCATransportTests/Vectors/
git commit -F /tmp/ReTiCA/commit-4c3b-t3.txt
```

(Message e.g. `test: transport #4c-3b task 3 — cross-validate 48-byte relay request slicing vs RNS` plus trailers.)

---

## Self-Review

- **Spec coverage:** flag + action (Task 1); recursive branch + `learned==nil`/dedup guards + fan-out (Task 1); `discoveryPathRequests` GC + constant (Task 2); cross-val (Task 3). Interface-mode gating, rate-limiting, grace, requester throttle deferred (spec §Scope) — no task, by design.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type consistency:** `recursivePathRequests: Bool`, `discoveryPathRequests: [Data: Date]`, `setRecursivePathRequests(Bool)`, `pathRequestTimeout: TimeInterval`; `LearnedDestination(identity:appData:ratchet:interfaceID:hops:nextHop:announceEmitted:learnedAt:)` matches its init; fixture fields (`prRecursive*`) consistent across generator keys, struct, CodingKeys, and test.
- **Wire correctness:** payload `requested + relayID.hash + tag` matches RNS request_path (Transport.py:2811); fan-out excludes arrival interface (Transport.py:3063-3064); `learned==nil` mirrors the RNS `elif` (Transport.py:2972); timeout 15 = RNS PATH_REQUEST_TIMEOUT.
- **Integration:** recursive branch replaces the terminal `.none` only — owner (#4c-1), relay-cache (#4c-2), and entry-gate (#4c-3a) code above it are unchanged; normal `.data` handling below the pathRequest branch is untouched.
