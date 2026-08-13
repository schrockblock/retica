# Sweep — where unauthenticated input drives link-element lifecycle

**Date:** 2026-08-13
**Slice:** `4ef3a21..034a4c9` (+ this commit)
**Suite:** 824 serially (`swift test --no-parallel`), 1 known issue
(`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`, pre-existing, `TransportTests`).

> **CORRECTED 2026-08-13 by the final whole-branch review over `4ef3a21..86086b0`,
> and by the fix it produced (`381d731`; suite now 826).** Two rows below said the
> wrong thing about the same code, and F14 turned out to be a Critical REGRESSION
> this slice introduced rather than a bounded pre-existing defect. **F14 is now
> CLOSED**; the `.acceptLinkRequest` cap/eviction rows are rewritten; F10 gained a
> half it did not have. Every correction is marked inline as a correction — the
> original claims are left visible, because what they got wrong is the lesson §4 is
> about.

The slice that precedes this document fixed **one instance of each of four verbs**: an element
that died on unauthenticated input (F6), elements that were created in duplicate (F2), elements
that could not be bounded (F1), and a binding that moved on unauthenticated input (F1's link-theft
half). Three instances of a pattern means the pattern is systemic. This is the sweep for the rest.

**Method.** Every branch of `LinkSession`, `LinkPlane` and `Transport` reachable from inbound
network data, classified against four verbs — **CREATE** a link element, **EXTEND** its life,
**RE-HOME** it, **DESTROY** it. Where reasoning could not settle a branch, a throwaway probe was
written in a scratch package outside the repo and deleted afterwards. Probes settled nine
questions; three of them came back the opposite of what reasoning predicted, and the two worst
findings in this document (F13, F14) exist only because a probe was written.

**What counts as a "link element".** Three populations, not one:

- `LinkPlane.State.links` — `LinkSession.State` values.
- `LinkSession.State.transfers` — `ResourceTransfer.State` values.
- `Transport.State.linkTable` — relay routing entries, one per transited link.

The third was outside the previous slice's frame entirely, which is where F13 was hiding.

**What counts as "unauthenticated input".** Bytes an attacker can put on the wire holding no
session key and no private key. Two standing facts make the bar this low, and both are load-bearing
for most rows below:

- `linkID` is the `destinationHash` of every link packet and `Packet.packed()` writes it in
  cleartext, so observing one packet is enough to address a link.
- `Transport.received` returns `.delegate(.linkPacket(...))` for `destinationType == .link` **above**
  the `seenPacketHashes.insert` guard, so replay on the link path is free. `LinkSession` adds no
  dedup of its own — it keeps no inbound packet-hash SET, so nothing there remembers that a packet
  has been seen. (State that precisely. The tempting shorthand — "every `packetHash` use there is
  outbound-keyed" — is FALSE: `(_, .active, .data, .none)` surfaces the INBOUND `packet.packetHash`
  via `.dataReceived(data:packetHash:)`, and `.provePacket(packetHash:)` signs that inbound value.
  Only `pendingDataReceipts` is outbound-keyed. Inbound hashes are computed and used; they are
  never RETAINED for comparison, and retention is the property that matters.)

---

## 1. The table

Verdicts: **safe** — unauthenticated input cannot reach the verb, or reaching it is harmless.
**fixed** — this slice closed it. **deliberate** — reachable, accepted, and pinned by a test.
**OPEN** — reachable, not fixed, carried into the handoff with an F-number.

### `LinkSession.acceptRequest`

| Branch (symbol) | Unauth? | Verb | Verdict |
|---|---|---|---|
| role/status/`owningIdentity` guard → `.none` | no | — | safe. Internal invariant; role and status are locally set. It is the only reap-less exit in the file (every sibling was converted to `.establishmentFailed`), but the element it strands has an empty `linkID` and is therefore unaddressable — see §2. |
| `Packet(raw:)` / `packetType` / payload-size guard → `.establishmentFailed` | yes | DESTROY (self) | safe. Destroys only the element just minted for this request. |
| empty-session-key guard → `.establishmentFailed` | **yes** | DESTROY (self) | safe. Probe-proven remotely reachable: an all-zeros 32-byte X25519 key is a valid 64-byte payload, CryptoKit's `sharedSecretFromKeyAgreement` rejects the point, and `Link.sessionKey` returns `Data()`. Probe confirmed the element IS reaped (`links` → 0) and that `LinkPlane`'s role gate suppresses `linkFailed`. The brief listed this as untested behaviour; it is correct behaviour. **But see F14** — the eviction it triggered upstream was not. Note this guard is also what made F14 look milder than it was: a payload that dies HERE frees its slot again, and F14's probe used one. A payload that does not die here holds the slot instead, which is the difference between "one link per refill" and a flush. |
| `packed()` guard → `.establishmentFailed` | no | DESTROY (self) | safe/defensive. `linkID` is always a 16-byte `truncatedHash` and `buildProof` always returns 99 bytes. |
| success → `.handshake` + establishment timer | yes | CREATE | bounded by `LinkPlane`'s half-open bound (`maxIncompleteResponderLinks`) since `381d731`; by `maxResponderLinks` before that. |

### `LinkSession.received` — pre-dispatch

| Branch (symbol) | Unauth? | Verb | Verdict |
|---|---|---|---|
| `packet.destinationHash == state.linkID` guard | yes | — | safe. Addressing only. An element with an empty `linkID` can never be addressed from the network — see §2. |
| initiator keepalive-echo early return (`payload == [keepaliveByte]`) | yes | — | safe. Drops our own loopback before the re-arm, matching RNS. |

### `LinkSession.received` — `dispatch` branches

| Branch (symbol) | Unauth? | Verb | Verdict |
|---|---|---|---|
| `(.initiator, .pending, .proof, .linkRequestProof)` | **yes** | **DESTROY** | **OPEN — F12.** A garbage proof at our own link's cleartext `linkID` fails `Link.validateProof` and emits `.establishmentFailed(.handshakeRejected)`; `LinkPlane` removes the element and reports `linkFailed(.handshakeRejected)`. Probe-proven: one packet, no crypto, `links` → 0. This is the exact hazard Task 1 fixed on the responder side, still live on the initiator side. |
| `(.initiator, .pending, .proof, .linkRequestProof)` empty-key sub-guard | no | DESTROY | safe. Requires a proof the destination validly signed. |
| `(.responder, .handshake, .data, .linkRequestRTT)` | yes | activate / no-op | **fixed** (F6, Task 1). Decrypt failure now returns `.none` and lets the establishment timer decide. |
| `(_, .active, .data, .none)` | no | — | safe. `authDecrypt` gate; failure is ignored. Replayable (F9). |
| `(_, .active, .data, .linkClose)` | no | DESTROY | safe. Requires decrypt AND `plain == linkID`. Replayable in principle (F9), but the ciphertext only exists once the link is already closing. |
| `(.responder, .active, .data, .keepalive)` | **yes** | EXTEND + reflect | **deliberate.** RNS keepalives are unencrypted by explicit design, so gating this breaks interop, and it bounds nothing — an attacker holding a link holds a session key. Pinned by `plaintextKeepaliveStillRefreshesInactivity`. Reflection (`0xFF` in → `0xFE` out) is unauthenticated. The EXTENSION here is subsumed by F16's broader re-arm, so removing this branch would not change the extension property — but it would remove the `0xFE` liveness answer RNS expects, which is pinned by `responderRepliesToKeepaliveWith0xFE`. The branch is redundant for extension, not redundant overall. |
| `(.initiator, .active, .data, .keepalive)` | **yes** | EXTEND | **deliberate**, same reasoning. |
| `(_, .active, .data, .resourceAdvertisement)` | no (needs the key) | CREATE (transfer) | **OPEN — F11.** Decrypt + unpack + a SAME-hash dedup only; distinct hashes append without bound. Probe: 25 advertisements → 25 transfers. Combined with `LinkPlane`'s `transfers.isEmpty` eviction filter this pins the link and refuses everyone else in. |
| `(_, .active, .data, .resourceRequest \| .resourceHashmapUpdate \| .resourceInitiatorCancel \| .resourceReceiverCancel)` | yes (bytes reach the child) | — | safe. These four `ResourceTransfer` branches each open with `Link.decrypt`, so unauthenticated bytes arrive and nothing acts on them. |
| `(_, .active, .data, .resource)` — the bulk SEGMENT branch | yes (bytes reach the child) | — | **safe, but NOT for the reason the other four are**, and an earlier draft of this row asserted the wrong mechanism for both. `ResourceTransfer.received`'s `(.receiver, .data, .resource)` branch calls **no `Link.decrypt` at all**, and on a match it DOES act: it writes `receivedParts[idx]`, does `outstanding.remove(idx)`, sets `status = .transferring`, sets `receivedFirstPart`/`partTimeoutFactor`, advances `consecutiveCompletedHeight`, and then either arms the receiver watchdog or calls `requestNextWindow`, which transmits. **The actual gate is `Resource.mapHash(chunk:randomHash:)`** — a 4-byte hash of the chunk under `state.randomHash` — looked up in `knownHashmap`, plus a `receivedParts[idx] == nil` per-index dedup. `randomHash` reaches the receiver only inside the advertisement, which IS decrypted, so it is a per-transfer secret an off-link attacker does not hold. Two further nets catch anything that slips through: `Resource.assemble` decrypts the joined stream under the session key, and `Resource.verify` checks `fullHash(data ‖ randomHash) == hash`. **Bounded residual, not promoted to an F-number:** the map hash is 4 bytes, so a blind chunk collides with one of the `N` hashmap entries with probability about `N / 2^32`. A collision poisons that part slot — the `receivedParts[idx] == nil` guard then REJECTS the legitimate part — and the transfer fails at `assemble`/`verify`. That is a transfer-scoped DoS costing on the order of `2^32 / N` packets, which is why it is recorded here rather than ranked. |
| `(_, .active, .data, .resourceProof)` and `(_, .active, .proof, .resourceProof)` | **yes** | **DESTROY (transfer)** | **OPEN — F15.** Fanned out raw to EVERY element of `state.transfers`. `ResourceTransfer`'s `(.sender, .proof, .resourceProof)` branch calls `Resource.validateProof`, which is a plaintext 64-byte equality check on an UNENCRYPTED payload, with no status guard and no check that the proof names this transfer. A non-matching value takes the `else` and sets `.failed`. Probe-proven: one 64-byte junk packet at the cleartext `linkID` emitted `resourceFailed` and removed the transfer. |
| `(_, .active, .data, .response)` | no | — | safe. Decrypt + `pendingRequests` membership. |
| `(_, .active, .data, .linkIdentify)` | no | — | safe. Decrypt + Ed25519 over `linkID ‖ pub`. |
| `(_, .active, .data, .request)` | no | — | safe. Decrypt gate. |
| `(_, .active, .proof, .none)` | no | DESTROY (receipt entry) | safe. Ed25519 against `destinationIdentity`. Note it authenticates WITHOUT `authDecrypt`, so it does not advance `lastData` — harmless, because `destinationIdentity` is written only by the initiator initialiser (verified: two writes in the file, one per initialiser) and only RESPONDER links are ever evicted. |
| `default:` | **yes** | — (but see below) | the branch itself is inert. |

### `LinkSession.received` — post-dispatch (hoisted)

| Branch (symbol) | Unauth? | Verb | Verdict |
|---|---|---|---|
| `guard state.status == .active` → `lastInbound = now` → `inactivityTimer(state.staleTime)` | **yes** | **EXTEND** | **OPEN — F16.** Every `guard … else { return .none }` inside `dispatch` returns from `dispatch`, not from the reducer, so control always reaches the re-arm. **ANY** packet bearing the cleartext `linkID` extends an `.active` link — a failed decrypt, an unhandled context, an 8-byte junk payload. Probe: eight rounds of `0.9 × staleTime` fed only undecryptable `.cacheRequest` packets left the link `.active`; a full `staleTime` of silence closed it. So the keepalive branches are not the extension mechanism — they are redundant with this **for extension only**, and remain load-bearing for the `0xFE` liveness reply. |
| `if sawAuthenticatedData { state.lastData = now }` | no | — | **fixed** (Task 3). Only decrypted traffic advances the eviction clock. |
| re-home block (`sawAuthenticatedData \|\| state.rehomePermitted`) | **yes**, two ways | **RE-HOME** | **fixed with two OPEN residuals — F9 and F10.** (a) `sawAuthenticatedData` proves the packet ORIGINATED from a key holder, not that the sender holds the key, and nothing dedupes inbound link packets — so replaying one captured ciphertext re-homes. (b) `rehomePermitted` is spendable by any interface. |

### `LinkSession` timers and child delegates

| Branch (symbol) | Unauth? | Verb | Verdict |
|---|---|---|---|
| `.establishmentDeadline` | no | DESTROY | safe. Clock-driven; nothing inbound re-arms it, so a `.pending`/`.handshake` element cannot be held past its deadline. |
| `.inactivityDeadline` | no | DESTROY | safe in itself; its firing time is postponed indefinitely by unauthenticated input (F16). |
| `.keepaliveDeadline` | no | — | safe. |
| `.transfer(.element(_, .delegate(.received \| .concluded \| .failed)))` | via F15 | DESTROY (transfer) | the removal is correct; what reaches it unauthenticated is F15. |

### `LinkPlane`

| Branch (symbol) | Unauth? | Verb | Verdict |
|---|---|---|---|
| `.openLink` | no | CREATE | safe. Local. |
| `.acceptLinkRequest` — `Packet(raw:)` guard | yes | — | safe, and stronger than before: unparseable bytes now mint no element at all. |
| `.acceptLinkRequest` — linkID dedupe | yes | prevents duplicate CREATE | **fixed** (F2). Probed against the ordering concern that the guard reads a `linkID` written only by the deferred child action: two identical requests driven back-to-back through a real `Store` with no awaiting produced ONE element. TCA drains the child before the second action is reduced. |
| `.acceptLinkRequest` — half-open bound (`maxIncompleteResponderLinks`) | **yes** | refuses only | **fixed** (F14, `381d731`). This row previously read "cap / eviction … **deliberate** (F1)", on the reasoning that opening a link is unauthenticated by protocol design so only resource policy can bound it. That reasoning is still true, but the verdict was WRONG: what was deliberate was the BOUND, not the eviction that paid for it, and the two were in the same branch. Unauthenticated input now spends only this budget and evicts nothing; when it is full the request is refused. (The batch-overshoot probe that supported the old row still holds: three requests driven with no draining at a bound of two leave the count at two.) |
| `.acceptLinkRequest` — eviction is emitted BEFORE the request is validated | **yes** | **DESTROY** | **CLOSED (`381d731`) — was F14, and was UNDERSTATED here.** The probe behind this row used an ALL-ZEROS X25519 key, which self-destructs at the empty-session-key guard and frees its slot again, so the harm looked like one link per refill. A payload of RANDOM bytes does not self-destruct: `Link.sessionKey` succeeds on it, so the element reaches `.handshake`, which is not evictable and holds the freed slot for a full establishment timeout. Probed through production wiring at a cap of four: **zero of four** established links survived four junk requests, and everything behind them was refused. Fixed by moving the eviction to promotion; see F14 in the handoff. |
| `.acceptLinkRequest` — refusal when the half-open budget is full | yes | refuses | safe as a bound on `links`. Availability cost: new inbound establishment is denied for the length of an establishment timeout. **Correction:** the earlier version of this row attributed the cost to "F11's payload", which is incomplete — the identical refusal-DoS needs no session key and no transfer at all. Anyone who can put well-formed LINKREQUESTs on the wire can hold the budget full, and F11 is only the variant that does it with links that never self-clear. |
| `.link(… .delegate(.established))` — active-responder cap / eviction | no | **DESTROY** | **deliberate** (F1), and this is where the eviction lives since `381d731`. Reached only after a peer decrypted the LRRTT under the session key, so the party that costs an incumbent its slot has demonstrably completed a handshake. Same policy as before (responder-only, `lastData` LRU, skip in-flight transfers, close via `.close`), plus: the promoted element is excluded by id, and when nothing is evictable the promotion itself is refused rather than the population growing. |
| `.routeLinkPacket` | yes | — | safe. Addressing only; the re-home decision moved into `LinkSession` in Task 5. |
| `.interfaceDisconnected` | trigger no, consumption **yes** | RE-HOME | **OPEN — F10.** It issues the grant to INITIATOR links as well as responder ones, so after any local disconnect one unauthenticated packet from a foreign interface re-homes a link WE opened. Left as-is deliberately: our outbound links go stale on the same event, their peer never initiates a keepalive, and a peer mid-transfer to us sends only segments, which never set `sawAuthenticatedData` — so restricting the grant to responders would strand them until timeout. Reasoning recorded at the branch; pinned by the initiator phase of `theReHomeGrantIsSpentByWhicheverInterfaceSpeaksFirst`. |
| `.link(… .delegate(.closed))` → `links.remove` | via cap only | DESTROY | safe. Reached from authenticated LINKCLOSE, local close, eviction, or a timer. |
| `.link(… .delegate(.establishmentFailed))` → `links.remove` | **yes**, via F12 | DESTROY | the removal is correct; what reaches it unauthenticated is F12. |
| `.link(… .delegate(.rehomed))` → rebind transfers | **yes**, via F9/F10 | RE-HOME | downstream of the re-home block. |
| `.link(… .delegate(.requestReceived))` → `requestResponder` | no | — | safe. Requires an authenticated `.request`, then `registrations` + `isAllowed`. |
| every `sendOverLink` / `closeLink` / … `first(where:)` handler | no | — | safe. Local callers only. `closeLink` on a non-`.active` element is a silent no-op — see §2. |

### `Transport.received`

| Branch (symbol) | Unauth? | Verb | Verdict |
|---|---|---|---|
| IFAC unmask / plain-interface flag guard | yes | — | safe. |
| `destinationType == .link` + `linkTable` hit → forward, `refreshedAt = date.now` | **yes** | **EXTEND** + **shadow** | **OPEN — F13.** |
| `destinationType == .link`, no `linkTable` hit → `.delegate(.linkPacket)` | **yes** | gateway | **deliberate**, and the mechanism behind F9. Sits above `seenPacketHashes` on purpose: byte-identical keepalives share a packet hash and must not be deduped. Pinned by `identicalLinkPacketsBypassDedup`. |
| `packetType == .linkRequest` + local destination → `.delegate(.linkRequest)` | **yes** | CREATE (at the plane) | bounded by the plane's half-open bound. Also above `seenPacketHashes`, which is why the plane's own dedupe had to exist. |
| `case .linkRequest:` relay branch → `linkTable[linkID] = …` | **yes** | **CREATE** | **OPEN — F13.** |
| `case .data:` relay / local delivery | no | — | safe. Local delivery requires `destination.decrypt`. |
| `case .announce:` and the ingress-control machinery | yes | — | touches no link element. `learned` entries do gate F13's relay branch. |
| `.maintenanceTick` → `linkTable` GC at `linkTableExpiry` | no | DESTROY | correct, and defeated by F13's refresh. |
| `setTransportIdentity(nil)` — the `guard identity == nil else { return .none }` branch → `linkTable = [:]` | no | DESTROY | safe. (There is no `stopRelaying` symbol in this repo; an earlier draft of this row invented one, against this document's own cite-symbols convention.) |

---

## 2. Two questions the brief asked, settled

**`LinkSession.acceptRequest`'s empty-session-key guard.** Remotely reachable, exactly as suspected —
an all-zeros 32-byte X25519 public key is a well-formed 64-byte payload that passes the size guard,
and `Link.sessionKey` returns `Data()` because CryptoKit rejects the point. The element-reaping
behaviour, which the brief flagged as untested, is **correct**: the element is removed and no
`linkFailed` escapes. What was NOT correct is what happened one layer up when this fired at the cap —
that was F14, and it was invisible until the two were probed together. **Correction:** choosing this
key for the probe is also what made F14 look bounded. It is the one junk payload that frees its own
slot; a random one does not, and the real harm was a flush. See F14 in the handoff.

**`LinkSession.close` on a non-`.active` element.** Confirmed a silent no-op (`guard state.status ==
.active else { return .none }`); a `.pending`/`.handshake` element leaves only at its establishment
deadline. This is what forces `acceptLinkRequest` to REFUSE rather than try to make room: there is
nothing there to close. Since `381d731` the half-open population is bounded by
`maxIncompleteResponderLinks` on exactly that reasoning. The cost is an availability window of one
establishment timeout, which self-clears — unlike F11, which does not.

**Can an element with an empty `linkID` be addressed?** No. `Packet.init?(raw:)` always yields a
16-byte `destinationHash`, `Transport` passes that same value as `.linkPacket(linkID:)`,
`LinkPlane.routeLinkPacket` matches on it, and `LinkSession.received` re-checks it. Three
independent checks, none of which an empty `linkID` can satisfy. This is what makes
`acceptRequest`'s first guard harmless despite being the file's only reap-less exit.

---

## 3. New OPEN items

Numbered continuing from the handoff. Full write-ups live there; this is the sweep's summary.

- **F9** — no per-packet replay rejection anywhere on the link path. Narrows Task 5's re-home gate
  from "closed" to "costs one captured ciphertext".
- **F10** — the local-disconnect re-home grant is spent by whichever interface speaks first, on
  INITIATOR links as well as responder ones.
- **F11** — advertise-and-stall pins a link against eviction and locks everyone else out.
- **F12** — one injected packet kills a legitimate OUTBOUND establishment
  (`(.initiator, .pending, .proof, .linkRequestProof)`). The initiator-side mirror of F6.
- **F13** — a reflected LINKREQUEST creates a relay `linkTable` entry that SHADOWS one of our own
  links, and unauthenticated traffic refreshes `linkTable` entries forever.
- **F14** — the responder cap evicts before it validates. **CLOSED in `381d731`**, after the final
  whole-branch review showed this entry had both understated it (the harm is a flush, not one link
  per refill) and prescribed a fix that would not have worked (a random payload passes every
  validation `acceptRequest` performs).
- **F15** — an unauthenticated RESOURCE_PRF destroys every sender transfer on a link.
- **F16** — the hoisted inactivity re-arm fires for ANY link-addressed packet, so extension is not
  a keepalive property and F10's exposure is not bounded by the watchdog.

**Priority.** F13 first — it is the only one that redirects a legitimate peer's traffic to an
attacker rather than merely denying service, and it is one packet. Then F12 (one packet, kills an
outbound link, mislabels the failure as PEER-shaped so the delivery layer burns its whole budget
retrying the same path). Then F15 (one packet, aborts transfers; and it fires between two of our own
concurrent transfers with no attacker present). Then F11, F16, F9, F10. (F14 was ranked here and is
now closed.)

**F13 is gated on relay mode.** It requires `transportIdentity != nil`, set only via
`TCPEndpoint.enableRelay` / `BLEEndpoint.enableRelay`. Neither has an in-repo caller, so this is a
latent hazard for relay deployments rather than a live defect in any composition that ships today.
It is still ranked first because its consequence is the most severe of anything here and because
enabling relay mode is a one-line decision an integrator can make without reading this document.

**F15 has a non-adversarial trigger, which is the stronger argument for fixing it.** The branch has
no check that the proof belongs to the transfer it is being delivered to, and `LinkSession` fans
every RESOURCE_PRF out to every transfer. Two concurrent sender transfers on one link therefore
destroy each other: the genuine proof for A takes the `else` in B.

---

## 4. Method notes

**Probes changed three answers.** Reasoning said the all-zeros LINKREQUEST would leak an element
(it does not); that the cap could be overshot by a batch (it cannot); and that the linkID dedupe
had a drain-ordering hole (it does not). Reasoning also did not produce F13 or F14 at all — both
needed two mechanisms composed, and both were found by pointing a probe at the seam between them.

**The independent enumeration pass earned its cost and had to be checked.** A second reader,
given the eight things already known and asked what was missing, returned F12, F13 and F15 —
the three highest-priority items here. It also returned one claim that reads plausibly and is
false: that `(_, .active, .proof, .none)` authenticating without advancing `lastData` mis-targets
the eviction LRU. It cannot, because that branch requires `destinationIdentity`, which only the
initiator initialiser writes, and only responder links are evicted. That is the §6 failure shape
exactly — every node correct, one arrow wrong — and it is the reason nothing from that pass was
recorded here without a probe or a repo-wide grep behind it.

**Cite symbols, not line numbers, and do not encode derived arithmetic.** Both conventions held
through this document with one lapse, caught on review: an earlier draft cited a `.stopRelaying`
action that does not exist in this repo. The real site is the `identity == nil` branch of
`setTransportIdentity`. Inventing a plausible symbol name is a failure mode the convention was
supposed to prevent, and it is harder to spot than a drifted line number because it reads right.

**The false claims that survived to review were all in "safe" and "corrects X" positions.** Six
accuracy defects were found after this document was first committed. Their distribution is the
lesson, not their count:

- Two were **inside entries whose job is to correct other claims** — the F16 entry, which exists to
  correct F1, itself overstated the correction ("removing the keepalive branches would change
  nothing" — false; they also emit the `0xFE` liveness reply, pinned by a test in the suite); and
  F1's own CLOSED banner said the link-theft half was "closed" three paragraphs before pointing at
  the two residuals that make it merely narrowed.
- One was **the justification behind a `safe` verdict**: the resource-segment row claimed every
  child branch gates on `Link.decrypt`. The bulk `(.receiver, .data, .resource)` branch calls no
  `Link.decrypt` at all and DOES act on a match. The verdict survives, but on a completely
  different mechanism (`Resource.mapHash` under the advertisement's secret `randomHash`).
- Two were **stable-ID mis-citations** (F12 written where F16 was meant), which is the worst kind
  of typo in a document whose IDs are its routing.
- One was **a shorthand that overreached** ("every `packetHash` use is outbound-keyed").

**A `safe` row and a "this corrects X" paragraph are the two places a wrong arrow does the most
damage,** because both are exactly what a later reader will NOT re-derive — one because it is
marked as nothing to worry about, the other because it is marked as the already-corrected version.
Every such claim in this document has now been re-checked against the code. Apply that ordering to
the next sweep: verify the reassuring sentences first.

**The final whole-branch review then produced the lesson AGAIN, one level up.** Six of its findings
were false claims, and five sat in reassuring or "this-corrects-X" positions — including inside this
very section's corrections. The two that mattered were both attached to F14: its severity sentence
("one legitimate link per refill rather than a flush") and its prescribed fix ("validate enough of
the request to know it can become an element"). Both read as the calm, already-handled part of an
entry whose alarming half was correct, and both were wrong, and the second would have persuaded an
implementer that they had fixed something they had not.

**The mechanism behind both is worth naming, because it is not carelessness.** Each was a
generalisation from ONE probe input. The F14 probe used an all-zeros X25519 key; that key is
unrepresentative in the exact dimension the severity claim turned on, because it self-destructs at
the empty-session-key guard and frees the slot again. A random key does not, and the harm is a
flush. **When a probe's result becomes a severity claim, ask what about that specific INPUT the
claim depends on** — and probe a second input chosen to differ in that dimension. That is cheaper
than the review round it saves.
