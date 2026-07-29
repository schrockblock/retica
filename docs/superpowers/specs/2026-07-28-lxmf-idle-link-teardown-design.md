# LXMF-4c-3b: Idle-Link Teardown — Design

**Sub-project:** LXMF-4 (LXMRouter), 4c robustness. Second half of 4c-3 (link recovery); completes 4c-3 after 4c-3a (link-CLOSED recovery). See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMRouter.clean_links` (`LXMRouter.py:951-965`): periodically tear down any `direct_link` with `link.no_data_for() > LINK_MAX_INACTIVITY` and drop it from `direct_links`; constant `LINK_MAX_INACTIVITY = 10*60` (`LXMRouter.py:35`).

## Goal

Our `LinkSession` keepalive watchdog (`keepaliveInterval=30`, `staleTime=60`) keeps an established direct link alive indefinitely. RNS's `clean_links` is a higher-level GC: proactively tear down a direct link that has carried no LXMF traffic for 10 minutes, so the router does not hoard idle direct links. This slice adds that idle teardown to the router.

## Approach

A per-link inactivity timer, restarted on activity — the same pattern `LinkSession` uses for `staleTime` and the router uses for delivery retries. No polling sweep and no wall-clock instants: just the `continuousClock` the reducer already depends on.

## Architecture

### Core constant (ReTiCA)
`Sources/ReTiCA/LXMF/LXMFDelivery.swift` gains:

```swift
/// Seconds a direct link may carry no LXMF traffic before the router tears it down — a higher GC than
/// the Link-level keepalive watchdog (RNS `LXMRouter.LINK_MAX_INACTIVITY`). Cross-validated.
public static let linkMaxInactivitySeconds = 600
```

### Reducer change (ReTiCANode `LXMFRouter`)

- **`CancelID`** gains `case idle(Data)` (per-destination).
- **`Action`** gains `case idleDeadline(destinationHash: Data)`.
- **`Action.Delegate`** gains `case closeLink(destinationHash: Data)` — the app wires this to tear down the real link (which then forwards `.linkClosed`).
- **Nested helper** alongside `retryTimer`:

```swift
func idleTimer(_ dest: Data) -> Effect<Action> {
    .run { send in
        try await clock.sleep(for: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
        await send(.idleDeadline(destinationHash: dest))
    }.cancellable(id: CancelID.idle(dest), cancelInFlight: true)
}
```

- **Restart on activity.** `idleTimer(dest)` is merged into the two effects that emit a `.sendDirect` for a *newly submitted* message to `dest`: `.send` direct-active and the `.linkEstablished` drain. `cancelInFlight: true` means each such send restarts the idle clock. The `.retryDue` active-link *resend* deliberately does **not** re-arm the idle timer: a retry saga is bounded to ~`maxAttempts × retryWaitSeconds` ≈ 50s ≪ 600s, so the original send's idle arm already spans the entire saga — re-arming on each resend would be redundant and would add an untested code path. New sends (the only activity that meaningfully extends a link's useful life beyond one saga) are covered by the two sites above.

- **`.idleDeadline(dest)`:**

```swift
case let .idleDeadline(dest):
    guard case .active = state.directLinks[dest] else { return .none }
    state.directLinks[dest] = nil
    return .send(.delegate(.closeLink(destinationHash: dest)))
```

The `guard case .active` makes a stale timer (link already closed or re-establishing) a no-op. No `hasPending`/`hasQueued` guard is needed: a pending direct delivery cannot survive to a 600s-idle fire — the retry timer resolves it (delivered or failed) within ~`maxAttempts × retryWaitSeconds` ≈ 50s, and each resend restarts the idle clock. So an idle fire implies no in-flight work, and the resulting `.closeLink → .linkClosed` finds nothing pending and does not spuriously re-establish (4c-3a).

`.linkClosed` and `.delivered` are otherwise unchanged. A lingering idle timer after `.linkClosed`-without-re-establish self-fires later as a `guard`-blocked no-op; a re-establish re-arms `idle(dest)` via the next `sendDirect` (`cancelInFlight` supersedes the old one).

## Data flow

```
.linkEstablished drain / .send direct-active  ──▶  .sendDirect(dest) ⊕ idleTimer(dest)   (restart)
… linkMaxInactivitySeconds with no further new send to dest …
.idleDeadline(dest) ──▶ directLinks[dest]=nil ; .delegate(.closeLink(dest))   → app tears down real link → .linkClosed(dest) (nothing pending → clears)
```

## Testing

TCA `TestStore` with an injected `TestClock`, `exhaustivity = .off`, mutation-verified. Idle timing is asserted via `directLinks[dest]` state (robust under `.off`), not only the delegate.

1. **Idle teardown fires.** Establish an active link with no queued/pending work; advance `linkMaxInactivitySeconds` → `.idleDeadline` → `.closeLink(dest)` emitted and `directLinks[dest] == nil`.
2. **Activity restarts the timer.** Establish (idle armed). Advance partway (< `linkMaxInactivitySeconds`); inject activity — `.send(message, .direct)` on the active link (emits `sendDirect`, restarts idle) followed immediately by `.delivered(hash)` (clears the pending + its retry timer, leaving only the restarted idle timer). Advance past the *original* deadline but before the *restarted* one → assert `directLinks[dest]` is still `.active` (proves the restart). Advance the remainder → `directLinks[dest] == nil` + `.closeLink(dest)`.
3. Cross-val constant test: `LXMFDelivery.linkMaxInactivitySeconds == f.linkMaxInactivity`, where the generator emits `link_max_inactivity` from `LXMF.LXMRouter.LINK_MAX_INACTIVITY`.

### Existing-test ripple

Adding a long-lived (600s) per-link idle timer means any existing test that flips `exhaustivity = .on` while an active link with recent `sendDirect` activity remains will now see that timer as an in-flight effect (which `.on` rejects at teardown). Those tests get their trailing `.on` flip removed — their core outcome assertions (via `.off` `receive`) stay intact; only the extra "no stray delegate at teardown" check is dropped, which is inherent to a persistent idle timer. The exact set (candidates: `routerRecoversPendingOnNewLinkAfterClose`, `routerDirectRetryUnaffectedByMissingPath`, `routerLinkClosedWithPendingReestablishes`, and any other test that flips `.on` after a `sendDirect`) is pinned during planning by running the suite and adjusting the ones that fail.

## Deferred (not in this slice)

- Restarting idle on inbound `.delivered` activity: negligible (a `sendDirect` always precedes `.delivered` within ~50s and already restarts the timer). Out of scope.
- LXMF-4d propagation; LXMF-5 stamps/rich-fields.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test. Apply mutations one at a time where they touch the same code.
- Cross-val fixtures must drive genuine LXMF (`cross-validation-drive-real-rns`); regenerating `lxmf_fixtures.json` churns the whole file (all LXMF cross-val re-derive + pass). Reference env: conda `rns` (`rns-reference-env`; rns 1.4.2 / lxmf 1.1.0).
- Signatures validated, never byte-compared (`ed25519-hedged-nondeterministic`); constants/hashes stay deterministic.
- New production: the `LXMFDelivery` constant (ReTiCA core) + the `LXMFRouter` reducer change (ReTiCANode); tests in `ReTiCATests` (cross-val) and `ReTiCANodeTests` (reducer). No Endpoint/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
