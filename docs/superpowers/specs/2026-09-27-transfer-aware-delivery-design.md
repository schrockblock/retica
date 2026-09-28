# LXMF — Transfer-aware delivery (progress, cancel, no retries mid-transfer) — Design

**Date:** 2026-09-27
**Status:** Approved (design); spec under review
**Reference implementation:** LXMF 1.1.0 / RNS 1.4.2 at
`/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/` — `LXMRouter.process_outbound`
(LXMRouter.py:2682-2900), `LXMRouter.cancel_outbound` (:1719-1744), `LXMessage.__resource_concluded`
(LXMessage.py:597-606), `__update_transfer_progress` (:623-624).
**Downstream consumer:** ReTiCaMsgr's images/files feature (next project), which needs long transfers
to succeed on Bluetooth, plus progress and cancel.
**Branch:** `feat/transfer-aware-delivery` in the worktree
`/Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery`, merged to `main`.

## Goal

1. A message delivered as a Resource (anything over one link packet, i.e. `packed.count > 431`) is never
   resent while its transfer is in flight, and its outcome is decided by the transfer itself:
   concluded → confirmed, failed → one retry attempt 10 s later, rejected → failed with no retry.
2. Transfer progress reaches the app for outbound and inbound Resources.
3. The app can cancel an outbound message, in the queue or mid-transfer.
4. Only one Resource transfer runs per link at a time; further large sends queue.
5. A long transfer no longer trips the link's idle timer.
6. Two propagation-node fixes: the propagated copy counts as outstanding while its stamp search runs,
   and a message larger than the node's advertised limit fails that copy up front.

## Current state (why)

- **Representation:** `LXMessage+Direct.swift:11-13` — `packed.count <= Link.mdu (431) ? .packet : .resource`.
  `LXMFRouter.swift:468,558` use it for the delivery copy; `:499,567,676` apply the same 431 test to
  the propagated container.
- **Retry armed regardless of representation:** `LXMFRouter.swift:473,511` arm `retryTimer` (10 s,
  `LXMFDelivery.retryWaitSeconds`) when a Resource send starts. `.retryDue` (`:665-685`) then starts a
  new Resource on the same link every 10 s and fails the copy after `maxAttempts` (5). A
  `resourceConcluded` arriving afterwards is dropped by `succeed`'s guard (`:266`).
- **`resourceFailed` is ignored:** `LXMFNode.swift:834` catch-all. Only `resourceReceived` and
  `resourceConcluded` are handled (`:827-832`).
- **No progress anywhere:** the delegate chain (`LinkSession.swift:223-225` → `LinkPlane.swift:118-120`
  → `TransportEndpoint.swift:120-122`) carries only received / concluded / failed.
- **No public cancel:** `ResourceTransfer.Action.cancel` exists (`ResourceTransfer.swift:144,524-532`)
  but is reachable only via `LinkSession.Action.transfer(.element(id:, .cancel))`. Nothing on
  LinkSession, LinkPlane, TransportEndpoint or LXMFNode exposes it.
- **Single segmented-send slot:** `LinkSession.State.segmentedSend` (`LinkSession.swift:95,858`) is
  overwritten by a second multi-segment `sendResource` on the same link. `linkResourceInFlight`
  (`LXMFRouter.swift:41`) likewise holds one entry per link, last write wins.
- **Idle timer:** `idleTimer(dest, linkID)` (`LXMFRouter.swift:247-251`, 600 s) is re-armed only on
  sends and link establishment (`:474,506,512,581`), never by Resource traffic.
- **Propagated copy during stamp search:** `isOutstanding` (`LXMFRouter.swift:279`) doesn't count a
  propagated copy whose PN stamp search is still running in `LXMFNode` (`LXMFNode.swift:484-495`), so
  `deliveryFailed` can fire before that copy is armed. Recorded as an accepted gap in
  `2026-09-26-single-packet-proofs-design.md` Amendment 3; now fixed.
- **PN limit not checked on send:** `PNAnnounce.perTransferLimit` is parsed but never consulted;
  an oversize propagated container is attempted and fails after 5 tries.

### Reference behaviour this mirrors

- While a message is `SENDING` (a Resource in flight), `process_outbound` does not resend; it logs
  progress (LXMRouter.py:2788-2796).
- `__resource_concluded`: `COMPLETE` → delivered; `REJECTED` → state `REJECTED` (terminal);
  otherwise tear the link down and return to `OUTBOUND`, where the next pass counts a new attempt and
  waits `DELIVERY_RETRY_WAIT` (10 s). `MAX_DELIVERY_ATTEMPTS` = 5.
- `cancel_outbound` marks the message `CANCELLED` and cancels the Resource representation.
- Progress: 0.05 when the link is active, 0.10 when the transfer starts, then
  `0.10 + 0.90 × resource.get_progress()`, 1.0 on delivery.
- Reference RNS allows several concurrent Resources per link; ReTiCA's single slot is the reason for
  the per-link queue below. The queue is not a wire behaviour, so it needs no reference parity.

## Design

### 1. Router: Resource copies are "transferring", not "retrying" (`LXMFRouter`)

- `PendingDelivery` gains `phase: Phase` with `enum Phase { case retrying, transferring, queued }`.
  - `retrying` — today's behaviour (opportunistic packets, link packets): retry timer armed.
  - `transferring` — a Resource is in flight for this copy: **no retry timer**.
  - `queued` — waiting for the link's current transfer to finish (see §4).
- Starting a Resource send (`:470,509,560,572,667,682`) sets `phase = .transferring`, records
  `linkResourceInFlight[linkID] = key`, and does **not** arm `retryTimer`. `attempts` is incremented
  once per started transfer.
- **New action `.resourceFailedOnLink(linkID: Data, rejected: Bool)`**, sent by `LXMFNode` from
  `endpoint(.delegate(.resourceFailed))` (rejection is detected in `ResourceTransfer` and carried up,
  see §3). Handling:
  - Resolve `key = linkResourceInFlight[linkID]`, clear it, cancel that copy's pending state.
  - `rejected == true` → `fail(&state, key, reason: .rejected)` immediately. No retry.
  - Otherwise → emit `.delegate(.closeLink(dest))` (reference tears the link down), set
    `phase = .retrying`, and arm one `retryTimer(key, retryWaitSeconds)`. When it fires, `.retryDue`
    re-establishes/uses the link and starts a fresh Resource, incrementing `attempts`. After
    `maxAttempts` failures → `fail(&state, key, reason: .exhausted)`.
- `.resourceDeliveredOnLink` is unchanged in meaning: it resolves the copy in `linkResourceInFlight`
  via `succeed` (delivery copy → `deliveryConfirmed`, propagated copy → `propagationAccepted`).
- `.retryDue` for a copy in `.transferring` is a no-op (defensive; no timer should exist).
- `fail` gains a `reason` so the delegate can say why (§3); the existing "every copy failed and none
  succeeded" rule from the proofs project is unchanged.

### 2. Cancel

- `LXMFRouter.Action.cancelOutbound(messageHash: Data)`:
  - For each copy of the hash: if `.queued`, remove it from the queue; if `.transferring`, emit
    `.delegate(.cancelResource(linkID))` and clear `linkResourceInFlight[linkID]`; if `.retrying`,
    cancel its timer. Remove all pending state, record the hash in `succeededMessages`' sibling ring
    `cancelledMessages` so a late `resourceFailed`/`resourceConcluded` for it is ignored, and emit
    `.delegate(.deliveryCancelled(messageHash:))` exactly once.
  - No `deliveryFailed` or `deliveryConfirmed` follows a cancel.
- `LXMFNode.Action.cancelOutbound(messageHash:)` forwards to the router and also cancels any
  in-flight delivery/propagation stamp search for that hash (`cancelDeliveryStamps` /
  `cancelPropagationStamps` are today all-or-nothing; this adds a per-hash variant).
- `LinkSession.Action.cancelResource(hash: Data)` → `transfer(.element(id:, .cancel))` for the
  transfer with that resource hash, or clears the queued segment in `segmentedSend`. `LinkPlane` and
  `TransportEndpoint` gain `cancelResource(linkID:hash:)`. The peer receives the standard cancel
  packet, already covered by the resource cross-validation fixtures.

### 3. Progress and outcomes (transfer layer → LXMFNode delegate)

- `ResourceTransfer.Delegate.progress(bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int)`:
  - Sender: after each served `resourceRequest` (`ResourceTransfer.swift:283-341`), using
    `sentIndices.count / parts.count`.
  - Receiver: after each part (`:360-390`), using `receivedParts.count / expectedParts`.
  - Rate limit: emit only when the done-fraction crosses a 1 % step or on the final part. A 1 MB
    transfer yields ≤ 100 events.
- `ResourceTransfer.Delegate.failed` gains `rejected: Bool` (true when the peer answered the
  advertisement with a reject rather than a request, or sent a receiver-cancel).
- Passed up unchanged: `LinkSession.Delegate.resourceProgress(hash, …)` → `LinkPlane` →
  `TransportEndpoint.Delegate.resourceProgress(linkID:hash:…)`; `resourceFailed` carries `rejected`.
- `LXMFNode` maps:
  - Outbound, via `router.linkResourceInFlight[linkID]` → `Delegate.deliveryProgress(messageHash:,
    fraction: Double)` for the delivery copy and `Delegate.propagationProgress(messageHash:, fraction:)`
    for the propagated copy. Scale, per reference: 0.05 when the link becomes active for that copy,
    0.10 when the transfer starts, `0.10 + 0.90 × done/total` during, 1.0 on confirmation. Fractions
    are monotonic per copy.
  - Inbound, before any message exists: `Delegate.inboundTransferProgress(sourceHash: Data,
    fraction: Double)` keyed by the link's destination identity hash (the peer's `lxmf.delivery`
    hash is not known until unpack, so `sourceHash` is the **remote destination hash of the link**).
    Fraction is `done/total`.
  - Outcomes: `Delegate.deliveryFailed(messageHash:)` is unchanged; new `Delegate.deliveryRejected(
    messageHash:)`, `Delegate.deliveryCancelled(messageHash:)`, and
    `Delegate.propagationRefused(messageHash:, reason: .tooLargeForNode)`.

### 4. One Resource transfer per link

- The router keeps `resourceQueue: [Data /*dest or PN*/: [DeliveryKey]]`. A large send whose link
  already has an entry in `linkResourceInFlight` is stored with `phase = .queued` instead of starting.
- When a transfer concludes, fails, or is cancelled, the router starts the next queued copy on that
  link (a fresh `sendDirect`/`sendPropagated` with `asResource: true`).
- Small (≤ 431 byte) sends are never queued behind a transfer; they go as link packets immediately.
- Link closure (`closed()`, `LXMFRouter.swift:321`) moves queued copies back to the existing
  re-establish path, as it already does for `outboundQueue`.

### 5. Idle timer

- `LXMFNode` forwards each `resourceProgress` for an outbound copy to the router as
  `.linkActivity(linkID:)`, and the router re-arms `idleTimer(dest, linkID)` on it. Inbound transfers
  on a link we own also count. The 600 s constant is unchanged.

### 6. Propagation-node fixes

- **Pending marker.** `LXMFRouter.Action.propagatedCopyPending(messageHash:)` is sent by `LXMFNode`
  when it starts the PN stamp search (`LXMFNode.swift:484-495`); `isOutstanding(_, hash, .propagated)`
  returns true while the marker is set. `sendViaPropagation` (arming) and `cancelPropagationStamps`
  (via `fail`) clear it. `cancelOutbound` clears it too.
- **Oversize.** `LXMFNode` knows the configured PN's announced `perTransferLimit` (from
  `PNAnnounce`, learned via `learnedPeers` / the PN announce). In `sendMessage(alsoViaPropagation:)`,
  if `message.packed.count > limitKB × 1000` (reference compares bytes to `limit*1000`,
  LXMRouter.py:1528), the propagated copy is not started: the router receives
  `.propagatedCopyRefused(messageHash:, reason: .tooLargeForNode)`, which runs `fail` for that copy
  with the distinct reason and emits `propagationRefused`. The delivery copy proceeds normally. If the
  PN's limit is unknown, the copy is attempted as today.

## Delegate API summary (`LXMFNode.Action.Delegate`)

| Case | New? | Meaning |
|---|---|---|
| `deliveryConfirmed(messageHash:)` | existing | delivery copy confirmed |
| `propagationAccepted(messageHash:)` | existing | propagated copy accepted by the PN |
| `deliveryFailed(messageHash:)` | existing | every copy failed (exhausted) |
| `deliveryRejected(messageHash:)` | new | the recipient rejected the transfer; no retry |
| `deliveryCancelled(messageHash:)` | new | the app cancelled it |
| `deliveryProgress(messageHash:fraction:)` | new | outbound delivery-copy progress, 0.05…1.0 |
| `propagationProgress(messageHash:fraction:)` | new | outbound propagated-copy progress |
| `inboundTransferProgress(sourceHash:fraction:)` | new | inbound Resource progress from a peer link |
| `propagationRefused(messageHash:reason:)` | new | propagated copy not attempted (`.tooLargeForNode`) |

`LXMFNode.Action.cancelOutbound(messageHash:)` is the only new inbound action for the app.

## Compatibility

- **Wire:** no change. Reference peers already behave this way; we stop resending mid-transfer.
- **Breaking public shapes:** `ResourceTransfer.Delegate.failed` (adds `rejected`),
  `LinkSession`/`LinkPlane`/`TransportEndpoint` delegate enums (new cases), `LXMFRouter.PendingDelivery`
  (adds `phase`), `LXMFRouter.Action` (new cases). Every internal pattern match and test is updated in
  this project.
- **ReTiCaMsgr:** the app's reducer pattern-matches specific delegate cases and has a catch-all for
  the rest (`AppFeature.swift`, the `.node` catch-all), so it keeps compiling. A minimal app commit
  maps `deliveryRejected` and `deliveryCancelled` to `MessageStatus.failed` so those messages don't
  sit on "sending" forever; the files feature will style them properly. Diagnostics reads
  `pendingDeliveries` values, so `PendingDelivery` keeps its existing fields.
- **Behaviour change visible to the app:** a large message sent over a slow link now stays "sending"
  until the transfer really concludes instead of flipping to "failed" at 50 s.

## Testing

Swift Testing + TCA `TestStore`, following the repo's conventions. Every new test goes through
mutate → red → revert → green, with no "Skipped assertions" known issues.

- **Router**
  - A Resource copy arms no retry timer: advance the test clock 60 s, exhaustive store, no resend and no
    `deliveryFailed`.
  - `resourceDeliveredOnLink` confirms; `resourceFailedOnLink(rejected: false)` closes the link, arms
    exactly one 10 s retry, increments `attempts`; the 5th failure fails the copy via `fail`.
  - `resourceFailedOnLink(rejected: true)` fails immediately with `.rejected`, no timer.
  - Cancel: transferring copy → `cancelResource` + `deliveryCancelled`, and a later
    `resourceFailedOnLink` is ignored; queued copy → removed, nothing sent; retrying copy → timer gone.
  - Queue: two large sends to one destination → one `sendDirect(asResource:)`, the second only after
    the first concludes; a small send in between goes out immediately.
  - Pending marker: direct copy exhausts attempts while the marker is set → no `deliveryFailed`
    (exhaustive); marker cleared and propagated copy fails → exactly one `deliveryFailed`.
  - Oversize: `propagatedCopyRefused` fails only the propagated copy, emits `propagationRefused`, and
    the delivery copy still confirms.
  - `linkActivity` re-arms the idle timer (advance 599 s, activity, advance 2 s → link still open).
- **Transfer layer**
  - Sender and receiver progress events with correct fractions and segment indices; the 1 % rate limit.
  - `failed(rejected:)` is true for an advertisement reject and a receiver cancel, false for a
    watchdog timeout.
  - `cancelResource` reaches the transfer and emits the cancel packet (existing fixture); on a queued
    segment it clears `segmentedSend` without a packet.
- **LXMFNode mapping:** progress scale points (0.05, 0.10, mid, 1.0) and per-copy monotonicity;
  `inboundTransferProgress` keyed by the link's destination hash; `cancelOutbound` reaches both the
  router and the per-hash stamp cancel.
- **End to end** (two `LXMFNode`s over the mocked-TCP harness in `LXMFNodeOpportunisticTests.swift`):
  - A 3 MB incompressible message: both sides see monotonic progress, the receiver's
    `messageReceived` carries the intact fields, the sender gets `deliveryConfirmed`, never
    `deliveryFailed`.
  - The same with a frame-delaying harness so the transfer spans more than 60 s of test-clock time.
  - Cancel mid-transfer: the peer's transfer fails, the sender gets `deliveryCancelled`.
  - With a PN configured: direct copy confirmed, propagated copy accepted, no false failure.
- **ReTiCaMsgr:** the core suite stays green after the compile-and-status commit.

## Docs

- `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md` Amendment 3: the propagated
  stamp-search gap is marked fixed by this spec.
- `docs/reference-parity-checklist.md`: outbound transfer semantics, cancel and progress entries
  updated.
- ReTiCaMsgr's `docs/superpowers/backlog-retica-followups.md`: remove the false-"failed" item once
  merged; hop count / interface / retry count stay.

## Amendments at planning time (2026-09-27)

Writing the plan against the real code surfaced these corrections. They override the text above
where they conflict.

1. **Inbound progress can't name the sender.** A peer delivering to us links to our own
   `lxmf.delivery` destination without identifying, so the link's remote hash is ours, not theirs.
   The delegate becomes `inboundTransferProgress(sourceHash: Data?, linkID: Data, fraction:)`;
   `sourceHash` is nil on ordinary delivery links and set only when the initiator identified. The app
   can show "Receiving…" keyed by link, and attributes the message once it unpacks.
2. **Transfer identity is by resource hash, matched in `LXMFNode`.** `LinkSession` emits
   `resourceFailed`/`resourceConcluded` for inbound transfers too, so a link-ID-only mapping would let
   a peer's failed transfer to us fail our outbound message on the same link. `LXMFNode` records the
   resource hash of its own outbound transfer per link (from the first sender progress event, emitted
   at advertisement, so `resourceProgress` carries a `role`) and ignores conclusions for other hashes.
   `cancelResource` therefore takes that hash, supplied by the node.
3. **Rejection is terminal for both copies.** Reference retries a rejected *propagated* copy; we
   don't, because a PN rejection is a policy/size decision that a retry won't change. The message
   reports `deliveryRejected` only if the last copy to fail was rejected.
4. **Oversize refusal does not call `fail`.** The propagated copy is simply never armed; the router
   reports `propagationRefused` and the delivery copy alone decides the message's outcome. A PN
   `perTransferLimit` of 0 or less counts as unknown (every existing PN fixture announces 0), and an
   unknown limit means the copy is attempted as today. The up-front check is a deliberate divergence
   from reference, which never checks the PN limit on send; recorded in the parity checklist.
5. **A link closing mid-transfer counts as a failed transfer** (closed, idle teardown or give-up):
   the copy returns to `retrying` with one timer. Give-up also fails queued copies.
6. **`setPropagationNode` clears pending markers** the same way `cancelPropagationStamps` does.
7. The 5th consecutive transfer failure fails the copy immediately, with no further 10 s wait.
8. Stale citation: `closed()` is at `LXMFRouter.swift:364`, not `:321`.

### Amendments at implementation time (2026-09-28)

9. **`sourceHash` refines amendment 1:** it is the far end of a link *we* opened (the destination
   we linked to) and nil for every inbound link, identified or not. `LXMFNode` does not track
   `linkIdentified`; an app wanting the sender of an identified inbound transfer waits for unpack.
10. **Cancelling a split send sends a cancel packet.** `LinkSession.cancelResource` drops the unsent
   segments and sends the standard RESOURCE_ICL for the segment in flight; "without a packet" only
   when no segment transfer is left. No `resourceFailed` follows a cancel.
11. **`deliveryCancelled` is reported once, and only if there was work.** The router reports it when
   it held any copy or queued message; the node reports it when the only work was a delivery stamp
   search the router never saw. A cancel for a message with nothing outstanding reports nothing,
   but the hash is still remembered.
12. **`cancelledMessages` is consulted at hand-over.** The router uses it only where it can act: a
   copy handed over after a cancel (a stamp search finishing late, via `send`/`sendViaPropagation`)
   is never armed, and `markPropagatedCopyPending` refuses a cancelled hash. It is not consulted on
   the transfer path. A fresh app-level `LXMFNode.sendMessage` for a cancelled hash un-cancels it
   first, so a deliberate re-send is a normal send (final-review ruling F2).
13. **Fractions are byte-based.** `ResourceTransfer` sums the sizes of the parts sent (`sentIndices`)
   or received (`receivedParts`); a split Resource's fraction spans its segments
   (`transferFraction`). The 0.10 point is the transfer's first progress event (`bytesDone == 0`),
   emitted when the sender advertises; the receiver reports 0 on accept.
14. **The pending marker is set synchronously.** `LXMFNode.sendMessage(alsoViaPropagation: true)`
   marks the copy through `LXMFRouter.State.markPropagatedCopyPending` in the same reduce (not a
   dispatched `.propagatedCopyPending` action), so a `cancelPropagationStamps` or
   `setPropagationNode` later in the same cycle already sees it; the router action remains as a thin
   wrapper over the same method.
15. **Transfer-phase progress is capped at 0.99.** `outboundFraction` never reports 1.0; only
   `finishProgress` does, on confirmation, so a full bar always means delivered (ruling F4).
16. **Cancel after a success is silent.** `cancelOutbound` for a hash in `succeededMessages` tears
   down the remaining copy — and the node stops its remaining stamp search — without
   `deliveryCancelled` (rulings F1, F1b). Abandoning a pending propagated copy while the delivery
   stamp search still runs drops the marker without `fail` (ruling F3).

## Out of scope

- Bandwidth throttling, resumable transfers, or partial-transfer persistence across relaunch.
- Reference RNS's multiple-concurrent-Resources-per-link (we serialise instead).
- The remaining backlog items: hop count, arrival interface, retry count, late proof after final
  retry, relay proof routing, and the delivery-stamp-search gaps (`cancelDeliveryStamps` bypassing
  `fail`; delivery copy in stamp search not outstanding).
- The images/files feature itself (next project).
