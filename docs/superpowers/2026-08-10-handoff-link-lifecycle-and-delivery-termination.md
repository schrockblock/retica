# Handoff — link lifecycle & delivery termination

**Date:** 2026-08-10
**HEAD at handoff:** `5912344`
**Suite:** 760/760 serially (`swift test --no-parallel`), 1 known issue
(`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`, pre-existing, `TransportTests`).
Re-confirmed on the revision pass below — count and known issue both still exact.

> **Updated 2026-08-13** by the "unauthenticated input cannot pin, steal or kill a
> link element" slice (`4ef3a21..034a4c9`) and the sweep that closed it. Suite is
> now 824, same one known issue. **F1, F2 and F6 are CLOSED** — read their entries
> for what "closed" actually means, because F1's is bounded by resource policy and
> not by authentication. **F9–F16 are new**, in §3a. §5 gained the precise TCA
> mechanism behind its own rules, and §6 gained the defect shape that produced two
> of that slice's three worst holes. The branch-by-branch table those came out of
> is `docs/superpowers/2026-08-13-unauthenticated-link-element-sweep.md`.

**Revised 2026-08-10, after an independent verification pass** that re-derived
every claim below from the code rather than from this document. Most held. What
changed:

- **F2's correctness mechanism was inverted** and is rewritten. The old
  description would have aimed the fix at the wrong seam — and §7 tells you to
  do that half FIRST.
- **§2's "unbounded" overstated the leak** and contradicted §3's own wording.
  Corrected, which is pointed given §2 exists to correct overclaiming.
- **Three defects were missing entirely** and are now F6/F7/F8. One of them is
  cheaper to trigger than anything previously listed here.
- Smaller corrections to F1, F3, F4, F5 and to §1a's C1/C6, marked inline.

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

  **Two qualifications added on the revision pass.** (a) The bound is checked in
  `LXMFRouter.establish`, which is the sole emitter of `requestLink` repo-wide —
  so nothing inside `LXMFRouter` bypasses it. But `PNNode.syncToPeer` reaches
  link establishment by emitting `openLink` on its endpoint DIRECTLY, with no
  budget. That is safe only because it cannot loop (see F3), not because it is
  bounded. The counter is a property of `LXMFRouter`, not of the endpoint layer.
  (b) `.linkEstablished` RESETS the counter, so the bound holds for sagas that
  never succeed. An establish→established→immediately-closed peer refreshes the
  allowance every cycle; what bounds that cycle is `pendingDeliveries.attempts`.
  Neither is a defect — both are things the sentence above would let you assume
  away.
- **Establishment timeouts now reach the router.** `LinkSession`'s
  `establishmentDeadline` used to emit `.closed(.timedOut)`, which arrives as
  `linkClosed(linkID:)` and dies at `LXMFNode`'s reverse-map (populated only on
  `linkEstablished`). The destination wedged at `.establishing` permanently —
  no timer, no retry, no failure, and no recovery even when the peer returned.
  It now emits `.establishmentFailed(.timedOut)` **for initiators only**.
- **The `.awaitingPath` park is bounded** by `pathRequestTimer` drawing on the
  SAME `establishAttempts` budget, so a destination cannot ping-pong between the
  link branch and the park branch for a fresh allowance. Verified: neither
  `.learnedPath` (park→link) nor `.pathLostAndClosed` (link→park) touches the
  counter, so no branch switch buys a reset.

  **Refinement:** `establish`'s park branch does not itself increment — entering
  the park is free and the charge is deferred to `.pathRequestDeadline`. It is
  still bounded, because entering the park requires `directLinks[dest] == nil`
  and every re-park is preceded by a CHARGED `requestLink`, so each free park is
  paired with a charge. True conclusion, different mechanism than the sentence
  implies; worth knowing before editing either branch.
- **Path-shaped failures request a path** instead of retrying links.
  `linkFailed` carries a `LinkFailure`; `LXMFNode` routes `.noPath` /
  `.pathStale` / `.establishmentTimedOut` through `pathLostAndClosed` (clears
  `knownPaths`, so `establish` takes the park branch), while
  `.handshakeRejected` — the peer answered, so the route demonstrably works —
  still retries the link.
- **`BLEEndpoint.openLink` gates on `Transport.reachableLearned`.** A BLE peer
  that reconnects gets a new `InterfaceID` by construction, so a path learned
  before the reconnect names a dead interface.

  **Do not read this as "BLE-only by design."** `TCPEndpoint.openLink` has no
  such gate and the gap is reachable — see F8.

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
  indefinitely (see §3, F1). This is the genuinely unbounded one: the retention
  is driven by keepalives, which refresh the inactivity timer forever.
- Replaying one identical well-formed LINKREQUEST creates elements that are
  costly and that can break legitimate establishment (see §3, F2).

**Correction, revision pass — this section overstated the second bullet.** It
originally said replays create "unbounded" elements. They do not. Each duplicate
arms its OWN establishment timer (per-element cancellation is scoped by
navigation path, so `cancelInFlight` does not cross-cancel siblings), and every
duplicate dies at that deadline. The population is bounded by replay rate ×
establishment timeout — a rate-limited flood, not unbounded growth. F2's own
text always said this; §2 contradicted it. Since §2 exists precisely to correct
overclaiming, that mattered enough to fix.

The attacker's price went from "1 packet, retained forever" to "2 packets,
retained forever plus upkeep." Real improvement; not closure.

**Update 2026-08-13.** Both bullets are now CLOSED — the first by a cap, the
second by dedupe — but read F1 before reading "closed" as "authenticated". The
element COUNT is bounded; who holds the elements is not, and cannot be. And the
section's own framing still understates one thing: element retention is not a
keepalive property at all. ANY link-addressed packet extends an `.active` link,
including one that fails to decrypt (F16). This section named the branch it had
found rather than the property it was describing — the same error §7 records.

---

## 3. Open items

**IDs are stable; the numbering is NOT the priority order.** F1–F5 keep their
original IDs because plans and working notes reference them. F6–F8 were added on
the revision pass. **F9–F16 were added on 2026-08-13** by the
unauthenticated-input slice and the sweep that closed it — see
`docs/superpowers/2026-08-13-unauthenticated-link-element-sweep.md` for the full
branch-by-branch table those came out of.

**F1, F2 and F6 are CLOSED** by `4ef3a21..034a4c9`. See their entries.

Current priority:

1. **F13** — a reflected LINKREQUEST makes us forward our OWN link's traffic to
   the attacker. One packet. The only item here that redirects a legitimate
   peer's traffic rather than merely denying service. Gated on relay mode.
2. **F12** — one injected packet kills a legitimate OUTBOUND establishment and
   mislabels the failure PEER-shaped, so the delivery layer burns its whole
   budget retrying the same path. The initiator-side mirror of the CLOSED F6.
3. **F15** — one injected packet aborts every sender transfer on a link, and the
   same branch makes two of our own concurrent transfers destroy each other with
   no attacker present.
4. **F11** — advertise-and-stall pins a link against eviction and then refuses
   every inbound LINKREQUEST. Does not self-clear.
5. **F7** — a real unbounded leak, in the router rather than the link plane.
6. **F14**, then **F16**, then **F9**/**F10** (the two accepted residuals of the
   re-home fix — deliberate, pinned by tests, listed so a future fix confronts
   them rather than deleting them).
7. **F8**, then F3/F4/F5.

F12, F13, F14, F15 and F16 share the root cause F1/F2/F6 shared —
**unauthenticated input drives link-element lifecycle** — but NOT one fix
surface: they are in four different files and three different element
populations. Do not plan them as one slice on the strength of the shared cause.

### F1 — unauthenticated keepalives hold a link element open forever — ✅ CLOSED (bounded, not authenticated)

**CLOSED by `4ef3a21..034a4c9`**, and read the qualification before trusting the
word. What closed it is `LinkPlane.State.maxResponderLinks` (default 256) with
eviction ordered by `lastData`, a clock only successfully-decrypted non-keepalive
traffic advances (`7169c73`, `39d44bc`, `b384ed6`).

**The link-theft half is NARROWED, not closed** — say it here rather than three
paragraphs down, because "closed" is the word a skimmer takes away. The re-home
decision moved into `LinkSession` behind an authentication gate (`5414b0b`,
then `349a77b` pinning the same-interface guard), and `e3eb397` then deliberately
WIDENED it again with the one-shot local-disconnect grant, so this is a
three-commit story and not a single one. What remains: **F9** — the gate proves a
packet originated from a key holder, not that its sender is one, and nothing
dedupes inbound link packets, so one captured ciphertext still re-homes; and
**F10** — the disconnect grant is spendable by any interface. The attacker's price
went from "observe a cleartext linkID" to "capture one ciphertext", or to "be
connected when a local interface drops". Real improvement; not closure.

**This is a RESOURCE-POLICY bound, not an authentication one, and it cannot be
anything else.** Opening a link is unauthenticated by protocol design: an
attacker supplies the LINKREQUEST, completes a genuine handshake with its own
ephemeral, and then holds a valid session key — so it keeps an element alive with
perfectly AUTHENTICATED keepalives forever. No gate bounds that. The element
count is bounded; the identity of who holds the elements is not.

**And the cap is refusable-into.** F11 shows a peer can make its own link
eviction-immune and, at the cap, cause every inbound LINKREQUEST from anyone to
be refused. F14 shows the cap evicts before it validates. The bound holds on
`links.count`; the availability guarantee does not.

The original text follows, because its mechanism description is still accurate
and F9/F10/F16 are corrections to it rather than replacements.

**Where:** `LinkSession`, the `(.responder, .active, .data, .keepalive)` and
`(.initiator, .active, .data, .keepalive)` branches.

They re-arm `inactivityTimer(state.staleTime)` with **no decryption and no
authentication**. `Transport` routes link-addressed packets BEFORE the
`seenPacketHashes` dedup — deliberately, so a byte-identical keepalive replays
forever. `LinkPlane.State.links` has no cap (verified: appended in `openLink`
and `acceptLinkRequest`, removed only by the two delegate handlers, no
plane-level GC anywhere).

Probe held an `.active` element alive 200s on injected plaintext keepalives. The
pre-existing `LinkSessionTests` test that builds an unauthenticated ping and
asserts it resets inactivity documents the behaviour.

**Three corrections from the revision pass, all making F1 worse:**

**(a) The gate is weaker than "`destinationHash == linkID`."** That understates
it — `packetType` and `context` must also match, and the initiator branch
additionally requires `payload != Data([0xFF])`. All are attacker-chosen
cleartext header bytes, so the conclusion is unchanged. But note the initiator
branch accepts ANY payload except exactly `0xFF`, including an empty one.

**(b) `linkID` is more exposed than "rides in the LINKREQUEST."** `Packet.packed`
writes `destinationHash` — which IS the linkID for link packets — unencrypted
into EVERY link packet header. An eavesdropper never needs to have seen the
LINKREQUEST. Any single captured link packet is enough.

**(c) The responder branch also REFLECTS.** `0xFF` in → `0xFE` out,
unauthenticated. That is a reflection/amplification primitive, not just a
liveness refresh, and it is available to anyone holding a linkID.

**The re-homing consequence is the severe one — this is link THEFT, not just
element retention.** `LinkPlane.routeLinkPacket` re-homes the element AND every
in-flight resource transfer to the ARRIVAL interface before delivering. So an
unauthenticated keepalive from an attacker's interface redirects the legitimate
peer's subsequent traffic to the attacker. `LinkPlane` already carries a
deferred comment flagging plaintext keepalives as a re-homing hazard; the
original F1 text treated re-homing as the known-lesser issue and element reaping
as the escalation. That ordering is backwards.

**What RNS does — checked, and it does NOT cover the fix.** `Link.receive`
(reference tree) updates `last_inbound` and revives `STALE → ACTIVE` BEFORE any
decryption, exactly as we do. So "gate the refresh on an authenticated packet"
is a DIVERGENCE from reference, not a transcription of it — decide it as a
design choice with that known. RNS's actual defense is different: it refuses to
touch `last_inbound` when the packet arrives on an interface other than the
link's attached one, and logs a manipulation warning. **We cannot currently
implement that guard** — `LinkSession.Action.received` carries only `Data`, with
no interface — even though `LinkPlane` HAS the arrival interface at the routing
site and chooses to re-home with it. Threading the interface into the action, or
moving the decision up into `LinkPlane`, is the reference-aligned option.

**Candidate fix:** gate inactivity-timer refresh AND re-homing on an
authenticated packet, and cap or rate-limit responder link creation per
interface. Note the two gates live in different files — see §7.

### F2 — replayed LINKREQUEST: resource cost AND a correctness bug — ✅ CLOSED

**CLOSED by `7dc7e55`**: `LinkPlane.acceptLinkRequest` now dedupes by `linkID`
before doing any crypto, so a duplicate costs one `Packet(raw:)` parse and one
`truncatedHash` instead of a keypair generation, a DH, an HKDF and an Ed25519
signature with our long-term destination key. This also collapses the
non-adversarial multipath duplicates the original entry argued were the stronger
reason to dedupe.

The sweep probed the one ordering concern the fix raises — the guard reads a
`linkID` that is written only by the deferred `.acceptRequest` child action, so
two requests queued together might both pass it. They do not: two identical
requests driven back-to-back through a real `Store` with no awaiting produced one
element. TCA drains the child before the second action is reduced.

The original text follows.

**Where:** `LinkPlane.acceptLinkRequest`.

50 replays of ONE identical well-formed LINKREQUEST → **50 elements sharing 1
`linkID`**, each costing an X25519 DH, an HKDF, and an **Ed25519 signature with
our long-term destination key**, emitting ~118 bytes (≈1.4× amplification),
reaped only at the establishment deadline.

**Cost correction (upward):** `LinkPlane.acceptLinkRequest` does not pass an
`ephemeral`, so the defaulted `ephemeral: Identity = Identity()` runs a fresh
X25519 + Ed25519 **keypair generation** per replay, on top of the DH/HKDF/sign
above.

> ### ⚠️ The correctness mechanism below was WRONG in the original handoff
>
> It said: *"because duplicates share a `linkID`, `routeLinkPacket`'s
> `first(where:)` shadows — so a replayed LINKREQUEST can make a legitimate
> establishment fail by consuming its RTT."*
>
> **The victim and the trigger are both wrong, and a fix aimed at this
> description would target the wrong seam.** `IdentifiedArrayOf` is
> insertion-ordered and `first(where:)` returns the EARLIEST append. A replay
> necessarily arrives after the original and TCA drains actions FIFO, so the
> **legitimate element always wins routing**. The duplicate is the one that
> starves and then gets reaped. The duplicate never consumes the legitimate RTT.

**The real failure mode is the mirror image.** Each duplicate emits its OWN
LRPROOF under a DIFFERENT responder ephemeral, every one validly signed by the
same owning identity — so `Link.validateProof` accepts any of them. The
initiator locks to whichever proof **arrives first** and has no way to tell which
responder element produced it; after that it is `.active` and later proofs fall
through to `default`.

If the proof it locked to came from a duplicate, the RTT is encrypted under the
DUPLICATE's session key but routes to the FIRST (legitimate) element. That
element fails HMAC and emits `.establishmentFailed(.handshakeRejected)`, so
**the legitimate element is reaped** — silently, because `LinkPlane` suppresses
`linkFailed` for the responder role. There is no RTT retransmit, so the duplicate
never activates either. The initiator has already emitted `.established` and
never learns otherwise: it holds a **zombie link** whose data packets are
silently dropped, recovering only via the LXMF retry ladder or the inactivity
watchdog.

So: the shadowing hurts the legitimate side **only when the initiator keys to a
duplicate's proof** — reachable via proof reordering, loss of the first proof, an
on-path attacker suppressing it, or asymmetric multi-interface latency. Absent
that, it hurts only the duplicate. The failure is *"the legitimate element is
killed by an RTT it cannot decrypt,"* not *"a duplicate consumes the legitimate
RTT."*

**Duplicate elements also arise NON-adversarially, which is the stronger argument
for dedupe.** `hashablePart` excludes `hops`, `headerType`, `transportType` and
`transportId`, so a HEADER_1 copy and a relayed HEADER_2 copy of the SAME request
share a `linkID`. Any multipath mesh produces duplicate elements with no attacker
present. Dedupe-by-`linkID` collapses those too — the right outcome, but a
broader behaviour change than "drop replays," so scope it deliberately.

There is no ingress control for LINKREQUEST analogous to the C4 announce ingress
control in `Transport` (confirmed: the burst/hold/arrival machinery is reached
exclusively from the `.announce` branch; the LINKREQUEST branch has no rate
limit, no hold queue, no per-interface accounting).

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

**The revision pass confirmed all three sub-claims and found the scoping is
weaker still:** `PNNode` has no production consumer AT ALL. The only non-test,
non-doc reference to the type anywhere is a comment in `LXMFServiceNode`, and the
sibling app composes `LXMFServiceNode`, not `PNNode`. So this is dead code with a
latent bug, not a live bug — which is why it sits near the bottom of the priority
list despite being easy to fix.

Given no production caller, the proportionate fix is a **failure delegate** so
the drop is observable, NOT duplicating `LXMFRouter`'s retry machinery.

### F4 — `Link.buildProof` can crash the process

`Identity.sign` calls `preconditionFailure` without a private key — the only
`preconditionFailure`/`fatalError` in all of `Sources`. Both endpoints guard
`owner.privateKey != nil` before forwarding ("both" is exactly two: `TCPEndpoint`
and `BLEEndpoint` are the only call sites of `acceptLinkRequest`), but
`LinkPlane.acceptLinkRequest` is **public API** and does not. Reachable only by
direct composition, not remotely.

**Second unguarded public path, same shape, missed originally:**
`LinkPlane.identifyOverLink` → `LinkSession.identify` → `identity.sign(...)`,
also public, also with no `privateKey` guard. Fix both together.
(`LinkSession.provePacket` → `owner.sign` is reachable only through the guarded
endpoint path, so it is fine.)

### F5 — smaller, verified

- `sendFailed` is consumed by **nobody** — confirmed repo-wide, including the
  sibling app. `LXMFNode` swallows it in its `case .endpoint, .router, .delegate`
  catch-all. It conflates opportunistic-send failures (`Transport.send`) with
  link-traffic failures (`BLEEndpoint`) under one case with no discriminator,
  which is why no consumer can route it safely. Making it consumable is a
  delegate DESIGN change. *("6 sites" matched no clean convention: 5 distinct
  causes, 7 textual emit statements counting endpoint forwarders, 8 if you count
  `BLEInterface`'s differently-typed `sendFailed(peer:reason:)` — which is also
  unconsumed. Count causes, not statements.)*
- `idleTimer` is never cancelled on close (`CancelID.idle` appears exactly once
  in `Sources`, at the arming site; the only suppression is re-arming), and the
  harm is real — the `.idleDeadline` guard does NOT prevent it, because a new
  link is also `.active`. Reachable route: direct send arms the timer → link
  closes → `closed()` re-establishes because the message is in
  `pendingDeliveries` → `.linkEstablished` arms a new idle timer only if
  something was queued, and nothing was → the stale timer fires on its ORIGINAL
  deadline and closes the new link. The PN-sync branch has the same shape.
- Standalone `LXMFNode.sendViaPropagation` silently drops with no
  `deliveryFailed` when the recipient identity is unlearned. (Note the contrast:
  `LXMFRouter.sendViaPropagation` DOES emit `deliveryFailed` when no PN is
  configured — the gap is specifically `LXMFNode`'s identity lookup.)
- `LinkSession`'s `.handshakeRejected` labels on the responder-gated sites are
  unpinned. **Corrected: there are three, not two, and "latent, not live" is
  wrong for two of them.** The third is `received (.responder, .handshake,
  .data, .linkRequestRTT)` — that one is F6, and the reap it triggers is live and
  remotely triggerable. And `acceptRequest`'s empty-session-key guard is remotely
  reachable via an all-zeros X25519 key (the degenerate-point trick the tests
  already use on the initiator side), so what is untested there is the
  element-reaping BEHAVIOUR, not merely the label.
- **Out of repo (ReTiCaMsgr):** with a PN configured, one `message.hash` gets TWO
  sagas, and `deliveryFailed` overwrites `propagationAccepted` last-write-wins —
  a message that propagated fine at ~20s is marked failed when the opportunistic
  leg times out at ~50s.

### F6 — one injected packet kills a legitimate inbound establishment — ✅ CLOSED

**CLOSED by `331843a`**: `(.responder, .handshake, .data, .linkRequestRTT)` now
returns `.none` on a decrypt/decode failure and lets `establishmentDeadline`
decide, instead of emitting `.establishmentFailed(.handshakeRejected)`. The
element stays reapable because the establishment timer is already armed, so the
§1b invariant still holds.

**The same defect is still live on the INITIATOR side — see F12.** Fixing the
responder branch and not its mirror is the exact shape §6 warns about, and it
survived the whole slice because the slice was framed around inbound
establishment.

The original text follows.

**Where:** `LinkSession.received`, case
`(.responder, .handshake, .data, .linkRequestRTT)`.

A decrypt/decode failure there emits `.establishmentFailed(.handshakeRejected)`,
which makes `LinkPlane` **reap a legitimate in-progress responder link**. The
branch performs no authentication before deciding. Reaching it needs only the
cleartext `linkID` — and `Transport` routes any `destinationType == .link` packet
to `linkPacket` by that `linkID` BEFORE `seenPacketHashes` (the same path F1
cites), while `linkID` is derivable by anyone who saw the LINKREQUEST or any
subsequent link packet (F1(b)).

So: inject one garbage RTT packet at a linkID you observed, and the legitimate
establishment dies. `LinkPlane` suppresses `linkFailed` for the responder role,
so it dies **silently**.

This is the same root-cause family as F1 and F2 — unauthenticated input driving
link-element lifecycle — but in the opposite direction: F1/F2 are about elements
that will not die, F6 is about an element that dies when it should not. It shares
their fix surface and belongs in the same slice. The §1b rule ("an element is
reapable whenever a timer is armed") is about STRANDING and does not cover this
inverse hazard.

### F7 — `linkResourceInFlight` leaks on idle teardown

**Added on the revision pass. A genuinely unbounded leak — in `LXMFRouter` rather
than `LinkPlane`, which is why the link-element slice did not touch it.**

`LXMFRouter`'s `.idleDeadline` sets `directLinks[dest] = nil` and THEN emits
`.closeLink`. The only clearer of `linkResourceInFlight[linkID]` on the close path
is `closed()`, whose `if case let .active(linkID) = state.directLinks[dest]` can
no longer match — the entry was already nil'd before the resulting `linkClosed`
arrives. **Any link torn down by the idle timer with a resource still in flight
leaks its `linkResourceInFlight` entry permanently.**

`giveUp` nils `directLinks[dest]` the same way without going through `closed()`,
though it is unreachable with an `.active` link.

This is exactly the "every object created for that attempt must be reaped"
invariant from §1 failing — in a router-side map instead of `LinkPlane.State.links`.
Worth noting for §6: the whole-branch review found the link-plane half and the
router-side half went unexamined because the slice was framed around `LinkPlane`.

### F8 — `TCPEndpoint.openLink` has no `reachableLearned` gate

**Added on the revision pass.** §1a's BLE bullet should not be read as
"BLE-only by design."

`TCPEndpoint.openLink` checks only `learned == nil → .noPath`; it never calls
`reachableLearned`. The gap is reachable: `TCPEndpoint` emits
`interfaceDisconnected` on socket loss, `Transport` then drops the interface, but
`reachableLearned` is deliberately non-destructive so `learned` retains the entry.
Result: a `LinkSession` that transmits into a dead interface and exits only via
the establishment deadline → `.establishmentTimedOut` → `pathLostAndClosed`.

Terminating, so not a hang — but it costs a full establishment timeout and one
attempt from the budget per cycle where BLE costs zero. The BLE code's own
rationale (*"`Transport.send` already gates on this; `openLink` must too"*)
applies verbatim to TCP.

**Minor, same area:** `LXMFRouter`'s `closed()` no-work branch resets
`establishAttempts` without cancelling the path-request timer, unlike `giveUp`
and `.linkEstablished`. Harmless today — the stale timer is swallowed by
`.pathRequestDeadline`'s `.awaitingPath` guard — but it is the one park exit that
does not cancel, and the asymmetry is a trap for a future edit to that guard.

---

## 3a. Added 2026-08-13 — the unauthenticated-input slice and its sweep

**F9, F10 and F11 are ACCEPTED RESIDUALS of the slice**, not defects it missed:
each was found during execution, priced, and deliberately left. **F12–F16 are
defects the sweep found.** All eight are pinned by something executable or by a
probe recorded in
`docs/superpowers/2026-08-13-unauthenticated-link-element-sweep.md`.

### F9 — link traffic has no per-packet replay rejection, anywhere in the link path

**Where:** `Transport.received` (the `destinationType == .link` return sits ABOVE
`seenPacketHashes.insert`) and `LinkSession.received`, which keeps **no inbound
packet-hash SET** — nothing there remembers that a packet has been seen.

State that precisely, because the obvious shorthand ("every `packetHash` use
there is outbound-keyed") is FALSE and was written that way in an earlier draft:
`(_, .active, .data, .none)` surfaces the INBOUND `packet.packetHash` in
`.dataReceived(data:packetHash:)`, and `.provePacket(packetHash:)` signs that
inbound value. Only `pendingDataReceipts` is outbound-keyed. Inbound hashes are
computed and used — they are just never RETAINED for comparison, which is the
property that matters.

The Transport half is deliberate and correct in isolation: byte-identical
keepalives share a packet hash and must not be deduped, and a retried link
request should still reach us. Pinned by `identicalLinkPacketsBypassDedup`.
The consequence is not confined to keepalives — **EVERY inbound link context is
replayable.**

**Why it matters for this slice specifically.** Task 5's re-home gate establishes
that a packet ORIGINATED from a holder of the session key. It does NOT establish
that the party which just sent it holds one. So an attacker that captures ONE
authenticated data packet replays those exact bytes from its own interface and
still re-homes the link. The fix NARROWED link theft from "observe a cleartext
linkID" to "capture any one ciphertext"; it did not close it. Probe-proven during
Task 5 and pinned by
`replayedAuthenticatedLinkPacketIsProcessedAgainAndMovesTheBinding`.

**Second-order consequence, from the sweep:** `LinkSession`'s
`.resourceAdvertisement` same-hash dedup is over LIVE transfers only, so once a
stalled transfer is reaped, replaying the SAME captured advertisement re-creates
it. One captured advertisement, replayed on a cycle, keeps `transfers` permanently
non-empty — which is F11's eviction immunity, without ever holding the session
key. (Both halves verified by reading; the composition was not separately probed.)

Closing F9 needs per-packet replay rejection on the link, which does not exist
anywhere in the link path today, and which has to be designed around the
keepalive exemption that put the Transport dispatch above the dedup in the first
place.

### F10 — the local-disconnect re-home grant is claimable by anyone

**Where:** `LinkPlane.interfaceDisconnected` sets `rehomePermitted`;
`LinkSession.received`'s re-home block consumes it.

The TRIGGER is unforgeable — a remote attacker cannot cause a local interface to
disconnect. The CONSUMPTION is not authenticated at all. Once `rehomePermitted`
is set, the first link-addressed packet from ANY interface other than the stored
one re-homes the link with no authentication whatsoever; the reducer sees only
`arrivalInterface` and cannot distinguish the reconnecting peer from a bystander.

**Reachable, not theoretical.** `BLEEndpoint.State.peerInterfaces` is a
multi-peer map, BLEEndpoint routes EVERY peer's link packets into
`LinkPlane.routeLinkPacket` tagged with that peer's `InterfaceID`, and `linkID`
is cleartext. A second connected peer that has merely OBSERVED one link packet
can claim the grant ahead of the returning peer, which is then stranded. Note the
prerequisite is WEAKER than F9's: F9 needs a captured authenticated packet, this
needs only an observed `linkID`. Pinned by
`theReHomeGrantIsSpentByWhicheverInterfaceSpeaksFirst`.

**INHERENT to the chosen design** (authenticate, or spend a local-disconnect
grant), which was chosen over closing every link on a local disconnect — that
alternative aborts in-flight transfers on every reconnect and is worse.

**Correction to how this was first written, including in the production comment:**
it was described as bounded "to the window before the inactivity watchdog reaps
the element." That bound does not hold against an attacker — see F16, the same
party refreshes the watchdog with junk. Bounded to one re-home per disconnect;
not otherwise bounded. Nothing clears `rehomePermitted` except the re-home that
spends it, so the grant does not expire either.

### F11 — advertise-and-stall pins a link against eviction

**Where:** `LinkSession.received`'s `(_, .active, .data, .resourceAdvertisement)`
branch, and `LinkPlane.acceptLinkRequest`'s `evictable` filter.

The branch appends to `state.transfers` after decrypt, unpack and a SAME-hash
dedup only, so DISTINCT-hash advertisements append without bound (probe: 25
advertisements → 25 transfers). The eviction filter skips any link whose
`transfers` is non-empty — deliberately, because resource SEGMENT contexts
forward raw bytes to `ResourceTransfer` children that decrypt internally and so
never advance `lastData`, which would make a link receiving a large resource look
maximally idle exactly when evicting it is most wasteful.

Composed: a peer holding an active link advertises, never sends a segment, and
becomes eviction-immune; re-advertising outruns `ResourceTransfer`'s receiver
watchdog. Holding the cap that way makes every inbound LINKREQUEST from anyone be
refused. This is the same class of unauthenticated-input resource exhaustion the
slice exists to close, and unlike the `.handshake` variant — where elements leave
on their own establishment deadline — it does NOT self-clear without the
advertiser's cooperation. Pinned by
`distinctAdvertisementsGrowTransfersAndPinTheLinkAgainstEviction`.

The durable fix is a per-link bound on `transfers`. That is its own slice: it has
to decide what happens to the transfer it displaces.

### F12 — one injected packet kills a legitimate OUTBOUND establishment ⚠️

**Where:** `LinkSession.received`, case
`(.initiator, .pending, .proof, .linkRequestProof)`.

**The initiator-side mirror of the now-CLOSED F6, still live.** A failed
`Link.validateProof` emits `.establishmentFailed(.handshakeRejected)`;
`LinkPlane` removes the element and, because the role IS `.initiator`, reports
`linkFailed(destinationHash:reason: .handshakeRejected)` upward.

Reaching it needs only the cleartext `linkID`, which any observer of our outbound
LINKREQUEST computes exactly — `Link.linkID` hashes `Packet.hashablePart`, every
byte of which is on the wire. Probe: one 99-byte garbage `.proof` packet →
`linkFailed(.handshakeRejected)` and `links.count == 0`.

**The mislabel is the expensive half.** `.handshakeRejected` is the one
PEER-shaped `LinkFailure`, and it is the only one the delivery layer does NOT
answer with a path request — `LXMFNode` retries the link on the same path. So one
packet per attempt burns the entire `establishAttempts` budget against a path
that was never the problem, terminating in `deliveryFailed`.

The fix is Task 1's, applied to this branch: ignore an unvalidatable proof and let
`establishmentDeadline` decide. The element is reapable throughout — the
establishment timer is already armed.

### F13 — a reflected LINKREQUEST makes us forward our own link's traffic to the attacker ⚠️ top priority

**Where:** `Transport.received`, the `case .linkRequest:` relay branch (CREATE)
and the `destinationType == .link` + `linkTable` hit branch (shadow + EXTEND).

`Packet.hashablePart` excludes `headerType`, `transportType`, `transportId` and
`hops`. So an attacker takes our own HEADER_1 LINKREQUEST off the wire and
re-emits it to us as HEADER_2 naming us as relay — and `Link.linkID` yields **our
own link's `linkID`, identically**. Every precondition on the relay branch holds
for that reflected copy: we are relaying, `transportId` is our hash, the
destination is remote, and we have a learned path to it (we must — that is why we
opened the link). `seenPacketHashes` does not stop the first one: we never insert
our OWN outbound packet hashes.

Result: `linkTable[ourLinkID]` exists, and the `destinationType == .link` block
runs FIRST and returns unconditionally — so `.delegate(.linkPacket(...))` is never
emitted for that `linkID` again. **Probe-proven end to end:** after the
reflection, the genuine LRPROOF arriving from the peer was NOT delivered locally;
it was transmitted to the attacker's interface.

Consequences, in order of severity: the attacker receives the legitimate peer's
link traffic; our own element never sees its proof and dies at
`.establishmentFailed(.timedOut)`, which `LXMFNode` treats as PATH-shaped and so
DISCARDS a perfectly good path; and run against an already-`.active` link the same
reflection blackholes all inbound link traffic until the inactivity watchdog
closes it.

Root defect: `linkTable` is keyed by `linkID` alone, `Transport` never checks
whether that `linkID` belongs to a LOCAL link, and the relay lookup is ordered
ahead of local delivery.

**Two more `linkTable` facts from the same probes.** Entries are created without
bound (probe: 20 unauthenticated relayed LINKREQUESTs → 20 entries; there is no
cap on `linkTable`), and `refreshedAt = date.now` is stamped on ANY matching link
packet with no decryption anywhere, so an entry survives `maintenanceTick`'s
`linkTableExpiry` GC forever on unauthenticated junk (probe: refreshed at
t=100000, survives the tick). There is no other DESTROY path — only that expiry
and `setTransportIdentity(nil)`.

**Gated on relay mode.** All of it requires `transportIdentity != nil`, set only
via `TCPEndpoint.enableRelay` / `BLEEndpoint.enableRelay`, neither of which has an
in-repo caller. Latent for relay deployments rather than live in anything that
ships today — but enabling relay is a one-line integrator decision.

### F14 — the responder cap evicts before it validates

**Where:** `LinkPlane.acceptLinkRequest`.

The eviction effects are appended before the new element is minted, and the
request itself is never checked for viability first. Probe: at the cap, a
LINKREQUEST carrying an all-zeros X25519 key (a well-formed 64-byte payload that
passes the size guard and dies at `LinkSession.acceptRequest`'s empty-session-key
guard) evicted a legitimate `.active` responder link and then self-destructed,
leaving the freed slot unused.

The cheapest unviable request is even simpler — a wrong-size payload, caught by
the `64 || 67` guard. Either way a legitimate link dies for a request that was
never going to become one.

Not a leak and not unbounded: the count settles back below the cap, so the
availability harm is one legitimate link per refill rather than a flush. Fix by
validating enough of the request to know it can become an element before
committing an eviction.

### F15 — an unauthenticated RESOURCE_PRF destroys every sender transfer on a link ⚠️

**Where:** `LinkSession.received`'s `(_, .active, .proof, .resourceProof)` /
`(_, .active, .data, .resourceProof)` raw-forwarding group, and
`ResourceTransfer.received`'s `(.sender, .proof, .resourceProof)` branch.

Resource proofs are sent UNENCRYPTED (`linkPacket(.proof, .resourceProof, proof)`,
no `Link.encrypt`), and `Resource.validateProof` is a plaintext equality check:
64 bytes whose trailing 32 must equal `expectedProof`. The branch has no status
guard and no check that the proof names THIS transfer, and a non-matching value
takes the `else` — `status = .failed`, `.delegate(.failed)`. `LinkSession` fans
the raw bytes out to EVERY element of `state.transfers`.

Probe: one 64-byte junk `.proof` packet at the cleartext `linkID` produced a
`resourceFailed` delegate and removed the transfer. `LinkSession`'s
`.transfer(… .delegate(.failed))` handler also cancels and fails a pending
request, and nils `segmentedSend` — aborting a whole multi-segment send at
segment 1 of N.

**The non-adversarial trigger is the stronger argument.** With two concurrent
sender transfers on one link, the genuine proof for A destroys B, because the
branch never checks that the proof belongs to this transfer — even though
`Resource.proofData` puts the resource hash in the proof's first 32 bytes and
`validateProof` ignores them.

### F16 — the inactivity re-arm fires for ANY link-addressed packet

**Where:** `LinkSession.received`, the hoisted block below `dispatch`.

Every `guard … else { return .none }` inside `dispatch` returns from `dispatch`,
not from the reducer. Control always reaches `guard state.status == .active`,
`state.lastInbound = now` and `inactivityTimer(state.staleTime)`. So while a link
is `.active`, ANY packet bearing the cleartext `linkID` extends its life: a failed
decrypt, an unhandled context, an 8-byte junk payload. Probe: eight rounds of
`0.9 × staleTime` fed nothing but undecryptable `.cacheRequest` packets left the
link `.active`; a full `staleTime` of silence closed it.

**This corrects F1 and F10.** F1 attributes life extension to "the keepalive
branches". Those branches are redundant with this re-arm **for the EXTENSION
property only** — deleting them would not change how long an unauthenticated
party can hold a link open, because the re-arm runs regardless. They are NOT
otherwise redundant, and an earlier draft of this entry said "removing them would
change nothing" without that scope, which is false:
`(.responder, .active, .data, .keepalive)` also emits the `0xFE` reply via
`linkPacket(state.linkID, .keepalive, …)` → `.delegate(.transmit)`, which is
RNS's liveness answer and is pinned by `responderRepliesToKeepaliveWith0xFE`.
Removing it breaks interop AND reddens the suite. The sweep's table row carried
the scope; this entry dropped it.

F10 was described as bounded by the watchdog; it is not, because the party
spending the grant refreshes the watchdog itself.

The hoisting is deliberate and was the fix for a real bug — per-branch re-arming
is how a 60s mid-transfer teardown got in, and the comment above it says so. So
this is a design tension, not an oversight: the re-arm must stay hoisted AND must
not be free. Any fix has to keep working for RNS's plaintext keepalives, which is
the constraint that makes the obvious answer ("re-arm only on
`sawAuthenticatedData`") wrong.

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

**Re-verified against the vendored TCA source on the revision pass — both halves
hold.** Also checked that ReTiCaMsgr resolves the SAME TCA version (identical
offsets in its own checkout), so this rule travels to the sibling repo unchanged
— which matters for F5's out-of-repo bullet.

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

### The mechanism behind both of those — stated precisely, 2026-08-13

Found while writing Task 7, re-derived from the vendored source under
`.build/checkouts/swift-composable-architecture` before being recorded here. An
earlier statement of it was half-right and would have misled, so this is the
version to trust. Three facts, in the order they execute:

1. **`TestReducer._reduce` updates `self.state` ONLY for `.send`-origin actions.**
   Its `switch action.origin` has exactly two arms: `.send` runs the reducer and
   then assigns `self.state = state`; `.receive` runs the reducer and appends to
   `receivedActions` **without touching `self.state`**. `TestStore.state` returns
   `self.reducer.state`. So `store.state` is blind to any effect-emitted action
   that has not been drained — that is the mechanism behind the "invisible until
   drained" rule above, not a separate quirk.

2. **`TestStore.send` checks `!self.reducer.receivedActions.isEmpty`
   UNCONDITIONALLY, BEFORE the exhaustivity switch** — "unconditionally" meaning
   for every exhaustivity setting, but only AFTER the `isDismissed` early return
   above it, which reports "Can't send action to dismissed test store" and returns
   without ever reaching the queue check. It routes the resulting
   "Must handle N received actions before sending an action" message through
   `reportIssueHelper` — which reads `self.exhaustivity` **at call time**:
   - `.on` → `reportIssue` → a real failure;
   - `.off(showSkippedAssertions: false)` (**the default**) → the message is
     **DROPPED ENTIRELY**;
   - `.off(showSkippedAssertions: true)` → wrapped in `withExpectedIssue`, so it
     is emitted as an EXPECTED, visible, non-failing issue.

3. **ONLY THEN does the switch clear the queue.** `.on` breaks;
   `.off(showSkippedAssertions: false)` does a bare `receivedActions = []`;
   `.off(showSkippedAssertions: true)` calls `skipReceivedActions(strict: false)`,
   which also ADVANCES `reducer.state` to the last received action's state before
   clearing.

**So the exhaustivity-gated report is what SILENCES a stray action; the clearing
is what makes it UNRECOVERABLE afterwards.** They are two separate steps and
conflating them is what produced the earlier half-right statement.

**Corollary — `receive(predicate)` under `.off` is queue-clearing too.** Its
non-exhaustive path does `while let first = receivedActions.first,
!predicate(first.action) { removeFirst(); reducer.state = first.state }` and
reports the discarded actions through the same `reportIssueHelper`. So every
non-matching action ahead of the match is silently dropped under the default
`.off`. `captureTransmit`-style helpers therefore consume the queue, and a test
that relies on a later assertion "catching" an earlier stray will not.

**The trap has a floor, and knowing where it is stops over-correction.**
`receive`'s two "no matching action" guards — the empty-queue one and the
`!contains(where: predicate)` one — and the async timeout path all call **raw
`reportIssue`, not `reportIssueHelper`**, so they do not consult exhaustivity at
all. A MISSING action therefore fails hard even under `.off`. Non-exhaustivity
silences EXTRA actions; it never silences ABSENT ones. So a `receive` that
returns without complaint really did see its action, at any setting — which is
why the characterization tests in this repo can rely on `receive` under `.off`
for positive assertions and only need `.on` for negative ones ("nothing else
happened").

**Fix pattern: keep `.on` ACROSS the boundary where silence must be proven** —
flip before the send whose effects you are making a claim about, and flip back
only after the observation. A `.on` flip placed after the queue has already been
cleared proves nothing.

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

**A test whose NAME claims two properties while its assertions cover only one —
added 2026-08-13.** This shape produced two of the three worst holes in the
unauthenticated-input slice. It is more dangerous than an obviously weak test,
because the name is what a reviewer reads and the name is accurate about INTENT.
The unasserted half is reliably the one an attacker or a plausible refactor
reaches, because the asserted half is usually the one that was easy to observe.

Two instances, both caught late:

- `replayedLinkRequestMintsExactlyOneElementAndOneProof` asserted the element
  count and NOT the proof. A dedupe that recognised the duplicate but
  re-dispatched `.acceptRequest` to the existing element keeps `links.count` at 1
  while still paying the keypair generation, DH, HKDF and Ed25519 signature the
  guard exists to avoid, and putting a second LRPROOF on the wire per replay —
  i.e. it restores the crypto amplification the slice exists to close. That
  refactor passed all 821 tests. The proof half was vacuous because the emission
  is invisible under `.off` (see §5), so asserting it required a deliberate `.on`
  window; that is why it was skipped.
- The plaintext-keepalive interop guard's "part 2" was described in its own
  doc comment and never written. Part 1 proved the keepalive REFRESHED the
  timer; part 2 was supposed to prove the timer was still ARMED. A change that
  cancelled the inactivity timer on a keepalive without re-arming it sails
  through part 1 — no deadline is queued — while leaving the link immortal, the
  opposite failure from the one the test is named for.

**The check:** for every `and` in a test name, point at the assertion that fails
if only that half breaks. If the answer is "the other assertion would probably
catch it", it will not. Both halves above were reachable by a one-line change.

**Verify the HANDOFF, not just the code — added by the revision pass.** This
document was written by the same process that §6 says produced ten wrong property
claims in one session, and it inherited the same failure mode. A verification
pass that re-derived every claim from the code found: one mechanism completely
inverted (F2) in exactly the item §7 said to implement FIRST, a §2 that
contradicted its own §3 while being the section devoted to correcting
overclaiming, and three defects missing outright — one of them (F6) cheaper to
trigger than anything that WAS listed. The pattern from §6 held precisely: the
nodes were right and an arrow was wrong.

Two things made the pass work, and both are cheap to repeat. **Ask for verdicts,
not review** — "TRUE / FALSE / MISLEADING, cite symbols, report what CONTRADICTS
this" rather than "check this document." **And check the reference implementation
for anything the doc defers** — §7 step 1 said "check what RNS does before
choosing," and doing so inverted the step's premise: RNS behaves as we do, so the
proposed fix had no reference cover, and RNS's actual defense turned out to be
something we cannot currently express. A deferred question is where a plan is
most likely to be built on an assumption nobody has priced.

---

## 7. Next slice

> **DONE 2026-08-13 — `4ef3a21..034a4c9`.** All four numbered steps below were
> taken. Step 1 was split: the inactivity-refresh half was NOT gated (it would
> break RNS interop and bounds nothing — see F1), and the re-homing half was
> gated on authentication, decided inside `LinkSession` with the arrival
> interface threaded through `Action.received`, plus a one-shot grant from a local
> interface disconnect. Step 2 chose dedupe-by-`linkID` AND a cap. Step 3 landed
> first, as suggested. Step 4 landed as the cap rather than as ingress control.
>
> **What to do next is now the §3 priority list, not this section.** The top three
> are F13, F12 and F15 — all found by the sweep, none of them in this repo's plan
> until it was written. In particular: F12 is this section's step 3 applied to the
> INITIATOR branch, which nobody noticed was a mirror until the sweep enumerated
> both. If you take one lesson from §7 into the next plan, take that one — the
> plan named the branch it had found, not the property it wanted.
>
> The original text follows unchanged, because §6 says to keep the record of what
> was believed at planning time.

**Take F1 + F2 + F6 together as "unauthenticated input cannot pin, steal, or kill
a link element."** They share one root cause — link elements are created, kept
alive, re-homed, and destroyed on unauthenticated input — and largely one fix
surface.

**Revised scope sketch.** The original listed the fix surface as
"`LinkPlane.acceptLinkRequest` + `LinkSession`'s keepalive branches." That
**omits `LinkPlane`'s re-home branch, where F1's worst consequence lives**, and
it predates F6. Corrected:

1. **Gate inactivity-timer refresh AND re-homing on an authenticated packet.**
   Note these are in different files — the refresh is in `LinkSession`'s
   keepalive branches, the re-home is in `LinkPlane.routeLinkPacket`. A fix to
   only the first leaves link theft open.

   **The RNS question is already answered — see F1.** Reference updates
   `last_inbound` before decryption exactly as we do, so this step is a
   deliberate DIVERGENCE with no reference cover. RNS's own defense is
   interface-pinning, which we cannot express today because
   `LinkSession.Action.received` carries no interface. Threading it through, or
   deciding in `LinkPlane` where the arrival interface is already in hand, is the
   reference-aligned alternative — and it also fixes re-homing, which makes it
   the more attractive of the two.
2. **Decide the duplicate-LINKREQUEST policy:** dedupe by `linkID`, cap
   `LinkPlane.State.links`, or rate-limit per interface. **Dedupe still wins, but
   for a different reason than originally stated** — not the (incorrect)
   shadowing story, but because duplicate elements arise NON-adversarially on any
   multipath mesh (HEADER_1 and relayed HEADER_2 copies share a `linkID`; see
   F2). Scope that deliberately: it is a broader behaviour change than "drop
   replays."
3. **Fix F6** — do not reap a responder element on an unauthenticated RTT
   decrypt failure. Cheapest defect here and it needs no replay, so if the slice
   has to be cut short, this is the part to keep.
4. Consider whether LINKREQUEST needs ingress control analogous to the announce
   ingress control already in `Transport`.

**On sequencing:** the original said "do the correctness half (shadowing) before
or with the resource half." That instruction survives its rationale — the
shadowing story as written is wrong (F2), so the correctness work to front-load
is **F6 plus the non-adversarial duplicate case**, not the replay-consumes-RTT
scenario. Both still bite real users on a busy shared interface independent of
any attacker, so the priority conclusion is unchanged even though the reasoning
that produced it was not.

Working notes and per-task history for the four slices are under
`.superpowers/sdd/` (git-ignored) — `2026-08-09-bound-link-establishment-saga`,
`2026-08-10-establishment-timeout-reaches-delivery`,
`2026-08-10-stale-path-failures-request-a-path`,
`2026-08-10-link-elements-are-always-reaped`. Plans are in
`docs/superpowers/plans/`.
