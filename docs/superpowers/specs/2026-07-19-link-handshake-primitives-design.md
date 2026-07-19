# Link Handshake Primitives — Design

**Date:** 2026-07-19
**Status:** Approved
**Sub-project:** #6 (slice 5-links-a) of the native iOS Reticulum (RNS) implementation

## Context

Sub-projects #1–#5 are complete and merged: the pure `ReTiCA` core (crypto, Identity,
Packet, Destination, Announce, HDLC), the TCA `ReTiCAInterfaces` / `ReTiCATransport` /
`ReTiCANode` layers forming a working endpoint. The library can connect to a Reticulum
network, hear announces, and exchange single packets with known destinations.

This slice adds the **cryptographic primitives of Reticulum Links** — encrypted end-to-end
sessions with forward secrecy. Links are RNS's ~1,460-line subsystem; per the project's
established pattern (pure format/crypto first, TCA state machine second), this slice
delivers only the **pure, byte-exact handshake crypto**. The stateful Link reducer
(PENDING→HANDSHAKE→ACTIVE→CLOSED, initiator/responder orchestration, RTT, keepalives,
requests/responses, close/identify) is deferred to slice 5-links-b.

Scope (confirmed): **only `MODE_AES256_CBC`** (the reference's default and only enabled
mode → 64-byte session key) and the **base handshake without optional MTU-signalling
bytes**. AES-128-CBC / AES-256-GCM modes, MTU discovery, and all lifecycle/state are
deferred.

Inherited constraints:
- **Full wire compatibility** with reference Reticulum, validated against Python-RNS 1.3.8.
- **Pure Swift core, dependency-free** (CryptoKit + CommonCrypto only). No TCA in this slice.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / Mac Catalyst 16.

## Reference constructions (confirmed against `markqvist/Reticulum`)

Line references are to `/tmp/ReTiCA/Reticulum-ref/RNS/Link.py`.

### Constants
- `ECPUBSIZE = 32 + 32 = 64` (ephemeral X25519 public key ‖ ephemeral Ed25519 public key).
- `KEYSIZE = 32`. `MODE_AES256_CBC = 0x01` (default, only enabled) → derived key length 64
  bytes → AES-256 `Token`. `SIGLENGTH//8 = 64`.
- `LINK_MTU_SIZE = 3` (MTU-signalling — NOT used in this slice's base handshake).

### The ephemeral keypair is an `Identity`
A link endpoint generates a fresh ephemeral X25519 keypair (`prv`/`pub_bytes`) and a fresh
Ed25519 keypair (`sig_pub_bytes`). That is exactly an `Identity` (X25519 ‖ Ed25519). So the
ephemeral link keypair = `Identity()`, and the link-request data = `ephemeral.publicKey`
(`X25519_pub(32) ‖ Ed25519_pub(32) = 64 = ECPUBSIZE`).

### Link request (initiator → responder)
- `link_request_data = ephemeral.publicKey` (64 bytes; base case, no MTU bytes).
- Sent as a `LINKREQUEST` packet to the SINGLE destination (HEADER_1, context NONE).
- `link_id = truncated_hash(link_request_packet.get_hashable_part())` (`set_link_id` /
  `link_id_from_lr_packet`, lines 337–347). In the base case (`len(data) == ECPUBSIZE`) no
  bytes are stripped, so `link_id = truncatedHash(packet.hashablePart)`. Both initiator and
  responder compute the same `link_id` from the same packet bytes. The `link_id` is the
  link's address.

### Handshake / session key (both sides — `handshake()`, lines 349–362)
- `shared_key = X25519_ECDH(own ephemeral X25519 private, peer ephemeral X25519 public)` —
  the **raw** 32-byte shared secret (not a CryptoKit-derived symmetric key).
- `derived_key = HKDF(length=64, derive_from=shared_key, salt=link_id, context=None)`.
- `derived_key` (64 bytes) is the AES-256 `Token` session key. Because ECDH is symmetric,
  both sides derive the identical key.

### Proof (LRPROOF, responder → initiator — `prove()`, lines 367–376)
- `signed_data = link_id ‖ responder_ephemeral_X25519_pub(32) ‖
  destination_identity_Ed25519_pub(32)` (base case; signalling empty).
- `signature = destination.identity.sign(signed_data)` (64 bytes) — the DESTINATION's
  long-term identity signs, proving ownership.
- `proof_data = signature(64) ‖ responder_ephemeral_X25519_pub(32)` (base case; no
  signalling). Sent as a `PROOF` packet with context `LRPROOF`, addressed to `link_id`.

### Validate proof (initiator — `validate_proof()`, lines 392–447)
- Parse `signature = proof_data[:64]`, `peer_pub = proof_data[64:64+32]`.
- `peer_sig_pub = destination.identity.publicKey[32:64]` (the destination's known Ed25519
  key — the initiator already knows it from the announce).
- `signed_data = link_id ‖ peer_pub ‖ peer_sig_pub`.
- If `destination.identity.validate(signature, signed_data)` → the responder pub is
  authentic; derive `session_key` with `peer_pub`; the link is established. Else reject.

### Link data cipher (`encrypt`/`decrypt`, lines 1132–1149)
- `Token(derived_key)` — the same `Token` (AES-256-CBC + HMAC) used by `Identity`.
  `encrypt(plaintext)` / `decrypt(ciphertext)`.

## Module structure

```
Sources/ReTiCA/Link/Link.swift        // pure Link namespace
Tests/ReTiCATests/Link/LinkTests.swift
Tests/ReTiCATests/Vectors/            // extend generator + fixtures with link vectors +
                                      // LinkCrossValidationTests.swift
```

`Link` is pure and dependency-free; it composes `Identity`, `Crypto.hkdf`,
`Crypto.truncatedHash`, `Packet.hashablePart`, and `Token`, plus CryptoKit for the raw
X25519 ECDH (as `Identity` already does).

## Public API

```swift
public enum Link {
    public static let ecPublicKeySize = 64     // ECPUBSIZE
    public static let sessionKeyLength = 64     // AES-256 Token key
    public static let signatureLength = 64
    static let publicKeyHalf = 32               // X25519 / Ed25519 half

    /// Deterministic link id from a (built or received) link-request packet.
    /// Base case (no MTU signalling): truncatedHash of the packet's hashable part.
    public static func linkID(requestPacket: Packet) -> Data

    /// The session key both sides derive:
    /// HKDF(64, ECDH(ephemeralPrivateX25519, peerPublicX25519), salt: linkID, context: nil).
    public static func sessionKey(ephemeralPrivateX25519: Data, peerPublicX25519: Data,
                                  linkID: Data) -> Data

    /// Responder builds the LRPROOF proof data:
    /// signed = linkID ‖ responderX25519pub ‖ destinationEd25519pub;
    /// proof  = destinationIdentity.sign(signed) ‖ responderX25519pub.
    /// Requires `destinationIdentity` to hold a private key (it owns the destination).
    public static func buildProof(linkID: Data, responderEphemeral: Identity,
                                  destinationIdentity: Identity) -> Data

    /// Initiator validates the proof against the destination's known identity.
    /// Returns the responder's X25519 public key on success, nil on a bad signature or
    /// malformed input.
    public static func validateProof(proofData: Data, linkID: Data,
                                     destinationIdentity: Identity) -> Data?

    /// Link data cipher over the derived session key (wraps `Token`).
    public static func encrypt(_ plaintext: Data, sessionKey: Data) -> Data
    public static func decrypt(_ ciphertext: Data, sessionKey: Data) -> Data?
}
```

Byte-slicing helpers use `Identity.publicKey`/`.privateKey` (both `public`): X25519 half =
`prefix(32)`, Ed25519 half = `suffix(32)`.

## Behavior / data flow

- **`linkID(requestPacket:)`** = `Crypto.truncatedHash(requestPacket.hashablePart)`.
- **`sessionKey(...)`**: CryptoKit `Curve25519.KeyAgreement.PrivateKey(rawRepresentation:
  ephemeralPrivateX25519)` → `sharedSecretFromKeyAgreement(with: PublicKey(rawRepresentation:
  peerPublicX25519))` → raw bytes (`withUnsafeBytes`) → `Crypto.hkdf(length: 64, derivedFrom:
  shared, salt: linkID, context: nil)`.
- **`buildProof(...)`**: `signed = linkID + responderEphemeral.publicKey.prefix(32) +
  destinationIdentity.publicKey.suffix(32)`; `proof = destinationIdentity.sign(signed) +
  responderEphemeral.publicKey.prefix(32)`.
- **`validateProof(...)`**: require `proofData.count >= 64 + 32`; `signature =
  proofData.prefix(64)`, `peerPub = proofData[64..<96]`; `signed = linkID + peerPub +
  destinationIdentity.publicKey.suffix(32)`; return `peerPub` iff
  `destinationIdentity.validate(signature:, message: signed)`.
- **`encrypt`/`decrypt`**: `try! Token(key: sessionKey).encrypt(plaintext)` /
  `try? Token(key: sessionKey).decrypt(ciphertext)` (session key is always 64 bytes, so
  `Token(key:)` cannot throw on the encrypt path).

## Error handling

- All parsing tolerates malformed input without trapping: `validateProof` returns `nil` on
  short/garbage `proofData` or a bad signature; `decrypt` returns `nil` on any failure.
- `buildProof` requires a private-key `destinationIdentity` (a programmer error otherwise —
  `sign` preconditions, consistent with `Identity.sign`).

## Verification strategy

Under the project's mutation-testing discipline.

1. **Unit / round-trip tests:**
   - Simulate both sides: initiator ephemeral + responder ephemeral + a link-request packet
     → both `sessionKey(...)` calls (init-pub×resp-priv and resp-pub×init-priv) yield the
     **identical** 64-byte key.
   - `buildProof` → `validateProof` returns the correct responder pub; a tampered signature
     or wrong destination identity → `nil`.
   - `encrypt` → `decrypt` round-trips over the session key; `decrypt` of garbage → `nil`.
   - `linkID` is deterministic for identical packets and changes with the request data.
2. **Cross-validation vs Python-RNS 1.3.8** (extend the generator; headless-safe via RNS
   crypto statics): emit a full handshake's bytes — the destination identity, initiator &
   responder ephemeral keys, the link-request packet raw, the reference `link_id`, the
   reference `derived_key`, the reference `proof_data`, and a `Token(derived_key)`-encrypted
   link-data sample. Swift asserts:
   - `Link.linkID(Packet(raw: link_request_raw))` == reference `link_id`;
   - `Link.sessionKey(initEphemeralX25519Priv, responderEphemeralX25519Pub, link_id)` ==
     reference `derived_key`;
   - `Link.validateProof(proof_data, link_id, destinationIdentity(public))` == the responder
     X25519 pub;
   - `Link.decrypt(link_data_ciphertext, derived_key)` == the reference plaintext.
   This proves link_id derivation, session-key derivation, proof validation, and the link
   cipher against reference bytes. The controller generates + commit-verifies the fixture
   (an external process reverts generator/fixtures — verify committed content).

## Success criteria

- Both handshake sides derive the identical session key; proof build/validate round-trips
  and rejects tampering; link data round-trips — all byte-exact and cross-validated against
  Python-RNS 1.3.8 (`link_id`, `derived_key`, `proof`, link cipher).
- `Link` is pure and lives in the dependency-free core; no TCA.
