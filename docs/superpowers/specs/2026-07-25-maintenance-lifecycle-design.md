# Transport Relaying 4b-3c-2 — Maintenance Lifecycle Wiring + Relay-Stop Cleanup

**Status:** approved (design)
**Date:** 2026-07-25
**Sub-project:** Transport relaying #4b, third sub-slice (4b-3), third piece (4b-3c), part 2 (final).
Prior merged: 4b-1, 4b-2, 4b-2b, 4b-3a, all of 4b-3b, 4b-3c-1 (maintenance tick).

## Problem

4b-3c-1 added the maintenance tick but it is **opt-in** (`.startMaintenance`) and nothing starts it in
production, so table GC never runs unless the consumer wires it. Separately, when a relay stops
relaying (`setTransportIdentity(nil)`), its pending announce re-broadcast/retry timers keep running
and would still emit re-broadcasts even though the node is no longer a relay, and its relay-only
routing tables (`announceTable`, `linkTable`) are left populated.

## Goal

1. **Auto-run GC in production** via the Node/Endpoint layer: start the maintenance tick when an
   Endpoint connects, stop it when it disconnects.
2. **Clean up on relay-stop**: on `setTransportIdentity(nil)`, cancel all pending announce timers and
   clear the relay-only tables, so a de-relayed node emits no stale re-broadcasts and holds no
   dangling relay state.

This completes the 4b-3c maintenance sub-project. No wire behaviour changes.

## Scope

**In scope (4b-3c-2):**
- Endpoint: send `.transport(.startMaintenance)` alongside `.interfaceConnected` on connect, and
  `.transport(.stopMaintenance)` alongside `.interfaceDisconnected` on disconnect.
- Transport: `setTransportIdentity(nil)` cancels every pending `CancelID.announceRetransmit` timer and
  clears `announceTable` and `linkTable`.
- Refactor the handful of inline **exhaustive** Endpoint tests (that connect and would now carry the
  standing tick) to non-exhaustive, asserting outcomes — per the project testing preference
  ([[tca-tests-non-exhaustive]]).

**Out of scope / deferred:**
- Removing `linkTable` entries whose interface disconnected (the tick's `linkTableExpiry` reaps idle
  ones; per-interface removal is a further refinement).
- Reverse/cache/tunnel tables (RNS-specific, not modelled here); AP/roaming path modes.
- Multi-interface relay nodes are bare `Transport` stores wired by the app; they call
  `.startMaintenance` directly (Endpoint is single-interface and never relays).

## Design

### 1. Endpoint: maintenance lifecycle (`Sources/ReTiCANode/Endpoint.swift`)

The connect/disconnect handlers currently forward a single transport action. Merge in the maintenance
start/stop:

```swift
            case .interface(.connectionEvent(.connected)):
                return .merge(.send(.transport(.interfaceConnected(id))),
                              .send(.transport(.startMaintenance)))
            case .interface(.connectionEvent(.disconnected)):
                return .merge(.send(.transport(.interfaceDisconnected(id))),
                              .send(.transport(.stopMaintenance)))
```

Because an Endpoint is single-interface, connect ⇒ start and disconnect ⇒ stop is the whole
lifecycle. `.startMaintenance` is idempotent (`cancelInFlight: true`), so a reconnect re-arms cleanly.

### 2. Transport: relay-stop cleanup (`Sources/ReTiCATransport/Transport.swift`)

Extend the `setTransportIdentity` handler:

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

Enabling relay (`identity != nil`) is unchanged (`return .none`). Only clearing to `nil` triggers
cleanup. The maintenance tick is NOT touched here (it is not relay-specific — it also GCs a leaf's
`learned` table).

### 3. What does NOT change

- The tick mechanism, sweep, timestamps, re-broadcast bytes, dedup, suppression, routing, retry
  lifecycle (4b-3c-1 and earlier). Core `Sources/ReTiCA/*` untouched.

## Test-migration impact

Most Endpoint tests already use `.off` helpers (`makeStore` / the inline `make` factories set
`store.exhaustivity = .off`), so they tolerate the now-auto-started standing tick at deinit. Only the
few Endpoint tests that build an **inline exhaustive** store and connect need attention: convert them
to `.off` and assert the outcomes they check (delegate actions, final state) rather than the exact
action trace. The plan enumerates the exact tests (found by running the suite after the Endpoint
change). No existing wire behaviour changes.

## Testing

### Unit
- **Endpoint runs GC on connect (`Tests/ReTiCANodeTests/EndpointTests.swift`):** connect an Endpoint,
  deliver an announce so a path is learned; with `$0.transportDate` advanced past `pathExpiry` and the
  `continuousClock` advanced past `maintenanceTickInterval`, the learned path is swept from
  `store.state.transport.learned`. (Confirms the Endpoint auto-started the tick.)
- **Endpoint stops GC on disconnect (outcome-based):** connect + learn a path, then disconnect; with
  `transportDate` advanced past `pathExpiry` and the clock advanced past several tick intervals, the
  learned path is **still present** — GC no longer runs, so nothing is swept. (Asserts the outcome —
  GC stopped — not the tick action itself, per [[tca-tests-non-exhaustive]].)
- **Relay-stop cancels pending re-broadcasts (`Tests/ReTiCATransportTests/TransportTests.swift`):** a
  relay holds a fresh announce (retry pending after send #1); `setTransportIdentity(nil)` → the
  `announceTable`/`linkTable` are cleared and advancing the clock fires no re-broadcast (the timer was
  cancelled).
- **Relay-stop clears linkTable:** create a `linkTable` entry (relayed LINKREQUEST), then
  `setTransportIdentity(nil)` → `linkTable` is empty.

### Cross-validation
None — this slice is pure lifecycle/GC wiring with no new wire-visible constants or bytes. (The GC
timeout constants were cross-validated in 4b-3c-1.)

## Constraints (project-wide)

- Wire-compatible with Python-RNS 1.3.8; core `Sources/ReTiCA/*` stays zero-dep and **untouched**.
- Commit **directly to `main`** — no feature branch ([[commit-directly-to-main]]). Every commit leaves
  the full suite green.
- No compound shell commands; temp files under `/tmp/ReTiCA/`.
- Mutation-testing verification for every new/changed test.
- New/converted TCA tests are non-exhaustive and assert outcomes ([[tca-tests-non-exhaustive]]).
- Commit trailers (exact):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
