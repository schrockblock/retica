# BLE Interface (CoreBluetooth) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Port the Reticulum fork's BLE transport (RBTP) to Swift in `ReTiCAInterfaces`: pure support logic, a `BLEInterface` TCA reducer, a `BLEDriver` dependency seam, and a live CoreBluetooth driver — RBTP v2 (Apple profile: no BD-address tie-break; both sides initiate; mandatory HELLO token frame + symmetric dedup).

**Architecture:** Three layers matching the repo's TCP interface: pure logic (`BLESupport.swift`), a `@Reducer` holding all policy (`BLEInterface.swift`), and a mechanism-only driver behind a `@Dependency` (`BLEDriver.swift` seam, `CoreBluetoothDriver.swift` live). Spec: `docs/superpowers/specs/2026-08-01-ble-interface-swift-design.md`. Python reference: `/Users/ell/development/python/Reticulum/RNS/Interfaces/util/ble_support.py` and `RNS/Interfaces/BLEInterface.py`.

**Tech Stack:** Swift 6, ComposableArchitecture 1.15+, swift-testing (`@Test`/`#expect`), CoreBluetooth, conda `rns` python for fixtures.

## Global Constraints

- All new source files go in `Sources/ReTiCAInterfaces/`; all tests in `Tests/ReTiCAInterfacesTests/`. The pure `ReTiCA` core target must not change.
- Constants (verbatim, from the spec): service UUID `99872ed7-eba8-4c07-bf35-ab464a957f80`; Version characteristic UUID `50870e44-2fd6-4cbc-9f1f-11a0fcf85265`; PSM characteristic UUID `1cfe213f-4ea4-48f9-9344-dde18cc729ef`; protocol version `2`; max frame payload `1196`; HELLO = `"RBT"` + version byte + 16-byte token (20 bytes); greylist base delay 5 s, max 300 s, strike-forget 600 s, inclusive blocking boundary; churn threshold 10 s; establish timeout 15 s; HELLO timeout 10 s; adapter retry backoff 5 s doubling to 120 s; default max peers 7.
- TestStores use `store.exhaustivity = .off` and assert outcomes/behavior (project preference).
- Run tests with e.g. `swift test --filter BLESupportTests` (one command per Bash invocation — never chain with `&&`, `|`, `;`).
- **Mutation verification is mandatory for every task that adds tests** (user's global instructions): (a) run the new tests, all pass; (b) apply the task's listed mutations to production code in one batch, run, ALL new tests that should fail DO fail; (c) revert mutations, run again, all pass. Only then commit.
- Commit directly to `main` (no feature branch). Write each commit message to a file under `/tmp/ReTiCA/` with the Write tool and commit with `git commit -F <file>`. The message MUST end with these two trailer lines starting at column 0 (no indentation):

```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```

After committing, verify trailers parse: `git log -1 --format='%(trailers:key=Claude-Session)'` must print the line.

---

### Task 1: Framing + HELLO codec (pure logic)

**Files:**
- Create: `Sources/ReTiCAInterfaces/BLESupport.swift`
- Test: `Tests/ReTiCAInterfacesTests/BLESupportTests.swift`

**Interfaces:**
- Consumes: nothing (pure Foundation).
- Produces: `BLEFramingError.invalidLength(Int)`; `BLEFraming.maxFrameLength == 1196`, `BLEFraming.headerLength == 2`, `BLEFraming.frame(_ packet: Data) throws -> Data`; `BLEFrameBuffer(maxFrameLength: Int = 1196)` with `mutating func append(_ data: Data) throws -> [Data]`; `BLEHello.magic == Data("RBT".utf8)`, `BLEHello.tokenLength == 16`, `BLEHello.length == 20`, `BLEHello.pack(version: UInt8, token: Data) -> Data`, `BLEHello.parse(_ frame: Data) -> (version: UInt8, token: Data)?`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCAInterfacesTests/BLESupportTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCAInterfaces

// MARK: - Framing

@Test func frameProducesBigEndianLengthPrefix() throws {
    let packet = Data([0xAA, 0xBB, 0xCC])
    #expect(try BLEFraming.frame(packet) == Data([0x00, 0x03, 0xAA, 0xBB, 0xCC]))
    let big = Data(repeating: 0x42, count: 300)
    #expect(try BLEFraming.frame(big) == Data([0x01, 0x2C]) + big)
}

@Test func frameRejectsEmptyAndOversizedPackets() {
    #expect(throws: BLEFramingError.invalidLength(0)) { try BLEFraming.frame(Data()) }
    #expect(throws: BLEFramingError.invalidLength(1197)) {
        try BLEFraming.frame(Data(repeating: 0, count: 1197))
    }
    // Boundary: exactly 1196 is legal.
    #expect((try? BLEFraming.frame(Data(repeating: 0, count: 1196))) != nil)
}

@Test func frameBufferRecoversMultiplePacketsFromOneAppend() throws {
    var buffer = BLEFrameBuffer()
    let a = Data([0x01]); let b = Data([0x02, 0x03])
    let stream = try BLEFraming.frame(a) + BLEFraming.frame(b)
    #expect(try buffer.append(stream) == [a, b])
}

@Test func frameBufferHandlesSplitDelivery() throws {
    var buffer = BLEFrameBuffer()
    let packet = Data((0..<30).map { UInt8($0) })
    let framed = try BLEFraming.frame(packet)
    // Split mid-header, then mid-payload.
    #expect(try buffer.append(framed.prefix(1)) == [])
    #expect(try buffer.append(framed.dropFirst(1).prefix(10)) == [])
    #expect(try buffer.append(framed.dropFirst(11)) == [packet])
}

@Test func frameBufferThrowsOnZeroLength() {
    var buffer = BLEFrameBuffer()
    #expect(throws: BLEFramingError.invalidLength(0)) {
        _ = try buffer.append(Data([0x00, 0x00, 0xFF]))
    }
}

@Test func frameBufferThrowsOnOversizedLength() {
    var buffer = BLEFrameBuffer()
    // 0x04AD = 1197 > 1196
    #expect(throws: BLEFramingError.invalidLength(1197)) {
        _ = try buffer.append(Data([0x04, 0xAD]))
    }
}

// MARK: - HELLO

@Test func helloPackParseRoundTrip() {
    let token = Data((0..<16).map { UInt8($0 &+ 0x10) })
    let packed = BLEHello.pack(version: 2, token: token)
    #expect(packed.count == BLEHello.length)
    #expect(packed.prefix(3) == Data("RBT".utf8))
    let parsed = BLEHello.parse(packed)
    #expect(parsed?.version == 2)
    #expect(parsed?.token == token)
}

@Test func helloParseRejectsBadInput() {
    let token = Data(repeating: 0xAA, count: 16)
    var wrongMagic = BLEHello.pack(version: 2, token: token)
    wrongMagic[wrongMagic.startIndex] = 0x51
    #expect(BLEHello.parse(wrongMagic) == nil)
    #expect(BLEHello.parse(Data(repeating: 0, count: 19)) == nil)  // short
    #expect(BLEHello.parse(Data(repeating: 0, count: 21)) == nil)  // long
    #expect(BLEHello.parse(Data()) == nil)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BLESupportTests`
Expected: compile FAILURE (`BLEFraming` etc. not defined).

- [ ] **Step 3: Write the implementation**

Create `Sources/ReTiCAInterfaces/BLESupport.swift`:

```swift
import Foundation

/// Pure support logic for the Reticulum BLE transport (RBTP v2, Apple profile).
/// Port of the fork's ble_support.py — no CoreBluetooth, no TCA, testable everywhere.

public enum BLEFramingError: Error, Equatable {
    case invalidLength(Int)
}

/// Wire framing: [len: 2 bytes big-endian][packet], 1 <= len <= 1196.
public enum BLEFraming {
    public static let maxFrameLength = 1196
    public static let headerLength = 2

    public static func frame(_ packet: Data) throws -> Data {
        guard packet.count >= 1, packet.count <= maxFrameLength else {
            throw BLEFramingError.invalidLength(packet.count)
        }
        var out = Data([UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)])
        out.append(packet)
        return out
    }
}

/// Streaming deframer. Accumulates bytes and yields complete packets; throws on a
/// malformed length prefix (no recovery — the caller must drop the connection).
public struct BLEFrameBuffer: Equatable, Sendable {
    public let maxFrameLength: Int
    var buffer: Data

    public init(maxFrameLength: Int = BLEFraming.maxFrameLength) {
        self.maxFrameLength = maxFrameLength
        self.buffer = Data()
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var packets: [Data] = []
        while buffer.count >= BLEFraming.headerLength {
            let b0 = Int(buffer[buffer.startIndex])
            let b1 = Int(buffer[buffer.startIndex + 1])
            let length = (b0 << 8) | b1
            guard length >= 1, length <= maxFrameLength else {
                throw BLEFramingError.invalidLength(length)
            }
            guard buffer.count >= BLEFraming.headerLength + length else { break }
            let start = buffer.startIndex + BLEFraming.headerLength
            packets.append(Data(buffer[start ..< start + length]))
            buffer = Data(buffer[(start + length)...])
        }
        return packets
    }
}

/// The mandatory first frame on every channel: "RBT" + version + 16-byte session token.
public enum BLEHello {
    public static let magic = Data("RBT".utf8)
    public static let tokenLength = 16
    public static let length = 20

    public static func pack(version: UInt8, token: Data) -> Data {
        precondition(token.count == tokenLength, "HELLO token must be \(tokenLength) bytes")
        var out = magic
        out.append(version)
        out.append(token)
        return out
    }

    public static func parse(_ frame: Data) -> (version: UInt8, token: Data)? {
        guard frame.count == length else { return nil }
        let rebased = Data(frame)
        guard rebased.prefix(magic.count) == magic else { return nil }
        return (version: rebased[magic.count], token: Data(rebased.suffix(tokenLength)))
    }
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BLESupportTests`
Expected: all PASS.

- [ ] **Step 5: Mutation verification (batch)**

Apply all three mutations at once to `BLESupport.swift`:
1. In `BLEFraming.frame`, change the length prefix to little-endian: `Data([UInt8(packet.count & 0xFF), UInt8(packet.count >> 8)])`.
2. In `BLEFrameBuffer.append`, change `guard length >= 1` to `guard length >= 0`.
3. In `BLEHello.parse`, delete the `guard rebased.prefix(magic.count) == magic` line.

Run: `swift test --filter BLESupportTests`
Expected: `frameProducesBigEndianLengthPrefix`, `frameBufferThrowsOnZeroLength`, and `helloParseRejectsBadInput` (at least) FAIL. If any of those still pass, the test is broken — fix it and restart from Step 4.

Revert all three mutations. Run: `swift test --filter BLESupportTests` — all PASS again.

- [ ] **Step 6: Commit**

Write the message to `/tmp/ReTiCA/task1-msg.txt` (subject `feat: BLE framing + HELLO codec (RBTP v2 pure support logic)`, trailers per Global Constraints), then:

```bash
git add Sources/ReTiCAInterfaces/BLESupport.swift Tests/ReTiCAInterfacesTests/BLESupportTests.swift
git commit -F /tmp/ReTiCA/task1-msg.txt
```

---

### Task 2: Greylist + duplicate-channel resolution (pure logic)

**Files:**
- Modify: `Sources/ReTiCAInterfaces/BLESupport.swift` (append to end)
- Test: `Tests/ReTiCAInterfacesTests/BLESupportTests.swift` (append)

**Interfaces:**
- Consumes: nothing new.
- Produces: `BLEPeerGreylist<Key: Hashable & Sendable>` with `init(baseDelay: TimeInterval = 5, maxDelay: TimeInterval = 300, strikeForget: TimeInterval = 600)`, `mutating func recordFailure(_ peer: Key, now: Date)`, `func isBlocked(_ peer: Key, now: Date) -> Bool`, `mutating func clear(_ peer: Key)`; `BLEChannelDirection` (`.outbound`/`.inbound`); `BLEDuplicateResolution` (`.keepExisting`/`.keepNew`); `bleTokenIsLower(_ a: Data, _ b: Data) -> Bool`; `bleResolveDuplicate(localToken:peerToken:existingDirection:newDirection:) -> BLEDuplicateResolution`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCAInterfacesTests/BLESupportTests.swift`:

```swift
// MARK: - Greylist

@Test func greylistBackoffGrowsExponentiallyAndIsInclusive() {
    var greylist = BLEPeerGreylist<String>()
    let t0 = Date(timeIntervalSince1970: 0)
    greylist.recordFailure("peer", now: t0)
    // Strike 1: 5 s delay; boundary is inclusive.
    #expect(greylist.isBlocked("peer", now: t0.addingTimeInterval(5.0)))
    #expect(!greylist.isBlocked("peer", now: t0.addingTimeInterval(5.01)))
    // Strike 2 at t=10: 10 s delay -> blocked through t=20.
    greylist.recordFailure("peer", now: t0.addingTimeInterval(10))
    #expect(greylist.isBlocked("peer", now: t0.addingTimeInterval(20.0)))
    #expect(!greylist.isBlocked("peer", now: t0.addingTimeInterval(20.01)))
}

@Test func greylistCapsAtMaxDelay() {
    var greylist = BLEPeerGreylist<String>()
    var t = Date(timeIntervalSince1970: 0)
    for _ in 0..<8 {  // strikes 1..8; 5*2^7 = 640 would exceed the 300 s cap
        greylist.recordFailure("peer", now: t)
        t = t.addingTimeInterval(10)
    }
    let last = t.addingTimeInterval(-10)  // time of the 8th strike
    #expect(greylist.isBlocked("peer", now: last.addingTimeInterval(300)))
    #expect(!greylist.isBlocked("peer", now: last.addingTimeInterval(300.01)))
}

@Test func greylistForgetsStrikesAfterQuietPeriod() {
    var greylist = BLEPeerGreylist<String>()
    let t0 = Date(timeIntervalSince1970: 0)
    greylist.recordFailure("peer", now: t0)
    greylist.recordFailure("peer", now: t0.addingTimeInterval(10))  // strike 2
    // 601 s after the last failure: strikes reset, next failure is strike 1 (5 s).
    let late = t0.addingTimeInterval(10 + 601)
    greylist.recordFailure("peer", now: late)
    #expect(greylist.isBlocked("peer", now: late.addingTimeInterval(5.0)))
    #expect(!greylist.isBlocked("peer", now: late.addingTimeInterval(5.01)))
}

@Test func greylistUnknownPeerIsNotBlockedAndClearWorks() {
    var greylist = BLEPeerGreylist<String>()
    let t0 = Date(timeIntervalSince1970: 0)
    #expect(!greylist.isBlocked("stranger", now: t0))
    greylist.recordFailure("peer", now: t0)
    greylist.clear("peer")
    #expect(!greylist.isBlocked("peer", now: t0))
}

// MARK: - Duplicate resolution

@Test func tokenComparisonIsUnsignedLexicographic() {
    #expect(bleTokenIsLower(Data([0x01, 0xFF]), Data([0x02, 0x00])))
    #expect(!bleTokenIsLower(Data([0x80]), Data([0x7F])))  // unsigned, not signed
    #expect(!bleTokenIsLower(Data([0x01]), Data([0x01])))  // equal is not lower
}

@Test func crossConnectBothEndpointsKeepTheLowerInitiatorsChannel() {
    let low = Data(repeating: 0x01, count: 16)
    let high = Data(repeating: 0x02, count: 16)
    // Endpoint LOW: its outbound channel exists, HIGH's inbound arrives second.
    #expect(bleResolveDuplicate(localToken: low, peerToken: high,
                                existingDirection: .outbound, newDirection: .inbound) == .keepExisting)
    // Endpoint HIGH: its outbound channel exists, LOW's inbound arrives second.
    #expect(bleResolveDuplicate(localToken: high, peerToken: low,
                                existingDirection: .outbound, newDirection: .inbound) == .keepNew)
    // Arrival order flipped on both endpoints — conclusions must still agree (keep LOW's channel).
    #expect(bleResolveDuplicate(localToken: low, peerToken: high,
                                existingDirection: .inbound, newDirection: .outbound) == .keepNew)
    #expect(bleResolveDuplicate(localToken: high, peerToken: low,
                                existingDirection: .inbound, newDirection: .outbound) == .keepExisting)
}

@Test func sameDirectionDuplicateIsAReconnectKeepNew() {
    let a = Data(repeating: 0x01, count: 16)
    let b = Data(repeating: 0x02, count: 16)
    #expect(bleResolveDuplicate(localToken: a, peerToken: b,
                                existingDirection: .outbound, newDirection: .outbound) == .keepNew)
    #expect(bleResolveDuplicate(localToken: a, peerToken: b,
                                existingDirection: .inbound, newDirection: .inbound) == .keepNew)
}
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `swift test --filter BLESupportTests`
Expected: compile FAILURE (`BLEPeerGreylist` not defined).

- [ ] **Step 3: Write the implementation**

Append to `Sources/ReTiCAInterfaces/BLESupport.swift`:

```swift
/// Per-peer reconnection rate limiter with exponential backoff. Port of
/// ble_support.PeerGreylist: delay = min(base * 2^(strikes-1), max); strikes are
/// forgotten when more than strikeForget elapses since the last failure; the
/// blocking boundary is INCLUSIVE (blocked while now <= unblock time).
public struct BLEPeerGreylist<Key: Hashable & Sendable>: Equatable, Sendable {
    struct Entry: Equatable, Sendable {
        var strikes: Int
        var lastFailure: Date
        var blockedUntil: Date
    }

    public let baseDelay: TimeInterval
    public let maxDelay: TimeInterval
    public let strikeForget: TimeInterval
    var entries: [Key: Entry] = [:]

    public init(baseDelay: TimeInterval = 5, maxDelay: TimeInterval = 300,
                strikeForget: TimeInterval = 600) {
        self.baseDelay = baseDelay
        self.maxDelay = maxDelay
        self.strikeForget = strikeForget
    }

    public mutating func recordFailure(_ peer: Key, now: Date) {
        var strikes = 0
        if let entry = entries[peer], now.timeIntervalSince(entry.lastFailure) <= strikeForget {
            strikes = entry.strikes
        }
        strikes += 1
        let delay = min(baseDelay * pow(2, Double(strikes - 1)), maxDelay)
        entries[peer] = Entry(strikes: strikes, lastFailure: now,
                              blockedUntil: now.addingTimeInterval(delay))
    }

    public func isBlocked(_ peer: Key, now: Date) -> Bool {
        guard let entry = entries[peer] else { return false }
        return now <= entry.blockedUntil
    }

    public mutating func clear(_ peer: Key) {
        entries[peer] = nil
    }
}

public enum BLEChannelDirection: Equatable, Sendable {
    case outbound, inbound
}

public enum BLEDuplicateResolution: Equatable, Sendable {
    case keepExisting, keepNew
}

/// Unsigned byte-wise lexicographic comparison.
public func bleTokenIsLower(_ a: Data, _ b: Data) -> Bool {
    for (x, y) in zip(a, b) where x != y { return x < y }
    return a.count < b.count
}

/// Symmetric duplicate-channel resolution. Same direction = reconnect (new wins).
/// Opposite directions = simultaneous cross-connect: the channel initiated by the
/// owner of the LOWER token survives; both endpoints reach complementary
/// conclusions from their own (localToken, direction) view.
public func bleResolveDuplicate(
    localToken: Data, peerToken: Data,
    existingDirection: BLEChannelDirection, newDirection: BLEChannelDirection
) -> BLEDuplicateResolution {
    guard existingDirection != newDirection else { return .keepNew }
    let localInitiatorWins = bleTokenIsLower(localToken, peerToken)
    let existingInitiatedLocally = existingDirection == .outbound
    return existingInitiatedLocally == localInitiatorWins ? .keepExisting : .keepNew
}
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BLESupportTests`
Expected: all PASS.

- [ ] **Step 5: Mutation verification (batch)**

Apply all three mutations at once:
1. In `recordFailure`, change `now.timeIntervalSince(entry.lastFailure) <= strikeForget` to `< 0` (always reset strikes).
2. In `isBlocked`, change `now <= entry.blockedUntil` to `now < entry.blockedUntil` (exclusive boundary).
3. In `bleResolveDuplicate`, swap the final ternary arms (`.keepNew : .keepExisting`).

Run: `swift test --filter BLESupportTests`
Expected: `greylistBackoffGrowsExponentiallyAndIsInclusive` (mutations 1+2) and `crossConnectBothEndpointsKeepTheLowerInitiatorsChannel` (mutation 3) FAIL. If not, fix the tests and restart from Step 4.

Revert all mutations. Run: `swift test --filter BLESupportTests` — all PASS again.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task2-msg.txt` (subject `feat: BLE greylist + duplicate-channel resolution`), then:

```bash
git add Sources/ReTiCAInterfaces/BLESupport.swift Tests/ReTiCAInterfacesTests/BLESupportTests.swift
git commit -F /tmp/ReTiCA/task2-msg.txt
```

---

### Task 3: Cross-validation fixtures vs the genuine Python `ble_support.py`

**Files:**
- Create: `Tests/ReTiCAInterfacesTests/Vectors/generate_ble_fixtures.py`
- Create: `Tests/ReTiCAInterfacesTests/Vectors/ble_fixtures.json` (generated)
- Create: `Tests/ReTiCAInterfacesTests/BLEFixtureTests.swift`
- Modify: `Package.swift` (add `resources` to the `ReTiCAInterfacesTests` test target)

**Interfaces:**
- Consumes: `BLEFraming.frame`, `BLEFrameBuffer`, `BLEPeerGreylist<String>` from Tasks 1–2.
- Produces: nothing used by later tasks (validation only).

- [ ] **Step 1: Write the generator script**

Create `Tests/ReTiCAInterfacesTests/Vectors/generate_ble_fixtures.py`:

```python
#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path (from the Vectors directory):
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_ble_fixtures.py > ble_fixtures.json
#
# Drives the GENUINE fork ble_support.py (imported by file path; the module is
# deliberately dependency-free) so the Swift port is validated against real
# reference code, not a hand-rolled reimplementation.
import importlib.util
import json

BLE_SUPPORT = "/Users/ell/development/python/Reticulum/RNS/Interfaces/util/ble_support.py"
spec = importlib.util.spec_from_file_location("ble_support", BLE_SUPPORT)
ble = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ble)

packets = [
    bytes([0x00]),
    bytes(range(30)),
    bytes((i * 7 + 3) % 256 for i in range(1196)),  # max-length packet
]
framing = [{"packet": p.hex(), "framed": ble.frame(p).hex()} for p in packets]

stream = b"".join(ble.frame(p) for p in packets)
fb = ble.FrameBuffer()
recovered = fb.append(stream)
assert [bytes(r) for r in recovered] == packets, "reference FrameBuffer sanity check"

# Greylist scenario: every probe expectation is the REAL PeerGreylist's answer.
ops = []
g = ble.PeerGreylist()
PEER = "aa:bb:cc:dd:ee:01"

def fail(t):
    g.record_failure(PEER, t)
    ops.append({"op": "fail", "t": t})

def probe(t):
    ops.append({"op": "probe", "t": t, "blocked": g.is_blocked(PEER, t)})

fail(0.0)
probe(4.9); probe(5.0); probe(5.01)          # strike 1: 5 s, inclusive boundary
fail(10.0)
probe(19.9); probe(20.0); probe(20.01)       # strike 2: 10 s
for t in (30.0, 40.0, 50.0, 60.0, 70.0, 80.0):
    fail(t)                                   # strikes 3..8, delay caps at 300 s
probe(380.0); probe(380.01)
fail(1000.0)                                  # 920 s quiet > 600 s: strikes forget
probe(1005.0); probe(1005.01)

print(json.dumps({
    "framing": framing,
    "framing_stream": stream.hex(),
    "greylist_ops": ops,
}, indent=2))
```

- [ ] **Step 2: Generate the fixtures**

From `Tests/ReTiCAInterfacesTests/Vectors/`, run (single command):
`/Users/ell/opt/anaconda3/envs/rns/bin/python generate_ble_fixtures.py > ble_fixtures.json`

(Redirection inside one command is fine; chaining commands is not.) Inspect `ble_fixtures.json`: it must contain 3 framing entries, a `framing_stream` hex string, and ~17 greylist ops.

- [ ] **Step 3: Add the resource to Package.swift**

In `Package.swift`, change the `ReTiCAInterfacesTests` test target to include resources:

```swift
.testTarget(
    name: "ReTiCAInterfacesTests",
    dependencies: [
        "ReTiCAInterfaces",
        .product(name: "ComposableArchitecture", package: "swift-composable-architecture"),
    ],
    resources: [.process("Vectors/ble_fixtures.json")]
),
```

- [ ] **Step 4: Write the failing fixture tests**

Create `Tests/ReTiCAInterfacesTests/BLEFixtureTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCAInterfaces

private struct BLEFixtures: Decodable {
    struct FramingCase: Decodable { let packet: String; let framed: String }
    struct GreylistOp: Decodable { let op: String; let t: Double; let blocked: Bool? }
    let framing: [FramingCase]
    let framingStream: String
    let greylistOps: [GreylistOp]

    enum CodingKeys: String, CodingKey {
        case framing
        case framingStream = "framing_stream"
        case greylistOps = "greylist_ops"
    }

    static func load() throws -> BLEFixtures {
        let url = Bundle.module.url(forResource: "ble_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(BLEFixtures.self, from: Data(contentsOf: url))
    }
}

private func dataFromHex(_ hex: String) -> Data {
    var data = Data(); var index = hex.startIndex
    while index < hex.endIndex {
        let next = hex.index(index, offsetBy: 2)
        data.append(UInt8(hex[index..<next], radix: 16)!)
        index = next
    }
    return data
}

@Test func framingMatchesReferencePythonByteForByte() throws {
    let fixtures = try BLEFixtures.load()
    for c in fixtures.framing {
        #expect(try BLEFraming.frame(dataFromHex(c.packet)) == dataFromHex(c.framed))
    }
    // The concatenated reference stream deframes back to the reference packets.
    var buffer = BLEFrameBuffer()
    let packets = try buffer.append(dataFromHex(fixtures.framingStream))
    #expect(packets == fixtures.framing.map { dataFromHex($0.packet) })
}

@Test func greylistArithmeticMatchesReferencePython() throws {
    let fixtures = try BLEFixtures.load()
    var greylist = BLEPeerGreylist<String>()
    for op in fixtures.greylistOps {
        let now = Date(timeIntervalSince1970: op.t)
        switch op.op {
        case "fail":
            greylist.recordFailure("peer", now: now)
        case "probe":
            #expect(greylist.isBlocked("peer", now: now) == op.blocked!,
                    "probe at t=\(op.t) disagrees with reference")
        default:
            Issue.record("unknown op \(op.op)")
        }
    }
}
```

- [ ] **Step 5: Run tests to verify they pass**

Run: `swift test --filter BLEFixtureTests`
Expected: all PASS. (These tests validate Tasks 1–2 code against the reference — they should pass immediately; the "failing" phase for this task is the mutation check below.)

- [ ] **Step 6: Mutation verification (batch)**

Apply both mutations at once to `BLESupport.swift`:
1. In `BLEFraming.frame`, swap the two length-prefix bytes (little-endian).
2. In `BLEPeerGreylist.recordFailure`, change `min(baseDelay * pow(2, Double(strikes - 1)), maxDelay)` to `baseDelay` (no exponential growth).

Run: `swift test --filter BLEFixtureTests`
Expected: BOTH fixture tests FAIL. If either passes, the fixture isn't exercising that path — fix and restart from Step 5.

Revert both mutations. Run: `swift test --filter BLEFixtureTests` — all PASS. Then run the full interface suite once: `swift test --filter ReTiCAInterfacesTests` — all PASS.

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/task3-msg.txt` (subject `test: BLE cross-validation fixtures vs fork ble_support.py`), then:

```bash
git add Tests/ReTiCAInterfacesTests/Vectors/generate_ble_fixtures.py Tests/ReTiCAInterfacesTests/Vectors/ble_fixtures.json Tests/ReTiCAInterfacesTests/BLEFixtureTests.swift Package.swift
git commit -F /tmp/ReTiCA/task3-msg.txt
```

---

### Task 4: Driver seam + reducer lifecycle skeleton

**Files:**
- Create: `Sources/ReTiCAInterfaces/BLEDriver.swift`
- Create: `Sources/ReTiCAInterfaces/BLEInterface.swift`
- Test: `Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift`

**Interfaces:**
- Consumes: `BLEFrameBuffer`, `BLEPeerGreylist`, `BLEChannelDirection` (Tasks 1–2).
- Produces (used by every later task):
  - `BLEPeerHandle(id: UUID)`, `BLEChannelID(id: UUID)` — `Hashable, Sendable`.
  - `BLEPairingMode` (`.open`/`.paired`), `BLEDriverConfig(version: UInt8, pairingMode: BLEPairingMode)`.
  - `BLEDriverEvent` (all cases below), `BLEDriver` (the dependency, `\.bleDriver`).
  - `\.bleDate` (`DateGenerator`), `\.bleRandomBytes` (`BLERandomBytesGenerator`).
  - `BLEInterface` reducer: `BLEInterfaceStatus` (`.stopped/.starting/.online/.waitingForAdapter`), full `State`/`Action` (later tasks fill in stubbed cases), constants `protocolVersion=2`, `defaultMaxPeers=7`, `establishTimeout=15s`, `helloTimeout=10s`, `churnMinLifetime=10`, `adapterRetryMin=5s`, `adapterRetryMax=120s`.
  - Test helper `makeStore(maxPeers:streams:)` and `MockDriverCall` in `BLEInterfaceTests.swift`.

- [ ] **Step 1: Write `BLEDriver.swift`**

```swift
import Foundation
import Security
import ComposableArchitecture

/// Locally-scoped handle for a remote device (wraps the CBPeer UUID). Pre-HELLO identity —
/// plays the role the bdaddr plays in the Python implementation.
public struct BLEPeerHandle: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

/// Opaque per-channel handle minted by the driver.
public struct BLEChannelID: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

public enum BLEPairingMode: String, Equatable, Sendable {
    case open, paired
}

public struct BLEDriverConfig: Equatable, Sendable {
    public var version: UInt8
    public var pairingMode: BLEPairingMode
    public init(version: UInt8, pairingMode: BLEPairingMode) {
        self.version = version
        self.pairingMode = pairingMode
    }
}

public enum BLEDriverEvent: Equatable, Sendable {
    case ready
    case unavailable(reason: String?)
    case peerDiscovered(BLEPeerHandle)
    case directoryRead(BLEPeerHandle, version: UInt8, psm: UInt16)
    case directoryFailed(BLEPeerHandle, reason: String?)
    case channelOpened(BLEChannelID, BLEPeerHandle, direction: BLEChannelDirection)
    case channelFailed(BLEPeerHandle, reason: String?)
    case channelData(BLEChannelID, Data)
    case channelClosed(BLEChannelID, reason: String?)
}

/// BLE driver dependency. Mechanism only — no policy, no retries, no framing.
/// The live value wraps CoreBluetooth (Task 8); tests inject a mock.
public struct BLEDriver: Sendable {
    public var start: @Sendable (BLEDriverConfig) -> AsyncStream<BLEDriverEvent>
    public var readDirectory: @Sendable (BLEPeerHandle) async -> Void
    public var openChannel: @Sendable (BLEPeerHandle, UInt16) async -> Void
    public var send: @Sendable (BLEChannelID, Data) async -> Void
    public var closeChannel: @Sendable (BLEChannelID) async -> Void
    public var stop: @Sendable () async -> Void

    public init(
        start: @escaping @Sendable (BLEDriverConfig) -> AsyncStream<BLEDriverEvent>,
        readDirectory: @escaping @Sendable (BLEPeerHandle) async -> Void,
        openChannel: @escaping @Sendable (BLEPeerHandle, UInt16) async -> Void,
        send: @escaping @Sendable (BLEChannelID, Data) async -> Void,
        closeChannel: @escaping @Sendable (BLEChannelID) async -> Void,
        stop: @escaping @Sendable () async -> Void
    ) {
        self.start = start
        self.readDirectory = readDirectory
        self.openChannel = openChannel
        self.send = send
        self.closeChannel = closeChannel
        self.stop = stop
    }
}

extension BLEDriver: DependencyKey {
    // Inert stub; Task 8 replaces this with the CoreBluetooth-backed driver.
    public static var liveValue: BLEDriver {
        BLEDriver(start: { _ in .finished }, readDirectory: { _ in },
                  openChannel: { _, _ in }, send: { _, _ in },
                  closeChannel: { _ in }, stop: {})
    }

    public static let testValue = BLEDriver(
        start: unimplemented("BLEDriver.start", placeholder: AsyncStream { $0.finish() }),
        readDirectory: unimplemented("BLEDriver.readDirectory"),
        openChannel: unimplemented("BLEDriver.openChannel"),
        send: unimplemented("BLEDriver.send"),
        closeChannel: unimplemented("BLEDriver.closeChannel"),
        stop: unimplemented("BLEDriver.stop")
    )
}

extension DependencyValues {
    public var bleDriver: BLEDriver {
        get { self[BLEDriver.self] }
        set { self[BLEDriver.self] = newValue }
    }
}

// "now" for greylist arithmetic. \.date's testValue is unimplemented in this TCA
// version, so a custom key (same pattern as Transport's \.transportDate).
private enum BLEDateKey: DependencyKey {
    static let liveValue = DateGenerator { Date() }
    static let testValue = DateGenerator { Date(timeIntervalSince1970: 0) }
    static let previewValue = liveValue
}
extension DependencyValues {
    public var bleDate: DateGenerator {
        get { self[BLEDateKey.self] }
        set { self[BLEDateKey.self] = newValue }
    }
}

/// Session-token generation. Live is CSPRNG-backed; test is a deterministic ramp.
/// (ReTiCAInterfaces cannot see ReTiCATransport's RandomBytesGenerator.)
public struct BLERandomBytesGenerator: Sendable {
    public var generate: @Sendable (Int) -> Data
    public init(generate: @escaping @Sendable (Int) -> Data) { self.generate = generate }
    public func callAsFunction(_ count: Int) -> Data { generate(count) }
}
extension BLERandomBytesGenerator: DependencyKey {
    public static let liveValue = BLERandomBytesGenerator { count in
        var bytes = [UInt8](repeating: 0, count: count)
        _ = bytes.withUnsafeMutableBytes { SecRandomCopyBytes(kSecRandomDefault, count, $0.baseAddress!) }
        return Data(bytes)
    }
    public static let testValue = BLERandomBytesGenerator { count in
        Data((0..<count).map { UInt8($0 & 0xff) })
    }
    public static let previewValue = testValue
}
extension DependencyValues {
    public var bleRandomBytes: BLERandomBytesGenerator {
        get { self[BLERandomBytesGenerator.self] }
        set { self[BLERandomBytesGenerator.self] = newValue }
    }
}
```

- [ ] **Step 2: Write `BLEInterface.swift` (skeleton — full State/Action, lifecycle handlers, stubs elsewhere)**

```swift
import Foundation
import ComposableArchitecture
import ReTiCA

public enum BLEInterfaceStatus: Equatable, Sendable {
    case stopped, starting, online, waitingForAdapter
}

/// The Reticulum BLE interface (RBTP v2, Apple profile). Parent lifecycle + all policy:
/// discovery gating, establishment, HELLO/dedup, data plane, greylist, peer cap,
/// adapter-loss recovery. The driver underneath is mechanism only.
@Reducer
public struct BLEInterface {
    public static let protocolVersion: UInt8 = 2
    public static let defaultMaxPeers = 7
    public static let establishTimeout: Duration = .seconds(15)
    public static let helloTimeout: Duration = .seconds(10)
    public static let churnMinLifetime: TimeInterval = 10
    public static let adapterRetryMin: Duration = .seconds(5)
    public static let adapterRetryMax: Duration = .seconds(120)

    public struct ChannelState: Equatable, Sendable {
        public var peer: BLEPeerHandle
        public var direction: BLEChannelDirection
        var frameBuffer: BLEFrameBuffer
        var peerToken: Data?     // nil until a valid HELLO arrives
        var openedAt: Date
    }

    @ObservableState
    public struct State: Equatable {
        public var status: BLEInterfaceStatus = .stopped
        public var maxPeers: Int
        public var pairingMode: BLEPairingMode
        public internal(set) var sessionToken: Data?
        var channels: [BLEChannelID: ChannelState] = [:]
        var peers: [Data: BLEChannelID] = [:]      // established peers by token
        var pendingPeers: Set<BLEPeerHandle> = []  // establishment in flight
        var greylist = BLEPeerGreylist<BLEPeerHandle>()
        var adapterRetryDelay: Duration = BLEInterface.adapterRetryMin

        public init(maxPeers: Int = BLEInterface.defaultMaxPeers,
                    pairingMode: BLEPairingMode = .open) {
            self.maxPeers = maxPeers
            self.pairingMode = pairingMode
        }
    }

    public enum Action: Equatable {
        case start
        case stop
        case driverEvent(BLEDriverEvent)
        case send(peer: Data, packet: Data)
        case helloDeadline(BLEChannelID)
        case establishDeadline(BLEPeerHandle)
        case adapterRetry
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case peerOnline(Data)
            case peerOffline(Data)
            case packetReceived(peer: Data, packet: Data)
        }
    }

    @Dependency(\.bleDriver) var bleDriver
    @Dependency(\.continuousClock) var clock
    @Dependency(\.bleDate) var date
    @Dependency(\.bleRandomBytes) var randomBytes

    private enum CancelID: Hashable {
        case driver, retry
        case hello(BLEChannelID)
        case establish(BLEPeerHandle)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                guard state.status == .stopped else { return .none }
                state.sessionToken = randomBytes(BLEHello.tokenLength)
                state.status = .starting
                return startDriver(state: &state)

            case .stop:
                let established = Array(state.peers.keys)
                let channelIDs = Array(state.channels.keys)
                let pending = Array(state.pendingPeers)
                state.channels = [:]
                state.peers = [:]
                state.pendingPeers = []
                state.sessionToken = nil
                state.adapterRetryDelay = Self.adapterRetryMin
                state.status = .stopped
                var effects: [Effect<Action>] = [
                    .cancel(id: CancelID.driver),
                    .cancel(id: CancelID.retry),
                ]
                effects += channelIDs.map { .cancel(id: CancelID.hello($0)) }
                effects += pending.map { .cancel(id: CancelID.establish($0)) }
                effects.append(.run { [bleDriver] _ in await bleDriver.stop() })
                effects += established.map { .send(.delegate(.peerOffline($0))) }
                return .merge(effects)

            case .driverEvent(.ready):
                state.status = .online
                state.adapterRetryDelay = Self.adapterRetryMin
                return .none

            // Stubs — implemented in Tasks 5–7.
            case .driverEvent(.unavailable):
                return .none
            case .driverEvent(.peerDiscovered):
                return .none
            case .driverEvent(.directoryRead):
                return .none
            case .driverEvent(.directoryFailed), .driverEvent(.channelFailed):
                return .none
            case .driverEvent(.channelOpened):
                return .none
            case .driverEvent(.channelData):
                return .none
            case .driverEvent(.channelClosed):
                return .none
            case .send:
                return .none
            case .helloDeadline:
                return .none
            case .establishDeadline:
                return .none
            case .adapterRetry:
                return .none

            case .delegate:
                return .none
            }
        }
    }

    /// Subscribes to the driver's event stream (used by .start and, later, .adapterRetry).
    private func startDriver(state: inout State) -> Effect<Action> {
        let config = BLEDriverConfig(version: Self.protocolVersion, pairingMode: state.pairingMode)
        return .run { [bleDriver] send in
            for await event in bleDriver.start(config) {
                await send(.driverEvent(event))
            }
        }
        .cancellable(id: CancelID.driver, cancelInFlight: true)
    }
}
```

- [ ] **Step 3: Write the failing lifecycle tests (plus the shared mock harness)**

Create `Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

enum MockDriverCall: Equatable {
    case start
    case stop
    case readDirectory(BLEPeerHandle)
    case openChannel(BLEPeerHandle, UInt16)
    case send(BLEChannelID, Data)
    case closeChannel(BLEChannelID)
}

// Deterministic fixtures shared by all reducer tests.
let localToken = Data(repeating: 0x11, count: 16)   // what bleRandomBytes yields below
let peerHandleA = BLEPeerHandle(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
let peerHandleB = BLEPeerHandle(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)
let channel1 = BLEChannelID(id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!)
let channel2 = BLEChannelID(id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000002")!)
let tokenLow = Data(repeating: 0x01, count: 16)     // sorts below localToken
let tokenHigh = Data(repeating: 0xEE, count: 16)    // sorts above localToken

func framedHello(token: Data) -> Data {
    try! BLEFraming.frame(BLEHello.pack(version: BLEInterface.protocolVersion, token: token))
}

/// Pre-creates `streams` driver event streams; the mock's start() hands them out in
/// order (yields buffer until consumed, so tests can yield any time after start).
@MainActor
func makeStore(maxPeers: Int = BLEInterface.defaultMaxPeers, streams: Int = 1)
    -> (store: TestStore<BLEInterface.State, BLEInterface.Action>,
        events: [AsyncStream<BLEDriverEvent>.Continuation],
        calls: LockIsolated<[MockDriverCall]>,
        clock: TestClock<Duration>,
        now: LockIsolated<Date>)
{
    let made = (0..<streams).map { _ in AsyncStream<BLEDriverEvent>.makeStream() }
    let startCount = LockIsolated(0)
    let calls = LockIsolated<[MockDriverCall]>([])
    let clock = TestClock()
    let now = LockIsolated(Date(timeIntervalSince1970: 1_000))
    let store = TestStore(initialState: BLEInterface.State(maxPeers: maxPeers)) {
        BLEInterface()
    } withDependencies: {
        $0.bleDriver = BLEDriver(
            start: { _ in
                calls.withValue { $0.append(.start) }
                let n = startCount.withValue { $0 += 1; return $0 }
                return n <= made.count ? made[n - 1].stream : AsyncStream { _ in }
            },
            readDirectory: { h in calls.withValue { $0.append(.readDirectory(h)) } },
            openChannel: { h, psm in calls.withValue { $0.append(.openChannel(h, psm)) } },
            send: { c, d in calls.withValue { $0.append(.send(c, d)) } },
            closeChannel: { c in calls.withValue { $0.append(.closeChannel(c)) } },
            stop: { calls.withValue { $0.append(.stop) } }
        )
        $0.continuousClock = clock
        $0.bleDate = DateGenerator { now.value }
        $0.bleRandomBytes = BLERandomBytesGenerator { count in Data(repeating: 0x11, count: count) }
    }
    store.exhaustivity = .off
    return (store, made.map { $0.continuation }, calls, clock, now)
}

// MARK: - Lifecycle

@Test @MainActor func startGeneratesTokenAndComesOnlineOnReady() async {
    let (store, events, calls, _, _) = makeStore()
    await store.send(.start) {
        $0.status = .starting
        $0.sessionToken = localToken
    }
    #expect(calls.value == [.start])
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func startWhileRunningIsIgnored() async {
    let (store, events, calls, _, _) = makeStore()
    await store.send(.start) { $0.status = .starting }
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    await store.send(.start)  // no state change, no second driver start
    #expect(calls.value.filter { $0 == .start }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func stopCallsDriverStopAndClearsToken() async {
    let (store, events, calls, _, _) = makeStore()
    await store.send(.start) { $0.status = .starting }
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    await store.send(.stop) {
        $0.status = .stopped
        $0.sessionToken = nil
    }
    #expect(calls.value.contains(.stop))
}
```

- [ ] **Step 4: Run tests to verify they fail, then pass**

Run: `swift test --filter BLEInterfaceTests` — first confirm they FAIL before Step 1–2 files exist (if you wrote implementation first, temporarily stub out and confirm; otherwise compile order makes this moot — the mutation step below is the real guard). After implementation: all PASS.

- [ ] **Step 5: Mutation verification (batch)**

Mutations to `BLEInterface.swift`:
1. In `.start`, delete the `state.sessionToken = randomBytes(...)` line.
2. In `.driverEvent(.ready)`, change `state.status = .online` to `.starting`.
3. In `.stop`, delete the `.run { ... await bleDriver.stop() }` effect append.

Run: `swift test --filter BLEInterfaceTests`
Expected: all three tests FAIL (token assertion, online assertion, `.stop` call assertion). Revert; re-run; all PASS.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task4-msg.txt` (subject `feat: BLE driver seam + interface lifecycle skeleton`), then:

```bash
git add Sources/ReTiCAInterfaces/BLEDriver.swift Sources/ReTiCAInterfaces/BLEInterface.swift Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift
git commit -F /tmp/ReTiCA/task4-msg.txt
```

---

### Task 5: Discovery → directory → channel-open pipeline

**Files:**
- Modify: `Sources/ReTiCAInterfaces/BLEInterface.swift` (replace stubs)
- Test: `Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift` (append)

**Interfaces:**
- Consumes: Task 4's reducer + `makeStore`/`MockDriverCall` harness; `BLEPeerGreylist` (Task 2).
- Produces: working handlers for `.driverEvent(.peerDiscovered/.directoryRead/.directoryFailed/.channelFailed)` and `.establishDeadline`. Later tasks rely on `pendingPeers` being cleared and `CancelID.establish` cancelled exactly as coded here.

- [ ] **Step 1: Write the failing tests**

Append to `BLEInterfaceTests.swift`:

```swift
// MARK: - Discovery / establishment

/// Brings a store online and returns it ready for discovery events.
@MainActor
func makeOnlineStore(maxPeers: Int = BLEInterface.defaultMaxPeers, streams: Int = 1)
    async -> (store: TestStore<BLEInterface.State, BLEInterface.Action>,
              events: [AsyncStream<BLEDriverEvent>.Continuation],
              calls: LockIsolated<[MockDriverCall]>,
              clock: TestClock<Duration>,
              now: LockIsolated<Date>)
{
    let (store, events, calls, clock, now) = makeStore(maxPeers: maxPeers, streams: streams)
    await store.send(.start) { $0.status = .starting }
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    return (store, events, calls, clock, now)
}

@Test @MainActor func discoveryReadsDirectoryThenOpensChannel() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA))) {
        $0.pendingPeers = [peerHandleA]
    }
    #expect(calls.value.contains(.readDirectory(peerHandleA)))
    events[0].yield(.directoryRead(peerHandleA, version: 2, psm: 0x0081))
    await store.receive(.driverEvent(.directoryRead(peerHandleA, version: 2, psm: 0x0081)))
    #expect(calls.value.contains(.openChannel(peerHandleA, 0x0081)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func versionMismatchRefusesAndGreylists() async {
    let (store, events, calls, _, now) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.directoryRead(peerHandleA, version: 1, psm: 0x0081))
    await store.receive(.driverEvent(.directoryRead(peerHandleA, version: 1, psm: 0x0081))) {
        $0.pendingPeers = []
    }
    #expect(!calls.value.contains(.openChannel(peerHandleA, 0x0081)))
    // Greylisted: an immediate rediscovery is ignored (no second readDirectory).
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 1)
    // After the 5 s backoff expires (strictly after — inclusive boundary), retry is allowed.
    now.setValue(now.value.addingTimeInterval(5.01))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 2)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func directoryFailureStrikesAndPendingPeerIsNotRediscovered() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    // While pending, duplicate discovery is ignored.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 1)
    events[0].yield(.directoryFailed(peerHandleA, reason: "gatt error"))
    await store.receive(.driverEvent(.directoryFailed(peerHandleA, reason: "gatt error"))) {
        $0.pendingPeers = []
    }
    // Strike recorded: immediate rediscovery ignored.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func establishDeadlineAbandonsAndStrikes() async {
    let (store, events, _, clock, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    await clock.advance(by: BLEInterface.establishTimeout)
    await store.receive(.establishDeadline(peerHandleA)) { $0.pendingPeers = [] }
    // Late directoryRead for a no-longer-pending peer is ignored (no openChannel).
    events[0].yield(.directoryRead(peerHandleA, version: 2, psm: 0x0081))
    await store.receive(.driverEvent(.directoryRead(peerHandleA, version: 2, psm: 0x0081)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func discoveryIsIgnoredAtPeerCap() async {
    let (store, events, calls, _, _) = await makeOnlineStore(maxPeers: 1)
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    // A pending establishment counts against the cap (Python: spawned + pending >= max).
    events[0].yield(.peerDiscovered(peerHandleB))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleB)))
    #expect(calls.value.filter {
        if case .readDirectory = $0 { return true } else { return false }
    }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `swift test --filter BLEInterfaceTests`
Expected: the five new tests FAIL (stubs return `.none`, so `readDirectory` is never called, `pendingPeers` never mutates).

- [ ] **Step 3: Replace the stubs in `BLEInterface.swift`**

Replace `case .driverEvent(.peerDiscovered): return .none` and friends with:

```swift
            case let .driverEvent(.peerDiscovered(handle)):
                guard state.status == .online,
                      !state.pendingPeers.contains(handle),
                      !state.channels.values.contains(where: { $0.peer == handle }),
                      state.peers.count + state.pendingPeers.count < state.maxPeers,
                      !state.greylist.isBlocked(handle, now: date())
                else { return .none }
                state.pendingPeers.insert(handle)
                return .merge(
                    .run { [bleDriver] _ in await bleDriver.readDirectory(handle) },
                    .run { [clock] send in
                        try await clock.sleep(for: Self.establishTimeout)
                        await send(.establishDeadline(handle))
                    }
                    .cancellable(id: CancelID.establish(handle), cancelInFlight: true)
                )

            case let .driverEvent(.directoryRead(handle, version, psm)):
                guard state.pendingPeers.contains(handle) else { return .none }
                guard version == Self.protocolVersion else {
                    state.pendingPeers.remove(handle)
                    state.greylist.recordFailure(handle, now: date())
                    return .cancel(id: CancelID.establish(handle))
                }
                return .run { [bleDriver] _ in await bleDriver.openChannel(handle, psm) }

            case let .driverEvent(.directoryFailed(handle, _)),
                 let .driverEvent(.channelFailed(handle, _)):
                guard state.pendingPeers.contains(handle) else { return .none }
                state.pendingPeers.remove(handle)
                state.greylist.recordFailure(handle, now: date())
                return .cancel(id: CancelID.establish(handle))

            case let .establishDeadline(handle):
                guard state.pendingPeers.contains(handle) else { return .none }
                state.pendingPeers.remove(handle)
                state.greylist.recordFailure(handle, now: date())
                return .none
```

(Keep the `.channelOpened`, `.channelData`, `.channelClosed`, `.send`, `.helloDeadline`, `.adapterRetry`, `.unavailable` stubs — Tasks 6–7.)

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BLEInterfaceTests` — all PASS.

- [ ] **Step 5: Mutation verification (batch)**

1. In `.peerDiscovered`, delete the greylist guard line.
2. In `.directoryRead`, change `version == Self.protocolVersion` to `version != Self.protocolVersion`.
3. In `.peerDiscovered`, change the cap check to `<= state.maxPeers`.

Run: `swift test --filter BLEInterfaceTests`
Expected: `versionMismatchRefusesAndGreylists`, `discoveryReadsDirectoryThenOpensChannel`, and `discoveryIsIgnoredAtPeerCap` FAIL. Revert; re-run; all PASS.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task5-msg.txt` (subject `feat: BLE discovery-to-channel-open pipeline with version gate + greylist`), then:

```bash
git add Sources/ReTiCAInterfaces/BLEInterface.swift Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift
git commit -F /tmp/ReTiCA/task5-msg.txt
```

---

### Task 6: HELLO exchange, dedup, data plane, send

**Files:**
- Modify: `Sources/ReTiCAInterfaces/BLEInterface.swift` (replace stubs; add `tearDown` helper)
- Test: `Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift` (append)

**Interfaces:**
- Consumes: Tasks 4–5 reducer + harness; `BLEHello`, `bleResolveDuplicate`, `BLEFraming` (Tasks 1–2).
- Produces: working `.driverEvent(.channelOpened/.channelData)`, `.send`, `.helloDeadline`; `private func tearDown(_ state: inout State, channelID: BLEChannelID, strike: Bool) -> Effect<Action>` (Task 7 reuses it). Delegate events `.peerOnline(token)` / `.packetReceived(peer:packet:)` now fire.

- [ ] **Step 1: Write the failing tests**

Append to `BLEInterfaceTests.swift`:

```swift
// MARK: - HELLO / data plane

/// Drives one peer to established: discovery → directory → channelOpened → peer HELLO.
@MainActor
func establishPeer(
    _ store: TestStore<BLEInterface.State, BLEInterface.Action>,
    _ events: AsyncStream<BLEDriverEvent>.Continuation,
    handle: BLEPeerHandle, channel: BLEChannelID, peerToken: Data
) async {
    events.yield(.peerDiscovered(handle))
    await store.receive(.driverEvent(.peerDiscovered(handle)))
    events.yield(.directoryRead(handle, version: 2, psm: 0x0081))
    await store.receive(.driverEvent(.directoryRead(handle, version: 2, psm: 0x0081)))
    events.yield(.channelOpened(channel, handle, direction: .outbound))
    await store.receive(.driverEvent(.channelOpened(channel, handle, direction: .outbound)))
    events.yield(.channelData(channel, framedHello(token: peerToken)))
    await store.receive(.driverEvent(.channelData(channel, framedHello(token: peerToken))))
    await store.receive(.delegate(.peerOnline(peerToken)))
}

@Test @MainActor func establishmentSendsHelloAndReportsPeerOnline() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    // Our HELLO went out on the channel, framed.
    #expect(calls.value.contains(.send(channel1, framedHello(token: localToken))))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func inboundChannelFollowsSameHelloPath() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    #expect(calls.value.contains(.send(channel1, framedHello(token: localToken))))
    events[0].yield(.channelData(channel1, framedHello(token: tokenHigh)))
    await store.receive(.driverEvent(.channelData(channel1, framedHello(token: tokenHigh))))
    await store.receive(.delegate(.peerOnline(tokenHigh)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func packetsFlowBothWaysAfterHello() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    // Inbound: a framed packet after HELLO surfaces as packetReceived.
    let packet = Data(repeating: 0xAB, count: 40)
    events[0].yield(.channelData(channel1, try! BLEFraming.frame(packet)))
    await store.receive(.driverEvent(.channelData(channel1, try! BLEFraming.frame(packet))))
    await store.receive(.delegate(.packetReceived(peer: tokenHigh, packet: packet)))
    // Outbound: .send frames and forwards to the driver.
    let outbound = Data(repeating: 0xCD, count: 21)
    await store.send(.send(peer: tokenHigh, packet: outbound))
    #expect(calls.value.contains(.send(channel1, try! BLEFraming.frame(outbound))))
    // Sending to an unknown peer is silently dropped.
    let before = calls.value.count
    await store.send(.send(peer: tokenLow, packet: outbound))
    #expect(calls.value.count == before)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func helloAndPacketInOneDeliveryBothProcessed() async {
    let (store, events, _, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    let packet = Data([0x01, 0x02, 0x03])
    let combined = framedHello(token: tokenHigh) + (try! BLEFraming.frame(packet))
    events[0].yield(.channelData(channel1, combined))
    await store.receive(.driverEvent(.channelData(channel1, combined)))
    await store.receive(.delegate(.peerOnline(tokenHigh)))
    await store.receive(.delegate(.packetReceived(peer: tokenHigh, packet: packet)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func invalidFirstFrameDropsChannelAndStrikes() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    // A validly-framed 20-byte frame that is NOT a HELLO (wrong magic).
    let bogus = try! BLEFraming.frame(Data(repeating: 0x51, count: 20))
    events[0].yield(.channelData(channel1, bogus))
    await store.receive(.driverEvent(.channelData(channel1, bogus)))
    #expect(calls.value.contains(.closeChannel(channel1)))
    // Strike recorded: discovery of the same handle is now ignored.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(!calls.value.contains(.readDirectory(peerHandleA)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func helloEchoingOurOwnTokenIsRejected() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    events[0].yield(.channelData(channel1, framedHello(token: localToken)))
    await store.receive(.driverEvent(.channelData(channel1, framedHello(token: localToken))))
    #expect(calls.value.contains(.closeChannel(channel1)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func malformedFramingDropsChannel() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    events[0].yield(.channelData(channel1, Data([0x00, 0x00])))  // len == 0: unrecoverable
    await store.receive(.driverEvent(.channelData(channel1, Data([0x00, 0x00]))))
    await store.receive(.delegate(.peerOffline(tokenHigh)))
    #expect(calls.value.contains(.closeChannel(channel1)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func helloTimeoutDropsChannelAndStrikes() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    await clock.advance(by: BLEInterface.helloTimeout)
    await store.receive(.helloDeadline(channel1))
    #expect(calls.value.contains(.closeChannel(channel1)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func inboundChannelRefusedAtPeerCap() async {
    let (store, events, calls, _, _) = await makeOnlineStore(maxPeers: 1)
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    events[0].yield(.channelOpened(channel2, peerHandleB, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleB, direction: .inbound)))
    #expect(calls.value.contains(.closeChannel(channel2)))
    // The refused channel never got our HELLO.
    #expect(!calls.value.contains(.send(channel2, framedHello(token: localToken))))
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Dedup

@Test @MainActor func crossConnectKeepsLowerInitiatorsChannelFromBothPerspectives() async {
    // Our token 0x11... vs peer 0x01...: PEER is lower, so the peer-initiated
    // (inbound-at-us) channel must survive regardless of arrival order.
    // Order 1: our outbound established first, then peer's inbound HELLOs.
    var (store, events, calls, _, _) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenLow)
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound)))
    events[0].yield(.channelData(channel2, framedHello(token: tokenLow)))
    await store.receive(.driverEvent(.channelData(channel2, framedHello(token: tokenLow))))
    #expect(calls.value.contains(.closeChannel(channel1)))   // outbound (ours) loses
    #expect(!calls.value.contains(.closeChannel(channel2)))  // inbound (peer's) survives
    // The peer stayed online through the swap: traffic flows on the survivor.
    let packet = Data([0x0A, 0x0B, 0x0C])
    await store.send(.send(peer: tokenLow, packet: packet))
    #expect(calls.value.contains(.send(channel2, try! BLEFraming.frame(packet))))
    await store.send(.stop) { $0.status = .stopped }

    // Order 2: peer's inbound established first, then our outbound HELLOs back.
    (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound)))
    events[0].yield(.channelData(channel2, framedHello(token: tokenLow)))
    await store.receive(.driverEvent(.channelData(channel2, framedHello(token: tokenLow))))
    await store.receive(.delegate(.peerOnline(tokenLow)))
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .outbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .outbound)))
    events[0].yield(.channelData(channel1, framedHello(token: tokenLow)))
    await store.receive(.driverEvent(.channelData(channel1, framedHello(token: tokenLow))))
    #expect(calls.value.contains(.closeChannel(channel1)))   // ours still loses
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func sameDirectionHelloReplacesStaleChannelWithoutOfflineBlip() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound)))
    events[0].yield(.channelData(channel1, framedHello(token: tokenHigh)))
    await store.receive(.driverEvent(.channelData(channel1, framedHello(token: tokenHigh))))
    await store.receive(.delegate(.peerOnline(tokenHigh)))
    // Peer silently dropped and re-dialed: new inbound channel, same token.
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound)))
    events[0].yield(.channelData(channel2, framedHello(token: tokenHigh)))
    await store.receive(.driverEvent(.channelData(channel2, framedHello(token: tokenHigh))))
    #expect(calls.value.contains(.closeChannel(channel1)))  // stale channel closed
    // No peerOffline/second peerOnline was emitted; traffic now rides channel2.
    let packet = Data([0x01])
    await store.send(.send(peer: tokenHigh, packet: packet))
    #expect(calls.value.contains(.send(channel2, try! BLEFraming.frame(packet))))
    await store.send(.stop) { $0.status = .stopped }
}
```

Note on `establishPeer` in the second dedup order: not used — the inbound path is driven inline because there is no discovery step.

- [ ] **Step 2: Run to verify the new tests fail**

Run: `swift test --filter BLEInterfaceTests`
Expected: all Task 6 tests FAIL (stubs).

- [ ] **Step 3: Implement**

Replace the `.channelOpened`, `.channelData`, `.send`, `.helloDeadline` stubs in `BLEInterface.swift`:

```swift
            case let .driverEvent(.channelOpened(channelID, handle, direction)):
                var effects: [Effect<Action>] = []
                if direction == .outbound {
                    state.pendingPeers.remove(handle)
                    effects.append(.cancel(id: CancelID.establish(handle)))
                }
                let now = date()
                guard state.status == .online,
                      let token = state.sessionToken,
                      state.peers.count < state.maxPeers,
                      !state.greylist.isBlocked(handle, now: now)
                else {
                    effects.append(.run { [bleDriver] _ in await bleDriver.closeChannel(channelID) })
                    return .merge(effects)
                }
                state.channels[channelID] = ChannelState(
                    peer: handle, direction: direction,
                    frameBuffer: BLEFrameBuffer(), peerToken: nil, openedAt: now)
                // 20-byte HELLO framed by hand — cannot exceed frame bounds, no throw.
                var hello = Data([0x00, UInt8(BLEHello.length)])
                hello.append(BLEHello.pack(version: Self.protocolVersion, token: token))
                let framedHello = hello
                effects.append(.run { [bleDriver] _ in await bleDriver.send(channelID, framedHello) })
                effects.append(.run { [clock] send in
                    try await clock.sleep(for: Self.helloTimeout)
                    await send(.helloDeadline(channelID))
                }
                .cancellable(id: CancelID.hello(channelID), cancelInFlight: true))
                return .merge(effects)

            case let .driverEvent(.channelData(channelID, bytes)):
                guard var channel = state.channels[channelID] else { return .none }
                let frames: [Data]
                do {
                    frames = try channel.frameBuffer.append(bytes)
                    state.channels[channelID] = channel
                } catch {
                    state.channels[channelID] = channel
                    return tearDown(&state, channelID: channelID, strike: true)
                }
                var effects: [Effect<Action>] = []
                for frame in frames {
                    guard let current = state.channels[channelID] else { break }
                    if let token = current.peerToken {
                        effects.append(.send(.delegate(.packetReceived(peer: token, packet: frame))))
                        continue
                    }
                    // First frame must be a valid v2 HELLO that is not our own echo.
                    guard let hello = BLEHello.parse(frame),
                          hello.version == Self.protocolVersion,
                          hello.token != state.sessionToken
                    else {
                        effects.append(tearDown(&state, channelID: channelID, strike: true))
                        continue  // channel gone; loop guard drops remaining frames
                    }
                    effects.append(.cancel(id: CancelID.hello(channelID)))
                    let token = hello.token
                    if let existingID = state.peers[token],
                       let existing = state.channels[existingID],
                       existingID != channelID {
                        let resolution = bleResolveDuplicate(
                            localToken: state.sessionToken ?? Data(),
                            peerToken: token,
                            existingDirection: existing.direction,
                            newDirection: current.direction)
                        switch resolution {
                        case .keepExisting:
                            // Close the new channel quietly: never online, no strike.
                            state.channels[channelID] = nil
                            effects.append(.run { [bleDriver] _ in
                                await bleDriver.closeChannel(channelID)
                            })
                        case .keepNew:
                            // Swap channels under the peer without an offline blip.
                            state.channels[existingID] = nil
                            effects.append(.cancel(id: CancelID.hello(existingID)))
                            effects.append(.run { [bleDriver] _ in
                                await bleDriver.closeChannel(existingID)
                            })
                            var updated = current
                            updated.peerToken = token
                            state.channels[channelID] = updated
                            state.peers[token] = channelID
                        }
                    } else {
                        var updated = current
                        updated.peerToken = token
                        state.channels[channelID] = updated
                        state.peers[token] = channelID
                        effects.append(.send(.delegate(.peerOnline(token))))
                    }
                }
                return .merge(effects)

            case let .send(peer, packet):
                guard let channelID = state.peers[peer],
                      let framed = try? BLEFraming.frame(packet)
                else { return .none }
                return .run { [bleDriver] _ in await bleDriver.send(channelID, framed) }

            case let .helloDeadline(channelID):
                guard let channel = state.channels[channelID], channel.peerToken == nil
                else { return .none }
                return tearDown(&state, channelID: channelID, strike: true)
```

Add the shared helper as a method on `BLEInterface` (below `startDriver`):

```swift
    /// Removes a channel, closes it at the driver, emits peerOffline if it was the
    /// established channel for a peer, and optionally records a greylist strike.
    private func tearDown(_ state: inout State, channelID: BLEChannelID, strike: Bool) -> Effect<Action> {
        guard let channel = state.channels.removeValue(forKey: channelID) else { return .none }
        var effects: [Effect<Action>] = [
            .cancel(id: CancelID.hello(channelID)),
            .run { [bleDriver] _ in await bleDriver.closeChannel(channelID) },
        ]
        if let token = channel.peerToken, state.peers[token] == channelID {
            state.peers[token] = nil
            effects.append(.send(.delegate(.peerOffline(token))))
        }
        if strike {
            state.greylist.recordFailure(channel.peer, now: date())
        }
        return .merge(effects)
    }
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BLEInterfaceTests` — all PASS.

- [ ] **Step 5: Mutation verification (batch)**

1. In `.channelData`'s HELLO branch, delete the `hello.token != state.sessionToken` condition.
2. In the dedup `switch`, swap the bodies of `.keepExisting` and `.keepNew`.
3. In `.send`'s run effect, change `await bleDriver.send(channelID, framed)` to `await bleDriver.send(channelID, packet)` (send unframed).
4. In `.channelOpened`, delete the hello-timeout effect append.

Run: `swift test --filter BLEInterfaceTests`
Expected: `helloEchoingOurOwnTokenIsRejected` (1), `crossConnectKeepsLowerInitiatorsChannelFromBothPerspectives` (2), `packetsFlowBothWaysAfterHello` (3), `helloTimeoutDropsChannelAndStrikes` (4) FAIL. Revert; re-run; all PASS.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task6-msg.txt` (subject `feat: BLE HELLO exchange, symmetric dedup, and data plane`), then:

```bash
git add Sources/ReTiCAInterfaces/BLEInterface.swift Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift
git commit -F /tmp/ReTiCA/task6-msg.txt
```

---

### Task 7: Channel-close policy, churn, adapter loss + recovery

**Files:**
- Modify: `Sources/ReTiCAInterfaces/BLEInterface.swift` (replace remaining stubs)
- Test: `Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift` (append)

**Interfaces:**
- Consumes: Tasks 4–6 reducer, `tearDown`, `startDriver`, harness (use `makeOnlineStore(streams: 2)` for recovery).
- Produces: working `.driverEvent(.channelClosed)`, `.driverEvent(.unavailable)`, `.adapterRetry`. The reducer is feature-complete after this task.

- [ ] **Step 1: Write the failing tests**

Append to `BLEInterfaceTests.swift`:

```swift
// MARK: - Close policy / churn / adapter loss

@Test @MainActor func channelClosedTakesPeerOfflineWithoutChurnStrike() async {
    let (store, events, calls, _, now) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    // Lives >= 10 s: no strike.
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime))
    events[0].yield(.channelClosed(channel1, reason: "supervision timeout"))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: "supervision timeout")))
    await store.receive(.delegate(.peerOffline(tokenHigh)))
    // No strike: rediscovery proceeds straight to a directory read.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 2)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func shortLivedChannelEarnsChurnStrike() async {
    let (store, events, calls, _, now) = await makeOnlineStore()
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    // Lives < 10 s: strike.
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime - 0.5))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(tokenHigh)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readDirectory(peerHandleA) }.count == 1)  // blocked
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func closedChannelUnknownToStateIsIgnored() async {
    let (store, events, _, _, _) = await makeOnlineStore()
    events[0].yield(.channelClosed(channel2, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel2, reason: nil)))  // no crash, no delegate
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func adapterLossTakesPeersOfflineThenRecoversWithBackoff() async {
    let (store, events, calls, clock, _) = await makeOnlineStore(streams: 2)
    await establishPeer(store, events[0], handle: peerHandleA, channel: channel1, peerToken: tokenHigh)
    events[0].yield(.unavailable(reason: "poweredOff"))
    await store.receive(.driverEvent(.unavailable(reason: "poweredOff"))) {
        $0.status = .waitingForAdapter
        $0.channels = [:]
        $0.peers = [:]
        $0.pendingPeers = []
    }
    await store.receive(.delegate(.peerOffline(tokenHigh)))
    // First retry after 5 s.
    await clock.advance(by: BLEInterface.adapterRetryMin)
    await store.receive(.adapterRetry) { $0.status = .starting }
    #expect(calls.value.filter { $0 == .start }.count == 2)
    // Recovery: second stream reports ready; backoff delay resets.
    events[1].yield(.ready)
    await store.receive(.driverEvent(.ready)) {
        $0.status = .online
        $0.adapterRetryDelay = BLEInterface.adapterRetryMin
    }
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func adapterRetryDelayDoublesUpToCap() async {
    let (store, events, _, clock, _) = await makeOnlineStore(streams: 2)
    events[0].yield(.unavailable(reason: nil))
    await store.receive(.driverEvent(.unavailable(reason: nil))) {
        $0.status = .waitingForAdapter
        $0.adapterRetryDelay = .seconds(10)  // doubled after scheduling the 5 s retry
    }
    await clock.advance(by: BLEInterface.adapterRetryMin)
    await store.receive(.adapterRetry) { $0.status = .starting }
    // Second loss: the scheduled retry now uses 10 s, and the stored delay doubles to 20 s.
    events[1].yield(.unavailable(reason: nil))
    await store.receive(.driverEvent(.unavailable(reason: nil))) {
        $0.status = .waitingForAdapter
        $0.adapterRetryDelay = .seconds(20)
    }
    await clock.advance(by: .seconds(5))
    // 5 s is no longer enough — no retry yet.
    await clock.advance(by: .seconds(5))
    await store.receive(.adapterRetry) { $0.status = .starting }
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func stopWhileWaitingForAdapterCancelsRetry() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.unavailable(reason: nil))
    await store.receive(.driverEvent(.unavailable(reason: nil))) { $0.status = .waitingForAdapter }
    await store.send(.stop) { $0.status = .stopped }
    let startsBefore = calls.value.filter { $0 == .start }.count
    await clock.advance(by: BLEInterface.adapterRetryMax)
    #expect(calls.value.filter { $0 == .start }.count == startsBefore)  // no retry fired
}
```

- [ ] **Step 2: Run to verify the new tests fail**

Run: `swift test --filter BLEInterfaceTests`
Expected: the six new tests FAIL.

- [ ] **Step 3: Implement**

Replace the `.channelClosed`, `.unavailable`, `.adapterRetry` stubs:

```swift
            case let .driverEvent(.channelClosed(channelID, _)):
                guard let channel = state.channels.removeValue(forKey: channelID) else { return .none }
                var effects: [Effect<Action>] = [.cancel(id: CancelID.hello(channelID))]
                if let token = channel.peerToken, state.peers[token] == channelID {
                    state.peers[token] = nil
                    effects.append(.send(.delegate(.peerOffline(token))))
                }
                let now = date()
                if now.timeIntervalSince(channel.openedAt) < Self.churnMinLifetime {
                    state.greylist.recordFailure(channel.peer, now: now)
                }
                return .merge(effects)

            case .driverEvent(.unavailable):
                guard state.status != .stopped else { return .none }
                let established = Array(state.peers.keys)
                let channelIDs = Array(state.channels.keys)
                let pending = Array(state.pendingPeers)
                state.channels = [:]
                state.peers = [:]
                state.pendingPeers = []
                state.status = .waitingForAdapter
                let delay = state.adapterRetryDelay
                state.adapterRetryDelay = min(delay * 2, Self.adapterRetryMax)
                var effects: [Effect<Action>] = [.cancel(id: CancelID.driver)]
                effects += channelIDs.map { .cancel(id: CancelID.hello($0)) }
                effects += pending.map { .cancel(id: CancelID.establish($0)) }
                effects += established.map { .send(.delegate(.peerOffline($0))) }
                effects.append(.run { [clock] send in
                    try await clock.sleep(for: delay)
                    await send(.adapterRetry)
                }
                .cancellable(id: CancelID.retry, cancelInFlight: true))
                return .merge(effects)

            case .adapterRetry:
                guard state.status == .waitingForAdapter else { return .none }
                state.status = .starting
                return startDriver(state: &state)
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter BLEInterfaceTests` — all PASS. Then run the whole package once: `swift test` — everything else still green.

- [ ] **Step 5: Mutation verification (batch)**

1. In `.channelClosed`, invert the churn comparison to `>= Self.churnMinLifetime`.
2. In `.unavailable`, replace `min(delay * 2, Self.adapterRetryMax)` with `delay`.
3. In `.adapterRetry`, change the guard to `state.status == .online`.

Run: `swift test --filter BLEInterfaceTests`
Expected: `channelClosedTakesPeerOfflineWithoutChurnStrike` + `shortLivedChannelEarnsChurnStrike` (1), `adapterRetryDelayDoublesUpToCap` (2), `adapterLossTakesPeersOfflineThenRecoversWithBackoff` (3) FAIL. Revert; re-run; all PASS.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task7-msg.txt` (subject `feat: BLE churn policy + adapter-loss recovery`), then:

```bash
git add Sources/ReTiCAInterfaces/BLEInterface.swift Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift
git commit -F /tmp/ReTiCA/task7-msg.txt
```

---

### Task 8: Live CoreBluetooth driver + hardware checklist

**Files:**
- Create: `Sources/ReTiCAInterfaces/CoreBluetoothDriver.swift`
- Modify: `Sources/ReTiCAInterfaces/BLEDriver.swift` (replace the inert `liveValue`)
- Create: `docs/superpowers/plans/2026-08-01-ble-hardware-checklist.md`

**Interfaces:**
- Consumes: `BLEDriver`, `BLEDriverConfig`, `BLEDriverEvent`, `BLEPeerHandle`, `BLEChannelID`, `BLEChannelDirection`, `BLEPairingMode` (Tasks 2, 4).
- Produces: `CoreBluetoothDriver` (internal class) and a CoreBluetooth-backed `BLEDriver.liveValue` on iOS/macOS/Catalyst; the inert stub remains on other platforms. No automated tests (mechanism only, verified on hardware via the checklist).

**Notes for the implementer:**
- The driver is MECHANISM ONLY. No retries, no greylist, no framing, no version policy. Every CoreBluetooth error becomes an event.
- All CoreBluetooth callbacks and internal state live on one serial `DispatchQueue`; both managers are created with that queue. `@unchecked Sendable` is justified by that single-queue confinement.
- Peripheral side: on `poweredOn` → `publishL2CAPChannel(withEncryption: pairingMode == .paired)` → on `didPublishL2CAPChannel` build the GATT service with STATIC characteristic values (Version = `Data([config.version])`, PSM = little-endian `UInt16`) → `add(service)` → `startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])`.
- Central side: on `poweredOn` → `scanForPeripherals(withServices: [serviceUUID], options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])`. Allow-duplicates + a `seenPeers` set gives re-discovery after failures: remove a peer from `seenPeers` on directory failure / channel failure / channel close / disconnect so the next advertisement re-emits `.peerDiscovered`.
- Emit `.ready` exactly once per `start()` when BOTH advertising and scanning are up. Emit `.unavailable` (once per start) when either manager reports `poweredOff`/`unauthorized`/`unsupported`.
- `readDirectory`: `central.connect` → `discoverServices([serviceUUID])` → `discoverCharacteristics([versionUUID, psmUUID])` → `readValue` both → when both values are in, emit `.directoryRead`. Any error/missing piece → `.directoryFailed`. Keep the peripheral connected — `openChannel` rides the same ACL link.
- Streams: schedule `CBL2CAPChannel` input/output on the driver queue via `CFReadStreamSetDispatchQueue`/`CFWriteStreamSetDispatchQueue`; buffer writes and drain on `.hasSpaceAvailable`.
- Gate the whole file `#if canImport(CoreBluetooth) && (os(iOS) || os(macOS))` (Catalyst counts as iOS). tvOS/watchOS keep the inert stub.

- [ ] **Step 1: Write `CoreBluetoothDriver.swift`**

```swift
#if canImport(CoreBluetooth) && (os(iOS) || os(macOS))
import Foundation
import CoreBluetooth

private let serviceUUID = CBUUID(string: "99872ed7-eba8-4c07-bf35-ab464a957f80")
private let versionUUID = CBUUID(string: "50870e44-2fd6-4cbc-9f1f-11a0fcf85265")
private let psmUUID = CBUUID(string: "1cfe213f-4ea4-48f9-9344-dde18cc729ef")

/// Live CoreBluetooth implementation of the BLEDriver contract. Mechanism only:
/// advertises + serves the GATT directory + publishes the L2CAP listener
/// (peripheral role) while scanning + reading directories + dialing channels
/// (central role). All policy lives in the BLEInterface reducer.
final class CoreBluetoothDriver: NSObject, @unchecked Sendable {
    private let queue = DispatchQueue(label: "retica.ble.driver")
    private var central: CBCentralManager?
    private var peripheralManager: CBPeripheralManager?
    private var continuation: AsyncStream<BLEDriverEvent>.Continuation?
    private var config = BLEDriverConfig(version: 0, pairingMode: .open)

    private var advertising = false
    private var scanning = false
    private var announcedReady = false
    private var announcedUnavailable = false

    private var peripherals: [UUID: CBPeripheral] = [:]
    private var seenPeers: Set<UUID> = []
    private var directoryReads: [UUID: (version: UInt8?, psm: UInt16?)] = [:]
    private var channels: [BLEChannelID: ChannelIO] = [:]

    // MARK: BLEDriver contract (each hops onto the driver queue)

    func start(_ config: BLEDriverConfig) -> AsyncStream<BLEDriverEvent> {
        AsyncStream { continuation in
            self.queue.async {
                self.teardownLocked()
                self.config = config
                self.continuation = continuation
                self.announcedReady = false
                self.announcedUnavailable = false
                self.central = CBCentralManager(delegate: self, queue: self.queue)
                self.peripheralManager = CBPeripheralManager(delegate: self, queue: self.queue)
            }
        }
    }

    func readDirectory(_ peer: BLEPeerHandle) {
        queue.async {
            guard let central = self.central, let peripheral = self.peripherals[peer.id] else {
                self.emit(.directoryFailed(peer, reason: "unknown peripheral"))
                return
            }
            self.directoryReads[peer.id] = (nil, nil)
            peripheral.delegate = self
            central.connect(peripheral)
        }
    }

    func openChannel(_ peer: BLEPeerHandle, psm: UInt16) {
        queue.async {
            guard let peripheral = self.peripherals[peer.id], peripheral.state == .connected else {
                self.forget(peer.id)
                self.emit(.channelFailed(peer, reason: "not connected"))
                return
            }
            peripheral.openL2CAPChannel(CBL2CAPPSM(psm))
        }
    }

    func send(_ channelID: BLEChannelID, data: Data) {
        queue.async { self.channels[channelID]?.send(data) }
    }

    func closeChannel(_ channelID: BLEChannelID) {
        queue.async { self.channels.removeValue(forKey: channelID)?.close() }
    }

    func stop() {
        queue.async { self.teardownLocked() }
    }

    // MARK: Internals (always on queue)

    private func teardownLocked() {
        for (_, io) in channels { io.close() }
        channels = [:]
        directoryReads = [:]
        seenPeers = []
        if let central {
            if central.isScanning { central.stopScan() }
            for (_, p) in peripherals where p.state != .disconnected {
                central.cancelPeripheralConnection(p)
            }
        }
        peripherals = [:]
        peripheralManager?.stopAdvertising()
        peripheralManager?.removeAllServices()
        central = nil
        peripheralManager = nil
        advertising = false
        scanning = false
        continuation?.finish()
        continuation = nil
    }

    private func emit(_ event: BLEDriverEvent) {
        continuation?.yield(event)
    }

    private func checkReady() {
        guard advertising, scanning, !announcedReady else { return }
        announcedReady = true
        emit(.ready)
    }

    private func fireUnavailable(_ reason: String) {
        guard !announcedUnavailable else { return }
        announcedUnavailable = true
        emit(.unavailable(reason: reason))
    }

    /// Allows a peer to be re-discovered after a failure or disconnect.
    private func forget(_ id: UUID) {
        seenPeers.remove(id)
        directoryReads[id] = nil
    }

    private func makeChannel(_ cbChannel: CBL2CAPChannel, peer: UUID, direction: BLEChannelDirection) {
        let channelID = BLEChannelID(id: UUID())
        let io = ChannelIO(channel: cbChannel, queue: queue) { [weak self] data in
            self?.emit(.channelData(channelID, data))
        } onClosed: { [weak self] reason in
            guard let self else { return }
            self.channels[channelID] = nil
            self.forget(peer)
            self.emit(.channelClosed(channelID, reason: reason))
        }
        channels[channelID] = io
        io.open()
        emit(.channelOpened(channelID, BLEPeerHandle(id: peer), direction: direction))
    }

    private func finishDirectoryReadIfComplete(_ peripheral: CBPeripheral) {
        let id = peripheral.identifier
        guard let read = directoryReads[id], let version = read.version, let psm = read.psm else { return }
        directoryReads[id] = nil
        emit(.directoryRead(BLEPeerHandle(id: id), version: version, psm: psm))
    }

    private func failDirectoryRead(_ id: UUID, reason: String?) {
        guard directoryReads[id] != nil else { return }
        directoryReads[id] = nil
        forget(id)
        emit(.directoryFailed(BLEPeerHandle(id: id), reason: reason))
    }
}

// MARK: - Central role

extension CoreBluetoothDriver: CBCentralManagerDelegate {
    func centralManagerDidUpdateState(_ central: CBCentralManager) {
        switch central.state {
        case .poweredOn:
            central.scanForPeripherals(
                withServices: [serviceUUID],
                options: [CBCentralManagerScanOptionAllowDuplicatesKey: true])
            scanning = true
            checkReady()
        case .poweredOff, .unauthorized, .unsupported:
            fireUnavailable("central \(central.state.rawValue)")
        default:
            break
        }
    }

    func centralManager(_ central: CBCentralManager, didDiscover peripheral: CBPeripheral,
                        advertisementData: [String: Any], rssi RSSI: NSNumber) {
        let id = peripheral.identifier
        guard !seenPeers.contains(id) else { return }
        seenPeers.insert(id)
        peripherals[id] = peripheral
        emit(.peerDiscovered(BLEPeerHandle(id: id)))
    }

    func centralManager(_ central: CBCentralManager, didConnect peripheral: CBPeripheral) {
        peripheral.discoverServices([serviceUUID])
    }

    func centralManager(_ central: CBCentralManager, didFailToConnect peripheral: CBPeripheral,
                        error: Error?) {
        failDirectoryRead(peripheral.identifier, reason: error?.localizedDescription ?? "connect failed")
    }

    func centralManager(_ central: CBCentralManager, didDisconnectPeripheral peripheral: CBPeripheral,
                        error: Error?) {
        failDirectoryRead(peripheral.identifier, reason: error?.localizedDescription ?? "disconnected")
        forget(peripheral.identifier)
        // Any open channel's streams will error and report channelClosed themselves.
    }
}

// MARK: - Peripheral (remote) GATT + outbound channel

extension CoreBluetoothDriver: CBPeripheralDelegate {
    func peripheral(_ peripheral: CBPeripheral, didDiscoverServices error: Error?) {
        guard error == nil, let service = peripheral.services?.first(where: { $0.uuid == serviceUUID })
        else {
            failDirectoryRead(peripheral.identifier,
                              reason: error?.localizedDescription ?? "service not found")
            return
        }
        peripheral.discoverCharacteristics([versionUUID, psmUUID], for: service)
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didDiscoverCharacteristicsFor service: CBService, error: Error?) {
        guard error == nil, let characteristics = service.characteristics else {
            failDirectoryRead(peripheral.identifier,
                              reason: error?.localizedDescription ?? "characteristics not found")
            return
        }
        var found = 0
        for characteristic in characteristics
        where characteristic.uuid == versionUUID || characteristic.uuid == psmUUID {
            peripheral.readValue(for: characteristic)
            found += 1
        }
        if found < 2 {
            failDirectoryRead(peripheral.identifier, reason: "directory characteristics missing")
        }
    }

    func peripheral(_ peripheral: CBPeripheral,
                    didUpdateValueFor characteristic: CBCharacteristic, error: Error?) {
        let id = peripheral.identifier
        guard error == nil, let value = characteristic.value, directoryReads[id] != nil else {
            failDirectoryRead(id, reason: error?.localizedDescription ?? "read failed")
            return
        }
        if characteristic.uuid == versionUUID, value.count >= 1 {
            directoryReads[id]?.version = value[value.startIndex]
        } else if characteristic.uuid == psmUUID, value.count >= 2 {
            let rebased = Data(value)
            directoryReads[id]?.psm = UInt16(rebased[0]) | (UInt16(rebased[1]) << 8)  // little-endian
        } else {
            failDirectoryRead(id, reason: "malformed characteristic value")
            return
        }
        finishDirectoryReadIfComplete(peripheral)
    }

    func peripheral(_ peripheral: CBPeripheral, didOpen channel: CBL2CAPChannel?, error: Error?) {
        let id = peripheral.identifier
        guard error == nil, let channel else {
            forget(id)
            emit(.channelFailed(BLEPeerHandle(id: id),
                                reason: error?.localizedDescription ?? "L2CAP open failed"))
            return
        }
        makeChannel(channel, peer: id, direction: .outbound)
    }
}

// MARK: - Peripheral (local) role: advertise, GATT directory, L2CAP listener

extension CoreBluetoothDriver: CBPeripheralManagerDelegate {
    func peripheralManagerDidUpdateState(_ peripheral: CBPeripheralManager) {
        switch peripheral.state {
        case .poweredOn:
            peripheral.publishL2CAPChannel(withEncryption: config.pairingMode == .paired)
        case .poweredOff, .unauthorized, .unsupported:
            fireUnavailable("peripheral \(peripheral.state.rawValue)")
        default:
            break
        }
    }

    func peripheralManager(_ peripheral: CBPeripheralManager,
                           didPublishL2CAPChannel PSM: CBL2CAPPSM, error: Error?) {
        guard error == nil else {
            fireUnavailable("publishL2CAPChannel: \(error!.localizedDescription)")
            return
        }
        let permissions: CBAttributePermissions =
            config.pairingMode == .paired ? .readEncryptionRequired : .readable
        let versionCharacteristic = CBMutableCharacteristic(
            type: versionUUID, properties: .read,
            value: Data([config.version]), permissions: permissions)
        var psmValue = Data(count: 2)
        psmValue[0] = UInt8(PSM & 0xFF)
        psmValue[1] = UInt8(PSM >> 8)  // little-endian per spec
        let psmCharacteristic = CBMutableCharacteristic(
            type: psmUUID, properties: .read, value: psmValue, permissions: permissions)
        let service = CBMutableService(type: serviceUUID, primary: true)
        service.characteristics = [versionCharacteristic, psmCharacteristic]
        peripheral.add(service)
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didAdd service: CBService,
                           error: Error?) {
        guard error == nil else {
            fireUnavailable("add service: \(error!.localizedDescription)")
            return
        }
        peripheral.startAdvertising([CBAdvertisementDataServiceUUIDsKey: [serviceUUID]])
    }

    func peripheralManagerDidStartAdvertising(_ peripheral: CBPeripheralManager, error: Error?) {
        guard error == nil else {
            fireUnavailable("advertising: \(error!.localizedDescription)")
            return
        }
        advertising = true
        checkReady()
    }

    func peripheralManager(_ peripheral: CBPeripheralManager, didOpen channel: CBL2CAPChannel?,
                           error: Error?) {
        guard error == nil, let channel else { return }
        makeChannel(channel, peer: channel.peer.identifier, direction: .inbound)
    }
}

// MARK: - L2CAP channel stream pump

/// Owns one CBL2CAPChannel's stream pair. Confined to the driver queue via
/// CFStream dispatch-queue scheduling; buffers writes until space is available.
private final class ChannelIO: NSObject, StreamDelegate {
    private let channel: CBL2CAPChannel
    private let queue: DispatchQueue
    private let onData: (Data) -> Void
    private let onClosed: (String?) -> Void
    private var outBuffer = Data()
    private var finished = false

    init(channel: CBL2CAPChannel, queue: DispatchQueue,
         onData: @escaping (Data) -> Void, onClosed: @escaping (String?) -> Void) {
        self.channel = channel
        self.queue = queue
        self.onData = onData
        self.onClosed = onClosed
    }

    func open() {
        guard let input = channel.inputStream, let output = channel.outputStream else {
            finish(reason: "missing streams")
            return
        }
        input.delegate = self
        output.delegate = self
        CFReadStreamSetDispatchQueue(input as CFReadStream, queue)
        CFWriteStreamSetDispatchQueue(output as CFWriteStream, queue)
        input.open()
        output.open()
    }

    func send(_ data: Data) {
        outBuffer.append(data)
        drain()
    }

    /// Silent close (no onClosed callback) — used when the reducer asked for it.
    func close() {
        finished = true
        teardownStreams()
    }

    func stream(_ aStream: Stream, handle eventCode: Stream.Event) {
        switch eventCode {
        case .hasBytesAvailable:
            readAvailable()
        case .hasSpaceAvailable:
            drain()
        case .errorOccurred:
            finish(reason: aStream.streamError?.localizedDescription ?? "stream error")
        case .endEncountered:
            finish(reason: nil)
        default:
            break
        }
    }

    private func drain() {
        guard !finished, let output = channel.outputStream else { return }
        while output.hasSpaceAvailable, !outBuffer.isEmpty {
            let written = outBuffer.withUnsafeBytes { raw in
                output.write(raw.bindMemory(to: UInt8.self).baseAddress!, maxLength: outBuffer.count)
            }
            if written <= 0 { break }
            outBuffer.removeFirst(written)
        }
    }

    private func readAvailable() {
        guard !finished, let input = channel.inputStream else { return }
        var scratch = [UInt8](repeating: 0, count: 4096)
        while input.hasBytesAvailable {
            let count = input.read(&scratch, maxLength: scratch.count)
            if count > 0 {
                onData(Data(scratch[0..<count]))
            } else if count < 0 {
                finish(reason: input.streamError?.localizedDescription ?? "read error")
                return
            } else {
                break
            }
        }
    }

    private func finish(reason: String?) {
        guard !finished else { return }
        finished = true
        teardownStreams()
        onClosed(reason)
    }

    private func teardownStreams() {
        if let input = channel.inputStream {
            input.close()
            CFReadStreamSetDispatchQueue(input as CFReadStream, nil)
        }
        if let output = channel.outputStream {
            output.close()
            CFWriteStreamSetDispatchQueue(output as CFWriteStream, nil)
        }
    }
}
#endif
```

- [ ] **Step 2: Wire the live dependency**

In `BLEDriver.swift`, replace the inert `liveValue` with:

```swift
extension BLEDriver: DependencyKey {
    public static var liveValue: BLEDriver {
        #if canImport(CoreBluetooth) && (os(iOS) || os(macOS))
        let driver = CoreBluetoothDriver()
        return BLEDriver(
            start: { config in driver.start(config) },
            readDirectory: { peer in driver.readDirectory(peer) },
            openChannel: { peer, psm in driver.openChannel(peer, psm: psm) },
            send: { channel, data in driver.send(channel, data: data) },
            closeChannel: { channel in driver.closeChannel(channel) },
            stop: { driver.stop() }
        )
        #else
        return BLEDriver(start: { _ in .finished }, readDirectory: { _ in },
                         openChannel: { _, _ in }, send: { _, _ in },
                         closeChannel: { _ in }, stop: {})
        #endif
    }
    // (testValue unchanged)
}
```

- [ ] **Step 3: Build and run the full suite**

Run: `swift build`
Expected: clean build (fix any CoreBluetooth API signature drift — the delegate method names above are the canonical ones; do NOT change the event semantics to make it compile, only signatures).
Run: `swift test`
Expected: everything still green (the driver has no automated tests; this catches compile breakage of the package).

- [ ] **Step 4: Write the hardware checklist**

Create `docs/superpowers/plans/2026-08-01-ble-hardware-checklist.md`:

```markdown
# BLE Interface — Hardware Verification Checklist

Manual verification of the live CoreBluetoothDriver (no automated coverage — the
reducer owns all policy and is fully TestStore-tested; this checks the mechanism).
Needs two Apple devices (Mac ↔ iPhone, or two Macs) running a small harness app
that starts a `BLEInterface` store and logs delegate events.

## App prerequisites (consuming app, not this package)
- [ ] `NSBluetoothAlwaysUsageDescription` in Info.plist.
- [ ] (iOS, optional) Background modes `bluetooth-central` + `bluetooth-peripheral`
      if background operation is wanted. Note: a backgrounded iOS advertiser moves
      the service UUID to the overflow area — only iOS centrals scanning for that
      exact UUID will find it; foreground both apps for first bring-up.
- [ ] macOS: Bluetooth entitlement/TCC prompt accepted.

## Bring-up
- [ ] Both devices report `.ready` → status `.online` after `.start`.
- [ ] Each device discovers the other (`.peerDiscovered` within a few seconds).
- [ ] Directory read succeeds: version 2, plausible PSM (> 0).
- [ ] Exactly ONE established channel per pair after HELLO/dedup settles
      (both sides log the SAME surviving direction; the lower-token side's
      outbound channel is the survivor).
- [ ] `.peerOnline` fires with the same 16-byte token on both sides' logs.

## Data plane
- [ ] Small packet (1–100 B) round-trips both directions intact.
- [ ] Max-size packet (1196 B) round-trips intact.
- [ ] Burst of 100 packets arrives complete and in order.

## Churn / recovery
- [ ] Kill the app on device B: device A gets `.peerOffline` within the BLE
      supervision timeout; on relaunch of B the pair re-establishes without
      restarting A.
- [ ] Toggle Bluetooth off on A: A goes `.waitingForAdapter`, peers offline.
      Toggle on: A recovers (`.online`) within the backoff schedule and re-peers.
- [ ] Rapid kill/relaunch of B several times in <10 s windows: A greylists B
      (visible as delayed re-establishment), then recovers after backoff.

## Results
Record throughput/latency observations here for the spec's Reference Values
section once measured.
```

- [ ] **Step 5: Commit**

Write `/tmp/ReTiCA/task8-msg.txt` (subject `feat: live CoreBluetooth BLE driver + hardware checklist`), then:

```bash
git add Sources/ReTiCAInterfaces/CoreBluetoothDriver.swift Sources/ReTiCAInterfaces/BLEDriver.swift docs/superpowers/plans/2026-08-01-ble-hardware-checklist.md
git commit -F /tmp/ReTiCA/task8-msg.txt
```

---

## Final verification (after Task 8)

- [ ] `swift test` — full package green.
- [ ] `git log --format='%(trailers:key=Claude-Session)' -8` — every task commit's trailers parse.
- [ ] Confirm no changes leaked outside `Sources/ReTiCAInterfaces/`, `Tests/ReTiCAInterfacesTests/`, `Package.swift`, and `docs/`.



