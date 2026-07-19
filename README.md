# ReTiCA

A native iOS library for the [Reticulum Network Stack (RNS)](https://reticulum.network/), written in pure Swift.

## Architecture

The library follows a two-layer design:

1. **Crypto + Identity core** (this sub-project) — pure Swift, zero third-party dependencies. Implements the cryptographic primitives and Identity type required by RNS, wire-compatible with reference Reticulum 1.3.8.

2. **TCA orchestration layer** (planned) — will use [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) to model Transport, Links, Announcements, and Resource delivery as reducers/effects on top of the crypto core.

## Sub-project #1: Crypto + Identity Core

This is the first deliverable of the decomposition. It covers:

| Module | What it implements |
|--------|--------------------|
| `Crypto.fullHash` / `truncatedHash` / `randomHash` | SHA-256 and the 16-byte truncated hash used for RNS addressing |
| `Crypto.hmacSHA256` | HMAC-SHA-256 (RFC 2104) |
| `Crypto.hkdf` | HKDF-SHA-256 (RFC 5869), reference-exact counter encoding |
| `PKCS7` | PKCS#7 padding at 16-byte block size, matching `RNS/Cryptography/PKCS7.py` |
| `AESCBC` | AES-128-CBC and AES-256-CBC via CommonCrypto |
| `Token` | Simplified Fernet (IV ‖ AES-CBC ciphertext ‖ HMAC-SHA-256), mode selected by key length: a 32-byte key → AES-128 (16-byte HMAC key + 16-byte AES key), a 64-byte key → AES-256 (32-byte HMAC key + 32-byte AES key); constant-time HMAC verification |
| `Identity` | X25519 + Ed25519 keypair; 64-byte serialization; HKDF-derived Token encryption with optional ratchet key; Ed25519 sign/validate; public-only variant |

### Cryptographic Backend

- **CryptoKit** — X25519 key agreement, Ed25519 signing/verification, SHA-256, HMAC
- **CommonCrypto** — AES-CBC block cipher
- No third-party dependencies.

### Wire Compatibility

Compatibility with reference Reticulum is verified through cross-validation tests (`Tests/ReTiCATests/Vectors/`) that decrypt ciphertexts and validate signatures produced by Python-RNS 1.3.8 fixtures, covering: identity hash, Token decryption, Identity-layer Token decryption, and Ed25519 signature verification.

## Not Yet Implemented

Transport, Link establishment, Announcements, and Resource delivery are **not** part of this sub-project and will be addressed in subsequent deliverables of the decomposition.

## Requirements

- Swift 6 (swift-tools-version 6.3)
- iOS 13+ / macOS 10.15+ / tvOS 13+ / watchOS 6+ / Mac Catalyst 13+ (CryptoKit minimums, declared in `Package.swift`)

## Running Tests

```
swift test
```

All tests should pass (currently 39, including the Python-RNS cross-validation vectors).
