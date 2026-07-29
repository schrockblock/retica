# LXMF-4d-4: Client Inbound Sync (request orchestration) — Design

**Sub-project:** LXMF-4d (propagation). LXMF-4d: 4d-1 container [done] → 4d-2 client send [done] → 4d-3 PN store [done] → **4d-4 client sync [this]** → (4d-3b PN serve wiring, 4d-5 mesh deferred). See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMRouter.request_messages_from_propagation_node` (`LXMRouter.py:502-539`): establish a link to the `outbound_propagation_node`, IDENTIFY, and issue a `MESSAGE_GET` request; if no path, request one.

## Scope decision (autonomous)

A client sync has two halves:
- **Request orchestration (this slice, router):** link to the PN and ask it for messages addressed to us. Structurally the same link-establish/path-request/reuse as the send path.
- **Receive (reuses LXMF-4a — no new router code):** the PN returns `lxmf_data` entries; the app opens each with the client's own identity (4d-2a `open`) and feeds the recovered `LXMessage` into the router as `.received(method: .direct, destinationHash: …, data: message.packed)`. The existing 4a inbound path unpacks, dedups by `message.hash`, and delivers with signature validation. So the receive side needs nothing new here.

This slice therefore adds only the request orchestration. The `MESSAGE_GET` request/response wire framing, IDENTIFY, and the open-and-feed loop are app/Endpoint glue (exercised by feeding the router `.received`), consistent with how the router's transport interactions are app-wired delegates.

## Architecture

Extends `Sources/ReTiCANode/LXMFRouter.swift`. Reuses `outboundPropagationNode` (4d-2b) and the `directLinks`/`establish` link machinery keyed on the PN hash.

### State (addition)
```swift
/// Set when a sync was requested but the PN link is not yet active; drained on `.linkEstablished`.
var pendingDownloadFromPN: Bool = false
```

### Action (addition)
- `case syncFromPropagationNode` — the app asks the router to pull messages from the configured PN.

### Delegate (addition)
- `case requestMessageDownload(linkID: Data)` — the app IDENTIFYs on the PN link and issues the `MESSAGE_GET` request; on the response it opens each returned `lxmf_data` (4d-2a `open`) and feeds the recovered messages back via `.received`.

### Reducer
- **`.syncFromPropagationNode`:** `guard let pn = state.outboundPropagationNode else { return .none }` (no PN → nothing to sync). If `directLinks[pn]` is `.active(linkID)` → emit `.requestMessageDownload(linkID)`. Else → `state.pendingDownloadFromPN = true`; if `directLinks[pn] == nil` return `establish(&state, pn)` else `.none` (a link/path request is already in flight).
- **`.linkEstablished(dest, linkID)`:** after the existing direct + propagation drains, if `dest == state.outboundPropagationNode && state.pendingDownloadFromPN`, set `pendingDownloadFromPN = false` and append `.send(.delegate(.requestMessageDownload(linkID: linkID)))` to the effects.
- Everything else unchanged. The synced messages arrive later via `.received` (4a).

## Data flow

```
.syncFromPropagationNode:
    pn == nil ─▶ .none
    directLinks[pn] active ─▶ requestMessageDownload(link)
    else ─▶ pendingDownloadFromPN = true ; establish(pn) if no link
.linkEstablished(pn, link) ─▶ (drain send queues) + if pendingDownloadFromPN → requestMessageDownload(link) ; clear flag
   … app: IDENTIFY + MESSAGE_GET → response entries → open(each, ownIdentity) → .received(.direct, …, packed) …
.received(.direct, …, packed) ─▶ 4a: unpack → dedup by message.hash → messageDelivered (unchanged)
```

## Testing

TCA `TestStore`, `exhaustivity = .off`, mutation-verified. (Reuses the router test harness; `makeMessage` for a message when needed, though sync tests mostly assert delegates/flags.)

1. **No PN → no-op.** `.syncFromPropagationNode` with `outboundPropagationNode == nil` → no delegate, `pendingDownloadFromPN == false` (flip `.on` to catch a stray `requestLink`/`requestMessageDownload`).
2. **Active PN link → requests download immediately.** Seed `outboundPropagationNode = pn`, `directLinks[pn] = .active(linkID)`; `.syncFromPropagationNode` → `.requestMessageDownload(linkID)`; `pendingDownloadFromPN == false`.
3. **No link → establishes, then requests on linkEstablished.** Seed `pn` + `knownPaths.contains(pn)`; `.syncFromPropagationNode` → `requestLink(pn)`, `pendingDownloadFromPN == true`. Then `.linkEstablished(pn, linkID)` → `.requestMessageDownload(linkID)`, `pendingDownloadFromPN == false`.
4. **Flag cleared — no re-request on a later linkEstablished.** After (3), a second `.linkEstablished(pn, linkID2)` emits no `requestMessageDownload` (flag already cleared; flip `.on`).
5. **Receive path reuses 4a (integration sanity).** Feeding a synced message as `.received(method: .direct, destinationHash: Data(), data: message.packed)` yields `.messageDelivered` (this is existing 4a behavior; the test documents that synced-message receipt needs no new router code). *(Optional — may fold into the existing 4a coverage; include only if it adds signal.)*

## Deferred (not in this slice)

- The `MESSAGE_GET` request/response wire framing, IDENTIFY, and the app-side open-and-feed loop (app/Endpoint glue).
- Sync progress/completion tracking, `PR_*` transfer states, "mark locally delivered" bookkeeping.
- 4d-3b PN serve wiring; 4d-5 mesh; stamps (LXMF-5).

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test; absence-of-delegate via flipping `.on` last (only where no timer is in flight — sync requests arm no timers).
- New production is the `LXMFRouter` reducer (ReTiCANode); tests in `ReTiCANodeTests`. No core/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
