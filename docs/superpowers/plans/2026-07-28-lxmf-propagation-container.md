# LXMF-4d-1: Propagation Container + `transient_id` Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A pure, byte-cross-validated `LXMFPropagation` namespace for the propagation-node container format `msgpack([timestamp, [lxmf_data…]])` and `transient_id = full_hash(lxmf_data)`.

**Architecture:** New zero-dep pure type `Sources/ReTiCA/LXMF/LXMFPropagation.swift` (depends only on `Crypto.fullHash`, `MsgPack`, `LXMessage.destinationLength`). Cross-validated against a genuine `lxmf 1.1.0` `PROPAGATED` message via a new isolated fixture (no churn to `lxmf_fixtures.json`). The destination encryption of the entry tail is out of scope (deferred to 4d-2/4d-4); the encrypted tail is opaque bytes.

**Tech Stack:** Swift, SwiftPM, swift-testing (`@Test`). Cross-validation from genuine LXMF in the conda `rns` env.

## Global Constraints

- Commit directly to `main`; no feature branch, no finishing-a-development-branch merge dance.
- No compound shell commands: no `|` chains, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, or inlining scripts into interpreters. One command per Bash call. A single `>` redirect is allowed (fixture generation). Never use echo/printf/heredoc to WRITE source files (use Write/Edit).
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- Cross-val fixtures must drive genuine LXMF (never hand-rolled/circular). New ISOLATED fixture — do NOT touch `lxmf_fixtures.json`. Reference env: `/Users/ell/opt/anaconda3/envs/rns/bin/python` (rns 1.4.2 / lxmf 1.1.0).
- Destination encryption is hedged/ephemeral → the encrypted blob and any artifact containing it are never byte-compared; only the deterministic container structure + `transient_id` are pinned.
- Commit trailers (exact); the `;` means author the message with the Write tool to `/tmp/ReTiCA/` and `git commit -F`, never `-m`:
  - `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`
  - `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`

---

### Task 1: `LXMFPropagation` pure type + cross-validation

**Files:**
- Create: `Sources/ReTiCA/LXMF/LXMFPropagation.swift`
- Create: `Tests/ReTiCATests/Vectors/generate_lxmf_propagation_fixtures.py`
- Create (generated): `Tests/ReTiCATests/Vectors/lxmf_propagation_fixtures.json`
- Create: `Tests/ReTiCATests/Vectors/LXMFPropagationFixtures.swift`
- Create: `Tests/ReTiCATests/Vectors/LXMFPropagationCrossValidationTests.swift`
- Modify: `Package.swift:35` (add the new fixture to the `ReTiCATests` resources)

**Interfaces:**
- Consumes (existing): `Crypto.fullHash(_ data: Data) -> Data`; `MsgPack.encode(_ value: MsgPackValue) -> Data`, `MsgPack.decodeValue(_ data: Data) -> MsgPackValue?`, `MsgPackValue` cases `.array([MsgPackValue])`, `.double(Double)`, `.bin(Data)`; `LXMessage.destinationLength` (== 16); `Data(hexString:)`.
- Produces: `LXMFPropagation.transientId(lxmfData:) -> Data`, `.destinationHash(lxmfData:) -> Data?`, `.lxmfData(destinationHash:encryptedData:) -> Data`, `.container(timestamp:entries:) -> Data`, `.parseContainer(_:) -> (timestamp: Double, entries: [Data])?`.

- [ ] **Step 1: Write the fixture generator**

Create `Tests/ReTiCATests/Vectors/generate_lxmf_propagation_fixtures.py`:

```python
#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_propagation_fixtures.py > lxmf_propagation_fixtures.json
#
# Emits a genuine lxmf 1.1.0 PROPAGATED LXMessage's propagation container so LXMFPropagation can be
# cross-validated. The container timestamp is pinned via a fixed time.time so propagation_packed is
# reproducible. NO propagation stamp (LXMF-5 concern), so the container entry equals the transient_id
# preimage. The destination-encrypted tail inside lxmf_data is hedged/ephemeral (not byte-reproducible),
# so only the deterministic container structure + transient_id (full_hash of the given bytes) are pinned.
import json
import time
import RNS
import LXMF

# Destination construction registers with Transport, which needs a running instance; no-op it.
RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)
time.time = lambda: 1700000000.5      # pin the container timestamp (LXMessage.pack uses time.time())

src_id = RNS.Identity()
dst_id = RNS.Identity()
src = RNS.Destination(src_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(dst_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")

title = b"greeting"
content = b"hello propagation"
msg = LXMF.LXMessage(dst, src, content=content, title=title, desired_method=LXMF.LXMessage.PROPAGATED)
msg.timestamp = 1700000000.5
msg.pack()

print(json.dumps({
    "source_private_key": src_id.get_private_key().hex(),
    "recipient_private_key": dst_id.get_private_key().hex(),
    "destination_hash": dst.hash.hex(),          # recipient lxmf.delivery destination hash
    "title": title.hex(),
    "content": content.hex(),
    "container_timestamp": 1700000000.5,
    "transient_id": msg.transient_id.hex(),
    "propagation_packed": msg.propagation_packed.hex(),
}, indent=2))
```

- [ ] **Step 2: Generate the fixture**

Run (single command, one redirect):

```bash
/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/generate_lxmf_propagation_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATests/Vectors/lxmf_propagation_fixtures.json
```

Expected: a JSON file with `transient_id`, `propagation_packed`, `destination_hash`, and `container_timestamp: 1700000000.5`. (If the run errors, capture the message — a genuine-LXMF failure must be fixed in the generator, never worked around by hand-writing the JSON.)

- [ ] **Step 3: Register the fixture as a test resource**

In `Package.swift`, line 35, change:

```swift
            resources: [.process("Vectors/fixtures.json"), .process("Vectors/lxmf_fixtures.json")]
```

to:

```swift
            resources: [.process("Vectors/fixtures.json"), .process("Vectors/lxmf_fixtures.json"), .process("Vectors/lxmf_propagation_fixtures.json")]
```

- [ ] **Step 4: Write the fixtures decoder**

Create `Tests/ReTiCATests/Vectors/LXMFPropagationFixtures.swift`:

```swift
import Foundation

struct LXMFPropagationFixtures: Decodable {
    let sourcePrivateKey: String
    let recipientPrivateKey: String
    let destinationHash: String
    let title: String
    let content: String
    let containerTimestamp: Double
    let transientId: String
    let propagationPacked: String

    enum CodingKeys: String, CodingKey {
        case sourcePrivateKey = "source_private_key"
        case recipientPrivateKey = "recipient_private_key"
        case destinationHash = "destination_hash"
        case title, content
        case containerTimestamp = "container_timestamp"
        case transientId = "transient_id"
        case propagationPacked = "propagation_packed"
    }

    static func load() throws -> LXMFPropagationFixtures {
        let url = Bundle.module.url(forResource: "lxmf_propagation_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(LXMFPropagationFixtures.self, from: Data(contentsOf: url))
    }
}
```

- [ ] **Step 5: Write the failing cross-val test**

Create `Tests/ReTiCATests/Vectors/LXMFPropagationCrossValidationTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCA

/// Our LXMFPropagation reproduces genuine lxmf 1.1.0's DETERMINISTIC propagation-container wire bytes:
/// transient_id = full_hash(lxmf_data), and the msgpack([timestamp, [lxmf_data]]) container. The
/// destination-encrypted tail inside lxmf_data is hedged/ephemeral, so it is opaque reference input —
/// never byte-produced or byte-compared here.
@Test func propagationContainerMatchesReferenceLXMF() throws {
    let f = try LXMFPropagationFixtures.load()
    let refPacked = Data(hexString: f.propagationPacked)!

    // 1. Parse the genuine container.
    let parsed = LXMFPropagation.parseContainer(refPacked)
    #expect(parsed != nil)
    #expect(parsed?.timestamp == f.containerTimestamp)
    #expect(parsed?.entries.count == 1)
    let lxmfData = parsed!.entries[0]

    // 2. transient_id byte-parity (full_hash of the given lxmf_data).
    #expect(LXMFPropagation.transientId(lxmfData: lxmfData) == Data(hexString: f.transientId)!)

    // 3. destination hash split byte-parity.
    #expect(LXMFPropagation.destinationHash(lxmfData: lxmfData) == Data(hexString: f.destinationHash)!)

    // 4. Our container re-encode of the same values is byte-identical to genuine LXMF's.
    #expect(LXMFPropagation.container(timestamp: parsed!.timestamp, entries: [lxmfData]) == refPacked)

    // 5. The assemble helper reconstructs the exact entry from its destHash + encrypted tail.
    let destHash = Data(lxmfData.prefix(LXMessage.destinationLength))
    let encrypted = Data(lxmfData.dropFirst(LXMessage.destinationLength))
    let reassembled = LXMFPropagation.lxmfData(destinationHash: destHash, encryptedData: encrypted)
    #expect(reassembled == lxmfData)
    #expect(LXMFPropagation.transientId(lxmfData: reassembled) == Data(hexString: f.transientId)!)
}
```

- [ ] **Step 6: Run it — verify it fails**

Run: `swift test --filter LXMFPropagationCrossValidationTests`
Expected: BUILD FAILURE — `LXMFPropagation` does not exist yet. This is the expected red.

- [ ] **Step 7: Implement `LXMFPropagation`**

Create `Sources/ReTiCA/LXMF/LXMFPropagation.swift`:

```swift
import Foundation

/// LXMF propagation container + transient id (LXMF-4d-1). Pure wire helpers for the store-and-forward
/// format a propagation node stores and serves: `msgpack([timestamp, [lxmf_data…]])`, where each
/// `lxmf_data = destinationHash(16) ‖ destination-encrypted(sourceHash‖signature‖payload)` and
/// `transient_id = full_hash(lxmf_data)` (RNS Identity.full_hash; the propagation dedup/identity key,
/// distinct from LXMessage.hash). The destination encryption of the tail is NOT performed here — it
/// lives at the Transport/Endpoint boundary (as with opportunistic delivery); this namespace treats
/// the encrypted tail as opaque bytes. Mirrors lxmf 1.1.0 LXMessage.pack() PROPAGATED (LXMessage.py:429-436).
public enum LXMFPropagation {
    /// Propagation identity / dedup key: SHA-256 of a full lxmf_data entry.
    public static func transientId(lxmfData: Data) -> Data {
        Crypto.fullHash(lxmfData)
    }

    /// The recipient's lxmf.delivery destination hash — the leading 16 bytes of an entry (nil if short).
    public static func destinationHash(lxmfData: Data) -> Data? {
        guard lxmfData.count >= LXMessage.destinationLength else { return nil }
        return Data(lxmfData.prefix(LXMessage.destinationLength))
    }

    /// Assemble one entry from a destination hash and the recipient-encrypted tail.
    public static func lxmfData(destinationHash: Data, encryptedData: Data) -> Data {
        destinationHash + encryptedData
    }

    /// Pack the propagation-node container: msgpack([timestamp, [entries…]]).
    public static func container(timestamp: Double, entries: [Data]) -> Data {
        MsgPack.encode(.array([.double(timestamp), .array(entries.map { .bin($0) })]))
    }

    /// Parse a propagation-node container back into its timestamp and entries; nil if malformed.
    public static func parseContainer(_ data: Data) -> (timestamp: Double, entries: [Data])? {
        guard case let .array(top)? = MsgPack.decodeValue(data), top.count == 2,
              case let .double(ts) = top[0],
              case let .array(items) = top[1] else { return nil }
        var entries: [Data] = []
        for item in items {
            guard case let .bin(d) = item else { return nil }
            entries.append(d)
        }
        return (ts, entries)
    }
}
```

- [ ] **Step 8: Run it — verify it passes**

Run: `swift test --filter LXMFPropagationCrossValidationTests`
Expected: PASS.

- [ ] **Step 9: Mutation verification**

Apply each mutation individually in `Sources/ReTiCA/LXMF/LXMFPropagation.swift`, run `swift test --filter LXMFPropagationCrossValidationTests`, confirm FAIL, revert, confirm PASS, then the next.

1. **Wrong transient id** — in `transientId`, return `Crypto.fullHash(lxmfData + Data([0x00]))` (hash of altered bytes).
   → assertions 2 and 5 FAIL (transient_id mismatch).
2. **Wrong destination split** — in `destinationHash`, return `Data(lxmfData.prefix(LXMessage.destinationLength - 1))` (15 bytes).
   → assertion 3 FAILS (destination hash mismatch).
3. **Wrong container shape** — in `container`, drop the timestamp: `MsgPack.encode(.array([.array(entries.map { .bin($0) })]))`.
   → assertion 4 FAILS (re-encode ≠ reference bytes).

After each: revert, re-run, expect PASS before the next.

- [ ] **Step 10: Full test gate**

Run: `swift test`
Expected: PASS. The 4c-3b baseline was 429 passed / 1 pre-existing live-node skip / 0 fail; this slice adds 1 cross-val test → 430 passed. On a signal-11/signal-10 build flake, run `swift package clean` (single command) and re-run.

- [ ] **Step 11: Commit**

Write the message to `/tmp/ReTiCA/commit-msg-4d1.txt` with the Write tool (body below), then:

```bash
git add Sources/ReTiCA/LXMF/LXMFPropagation.swift Tests/ReTiCATests/Vectors/generate_lxmf_propagation_fixtures.py Tests/ReTiCATests/Vectors/lxmf_propagation_fixtures.json Tests/ReTiCATests/Vectors/LXMFPropagationFixtures.swift Tests/ReTiCATests/Vectors/LXMFPropagationCrossValidationTests.swift Package.swift
```

```bash
git commit -F /tmp/ReTiCA/commit-msg-4d1.txt
```

Commit message body:

```
feat: LXMF-4d-1 — propagation container + transient_id

Pure LXMFPropagation namespace (zero-dep) for the propagation-node
store-and-forward format: container = msgpack([timestamp, [lxmf_data…]]),
transient_id = full_hash(lxmf_data), destHash split, and entry assembly.
The destination-encrypted tail is opaque (encryption deferred to the
transport boundary in 4d-2/4d-4). Byte-cross-validated vs genuine lxmf
1.1.0 PROPAGATED (container re-encode + transient_id + destHash) with a
new isolated fixture; encrypted tail not byte-compared (hedged).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Self-Review

**Spec coverage:**
- Spec "In scope" API (`transientId`, `destinationHash`, `lxmfData`, `container`, `parseContainer`) → Task 1 Step 7. ✓
- Spec "encryption out of scope / opaque tail" → the type never encrypts; the test treats the tail as opaque reference input. ✓
- Spec cross-val (generator + isolated fixture + 5 assertions) → Steps 1-5 (+ Package.swift resource, Step 3). ✓
- Spec "no churn to lxmf_fixtures.json" → new isolated fixture only; `lxmf_fixtures.json` untouched. ✓
- Spec "encrypted blob not byte-compared" → test uses reference `lxmf_data` as opaque input; only container/transient_id/destHash pinned. ✓

**Placeholder scan:** none — every code step shows exact code.

**Type consistency:** `LXMFPropagation.transientId/destinationHash/lxmfData/container/parseContainer` signatures are identical between the production type (Step 7) and the test (Step 5). `parseContainer` returns `(timestamp: Double, entries: [Data])?`, matching the test's `parsed?.timestamp`/`parsed!.entries` usage. Fixture JSON keys (`transient_id`, `propagation_packed`, `destination_hash`, `container_timestamp`) match the generator's emitted keys and the decoder's `CodingKeys`.
