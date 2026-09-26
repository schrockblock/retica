# LXMF-4c-2 remainder: Opportunistic Pathless-Retry — Design

**Sub-project:** LXMF-4 (LXMRouter), 4c robustness. Completes 4c-2 (the direct-establish path check shipped separately; see the `lxmf` memory). Follows 4c-1 (retry timer).

**Reference pin:** `lxmf 1.1.0` — `LXMRouter.process_outbound` opportunistic branch (`LXMRouter.py:2734-2761`); constants `PATH_REQUEST_WAIT = 7`, `MAX_PATHLESS_TRIES = 1` (`LXMRouter.py:33-34`).

## Goal

Opportunistic outbound currently retries by blindly resending until the delivery cap. When no path to the recipient is known, resending is futile. This slice makes an opportunistic retry **request a path** (instead of resending) when no path is known, waiting the longer `PATH_REQUEST_WAIT` before the next attempt, and resume normal resends once a path is learned.

## Reference behavior

`LXMRouter.process_outbound`, opportunistic method (`LXMRouter.py:2735-2761`): the message sends once best-effort, then on each retry cycle:
- `if delivery_attempts >= MAX_PATHLESS_TRIES(1) and not has_path(dest)` → request a path, set next attempt `now + PATH_REQUEST_WAIT(7)`, do **not** send.
- `elif delivery_attempts == MAX_PATHLESS_TRIES+1 and has_path(dest)` → path-rediscovery (`drop_path` + re-request). **Deferred** (see below).
- `else` → normal resend, next attempt `now + DELIVERY_RETRY_WAIT(10)`.
- Once `delivery_attempts > MAX_DELIVERY_ATTEMPTS(5)` → `fail_message`.

There is no separate path-request timeout; `MAX_DELIVERY_ATTEMPTS` is the give-up.

## Fit with our stack

The prior 4c-2 slice already gave `LXMFRouter` the state and wiring this needs: `knownPaths: Set<Data>`, the `.learnedPath(destinationHash:)` action (app forwards `Transport`/`Endpoint` path-learned), and the `.requestPath(destinationHash:)` delegate (app wires to `Transport.requestPath`). Our stack has no opportunistic DATA-packet receipt, so opportunistic delivery stays best-effort (retry-to-max, then `.deliveryFailed`) — this slice only changes *what* a retry does when there is no path.

`MAX_PATHLESS_TRIES = 1` is honored **structurally**, not via a counter: the first send at `.send` is the single unconditional best-effort try; the path check runs only from the first `.retryDue` onward. No `maxPathlessTries` constant is introduced (it would be a near-dead value in our arming model).

## Architecture

### Core constant (ReTiCA)
`Sources/ReTiCA/LXMF/LXMFDelivery.swift` gains:

```swift
/// RNS LXMRouter.PATH_REQUEST_WAIT — the wait after requesting a path before the next delivery
/// attempt (longer than retryWaitSeconds). Cross-validated against genuine LXMF.
public static let pathRequestWaitSeconds = 7
```

### Reducer change (ReTiCANode `LXMFRouter`)

Parameterize the nested `retryTimer` helper to accept a wait duration (it currently hardcodes `retryWaitSeconds`):

```swift
func retryTimer(_ hash: Data, _ seconds: Int) -> Effect<Action> {
    .run { send in
        try await clock.sleep(for: .seconds(seconds))
        await send(.retryDue(messageHash: hash))
    }.cancellable(id: CancelID.retry(hash), cancelInFlight: true)
}
```

All existing `retryTimer(hash)` call sites (arming in `.send` opportunistic, `.send` direct-active, `.linkEstablished` drain, and the normal-resend path of `.retryDue`) become `retryTimer(hash, LXMFDelivery.retryWaitSeconds)`.

In `.retryDue`, after the existing `attempts += 1` and the `> maxAttempts → deliveryFailed` terminal check, replace the single resend path with a branch:

```swift
state.pendingDeliveries[hash] = pending
switch pending.resend {
case let .opportunistic(destinationHash, payload):
    if !state.knownPaths.contains(destinationHash) {
        // Pathless opportunistic retry: request a path instead of resending, and wait longer.
        return .merge(.send(.delegate(.requestPath(destinationHash: destinationHash))),
                      retryTimer(hash, LXMFDelivery.pathRequestWaitSeconds))
    }
    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: destinationHash, payload: payload))),
                  retryTimer(hash, LXMFDelivery.retryWaitSeconds))
case let .direct(linkID, data, asResource):
    return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                  retryTimer(hash, LXMFDelivery.retryWaitSeconds))
}
```

The direct case is unchanged behavior (always resends at `retryWaitSeconds`); the opportunistic-only pathless branch is the new logic. `.send`, `.linkEstablished`, `.delivered`, `.learnedPath` are otherwise untouched — the first opportunistic send still arms at `retryWaitSeconds`, and `.learnedPath` already records `knownPaths`, so a subsequent retry resumes sending.

## Data flow

```
.send(opportunistic) ─▶ .sendOpportunistic (best-effort try #1) ; arm retry @ retryWaitSeconds(10)
.retryDue (opportunistic pending):
    attempts += 1 ; attempts > maxAttempts ─▶ .deliveryFailed
    else, knownPaths.contains(dest)?
        no  ─▶ .requestPath(dest)          ; restart retry @ pathRequestWaitSeconds(7)
        yes ─▶ .sendOpportunistic(dest,pl) ; restart retry @ retryWaitSeconds(10)
.learnedPath(dest) ─▶ knownPaths.insert(dest)   (next opportunistic retry then resends)
.delivered / .retryDue direct ─▶ unchanged (4c-1)
```

## Testing

TCA `TestStore` with an injected `TestClock`, `exhaustivity = .off`, mutation-verified. Discriminator: a `store.receive` looking for `requestPath` fails (times out) if the reducer emits `sendOpportunistic` instead, and vice-versa; the post-request wait is proven by advancing exactly `pathRequestWaitSeconds` to fire the next retry.

1. **Pathless retry requests a path and waits 7s.** `knownPaths` empty. `.send(opportunistic)` → `sendOpportunistic` (first best-effort try, `attempts == 1`). Advance `retryWaitSeconds(10)` → `.retryDue` → `requestPath(dest)` (not a resend), `attempts == 2`. Advance `pathRequestWaitSeconds(7)` → `requestPath(dest)` again (proves the 7s wait), `attempts == 3`. Clean up with `.delivered` → `deliveryConfirmed`, flip `.on`.
2. **Learning a path resumes sending.** `knownPaths` empty. `.send(opportunistic)` → `sendOpportunistic`. Advance 10 → `requestPath`. `.learnedPath(dest)`. Advance `pathRequestWaitSeconds(7)` → `sendOpportunistic` (path now known → resend, not `requestPath`). `.delivered` → `deliveryConfirmed`, flip `.on`.
3. **Known path from the start resends as before.** `knownPaths` seeded with dest. `.send(opportunistic)` → `sendOpportunistic`. Advance `retryWaitSeconds(10)` → `sendOpportunistic` again (no `requestPath`), `attempts == 2`. `.delivered` → `deliveryConfirmed`, flip `.on`. (Existing-behavior regression guard.)
4. **Direct pending is unaffected (opportunistic-only scope).** Seed `directLinks[dest] = .active(linkID)`, `knownPaths` empty. `.send(message, .direct)` → `sendDirect` (`attempts == 1`). Advance `retryWaitSeconds(10)` → `sendDirect` again (never `requestPath`, despite no known path). `.delivered` → `deliveryConfirmed`, flip `.on`.

Plus a cross-val constant test: `LXMFDelivery.pathRequestWaitSeconds == f.pathRequestWait` where the generator emits `path_request_wait` from `LXMF.LXMRouter.PATH_REQUEST_WAIT`.

## Deferred (not in this slice)

- **Path rediscovery** (`LXMRouter.py:2743-2752`): when a path *is* known but delivery keeps failing, `drop_path` + re-request to refresh a possibly-stale path. Our receipt-less opportunistic delivery cannot detect "still failing after a path was found," so this branch would be inert and untestable in our stack; it would also need a new `.dropPath` delegate. Revisit if/when opportunistic delivery gains a receipt. (It now has one — see `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md`. Rediscovery itself is still not implemented.)
- Link-CLOSED recovery + inactivity teardown (`LINK_MAX_INACTIVITY=600`) → LXMF-4c-3.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test. If mutations could mask each other, isolate them one at a time.
- Signatures validated, never byte-compared (`ed25519-hedged-nondeterministic`). Hashes/constants stay deterministic.
- Cross-val fixtures must drive genuine LXMF (`cross-validation-drive-real-rns`); regenerating `lxmf_fixtures.json` churns the whole file (LXMF-1/2/3/4b/4c-1 re-derive + pass). The conda `rns` env is the reference (`rns-reference-env`; baseline rns 1.4.2 / lxmf 1.1.0).
- New production: the `LXMFDelivery` constant (ReTiCA core) and the `LXMFRouter` reducer change (ReTiCANode); tests in `ReTiCATests` (cross-val) and `ReTiCANodeTests` (reducer). No Endpoint/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
