# F19 — a replayed RESOURCE_REQ postpones the sender watchdog without bound

**Written:** 2026-08-23. **Repo:** ReTiCA (`/Users/ell/development/ios/pods/ReTiCA`). Target: `main`.
**Layer:** `ReTiCATransport` (`ResourceTransfer`).

## Goal

Close backlog item **F19**: a captured, byte-identical `RESOURCE_REQ` packet, replayed on a loop,
re-arms the SENDER-side resource-transfer watchdog every round. The watchdog is the sender transfer's
only self-terminator when the peer goes silent, so while the replays continue the transfer never
ends, its `proofRetriesLeft` never decrements, and the (eviction-immune) responder link it sits on
stays pinned — F11's lockout reached without the session key. Fix by adopting reference's per-resource
`req_hashlist`: a request whose packet has already been served is a complete no-op, so a replay
cannot postpone termination, while genuine retransmissions are still served.

## Root cause

The sender request branch `(.sender, .data, .resourceRequest)` in `ResourceTransfer.received`
(`ResourceTransfer.swift:278`) has two gates — `Link.decrypt` (`:279`) and a `resourceHash` match
(`:284-285`) — both of which a *captured genuine request satisfies with no key*, because the bytes are
a real encrypted frame. It then unconditionally re-sends the requested parts (`:296`), resets
`status = .transferring` (`:287`) and `retriesLeft = Const.maxRetries` (`:288`), and calls
`armSenderWatchdog(state)` (`:328`), which is `.cancellable(id: CancelID.watchdog, cancelInFlight: true)`
(`:204`) — it **restarts** the watchdog. There is no dedup of an incoming request today.

`.senderDeadline`'s `.awaitingProof` branch (`:501-507`) is the *only* place `proofRetriesLeft` is
decremented, and it runs only when the watchdog fires. A replay that lands inside the window restarts
the watchdog before it fires, so the deadline never arrives and the retry counter never advances —
unbounded while replayed (probe: one frame replayed every 5s left the transfer `.awaitingProof` with
`proofRetriesLeft` pinned at `Const.proofRetries` at t≈600s; the control with junk proofs terminated
at t≈40s). `LinkSession` removes a transfer only on a child `.delegate(.received/.concluded/.failed)`,
so `transfers` stays non-empty and — sender transfers being eviction-immune by design (the F11 fix
protects genuine senders) — the responder link cannot be evicted while the pin holds.

**Preconditions (bounds the rank, not the fix):** the attacker cannot create the transfer — we must
already be serving a resource to that peer on a responder link (routine for a propagation node, which
sends any response above `requestMDU` as a sender-role Resource on the link the client opened). One
pin per resource we chose to send; the branch's hash check keeps a captured frame from touching any
other transfer.

## The crux: dedup on the encrypted packet, never the plaintext

The dedup key MUST be the raw request packet's hash (over the encrypted bytes), not the decrypted
request body. Verified: `Token.encrypt` uses a fresh random IV per call
(`SecureRandom.bytes(16)`, `Token.swift:31-32`), prepended to the ciphertext — so `Link.encrypt` is
**not** deterministic. Consequences:
- A genuine re-request — even one asking for the *same still-missing parts*, whose plaintext is
  therefore identical — is freshly encrypted, so its ciphertext and thus `packet.packetHash` differ.
  It is served normally: legitimate retransmission is unaffected.
- A replay reuses the *captured ciphertext* verbatim, so its `packet.packetHash` is identical. It is
  deduped.

Keying on the decrypted body would be wrong: two genuine re-requests for the same missing parts share
a plaintext and would be falsely deduped, breaking recovery. This matches reference, which keys
`req_hashlist` on `packet.packet_hash` (`RNS/Link.py:1087-1089`, stock 1.4.2) — the hash of the
encrypted packet.

## Reference alignment (stock RNS 1.4.2)

- `RNS/Resource.py:372` — `self.req_hashlist = []`, per-resource.
- `RNS/Link.py:1087-1089` — `if not packet.packet_hash in resource.req_hashlist:
  resource.req_hashlist.append(packet.packet_hash); resource.request(plaintext)`. A duplicate skips
  the **entire** handler: no re-transmission and no `last_activity` update, so a replay cannot push
  the sender timeout forward. No cap on `req_hashlist` (transfer-scoped).

This is the backlog's Option 1 (cheapest, reference-blessed). Option 2 (bound total transfer lifetime)
and Option 3 (make the `evictable` filter tolerate no-progress transfers — reopens the
mid-transfer-eviction problem the filter exists for; F11 already handles the receiver side) are
rejected. Do NOT restore a destructive branch on unauthenticated input — that is F15.

## Design

Library-side only, in `ResourceTransfer` (`ReTiCATransport`). No wire-format change. No cap.

1. **Add `servedRequestHashes: Set<Data>` to `ResourceTransfer.State`** (the `req_hashlist`), default
   empty, initialized in both inits. Transfer-scoped — it lives and dies with the transfer.
2. **In the `(.sender, .data, .resourceRequest)` branch**, after the existing `Link.decrypt` +
   `resourceHash`-match gate (`:279-285`) confirms the request is valid for this transfer, and
   **before** any state mutation, part re-send, or `armSenderWatchdog`:
   - `guard !state.servedRequestHashes.contains(packet.packetHash) else { return .none }`
   - then `state.servedRequestHashes.insert(packet.packetHash)` and proceed exactly as today.
   `packet` is already bound from `Packet(raw: data)` at the top of the branch handling (`:275`);
   `packet.packetHash` is the hash over the packet's hashable part (which includes the encrypted
   payload), so it differs when the IV differs and is identical for a byte-for-byte replay.

A replay therefore returns `.none` with zero side effects — no parts re-sent, no `status`/`retriesLeft`
reset, and no watchdog re-arm — so the watchdog continues from the last genuine request, fires on
schedule, decrements `proofRetriesLeft`, and the transfer reaches `.failed`; `LinkSession` removes it,
and the now-transfer-less responder link becomes evictable via the F11 fix.

## Data flow (after the fix)

```
Inbound RESOURCE_REQ for this transfer (decrypt + hash match pass):
   if packet.packetHash ∈ servedRequestHashes:  return .none   (replay — no re-send, no re-arm)
   else: insert; re-send requested parts; reset status/retries; armSenderWatchdog   (as today)

Peer silent, attacker replays:
   every replay is deduped → watchdog NOT re-armed → fires on schedule →
   .senderDeadline decrements proofRetriesLeft → eventually .failed →
   LinkSession removes the transfer → link evictable (F11).

Genuine re-request (fresh IV → new packetHash): served normally; watchdog re-armed legitimately.
```

## Edge cases

- **Re-request for the same still-missing parts:** identical plaintext, different ciphertext (fresh
  IV) → different `packetHash` → served. Recovery works.
- **`servedRequestHashes` growth:** transfer-scoped, bounded by the transfer's lifetime, removed with
  the transfer. No cap, matching reference.
- **F16 rider (out of scope):** the *link's* inactivity timer is still refreshed by the replay
  (LinkSession re-arms it on any link-addressed packet), so the link does not self-close via
  inactivity while replayed. But once the transfer self-terminates (this fix), the link is
  transfer-less and reclaimable under cap pressure (F11). F16 is a separate item.

## Testing

Three-step verification (green → mutate to red → revert). Tests at the `ResourceTransfer` sender
level; `TestClock` for watchdog timing. Model on existing `ResourceTransferTests.swift`
(`senderStore`, `resourceRequestPacket`, `senderAwaitingProofTimesOutThenFails`).

1. **Replay is a no-op.** Serve a genuine request (parts transmitted, `servedRequestHashes` size 1,
   watchdog armed). Send the byte-identical packet again → assert no `.transmit` effects and no state
   change (set size still 1). Mutation: remove the dedup guard → the replay re-transmits → fails.
2. **Freshly-encrypted re-request is served (legitimate retransmission).** Encrypt the *same request
   plaintext* again (fresh IV → different `packetHash`) and send it → assert the parts are
   re-transmitted. Mutation: key the dedup on the decrypted body instead of `packetHash` → this
   re-request is wrongly dropped → fails.
3. **The pin is broken (F19 regression).** After serving the request (`.awaitingProof`, watchdog
   armed for `rtt*proofTimeoutFactor + senderGrace`), loop: advance the clock by less than the
   window, replay the captured request, repeat until total elapsed exceeds the window. Assert the
   watchdog fires despite the replays (`proofRetriesLeft` decrements; transfer progresses toward
   `.failed`). Mutation: remove the dedup → each replay re-arms (`cancelInFlight`) the watchdog, the
   window never elapses, `proofRetriesLeft` stays pinned → fails.

## Accepted limitations

- **F16 (link inactivity refresh) is not closed here** — see the edge case. This fix removes the
  transfer-level pin (the transfer self-terminates despite replays) and lets F11 reclaim the link;
  the link's own inactivity timer refreshing on replayed traffic is a separate backlog item.

## Out of scope

- Any change to the `evictable` filter or link-level dedup (Options 2/3, and F16).
- A cap on `servedRequestHashes` (reference has none; transfer-scoped and self-bounding).
- Any wire-format change.
