# LXMessage carries its received bytes Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop ReTiCA from silently dropping and silently re-encoding legitimate inbound LXMF messages, by carrying the exact received bytes on `LXMessage` and using them for both signature validation and forwarding.

**Architecture:** `LXMessage.unpack` already computes the message hash the reference way — from the *received* payload slice when no stamp is present (`LXMessage.swift:106-109`, mirroring `LXMessage.py:753-756`). `validateSignature` then throws that away and rebuilds the payload from decoded fields, and the `packed` property does the same for outbound bytes. This plan adds one stored property holding the received bytes, uses it in both places, and pins the behaviour with a test built from a *spec-legal but non-canonical* encoding.

**Tech Stack:** Swift 6, swift-testing, The Composable Architecture 1.26.

## Global Constraints

- Platform floor **iOS 17 / macOS 13 / macCatalyst 17** (`Package.swift:6-10`).
- `ReTiCATransport` is interface-agnostic; no new dependencies.
- **Wire compatibility with Python-RNS 1.4.1/1.4.2 and LXMF 1.1.0 is mandatory. No emitted byte may change for any message ReTiCA itself creates.**
- `swift-testing`, not XCTest.
- `#expect(optional?.field == x)` **aborts** when the optional is nil. Use `#expect(x != nil)` then `if let`.
- Durable records (comments, docs, allowlist) **name the enclosing function**, not a bare line number.
- Reference trees: `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/{RNS,LXMF}` is stock 1.4.2 / LXMF 1.1.0; `/Users/ell/development/python/Reticulum/RNS` is a 1.4.1 **fork** whose extra import at `Reticulum.py:37` shifts all later lines +1. **Cite the version with the line.**
- Verify every reference claim in this plan rather than inheriting it. Reference claims in the preceding slice were wrong twice, each caught only because someone re-checked.
- Mutation-verify per repo rule: run and pass; batch-mutate so all changed tests fail in one run; revert and confirm green.
- Commit trailers start at **column 0**:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Background: what is actually broken

Reference `LXMessage.unpack_from_bytes` (stock LXMF 1.1.0, `LXMessage.py:745-798`) — **verified by reading, 2026-08-15**:

```python
packed_payload = lxmf_bytes[2*DESTINATION_LENGTH+SIGNATURE_LENGTH:]
unpacked_payload = msgpack.unpackb(packed_payload)
if len(unpacked_payload) > 4:              # stamp present
    unpacked_payload = unpacked_payload[:4]
    packed_payload = msgpack.packb(unpacked_payload)   # ONLY here does it re-pack
hashed_part = destination_hash + source_hash + packed_payload
message_hash = RNS.Identity.full_hash(hashed_part)
signed_part = hashed_part + message_hash
...
message.packed = lxmf_bytes                # re-transmits the RECEIVED bytes
```

Two divergences in ReTiCA:

1. **`validateSignature` (`LXMessage.swift:118-123`) always re-encodes.** It calls `payloadBytes(...)` from decoded fields, recomputes the hash, and validates against that — ignoring `self.hash`, which `unpack` had already computed correctly. **A legitimate sender whose encoder differs from ours in any single byte fails validation, and `LXMFRouter.received` drops the message.** This is silent data loss, not a hypothetical.
2. **`packed` (`LXMessage.swift:58-62`) recomputes from fields.** A ReTiCA propagation node forwarding a message re-encodes it, so byte-exact re-encode is a correctness requirement for relaying someone else's message.

Together these also make every encode-side trap **wire-reachable**: an inbound rich message traverses decode→re-encode, which is how a recorded *host-only* `UInt16(n)` in the map encoders was one commit from being a remote abort.

**Not in scope:** the stamped path legitimately re-packs `payload[:4]` — reference does too (`:755`) — so canonical encoding remains required there. Say so; do not "fix" it.

---

## File Structure

- `Sources/ReTiCA/LXMF/LXMessage.swift` — add the stored property, use it in `validateSignature` and `packed`, add explicit `==`.
- `Tests/ReTiCATests/LXMessageReceivedBytesTests.swift` — **new**; the non-canonical-encoding tests.
- `Tests/ReTiCATests/LXMessageTests.swift` — existing round-trip tests; verify unaffected.

---

### Task 1: Carry the received bytes and validate against them

**Files:**
- Modify: `Sources/ReTiCA/LXMF/LXMessage.swift`
- Test: `Tests/ReTiCATests/LXMessageReceivedBytesTests.swift` (create)

**Interfaces:**
- Produces: `LXMessage.receivedBytes: Data?` — the exact bytes `unpack` was given; `nil` for locally-created messages. Task 2 consumes it in `packed`.

- [ ] **Step 1: Write the failing test — a spec-legal, non-canonical encoding.**

The point is a payload that is *valid msgpack* and *correctly signed* but not byte-identical to our encoder's output. MessagePack permits a longer length prefix than strictly necessary: a 5-byte binary may be encoded `bin16` (`0xC5 0x00 0x05 …`) where our `MsgPack.encode` emits `bin8` (`0xC4 0x05 …`). Both decode to the same value.

Build the payload array by hand so the title uses `bin16`, sign over the **hand-built** bytes exactly as a sender would, then unpack and validate.

```swift
import Foundation
import Testing
@testable import ReTiCA

@Suite("LXMessage validates against received bytes")
struct LXMessageReceivedBytesTests {

    /// A payload whose `title` is encoded `bin16` rather than the canonical `bin8`. Spec-legal:
    /// MessagePack permits any length prefix that can represent the length. Our encoder emits
    /// `bin8`, so this is a sender we must accept but cannot reproduce byte-for-byte.
    private func nonCanonicalPayload(timestamp: Double, title: Data, content: Data) -> Data {
        var out = Data([0x94])                                  // fixarray of 4
        out += MsgPack.encode(.double(timestamp))
        out += Data([0xC5, UInt8(title.count >> 8), UInt8(title.count & 0xFF)]) + title  // bin16
        out += MsgPack.encode(.bin(content))
        out += MsgPack.encode(.map([]))                         // empty fields
        return out
    }

    @Test("a validly-signed message in a non-canonical encoding still validates")
    func nonCanonicalEncodingValidates() {
        let source = Identity()
        let sourceHash = LXMessage.deliveryHash(identityHash: source.hash)
        let destinationHash = LXMessage.deliveryHash(identityHash: Identity().hash)
        let title = Data("hi".utf8)
        let content = Data("hello world".utf8)

        let payload = nonCanonicalPayload(timestamp: 1700000000.5, title: title, content: content)
        let hashedPart = destinationHash + sourceHash + payload
        let hash = Crypto.fullHash(hashedPart)
        let signature = source.sign(hashedPart + hash)
        let wire = destinationHash + sourceHash + signature + payload

        let msg = LXMessage.unpack(wire)
        #expect(msg != nil)
        if let msg {
            #expect(msg.title == title)
            #expect(msg.content == content)
            #expect(msg.hash == hash)
            // The defect: we re-encode the payload as bin8, so the recomputed hash differs and
            // the signature check fails against a message that is genuinely valid.
            #expect(msg.validateSignature(source: source) == true)
        }
    }

    @Test("a canonically-encoded message still validates")
    func canonicalEncodingStillValidates() {
        let source = Identity()
        let msg = LXMessage.create(source: source,
                                   destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                                   timestamp: 1700000000.5,
                                   title: Data("hi".utf8), content: Data("hello world".utf8))
        let reparsed = LXMessage.unpack(msg.packed)
        #expect(reparsed != nil)
        if let reparsed { #expect(reparsed.validateSignature(source: source) == true) }
    }

    @Test("a tampered payload still fails validation")
    func tamperedPayloadFailsValidation() {
        let source = Identity()
        let msg = LXMessage.create(source: source,
                                   destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                                   timestamp: 1700000000.5,
                                   title: Data("hi".utf8), content: Data("hello world".utf8))
        var wire = msg.packed
        wire[wire.count - 1] ^= 0xFF                 // flip a byte inside the payload
        if let tampered = LXMessage.unpack(wire) {
            #expect(tampered.validateSignature(source: source) == false)
        }
    }
}
```

**Confirm `Identity()` is the correct no-argument initializer for a fresh identity before writing this** — check `Sources/ReTiCA/Identity/Identity.swift` and match whatever the existing `LXMessageTests.swift` uses. Adjust the helper names if they differ; the *shape* of the test is what matters, not these exact spellings.

- [ ] **Step 2: Run it and confirm RED.**

Run: `swift test --filter 'LXMessageReceivedBytesTests'`
Expected: `nonCanonicalEncodingValidates` **FAILS** on the `validateSignature` expectation. The other two **PASS** — they must, since they encode canonically; if either fails you have a different bug and should stop and diagnose.

- [ ] **Step 3: Add the stored property.**

Add to the property block (after `stamp`, `LXMessage.swift:19`):

```swift
    /// The exact bytes `unpack` was given, retained so signature validation and forwarding use what
    /// the sender actually sent rather than what our encoder would have produced. `nil` for messages
    /// built locally by `create`, which have no wire form yet.
    ///
    /// Mirrors reference `message.packed = lxmf_bytes` (lxmf 1.1.0 `LXMessage.py:797`). Without it a
    /// sender whose MessagePack encoder differs from ours in any single legal way — a `bin16` length
    /// prefix where we emit `bin8`, say — fails signature validation and the message is dropped.
    /// Excluded from `==` on purpose: see the `Equatable` conformance below.
    public let receivedBytes: Data?
```

Add `receivedBytes` to the memberwise initializer with a default of `nil` so no existing call site changes, and set it in `unpack`.

- [ ] **Step 4: Make `==` explicit, excluding `receivedBytes`.**

`LXMessage` is `Equatable` (`LXMessage.swift:7`) with a synthesized `==`. Adding a stored property silently changes equality: a message off the wire would no longer equal a semantically identical one built locally. Two messages are equal when their *content* is; retained provenance is a cache, not identity.

```swift
    /// Compares message content only. `receivedBytes` is deliberately excluded — it is a cache of how
    /// this message arrived, not part of what it says, and including it would make a round-tripped
    /// message unequal to the one it round-tripped from.
    public static func == (lhs: LXMessage, rhs: LXMessage) -> Bool {
        lhs.destinationHash == rhs.destinationHash && lhs.sourceHash == rhs.sourceHash
            && lhs.timestamp == rhs.timestamp && lhs.title == rhs.title
            && lhs.content == rhs.content && lhs.hash == rhs.hash
            && lhs.signature == rhs.signature && lhs.fields == rhs.fields && lhs.stamp == rhs.stamp
    }
```

- [ ] **Step 5: Use it in `validateSignature`.**

`unpack` already computed the hash the reference way (`LXMessage.swift:106-110`). `validateSignature` must use that work instead of redoing it differently:

```swift
    /// Validate the signature against the resolved source identity (the caller resolves it by
    /// `sourceHash`). For a message off the wire this validates the bytes **as received**, matching
    /// reference `signed_part` (lxmf 1.1.0 `LXMessage.py:761`); only a locally-created message, which
    /// has no received form, is validated against re-encoded fields.
    ///
    /// A stamped message still re-packs `payload[:4]`, exactly as reference does at
    /// `LXMessage.py:755` — canonical encoding remains required on that path, by design, not oversight.
    public func validateSignature(source: Identity) -> Bool {
        let hashedPart: Data
        if let receivedBytes, stamp == nil {
            let headerLen = 2 * LXMessage.destinationLength + LXMessage.signatureLength
            hashedPart = destinationHash + sourceHash + Data(receivedBytes.dropFirst(headerLen))
        } else {
            hashedPart = destinationHash + sourceHash
                + LXMessage.payloadBytes(timestamp: timestamp, title: title,
                                         content: content, fields: fields)
        }
        return source.validate(signature: signature, message: hashedPart + Crypto.fullHash(hashedPart))
    }
```

Note the `stamp == nil` condition mirrors reference's `len(unpacked_payload) > 4` branch. Confirm that reading against `LXMessage.py:753-761` yourself before committing to it.

- [ ] **Step 6: Run the tests and confirm all three pass.**

Run: `swift test --filter 'LXMessageReceivedBytesTests'`
Expected: PASS, all three.

- [ ] **Step 7: Full suite plus the gate.**

Run: `swift test`
Run: `Scripts/check-wire-narrowing.swift --fail-on-open`
Expected: green; conversion count unchanged (this task adds no conversions).

Pay attention to any existing test that compares two `LXMessage` values or round-trips one — Step 4 is meant to keep those passing, and a failure there means the `==` exclusion is wrong or incomplete.

- [ ] **Step 8: Mutation-verify.** In one batch: (a) in `validateSignature`, change the `if let receivedBytes, stamp == nil` condition to `if false`; (b) in `unpack`, set `receivedBytes: nil`. Both should make `nonCanonicalEncodingValidates` fail. Revert; confirm green.

- [ ] **Step 9: Commit.**

---

### Task 2: Forward the received bytes instead of re-encoding

**Files:**
- Modify: `Sources/ReTiCA/LXMF/LXMessage.swift` (the `packed` property)
- Test: `Tests/ReTiCATests/LXMessageReceivedBytesTests.swift` (extend)

**Interfaces:**
- Consumes: `LXMessage.receivedBytes` from Task 1.

Fixing only validation "would read as done" while leaving relaying exposed — that is the explicit reason this is two tasks and not one.

- [ ] **Step 1: Write the failing test.**

```swift
    @Test("forwarding preserves the sender's exact bytes")
    func forwardingPreservesReceivedBytes() {
        let source = Identity()
        let sourceHash = LXMessage.deliveryHash(identityHash: source.hash)
        let destinationHash = LXMessage.deliveryHash(identityHash: Identity().hash)
        let title = Data("hi".utf8)
        let content = Data("hello world".utf8)

        let payload = nonCanonicalPayload(timestamp: 1700000000.5, title: title, content: content)
        let hashedPart = destinationHash + sourceHash + payload
        let signature = source.sign(hashedPart + Crypto.fullHash(hashedPart))
        let wire = destinationHash + sourceHash + signature + payload

        let msg = LXMessage.unpack(wire)
        #expect(msg != nil)
        // A relay must hand on what it received. Re-encoding would emit bin8 where the sender used
        // bin16, changing the bytes and invalidating the signature for every downstream hop.
        if let msg { #expect(msg.packed == wire) }
    }

    @Test("a locally-created message still packs from its fields")
    func locallyCreatedMessagePacksFromFields() {
        let source = Identity()
        let msg = LXMessage.create(source: source,
                                   destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                                   timestamp: 1700000000.5,
                                   title: Data("hi".utf8), content: Data("hello world".utf8))
        #expect(msg.packed.count > 0)
        #expect(LXMessage.unpack(msg.packed) != nil)
    }
```

- [ ] **Step 2: Run and confirm RED** on `forwardingPreservesReceivedBytes` only.

- [ ] **Step 3: Implement.**

```swift
    /// The on-wire bytes: destinationHash ‖ sourceHash ‖ signature ‖ msgpack(payload).
    ///
    /// A message that came off the wire returns **exactly what it received**, mirroring reference
    /// `message.packed = lxmf_bytes` (lxmf 1.1.0 `LXMessage.py:797`) — a relay must not re-encode
    /// someone else's message, because any legal encoding difference would invalidate their
    /// signature for every downstream hop. Only a locally-created message is packed from its fields.
    public var packed: Data {
        if let receivedBytes { return receivedBytes }
        return destinationHash + sourceHash + signature
            + LXMessage.payloadBytes(timestamp: timestamp, title: title,
                                     content: content, fields: fields, stamp: stamp)
    }
```

- [ ] **Step 4: Check `withStamp` — this is the trap in this task.**

`withStamp` (`LXMessage.swift:66-69`) returns a copy with a stamp attached. If it carries `receivedBytes` through unchanged, `packed` would return the **pre-stamp** bytes and silently discard the stamp. Verify and handle it: a stamped copy of a received message must either drop `receivedBytes` or re-pack. Add a test asserting `withStamp(...).packed` actually contains the stamp — round-trip it and check `unpack(...)?.stamp` matches.

- [ ] **Step 5: Verify the forwarding consumers** at `LXMFPropagation+Message.swift:21` (`pack`, which does `message.packed.dropFirst(16)`) and `LXMFRouter.swift:340,342,423,425` (`sendDirect`/`arm`). Confirm each still behaves correctly for both received and locally-created messages, and say in the report which you checked and how.

- [ ] **Step 6: Full suite plus the gate.** Then **mutation-verify**: make `packed` ignore `receivedBytes`; `forwardingPreservesReceivedBytes` must fail. Revert; confirm green.

- [ ] **Step 7: Update the checklist.** Tick Tier 2b in `docs/reference-parity-checklist.md`, recording the fixing commits and naming the enclosing functions (`validateSignature`, `packed`). Do **not** re-stamp the header date unless you re-checked the other items. Note explicitly that the stamped path still requires canonical encoding, and why that is parity rather than a remaining gap.

- [ ] **Step 8: Commit.**

---

## Self-review notes for the implementer

- **The `Identity()` spellings in these tests are unverified.** Match the existing `LXMessageTests.swift`. If a fresh identity needs different construction, adapt — do not force these exact names.
- **`bin16`-for-a-short-payload must actually be legal and must actually differ from our encoder's output.** Verify both before building the test on it: decode your hand-built payload with `MsgPack.decodeValue` and confirm it yields the same values, and confirm `MsgPack.encode` emits `bin8` for the same input. If our decoder happens to reject `bin16`, that is itself a finding — report it and pick another legal divergence (a `map16` empty map, or a longer-than-needed array prefix).
- **Do not change `MsgPack.encode`.** Canonical output is required for every message we originate; this plan changes only which bytes we *validate and forward*.
