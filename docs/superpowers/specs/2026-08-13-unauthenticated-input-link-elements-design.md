# Design — unauthenticated input cannot pin, steal, or kill a link element

**Date:** 2026-08-13
**Source:** `docs/superpowers/2026-08-10-handoff-link-lifecycle-and-delivery-termination.md`
(as corrected in `87055bc`), items F1, F2, F6.

---

## 1. The invariant

> Unauthenticated input can neither **pin**, **steal**, nor **kill** a link
> element — and link-element growth is bounded regardless of what keys an
> attacker legitimately holds.

The final clause is the correction that motivated this design. **Opening a link
is unauthenticated by protocol design**, so authentication can never be the
*bound* on link-element growth. It can only be a *gate on transitions*.

**Correction, added 2026-08-13 after the slice shipped — the KILL half was
FALSIFIED by this slice's own Task 4, and restored afterwards.** Recorded as a
correction rather than a rewrite, because the sequence is the point.

Task 4 implemented §2.3's cap in `LinkPlane.acceptLinkRequest` and paid for it by
evicting an `.active` responder link. That gave unauthenticated input a DESTROY
verb it had never had before: pre-slice, a junk LINKREQUEST could only CREATE
elements. Worse, a junk request is viable enough to reach `.handshake` — `Link.sessionKey`
succeeds on a random 32-byte key (overwhelmingly likely to be accepted); several canonical
low-order values including all-zeros ARE rejected by CryptoKit —
and a `.handshake` element is not evictable,
so each one killed an authenticated link and then held the slot it freed. Probed
through production wiring at a cap of four: zero of four established links
survived. The invariant above read as satisfied for the whole slice while the
opposite was true, and neither Task 1's review (one packet cannot kill an
element) nor Task 4's (growth is bounded) asked what happened to the links that
died on the way to the bound.

Fixed in `381d731` by splitting the budgets: unauthenticated input spends only
`maxIncompleteResponderLinks` and evicts nothing, and the `maxResponderLinks`
eviction moved to promotion, where the peer has demonstrably completed a
handshake. The KILL half of the invariant holds again.

The other two halves are weaker than this sentence claims and were already
qualified during execution: STEAL is narrowed, not closed (F9, F10 in the
handoff), and PIN is "refusable-into" rather than prevented (F11). Read the
handoff's F-entries before relying on any of the three words.

### 1a. Two premises in the handoff were falsified before designing

Both were verified against the reference tree, not reasoned about.

**Gating inactivity refresh on an authenticated packet breaks RNS interop.**
`Packet.pack` carries a dedicated branch — `elif self.context ==
Packet.KEEPALIVE:` → `self.ciphertext = self.data`, commented *"Keepalive
packets contain no actual data."* RNS keepalives are unencrypted **by explicit
design**. Our plaintext `0xFF`/`0xFE` byte-compare is faithful to reference. A
peer on an otherwise-idle link sends only keepalives, so refusing to refresh on
them tears down links with real RNS peers. That is a wire-compat regression of
exactly the kind [[cross-validation-drive-real-rns]] exists to prevent.

**And that gate would not have closed F1 anyway.** The responder reaches
`.active` only by decrypting a valid RTT — but the attacker *supplied* the
LINKREQUEST, so it holds its own ephemeral, completes a genuine handshake, and
owns a valid session key. It can send perfectly **authenticated** keepalives
forever. Authentication does not discriminate here.

**Consequence:** F1 is bounded by resource policy (§2.3), never by
authentication. Authentication gates only **re-homing** (§2.4), where an
attacker who lacks the session key genuinely cannot pass.

**Third fact, for context:** RNS caps nothing either — `pending_links` and
`active_links` are unbounded lists. Our cap is therefore a divergence from
reference, but a *local resource policy* one, not a wire-behaviour one. That is
what makes it safe where the interop gate was not.

---

## 2. The four changes

### 2.1 — F6: ignore a bad RTT, do not reap the element

**Where:** `LinkSession.received`, `(.responder, .handshake, .data,
.linkRequestRTT)`.

An undecryptable RTT currently emits `.establishmentFailed(.handshakeRejected)`,
which makes `LinkPlane` **reap a legitimate in-progress responder link**. Since
`Transport` routes link-addressed packets by cleartext `linkID` ahead of
`seenPacketHashes`, and `linkID` is derivable from any observed link packet, a
single injected garbage packet silently kills a legitimate inbound
establishment.

**Change:** ignore the packet. This mirrors the branch a few lines above,
`(_, .active, .data, .none)`, commented *"corrupt/foreign data is ignored, link
stays active."* The establishment timer is already armed, so the element still
terminates and §1b's reapability rule continues to hold.

Smallest change in the slice, largest security win: it is the only one-packet
attack.

### 2.2 — F2: dedupe inbound LINKREQUESTs by `linkID`

**Where:** `LinkPlane.acceptLinkRequest(owner:destinationHash:interfaceID:data:)`.

The action already carries the raw request, so `LinkPlane` can compute
`Link.linkID(requestPacket:)` and drop a request whose `linkID` is already
present in `state.links`.

**The check must precede the append.** Append-before-dispatch is the shape that
made replays expensive in the first place.

**Verified safe on both sides.** ReTiCA defaults `ephemeral: Identity =
Identity()` per attempt; RNS calls `X25519PrivateKey.generate()` in
`Link.__init__` and has no LINKREQUEST retransmit — a retry is a new `Link` with
a new ephemeral. **An identical `linkID` is therefore always a replay or a
multipath copy, never a legitimate retry.**

This also eliminates the per-replay **keypair generation** caused by that
defaulted `ephemeral:` parameter, which was the largest unlisted cost in F2.

**Note on the motivation.** The original handoff justified dedupe with a
shadowing story that was inverted and false (see `87055bc`). The surviving
justification is different and stronger: `hashablePart` excludes `hops`,
`headerType`, `transportType` and `transportId`, so HEADER_1 and relayed
HEADER_2 copies of the same request share a `linkID`. **Duplicate elements arise
non-adversarially on any multipath mesh.**

### 2.3 — F1: cap responder links, evict by least-recent authenticated data

Two traps here. A naive cap hits both, and the second one silently inverts the
policy.

> **Trap 3, which this section MISSED and Task 4 walked into — see §1's
> correction.** It says nothing about WHERE the cap is checked, and the obvious
> place (`acceptLinkRequest`, at the moment the population grows) is the one place
> the eviction is paid for by unauthenticated input. Both traps below are about
> WHICH link is evicted; neither asks who gets to trigger an eviction. Since
> `381d731` the answer is: the half-open population is bounded at the request, with
> no eviction at all, and the `.active` cap is enforced at PROMOTION. Everything
> below still describes the eviction POLICY correctly; only its site moved.

**Trap 1 — cap responder links only.** A global cap with oldest-eviction lets an
attacker flood us into evicting **our own outbound initiator links**. The cap
would become a DoS amplifier. Initiator links are ours and are never the attack
surface.

**Trap 2 — evict on `lastData`, not `lastInbound`.** An attacker sending
keepalives keeps `lastInbound` permanently fresh. An LRU over `lastInbound`
therefore evicts quiet **legitimate** links and preserves attacker links —
precisely backwards.

**So `LinkSession.State` gains `lastData`, updated only on a SUCCESSFULLY
DECRYPTED non-keepalive packet.**

**Be precise about how this relates to RNS, because half of it is a deliberate
divergence and the design fails without that half.** The keepalive-vs-data
*distinction* is RNS's — `if packet.context != RNS.Packet.KEEPALIVE:
self.last_data = self.last_inbound` — and we already have `lastInbound`, so we
are only missing the other half. But RNS performs that assignment **before** it
decrypts (the decrypt is further down the same handler). Mirroring RNS exactly
would let an attacker bump `last_data` with a **garbage non-keepalive packet**,
which defeats the eviction policy entirely.

So: take RNS's distinction, add a decryption requirement RNS does not have.
Requiring successful decryption is the point — it is the one place in this design
where authentication genuinely discriminates on the *responder* side, because it
is the one signal an attacker cannot forge without the session key. And an
attacker that HAS the session key is on its own link, which the cap bounds.

Eviction sorts on `lastData`, falling back to activation time for links that
have never carried data.

**Cap shape follows the `PropagationStore` precedent** in this repo:
`maxResponderLinks: Int?`, where `nil` means unlimited. Note that
`PropagationNode` explicitly documents *"Do not pass 0 as unlimited"* for its
analogous limit; the same rule applies here — `0` means zero, not infinity.

**Eviction must emit the normal removal-triggering delegate**, not a bare
`state.links.remove`. A silent removal would strand `linkResourceInFlight` —
exactly F7's shape. Do not introduce a second instance of a known bug while
fixing this family.

**Cap value.** Configurable on `LinkPlane.State`. The default must be chosen
against **propagation-node** expectations, since a PN legitimately holds many
concurrent responder links and is the realistic false-positive case. Name the
constant, state the chosen value where it is defined, and pin the *policy* in
tests rather than the number — do not derive capacity arithmetic in prose
(§4 convention of the handoff).

Deliberately not fixed here: this design does not claim a specific number. It
claims the **shape** (responder-only, `Int?`, evict-by-`lastData`). The plan
picks the value, and the tests must pass for any cap ≥ 2 so that changing it
later does not invalidate them.

### 2.4 — Re-home only on authenticated input, or after a local disconnect

Re-homing is the **link-theft** vector: `LinkPlane.routeLinkPacket` currently
re-homes the element *and every in-flight resource transfer* to the arrival
interface before delivering, driven by any inbound link packet including a
plaintext keepalive. An attacker holding only an observed `linkID` can redirect
a legitimate peer's traffic to itself.

**Change:** `LinkSession.Action.received` gains the arrival `InterfaceID`. The
re-home decision moves out of `routeLinkPacket`'s unconditional rebind and into
`LinkSession`, **after decryption** — the only place that can distinguish
"authenticated **and** from somewhere new." `LinkSession` emits a `rehomed`
delegate so `LinkPlane` still re-homes in-flight resource transfers.

`routeLinkPacket` loses its unconditional rebind entirely.

**Local-disconnect escape hatch.** Re-homing exists deliberately: a reconnected
BLE peer always gets a new `InterfaceID`. Authenticated-only re-homing would
strand an idle BLE link on a dead interface until the peer sends real data, with
outbound failing into the `sendFailed` that F5 says nobody consumes.

So a **local** interface disconnect flags affected elements as re-home-permitted,
and a flagged element re-homes on the next packet whether authenticated or not.
An attacker cannot forge a local disconnect; every BLE reconnect involves one.

**Where the flag lives:** on the element — `LinkSession.State` — because §2.4
puts the re-home decision inside `LinkSession`, so the decision and its input
must sit together. `LinkPlane` sets it directly on the matching elements when it
handles `interfaceDisconnected`. The flag clears on the re-home it authorises,
so one disconnect authorises one rebind rather than permanently downgrading the
element to unauthenticated re-homing.

**This needs one new action.** `LinkPlane` has no `interfaceDisconnected` case
today — both endpoints emit `.transport(.interfaceDisconnected(id))` to
`Transport` only. Add the `LinkPlane` case and fan out at those two existing
emit sites in `BLEEndpoint` and `TCPEndpoint`.

---

## 3. What this design deliberately does NOT do

**No authentication gate on keepalive inactivity refresh.** See §1a. The cap is
the bound; authentication gates only re-homing.

This is a deliberate non-change and it must be **pinned by a test** (§5), because
it is precisely the kind of thing a later well-intentioned hardening edit
re-breaks silently.

---

## 4. Data flow

**Inbound link packet.** `Transport.received` → link-addressed →
endpoint → `LinkPlane.routeLinkPacket(linkID:arrivalInterface:data:)` →
`first(where:)` → `LinkSession.received(data, arrivalInterface)` → decrypt → if
authenticated and the interface differs, rebind and emit `rehomed` →
`LinkPlane` re-homes in-flight transfers.

**Inbound LINKREQUEST.** Endpoint ownership/private-key guards →
`LinkPlane.acceptLinkRequest` → compute `linkID`, drop if already present →
responder-cap check, evict if full → append → dispatch `.acceptRequest`.
*(Corrected in `381d731`: the step now reads "half-open-budget check, REFUSE if
full", and the eviction happens on the `.delegate(.established)` promotion
instead. See §1's correction — "evict if full" here is what Trap 3 was.)*

**Local disconnect.** Endpoint peer/socket loss → existing
`.transport(.interfaceDisconnected(id))` **plus** new
`.linkPlane(.interfaceDisconnected(id))` → flag elements bound to `id`.

---

## 5. Testing

Two recorded lessons bind hard here.

**"Tests that seed state prove nothing about reachability."** The cap test feeds
N+1 real LINKREQUESTs through the endpoint. It does **not** seed
`state.links`.

**`Effect.cancel` is eager** ([[tca-effect-cancel-is-eager]]). We are editing
`LinkSession`'s effect construction — the exact place where that bit once killed
three timers while all 56 tests passed, before and after.

Standard TestStore hygiene applies: prefer flip-then-send over a trailing `.on`;
never assert effect-produced state before draining; never flip back to `.off`
before teardown.

### Tests that carry weight

1. **F6** — inject a garbage RTT at a legitimate in-progress responder link;
   assert the element **survives** and still establishes when the real RTT
   arrives.
2. **F2 dedupe** — the same LINKREQUEST twice yields exactly one element and
   exactly one LRPROOF.
3. **Cap** — N+1 distinct requests leave the count bounded, and **an initiator
   link is never the victim**. *(Missing, and this is the gap Trap 3 fell
   through: nothing here asks whether the ESTABLISHED links survive the flood.
   `junkLinkRequestBurstDoesNotEvictASingleEstablishedLink` is that test, added
   with the `381d731` fix.)*
4. **Eviction policy — the load-bearing test.** Construct an attacker link kept
   fresh by keepalives alongside a quieter legitimate link whose `lastData` is
   newer but whose `lastInbound` is older. **This test must fail if eviction
   ever sorts on `lastInbound`.** Without it, the subtle half of §2.3 is
   unpinned and inverts under a plausible future edit.
5. **`lastData` requires decryption — pins the §2.3 divergence.** An
   undecryptable **non-keepalive** packet must not bump `lastData`. If it does,
   an attacker keeps its link at the head of the eviction order with garbage and
   the cap protects the wrong links. This is the test that would have caught the
   error the spec self-review found; without it, mirroring RNS exactly looks
   correct and passes everything else.
6. **Re-home** — an authenticated packet from a new interface rebinds; a
   plaintext keepalive from a new interface does **not**; after a local
   disconnect, it does — **once**, and a second keepalive from a third interface
   does not (pins the flag-clears-on-use rule in §2.4).
7. **Interop guard** — a plaintext keepalive still refreshes inactivity. Pins
   the §3 non-change.

Then the three-step verification: green → batch-mutate → confirm all fail →
revert → green.

---

## 6. The sweep

A **planned task with a committed artifact**, not a verdict in chat. F1, F2 and
F6 are three instances of one pattern, and three instances means the pattern is
systemic ([[narrowing-conversions-are-a-class-defect]]).

Enumerate every branch in `LinkSession`, `LinkPlane` and `Transport` where
unauthenticated input can **create, extend, re-home, or destroy** a link element
— the four verbs this slice fixes one instance of each. Output a table of
branch → what unauthenticated input can cause → verdict.

Anything found and not fixed here becomes a numbered item in the handoff.

Known starting points, already identified and not otherwise covered by this
slice:

- `acceptRequest`'s empty-session-key guard is **remotely reachable** via an
  all-zeros X25519 key (the degenerate-point trick the initiator-side tests
  already use), and its element-reaping behaviour is untested.
- `LinkSession.close` on a non-`.active` link is a silent no-op; the element
  survives to the establishment deadline.

---

## 7. Residual risks

**The cap can evict a legitimate responder link under genuine load.** A
propagation node serving many peers is the realistic case. Mitigated by choosing
the default against PN expectations and by evicting on `lastData`, but not
eliminated. *(Since `381d731` there is a second such risk: a flood of half-open
handshakes fills `maxIncompleteResponderLinks` and new inbound establishment is
refused until those elements hit their establishment deadline. That window
self-clears without the attacker's cooperation, which the eviction it replaced
did not.)*

**Auth-gated re-homing can still flap** for a genuinely multi-interface peer
whose authenticated packets arrive over more than one interface. Strictly better
than today's rebind-on-anything, but not zero.

**The `LinkSession.Action.received` signature change ripples to every existing
call site**, production and test. Mechanical, but it is the largest source of
diff volume in the slice and should be sequenced so it lands in one task.

---

## 8. Out of scope

F3, F4, F5, F7, F8 from the handoff. F7 (`linkResourceInFlight` leak) and F8
(TCP `reachableLearned` gate) are adjacent and small, but belong to a different
failure family — reaping and gating rather than authentication — and including
them would blur what this slice proves.
