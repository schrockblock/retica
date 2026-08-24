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
>
> **Updated again 2026-08-13** by the final whole-branch review over
> `4ef3a21..86086b0` and its single fix wave (`381d731`). Suite is now 826.
> **F14 is CLOSED**, having first been escalated to Critical: it was a REGRESSION
> the slice introduced, and both its severity sentence and its prescribed fix were
> false — read its entry, which now records both corrections. **F10 gained a
> second half** (the grant reaches initiator links too). Nothing else changed
> status.
>
> **Updated a third time 2026-08-13** by the "a destructive transition requires
> authenticated, owned input" slice (`892652a..a4b5e21`). Suite is now 835, same
> one known issue. **F12 and F15 are CLOSED** — but read F15's entry before
> reading "closed" as "authenticated": a resource proof CANNOT be authenticated at
> all, so what closed it is ownership routing plus non-destructiveness. **F17 and
> F18 are new**, from the sweep in
> `docs/superpowers/2026-08-13-destructive-transition-sweep.md`, which asked a
> different question from the previous one ("does this destroy something without
> checking that the input owns it?" rather than "can an attacker reach this?") and
> found the half of F15 the first framing could not see.

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

  **This was once BLE-only, and that was the defect, not the design.**
  `TCPEndpoint.openLink` lacked the gate until `c4d00b2`; both endpoints gate now.
  See F8, including why the miss was worse than the cost argument suggested.

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
branch-by-branch table those came out of. **F17 and F18 were added later the same
day** by the destructive-transition slice and its sweep,
`docs/superpowers/2026-08-13-destructive-transition-sweep.md`. **F19 was added on
2026-08-14** by that slice's final whole-branch review — see §3c; it is a
PRE-EXISTING defect the review composed out of facts the sweep already recorded
separately, not one the slice introduced.

**F1, F2 and F6 are CLOSED** by `4ef3a21..034a4c9`. **F12 and F15 are CLOSED** by
`892652a..a4b5e21`. See their entries — F15's in particular, which is closed on
ownership rather than on authentication because authentication is not available
to it. **F8 is CLOSED** by `c4d00b2` (2026-08-21) — read its entry before trusting
the severity this list gave it, which was too low for the wrong reason.

**F20 was added AND largely closed on 2026-08-21** — filed from device testing
(a cold launch rendering a peer list it could not message), then fixed hours later
by `aa19115` + `5d2b33a` + `cbe1845`, which persist and replay
`Transport.State.learned`. Its entry is kept because the reference-parity analysis
in it is what the fix was built from, and because one question it raised is still
open: the fix restores identity and path TOGETHER, where the analysis argued for
restoring identities and re-learning paths. Read the entry's header before
believing any sentence in its body.

Current priority:

1. **F4, and the rest of F5** — the remaining items with an open fix decision
   (F7 closed 2026-08-23; **F16 accepted won't-fix**; F9/F10 accepted residuals;
   **F5.2 CLOSED `e22cb4d..654d230` 2026-08-23** — the stale idle-timer teardown).
   Scoped 2026-08-23: **F3 is dead code** (`PNNode` has no production consumer —
   skip until wired up). **F4** is a real crash-on-misuse (the only
   `preconditionFailure` in `Sources`, two unguarded public `LinkPlane` paths) but
   reachable only by a direct-composition caller, not remotely — a robustness
   cleanup if wanted. **F5's remaining sub-items:** F5.1 `sendFailed` is
   unconsumable (a delegate DESIGN change, not small), F5.3 `LXMFNode.sendViaPropagation`
   silent drop (minor observability), F5.4 `.handshakeRejected` label test-coverage,
   F5.5 the app-side double-saga (ReTiCaMsgr — real UX bug, app work). None is a
   clean high-value link/router fix; scope before assuming actionable.
   - ⏸️ **F16** — ACCEPTED (won't fix): the inactivity re-arm fires for any
     link-addressed packet, but the plaintext keepalive makes that vector
     irreducible and F11's `lastData`-based eviction already reclaims the slot; a
     fix would be cosmetic and reintroduce per-branch re-arm fragility. See its
     entry for the full analysis.
   - **F9**/**F10** — the two accepted residuals of the re-home fix (deliberate,
     pinned by tests, listed so a future fix confronts them rather than deleting
     them).
2. ~~**F8**~~ (CLOSED, `c4d00b2`), ~~**F13**~~ (CLOSED, `3023592..ac7a2f3`; latent
   until relay mode is enabled — see its entry), ~~**F11**~~ (CLOSED,
   `07d12bd..6d05524`; eviction now keys on genuine transfer progress and
   advertisements no longer refresh the eviction clock — see its entry),
   ~~**F19**~~ (CLOSED, `3a7a1d9`; replayed RESOURCE_REQ deduped on the encrypted
   packet hash — see §3c), ~~**F7**~~ (CLOSED, `ce14cfa`; linkResourceInFlight now
   reaped on directLink teardown via a shared clearDirectLink helper), then
   F3/F4/F5.
3. **F17**, then **F18** — both low, both from the destructive-transition sweep.
   F17 is an actual behaviour defect (two of our own transfers destroy each
   other) with no reference-aligned fix — RNS routes resource segments the same
   way, carrying a standing TODO — so taking it means choosing a deliberate
   divergence. F18 is defence-in-depth whose impact today is nil.

   **Two rationales that stood here are RETRACTED. Do not restore either.**
   (a) *"F17's price to an attacker is set by `Resource.mapHashLength`"* — false
   since `8aa02ee`: that price covers the accidental and sprayed routes, but for
   a session-key-holding peer route 3 is free.
   (b) *"F18 causes F17's route 3 and row 29's weakness, so rank it first"* — a
   flip made on a review instruction and then retracted, because **no validation
   at `unpack` can close route 3 at all** (`m` IS the peer's own resource's map
   hashes by protocol design, so a hostile hashmap is indistinguishable from a
   legitimate one) and row 29's `q` gap is PROVENANCE, not length. The
   load-bearing sentence — "one length check now closes four consumers" — closes
   exactly ONE (`h`). Full reasoning in §7 of
   `docs/superpowers/2026-08-13-destructive-transition-sweep.md`.

   Both stay below F3/F4/F5: all four F18 consumers require the session key and
   are bounded to that peer's own link, so widening from one consumer to four
   does not move the trust boundary.

**F12, F14 and F15 were ranked here and are now CLOSED** (`bd5dd7f`, `381d731`,
`d0570ef` + `0101a74`).

F13, F16 and F17 share the root cause F1/F2/F6/F12/F15 shared — **input drives
lifecycle without being checked against the thing it acts on** — but NOT one fix
surface: they are in different files and different element populations. Do not
plan them as one slice on the strength of the shared cause. F17 in particular is
NOT an authentication problem at all, which is the distinction the second sweep
exists to make: it is an OWNERSHIP problem between two of our own objects.

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
eviction-immune and, at the cap, lock every other peer out. The bound holds on
`links.count`; the availability guarantee does not.

**The cap also, briefly, let unauthenticated input DESTROY established links —
that was F14, and it is CLOSED in `381d731`.** It is worth stating in this entry
rather than only in F14's, because F1's closure is the reason the cap exists: as
first written, the cap was enforced in `acceptLinkRequest` and paid for by
evicting an `.active` responder, so a junk LINKREQUEST burst flushed the whole
responder population. The cap is now two budgets — a half-open one that inbound
requests spend and that evicts nothing, and the `maxResponderLinks` one enforced
at promotion, where the peer has demonstrably completed a handshake.

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
- ✅ **F5.2 CLOSED (`e22cb4d..654d230`, 2026-08-23):** `idleTimer` was never cancelled on close and
  `.linkEstablished` re-armed it only if a queue drained, so a link re-established for a still-pending
  delivery (or PN sync) kept the prior link's timer alive; it fired on its original deadline and
  `.idleDeadline`'s `.active` guard matched the NEW link, closing it (PN-sync branch same shape).
  Fixed by always arming `idleTimer(dest, linkID)` at `.linkEstablished` (its `cancelInFlight` cancels
  the stale timer and provisions the new link) and linkID-stamping `.idleDeadline` so it closes only
  the link it was armed for. Whole-branch reviewed; two fix rounds repaired ripple-broken/weakened
  tests (the always-arm timer rippled into LXMFServiceNode tests that flip `.on`, and four ripple-fixes
  had to be injection-verified to keep their stray-action guard). Spec/plan:
  `docs/superpowers/specs/2026-08-23-f5-2-router-idle-timer-stale-teardown-design.md`,
  `docs/superpowers/plans/2026-08-23-f5-2-router-idle-timer-stale-teardown.md`. **Original bullet:**
  `idleTimer` is never cancelled on close (`CancelID.idle` appears exactly once
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

### F7 — `linkResourceInFlight` leaks on idle teardown — ✅ CLOSED (`ce14cfa`, 2026-08-23)

**Closed by** a shared `clearDirectLink(&state, dest)` helper that reaps `linkResourceInFlight[linkID]`
(when the entry is `.active`) BEFORE clearing `directLinks[dest]`. All three teardown paths — `closed()`,
`.idleDeadline`, and `giveUp` — now route through it, so the leak is fixed and the reap-on-teardown
invariant is enforced in one place a future teardown path cannot bypass. `.idleDeadline` was the only
leaking site (exhaustive lifecycle grep); `giveUp` is unreachable with an `.active` link. Whole-branch
reviewed, mutation-verified in a worktree. No wire/reference concern (internal router state). Spec/plan:
`docs/superpowers/specs/2026-08-23-f7-linkresourceinflight-leak-design.md`,
`docs/superpowers/plans/2026-08-23-f7-linkresourceinflight-leak.md`. The original analysis follows.

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

### F8 — `TCPEndpoint.openLink` has no `reachableLearned` gate — ✅ CLOSED

**CLOSED by `c4d00b2`** (2026-08-21), found again from a device report: "tapping a
detected-announce row always fails after ~15 seconds". The gate now mirrors BLE's
and the open fails fast as `.pathStale`. Two things worth keeping from the fix.

**The severity below UNDERSTATES it, and the understatement is the lesson.** This
entry priced the defect as "costs a full establishment timeout and one attempt
from the budget" — a cost argument. The real damage is that
`.establishmentTimedOut` is classified PATH-shaped and routes to
`pathLostAndClosed`, so **a dead SOCKET was laundered into a dead ROUTE**: the
router discarded a perfectly good path and requested a new one because the
interface underneath it was gone. On device that made a connection failure
indistinguishable from a routing failure, which is what sent the investigation
after the wrong subsystem.

**Two fixtures had to be corrected to land it, and they are the more transferable
finding.** `PNNodeTests` and `StampWorkBoundsTests` seeded `transport.learned`
while leaving `transport.interfaces` empty — a state the runtime cannot reach,
since a path is only ever learned over an interface that existed. They passed
because nothing read both tables together; the moment something did, they broke.
That is the "seeded state proves nothing about reachability" trap, and a guard
that reads TWO tables is exactly where it surfaces.

**Original entry follows.**

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

### F20 — nothing persists the peer IDENTITY cache, so a restart can see a peer it cannot message — ✅ LARGELY CLOSED

**Added 2026-08-21 from device testing. CLOSED the same day**, by work that landed
while this entry was still being written: ReTiCA gained
`Transport.Action.rehydrateLearnedDestinations` and `Transport.pathExpiry` became
public (`aa19115`), and ReTiCaMsgr added a `LearnedDestinationRow` GRDB table that
mirrors `Transport.State.learned`, writes on a debounced 30 s timer plus an
immediate flush on background/terminate, prunes at launch, and dispatches the
rehydrate action (`5d2b33a`, `cbe1845`).

**So the headline claim below — "ReTiCA persists neither" — is now FALSE, and the
diagnosis in the middle of this entry is what the fix was built from.** Read the
rest as the analysis that produced the fix, not as current state.

**What the fix does NOT cover, stated so this is not read as fully closed.** The
restored table carries `LearnedDestination`, which holds BOTH the identity and the
path — including an `interfaceID` minted by a previous process. F8's gate requires
that id to be present in `transport.interfaces`, so a rehydrated entry is
`reachable=NO` until an interface with that id registers. The parity target argued
below was *restore identities, re-learn paths*; what shipped restores both
together. Whether that is right is a live question, not a settled one: it is
cheaper and it works when the interface id is stable (`InterfaceID("tcp")` is a
constant for the TCP endpoint), but it puts entries in the table that `openLink`
will refuse until the socket is up.

The diagnostics screen added the same day renders exactly this — its Paths layer
cross-checks `learned` against `interfaces` — so the condition is now visible
rather than inferred from a greyed-out Send button, which is what this entry asked
for. See `docs/superpowers/specs/2026-08-21-diagnostics-page-design.md`.

**Original entry follows, unchanged apart from this header.**

**What reference actually does. Every citation below was opened and read, because
two earlier drafts of this paragraph got it wrong in opposite directions.**
Reference keeps identities and paths in separate stores with DIFFERENT rules:

- **Identity cache — persisted AND restored by every node.**
  `Reticulum.__init__` calls `RNS.Identity.load_known_destinations()`
  unconditionally (`Reticulum.py:344`), before `Transport.start`. The save side is
  gated only on `is_connected_to_shared_instance` (`Identity.py:349`, and again at
  `:615`) — never on transport. Entries map destination hash →
  `[timestamp, packet_hash, public_key, app_data, …]`.
- **Path table — saved by every node, but LOADED only by transport nodes.**
  `save_path_table` is gated only on shared-instance (`Transport.py:3336`) and runs
  from `persist_data` in `exit_handler` (`:3526`), but the LOAD sits behind
  `if RNS.Reticulum.transport_enabled()` (`:306`). So a leaf client writes
  `destination_table` on exit and **never reads it back**.

**Net effect for a leaf client like ReTiCaMsgr: identities survive a restart;
paths do not, and are re-requested on demand.** That is the parity target.

**Two drafts of this paragraph were wrong, and the way they were wrong is worth
keeping.** The first said "reference persists this and we do not", with no gate at
all — wider than the evidence. The second over-corrected to "both the save and the
load are transport-gated" and cited `Transport.py:243` for the save; `:243` is the
**packet hashlist**, and the save is not transport-gated at all. Only opening the
line disproved it. An implementer who trusted either draft would have built the
wrong store.

ReTiCA persists neither: `Transport.State.learned` has no rehydrate action at all
(a grep for `rehydrate` in `Transport.swift` returns nothing), and it fuses both
concerns into one struct, so there is no identity store to persist independently.

**Why it bites now.** `LXMFNode.learnedPeers` *is* persistable and ReTiCaMsgr now
rehydrates it, but `LearnedPeer` carries only `displayName`, `stampCost`,
`supportsCompression` and `learnedAt` — **no identity and no path**. So after a
cold launch the app can render a full list of known peers while holding nothing it
can act on. Both consumers need what is missing:

- Opportunistic send encrypts to the recipient's identity
  (`LXMFNode`'s `state.endpoint.learned[destinationHash]?.identity`).
- `openLink` resolves the same table, and now also requires the interface
  (see F8).

So the honest statement is that the announce list survives a restart and the
ability to USE it does not. **Do not "fix" this by seeding the app's
`reachablePeers` so the Send button lights up** — the button is currently telling
the truth, and making it lie would convert a visible block into a silent failure.

**The shape the fix probably takes**, from the split above: restore IDENTITIES
only and let path discovery re-run. That also resolves a question the draft left
open — restoring a path is not merely unnecessary but close to meaningless here,
because F8's gate now requires the entry's `interfaceID` to exist in
`transport.interfaces`, and an interface ID minted in a previous process will not.
`LXMFRouter.establish` already parks in `.awaitingPath` and requests a path when
one is unknown, so re-learning is the supported route, not a workaround.

**Still open, and NOT settled by the above:** whether a restored identity should be
trusted without a fresh signed announce (reference caches the public key and the
announce `packet_hash` together, which suggests it keeps the provenance); how
expiry should work, given `learnedPeers` already sweeps at 45 days on a different
clock (see `LearnedPeer.learnedAt`, which is deliberately NOT the path's
`learnedAt`); and whether splitting `LearnedDestination` into an identity half and
a path half is worth the churn to the call sites that read it as one.

---

## 3a. Added 2026-08-13 — the unauthenticated-input slice and its sweep

**F9, F10 and F11 are ACCEPTED RESIDUALS of the slice**, not defects it missed:
each was found during execution, priced, and deliberately left. **F12–F16 are
defects the sweep found.** All eight are pinned by something executable or by a
probe recorded in
`docs/superpowers/2026-08-13-unauthenticated-link-element-sweep.md`.

**Status as of `381d731`: F14 is CLOSED.** The final whole-branch review escalated
it to Critical — its severity sentence and its prescribed fix were both wrong, and
the defect was a REGRESSION this slice introduced rather than a pre-existing one —
and it was fixed in the same pass. F10 gained a second half (initiator links) in
the same review; the behaviour was left as it stands, with the reasoning recorded
both here and at `LinkPlane.interfaceDisconnected`.

**Status as of `a4b5e21`: F12 and F15 are also CLOSED**, by the
destructive-transition slice (`892652a..a4b5e21`). **F9, F11, F13 and F16 remain
OPEN**, and **F17/F18 are added below** by that slice's sweep.

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

**Third-order consequence, added 2026-08-13 by the destructive-transition sweep,
and it comes with a reference guard we are missing.** Reference `RNS/Link.py`'s
`RESOURCE_REQ` branch keeps a per-resource `req_hashlist` of `packet_hash` values
and skips a request it has already served, commented *"We need to check that this
request has not been received before in order to avoid sequencing errors."*
`ResourceTransfer.State` has no such set. So a captured `RESOURCE_REQ` replayed by
a third party — no key needed, it is just bytes — makes us re-transmit the
requested parts and re-arm the sender watchdog. Amplification and life extension,
not destruction, which is why the sweep left it here rather than minting a number
for it. It does NOT reach the sequencing-error `.failed` exit: that exit keys on
`partIndex % Resource.hashmapMaxLen`, a function of the request's contents, so it
is identical on every replay. **This is the first F9 instance where reference
carries a defence we simply do not have** — the others are places where reference
is equally exposed.

**And the extension it buys is UNBOUNDED, which the paragraph above does not say
— that is F19, added 2026-08-14.** "Re-arm the sender watchdog" understates it:
the re-arm uses `cancelInFlight: true`, so it RESTARTS the window, and
`proofRetriesLeft` is decremented only when the deadline actually fires. Replays
faster than the window therefore mean the transfer never SELF-terminates for as
long as they keep arriving, which pins its link against eviction for that whole
time. It is unbounded while replayed, not unconditionally permanent — the peer's
proof or `RESOURCE_RCL`, the host's `.cancel`, and simply stopping the replays each
still end it. See §3c for the composition, the bound and the ranking.

Closing F9 needs per-packet replay rejection on the link, which does not exist
anywhere in the link path today, and which has to be designed around the
keepalive exemption that put the Transport dispatch above the dedup in the first
place. The `req_hashlist` above is a cheap, reference-blessed partial that does
not require solving the general problem.

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

**Extension, added 2026-08-13 by the final whole-branch review: this is not
confined to inbound links.** `LinkPlane.interfaceDisconnected` does not filter on
role, so the grant is issued to INITIATOR links too — links WE opened. After any
local disconnect, one unauthenticated packet from a foreign interface re-homes
one of our own outbound links, which sits awkwardly beside `maxResponderLinks`'s
own comment ("Initiator links are ours"). On an initiator link the relevant
plaintext is `0xFE`, the responder's keepalive reply — `0xFF` is dropped as our
own loopback at the top of `LinkSession.received` before the re-home block — but
per F16 any link-addressed packet at all will do. The original write-up and its
characterization test described only the responder/BLE-peer case.

**Left as-is deliberately, and here is why.** Restricting the grant to responders
would not remove the exposure, it would trade it for a worse failure. Our
initiator links go stale on exactly the same event — a BLE peer reconnects under
a new token, so the `InterfaceID` bound at creation is dead — and an initiator
link's peer is the RESPONDER, which never initiates keepalives; it only replies
to ours, which would be going to the dead interface. If that peer is mid-transfer
to us, the segments it sends never set `sawAuthenticatedData` (see F9's mechanism
and `LinkPlane`'s `.rehomed` comment). Without the grant those links recover only
by timing out, aborting the transfer with them. The reasoning is recorded at
`LinkPlane.interfaceDisconnected`; the behaviour is pinned by the initiator phase
of `theReHomeGrantIsSpentByWhicheverInterfaceSpeaksFirst`.

**Correction to how this was first written, including in the production comment:**
it was described as bounded "to the window before the inactivity watchdog reaps
the element." That bound does not hold against an attacker — see F16, the same
party refreshes the watchdog with junk. Bounded to one re-home per disconnect;
not otherwise bounded. Nothing clears `rehomePermitted` except the re-home that
spends it, so the grant does not expire either.

### F11 — advertise-and-stall pins a link against eviction — ✅ CLOSED (`07d12bd..6d05524`, 2026-08-23)

**Closed by** fixing the eviction POLICY (not by the per-link `transfers` cap this entry originally
proposed — a cap would not have helped, since one stalled transfer conferred immunity regardless of
count). Two changes: (1) `LinkPlane`'s `evictable` filter now grants immunity only to a link with a
genuinely-progressing transfer — a sender-role transfer, or a receiver that has received a part
(`transfers.allSatisfy { $0.role == .receiver && !$0.receivedFirstPart }`) — so an advertised-but-
stalled transfer no longer pins the slot; (2) resource advertisements no longer advance the
`lastData` eviction clock (a new `sawGenuineData` flag gates `lastData`; advertisements still set
`sawAuthenticatedData`, so re-home is unchanged), so a re-advertising attacker sorts as the LRU
victim instead of looking freshly active. No per-link cap (reference has none; stalled transfers
self-reap via the receiver watchdog / link inactivity). Whole-branch reviewed. Accepted residual: an
attacker who continuously sends REAL parts holds a slot like any long transfer — only the zero-cost
pin is eliminated. Spec/plan: `docs/superpowers/specs/2026-08-23-f11-stalled-advertiser-link-pin-design.md`,
`docs/superpowers/plans/2026-08-23-f11-stalled-advertiser-link-pin.md`. The original analysis follows.

**Where:** `LinkSession.received`'s `(_, .active, .data, .resourceAdvertisement)`
branch, and `LinkPlane`'s `evictable` filter — which since F14's fix lives in the
`.link(… .delegate(.established))` handler, not in `acceptLinkRequest`.

The branch appends to `state.transfers` after decrypt, unpack and a SAME-hash
dedup only, so DISTINCT-hash advertisements append without bound (probe: 25
advertisements → 25 transfers). The eviction filter skips any link whose
`transfers` is non-empty — deliberately, because resource SEGMENT contexts
forward raw bytes to `ResourceTransfer` children that decrypt internally and so
never advance `lastData`, which would make a link receiving a large resource look
maximally idle exactly when evicting it is most wasteful.

Composed: a peer holding an active link advertises, never sends a segment, and
becomes eviction-immune; re-advertising outruns `ResourceTransfer`'s receiver
watchdog. Holding the cap that way locks everyone else out. **Since F14's fix the
shape of that lockout changed** — the newcomer is no longer refused at the
request, because `acceptLinkRequest` no longer consults the active cap. It is now
admitted, completes a whole handshake, and is then the element CLOSED on
promotion, because the advertiser is not an eviction candidate and the newcomer
is the only one left to refuse. The denial is the same; it costs the newcomer a
handshake first. This is the same class of unauthenticated-input resource
exhaustion the slice exists to close, and unlike the half-open variant — where
elements leave on their own establishment deadline — it does NOT self-clear
without the advertiser's cooperation. Pinned by
`distinctAdvertisementsGrowTransfersAndPinTheLinkAgainstEviction`.

The durable fix is a per-link bound on `transfers`. That is its own slice: it has
to decide what happens to the transfer it displaces.

**F19 is the same immunity at a lower price — read them together.** This entry's
mechanism needs the session key (a peer advertising resources it never sends);
F19's needs only one CAPTURED `RESOURCE_REQ` frame, because it pins a SENDER-role
transfer of ours instead of creating a receiver-role one. What bounds F19 instead
is that the attacker cannot make the transfer exist. The `evictable` filter's own
comment prices this entry's version only.

### F12 — one injected packet kills a legitimate OUTBOUND establishment — ✅ CLOSED

**CLOSED by `bd5dd7f`** (in `892652a..a4b5e21`): a `Link.validateProof` failure at
`(.initiator, .pending, .proof, .linkRequestProof)` now returns `.none` instead of
emitting `.establishmentFailed(.handshakeRejected)`, so neither half of the old
damage happens — the element is not reaped and the failure is not mislabelled
PEER-shaped. The already-armed establishment timer decides, and the failure
arrives as `.timedOut`, which is PATH-shaped and triggers a path request. Probed
for the sweep: a junk 99-byte proof leaves the element byte-identical and
`.pending`. This is Task 1's F6 fix applied to its mirror.

Unlike F15, this one IS authenticated: `Link.validateProof` is an Ed25519
validation against `destinationIdentity`, which is a stronger gate than a decrypt.
What was wrong was never the gate — it was what the branch did when the gate said
no.

The original text follows.

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

### F13 — a reflected LINKREQUEST makes us forward our own link's traffic to the attacker — ✅ CLOSED (`3023592..ac7a2f3`, 2026-08-22)

**Closed by** a `Transport.localLinkIDs` registry (synced from the link lifecycle via
`LinkSession`→`LinkPlane`→`TransportEndpoint`): Transport now drops a reflected LINKREQUEST whose
linkID it owns and delivers a local link's packets locally instead of relaying them. The same slice
added the reference-aligned validated/unvalidated `linkTable` split (hard unvalidated proof-deadline,
refresh-only-on-data) that closes the GC-evasion the probes below also found. Whole-branch reviewed;
no count cap (matches stock RNS — the validated-junk accumulation vector is accepted). **Latent
until relay mode is enabled** (`transportIdentity != nil`, no in-repo caller). Spec/plan:
`docs/superpowers/specs/2026-08-22-f13-relay-link-shadow-design.md`,
`docs/superpowers/plans/2026-08-22-f13-relay-link-shadow.md`. The original analysis follows.

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

### F14 — the responder cap evicts before it validates — **CLOSED in `381d731`**

**Where it was:** `LinkPlane.acceptLinkRequest`.

The eviction effects were appended before the new element was minted, and the
request itself was never checked for viability first. Probe: at the cap, a
LINKREQUEST carrying an all-zeros X25519 key (a well-formed 64-byte payload that
passes the size guard and dies at `LinkSession.acceptRequest`'s empty-session-key
guard) evicted a legitimate `.active` responder link and then self-destructed,
leaving the freed slot unused.

The cheapest unviable request is even simpler — a wrong-size payload, caught by
the `64 || 67` guard. Either way a legitimate link died for a request that was
never going to become one.

**Two corrections to how this was first written, both found by the final
whole-branch review and both worse than the original entry.**

*The severity sentence was FALSE.* It read: "Not a leak and not unbounded: the
count settles back below the cap, so the availability harm is one legitimate
link per refill rather than a flush." A probe through production wiring at a cap
of four showed **zero of four** established links surviving four junk requests.

The whole difference is the probe's choice of key. The original used an
ALL-ZEROS one, which CryptoKit rejects at `sharedSecretFromKeyAgreement`, so the
element self-destructs at `acceptRequest`'s empty-session-key guard and frees its
slot again — and that is what made the harm look self-limiting. `Link.sessionKey`
succeeds on a RANDOM 32-byte key, so that element does not self-destruct: it
reaches `.handshake`, `evictable` requires `.active`, and it therefore holds the
slot it just freed for a full establishment timeout. Each junk request killed one
authenticated link and took its place.

*The prescribed fix was INSUFFICIENT.* It read: "Fix by validating enough of the
request to know it can become an element before committing an eviction." A
random 64-byte payload passes every validation `LinkSession.acceptRequest`
performs, so anyone implementing that sentence as written would have believed
they had closed this and would have changed nothing about the flush.

**What was actually implemented (`381d731`).** Split the budgets, so that
unauthenticated input can only ever spend an unauthenticated one:

- `LinkPlane.State.maxIncompleteResponderLinks` bounds the responder population
  that has not reached `.active`. `acceptLinkRequest` checks it and REFUSES when
  it is full. It evicts nothing, ever.
- The `maxResponderLinks` eviction moved to PROMOTION — `LinkPlane`'s
  `.link(.element(_, .delegate(.established)))` handler, reachable only by a peer
  that decrypted the LRRTT and therefore holds the session key. It keeps every
  property the old eviction had (responder-only, `lastData` not `lastInbound`,
  skip in-flight transfers, close via `.close` so the element leaves through
  `.delegate(.closed)`, refuse when nothing is evictable), and additionally
  excludes the element being promoted by id.

Pinned by `junkLinkRequestBurstDoesNotEvictASingleEstablishedLink` (restoring the
pre-fix shape in `acceptLinkRequest` leaves zero of four survivors and reddens it)
and `promotingOneOfOurOwnLinksIsNeverRefusedByTheResponderCap`.

**Residual, accepted:** a flood still fills the half-open budget, so new inbound
establishment is refused for as long as those elements take to hit their
establishment deadline. Links that are already up are untouched — that is the
property the old shape did not have.

### F15 — an unauthenticated RESOURCE_PRF destroys every sender transfer on a link — ✅ CLOSED (owned and non-destructive, NOT authenticated)

**CLOSED by `d0570ef` + `0101a74`** (in `892652a..a4b5e21`), and read the
qualification, because it is not the usual one.

**A resource proof cannot be authenticated at all.** `Packet.pack` has a branch
dedicated to `RESOURCE_PRF` that leaves resource proofs unencrypted — that is
reference design, not an oversight here — so there is no decrypt to gate on and
no signature to check. Anyone who has observed the cleartext `linkID` can still
put a proof-shaped packet at this branch, and always will be able to. What
changed is what happens to it:

- **`d0570ef` — ownership routing.** `Resource.proofData` is
  `hash ‖ fullHash(data ‖ hash)`, so a proof's leading 32 bytes ARE the resource
  hash. `LinkSession` now delivers a proof to the ONE sender-role transfer whose
  `resourceHash` matches those bytes, instead of fanning it out to every transfer
  on the link. This mirrors reference `Link.receive`, which scopes proofs to
  `outgoing_resources`. A `payload.count >= 32` guard sits in front, because
  `prefix(32)` yields a SHORT `Data` rather than trapping.
- **`0101a74` — non-destructiveness.** `ResourceTransfer`'s
  `(.sender, .proof, .resourceProof)` branch no longer takes an `else` on a proof
  that fails to validate. It ignores it, matching reference
  `Resource.validate_proof`, which has no else branch and leaves termination to
  the sender watchdog. That watchdog (`senderDeadline` in `.awaitingProof`) is now
  the only SELF-terminator for a sender whose proof never validates, deliberately.
  It is not the only terminator: the peer can still cancel explicitly with a
  `RESOURCE_RCL`, and a host can send `.cancel`.

The routing mirrors reference exactly, verified against `RNS/Link.py` rather than
assumed: its `RESOURCE_PRF` branch takes `packet.data[0:HASHLENGTH//8]` and matches
it against `outgoing_resources`. One divergence to know about: reference uses a
`for` loop and acts on every match, ReTiCA uses `first(where:)` and acts on one.
With 32-byte hashes that never differs — see F18 for the case where it would.

**One thing this fix REMOVED that was load-bearing by accident, said here so the
next reader is not surprised by F19.** The old destructive branch was also the
only un-keyed way to clear a stuck sender transfer: one junk `RESOURCE_PRF` from
any off-path party failed EVERY sender-role transfer on the link, so a transfer
whose peer had gone silent could be swept away by a passer-by. F19 — a replayed
`RESOURCE_REQ` postponing the sender watchdog for as long as the replays continue,
which pins the transfer and with it the link — is PRE-EXISTING and unchanged by
this slice, but it no longer has that accidental teardown. Removing it was still
right: the teardown was itself the kill primitive this entry is about, and
restoring it to close F19 would reopen F15. See §3c.

**Do not summarise this as "proofs are now authenticated."** The honest statement
is that the branch no longer destroys anything, and that when it does act it acts
only on the transfer named in the packet. The resource hash is a per-transfer
SECRET carried in an encrypted advertisement — it is a discriminator, not an
authenticator, and treating it as one is how "failing on a mismatch" turned a
leaked hash into a kill primitive in the first place.

**The non-adversarial half was the stronger argument and it is fully closed.** Two
concurrent sender transfers on one link no longer destroy each other. Pinned by
`aResourceProofReachesOnlyTheTransferThatOwnsIt`,
`aResourceProofIsNotDeliveredToAReceiverRoleTransfer`,
`aShortResourceProofPayloadIsDroppedWithoutDelivery` and
`aTruncatedProofIsRejectedBeforeThePrefixComparison`; all four, plus the role and
length clauses independently, are mutation-verified in `a4b5e21`.

**And "two of our own concurrent sender transfers" is NOT hypothetical, which
makes this fix more load-bearing than the entry first claimed — added 2026-08-14.**
`LXMFRouter`'s retry timer manufactures that exact shape on any resource-framed
direct send that has not concluded within `LXMFDelivery.retryWaitSeconds`:
`.retryDue`'s `.direct` branch re-emits `.sendDirect(… asResource: true)` on the
live link without asking whether the previous send is still in flight, and
`LinkSession.sendResource` appends a SECOND sender-role transfer beside the first
— with a fresh `randomHash`, hence a different `resourceHash`, so nothing dedupes
it. Before `d0570ef`, whichever proof came back first failed the other transfer.
On the RF/mesh links this library targets, a transfer outrunning
`retryWaitSeconds` is the ordinary case, so this was reachable with no attacker
and no unusual timing. The same chain is F17's reachability correction — read
them together.

**The same shape survives one context over — see F17.** `.resource` is the one
remaining fanned-out context with no resource hash to route on.

The original text follows.

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

### F16 — the inactivity re-arm fires for ANY link-addressed packet — ⏸️ ACCEPTED (won't fix, 2026-08-23)

**Decision (2026-08-23), after a full brainstorm with the reference and the post-F11 state mapped:**
fixing F16 is not worth it, for three compounding reasons.
- **RNS-faithful.** Stock RNS stamps `last_inbound` BEFORE decrypt (`Link.py:935`, verified in 1.4.2 and
  the local fork), so reference ALSO extends a link's life on undecryptable junk. Any fix is a
  deliberate divergence, not a correctness restoration.
- **The plaintext keepalive is an irreducible re-arm vector.** An off-path party who knows the
  cleartext `linkID` can hold an `.active` link open indefinitely with valid `0xFF` keepalives, which
  RNS interop REQUIRES the responder to honor (re-arm + `0xFE` reply, pinned by
  `plaintextKeepaliveStillRefreshesInactivity` / `responderRepliesToKeepaliveWith0xFE`). Gating the
  re-arm on "legitimacy" only forces the attacker from arbitrary junk to valid keepalives — the
  capability (holding the link `.active`) is unchanged.
- **The slot-pinning harm is already handled by F11.** Eviction now keys on `lastData` + transfer
  progress, and keepalives/junk do NOT advance `lastData`, so a keepalive-held attacker link has an old
  `lastData` and no progressing transfer → it is the LRU eviction victim under cap pressure. The slot
  is reclaimable regardless of the inactivity timer; without cap pressure a keepalive-held link is just
  a live link consuming its own state and denies no one.

So the best a fix could do is stop *junk* (not keepalives) from re-arming the inactivity clock — a
cosmetic/consistency gain with near-zero residual-harm reduction — while reintroducing exactly the
per-branch re-arm fragility the hoisting exists to prevent ("adding a new context must not require
remembering this"). Net-negative; accepted as an RNS-faithful residual. Revisit only if a future change
makes the inactivity timer (not F11's eviction) load-bearing for slot reclamation. The original
analysis follows.

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

## 3b. Added 2026-08-13 — the destructive-transition sweep

Full branch-by-branch table:
`docs/superpowers/2026-08-13-destructive-transition-sweep.md`. Both items below
are LOW priority; they are recorded because the sweep's question surfaced them,
not because either is urgent.

**The structural finding behind both is worth more than either item.** For
anything `LinkSession` fans out to every `ResourceTransfer`, `Link.decrypt` and
the ownership check do DIFFERENT jobs. Every transfer on a link is constructed
with the same `sessionKey`, so decrypt keeps an OFF-LINK party out and does not
discriminate between two of OUR OWN objects at all (probed: transfer B decrypts a
`RESOURCE_REQ` addressed to transfer A without difficulty, and the only thing
that stops it acting is the `state.resourceHash` comparison). **AUTH bounds the
attacker set; OWNERSHIP bounds the blast radius.** A destructive branch with only
the first is the exact shape that lets our own objects destroy each other, which
is what F15 was.

### F17 — the `.resource` segment fan-out cannot keep two of our own receivers apart

**Where:** `LinkSession.received`'s `(_, .active, .data, .resource)` fan-out, and
`ResourceTransfer.received`'s `(.receiver, .data, .resource)` branch.

Five contexts still fan out to every transfer. Four of them are safe to fan out:
`.resourceRequest`, `.resourceHashmapUpdate`, `.resourceInitiatorCancel` and
`.resourceReceiverCancel` each decrypt and THEN compare against
`state.resourceHash`, so a non-owner returns `.none`. `.resource` is the
exception. A segment packet carries no resource hash, its branch calls no
`Link.decrypt`, and its only discriminator is
`Resource.mapHash(chunk:randomHash:)` — a hash of width `Resource.mapHashLength`
— looked up in `knownHashmap`, plus a `receivedParts[idx] == nil` dedup.

**Probe, with the collision constructed rather than searched for:** with two
receiver-role transfers on one link, transfer B absorbed a chunk belonging to
transfer A — `receivedParts[1]` filled, index 1 dropped from `outstanding`. B's
own legitimate part for that index then arrived and was REJECTED by the dedup
guard, leaving B byte-identical. B can no longer complete correctly and exits
through one of its `.failed` branches (`Resource.assemble` or `Resource.verify`).
**No attacker is involved**, and
`(_, .active, .data, .resourceAdvertisement)` will create two receivers for any
two distinct advertised hashes.

The ADVERSARIAL version of this was already priced by the previous sweep, which
deliberately recorded it without an F-number. The self-collision case is the half
it did not see, and it is F15's non-adversarial half one context over.

**Price it honestly before ranking it — there are THREE routes, not two.**

1. *Accidental*, between two of our own concurrent receivers: probability per
   fanned part is set by `Resource.mapHashLength` against the other transfer's
   hashmap height. Expensive **per part — but the two-concurrent-receivers
   PRECONDITION is not the rare part, and an earlier draft left the reader
   assuming it was. See the reachability correction below.**
2. *Sprayed*, by an off-link party holding no key: same probability. Expensive.
3. *Constructed by a peer holding the session key: FREE and deterministic.*
   `.accept` copies `adv.randomHash` and `adv.hashmap` into `state.randomHash` and
   `state.knownHashmap` VERBATIM, with no validation (F18's field set). The peer
   does not have to FIND a collision — it DECLARES one, advertising transfer B
   with a hashmap containing the map hashes of the chunks it is about to send for
   transfer A.

**Reachability correction to route 1, added 2026-08-14 by the final whole-branch
review: two concurrent receivers on one link is the ORDINARY case for a slow
resource, because OUR OWN retry timer manufactures it.** Every arrow verified
against the code:

- `LXMFRouter`'s `.retryDue` `.direct` branch, on a destination whose
  `directLinks` entry is `.active`, emits `.sendDirect(linkID:data:asResource:)`
  **unconditionally** and re-arms `retryTimer(hash, retryWaitSeconds)`. It never
  asks whether the previous send is still in flight.
- `LXMFNode` maps `.sendDirect(_, _, asResource: true)` to
  `.endpoint(.sendResourceOverLink)`, and `LinkPlane` maps that to
  `LinkSession.sendResource`.
- `LinkSession.sendResource` draws `randomBytes(8)` for a FRESH `randomHash` every
  call, and `Resource.resourceHash` is `fullHash(data ‖ randomHash)` — so the
  identical payload gets a **different `resourceHash`** on the retry.
- The receiver's only dedup is
  `state.transfers.contains(where: { $0.resourceHash == adv.hash })` in
  `(_, .active, .data, .resourceAdvertisement)`. Different hash, so it does not
  fire, and a second receiver-role transfer is created.
- The retry timer's only cancel is `.delivered`, and for a resource-framed direct
  send the only route to it is `.resourceDeliveredOnLink` ← `LinkSession`'s
  `.resourceConcluded` — i.e. only once the resource PROOF has returned.

So any resource-framed LXMF message whose transfer has not concluded within
`LXMFDelivery.retryWaitSeconds` duplicates itself, bounded by
`LXMFDelivery.maxAttempts` — and on the RF/mesh links this library targets, a
transfer running longer than `retryWaitSeconds` is the ordinary case. Probe:
two `sendResourceOverLink` calls of the IDENTICAL payload on one link produced two
sender transfers with distinct hashes and **two concurrent receiver transfers,
both `.requesting`.** The factors are positively correlated: the transfers most
likely to duplicate are the large slow ones, which are exactly the ones with the
tallest `knownHashmap`, and the number of collision opportunities is one
transfer's part count against the other's hashmap height.

**LOW survives, because the correction is to the PRECONDITION's price, not to the
collision's.** (a) The per-part probability against `Resource.mapHashLength` is
unchanged — duplication multiplies OPPORTUNITIES, not the chance per opportunity.
(b) Duplicates produced this way carry the SAME message, and a collision poisons
only the transfer whose `knownHashmap` held the colliding entry: the segment is
fanned out to both, so the other twin absorbs its own part normally and still
completes, after which `LXMFRouter.received`'s `state.seen.insert(message.hash)`
drops the duplicate delivery. The harmful shape — two receivers carrying DIFFERENT
resources — still needs two genuinely concurrent sends. (c) Nothing crosses a
trust boundary: `transfers` is per-`LinkSession` and both transfers are ours.

**A SECOND consequence of the same duplication chain, recorded 2026-08-14 as a LEAD
for whoever takes F17 — not a finding of its own, and not a collision.**
`LinkSession.State.segmentedSend` is a SINGLE optional keyed on one
`currentTransferID`, and `.sendResource` assigns it unconditionally on every call
whose `data.count` exceeds `LinkSession.maxEfficientSize`. So the second of the two
`sendResource` calls the retry chain produces OVERWRITES the first chain's
continuation state. Both handlers that act on it —
`.transfer(… .delegate(.concluded))` and `.transfer(… .delegate(.failed))` — are
gated on `send.currentTransferID == elementID`, so when the first chain's segment 1
concludes it no longer matches, falls through to the ordinary non-segmented exit,
and **its segments 2…N are never advertised** — that branch is their only emitter,
and the `remaining` array holding them was overwritten. Narrower than the collision
routes: it needs a payload above `maxEfficientSize`, where a collision needs none.
**Note that F17's own candidate fixes do NOT close it** — scoping a segment to the
transfer whose `outstanding` holds its index, or carrying the resource hash on
segments, both act on the RECEIVE side, and this clobber happens on the SEND side
before any segment goes out. Closing it means either scoping duplicate sends (the
`LXMFRouter.retryDue` half of the chain) or giving `segmentedSend` one entry per
chain instead of one per link; neither is on F17's list. Verify all of it before
acting.

**Test-visibility trap, which is why no in-repo test can currently observe this.**
`RandomBytesGenerator.testValue` is a deterministic ramp, so in-tree tests get the
same `randomHash` — and therefore the same `resourceHash` — for the same payload,
and the receiver's advertisement dedup swallows the duplicate. Nothing in `Tests/`
can show the duplication without overriding `\.randomBytes`, and a test written
without that override will look like evidence that it does not happen.

Route 3 does not raise the severity, and the reason is worth stating rather than
assuming: the peer that constructs it advertised BOTH transfers, so it destroys a
delivery it controls anyway and could equally well just not send, and `transfers`
is per-`LinkSession` so it cannot reach another peer's. LOW stands.

**Do not restate this as "a buggy peer that reuses `r` gets it for free" — that is
FALSE, and it is the intuitive summary.** Map hashes are taken over CIPHERTEXT
chunks, and `Resource.buildStream` → `Token.encrypt` draws a fresh random IV per
call, so two sends of byte-identical data under the same `randomHash` and the same
prefix still yield entirely different chunks and entirely different map hashes.
Probed three ways (same `r` + different data; same `r` + same data + same prefix;
same `r` + same data + different prefix) — zero collisions in all three. The
deterministic route is control of `m`, not repetition of `r`.

Two blast-radius facts belong with it: a collision also drops `partTimeoutFactor`
to `Const.partTimeoutFactorAfterRTT` for the rest of that transfer's life, and if
the poisoned transfer is a response-Resource its failure reaches
`.transfer(… .delegate(.failed))` and cancels a legitimate request with it.

**Reference has the same defect and knows it.** Read out of `RNS/Link.py`, not
assumed: its `RESOURCE` branch is
`for resource in self.incoming_resources: resource.receive_part(packet)` — no hash
filter at all — carrying a standing upstream TODO, *"find the most efficient way
to allow multiple transfers at the same time, sending resource hash on each packet
is a huge overhead."* `RNS.Packet` defines seven resource contexts; of the six
others, five filter (`RESOURCE_REQ`, `RESOURCE_HMU`, `RESOURCE_ICL`,
`RESOURCE_RCL` decrypt and match `resource.hash`; `RESOURCE_PRF` matches against
`outgoing_resources`) and the sixth, `RESOURCE_ADV`, has no existing resource to
route to because it CREATES the resource. (An earlier draft said it "has nothing
to filter against". That is wrong about reference and is contradicted by this
document's own F18 `q` bullet: `RESOURCE_ADV` DOES filter, matching
`read_request_id` against `pending_requests` on its `is_response` branch. Only the
no-existing-resource clause is true. The sweep named this a drafting error in
round 2 and the fix landed there and not here — see §6's twin rule.) So
`.resource` is the one context that routes to
an existing resource with no reference discriminator to copy, and a fix has to be
CHOSEN rather than ported: scope a segment to the transfer whose `outstanding`
contains its index, or carry the resource hash on segments — which is the overhead
the upstream TODO is about. That is why this is ranked below F3/F4/F5 despite
being a real correctness defect.

**Verified against BOTH RNS checkouts**, since this repo has two at different
versions: `diff` between the local 1.4.1-fork `Link.py` and the stock 1.4.2 one in
the conda `rns` env is EMPTY. The claims above are stock behaviour, not fork
behaviour.

### F18 — `ResourceAdvertisement.unpack` validates the length of none of `h`, `r`, `o`, `m`, `q`

**Where:** `ResourceAdvertisement.unpack`. `h`, `r`, `o` and `m` are read through
the same `bin(_:)` helper, which checks only that the MsgPack value is a `.bin`;
`q` goes through its own `switch`, which likewise accepts any `.bin`. Only `t` has
any gate (a magnitude gate against `Resource.maxAdvertisedTransferSize`). Probed:
an advertisement with all four `bin(_:)` fields EMPTY round-trips intact, and so
does one with over-long `h` / `r` / `o`.

**Ranked BELOW F17** (see §3). A round-2 review flipped that and round 3 retracted
the flip: F18 is NOT the upstream cause of F17's route 3, because no `unpack`
validation of any kind can close it — `m` carries the peer's own resource's map
hashes by protocol design, so a hostile hashmap is indistinguishable from a
legitimate one. **A length check closes exactly ONE of the four consumers below
(`h`);** the others need uniqueness (`o`), routing (`m`, which is F17's fix) or
provenance (`q`) checks. §7 of the sweep has the full retraction.

**Impact today is nil, and the framing matters more than the finding.** An empty
`h` becomes a receiver transfer's `resourceHash`, and an empty `owner` prefix
compares equal to it — so a truncated proof payload would match a decoy. Three
corrections to how this was first written during the slice, all re-verified by
probe before being recorded here:

1. **The length guard is the SECOND LOCK that keeps the match from happening. It
   is not that an attacker gains something today.** `ResourceTransfer.received`
   has no `(.receiver, …, .resourceProof)` case at all; a receiver handed a proof
   falls to `default: return .none`. Probed with both `.proof` and `.data` packet
   types: state byte-identical. It would bite only if a receiver-side proof
   handler were added, because `first(where:)` returns a SINGLE target and a
   matched decoy would then shadow the real recipient.
2. **"Wire-controlled" means PEER-controlled, not off-path.** The advertisement
   carrying `h` goes through `authDecrypt`, so an empty hash requires the session
   key (probed: an unencrypted advertisement creates no transfer at all). The
   proof PACKET is the off-path half — unencrypted, admitted on
   `destinationHash == state.linkID` alone.
3. **Only the role-gate pairing holds.** The claim "(b)+(d) and (c)+(d) are
   jointly exploitable" is half false. Under (c) the predicate is
   `$0.role == .sender`, which never selects a receiver, so the empty-hash
   mechanism is irrelevant to it. Probed by running both mutated predicates
   literally over a decoy-first array.

A length check on `h` at unpack time would remove **the `h` class** outright, and
**that belongs to whoever owns advertisement validation**, not to the
proof-routing code.

**Three more consumers of unvalidated advertisement fields**, all needing the
session key and so all bounded to what that peer could refuse to do anyway. Name
them here because they share a SITE (`unpack` validates nothing), but **do not
read them as things the length check closes — it closes none of them.** That
mis-reading is what produced the retracted ranking flip in §3:

- `o` (`originalHash`) keys `incomingSegments`, so two advertisements from one
  peer can share an accumulator. **Needs a uniqueness check at the consumer**, not
  a length gate — the weakness is two advertisements declaring the SAME valid `o`,
  and `unpack` only ever sees one advertisement at a time.
- `m` (`hashmap`) is copied verbatim into `state.knownHashmap`, which is what makes
  F17's collision constructible for free rather than found — see F17, route 3.
  **No `unpack` validation of any kind closes this**: `m` IS the peer's own
  resource's map hashes by protocol design, so a hostile hashmap is
  indistinguishable from a legitimate one. This one is F17's to fix, not F18's.
- `q` (`requestID`) is copied into the transfer's advertisement and later read by
  `.transfer(… .delegate(.failed))`. **The flag gate does not cover it:** the
  `pendingRequests` check in `.resourceAdvertisement` sits inside `if
  adv.isResponse`, so an advertisement with NEITHER flag can carry a live
  requestID past it. Probed. **Length is irrelevant here** — a borrowed id is a
  legitimate full-length `truncatedHash`; the gap is PROVENANCE. What actually
  holds is the `.failed` handler's own `state.pendingRequests.contains(rid)` plus
  `pendingRequests` being per-`LinkSession` — whose only INSERT sites are
  `.sendRequest`'s two branches (say "inserted", not "written": the file has NINE
  write sites — two inserts, five removals, and two initialiser assignments) — so
  a peer can cancel only requests we sent to THAT peer.

  Reference nests this identically and still lacks the defect, which locates ours
  exactly: RNS's `RESOURCE_ADV` matches `read_request_id` against
  `pending_requests` inside `elif is_response(packet)`, but its
  non-request/non-response paths call `RNS.Resource.accept(packet, callback)`
  WITHOUT `request_id=`, so a borrowed id is never bound to a plain resource. Our
  divergence is not the nesting — it is storing `q` regardless of flags and
  reading it back unconditionally.

## 3c. Added 2026-08-14 — the final whole-branch review of the destructive-transition slice

### F19 — a replayed `RESOURCE_REQ` postpones the sender watchdog without bound, pinning the transfer and its link — ✅ CLOSED (`3a7a1d9`, 2026-08-23)

**Closed by** adopting reference's per-resource `req_hashlist`: the sender transfer now carries a
`servedRequestHashes: Set<Data>`, and the `(.sender, .data, .resourceRequest)` branch dedups an
incoming request on `packet.packetHash` — the hash over the ENCRYPTED packet — before any re-send,
status/retry reset, or `armSenderWatchdog`. A byte-identical replay is a complete no-op, so it can no
longer re-arm the watchdog; the transfer's watchdog fires on schedule, `proofRetriesLeft` decrements,
it reaches `.failed`, and the link becomes evictable (via the F11 fix). Genuine re-requests are
served because `Link.encrypt` uses a fresh random IV per call (`Token.swift:31-32`), so a legitimate
re-request — even for the same still-missing parts — re-encrypts to a different packet and a different
`packetHash`. No cap (transfer-scoped, matching reference). Whole-branch reviewed, both mutation
directions confirmed live. **F16 rider still open:** the *link's* inactivity timer is still refreshed
by replayed traffic; the link is reclaimed under F11 cap pressure once the transfer self-terminates.
Spec/plan: `docs/superpowers/specs/2026-08-23-f19-replayed-resource-req-watchdog-design.md`,
`docs/superpowers/plans/2026-08-23-f19-replayed-resource-req-watchdog.md`. The original analysis follows.

**Where:** `ResourceTransfer.received`'s `(.sender, .data, .resourceRequest)`
branch and `armSenderWatchdog`; `LinkPlane`'s `evictable` filter, which since
F14's fix lives in the `.link(… .delegate(.established))` handler.

**Mechanism — every arrow verified against the code, not inferred:**

- `Transport.received` routes `destinationType == .link` packets ABOVE
  `seenPacketHashes.insert`, so a replay reaches the link path at all (F9).
- `LinkSession` fans `(_, .active, .data, .resourceRequest)` out to every transfer
  on the link.
- The sender branch's gates are `Link.decrypt` and
  `p[pad ..< pad+32] == state.resourceHash`. **A captured genuine request
  satisfies both with no key** — that is F9's `req_hashlist` instance, already
  recorded in F9 with the reference guard we lack.
- The branch re-sends the requested parts, restores `.awaitingProof` when
  `sentIndices` is already complete, and calls `armSenderWatchdog(state)` — which
  is `.cancellable(id: CancelID.watchdog, cancelInFlight: true)`, i.e. it
  **RESTARTS** the window rather than leaving it running.
- `proofRetriesLeft` is decremented in exactly ONE place: `.senderDeadline`'s
  `.awaitingProof` branch. A deadline that never fires never spends a retry.

**Probe, through production wiring** (the reducer-level equivalent would not have
shown the link-plane half): one captured `RESOURCE_REQ` frame replayed every 5 s —
inside the `.awaitingProof` window, which is
`rtt × Const.proofTimeoutFactor + Const.senderGrace` — left the transfer
`.awaitingProof` at t ≈ 600 s with **`proofRetriesLeft` pinned at its initial
`Const.proofRetries`, never decremented**, and `links=1 transfers=1` throughout.
The control, an identical loop with junk proofs instead of the replayed request,
terminated at t ≈ 40 s. **So the extension is UNBOUNDED, which F9's paragraph does
not say** — F9 records the re-transmission and the re-arm as amplification and
life extension; it does not say the retry counter never advances.

**What it costs us, composed from two facts this repo records separately and never
put together.** The sender watchdog is the transfer's only SELF-terminator — every
other exit needs someone to act, and all three were read out of
`ResourceTransfer`: a proof that satisfies `Resource.validateProof`
(`received`'s `(.sender, .proof, .resourceProof)` → `.complete` →
`.delegate(.concluded)`), the peer's `RESOURCE_RCL` (`received`'s
`(.sender, .data, .resourceReceiverCancel)`, gated on `Link.decrypt`, so it needs
the session key), and the host's `.cancel` — which is a reducer ACTION, not a
`received` branch. Postponing the watchdog therefore means a sender transfer whose
peer has gone silent — the exact case the watchdog exists for — does not end **on
its own** for as long as the replays keep arriving. `LinkSession` removes a transfer only on a child
`.delegate(.received/.concluded/.failed)`, so `transfers` stays non-empty for that
whole time; and `LinkPlane`'s eviction filter is
`active.filter { $0.id != elementID && $0.transfers.isEmpty }`, so that RESPONDER
link is un-evictable for as long as the pin holds, and while nothing is evictable
the plane REFUSES the newcomer at the cap. **That is F11's lockout, reached without
the session key.** The comment above that filter prices the RECEIVER-side version —
"a peer holding an active link … can advertise a resource, never send a segment,
and become eviction-immune" — and scopes it to a peer holding the session key. The
sender-side version needs one captured frame.

**What bounds the pin, stated because an earlier draft of this entry — and the
subject line of the commit that added it — said "for ever", which is wider than the
evidence.** The pin lasts exactly as long as the replays do. Stop them and the next
`.awaitingProof` deadline is no longer postponed: `.senderDeadline` decrements
`proofRetriesLeft` from `Const.proofRetries`, and on the deadline that finds it at
zero the branch sets `.failed` and emits `.delegate(.failed)` — at which point
`LinkSession` removes the transfer, and once that empties `transfers` the link is
evictable again. The correct claim is **unbounded while replayed**, which is what
the probe observed; "never ends" unconditionally is not, and neither is
"permanently un-evictable". **Note for anyone arriving by git blame:** commit
`c47443b`'s subject line is *"docs: F19 — a replayed `RESOURCE_REQ` postpones the
sender watchdog for ever"*. That overstates it in the same way, and a pushed commit
message cannot be corrected — this paragraph is the correction.

Two riders that keep the pin from being cleared by the link's own inactivity timer
or by the LRU that picks eviction candidates, both verified in
`LinkSession.received`: the replay is a link-addressed packet, so the hoisted
re-arm below `dispatch` refreshes `inactivityTimer(state.staleTime)` on every
round (F16) and the link element does not time out either; and the fan-out
contexts forward raw bytes without calling `authDecrypt`, so `sawAuthenticatedData`
stays false and `lastData` is NEVER advanced — the pinned link simultaneously looks
maximally idle to the LRU key and is excluded from the candidate set. That second
one is the exact trade the `evictable` comment describes, seen from the other side.

**Do NOT claim this is the first un-keyed route to F11's immunity — it is not, and
an earlier draft of this entry said so before checking.** F9's second-order
consequence already records one: replaying a captured ADVERTISEMENT re-creates a
receiver transfer after the previous one is reaped, keeping `transfers` non-empty
without the session key. What F19 adds is that it needs no re-creation cycle at
all, because the terminator never fires: the object it pins is our own SENDER
state, and the same replay also re-transmits the requested parts (F9's
amplification half). Same root cause, same family, and the same cheapest fix.

**Preconditions, stated so the rank below is honest.** The attacker cannot create
the transfer: we must already be serving a resource to that peer on a RESPONDER
link, and the transfer must not otherwise conclude. Neither is exotic.
`LXMFServiceNode` answers a client's message-download with `sendResponseOverLink`,
and `LinkSession.sendResponse` sends any response above `Self.requestMDU` as a
sender-role Resource **on the link the CLIENT opened** — so a node in
propagation-node mode serves resources on responder links as a matter of course.
It is one pin per resource we chose to send: a captured frame names one
`resourceHash`, and the branch's own hash check keeps it from touching any other
transfer.

**What this slice changed — and it is the only part attributable to it.** The
attack is PRE-EXISTING. Before `d0570ef` + `0101a74`, one junk 64-byte
`RESOURCE_PRF` from any off-path party fanned out to every transfer and failed
every SENDER-role one — that was F15 — so the pin had an accidental, un-keyed
teardown. **Task 3 removed it, correctly**: that teardown was itself the kill
primitive F15 names, and restoring it to close F19 would reopen F15. What changed
is not the pin but the accident that used to clear it.

**Rank: 3rd — directly below F11, above F7.** Justification, and what would move
it:

- **Below F11**, because F11's precondition is entirely attacker-supplied: a peer
  holding an active link can advertise and stall without bound (probe: 25
  advertisements → 25 transfers). F19 needs us to be actively serving a resource
  to that peer, so it is one pin per resource WE chose to send, not one per packet
  the attacker sends. F11 already accepts the KEYED version of this exact immunity
  as a priced trade — F19 is the same immunity at a lower price with a narrower
  trigger.
- **Above F7**, because the consequences are not comparable in kind: per instance
  F19 pins a whole `ResourceTransfer.State` plus the `LinkSession` element and
  denies service to every new responder peer once the responder population is at
  the cap, where F7 leaks one map entry — and F19 does it for an off-path party
  holding no key.
  **The opposing consideration, stated because a rank argument that omits it is the
  same over-wide shape as everything else this slice had to correct:** F7 needs no
  attacker at all — our own idle timer produces it, and the only clearer on that
  path, `closed()`'s `if case let .active(linkID)`, cannot match because
  `.idleDeadline` nil'd `directLinks[dest]` first — where F19's pin clears once the
  replays stop (see "what bounds the pin" above). Do not read the rank as "F19 is
  worse in every dimension"; it is worse in blast radius per instance, which is what
  this bullet ranks on.
  **Cost of fix is deliberately NOT part of this argument, and a clause arguing
  from it was removed here on 2026-08-14.** It said F19 has a cheap
  reference-blessed partial already specified (F9's `req_hashlist`) — true, but it
  argues F19 over **F11**, whose fix is its own slice, not over F7, whose fix is
  cheaper still: bind `linkID` in `LXMFRouter.idleDeadline`'s existing `.active`
  guard and clear `linkResourceInFlight[linkID]` before nil'ing `directLinks[dest]`.
  As a reason to outrank F7 it was backwards. Fix costs for F19 are listed at the
  end of this entry, where they inform the fix rather than the rank.
- **What would move it DOWN:** if a deployment never serves resources on responder
  links, the precondition never arises and F19 collapses into F9's group. It is
  ranked for the propagation-node case, which this library supports and which
  meets the precondition routinely.

**Fix options, cheapest first.** (1) Reference's per-resource `req_hashlist` —
skip a `RESOURCE_REQ` whose `packet_hash` has already been served — closes it at
the source, is reference-blessed, and does not require solving F9's general
problem. (2) Bound a transfer's TOTAL lifetime rather than only its per-window
one, so re-arming cannot be free. (3) Make the `evictable` filter tolerate a
transfer that has made no progress, which addresses F11 and F19 together but
re-opens the mid-transfer-eviction problem the filter exists for. Do NOT "fix" it
by restoring a destructive branch on unauthenticated input; that is F15.

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

**And when a probe crosses the endpoint boundary, guard it with a positive
control.** `TCPClientInterface` deframes with HDLC, so an unframed packet handed
to `TCPEvent.data` is silently swallowed and never reaches `Transport.received` —
a composition probe that injects raw packets will report reassuring state while
every injection is a no-op. Inject N framed packets, assert N arrivals, and only
then assert anything about what the injection failed to do. Full write-up in §6 of
`docs/superpowers/2026-08-13-destructive-transition-sweep.md`.

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

**A claim that lives in BOTH this document and its sweep must be fixed in both,
or in neither — added 2026-08-14, and it is the most transferable thing the
destructive-transition slice produced.** The sweeps and this handoff deliberately
restate each other, and **two of the four minors that slice deferred were
one-sided fixes**: round 3 narrowed "would remove the `h` class" here and left
"would remove the class outright" standing in the sweep, and round 2's
`RESOURCE_ADV` correction landed in the sweep and not here. A one-sided
correction is **strictly worse than leaving both wrong**: the wider statement
survives in the document that is not open at the time, and the disagreement
between the twins is invisible from either one — which is the entry directly
above, one document over. The check is one grep of the twin for the claim before
committing the fix. Where a finding is big enough that duplicating it is itself a
hazard, state it ONCE and point at it from the other — F19 is written that way.

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
> **Superseded again 2026-08-13 (`892652a..a4b5e21`): F12 and F15 are CLOSED**, so
> the top of the list is now F13 alone. The lesson above held a second time — F15's
> fix produced F17, which is the same property one context over, and the sweep that
> found it only did so because it stopped asking about the branch (can an attacker
> reach this?) and asked about the property (does this destroy something it has not
> checked it owns?).
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
