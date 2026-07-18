# Crypto + Identity Core Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build the pure-Swift cryptographic foundation of a native iOS Reticulum (RNS) library — hashing, HMAC, HKDF, PKCS7, AES-CBC, the Token cipher, and the Identity value type — byte-for-byte wire-compatible with `markqvist/Reticulum`.

**Architecture:** Pure Swift value types and free functions, no TCA and zero third-party dependencies. Native primitives come from CryptoKit (SHA-256, HMAC, Ed25519, X25519); AES-CBC comes from CommonCrypto; HKDF and PKCS7 are hand-written to match the reference exactly. Randomness is injected through internal method overloads so encryption is deterministically testable while the public API stays random-by-default.

**Tech Stack:** Swift 6.3 / Swift 6 language mode, Swift Testing framework, CryptoKit, CommonCrypto, SwiftPM library target.

## Global Constraints

- **Toolchain:** swift-tools-version 6.3; `swiftLanguageModes: [.v6]` (already set in `Package.swift`).
- **Test framework:** Swift Testing (`import Testing`, `@Test`, `#expect`). Run with `swift test`.
- **Zero third-party dependencies.** Only CryptoKit and CommonCrypto (system frameworks).
- **Byte-exact with the reference.** Every construction must match `markqvist/Reticulum` (cloned at `/tmp/ReTiCA/Reticulum-ref`). Constants: identity hash = `SHA256(pubkey)[:16]`; public/private key = 64 bytes (`X25519(32) ‖ Ed25519(32)`); Identity derives a **64-byte** HKDF key → **AES-256-CBC**; Token layout = `IV(16) ‖ AES-CBC(PKCS7(pt)) ‖ HMAC-SHA256(32)`.
- **No TCA in this slice.**
- **Value semantics.** `Identity` is a `struct`; primitives are free functions or small value types. No shared mutable global state.
- **Mutation-testing discipline (per project convention):** after each task's tests pass, batch-mutate the production code the tests exercise (invert a return, drop a guard, return a wrong constant), confirm the tests fail, revert, confirm they pass again. Only then is the task's commit final.

---

## File Structure

```
Sources/ReTiCA/
  Support/
    Data+Hex.swift        // Data(hexString:) init + .hexString property
    SecureRandom.swift    // SecureRandom.bytes(_:) — system CSPRNG
  Crypto/
    Hashing.swift         // Crypto.fullHash / truncatedHash / randomHash
    HMAC.swift            // Crypto.hmacSHA256(key:_:)
    HKDF.swift            // Crypto.hkdf(length:derivedFrom:salt:context:)
    PKCS7.swift           // PKCS7.pad / unpad
    AESCBC.swift          // AESCBC.encrypt/decrypt (CommonCrypto, 128 & 256)
    Token.swift           // Token struct
  Identity/
    Identity.swift        // Identity struct

Tests/ReTiCATests/
  Support/DataHexTests.swift
  Crypto/HashingTests.swift
  Crypto/HMACTests.swift
  Crypto/HKDFTests.swift
  Crypto/PKCS7Tests.swift
  Crypto/AESCBCTests.swift
  Crypto/TokenTests.swift
  Identity/IdentityTests.swift
  Vectors/
    generate_fixtures.py  // run in a Python RNS environment
    fixtures.json         // committed output of the generator
    VectorFixtures.swift  // Swift decoder for fixtures.json
```

Delete the placeholder `Sources/ReTiCA/ReTiCA.swift` and `Tests/ReTiCATests/ReTiCATests.swift` as part of Task 1.

---

### Task 1: Support — hex + secure random

**Files:**
- Create: `Sources/ReTiCA/Support/Data+Hex.swift`
- Create: `Sources/ReTiCA/Support/SecureRandom.swift`
- Delete: `Sources/ReTiCA/ReTiCA.swift`, `Tests/ReTiCATests/ReTiCATests.swift`
- Test: `Tests/ReTiCATests/Support/DataHexTests.swift`

**Interfaces:**
- Produces:
  - `extension Data { init?(hexString: String); var hexString: String { get } }`
  - `enum SecureRandom { static func bytes(_ count: Int) -> Data }`

- [ ] **Step 1: Remove placeholders**

```bash
git rm Sources/ReTiCA/ReTiCA.swift Tests/ReTiCATests/ReTiCATests.swift
```

- [ ] **Step 2: Write the failing test**

`Tests/ReTiCATests/Support/DataHexTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func hexRoundTripsLowercaseNoDelimiters() {
    let data = Data([0x00, 0x0f, 0xa1, 0xff])
    #expect(data.hexString == "000fa1ff")
    #expect(Data(hexString: "000fa1ff") == data)
}

@Test func hexParsingRejectsOddLength() {
    #expect(Data(hexString: "abc") == nil)
}

@Test func hexParsingRejectsNonHex() {
    #expect(Data(hexString: "zz") == nil)
}

@Test func secureRandomReturnsRequestedLengthAndVaries() {
    let a = SecureRandom.bytes(32)
    let b = SecureRandom.bytes(32)
    #expect(a.count == 32)
    #expect(b.count == 32)
    #expect(a != b)
}
```

- [ ] **Step 3: Run test to verify it fails**

Run: `swift test --filter DataHexTests`
Expected: FAIL — `Data(hexString:)` / `SecureRandom` not defined (build error).

- [ ] **Step 4: Write minimal implementation**

`Sources/ReTiCA/Support/Data+Hex.swift`:

```swift
import Foundation

extension Data {
    /// Parse a non-delimited hex string (even length, [0-9a-fA-F]) into bytes.
    init?(hexString: String) {
        let chars = Array(hexString)
        guard chars.count % 2 == 0 else { return nil }
        var bytes = [UInt8]()
        bytes.reserveCapacity(chars.count / 2)
        var index = chars.startIndex
        while index < chars.endIndex {
            guard let high = chars[index].hexDigitValue,
                  let low = chars[index + 1].hexDigitValue else { return nil }
            bytes.append(UInt8(high << 4 | low))
            index += 2
        }
        self = Data(bytes)
    }

    /// Lowercase, non-delimited hex representation (matches Python `bytes.hex()`).
    var hexString: String {
        map { String(format: "%02x", $0) }.joined()
    }
}
```

`Sources/ReTiCA/Support/SecureRandom.swift`:

```swift
import Foundation

/// Cryptographically secure random bytes. The single source of randomness for the
/// core; internal encrypt overloads accept explicit bytes so tests stay deterministic.
public enum SecureRandom {
    public static func bytes(_ count: Int) -> Data {
        var data = Data(count: count)
        let status = data.withUnsafeMutableBytes { raw in
            SecRandomCopyBytes(kSecRandomDefault, count, raw.baseAddress!)
        }
        precondition(status == errSecSuccess, "SecRandomCopyBytes failed: \(status)")
        return data
    }
}
```

- [ ] **Step 5: Run test to verify it passes**

Run: `swift test --filter DataHexTests`
Expected: PASS (4 tests).

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCA/Support Tests/ReTiCATests/Support
git commit -m "feat: hex encoding helpers and secure random seam"
```

---

### Task 2: Hashing — SHA-256 + truncated + random hash

**Files:**
- Create: `Sources/ReTiCA/Crypto/Hashing.swift`
- Test: `Tests/ReTiCATests/Crypto/HashingTests.swift`

**Interfaces:**
- Consumes: `SecureRandom.bytes(_:)`, `Data.hexString`.
- Produces:
  - `enum Crypto` (namespace, extended by later tasks)
  - `Crypto.fullHash(_ data: Data) -> Data` (32 bytes)
  - `Crypto.truncatedHash(_ data: Data) -> Data` (first 16 bytes)
  - `Crypto.randomHash() -> Data` (16 bytes)
  - `Crypto.truncatedHashLength = 16`

- [ ] **Step 1: Write the failing test**

`Tests/ReTiCATests/Crypto/HashingTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

// NIST SHA-256 known answer: SHA256("abc")
@Test func fullHashMatchesNISTVector() {
    let digest = Crypto.fullHash(Data("abc".utf8))
    #expect(digest.hexString == "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
    #expect(digest.count == 32)
}

@Test func truncatedHashIsFirst16BytesOfFullHash() {
    let data = Data("reticulum".utf8)
    let full = Crypto.fullHash(data)
    let truncated = Crypto.truncatedHash(data)
    #expect(truncated.count == 16)
    #expect(truncated == full.prefix(16))
}

@Test func randomHashIs16BytesAndVaries() {
    let a = Crypto.randomHash()
    let b = Crypto.randomHash()
    #expect(a.count == 16)
    #expect(a != b)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HashingTests`
Expected: FAIL — `Crypto` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Crypto/Hashing.swift`:

```swift
import Foundation
import CryptoKit

/// Namespace for Reticulum's cryptographic primitives. Extended across the Crypto/ files.
public enum Crypto {
    /// Reticulum's addressable hash length: TRUNCATED_HASHLENGTH = 128 bits.
    public static let truncatedHashLength = 16

    /// SHA-256 of `data` (32 bytes).
    public static func fullHash(_ data: Data) -> Data {
        Data(SHA256.hash(data: data))
    }

    /// First 16 bytes of the SHA-256 hash.
    public static func truncatedHash(_ data: Data) -> Data {
        fullHash(data).prefix(truncatedHashLength)
    }

    /// Truncated hash of 16 random bytes.
    public static func randomHash() -> Data {
        truncatedHash(SecureRandom.bytes(truncatedHashLength))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HashingTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Crypto/Hashing.swift Tests/ReTiCATests/Crypto/HashingTests.swift
git commit -m "feat: SHA-256 full/truncated/random hashing"
```

---

### Task 3: HMAC-SHA256

**Files:**
- Create: `Sources/ReTiCA/Crypto/HMAC.swift`
- Test: `Tests/ReTiCATests/Crypto/HMACTests.swift`

**Interfaces:**
- Produces: `Crypto.hmacSHA256(key: Data, _ data: Data) -> Data` (32 bytes)

- [ ] **Step 1: Write the failing test**

`Tests/ReTiCATests/Crypto/HMACTests.swift` — RFC 4231 Test Case 2:

```swift
import Testing
import Foundation
@testable import ReTiCA

// RFC 4231 Test Case 2: key="Jefe", data="what do ya want for nothing?"
@Test func hmacSHA256MatchesRFC4231Case2() {
    let mac = Crypto.hmacSHA256(key: Data("Jefe".utf8),
                                Data("what do ya want for nothing?".utf8))
    #expect(mac.hexString == "5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843")
    #expect(mac.count == 32)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HMACTests`
Expected: FAIL — `hmacSHA256` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Crypto/HMAC.swift`:

```swift
import Foundation
import CryptoKit

extension Crypto {
    /// HMAC-SHA256 of `data` under `key` (32 bytes).
    public static func hmacSHA256(key: Data, _ data: Data) -> Data {
        let mac = HMAC<SHA256>.authenticationCode(for: data, using: SymmetricKey(data: key))
        return Data(mac)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HMACTests`
Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Crypto/HMAC.swift Tests/ReTiCATests/Crypto/HMACTests.swift
git commit -m "feat: HMAC-SHA256"
```

---

### Task 4: HKDF (reference-exact)

**Files:**
- Create: `Sources/ReTiCA/Crypto/HKDF.swift`
- Test: `Tests/ReTiCATests/Crypto/HKDFTests.swift`

**Interfaces:**
- Consumes: `Crypto.hmacSHA256(key:_:)`.
- Produces: `Crypto.hkdf(length: Int, derivedFrom: Data, salt: Data?, context: Data?) -> Data`

Reference algorithm (`RNS/Cryptography/HKDF.py`): `PRK = HMAC(salt ?? 32 zero bytes, ikm)`; expand `T(i) = HMAC(PRK, T(i-1) ‖ context ‖ byte((i+1)&0xFF))` for `i` in `0..<ceil(length/32)`, concatenated, truncated to `length`.

- [ ] **Step 1: Write the failing test**

`Tests/ReTiCATests/Crypto/HKDFTests.swift` — RFC 5869 Test Case 1 (SHA-256):

```swift
import Testing
import Foundation
@testable import ReTiCA

// RFC 5869 Appendix A.1 (SHA-256, L=42)
@Test func hkdfMatchesRFC5869Case1() {
    let ikm = Data(repeating: 0x0b, count: 22)
    let salt = Data(hexString: "000102030405060708090a0b0c")!
    let info = Data(hexString: "f0f1f2f3f4f5f6f7f8f9")!
    let okm = Crypto.hkdf(length: 42, derivedFrom: ikm, salt: salt, context: info)
    #expect(okm.hexString ==
        "3cb25f25faacd57a90434f64d0362f2a2d2d0a90cf1a5a4c5db02d56ecc4c5bf34007208d5b887185865")
}

@Test func hkdfEmptySaltUsesZeroBlock() {
    // With salt nil, PRK = HMAC(32 zero bytes, ikm). Length one block.
    let okm = Crypto.hkdf(length: 32, derivedFrom: Data("ikm".utf8), salt: nil, context: nil)
    let prk = Crypto.hmacSHA256(key: Data(repeating: 0, count: 32), Data("ikm".utf8))
    let expected = Crypto.hmacSHA256(key: prk, Data([0x01]))
    #expect(okm == expected)
}

@Test func hkdf64ByteOutputIsTwoBlocks() {
    let okm = Crypto.hkdf(length: 64, derivedFrom: Data("x".utf8),
                          salt: Data("salt".utf8), context: nil)
    #expect(okm.count == 64)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter HKDFTests`
Expected: FAIL — `hkdf` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Crypto/HKDF.swift`:

```swift
import Foundation

extension Crypto {
    /// Reticulum's HKDF (RFC-5869-equivalent for lengths ≤ 255*32 bytes).
    public static func hkdf(length: Int, derivedFrom ikm: Data,
                            salt: Data?, context: Data?) -> Data {
        precondition(length >= 1, "HKDF output length must be >= 1")
        precondition(!ikm.isEmpty, "HKDF input key material must be non-empty")

        let hashLen = 32
        let effectiveSalt = (salt?.isEmpty == false) ? salt! : Data(repeating: 0, count: hashLen)
        let info = context ?? Data()

        let prk = hmacSHA256(key: effectiveSalt, ikm)

        var derived = Data()
        var block = Data()
        let blocks = (length + hashLen - 1) / hashLen
        for i in 0..<blocks {
            var input = block
            input.append(info)
            input.append(UInt8((i + 1) & 0xFF))
            block = hmacSHA256(key: prk, input)
            derived.append(block)
        }
        return derived.prefix(length)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter HKDFTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Crypto/HKDF.swift Tests/ReTiCATests/Crypto/HKDFTests.swift
git commit -m "feat: reference-exact HKDF-SHA256"
```

---

### Task 5: PKCS7 padding

**Files:**
- Create: `Sources/ReTiCA/Crypto/PKCS7.swift`
- Test: `Tests/ReTiCATests/Crypto/PKCS7Tests.swift`

**Interfaces:**
- Produces:
  - `enum PKCS7 { static let blockSize = 16 }`
  - `PKCS7.pad(_ data: Data) -> Data`
  - `PKCS7.unpad(_ data: Data) throws -> Data`
  - `enum PKCS7Error: Error { case invalidPadding }`

- [ ] **Step 1: Write the failing test**

`Tests/ReTiCATests/Crypto/PKCS7Tests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func padAddsBytesEqualToPadCount() {
    let padded = PKCS7.pad(Data([0x01, 0x02, 0x03])) // 3 bytes -> +13
    #expect(padded.count == 16)
    #expect(Array(padded.suffix(13)) == Array(repeating: 13, count: 13))
}

@Test func padFullBlockAddsWholeBlock() {
    let padded = PKCS7.pad(Data(repeating: 0xaa, count: 16))
    #expect(padded.count == 32)
    #expect(Array(padded.suffix(16)) == Array(repeating: 16, count: 16))
}

@Test func unpadReversesPad() throws {
    let original = Data([0x09, 0x08, 0x07, 0x06, 0x05])
    let restored = try PKCS7.unpad(PKCS7.pad(original))
    #expect(restored == original)
}

@Test func unpadRejectsPaddingLongerThanBlock() {
    #expect(throws: PKCS7Error.self) {
        _ = try PKCS7.unpad(Data(repeating: 0x11, count: 16)) // last byte 0x11 = 17 > 16
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter PKCS7Tests`
Expected: FAIL — `PKCS7` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Crypto/PKCS7.swift`:

```swift
import Foundation

public enum PKCS7Error: Error, Equatable {
    case invalidPadding
}

/// PKCS7 padding at a 16-byte block size (matches `RNS/Cryptography/PKCS7.py`).
public enum PKCS7 {
    public static let blockSize = 16

    public static func pad(_ data: Data) -> Data {
        let n = blockSize - (data.count % blockSize)
        return data + Data(repeating: UInt8(n), count: n)
    }

    public static func unpad(_ data: Data) throws -> Data {
        guard let n = data.last, n <= blockSize, n >= 1, Int(n) <= data.count else {
            throw PKCS7Error.invalidPadding
        }
        return data.prefix(data.count - Int(n))
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter PKCS7Tests`
Expected: PASS (4 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Crypto/PKCS7.swift Tests/ReTiCATests/Crypto/PKCS7Tests.swift
git commit -m "feat: PKCS7 padding at 16-byte block size"
```

---

### Task 6: AES-CBC via CommonCrypto

**Files:**
- Create: `Sources/ReTiCA/Crypto/AESCBC.swift`
- Test: `Tests/ReTiCATests/Crypto/AESCBCTests.swift`

**Interfaces:**
- Produces:
  - `enum AESCBC`
  - `AESCBC.encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data`
  - `AESCBC.decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data`
  - `enum AESError: Error { case invalidKeySize, invalidIVSize, cryptoFailed(Int32) }`

Notes: `plaintext`/`ciphertext` must already be block-aligned (Token applies PKCS7 itself). Key must be 16 (AES-128) or 32 (AES-256) bytes; IV 16 bytes. No internal padding (`options = 0`).

- [ ] **Step 1: Write the failing test**

`Tests/ReTiCATests/Crypto/AESCBCTests.swift` — NIST SP 800-38A AES-128-CBC first block + AES-256 round-trip:

```swift
import Testing
import Foundation
@testable import ReTiCA

// NIST SP 800-38A F.2.1 AES-128-CBC encrypt, first block.
@Test func aes128CBCMatchesNISTFirstBlock() throws {
    let key = Data(hexString: "2b7e151628aed2a6abf7158809cf4f3c")!
    let iv  = Data(hexString: "000102030405060708090a0b0c0d0e0f")!
    let pt  = Data(hexString: "6bc1bee22e409f96e93d7e117393172a")!
    let ct  = try AESCBC.encrypt(pt, key: key, iv: iv)
    #expect(ct.hexString == "7649abac8119b246cee98e9b12e9197d")
    #expect(try AESCBC.decrypt(ct, key: key, iv: iv) == pt)
}

@Test func aes256CBCRoundTrips() throws {
    let key = Data(repeating: 0x24, count: 32)
    let iv  = Data(repeating: 0x11, count: 16)
    let pt  = Data(repeating: 0xab, count: 48)
    let ct  = try AESCBC.encrypt(pt, key: key, iv: iv)
    #expect(ct != pt)
    #expect(try AESCBC.decrypt(ct, key: key, iv: iv) == pt)
}

@Test func aesRejectsBadKeySize() {
    #expect(throws: AESError.self) {
        _ = try AESCBC.encrypt(Data(count: 16), key: Data(count: 20), iv: Data(count: 16))
    }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter AESCBCTests`
Expected: FAIL — `AESCBC` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Crypto/AESCBC.swift`:

```swift
import Foundation
import CommonCrypto

public enum AESError: Error, Equatable {
    case invalidKeySize
    case invalidIVSize
    case cryptoFailed(Int32)
}

/// AES-CBC (128/256) with no built-in padding — callers pre-pad with PKCS7.
public enum AESCBC {
    public static func encrypt(_ plaintext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(input: plaintext, key: key, iv: iv, operation: kCCEncrypt)
    }

    public static func decrypt(_ ciphertext: Data, key: Data, iv: Data) throws -> Data {
        try crypt(input: ciphertext, key: key, iv: iv, operation: kCCDecrypt)
    }

    private static func crypt(input: Data, key: Data, iv: Data,
                              operation: Int) throws -> Data {
        guard key.count == kCCKeySizeAES128 || key.count == kCCKeySizeAES256 else {
            throw AESError.invalidKeySize
        }
        guard iv.count == kCCBlockSizeAES128 else { throw AESError.invalidIVSize }

        var output = Data(count: input.count + kCCBlockSizeAES128)
        var moved = 0
        let status = output.withUnsafeMutableBytes { outRaw in
            input.withUnsafeBytes { inRaw in
                key.withUnsafeBytes { keyRaw in
                    iv.withUnsafeBytes { ivRaw in
                        CCCrypt(
                            CCOperation(operation),
                            CCAlgorithm(kCCAlgorithmAES),
                            CCOptions(0), // no padding, CBC (ECB bit unset)
                            keyRaw.baseAddress, key.count,
                            ivRaw.baseAddress,
                            inRaw.baseAddress, input.count,
                            outRaw.baseAddress, output.count,
                            &moved
                        )
                    }
                }
            }
        }
        guard status == kCCSuccess else { throw AESError.cryptoFailed(status) }
        return output.prefix(moved)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter AESCBCTests`
Expected: PASS (3 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Crypto/AESCBC.swift Tests/ReTiCATests/Crypto/AESCBCTests.swift
git commit -m "feat: AES-128/256-CBC via CommonCrypto"
```

---

### Task 7: Token cipher

**Files:**
- Create: `Sources/ReTiCA/Crypto/Token.swift`
- Test: `Tests/ReTiCATests/Crypto/TokenTests.swift`

**Interfaces:**
- Consumes: `Crypto.hmacSHA256`, `PKCS7`, `AESCBC`, `SecureRandom.bytes`.
- Produces:
  - `struct Token`
  - `init(key: Data) throws` — key 32 → AES-128, 64 → AES-256, else throws `TokenError.invalidKeySize`
  - `func encrypt(_ data: Data) -> Data` (public; random IV)
  - `func encrypt(_ data: Data, iv: Data) -> Data` (internal; deterministic)
  - `func decrypt(_ token: Data) throws -> Data`
  - `func verifyHMAC(_ token: Data) -> Bool`
  - `enum TokenError: Error { case invalidKeySize, hmacFailed, tokenTooShort, decryptionFailed }`
  - `static let overhead = 48`

Layout: `IV(16) ‖ AESCBC(encKey, iv, PKCS7(pt)) ‖ HMAC(signKey, IV‖ct)`. AES-128: signKey=key[0..<16], encKey=key[16...]. AES-256: signKey=key[0..<32], encKey=key[32...].

- [ ] **Step 1: Write the failing test**

`Tests/ReTiCATests/Crypto/TokenTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func tokenRejectsWrongKeySize() {
    #expect(throws: TokenError.self) { _ = try Token(key: Data(count: 40)) }
}

@Test func token256RoundTrips() throws {
    let token = try Token(key: Data(repeating: 0x33, count: 64))
    let pt = Data("hello reticulum".utf8)
    let ct = token.encrypt(pt)
    #expect(ct.count >= pt.count + Token.overhead)
    #expect(try token.decrypt(ct) == pt)
}

@Test func token128RoundTrips() throws {
    let token = try Token(key: Data(repeating: 0x44, count: 32))
    let pt = Data("legacy path".utf8)
    #expect(try token.decrypt(token.encrypt(pt)) == pt)
}

@Test func tokenDeterministicLayoutWithFixedIV() throws {
    // AES-256: signKey = key[:32], encKey = key[32:]
    let key = Data((0..<64).map { UInt8($0) })
    let token = try Token(key: key)
    let iv = Data(repeating: 0x01, count: 16)
    let pt = Data("abc".utf8)
    let out = token.encrypt(pt, iv: iv)

    let signKey = key.prefix(32)
    let encKey = key.suffix(32)
    let expectedCT = try AESCBC.encrypt(PKCS7.pad(pt), key: Data(encKey), iv: iv)
    let signed = iv + expectedCT
    let expectedMAC = Crypto.hmacSHA256(key: Data(signKey), signed)
    #expect(out == signed + expectedMAC)
}

@Test func tokenRejectsTamperedHMAC() throws {
    let token = try Token(key: Data(repeating: 0x55, count: 64))
    var ct = token.encrypt(Data("x".utf8))
    ct[ct.count - 1] ^= 0xFF
    #expect(token.verifyHMAC(ct) == false)
    #expect(throws: TokenError.self) { _ = try token.decrypt(ct) }
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter TokenTests`
Expected: FAIL — `Token` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Crypto/Token.swift`:

```swift
import Foundation

public enum TokenError: Error, Equatable {
    case invalidKeySize
    case hmacFailed
    case tokenTooShort
    case decryptionFailed
}

/// Simplified Fernet (no version/timestamp). Mode is chosen by key length:
/// 32 bytes → AES-128-CBC, 64 bytes → AES-256-CBC.
public struct Token {
    public static let overhead = 48 // 16 IV + 32 HMAC

    private let signingKey: Data
    private let encryptionKey: Data

    public init(key: Data) throws {
        switch key.count {
        case 32:
            signingKey = key.prefix(16)
            encryptionKey = key.suffix(16)
        case 64:
            signingKey = key.prefix(32)
            encryptionKey = key.suffix(32)
        default:
            throw TokenError.invalidKeySize
        }
    }

    public func encrypt(_ data: Data) -> Data {
        encrypt(data, iv: SecureRandom.bytes(16))
    }

    /// Deterministic entry point for tests.
    func encrypt(_ data: Data, iv: Data) -> Data {
        // AESCBC.encrypt only throws on bad key/IV sizes, which the initializer prevents.
        let ciphertext = try! AESCBC.encrypt(PKCS7.pad(data), key: encryptionKey, iv: iv)
        let signed = iv + ciphertext
        return signed + Crypto.hmacSHA256(key: signingKey, signed)
    }

    public func verifyHMAC(_ token: Data) -> Bool {
        guard token.count > 32 else { return false }
        let received = token.suffix(32)
        let expected = Crypto.hmacSHA256(key: signingKey, token.prefix(token.count - 32))
        return constantTimeEquals(Data(received), expected)
    }

    public func decrypt(_ token: Data) throws -> Data {
        guard token.count > 48 else { throw TokenError.tokenTooShort }
        guard verifyHMAC(token) else { throw TokenError.hmacFailed }
        let iv = token.prefix(16)
        let ciphertext = token.dropFirst(16).dropLast(32)
        do {
            let padded = try AESCBC.decrypt(Data(ciphertext), key: encryptionKey, iv: Data(iv))
            return try PKCS7.unpad(padded)
        } catch {
            throw TokenError.decryptionFailed
        }
    }

    private func constantTimeEquals(_ a: Data, _ b: Data) -> Bool {
        guard a.count == b.count else { return false }
        var diff: UInt8 = 0
        for (x, y) in zip(a, b) { diff |= x ^ y }
        return diff == 0
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter TokenTests`
Expected: PASS (5 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Crypto/Token.swift Tests/ReTiCATests/Crypto/TokenTests.swift
git commit -m "feat: Token cipher (simplified Fernet, AES-128/256)"
```

---

### Task 8: Identity value type

**Files:**
- Create: `Sources/ReTiCA/Identity/Identity.swift`
- Test: `Tests/ReTiCATests/Identity/IdentityTests.swift`

**Interfaces:**
- Consumes: CryptoKit `Curve25519`, `Crypto.truncatedHash`, `Crypto.hkdf`, `Token`, `SecureRandom`, `Data.hexString`.
- Produces:
  - `struct Identity: Equatable`
  - `init()` — generate fresh keypair
  - `init?(privateKey: Data)` — 64 bytes (`X25519(32) ‖ Ed25519(32)`)
  - `init?(publicKey: Data)` — 64 bytes, public-only
  - `var publicKey: Data { get }` (64), `var privateKey: Data? { get }` (64), `var hash: Data { get }` (16), `var hexHash: String { get }`
  - `func encrypt(_ plaintext: Data, ratchet: Data? = nil) -> Data`
  - `func encrypt(_ plaintext: Data, ratchet: Data?, ephemeralPrivateKey: Data, iv: Data) -> Data` (internal, deterministic)
  - `func decrypt(_ token: Data, ratchets: [Data]? = nil, enforceRatchets: Bool = false) -> Data?`
  - `func sign(_ message: Data) -> Data` (precondition: has private key)
  - `func validate(signature: Data, message: Data) -> Bool`
  - `static let keySize = 64`

Key math: X25519 half = first 32 bytes, Ed25519 half = last 32 bytes, for both public and private. `hash = truncatedHash(publicKey)`. Derived key length 64 (AES-256). Encrypt output = `ephemeralX25519Pub(32) ‖ Token(hkdf(64, shared, salt: hash)).encrypt(pt)`.

- [ ] **Step 1: Write the failing test**

`Tests/ReTiCATests/Identity/IdentityTests.swift`:

```swift
import Testing
import Foundation
import CryptoKit
@testable import ReTiCA

@Test func generatedIdentityHasCorrectSizes() {
    let id = Identity()
    #expect(id.publicKey.count == 64)
    #expect(id.privateKey?.count == 64)
    #expect(id.hash.count == 16)
    #expect(id.hexHash == id.hash.hexString)
}

@Test func hashIsTruncatedHashOfPublicKey() {
    let id = Identity()
    #expect(id.hash == Crypto.truncatedHash(id.publicKey))
}

@Test func privateKeyRoundTripsThroughBytes() {
    let original = Identity()
    let restored = Identity(privateKey: original.privateKey!)
    #expect(restored != nil)
    #expect(restored?.publicKey == original.publicKey)
    #expect(restored?.hash == original.hash)
}

@Test func publicOnlyIdentityHasNoPrivateKey() {
    let full = Identity()
    let pub = Identity(publicKey: full.publicKey)
    #expect(pub?.privateKey == nil)
    #expect(pub?.hash == full.hash)
}

@Test func rejectsWrongSizedKeys() {
    #expect(Identity(privateKey: Data(count: 32)) == nil)
    #expect(Identity(publicKey: Data(count: 10)) == nil)
}

@Test func signAndValidateRoundTrip() {
    let id = Identity()
    let msg = Data("prove it".utf8)
    let sig = id.sign(msg)
    #expect(sig.count == 64)
    #expect(id.validate(signature: sig, message: msg) == true)
    #expect(id.validate(signature: sig, message: Data("tampered".utf8)) == false)
}

@Test func encryptDecryptRoundTrip() {
    let id = Identity()
    let pt = Data("secret payload".utf8)
    let decrypted = id.decrypt(id.encrypt(pt))
    #expect(decrypted == pt)
}

@Test func encryptOutputStartsWithEphemeralKeyAndDecryptsDeterministically() throws {
    let id = Identity()
    let ephemeral = Curve25519.KeyAgreement.PrivateKey()
    let iv = Data(repeating: 0x07, count: 16)
    let pt = Data("determinism".utf8)
    let out = id.encrypt(pt, ratchet: nil,
                         ephemeralPrivateKey: ephemeral.rawRepresentation, iv: iv)
    #expect(out.prefix(32) == ephemeral.publicKey.rawRepresentation)
    #expect(id.decrypt(out) == pt)
}

@Test func decryptWithRatchetKey() {
    let id = Identity()
    let ratchetPriv = Curve25519.KeyAgreement.PrivateKey()
    let ratchetPub = ratchetPriv.publicKey.rawRepresentation
    let pt = Data("ratcheted".utf8)
    let ct = id.encrypt(pt, ratchet: ratchetPub)
    // Static key cannot decrypt a ratchet-encrypted token.
    #expect(id.decrypt(ct) == nil)
    // Providing the ratchet private key recovers it.
    #expect(id.decrypt(ct, ratchets: [ratchetPriv.rawRepresentation]) == pt)
}

@Test func decryptReturnsNilOnGarbage() {
    let id = Identity()
    #expect(id.decrypt(Data(repeating: 0, count: 10)) == nil)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter IdentityTests`
Expected: FAIL — `Identity` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Identity/Identity.swift`:

```swift
import Foundation
import CryptoKit

/// A Reticulum identity: an X25519 encryption keypair concatenated with an Ed25519
/// signing keypair. Public/private serializations are 64 bytes: `X25519(32) ‖ Ed25519(32)`.
public struct Identity: Equatable {
    public static let keySize = 64
    private static let halfKey = 32
    private static let derivedKeyLength = 64 // AES-256 Token

    // Raw 32-byte representations.
    private let x25519Public: Data
    private let ed25519Public: Data
    private let x25519Private: Data?
    private let ed25519Private: Data?

    // MARK: Init

    public init() {
        let enc = Curve25519.KeyAgreement.PrivateKey()
        let sig = Curve25519.Signing.PrivateKey()
        x25519Private = enc.rawRepresentation
        ed25519Private = sig.rawRepresentation
        x25519Public = enc.publicKey.rawRepresentation
        ed25519Public = sig.publicKey.rawRepresentation
    }

    public init?(privateKey: Data) {
        guard privateKey.count == Identity.keySize else { return nil }
        let encSeed = privateKey.prefix(Identity.halfKey)
        let sigSeed = privateKey.suffix(Identity.halfKey)
        guard let enc = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: encSeed),
              let sig = try? Curve25519.Signing.PrivateKey(rawRepresentation: sigSeed)
        else { return nil }
        x25519Private = Data(encSeed)
        ed25519Private = Data(sigSeed)
        x25519Public = enc.publicKey.rawRepresentation
        ed25519Public = sig.publicKey.rawRepresentation
    }

    public init?(publicKey: Data) {
        guard publicKey.count == Identity.keySize else { return nil }
        let encPub = publicKey.prefix(Identity.halfKey)
        let sigPub = publicKey.suffix(Identity.halfKey)
        guard (try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: encPub)) != nil,
              (try? Curve25519.Signing.PublicKey(rawRepresentation: sigPub)) != nil
        else { return nil }
        x25519Public = Data(encPub)
        ed25519Public = Data(sigPub)
        x25519Private = nil
        ed25519Private = nil
    }

    // MARK: Accessors

    public var publicKey: Data { x25519Public + ed25519Public }

    public var privateKey: Data? {
        guard let x = x25519Private, let e = ed25519Private else { return nil }
        return x + e
    }

    public var hash: Data { Crypto.truncatedHash(publicKey) }
    public var hexHash: String { hash.hexString }

    // MARK: Encryption

    public func encrypt(_ plaintext: Data, ratchet: Data? = nil) -> Data {
        encrypt(plaintext, ratchet: ratchet,
                ephemeralPrivateKey: SecureRandom.bytes(32),
                iv: SecureRandom.bytes(16))
    }

    /// Deterministic entry point for tests.
    func encrypt(_ plaintext: Data, ratchet: Data?,
                 ephemeralPrivateKey: Data, iv: Data) -> Data {
        let ephemeral = try! Curve25519.KeyAgreement.PrivateKey(
            rawRepresentation: ephemeralPrivateKey)
        let targetPub = try! Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: ratchet ?? x25519Public)
        let shared = try! ephemeral.sharedSecretFromKeyAgreement(with: targetPub)
        let sharedData = shared.withUnsafeBytes { Data($0) }
        let derived = Crypto.hkdf(length: Identity.derivedKeyLength,
                                  derivedFrom: sharedData, salt: hash, context: nil)
        let token = try! Token(key: derived)
        return ephemeral.publicKey.rawRepresentation + token.encrypt(plaintext, iv: iv)
    }

    public func decrypt(_ token: Data, ratchets: [Data]? = nil,
                        enforceRatchets: Bool = false) -> Data? {
        guard let x = x25519Private, token.count > Identity.halfKey else { return nil }
        let peerPubBytes = token.prefix(Identity.halfKey)
        let ciphertext = Data(token.dropFirst(Identity.halfKey))
        guard let peerPub = try? Curve25519.KeyAgreement.PublicKey(
            rawRepresentation: peerPubBytes) else { return nil }

        if let ratchets {
            for ratchet in ratchets {
                guard let rPriv = try? Curve25519.KeyAgreement.PrivateKey(
                        rawRepresentation: ratchet),
                      let shared = try? rPriv.sharedSecretFromKeyAgreement(with: peerPub)
                else { continue }
                if let pt = decryptCiphertext(ciphertext,
                                              shared: shared.withUnsafeBytes { Data($0) }) {
                    return pt
                }
            }
            if enforceRatchets { return nil }
        }

        guard let staticPriv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: x),
              let shared = try? staticPriv.sharedSecretFromKeyAgreement(with: peerPub)
        else { return nil }
        return decryptCiphertext(ciphertext, shared: shared.withUnsafeBytes { Data($0) })
    }

    private func decryptCiphertext(_ ciphertext: Data, shared: Data) -> Data? {
        let derived = Crypto.hkdf(length: Identity.derivedKeyLength,
                                  derivedFrom: shared, salt: hash, context: nil)
        guard let token = try? Token(key: derived) else { return nil }
        return try? token.decrypt(ciphertext)
    }

    // MARK: Signing

    public func sign(_ message: Data) -> Data {
        guard let seed = ed25519Private,
              let key = try? Curve25519.Signing.PrivateKey(rawRepresentation: seed) else {
            preconditionFailure("Cannot sign without a private key")
        }
        return try! key.signature(for: message)
    }

    public func validate(signature: Data, message: Data) -> Bool {
        guard let key = try? Curve25519.Signing.PublicKey(rawRepresentation: ed25519Public)
        else { return false }
        return key.isValidSignature(signature, for: message)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter IdentityTests`
Expected: PASS (10 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Identity Tests/ReTiCATests/Identity
git commit -m "feat: Identity value type (keys, hash, encrypt/decrypt, sign/validate)"
```

---

### Task 9: Python-RNS cross-validation fixtures

**Files:**
- Create: `Tests/ReTiCATests/Vectors/generate_fixtures.py`
- Create: `Tests/ReTiCATests/Vectors/fixtures.json` (generator output, committed)
- Create: `Tests/ReTiCATests/Vectors/VectorFixtures.swift`
- Create/append: `Tests/ReTiCATests/Vectors/CrossValidationTests.swift`

**Interfaces:**
- Consumes: `Identity`, `Token`, `Crypto`, `Data(hexString:)`.
- Produces: `struct VectorFixtures: Decodable` mirroring `fixtures.json`.

**fixtures.json shape** (all byte fields lowercase hex):

```json
{
  "identity_private_key": "…128 hex chars (64 bytes)…",
  "identity_public_key":  "…128 hex chars…",
  "identity_hash":        "…32 hex chars (16 bytes)…",
  "sign_message":         "…hex…",
  "signature":            "…128 hex chars (64 bytes)…",
  "encrypt_plaintext":    "…hex…",
  "encrypt_token":        "…hex (ephemeralPub ‖ token, produced by RNS)…",
  "token_key":            "…128 hex chars (64 bytes)…",
  "token_plaintext":      "…hex…",
  "token_ciphertext":     "…hex (IV ‖ ct ‖ HMAC, produced by RNS)…"
}
```

- [ ] **Step 1: Write the generator script**

`Tests/ReTiCATests/Vectors/generate_fixtures.py`:

```python
#!/usr/bin/env python3
# Run inside a Python environment with Reticulum (RNS) installed:
#   python3 generate_fixtures.py > fixtures.json
import json, os
import RNS
from RNS.Cryptography import Token

identity = RNS.Identity()
priv = identity.get_private_key()
pub = identity.get_public_key()

sign_message = os.urandom(24)
signature = identity.sign(sign_message)

encrypt_plaintext = b"cross-validation payload"
encrypt_token = identity.encrypt(encrypt_plaintext)

token_key = os.urandom(64)  # AES-256 Token
token_plaintext = b"token vector"
token_ciphertext = Token(token_key).encrypt(token_plaintext)

print(json.dumps({
    "identity_private_key": priv.hex(),
    "identity_public_key": pub.hex(),
    "identity_hash": identity.hash.hex(),
    "sign_message": sign_message.hex(),
    "signature": signature.hex(),
    "encrypt_plaintext": encrypt_plaintext.hex(),
    "encrypt_token": encrypt_token.hex(),
    "token_key": token_key.hex(),
    "token_plaintext": token_plaintext.hex(),
    "token_ciphertext": token_ciphertext.hex(),
}, indent=2))
```

- [ ] **Step 2: Generate the fixtures in your Python RNS environment**

Run (in the RNS environment): `python3 Tests/ReTiCATests/Vectors/generate_fixtures.py > Tests/ReTiCATests/Vectors/fixtures.json`
Expected: `fixtures.json` populated with the 10 hex fields above.

- [ ] **Step 3: Add the fixture decoder + failing cross-validation tests**

`Tests/ReTiCATests/Vectors/VectorFixtures.swift`:

```swift
import Foundation

struct VectorFixtures: Decodable {
    let identityPrivateKey: String
    let identityPublicKey: String
    let identityHash: String
    let signMessage: String
    let signature: String
    let encryptPlaintext: String
    let encryptToken: String
    let tokenKey: String
    let tokenPlaintext: String
    let tokenCiphertext: String

    enum CodingKeys: String, CodingKey {
        case identityPrivateKey = "identity_private_key"
        case identityPublicKey = "identity_public_key"
        case identityHash = "identity_hash"
        case signMessage = "sign_message"
        case signature = "signature"
        case encryptPlaintext = "encrypt_plaintext"
        case encryptToken = "encrypt_token"
        case tokenKey = "token_key"
        case tokenPlaintext = "token_plaintext"
        case tokenCiphertext = "token_ciphertext"
    }

    static func load() throws -> VectorFixtures {
        let url = Bundle.module.url(forResource: "fixtures", withExtension: "json")!
        return try JSONDecoder().decode(VectorFixtures.self, from: Data(contentsOf: url))
    }
}
```

`Tests/ReTiCATests/Vectors/CrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func swiftIdentityHashMatchesReference() throws {
    let f = try VectorFixtures.load()
    let id = Identity(publicKey: Data(hexString: f.identityPublicKey)!)!
    #expect(id.hexHash == f.identityHash)
    #expect(Data(hexString: f.identityPublicKey) == id.publicKey)
}

@Test func swiftValidatesReferenceSignature() throws {
    let f = try VectorFixtures.load()
    let id = Identity(publicKey: Data(hexString: f.identityPublicKey)!)!
    #expect(id.validate(signature: Data(hexString: f.signature)!,
                        message: Data(hexString: f.signMessage)!))
}

@Test func swiftDecryptsReferenceIdentityToken() throws {
    let f = try VectorFixtures.load()
    let id = Identity(privateKey: Data(hexString: f.identityPrivateKey)!)!
    let decrypted = id.decrypt(Data(hexString: f.encryptToken)!)
    #expect(decrypted == Data(hexString: f.encryptPlaintext))
}

@Test func swiftDecryptsReferenceToken() throws {
    let f = try VectorFixtures.load()
    let token = try Token(key: Data(hexString: f.tokenKey)!)
    let decrypted = try token.decrypt(Data(hexString: f.tokenCiphertext)!)
    #expect(decrypted == Data(hexString: f.tokenPlaintext))
}
```

- [ ] **Step 4: Register the fixtures resource in Package.swift**

Modify `Package.swift` test target so `fixtures.json` is bundled:

```swift
.testTarget(
    name: "ReTiCATests",
    dependencies: ["ReTiCA"],
    resources: [.process("Vectors/fixtures.json")]
),
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter CrossValidation`
Expected: PASS (4 tests) — Swift interoperates with reference-generated material.

- [ ] **Step 6: Commit**

```bash
git add Tests/ReTiCATests/Vectors Package.swift
git commit -m "test: Python-RNS cross-validation fixtures and tests"
```

---

### Task 10: Full suite + wire-compat gate

**Files:** none new — a verification and documentation checkpoint.

- [ ] **Step 1: Run the full test suite**

Run: `swift test`
Expected: PASS — all tasks' tests green together.

- [ ] **Step 2: Mutation sweep (project convention)**

Batch-mutate one production line per unit (e.g. change `truncatedHashLength` to 15, invert `constantTimeEquals`, drop the salt-zero branch in `hkdf`, return `pt` instead of ciphertext in `Token.encrypt`), run `swift test`, confirm the corresponding tests fail, then revert all and confirm green. Do not commit any mutation.

- [ ] **Step 3: Update package summary**

Add a short `README.md` section (or create it) documenting the module: what's implemented (crypto core + Identity), the two-layer architecture, and that this is sub-project #1. Commit.

```bash
git add README.md
git commit -m "docs: describe crypto + identity core module"
```

---

## Self-Review

**Spec coverage:**
- Hashing (fullHash/truncatedHash/randomHash) → Task 2.
- HMAC-SHA256 → Task 3. HKDF (reference-exact) → Task 4. PKCS7 → Task 5.
- AES-128/256-CBC via CommonCrypto → Task 6.
- Token (mode-by-key-length, IV‖ct‖HMAC, constant-time verify) → Task 7.
- Identity (keygen, load/export 64-byte keys, hash/hexHash, encrypt/decrypt with ratchet, sign/validate, public-only) → Task 8.
- SecureRandom seam + deterministic encrypt overloads → Tasks 1, 7, 8.
- Verification layer 1 (RFC/NIST KATs) → Tasks 2–6. Layer 2 (Python-RNS cross-validation) → Task 9. Layer 3 (round-trips) → Tasks 7, 8. Full gate + mutation sweep → Task 10.
- Module structure matches spec → Task file paths.
- No TCA, zero third-party deps, value semantics → honored throughout.

**Placeholder scan:** No TBD/TODO; every code step contains complete code; every command has expected output.

**Type consistency:** `Crypto.fullHash/truncatedHash/randomHash/hmacSHA256/hkdf` consistent across tasks; `Token(key:)`, `Token.overhead`, `Token.encrypt(_:iv:)` consistent between Tasks 7 and its uses in Task 8; `Identity` initializers and `encrypt(_:ratchet:ephemeralPrivateKey:iv:)` used identically in Tasks 8 and 9; `Data(hexString:)`/`.hexString` from Task 1 used throughout; `AESCBC.encrypt/decrypt` signatures consistent between Tasks 6 and 7.

**Decision recorded:** `sign` on a public-only identity uses `preconditionFailure` (programmer error), per the spec's open question.
