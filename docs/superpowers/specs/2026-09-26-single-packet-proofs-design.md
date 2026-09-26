# Transport/LXMF — Single-packet delivery proofs — Design

**Date:** 2026-09-26
**Status:** Approved (design); spec under review
**Closes (partially):** `docs/reference-gap-analysis-2026-08-10.md` §1.6 and
`docs/reference-parity-checklist.md:604-606`. The relay part of that gap (a ReTiCA relay routing proofs for
third parties) stays open.
**Reference implementation:** RNS 1.4.2 / LXMF 1.1.0, as installed at
`/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/`.
**Downstream consumer:** ReTiCaMsgr (`/Users/ell/development/ios/apps/ReTiCaMsgr`). Its "message Info"
feature and honest delivery statuses are a separate project that builds on this one.

## Goal

1. When an opportunistic LXMF message arrives at one of our `lxmf.delivery` destinations, ReTiCA sends a
   reference-compatible delivery proof. Reference peers, and ReTiCA peers, then stop timing out on
   messages we actually received.
2. When ReTiCA sends an opportunistic LXMF message, it tracks a receipt. A valid proof produces
   `LXMFNode.Delegate.deliveryConfirmed(messageHash:)`.
3. The router tracks the direct/opportunistic copy and the propagation-node copy of a message
   separately, so one copy's outcome is never misreported as the other's.
4. `LXMFNode.Delegate.messageReceived` reports how a message arrived: opportunistic, direct, or
   propagated.

## Current state (why)

- **Proofs exist only inside links.** `LinkSession` has `pendingDataReceipts`, `sendWithReceipt`,
  `provePacket` and the matching 96-byte proof validation (`LinkSession.swift:92,188,654-664,928-975`).
  Transport's non-link switch handles only `.announce`, `.data` and `.linkRequest`, then
  `default: return .none` (`Transport.swift:722-723`). Non-link PROOF packets are dropped.
- **We never prove what we receive.** `Transport.swift:695-700` decrypts a single DATA packet and emits
  `.received(destinationHash:plaintext:)`, dropping the packet hash and the arrival interface.
  `LXMFNode.swift:600-601` forwards it to the router as `.opportunistic`. Nothing proves it.
- **We never learn that our sends arrived.** `LXMFRouter.send` (`LXMFRouter.swift:369-379`) arms a
  retry, then emits `.sendOpportunistic(destinationHash:payload:)` without the message hash.
  `Transport.send` (`Transport.swift:917-943`) records no packet hash. After
  `LXMFDelivery.maxAttempts` (5) × `retryWaitSeconds` (10 s), every opportunistic send ends in
  `deliveryFailed`, even when it was received.
- **One key for two copies.** `LXMFNode.sendMessage(alsoViaPropagation:)`
  (`LXMFNode.swift:456-494`) arms the opportunistic copy and the propagated copy under the same
  `message.hash`. `arm` overwrites (`LXMFRouter.swift:218-220`), and `.delivered(hash)`
  (`LXMFRouter.swift:543-550`) picks `propagationAccepted` or `deliveryConfirmed` from whichever copy
  was stored last.
- **Arrival method is lost.** Downloaded propagated messages are fed to the router as `.direct`
  (`LXMFNode.swift:584`), and `DeliveryMethod` is discarded after reconstruction
  (`LXMFRouter.swift:179`, `LXMFNode.swift:238`).

### Reference behaviour this mirrors

- Proving is done by the LXMF delivery callback, not by a destination proof strategy.
  `LXMRouter.delivery_packet` (LXMRouter.py:1926-1927) calls `packet.prove()` as its first statement,
  for opportunistic (non-link) packets too. LXMF 1.1.0 does not call `set_proof_strategy(PROVE_ALL)`.
- `Packet.prove` (Packet.py:327-331) → `Identity.prove` (Identity.py:942-953):
  - The signature is over `packet.packet_hash`.
  - The payload is the signature alone (*implicit*, 64 bytes) when `should_use_implicit_proof()`,
    which is the default (Reticulum.py:259). Otherwise it is `packet_hash + signature` (*explicit*,
    96 bytes).
  - The destination is `ProofDestination`: hash = `packet_hash[:16]`, type SINGLE.
  - It is sent as a PROOF packet, context NONE, on `packet.receiving_interface`.
- The sender validates proofs against outstanding `PacketReceipt`s (Transport.py:2334-2360,
  Packet.py:480-515).
- LXMF's inbound duplicate check comes *after* `packet.prove()`, so a resend of an already-received
  message is still proved.

## Design

### 1. Proving inbound opportunistic LXMF (Transport + LXMFNode)

- `Transport.Action.Delegate.received` gains `packetHash: Data` (the full 32-byte
  `Packet.packetHash`) and `interfaceID: InterfaceID`.
  `TransportEndpoint.Action.Delegate.messageReceived` gains the same two values and passes them
  through.
- New action `Transport.Action.proveSingle(packetHash: Data, interfaceID: InterfaceID, identity: Identity)`:
  - Builds `Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
    destinationType: .single, context: .none, contextFlag: false, hops: 0,
    destinationHash: packetHash.prefix(16), transportId: nil, payload: identity.sign(packetHash))`,
    the 64-byte implicit form.
  - Emits `.delegate(.transmit(interfaceID, raw))`, unencrypted.
  - Does nothing if the identity has no private key or the interface isn't registered.
  - `TransportEndpoint` exposes it as `.proveSinglePacket(packetHash:interfaceID:identity:)`.
- `LXMFNode`, handling `endpoint(.delegate(.messageReceived(destHash, plaintext, packetHash, interfaceID)))`
  where `destHash` is our registered delivery destination:
  1. Emits `.endpoint(.proveSinglePacket(packetHash:interfaceID:identity: <delivery identity>))`.
  2. Then forwards to the router exactly as today.
  3. The proof goes out **before** the router's `seen` dedup, so a resend of an already-delivered
     message is proved again, matching reference.
- Not proved:
  - packets to non-delivery destinations
  - link traffic (unchanged: already proved by `LXMFNode.swift:778-803`)
  - propagated downloads, which are not single packets addressed to us
- If the packet can't be decrypted or parsed as a message, it isn't proved. The proof is emitted only
  after `Transport` has successfully decrypted a packet for a local destination. LXMF-level
  malformation (the router's `reconstructed == nil`) is still proved, as in reference, where
  `packet.prove()` precedes unpacking.

### 2. Receipts for outbound opportunistic sends (Transport)

- `Transport.Action.send` gains `receiptToken: Data? = nil`. `TransportEndpoint.send` does the same.
  All existing callers pass nil and behave exactly as today.
- New state `Transport.State.pendingReceipts: [Data: PendingReceipt]`, keyed by
  `packetHash.prefix(16)`:

  ```swift
  public struct PendingReceipt: Equatable, Sendable {
      public var packetHash: Data      // full 32 bytes
      public var token: Data           // opaque to Transport (LXMF passes message.hash)
      public var identity: Identity    // recipient identity from learned[dest] at send time
      public var expiresAt: Date
  }
  ```

- On `.send(..., receiptToken: token?)` with a non-nil token, after the packet is built and packed:
  - Insert a receipt with `expiresAt = now + receiptTimeoutBase + receiptTimeoutPerHop * max(1, entry.hops)`.
    The constants are defined next to `establishmentTimeoutPerHop`, with the chosen values and a
    comment on how they map to reference's first-hop timeout + `TIMEOUT_PER_HOP * hops`.
  - The table is capped at `Transport.maxPendingReceipts`. When full, the entry with the soonest
    expiry is evicted.
- The inbound non-link switch gets a new `case .proof` for `packet.destinationType == .single`, before
  `default`:
  - Look up `pendingReceipts[packet.destinationHash]`.
  - **Implicit** (`payload.count == 64`): validate `identity.validate(signature: payload, message: receipt.packetHash)`.
  - **Explicit** (`payload.count == 96`): require `payload.prefix(32) == receipt.packetHash`, then
    validate the signature `payload.suffix(64)`.
  - If valid, remove the receipt and emit `.delegate(.singlePacketDelivered(token: receipt.token))`.
  - Otherwise, including an unknown hash or any other length, return `.none` and leave the receipt in place.
  - Proof packets are not deduped by `seenPacketHashes` ahead of this check, so a duplicate proof for an
    already-removed receipt just misses the lookup.
- `maintenanceTick` removes receipts with `expiresAt <= now`. An expired receipt emits nothing,
  because the LXMF router's own retry timer stays the only failure authority. That prevents the double
  retries that reusing `packetDeliveryFailed → retryDue` would cause.
- `TransportEndpoint` forwards `.singlePacketDelivered(token:)` as its own delegate case of the same
  name. It does not reuse `packetDelivered(token:)`, which remains link-only.

### 3. Router: separate copies, confirmation and failure (LXMFRouter + LXMFNode)

- `LXMFRouter.Delegate.sendOpportunistic` gains `messageHash: Data`. `LXMFNode` passes it as
  `receiptToken` to `.endpoint(.send(...))`. Each resend on `retryDue` sends a new packet with a new
  receipt and the same token, so a proof for any attempt confirms the message.
- `pendingDeliveries` and the retry `CancelID` are keyed by `DeliveryKey(messageHash: Data, leg: Leg)`,
  where `enum Leg { case delivery, propagated }`. `delivery` covers opportunistic and direct (link),
  including an opportunistic send that is promoted to direct because it doesn't fit in one packet.
  `arm` no longer overwrites the other copy.
- **Outcomes:**
  - New router action `.opportunisticDelivered(messageHash:)`, sent by `LXMFNode` on
    `endpoint(.delegate(.singlePacketDelivered(token)))`. It clears the `delivery` copy, cancels that
    copy's retry, and emits `.delegate(.deliveryConfirmed(messageHash:))`.
  - The existing `.delivered(messageHash:)` from `packetDelivered`: link DATA proofs resolve the
    `delivery` copy (`deliveryConfirmed`). PN small-container receipts resolve the `propagated` copy
    (`propagationAccepted`). The copy is chosen by which path produced the receipt, not by "whichever
    was armed last". `.resourceDeliveredOnLink` resolves the copy that owns `linkResourceInFlight`.
  - `.retryDue` is per copy. Once a copy passes `maxAttempts` it is marked failed.
    `.delegate(.deliveryFailed(messageHash:))` fires **only when every armed copy for that hash has
    failed**, and never after either copy succeeded.
  - Each success is reported independently, so a message can yield both `propagationAccepted` and
    `deliveryConfirmed`, in either order. Consumers decide how to present that.
- This makes ReTiCaMsgr's F5.5 guard (`AppFeature.swift:688-692`, "deliveryFailed must not clobber a
  propagation success") redundant. The app can keep the guard; it becomes unreachable.

### 4. Arrival method (LXMFRouter + LXMFNode)

- `LXMFRouter.DeliveryMethod` gains `.propagated`. `.received(method: .propagated, ...)` rebuilds the
  message with `LXMessage.unpack`, like `.direct`. `LXMFNode.swift:584` passes `.propagated` for
  downloaded messages.
- `LXMFRouter.Delegate.messageDelivered` and `LXMFNode.Delegate.messageReceived` gain
  `method: LXMFRouter.DeliveryMethod`. With duplicates, the first arrival wins because dedup
  (`state.seen`) is unchanged.

## Compatibility

- **Additive with defaults:** `receiptToken` (nil), the extra delegate associated values, and the new
  cases.
- **Breaking public shapes:** `Transport.Delegate.received`, `TransportEndpoint.Delegate.messageReceived`,
  `LXMFRouter.Delegate.sendOpportunistic`, `LXMFRouter.Delegate.messageDelivered` and
  `LXMFNode.Delegate.messageReceived`. Every internal pattern match and test is updated in this
  project.
- **ReTiCaMsgr:** a minimal compile fix in the app repo, in the same project. It updates the
  `messageReceived` pattern match in `AppFeature.swift` and every test that builds that action, adding
  `method:` and ignoring it. No behaviour change: the app keeps ignoring `deliveryConfirmed` until the
  follow-up Info project.
- **Wire compatibility:**
  - Reference peers already send implicit proofs and accept both forms, so our implicit proofs are
    accepted.
  - We accept both forms from them.
  - A ReTiCA peer on the old version never proves, so our sends to it keep ending in `deliveryFailed`
    exactly as today. No regression.

## Testing

Swift Testing plus TCA `TestStore`, following the repo's conventions. Every new test goes through
mutate → red → revert → green.

- **Reference vectors:** a new `Tests/ReTiCATransportTests/Vectors/generate_proof_fixtures.py`, run
  with the `rns` conda env, writes a JSON fixture containing:
  - a deterministic identity
  - a single DATA packet's raw bytes and `packet_hash`
  - `Identity.prove` output in implicit and explicit form
  - the full raw proof packet (header 1, PROOF, SINGLE, dest = `packet_hash[:16]`)

  Tests assert that ReTiCA's `.proveSingle` produces byte-identical proof packets, and that both
  reference forms validate against a matching receipt.
- **Transport:**
  - `.received` carries the hash and interface.
  - `.proveSingle` transmits on the arrival interface.
  - A send with a token records a receipt; without a token it records nothing.
  - A valid implicit or explicit proof emits `singlePacketDelivered` exactly once and removes the
    receipt.
  - A wrong signature, an unknown hash or a wrong length is ignored and leaves the receipt.
  - Expiry at `maintenanceTick` works, and the cap evicts the soonest expiry.
- **Router:**
  - The two copies are tracked independently.
  - A confirmation after the propagated copy is armed is still reported as `deliveryConfirmed`
    (regression test for the collision).
  - `deliveryFailed` fires only after every copy fails, and never after a success.
  - A resend's proof confirms the message.
  - `.resourceDeliveredOnLink` resolves the owning copy.
- **End-to-end** (two `LXMFNode`s over the mocked-TCP harness in `LXMFNodeOpportunisticTests.swift`):
  - A sends opportunistically, B proves, A gets `deliveryConfirmed` and no later `deliveryFailed`.
  - A variant drops B's first proof: A's resend is proved again although B's router dedups it.
  - A variant with a propagation node configured gets both outcomes, with no false failure.
- **Arrival method:** opportunistic, direct and propagated deliveries each report the correct `method`.
- **ReTiCaMsgr:** the full core suite stays green after the compile fix.

## Docs

- `docs/reference-gap-analysis-2026-08-10.md` §1.6: marked resolved for the endpoint, with a link to
  this spec. The relay reverse table stays open.
- `docs/reference-parity-checklist.md:604-606` gets the same update.
- The deferred path-rediscovery note in `docs/superpowers/specs/2026-07-28-lxmf-opportunistic-path-request-design.md`
  ("until opportunistic delivery gains a receipt") gets a pointer to this spec. Rediscovery itself
  stays out of scope.

## Amendments at planning time (2026-09-26)

Writing the plan against the real code surfaced these corrections. They override the text above
where they conflict.

1. **Proof vectors can't be byte-identical.** `Identity.sign` uses CryptoKit, whose Ed25519
   signatures are randomised; RNS signs deterministically. The vector test therefore:
   - byte-compares the proof packet's header, destination and context bytes;
   - checks that ReTiCA's signature validates;
   - requires that genuine reference proofs, in both implicit and explicit form, confirm a ReTiCA
     receipt.

   Switching to the IFAC-only `DeterministicSigner` is rejected.
2. **"Link DATA proofs resolve the delivery copy" matches no code.** Direct link packets go out via
   `sendOverLink` without a receipt. The only receipted link send is the propagated small container
   (`sendPropagatedPacket`). So:
   - `.delivered` takes an explicit `leg:` with no default;
   - `LXMFNode` maps `packetDelivered` and `packetDeliveryFailed` to `.propagated`;
   - `linkResourceInFlight` stores the owning `DeliveryKey`, so `.resourceDeliveredOnLink` resolves
     the copy that sent the Resource.

   `.delivered(messageHash:leg:)` and `.retryDue(messageHash:leg:)` join the list of breaking public
   shapes.
3. **What counts as "every armed copy has failed":**
   - A copy still queued behind its link counts as outstanding.
   - A success is remembered in a bounded ring (`succeededMessageMemory = 1024`) after its pending
     entry is gone, so a propagated copy armed late (after its stamp search) that then fails still
     cannot produce `deliveryFailed`.
   - The no-node `sendViaPropagation` case fails only its own copy, through the same failure helper.
   - `.send(desiredMethod: .propagated)` fails the delivery copy.
   - Accepted gap: if one copy fails, and another copy is armed later and also fails,
     `deliveryFailed` can fire twice.
4. **Chosen constants:** `receiptTimeoutBase = 6` s and `receiptTimeoutPerHop = 6` s (reference
   `DEFAULT_PER_HOP_TIMEOUT`), and `maxPendingReceipts = 1024` (reference `MAX_RECEIPTS`).
5. **The app compile fix is larger than stated.** Besides the `messageReceived` pattern, it also
   updates:
   - `DiagnosticsSnapshot.swift`, where `pendingDeliveries` is now keyed by `DeliveryKey`;
   - `DiagnosticsSnapshotTests`;
   - one `.sendOpportunistic` match in `AppFeatureTests`.

   It is done in an app worktree on branch `feat/retica-proofs-compat`, and is verified with a
   temporary, uncommitted path override. **Merge order:** ReTiCA's `feat/single-packet-proofs` must
   land in the ReTiCA checkout the app builds against before, or together with, the app branch.
6. The path-request spec's wording at :100 is "Revisit if/when opportunistic delivery gains a
   receipt". The docs update targets that line.

## Out of scope

- ReTiCA-as-relay routing proofs for third parties (reverse table, Transport.py:1690, 2340-2348).
- Destination proof strategies (PROVE_ALL / PROVE_APP) and proving arbitrary non-LXMF single packets.
- Receipt-driven retry/backoff changes and path rediscovery (`drop_path`) on missing proofs.
- Any ReTiCaMsgr UI or status change (the follow-up Info project).
- Ratchet-related proof behaviour. ReTiCA has no own-ratchet lifecycle, and proofs are unencrypted.
