# Hostile-Input Hardening Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every remotely reachable crash, unbounded-allocation and fail-open path found in §2 of `docs/reference-gap-analysis-2026-08-10.md`, so that a hostile or merely buggy peer cannot kill the process or silently downgrade confidentiality.

**Architecture:** Six independent tasks across the pure core (`Identity`, `Destination`, `HDLC`) and `ReTiCATransport` (`Bzip2`, `ResourceTransfer`, `Transport`). The unifying principle is **validate at the ingress boundary, and never fail open**: untrusted bytes are checked where they enter, and where a check fails the operation must fail *closed* (drop / return nil), never fall through to plaintext or a force-unwrap.

**Tech Stack:** Swift 6, CryptoKit, The Composable Architecture, `swift-testing`.

## Global Constraints

- Platform floor iOS 16 / macOS 13 (package-wide; do not raise).
- The `ReTiCA` core target has **zero third-party dependencies** — keep it that way.
- `ReTiCATransport` is interface-agnostic — no Network.framework, no CoreBluetooth.
- Wire compatibility with Python-RNS 1.4.1/1.4.2 is mandatory. **None of these tasks may change a byte we emit.** They change only what we *accept*. If a task's diff alters an outbound packet, stop and escalate.
- Reference Python: `/Users/ell/development/python/Reticulum/RNS`.
- Tests use `swift-testing` (`import Testing`, `@Test func …`, `#expect`), NOT XCTest.
- Run `swift package clean` before the first build — `RingSet`'s layout changed in `4b968ba` and incremental builds have stale-linked into a SIGSEGV.
- **Never widen a fail-open.** Where reference raises and we currently return plaintext or a default, the fix is to return `nil`/reject — not to pick a "safe-looking" fallback value.
- Verify per the three-step process: (a) run and confirm pass, (b) mutate the guard away and confirm every new test fails, (c) revert and confirm pass.
- Commit after each task. Trailers must start at column 0:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

### One rule that binds every task

**A test that proves a crash no longer happens must first prove the crash DID happen.** A Swift trap or `preconditionFailure` cannot be caught in-process, so you cannot write an XCTest-style "expect no crash". Instead, assert the *observable substitute*: the function now returns `nil` / the packet is dropped / the buffer is bounded. Then verify RED by reverting the guard and confirming the test **crashes the test process** — record that crash output in your report as the RED evidence. A green test with no demonstrated RED proves nothing here.

---

### Task 1: `Identity` rejects public keys that cannot perform key agreement

**Why:** `Identity.swift:77-85` force-unwraps three throwing CryptoKit calls, including `try! ephemeral.sharedSecretFromKeyAgreement(with: targetPub)`. CryptoKit **accepts** a low-order Curve25519 point at `PublicKey(rawRepresentation:)` and only throws at key agreement — so the existing validation in `init?(publicKey:)` (`Identity.swift:45-47`), which constructs the public key, is **not sufficient**. Construction-validity is not agreement-validity.

Reachability: an attacker generates a real Ed25519 keypair, uses a low-order 32-byte value as the X25519 half, and derives a matching destination hash. The announce's Ed25519 signature and the `destinationHash == SHA256(nameHash ‖ identityHash)[:16]` binding (`Announce.swift:60-63`) both pass, because neither touches the X25519 key. The identity lands in `Transport.State.learned`; the first `.send` to it reaches `Transport.swift:772` → `Identity.swift:81` → **process abort**.

Reference does not abort: pure-Python `X25519PrivateKey.exchange` performs no check and returns an all-zero secret; PyCA raises a catchable `ValueError`.

**Fix:** make `init?(publicKey:)` perform a trial key agreement and return `nil` if it throws. Then every `Identity` that exists is safe to encrypt to, the `try!` becomes genuinely unreachable, and every ingress path inherits the check for free — `Announce.parse` constructs an `Identity`, so bad keys never enter the path table.

**Cost note to record in the comment:** this adds one X25519 operation per `Identity(publicKey:)` construction. Announce validation already performs an Ed25519 signature verification, which is the same order of magnitude, and announce ingest is already rate-limited by ingress control — so this does not create a new CPU-amplification vector. State that reasoning in the code, because "add a crypto op to a hot path" deserves a justification a reviewer can check.

**Files:**
- Modify: `Sources/ReTiCA/Identity/Identity.swift:41-52`
- Test: `Tests/ReTiCATests/Identity/IdentityTests.swift`

**Interfaces:** no signature change. `init?(publicKey:)` returns `nil` for strictly more inputs than before.

- [ ] **Step 1: Write the failing test.**

```swift
// CryptoKit accepts a low-order Curve25519 point at PublicKey(rawRepresentation:) and only
// throws at key agreement. Identity must reject such a key at construction, or the force-try
// in encrypt() aborts the process on the first send to that peer.
@Test func identityRejectsLowOrderX25519PublicKey() {
    let sig = Curve25519.Signing.PrivateKey().publicKey.rawRepresentation
    // Canonical low-order points: all-zero, and 0x01 followed by zeros.
    for lowOrder in [Data(repeating: 0x00, count: 32),
                     Data([0x01]) + Data(repeating: 0x00, count: 31)] {
        #expect(Identity(publicKey: lowOrder + sig) == nil)
    }
    // A genuine key still constructs.
    let good = Identity()
    #expect(Identity(publicKey: good.publicKey) != nil)
}
```

Add `import CryptoKit` to the test file if it is not already there.

- [ ] **Step 2: Run and confirm it fails.** `swift test --filter identityRejectsLowOrderX25519PublicKey` — expect FAIL, because the low-order keys currently construct successfully.

- [ ] **Step 3: Add the trial agreement** in `init?(publicKey:)`, after the existing construction guards:

```swift
        // CryptoKit accepts a low-order point here but throws at key agreement, so
        // constructibility is NOT sufficient — a peer can announce such a key with a valid
        // Ed25519 signature and a matching destination hash, and the force-try in encrypt()
        // would abort the process on our first send. Reject it at the boundary instead.
        //
        // Cost: one X25519 op per construction. Announce validation already does an Ed25519
        // verify of the same order, and announce ingest is ingress-rate-limited, so this adds
        // no new CPU-amplification surface.
        guard let encKey = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: encPub),
              (try? Curve25519.KeyAgreement.PrivateKey()
                  .sharedSecretFromKeyAgreement(with: encKey)) != nil
        else { return nil }
```

Restructure the existing guard at `:45-47` so `encPub` is constructed once, not twice.

- [ ] **Step 4: Run** `swift test --filter Identity`. Expected: all pass.
- [ ] **Step 5: Verify RED/GREEN**, then run the full `swift test` — this changes a core type used everywhere.
- [ ] **Step 6: Commit** — `fix: reject X25519 public keys that cannot perform key agreement`.

---

### Task 2: An announced ratchet is validated before use

**Why:** Task 1 closes the identity-key path, but the announced 32-byte `ratchet` is a **second, independent** route to the same `try!`. It is parsed at `Announce.swift:50-53`, stored at `Transport.swift:429` into `LearnedDestination.ratchet`, and passed to `Identity.encrypt(_:ratchet:)` at `Transport.swift:772`, where it becomes `targetPub` at `Identity.swift:79-81`. A low-order ratchet aborts the process exactly as a low-order identity key would. `LXMFPropagation+Message.swift:16` reaches the same code.

**Fix:** validate the ratchet where the announce is parsed. **Drop the ratchet, keep the announce** — a peer with an unusable ratchet is still reachable via its static key, and rejecting the whole announce would deny us a working path over a field that is optional anyway. Falling back to the static key is exactly what happens today for peers that announce no ratchet at all.

**Files:**
- Modify: `Sources/ReTiCA/Destination/Announce.swift` (the ratchet extraction)
- Test: `Tests/ReTiCATests/Destination/AnnounceTests.swift`

**Interfaces:** no signature change. `Announce.parse` may now return a result whose `ratchet` is `nil` where it previously carried unusable bytes.

- [ ] **Step 1: Write the failing test** — build a genuine, correctly-signed announce carrying a low-order 32-byte ratchet, parse it, and assert the parse succeeds with `ratchet == nil`. Reuse whatever helper `AnnounceTests.swift` already uses to build a signed announce; do not hand-roll the signature.

- [ ] **Step 2: Run and confirm it fails** — `ratchet` currently comes back as the low-order bytes.

- [ ] **Step 3: Add the validation.** Introduce one shared helper rather than duplicating Task 1's logic — add to `Identity`:

```swift
    /// True if `key` is a 32-byte X25519 public key usable for key agreement. CryptoKit accepts
    /// low-order points at construction and only throws at agreement, so this does a trial
    /// exchange. Used to validate announced ratchets before they reach `encrypt(_:ratchet:)`.
    public static func isUsableX25519PublicKey(_ key: Data) -> Bool {
        guard key.count == Identity.halfKey,
              let pub = try? Curve25519.KeyAgreement.PublicKey(rawRepresentation: key),
              (try? Curve25519.KeyAgreement.PrivateKey()
                  .sharedSecretFromKeyAgreement(with: pub)) != nil
        else { return false }
        return true
    }
```

`halfKey` is currently `private static let` (`Identity.swift:8`) — this helper is inside `Identity`, so it can read it. Use the helper in Task 1's guard too, so there is one implementation.

Then in `Announce.parse`, drop a ratchet that fails the check, with a comment explaining why the announce is still accepted.

- [ ] **Step 4: Run** `swift test --filter Announce`, then the full suite.
- [ ] **Step 5: Verify RED/GREEN. Commit** — `fix: drop an announced ratchet that cannot perform key agreement`.

---

### Task 3: Bounded bzip2 decompression

**Why:** `ResourceTransfer.swift:377` calls `Bzip2.decompress(payload, expectedSize: Int(adv.dataSize))`, where `adv.dataSize` is an unbounded `UInt64` read straight off the wire (`ResourceAdvertisement.swift:7, 60`). `Bzip2.decompress` then does `var destLen = UInt32(max(expectedSize, 1))` (`Bzip2.swift:28`) and allocates that many bytes (`:29`).

Two distinct failure modes:
- `d` above `UInt32.max` → the `UInt32(...)` conversion **traps**, a deterministic Swift runtime crash before any allocation.
- `d` between ~1 GiB and 4 GiB → a genuine multi-gigabyte allocation.

Reachable by any peer that can establish a link, which is currently unconditional.

Reference clamps to `AUTO_COMPRESS_MAX_SIZE` = 64 MiB (`Resource.py:124, 360`) and enforces it with `decompressor.decompress(data, max_length=…)` plus an explicit `decompressor.eof` check that marks the resource CORRUPT and cancels (`Resource.py:690-696`). Reference **also** rejects an advertisement with `adv.t > MAX_EFFICIENT_SIZE*3` at unpack (`Resource.py:1366`) — we have no magnitude validation at all in `ResourceAdvertisement.unpack` (`ResourceAdvertisement.swift:44-63`).

**Secondary bug in the same line:** for a **split** resource, `dataSize` is the *whole object's* size (`ResourceTransfer.swift:80`, fed by `LinkSession.swift:504`), so every segment allocates a decompression buffer sized to the entire multi-megabyte object rather than to that segment.

**Fix, three layers:**
1. `ResourceAdvertisement.unpack` rejects `transferSize > LinkSession.maxEfficientSize * 3`, mirroring `Resource.py:1366`. Put the constant in `Resource`, not `LinkSession`, so the pure core owns it.
2. `Bzip2.decompress` takes a hard ceiling and returns `nil` above it — never a force conversion. Replace `UInt32(max(expectedSize, 1))` with a guard.
3. The caller passes the **segment's** expected size, not the whole object's, and clamps to the 64 MiB auto-compress ceiling.

**Files:**
- Modify: `Sources/ReTiCATransport/Bzip2.swift:26-42`
- Modify: `Sources/ReTiCA/Resource/ResourceAdvertisement.swift` (unpack validation) and `Resource.swift` (the constant)
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift:377`
- Test: `Tests/ReTiCATests/Resource/ResourceAdvertisementTests.swift`, `Tests/ReTiCATransportTests/` (bzip2 bound)

- [ ] **Step 1: Write three failing tests.**

```swift
// A declared size above UInt32.max used to TRAP on the UInt32 conversion before allocating.
@Test func bzip2DecompressRejectsAbsurdExpectedSize() {
    let compressed = Bzip2.compress(Data(repeating: 0x41, count: 1024))!
    #expect(Bzip2.decompress(compressed, expectedSize: Int(UInt32.max) + 1) == nil)
    #expect(Bzip2.decompress(compressed, expectedSize: Resource.autoCompressMaxSize + 1) == nil)
    // A legitimate size still round-trips.
    #expect(Bzip2.decompress(compressed, expectedSize: 1024)?.count == 1024)
}
```

Plus a test that `ResourceAdvertisement.unpack` returns `nil` for an advertisement declaring `t` above `Resource.maxAdvertisedTransferSize`, and one asserting a legitimate advertisement still unpacks. Build the oversized advertisement with `ResourceAdvertisement.pack` so it is structurally valid and only the magnitude is hostile.

- [ ] **Step 2: Run and confirm.** The `UInt32.max + 1` case will **crash the test process** rather than fail — that is the RED evidence; capture it verbatim in your report.

- [ ] **Step 3: Add the constants** to `Sources/ReTiCA/Resource/Resource.swift`:

```swift
    /// Reference `AUTO_COMPRESS_MAX_SIZE` (RNS/Resource.py:124) — the largest payload reference
    /// will auto-compress, and the ceiling it enforces when decompressing (RNS/Resource.py:360).
    public static let autoCompressMaxSize = 64 * 1024 * 1024
    /// Reference rejects an advertisement declaring more than MAX_EFFICIENT_SIZE*3
    /// (RNS/Resource.py:1366). An advertisement is attacker-controlled, so this bound is what
    /// stops a declared size becoming an allocation.
    public static let maxAdvertisedTransferSize = 1_048_575 * 3
```

- [ ] **Step 4: Bound `Bzip2.decompress`.** Replace lines 27-29:

```swift
    static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return expectedSize == 0 ? Data() : nil }
        // `expectedSize` is attacker-controlled (it comes from a RESOURCE_ADV's `d` field), so it
        // is a claim, not a fact. Above UInt32.max the old `UInt32(...)` conversion TRAPPED before
        // allocating; between 1-4 GiB it allocated for real. Reference clamps to
        // AUTO_COMPRESS_MAX_SIZE and checks decompressor.eof (RNS/Resource.py:360, 690-696).
        guard expectedSize > 0, expectedSize <= Resource.autoCompressMaxSize else { return nil }
        var destLen = UInt32(expectedSize)
        var dest = [UInt8](repeating: 0, count: expectedSize)
```

`Bzip2` is in `ReTiCATransport` and `Resource` is in `ReTiCA`; confirm the import is already present (it is — `ResourceTransfer` uses both).

- [ ] **Step 5: Validate the advertisement** in `ResourceAdvertisement.unpack`, rejecting `t > Resource.maxAdvertisedTransferSize`.

- [ ] **Step 6: Pass the segment size** at `ResourceTransfer.swift:377`. For a split resource use the size of *this segment's* payload, not `adv.dataSize`. Read the surrounding code to determine the correct expression and state in your report which value you used and why it is the segment's, not the object's.

- [ ] **Step 7:** run the full suite, verify RED/GREEN, commit — `fix: bound bzip2 decompression by the advertised-size ceiling`.

---

### Task 4: A GROUP destination rejects a key it cannot use

**Why:** `Destination.encrypt` returns **plaintext** when the group key is unusable (`Destination.swift:78`: `guard let key = groupKey, let token = try? Token(key: key) else { return plaintext }`), while `decrypt` at `:91` correctly returns `nil` for the same condition. That asymmetry is the tell. `init?` at `:50` checks only `groupKey != nil`, never its length, and `Token.init` requires exactly 32 or 64 bytes — so a GROUP destination built with, say, a 16-byte key **silently emits cleartext on the wire**. Reference raises instead (`Destination.py:620`).

**Fix:** validate the key at construction so an unusable one cannot exist. Then the encrypt guard is unreachable, and the fail-open is gone by construction rather than by a second check.

**Files:**
- Modify: `Sources/ReTiCA/Destination/Destination.swift:50` (and the `encrypt` comment at `:78`)
- Test: `Tests/ReTiCATests/Destination/DestinationTests.swift`

- [ ] **Step 1: Write the failing test.**

```swift
// A GROUP destination whose key Token cannot use must not be constructible — otherwise
// encrypt() falls through and emits CLEARTEXT (Destination.swift:78), where reference raises
// (RNS/Destination.py:620).
@Test func groupDestinationRejectsUnusableKey() {
    for badLength in [0, 15, 16, 24, 33, 63, 65] {
        let d = Destination(kind: .group, direction: .in, appName: "t", aspects: ["g"],
                            groupKey: Data(repeating: 0x11, count: badLength))
        #expect(d == nil, "group key of \(badLength) bytes must be rejected")
    }
    for goodLength in [32, 64] {
        let d = Destination(kind: .group, direction: .in, appName: "t", aspects: ["g"],
                            groupKey: Data(repeating: 0x11, count: goodLength))
        #expect(d != nil)
        // And it must actually encrypt, not pass through.
        let plaintext = Data([0xDE, 0xAD])
        #expect(d!.encrypt(plaintext) != plaintext)
    }
}
```

The `encrypt(plaintext) != plaintext` assertion is the load-bearing one — it is what a length check alone would not prove.

- [ ] **Step 2: Run and confirm it fails** for the bad lengths (they construct today) and, for a 16-byte key, that `encrypt` returns the plaintext unchanged.

- [ ] **Step 3: Validate in `init?`.** Change the `.group` case at `:50` to require that a `Token` can actually be built from the key, rather than merely that the key is non-nil. Update the comment at `:78` to record that the guard is now unreachable-by-construction and must **never** be relaxed to return plaintext.

- [ ] **Step 4:** run `swift test --filter Destination`, then the full suite. Verify RED/GREEN. Commit — `fix: a GROUP destination with an unusable key no longer emits cleartext`.

---

### Task 5: `enforceRatchets` fails closed

**Why:** `Identity.swift:108` places `if enforceRatchets { return nil }` **inside** the `if let ratchets` block, so `decrypt(token, ratchets: nil, enforceRatchets: true)` falls through to the static-key branch (`:111-114`) and **decrypts** — the exact opposite of the requirement. Reference dedents the check outside the block (`Identity.py:880`: `if enforce_ratchets and plaintext == None:`) and returns `None`, and it makes exactly that call whenever a ratchet-enforcing destination has no ratchets loaded (`Destination.py:654`).

Latent today — nothing in `Sources/` passes `enforceRatchets: true` — but it is a silent security hole the moment enforcement is wired up, and enforcement is a prerequisite for the forward-secrecy work in §7.

**Files:**
- Modify: `Sources/ReTiCA/Identity/Identity.swift:97-114`
- Test: `Tests/ReTiCATests/Identity/IdentityTests.swift`

- [ ] **Step 1: Write the failing test.**

```swift
// Reference checks enforcement OUTSIDE the `if ratchets:` block (RNS/Identity.py:880), so a
// ratchet-enforcing destination with NO ratchets loaded drops the packet. Ours fell through to
// the static key and decrypted — the opposite of enforcement.
@Test func enforceRatchetsFailsClosedWithNoRatchets() {
    let id = Identity()
    let pub = Identity(publicKey: id.publicKey)!
    let ciphertext = pub.encrypt(Data([0x01, 0x02, 0x03]))

    // Baseline: without enforcement the static key decrypts.
    #expect(id.decrypt(ciphertext) == Data([0x01, 0x02, 0x03]))
    // With enforcement and no ratchets, it must NOT decrypt.
    #expect(id.decrypt(ciphertext, ratchets: nil, enforceRatchets: true) == nil)
    #expect(id.decrypt(ciphertext, ratchets: [], enforceRatchets: true) == nil)
}
```

Note both the `nil` and the empty-array case: `ratchets: []` enters the `if let` block, loops zero times, and hits the existing check — so that one may already pass. `ratchets: nil` is the broken path. Assert both so the fix cannot regress either.

- [ ] **Step 2: Run and confirm** the `ratchets: nil` case fails (it returns the plaintext).

- [ ] **Step 3: Dedent the check** so it runs whenever no ratchet produced a plaintext, matching `Identity.py:880`. Cite that line in a comment.

- [ ] **Step 4:** run the full suite, verify RED/GREEN, commit — `fix: enforceRatchets fails closed when no ratchets are supplied`.

---

### Task 6: The HDLC deframer is bounded

**Why:** `HDLCDeframer.ingest` (`HDLC.swift:61-72`) breaks out at `:65` (no FLAG found) and `:66` (opening FLAG with no closing FLAG) **without clearing `buffer`**, and bounds frames only from below (`:68`, `frame.count > minFrameSize`). Any TCP peer that streams bytes without ever sending `0x7E` grows the buffer without bound — unbounded memory growth on a network-facing path in an iOS app.

Reference has both clamps and an upper frame bound:
- `TCPInterface.py:408` — `if len(frame_buffer) > self.HW_MTU*2: frame_buffer = b""` when an opening flag has no closing flag.
- `TCPInterface.py:411` — `frame_buffer = b""` when no flags are present at all.
- `TCPInterface.py:335-338` — `check_frame_len` rejects `<= HEADER_MINSIZE` **and** `> HW_MTU + ifac_size`.

**Design note:** `HDLC` lives in the pure core and has no interface knowledge, so it cannot read `HW_MTU`. Add a `maxFrameSize` initialiser parameter with a documented default, and let the interface layer pass its real value later. Default to a value that cannot reject legitimate traffic: reference's TCP `HW_MTU` is large, and ReTiCA's `InterfaceProfile.hwMTU` is 262144 for TCP and 1196 for BLE (`InterfaceProfile.swift:49-51`). Use **262144** as the default so the bound is a runaway guard rather than a policy, and note that a caller with a smaller medium should pass its own.

**Files:**
- Modify: `Sources/ReTiCA/Framing/HDLC.swift:53-73`
- Test: `Tests/ReTiCATests/Framing/HDLCTests.swift`

**Interfaces produced:** `HDLCDeframer.init(minFrameSize:maxFrameSize:)` — `maxFrameSize` defaulted, so existing call sites keep compiling.

- [ ] **Step 1: Write the failing tests.**

```swift
// A peer that never sends a FLAG must not grow the deframer without bound.
@Test func deframerDiscardsRunawayInputWithNoFlag() {
    var d = HDLCDeframer(maxFrameSize: 1024)
    for _ in 0..<64 {
        #expect(d.ingest(Data(repeating: 0x41, count: 1024)).isEmpty)
    }
    #expect(d.bufferedByteCount <= 1024 * 2)
}

// An opening FLAG with no closing FLAG must also be bounded.
@Test func deframerDiscardsUnterminatedFrame() {
    var d = HDLCDeframer(maxFrameSize: 1024)
    _ = d.ingest(Data([HDLC.flag]))
    for _ in 0..<64 {
        #expect(d.ingest(Data(repeating: 0x41, count: 1024)).isEmpty)
    }
    #expect(d.bufferedByteCount <= 1024 * 2)
}

// A legitimate frame still round-trips after a runaway reset.
@Test func deframerRecoversAfterDiscard() {
    var d = HDLCDeframer(maxFrameSize: 1024)
    _ = d.ingest(Data(repeating: 0x41, count: 4096))
    let payload = Data(repeating: 0x5A, count: 40)
    #expect(d.ingest(HDLC.frame(payload)) == [payload])
}
```

This needs a `bufferedByteCount` accessor. Add it as a `public var` on `HDLCDeframer` with a comment saying it exists for the bound tests — that is honest and better than making `buffer` public.

- [ ] **Step 2: Run and confirm the two bound tests fail** (the buffer grows to 64 KiB+).

- [ ] **Step 3: Add the bound.** Give `HDLCDeframer` a `maxFrameSize` (default 262144), and in `ingest`: after the two `break` paths, clear `buffer` when it exceeds `maxFrameSize * 2` with no closing flag, and clear it entirely when no FLAG is present at all. Also reject an assembled frame longer than `maxFrameSize` rather than delivering it, mirroring `check_frame_len`. Cite `TCPInterface.py:337, 408, 411` in the comment.

Be careful to preserve the existing shared-FLAG behaviour: `buffer = Array(buffer[end...])` at `:69` deliberately keeps the closing FLAG as the next opening FLAG. Do not break that — there is a round-trip test for it.

- [ ] **Step 4:** run `swift test --filter HDLC`, then the full suite. Verify RED/GREEN. Commit — `fix: bound the HDLC deframer so a flagless peer cannot exhaust memory`.

---

## Self-review notes

- **Coverage:** §2.1 → Task 3; §2.2 → Tasks 1 and 2 (two independent routes to the same `try!`); §2.4 → Task 4; §2.5 → Task 5; §2.6 → Task 6.
- **Correction carried in:** the gap analysis says `Identity(publicKey:)` "validates only length". That is **wrong** — `Identity.swift:45-47` already constructs the CryptoKit public key. The real gap is that CryptoKit accepts a low-order point at construction and throws only at agreement. Task 1's rationale states the corrected version; the gap analysis should be amended when this lands.
- **Type consistency:** `Identity.isUsableX25519PublicKey(_:)` is introduced in Task 2 and back-applied to Task 1's guard, so Task 2 must land after Task 1 — or Task 1 should introduce the helper and Task 2 merely use it. Prefer the latter if the implementer finds it cleaner; either way there must be exactly one implementation.
- **Out of scope, deliberately:** §2.3 admission control (`accepts_links`, `resource_strategy`, `max_request_size`, path-request rate limiting). That is API design — new policy types and delegate hooks — not a bug fix, and the crash paths above should not wait on it. It remains the single largest remaining exposure: without it, any peer can still open unlimited links and push unlimited concurrent resources. Track as the immediate follow-up.
- **Also out of scope:** the `Identity.sign` `preconditionFailure` on a public-only identity (`Identity.swift:126-132`). All four in-repo call sites are guarded, so it is unreachable today, and making it non-trapping is an API change to a total function. Worth doing with §2.3.
