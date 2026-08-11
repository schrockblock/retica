# Handoff — link lifecycle & delivery termination

**Date:** 2026-08-10
**HEAD at handoff:** `5912344`
**Suite:** 760/760 serially (`swift test --no-parallel`), 1 known issue
(`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`, pre-existing, `TransportTests`).

Read this before picking up the next slice. It records what is true, what is
NOT true, and — importantly — which claims in this repo have been wrong before.

---

## 1. What was built

Four slices, one theme: **every attempt to reach a peer must terminate, and
every object created for that attempt must be reaped.**

### 1a. Delivery termination (three slices)

The standing invariant, now holding on every traced route:

> A message queued for direct delivery always terminates — in delivery, or in
> `deliveryFailed`.

- **`establishAttempts`** (`LXMFRouter.State`) bounds the link-establishment
  saga. `pendingDeliveries.attempts` bounds only the retry-TIMER saga, and a
  message in `outboundQueue` is never armed with a timer until `linkEstablished`
  drains it — so without this counter, `linkClosed → establish → requestLink →
  linkFailed → linkClosed` recurred forever.
- **Establishment timeouts now reach the router.** `LinkSession`'s
  `establishmentDeadline` used to emit `.closed(.timedOut)`, which arrives as
  `linkClosed(linkID:)` and dies at `LXMFNode`'s reverse-map (populated only on
  `linkEstablished`). The destination wedged at `.establishing` permanently —
  no timer, no retry, no failure, and no recovery even when the peer returned.
  It now emits `.establishmentFailed(.timedOut)` **for initiators only**.
- **The `.awaitingPath` park is bounded** by `pathRequestTimer` drawing on the
  SAME `establishAttempts` budget, so a destination cannot ping-pong between the
  link branch and the park branch for a fresh allowance.
- **Path-shaped failures request a path** instead of retrying links.
  `linkFailed` carries a `LinkFailure`; `LXMFNode` routes `.noPath` /
  `.pathStale` / `.establishmentTimedOut` through `pathLostAndClosed` (clears
  `knownPaths`, so `establish` takes the park branch), while
  `.handshakeRejected` — the peer answered, so the route demonstrably works —
  still retries the link.
- **`BLEEndpoint.openLink` gates on `Transport.reachableLearned`.** A BLE peer
  that reconnects gets a new `InterfaceID` by construction, so a path learned
  before the reconnect names a dead interface.

### 1b. Link-element reaping (one slice)

`LinkPlane.acceptLinkRequest` appends a `LinkSession` element BEFORE dispatching
the work, and `LinkPlane` removes elements ONLY in response to a delegate
(`.closed` or `.establishmentFailed`). So any `return .none` on a path where no
timer is yet armed stranded the element permanently.

Fixed at three sites by emitting `.establishmentFailed` instead of `.none`.
`LinkPlane`'s `role == .initiator` gate means a **responder** reaps silently —
no spurious `linkFailed` naming our own served destination.

**The derived rule** (re-verified independently by two reviewers): an element is
reapable whenever a timer is armed — establishment timer while
`.pending`/`.handshake`, inactivity timer while `.active`. Only the pre-timer
windows in `.establish` and `.acceptRequest` are dangerous. All four `cancelAll`
sites emit a removal-triggering delegate in the same returned effect, so nothing
cancels-and-strands.

---

## 2. What is NOT true — read this before trusting any summary

**The link-element slice closes the MALFORMED-payload leak. It does NOT close
"the unbounded-growth leak."** I claimed the stronger thing repeatedly during
the session and it is false. Both of the following are probe-proven open, and
both are pre-existing rather than regressions:

- A **well-formed** LINKREQUEST creates an element an attacker retains
  indefinitely (see §3, F1).
- Replaying one identical well-formed LINKREQUEST creates unbounded elements
  AND can break legitimate establishment (see §3, F2).

The attacker's price went from "1 packet, retained forever" to "2 packets,
retained forever plus upkeep." Real improvement; not closure.

---

## 3. Open items, priority order

### F1 — unauthenticated keepalives hold a link element open forever ⚠️ highest value

**Where:** `LinkSession`, the `(.responder, .active, .data, .keepalive)` and
`(.initiator, .active, .data, .keepalive)` branches.

They re-arm `inactivityTimer(state.staleTime)` with **no decryption and no
authentication**. The only gate is `packet.destinationHash == state.linkID`, and
`linkID` rides in cleartext in every link packet header. `Transport` routes
link-addressed packets BEFORE the `seenPacketHashes` dedup — deliberately, so a
byte-identical keepalive replays forever. `LinkPlane.State.links` has no cap.

Probe held an `.active` element alive 200s (>3× `staleTime` = 60) on injected
plaintext keepalives. The pre-existing `LinkSessionTests` test that builds an
unauthenticated ping and asserts it resets inactivity documents the behaviour.

**Note:** `LinkPlane` already carries a deferred comment flagging plaintext
keepalives as a re-homing hazard. F1 shows the same weakness is now load-bearing
for element REAPING, not just re-homing — which raises its priority.

**Candidate fix:** gate inactivity-timer refresh on an authenticated packet, and
cap or rate-limit responder link creation per interface.

### F2 — replayed LINKREQUEST: resource cost AND a correctness bug

**Where:** `LinkPlane.acceptLinkRequest`.

50 replays of ONE identical well-formed LINKREQUEST → **50 elements sharing 1
`linkID`**, each costing an X25519 DH, an HKDF, and an **Ed25519 signature with
our long-term destination key**, emitting ~118 bytes (≈1.4× amplification),
reaped only at the 15s establishment deadline.

**The correctness half matters more than the DoS half:** because duplicates
share a `linkID`, `routeLinkPacket`'s `first(where:)` shadows — so a replayed
LINKREQUEST can make a **legitimate** establishment fail by consuming its RTT.

There is no ingress control for LINKREQUEST analogous to the C4 announce ingress
control in `Transport`.

### F3 — `PNNode` discards the `LinkFailure` reason

`PNNode`'s `linkFailed` handler binds and ignores the reason, terminally
abandoning `pendingSyncPeers[dest]` and never requesting a path — the behaviour
`LXMFNode` no longer has.

**Correction to an earlier claim:** this was previously described (by me) as
affecting "PN↔PN mesh sync against a stale BLE binding." **That is not
reachable.** `PNNode` composes `TCPEndpoint` directly, not `TransportEndpoint`,
so it cannot run over BLE at all; and `syncToPeer` has no production caller —
only tests drive it. The real gap is narrower: over TCP, a failed sync drops
silently with no delegate (`PNNode.Action.Delegate` has only `.messagesStored`).

Given no production caller, the proportionate fix is a **failure delegate** so
the drop is observable, NOT duplicating `LXMFRouter`'s retry machinery.

### F4 — `Link.buildProof` can crash the process

`Identity.sign` calls `preconditionFailure` without a private key. Both endpoints
guard `owner.privateKey != nil` before forwarding, but
`LinkPlane.acceptLinkRequest` is **public API** and does not. Reachable only by
direct composition, not remotely.

### F5 — smaller, verified

- `sendFailed` is emitted at 6 sites and consumed by **nobody** in `LXMFNode`.
  It conflates opportunistic-send failures (`Transport.send`) with link-traffic
  failures (`BLEEndpoint`) under one case with no discriminator, which is why no
  consumer can route it safely. Making it consumable is a delegate DESIGN change.
- `idleTimer` is never cancelled on close; a stale 600s timer can tear down a
  NEW link established with nothing queued.
- Standalone `LXMFNode.sendViaPropagation` silently drops with no
  `deliveryFailed` when the recipient identity is unlearned.
- `LinkSession`'s `.handshakeRejected` labels on the two responder-gated sites
  are unpinned (mutating them leaves the suite green). Latent, not live.
- **Out of repo (ReTiCaMsgr):** with a PN configured, one `message.hash` gets TWO
  sagas, and `deliveryFailed` overwrites `propagationAccepted` last-write-wins —
  a message that propagated fine at ~20s is marked failed when the opportunistic
  leg times out at ~50s.

---

## 4. Conventions established this session — please keep them

**Cite symbols, not line numbers,** for same-repo cross-file references. Line
citations drifted five times, once invalidated by the very commit that wrote
them (inserting an enum moved an emitter 12 lines and broke a citation in a
different file, in the same commit). Symbols drift only on rename, which the
compiler catches.

**Do not encode derived arithmetic in prose.** The `establishAttempts` doc was
falsified three times because it multiplied constants into wall-clock figures;
any change to `maxAttempts`, `pathRequestWaitSeconds`, `establishmentTimeout`,
or the routing invalidates the arithmetic while leaving confident prose behind.
State the mechanism, name the constants, and point at the tests — the clock
advances are executable and cannot go stale silently.

**Make a mislabeled failure a compile error.** `LinkPlane`'s `EstablishmentFailure
→ LinkFailure` mapping is an exhaustive `switch`, not a ternary, precisely so a
new case is a compile error and a deliberate routing decision rather than a
silent default into `.handshakeRejected` (the one PEER-shaped reason, the only
one that does not trigger a path request).

**Prefer eliminating an invariant over documenting one.** `pathLost` and
`linkClosed` had a load-bearing ordering; fusing them into `pathLostAndClosed`
and DELETING the ordering doc is better than explaining it.

---

## 5. TestStore traps — corrected, and the correction matters

**A trailing `.on` flip is NOT a no-op.** I asserted this without reading the
source, it propagated into a plan and four dispatches, a reviewer echoed it back
as a finding, and an implementer then deleted an assertion that was the SOLE
enforcement of its test's named property.

The truth: `reportIssueHelper` reads `self.exhaustivity` **at call time**, and
teardown (`deinit → completed() → assertNoReceivedActions`) runs after the test
body — so a trailing `.on` DOES catch stray received actions. It ALSO asserts no
in-flight effects, so it fails when a timer is armed.

- **Trailing `.on`** — catches strays; fails if a timer is armed.
- **Flip-then-send** — catches strays; tolerates armed timers. Prefer this,
  because it is robust, **not** because the alternative is inert.
- **Flipping back to `.off` before teardown disables the teardown check.** An
  implementer's test was vacuous for exactly this reason.

**Effect-produced state is invisible via `store.state` until drained.**
`#expect(store.state.x.isEmpty)` right after a send reads PRE-effect state and
passes even with the production code deleted. This exact assertion shape was
proven vacuous twice this month.

**Do not seed the state you claim to prove.**

---

## 6. Process notes for whoever continues

**The whole-branch review has found something real on 10/10 slices**, always in a
seam no single diff shows. Ask it STRUCTURAL questions — who consumes this, what
bounds this loop, trace it through production wiring not the reducer, construct
the adversarial sequence — not "review this diff." Give it licence to write
throwaway probes; the decisive findings in the last four slices all came from
probes rather than reasoning. Budget for a fix wave after it.

**Verify PROPERTY claims with a repo-wide grep.** Ten claims of mine were wrong
this session. Citations became reliable once I started opening files; claims
*about* behaviour did not. The failing shape is "only X does Y", "nothing
consumes Z", "this always/never happens" — checked in one place, false in
another. Three were caught by implementers rather than reviewers.

**Verify the ARROWS, not just the nodes.** One plan was built on a chain where
every `file:line` was correct and the chain still did not exist: I confirmed a
handler for `linkFailed` existed but never asked what *emits* it on that path.
Nothing did.

**"I ran it" is not "I read it."** An implementer reported a suite count before
reading the output file. It happened to be true; a red suite would have been
committed and reported green.

**Contradictory memories can coexist.** My memory index already recorded the
CORRECT `.on` rule in one file while I wrote the opposite into another and
propagated that one. Nothing forces two entries to be read side by side.

---

## 7. Suggested next slice

**Take F1 + F2 together as "an unauthenticated peer cannot pin or shadow a link
element."** They share a root cause (link elements are created and kept alive on
unauthenticated input) and a fix surface (`LinkPlane.acceptLinkRequest` +
`LinkSession`'s keepalive branches).

Scope sketch — decide the design deliberately, this is not obvious:

1. Gate inactivity-timer refresh on an AUTHENTICATED packet. Check what RNS
   reference does before choosing; the local fork and the conda `rns` env are
   both available (see the `two-rns-checkouts` / `rns-reference-env` memories —
   the fork's line numbers are shifted, cite the version).
2. Decide the duplicate-LINKREQUEST policy: dedupe by `linkID` (which also fixes
   the `first(where:)` shadowing correctness bug), cap `LinkPlane.State.links`,
   or rate-limit per interface. The shadowing bug argues for dedupe first.
3. Consider whether LINKREQUEST needs ingress control analogous to the announce
   ingress control already in `Transport`.

**Do the correctness half (shadowing) before or with the resource half** — a
replayed LINKREQUEST breaking a legitimate establishment is a functional bug that
will bite real users on a busy shared interface, independent of any attacker.

Working notes and per-task history for the four slices are under
`.superpowers/sdd/` (git-ignored) — `2026-08-09-bound-link-establishment-saga`,
`2026-08-10-establishment-timeout-reaches-delivery`,
`2026-08-10-stale-path-failures-request-a-path`,
`2026-08-10-link-elements-are-always-reaped`. Plans are in
`docs/superpowers/plans/`.
