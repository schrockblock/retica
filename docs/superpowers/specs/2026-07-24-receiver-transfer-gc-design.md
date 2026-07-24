# Receiver-Transfer GC — Design

**Status:** Approved (design phase)
**Date:** 2026-07-24
**Depends on:** the merged Resource stack (through multi-segment) and the Link/transfer/pending-request GC slice.

## Goal

Remove a completed *receiver* `ResourceTransfer` from its `LinkSession.transfers` collection the moment it
finishes (emits `.received`), so completed receivers don't accumulate. Closes the leak the multi-segment
review flagged: a receiver transfer completes via `.received` (never `.concluded`/`.failed`), so the GC slice
— which removes only on `.concluded`/`.failed` — never removes it. Amplified by multi-segment, where an
N-segment resource spawns N such inert receiver transfers that persist on the link forever. No wire change,
no new dependency.

## Scope

**In scope**

1. `LinkSession` removes a receiver transfer from `state.transfers` in the `.received` interception, after
   capturing the advertisement it needs for routing, for ALL receiver completions (plain resource, large
   request-resource, large response-resource, and each multi-segment segment).

**Explicitly deferred (out of scope)**

- Any change to sender-side GC (already handled: senders GC on `.concluded`/`.failed`).
- A grace-delay/proof-cache variant (we chose remove-immediately; proof-safety analysis below shows it is
  unnecessary).
- Any change to the `ResourceTransfer` reducer, the wire format, or `Endpoint`.

## Why remove-on-`.received` is safe (established from the code)

- **A completed receiver is effect-inert.** On success it sets `status = .complete` and returns
  `.merge(.cancel(id: CancelID.watchdog), .send(.transmit(proof)), .send(.received(data)))` — the watchdog
  is cancelled, so there are no live effects to orphan on removal.
- **A completed receiver never re-sends its proof.** Its inbound-packet guard is `status == .requesting ||
  .transferring`, which excludes `.complete` — so any later inbound packet (duplicate part, re-ADV routed to
  it, re-request) is ignored and it never re-proves. A persisted completed receiver therefore contributes
  nothing to proof recovery; removing it changes nothing proof-wise.
- **The sender does not re-advertise/re-request during proof-wait.** On a lost proof it only re-arms its
  proof-wait watchdog (`proofRetriesLeft = 3`) waiting for the already-sent proof, then fails. It never
  re-contacts the receiver, so a removed receiver is never needed.
- **Ordering:** the proof `.transmit` and `.received` are separate child delegate actions from the same
  sender `.merge`, delivered in order (`.transmit` first). LinkSession relays the proof `.transmit` (via the
  element-independent `.transfer(.element(_, .delegate(.transmit)))` relay case) before it processes
  `.received` and removes the element — so the proof is already relayed when removal happens.

**One accepted tradeoff:** a persisted completed receiver currently acts as an ADV-dedup guard (the
ADV-spawn dedups by `resourceHash == adv.hash`). Removing it means a later duplicate/replayed advertisement
for an already-received resource would re-spawn a receiver and re-download. This is largely covered by the
Transport-level packet dedup (byte-identical duplicate ADVs are dropped before reaching LinkSession), and
the sender doesn't re-advertise once parts are flowing — so the window is small. Accepted.

## Current state (what exists / what's missing)

- `ResourceTransfer` receiver success: sets `.complete`, cancels the watchdog, emits `.transmit(proof)` +
  `.received(data)`. Never emits `.concluded`/`.failed` on success (those are the sender terminal /
  error-only). All receiver ERROR paths (assemble/decompress/verify fail, cancel, timeout-exhaust) emit
  `.failed` and are already GC'd by the GC slice.
- `LinkSession` `.transfer(.element(elementID, .delegate(.received(payload))))` interception routes by
  reading `state.transfers[id: elementID]?.advertisement` (currently reads it twice — once for
  `isRequest`/`isResponse`, once as `advR` for `isSplit`) and returns `requestReceived` / `responseReceived`
  / buffers a split segment / `resourceReceived`. It does NOT remove the element — the leak.
- The GC slice's `.concluded`/`.failed` interceptions DO `state.transfers.remove(id: elementID)` (capture
  adv/hash into locals first, then remove, then branch) — this is the pattern to mirror.

## Architecture

A single, localized change in `LinkSession` (`Sources/ReTiCATransport/LinkSession.swift`). The `ReTiCA`
core, `ResourceTransfer`, and `Endpoint` are untouched.

Refactor the `.received` interception to the capture-remove-branch shape used by `.concluded`/`.failed`:

```
case let .transfer(.element(elementID, .delegate(.received(payload)))):
    let adv = state.transfers[id: elementID]?.advertisement   // capture ONCE up front
    state.transfers.remove(id: elementID)                     // GC the completed receiver
    if adv?.isRequest == true { … requestReceived … }
    else if adv?.isResponse == true { … responseReceived … }
    if adv?.isSplit == true, let a = adv { … buffer by segmentIndex; surface whole on last … }
    return .send(.delegate(.resourceReceived(payload)))
```

All existing routing logic is preserved; it just reads the captured `adv` local instead of re-reading
`state.transfers[id:]` (which is now removed), and the element is gone by return. Every branch (request /
response / split-buffer-returning-`.none` / split-complete / plain) runs after removal — correct, because
the payload and advertisement are already captured and the transfer is terminal in all cases.

## Data flow

1. A receiver transfer assembles/verifies → emits `.received(payload)` (+ proof transmit).
2. LinkSession relays the proof (independent `.transmit` case), then processes `.received`: captures `adv`,
   removes the transfer, and routes the payload exactly as before.
3. `state.transfers` no longer retains the completed receiver. For a multi-segment resource, each segment's
   receiver is removed as its `.received` fires; after the last segment, the whole is surfaced and zero
   segment receivers remain.

## Error handling / edge cases

- **Order of capture vs removal:** `adv`/`payload` are locals captured before `remove`; the `IdentifiedArray`
  subscript returns a value copy, so routing is unaffected by removal.
- **Split segment returning `.none`** (waiting for more): the segment's payload is already buffered in
  `incomingSegments`; removing the (terminal) segment transfer is correct.
- **Duplicate/replayed ADV after removal:** re-spawns a receiver + re-downloads (wasteful, correct);
  mitigated by Transport packet dedup as noted.
- **No effect-orphaning:** the receiver's watchdog was cancelled at `.complete`; removal orphans nothing.
- **Sender/receiver symmetry:** senders still GC on `.concluded`/`.failed` (unchanged); this only adds the
  receiver-success removal, so both roles are now fully GC'd.

## Testing

- A completed single-segment receiver transfer is removed from `state.transfers` after `.received`, and
  still surfaces `resourceReceived(payload)`.
- A large request-resource receiver is removed and still surfaces `requestReceived`; a large
  response-resource receiver is removed and still surfaces `responseReceived`.
- Split-segment receivers are removed as each `.received` fires; after a full multi-segment receive,
  `state.transfers` is empty AND exactly one `resourceReceived(whole)` was surfaced (extend the existing
  two-segment E2E with a `state.links[…].transfers.isEmpty` assertion rather than a new heavy pump).
- Regression: all existing resource / request-response / split delegate surfacing still works (removal is
  after routing).
- Mutation: dropping the `state.transfers.remove(id:)` makes the "transfers empty after received"
  assertions fail.
- No cross-validation (pure state hygiene, zero wire change). Every new/changed test is mutation-swept.
  Committed directly to `main`.

## Known simplifications (carry to review)

- Remove-immediately (not grace-delay/proof-cache): justified because a completed receiver never re-proves
  and the sender never re-contacts it; the only loss is the ADV-dedup guard, covered by Transport dedup.
- No sender-side change; no wire/core/`Endpoint` change.
