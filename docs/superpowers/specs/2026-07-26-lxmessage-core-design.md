# LXMF-1: LXMessage Core — Design

**Sub-project:** LXMF (Lightweight Extensible Message Format), first slice. LXMF is the messaging layer atop Reticulum; it decomposes into LXMF-1 (LXMessage core, this slice), LXMF-2 (opportunistic delivery), LXMF-3 (direct delivery over a Link), LXMF-4 (LXMRouter + propagation), LXMF-5 (stamps/tickets). See `transport-relaying` memory for the Transport foundation this builds on.

**Reference pin:** `lxmf 1.1.0` (which pulled `rns 1.4.2` — the reference env baseline is now 1.4.2, up from 1.3.8; see the Cross-validation note). Source: `LXMF/LXMessage.py`.

**Goal.** A pure, zero-dependency `LXMessage` value type with deterministic pack/unpack, Ed25519 signing, and message-ID hashing — byte-compatible with reference LXMF. The foundation every later LXMF slice builds on.

## Problem

ReTiCA has the full Reticulum substrate (Destinations, Identity, Transport, Links, Resources) but no message format on top. LXMF defines the message envelope RNS applications exchange. Before any delivery (opportunistic/direct/propagated) can be built, we need the message object itself: how it is packed to bytes, signed, and identified — byte-for-byte compatible with reference LXMF so a genuine LXMF peer accepts our messages and we accept theirs.

## Scope

**In scope:**
1. An `LXMessage` value type: destination hash, source hash, timestamp, title, content, plus the derived message hash (ID) and signature.
2. Deterministic `pack` → wire bytes, with Ed25519 signing over the defined signed part and SHA-256 message-ID hashing over the defined hashed part.
3. `unpack` → parse wire bytes back to an `LXMessage` (structure + recomputed hash), and a separate signature-validation step against a resolved source identity.
4. Byte-level cross-validation against genuine `lxmf 1.1.0`.

**Out of scope / deferred:**
- **Rich `fields`.** LXMF `fields` is a msgpack map with **integer keys** (the `FIELD_*` constants). ReTiCA's `MsgPack.Pair` is string-keyed, so LXMF-1 supports only an **empty** fields map (plain messages: title + content). Rich fields require a MsgPack integer-key extension (encode ordering + decode) plus the `FIELD_*` value types — a dedicated later slice. This does not block opportunistic delivery (LXMF-2), which carries plain messages.
- **Stamps/tickets** (proof-of-work spam mitigation, `LXMessage.py:277-320`, the optional 5th payload element) — LXMF-5.
- **Delivery** (opportunistic/direct/propagated packing, `as_packet`/`as_resource`, propagation containers) — LXMF-2+.

## Wire format

From `LXMF/LXMessage.py` (`pack` 355-388, `unpack_from_bytes` 747-768):

```
DESTINATION_LENGTH = TRUNCATED_HASHLENGTH/8 = 16
SIGNATURE_LENGTH   = SIGLENGTH/8            = 64

payload      = [ timestamp, title, content, fields ]           # msgpack array of 4
  timestamp  : float64   (Python time.time(); msgpack 0xCB)
  title      : bin       (utf-8 bytes; msgpack bin 0xC4…)
  content    : bin       (utf-8 bytes; msgpack bin 0xC4…)
  fields     : map       (LXMF-1: empty → msgpack fixmap 0x80)

hashedPart   = destinationHash ‖ sourceHash ‖ msgpack(payload)
hash / msgID = SHA-256(hashedPart)                              # 32 bytes (RNS full_hash)
signedPart   = hashedPart ‖ hash
signature    = source.sign(signedPart)                          # Ed25519, 64 bytes, deterministic

packed       = destinationHash(16) ‖ sourceHash(16) ‖ signature(64) ‖ msgpack(payload)
```

Note the reference computes `hash` over the **4-element** payload, then (only if a stamp is present, deferred) appends a 5th element before the final `msgpack(payload)` in `packed`. With no stamp (LXMF-1), the msgpack in `hashedPart` and in `packed` are identical.

## Architecture

New pure file `Sources/ReTiCA/LXMF/LXMessage.swift`, depending only on `Identity` (`sign`/`validate`/`hash`), `Crypto.fullHash` (SHA-256), and `MsgPack`. No TCA, no Transport, no I/O — mirrors the `Packet`/`Announce` layering.

### Type

```swift
public struct LXMessage: Equatable {
    public let destinationHash: Data          // 16
    public let sourceHash: Data               // 16
    public let timestamp: Double
    public let title: Data                     // utf-8 bytes (may be empty)
    public let content: Data                   // utf-8 bytes (may be empty)
    public let hash: Data                      // 32 — message ID (SHA-256 of hashedPart)
    public let signature: Data                 // 64 — Ed25519 over signedPart
}
```

`title`/`content` are stored as `Data` (matching the reference's bytes), with String conveniences (`titleString`/`contentString` decoding utf-8; a `create` overload accepting `String` title/content).

### API

- `static func create(source: Identity, destinationHash: Data, timestamp: Double, title: Data, content: Data) -> LXMessage`
  - `sourceHash = source.hash`; builds `payload = [timestamp, title, content, emptyMap]`; `hashedPart = destinationHash ‖ sourceHash ‖ msgpack(payload)`; `hash = Crypto.fullHash(hashedPart)`; `signedPart = hashedPart ‖ hash`; `signature = source.sign(signedPart)`. Returns the fully-populated value.
  - A `String` convenience overload encodes title/content as utf-8.

- `var packed: Data`
  - `destinationHash ‖ sourceHash ‖ signature ‖ msgpack(payload)`.

- `static func unpack(_ data: Data) -> LXMessage?`
  - Guards `data.count >= 16 + 16 + 64` and count-based slices `destinationHash`, `sourceHash`, `signature`, `packedPayload`.
  - `MsgPack.decodeValue(packedPayload)` must be a 4-element array `[double, bin, bin, map]`; returns `nil` otherwise (this cleanly rejects rich-field messages — their integer-keyed map fails to parse — and any malformed input).
  - Recomputes `hash = Crypto.fullHash(destinationHash ‖ sourceHash ‖ msgpack(payload))` from the parsed payload (re-encoded), so `hash` is trustworthy independent of the wire bytes.
  - Returns the `LXMessage` with the parsed `signature` (validation is separate).

- `func validateSignature(source: Identity) -> Bool`
  - Recomputes `hashedPart`/`signedPart` from this message's fields and returns `source.validate(signature: signature, message: signedPart)`. The caller resolves the source `Identity` by `sourceHash` (from known destinations / announces).

Empty fields map: `MsgPack.encode(.map([]))` → `0x80`, and `create` always includes it as the 4th payload element (wire-required).

## Data flow

```
create(source, destHash, ts, title, content)
   → payload = [ts, title, content, {}]
   → hashedPart = destHash ‖ sourceHash ‖ msgpack(payload)
   → hash = SHA-256(hashedPart);  signature = source.sign(hashedPart ‖ hash)
   → LXMessage{…, hash, signature}
        │ .packed = destHash ‖ sourceHash ‖ signature ‖ msgpack(payload)
        ▼ (wire)
unpack(bytes) → slice dh/sh/sig/payload → decode payload (nil if not [double,bin,bin,map])
             → recompute hash → LXMessage
validateSignature(source) → source.validate(signature, hashedPart ‖ hash)
```

## Testing

Swift Testing, mutation-verified per the three-step protocol.

**Task 1 (core):**
1. **Round-trip** — `create` → `packed` → `unpack` recovers destinationHash/sourceHash/timestamp/title/content and the same `hash`; `validateSignature(source)` is `true`.
2. **Tamper** — flip a byte in the content region of `packed` → `unpack` still parses but `validateSignature` is `false` (and the recomputed `hash` differs from a pristine message's).
3. **Message-ID stability** — two `create` calls with identical inputs produce the same `hash` and the same `signature` (deterministic); differing content produces a different `hash`.
4. **Malformed / rich-fields rejection** — `unpack` returns `nil` for truncated input and for a payload whose 4th element is a non-empty (integer-keyed) map.

**Task 2 (cross-val vs genuine lxmf 1.1.0):**
5. A generator (`generate_lxmf_fixtures.py`, run via the conda `rns` env) creates a genuine `LXMF.LXMessage`, assigns a **fixed** `timestamp`, packs it, and emits: the source identity's private key (`get_private_key()`), the destination hash, the timestamp, title, content, and the reference `.packed` / `.hash` / `.signature` (all hex).
6. Our test loads the identity via `Identity(privateKey:)`, calls `create(...)` with the identical inputs, and asserts **byte-identical** `packed`, `hash`, and `signature`. It also `unpack`s the reference `.packed`, asserts the recovered fields match, and that `validateSignature(against the loaded identity)` is `true`. Ed25519 determinism makes the signature comparison exact. Non-circular: the reference bytes come from genuine LXMF; our independent implementation must reproduce them.

**Load-bearing assumption:** the byte-identical `signature` comparison requires RNS `Identity.get_private_key()` bytes to load into ReTiCA's `Identity(privateKey:)` as the same key (ReTiCA expects `encSeed(halfKey) ‖ sigSeed(halfKey)`). This private-key round-trip has not been exercised before (prior cross-val recovered only public keys). If the formats differ, the signature match will fail; the fix is to reconcile the private-key layout (not to weaken the assertion) or, if genuinely incompatible, fall back to validating the reference signature with the reference public key (`Identity(publicKey:)`) plus a separate deterministic-pack check — escalate rather than paper over.

## Cross-validation note (reference baseline shift)

Installing `lxmf 1.1.0` upgraded the conda `rns` env from `rns 1.3.8` to `rns 1.4.2` (lxmf 1.1.0 requires rns ≥ 1.4.0). The committed Transport `transport_fixtures.json` was generated against 1.3.8 and is static, so existing tests are unaffected. **Before regenerating any Transport fixture in future**, verify a 1.4.2-generated announce/path-request still byte-matches the committed 1.3.8 vectors (Reticulum's wire format is normally stable across minor versions). LXMF-1 fixtures are generated fresh against lxmf 1.1.0 / rns 1.4.2. The `rns-reference-env` memory should record the new baseline.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Cross-val fixtures MUST drive genuine LXMF (`cross-validation-drive-real-rns`).
- Pure core only: changes confined to `Sources/ReTiCA/LXMF/LXMessage.swift`, its tests, and a new LXMF fixture generator/vectors. No TCA/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
