# Transport #4c-3a: PATH_REQUEST Entry Gate — Tag Dedup + Tagless-Ignore — Design

**Sub-project:** #4c Path Requests (3rd slice, first of the #4c-3 essentials). Follows #4c-1 (owner answer) and #4c-2 (relay-cache answer). See `transport-relaying` memory.

**Goal.** Put the RNS `path_request_handler` entry gate (Transport.py:2894-2935) in front of the existing owner (#4c-1) and relay-cache (#4c-2) answers: parse the request's tag, **ignore tagless requests**, and **ignore duplicate `(destHash+tag)` requests**.

## Problem

The current PATH_REQUEST responder (the first branch of inbound `.data`, guarded by `packet.destinationHash == Transport.pathRequestDestinationHash`) dispatches straight to the owner-answer and relay-cache-answer logic with only a `payload.count >= 16` guard. Two RNS behaviors are missing:

1. **Tagless-ignore.** RNS ignores a request that carries only a 16-byte destination hash and no tag (Transport.py:2935). We currently answer it (the deferred #4c-1/#4c-2 Minor: our `>= 16` vs RNS's `> 16`).
2. **Tag dedup.** RNS records each fresh `unique_tag = destHash + tag` and ignores a request whose tag it has already seen (Transport.py:2924-2934). Without this, a relay answers the *same* logical request every time a copy arrives.

A PATH_REQUEST is a `.data` packet, so it already passes the `seenPacketHashes` dedup (identical bytes are dropped). The tag dedup is different: it keys on `(destHash+tag)`, catching re-broadcasts that share a tag but differ in transport_id/hops (different bytes, same tag). That value is mostly realized once recursive re-broadcast exists (#4c-3b); building the ring now is the correct sequencing — #4c-3b plugs into it — and the tagless-ignore fixes the Minor immediately.

## Scope

**In scope:**
1. A bounded `discoveryPrTags` ring (RNS `max_pr_tags = 32000`), keyed on `unique_tag = destHash ‖ tag`.
2. Tag parsing at the front of the responder, matching RNS's variable-length slicing.
3. Tagless-ignore (request length exactly 16 → drop).
4. Duplicate-tag ignore (a `unique_tag` already in the ring → drop, no answer).

**Deferred:**
- **Recursive re-broadcast** → #4c-3b (uses this ring's dedup to be storm-safe).
- **`PATH_REQUEST_GRACE` timing** and **requester-side `path_requests` throttle** → deferred as optional polish (user-chosen "essentials only").
- **Ingress/egress PR rate-limiting** (`should_ingress_limit_pr`) → out of scope; pure RNS interface-mode machinery ReTiCA does not model (like roaming/local-client interfaces).

## Architecture

All changes in `Sources/ReTiCATransport/Transport.swift` (TCA state + reducer). Pure core (`Sources/ReTiCA/*`) untouched.

### 1. New state — the tag ring

```swift
/// unique_tag (destHash ‖ tag) ring for PATH_REQUEST dedup — a duplicate tagged request is
/// ignored rather than re-answered (RNS discovery_pr_tags, Transport.py:2924-2934). Bounded
/// (auto-evicts oldest at capacity), so no separate GC pass.
var discoveryPrTags = RingSet(capacity: Transport.pathRequestTagRingSize)
```

with `static let pathRequestTagRingSize = 32000` (RNS `max_pr_tags`, Transport.py:127). A single global ring (RNS's `discovery_pr_tags` is a flat list, not per-destination). RingSet is the same type used for `announceBlobs`; `insert` returns `false` when the key is already present.

### 2. Entry gate — front of the responder

At the start of the `pathRequestDestinationHash` branch, before the owner/relay dispatch:

```
if packet.destinationHash == Transport.pathRequestDestinationHash {
    guard packet.payload.count >= 16 else { return .none }
    let requested = Data(packet.payload.prefix(16))
    // Parse the tag (RNS path_request_handler:2905-2919). A relay request carries a
    // transport_id in bytes 16..32; the tag follows. A request with no tag is ignored.
    let tag: Data
    if packet.payload.count > 32 {
        tag = Data(packet.payload.dropFirst(32).prefix(16))     // after destHash + transport_id
    } else if packet.payload.count > 16 {
        tag = Data(packet.payload.dropFirst(16).prefix(16))     // after destHash
    } else {
        return .none                                            // tagless (== 16) → ignore (RNS:2935)
    }
    // Duplicate (destHash ‖ tag) → ignore; a fresh tag is recorded and falls through to answer.
    let uniqueTag = requested + tag
    guard state.discoveryPrTags.insert(uniqueTag) else { return .none }

    // ... existing #4c-1 owner-answer + #4c-2 relay-cache-answer dispatch, UNCHANGED ...
    return .none
}
```

The tag `prefix(16)` matches RNS's `if len(tag_bytes) > 16: tag_bytes = tag_bytes[:16]` truncation. Slicing is count-based (`dropFirst`/`prefix` wrapped in `Data(...)`), per the non-zero-startIndex slice gotcha. The existing owner and relay branches (and the relay branch's own `requestorTransportId` parse) are unchanged; the gate only adds tagless-ignore and tag-dedup in front.

## Data flow

```
PATH_REQUEST arrives (.data, dest == pathRequestDestinationHash)
        │
        ├─ payload.count < 16      → .none (malformed)
        ├─ payload.count == 16     → .none (TAGLESS, ignored — RNS:2935)
        ├─ payload.count in 17..32 → tag = payload[16:].prefix(16)      (leaf request, no transport_id)
        └─ payload.count > 32      → tag = payload[32:].prefix(16)      (relay request; transport_id in 16..32)
        │
        ▼
uniqueTag = requested ‖ tag
        │
        ├─ already in discoveryPrTags → .none (DUPLICATE, ignored — RNS:2924-2934)
        └─ fresh → record → fall through to:
                 owner-answer (#4c-1) OR relay-cache-answer (#4c-2) OR .none (no path known)
```

## Testing

Non-exhaustive TCA tests (`store.exhaustivity = .off`), outcome-focused, mutation-verified per the three-step protocol.

1. **Tagless request ignored** — a 16-byte (no-tag) request to an OWNED destination → no answer. (The Minor fix; distinguishes from #4c-1's owner-answer of a tagged request.)
2. **Duplicate tag ignored** — relay has a cached path; a request with tag T → answers (pathResponse); the *same* request (same tag T) again → no answer; a request with a *different* tag → answers again. (Dedup is load-bearing.)
3. **Owner answer preserved** — a fresh tagged request to an owned destination still produces the #4c-1 owner pathResponse (the gate does not break the existing path).
4. **Cross-val** — extend the fixture generator to emit `pr_tag` (the genuine RNS 16-byte tag already used to build `pr_request_payload`). A test asserts our tag extraction from the genuine-RNS `pr_request_payload` equals `pr_tag`, and `uniqueTag == pr_requested_dest + pr_tag` — validating our slicing against genuine-RNS-produced request bytes (extends #4c-1's `Data(payload.prefix(16)) == requested` slicing cross-val).

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Pure core untouched; changes confined to `Transport.swift` + its tests + the cross-val fixture generator/vectors.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
