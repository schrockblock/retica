# Transport #4c-2: Relay Answers a Path Request From Cache — Design

**Sub-project:** #4c Path Requests (2nd slice). Follows #4c-1 (path request → local-destination response → learn). See `transport-relaying` memory.

**Goal.** A relay that *knows a path* to a destination D (learned it, but does not own D) answers an inbound `PATH_REQUEST` for D by re-emitting D's cached announce — so a requester can discover a multi-hop destination via the relay, not only from D's owner.

## Problem

#4c-1 gave us: a leaf broadcasts a `PATH_REQUEST`; the **owner** of the requested destination answers with a `pathResponse` announce. But in a relayed topology the requester is often not adjacent to the owner — an intermediate relay that has already *learned* the path should be able to answer on the owner's behalf.

We cannot forge a fresh announce for a remote destination: an announce is signed by the destination's identity private key, which a relay does not hold. RNS solves this by re-emitting the **cached raw announce** (original, still-valid signature) — `get_cached_packet(path_table[dest][IDX_PT_PACKET])` (Transport.py:2973). Our `LearnedDestination` stores only *parsed* fields (identity, appData, ratchet, hops, nextHop, …), not the raw announce bytes, so this slice must add an announce cache.

## Scope

**In scope:**
1. **Announce cache** — retain the announce *payload* (which carries the valid signature) per learned destination.
2. **Relay-answer** — on a `PATH_REQUEST` for a destination we have cached (and we are a relay, and the loop guard passes), re-emit the cached announce as a `pathResponse` announce so the requester learns D via us.
3. **Loop guard** — do not answer when the requester is our own next hop toward D (RNS `next_hop == requestor_transport_id`, Transport.py:2987).

**Deferred to #4c-3** (timing + dedup + recursive):
- `PATH_REQUEST_GRACE` delay before answering (RNS schedules the answer via the announce_table after a grace so better-connected peers answer first; we answer immediately — duplicate answers re-emit the *same* cached announce, so the requester's existing announce blob-dedup collapses them).
- `discovery_pr_tags` unique-tag dedup, `path_requests` requester table.
- **Recursive re-broadcast** of the `PATH_REQUEST` when the path is unknown (RNS Transport.py:3035-3044). This is deferred because an unconditional re-broadcast of every unknown-destination request is a broadcast storm; RNS gates it on interface mode **and** the `discovery_path_requests` dedup, and that dedup lands in #4c-3. Moving recursive to #4c-3 keeps #4c-2 self-contained and storm-free (a known-path answer is bounded).

## Architecture

All changes in `Sources/ReTiCATransport/Transport.swift`. Pure core (`Sources/ReTiCA/*`) untouched. TCA state/reducer only.

### 1. Announce cache — new state

Add to Transport state:

```swift
/// destHash → the announce payload (carries the destination's valid signature)
/// for the currently-learned path. Enables a relay to re-emit a cached
/// announce as a path response (RNS get_cached_packet, Transport.py:2973).
var announceCache: [Data: Data] = [:]
```

**Populate:** in the `.announce` fresh-path handling, wherever we adopt or replace a learned path (`shouldReplace` true → we set `learned[destHash] = …`), also set `announceCache[destHash] = packet.payload`. The payload is the announce payload exactly as received, including the identity's signature; re-emitting it verbatim keeps the announce cryptographically valid.

**Garbage-collect:** the maintenance-tick path-expiry sweep already removes stale `learned[dest]` (and `announceBlobs`); remove `announceCache[dest]` in the same sweep so a cached announce never outlives its path. No separate expiry constant.

Not gated on relay mode: a leaf also caches (small, one payload per learned dest, GC-bounded) but never relay-answers (the answer is guarded on `transportIdentity != nil`). Caching unconditionally means a node that later enables relay can answer for paths it already knew.

### 2. Relay-answer — in the #4c-1 PATH_REQUEST responder

The #4c-1 responder is the first branch of the inbound `.data` case (guarded by `packet.destinationHash == Transport.pathRequestDestinationHash`). It currently:
- parses `requested = Data(payload.prefix(16))`,
- if `localDestinations[requested]` and we own the private key → owner path-response.

Add, **after** the owner check fails (we do not own D):

```
else if transportIdentity != nil,
        let cachedPayload = announceCache[requested],
        let path = learned[requested] {
    // Loop guard: if the requester carries a transport_id (relay requester,
    // 48-byte payload) equal to our next hop toward D, the requester is
    // already on our path — answering would send the announce back toward
    // its source. RNS Transport.py:2987.
    let requestorTransportId: Data? =
        payload.count > 32 ? Data(payload.dropFirst(16).prefix(16)) : nil
    if requestorTransportId == path.nextHop { /* skip: requester is our next hop */ }
    else {
        // Re-emit the cached announce as a HEADER_2 pathResponse announce,
        // transport_id = us, so the requester learns D reachable via us.
        <emit>
    }
}
```

**The emit** builds a `.announce` packet with:
- `headerType: .header2`, `transportType: .transport`, `transportId: <our transport hash>` — a relayed announce; the requester learns D's next hop is us.
- `context: .pathResponse` — marks it a path response (not a spontaneous announce), matching the owner response and RNS.
- `destinationType: .single`, `destinationHash: requested`.
- `payload: cachedPayload` — verbatim, signature intact.
- `hops:` set from the learned path so the requester learns the correct distance — mirror the existing relay re-broadcast hop handling (4b-1) exactly. The precise value is pinned during planning against the existing relay-forward code and cross-validated.

Transmit on the **arrival interface** (`interfaceID`), back toward the requester — same as the #4c-1 owner response.

### Loop-guard payload parse

- Non-relay requester: `payload` is `destHash(16) ‖ tag(16)` = 32 bytes → `count > 32` is false → `requestorTransportId == nil` → guard cannot trip → we answer (correct: a leaf requester is never our next hop).
- Relay requester: `payload` is `destHash(16) ‖ transport_id(16) ‖ tag(16)` = 48 bytes → `count > 32` true → parse `transport_id` from bytes 16..32. Count-based slicing (`dropFirst(16).prefix(16)`, wrapped in `Data(...)`) per the established non-zero-startIndex slice gotcha.

## Data flow

```
Requester R broadcasts PATH_REQUEST(dest=D [, R's transport_id], tag)  [#4c-1]
        │
        ▼  arrives at relay X (X learned D via some next hop N)
X inbound .data, destHash == pathRequestDestinationHash
        │
        ├─ localDestinations[D]?  no (X does not own D)          [#4c-1 branch, skipped]
        │
        ├─ transportIdentity != nil AND announceCache[D] AND learned[D]?  yes
        │       └─ requestor_transport_id == learned[D].nextHop (== N)?
        │               ├─ yes → skip (requester is our next hop; would loop)
        │               └─ no  → emit HEADER_2 pathResponse announce
        │                        (transport_id = X, payload = cachedPayload, hops from path)
        │                        on arrival interface, back toward R
        ▼
R receives the announce via existing announce handling → learns D reachable via X
```

## Testing

Non-exhaustive TCA tests (`store.exhaustivity = .off`), outcome-focused (`tca-tests-non-exhaustive` memory). Mutation-verified per the three-step protocol.

Behavioral cases:
1. **Cache populated on learn** — after processing an announce for D, `announceCache[D]` equals the announce payload. (Mutation: don't store → assert fails.)
2. **Relay answers from cache** — relay X has learned D (cache present, `transportIdentity` set); X receives a `PATH_REQUEST` for D from a leaf → X transmits a `pathResponse` announce for D (HEADER_2, transport_id = X, payload = cached) on the arrival interface. (Mutation: skip the emit → assert fails.)
3. **Non-relay does not answer from cache** — same setup but `transportIdentity == nil` → no transmit. (Distinguishes relay-answer from the owner branch.)
4. **Unknown path → no answer** — relay X, no cache for D → no transmit. (Bounds the relay-answer to known paths; recursive re-broadcast is #4c-3.)
5. **Loop guard** — relay requester whose transport_id equals X's next hop toward D → X does not answer. And the converse (transport_id ≠ next hop) → X answers. (Mutation: drop the guard → the equal case erroneously answers.)
6. **Cache GC'd with path** — after path expiry removes `learned[D]`, `announceCache[D]` is also gone. (Mutation: don't remove → assert fails.)

**Cross-validation:** a test (extending the #4c-1 fixture set) confirms the re-emitted announce is byte-faithful to what genuine RNS emits for a cached path response — the HEADER_2 rewrite + `pathResponse` context wrapping the verbatim cached payload, whose signature still validates under RNS. Grounds the wire-compat claim that a real RNS requester learns D from our relay answer.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main` memory).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
- Pure core untouched; changes confined to `Transport.swift` + its tests + the cross-val fixture generator/vectors.
