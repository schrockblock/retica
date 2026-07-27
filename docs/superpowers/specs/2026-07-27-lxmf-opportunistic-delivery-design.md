# LXMF-2: Opportunistic Delivery — Design

**Sub-project:** LXMF, second slice. Follows LXMF-1 (LXMessage core). See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0`, `LXMessage.py` (`pack` 404-415, `__as_packet` 633-634).

**Goal.** Send and receive a small LXMF message as a single encrypted packet to a recipient's `<identity>.lxmf.delivery` destination — the first end-to-end LXMF message over the real Transport/Endpoint/Destination stack.

## Problem

LXMF-1 gave us the `LXMessage` value type (pack/unpack/sign/validate) but no way to move a message between nodes. LXMF's simplest delivery is **opportunistic**: for a message small enough to fit one packet, send it as a single encrypted DATA packet to the recipient's `lxmf.delivery` destination — fire-and-forget, no link. This is the minimal path to a working message and the foundation the richer methods (direct/link, propagated) extend.

## How reference LXMF does it

Opportunistic delivery (`LXMessage.py:404-415, 633-634`):
```
lxm_packet = RNS.Packet(delivery_destination, packed[DESTINATION_LENGTH:])
```
- `delivery_destination` = the recipient's `<identity>.lxmf.delivery` OUT/SINGLE destination.
- Packet payload = `packed[16:]` = `sourceHash(16) ‖ signature(64) ‖ msgpack(payload)` — the full LXMessage minus its leading `destinationHash` (redundant on the wire, since the RNS packet header carries the destination hash).
- `RNS.Packet(destination, data)` for a SINGLE destination **encrypts** `data` to the destination's identity.

On receipt, the recipient owns the `lxmf.delivery` destination; RNS decrypts the packet, and the LXMF router prepends the destination hash to reconstruct `packed = destination.hash + decrypted_payload`, then `LXMessage.unpack_from_bytes(packed)`.

## Key insight — this maps onto existing ReTiCA machinery

- **Send:** `Transport.send(destinationHash:, plaintext:)` (Transport.swift:445-461) looks up the learned destination, **encrypts `plaintext` to its identity** (with ratchet), and builds the DATA packet (HEADER_1 direct or HEADER_2 via relay). Feeding it `plaintext = msg.packed.dropFirst(16)` toward `recipientDeliveryHash` produces exactly the reference opportunistic packet.
- **Receive:** the recipient's `Endpoint` owns the `lxmf.delivery` destination (a registered local destination); `Transport` decrypts an inbound DATA packet and surfaces `Endpoint.Delegate.messageReceived(destinationHash: deliveryHash, plaintext: packed[16:])`.

So the only new code is two pure transforms on `LXMessage`. The encryption, routing, announce/learn, and decryption are all existing, cross-validated machinery.

## Scope

**In scope:**
1. `LXMessage.opportunisticPayload` — the plaintext to hand `Transport.send`.
2. `LXMessage.fromOpportunistic(destinationHash:payload:)` — reconstruct a received opportunistic message.
3. An end-to-end integration test: a real LXMF message delivered node-to-node.

**Out of scope / deferred:**
- DIRECT (link) and RESOURCE delivery for larger messages → LXMF-3.
- PROPAGATED delivery, LXMRouter (outbound/inbound queues, retries, `transient_id` dedup, delivery receipts/callbacks) → LXMF-4.
- Stamps/tickets and rich integer-keyed fields → LXMF-5 (LXMF-1 boundary).
- Automatic size-based method fallback (opportunistic→direct). Oversized content makes `Transport.send` return `.tooLarge`; choosing a fallback is the app's/LXMF-3's concern.

## Architecture

Pure additions to `LXMessage` (in `Sources/ReTiCA/LXMF/LXMessage.swift` or an extension). No new module, no TCA — the send/receive wiring uses the existing `Transport`/`Endpoint` actions.

```swift
extension LXMessage {
    /// The plaintext for an opportunistic send: `packed` minus the leading destinationHash (the RNS
    /// packet header carries the destination). Hand this to Transport.send toward the recipient's
    /// `lxmf.delivery` destination (LXMessage.deliveryHash(recipientIdentityHash)), which encrypts it.
    /// (LXMessage.py:634 — RNS.Packet(delivery_destination, packed[DESTINATION_LENGTH:]).)
    public var opportunisticPayload: Data {
        Data(packed.dropFirst(LXMessage.destinationLength))
    }

    /// Reconstruct a message received opportunistically: prepend our `lxmf.delivery` destination hash
    /// (which the packet header carried, not the payload) to the decrypted `payload`, then unpack.
    /// `destinationHash` is our delivery-destination hash; `payload` is the decrypted `.received`
    /// plaintext. Returns nil if malformed (LXMF-1 unpack rules). Signature validation is separate.
    public static func fromOpportunistic(destinationHash: Data, payload: Data) -> LXMessage? {
        unpack(destinationHash + payload)
    }
}
```

## Data flow

```
SENDER                                              RECIPIENT
                                    (owns <recipient>.lxmf.delivery IN/SINGLE dest, announces it)
  learns recipientDeliveryHash  ◀── announce ───────
  msg = LXMessage.create(source: senderIdentity,
        destinationHash: recipientDeliveryHash, …)
  Transport.send(recipientDeliveryHash,
                 msg.opportunisticPayload)
        │  (encrypt to recipient identity + DATA packet)
        └────────────── DATA packet ──────────────▶ Transport decrypts → Endpoint
                                                     .messageReceived(deliveryHash, plaintext)
                                                     m = LXMessage.fromOpportunistic(
                                                           destinationHash: deliveryHash,
                                                           payload: plaintext)
                                                     m.validateSignature(source: senderIdentity)  ✓
                                                     m.content == original                        ✓
```

The recipient resolves the sender identity from the message's `sourceHash` (the sender's `lxmf.delivery` destination hash) via a prior announce of the sender's delivery destination (RNS `Identity.recall`), or knows it out-of-band.

## Testing

Swift Testing, mutation-verified per the three-step protocol.

**Task 1 (helpers + cross-val):**
1. `opportunisticPayload == packed.dropFirst(16)` and has length `packed.count - 16`.
2. Round-trip: `fromOpportunistic(destinationHash: msg.destinationHash, payload: msg.opportunisticPayload)` reconstructs a message equal to `msg` (same hash/fields) that `validateSignature(source:)` accepts.
3. Malformed: `fromOpportunistic` returns `nil` when `destinationHash + payload` is too short / not a valid LXMF payload.
4. Cross-val (reuse the LXMF-1 fixture): `fromOpportunistic(destinationHash: f.destinationHash, payload: genuinePacked.dropFirst(16))` reconstructs the genuine reference message — recovered `hash`/`content` match, and `validateSignature(source: identity-loaded-from-fixture-key)` is `true`. (The opportunistic payload IS `genuinePacked[16:]`; this validates the reconstruction direction against genuine LXMF bytes.)

**Task 2 (end-to-end integration):**
5. Two nodes (Transport or Endpoint stores over a mock interface, mirroring the existing two-node tests). The recipient registers its `lxmf.delivery` destination and announces it; the sender learns it. The sender builds an `LXMessage` and sends `opportunisticPayload` via `Transport.send`/`Endpoint.send`. The recipient surfaces `messageReceived(deliveryHash, plaintext)`; `fromOpportunistic` reconstructs the message; `validateSignature` against the sender identity is `true`; and the decrypted `content`/`title` equal what the sender sent. This proves a real LXMF message delivers over the genuine encrypt→route→decrypt path. (The recipient obtains the sender identity via the sender also announcing its `lxmf.delivery` destination, or is given it directly.)

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Cross-val fixtures MUST drive genuine LXMF (`cross-validation-drive-real-rns`); reuse the committed LXMF-1 fixture where possible.
- ReTiCA signatures are hedged/randomized (`ed25519-hedged-nondeterministic`): validate signatures, never byte-compare them; and the opportunistic packet's encrypted payload is non-deterministic (ephemeral keys) — assert via decrypt+reconstruct+validate, not byte-identity.
- Pure additions to `LXMessage` + tests; the end-to-end test may live in the Transport or Node test target. No new production module.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
