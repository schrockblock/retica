# Link / Transfer / Pending-Request GC — Design

**Status:** Approved (design phase)
**Date:** 2026-07-22
**Depends on:** the merged Link lifecycle + Link/Resource integration + request/response slices.

## Goal

Purge terminal state so it does not accumulate: remove closed/failed links from `Endpoint.links`, remove
concluded/failed transfers from `LinkSession.transfers`, and ensure a closing link leaks no
`pendingRequests` entries or request timers. Reactive (remove at the terminal transition); **no new timers,
no new dependencies, zero wire changes.**

## Scope

**In scope**

1. `Endpoint` removes a `LinkSession` element from `links` when it reaches terminal (`.closed`, or
   `.establishmentFailed`).
2. `LinkSession` removes a `ResourceTransfer` element from `transfers` when it concludes or fails.
3. `LinkSession` clears `pendingRequests` and cancels their `CancelID.request(rid)` timers on every close
   path.

**Explicitly deferred (out of scope)**

- Surfacing `resourceFailed` for in-flight transfers that die because their link closed (the app gets
  `linkClosed` and can infer). Its own follow-up.
- A periodic janitor / grace-window (we chose reactive removal).
- Closed-link reconnect, per-`Destination` concerns, RTT-adaptive keepalive.

## Current state (what exists / what's missing)

- **Link terminal:** `Status` = `pending | handshake | active | closed`; `.closed` is the only terminal
  status. `.close`, `.establishmentDeadline`, `.inactivityDeadline`, and inbound `.linkClose` all set
  `.closed` and emit `.delegate(.closed(reason))` (reasons `initiatorClosed`/`destinationClosed`/`timedOut`).
  `.delegate(.establishmentFailed)` is emitted on handshake failure but leaves the link in
  `.pending`/`.handshake` (NOT `.closed`).
- **`cancelAll`** = `.merge(.cancel(.establishment), .cancel(.keepalive), .cancel(.inactivity))` — a stored
  `let`; does NOT cancel `CancelID.request(rid)`. `CancelID = { establishment, keepalive, inactivity,
  request(Data) }`.
- **`pendingRequests: Set<Data>`** is inserted on `.sendRequest` (inline + large) and removed on
  response-match / `.requestDeadline` / request-Resource-fail — but is NOT cleared on link close, and its
  timers keep running after close.
- **`transfers: IdentifiedArrayOf<ResourceTransfer.State>`** via `.forEach`. On `.concluded`/`.failed`,
  LinkSession surfaces the resource/request delegate but does NOT remove the element; the transfer cancels
  its own `watchdog` at terminal.
- **`Endpoint.links: IdentifiedArrayOf<LinkSession.State>`** via `.forEach`. On `.closed`/
  `.establishmentFailed`, Endpoint surfaces `linkClosed`/`linkFailed` but does NOT remove the element.
- **No GC/janitor exists**; no `IdentifiedArray` element removal is used anywhere in the codebase.
- **Ordering:** the close paths return `.merge(.send(transmit), .send(closed), cancelAll)` — the LINKCLOSE
  transmit action precedes the `.closed` delegate, so the close packet is relayed before any removal.

## Key mechanism

Removing an element from an `IdentifiedArrayOf` driven by `.forEach` **auto-cancels that element's in-flight
effects**. So removing a closed `LinkSession` element cancels its link timers, its `CancelID.request(rid)`
request timers, and its hosted transfers' watchdogs — the timer leak is solved by the removal itself. The
LinkSession-level pending cleanup (item 3) is belt-and-suspenders that keeps a closed link self-consistent
even when driven in isolation (unit tests, or any use without Endpoint GC).

## Architecture

Reactive GC at both layers. No new timers, no new dependencies. `Endpoint` (ReTiCANode) and `LinkSession`
(ReTiCATransport) change; the `ReTiCA` core and the wire format are untouched.

### `Endpoint` (`Sources/ReTiCANode/Endpoint.swift`) — remove terminal links

- `.link(.element(elementID, .delegate(.closed(reason))))`: capture `linkID`, return
  `.send(.delegate(.linkClosed(linkID:reason:)))`, and `state.links.remove(id: elementID)` (mutate before
  returning the send; the delegate carries the captured `linkID`, so order relative to the send is
  immaterial to its content).
- `.link(.element(elementID, .delegate(.establishmentFailed)))`: capture `destHash`, return
  `.send(.delegate(.linkFailed(destinationHash:)))`, and `state.links.remove(id: elementID)`.

Removing the element auto-cancels every in-flight effect scoped to that link (link timers + request timers +
hosted transfer watchdogs).

### `LinkSession` (`Sources/ReTiCATransport/LinkSession.swift`) — remove terminal transfers

- `.transfer(.element(elementID, .delegate(.concluded)))` and `.failed`: compute the surfaced delegate
  exactly as today (reading `advertisement`/`resourceHash`/pending-request state BEFORE removal), then
  `state.transfers.remove(id: elementID)` before returning the existing `.send`/`.merge`/`.none`.

### `LinkSession` — close-path pending cleanup

- A state-aware helper cancels every pending request timer and clears the set:
  ```
  func cancelPending(_ state: inout State) -> Effect<Action> {
      let cancels = state.pendingRequests.map { Effect<Action>.cancel(id: CancelID.request($0)) }
      state.pendingRequests.removeAll()
      return .merge(cancels)
  }
  ```
  Merge `cancelPending(&state)` into the returned effect of each close path (`.close`,
  `.establishmentDeadline`, `.inactivityDeadline`, inbound `.linkClose`) alongside the existing `cancelAll`.

## Data flow / ordering

1. A link closes → LinkSession emits `.merge(.send(transmit), .send(closed), cancelAll, cancelPending)`.
   The transmit action is delivered first → Endpoint relays `interface(.send)` (LINKCLOSE goes out).
2. Endpoint then processes `.closed` → surfaces `linkClosed` and removes the element. Removal auto-cancels
   any remaining child effects.
3. A transfer concludes/fails → LinkSession surfaces the resource/request delegate, then removes the
   transfer element.

## Error handling / edge cases

- **Double close:** `.close` guards `status == .active`; a second close no-ops. An action routed to an
  already-removed element is dropped by TCA. Safe.
- **Establishment-failed link** (in `.pending`/`.handshake`): removed on `establishmentFailed`; its
  establishment timer is auto-cancelled by removal.
- **Close mid-transfer:** in-flight transfers are dropped with the link element (their effects
  auto-cancelled). No `resourceFailed` is surfaced (deferred, see scope).
- **Pending cleanup with empty set:** `cancelPending` merges zero cancels → harmless no-op.

## Testing

- **`Endpoint`:** closing an active link removes it from `state.links` after `linkClosed` surfaces (correct
  `linkID`/`reason`); an establishment-failed link is removed after `linkFailed`; a closed link's request
  timer does NOT later fire (advance the clock past the request timeout → no `requestFailed`, no dangling
  effect at teardown — proving removal cancelled it).
- **`LinkSession`:** a concluded transfer is removed from `state.transfers` (count → 0) after
  `resourceConcluded` surfaces; a failed transfer removed after `resourceFailed`/`requestFailed`; closing a
  link with an outstanding request clears `pendingRequests` and cancels its timer (populate a pending
  request, close, assert `pendingRequests` empty AND advancing past the timeout fires nothing).
- **Regression:** all existing close/timeout/fail/transfer tests still pass — they assert state transitions
  and delegate emissions, which are unchanged; GC only ADDS removal afterward. The implementer verifies no
  existing test relies on a terminal element lingering (and updates any that inspect a post-close/terminal
  element to expect removal).
- **No new cross-validation** — pure state hygiene, zero wire change.
- Every new/changed test is mutation-swept. Committed directly to `main`.

## Known simplifications (carry to review)

- In-flight transfers that die on link close are dropped without a `resourceFailed` delegate (deferred).
- The LinkSession-level pending cleanup is redundant with Endpoint's element removal for the Endpoint-driven
  flow, but is retained for LinkSession-in-isolation correctness and to fix the noted `cancelAll` gap.
- Reactive removal means a closed link/terminal transfer is not queryable after its terminal delegate; the
  delegate carries the identifying data the app needs.
