# Resource Compression (bzip2) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Auto-compress resource payloads with bzip2 (matching Python-RNS 1.3.8, byte-for-byte), bidirectionally — compress on send when it shrinks the payload, decompress on receive.

**Architecture:** Vendor the reference libbzip2 as a new C SPM target (`Cbzip2`); a thin `Bzip2.swift` wrapper in `ReTiCATransport` calls it. The sender in `ResourceTransfer.init` compresses `data` and sets the advertisement compression bit (`0x02`) when the compressed payload is smaller; the receiver decompresses the assembled payload (using the known `dataSize`) before verifying. Core `ReTiCA` stays zero-dependency and untouched.

**Tech Stack:** Swift 6, SwiftPM C-interop target, The Composable Architecture (~1.26), the existing `Resource`/`ResourceAdvertisement`/`ResourceTransfer` machinery, and cross-validation against genuine Python-RNS 1.3.8 bz2.

## Global Constraints

- **Byte-for-byte wire compat.** Compression uses libbzip2 1.0.8 `BZ2_bzBuffToBuffCompress` with `blockSize100k = 9`, `verbosity = 0`, `workFactor = 0` — **empirically verified byte-identical to Python's `bz2.compress(data, 9)`** (the cross-val test proves it; keep the Ed25519-sign-style interop fallback documented only as a contingency).
- **Wire semantics:** compression happens BEFORE encryption. The resource `hash` and advertisement `dataSize` (`d`) stay over the **original uncompressed** `data`; `transferSize` (`t`) is the encrypted stream size (over the compressed-or-not payload). Compression flag = advertisement bit 1 (`0x02`); only set when `compressed.count < data.count`.
- **Two-layer purity:** all new Swift logic lives in `ReTiCATransport`; the `Cbzip2` C target is a dependency of `ReTiCATransport` only. `Sources/ReTiCA/*` (core) and the wire advertisement model do NOT change.
- **Vendored source provenance:** bzip2 1.0.8, `sha256 = ab5a03176ee106d3f0fa90e381da478ddae405918153cca248e682cd0c4a2269`, from `https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz`. Already downloaded + extracted this session at `/private/tmp/claude-502/-Users-ell-development-ios-pods-ReTiCA/613c1f9f-9b81-49f1-a738-df620593789c/scratchpad/bzip2-1.0.8/`. BSD-style license — retain the `LICENSE` file and per-file headers.
- Build gotcha: signal-11/SIGILL during `swift test` → `swift package clean` then retry (stale cache); never delete State fields to "fix" a crash.
- **Mutation-test discipline** for every new/changed test: run-pass → batch-mutate-fail → revert-pass, before commit.
- **Commit directly to `main`** (no feature branch). **Commit trailers:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/Cbzip2/` (**create**, Task 1) — vendored libbzip2 (7 `.c`, `bzlib_private.h`, `include/bzlib.h`, `include/module.modulemap`, `LICENSE`).
- `Package.swift` (**modify**, Task 1) — add the `Cbzip2` target + make `ReTiCATransport` depend on it.
- `Sources/ReTiCATransport/Bzip2.swift` (**create**, Task 1) — the Swift wrapper.
- `Tests/ReTiCATransportTests/Bzip2Tests.swift` (**create**, Task 1).
- `Sources/ReTiCATransport/ResourceTransfer.swift` (**modify**, Task 2) — sender compress + receiver decompress.
- `Tests/ReTiCATransportTests/ResourceTransferTests.swift` (**modify**, Task 2).
- `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`, `transport_fixtures.json`, `TransportVectorFixtures.swift` + a new cross-val test (**modify/create**, Task 3).
- `README.md` (**modify**, Task 3).

---

### Task 1: Vendor `Cbzip2` + `Bzip2.swift` wrapper

**Files:**
- Create: `Sources/Cbzip2/**` (vendored source + module map + LICENSE)
- Modify: `Package.swift`
- Create: `Sources/ReTiCATransport/Bzip2.swift`
- Test: `Tests/ReTiCATransportTests/Bzip2Tests.swift`

**Interfaces:**
- Consumes: the vendored `BZ2_bzBuffToBuffCompress` / `BZ2_bzBuffToBuffDecompress` (C, via the `Cbzip2` module).
- Produces: `enum Bzip2 { static func compress(_ data: Data) -> Data?; static func decompress(_ data: Data, expectedSize: Int) -> Data? }`.

- [ ] **Step 1: Vendor the library source**

Create `Sources/Cbzip2/` and copy exactly these 9 library files + LICENSE from the pre-extracted source (the CLI tools `bzip2.c`, `bzip2recover.c`, `dlltest.c`, `mk251.c`, `spewG.c`, `unzcrash.c` are NOT included):

```
cp /private/tmp/claude-502/-Users-ell-development-ios-pods-ReTiCA/613c1f9f-9b81-49f1-a738-df620593789c/scratchpad/bzip2-1.0.8/blocksort.c   Sources/Cbzip2/
cp .../bzip2-1.0.8/bzlib.c        Sources/Cbzip2/
cp .../bzip2-1.0.8/compress.c     Sources/Cbzip2/
cp .../bzip2-1.0.8/crctable.c     Sources/Cbzip2/
cp .../bzip2-1.0.8/decompress.c   Sources/Cbzip2/
cp .../bzip2-1.0.8/huffman.c      Sources/Cbzip2/
cp .../bzip2-1.0.8/randtable.c    Sources/Cbzip2/
cp .../bzip2-1.0.8/bzlib_private.h Sources/Cbzip2/
cp .../bzip2-1.0.8/LICENSE        Sources/Cbzip2/
```
(Run each `cp` as its own command — no compound shell. If the scratchpad extraction is gone, re-fetch: `curl -sSL -o /tmp/ReTiCA/bzip2.tgz https://sourceware.org/pub/bzip2/bzip2-1.0.8.tar.gz`, verify `shasum -a 256` equals `ab5a0317…4a2269`, `tar -xzf`, then copy.)

Then the public header + module map:

```
mkdir -p Sources/Cbzip2/include
cp .../bzip2-1.0.8/bzlib.h Sources/Cbzip2/include/
```

Create `Sources/Cbzip2/include/module.modulemap`:

```
module Cbzip2 {
    header "bzlib.h"
    export *
}
```

> Header-resolution note: the `.c` files do `#include "bzlib.h"` and `#include "bzlib_private.h"`; `bzlib_private.h` does `#include "bzlib.h"`. SwiftPM puts `include/` on the target's header search path, so `bzlib.h` (in `include/`) and `bzlib_private.h` (in the target root) both resolve. If the C compile can't find a header, add `cSettings: [.headerSearchPath("include")]` to the `Cbzip2` target. If it fails on warnings-as-errors (it should not — the source compiles cleanly under clang), add `cSettings: [.unsafeFlags(["-w"])]`.

- [ ] **Step 2: Add the `Cbzip2` target to `Package.swift`**

In `Package.swift`, add a target (after the `ReTiCA` target at line 23):

```swift
        .target(name: "Cbzip2"),
```

And add `"Cbzip2"` to the `ReTiCATransport` target's `dependencies` array (currently `["ReTiCA", .product(name: "ComposableArchitecture", ...)]`):

```swift
        .target(
            name: "ReTiCATransport",
            dependencies: [
                "ReTiCA",
                "Cbzip2",
                .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
            ]
        ),
```

- [ ] **Step 3: Write the wrapper failing tests**

Create `Tests/ReTiCATransportTests/Bzip2Tests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCATransport

@Suite struct Bzip2Tests {
    @Test func roundTripsCompressibleText() throws {
        let data = Data(String(repeating: "reticulum resource payload ", count: 20).utf8)
        let c = try #require(Bzip2.compress(data))
        #expect(c.count < data.count)                       // genuinely compressed
        #expect(Bzip2.decompress(c, expectedSize: data.count) == data)
    }

    @Test func roundTripsRandomData() throws {
        // Incompressible: bz2 output is >= input, but decompress must still recover it exactly.
        let data = Data((0..<256).map { UInt8(($0 * 37 + 11) & 0xff) })
        let c = try #require(Bzip2.compress(data))
        #expect(Bzip2.decompress(c, expectedSize: data.count) == data)
    }

    @Test func roundTripsEmpty() throws {
        let c = try #require(Bzip2.compress(Data()))
        #expect(Bzip2.decompress(c, expectedSize: 0) == Data())
    }

    @Test func decompressRejectsGarbage() {
        #expect(Bzip2.decompress(Data([0x00, 0x01, 0x02, 0x03]), expectedSize: 10) == nil)
    }
}
```

Run: `swift test --filter Bzip2Tests` → FAIL (no `Bzip2`).

- [ ] **Step 4: Write the wrapper**

Create `Sources/ReTiCATransport/Bzip2.swift`:

```swift
import Foundation
import Cbzip2

/// Thin wrapper over the vendored reference libbzip2 (one-shot buffer APIs). Compression parameters
/// (blockSize100k = 9, workFactor = 0) match Python's `bz2.compress(data, 9)` byte-for-byte.
enum Bzip2 {
    static func compress(_ data: Data) -> Data? {
        // libbzip2 documented worst-case output bound: srcLen + srcLen/100 + 600.
        var destLen = UInt32(data.count + data.count / 100 + 600)
        var dest = [UInt8](repeating: 0, count: Int(destLen))
        // BZ2 takes a non-const char* source; give it its own mutable buffer (non-nil even when empty).
        var src = [UInt8](repeating: 0, count: max(data.count, 1))
        data.copyBytes(to: &src, count: data.count)
        let rc = dest.withUnsafeMutableBufferPointer { d -> Int32 in
            src.withUnsafeMutableBufferPointer { s in
                BZ2_bzBuffToBuffCompress(
                    d.baseAddress!.withMemoryRebound(to: CChar.self, capacity: d.count) { $0 }, &destLen,
                    s.baseAddress!.withMemoryRebound(to: CChar.self, capacity: s.count) { $0 },
                    UInt32(data.count), 9, 0, 0)
            }
        }
        guard rc == BZ_OK else { return nil }
        return Data(dest.prefix(Int(destLen)))
    }

    static func decompress(_ data: Data, expectedSize: Int) -> Data? {
        guard !data.isEmpty else { return expectedSize == 0 ? Data() : nil }
        var destLen = UInt32(max(expectedSize, 1))
        var dest = [UInt8](repeating: 0, count: Int(destLen))
        var src = [UInt8](repeating: 0, count: data.count)
        data.copyBytes(to: &src, count: data.count)
        let rc = dest.withUnsafeMutableBufferPointer { d -> Int32 in
            src.withUnsafeMutableBufferPointer { s in
                BZ2_bzBuffToBuffDecompress(
                    d.baseAddress!.withMemoryRebound(to: CChar.self, capacity: d.count) { $0 }, &destLen,
                    s.baseAddress!.withMemoryRebound(to: CChar.self, capacity: s.count) { $0 },
                    UInt32(data.count), 0, 0)
            }
        }
        guard rc == BZ_OK else { return nil }
        return Data(dest.prefix(Int(destLen)))
    }
}
```

> The `withMemoryRebound` from `UInt8` to `CChar` is a same-size (1-byte) rebind — valid. If the Swift 6 compiler rejects the inline rebind form, bind via `UnsafeMutableRawPointer(d.baseAddress!).assumingMemoryBound(to: CChar.self)` instead; the REQUIRED behavior is the byte-exact round-trip in the tests. `BZ_OK` comes from the `Cbzip2` module (value 0).

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter Bzip2Tests` → PASS (all 4).

- [ ] **Step 6: Mutation sweep**

Apply each, run `swift test --filter Bzip2Tests`, confirm the named test fails, revert; final green:
- In `compress`, change `9` (blockSize100k) to `0` → `BZ2_bzBuffToBuffCompress` returns an error (0 is invalid) → `compress` returns nil → `roundTripsCompressibleText` fails (`#require` unwrap).
- In `decompress`, change `guard rc == BZ_OK` to `guard rc != BZ_OK` → `roundTripsCompressibleText`/`roundTripsRandomData` fail (nil).
- In `decompress`, `return Data(dest.prefix(Int(destLen)))` → `return Data(dest)` (don't trim to actual length) → `roundTripsCompressibleText` fails (trailing zero padding ≠ original).

- [ ] **Step 7: Commit**

```
git add Package.swift Sources/Cbzip2 Sources/ReTiCATransport/Bzip2.swift Tests/ReTiCATransportTests/Bzip2Tests.swift
git commit -F /tmp/ReTiCA/commit-c1.txt
```
(`/tmp/ReTiCA/commit-c1.txt` first line: `feat: vendor libbzip2 (Cbzip2 target) + Bzip2 compress/decompress wrapper`, blank line, trailers.)

---

### Task 2: Sender compression + receiver decompression in `ResourceTransfer`

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift`
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`

**Interfaces:**
- Consumes: Task 1's `Bzip2`; the existing `Resource.buildStream`/`resourceHash`, `ResourceAdvertisement`, and the receiver-assembly path.
- Produces: a sender that sets the `0x02` flag + ships compressed parts when smaller; a receiver that decompresses when the flag is set.

- [ ] **Step 1: Sender — compress before building the stream**

In `Sources/ReTiCATransport/ResourceTransfer.swift`, in `init(sending:)`, replace the block that builds `stream`/`h`/`advFlags`/`advertisement` (currently lines 61–76) with:

```swift
            // Compress before encryption; use the compressed payload only when it is actually smaller
            // (matches RNS). The resource hash and dataSize stay over the ORIGINAL data.
            let compressed = Bzip2.compress(data)
            let didCompress = (compressed?.count ?? .max) < data.count
            let payload = didCompress ? compressed! : data
            let stream = Resource.buildStream(data: payload, prefix: prefix, sessionKey: sessionKey)
            let chunks = Resource.parts(stream: stream, sdu: sdu)
            let mapHashes = chunks.map { Resource.mapHash(chunk: $0, randomHash: randomHash) }
            let h = Resource.resourceHash(data: data, randomHash: randomHash)
            self.parts = chunks
            self.partMapHashes = mapHashes
            self.resourceHash = h
            self.expectedProof = Resource.expectedProof(data: data, hash: h)
            self.expectedParts = UInt64(chunks.count)
            self.receivedParts = [:]
            let advFlags: UInt8 = 0x01 | (didCompress ? 0x02 : 0) | (requestID != nil ? (isResponse ? 0x10 : 0x08) : 0)
            self.advertisement = ResourceAdvertisement(
                transferSize: UInt64(stream.count), dataSize: UInt64(data.count),
                numberOfParts: UInt64(chunks.count), hash: h, randomHash: randomHash, originalHash: h,
                segmentIndex: 0, totalSegments: 1, requestID: requestID, flags: advFlags,
                hashmap: mapHashes.prefix(Resource.hashmapMaxLen).reduce(Data()) { $0 + $1 })
```

(`resourceHash`, `expectedProof`, and `dataSize` all use the original `data`; only `buildStream` uses `payload`.)

- [ ] **Step 2: Receiver — decompress after assembling**

In the receiver-assembly block (currently lines 359–374), replace:

```swift
                    // all parts in: assemble + verify + prove (cancel the watchdog)
                    let ordered = (0..<Int(state.expectedParts)).compactMap { state.receivedParts[$0] }
                    guard ordered.count == Int(state.expectedParts),
                          let out = Resource.assemble(parts: ordered, sessionKey: state.sessionKey),
                          Resource.verify(data: out, randomHash: state.randomHash, hash: state.resourceHash)
                    else {
                        state.status = .failed
                        return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))
                    }
```

with (decompress the assembled payload when the advertisement's compression flag is set, using the known `dataSize`, BEFORE verifying):

```swift
                    // all parts in: assemble, decompress if flagged, verify + prove (cancel the watchdog)
                    let ordered = (0..<Int(state.expectedParts)).compactMap { state.receivedParts[$0] }
                    guard ordered.count == Int(state.expectedParts),
                          let payload = Resource.assemble(parts: ordered, sessionKey: state.sessionKey)
                    else {
                        state.status = .failed
                        return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))
                    }
                    let out: Data
                    if adv.isCompressed {
                        guard let decompressed = Bzip2.decompress(payload, expectedSize: Int(adv.dataSize))
                        else {
                            state.status = .failed
                            return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))
                        }
                        out = decompressed
                    } else {
                        out = payload
                    }
                    guard Resource.verify(data: out, randomHash: state.randomHash, hash: state.resourceHash)
                    else {
                        state.status = .failed
                        return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))
                    }
```

(`adv` is already bound at the top of this case — `guard ... let adv = state.advertisement` at line 330. The subsequent `state.status = .complete`, `proofData(data: out, ...)`, and `.received(out)` are unchanged and now operate on the decompressed original.)

- [ ] **Step 3: Write the tests**

Append to `Tests/ReTiCATransportTests/ResourceTransferTests.swift` (reuse the file's existing `key`/`linkID`/`prefix`/`r` constants). These build a sender transfer from compressible data, drive its parts through a receiver transfer, and assert the receiver recovers the exact original — plus assert the flag is set (compressible) or clear (incompressible).

```swift
@Test @MainActor func compressibleResourceSetsFlagAndRoundTrips() async {
    let original = Data(String(repeating: "reticulum compresses this well ", count: 30).utf8)
    let sender = ResourceTransfer.State(sending: original, linkID: linkID, sessionKey: key,
        interfaceID: InterfaceID("i"), prefix: prefix, randomHash: r, sdu: 64)
    #expect(sender.advertisement!.isCompressed == true)                       // flag set
    #expect(sender.advertisement!.dataSize == UInt64(original.count))         // dataSize over original
    #expect(sender.advertisement!.transferSize < UInt64(original.count))      // compressed stream is smaller
    // Drive the sender's parts into a receiver and assert exact recovery.
    let recovered = await driveTransferToReceived(sender: sender, key: key)   // see helper note below
    #expect(recovered == original)
}

@Test @MainActor func incompressibleResourceStaysUncompressedAndRoundTrips() async {
    let original = Data((0..<400).map { UInt8(($0 * 37 + 11) & 0xff) })       // random-ish → bz2 not smaller
    let sender = ResourceTransfer.State(sending: original, linkID: linkID, sessionKey: key,
        interfaceID: InterfaceID("i"), prefix: prefix, randomHash: r, sdu: 64)
    #expect(sender.advertisement!.isCompressed == false)                      // flag clear
    let recovered = await driveTransferToReceived(sender: sender, key: key)
    #expect(recovered == original)
}
```

> Implementer note: `driveTransferToReceived(sender:key:)` is whatever the file's existing end-to-end resource test already does to pump a sender's parts into a receiver `ResourceTransfer` and capture the `.received(_)` payload (e.g. `endToEndWindowedTransferWithADroppedPart` / `senderServesAllPartsThenAwaitsProofAndConcludes` are the working references). Reuse that idiom — spawn a receiver from `sender.advertisement`, feed the parts, and read the `.delegate(.received(out))`. If no reusable helper exists, drive it inline in each test mirroring the existing end-to-end test. The REQUIRED assertions (do NOT weaken): compressible → `isCompressed == true`, `transferSize < dataSize`, receiver recovers the exact original; incompressible → `isCompressed == false`, receiver recovers the exact original. Both prove the receiver's decompress path (flagged) and passthrough path (unflagged).

- [ ] **Step 4: Run to verify**

Run: `swift test --filter ResourceTransfer` → PASS (existing + 2 new). Also run `swift test --filter LinkSessionResource` to confirm the plain link-hosted resource path still round-trips (its payloads may now compress — that's fine, the flag + decompress handle it; if any assertion there hard-coded `transferSize == dataSize` or an uncompressed part count, update it to the compressed reality).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter ResourceTransfer`, confirm the named test fails, revert; final green:
- Sender: change `(didCompress ? 0x02 : 0)` to `0` (never set the flag) → `compressibleResourceSetsFlagAndRoundTrips` fails (`isCompressed == false`, and the receiver won't decompress → recovered ≠ original).
- Sender: change `buildStream(data: payload,` to `buildStream(data: data,` (ship uncompressed but still flag it) → `compressibleResourceSetsFlagAndRoundTrips` fails (receiver decompresses raw uncompressed bytes → recovered ≠ original / decompress fails).
- Receiver: change `if adv.isCompressed {` to `if false {` (never decompress) → `compressibleResourceSetsFlagAndRoundTrips` fails (verify fails on still-compressed bytes → `.failed`).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/ResourceTransfer.swift Tests/ReTiCATransportTests/ResourceTransferTests.swift
git commit -F /tmp/ReTiCA/commit-c2.txt
```
(First line: `feat: ResourceTransfer compresses (sets 0x02) + decompresses resources`, blank line, trailers.)

---

### Task 3: Cross-validation vs genuine RNS bz2 + full gate + README

**Files:**
- Modify: `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`, `transport_fixtures.json`, `TransportVectorFixtures.swift`
- Create: `Tests/ReTiCATransportTests/Vectors/CompressionCrossValidationTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1's `Bzip2`.

- [ ] **Step 1: Add a genuine-RNS bz2 fixture**

In `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`, add `import bz2` at the top, and before the final `print(json.dumps({...}))` add:

```python
# --- bz2 compression cross-validation (genuine Python bz2, level 9 = what RNS uses) ---
bz2_original = b"reticulum resource payload for cross validation " * 6
bz2_compressed = bz2.compress(bz2_original, 9)
```

Add these keys to the `json.dumps({...})` dict:

```python
    "bz2_original": bz2_original.hex(),
    "bz2_compressed": bz2_compressed.hex(),
    "bz2_original_len": len(bz2_original),
```

Regenerate (its own command, single redirect):
`/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`

Verify (its own command): `grep -n "bz2_compressed" /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json` → expect one line.

- [ ] **Step 2: Decode the new fields**

In `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`, add the three properties + `CodingKeys`:

```swift
    let bz2Original: String
    let bz2Compressed: String
    let bz2OriginalLen: Int
```
```swift
        case bz2Original = "bz2_original"
        case bz2Compressed = "bz2_compressed"
        case bz2OriginalLen = "bz2_original_len"
```

- [ ] **Step 3: Write the cross-validation test**

Create `Tests/ReTiCATransportTests/Vectors/CompressionCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCATransport

@Test func swiftCompressMatchesPythonBz2ByteForByte() throws {
    let f = try TransportVectorFixtures.load()
    let original = Data(hexString: f.bz2Original)!
    let expected = Data(hexString: f.bz2Compressed)!
    #expect(Bzip2.compress(original) == expected)          // byte-identical to Python bz2.compress(x, 9)
}

@Test func swiftDecompressesGenuineRnsBz2Stream() throws {
    let f = try TransportVectorFixtures.load()
    let compressed = Data(hexString: f.bz2Compressed)!
    let original = Data(hexString: f.bz2Original)!
    #expect(Bzip2.decompress(compressed, expectedSize: f.bz2OriginalLen) == original)
}
```

> `Data(hexString:)` already exists in the test support (used across the other cross-val tests); if the transport test target lacks it, mirror the helper used by `TransportCrossValidationTests`. If `swiftCompressMatchesPythonBz2ByteForByte` ever fails, that is a real finding — investigate the blockSize/workFactor mapping before weakening; only if genuinely non-reproducible fall back to an interop assertion (`Bzip2.decompress(Bzip2.compress(x)!, expectedSize:) == x` plus the decompress-genuine-stream test), documenting why, per the Ed25519-sign precedent. (Byte-identity was verified during planning, so this is expected to pass as-is.)

- [ ] **Step 4: Run the cross-val filter**

Run: `swift test --filter CompressionCrossValidation` → PASS (both).

- [ ] **Step 5: Full-suite gate**

Run: `swift test` → PASS. Report pass/skip counts.

- [ ] **Step 6: Commit (verify fixture captured)**

```
git add Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py Tests/ReTiCATransportTests/Vectors/transport_fixtures.json Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift Tests/ReTiCATransportTests/Vectors/CompressionCrossValidationTests.swift
git commit -F /tmp/ReTiCA/commit-c3a.txt
```
(First line: `test: bz2 compression cross-validation vs genuine RNS (byte-identical)`, blank line, trailers.)

After committing, run `git show HEAD:Tests/ReTiCATransportTests/Vectors/transport_fixtures.json | grep bz2_compressed` (its own command) and confirm the key is in the committed blob; if missing, re-stage + `git commit --amend --no-edit`, re-verify.

- [ ] **Step 7: Mutation sweep (cross-cutting)**

Apply, run the named filter, confirm the failure, revert; final full `swift test` green:
- In `Bzip2.compress`, change `9` to `1` (block size 1) → `swiftCompressMatchesPythonBz2ByteForByte` fails (different stream, e.g. `BZh1…` vs `BZh9…`); run `swift test --filter CompressionCrossValidation`.
Run `swift test` after reverting → green.

- [ ] **Step 8: Update the README**

In `README.md`, replace the "compression … future slice" note (near the resources section, ~line 179 and the "Not Yet Implemented"/footer list) with:

```markdown
Resource payloads are transparently compressed with bzip2 before encryption when it shrinks them: the
sender sets a compression flag in the advertisement and ships the compressed stream, and the receiver
decompresses on assembly (the resource hash stays over the original data). Compression is byte-for-byte
identical to Python-RNS 1.3.8 (a vendored copy of the reference libbzip2). Incompressible payloads are sent
uncompressed automatically.
```

- [ ] **Step 9: Commit**

```
git add README.md
git commit -F /tmp/ReTiCA/commit-c3b.txt
```
(First line: `docs: resource bzip2 compression`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- Vendored `Cbzip2` C target + `Bzip2.swift` wrapper (core stays zero-dep) → Task 1. ✓
- Sender compression + `0x02` flag when smaller; hash/dataSize over original, transferSize over stream → Task 2 Step 1. ✓
- Receiver decompression (flagged, using dataSize) before verify → Task 2 Step 2. ✓
- Cross-val: byte-identical compress vs Python bz2 + decompress a genuine-RNS stream → Task 3. ✓
- Full gate + README → Task 3. ✓
- Incompressible → uncompressed (flag clear); decompress-failure → transfer fails → Tasks 2–3 tests + receiver guard. ✓
- No core / wire-model change; compression is transport-layer only → Global Constraints, respected. ✓
- Deferred (>1MB multi-segment / RESOURCE_MAX_EFFICIENT_SIZE skip) → untouched. ✓

**Placeholder scan:** No TBD/TODO in production steps. The `driveTransferToReceived` helper note and the `Data(hexString:)` note are explicit implementer guidance (reuse existing per-file idioms) with assertions locked — not missing implementation. The header-resolution / `withMemoryRebound` notes are build contingencies with a concrete fallback each.

**Type consistency:** `Bzip2.compress(_:) -> Data?` / `Bzip2.decompress(_:expectedSize:) -> Data?`, `BZ_OK`, `advFlags = 0x01 | (didCompress ? 0x02 : 0) | (requestID != nil ? …)`, `adv.isCompressed`, `adv.dataSize`, and the unchanged `Resource.buildStream`/`resourceHash`/`verify`/`proofData` calls are used identically across tasks. `transferSize` (stream), `dataSize` (original) usage matches the spec. The `Cbzip2` module name matches the target name in `Package.swift` and the `import Cbzip2` in the wrapper.
