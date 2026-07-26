# Maintenance Lifecycle Wiring + Relay-Stop Cleanup Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-run table GC in production (Endpoint starts the maintenance tick on connect, stops on disconnect) and clean up relay-only state when relaying stops (`setTransportIdentity(nil)`).

**Architecture:** Two small production edits — `Endpoint.swift` merges `.transport(.startMaintenance)`/`.stopMaintenance` into its connect/disconnect handlers; `Transport.swift`'s `setTransportIdentity(nil)` cancels pending announce timers and clears `announceTable`/`linkTable`. Plus behavior-focused tests. No wire behaviour change; no test migration (all Endpoint tests are already `.off`).

**Tech Stack:** Swift, The Composable Architecture (~1.26): `.merge`/`.send`/`.cancel(id:)`, `TestClock`, `DateGenerator`, `LockIsolated`.

## Global Constraints

- Wire-compatible with Python-RNS 1.3.8. Core `Sources/ReTiCA/*` stays zero-dep and **untouched** — changes only in `Sources/ReTiCANode/Endpoint.swift`, `Sources/ReTiCATransport/Transport.swift`, and `Tests/*`.
- Commit **directly to `main`** — no feature branch. The commit leaves the FULL suite green.
- **No compound shell commands** — one command per shell call (a single `|` pipeline or `>` redirect allowed). Run `swift build`, `swift test`, `git add`, `git commit` separately. Never inline a script into an interpreter; write it to a file under `/tmp/ReTiCA/` and run the file.
- Temp files under `/tmp/ReTiCA/`.
- **Mutation-testing verification** for every new test: run pass → batch-mutate → confirm fail → revert → confirm pass. Verify interacting mutations independently.
- **New TCA tests are non-exhaustive** (`store.exhaustivity = .off`) and assert outcomes, not the action trace ([[tca-tests-non-exhaustive]]).
- Reference RNS at `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/RNS/`. Build gotcha: signal-11/SIGILL → `swift package clean` then retry.
- Commit trailers (exact, both lines):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

Spec: `docs/superpowers/specs/2026-07-25-maintenance-lifecycle-design.md`.

## Grounding facts (verified — do not re-derive)

- Endpoint connect/disconnect handlers (`Endpoint.swift:90-93`):
  ```swift
  case .interface(.connectionEvent(.connected)):
      return .send(.transport(.interfaceConnected(id)))
  case .interface(.connectionEvent(.disconnected)):
      return .send(.transport(.interfaceDisconnected(id)))
  ```
  (`.connectionEvent(.disconnected)` is the interface REPORTING a drop — distinct from the `.disconnect` command at line 82.)
- Transport `setTransportIdentity` handler (`Transport.swift:116-118`):
  ```swift
  case let .setTransportIdentity(identity):
      state.transportIdentity = identity
      return .none
  ```
- `Transport.Action` already has `.startMaintenance`, `.stopMaintenance`, `.maintenanceTick`; `private enum CancelID { case announceRetransmit(Data); case maintenance }`; `State.announceTable: [Data: PendingAnnounce]`, `State.linkTable: [Data: LinkTableEntry]`. Statics `pathExpiry = 604800`, `maintenanceTickInterval = 60`, `announceRebroadcastWindow = 0.5`. The Transport reducer stamps timestamps from `@Dependency(\.transportDate)` (testValue = epoch; expiry tests set `$0.transportDate`).
- `.startMaintenance` is `.cancellable(id: .maintenance, cancelInFlight: true)` (idempotent). `.stopMaintenance` is `.cancel(id: .maintenance)`. Both proven in the Transport tests `stopMaintenanceCancelsTheTick` etc.
- ALL Endpoint tests are already `.off` (helpers `makeStore` line 39, the inline `make` factories at 270/410/549/684, and the inline stores at 782/877/892/977/992/1116 all set `.off`); none flips to `.on`. Endpoint tests leave `transportDate` at epoch, so a fired tick sweeps nothing (age 0). ⇒ auto-wiring the tick breaks NO existing Endpoint test.
- `makeStore` (EndpointTests.swift:26-41) builds an Endpoint TestStore + a `TCPEvent` stream; the pattern to control the sweep clock/date is to add `$0.continuousClock = <TestClock>` (already there) and `$0.transportDate = DateGenerator { <LockIsolated>.value }`.
- Helpers: `relayStoreKnowingDestDirectly()` → `(store, relay, destHash, outIf)` (a bare relay knowing a dest directly, one interface `outIf`, no timers); `makeAnnouncePacket(hops:emitted:)`; `makeHeader2LinkRequestPacket(transportId:destHash:hops:payload:)`; `Link.linkID(requestPacket:)`. EndpointTests imports `@testable import ReTiCATransport` (so `Transport.pathExpiry` etc. are accessible).

---

### Task 1: Maintenance lifecycle wiring + relay-stop cleanup

**Files:**
- Modify: `Sources/ReTiCANode/Endpoint.swift`, `Sources/ReTiCATransport/Transport.swift`.
- Test: `Tests/ReTiCANodeTests/EndpointTests.swift`, `Tests/ReTiCATransportTests/TransportTests.swift`.

- [ ] **Step 1: Wire maintenance start/stop into the Endpoint**

Replace `Endpoint.swift:90-93` with:

```swift
            case .interface(.connectionEvent(.connected)):
                return .merge(.send(.transport(.interfaceConnected(id))),
                              .send(.transport(.startMaintenance)))
            case .interface(.connectionEvent(.disconnected)):
                return .merge(.send(.transport(.interfaceDisconnected(id))),
                              .send(.transport(.stopMaintenance)))
```

- [ ] **Step 2: Clean up relay state on `setTransportIdentity(nil)`**

Replace `Transport.swift:116-118` with:

```swift
            case let .setTransportIdentity(identity):
                state.transportIdentity = identity
                guard identity == nil else { return .none }
                // Stopped relaying: cancel pending re-broadcasts and drop relay-only routing state.
                let cancels = state.announceTable.keys
                    .map { Effect<Action>.cancel(id: CancelID.announceRetransmit($0)) }
                state.announceTable = [:]
                state.linkTable = [:]
                return cancels.isEmpty ? .none : .merge(cancels)
```

- [ ] **Step 3: Build**

Run: `swift build`
Expected: compiles. (Editor "No such module 'ComposableArchitecture'" is a known false positive.)

- [ ] **Step 4: Run the full suite (no migration expected)**

Run: `swift test`
Expected: all pass unchanged (baseline 346 pass / 1 skip). All Endpoint tests are `.off` and leave `transportDate` at epoch, so the auto-started tick is tolerated at deinit and sweeps nothing. If any test fails, STOP and report.

- [ ] **Step 5: Add the tests**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift`:

```swift
// MARK: - 4b-3c-2 maintenance lifecycle

/// Connecting an Endpoint starts the maintenance tick: a learned path is swept once it ages past
/// pathExpiry and the tick fires. (End-to-end proof the Endpoint auto-started GC.)
@Test @MainActor func endpointStartsGcOnConnectAndSweepsExpiredPath() async {
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 0))
    let events = AsyncStream<TCPEvent>.makeStream()
    let store = TestStore(initialState: Endpoint.State(host: "h", port: 4242, reconnectOnDrop: false)) {
        Endpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in events.stream }, send: { _ in }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.transportDate = DateGenerator { now.value }
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    let id = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(identity: id, appName: "app", aspects: ["svc"],
                                                     hops: 3, emitted: 1000)
    await store.send(.connect)
    events.continuation.yield(.connected)               // → interfaceConnected + startMaintenance
    await store.receive(\.transport.interfaceConnected)
    events.continuation.yield(.data(HDLC.frame(announceRaw)))
    await store.receive(\.delegate.pathLearned)
    #expect(store.state.transport.learned[destHash] != nil)
    // Age past pathExpiry and fire the tick → path swept.
    now.setValue(Date(timeIntervalSince1970: Transport.pathExpiry + 1))
    await clock.advance(by: .seconds(Transport.maintenanceTickInterval))
    await store.receive(\.transport.maintenanceTick)
    #expect(store.state.transport.learned[destHash] == nil)
}

/// Disconnecting an Endpoint stops the maintenance tick (the Endpoint forwards .stopMaintenance).
@Test @MainActor func endpointStopsMaintenanceOnDisconnect() async {
    let (store, events) = makeStore()
    await store.send(.connect)
    events.yield(.connected)
    await store.receive(\.transport.interfaceConnected)
    events.yield(.disconnected)                          // → interfaceDisconnected + stopMaintenance
    await store.receive(\.transport.stopMaintenance)
}
```

Append to `Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
/// Stopping relaying cancels a pending announce re-broadcast retry and clears the announce table.
@Test @MainActor func relayStopCancelsPendingRebroadcastAndClearsAnnounceTable() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = clock
        $0.transportDate = .constant(Date(timeIntervalSince1970: 0))
        $0.randomBytes = RandomBytesGenerator { _ in Data([128]) }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(Identity()))
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))                     // send #1 → retry pending
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash] != nil)
    // Stop relaying → cancel the pending retry + clear the table.
    await store.send(.setTransportIdentity(nil))
    #expect(store.state.announceTable.isEmpty)
    // The retry timer was cancelled: advancing past the retry fires no re-broadcast.
    store.exhaustivity = .on
    await clock.advance(by: .seconds(10))
}

/// Stopping relaying clears the link table (relay reverse-routing is meaningless without relay mode).
@Test @MainActor func relayStopClearsLinkTable() async {
    let (store, relay, destHash, _) = await relayStoreKnowingDestDirectly()
    let payload = Data(repeating: 0x11, count: 64) + Data([0, 0, 0])
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    await store.send(.received(InterfaceID("in"), lr))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.linkTable[linkID] != nil)
    await store.send(.setTransportIdentity(nil))
    #expect(store.state.linkTable.isEmpty)
}
```

> If `TCPConnection`/`TCPEvent`/`makeStore` signatures differ from the above, match the exact form used at `EndpointTests.swift:26-41`. `DateGenerator`/`LockIsolated` come with `import ComposableArchitecture`.

- [ ] **Step 6: Run the new tests**

Run: `swift test --filter "endpointStartsGcOnConnectAndSweepsExpiredPath|endpointStopsMaintenanceOnDisconnect|relayStopCancelsPendingRebroadcastAndClearsAnnounceTable|relayStopClearsLinkTable"`
Expected: all pass.

- [ ] **Step 7: Mutation verification**

Apply and confirm the mapped test fails; verify interacting ones independently:
1. Endpoint connect drops `.startMaintenance` (revert to a single `.send(.transport(.interfaceConnected(id)))`) → `endpointStartsGcOnConnectAndSweepsExpiredPath` fails (no tick fires; `receive(\.transport.maintenanceTick)` times out / path not swept).
2. Endpoint disconnect drops `.stopMaintenance` → `endpointStopsMaintenanceOnDisconnect` fails (`receive(\.transport.stopMaintenance)` times out).
3. `setTransportIdentity(nil)` skips the cancel/`.merge(cancels)` (return `.none` after clearing) → `relayStopCancelsPendingRebroadcastAndClearsAnnounceTable` fails (the retry fires under `.on` → the unreceived `.announceRetransmitDue`/transmit trips cleanup).
4. `setTransportIdentity(nil)` skips `state.linkTable = [:]` → `relayStopClearsLinkTable` fails.
5. `setTransportIdentity(nil)` skips `state.announceTable = [:]` → `relayStopCancelsPendingRebroadcastAndClearsAnnounceTable` fails on `announceTable.isEmpty`.

Run: `swift test`. Then revert all and re-run — expect all pass.

- [ ] **Step 8: Full suite**

Run: `swift test`
Expected: all pass (baseline 346 + 4 new → ~350 / 1 skip).

- [ ] **Step 9: Commit**

Write the message to `/tmp/ReTiCA/commit-t1.txt`, `git add` the changed files, `git commit -F`.

```
feat: Endpoint auto-runs GC; relay-stop cancels re-broadcasts + clears tables

Endpoint starts the maintenance tick on connect and stops it on disconnect, so
table GC finally runs in production via the Node layer. Transport's
setTransportIdentity(nil) cancels every pending announce re-broadcast/retry
timer and clears announceTable + linkTable, so a de-relayed node emits no stale
re-broadcasts and holds no dangling relay state. All Endpoint tests are already
non-exhaustive, so no migration. Core untouched.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Notes for the executor

- After this task, the slice (4b-3c-2) is done — and the whole 4b-3c maintenance sub-project (tick + expiry + lifecycle wiring + relay-stop cleanup) is complete. A final whole-slice review is warranted, then the full `swift test` gate on `main` and updating the `transport-relaying` memory (4b-3c done; next is #4c path requests → LXMF).
- Do NOT touch `Sources/ReTiCA/*`. Multi-interface relay nodes are bare `Transport` stores the app wires directly (they call `.startMaintenance`); only the single-interface `Endpoint` auto-wires it here.
- No cross-validation task: this slice adds no new wire-visible constants or bytes (the GC timeout constants were cross-validated in 4b-3c-1).
