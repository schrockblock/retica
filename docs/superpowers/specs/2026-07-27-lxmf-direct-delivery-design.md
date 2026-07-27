# LXMF-3: Direct Delivery Over a Link — Design

**Sub-project:** LXMF, third slice. Follows LXMF-1 (LXMessage core) and LXMF-2 (opportunistic delivery). See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` (`LXMessage.py:417-424, 636`; `LXMRouter.py:1936-1937`), `rns 1.4.2` (`RNS.Link.MDU`).

**Goal.** Deliver an LXMF message over an established Link to the recipient's `lxmf.delivery` destination — as a single link packet if it fits, else as a Resource — enabling messages larger than a single opportunistic packet.

## Problem

LXMF-2 delivers a small message as one opportunistic DATA packet; content exceeding a packet makes `Transport.send` return `.tooLarge`. LXMF's answer is **DIRECT** delivery over a Link: for a message that fits a link packet, send the whole `packed` as a single link packet; for a larger one, send it as a Resource (the multi-packet, windowed transfer we already built). This unlocks arbitrarily large LXMF messages and is the reliable-delivery path (a link is acknowledged/proven).

## How reference LXMF does it

- **Send** (`LXMessage.py:417-424, 636`): the delivery destination is an established `RNS.Link` to the recipient's `lxmf.delivery` destination. If `content_size <= LINK_PACKET_MAX_CONTENT` → `RNS.Packet(link, packed)` (the **whole** `packed` — NOT stripped of the destination hash, because a link is addressed by its link id, not a destination hash); else → `RNS.Resource(packed, link)`.
- **Receive** (`LXMRouter.py:1930-1937`): for a LINK-delivered packet, `lxmf_data = data` (the whole `packed`, no prepend — unlike opportunistic, which prepends the destination hash); for a resource, `lxmf_data = resource.data`. Then `LXMessage.unpack_from_bytes(lxmf_data)`.

## The threshold reduces to `packed.count <= Link.MDU`

RNS chooses packet vs resource by `content_size <= LINK_PACKET_MAX_CONTENT`, where `LINK_PACKET_MAX_CONTENT = RNS.Link.MDU − LXMF_OVERHEAD` and `LXMF_OVERHEAD = 2·16 + 64 + TIMESTAMP_SIZE + STRUCT_OVERHEAD`. Since `packed = destinationHash(16) ‖ sourceHash(16) ‖ signature(64) ‖ packed_payload` (so `packed.count = 96 + packed_payload.count`) and `content_size = packed_payload.count − TIMESTAMP_SIZE − STRUCT_OVERHEAD`:

```
content_size + LXMF_OVERHEAD
  = (packed_payload.count − TIMESTAMP − STRUCT) + (96 + TIMESTAMP + STRUCT)
  = packed_payload.count + 96
  = packed.count
```

So `content_size ≤ LINK_PACKET_MAX_CONTENT`  ⟺  `content_size + LXMF_OVERHEAD ≤ RNS.Link.MDU`  ⟺  **`packed.count ≤ RNS.Link.MDU`**. `RNS.Link.MDU = 431` (the same value `LinkSession.requestMDU` already uses).

## Scope

**In scope:**
1. A core `Link.mdu = 431` constant (RNS `Link.MDU`) and a pure `LXMessage.directRepresentation` choosing packet vs resource by `packed.count <= Link.mdu`.
2. End-to-end delivery of the whole `packed` over an established link — as a link packet, and as a Resource — and its reconstruction via `unpack` on receipt.

**Out of scope / deferred → LXMF-4 (LXMRouter):**
- Automatic link lifecycle: establishing/reusing a `direct_link`, queuing a message until the link is up, inactivity teardown.
- Method selection (opportunistic vs direct vs propagated) and the opportunistic→direct size fallback orchestration.
- Delivery receipts/retries, propagation nodes.
- Stamps/tickets and rich integer-keyed fields (LXMF-5 / LXMF-1 boundary).

The link lifecycle here is driven by the test/app via existing `Endpoint` actions (`openLink` → `linkEstablished`), exactly as the existing two-Endpoint link tests do.

## Architecture

- **`Sources/ReTiCA/Link/Link.swift`** — add `public static let mdu = 431   // RNS Link.MDU`.
- **`Sources/ReTiCA/LXMF/LXMessage+Direct.swift`** (new, pure) —
  ```swift
  extension LXMessage {
      public enum DirectRepresentation: Equatable { case packet, resource }

      /// How this message is delivered over a Link (DIRECT method): a single link packet if the whole
      /// `packed` fits the link MDU, else a Resource. Reference LXMF compares `content_size` to
      /// `LINK_PACKET_MAX_CONTENT = Link.MDU − LXMF_OVERHEAD`, which reduces exactly to
      /// `packed.count <= Link.mdu` (LXMessage.py:417-424).
      public var directRepresentation: DirectRepresentation {
          packed.count <= Link.mdu ? .packet : .resource
      }
  }
  ```
  Delivery sends the **whole `packed`** (there is no direct-specific payload transform — unlike opportunistic's `packed.dropFirst(16)`).

The send/receive wiring uses existing `Endpoint`/`LinkSession`/`Resource` machinery; no new production module beyond the constant + the pure helper.

## Data flow

```
SENDER                                             RECIPIENT
                                    (owns <recipient>.lxmf.delivery, announces it)
  learns recipientDeliveryHash  ◀── announce ──────
  openLink(recipientDeliveryHash) ── LINKREQUEST/LRPROOF/LRRTT ──▶  link established (both sides)
  msg = LXMessage.create(source:…, destinationHash: recipientDeliveryHash, …)
  switch msg.directRepresentation {
    case .packet:   sendOverLink(linkID, msg.packed)        ─ link packet ─▶ linkDataReceived(linkID, data)
    case .resource: sendResourceOverLink(linkID, msg.packed) ─ resource ───▶ resourceReceived(linkID, data)
  }                                                          data == msg.packed
                                                             m = LXMessage.unpack(data)
                                                             m.validateSignature(source: learned sender)  ✓
                                                             m.content == original                        ✓
```

## Testing

Swift Testing, mutation-verified per the three-step protocol.

**Task 1 (helper + cross-val):**
1. `directRepresentation == .packet` for a small message (short title/content → `packed.count <= 431`); `== .resource` for a message whose `packed` exceeds 431 (long content); boundary check just above/at 431.
2. Cross-val: `Link.mdu == RNS.Link.MDU` (a fixture emits `RNS.Link.MDU`; assert equal to `431`). Document the algebra parity (our `packed.count <= Link.mdu` ⟺ RNS `content_size <= LINK_PACKET_MAX_CONTENT`).

**Task 2 (end-to-end integration):** over the two-Endpoint link harness (mirroring `twoEndpointsEstablishLinkExchangeDataAndClose` / `twoEndpointsTransferAResourceOverALink`):
3. **Packet path** — recipient announces `lxmf.delivery`, sender learns + opens a link; sender creates a small `LXMessage` (`directRepresentation == .packet`) and `sendOverLink(linkID, msg.packed)`; recipient `linkDataReceived(linkID, data)` → `unpack(data)` → validates against the learned sender identity → content matches.
4. **Resource path (headline)** — same setup, but a **large** message (`packed.count > 431`, `directRepresentation == .resource`); sender `sendResourceOverLink(linkID, msg.packed)`; recipient `resourceReceived(linkID, data)` → `unpack(data)` → validates → content matches. Proves a message too large for opportunistic delivery arrives intact.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Cross-val fixtures MUST drive genuine RNS/LXMF (`cross-validation-drive-real-rns`); reference is now `rns 1.4.2` / `lxmf 1.1.0` (`rns-reference-env`).
- Signatures + encrypted/resource payloads validated, never byte-compared (`ed25519-hedged-nondeterministic`).
- New: `Link.mdu` constant + `LXMessage+Direct.swift` (pure); tests in `ReTiCATests` (unit/cross-val) and `ReTiCANodeTests` (end-to-end). No new production module.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
