# ReTiCA vs reference Reticulum — gap analysis

**Date:** 2026-08-10
**Reference:** `RNS` 1.4.1 (`/Users/ell/development/python/Reticulum`, BLE fork) cross-checked against stock 1.4.2
(conda env `rns`); `LXMF` 1.1.0 (`.../site-packages/LXMF`).
**Under review:** `Sources/` at `5912344`.

Method: eight parallel subsystem sweeps (Identity/Crypto, Packet/Destination, Link/Channel/Buffer,
Resource, Transport×2, Interfaces, LXMF), each required to cite `file:line` on both sides and to
grep repo-wide before asserting absence. Findings marked **[verified]** were additionally
re-checked by hand against both trees.

---

## Verdict

The **wire core is in good shape**. Every byte-level construction that was checked — packet framing,
`get_hashable_part` masking, announce signing, the link handshake, resource advertisements including
multi-segment, HDLC, the LXMF message container, propagation transient_ids, all three stamp
workblocks — matches the reference. The primitive crypto layer has no algorithmic gap at all.

The gaps are almost entirely in the **stateful, adversarial, and durable** layers around that core:

1. **Liveness and timing.** Fixed constants where the reference derives from RTT, hop count, and
   interface bitrate. One of these is a live defect that kills transfers (§1.1).
2. **Return paths.** No reverse table, no non-link proofs, no packet receipts. Proof-of-delivery
   does not work through or to a ReTiCA node.
3. **Durability.** Nothing in the transport core is persisted. Paths, identities, dedup memory and
   the LXMF outbound queue all evaporate on cold start.
4. **Admission control.** No resource-accept policy, no request size caps, no link-accept policy,
   no path-request rate limiting. Several unbounded-allocation paths reachable by any peer.
5. **Two whole subsystems absent:** `Channel`/`Buffer`, and the LXMF ticket system.

Nothing here contradicts the README's own "Not Yet Implemented" section — but the README
substantially understates the list, and several items below are defects rather than deferrals.

---

## 1. Live defects — wrong behaviour today

> **Plans written 2026-08-10** covering everything in this section except §1.6:
> - `docs/superpowers/plans/2026-08-10-link-liveness-and-lifecycle.md` — §1.1, §1.7, §1.8
> - `docs/superpowers/plans/2026-08-10-transport-announce-path-correctness.md` — §1.2, §1.3, §1.4
> - `docs/superpowers/plans/2026-08-10-pn-stamp-cost-parity.md` — §1.5
>
> §1.6 is **deferred by decision** — it is a feature (Identity.prove + ProofDestination + reverse
> table + PacketReceipt + proof strategy), not a fix, and is ~10× the size of the rest of §1.

### 1.1 Link inactivity teardown kills any transfer longer than 60 s **[verified]**

`LinkSession` re-arms its inactivity timer at exactly four sites — link activation
(`LinkSession.swift:351, 367`) and inbound KEEPALIVE (`:384, 394`). The inbound DATA
(`:369-372`), RESOURCE (`:417-426`), REQUEST (`:452`), RESPONSE (`:428`), RESOURCE_ADV (`:396`)
and LINKIDENTIFY (`:439`) branches all return without re-arming. `state.lastInbound` is written at
those four sites and **never read** — dead state. The timer is the whole mechanism.

That works only if keepalives are guaranteed. Against a reference peer they are not:

- `Link.py:749` — the reference initiator sends `0xFF` only when inbound *or* outbound has been
  silent for `keepalive`. Mid-transfer both are fresh, so it sends nothing.
- `Link.py:1125` — the reference responder replies `0xFE` only if outbound-silent for `keepalive`.
  While streaming resource parts it stays quiet.

So a ReTiCA **initiator downloading** gets no `0xFE`, and a ReTiCA **responder receiving an upload**
gets no `0xFF`. Either way `staleTime` = `keepaliveInterval * 2` = **60 s** (`LinkSession.swift:73, 78`)
fires and `.inactivityDeadline` (`:634-643`) sends LINKCLOSE mid-flight.

**Impact as originally written:** "any link-borne transfer over 60 s dies, in both roles."

> **CORRECTED 2026-08-11 — the symptom above is INVERTED, and the real defect was larger.**
> Fixed in `61566a2` (hoist) + `86ee622` (root cause).
>
> The missing re-arms were real, but links were **not** being torn down at 60 s — they were
> **never timing out at all**. `LinkSession` built `cancelAll` as a `let` at the top of every
> reduce, and `Effect.cancel(id:)` cancels at *construction*
> (`Effects/Publisher.swift:8-10` invokes `createPublisher()` immediately;
> `Effects/Cancellation.swift:106-117` cancels inside it). So every action cancelled the
> establishment, keepalive and inactivity timers.
>
> The precise mechanism, measured: `.run` effects register their cancellable only when the Task
> body starts, whereas `Effect.send(_:)` is a synchronous `.publisher(Just(...))`. A timer armed
> in a return value therefore survives every action delivered by that return value's own sibling
> sends, and dies at the next **externally-driven** action. The trigger set is *every* action
> other than an active-link `.received` — on an initiator that includes `.keepaliveDeadline`
> itself, so an initiator lost its keepalive loop **and** its inactivity watchdog at t=30.
>
> Consequences that were live in shipped code: the initiator emitted **exactly one keepalive per
> link, ever**; a stray packet mid-handshake left the link hung in `.pending`, unreapable; and no
> link ever timed out. The entire 56-test `LinkSession` suite passed before and after the fix —
> every timer test either drove the link with inbound traffic (which re-armed behind the cancel)
> or observed a single tick.
>
> Two lessons recorded rather than buried: a wrong *explanation* was baked into a test-file
> comment as "a TCA 1.26 limitation" and had to be removed twice; and `#expect(store.state.x ==
> …)` after a bare `clock.advance` asserts nothing, because `TestStore` does not fold
> effect-emitted actions into `state` until drained — which is what made the first fix's test
> vacuous.

### 1.2 A local path response wipes the requester's app data and ratchet **[verified]**

`Transport.swift:492` builds the path-response announce with `ratchet: nil, appData: nil`, stamped
with a fresh `randomHash` at `now` (`:489-490`). On the requester, `announceEmitted` is therefore
newer, `shouldReplace` returns true (`:1000`), and the richer entry learned from a normal announce
is overwritten with nils (`:428-431`).

**Impact:** requesting a path to a peer erases that peer's display name / PN metadata (read at
`LXMFNode.swift:337`) and drops ratchet encryption to them. The relay branch is fine — it replays
the cached payload verbatim (`:502, :515`). Reference sends a full announce with rotated ratchet and
`default_app_data` (`Destination.py:283-304`).

### 1.3 Path responses are re-broadcast — announce amplification **[verified]**

Reference gates announce-table insertion on `packet.context != PATH_RESPONSE`
(`Transport.py:1944`): a transport node adopts a path response but **never** re-broadcasts it.
ReTiCA's relay block copies `context: packet.context` (`Transport.swift:451`) with no such test.

**Impact:** because each path response carries a fresh `random_hash`, every ReTiCA relay that hears
one sees an unseen blob, passes `shouldReplace`, and schedules a network-wide re-broadcast. One path
request triggers a flood proportional to the number of ReTiCA relays. Bounded by
`announceMaxRebroadcasts = 2`; reference emits zero.

### 1.4 Packet-hash dedup window is 1000 entries instead of 500k–1M **[verified]**

`seenPacketHashes = RingSet()` (`Transport.swift:32`) takes `RingSet`'s default `capacity: 1000`
(`RingSet.swift:10`). Reference keeps `hashlist_maxsize = 1000000` with a two-generation flip holding
500k–1M live (`Transport.py:177, 656-657, 1417`).

This is clearly unintentional: the two sibling rings are explicitly sized against named reference
constants, with citations —

```
973:  static let pathRequestTagRingSize = 32000   // RNS max_pr_tags (Transport.py:127)
975:  static let announceBlobRingSize = 64
```

— while the one ring where the window matters most silently takes the default.

**Impact:** loop protection and duplicate suppression evaporate after 1000 distinct packets. A relay
carrying more than ~1000 packets between a packet and its echo re-forwards the echo. Reference costs
16–32 MB for this; ReTiCA's costs 32 KB.

### 1.5 `PNNode` advertises propagation stamp cost 0 while enforcing 16 — **FIXED 2026-08-11 (`8a56a25`, `08f1931`)**

`PNNode.swift:79` announces `targetStampCost: 0`; the store it created enforces
`LXMFPropagation.defaultPropagationStampCost` = 16 (`PNNode.swift:24`), silently skipping every
entry that fails validation (`PropagationStore.swift:70-77`).

Reference `get_outbound_propagation_cost` tests `if not target_propagation_cost:`
(`LXMRouter.py:428`) — **0 is falsy** — so it path-requests, still gets 0, logs
"still unavailable", and returns `None`; the send then fails.

**Impact:** a reference client fails *every* propagated send to a `PNNode`. `LXMFServiceNode.swift:122-125`
does this correctly with an explicit "advertised == enforced" comment, which confirms the intended
invariant and makes `PNNode` the outlier.

### 1.6 No PROOF handling for non-link packets **[verified]**

`Transport.swift` dispatches only `.announce` (332), `.data` (467), `.linkRequest` (555), then
`default: return .none` (570). There is no `.proof` case, no `Identity.prove`, no
`ProofDestination`, no reverse table, and no `PacketReceipt` anywhere outside `LinkSession`.

**Impact:** two distinct breaks. (a) A reference peer that sends a plain DATA packet to a ReTiCA
destination and waits on its `PacketReceipt` **always times out**, on a message ReTiCA received
fine. (b) A ReTiCA relay cannot route a proof back toward the sender, so proof-based delivery
confirmation is broken *through* ReTiCA relays as well as *at* them. This is the root cause of
`LXMFRouter`'s blind fixed-interval retry design.

### 1.7 Link teardown does not cancel hosted resource transfers

`LinkSession.cancelPending` (`:201-205`) cancels only request timers; `cancelAll` (`:198-200`) only
establishment/keepalive/inactivity. Hosted `state.transfers` are never cancelled on `.close`
(`:591-601`), `.inactivityDeadline` (`:634-643`), or peer close (`:380`). `LinkPlane` then removes
the element (`LinkPlane.swift:209`), cancelling every child effect.

**Impact:** an in-flight resource on a closing link vanishes silently — no `.failed` delegate is ever
emitted, so a caller awaiting conclusion hangs indefinitely. Reference explicitly cancels both
directions in `link_closed()` (`Link.py:685-687`).

### 1.8 Large-request response timer starts at advertise, not at upload completion

`LinkSession.swift:553-557` arms `requestDeadline` when the request-resource is *advertised*.
Reference starts the clock only when the upload concludes (`Link.py:1331-1333, 1368`).

**Impact:** a large request over a slow link fails spuriously — `requestFailed` fires while the
request is still being transferred. The constant itself is right (`11.25` at `:526`); only the
clock's start point is wrong.

---

## 2. Remotely reachable resource-exhaustion / crash paths

### 2.1 Decompression bomb via advertised data size **[verified]**

`adv.dataSize` is an unbounded `UInt64` off the wire (`ResourceAdvertisement.swift:7, 60`), passed
as `Int(adv.dataSize)` (`ResourceTransfer.swift:377`) into
`var destLen = UInt32(max(expectedSize, 1))` (`Bzip2.swift:28`).

For a declared `d` above `UInt32.max` that conversion **traps** — a deterministic Swift runtime
crash before any allocation. Between ~1–4 GiB you get the huge allocation instead. Reference clamps
to `AUTO_COMPRESS_MAX_SIZE` (64 MiB) and checks `decompressor.eof` (`Resource.py:690-696`).

Reachable by any peer that can establish a link, which is unconditional (§2.3).

### 2.2 `try!` on X25519 key agreement is a remote abort **[verified]**

`Identity.swift:77-81` force-unwraps three throwing CryptoKit calls, including
`try! ephemeral.sharedSecretFromKeyAgreement(with: targetPub)`. CryptoKit throws on low-order
Curve25519 points; `Identity(publicKey:)` (`:41-52`) and `Announce.parse` (`Announce.swift:57`)
validate only *length*.

An attacker generates a real Ed25519 keypair, uses a low-order value as the X25519 public key, and
derives a matching destination hash — the announce signature and the
`destinationHash == SHA256(nameHash‖identityHash)[:16]` binding both pass, since neither touches the
X25519 key. The first `.send` to it aborts the process. The announced 32-byte `ratchet` field is a
second unvalidated path to the same `try!`, as is `LXMFPropagation+Message.swift:16`.

Reference does not abort: pure-Python returns an all-zero secret, PyCA raises catchably.

### 2.3 No admission control on links, resources, or requests

- **Links:** no `accepts_links` equivalent. `LinkPlane.acceptLinkRequest` is an unconditional command
  (`LinkPlane.swift:110-115`); its only caller accepts any request for any registered destination
  holding a private key (`TCPEndpoint.swift:142-147`).
- **Resources:** no `resource_strategy`. Reference defaults to `ACCEPT_NONE` (`Link.py:239`);
  ReTiCA accepts unconditionally (`LinkSession.swift:396-415`), gated only by hash dedup. No
  `Resource.reject`/RCL path for unwanted advertisements. No `ready_for_new_resource()` gate, so
  unlimited concurrent transfers.
- **Requests:** no `max_request_size` / `max_response_size` (`Link.py:992-994, 1030-1036`). A
  `.none`-policy handler still pays full reassembly before the drop, because `LinkPlane` consults
  `RequestPolicy` only after reassembly (`LinkPlane.swift:248-262`).
- **Path requests:** no ingress or egress rate control (`Interface.py:174-203`). Fresh random tags
  pass the `discoveryPrTags` ring every time, each drawing a cached response or a recursive fan-out.

### 2.4 GROUP destination encryption fails open to plaintext **[verified]**

`Destination.swift:78` returns `plaintext` when `Token(key:)` fails, while `decrypt` at `:91` fails
closed — an asymmetry that is itself the tell. `init?` at `:50` checks only `groupKey != nil`, never
its length, and `Token` requires exactly 32 or 64 bytes. A 16- or 24-byte group key silently emits
cleartext. Reference raises (`Destination.py:620`).

### 2.5 `enforceRatchets` fails open **[verified]**

`Identity.swift:108` places the `if enforceRatchets { return nil }` check *inside* `if let ratchets`,
so `ratchets: nil, enforceRatchets: true` falls through to the static-key branch (`:111-114`) and
**decrypts**. Reference dedents the check outside the block (`Identity.py:880`) and returns `None` —
and makes exactly that call whenever a ratchet-enforcing destination has no ratchets loaded
(`Destination.py:654`).

Latent today (nothing passes `enforceRatchets: true`), but a silent security hole the moment
enforcement is wired up.

### 2.6 HDLC deframer buffer is unbounded **[verified]**

`HDLCDeframer.ingest` (`HDLC.swift:61-72`) breaks out at `:65` (no FLAG found) and `:66` (opening FLAG
with no closing FLAG) **without clearing `buffer`**, and bounds frames only from below (`:68`).

Reference has both runaway clamps — `frame_buffer = b""` when it exceeds `HW_MTU*2` with no closing
flag (`TCPInterface.py:408`) and when no flags remain at all (`:411`) — plus an upper frame-length
bound in `check_frame_len` (`:337`).

**Impact:** any TCP peer that streams bytes without ever sending `0x7E` grows the deframer buffer
without bound — unbounded memory growth on a network-facing path in an iOS app. A single oversized
frame also reaches `Transport.received` where the reference drops it at the interface.

### 2.7 Link relaying does not validate hop counts

Reference gates link-table forwarding on hop count as well as interface, with distinct expected
values for shared-medium vs cross-interface (`Transport.py:1704-1739`), and adds the packet hash to
the filter list once it decides it is its turn (`:1733`).

ReTiCA gates on interface identity alone (`Transport.swift:304-315`), stores no hop fields in
`LinkTableEntry` (`:136-146`), and routes link packets *before* the dedup ring (`:327-329`). On a
single-interface host `rcvdIf == nhIf` always (`:564-565`), so an arriving link packet is echoed
straight back out the interface it came from, re-forwarded until `hops+1` reaches 128.

---

## 3. Absent subsystems

| Subsystem | Reference | ReTiCA | Consequence |
|---|---|---|---|
| **`Channel`** | `Channel.py` (606 L) | none | `PacketContext.channel = 0x0E` is declared (`PacketConstants.swift:31`) but has no case in `LinkSession.received` → falls to `default`. Reference both proves and dispatches (`Link.py:1140-1148`). A peer using `link.get_channel()` sees 5 unanswered retries → **tears the link down** (`Channel.py:479-483`). Fails loudly, not gracefully. |
| **`Buffer`** | `Buffer.py` (371 L) | none | Downstream of Channel. No stream-oriented transfer; blocks `rnx`-style remote execution and any `BufferedRWPair` peer. |
| **LXMF tickets** | `LXMessage.py:42-53`, `LXMRouter.py:1073-1134` | none (zero `ticket` hits in `Sources/`) | No stamp-cost exemption in either direction. An inbound `FIELD_TICKET` survives round-trip in `fields` but is never acted on. |
| **Tunnels** | `Transport.py:2365-2476` | none | No path restoration when a transport peer reappears. `LinkPlane.swift:133` names this absence as the reason for its heuristic interface re-homing. |
| **Reverse table / receipts** | `Transport.py:116, 1684-1690` | none | §1.6. |
| **Persistence** | `Transport.py:3291-3504`, `Identity.py:176-239`, LXMF message store | none in transport core | §4. |
| **Paper messaging** | `LXMessage.py:698-744`, `LXMRouter.py:2542-2562` | none | No `lxm://` URI or QR generation/ingest. The encryption step it needs already exists (`LXMFPropagation+Message.swift:15-17`). |

---

## 4. Durability

Nothing in the transport core is persisted. Repo-wide grep finds no `FileManager`/`UserDefaults`/
`Codable` persistence in `ReTiCATransport`. Reference persists the packet hashlist, path table (each
entry rebuilt from its cached announce), tunnel table and announce cache
(`Transport.py:3291-3504`), plus `known_destinations` (`Identity.py:176-239`).

The one designed seam is LXMF-side and write-only: `PropagationNode.swift:44-48` emits
`.storedEntries` / `.purged` for a host to mirror, but nothing consumes a mirror back —
`PropagationStore` has no bulk-insert API (`ingest` at `:64` re-runs stamp validation).

**Impact on cold start:**
- Every learned path and peer public key is gone; no sending until a fresh announce or path
  round-trip. A relay comes back unable to answer path requests from cache.
- The packet-hash dedup memory is gone, so old packets replayed after restart are accepted again.
- The LXMF outbound queue and every in-flight retry saga are lost silently — no `deliveryFailed`.
- **Duplicate delivery:** `seen` (`LXMFRouter.swift:21`) and `downloadedTransientIds` (`:43`) both
  reset, so the next PN sync re-downloads everything the node still holds and re-delivers it as new.
  Reference avoids exactly this with `local_deliveries` / `locally_processed`.

Additionally, path entries are never culled when their interface disappears and `learnedAt` is never
refreshed by use (`Transport.swift:431` is the only write). Reference refreshes on every send and
relay (`Transport.py:1162, 1182, 1694`), so its timeouts mean "unused for". ReTiCA drops an actively
used roaming path 6 h after the last *announce*, while accumulating dead-interface entries for 7 days
— which on BLE happens on every reconnect, since each mints a new `InterfaceID`.

---

## 5. Timing and negotiation constants

The recurring pattern: ReTiCA uses a fixed constant where the reference derives from RTT, hop count,
or interface bitrate.

| Quantity | Reference | ReTiCA |
|---|---|---|
| Keepalive interval | `clamp(rtt * 205.7, 5, 360)` (`Link.py:92-99`) | fixed 30 s (`LinkSession.swift:78`) |
| Link stale time | `keepalive * 2`, recomputed per link | `keepaliveInterval * 2` = 60 s |
| `STALE` grace state | ACTIVE → STALE → `rtt*4 + 5` grace (`Link.py:753-766`) | absent; jumps straight to closed |
| Establishment timeout (initiator) | `first_hop_timeout + 6 * hops` (`Link.py:282-283`) | fixed 15 s (`:78, 105`) |
| Establishment timeout (responder) | `6 * hops + KEEPALIVE` ≈ 366 s (`Link.py:204`) | fixed 15 s |
| Link MTU | negotiated, `mtu_from_lr_packet` etc. (`Link.py:147-164`) | frozen `0x20 0x01 0xf4` = 500 (`Link.swift:16-21`) |
| Resource window cap | `WINDOW_MAX_FAST = 75` with rate escalation (`Resource.py:64-99`) | `maxWindowSlow = 10`, no escalation (`ResourceWindow.swift:5`) |
| Resource timing | eifr-driven, per-round RTT re-measure (`Resource.py:552-562, 848-851`) | flat RTT set once at construction |
| Sender TRANSFERRING patience | `rtt*6*16 + grace + max_extra_wait(68 s)` (`Resource.py:635-636`) | `rtt*4*16 + grace` — `max_extra_wait` **omitted** |

Two of these have concrete cost beyond throughput:

- **Keepalive.** On a fast link (rtt 50 ms) reference keepalives every ~10 s vs ReTiCA's 30 s, so
  ReTiCA holds dead links ~3× longer than the peer. On LoRa (rtt 2 s) reference uses 360 s vs
  ReTiCA's 30 s — 12× the keepalive traffic on the medium least able to carry it, and teardown at
  60 s where the peer allows 720 s.
- **Sender patience.** The reference pads by exactly the receiver's cumulative retry budget so the
  sender never gives up first. At rtt 1 s ReTiCA aborts at ~74 s where reference waits ~174 s — on a
  lossy link it sends an ICL and kills a transfer the receiver was still successfully retrying.
- **Window cap.** 10 × 464 B = 4.6 kB/RTT vs 75 × 464 B = 34.8 kB/RTT — a **7.5× throughput ceiling**
  on any link fast enough to qualify, i.e. every TCP link and most BLE.

MTU non-negotiation degrades correctly as a *terminus* (both sides agree on 500), but is unsafe as a
**relay**: reference clamps or strips the MTU signalling when forwarding a LINKREQUEST
(`Transport.py:1646-1668`); ReTiCA copies the payload verbatim (`Transport.swift:212-227`). Two
MTU-upgrading peers linking through a ReTiCA relay negotiate an MTU it cannot carry, and every
oversized packet then dies silently at `Packet.packed()`'s guard (`Packet.swift:65`).

---

## 6. Interop hazards in the LXMF layer

- **Advertising `perTransferLimit: 0` / `perSyncLimit: 0` silently kills mesh sync** — **CORRECTION
  2026-08-11.** An earlier draft of this document claimed 0 safely means "no limit" to a reference
  peer, citing `LXMF.py:234-236`. **That was wrong**, and the error propagated into a plan's
  exclusion list before a whole-branch review caught it. Those lines are only an `int()`-parseability
  check inside `pn_announce_data_is_valid`. The real consumer is `LXMPeer.py:370-373`: with limit 0,
  `0 != None` holds and `lxm_transfer_size > 0` always holds, so every message is dropped **and
  permanently marked handled** — never retried. `None` is the true no-limit sentinel
  (`LXMPeer.py:192, 194`) and can never arrive from the wire. Reference defaults advertise 256 /
  10240 (`LXMRouter.py:55, 59`). Both `LXMFServiceNode.swift:120` and `PNNode.swift:85` advertise 0,
  so **reference→ReTiCA mesh sync silently delivers nothing, forever** — default-reachable via
  `AUTOPEER = True` / `AUTOPEER_MAXDEPTH = 4` (`LXMRouter.py:44-45`). Client `/get` downloads are
  unaffected (the client sends its own limit, honoured at `LXMFServiceNode.swift:204-226`). The fix
  is not "advertise 256" — that is the same misstatement inverted until real inbound caps exist.
- **`nodeState` never re-announced when node mode is turned off.** `.setNodeMode(false)`
  (`LXMFServiceNode.swift:101-111`) clears bookkeeping and returns `.none`, so the last announce on
  the network still carries `nodeState: true` (`:119`). Reference `disable_propagation()`
  re-announces immediately (`LXMRouter.py:692-694` → `:338-345`) and peers act on it by unpeering
  (`Handlers.py:98-99`). Peers keep syncing into a node that drops everything, and clients that
  selected us as outbound PN keep uploading into a black hole. Cheap fix: emit an announce with
  `nodeState: false`.
- **No delivery-announce app data.** `LXMFNode.registerDelivery` announces `appData: nil`
  (`LXMFNode.swift:92`). Reference packs `msgpack([display_name, stamp_cost, [SF_COMPRESSION]])`
  (`LXMRouter.py:1034-1050`). Sideband/NomadNet therefore show a ReTiCA user as **unnamed**, and
  ReTiCA can never advertise a required stamp cost.
- **Delivery stamps not wired.** All PoW primitives exist (`LXStamper.swift:13-46`,
  `LXMessage.swift:66-76`) but `validateStamp` has no caller and `send` never generates one. A peer
  running `enforce_stamps()` **drops every ReTiCA message** (`LXMRouter.py:1875-1877`).
- **MsgPack decoder rejects types real clients emit.** `MsgPack.parse` (`MsgPack.swift:92-118`)
  lacks negative fixint, `int8/16/32/64`, `float32`, `map32` and all ext types, and `parseMap`
  requires uniformly string- or uint-typed keys. `LXMessage.unpack` decodes the payload in one shot
  and `LXMFRouter.received` drops the message with no diagnostic (`LXMFRouter.swift:317`). A message
  whose `fields` carry a single negative integer — routine for `FIELD_TELEMETRY` coordinates — is
  **discarded entirely**, content and all, with no error to the sender.
- **Resource metadata unimplemented → file responses corrupt or dropped.** `hasMetadata` is decoded
  (`ResourceAdvertisement.swift:70`) but never set, and nothing strips the 3-byte length prefix on
  receive. Inbound metadata resources are delivered with the prefix still attached — silently, since
  the hash covers it too. `Link.py:897-912` uses `has_metadata` as the discriminator for file
  responses, so rncp / Nomad Network file downloads fail to msgpack-decode and are dropped.
- **No proof recovery via cache request.** `PacketContext.cacheRequest = 0x08` is declared
  (`PacketConstants.swift:25`) and never handled. A reference sender that loses a `RESOURCE_PRF`
  issues a `CACHE_REQUEST` (`Resource.py:655-661`); ReTiCA ignores it, so the sender burns all 3
  proof retries and cancels a resource ReTiCA already has complete and verified.

---

## 7. Forward secrecy: ratchets are send-side only

ReTiCA honours a *peer's* announced ratchet when encrypting (`Identity.swift:68-87`,
`Transport.swift:772`) but never generates, rotates, persists, announces, or enforces one of its own.
Both `Announce.buildPayload` call sites hardcode `ratchet: nil` (`Transport.swift:492, 799`), and the
sole `Destination.decrypt` call site passes no ratchets (`:551`).

Not a wire break — a ratchet-less announce is valid, and the two halves are self-consistent. Two real
losses: **no forward secrecy for any inbound traffic** to a ReTiCA destination (every packet stays
decryptable by whoever holds the long-term X25519 key), and a **hard break with any peer calling
`enforce_ratchets()`** (`Destination.py:502-510`), which drops everything ReTiCA sends, silently.

---

## 8. Interfaces and composition

ReTiCA implements **2 of the reference's 15 interfaces** (TCP client, BLE/RBTP). It implements the
*Transport-side* half of `Interface.py` well — announce-queue pacing, ingress-control burst holding,
IFAC, mode-gated relay, all constant-for-constant — and omits the *interface-side* half entirely:
traffic counters, `online`/`IN`/`OUT`/`FWD`/`RPT`, `detach`, `get_hash`, `optimise_mtu`, gravity,
announce-rate targets, egress control, path-request frequency tracking.

Three structural absences dominate:

**8.1 Only one transport can be live at a time.** `TransportEndpoint.State` is an enum
(`TransportEndpoint.swift:18-20`); `TCPEndpoint.State` holds one `interface` (`TCPEndpoint.swift:19-25`);
`LXMFNode.State` holds one `endpoint` (`LXMFNode.swift:17`). The `Transport` *core* is
multi-interface-capable — `State.interfaces` is a dictionary (`Transport.swift:30`) and `BLEEndpoint`
genuinely registers one `InterfaceID` per peer (`BLEEndpoint.swift:123-127`) — but the composition
layer is not. Two `TransportEndpoint`s give two disjoint path tables with no failover and no relay
between them. **This is the largest gap for a real mobile client**, which wants
internet-when-available plus off-grid BLE simultaneously.

**8.2 There is no interface abstraction.** `grep -rn "^public protocol \|^protocol " Sources` returns
nothing — the package declares zero protocols. Each interface is a bespoke reducer wired by a bespoke
`*Endpoint`. Adding an interface type means writing a new endpoint and extending a sum type.

**8.3 No config, no persistence, no logging.** No config-file parsing (reference:
`Reticulum.py:455-733`, ~35 global + ~40 per-interface keys), so an app cannot ship or import a
`.reticulum` config and cannot be pointed at an arbitrary network. No logging at all — reference has
nine levels with file/callback sinks (`__init__.py:65-78`). When a path silently fails in production
there is no instrumentation.

### Missing interfaces that matter on iOS

| Missing | Reference | Unlocks |
|---|---|---|
| **TCP server** | `TCPInterface.py:465`, `BackboneInterface.py:51` | iOS can only dial out, never accept. Two phones on one Wi-Fi cannot peer over IP. Blocks reachable propagation-node hosting. |
| **AutoInterface** | `AutoInterface.py:43` | Zero-config LAN discovery (IPv6 multicast, port 29716) — the most common "it just works" deployment. Buildable on iOS with the multicast entitlement. |
| **RNodeInterface over BLE** | `RNodeInterface.py:176-178, 1250` | LoRa hardware. ReTiCA's BLE stack implements RBTP peer-to-peer (`BLESupport.swift:12`), a *different* protocol from RNode serial-over-BLE. The CoreBluetooth plumbing already exists — highest-value missing interface if off-grid LoRa is a product goal. |
| **UDPInterface** | `UDPInterface.py:40` | Lower priority; AutoInterface supersedes it. |

`BackboneClientInterface` is **not** missing in practice — its wire format is byte-identical
HDLC-over-TCP (`BackboneInterface.py:764-794`), so the existing TCP client interoperates with
Backbone hubs, just with the wrong MTU/bitrate profile (§8.4).

Correctly absent for iOS: Serial, KISS, AX25KISS, Pipe, I2P, Local (Unix socket), Weave,
RNodeMulti, and the Android variants.

### TCP client thinness

| Reference feature | Cite | Swift |
|---|---|---|
| `RECONNECT_WAIT = 5`, unlimited retries | `TCPInterface.py:80-81` | present (`TCPClientInterface.swift:11, 77-83`) |
| `max_reconnect_tries` + teardown | `TCPInterface.py:109, 279-282` | absent — retries forever |
| `INITIAL_CONNECT_TIMEOUT = 5` | `TCPInterface.py:89, 240` | absent — `NWConnection.State.waiting` falls into `default: break` (`TCPConnection.swift:98-99`), so a connect with no route sits in `.connecting` **silently and forever**, emitting no event |
| TCP keepalive / `TCP_USER_TIMEOUT` | `TCPInterface.py:84-87, 181-207` | absent — `TCPConnection.swift:80` uses bare `using: .tcp`; keepalive defaults off. A NAT-timed-out socket (routine on cellular) goes undetected, so no `.disconnected` fires and no reconnect happens |
| `TCP_NODELAY` | `TCPInterface.py:149` | absent |
| `kiss_framing`, `i2p_tunneled`, `fixed_mtu` | `TCPInterface.py:92-116` | absent |

**8.4 No MTU/bitrate autoconfiguration.** `InterfaceProfile.hwMTU` is a hardcoded preset
(`InterfaceProfile.swift:49-51`); reference derives it from bitrate via `optimise_mtu()`
(`Interface.py:205-219`). Connecting to a Backbone hub (`HW_MTU 1048576`, 1 Gbps guess) still uses
TCP's 262 KiB / 10 Mbps figures, mis-sizing resource windowing and announce pacing.

**8.5 No traffic counters.** No `rxb`/`txb` anywhere (`Interface.py:98-99`). An app on metered
cellular cannot account for data usage.

**8.6 No interface lifecycle flags.** `online` exists only as a private per-reducer enum
(`TCPClientInterface.swift:30`) invisible to `Transport`, which knows only registered/not. No
`IN`/`OUT`/`FWD`/`RPT` (reference gates every transmit on `interface.OUT`, `Transport.py:1202`), no
`detach`, no `get_hash`, no `tunnel_id`, no parent/child relationship — BLE's per-peer IDs are
siblings with no parent, which is the documented cause of the ingress-control aggregation deferral
(`Transport.swift:355-361`).

**8.7 No introspection or `Discovery.py`.** No `get_interface_stats`/`get_path_table`/`drop_path`
equivalents (`Reticulum.py:1364-1700`), though an app can read `Transport.State` directly for a
rudimentary path-table view. `Discovery.py` (~49 KB, in both versions) — interface announces with
PoW stamps, autoconnect to discovered hubs, identity blackholing — is entirely absent, so an app must
hardcode its hub. `Resolver.py` is a stub upstream and is **not** a gap.

---

## 9. Verified complete — do not re-litigate

Recorded so these are not re-investigated:

- **Crypto primitives.** No algorithm in `RNS/Cryptography/` is missing. HKDF matches exactly
  including the `(i+1) & 0xFF` counter wrap; PKCS7 is stricter than reference; Token mode selection
  by key length matches; all size constants correct.
- **Packet framing.** All 21 contexts present and value-exact; flags bit layout, HEADER_2 field
  order, `get_hashable_part` masking and `PATHFINDER_M` rejection all match.
- **Announce validation.** The ratchet/no-ratchet payload split, signed-data field order, and
  destination-hash binding all match `Identity.py:511-601`.
- **Link handshake.** `link_id_from_lr_packet` including the trailing-signalling strip, the
  LR/LRPROOF/LRRTT exchange, HKDF-over-ECDH keying, LINKIDENTIFY signature layout, LINKCLOSE.
- **Resource wire format.** All 11 advertisement fields in reference order, flag bits including
  is_request/is_response/is_split, `HASHMAP_MAX_LEN = 74`, `MAX_EFFICIENT_SIZE`, `resourceSDU = 464`,
  hash/proof derivations, the unencrypted-parts rule, `WINDOW_FLEXIBILITY` both directions,
  `MAX_RETRIES`/`MAX_ADV_RETRIES`, multi-segment `i`/`l`/`o`/split encoding.
- **Request/response timeout formula** `rtt*6 + 11.25` matches (`LinkSession.swift:526`).
- **Ingress control + announce pacing.** `IC_*`, `MAX_QUEUED_ANNOUNCES`, `MAX_RANDOM_BLOBS`,
  `LINK_TIMEOUT`, `ANNOUNCE_CAP`, `pathRequestTagRingSize` all match named reference constants.
  `Transport.swift:104-116, 878-954` reproduces `Interface.py:58-92, 152-172, 223-255`
  constant-for-constant, including the deliberate asymmetry where the announce that *ends* a burst is
  itself held. Announce-queue pacing (`Transport.swift:82-99, 693-720, 865-874`) matches
  `Interface.py:321-361` + `Transport.py:1277-1336`, including the local-announce cap bypass.
- **IFAC.** `IFAC.swift` is a careful port of `Reticulum.py:958-973` + `Transport.py:1069-1104,
  1440-1476`, including the bit-7 asymmetry (`:9-14`), with a constant-time comparison that improves
  on the reference (`:156-158`).
- **Interface modes.** Full 7-value enum with reference wire constants
  (`InterfaceProfile.swift:5-13` vs `Interface.py:45-51`), mode-gated relay, mode-dependent path
  expiry.
- **RBTP BLE profile.** `BLESupport.swift:12, 57-58` matches the fork's `BLEInterface.py:41-53`
  framing and HELLO.
- **LXMF core.** Message pack/unpack/sign/hash, rich int-keyed fields, delivery stamp as 5th payload
  element, propagation container and transient_id, PN announce app-data, all three stamp workblocks.

Two claims in the original brief were checked and are **false**: `MAX_ACCEPTED_RESOURCES` does not
exist in the reference (its concurrency control is `ready_for_new_resource()`), and
`LXMessage.RATCHET_COUNT` does not exist in lxmf 1.1.0 (`RATCHET_COUNT` is an RNS `Destination`
constant). `announce_immediately` likewise does not exist in either tree.
