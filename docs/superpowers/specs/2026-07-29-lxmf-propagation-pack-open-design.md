# LXMF-4d-2a: Propagation Pack/Open (recipient crypto) — Design

**Sub-project:** LXMF-4d (propagation). Second slice; first half of 4d-2. LXMF-4d: 4d-1 container+transient_id [done] → **4d-2a pack/open crypto [this]** → 4d-2b router PROPAGATED orchestration → 4d-3 PN store+serve → 4d-4 client sync → 4d-5 mesh. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMessage.pack()` PROPAGATED branch (`LXMessage.py:429-436`): `lxmf_data = packed[:16] + destination.encrypt(packed[16:])`.

## Goal

Complete the recipient-encryption boundary explicitly deferred from 4d-1: turn a message + the recipient's identity into a propagation container (`pack`), and recover the message from a container entry (`open`). This closes 4d-1's deferred decrypt-and-validate round trip and provides the `pack`/`open` primitives reused by the send path (4d-2b) and the receive path (4d-4).

## The operation

Genuine LXMF encrypts the message's delivery tail to the recipient's `lxmf.delivery` destination, then hashes/containers it (4d-1):

```
tail       = message.packed[16:]                          # sourceHash ‖ signature ‖ payload_msgpack
encrypted  = recipientDestination.encrypt(tail)           # ECDH to the recipient (ephemeral key + IV → hedged)
lxmf_data  = message.destinationHash ‖ encrypted          # (4d-1 lxmfData)
transient_id / propagation_packed                         # (4d-1 transientId / container)
```

For a SINGLE destination, `Destination.encrypt` delegates to `Identity.encrypt` (`Destination.swift:76`), so encrypting to the recipient's delivery destination is `recipientIdentity.encrypt(tail)` — the SAME operation opportunistic delivery uses (`Transport.swift:450`). Our `Identity.encrypt(_:ratchet:)` is hedged (random ephemeral key + IV); `Identity.decrypt(_:ratchets:)` falls back to the static key when no ratchet is supplied.

## Scope

**In** — extend the pure `LXMFPropagation` namespace (new file `Sources/ReTiCA/LXMF/LXMFPropagation+Message.swift`; depends on `LXMessage`, `Identity`, and the 4d-1 helpers — all core):

```swift
extension LXMFPropagation {
    /// Build the propagation container for `message`, encrypting its delivery tail to `recipientIdentity`.
    /// Returns the container bytes and the transient_id of the (single) entry. The encryption is hedged
    /// (ephemeral) — the bytes differ per call, so callers that retry must reuse the returned container.
    public static func pack(message: LXMessage, recipientIdentity: Identity, timestamp: Double)
        -> (propagationPacked: Data, transientId: Data)

    /// Recover the LXMessage from one container entry by decrypting its tail with `recipientIdentity`.
    /// Returns nil if the entry is malformed or decryption/unpack fails.
    public static func open(lxmfData: Data, recipientIdentity: Identity) -> LXMessage?
}
```

- `pack`: `let tail = Data(message.packed.dropFirst(LXMessage.destinationLength))`; `let encrypted = recipientIdentity.encrypt(tail)`; `let entry = lxmfData(destinationHash: message.destinationHash, encryptedData: encrypted)`; return `(container(timestamp: timestamp, entries: [entry]), transientId(lxmfData: entry))`.
- `open`: `guard let destHash = destinationHash(lxmfData: lxmfData) else return nil`; `let encrypted = Data(lxmfData.dropFirst(LXMessage.destinationLength))`; `guard let tail = recipientIdentity.decrypt(encrypted) else return nil`; `return LXMessage.unpack(destHash + tail)`.

**Out (deferred):** ratchet-based encryption (RNS uses `destination.latest_ratchet_id`; default no ratchet — `pack` uses the static key via `encrypt(_:ratchet: nil)`; revisit with LXMF ratchet support). Router orchestration, PN link, resource transfer → 4d-2b. Sync/receive wiring → 4d-4.

## Architecture

`pack`/`open` sit beside the 4d-1 wire helpers, in an extension file so the pure-wire concern (4d-1) stays separate from the crypto concern (4d-2a). Both are core; no TCA, no Transport. This is the exact inverse pair the send and receive paths need, defined and validated once.

## Cross-validation

Reuses the **existing** `lxmf_propagation_fixtures.json` from 4d-1 (already emits `recipient_private_key`, `source_private_key`, `destination_hash`, `title`, `content`, `propagation_packed`). No new fixture. Add tests to `LXMFPropagationCrossValidationTests.swift`:

1. **`open` recovers the genuine reference message.** Build `recipientIdentity` from `recipient_private_key` and `source` from `source_private_key`; `parseContainer(reference propagation_packed)` → `lxmf_data`; `open(lxmfData:, recipientIdentity:)` returns a message whose `content == reference content`, `destinationHash == reference destination_hash`, and `validateSignature(source:) == true`. This proves **our decrypt matches genuine LXMF's encrypt** through real reference ciphertext.
2. **`pack → open` round trip (our encrypt → our decrypt).** Create a fresh `LXMessage` to `reference destination_hash`; `pack(message:, recipientIdentity:, timestamp:)`; `parseContainer` the result; `open` the entry; the recovered message's `hash`/`content` match the original and `validateSignature(source:)` holds. Also assert the returned `transientId == transientId(lxmfData: parsedEntry)` (self-consistency).

The hedged encryption means our `pack` output is never byte-compared (ciphertext is ephemeral); correctness is proven by the round trip and by validating a genuine reference message. The reference `transient_id` remains pinned by 4d-1 (unchanged).

## Testing

The two cross-val/round-trip tests above are the whole surface (pure functions). Mutation-verify each. No TCA tests.

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- Encryption is hedged/ephemeral → never byte-compare `pack` output or ciphertext; validate round trips and signatures instead (`ed25519-hedged-nondeterministic` generalizes to encryption).
- Cross-val drives genuine LXMF (reuses the 4d-1 fixture, which was generated from real LXMF; no hand-rolling). Reference env: conda `rns` (`rns-reference-env`).
- New production is pure core (`Sources/ReTiCA/LXMF/LXMFPropagation+Message.swift`); tests in `ReTiCATests`. No ReTiCANode/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
