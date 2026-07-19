# Link Handshake Primitives Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add the pure, byte-exact cryptographic primitives of Reticulum Links to the `ReTiCA` core — link_id derivation, session-key derivation, LRPROOF build/validate, and the link data cipher — wire-compatible with `markqvist/Reticulum`.

**Architecture:** A pure `Link` namespace of value functions composing existing core primitives (`Identity` as the ephemeral keypair, `Crypto.hkdf`, `Crypto.truncatedHash`, `Packet.hashablePart`, `Token`) plus CryptoKit for the raw X25519 ECDH. No TCA, no networking, no state machine (deferred to a later slice). Only `MODE_AES256_CBC` and the base handshake without MTU signalling.

**Tech Stack:** Swift 6.3 / Swift 6 language mode, Swift Testing, CryptoKit, building on the merged `ReTiCA` core.

## Global Constraints

- **Toolchain:** swift-tools-version 6.3; `swiftLanguageModes: [.v6]`. Do not modify `Package.swift`.
- **Test framework:** Swift Testing (`import Testing`, `@Test`, `#expect`). Run with `swift test`.
- **Pure core, dependency-free** (CryptoKit + CommonCrypto only). No TCA in this slice.
- **Byte-exact with the reference** (`/tmp/ReTiCA/Reticulum-ref/RNS/Link.py`): `ECPUBSIZE=64`; session key 64 bytes (AES-256); `SIGLENGTH/8=64`. `link_id = truncatedHash(link_request_packet.hashablePart)` (base case, no MTU strip). `session_key = HKDF(64, ECDH(ownX25519priv, peerX25519pub), salt=link_id, context=nil)` using the RAW X25519 shared secret. Proof: `signed = link_id ‖ responderX25519pub(32) ‖ destinationEd25519pub(32)`; `proof = destinationIdentity.sign(signed)(64) ‖ responderX25519pub(32)`. Validate: parse `signature(64) ‖ peerPub(32)`, verify signature over `link_id ‖ peerPub ‖ destinationEd25519pub` with the destination identity. Link data = `Token(sessionKey)`.
- **AES-256-CBC only, no MTU signalling.** Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / Mac Catalyst 16.
- **Value semantics;** pure functions. No shared mutable state.
- **Mutation-testing discipline** after each task.

---

## File Structure

```
Sources/ReTiCA/Link/Link.swift          (Task 1) — pure Link namespace
Tests/ReTiCATests/Link/LinkTests.swift  (Task 1)
Tests/ReTiCATests/Vectors/ (Task 2: extend generate_fixtures.py + fixtures.json +
   VectorFixtures.swift; add LinkCrossValidationTests.swift)
README.md (Task 3)
```

---

### Task 1: Link handshake primitive functions

**Files:**
- Create: `Sources/ReTiCA/Link/Link.swift`
- Test: `Tests/ReTiCATests/Link/LinkTests.swift`

**Interfaces:**
- Consumes: `Identity` (`.publicKey`/`.privateKey`/`.sign`/`.validate`), `Crypto.hkdf`/`Crypto.truncatedHash`, `Packet.hashablePart`, `Token(key:)`, CryptoKit `Curve25519.KeyAgreement`.
- Produces:
  - `enum Link` with statics `ecPublicKeySize=64`, `sessionKeyLength=64`, `signatureLength=64`, and `publicKeyHalf=32`.
  - `linkID(requestPacket: Packet) -> Data`
  - `sessionKey(ephemeralPrivateX25519: Data, peerPublicX25519: Data, linkID: Data) -> Data`
  - `buildProof(linkID: Data, responderEphemeral: Identity, destinationIdentity: Identity) -> Data`
  - `validateProof(proofData: Data, linkID: Data, destinationIdentity: Identity) -> Data?`
  - `encrypt(_ plaintext: Data, sessionKey: Data) -> Data`
  - `decrypt(_ ciphertext: Data, sessionKey: Data) -> Data?`

- [ ] **Step 1: Write the failing tests**

`Tests/ReTiCATests/Link/LinkTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

private func x25519Priv(_ id: Identity) -> Data { Data(id.privateKey!.prefix(32)) }
private func x25519Pub(_ id: Identity) -> Data { Data(id.publicKey.prefix(32)) }

@Test func bothSidesDeriveSameSessionKey() {
    let initEph = Identity()
    let respEph = Identity()
    let linkID = Data(repeating: 0x11, count: 16)
    let initKey = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(initEph),
                                  peerPublicX25519: x25519Pub(respEph), linkID: linkID)
    let respKey = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(respEph),
                                  peerPublicX25519: x25519Pub(initEph), linkID: linkID)
    #expect(initKey == respKey)
    #expect(initKey.count == 64)
}

@Test func sessionKeyDependsOnLinkIDSalt() {
    let a = Identity(); let b = Identity()
    let k1 = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(a), peerPublicX25519: x25519Pub(b),
                             linkID: Data(repeating: 0x01, count: 16))
    let k2 = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(a), peerPublicX25519: x25519Pub(b),
                             linkID: Data(repeating: 0x02, count: 16))
    #expect(k1 != k2) // salt (link_id) changes the derived key
}

@Test func proofBuildValidateRoundTrip() {
    let dest = Identity()          // destination identity (holds private key)
    let respEph = Identity()
    let linkID = Data(repeating: 0x22, count: 16)
    let proof = Link.buildProof(linkID: linkID, responderEphemeral: respEph, destinationIdentity: dest)
    #expect(proof.count == 64 + 32)
    let peerPub = Link.validateProof(proofData: proof, linkID: linkID,
                                     destinationIdentity: Identity(publicKey: dest.publicKey)!)
    #expect(peerPub == x25519Pub(respEph))
}

@Test func proofRejectsTamperAndWrongInputs() {
    let dest = Identity()
    let respEph = Identity()
    let linkID = Data(repeating: 0x22, count: 16)
    let destPub = Identity(publicKey: dest.publicKey)!
    var proof = Link.buildProof(linkID: linkID, responderEphemeral: respEph, destinationIdentity: dest)
    proof[0] ^= 0xFF // corrupt the signature
    #expect(Link.validateProof(proofData: proof, linkID: linkID, destinationIdentity: destPub) == nil)

    let good = Link.buildProof(linkID: linkID, responderEphemeral: respEph, destinationIdentity: dest)
    #expect(Link.validateProof(proofData: good, linkID: Data(repeating: 0x99, count: 16),
                               destinationIdentity: destPub) == nil) // wrong link id
    #expect(Link.validateProof(proofData: good, linkID: linkID,
                               destinationIdentity: Identity(publicKey: Identity().publicKey)!) == nil) // wrong dest
    #expect(Link.validateProof(proofData: Data(repeating: 0, count: 10), linkID: linkID,
                               destinationIdentity: destPub) == nil) // too short
}

@Test func linkIDIsTruncatedHashOfHashablePart() {
    let eph = Identity()
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Data(repeating: 0x33, count: 16), transportId: nil,
                        payload: eph.publicKey)
    let id = Link.linkID(requestPacket: packet)
    #expect(id.count == 16)
    #expect(id == Crypto.truncatedHash(packet.hashablePart))
}

@Test func linkEncryptDecryptRoundTrips() {
    let a = Identity(); let b = Identity()
    let linkID = Data(repeating: 0x44, count: 16)
    let key = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(a), peerPublicX25519: x25519Pub(b),
                              linkID: linkID)
    let pt = Data("link payload".utf8)
    #expect(Link.decrypt(Link.encrypt(pt, sessionKey: key), sessionKey: key) == pt)
    #expect(Link.decrypt(Data(repeating: 0xAB, count: 80), sessionKey: key) == nil) // garbage
}

@Test func fullHandshakeSimulationEstablishesSharedKeyAndDataFlows() {
    let dest = Identity()          // destination (responder owns it)
    let initEph = Identity()
    // Initiator builds the link-request packet, both sides derive link_id from it.
    let reqPacket = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                           destinationType: .single, context: .none, contextFlag: false, hops: 0,
                           destinationHash: Data(repeating: 0x55, count: 16), transportId: nil,
                           payload: initEph.publicKey)
    let linkID = Link.linkID(requestPacket: reqPacket)

    // Responder derives the session key and builds the proof.
    let respEph = Identity()
    let respKey = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(respEph),
                                  peerPublicX25519: x25519Pub(initEph), linkID: linkID)
    let proof = Link.buildProof(linkID: linkID, responderEphemeral: respEph, destinationIdentity: dest)

    // Initiator validates the proof and derives the same key.
    let peerPub = Link.validateProof(proofData: proof, linkID: linkID,
                                     destinationIdentity: Identity(publicKey: dest.publicKey)!)!
    let initKey = Link.sessionKey(ephemeralPrivateX25519: x25519Priv(initEph),
                                  peerPublicX25519: peerPub, linkID: linkID)
    #expect(initKey == respKey)

    // Data flows over the established link.
    let pt = Data("secure link message".utf8)
    #expect(Link.decrypt(Link.encrypt(pt, sessionKey: initKey), sessionKey: respKey) == pt)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --filter LinkTests`
Expected: FAIL — `Link` not defined.

- [ ] **Step 3: Write minimal implementation**

`Sources/ReTiCA/Link/Link.swift`:

```swift
import Foundation
import CryptoKit

/// Pure cryptographic primitives of a Reticulum Link (AES-256-CBC mode, base handshake).
/// The stateful Link session (PENDING→HANDSHAKE→ACTIVE→CLOSED) is a separate layer.
public enum Link {
    public static let ecPublicKeySize = 64   // ECPUBSIZE (X25519 32 ‖ Ed25519 32)
    public static let sessionKeyLength = 64   // AES-256 Token key
    public static let signatureLength = 64
    static let publicKeyHalf = 32

    /// Deterministic link id from a link-request packet: truncated hash of its hashable part.
    public static func linkID(requestPacket: Packet) -> Data {
        Crypto.truncatedHash(requestPacket.hashablePart)
    }

    /// The session key both sides derive:
    /// HKDF(64, ECDH(ephemeralPrivateX25519, peerPublicX25519), salt: linkID).
    public static func sessionKey(ephemeralPrivateX25519: Data, peerPublicX25519: Data,
                                  linkID: Data) -> Data {
        guard let priv = try? Curve25519.KeyAgreement.PrivateKey(rawRepresentation: ephemeralPrivateX25519),
              let peer = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: peerPublicX25519),
              let shared = try? priv.sharedSecretFromKeyAgreement(with: peer)
        else { return Data() }
        let sharedData = shared.withUnsafeBytes { Data($0) }
        return Crypto.hkdf(length: sessionKeyLength, derivedFrom: sharedData,
                           salt: linkID, context: nil)
    }

    /// Responder builds the LRPROOF proof data.
    public static func buildProof(linkID: Data, responderEphemeral: Identity,
                                  destinationIdentity: Identity) -> Data {
        let responderX25519Pub = Data(responderEphemeral.publicKey.prefix(publicKeyHalf))
        let destinationEd25519Pub = Data(destinationIdentity.publicKey.suffix(publicKeyHalf))
        let signedData = linkID + responderX25519Pub + destinationEd25519Pub
        let signature = destinationIdentity.sign(signedData)
        return signature + responderX25519Pub
    }

    /// Initiator validates the proof against the destination's known identity; returns the
    /// responder's X25519 public key on success, nil on bad signature or malformed input.
    public static func validateProof(proofData: Data, linkID: Data,
                                     destinationIdentity: Identity) -> Data? {
        let data = Data(proofData)
        guard data.count >= signatureLength + publicKeyHalf else { return nil }
        let signature = data.prefix(signatureLength)
        let peerPub = data.subdata(in: signatureLength..<(signatureLength + publicKeyHalf))
        let destinationEd25519Pub = Data(destinationIdentity.publicKey.suffix(publicKeyHalf))
        let signedData = Data(linkID) + peerPub + destinationEd25519Pub
        guard destinationIdentity.validate(signature: Data(signature), message: signedData) else {
            return nil
        }
        return peerPub
    }

    /// Link data cipher over the derived session key (wraps `Token`).
    public static func encrypt(_ plaintext: Data, sessionKey: Data) -> Data {
        guard let token = try? Token(key: sessionKey) else { return Data() }
        return token.encrypt(plaintext)
    }

    public static func decrypt(_ ciphertext: Data, sessionKey: Data) -> Data? {
        guard let token = try? Token(key: sessionKey) else { return nil }
        return try? token.decrypt(ciphertext)
    }
}
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --filter LinkTests`
Expected: PASS (7 tests).

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCA/Link/Link.swift Tests/ReTiCATests/Link/LinkTests.swift
git commit -m "feat: pure Link handshake primitives (link_id, session key, proof, cipher)"
```

---

### Task 2: Cross-validation vs Python-RNS

**Files:**
- Modify: `Tests/ReTiCATests/Vectors/generate_fixtures.py`
- Modify: `Tests/ReTiCATests/Vectors/fixtures.json` (regenerated)
- Modify: `Tests/ReTiCATests/Vectors/VectorFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/LinkCrossValidationTests.swift`

**Interfaces:**
- Consumes: `Link`, `Identity(publicKey:)`, `Packet(raw:)`, `Data(hexString:)`.
- Produces: `VectorFixtures` gains 9 link fields.

- [ ] **Step 1: Extend the generator**

Add to `Tests/ReTiCATests/Vectors/generate_fixtures.py`, before the final `print(json.dumps(...))`:

```python
# --- Link handshake vectors (base AES-256-CBC handshake, no MTU signalling) ---
from RNS.Cryptography import X25519PrivateKey, X25519PublicKey
from RNS.Cryptography import Token as LinkToken

link_dest = RNS.Identity()                 # the destination the link is made to (responder owns it)
link_init_eph = RNS.Identity()             # initiator ephemeral (X25519 ‖ Ed25519)
link_resp_eph = RNS.Identity()             # responder ephemeral

# Link request packet: HEADER_1 LINKREQUEST to the destination; data = initiator ephemeral public key.
link_dest_hash = RNS.Destination.hash(link_dest, "reticula", "link")
lr_flags = (0 << 6) | (0 << 5) | (0 << 4) | (RNS.Destination.SINGLE << 2) | RNS.Packet.LINKREQUEST  # 0x02
lr_data = link_init_eph.get_public_key()   # 64 bytes
link_request_raw = bytes([lr_flags, 0]) + link_dest_hash + bytes([0x00]) + lr_data

# link_id = truncated_hash(get_hashable_part) = truncated_hash(bytes([flags&0x0F]) ‖ dest_hash ‖ context ‖ data)
lr_hashable = bytes([lr_flags & 0x0F]) + link_dest_hash + bytes([0x00]) + lr_data
link_id = RNS.Identity.truncated_hash(lr_hashable)

# session key: HKDF(64, ECDH(init x25519 priv, resp x25519 pub), salt=link_id)
init_x25519_priv = X25519PrivateKey.from_private_bytes(link_init_eph.get_private_key()[:32])
resp_x25519_pub = X25519PublicKey.from_public_bytes(link_resp_eph.get_public_key()[:32])
link_shared = init_x25519_priv.exchange(resp_x25519_pub)
link_derived_key = RNS.Cryptography.hkdf(length=64, derive_from=link_shared, salt=link_id, context=None)

# proof: signed = link_id ‖ resp x25519 pub(32) ‖ dest identity ed25519 pub(32); signed by the destination identity.
resp_x25519_pub_bytes = link_resp_eph.get_public_key()[:32]
dest_ed25519_pub = link_dest.get_public_key()[32:64]
link_proof_signed = link_id + resp_x25519_pub_bytes + dest_ed25519_pub
link_proof = link_dest.sign(link_proof_signed) + resp_x25519_pub_bytes

# link data over the session key
link_plaintext = b"secure link message"
link_ciphertext = LinkToken(link_derived_key).encrypt(link_plaintext)
```

And add to the printed dict:

```python
    "link_dest_identity_public": link_dest.get_public_key().hex(),
    "link_init_eph_private_key": link_init_eph.get_private_key().hex(),
    "link_resp_eph_public_key": link_resp_eph.get_public_key().hex(),
    "link_request_raw": link_request_raw.hex(),
    "link_id": link_id.hex(),
    "link_derived_key": link_derived_key.hex(),
    "link_proof": link_proof.hex(),
    "link_plaintext": link_plaintext.hex(),
    "link_ciphertext": link_ciphertext.hex(),
```

- [ ] **Step 2: Regenerate fixtures (controller runs this in the RNS env)**

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python Tests/ReTiCATests/Vectors/generate_fixtures.py > Tests/ReTiCATests/Vectors/fixtures.json`
Expected: `fixtures.json` gains the 9 `link_*` fields, keeping all prior fields. If the `from RNS.Cryptography import ...` lines error, STOP and report — do not fabricate values. Verify the committed content contains `link_id`/`link_derived_key` after committing (an external process reverts these files).

- [ ] **Step 3: Extend the decoder**

Add to `Tests/ReTiCATests/Vectors/VectorFixtures.swift` (keep existing fields):

```swift
    let linkDestIdentityPublic: String
    let linkInitEphPrivateKey: String
    let linkRespEphPublicKey: String
    let linkRequestRaw: String
    let linkID: String
    let linkDerivedKey: String
    let linkProof: String
    let linkPlaintext: String
    let linkCiphertext: String
```

CodingKeys additions:

```swift
        case linkDestIdentityPublic = "link_dest_identity_public"
        case linkInitEphPrivateKey = "link_init_eph_private_key"
        case linkRespEphPublicKey = "link_resp_eph_public_key"
        case linkRequestRaw = "link_request_raw"
        case linkID = "link_id"
        case linkDerivedKey = "link_derived_key"
        case linkProof = "link_proof"
        case linkPlaintext = "link_plaintext"
        case linkCiphertext = "link_ciphertext"
```

- [ ] **Step 4: Write the failing cross-validation tests**

`Tests/ReTiCATests/Vectors/LinkCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

@Test func swiftLinkIDMatchesReference() throws {
    let f = try VectorFixtures.load()
    let packet = try #require(Packet(raw: Data(hexString: f.linkRequestRaw)!))
    #expect(Link.linkID(requestPacket: packet) == Data(hexString: f.linkID))
}

@Test func swiftLinkSessionKeyMatchesReference() throws {
    let f = try VectorFixtures.load()
    let initPriv = Data(Data(hexString: f.linkInitEphPrivateKey)!.prefix(32))
    let respPub = Data(Data(hexString: f.linkRespEphPublicKey)!.prefix(32))
    let key = Link.sessionKey(ephemeralPrivateX25519: initPriv, peerPublicX25519: respPub,
                              linkID: Data(hexString: f.linkID)!)
    #expect(key == Data(hexString: f.linkDerivedKey))
}

@Test func swiftValidatesReferenceLinkProof() throws {
    let f = try VectorFixtures.load()
    let dest = Identity(publicKey: Data(hexString: f.linkDestIdentityPublic)!)!
    let peerPub = Link.validateProof(proofData: Data(hexString: f.linkProof)!,
                                     linkID: Data(hexString: f.linkID)!, destinationIdentity: dest)
    #expect(peerPub == Data(Data(hexString: f.linkRespEphPublicKey)!.prefix(32)))
}

@Test func swiftDecryptsReferenceLinkData() throws {
    let f = try VectorFixtures.load()
    let key = Data(hexString: f.linkDerivedKey)!
    #expect(Link.decrypt(Data(hexString: f.linkCiphertext)!, sessionKey: key)
            == Data(hexString: f.linkPlaintext))
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter LinkCrossValidation`
Expected: PASS (4 tests) — Swift link_id, session key, proof validation, and link cipher match Python-RNS byte-for-byte.

- [ ] **Step 6: Commit**

```bash
git add Tests/ReTiCATests/Vectors
git commit -m "test: Link handshake cross-validation vs Python-RNS"
```

---

### Task 3: Full suite + mutation gate + README

**Files:** `README.md` (modify); no new source.

- [ ] **Step 1: Run the full suite**

Run: `swift test`
Expected: PASS — all targets, pristine output.

- [ ] **Step 2: Mutation sweep (project convention)**

Batch-mutate one production line per unit, run `swift test` once, confirm the covering tests fail, then revert all and confirm green. Commit nothing with mutations. Suggested mutations:
- `Link.linkID`: use `Crypto.fullHash` instead of `Crypto.truncatedHash` (breaks `linkIDIsTruncatedHashOfHashablePart` + cross-validation).
- `Link.sessionKey`: pass `salt: nil` instead of `salt: linkID` (breaks `sessionKeyDependsOnLinkIDSalt` + cross-validation).
- `Link.buildProof`: use `.suffix(publicKeyHalf)` instead of `.prefix(publicKeyHalf)` for `responderX25519Pub` (breaks proof round-trip + cross-validation).
- `Link.validateProof`: drop the `destinationEd25519Pub` from `signedData` (breaks proof validation + cross-validation).
- `Link.validateProof`: return `peerPub` without checking `validate(...)` (breaks `proofRejectsTamperAndWrongInputs`).
- `Link.decrypt`: return `ciphertext` instead of the decrypted plaintext (breaks the round-trip + cross-validation).
Record which tests fail per mutation. If any mutation is not caught, add a covering test. Revert all; confirm green.

- [ ] **Step 3: Update the README**

Add a "Link handshake primitives" subsection under the appropriate area (e.g. after the core module description). Suggested content:

```markdown
### Link handshake primitives (`Link`)

The `Link` namespace (pure core) implements the cryptographic handshake of a Reticulum Link — an encrypted end-to-end session with forward secrecy:

- `Link.linkID(requestPacket:)` — the deterministic link id from a link-request packet
- `Link.sessionKey(ephemeralPrivateX25519:peerPublicX25519:linkID:)` — the shared session key both sides derive (X25519 ECDH → HKDF salted by the link id)
- `Link.buildProof` / `Link.validateProof` — the LRPROOF signed by the destination identity, proving ownership while the X25519 half stays ephemeral (forward secrecy)
- `Link.encrypt` / `Link.decrypt` — link data over the session key (`Token`)

Only `MODE_AES256_CBC` and the base handshake (no MTU signalling) are implemented. The stateful Link session (state machine, RTT, keepalives, requests) is a future slice. All four handshake constructions are cross-validated against Python-RNS 1.3.8.
```

Update "Not Yet Implemented" to note the Link state machine / lifecycle (session establishment orchestration, RTT, keepalives, requests/responses, close) as future, alongside relaying/path-requests/resources. Do not hard-code a permanent test count.

- [ ] **Step 4: Commit**

```bash
git add README.md
git commit -m "docs: document Link handshake primitives"
```

---

## Self-Review

**Spec coverage:**
- `Link.linkID` (truncatedHash of hashablePart) → Task 1 + cross-validation Task 2.
- `Link.sessionKey` (ECDH + HKDF salt=link_id, 64-byte AES-256 key) → Task 1 + Task 2.
- `Link.buildProof` / `validateProof` (byte layout, destination-identity signing) → Task 1 + Task 2.
- `Link.encrypt` / `decrypt` (Token over session key) → Task 1 + Task 2.
- Ephemeral keypair = `Identity`; reuse of `Crypto`/`Token`/`Packet.hashablePart` → Task 1.
- Cross-validation vs Python-RNS (link_id, derived_key, proof, cipher) → Task 2.
- Full-suite + mutation gate + README → Task 3.
- Deferred (AES-128/GCM, MTU signalling, Link state machine/lifecycle) → not built, per scope.

**Placeholder scan:** No TBD/TODO; every code step has complete code; every command has expected output.

**Type consistency:** `Link.linkID/sessionKey/buildProof/validateProof/encrypt/decrypt` signatures are consistent between Task 1 and the Task 2 cross-validation tests; `Identity.publicKey/privateKey/sign/validate`, `Crypto.hkdf(length:derivedFrom:salt:context:)`/`truncatedHash`, `Packet.hashablePart`/`Packet(raw:)`, `Token(key:)`, and `Data(hexString:)` match the merged core APIs; the 9 `link_*` fixture fields and their camelCase decoder names are consistent between the generator and `VectorFixtures`.

**Decisions recorded:** ephemeral keypair = `Identity` (only X25519 half used in ECDH; responder's Ed25519 in the proof is the destination identity's key); `sessionKey`/`encrypt` return an empty `Data` sentinel on the (contract-violating) invalid-key path rather than trapping; link data cipher reuses `Token`; AES-256-CBC only, no MTU signalling; cross-validation fixtures live in the shared `fixtures.json` (controller generates + commit-verifies).
