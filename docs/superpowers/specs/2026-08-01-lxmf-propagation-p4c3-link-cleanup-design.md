# LXMF Propagation P4c-3 — PNNode Link Cleanup — Design

**Date:** 2026-08-01
**Status:** Approved (design)

## Context

Across P3b/P4a/P4b-2/P4c-2, `PNNode` accumulated per-link state
(`clientIdentities`, `pendingGet`, `pendingOffer`, `offerLinks`,
`pendingSyncPeers`) but never handles link failure/close — those Endpoint
delegates fall through to the catch-all `.none`. The whole-slice reviews flagged
a few benign, bounded leaks (an `offerLinks`/`pendingSyncPeers` entry can linger
if a peer never responds or `openLink` fails). P4c-3 plugs them and fixes a
stale comment. Pure hygiene — closes the deferred Minors from P4b-2 and P4c-2.

## Scope

**In scope:** clear per-link `PNNode` state on `linkClosed` / `requestFailed` /
`linkFailed`; fix the stale `PNNode.swift:132` comment.

**Out of scope / deferred:** proactive `closeLink` after a completed transfer —
a resource-lifecycle optimization (the transfer is async; closing immediately
would abort it — it would need `resourceConcluded` tracking), not a leak. The
link is reaped by its own keepalive/inactivity or the app.

## Design

### `clearLink(linkID)` helper

A local function in the reducer that removes all state keyed on (or referencing)
a `linkID`:

```swift
func clearLink(_ state: inout State, _ linkID: Data) {
    state.offerLinks[linkID] = nil
    state.clientIdentities[linkID] = nil
    state.pendingGet = state.pendingGet.filter { $0.value.linkID != linkID }
    state.pendingOffer = state.pendingOffer.filter { $0.value.linkID != linkID }
}
```

(`PendingGet` and `PendingOffer` both carry `.linkID`; `pendingGet`/`pendingOffer`
are keyed by client/peer hash, so they're filtered by value, not looked up.)

### Handlers (added before the catch-all)

```swift
case let .endpoint(.delegate(.linkClosed(linkID, _))):
    clearLink(&state, linkID)
    return .none

case let .endpoint(.delegate(.requestFailed(linkID, _))):
    clearLink(&state, linkID)
    return .none

case let .endpoint(.delegate(.linkFailed(dest))):
    state.pendingSyncPeers[dest] = nil          // outbound openLink failed before a link existed (no linkID)
    return .none
```

`linkFailed` carries only a destination (the `openLink` never produced a link),
so it clears the `pendingSyncPeers` entry keyed by dest.

### Comment fix

`PNNode.swift:132` — change `// invalid key → drop (dead path at cost 0)` to
`// invalid key → drop` (P4c-2 made this the live enforcement path at cost > 0).

### Delegate signatures (existing)

`Endpoint.Action.Delegate`: `linkClosed(linkID: Data, reason:)`,
`requestFailed(linkID: Data, requestID: Data)`, `linkFailed(destinationHash:
Data)` — all currently swallowed by `PNNode`'s catch-all.

## Testing

Injected-delegate unit tests in `PNNodeTests`:

1. **`linkClosed` clears everything:** on a link, inject `linkIdentified(link,
   peer)` and seed a `pendingGet`/`pendingOffer`/`offerLinks` entry for that link
   (construct via the initial state, or drive `requestReceived`/`syncToPeer`+
   `linkEstablished`). Inject `linkClosed(link, .initiatorClosed)` → assert
   `clientIdentities[link] == nil`, no `pendingGet`/`pendingOffer` entry with
   that linkID, and `offerLinks[link] == nil`.
2. **`requestFailed` clears the outbound offer:** seed `offerLinks[link]` →
   inject `requestFailed(link, rid)` → `offerLinks[link] == nil`.
3. **`linkFailed` clears the pending sync:** `syncToPeer(dest, cost)` → inject
   `linkFailed(dest)` → `pendingSyncPeers[dest] == nil`.

Mutation verification, one at a time (e.g. drop the `offerLinks` clear from
`clearLink` → the `linkClosed`/`requestFailed` tests fail; drop the `linkFailed`
handler body → the linkFailed test fails). Each must break its covering test,
then revert to green.

Also confirm the existing pnNode tests stay green (the new delegate handlers
were previously `.none`, so no behavior change for links that don't
fail/close).

## Known Limitations (P4c-3)

- No proactive post-transfer `closeLink` (deferred — optimization, not a leak).
- Registry/scheduling remain app-layer.
