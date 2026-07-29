# LXMF-4d-2a: Propagation Pack/Open Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Two pure inverse functions extending `LXMFPropagation` — `pack` (encrypt a message's delivery tail to the recipient + wrap in the 4d-1 container) and `open` (decrypt + `LXMessage.unpack`) — closing 4d-1's deferred decrypt round trip.

**Architecture:** New file `Sources/ReTiCA/LXMF/LXMFPropagation+Message.swift` extending the pure `LXMFPropagation` namespace. Depends only on core (`LXMessage`, `Identity`, the 4d-1 helpers). Cross-validated by reusing the existing 4d-1 propagation fixture (no new fixture).

**Tech Stack:** Swift, SwiftPM, swift-testing (`@Test`). Cross-validation from the genuine-LXMF fixture generated in 4d-1.

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test; apply the mutations one at a time.
- Encryption is hedged/ephemeral → never byte-compare `pack` output or ciphertext; validate round trips and signatures instead. Hashes/`transient_id` stay deterministic.
- No new fixture — reuse `Tests/ReTiCATests/Vectors/lxmf_propagation_fixtures.json` (from 4d-1); do NOT regenerate it.
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: `LXMFPropagation.pack` / `.open` + round-trip cross-val

**Files:**
- Create: `Sources/ReTiCA/LXMF/LXMFPropagation+Message.swift`
- Modify (append 2 tests): `Tests/ReTiCATests/Vectors/LXMFPropagationCrossValidationTests.swift`

**Interfaces:**
- Consumes (existing): `LXMFPropagation.lxmfData(destinationHash:encryptedData:)`, `.transientId(lxmfData:)`, `.destinationHash(lxmfData:)`, `.container(timestamp:entries:)`, `.parseContainer(_:)` (4d-1); `LXMessage.packed`, `.destinationHash`, `.content`, `.hash`, `.destinationLength` (==16), `LXMessage.unpack(_:)`, `LXMessage.create(source:destinationHash:timestamp:title:content:)`, `.validateSignature(source:)`; `Identity(privateKey:)`, `Identity.encrypt(_:ratchet:)`, `Identity.decrypt(_:ratchets:enforceRatchets:)`; `Data(hexString:)`; the `LXMFPropagationFixtures` decoder (fields `recipientPrivateKey`, `sourcePrivateKey`, `destinationHash`, `content`, `propagationPacked`).
- Produces: `LXMFPropagation.pack(message:recipientIdentity:timestamp:) -> (propagationPacked: Data, transientId: Data)`; `LXMFPropagation.open(lxmfData:recipientIdentity:) -> LXMessage?`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCATests/Vectors/LXMFPropagationCrossValidationTests.swift`:

```swift
/// open() recovers the genuine reference PROPAGATED message: decrypting the reference lxmf_data tail
/// with the recipient identity yields a message whose content/destination match and whose signature
/// validates against the source identity — proving our decrypt matches genuine LXMF's encrypt.
@Test func propagationOpenRecoversReferenceMessage() throws {
    let f = try LXMFPropagationFixtures.load()
    let recipient = Identity(privateKey: Data(hexString: f.recipientPrivateKey)!)!
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let parsed = LXMFPropagation.parseContainer(Data(hexString: f.propagationPacked)!)!
    let recovered = LXMFPropagation.open(lxmfData: parsed.entries[0], recipientIdentity: recipient)
    #expect(recovered != nil)
    #expect(recovered?.content == Data(hexString: f.content)!)
    #expect(recovered?.destinationHash == Data(hexString: f.destinationHash)!)
    #expect(recovered?.validateSignature(source: source) == true)
}

/// pack() then open() round-trips one of our own messages through hedged recipient encryption.
@Test func propagationPackOpenRoundTrips() throws {
    let f = try LXMFPropagationFixtures.load()
    let recipient = Identity(privateKey: Data(hexString: f.recipientPrivateKey)!)!
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let msg = LXMessage.create(source: source, destinationHash: Data(hexString: f.destinationHash)!,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("round trip".utf8))
    let (packed, transientId) = LXMFPropagation.pack(message: msg, recipientIdentity: recipient,
                                                     timestamp: 1700000000.5)
    let parsed = LXMFPropagation.parseContainer(packed)!
    #expect(parsed.entries.count == 1)
    #expect(transientId == LXMFPropagation.transientId(lxmfData: parsed.entries[0]))   // returned id self-consistent
    let recovered = LXMFPropagation.open(lxmfData: parsed.entries[0], recipientIdentity: recipient)
    #expect(recovered?.hash == msg.hash)
    #expect(recovered?.content == Data("round trip".utf8))
    #expect(recovered?.validateSignature(source: source) == true)
}
```

- [ ] **Step 2: Run them — verify they fail**

Run: `swift test --filter LXMFPropagationCrossValidationTests`
Expected: BUILD FAILURE — `LXMFPropagation.pack` / `.open` don't exist yet. This is the expected red.

- [ ] **Step 3: Implement `pack` / `open`**

Create `Sources/ReTiCA/LXMF/LXMFPropagation+Message.swift`:

```swift
import Foundation

/// Propagation pack/open (LXMF-4d-2a): the recipient-encryption boundary for store-and-forward.
/// `pack` encrypts a message's delivery tail (packed[16:]) to the recipient and wraps it in the 4d-1
/// container; `open` reverses it. Encryption is hedged (ephemeral key + IV) — mirrors genuine LXMF
/// LXMessage.pack() PROPAGATED (LXMessage.py:429-436). Core-only (LXMessage, Identity, 4d-1 helpers).
extension LXMFPropagation {
    /// Build the propagation container for `message`, encrypting its delivery tail (packed[16:]) to
    /// `recipientIdentity`. Returns the container bytes and the (single) entry's transient_id. The
    /// encryption is hedged, so the bytes differ per call — callers that retry must reuse the result.
    public static func pack(message: LXMessage, recipientIdentity: Identity, timestamp: Double)
        -> (propagationPacked: Data, transientId: Data) {
        let tail = Data(message.packed.dropFirst(LXMessage.destinationLength))
        let encrypted = recipientIdentity.encrypt(tail)
        let entry = lxmfData(destinationHash: message.destinationHash, encryptedData: encrypted)
        return (container(timestamp: timestamp, entries: [entry]), transientId(lxmfData: entry))
    }

    /// Recover the LXMessage from one container entry by decrypting its tail with `recipientIdentity`.
    /// Returns nil if the entry is malformed or decryption/unpack fails.
    public static func open(lxmfData: Data, recipientIdentity: Identity) -> LXMessage? {
        guard let destHash = destinationHash(lxmfData: lxmfData) else { return nil }
        let encrypted = Data(lxmfData.dropFirst(LXMessage.destinationLength))
        guard let tail = recipientIdentity.decrypt(encrypted) else { return nil }
        return LXMessage.unpack(destHash + tail)
    }
}
```

- [ ] **Step 4: Run them — verify they pass**

Run: `swift test --filter LXMFPropagationCrossValidationTests`
Expected: PASS (the 4d-1 `propagationContainerMatchesReferenceLXMF` plus the two new round-trip tests).

If `propagationOpenRecoversReferenceMessage` fails at the decrypt (`recovered == nil`), the reference message may have been encrypted with a ratchet. Diagnose before proceeding: inspect whether the 4d-1 generator/destination used ratchets. (Default lxmf.delivery destinations do not enable ratchets, so the static-key `decrypt` path should succeed; if it does not, report the finding rather than working around it.)

- [ ] **Step 5: Mutation verification (one mutation at a time)**

Apply each individually in `Sources/ReTiCA/LXMF/LXMFPropagation+Message.swift`, run `swift test --filter LXMFPropagationCrossValidationTests`, confirm the named test(s) fail, revert, confirm pass, then the next.

1. **`pack` encrypts the wrong span** — change `message.packed.dropFirst(LXMessage.destinationLength)` to `message.packed.dropFirst(0)` (encrypt the whole packed).
   → `propagationPackOpenRoundTrips` FAILS (open reconstructs a misaligned `packed`; recovered hash/content/signature wrong). (`propagationOpenRecoversReferenceMessage` uses reference bytes, so it stays green — distinct.)
2. **`open` skips decryption** — replace the line `guard let tail = recipientIdentity.decrypt(encrypted) else { return nil }` with `let tail = encrypted` (use the ciphertext directly as the tail).
   → BOTH `propagationOpenRecoversReferenceMessage` and `propagationPackOpenRoundTrips` FAIL (cannot recover from ciphertext).
3. **`open` forgets the destination-hash prefix** — change `LXMessage.unpack(destHash + tail)` to `LXMessage.unpack(tail)`.
   → BOTH tests FAIL (the reconstructed `packed` is missing its leading 16 bytes → misaligned unpack).

After each: revert, re-run, expect PASS before the next.

- [ ] **Step 6: Full test gate**

Run: `swift test`
Expected: PASS. The 4d-1 baseline was 430 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 2 tests → 432 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 7: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-4d2a.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCA/LXMF/LXMFPropagation+Message.swift Tests/ReTiCATests/Vectors/LXMFPropagationCrossValidationTests.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4d2a.txt
```

Commit message body:

```
feat: LXMF-4d-2a — propagation pack/open (recipient crypto)

LXMFPropagation.pack(message, recipientIdentity, timestamp) encrypts the
delivery tail (packed[16:]) to the recipient and wraps it in the 4d-1
container, returning (propagationPacked, transientId); open(lxmfData,
recipientIdentity) decrypts + LXMessage.unpack. Closes 4d-1's deferred
decrypt round trip. Cross-val reuses the 4d-1 fixture: open() recovers
the genuine reference message (signature validates), plus our own
pack→open round trip. Encryption hedged → round-trip-validated, never
byte-compared. Ratchets deferred.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec `pack(message:recipientIdentity:timestamp:)` (encrypt tail + 4d-1 container) → Task 1 Step 3. ✓
- Spec `open(lxmfData:recipientIdentity:)` (decrypt + unpack) → Step 3. ✓
- Spec cross-val test 1 (open recovers the reference message, signature validates) → `propagationOpenRecoversReferenceMessage`, Step 1. ✓
- Spec cross-val test 2 (pack→open round trip) → `propagationPackOpenRoundTrips`, Step 1. ✓
- Spec "reuse 4d-1 fixture, no new fixture" → no fixture/Package.swift change. ✓
- Spec "hedged → never byte-compare pack output" → tests validate round trips + signatures; no byte compare of `pack`/ciphertext. ✓
- Spec "ratchets deferred" → `pack` uses `encrypt(_:ratchet: nil)` default; Step 4 notes the ratchet diagnostic if decrypt fails. ✓

**Placeholder scan:** none — every code step shows exact code.

**Type consistency:** `pack` returns `(propagationPacked: Data, transientId: Data)` and `open` returns `LXMessage?`, matching the test call sites. All consumed helpers (`lxmfData`, `transientId`, `container`, `destinationHash`, `parseContainer`) are the exact 4d-1 signatures. Fixture fields (`recipientPrivateKey`, `sourcePrivateKey`, `destinationHash`, `content`, `propagationPacked`) match the `LXMFPropagationFixtures` decoder from 4d-1.
