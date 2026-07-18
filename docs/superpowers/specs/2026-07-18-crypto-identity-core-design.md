# Crypto + Identity Core — Design

**Date:** 2026-07-18
**Status:** Approved
**Sub-project:** #1 of the native iOS Reticulum (RNS) implementation

## Context

We are building a **reusable Swift library** that implements the Reticulum Network
Stack (RNS), with **full wire compatibility** with the reference implementation
(`markqvist/Reticulum`) as a hard requirement — every hash, header flag, and crypto
construction must match byte-for-byte so the library can interoperate with existing
RNS nodes.

The architecture is **two-layer**:

- A **pure Swift core** (value types + functions) — crypto, Identity, Packet,
  Destination hashing. No dependency on The Composable Architecture (TCA). Trivially
  unit-testable against reference vectors.
- A **TCA layer** on top for the stateful, effectful subsystems — Transport, Links,
  Interfaces, Resources — modeled as composable reducers with effects for I/O.

The full stack decomposes into sequential sub-projects, each with its own
spec → plan → build cycle:

| # | Sub-project | Layer | Depends on |
|---|-------------|-------|------------|
| 1 | **Crypto + Identity core** (this doc) | Pure | — |
| 2 | Packet + Destination | Pure | 1 |
| 3 | Interfaces (TCP first) | TCA | 2 |
| 4 | Transport (path table, announces, routing) | TCA | 2, 3 |
| 5 | Links (ECDH sessions, forward secrecy) | TCA | 4 |
| 6 | Resources (segmentation, compression) | TCA | 5 |

LXMF (messaging) sits *above* this library entirely and is a separate package.

This document specifies **sub-project #1: the Crypto + Identity core** — the pure
foundation everything else depends on. It is pure Swift (no TCA), proving the
two-layer boundary from the start, and is the most rigorously testable slice.

## Reference constructions (confirmed against `markqvist/Reticulum`)

These are the exact facts the implementation must match. Line references are to the
cloned reference at `/tmp/ReTiCA/Reticulum-ref`.

### Constants

- `TRUNCATED_HASHLENGTH = 128` bits = **16 bytes** (addressable/identity hashes).
- `KEYSIZE = 512` bits — a full key is **64 bytes**: a 256-bit encryption (X25519)
  half concatenated with a 256-bit signing (Ed25519) half.
  - **Public key** (64 bytes) = `X25519_pub(32) ‖ Ed25519_pub(32)`.
  - **Private key** (64 bytes) = `X25519_priv(32) ‖ Ed25519_seed(32)`.
- `DERIVED_KEY_LENGTH = 512//8 = 64` bytes (current). `DERIVED_KEY_LENGTH_LEGACY =
  256//8 = 32` bytes (legacy).
- `Token.TOKEN_OVERHEAD = 48` bytes (16 IV + 32 HMAC).
- `NAME_HASH_LENGTH = 80` bits = 10 bytes (used by Destinations/announces — noted for
  later, not exercised in this slice).

### Identity hash

`hash = SHA256(public_key_64_bytes)[:16]` where `public_key = X25519_pub ‖ Ed25519_pub`.
`hexHash = hash.hex()`.

### Token cipher (`RNS/Cryptography/Token.py`)

A simplified Fernet with the version/timestamp fields stripped.

- **Key length selects mode:** 32-byte key → AES-128-CBC; 64-byte key → AES-256-CBC.
  - AES-128: `signing_key = key[:16]`, `encryption_key = key[16:]`.
  - AES-256: `signing_key = key[:32]`, `encryption_key = key[32:]`.
- **encrypt(data):** `iv = random(16)`; `ciphertext = AES-CBC(encryption_key, iv,
  PKCS7.pad(data))`; `signed = iv ‖ ciphertext`; return `signed ‖ HMAC-SHA256(signing_key, signed)`.
- **decrypt(token):** verify the trailing 32-byte HMAC over `token[:-32]` (constant-time
  compare), then `iv = token[:16]`, `ciphertext = token[16:-32]`, return
  `PKCS7.unpad(AES-CBC-decrypt(encryption_key, iv, ciphertext))`.
- Layout: **`IV(16) ‖ AES-CBC(PKCS7(plaintext)) ‖ HMAC-SHA256(32)`**.

### PKCS7 (`RNS/Cryptography/PKCS7.py`, blocksize 16)

- `pad`: `n = 16 - (len % 16)` (always pads; a full block adds 16 bytes of `0x10`);
  append `n` copies of byte `n`.
- `unpad`: read last byte `n`; error if `n > 16`; strip `n` bytes.

### HKDF (`RNS/Cryptography/HKDF.py`)

RFC-5869-equivalent for our output lengths (≤ 255 blocks):

- `hash_len = 32`.
- If salt empty/None → 32 zero bytes. If context None → empty.
- `PRK = HMAC-SHA256(salt, ikm)`.
- Expand: `T(0) = ""`; for `i` in `0..ceil(length/32)-1`: `T = HMAC-SHA256(PRK, T ‖
  context ‖ byte((i+1) & 0xFF))`; concatenate; return first `length` bytes.
- We implement this directly rather than relying on CryptoKit's `HKDF`, to guarantee
  the byte-exact match.

### Identity.encrypt / decrypt (`RNS/Identity.py`)

- **encrypt(plaintext, ratchet=None):**
  1. `ephemeral = X25519.generate()`.
  2. `target_pub = X25519PublicKey(ratchet) if ratchet else self.pub` (ratchet is a
     32-byte X25519 public key).
  3. `shared = ephemeral.exchange(target_pub)`.
  4. `derived = HKDF(length=64, ikm=shared, salt=self.hash, context=None)`.
  5. `ct = Token(derived).encrypt(plaintext)` → AES-256-CBC.
  6. return `ephemeral.public_bytes(32) ‖ ct`.
- **decrypt(token, ratchets=None, enforce_ratchets=False):**
  1. Require `len(token) > 32`. `peer_pub = token[:32]`, `ct = token[32:]`.
  2. If `ratchets`: for each ratchet private key, `shared = ratchet_prv.exchange(peer_pub)`,
     try `Token(HKDF(...)).decrypt(ct)`; stop on first success.
  3. If `enforce_ratchets` and still nothing → return `nil`.
  4. Else fall back to `shared = self.prv.exchange(peer_pub)` and decrypt.
  5. Returns `nil` on any failure (does not throw for the caller).

### Sign / validate

- `sign(message)` → Ed25519 signature (64 bytes, RFC 8032).
- `validate(signature, message)` → bool (Ed25519 verify).

### X25519 clamping note

The reference clamps the private scalar on load (`_fix_secret`) and re-serializes the
clamped value. CryptoKit clamps internally at exchange time. Clamping is idempotent, so
ECDH outputs, derived public keys, and identity hashes all match — interop holds. A
Swift-generated private key exported raw and re-imported into Python may serialize to
different *stored* bytes (Python clamps on load) but is the mathematically same key.

## Scope

### In scope

- **Hashing** — `fullHash` (SHA-256), `truncatedHash` (first 16 bytes), `randomHash`.
- **HMAC-SHA256** wrapper.
- **HKDF** (hand-written, matching reference).
- **PKCS7** pad/unpad (hand-written, matching reference).
- **AES-128/256-CBC** via CommonCrypto (no-padding; PKCS7 applied by us).
- **Token** — `init(key:)` (mode from key length), `encrypt`, `decrypt`, `verifyHMAC`.
- **Identity** value type — generate, load/export private (64) and public (64) bytes,
  `hash`/`hexHash`, `encrypt(_:ratchet:)`, `decrypt(_:ratchets:enforceRatchets:)`,
  `sign`, `validate`.
- **SecureRandom** seam — random-by-default, injectable for deterministic tests.

### Out of scope (deferred)

- `known_destinations` / `known_ratchets` tables, disk persistence, `recall`/`remember`
  (need Packet/Transport — sub-projects #2 and #4).
- Ratchet *lifecycle* (generation cadence, expiry, announce integration, on-disk
  storage). The *cryptographic operation* against a supplied ratchet key is in scope;
  managing which ratchet to use is not.
- `validate_announce`, `prove` (need Packet — sub-project #2).
- Any TCA. This slice is pure Swift.

## Module structure

```
Sources/ReTiCA/
  Crypto/
    Hashing.swift      // fullHash, truncatedHash, randomHash
    HMAC.swift         // hmacSHA256(key:_:)
    HKDF.swift         // hkdf(length:derivedFrom:salt:context:)
    PKCS7.swift        // pad / unpad
    AESCBC.swift       // CommonCrypto wrapper: aes128/256 CBC enc/dec (no padding)
    Token.swift        // Token struct
  Identity/
    Identity.swift     // Identity struct
  Support/
    Data+Hex.swift     // hexrep / prettyhexrep helpers
    SecureRandom.swift // randomBytes seam (injectable)

Tests/ReTiCATests/
  Vectors/             // Python-RNS-generated fixtures + RFC/NIST KAT files
  (mirrored test files per source unit)
```

Public API deliberately mirrors RNS names so the code reads like the reference.
`Identity` is a `struct` (value semantics, no shared mutable state).

## Public API sketch

```swift
public enum Crypto {
    public static func fullHash(_ data: Data) -> Data           // SHA-256, 32 bytes
    public static func truncatedHash(_ data: Data) -> Data      // first 16 bytes
    public static func randomHash() -> Data                     // truncatedHash(random 16)
    public static func hmacSHA256(key: Data, _ data: Data) -> Data
    public static func hkdf(length: Int, derivedFrom: Data, salt: Data?, context: Data?) -> Data
}

public struct Token {
    public init(key: Data) throws            // 32 → AES-128, 64 → AES-256, else throws
    public func encrypt(_ data: Data) -> Data
    public func decrypt(_ token: Data) throws -> Data
    public func verifyHMAC(_ token: Data) -> Bool
}

public struct Identity: Equatable {
    public init()                                       // generate fresh keypair
    public init?(privateKey: Data)                      // 64 bytes
    public init?(publicKey: Data)                       // 64 bytes (no private ops)

    public var publicKey: Data { get }                  // 64 bytes
    public var privateKey: Data? { get }                // 64 bytes, nil if public-only
    public var hash: Data { get }                       // 16 bytes
    public var hexHash: String { get }

    public func encrypt(_ plaintext: Data, ratchet: Data? = nil) -> Data
    public func decrypt(_ token: Data, ratchets: [Data]? = nil,
                        enforceRatchets: Bool = false) -> Data?
    public func sign(_ message: Data) -> Data           // requires private key
    public func validate(signature: Data, message: Data) -> Bool
}
```

Errors: `TokenError` (invalid key size, HMAC failure, bad padding). Identity `decrypt`
returns `nil` on failure to match reference semantics; `sign` on a public-only identity
is a programmer error (precondition/throwing — decided at implementation).

## Data flow

**Identity.encrypt(plaintext, ratchet?)**
`ephemeral = X25519.generate()` → `shared = ECDH(ephemeral, ratchet ?? selfX25519Pub)`
→ `derived = HKDF(64, shared, salt: self.hash, context: nil)` →
`ct = Token(derived).encrypt(plaintext)` → return `ephemeralPub(32) ‖ ct`.

**Identity.decrypt(token, ratchets?, enforce?)**
split `peerPub(32) ‖ ct`; for each ratchet priv → `ECDH → HKDF → Token.decrypt`, first
success wins; if `enforce` and none → `nil`; else fall back to static X25519 priv.
Any failure → `nil`.

**Testability seam:** ephemeral key + IV are injectable through internal entry points so
`encrypt` and `Token.encrypt` can be tested deterministically; the public API stays
random-by-default via `SecureRandom`.

## Crypto backend

| Primitive | Backend |
|---|---|
| SHA-256, HMAC-SHA256, Ed25519, X25519 | CryptoKit (native, hardware-accelerated) |
| HKDF, PKCS7 | Hand-written to match RNS byte-for-byte |
| AES-128/256-CBC | CommonCrypto (`CCCrypt`, CBC mode, no built-in padding) |

**Decision:** CryptoKit + CommonCrypto. Apple-native, zero third-party dependencies,
hardware-accelerated. CryptoKit has no AES-CBC, so CommonCrypto supplies it; we apply
PKCS7 ourselves (not `kCCOptionPKCS7Padding`) for exact-match and independent
testability. `apple/swift-crypto` (which would add Linux CI) was considered and
rejected: it also lacks public AES-CBC and adds a dependency, not worth it for an
iOS-first library. It can be added later behind a compile flag if Linux CI is wanted.

## Verification strategy

Three layers, executed under the project's mutation-testing discipline (write test →
confirm pass → mutate production to force failure → confirm fail → revert → confirm pass):

1. **Known-answer tests (KATs)** for primitives:
   - SHA-256 (NIST), HMAC-SHA256 (RFC 4231), HKDF (RFC 5869), Ed25519 (RFC 8032),
     X25519 (RFC 7748).
2. **Cross-validation fixtures from Python RNS** — generate keypairs, tokens, signatures,
   and identity hashes with the reference (`pip install rns`); commit as fixtures under
   `Tests/ReTiCATests/Vectors/`. Assert:
   - Swift `truncatedHash(publicKey)` equals the reference identity hash.
   - Swift `Identity(privateKey:).decrypt(pythonToken)` recovers the plaintext.
   - Swift `validate(pythonSignature, message)` succeeds; a tampered signature fails.
   - Swift `Token(key:).decrypt(pythonToken)` recovers the plaintext.
   This is the real wire-compatibility proof.
3. **Round-trip + cross-decrypt** — Swift encrypt → Swift decrypt for all types; and,
   where a Python RNS is available, Swift encrypt → Python decrypt.

Layer 2 requires a Python RNS environment to generate the fixtures. If unavailable at
build time, the fixtures can be added later; layers 1 and 3 still provide strong
coverage in the interim.

## Success criteria

- All primitives pass their RFC/NIST KATs.
- Swift decrypts Python-RNS-generated tokens and validates Python-RNS signatures.
- Identity hashes computed in Swift match the reference byte-for-byte.
- Swift encrypt → Swift decrypt round-trips for `Token` and `Identity`, with and without
  a ratchet key.
- Zero third-party dependencies; builds as a SwiftPM library target for iOS/macOS.
- No TCA in this slice.
