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
| 8 | `.senderDeadline` `.transferring` → `.failed` | clock | n/a | **safe as a TRANSITION — it destroys only the transfer whose own clock fired — but the justification an earlier draft gave is FALSE, and what replaces it is F19.** The old reason was: *"entering `.transferring` requires row 1's two gates, so the window length is not settable by an unauthenticated party."* Row 1's gates are `Link.decrypt` plus the `resourceHash` match, and a **REPLAYED** `RESOURCE_REQ` satisfies both — it is a genuine packet, and F9 says nothing on the link path rejects replays; the slice's own F9 addition says exactly that. Two true nodes, false arrow: passing those gates does not imply an authenticated party. And what the replay does is not *set* the window's length: every accepted request calls `armSenderWatchdog` with `cancelInFlight: true`, which RESTARTS it — so ONE captured frame, replayed on any cycle shorter than the window, postpones this deadline without bound. Postponement is life extension rather than destruction, so it is outside this sweep's verb set — but it disables the transfer's only self-terminator, which is what **F19** numbers. |
| 9 | `.senderDeadline` `.awaitingProof` — proof retries exhausted → `.failed` | clock | n/a | **safe, and load-bearing after this slice.** Since `0101a74` this is the only SELF-terminator for a sender whose proof never validates, which is deliberate: reference `Resource.validate_proof` has no else branch and lets the sender watchdog decide. It is not the only terminator — the peer can still cancel explicitly via row 4, and a host can via row 10. **But it is POSTPONABLE by the replay row 8 names:** the `.awaitingProof` window restarts on every accepted `RESOURCE_REQ`, and `proofRetriesLeft` is decremented in exactly one place — this branch — so a deadline that never fires never spends a retry. That is **F19**, and it is what makes "load-bearing" the right word rather than a reassuring one. |
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
refuse to answer. (Say "inserted", not "written". `pendingRequests` has NINE write sites in the file:
the two `.sendRequest` inserts; five removals — `cancelPending`'s `removeAll`, the `.response`
branch, `.requestDeadline`, `.transfer(… .delegate(.received))`'s response branch, and this handler;
and two initialiser assignments, which are writes but not removals. Only the two inserts decide what
can ever be cancelled. An earlier draft said "six other write sites, all removals" and then listed
five — off by one against its own enumeration AND mischaracterising the initialisers, which is the
same class this document flags twice elsewhere.)

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
| 37b | `setTransportIdentity(nil)` → `announceTable = [:]`, `linkTable = [:]`, `discoveryPathRequests = [:]` | n/a | **none — three WHOLESALE wipes**, including every transited link's routing state | **safe: no emitter inside this package's `Sources`, the behaviour is deliberate, and three tests pin it.** Took three drafts to state — see the note below the table, which separates the reachability claim from the rationale claim. |
| 38 | `seenPacketHashes` ring eviction under load | no | n/a | **outside the verb set, recorded anyway.** An unauthenticated flood evicts dedup memory, which re-enables replay of an evicted packet. Pinned by `seenPacketRingEvictsOldestAndReDeliversIt`; the ring is deliberately sized for this (`seenPacketRingSize`). Not a destructive transition, but it is the one place in `Transport` where unauthenticated volume erases state that a security property rests on. |

**Note on row 37b, which took THREE drafts to state correctly. Two claims are in play and the first
two drafts kept conflating them — reachability and rationale.**

*Draft 1* called the three wipes "keyed". They are not; they are the least discriminating destructive
action in the file. That correction stands.

*Draft 2* said the `safe` verdict "rests entirely on the TRIGGER being local", and added that
"dropping relay state on leaving relay mode is the point".

*Draft 3 (this one) corrects the reachability half and RESTORES the rationale half.*

- **Reachability — draft 2 was wrong.** `Transport.Action.setTransportIdentity` takes an `Identity?`,
  but every in-package emitter reaches it through an `enableRelay(Identity)` case (`TCPEndpoint`,
  `BLEEndpoint` and `TransportEndpoint` all declare the payload NON-optional), so those sends can only
  produce `.some`. There is no `disableRelay` and no literal `setTransportIdentity(nil)` anywhere in
  `Sources`. Narrowest supportable statement: **no emitter inside this package's `Sources`.** NOT
  "unreachable from production" — `Transport.Action` and the case are both `public`, so a package
  consumer can emit `nil` directly. There are **TWO** local path-dependency consumers, not one —
  `apps/ReTiCaMsgr/ReTiCaMsgrCore/Package.swift` and `apps/Nbhd/Packages/NbhdKernel/Package.swift` —
  and NEITHER names `setTransportIdentity` or `enableRelay` (grepped across both trees), so the
  verdict survives on a wider consumer set than the sentence originally claimed. (The second is easy
  to miss: `NbhdKernel` declares its path as `../../../../pods/ReTiCa`, lower-case `a`, which a
  case-sensitive search for the directory name does not match — a case-insensitive grep over
  `Package.swift` finds both.) Commit `7125076`'s message carries the earlier "the one in-tree
  consumer" wording and a pushed message cannot be corrected, so it is corrected here. Same caveat
  this document already applies to `destinationIdentity`, and an earlier draft of this note failed
  to apply it here.
- **Rationale — draft 2 was wrong to call this wrong.** "Dropping relay state on leaving relay mode
  is the point" is not a reachability claim; it is the repo's own recorded intent, and
  `relayStopClearsLinkTable`'s doc comment states it almost verbatim ("relay reverse-routing is
  meaningless without relay mode"). It stands.
- **And the seam is NOT unwatched, which draft 2 also got wrong.** Three tests drive
  `.setTransportIdentity(nil)` and assert each wipe by name:
  `relayStopCancelsPendingRebroadcastAndClearsAnnounceTable` (`announceTable.isEmpty`),
  `relayStopClearsLinkTable` (`linkTable.isEmpty`) and `deRelayingClearsInFlightRecursiveSearches`
  (`discoveryPathRequests.isEmpty`). The wipes are pinned as INTENDED behaviour, not left unguarded.

Net verdict: **safe.** No in-package emitter, the behaviour is deliberate, and it is covered by three
tests. Not numbered, because it performs none of the five verbs against anything an attacker reaches.

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
   `Resource.mapHashLength` against the other transfer's hashmap height. Expensive **per part — but
   the two-concurrent-receivers PRECONDITION is not the rare part, and an earlier draft left the
   reader assuming it was. See the reachability correction below.**
2. *Sprayed*, by an off-link party with no key: same probability, and it must spray. Expensive.
3. *Constructed, by a peer holding the session key: FREE and deterministic.* `.accept` copies
   `adv.randomHash` into `state.randomHash` and `adv.hashmap` into `state.knownHashmap` **verbatim**,
   with no validation (that is F18's field set). A peer therefore does not have to FIND a collision —
   it DECLARES one: it advertises transfer B with a hashmap whose entries are the map hashes of the
   chunks it is about to send for transfer A. Probed: a peer-chosen `m` survives `unpack` byte-for-byte.

**Reachability correction to route 1, from the final whole-branch review: two concurrent receivers
on one link is the ORDINARY case for a slow resource, because OUR OWN retry timer manufactures it.**
Every arrow verified against the code:

- `LXMFRouter`'s `.retryDue` `.direct` branch, on a destination whose `directLinks` entry is
  `.active`, emits `.sendDirect(linkID:data:asResource:)` **unconditionally** and re-arms
  `retryTimer(hash, LXMFDelivery.retryWaitSeconds)`. It never asks whether the previous send is
  still in flight.
- `LXMFNode` maps `.sendDirect(_, _, asResource: true)` to `.endpoint(.sendResourceOverLink)`, and
  `LinkPlane` maps that to `LinkSession.sendResource`.
- `LinkSession.sendResource` draws `randomBytes(8)` for a FRESH `randomHash` every call, and
  `Resource.resourceHash` is `fullHash(data ‖ randomHash)` — so the identical payload gets a
  **different `resourceHash`** on the retry.
- The receiver's only dedup is `state.transfers.contains(where: { $0.resourceHash == adv.hash })` in
  `(_, .active, .data, .resourceAdvertisement)`. Different hash, so it does not fire, and a second
  receiver-role transfer is created.
- The retry timer's only cancel is `.delivered`. For a resource-framed direct send the only route to
  it is `.resourceDeliveredOnLink` ← `LinkSession`'s `.resourceConcluded` — i.e. only once the
  resource PROOF has returned.

So any resource-framed LXMF message whose transfer has not concluded within `retryWaitSeconds`
duplicates itself, bounded by `maxAttempts` — and on the RF/mesh links this library targets, a
transfer running longer than `retryWaitSeconds` is the ordinary case, not the exception. Probe (the
final review's, through production wiring): two `sendResourceOverLink` calls of the IDENTICAL
payload on one link produced two sender transfers with distinct hashes and **two concurrent receiver
transfers, both `.requesting`.** The factors are positively correlated, too: the transfers most
likely to duplicate are the large slow ones, which are exactly the ones with the tallest
`knownHashmap`, and the number of collision opportunities is one transfer's part count against the
other's hashmap height.

**LOW survives, and the reason is that the correction is to the PRECONDITION's price, not to the
collision's.** Three things hold it down. (a) The per-part probability against
`Resource.mapHashLength` is unchanged — duplication multiplies OPPORTUNITIES, not the chance per
opportunity. (b) Duplicates produced this way carry the SAME message, and a collision poisons only
the transfer whose `knownHashmap` contained the colliding entry: the segment is fanned out to both,
so the other twin absorbs its own part normally and still completes, after which
`LXMFRouter.received`'s `state.seen.insert(message.hash)` drops the duplicate delivery. The harmful
shape — two receivers carrying DIFFERENT resources — still needs two genuinely concurrent sends.
(c) Nothing crosses a trust boundary: `transfers` is per-`LinkSession` and both transfers are ours.

**The test-visibility trap, which is why no in-repo test can currently observe this shape.**
`RandomBytesGenerator.testValue` is a deterministic ramp, so in-tree tests get the same
`randomHash` — and therefore the same `resourceHash` — for the same payload, and the receiver's
advertisement dedup swallows the duplicate. Nothing in `Tests/` can show the duplication without
overriding `\.randomBytes`, and a test written without that override will look like evidence that
the duplication does not happen.

**The same chain is also why F15's fix is load-bearing rather than theoretical.** The duplicate
SENDER transfers it creates on our side are exactly the two-concurrent-senders shape whose proof
fan-out was F15 — see F15 in the handoff.

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

A length check on `h` at unpack time would remove **the `h` class** outright, and **this belongs to
whoever owns advertisement validation, not to the proof-routing code.** The `h` story above is only
the most visible instance: FOUR consumers already depend on a downstream check instead — but **do
not read them as things the length check closes; it closes `h` and nothing else**, which is what the
table below and §7 exist to establish. Each of the four was found by following a different thread in
this slice rather than by looking at `unpack`.

(This sentence was narrowed in the handoff in round 3 and left wide HERE until the final review —
which is the one-sided-fix hazard §6 now carries a rule about. Until then, the widest surviving
statement of the claim §7 exists to retract sat directly above the table that refutes it.)

| field | consumer | what holds today instead | would a LENGTH check at `unpack` close it? |
|---|---|---|---|
| `h` | a receiver's `resourceHash` | the `payload.count >= 32` guard plus the `role == .sender` gate (§5 above) | **YES** — `h.count == 32` kills the empty-hash decoy outright |
| `o` | keys `incomingSegments` | nothing — two advertisements from one peer can share an accumulator (row 29) | **no** — the weakness is two advertisements declaring the SAME valid `o`. Needs a consumer-side uniqueness check, not a length gate, and `unpack` sees one advertisement at a time |
| `m` | copied verbatim into `knownHashmap` | nothing at `unpack`; F17's routing is the only thing between it and another transfer | **no, and NO validation of any kind would** — `m` IS the peer's own resource's map hashes by protocol design, so a hostile hashmap is indistinguishable from a legitimate one. This is F17's to fix, not F18's |
| `q` | copied onto the transfer, read by `.transfer(… .delegate(.failed))` | that handler's own `pendingRequests.contains(rid)`, NOT the flag gate (row 29's correction) | **no** — a borrowed id is a legitimate full-length `truncatedHash`. The gap is PROVENANCE (`q` honoured with neither flag set), fixable by a cross-field rule at `unpack` or a flag check in `LinkSession` |

**The narrowest supportable statement, and it is narrower than two earlier drafts claimed:** four
consumers rely on a downstream check instead of validation at `unpack`; **one length check closes
exactly ONE of them (`h`), and the other three need value, uniqueness or provenance checks — not
length.** All four require the session key and are bounded to that peer's own link, so the widening
does not move the trust boundary.

**This retracts the round-2 ranking flip. See §7.**

### F19 — a replayed `RESOURCE_REQ` postpones the sender watchdog without bound

**Added by the final whole-branch review.** Stated in OUTLINE here, because rows 8 and 9 are where
it surfaces; the full entry, the preconditions and the RANKING live in
`docs/superpowers/2026-08-10-handoff-link-lifecycle-and-delivery-termination.md` §3c. Written that
way on purpose — duplicating a whole item is what produced two of this slice's four deferred minors
(see §6's twin rule).

**Where:** `ResourceTransfer.received`'s `(.sender, .data, .resourceRequest)` branch and
`armSenderWatchdog`; `LinkPlane`'s `evictable` filter in the `.link(… .delegate(.established))`
handler.

The branch's gates (row 1) are `Link.decrypt` plus the `resourceHash` match. A captured genuine
`RESOURCE_REQ` replayed by a third party satisfies both with no key — F9's `req_hashlist` instance,
already recorded there — and the branch then re-arms `armSenderWatchdog(state)`, which is
`.cancellable(id: CancelID.watchdog, cancelInFlight: true)`. `proofRetriesLeft` is decremented in
exactly one place, `.senderDeadline`'s `.awaitingProof` branch, so a deadline that never fires never
spends a retry. Probe, through production wiring: ONE captured frame replayed on a cycle shorter
than the `.awaitingProof` window (`rtt × Const.proofTimeoutFactor + Const.senderGrace`) left the
transfer `.awaitingProof` at t ≈ 600 s with `proofRetriesLeft` **pinned at its initial
`Const.proofRetries`, never decremented**; the control run, junk proofs instead of replays,
terminated at t ≈ 40 s.

The consequence this document records in two places and never composed: `LinkSession` removes a
transfer only on a child `.delegate(.received/.concluded/.failed)`, and `LinkPlane`'s eviction
filter is `active.filter { $0.id != elementID && $0.transfers.isEmpty }` (row 32) — so a pinned
transfer makes a RESPONDER link permanently un-evictable, and once nothing is evictable the plane
refuses the newcomer. That is F11's lockout reached without the session key. The comment above that
filter prices the RECEIVER-side version and scopes it to a peer holding the session key; the
sender-side version needs one captured frame.

**What this slice changed is only the teardown, not the pin.** Before `d0570ef` + `0101a74`, one
junk `RESOURCE_PRF` from any off-path party fanned out to every transfer and failed every
SENDER-role one — that was F15 — so the pin had an accidental, un-keyed teardown. Task 3 removed it,
correctly: that teardown was itself the kill primitive F15 names. The attack is pre-existing; what
is gone is the accident that used to clear it.

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

**Round 3's defects were, again, sentences wider than their evidence — and one of them was a RANKING
rationale.** NEW-A found "one length check now closes four consumers", which closes one; NEW-B found
an over-correction that called a pinned, intended behaviour "unwatched" and "unguarded". The second
is the sharper lesson: **over-correction is a failure mode in its own right.** Round 2's row-37b
rewrite was so focused on the reachability error that it swept up a rationale that was correct and a
test-coverage claim that was checkable in one grep. When a draft is wrong, the fix is to narrow the
wrong clause, not to invert the whole paragraph.

**A claim that lives in BOTH documents must be fixed in both, or in neither.** This document and
`docs/superpowers/2026-08-10-handoff-link-lifecycle-and-delivery-termination.md` deliberately
restate each other, and **two of the four minors this slice deferred were one-sided fixes**: round 3
narrowed the handoff's "would remove the `h` class" and left this document's "would remove the class
outright" standing, and round 2's `RESOURCE_ADV` correction landed here and not in the handoff. A
one-sided correction is **strictly worse than leaving both wrong**, because the wider statement
survives in the document that is not open at the time, and the disagreement between the twins is
invisible from either one — nothing forces them to be read side by side. (That is the same shape as
the contradictory-memory failure §6 of the handoff records.) The check is one grep of the other file
for the claim, before committing the fix. Where a finding is large enough that duplicating it is
itself a hazard, state it ONCE and point — which is what F19 below does.

**Every probe in this document is REDUCER-level, and the endpoint boundary has a trap that makes
such probes silently vacuous.** The final whole-branch review re-ran the equivalents through the
full composition and every claim here held — but its first run injected UNFRAMED packets into
`TCPEvent.data`, and `TCPClientInterface` deframes with HDLC: `HDLCDeframer.ingest` finds no
`HDLC.flag`, clears its buffer and emits nothing, so **an unframed packet is silently swallowed and
never reaches `Transport.received`.** Every injection was a no-op while the probe printed
reassuring state, which would have made every "the attacker cannot hurt us" assertion vacuous — in
exactly the reassuring position this section's other entries occupy. The guard is a POSITIVE
CONTROL: inject N frames (`HDLC.frame`), assert N `Transport.received`s, and only then assert
anything about what the injection failed to do.

**One prose defect from this slice could not be fixed in place.** Commit `d0570ef`'s message says
"The other six resource contexts keep fanning out." It is five. The code was always right; only the
message is wrong, and a pushed commit message cannot be corrected. The count is now stated
explicitly in the routing comment in `LinkSession`, together with a note that the message is wrong,
because that comment is where a reader arrives. Note that the corresponding claim in
`docs/superpowers/plans/2026-08-13-destructive-transitions-need-authentication.md` also says six —
plans are left as written per the handoff's §6 convention.

---

## 7. A ranking change that was made, then retracted

**F17 is ranked above F18. A round-2 review instruction flipped that order; round 3 showed the flip
rested on two false premises, and it is retracted. Recorded rather than silently reverted, because
the false premises are more instructive than the ordering.**

The flip was justified by: *"F18 is the upstream cause of F17's route 3 (free only because `m` is
unvalidated) and of row 29's real weakness."* Both halves fail.

- **F18 does not cause F17's route 3.** `m` carries the peer's own resource's map hashes — that is
  what a resource advertisement is FOR, and the receiver has no independent source for them. A
  hostile hashmap is therefore indistinguishable from a legitimate one, so **no validation at
  `unpack` — of length, range, shape or anything else — can close route 3.** The fix is F17's own
  routing. `m` is not really an F18 consumer at all; listing it as one was the mis-attribution that
  made the causal claim look sound.
- **F18 does not cause row 29's weakness either.** The `q` gap is PROVENANCE — a live requestID
  honoured on an advertisement with neither flag set. A length check is irrelevant to it (a borrowed
  id is a legitimate full-length `truncatedHash`), and row 29's verdict is `safe` regardless, because
  the `.failed` handler's own membership test bounds it to requests we sent that same peer.

The sentence that carried the flip into both documents — *"one length check now closes four
consumers"* — is simply false: **it closes one.** Third consecutive round in which the failure was a
sentence wider than its evidence, this time inside a ranking rationale rather than a `safe` row.

**Ruling.** F18 stays what its title says: a length item. Its fix closes `h`. The other three fields
flow into consumers needing uniqueness (`o`), routing (`m`) or provenance (`q`) checks that are not
F18's, and mostly not `unpack`'s at all. F17 — an actual behaviour defect, where two transfers
destroy each other — outranks a defence-in-depth item whose current impact is nil. **Original order
restored.**

**The reviewer who requested the flip also supplied the finding that retracted it, and explicitly
invited that outcome.** The process point worth keeping: a review instruction is evidence about where
to look, not a verdict to implement. Two of three rounds contained a relayed claim that did not
survive checking — `r`-reuse in round 1, this flip in round 2 — and in both cases implementing as
instructed would have replaced one false claim with another. (Both are labelled by the round the
claim ARRIVED in, which is what §5, §6 and this section's opening already do: the flip was MADE in
round 2, on `234805c`, and RETRACTED in round 3.)
