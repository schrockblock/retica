# LXMF-4d-2b: Router PROPAGATED Orchestration — Design

**Sub-project:** LXMF-4d (propagation). Second half of 4d-2 (client outbound via a propagation node). LXMF-4d: 4d-1 container [done] → 4d-2a pack/open [done] → **4d-2b router orchestration [this]** → 4d-3 PN store+serve → 4d-4 client sync → 4d-5 mesh. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMRouter.process_outbound` PROPAGATED branch (`LXMRouter.py:2846-2900`): if no `outbound_propagation_node`, fail; else establish a link to the PN (path-request if no path), transfer the `propagation_packed` over it (as a Resource), bounded by `MAX_DELIVERY_ATTEMPTS`.

## Goal

Add the `PROPAGATED` delivery path to the `LXMFRouter`: send a message to the recipient via a store-and-forward propagation node. The client establishes a link to the configured `outboundPropagationNode` and transfers the `propagationPacked` (built once by the app via 4d-2a `pack`) as a Resource, with the same establish/retry/close/idle robustness the direct path already has.

## Fit with the existing router

The propagation send is structurally the direct state machine, with three differences:
1. The link target is a single configured propagation node (`outboundPropagationNode`), not the recipient's delivery destination.
2. The transferred payload is the app-built `propagationPacked` (opaque to the router), not `message.packed`.
3. Retries must re-send the **same** `propagationPacked` bytes (so `transient_id` is stable and the PN dedups), so the router stores and reuses those bytes rather than rebuilding.

Everything else — establish-once/path-request (4c-2), retry-to-max (4c-1), close-recovery (4c-3a), idle teardown (4c-3b) — is reused by keying the PN link in the existing `directLinks` map on the PN hash.

## Architecture

Extends `Sources/ReTiCANode/LXMFRouter.swift`. Still decoupled: the app builds `propagationPacked` (4d-2a, needs the recipient identity + encryption) and hands it in; the router orchestrates the PN link and emits a `sendPropagated` delegate the app wires to a Resource transfer.

**Design choice — a separate `propagationQueue`, not a polymorphic rewrite of `outboundQueue`.** Making `outboundQueue` hold a `direct|propagated` enum would change its type and ripple every existing direct test that seeds it. Instead a parallel `propagationQueue` is added; `.linkEstablished` drains both (a dest is either a PN or a recipient, so one is always empty — no per-dest branching, no duplication of the direct drain logic, and zero change to the direct queue's type or tests).

### State / types (additions)
```swift
public var outboundPropagationNode: Data? = nil
struct PropagationItem: Equatable { var messageHash: Data; var propagationPacked: Data }
var propagationQueue: [Data: [PropagationItem]] = [:]   // keyed by PN hash
```
`ResendInfo` gains:
```swift
case propagated(destinationHash: Data, data: Data)      // destinationHash = the PN; data = propagationPacked
```

### Actions (additions)
- `case setOutboundPropagationNode(Data?)` — configure the PN.
- `case sendViaPropagation(message: LXMessage, propagationPacked: Data)` — the app supplies the pre-built container.

### Delegate (addition)
- `case sendPropagated(linkID: Data, propagationPacked: Data)` — the app Resource-transfers the container over the PN link.

### Reducer
- **`.setOutboundPropagationNode(pn)`:** `state.outboundPropagationNode = pn`; `.none`. (Deferred: tearing down an existing PN link when the PN changes — one-PN-at-a-time makes it low-value now.)
- **`.sendViaPropagation(message, packed)`:**
  - `guard let pn = state.outboundPropagationNode else { return .send(.delegate(.deliveryFailed(messageHash: message.hash))) }`.
  - If `directLinks[pn]` is `.active(linkID)`: `arm(&state, message.hash, .propagated(destinationHash: pn, data: packed))`; return `.merge(sendPropagated(linkID, packed), retryTimer(hash, retryWaitSeconds), idleTimer(pn))`.
  - Else: `propagationQueue[pn, default: []].append(PropagationItem(messageHash: message.hash, propagationPacked: packed))`; if `directLinks[pn] == nil` return `establish(&state, pn)` else `.none`.
- **`.linkEstablished(dest, linkID)`:** the existing direct-drain loop, then a second loop draining `propagationQueue[dest]` (clear it): for each item `arm(item.messageHash, .propagated(destinationHash: dest, data: item.propagationPacked))`, append `sendPropagated(linkID, item.propagationPacked)` and `retryTimer(item.messageHash, retryWaitSeconds)`. Arm the idle timer if either the direct queue OR the propagation queue drained anything.
- **`.retryDue`** `.propagated(destinationHash, data)` case (mirrors `.direct`): if `directLinks[destinationHash]` is `.active(linkID)` → `.merge(sendPropagated(linkID, data), retryTimer(hash, retryWaitSeconds))`; else (link down/re-establishing) → `retryTimer(hash, retryWaitSeconds)` only (the attempt was counted; bounded by `maxAttempts`).
- **`.linkClosed(dest)`:** the recover-if-work check also treats a non-empty `propagationQueue[dest]` OR a `.propagated`-to-`dest` pending as recoverable work → `establish(&state, dest)`.
- **`establish`, `.idleDeadline`, `.delivered`, `.received`, opportunistic/direct `.send`** — unchanged.

## Data flow

```
.setOutboundPropagationNode(pn)
.sendViaPropagation(message, packed):
    pn == nil ─▶ .deliveryFailed
    directLinks[pn] active ─▶ sendPropagated(link, packed) ⊕ retry ⊕ idle
    else ─▶ propagationQueue[pn] += item ; directLinks[pn]==nil ? establish(pn) : .none
.learnedPath(pn)/.linkEstablished(pn, link) ─▶ drain propagationQueue[pn] → sendPropagated(link,·) each ⊕ retry ⊕ idle
.retryDue(propagated) ─▶ active? sendPropagated(currentLink, sameBytes) : wait   (bounded)
.delivered(hash) ─▶ deliveryConfirmed (unchanged)
```

## Testing

TCA `TestStore` with an injected `TestClock`, `exhaustivity = .off`, mutation-verified. Existing direct/opportunistic tests must stay green (the direct queue type is unchanged).

1. **No PN → fails fast.** `.sendViaPropagation(message, packed)` with `outboundPropagationNode == nil` → `.deliveryFailed(message.hash)`.
2. **PN set, no link → establishes + queues.** `.setOutboundPropagationNode(pn)` (and `knownPaths` contains `pn`); `.sendViaPropagation` → `requestLink(pn)`, `directLinks[pn] == .establishing`, `propagationQueue[pn]?.count == 1`, no `sendPropagated` yet.
3. **linkEstablished drains as sendPropagated.** After (2), `.linkEstablished(pn, linkID)` → `.sendPropagated(linkID, packed)` with the exact `packed` bytes; `pendingDeliveries[message.hash]?.attempts == 1`.
4. **Active PN link → sends immediately.** Seed `directLinks[pn] = .active(linkID)`; `.sendViaPropagation` → `.sendPropagated(linkID, packed)` immediately; pending armed.
5. **Retry re-sends the same bytes.** After (4), advance `retryWaitSeconds` → `.retryDue` → `.sendPropagated(linkID, packed)` with the **same** `packed` bytes (byte-equal).

No cross-val (pure orchestration; the wire/crypto were pinned in 4d-1/4d-2a). The `propagationPacked` bytes are opaque test inputs (the tests use an arbitrary `Data`, e.g. built via 4d-2a `pack`, and assert the router carries those exact bytes through).

### Existing-test note
The direct `outboundQueue` type is unchanged, so existing direct tests are unaffected. Any test asserting `pendingDeliveries`/`directLinks` for the PN link uses the same shapes as direct.

## Deferred (not in this slice)

- PN-link teardown when `outboundPropagationNode` changes.
- End-to-end 2-node integration (needs a real PN to receive) → arrives with 4d-3.
- Propagation stamps / cost (`PROPAGATION_COST`) → LXMF-5.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test; apply mutations one at a time where they touch shared code.
- Prefer non-exhaustive TCA tests (`exhaustivity = .off`) asserting outcomes; absence-of-delegate via flipping `.on` last (only where no timer is left in flight — note the idle timer from a `sendPropagated` is long-lived, same as direct).
- Signatures/ciphertext hedged → the router only moves opaque `propagationPacked` bytes; no byte-compare of ciphertext beyond asserting the router carries the caller's exact bytes through.
- New production is the `LXMFRouter` reducer (ReTiCANode); tests in `ReTiCANodeTests`. No core/Transport changes (4d-2a already provides `pack`).
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
