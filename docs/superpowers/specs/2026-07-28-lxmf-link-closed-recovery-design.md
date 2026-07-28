# LXMF-4c-3a: Link-CLOSED Recovery — Design

**Sub-project:** LXMF-4 (LXMRouter), 4c robustness. First half of 4c-3 (link-CLOSED recovery); the idle-link teardown (`LINK_MAX_INACTIVITY=600`) is deferred to 4c-3b. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMRouter.process_outbound` direct-outbound CLOSED handling (`LXMRouter.py:2797-2816`): on a closed direct link, drop the dead link from `direct_links`, request a path, and let a later cycle re-establish and resend; `delivery_attempts` is not reset, so the message stays bounded by `MAX_DELIVERY_ATTEMPTS`.

**Prerequisite already in place:** our `LinkSession` implements RNS Link-level keepalive + inactivity teardown (`LinkSession.swift`: `keepaliveInterval=30`, `staleTime=60`, an `inactivityDeadline` that closes the link and forwards `.closed(.timedOut)`). So dead links are already detected and surfaced to the router as `.linkClosed`. This slice makes the router *recover* from that event.

## Problem

A direct message that has been *sent* over a link lives in `pendingDeliveries[hash]` as `.direct(linkID, data, asResource)` with a cancellable retry timer. Today:

- `.retryDue` re-emits `.sendDirect` to the **stored `linkID`**. If the link has closed, every retry targets a dead link until `maxAttempts` — the message never recovers even though re-establishing a fresh link would deliver it.
- `.linkClosed(dest)` only does `directLinks[dest] = nil` and returns `.none`. It re-drives nothing: pending messages keep firing at the dead link, and any `outboundQueue[dest]` messages (queued while the link was establishing) have no trigger to drain.

## Fix

Resend to the *current* link (looked up live), and re-establish on close.

### Type change

`ResendInfo.direct` stores the destination hash instead of the link id:

```swift
public enum ResendInfo: Equatable {
    case opportunistic(destinationHash: Data, payload: Data)
    case direct(destinationHash: Data, data: Data, asResource: Bool)   // was: linkID: Data
}
```

The old `linkID` was read only by `.retryDue`; storing `destinationHash` lets a retry look up the live link. Both creation sites (`.send` direct-active, `.linkEstablished` drain) already have `dest` in scope.

### Reducer changes

**Shared establish helper (DRY).** Factor the "set link status + request link/path" step — currently inline in `.send` direct-no-link — into a nested helper reused by `.linkClosed`:

```swift
func establish(_ state: inout State, _ dest: Data) -> Effect<Action> {
    if state.knownPaths.contains(dest) {
        state.directLinks[dest] = .establishing
        return .send(.delegate(.requestLink(destinationHash: dest)))
    }
    state.directLinks[dest] = .awaitingPath
    return .send(.delegate(.requestPath(destinationHash: dest)))
}
```

`.send` direct-no-active-link becomes: enqueue, then `if state.directLinks[dest] == nil { return establish(&state, dest) }` else `.none` (the establish-once guard is preserved — `establish` is only called when there is no entry).

**`.retryDue` direct branch.** After the existing `attempts += 1` and the `> maxAttempts → deliveryFailed` terminal check, the `.direct` case looks up the live link:

```swift
case let .direct(destinationHash, data, asResource):
    if case let .active(linkID) = state.directLinks[destinationHash] {
        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                      retryTimer(hash, LXMFDelivery.retryWaitSeconds))
    }
    // Link is down or re-establishing: don't send (no live link); just wait and re-check.
    // The attempt was already counted, so the saga stays bounded by maxAttempts.
    return retryTimer(hash, LXMFDelivery.retryWaitSeconds)
```

(The opportunistic branch of `.retryDue` is unchanged from 4c-2.)

**`.linkClosed(dest)`.** Clear the dead link, then re-establish if there is recoverable work:

```swift
case let .linkClosed(dest):
    state.directLinks[dest] = nil
    let hasPending = state.pendingDeliveries.values.contains {
        if case let .direct(d, _, _) = $0.resend { return d == dest }
        return false
    }
    let hasQueued = !(state.outboundQueue[dest]?.isEmpty ?? true)
    if hasPending || hasQueued {
        return establish(&state, dest)
    }
    return .none
```

`.linkEstablished` is unchanged: it drains `outboundQueue[dest]` (queued messages, freshly armed). Pending messages are not in the queue, so they are not double-sent — they recover on their next retry-timer tick, which now finds the fresh active link. No change to `.linkEstablished` is required.

## Data flow

```
(pending .direct to dest, link active) 
.linkClosed(dest) ─▶ directLinks[dest]=nil ; recoverable work? ─▶ establish(dest)  (requestLink/requestPath)
   … LinkSession re-establishes …
.linkEstablished(dest, newLinkID) ─▶ .active(newLinkID) ; drain outboundQueue[dest]
.retryDue(pending hash) ─▶ attempts++ ; directLinks[dest] active? 
        yes ─▶ .sendDirect(newLinkID, …)      (resend on the FRESH link)
        no  ─▶ (wait) re-arm timer only        (bounded by maxAttempts)
```

## Testing

TCA `TestStore` with an injected `TestClock`, `exhaustivity = .off`, mutation-verified.

1. **Close with in-flight work re-establishes.** Seed `directLinks[dest] = .active(oldLinkID)` and `knownPaths` containing `dest`; `.send(message, .direct)` → `sendDirect` (pending, `attempts == 1`). `.linkClosed(dest)` → `requestLink(dest)` emitted and `directLinks[dest] == .establishing`; the pending delivery is retained.
2. **Recovery headline.** Continue from (1): `.linkEstablished(dest, newLinkID)`; advance `retryWaitSeconds` → the retry emits `.sendDirect(newLinkID, …)` — the fresh link, never `oldLinkID`.
3. **Retry while the link is down waits.** Pending direct delivery with `directLinks[dest] == .establishing` (no active link); advance `retryWaitSeconds` → `attempts` increments but **no** `sendDirect` is emitted (flip `exhaustivity = .on` to catch a stray send).
4. **Bounded give-up.** Link never returns (`directLinks[dest]` stays non-active); advancing the clock `maxAttempts` times drives `attempts` past the cap → `.deliveryFailed`.
5. **Close with nothing pending just clears.** `.linkClosed(dest)` with empty `pendingDeliveries`/`outboundQueue` → `directLinks[dest] == nil`, and no `requestLink`/`requestPath` is emitted (flip `.on`).

No cross-val (pure behavior; no new wire constants).

## Bounded-recovery semantic

Attempts are **preserved** across the close→re-establish cycle — the pending delivery is never reset — so a flapping or unreachable destination still fails at `maxAttempts` rather than retrying forever. The retry timer keeps ticking through the link-down window (incrementing attempts without sending), which is what enforces the bound.

## Deferred (not in this slice)

- **Idle-link teardown** (`LINK_MAX_INACTIVITY=600`, `LXMRouter.clean_links`): proactively close direct links kept alive by keepalives but idle of LXMF traffic for 10 minutes. Needs per-link activity tracking + a periodic sweep + a `.closeLink` delegate → LXMF-4c-3b.
- **Bounding a queued message whose link never establishes at all** (a message still in `outboundQueue`, never sent, so it has no attempt counter). Pre-existing limitation, separate from CLOSED-link recovery.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test. Apply mutations one at a time where they touch the same code.
- Signatures validated, never byte-compared (`ed25519-hedged-nondeterministic`); hashes/constants stay deterministic.
- New production is the `LXMFRouter` reducer change (ReTiCANode); tests in `ReTiCANodeTests`. No core / Endpoint / Transport changes (the Endpoint↔router wiring is exercised by feeding the router `.linkClosed`/`.linkEstablished`/`.retryDue`).
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
