# Transport #4c-3b: Recursive PATH_REQUEST Re-broadcast — Design

**Sub-project:** #4c Path Requests (4th slice, last of the #4c essentials). Follows #4c-1 (owner answer), #4c-2 (relay-cache answer), #4c-3a (entry gate: tag dedup + tagless-ignore). See `transport-relaying` memory.

**Goal.** When an opt-in relay receives a PATH_REQUEST for a destination it does not know, forward the request onward (to all interfaces except the arrival one) so path discovery reaches destinations more than one relay deep.

## Problem

#4c-1/#4c-2 let a requester learn a path only if the *owner* or a *directly-knowing relay* hears the request. In a deeper mesh, the requester is often several relays from the destination, and the intermediate relay that hears the request does not know the path. RNS handles this by re-broadcasting the request onward (Transport.py:3044-3070) — recursive discovery — so it propagates until it reaches a node that can answer, whose pathResponse then flows back along the reverse path.

Without recursion, ReTiCA path discovery is limited to one-relay-deep. This slice adds it, gated to stay storm-safe.

## Scope

**In scope:**
1. An opt-in `recursivePathRequests` flag (per-Transport, default off) plus a `.setRecursivePathRequests(Bool)` action.
2. A `discoveryPathRequests` per-destination in-flight table for dedup + time-bounded GC.
3. The recursive re-broadcast branch: on an unknown-path request, re-broadcast to all non-arrival interfaces with our transport_id and the same tag.
4. GC of `discoveryPathRequests` in `maintenanceTick`.
5. Cross-validation of the recursive request payload format against genuine RNS.

**Out of scope / deferred:**
- **Interface-mode gating.** RNS gates recursion on `recursive_prs` / `DISCOVER_PATHS_FOR` interface modes (Transport.py:2946-2947). ReTiCA does not model interface modes, so recursion is triggered by the opt-in Transport flag instead (user-chosen). Recursion additionally requires relay mode (`transportIdentity != nil`), matching RNS's `transport_enabled()` prerequisite (Transport.py:2945).
- **Ingress/egress PR rate-limiting** (`should_ingress_limit_pr` / `should_egress_limit_pr` / `announce_cap`) — pure RNS interface machinery ReTiCA does not model.
- **`PATH_REQUEST_GRACE` timing** and **requester-side `path_requests` throttle** — deferred (optional polish, earlier user choice).

## Architecture

All changes in `Sources/ReTiCATransport/Transport.swift` (TCA state + reducer). Pure core (`Sources/ReTiCA/*`) untouched.

### 1. New state

```swift
/// Opt-in: when set (and in relay mode), a PATH_REQUEST for an unknown destination is
/// re-broadcast onward for recursive discovery (RNS recursive_prs, Transport.py:2946).
public var recursivePathRequests = false

/// destHash → when a recursive search for it began. Coalesces concurrent searches for the same
/// destination and is GC'd after pathRequestTimeout (RNS discovery_path_requests, Transport.py:3060).
public var discoveryPathRequests: [Data: Date] = [:]
```

with `static let pathRequestTimeout: TimeInterval = 15` (RNS `PATH_REQUEST_TIMEOUT`, Transport.py:79).

### 2. New action

`case setRecursivePathRequests(Bool)` → sets `state.recursivePathRequests`. This is a bare-Transport feature; multi-interface relay nodes are wired directly by the app (like `setTransportIdentity`/`startMaintenance`). No Endpoint wiring (a single-interface leaf excludes the arrival interface → no interface to forward to → no-op).

### 3. Recursive re-broadcast branch

In the PATH_REQUEST responder, the terminal `return .none` (reached after the #4c-1 owner-answer and #4c-2 relay-cache-answer both decline) is replaced with:

```
// (3) Path unknown: if recursion is enabled (relay + opt-in) and we are not already searching
// for this destination, re-broadcast the request onward (RNS path_request:3044-3070).
if let relayID = state.transportIdentity, state.recursivePathRequests,
   state.learned[requested] == nil,
   state.discoveryPathRequests[requested] == nil {
    state.discoveryPathRequests[requested] = date.now
    let fwd = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
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

- `tag` and `requested` are already bound by the #4c-3a entry gate earlier in the same branch and remain in scope.
- **Payload** = `requested ‖ relayID.hash ‖ tag` — the destination, OUR transport_id (the recursing relay's), and the SAME tag from the original request. Matches RNS `request_path(recursive=True)`: `path_request_data = destination_hash + Transport.identity.hash + request_tag` (Transport.py:2811) reusing the inbound tag (Transport.py:3068-3070). Reusing the tag is the loop-damper: a re-broadcast that loops back to us hits our #4c-3a `discoveryPrTags` ring and is dropped at the entry gate.
- **`learned[requested] == nil` guard** faithfully mirrors RNS's control structure: answer-from-cache is an `elif (dest in path_table)` (Transport.py:2972), so a relay that knows a path never falls through to recursion — even if its announce cache is momentarily empty. We recurse only for genuinely-unknown destinations. (`announceCache` without `learned` cannot occur — they are written and GC'd together.)
- **`discoveryPathRequests[requested] == nil` guard** coalesces concurrent searches: a second unknown-path request for the same destination (with a fresh tag, so it passes the entry gate) does not trigger a second re-broadcast while the first is in flight.
- **Fan-out** excludes the arrival interface (RNS forwards on all interfaces except the requestor's, Transport.py:3063-3064).

### 4. GC

`maintenanceTick` removes stale in-flight searches:

```swift
for (dest, startedAt) in state.discoveryPathRequests
where now.timeIntervalSince(startedAt) > Transport.pathRequestTimeout {
    state.discoveryPathRequests[dest] = nil
}
```

## Data flow

```
Unknown-path PATH_REQUEST arrives at relay X on i0 (X: relay + recursivePathRequests)
        │  (passes #4c-3a entry gate: fresh tag)
        ├─ owner-answer (#4c-1)?  no (X does not own it)
        ├─ relay-cache-answer (#4c-2)? no (learned[requested] == nil)
        ▼
recursive branch: learned == nil AND discoveryPathRequests[requested] == nil?
        ├─ no  → .none (already searching, or path known, or recursion off/leaf)
        └─ yes → record discoveryPathRequests[requested] = now;
                 re-broadcast (dest ‖ X.transport_id ‖ same tag) to interfaces != i0
        ▼
downstream relays repeat until a knowing node answers; the pathResponse flows back
        │
maintenanceTick: discoveryPathRequests entries older than 15s are swept
```

## Testing

Non-exhaustive TCA tests (`store.exhaustivity = .off`), outcome-focused, mutation-verified per the three-step protocol. The "no re-broadcast" cases use the isolated-store + flip-`.on`-last idiom so a stray transmit fails teardown.

**Task 1 (recursive branch):**
1. **Recursion re-broadcasts** — relay with 2 interfaces (i0, i1), `recursivePathRequests = true`, unknown dest; request arrives on i0 → a re-broadcast is transmitted on i1 (not i0) with payload `requested ‖ relayID.hash ‖ tag`.
2. **Disabled → no re-broadcast** — flag false, unknown dest → nothing transmitted.
3. **Non-relay → no re-broadcast** — `transportIdentity == nil` (flag true) → nothing.
4. **Known path → no recursion** — relay has learned the dest → the relay-cache answer fires (or, if learned-but-uncached, still no recursion) rather than a re-broadcast.
5. **Duplicate dest → no second re-broadcast** — two unknown-path requests for the same dest (distinct tags) → only the first re-broadcasts (`discoveryPathRequests` dedup).

**Task 2 (GC):**
6. **Stale search swept** — a `discoveryPathRequests` entry older than `pathRequestTimeout` is removed by `maintenanceTick`; a fresh one survives.

**Task 3 (cross-val):**
7. Extend the fixture generator to emit a genuine RNS relay path-request payload (`dest_hash ‖ Transport.identity.hash ‖ tag`); a test asserts our recursive re-broadcast payload composition matches it byte-for-byte.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Cross-val fixtures MUST drive genuine RNS (`cross-validation-drive-real-rns`).
- Pure core untouched; changes confined to `Transport.swift` + its tests + the cross-val fixture generator/vectors.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
