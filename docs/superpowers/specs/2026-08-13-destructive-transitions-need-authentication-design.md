# Design — a destructive transition requires authenticated, owned input

**Date:** 2026-08-13
**Source:** `docs/superpowers/2026-08-13-unauthenticated-link-element-sweep.md`, items **F12** and **F15**;
handoff `docs/superpowers/2026-08-10-handoff-link-lifecycle-and-delivery-termination.md`.
**Predecessor slice:** `4ef3a21..e2a5848` (closed F1, F2, F6).

---

## 1. The invariant

> **No branch performs a destructive state transition on input it has not
> authenticated and confirmed it owns.** Termination is the armed timer's job,
> not the packet's.

**One honest qualification, stated here rather than buried in §6.** Resource
proofs **cannot** satisfy the authentication half — they are unencrypted by
reference design, so there is nothing to decrypt. For that one context the
invariant degrades to *ownership plus non-destructiveness*: route by ownership
(§3.1) so the right transfer sees it, and never destroy on a bad one (§3.2) so
the outcome is safe even if the ownership discriminator leaks. Do not read §1 as
claiming F15 ends up authenticated. It does not.

F6 established this on the responder RTT path in the previous slice. F12 and F15
are the two known live violations. Three instances of one corrective pattern is
the signal that it is systemic, which is why §5 makes the sweep a planned task
rather than a hope.

"Destructive" means specifically: `.failed`, `.closed`,
`.establishmentFailed`, link-element removal, transfer removal.

---

## 2. F12 — an invalid LRPROOF must not reap our own element

**Where:** `LinkSession.received`, `(.initiator, .pending, .proof, .linkRequestProof)`.

An invalid proof currently emits `.establishmentFailed(.handshakeRejected)`. Two
consequences, and the second is the expensive one:

1. `LinkPlane` removes the element — so one injected packet kills our own
   outbound establishment. `linkID` rides in cleartext and `Transport` routes
   link-addressed packets ahead of `seenPacketHashes`, so anyone who has observed
   one link packet can send it.
2. `.handshakeRejected` is the **PEER-shaped** label — the one reason `LXMFNode`
   answers by retrying the link rather than requesting a path. So the delivery
   budget burns against a route that demonstrably works.

**Change: ignore the packet**, exactly as F6 did on the responder side.

This fixes both halves with one edit. The establishment timer is already armed,
so the element stays reapable and the §1b reapability rule continues to hold; and
the eventual failure now arrives through `establishmentDeadline` as `.timedOut` →
`.establishmentTimedOut`, which is PATH-shaped and correctly triggers a path
request.

**Accepted cost:** a genuinely misbehaving peer now costs a full establishment
timeout where it previously failed fast. This is the same trade F6 already made
and it is the reason the timer exists.

---

## 3. F15 — resource proofs must be routed by ownership, and must never fail a transfer

Two changes. Both are transcriptions of reference behaviour, and neither touches
the wire format.

### 3.1 Route by ownership

**Where:** `LinkSession.received`, the fan-out group ending
`(_, .active, .proof, .resourceProof)`, which currently sends the packet to
**every** transfer on the link.

`Resource.proofData(data:hash:)` is `hash ‖ fullHash(data ‖ hash)`. The leading 32
bytes **are the resource hash** — the discriminator is already on the wire and
simply unused. `Resource.validateProof` examines only `suffix(32)`.

Reference does exactly what we do not. RNS `Link.receive`:

```python
resource_hash = packet.data[0:RNS.Identity.HASHLENGTH//8]
for resource in self.outgoing_resources:
    if resource_hash == resource.hash:
        resource.validate_proof(packet.data)
```

It reads the hash from the leading 32 bytes, routes only to the matching
resource, and scopes to `outgoing_resources` — **sender-role only**. Role scoping
is part of the reference, not an embellishment.

**Change:** deliver a `.resourceProof` only to the sender-role transfer whose
`resourceHash` equals `proofData.prefix(32)`.

### 3.2 Never fail a transfer on a bad proof

**Where:** `ResourceTransfer.received`, `(.sender, .proof, .resourceProof)`.

On mismatch it sets `state.status = .failed` and emits `.delegate(.failed)`.
RNS's `Resource.validate_proof` has **no else branch at all** — a proof that is
the wrong length, or whose trailing 32 bytes do not match, does nothing. The
resource keeps its status and the sender watchdog terminates it.

**Change:** ignore a proof that does not validate.

**Accepted cost:** a genuinely failed transfer now waits for the watchdog rather
than concluding immediately. This is reference behaviour.

### 3.3 Why both, and why this is one omission rather than a design gap

Either change alone closes the non-adversarial bug. Both together are reference
parity, and §3.2 matters independently because §3.1 relies on an attacker not
guessing a resource hash rather than on authentication.

**The house style is already correct in the same file.** Every sibling in the
fan-out group guards with BOTH a decrypt gate and an ownership check against
`state.resourceHash`:

- `(.receiver, .data, .resourceInitiatorCancel)` — `Link.decrypt` + `plain == state.resourceHash`
- `(.sender, .data, .resourceReceiverCancel)` — same
- `(.receiver, .data, .resourceHashmapUpdate)` — `Link.decrypt` + `prefix(32) == state.resourceHash`

`.resourceProof` is the sole outlier, and it is the only one that **cannot** have
a decrypt gate. `Packet.pack` carries a branch dedicated to this exact context —
`elif self.packet_type == Packet.PROOF and self.context == Packet.RESOURCE_PRF:`
→ `self.ciphertext = self.data`, commented *"Resource proofs are not encrypted"*
— alongside a separate one for link proofs generally. Resource proofs are
unencrypted by explicit reference design, which is precisely why RNS routes them
by hash instead of authenticating them. So F15 is one omission against an
established local pattern, and ownership is the only discriminator available.

---

## 4. Testing

Every test gets **one mutation per clause in its name**. A compound name is a
coverage claim, and the previous slice shipped three tests whose names promised
two properties while asserting one.

1. **F12 reap** — inject a bogus LRPROOF at an initiator's `linkID`; the element
   SURVIVES and still establishes when the real proof arrives.
2. **F12 label — a SEPARATE test.** After the injected proof, advance to the
   establishment deadline and assert the failure surfaces as
   `.establishmentTimedOut`, NOT `.handshakeRejected`. This is the expensive half
   of F12; a single test asserting only survival would leave it unpinned, which
   is exactly the defect shape this project keeps paying for.
3. **F15 non-adversarial** — two concurrent SENDER transfers on one link; A's
   valid proof concludes A and leaves B untouched. **This test must fail if the
   fan-out is restored.** It is the half that may already be biting real users.
4. **F15 no-fail** — a proof correctly addressed to A whose trailing 32 bytes do
   not match leaves A alive; the watchdog is what terminates it.
5. **F15 role scoping** — a receiver-role transfer whose `resourceHash` matches
   must not consume a proof.

Then the three-step verification: green → mutate → confirm each targeted test
fails → revert → green.

**TestStore hazards that apply here** (see the recorded traps): effect-produced
state is invisible via `store.state` until drained; under `.off`, `send` silences
and then discards a stray action from the previous send, so proving that transfer
B was NOT touched requires either an `.on` window across the boundary or a direct
state assertion after draining. Test 3 is an absence claim and is therefore the
one most likely to be vacuous — mutate it first.

---

## 5. The sweep

A planned task with a committed artifact, scoped by the **pattern** rather than
by file.

Enumerate every branch in `LinkSession`, `ResourceTransfer` and `Transport` that
performs a destructive transition (§1's list), and classify whether it is
reachable from input lacking **both** an authentication gate and an ownership
check. Output a table: branch (by SYMBOL) → reachable unauthenticated? → owned? →
verdict (safe / fixed here / **open**).

**Why this is not a repeat of the previous sweep.** That one classified by
CREATE / EXTEND / RE-HOME / DESTROY *reachability*. It recorded F15's adversarial
half and never surfaced the non-adversarial one, because "can an attacker reach
this?" is a different question from "does this destroy something without checking
ownership?" — and the answer that mattered came from the second.

This sweep also has a yardstick the previous one lacked: §3.3's sibling branches
define the house style, so any destructive branch missing both gates is an
anomaly to justify or fix.

Write throwaway probes for anything reasoning cannot settle — probes, not
reasoning, found every significant defect in the previous slice. Keep them out of
`Tests/` and leave none behind.

Anything found and not fixed becomes a numbered handoff item (F17 onward — IDs
are stable, do not renumber).

**Verify the artifact's REASSURING sentences first.** Five of the six accuracy
defects in the previous sweep sat in reassuring positions or inside entries whose
job was correcting other claims — the two places a later reader will not
re-derive.

---

## 6. Residual risks

**Role scoping needs one check during implementation:** confirm no legitimate
path delivers a resource proof to a receiver-role transfer. Reference scopes to
`outgoing_resources`, which is strong evidence, but it should be verified against
our own transfer lifecycle rather than assumed.

**Both fixes trade latency for safety.** F12 and F15.2 each replace an immediate
failure with a timer-bounded one. Neither is unbounded — the establishment timer
and the sender watchdog are the terminators — but a failure that used to surface
in one round trip now surfaces on a timeout.

**§3.1 is not an authentication gate.** It relies on an attacker not knowing a
resource hash, which is carried only in an encrypted advertisement. That is
sound, but it is secrecy rather than authentication, and §3.2 is what makes the
outcome safe if the hash ever leaks.

---

## 7. Out of scope

F9, F10, F11, F13, F14, F16 from the handoff. F13 in particular is now
well-specified — reference gates relayed LRPROOFs on interface match, hop count,
and signature validation, none of which we do — but it is gated on relay mode,
which no in-repo composition enables, so it is latent where F12 and F15 are live.
