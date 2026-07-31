# LXMF Propagation P1 — Client Send-via-PN — Design

**Date:** 2026-07-31
**Status:** Approved (design)

## Context: propagation-glue decomposition

Wiring the decoupled propagation reducers to real transport is a subsystem,
decomposed into independently-testable sub-slices:

- **P1 (this slice) — Client send-via-PN:** `LXMFNode` builds a propagation
  container and ships it as a Resource over a link to a configured
  propagation node's `lxmf.propagation` destination.
- **P2 — Client sync/receive from PN:** link + `IDENTIFY` + download request +
  receive response → open → `router.received`.
- **P3 — PN server node:** a new `Endpoint` + `PropagationNode` composition
  that registers/announces `lxmf.propagation`, ingests concluded-resource
  containers, and serves download requests. Propagation-accept confirmation
  (see below) is natural to add here, where it is end-to-end testable.
- **P4 — PN↔PN mesh:** peer offer/want sync over links.

## Goal (P1)

`LXMFNode` gains a client-side propagation send path. It reuses the
direct-link machinery from the direct-over-link + confirmation slices: the
router already establishes / reuses / queue-drains a link keyed on the PN
hash inside `sendViaPropagation`. The only genuinely new wire is
`sendPropagated → sendResourceOverLink`.

## Scope

**In scope:** client-side propagation send (config + build container + ship as
Resource to the PN), best-effort.

**Out of scope / deferred (deliberate):**
- **Propagation-accept confirmation.** Propagation "success" means *the PN
  accepted the container* (the recipient fetches it later, in P2) — a weaker,
  distinct signal from direct `deliveryConfirmed` (recipient got it).
  Overloading `deliveryConfirmed` with that meaning would mislead the app, so
  P1 stays best-effort. It carries the same bounded-but-wasteful retry-storm
  as direct-before-confirmation (cancellable timers, `pendingDeliveries`
  cleared on failure — no leak). A proper propagation-accept signal is a
  follow-on, natural to pair with P3 where it is end-to-end testable.
- P2/P3/P4 (sync, server, mesh).

## Architecture

### `LXMFNode` changes (thin — no router change)

**New action `setPropagationNode(destinationHash: Data)`** (config, called
once):

```swift
case let .setPropagationNode(destinationHash):
    return .send(.router(.setOutboundPropagationNode(destinationHash)))
```

**New action `sendViaPropagation(destinationHash: Data, title: Data, content: Data)`:**

```swift
case let .sendViaPropagation(destinationHash, title, content):
    guard let recipient = state.endpoint.transport.learned[destinationHash]?.identity
    else { return .none }
    let msg = LXMessage.create(source: state.identity, destinationHash: destinationHash,
                               timestamp: date.now.timeIntervalSince1970, title: title, content: content)
    let (packed, _) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient,
                                           timestamp: date.now.timeIntervalSince1970)
    return .send(.router(.sendViaPropagation(message: msg, propagationPacked: packed)))
```

`LXMFPropagation.pack(message:recipientIdentity:timestamp:) ->
(propagationPacked: Data, transientId: Data)` encrypts the container tail to
the **final recipient** (not the PN). The recipient identity comes from
`state.endpoint.transport.learned[destinationHash]?.identity` — the same
source the opportunistic path uses.

**New wire** (add among the direct/link translations, before the catch-all):

```swift
case let .router(.delegate(.sendPropagated(linkID, propagationPacked))):
    return .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: propagationPacked)))
```

The router emits `sendPropagated(linkID, propagationPacked)` from two sites —
the `sendViaPropagation` active-link path and the `linkEstablished`
propagation-queue drain — both handled by this single translation. Link
establish / reuse / path-request / close to the PN all reuse the existing
`LXMFNode` direct wiring (keyed on the PN hash).

The router may also emit `requestMessageDownload` (for P2 sync); it is not
wired in P1 and falls through to the existing `.none` catch-all.

### Two identities, two roles

- **PN identity + path** — learned via the PN's announce — establishes the
  *link* to `lxmf.propagation`.
- **Recipient identity** — learned via the recipient's announce — encrypts the
  container *tail*.

The PN only ever sees opaque encrypted bytes.

### `Endpoint` / `LXMFRouter`

No changes. `sendViaPropagation`, `setOutboundPropagationNode`, the
`sendPropagated` delegate, and the PN-link establish/drain all already exist
in the router; `sendResourceOverLink` already exists in the Endpoint.

## Testing

One integration test: client `LXMFNode` (A) + a **bare `Endpoint` as the PN
stub** registered for `lxmf.propagation` (the full `PropagationNode` ingest is
P3; here we need only a peer that completes the link + resource transfer so we
can inspect the delivered bytes). Reuses the `LXMFNodeDirectTests`
Link-handshake + Resource-transfer bridge.

Flow:
1. Three identities: client A, recipient R, propagation node PN. A learns R's
   identity (R's announce bridged) and the PN's `lxmf.propagation` path +
   identity (PN's announce bridged).
2. `A.send(.setPropagationNode(destinationHash: pnPropagationHash))`.
3. `A.send(.sendViaPropagation(destinationHash: rDeliveryHash, title:, content:))`
   — router establishes a link to the PN and drains the container as a
   Resource.
4. Bridge the handshake + resource frames A↔PN (index-based bridging per the
   prior-slice gotcha where LRRTT + RESOURCE_ADV can co-land in one `receive`).
5. Assert the PN stub's `resourceReceived(linkID, data)` carries the container;
   then verify `data`'s container parses, its entry's `transientId` matches
   `LXMFPropagation.transientId(lxmfData:)`, and
   `LXMFPropagation.open(lxmfData: entry, recipientIdentity: R)` recovers the
   message with `content`/`title` correct and `validateSignature(source: A) ==
   true` (deterministic hash / real Ed25519 validation — never a signature
   byte-compare).

Mutation verification, one at a time (e.g. drop the `sendPropagated →
sendResourceOverLink` wire → PN receives nothing; corrupt the recipient
identity used for `pack` → `open` fails to recover). Each must break the
covering test, then revert to green.

## Known Limitations (P1)

- No propagation-accept confirmation — best-effort; retry-storm to the PN
  until `maxAttempts` then `deliveryFailed` even on PN-accept (deferred, see
  Scope).
- Requires the recipient's and the PN's identities already learned (via
  announces), as with every other send path.
