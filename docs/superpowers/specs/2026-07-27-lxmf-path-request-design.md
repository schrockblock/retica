# LXMF-4c-2: Path-Request on No-Path (direct establish) — Design

**Sub-project:** LXMF-4 (LXMRouter), 4c robustness, second sub-slice. Follows 4c-1 (retry timer). See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` (`LXMRouter.py:2820-2839` — direct outbound requests a path when none is known before establishing a link).

**Goal.** Before establishing a direct link, if the router has no path to the recipient, request one and wait; establish the link once the path is learned. Fixes the case that breaks today: `Endpoint.openLink` to a destination with no learned path returns `linkFailed` immediately (no auto path-request).

## Problem

4b's direct-outbound path emits `.requestLink(dest)` unconditionally when no link exists. But `Endpoint.openLink` requires a learned path (`state.transport.learned[dest]`); with none, it fails immediately (`linkFailed`). RNS handles this by requesting a path first and establishing the link only once a path is known (`process_outbound`, LXMRouter.py:2829-2838). This slice adds that path-awareness to the router's direct-establish path.

**Scope:** the direct-establish path check only (event-driven, no clock). Deferred: opportunistic-retry path-request (RNS requests a path after `MAX_PATHLESS_TRIES` failed opportunistic sends) and path-request timeout/give-up (`PATH_REQUEST_WAIT=7`).

## Architecture

Extends `Sources/ReTiCANode/LXMFRouter.swift`. Still decoupled — the app forwards `Endpoint.pathLearned` as `.learnedPath`, and wires the `.requestPath` delegate to `Transport.requestPath`.

### State + types
- `LinkStatus` gains a case: `case awaitingPath` (a path was requested; waiting to learn it before establishing).
  ```swift
  public enum LinkStatus: Equatable { case awaitingPath; case establishing; case active(linkID: Data) }
  ```
- State: `public var knownPaths: Set<Data> = []` — destinations we have a path to.

### Actions
- `case learnedPath(destinationHash: Data)` — app forwards `Endpoint.pathLearned`.
- `Delegate.requestPath(destinationHash: Data)` — app wires to `Transport.requestPath`.

### Reducer
- **`.send` direct, no `directLinks[dest]` entry** (replaces the current unconditional `requestLink`): enqueue the message, then
  - `knownPaths.contains(dest)` → `directLinks[dest] = .establishing`, emit `.requestLink(dest)` (unchanged behavior when a path is known).
  - else → `directLinks[dest] = .awaitingPath`, emit `.requestPath(dest)`.
  (A second `.send` for the same dest while `.awaitingPath` or `.establishing` — `directLinks[dest] != nil` — just enqueues, no re-request. The existing establish-once guard now also covers request-path-once.)
- **`.learnedPath(dest)`** → `knownPaths.insert(dest)`; if `directLinks[dest] == .awaitingPath` → `directLinks[dest] = .establishing`, emit `.requestLink(dest)` (proceed now that a path exists). Otherwise `.none`.
- `.linkEstablished` / drain, opportunistic `.send`, retry timer — unchanged (4b/4c-1). Queued `.awaitingPath` messages are not sent (and thus not armed with a delivery timer) until the link establishes and drains them.

## Data flow

```
.send(direct, dest), no link entry → enqueue msg
     knownPaths[dest]? ── yes ──▶ directLinks[dest]=.establishing ; .delegate(.requestLink(dest))   → Endpoint.openLink
                       └─ no  ──▶ directLinks[dest]=.awaitingPath ; .delegate(.requestPath(dest))   → Transport.requestPath
.learnedPath(dest) ──▶ knownPaths += dest ; if directLinks[dest]==.awaitingPath → .establishing ; .delegate(.requestLink(dest))
.linkEstablished(dest, linkID) ──▶ .active ; drain queue (unchanged)
```

## Testing

TCA `TestStore` (no clock), mutation-verified.

1. **Known path → establishes directly** — with `knownPaths` containing the dest (seeded in initial state), `.send(direct)` → `.requestLink(dest)` and `directLinks[dest] == .establishing` (unchanged 4b behavior preserved).
2. **No path → requests path** — `.send(direct)` with an empty `knownPaths` → `.requestPath(dest)`, `directLinks[dest] == .awaitingPath`, message enqueued, and **no** `requestLink`.
3. **learnedPath proceeds to establish** — after (2), `.learnedPath(dest)` → `.requestLink(dest)`, `directLinks[dest] == .establishing`; then `.linkEstablished` drains the queued message (`sendDirect`).
4. **Establish-once across awaitingPath** — a second `.send(direct)` to the same dest while `.awaitingPath` → no second `requestPath` (just enqueued); on `.learnedPath` then `.linkEstablished`, both queued messages drain.
5. **Unrelated learnedPath is inert** — `.learnedPath(otherDest)` with no `.awaitingPath` entry for it updates `knownPaths` but emits no `requestLink`.

No cross-val (pure behavior; no new wire constants).

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Signatures validated, never byte-compared (`ed25519-hedged-nondeterministic`).
- New production is the `LXMFRouter` extension (ReTiCANode); tests in `ReTiCANodeTests`. No Endpoint/Transport/core changes (the Endpoint↔router wiring is app-level, exercised by feeding the router `.learnedPath`/`.send` actions).
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
