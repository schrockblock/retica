# LXMF-4a: Inbound Router + Dedup — Design

**Sub-project:** LXMF-4 (LXMRouter), first sub-slice. LXMF-4 decomposes into **4a inbound delivery + dedup** (this), 4b outbound orchestration (method selection + link lifecycle + queue), 4c delivery receipts + retries, 4d propagation (own sub-project). Follows LXMF-1/2/3. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` (`LXMRouter.py:1837-1937` `lxmf_delivery`/`delivery_packet`).

**Goal.** A dedicated `LXMFRouter` TCA reducer that turns raw inbound deliveries (Endpoint's received events) into validated, de-duplicated LXMF messages surfaced once to the app.

## Problem

After LXMF-1/2/3, receiving a message is manual: the app must recognize the arrival method, reconstruct (`fromOpportunistic` vs `unpack`), validate the signature, and de-duplicate. The LXMRouter centralizes this. This slice builds its **receive side**: a mailbox that ingests deliveries from any path, validates + de-duplicates by `message.hash`, and delivers each unique message exactly once — the foundation the outbound/receipt/propagation slices attach to.

## How reference LXMF does it

`delivery_packet` (LXMRouter.py:1926-1937) reconstructs `lxmf_data` by arrival method — for a non-LINK (opportunistic) packet, `lxmf_data = destination.hash + data`; for a LINK packet/resource, `lxmf_data = data` (whole). `lxmf_delivery` (1837-1919) then: `unpack_from_bytes` → (stamp/ticket/blackhole checks — deferred) → **dedup**: `if not allow_duplicate and self.has_message(message.hash): return False` else record `locally_delivered_transient_ids[message.hash] = now` → fire `delivery_callback(message)`. The dedup key is `message.hash` (LXMF-1's message ID), and the message is delivered **regardless of signature validity** (`unpack_from_bytes` sets `signature_validated` true/false/unknown; the callback receives it flagged, not dropped). Only malformed data (`unpack` raises) or a duplicate is dropped.

## Architecture

New reducer `Sources/ReTiCANode/LXMFRouter.swift` (uses TCA → lives with the node reducers; depends on `ReTiCA` for `LXMessage`/`Identity` and `ReTiCATransport` for `RingSet`). **Decoupled from `Endpoint`** — the app forwards Endpoint's delivery + announce events into it, so the router is a self-contained message processor and a clean home for 4b/4c/4d.

### State
```swift
public struct State: Equatable {
    /// Dedup of already-delivered message IDs (LXMF message.hash). Bounded.
    var seen = RingSet(capacity: 10_000)
    /// sourceHash (sender's lxmf.delivery destination hash) → identity, for signature validation.
    public var knownIdentities: [Data: Identity] = [:]
    public init() {}
}
```

### Actions
```swift
public enum DeliveryMethod: Equatable { case opportunistic, direct }

public enum Action: Equatable {
    /// Populate the identity table (app forwards this from announces / pathLearned).
    case learnedIdentity(destinationHash: Data, identity: Identity)
    /// One inbound LXMF delivery. `.opportunistic` → reconstruct via fromOpportunistic(destinationHash, data);
    /// `.direct` (link packet or resource) → unpack(data) whole. `destinationHash` is our lxmf.delivery
    /// hash (used only for opportunistic reconstruction).
    case received(method: DeliveryMethod, destinationHash: Data, data: Data)
    case delegate(Delegate)

    public enum Delegate: Equatable {
        case messageDelivered(message: LXMessage, signatureValidated: Bool)
        case duplicateDropped(hash: Data)
    }
}
```

### Reducer
- `.learnedIdentity(h, id)` → `state.knownIdentities[h] = id`; `.none`.
- `.received(method, destinationHash, data)`:
  1. Reconstruct: `.opportunistic` → `LXMessage.fromOpportunistic(destinationHash: destinationHash, payload: data)`; `.direct` → `LXMessage.unpack(data)`.
  2. `guard let message = reconstructed else { return .none }` — malformed → dropped silently.
  3. Dedup: `guard state.seen.insert(message.hash) else { return .send(.delegate(.duplicateDropped(hash: message.hash))) }`.
  4. Validate: `let validated = state.knownIdentities[message.sourceHash].map { message.validateSignature(source: $0) } ?? false`.
  5. `return .send(.delegate(.messageDelivered(message: message, signatureValidated: validated)))`.

The message is always delivered when well-formed and new — validity is a flag, matching RNS. Dedup is by `message.hash` and therefore path-independent (the same message via opportunistic and direct is delivered once).

## Data flow

```
announce learned (app) ─▶ .learnedIdentity(senderDeliveryHash, senderIdentity) ─▶ knownIdentities[…]=id

Endpoint.messageReceived(deliveryHash, plaintext)  ─▶ .received(.opportunistic, deliveryHash, plaintext)
Endpoint.linkDataReceived(linkID, data)            ─▶ .received(.direct, _, data)
Endpoint.resourceReceived(linkID, data)            ─▶ .received(.direct, _, data)
        │
        ▼  reconstruct → unpack (nil ⇒ drop)
     dedup seen.insert(message.hash)?
        ├─ already seen → .delegate(.duplicateDropped(hash))
        └─ new → validated = knownIdentities[sourceHash]?.validate(message) ?? false
                 → .delegate(.messageDelivered(message, signatureValidated: validated))
```

## Testing

TCA `TestStore`, mutation-verified. No cross-validation fixture: the router is pure behavior over LXMF-1's already-cross-validated `packed`/`unpack`/`hash`; the only externally-defined value (`message.hash` as the dedup key) is validated in LXMF-1.

**Task 1 (reducer + delivery/validation):**
1. **Opportunistic delivers** — after `.learnedIdentity(senderDeliveryHash, senderId)`, `.received(.opportunistic, recipientDeliveryHash, msg.opportunisticPayload)` → `.messageDelivered(message: m, signatureValidated: true)` with `m.hash == msg.hash`, `m.content` correct.
2. **Direct delivers** — `.received(.direct, _, msg.packed)` → `.messageDelivered(_, true)`.
3. **Unknown source** — no `.learnedIdentity` → `.messageDelivered(_, signatureValidated: false)` (still delivered).
4. **Tampered signature** — known identity but a byte flipped in the reconstructed payload → `.messageDelivered(_, false)`.
5. **Malformed** — `.received(.direct, _, Data(count: 20))` → no delegate action (dropped).

**Task 2 (dedup + identity table):**
6. **Duplicate, same method** — the same message received twice → first `.messageDelivered`, second `.duplicateDropped(hash)`.
7. **Duplicate across methods (headline)** — the same message received `.opportunistic` then `.direct` (both reconstruct to equal `message.hash`) → delivered once, then `.duplicateDropped`.
8. **`learnedIdentity` populates** — `.learnedIdentity` sets `knownIdentities`, and a subsequent matching-source message validates `true` (vs `false` before it was learned).

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Signatures validated, never byte-compared (`ed25519-hedged-nondeterministic`).
- New production: `Sources/ReTiCANode/LXMFRouter.swift`; tests in `ReTiCANodeTests`. No changes to Endpoint/Transport/core in this slice (the Endpoint→router wiring is app-level, exercised by feeding the router `.received`/`.learnedIdentity` actions directly).
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
