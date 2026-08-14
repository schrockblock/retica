# Sweep — where inbound data destroys state without checking that it owns it

**Date:** 2026-08-13
**Slice:** `892652a..a4b5e21` (+ this commit)
**Suite:** 835 serially (`swift test --no-parallel`), 1 known issue — 834 at the slice's last code
commit, plus the one characterization test this document's row-34 ruling required (see §4).
(`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`, pre-existing, `TransportTests`).

## Why this is not the previous sweep again

`docs/superpowers/2026-08-13-unauthenticated-link-element-sweep.md` classified branches by
**reachability**: can unauthenticated input CREATE / EXTEND / RE-HOME / DESTROY a link element?
That framing found F15's adversarial half — one injected `RESOURCE_PRF` kills a transfer — and
missed the non-adversarial half entirely: **two of our own concurrent sender transfers destroying
each other, with no attacker anywhere.** It missed it because "can an attacker reach this?" and
"does this destroy something without checking that the input belongs to it?" are different
questions, and only the second one sees a defect whose two parties are both ours.

This document asks the second question. Every branch of `LinkSession`, `ResourceTransfer` and
`Transport` reachable from inbound network data that performs a **destructive** transition —
`.failed`, `.closed`, `.establishmentFailed`, link-element removal, transfer removal — classified
on two axes:

- **AUTH** — is it behind a successful `Link.decrypt` / `authDecrypt`, or another cryptographic
  check (an Ed25519 validation counts, and is stronger)?
- **OWN** — does it check that the input names *this* object: `resourceHash`, `linkID`, a
  membership test in `pendingRequests` / `pendingDataReceipts`, or the element id?

`LinkPlane` is included even though the brief scoped three files, because link-element removal
happens there and nowhere else: `LinkSession` emits `.closed` / `.establishmentFailed` and
`LinkPlane` is the only code that calls `links.remove`.

**Scope note.** Four smaller removals are included alongside the five named verbs —
`pendingRequests`, `pendingDataReceipts`, `incomingSegments`, `segmentedSend`. They are the same
verb one scope down (they terminate a pending operation), and one of them is how a defect in the
`ResourceTransfer` layer propagates upward into a `requestFailed`. Leaving them out is how the
previous sweep's frame lost half of F15.

## The yardstick

Three branches already do it correctly, and they are the standard every other row is compared to:

| house-style branch | AUTH | OWN |
|---|---|---|
| `(.receiver, .data, .resourceInitiatorCancel)` | `Link.decrypt` | `plain == state.resourceHash` |
| `(.sender, .data, .resourceReceiverCancel)` | `Link.decrypt` | `plain == state.resourceHash` |
| `(.receiver, .data, .resourceHashmapUpdate)` | `Link.decrypt` | `prefix(32) == state.resourceHash` |

**Two gates, and they do different jobs — this is the structural point of the whole sweep.**
`Link.decrypt` keeps an OFF-LINK party out. It does **not** discriminate between two objects on the
same link, because every `ResourceTransfer` hosted by a `LinkSession` is constructed with that
session's `sessionKey`. Probe P4: transfer B decrypts a genuine `RESOURCE_REQ` addressed to
transfer A's resource without difficulty, and the only thing that stops B acting on it is the
`state.resourceHash` comparison. So for anything fanned out to every transfer, **AUTH bounds the
attacker set and OWN bounds the blast radius, and a branch with only AUTH is exactly the shape that
lets our own objects destroy each other.** That is what F15 was.

`.resourceProof` legitimately cannot have an AUTH gate at all: resource proofs are unencrypted by
explicit reference design (`Packet.pack` has a branch dedicated to `RESOURCE_PRF`), so ownership
routing plus non-destructiveness is the only defence available to it. Both landed in this slice.

**Method.** Reasoning where the code settles it, probes where it does not. Probes lived in a
scratch SwiftPM package outside the repo (`/tmp/ReTiCA/probe5`) and are deleted; each is cited as
**P1**–**P10** below with what it showed.

---

## 1. `ResourceTransfer.received` and its timers

| # | Branch (symbol) | AUTH | OWN | Verdict |
|---|---|---|---|---|
| 1 | `(.sender, .data, .resourceRequest)` — HMU sequencing error → `.failed` + initiator-cancel + `.delegate(.failed)` | **yes** — `Link.decrypt` | **yes** — the `p[pad ..< pad+32] == state.resourceHash` guard precedes the whole branch, so the failure exit is behind it too | **safe.** P10: the same HMU request naming transfer A's hash, handed to B, leaves B byte-identical; unencrypted, it leaves even the named transfer byte-identical. |
| 2 | `(.receiver, .data, .resource)` — four `.failed` exits (short/failed `Resource.assemble`, oversized `adv.dataSize`, failed `Bzip2.decompress`, failed `Resource.verify`) | **no** — this branch calls no `Link.decrypt` | **partial** — `Resource.mapHash(chunk:randomHash:)` looked up in `knownHashmap`, i.e. a hash of width `Resource.mapHashLength` under the per-transfer `randomHash` | **OPEN — F17.** See §5. |
| 3 | `(.receiver, .data, .resourceInitiatorCancel)` → `.failed` | **yes** | **yes** | **safe** — house style. |
| 4 | `(.sender, .data, .resourceReceiverCancel)` → `.failed` | **yes** | **yes** | **safe** — house style. |
| 5 | `(.sender, .proof, .resourceProof)` | **impossible** — unencrypted by reference design | **yes, enforced upstream** — `LinkSession` routes on `prefix(32) == resourceHash` and `role == .sender` | **fixed in this slice.** Routing `d0570ef`, non-destructiveness `0101a74`. P6: a junk 64-byte proof at the cleartext `linkID` leaves both seeded senders present and `.idle`; B's genuine proof handed directly to A leaves A byte-identical. |
| 6 | `.receiverDeadline` — `retriesLeft == 0` → `.failed` + receiver-cancel | clock | n/a | **safe**, with one qualification worth stating rather than eliding: an inbound part is not inert to the timer. The first accepted part sets `receivedFirstPart` and drops `partTimeoutFactor` to `Const.partTimeoutFactorAfterRTT`, shortening every subsequent watchdog. That ACCELERATES the deadline; it does not reach the failure exit, which needs `retriesLeft` to reach zero. Note what does and does not reset that counter, because the tempting shorthand is wrong: `retriesLeft = Const.maxRetries` is written by `.accept` and by the COMPLETED-ROUND branch (`outstanding.isEmpty` with parts still outstanding overall), NOT by every accepted part. A part that completes no round leaves the counter where it was. |
| 7 | `.senderDeadline` `.advertised` — advert retries exhausted, or `linkPacket` returns nil → `.failed` | clock | n/a | **safe.** |
| 8 | `.senderDeadline` `.transferring` → `.failed` | clock | n/a | **safe.** Entering `.transferring` requires row 1's two gates, so the window length is not settable by an unauthenticated party. |
| 9 | `.senderDeadline` `.awaitingProof` — proof retries exhausted → `.failed` | clock | n/a | **safe, and load-bearing after this slice.** Since `0101a74` this is the only SELF-terminator for a sender whose proof never validates, which is deliberate: reference `Resource.validate_proof` has no else branch and lets the sender watchdog decide. It is not the only terminator — the peer can still cancel explicitly via row 4, and a host can via row 10. |
| 10 | `.cancel` → `.failed` | local action | n/a | **safe.** No emitter in `Sources` — it is a host-facing command, exercised only by tests today. |

## 2. `LinkSession`

### 2a. Establishment

| # | Branch (symbol) | AUTH | OWN | Verdict |
|---|---|---|---|---|
| 11 | `.establish` — `packed()` guard → `.establishmentFailed(.handshakeRejected)` | n/a — local action | n/a | **safe/defensive.** Destroys only the element the local caller just created. |
| 12 | `.acceptRequest` — `Packet(raw:)` / `packetType` / payload-size guard → `.establishmentFailed` | **no** | **n/a, and that is fine** — this destroys ONLY the element minted for this very request. Verified structurally: `.acceptRequest` has exactly one emitter in `Sources`, `LinkPlane.acceptLinkRequest`, which appends the element and dispatches to that new id in the same branch | **safe.** |
| 13 | `.acceptRequest` — empty-session-key guard → `.establishmentFailed` | no | same | **safe**, same reason. |
| 14 | `.acceptRequest` — `packed()` guard → `.establishmentFailed` | no | same | **safe/defensive.** |
| 15 | `.acceptRequest` — role/status/`owningIdentity` guard → `.none` | no | n/a | **safe** and non-destructive. The file's only reap-less exit; harmless because the element it strands has an empty `linkID` and is therefore unaddressable from the network (three independent checks, unchanged since the previous sweep). |
| 16 | `(.initiator, .pending, .proof, .linkRequestProof)` — proof that does not validate | **yes, and the strongest in the file** — `Link.validateProof` is an Ed25519 validation against `destinationIdentity`, not a decrypt | **yes** — `linkID` | **fixed in this slice (F12), `bd5dd7f`.** It used to emit `.establishmentFailed(.handshakeRejected)` on failure, which reaped our own outbound element AND mislabelled the failure PEER-shaped. Now `.none`; the already-armed establishment timer decides, and the failure arrives as `.timedOut`. P9: a junk 99-byte proof leaves the element byte-identical and `.pending`. |
| 17 | `(.responder, .handshake, .data, .linkRequestRTT)` — decrypt/decode failure | **yes** — `authDecrypt` | **yes** — `linkID` | **safe**; fixed earlier as F6 (`331843a`). Failure is `.none`, not a reap. |

### 2b. Active-link destructive branches

| # | Branch (symbol) | AUTH | OWN | Verdict |
|---|---|---|---|---|
| 18 | `(_, .active, .data, .linkClose)` → `.closed` + `cancelAll` + `cancelPending`, and thence `links.remove` | **yes** — `authDecrypt` | **yes** — `plain == state.linkID` | **safe** — house style, applied to a link instead of a transfer. P8, three inputs: a plaintext `linkID` payload leaves the link `.active`; a correctly encrypted but WRONG `linkID` leaves it `.active`; only the encrypted correct one closes it. Both gates are independently load-bearing. Residual F9 (replay) applies in principle, but the only ciphertext that satisfies it is one the peer emitted to close the link, by which point the link is closing anyway. |
| 19 | `(_, .active, .data, .response)` → `pendingRequests.remove` + `.cancel(request)` | **yes** — `authDecrypt` | **yes** — `state.pendingRequests.contains(requestID)` | **safe.** |
| 20 | `(_, .active, .proof, .none)` → `pendingDataReceipts[proofHash] = nil` + `.cancel(receipt)` | **yes**, but NOT via `authDecrypt` — Ed25519 against `destinationIdentity` | **yes** — `pendingDataReceipts[proofHash]` membership | **safe.** It authenticates without advancing `lastData`, which is harmless: re-verified for this sweep that `state.destinationIdentity` has exactly two writes repo-wide, both in `LinkSession.State`'s initialisers (the initiator one sets it, the responder one nils it), and nothing in `Sources` assigns it afterwards — so this branch is initiator-only, while only RESPONDER links are ever evicted. |
| 21 | `(_, .active, .data, .resourceProof)` / `(_, .active, .proof, .resourceProof)` — the routing branch | **impossible** | **yes** — `payload.count >= 32`, then `prefix(32) == $0.resourceHash` and `$0.role == .sender` | **fixed in this slice (F15), `d0570ef`.** The routing is the ownership gate that row 5 depends on. |

### 2c. Timers and local commands

| # | Branch (symbol) | AUTH | OWN | Verdict |
|---|---|---|---|---|
| 22 | `.establishmentDeadline` → `.establishmentFailed(.timedOut)` (initiator) / `.closed(.timedOut)` (responder) | clock | n/a | **safe.** Nothing inbound re-arms it — the re-arm hoisted below `dispatch` is the INACTIVITY timer, on a different `CancelID`. |
| 23 | `.inactivityDeadline` → `.closed(.timedOut)` | clock | n/a | **safe in itself.** Postponed indefinitely by unauthenticated input (F16), never accelerated by it. |
| 24 | `.requestDeadline` → `pendingRequests.remove` + `requestFailed` | clock | membership | **safe.** |
| 25 | `.dataProofDeadline` → `pendingDataReceipts` removal + `packetDeliveryFailed` | clock | membership | **safe.** |
| 26 | `.close` → `.closed` | local | n/a | **safe.** |

### 2d. Child delegates — where transfers are removed

| # | Branch (symbol) | AUTH | OWN | Verdict |
|---|---|---|---|---|
| 27 | `.transfer(… .delegate(.received))` → `transfers.remove(id:)` | n/a | **yes** — `elementID` | **safe.** Reached only after the child completed `Resource.assemble` under the session key AND `Resource.verify`. |
| 28 | `.transfer(… .delegate(.concluded))` → `transfers.remove(id:)`, and `segmentedSend = nil` on the last segment | n/a | **yes** — `elementID`, plus `send.currentTransferID == elementID` for the segmented half | **safe.** |
| 29 | `.transfer(… .delegate(.failed))` → `transfers.remove(id:)`, `pendingRequests.remove(rid)`, `segmentedSend = nil`, `incomingSegments[a.originalHash] = nil` | n/a | **mixed** — `elementID` and `currentTransferID` are sound; `advertisement.requestID` and `advertisement.originalHash` are WIRE-DERIVED for a receiver-role transfer and length-unvalidated | **safe, but NOT for the reason an earlier draft gave** — read the correction below the table before trusting this row. The gate is `state.pendingRequests.contains(rid)` in THIS handler; the bound is that `pendingRequests` is per-`LinkSession`. `originalHash` (`o`) is checked against nothing, so two advertisements from one peer may share an accumulator — that needs the session key, so a peer can only disrupt its own delivery. Folded into **F18**. This handler is also the amplifier for F17: a poisoned RESPONSE receiver fails here and takes a legitimate `requestFailed` with it. |

**Correction to row 29 — the kind this document exists to catch.** An earlier draft justified the
`safe` verdict with: *"`requestID` is safe because the `.resourceAdvertisement` branch only accepts a
response-Resource whose `q` is already in `pendingRequests`."* **That gate is real but it sits INSIDE
`if adv.isResponse`.** An advertisement with NEITHER the request nor the response flag set, carrying
`q` = a live pending requestID, sails straight past it. Probed end to end: the transfer is created,
`.accept` populates `advertisement.requestID` with the borrowed id, and the transfer's
`.delegate(.failed)` then removes that id from `pendingRequests` and emits `requestFailed`.

The verdict survives, on a different mechanism. **The actual gate is this handler's own
`state.pendingRequests.contains(rid)`**, and the actual bound is that `pendingRequests` is
per-`LinkSession` state whose only INSERT sites are `.sendRequest`'s two branches — so a peer holding
the session key can cancel only requests WE SENT TO THAT PEER, which it could equally well just
refuse to answer. (Say "inserted", not "written": `pendingRequests` has six other write sites in the
file — `cancelPending`'s `removeAll`, the `.response` branch, `.requestDeadline`,
`.transfer(… .delegate(.received))`'s response branch, and this handler — all of them REMOVALS. Only
the two inserts decide what can ever be cancelled.)

Control: with the id absent from `pendingRequests`, no request is cancelled and no `requestFailed`
is emitted. **Not "nothing is emitted" — an earlier version of this paragraph said that and it is
false.** Execution falls past the membership branch, past the `isRequest`/`isResponse` early return
(neither flag is set, so it does not fire), past the `segmentedSend` and `isSplit` branches, and
reaches `return .send(.delegate(.resourceFailed(hash)))`. The transfer still reports its own failure;
what the membership test gates is specifically the request cancellation.

Stating it the old way was worse than saying nothing: it pointed a future reader at a gate that does
not cover the case, and would have survived deleting the one that does.

**Reference nests this the same way — and still does not have our defect, which locates it
precisely.** RNS's `RESOURCE_ADV` branch reads `read_request_id` and matches it against
`pending_requests` inside `elif RNS.ResourceAdvertisement.is_response(packet)`, exactly the nesting
that lets a neither-flag advertisement past. But on its non-request/non-response paths reference
calls `RNS.Resource.accept(packet, callback)` **without** `request_id=`, so a borrowed id is never
bound to a plain resource in the first place. Our divergence is not the nesting: it is that
`.resourceAdvertisement` stores `q` on the transfer regardless of flags and
`.transfer(… .delegate(.failed))` reads it back unconditionally.

## 3. `LinkPlane` — the only place a link element is removed

| # | Branch (symbol) | AUTH | OWN | Verdict |
|---|---|---|---|---|
| 30 | `.link(… .delegate(.closed))` → `links.remove` | inherited | **yes** — `elementID` | **safe.** |
| 31 | `.link(… .delegate(.establishmentFailed))` → `links.remove` | inherited | **yes** — `elementID` | **safe.** The removal was always correct; what reached it unauthenticated was F12, closed in this slice. |
| 32 | `.link(… .delegate(.established))` → closes OTHER links to enforce `maxResponderLinks` | **yes** — promotion requires the peer to have decrypted the LRRTT | **none, deliberately** | **deliberate (F1).** The one destructive branch in the repo that intentionally destroys something the input does not own. It is priced: responder-only, `lastData` LRU, in-flight transfers skipped, the promoted element excluded by id, and refusal rather than growth when nothing is evictable. |
| 33 | `.acceptLinkRequest` — linkID dedupe and the half-open bound | no | n/a | **safe** — both REFUSE; neither destroys. That was the F14 fix. |

## 4. `Transport`

`Transport` holds no `.failed` / `.closed` status and no link elements, so nothing here is
destructive under the brief's five verbs. The nearest analogues, enumerated so the next reader does
not have to re-derive that:

| # | Branch (symbol) | AUTH | OWN | Verdict |
|---|---|---|---|---|
| 34 | `.maintenanceTick` — GC of `learned`, `announceBlobs`, `announceCache`, `linkTable`, `discoveryPathRequests`, `pathRequests`, `announceQueues` | clock | keyed | **safe, and INTENDED — but the obvious universal is false.** Inbound data CAN shorten the time to a `learned` GC; see the ruling below the table. |
| 35 | `case .announce:` replay-suppression branch → `announceTable[dest] = nil` + `.cancel(announceRetransmit)` | **partial** — `Announce.parse` validates the destination's Ed25519 signature and re-derives `destinationHash` from `nameHash ‖ identity.hash`, but REPLAYING a genuine announce needs no key | **yes** — keyed by `destinationHash`, and additionally requires `transportId != nil` and a `rebroadcastHops` match | **deliberate.** This is RNS's collaborative suppression (Transport.py:1774-1791) and what it destroys is our own pending re-broadcast, not anyone else's state. Bounded: the cancelling paths both require `entry.rebroadcasts >= 1`, so nothing can be suppressed before the retransmit timer has fired at least once. (Precisely that, NOT "before we have broadcast at least once" — `entry.rebroadcasts += 1` sits outside the `eligible` loop in `.announceRetransmitDue` and increments even when no interface was eligible and nothing was sent.) |
| 36 | `case .announce:` ingress hold → `held[destinationHash] = …` replaces an existing held announce | same as 35 | keyed by `destinationHash` | **safe.** Reference `hold_announce` (Interface.py:223-229); bounded by `maxHeldAnnounces`. |
| 37 | `.interfaceDisconnected`, `.announceQueueDrainDue` interface-vanished branch, `.announceRetransmitDue` lifecycle-complete branch | local / clock | keyed | **safe.** |
| 37b | `setTransportIdentity(nil)` → `announceTable = [:]`, `linkTable = [:]`, `discoveryPathRequests = [:]` | n/a | **none — three WHOLESALE wipes**, including every transited link's routing state | **safe because it is UNREACHABLE from production, which is stronger than "the trigger is local" and also a latent trap.** See the note below the table. |
| 38 | `seenPacketHashes` ring eviction under load | no | n/a | **outside the verb set, recorded anyway.** An unauthenticated flood evicts dedup memory, which re-enables replay of an evicted packet. Pinned by `seenPacketRingEvictsOldestAndReDeliversIt`; the ring is deliberately sized for this (`seenPacketRingSize`). Not a destructive transition, but it is the one place in `Transport` where unauthenticated volume erases state that a security property rests on. |

**Note on row 37b, where two successive drafts both understated the verdict.** The first called the
three wipes "keyed", which they are not — they are the least discriminating destructive action in the
file. The second said the `safe` verdict "rests entirely on the TRIGGER being local", and added that
"dropping relay state on leaving relay mode is the point". Also wrong, and in the more interesting
direction: **leaving relay mode is a transition no production code can perform.**
`Transport.Action.setTransportIdentity` takes an `Identity?`, but every emitter reaches it through an
`enableRelay(Identity)` case — `TCPEndpoint`, `BLEEndpoint` and `TransportEndpoint` all declare the
payload NON-optional — so those sends can only ever produce `.some`. There is no `disableRelay`
action and no literal `setTransportIdentity(nil)` anywhere in `Sources`.

So the accurate verdict is: **the `nil` branch has no production emitter at all.** It is reachable
only from a test or a future caller. That is safer than "local trigger" today and worse tomorrow —
whoever adds the `disableRelay` this API obviously implies will silently enable three unguarded
wholesale wipes, including every transited link's routing state, and nothing in the suite is watching
that seam. Recorded here rather than numbered because an unreachable branch performs none of the five
verbs; it belongs with whoever implements relay teardown.

**Ruling on row 34: the mode re-class is INTENDED, and the universal an earlier draft carried
("nothing inbound makes any of them fire early") is FALSE.** Both halves matter, so both are stated.

*The mechanism, probe-confirmed in two halves.* The `learned` sweep predicate is
`pathExpiry(forMode: state.interfaces[entry.interfaceID]?.mode)` — it looks the mode up at GC time
rather than storing it. And `case .announce:` replaces the WHOLE `LearnedDestination`, `interfaceID`
included, whenever `Transport.shouldReplace` says so — and `shouldReplace` compares only
`announceEmitted` and `hops`, so it is mode-blind. Probe (a): with the entry seeded, a `.full`
binding survives a tick at an age a `.roaming` binding does not. Probe (b): a genuine newer announce
arriving on a roaming interface moves a full-learned entry's `interfaceID` to the roaming one, resets
`learnedAt`, and the entry is then GC'd at the roaming lifetime. The same loop also nils
`announceBlobs[dest]`, the per-destination announce anti-replay ring.

*Why INTENDED rather than a finding.* The entry after the replacement genuinely IS a roaming path —
`Transport.send` transmits on `entry.interfaceID`, which now names the roaming interface, so the
route really does run over it. Classifying it by the mode it actually rides is the whole purpose of
`pathExpiry(forMode:)` (RNS `ROAMING_PATH_TIME` / `AP_PATH_TIME`), and the function's own doc comment
shows the lookup-at-GC-time behaviour was chosen deliberately: it reasons explicitly about the `nil`
case and elects to fall back to the 7-day default "rather than expiring early". Nothing is truncated
mid-life either — the replacement resets `learnedAt`, so the entry gets a FULL roaming lifetime from
the moment it became a roaming path. **No F-number.**

*And it is now pinned, which it was not when this ruling was first written.* An earlier draft cited
`roamingPathExpiresAfterSixHours`; that test connects a single `.roaming` interface and never
re-classes anything, so it does not cover this at all — adding a mode comparison to `shouldReplace`
broke neither it nor `fullModePathSurvivesShortWindows`. For a behaviour ruled intended and given no
F-number, a characterization test is worth more than a sentence, so one was written:
**`newerAnnounceOnRoamingInterfaceReClassesAFullLearnedPathToTheRoamingLifetime`**, which learns a
path on a `.full` interface, delivers a genuine newer announce for the same destination on a
`.roaming` one, and asserts the entry survives to just under the roaming window and is GC'd just
past it — with a control half where the newer announce arrives on the FULL interface and the entry
stays on the 7-day window. Mutation-verified: adding `if candidate.interfaceID != existing.interfaceID
{ return false }` to `shouldReplace` reddens the new test with three issues and leaves both
neighbours green. The doc comment names this ruling, so a future edit has to confront it.

*The rider, considered and deliberately not numbered.* The GC nils `announceBlobs[dest]` alongside
`learned[dest]`, so after expiry an old captured announce for that destination is adoptable again
(`shouldReplace(nil, _)` is unconditionally true), and an adopting candidate takes its `interfaceID`
and `nextHop` from the arriving packet. Real, but: it is a property of path expiry in GENERAL, not of
the mode mechanism — the identical reset happens at the ordinary 7-day expiry — it is pre-existing
and untouched by this slice, and it performs none of this sweep's five verbs. It belongs with F13's
family (relay/path redirection) if anyone picks that up, and is recorded here rather than numbered
so that the ranking of this document's OPEN items stays honest.

**Also cross-referenced, not re-litigated:** the `destinationType == .link` + `linkTable`-hit branch
(F13) is not itself destructive, but it causes a destructive transition downstream — it shadows
local delivery, so our own element never sees its proof and dies at `.establishmentFailed(.timedOut)`.
It stays ranked where the previous sweep put it.

**One non-destructive gap found while verifying F17's reference claim, recorded under F9 rather
than given a number.** Reference's `RESOURCE_REQ` branch keeps a per-resource `req_hashlist` of
`packet_hash` values and skips a request it has already served, with the comment *"We need to check
that this request has not been received before in order to avoid sequencing errors."*
`ResourceTransfer.State` has no such set, so a captured `RESOURCE_REQ` replayed by a third party
(no key needed — it is just bytes, and F9 says nothing on the link path rejects replays) makes us
re-transmit the requested parts and re-arm the sender watchdog. That is amplification and life
EXTENSION, not destruction, so it is outside this sweep's verb set. It does NOT reach the
sequencing-error `.failed` exit: that exit keys on `partIndex % Resource.hashmapMaxLen`, which is a
function of the request's contents and identical on every replay. It is a concrete instance of F9
with the added fact that reference carries a guard we do not.

---

## 5. New OPEN items

### F17 — the `.resource` segment fan-out cannot keep two of our own receivers apart

**Where:** `LinkSession.received`'s `(_, .active, .data, .resource)` fan-out, and
`ResourceTransfer.received`'s `(.receiver, .data, .resource)` branch.

Of the five contexts still fanned out to every transfer, four re-check `state.resourceHash` after
decrypting and so cannot cross-contaminate. `.resource` is the exception: a segment packet carries
no resource hash at all, its branch calls no `Link.decrypt`, and its only discriminator is
`Resource.mapHash(chunk:randomHash:)` — a hash of width `Resource.mapHashLength` — looked up in
`knownHashmap`, plus a `receivedParts[idx] == nil` per-index dedup.

**Probe P5, which is the new half.** With two receiver-role transfers on one link and a map-hash
collision *constructed* rather than searched for, transfer B absorbed a chunk belonging to transfer
A: `receivedParts[1]` filled, index 1 dropped from `outstanding`. B's own legitimate part for that
index then arrived and was REJECTED by the dedup guard, leaving B byte-identical. B can no longer
complete correctly, and its terminal exit is one of row 2's `.failed` branches. **No attacker is
involved in any of that** — both transfers are ours, and `(_, .active, .data, .resourceAdvertisement)`
will create two receivers for any two distinct advertised hashes.

The adversarial half was already priced by the previous sweep, which chose to record it without an
F-number; the self-collision case is what it did not see, and it is the same shape as F15's
non-adversarial half one context over. That is why it gets a number now.

**Rank it low, but price all THREE routes — an earlier draft priced only two and would have led a
reader to "this needs a rare event", which is false.**

1. *Accidental*, between two of our own concurrent receivers: probability per fanned part is set by
   `Resource.mapHashLength` against the other transfer's hashmap height. Expensive.
2. *Sprayed*, by an off-link party with no key: same probability, and it must spray. Expensive.
3. *Constructed, by a peer holding the session key: FREE and deterministic.* `.accept` copies
   `adv.randomHash` into `state.randomHash` and `adv.hashmap` into `state.knownHashmap` **verbatim**,
   with no validation (that is F18's field set). A peer therefore does not have to FIND a collision —
   it DECLARES one: it advertises transfer B with a hashmap whose entries are the map hashes of the
   chunks it is about to send for transfer A. Probed: a peer-chosen `m` survives `unpack` byte-for-byte.

**Route 3 does not raise the severity, and the reason is worth stating rather than assuming.** The
peer that constructs it is the peer that advertised BOTH transfers, so what it destroys is a delivery
it controls anyway — it could simply not send the data. It cannot reach another peer's transfers:
`transfers` is per-`LinkSession`. LOW stands.

**A framing to avoid, because it is the intuitive one and it is wrong.** "A merely buggy peer that
reuses `r` gets this for free" is FALSE, and reusing `r` alone never produces a collision. Map hashes
are taken over CIPHERTEXT chunks, and `Resource.buildStream` → `Token.encrypt` draws a fresh random
IV per call (`SecureRandom.bytes(16)`), so two sends of byte-identical data under the same
`randomHash` and the same prefix still yield completely different chunks and completely different map
hashes. Probed all three ways: same `r` + different data → zero collisions; same `r` + same data +
same prefix → maps still differ; same `r` + same data + different prefix → maps still differ. The
deterministic route is control of `m`, not repetition of `r`.

Two smaller blast-radius facts belong with it: a collision also drops `partTimeoutFactor` to
`Const.partTimeoutFactorAfterRTT` for the rest of that transfer's life, and if the poisoned transfer
is a response-Resource, its failure reaches `.transfer(… .delegate(.failed))` and cancels a
legitimate request (row 29).

**Reference has the same defect and knows it**, which is the strongest single fact about this item
and was read out of `RNS/Link.py` rather than assumed. Its `RESOURCE` branch is
`for resource in self.incoming_resources: resource.receive_part(packet)` — every incoming resource,
no hash filter at all — and it is preceded by a standing upstream TODO:

> `# TODO: find the most efficient way to allow multiple transfers at the same time, sending`
> `# resource hash on each packet is a huge overhead. Probably some kind of hash -> sequence map`

`RNS.Packet` defines SEVEN resource contexts, so there are six others, and five of them filter:
`RESOURCE_REQ`, `RESOURCE_HMU`, `RESOURCE_ICL` and `RESOURCE_RCL` each decrypt and then match
`resource.hash` against the appropriate list, and `RESOURCE_PRF` matches
`packet.data[0:HASHLENGTH//8]` against `outgoing_resources` — which is exactly what `d0570ef`
implemented. The sixth, `RESOURCE_ADV`, is the one that CREATES rather than routes, so it has no
existing resource to select. (Two drafting errors here, both listed because the class is the point.
The first said "the other five all filter" — a universal over an enumerated set, off by one. The
second said `RESOURCE_ADV` "has nothing to filter against", which is wrong about reference:
`RESOURCE_ADV` DOES filter, matching `read_request_id` against `pending_requests` on its
`is_response` branch. What is true is only the second clause — there is no existing resource to route
to. That same `is_response` nesting is what row 29's correction turns on.)

**So `.resource` is the one context that routes to an existing resource and has no discriminator to
copy.** A fix is therefore a deliberate divergence and needs choosing, not just porting: scope a
segment to the transfer whose `outstanding` contains its index, or carry the resource hash on
segments (which is the overhead the upstream TODO is about).

Checked in BOTH RNS checkouts, because this repo has two and they are not the same version: the
local `Reticulum` tree is a 1.4.1 BLE fork, the conda `rns` env is stock 1.4.2. **`diff` between the
two `Link.py` files is EMPTY** — they are byte-identical, so every claim above holds for stock RNS
and not merely for the fork. Symbols rather than line numbers are cited here by this repo's standing
convention. (An earlier draft justified that with "the fork's extra import shifts every later line",
which is false for THIS file — the empty diff is the proof — and the shift it was remembering is in
`Reticulum.py`. The convention is right; that reason was not.)

**One general divergence, recorded here because this is where the reference comparison lives:**
reference iterates and acts on EVERY hash match; ReTiCA's proof routing uses `first(where:)` and
acts on the first. Two sender transfers cannot collide on a full-length hash in practice —
`resourceHash` is `fullHash(data ‖ randomHash)` over per-send random material — so today the two
shapes agree. It matters only when a SHORT hash can enter the candidate set, which is exactly
F18: there, a matched decoy would SHADOW the real recipient rather than merely accompany it.

### F18 — `ResourceAdvertisement.unpack` validates the length of none of `h`, `r`, `o`, `m`, `q`

**Where:** `ResourceAdvertisement.unpack`. `h`, `r`, `o` and `m` are read through the same `bin(_:)`
helper, which checks only that the MsgPack value is a `.bin`; `q` goes through its own `switch` that
likewise accepts any `.bin` (or `.null`). Only `t` has any gate at all (a magnitude gate against
`Resource.maxAdvertisedTransferSize`).

Probe P7: an advertisement with all four `bin(_:)` fields EMPTY round-trips through `unpack` intact,
and so does one with over-long `h` / `r` / `o`.

**Impact today is nil, and the accurate framing matters more than the finding.** An empty `h`
becomes a receiver-role transfer's `resourceHash` (probe P2), and an empty `owner` prefix compares
equal to it — so a truncated proof payload would match a decoy. But three things have to be said
precisely, because the Task 2 report said them loosely:

1. **The length guard is the second lock that keeps the match from happening — it is not the case
   that an attacker gains something today.** `ResourceTransfer.received` has no
   `(.receiver, …, .resourceProof)` case at all; a receiver handed a proof falls to `default:
   return .none`. Probe P3, both `.proof` and `.data` packet types: the receiver's state is
   byte-identical afterwards. It would bite only if a receiver-side proof handler were added,
   because `first(where:)` returns a SINGLE target and a matched decoy would then shadow the real
   recipient.
2. **"Wire-controlled" means PEER-controlled, not off-path.** The advertisement that carries `h`
   goes through `authDecrypt`, so producing an empty hash requires the session key. Probe P2: an
   unencrypted advertisement creates no transfer at all; the encrypted one creates a receiver whose
   `resourceHash` is empty. The proof PACKET is the off-path half — unencrypted, admitted on
   `destinationHash == state.linkID` alone.
3. **Only the role-gate pairing holds.** The Task 2 report said "(b)+(d) and (c)+(d) are jointly
   exploitable". The (c) half is FALSE: under (c) the predicate is `$0.role == .sender`, which never
   selects a receiver, so the empty-hash mechanism is irrelevant to it. Probe P1, running both
   mutated predicates literally over a decoy-first array: the (b) predicate selects the receiver
   decoy; the (c) predicate selects the sender and cannot select a receiver at all.

A length check at unpack time would remove the class outright, and **this belongs to whoever owns
advertisement validation, not to the proof-routing code.** The `h` story above is only the most
visible instance: FOUR consumers already depend on a downstream check instead, and each one of them
was found by following a different thread in this slice rather than by looking at `unpack`.

| field | consumer | what holds today instead |
|---|---|---|
| `h` | a receiver's `resourceHash` | the `payload.count >= 32` guard plus the `role == .sender` gate (§5 above) |
| `o` | keys `incomingSegments` | nothing — two advertisements from one peer can share an accumulator (row 29) |
| `m` | copied verbatim into `knownHashmap` | nothing — this is what makes F17's route 3 free rather than found |
| `q` | copied onto the transfer, read by `.transfer(… .delegate(.failed))` | that handler's own `pendingRequests.contains(rid)`, NOT the flag gate (row 29's correction) |

All four require the session key and are bounded to that peer's own link, so the trust boundary is
unchanged by the widening — which is why F18 stays below F3/F4/F5. What the widening DOES change is
the cost/benefit: the fix is the same one length check it always was, and it now closes four
consumers rather than one.

---

## 6. Method notes

**Every `safe` verdict's stated justification was checked before anything else,** as the previous
sweep's post-mortem instructed. Two needed more than the evidence they arrived with:

- The `(_, .active, .proof, .none)` row's justification ("`destinationIdentity` is initiator-only")
  was inherited from the previous sweep and is TRUE, but it had been verified there by counting
  writes *in `LinkSession.swift`*. `destinationIdentity` is a `public var`, so a host could assign
  it. Re-verified repo-wide across `Sources`: there is no such assignment. The claim survives on a
  wider grep than the one that originally supported it.
- A draft of the fan-out comment added to `LinkSession` in this slice said all five remaining
  fan-out contexts "re-check `state.resourceHash` after decrypting". That is false for `.resource`,
  which is F17. It was caught before commit, and it is a clean instance of the shape §6 of the
  handoff names: a reassuring generalisation over a set, wrong on one member.

**And the first committed draft of this document still shipped two more of exactly that shape,
found on review.** Both are `safe` rows whose VERDICT survives but whose stated REASON was wrong —
which is the precise failure the "verify the reassuring sentences first" rule exists to prevent,
because a `safe` row is what nobody re-derives. They are corrected in place above, and both are
worth reading as a pair:

- **Row 29** named a gate (`.resourceAdvertisement`'s `pendingRequests` check) that sits inside
  `if adv.isResponse` and therefore does not cover the case, instead of the gate that actually holds
  (the `.failed` handler's own membership test). *Reading the guard is not enough — read what
  BRANCH the guard is nested in.* That single nesting level is the whole defect.
- **Row 34** carried a universal ("nothing inbound makes any of them fire early") that is falsified
  by a two-step chain, neither step of which is surprising alone: the GC predicate looks the
  interface mode up at GC time, and a mode-blind `shouldReplace` can move an entry's `interfaceID`.
  *A universal over a GC is a claim about every write to every field it reads*, and this one reads a
  field owned by a different branch in a different file section.

The two share a shape with the six defects the previous sweep's post-mortem catalogued: **every node
in the chain was individually true, and the error was in an arrow** — nesting in one case, a
cross-branch write in the other. Verifying "does this guard exist?" catches neither.

**One correction that came back the other way, and it is the reason for the verify-before-fixing
rule.** The review also reported that a "merely buggy peer that reuses `r`" gets F17's collision for
free. Probing it first showed that is FALSE — map hashes are over freshly-IV'd ciphertext, so
repetition of `r` yields nothing — while confirming the underlying point that the collision IS free
via peer control of `m`. Fixing as reported would have replaced one wrong price with another.
(Independently re-run afterwards at 1000 trials per variant: zero colliding map hashes in all three.)

**The CORRECTIONS then introduced two more defects of the same class, which is the honest headline
of this document's method section.** Round two found them:

- The row-29 correction paragraph ended with a false absolute — "the same sequence emits nothing" —
  where the truth is that no *request cancellation* happens but the transfer still emits
  `.resourceFailed`. I had probed the narrow claim (`pendingRequests` unchanged) and then written a
  broader one than the probe supported. **A probe licenses exactly the proposition it observed**;
  mine printed one field and the sentence spoke about all effects.
- The row-37b rewrite said the `safe` verdict "rests on the trigger being local" and that "dropping
  relay state on leaving relay mode is the point". Both understate it: `enableRelay` carries a
  NON-optional `Identity` in all three endpoints, so the `nil` branch has no production emitter at
  all and "leaving relay mode" is not a transition this codebase can perform.

Three rounds, and every round's defects were in the same two positions — a `safe` row's reason, or a
paragraph whose job was correcting an earlier claim. **The lesson is not "check harder", it is that
correcting text is itself high-risk text and should be re-verified as if it were new.** The rule
that would have caught both: *state the narrowest claim your evidence supports, then check whether
the sentence you actually wrote is wider than that.*

**Probes over reasoning, again.** P5 is the whole of F17 and reasoning did not produce it —
"`.resource` is gated by a map hash" reads like a gate until you watch a chunk from one transfer
land in another's part table. P4 is the structural claim the rest of the document rests on
(decrypt authenticates but does not discriminate) and it is one line of output. P10 and P8 were
written to try to break `safe` verdicts and failed to, which is the outcome a `safe` verdict is
supposed to have evidence for.

**A comment claim was demoted from "read the framework source" to "ran the experiment."** The
reworded inert-send comment in `aResourceProofReachesOnlyTheTransferThatOwnsIt` asserts that under
`.on` the `receive` steps already catch a stray delivery, so the inert send is belt-and-braces
THERE while being the sole catcher in the other three proof tests. That is readable off
`TestStore.receiveAction(matching:)` — its skip-and-report block is gated on
`exhaustivity != .on`, and otherwise it asserts the predicate against the head of the queue. It was
nonetheless verified by experiment, because it sits in the reassuring position this document's
predecessor identified as the most dangerous one. Two runs, both under a restored-fan-out mutation:
with the inert send REMOVED, `aResourceProofReachesOnlyTheTransferThatOwnsIt` still fails (three
issues, "Received unexpected action" at the `receive` steps); with the inert send removed,
`aResourceProofIsNotDeliveredToAReceiverRoleTransfer` PASSES, which is what "sole catcher" means.
Both mutations reverted; suite re-confirmed at 834.

**Two-input discipline, applied.** The previous sweep's post-mortem says: when a probe's result
becomes a claim, ask what about that specific INPUT the claim depends on, and probe a second input
that differs in that dimension. P8 does this deliberately — a plaintext payload and a
correctly-encrypted-wrong-value payload, so "both gates are load-bearing" rests on two inputs rather
than on one plus an inference. P3 does it too, running both `.proof` and `.data` packet types
against the receiver so "there is no receiver-side handler" is not a claim about one case label.

**One prose defect from this slice could not be fixed in place.** Commit `d0570ef`'s message says
"The other six resource contexts keep fanning out." It is five. The code was always right; only the
message is wrong, and a pushed commit message cannot be corrected. The count is now stated
explicitly in the routing comment in `LinkSession`, together with a note that the message is wrong,
because that comment is where a reader arrives. Note that the corresponding claim in
`docs/superpowers/plans/2026-08-13-destructive-transitions-need-authentication.md` also says six —
plans are left as written per the handoff's §6 convention.
