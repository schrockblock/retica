# BLE v2.2 GATT Driver (ble-reticulum interop) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace ReTiCA's RBTP v2 BLE stack with ble-reticulum protocol v2.2 (TX/RX/Identity GATT service, 16-byte identity handshake, 5-byte fragmentation) so an iPhone interoperates with a Pi running stock ble-reticulum, with other iPhones, and with Columba.

**Architecture:** Same three layers as today — pure support logic (`BLESupport.swift`), a TCA reducer owning all policy (`BLEInterface.swift`), and a mechanism-only CoreBluetooth adapter behind the `BLEDriver` seam (`FCBDriverAdapter.swift`). The wire protocol changes: GATT characteristics carry fragmented packets instead of an L2CAP stream; the peer key becomes the 16-byte RNS identity hash instead of a random session token. One sibling-package change: FCB's `updateValue` must return CoreBluetooth's `Bool`.

**Tech Stack:** Swift 6 / SwiftPM, swift-composable-architecture (TestStore, TestClock, `@Dependency`), FCBComposable (`../FCB`, CoreBluetooth wrapper), CoreBluetoothMock (integration test), Swift Testing. Python 3 (conda env `rns`) only to generate cross-validation fixtures from the genuine ble-reticulum module.

**Spec:** `docs/superpowers/specs/2026-09-26-ble-v22-gatt-driver-design.md` (read it first; every task below cites its sections).

## Global Constraints

- Two repos: ReTiCA at `/Users/ell/development/ios/pods/ReTiCA` (work on branch `feat/ble-v22`, created in Task 1) and FCB at `/Users/ell/development/ios/pods/FCB` (Task 1 only; branch `feat/update-value-result`). FCB has unrelated uncommitted changes under `Example/` — never `git add -A` there; stage files by name.
- Run tests with `swift test --filter <SuiteOrTestName>` from the package directory. One command per Bash invocation — never chain with `&&`, `|`, `;`. `swift test --filter X` still compiles EVERY test target in the package, so the whole package (all sources, all tests) must compile at the end of every task.
- Every test task follows the mutation discipline: write test → run (fail) → implement → run (pass) → mutate production code → run (all new tests fail) → revert → run (pass) → commit. Each task states its mutations.
- Wire constants (spec §2.1, §2.5, §2.8): service `37145b00-442d-4a94-917f-8f42c5da28e3`, TX `…28e4`, RX `…28e5`, Identity `…28e6`; fragment header 5 bytes `!BHH` (type 1/2/3, uint16 seq, uint16 total, big-endian); MTU floor 20; identity length 16; keepalive `[0x00]` every 15 s outbound only; handshake deadline 10 s; establish deadline 15 s; reassembly stale age 30 s, max 8 in-flight packets per peer; notify FIFO cap 256; held handshake 2 s; `HW_MTU` 500; bitrate 80 000; max peers 7; greylist/churn unchanged.
- No `pairingMode`, no `bleRandomBytes`, no `BLEFraming`/`BLEFrameBuffer`/`BLEHello` survive (spec §2.9, §3.1, §3.2).
- Commit messages: `feat:` / `fix:` / `test:` / `docs:` prefix, then a blank line, then these two trailer lines:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01TRTeyiHdN7Mnmb6e6AifR7`
  Write the message to a file in the scratchpad and commit with `git commit -F <file>`.

## Review Focus

Inputs the spec implies but its own examples do not exercise; each has a pinning test in the task named.

1. **A 16-byte write on an inbound channel that already completed its handshake** must go to the reassembler as a fragment, never be re-read as a handshake (spec §2.4 step 2 says "with no known identity"). Test in Task 5 (`sixteenByteFragmentAfterHandshakeIsData`).
2. **Driver events for a channel the reducer already tore down** (late `channelData`, second `channelClosed`) must be ignored without a delegate emission or a strike. Test in Task 5 (`lateEventsForTornDownChannelAreIgnored`).
3. **A `didReceiveWrite` batch holding several RX writes from one central** must surface as `channelData` events in batch order, each responded to. Test in Task 7 (`writeBatchEmitsEachValueInOrder`).
4. **The same central unsubscribing and re-subscribing to TX** mints a new inbound channel and closes the old one; the reducer treats it as a same-direction duplicate (keep new, no offline blip). Tests in Task 7 (`resubscribeMintsNewChannelAndClosesOld`) and Task 5 (`sameDirectionHandshakeReplacesStaleChannelWithoutOfflineBlip`).
5. **A second sequence-0 fragment for the same `total` while a packet is in flight** restarts that packet's buffer (the reference overwrites on sequence 0) rather than merging two packets. Test in Task 3 (`sequenceZeroRestartsBufferForThatTotal`).

---

### Task 1: FCB `updateValue` returns CoreBluetooth's Bool; ReTiCA branch

**Files:**
- Modify: `/Users/ell/development/ios/pods/FCB/Sources/FCBComposable/BluetoothPeripheralClient.swift:19`
- Modify: `/Users/ell/development/ios/pods/FCB/Sources/FCBComposable/BluetoothPeripheralClient+Live.swift:39,260-267`
- Modify: `/Users/ell/development/ios/pods/FCB/Sources/FCBComposable/BluetoothPeripheralClient+Preview.swift:26`
- Modify: `/Users/ell/development/ios/pods/FCB/Tests/FCBComposableTests/FakePeripheralManager.swift:32-35`
- Test: `/Users/ell/development/ios/pods/FCB/Tests/FCBComposableTests/BluetoothPeripheralClientTests.swift`
- Modify (compile fix only): `/Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift:106`

**Interfaces:**
- Produces: `BluetoothPeripheralClient.updateValue: @Sendable (Data, CBUUID, [UUID]?) async throws -> Bool` — `false` means CoreBluetooth's transmit queue is full; wait for `PeripheralManagerEvent.isReadyToUpdateSubscribers` and retry. Task 8 relies on this.

- [ ] **Step 1: Create the branches**

```bash
git -C /Users/ell/development/ios/pods/FCB switch -c feat/update-value-result
```
```bash
git -C /Users/ell/development/ios/pods/ReTiCA switch -c feat/ble-v22
```

- [ ] **Step 2: Write the failing FCB test**

Append to `BluetoothPeripheralClientServicesTests` in `BluetoothPeripheralClientTests.swift` (inside the struct, after `subscriptionStreamYieldsSubscribeEvent`):

```swift
    @Test func updateValueReturnsManagerResult() async throws {
        let fake = FakePeripheralManager()
        let actor = PeripheralRoleActor(manager: fake)
        try? await Task.sleep(nanoseconds: 50_000_000)   // let wireDelegate run
        let svc = MutableService(id: CBUUID(string: "180F"), isPrimary: true, characteristics: [
            MutableCharacteristic(id: CBUUID(string: "2A19"), properties: .notify, permissions: .readable, value: nil)
        ])
        async let added = actor.add(service: svc)
        try? await Task.sleep(nanoseconds: 50_000_000)
        fake.simulateDidAddService(fake.addedServices[0])
        _ = try await added

        fake.nextUpdateValueResult = true
        #expect(try await actor.updateValue(data: Data([1]), characteristicID: CBUUID(string: "2A19"), centralIDs: nil) == true)
        fake.nextUpdateValueResult = false
        #expect(try await actor.updateValue(data: Data([2]), characteristicID: CBUUID(string: "2A19"), centralIDs: nil) == false)
        #expect(fake.updateValueCalls.count == 2)
    }
```

In `FakePeripheralManager.swift` replace the `updateValue` method with:

```swift
    var nextUpdateValueResult = true
    func updateValue(_ value: Data, for characteristic: CBMutableCharacteristic, onSubscribedCentrals centrals: [CBCentral]?) -> Bool {
        updateValueCalls.append((value, characteristic, centrals))
        return nextUpdateValueResult
    }
```

- [ ] **Step 3: Run it to verify it fails**

Run (in `/Users/ell/development/ios/pods/FCB`): `swift test --filter updateValueReturnsManagerResult`
Expected: compile error — `actor.updateValue(...)` returns `Void`, cannot compare to `Bool`.

- [ ] **Step 4: Implement**

`BluetoothPeripheralClient.swift` line 19:
```swift
    public var updateValue: @Sendable (_ data: Data, _ characteristicID: CBUUID, _ centralIDs: [UUID]?) async throws -> Bool
```
`BluetoothPeripheralClient+Live.swift` line 260–267:
```swift
    func updateValue(data: Data, characteristicID: CBUUID, centralIDs: [UUID]?) async throws -> Bool {
        try preflightCheck()
        guard let char = characteristics[characteristicID] else {
            throw BluetoothError.unknownCharacteristic(characteristicID, serviceID: CBUUID())
        }
        let cbCentrals: [CBCentral]? = centralIDs?.compactMap { centrals[$0] }
        return manager.updateValue(data, for: char, onSubscribedCentrals: cbCentrals)
    }
```
Line 39 is unchanged in text (`try await actor.updateValue(...)`) — it now returns the Bool.
`BluetoothPeripheralClient+Preview.swift` line 26: `updateValue: { _, _, _ in true },`

- [ ] **Step 5: Run FCB tests**

Run: `swift test --filter BluetoothPeripheralClient`
Expected: all PASS, including `updateValueReturnsManagerResult`.

- [ ] **Step 6: Mutate, verify failure, revert**

Mutation: in `+Live.swift` change `return manager.updateValue(...)` to `_ = manager.updateValue(...); return true`. Run `swift test --filter updateValueReturnsManagerResult` — expected FAIL (second expectation). Revert. Run again — PASS.

- [ ] **Step 7: Keep ReTiCA compiling**

In `/Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift` line 106 change `updateValue: { _, _, _ in },` to `updateValue: { _, _, _ in true },`. Run (in ReTiCA): `swift build --build-tests` — expected: succeeds.

- [ ] **Step 8: Commit both repos**

FCB: `git -C /Users/ell/development/ios/pods/FCB add Sources/FCBComposable/BluetoothPeripheralClient.swift Sources/FCBComposable/BluetoothPeripheralClient+Live.swift Sources/FCBComposable/BluetoothPeripheralClient+Preview.swift Tests/FCBComposableTests/FakePeripheralManager.swift Tests/FCBComposableTests/BluetoothPeripheralClientTests.swift` then commit: `feat: updateValue returns CoreBluetooth's queue-full Bool`.
ReTiCA: `git -C /Users/ell/development/ios/pods/ReTiCA add Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift` then commit: `test: follow FCB updateValue Bool signature`.

---

### Task 2: Pure fragmenter (`BLEFragmenter`) and protocol constants

**Files:**
- Modify: `Sources/ReTiCAInterfaces/BLESupport.swift` (append; do NOT delete framing/HELLO yet — Task 5 removes them)
- Test: `Tests/ReTiCAInterfacesTests/BLESupportTests.swift` (append)

**Interfaces:**
- Produces:
  ```swift
  public enum BLEProtocol {   // string UUIDs so this file stays CoreBluetooth-free
      public static let serviceUUID  = "37145b00-442d-4a94-917f-8f42c5da28e3"
      public static let txCharUUID   = "37145b00-442d-4a94-917f-8f42c5da28e4"
      public static let rxCharUUID   = "37145b00-442d-4a94-917f-8f42c5da28e5"
      public static let identityCharUUID = "37145b00-442d-4a94-917f-8f42c5da28e6"
      public static let identityLength = 16
  }
  public enum BLEFragmentType: UInt8 { case start = 1, cont = 2, end = 3 }
  public enum BLEFragmentError: Error, Equatable { case emptyPacket, tooManyFragments(Int) }
  public struct BLEFragmenter: Equatable, Sendable {
      public static let headerLength = 5
      public static let minimumMTU = 20
      public let mtu: Int                     // floored at minimumMTU
      public var payloadSize: Int { mtu - Self.headerLength }
      public init(mtu: Int)
      public func fragment(_ packet: Data) throws -> [Data]
  }
  ```

- [ ] **Step 1: Write the failing tests**

Append to `BLESupportTests.swift`:

```swift
// MARK: - Fragmenter (ble-reticulum v2.2)

@Test func singleFragmentPacketIsStartWithTotalOne() throws {
    let f = BLEFragmenter(mtu: 185)
    let packet = Data([0xAA, 0xBB, 0xCC])
    let frags = try f.fragment(packet)
    #expect(frags == [Data([0x01, 0x00, 0x00, 0x00, 0x01, 0xAA, 0xBB, 0xCC])])
}

@Test func multiFragmentPacketHasStartContinueEndHeaders() throws {
    let f = BLEFragmenter(mtu: 23)                 // payload 18
    #expect(f.payloadSize == 18)
    let packet = Data((0..<40).map { UInt8($0) })  // 18 + 18 + 4 → 3 fragments
    let frags = try f.fragment(packet)
    #expect(frags.count == 3)
    #expect(frags[0].prefix(5) == Data([0x01, 0x00, 0x00, 0x00, 0x03]))
    #expect(frags[1].prefix(5) == Data([0x02, 0x00, 0x01, 0x00, 0x03]))
    #expect(frags[2].prefix(5) == Data([0x03, 0x00, 0x02, 0x00, 0x03]))
    #expect(frags[0].dropFirst(5) == packet[0..<18])
    #expect(frags[1].dropFirst(5) == packet[18..<36])
    #expect(frags[2].dropFirst(5) == packet[36..<40])
}

@Test func exactMultipleOfPayloadNeedsNoExtraFragment() throws {
    let f = BLEFragmenter(mtu: 23)
    let frags = try f.fragment(Data(repeating: 0x5A, count: 36))
    #expect(frags.count == 2)
    #expect(frags[1][frags[1].startIndex] == 0x03)   // END, not CONTINUE
}

@Test func mtuIsFlooredAtTwenty() {
    #expect(BLEFragmenter(mtu: 3).mtu == 20)
    #expect(BLEFragmenter(mtu: 3).payloadSize == 15)
    #expect(BLEFragmenter(mtu: 517).payloadSize == 512)
}

@Test func fragmentRejectsEmptyPacket() {
    #expect(throws: BLEFragmentError.emptyPacket) { try BLEFragmenter(mtu: 185).fragment(Data()) }
}

@Test func fragmentRejectsMoreThan65535Fragments() {
    // mtu 20 → payload 15; 65 536 × 15 bytes needs 65 536 fragments.
    let packet = Data(repeating: 0, count: 65_536 * 15)
    #expect(throws: BLEFragmentError.tooManyFragments(65_536)) { try BLEFragmenter(mtu: 20).fragment(packet) }
}

@Test func sequenceAndTotalAreBigEndianUInt16() throws {
    // 300 fragments of 15 bytes: sequence 299 = 0x012B, total 300 = 0x012C.
    let frags = try BLEFragmenter(mtu: 20).fragment(Data(repeating: 1, count: 300 * 15))
    #expect(frags[299].prefix(5) == Data([0x03, 0x01, 0x2B, 0x01, 0x2C]))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BLESupportTests`
Expected: compile error, `BLEFragmenter` not found.

- [ ] **Step 3: Implement**

Append to `BLESupport.swift`:

```swift
// MARK: - ble-reticulum protocol v2.2

/// Wire constants for ble-reticulum protocol v2.2 (BLE_PROTOCOL_v2.2.md §UUID Reference).
/// Strings, not CBUUIDs, so this file stays free of CoreBluetooth.
public enum BLEProtocol {
    public static let serviceUUID      = "37145b00-442d-4a94-917f-8f42c5da28e3"
    public static let txCharUUID       = "37145b00-442d-4a94-917f-8f42c5da28e4"
    public static let rxCharUUID       = "37145b00-442d-4a94-917f-8f42c5da28e5"
    public static let identityCharUUID = "37145b00-442d-4a94-917f-8f42c5da28e6"
    public static let identityLength   = 16
}

public enum BLEFragmentType: UInt8, Sendable {
    case start = 0x01, cont = 0x02, end = 0x03
}

public enum BLEFragmentError: Error, Equatable {
    case emptyPacket
    case tooManyFragments(Int)
}

/// Port of ble_reticulum.BLEFragmentation.BLEFragmenter. Every packet — even one that fits in a
/// single fragment — is sent with the 5-byte header `!BHH` (type, sequence, total).
public struct BLEFragmenter: Equatable, Sendable {
    public static let headerLength = 5
    public static let minimumMTU = 20
    public static let maxFragments = 65_535

    public let mtu: Int
    public var payloadSize: Int { mtu - Self.headerLength }

    public init(mtu: Int) {
        self.mtu = max(mtu, Self.minimumMTU)
    }

    public func fragment(_ packet: Data) throws -> [Data] {
        guard !packet.isEmpty else { throw BLEFragmentError.emptyPacket }
        let count = (packet.count + payloadSize - 1) / payloadSize
        guard count <= Self.maxFragments else { throw BLEFragmentError.tooManyFragments(count) }
        let bytes = Data(packet)   // rebase indices to 0
        var out: [Data] = []
        out.reserveCapacity(count)
        for i in 0..<count {
            let type: BLEFragmentType = (i == 0) ? .start : (i == count - 1 ? .end : .cont)
            var frag = Data([type.rawValue,
                             UInt8(i >> 8), UInt8(i & 0xFF),
                             UInt8(count >> 8), UInt8(count & 0xFF)])
            let start = i * payloadSize
            frag.append(bytes[start ..< min(start + payloadSize, bytes.count)])
            out.append(frag)
        }
        return out
    }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter BLESupportTests` — expected: all PASS.

- [ ] **Step 5: Mutate, verify, revert**

Mutations (one batch): (a) `let type ... ? .start : (i == count - 1 ? .end : .cont)` → always `.start`; (b) `max(mtu, Self.minimumMTU)` → `mtu`; (c) header bytes `UInt8(i >> 8), UInt8(i & 0xFF)` → swap to little-endian. Run `swift test --filter BLESupportTests` — expected: `multiFragmentPacketHasStartContinueEndHeaders`, `exactMultipleOfPayloadNeedsNoExtraFragment`, `mtuIsFlooredAtTwenty`, `sequenceAndTotalAreBigEndianUInt16` FAIL. Revert all three. Run — all PASS.

- [ ] **Step 6: Commit**

`git add Sources/ReTiCAInterfaces/BLESupport.swift Tests/ReTiCAInterfacesTests/BLESupportTests.swift` — message `feat: BLE v2.2 fragmenter and protocol constants`.

---
### Task 3: Pure reassembler (`BLEReassembler`) and keepalive predicate

**Files:**
- Modify: `Sources/ReTiCAInterfaces/BLESupport.swift` (append)
- Test: `Tests/ReTiCAInterfacesTests/BLESupportTests.swift` (append)

**Interfaces:**
- Consumes: `BLEFragmenter`, `BLEFragmentType` (Task 2).
- Produces:
  ```swift
  public enum BLEReassemblyError: Error, Equatable {
      case tooShort(Int), badType(UInt8), badSequence(UInt16, total: UInt16), zeroTotal,
           totalMismatch(expected: UInt16, got: UInt16), conflictingDuplicate(UInt16)
  }
  public struct BLEReassembler: Equatable, Sendable {
      public static let staleAge: TimeInterval = 30
      public static let maxInFlight = 8
      public init()
      public mutating func receive(_ fragment: Data, now: Date) throws -> Data?
      public var inFlightCount: Int { get }
  }
  public enum BLEKeepalive {
      public static let frame = Data([0x00])
      public static func isKeepalive(_ data: Data) -> Bool
  }
  ```
  Semantics (port of `BLEReassembler.receive_fragment`): buffers are keyed by `total`; a sequence-0 fragment starts (or restarts) the buffer for its `total`; other sequences join the buffer with that `total`, creating an empty one if absent; complete when all `0..<total` are present. `totalMismatch` cannot occur under this keying and is thrown only if a buffer's stored total disagrees (kept for parity/safety).

- [ ] **Step 1: Write the failing tests**

Append to `BLESupportTests.swift`:

```swift
// MARK: - Reassembler (ble-reticulum v2.2)

private let t0 = Date(timeIntervalSince1970: 10_000)

@Test func reassemblesInOrderFragmentsIntoOnePacket() throws {
    let packet = Data((0..<40).map { UInt8($0) })
    let frags = try BLEFragmenter(mtu: 23).fragment(packet)
    var r = BLEReassembler()
    #expect(try r.receive(frags[0], now: t0) == nil)
    #expect(try r.receive(frags[1], now: t0) == nil)
    #expect(try r.receive(frags[2], now: t0) == packet)
    #expect(r.inFlightCount == 0)
}

@Test func singleFragmentPacketCompletesImmediately() throws {
    var r = BLEReassembler()
    let frag = try BLEFragmenter(mtu: 185).fragment(Data([9, 8, 7]))[0]
    #expect(try r.receive(frag, now: t0) == Data([9, 8, 7]))
}

@Test func outOfOrderFragmentsStillComplete() throws {
    let packet = Data(repeating: 0x33, count: 50)
    let frags = try BLEFragmenter(mtu: 23).fragment(packet)   // 3 fragments
    var r = BLEReassembler()
    #expect(try r.receive(frags[2], now: t0) == nil)   // arrives before sequence 0
    #expect(try r.receive(frags[0], now: t0) == nil)
    #expect(try r.receive(frags[1], now: t0) == packet)
}

@Test func identicalDuplicateFragmentIsIgnored() throws {
    let packet = Data(repeating: 0x44, count: 30)
    let frags = try BLEFragmenter(mtu: 23).fragment(packet)   // 2 fragments
    var r = BLEReassembler()
    _ = try r.receive(frags[0], now: t0)
    _ = try r.receive(frags[0], now: t0)                      // retransmit, harmless
    #expect(try r.receive(frags[1], now: t0) == packet)
}

@Test func conflictingDuplicateThrowsAndDiscardsBuffer() throws {
    // A 3-fragment packet so the conflict happens mid-flight.
    var r = BLEReassembler()
    let big = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0x55, count: 50))
    _ = try r.receive(big[0], now: t0)
    var altered = big[0]; altered[altered.startIndex + 5] = 0x99
    #expect(throws: BLEReassemblyError.conflictingDuplicate(0)) { _ = try r.receive(altered, now: t0) }
    #expect(r.inFlightCount == 0)   // buffer discarded
}

@Test func malformedFragmentsThrowWithoutTouchingOtherBuffers() throws {
    var r = BLEReassembler()
    let big = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0x55, count: 50))
    _ = try r.receive(big[0], now: t0)
    #expect(throws: BLEReassemblyError.tooShort(4)) { _ = try r.receive(Data([1, 0, 0, 0]), now: t0) }
    #expect(throws: BLEReassemblyError.badType(0x07)) { _ = try r.receive(Data([7, 0, 0, 0, 1, 0xAA]), now: t0) }
    #expect(throws: BLEReassemblyError.badSequence(3, total: 3)) { _ = try r.receive(Data([2, 0, 3, 0, 3, 0xAA]), now: t0) }
    #expect(throws: BLEReassemblyError.zeroTotal) { _ = try r.receive(Data([1, 0, 0, 0, 0, 0xAA]), now: t0) }
    #expect(r.inFlightCount == 1)   // the in-flight packet survived the junk
}

@Test func sequenceZeroRestartsBufferForThatTotal() throws {
    // Review Focus 5: a fresh START for the same total replaces the partial packet.
    let a = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0xA1, count: 50))
    let b = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0xB2, count: 50))
    var r = BLEReassembler()
    _ = try r.receive(a[0], now: t0)
    _ = try r.receive(a[1], now: t0)
    _ = try r.receive(b[0], now: t0)          // restart
    #expect(try r.receive(b[1], now: t0) == nil)
    #expect(try r.receive(b[2], now: t0) == Data(repeating: 0xB2, count: 50))
    #expect(r.inFlightCount == 0)
}

@Test func twoPacketsWithDifferentTotalsInterleave() throws {
    let a = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0xA1, count: 50))  // 3 frags
    let b = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0xB2, count: 30))  // 2 frags
    var r = BLEReassembler()
    _ = try r.receive(a[0], now: t0)
    _ = try r.receive(b[0], now: t0)
    #expect(r.inFlightCount == 2)
    #expect(try r.receive(b[1], now: t0) == Data(repeating: 0xB2, count: 30))
    _ = try r.receive(a[1], now: t0)
    #expect(try r.receive(a[2], now: t0) == Data(repeating: 0xA1, count: 50))
}

@Test func staleBuffersArePurgedWhenAPacketCompletes() throws {
    var r = BLEReassembler()
    let stale = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 0x11, count: 50))
    _ = try r.receive(stale[0], now: t0)
    let later = t0.addingTimeInterval(BLEReassembler.staleAge + 1)
    let quick = try BLEFragmenter(mtu: 185).fragment(Data([1]))[0]
    #expect(try r.receive(quick, now: later) == Data([1]))
    #expect(r.inFlightCount == 0)   // stale 3-fragment packet purged on completion
}

@Test func ninthInFlightPacketEvictsTheOldest() throws {
    var r = BLEReassembler()
    // Nine partial packets with distinct totals 2...10 (one START each).
    for total in 2...10 {
        let size = (total - 1) * 18 + 1            // exactly `total` fragments at payload 18
        let frags = try BLEFragmenter(mtu: 23).fragment(Data(repeating: UInt8(total), count: size))
        _ = try r.receive(frags[0], now: t0.addingTimeInterval(Double(total)))
    }
    #expect(r.inFlightCount == BLEReassembler.maxInFlight)
    // The oldest (total 2) was evicted: its END now lands in a fresh, incomplete buffer.
    let two = try BLEFragmenter(mtu: 23).fragment(Data(repeating: 2, count: 19))
    #expect(try r.receive(two[1], now: t0.addingTimeInterval(20)) == nil)
}

@Test func keepalivePredicateMatchesOnlyASingleZeroByte() {
    #expect(BLEKeepalive.isKeepalive(Data([0x00])))
    #expect(BLEKeepalive.frame == Data([0x00]))
    #expect(!BLEKeepalive.isKeepalive(Data([0x01])))
    #expect(!BLEKeepalive.isKeepalive(Data([0x00, 0x00])))
    #expect(!BLEKeepalive.isKeepalive(Data()))
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter BLESupportTests` — expected: compile error, `BLEReassembler` not found.

- [ ] **Step 3: Implement**

Append to `BLESupport.swift`:

```swift
public enum BLEReassemblyError: Error, Equatable {
    case tooShort(Int)
    case badType(UInt8)
    case badSequence(UInt16, total: UInt16)
    case zeroTotal
    case totalMismatch(expected: UInt16, got: UInt16)
    case conflictingDuplicate(UInt16)
}

/// Port of ble_reticulum.BLEFragmentation.BLEReassembler for ONE peer. Buffers are keyed by
/// `total` exactly as the reference does (its packet_key collapses to (sender, 0, total)):
/// sequence 0 starts or restarts the buffer for that total; other sequences join it.
/// Bounded: at most `maxInFlight` buffers (oldest evicted) and a stale purge on completion.
public struct BLEReassembler: Equatable, Sendable {
    public static let staleAge: TimeInterval = 30
    public static let maxInFlight = 8

    private struct Buffer: Equatable, Sendable {
        var fragments: [UInt16: Data] = [:]
        var total: UInt16
        var startedAt: Date
    }
    private var buffers: [UInt16: Buffer] = [:]

    public init() {}

    public var inFlightCount: Int { buffers.count }

    public mutating func receive(_ fragment: Data, now: Date) throws -> Data? {
        let f = Data(fragment)
        guard f.count >= BLEFragmenter.headerLength else { throw BLEReassemblyError.tooShort(f.count) }
        guard BLEFragmentType(rawValue: f[0]) != nil else { throw BLEReassemblyError.badType(f[0]) }
        let sequence = UInt16(f[1]) << 8 | UInt16(f[2])
        let total = UInt16(f[3]) << 8 | UInt16(f[4])
        guard total != 0 else { throw BLEReassemblyError.zeroTotal }
        guard sequence < total else { throw BLEReassemblyError.badSequence(sequence, total: total) }
        let payload = Data(f[BLEFragmenter.headerLength...])

        if sequence == 0 {
            buffers[total] = Buffer(fragments: [0: payload], total: total, startedAt: now)
        } else {
            if buffers[total] == nil {
                buffers[total] = Buffer(fragments: [:], total: total, startedAt: now)
            }
            guard buffers[total]!.total == total else {
                let expected = buffers[total]!.total
                buffers[total] = nil
                throw BLEReassemblyError.totalMismatch(expected: expected, got: total)
            }
            if let existing = buffers[total]!.fragments[sequence] {
                if existing == payload { return nil }          // benign retransmit
                buffers[total] = nil
                throw BLEReassemblyError.conflictingDuplicate(sequence)
            }
            buffers[total]!.fragments[sequence] = payload
        }
        evictIfOverCapacity()

        guard let buffer = buffers[total], buffer.fragments.count == Int(total) else { return nil }
        var packet = Data()
        for i in 0..<total {
            guard let part = buffer.fragments[i] else { return nil }
            packet.append(part)
        }
        buffers[total] = nil
        purgeStale(now: now)
        return packet
    }

    private mutating func evictIfOverCapacity() {
        while buffers.count > Self.maxInFlight {
            guard let oldest = buffers.min(by: { $0.value.startedAt < $1.value.startedAt }) else { return }
            buffers[oldest.key] = nil
        }
    }

    private mutating func purgeStale(now: Date) {
        buffers = buffers.filter { now.timeIntervalSince($0.value.startedAt) <= Self.staleAge }
    }
}

/// Columba's 1-byte keepalive; every ble-reticulum peer filters it before reassembly.
public enum BLEKeepalive {
    public static let frame = Data([0x00])
    public static func isKeepalive(_ data: Data) -> Bool { data.count == 1 && data[data.startIndex] == 0x00 }
}
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter BLESupportTests` — expected: all PASS.

- [ ] **Step 5: Mutate, verify, revert**

Mutations in one batch: (a) `if existing == payload { return nil }` → `if true { return nil }` (conflict no longer throws); (b) in `sequence == 0` branch, merge instead of restart: `buffers[total, default: Buffer(fragments: [:], total: total, startedAt: now)].fragments[0] = payload`; (c) `purgeStale` body → no-op; (d) `evictIfOverCapacity` → no-op. Run `swift test --filter BLESupportTests` — expected FAIL: `conflictingDuplicateThrowsAndDiscardsBuffer`, `sequenceZeroRestartsBufferForThatTotal`, `staleBuffersArePurgedWhenAPacketCompletes`, `ninthInFlightPacketEvictsTheOldest`. Revert all. Run — all PASS.

- [ ] **Step 6: Commit**

`git add Sources/ReTiCAInterfaces/BLESupport.swift Tests/ReTiCAInterfacesTests/BLESupportTests.swift` — `feat: BLE v2.2 per-peer reassembler and keepalive predicate`.

---

### Task 4: Cross-validation fixtures from the genuine ble-reticulum module

**Files:**
- Create (outside repo, once): checkout of ble-reticulum at `/Users/ell/development/python/ble-reticulum`
- Modify: `Tests/ReTiCAInterfacesTests/Vectors/generate_ble_fixtures.py`
- Regenerate: `Tests/ReTiCAInterfacesTests/Vectors/ble_fixtures.json`
- Modify: `Tests/ReTiCAInterfacesTests/BLEFixtureTests.swift`

**Interfaces:**
- Consumes: `BLEFragmenter`, `BLEReassembler`, `BLEPeerGreylist` (Tasks 2–3, existing).
- Produces: fixture JSON keys `fragmentation` (array of `{mtu, packet, fragments[]}` hex), `reassembly` (`{mtu, order[], fragments[], packet}` — fragments listed in delivery order, `packet` is the expected result), `reassembly_conflict` (`{fragments[], throws: true}`), `greylist_ops` (unchanged).

- [ ] **Step 1: Check out the reference at a pinned commit**

```bash
git clone https://github.com/torlando-tech/ble-reticulum /Users/ell/development/python/ble-reticulum
```
```bash
git -C /Users/ell/development/python/ble-reticulum checkout 07d941304c9a1dc3a8e58087b3b974ff3d229e56
```

- [ ] **Step 2: Rewrite the generator**

Replace the whole of `generate_ble_fixtures.py` with:

```python
#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path (from the Vectors directory):
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_ble_fixtures.py > ble_fixtures.json
#
# Drives the GENUINE reference modules by file path so the Swift ports are validated
# against real code, not a hand-rolled reimplementation:
#   - fragmentation: torlando-tech/ble-reticulum BLEFragmentation.py (pinned checkout)
#   - greylist:      the Reticulum fork's ble_support.py (dependency-free)
import importlib.util
import json
import random
import sys

# BLEFragmentation logs through RNS when importable; RNS.log writes to STDOUT, which would
# corrupt the JSON. Make `import RNS` fail so the module takes its RNS = None branch.
sys.modules["RNS"] = None

FRAG = "/Users/ell/development/python/ble-reticulum/src/ble_reticulum/BLEFragmentation.py"
BLE_SUPPORT = "/Users/ell/development/python/Reticulum/RNS/Interfaces/util/ble_support.py"

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

frag = load("BLEFragmentation", FRAG)
ble = load("ble_support", BLE_SUPPORT)

def pattern(n, seed):
    return bytes((i * 7 + seed) % 256 for i in range(n))

packets = [pattern(1, 3), pattern(15, 5), pattern(16, 9), pattern(40, 11),
           pattern(233, 13), pattern(500, 17)]
mtus = [20, 23, 185, 517]
fragmentation = []
for mtu in mtus:
    f = frag.BLEFragmenter(mtu=mtu)
    for p in packets:
        fragmentation.append({"mtu": mtu, "packet": p.hex(),
                              "fragments": [x.hex() for x in f.fragment_packet(p)]})

# Reassembly scenario: a 500-byte packet at MTU 23 with sequence 0 first and the REST shuffled,
# plus one benign duplicate; the reference reassembler must return the packet on the last
# fragment. Sequence 0 must lead: the reference restarts the buffer on sequence 0, discarding
# anything received before it (so a fully shuffled order can never complete).
rng = random.Random(2026)
big = pattern(500, 19)
frags = frag.BLEFragmenter(mtu=23).fragment_packet(big)
rest = list(range(1, len(frags)))
rng.shuffle(rest)
delivery = [frags[0]] + [frags[i] for i in rest]
delivery.insert(5, delivery[2])            # duplicate of an earlier fragment
r = frag.BLEReassembler()
result = None
for i, x in enumerate(delivery):
    got = r.receive_fragment(x, "peer")
    assert (got is not None) == (i == len(delivery) - 1), "reference reassembly sanity"
    if got is not None:
        result = got
assert result == big
reassembly = {"mtu": 23, "fragments": [x.hex() for x in delivery], "packet": big.hex()}

# Conflict: same sequence, different bytes → the reference raises ValueError.
r2 = frag.BLEReassembler()
three = frag.BLEFragmenter(mtu=23).fragment_packet(pattern(50, 23))
r2.receive_fragment(three[0], "peer")
r2.receive_fragment(three[1], "peer")
bad = bytearray(three[1]); bad[5] ^= 0xFF; bad = bytes(bad)
threw = False
try:
    r2.receive_fragment(bad, "peer")
except ValueError:
    threw = True
assert threw
reassembly_conflict = {"fragments": [three[0].hex(), three[1].hex(), bad.hex()], "throws": True}

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
probe(4.9); probe(5.0); probe(5.01)
fail(10.0)
probe(19.9); probe(20.0); probe(20.01)
for t in (30.0, 40.0, 50.0, 60.0, 70.0, 80.0):
    fail(t)
probe(380.0); probe(380.01)
fail(1000.0)
probe(1005.0); probe(1005.01)

print(json.dumps({
    "fragmentation": fragmentation,
    "reassembly": reassembly,
    "reassembly_conflict": reassembly_conflict,
    "greylist_ops": ops,
}, indent=2))
```

- [ ] **Step 3: Regenerate the JSON**

Run from `Tests/ReTiCAInterfacesTests/Vectors`:
`/Users/ell/opt/anaconda3/envs/rns/bin/python generate_ble_fixtures.py > ble_fixtures.json`
Expected: no assertion error; `head -c 300 ble_fixtures.json` starts with `{ "fragmentation": [`. If the file contains any non-JSON line, the RNS stdout guard failed — stop and diagnose.

- [ ] **Step 4: Rewrite the fixture tests**

Replace `BLEFixtureTests.swift` with:

```swift
import Testing
import Foundation
@testable import ReTiCAInterfaces

private struct BLEFixtures: Decodable {
    struct FragCase: Decodable { let mtu: Int; let packet: String; let fragments: [String] }
    struct Reassembly: Decodable { let mtu: Int; let fragments: [String]; let packet: String }
    struct Conflict: Decodable { let fragments: [String]; let throws: Bool }
    struct GreylistOp: Decodable { let op: String; let t: Double; let blocked: Bool? }
    let fragmentation: [FragCase]
    let reassembly: Reassembly
    let reassemblyConflict: Conflict
    let greylistOps: [GreylistOp]

    enum CodingKeys: String, CodingKey {
        case fragmentation, reassembly
        case reassemblyConflict = "reassembly_conflict"
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

@Test func fragmentationMatchesReferencePythonByteForByte() throws {
    let fixtures = try BLEFixtures.load()
    #expect(fixtures.fragmentation.count == 24)   // 4 MTUs × 6 packets
    for c in fixtures.fragmentation {
        let got = try BLEFragmenter(mtu: c.mtu).fragment(dataFromHex(c.packet))
        #expect(got == c.fragments.map(dataFromHex), "mtu \(c.mtu) packet \(c.packet.count / 2) B")
        // And our reassembler re-ingests the reference fragments to the reference packet.
        var r = BLEReassembler()
        var out: Data?
        for f in c.fragments { out = try r.receive(dataFromHex(f), now: Date()) }
        #expect(out == dataFromHex(c.packet))
    }
}

@Test func reassemblyMatchesReferenceOnShuffledDeliveryWithDuplicate() throws {
    let fixtures = try BLEFixtures.load()
    var r = BLEReassembler()
    let frags = fixtures.reassembly.fragments.map(dataFromHex)
    for (i, f) in frags.enumerated() {
        let got = try r.receive(f, now: Date())
        if i < frags.count - 1 { #expect(got == nil, "completed early at \(i)") }
        else { #expect(got == dataFromHex(fixtures.reassembly.packet)) }
    }
}

@Test func conflictingDuplicateThrowsLikeTheReference() throws {
    let fixtures = try BLEFixtures.load()
    let frags = fixtures.reassemblyConflict.fragments.map(dataFromHex)
    var r = BLEReassembler()
    _ = try r.receive(frags[0], now: Date())
    _ = try r.receive(frags[1], now: Date())
    #expect(throws: BLEReassemblyError.self) { _ = try r.receive(frags[2], now: Date()) }
}

@Test func greylistArithmeticMatchesReferencePython() throws {
    let fixtures = try BLEFixtures.load()
    var greylist = BLEPeerGreylist<String>()
    for op in fixtures.greylistOps {
        let now = Date(timeIntervalSince1970: op.t)
        switch op.op {
        case "fail":  greylist.recordFailure("peer", now: now)
        case "probe": #expect(greylist.isBlocked("peer", now: now) == op.blocked!, "probe at t=\(op.t)")
        default:      Issue.record("unknown op \(op.op)")
        }
    }
}
```

- [ ] **Step 5: Run**

Run: `swift test --filter BLEFixtureTests` — expected: all PASS. If `fragmentationMatchesReferencePythonByteForByte` fails on a specific MTU, the Swift port diverges from the reference — fix `BLEFragmenter`, not the fixture.

- [ ] **Step 6: Mutate, verify, revert**

Mutation batch: in `BLEFragmenter.fragment` make the last fragment `.cont` instead of `.end`; in `BLEReassembler.receive` change `if existing == payload { return nil }` to `if existing == payload { throw BLEReassemblyError.conflictingDuplicate(sequence) }`. Run `swift test --filter BLEFixtureTests` — expected FAIL: `fragmentationMatchesReferencePythonByteForByte`, `reassemblyMatchesReferenceOnShuffledDeliveryWithDuplicate`. Revert. Run — all PASS. Then `swift test --filter ReTiCAInterfacesTests` — all PASS (RBTP tests still present and green).

- [ ] **Step 7: Commit**

`git add Tests/ReTiCAInterfacesTests/Vectors/generate_ble_fixtures.py Tests/ReTiCAInterfacesTests/Vectors/ble_fixtures.json Tests/ReTiCAInterfacesTests/BLEFixtureTests.swift` — `test: cross-validate fragmentation against genuine ble-reticulum`.

---
### Task 5: Driver seam + reducer on v2.2 (identity handshake, fragmented data plane)

This is the pivot task: the seam, the reducer, the endpoint state and every test that touches them change together so the package compiles at the end. The RBTP adapter and its tests are deleted here (Tasks 6–8 recreate the adapter for v2.2); `BLEDriver.liveValue` is temporarily the inert stub.

**Files:**
- Rewrite: `Sources/ReTiCAInterfaces/BLEDriver.swift`
- Rewrite: `Sources/ReTiCAInterfaces/BLEInterface.swift`
- Modify: `Sources/ReTiCAInterfaces/BLESupport.swift` (delete `BLEFramingError`, `BLEFraming`, `BLEFrameBuffer`, `BLEHello`)
- Delete: `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift`, `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift`, `Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMTests.swift`
- Modify: `Sources/ReTiCANode/BLEEndpoint.swift`
- Modify: `Sources/ReTiCA/Packet/Packet.swift:77` (comment only)
- Rewrite: `Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift`
- Modify: `Tests/ReTiCAInterfacesTests/BLESupportTests.swift` (delete the Framing and HELLO sections)
- Modify: `Tests/ReTiCANodeTests/EndpointTestSupport.swift`, `BLEEndpointIntegrationTests.swift`, `BLEEndpointLinkTests.swift`, `LXMFNodeBLETests.swift`, `TransportEndpointCharacterizationTests.swift`, `TransportEndpointTests.swift`, `Tests/ReTiCATests/Packet/PacketTests.swift:87` (comment)

**Interfaces:**
- Consumes: `BLEProtocol`, `BLEFragmenter`, `BLEReassembler`, `BLEKeepalive`, `BLEPeerGreylist`, `bleResolveDuplicate`.
- Produces (Tasks 6–9 and the node layer build on these exact names):
  ```swift
  public struct BLEDriverConfig: Equatable, Sendable { public var localIdentity: Data }
  public enum BLEDriverEvent: Equatable, Sendable {
      case ready
      case unavailable(BLEAdapterUnavailable)
      case peerDiscovered(BLEPeerHandle)
      case identityRead(BLEPeerHandle, identity: Data)
      case identityFailed(BLEPeerHandle, reason: String?)
      case channelOpened(BLEChannelID, BLEPeerHandle, direction: BLEChannelDirection, mtu: Int)
      case channelFailed(BLEPeerHandle, reason: String?)
      case channelData(BLEChannelID, Data)
      case channelClosed(BLEChannelID, reason: String?)
  }
  public struct BLEDriver { start, readIdentity(BLEPeerHandle), openChannel(BLEPeerHandle),
                            send(BLEChannelID, Data), closeChannel(BLEChannelID),
                            disconnect(BLEPeerHandle), stop }
  BLEInterface.State.init(localIdentity: Data, maxPeers: Int = 7, keepaliveInterval: Duration? = .seconds(15))
  BLEInterface.Action: .start, .stop, .driverEvent, .send(peer:packet:), .handshakeDeadline(BLEChannelID),
                       .establishDeadline(BLEPeerHandle), .keepalive(BLEChannelID), .adapterRetry, .delegate
  BLEInterface.Action.SendFailedReason.unfragmentable
  BLEInterface.handshakeTimeout: Duration = .seconds(10)
  BLEEndpoint.State.init(localIdentity: Data, maxPeers: Int = 7, profile: InterfaceProfile = .ble)
  ```
  Delegate surface (`peerOnline(Data)`, `peerOffline(Data)`, `packetReceived(peer:packet:)`, `sendFailed`, `adapterUnavailable`) keeps its shape; the `Data` is now the peer's 16-byte identity.

- [ ] **Step 1: Replace `BLEDriver.swift`**

```swift
import Foundation
import ComposableArchitecture

/// Locally-scoped handle for a remote device (wraps the CBPeer UUID). Pre-handshake identity —
/// plays the role the BLE address plays in ble-reticulum's Python.
public struct BLEPeerHandle: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

/// Opaque per-channel handle minted by the driver.
public struct BLEChannelID: Hashable, Sendable {
    public let id: UUID
    public init(id: UUID) { self.id = id }
}

public struct BLEDriverConfig: Equatable, Sendable {
    /// 16 bytes: served on the Identity characteristic and written as the handshake.
    public var localIdentity: Data
    public init(localIdentity: Data) { self.localIdentity = localIdentity }
}

/// Why the BLE adapter is unavailable. `isTerminal` separates causes retrying cannot fix
/// (`unauthorized`, `unsupported`) from transient ones (`poweredOff`, `other`).
public enum BLEAdapterUnavailable: Equatable, Sendable {
    case poweredOff
    case unauthorized
    case unsupported
    case other(String?)

    public var isTerminal: Bool {
        switch self {
        case .unauthorized, .unsupported: return true
        case .poweredOff, .other:         return false
        }
    }
}

public enum BLEDriverEvent: Equatable, Sendable {
    case ready
    case unavailable(BLEAdapterUnavailable)
    case peerDiscovered(BLEPeerHandle)
    /// Central role: the peer's Identity characteristic was read (16 bytes).
    case identityRead(BLEPeerHandle, identity: Data)
    case identityFailed(BLEPeerHandle, reason: String?)
    /// Outbound: after TX subscription + handshake write succeeded. Inbound: a central
    /// subscribed to our TX. `mtu` is the fragment size for this channel.
    case channelOpened(BLEChannelID, BLEPeerHandle, direction: BLEChannelDirection, mtu: Int)
    case channelFailed(BLEPeerHandle, reason: String?)
    /// One RX write (peripheral role) or one TX notification (central role).
    case channelData(BLEChannelID, Data)
    case channelClosed(BLEChannelID, reason: String?)
}

/// BLE driver dependency. Mechanism only — no policy, no retries, no fragmentation.
public struct BLEDriver: Sendable {
    public var start: @Sendable (BLEDriverConfig) -> AsyncStream<BLEDriverEvent>
    /// Connect, discover the v2.2 service, read Identity. Result arrives as identityRead/identityFailed.
    public var readIdentity: @Sendable (BLEPeerHandle) async -> Void
    /// Subscribe to TX and write our identity to RX. Result arrives as channelOpened/channelFailed.
    public var openChannel: @Sendable (BLEPeerHandle) async -> Void
    /// One fragment or keepalive. Central: RX write without response. Peripheral: TX notify.
    public var send: @Sendable (BLEChannelID, Data) async -> Void
    public var closeChannel: @Sendable (BLEChannelID) async -> Void
    /// Tear down a peer that has NO open channel (cancel in-flight connect, drop the GATT link).
    public var disconnect: @Sendable (BLEPeerHandle) async -> Void
    public var stop: @Sendable () async -> Void

    public init(
        start: @escaping @Sendable (BLEDriverConfig) -> AsyncStream<BLEDriverEvent>,
        readIdentity: @escaping @Sendable (BLEPeerHandle) async -> Void,
        openChannel: @escaping @Sendable (BLEPeerHandle) async -> Void,
        send: @escaping @Sendable (BLEChannelID, Data) async -> Void,
        closeChannel: @escaping @Sendable (BLEChannelID) async -> Void,
        disconnect: @escaping @Sendable (BLEPeerHandle) async -> Void = { _ in },
        stop: @escaping @Sendable () async -> Void
    ) {
        self.start = start
        self.readIdentity = readIdentity
        self.openChannel = openChannel
        self.send = send
        self.closeChannel = closeChannel
        self.disconnect = disconnect
        self.stop = stop
    }
}

extension BLEDriver: DependencyKey {
    // Task 6 replaces this with the FCB-backed adapter.
    public static var liveValue: BLEDriver {
        BLEDriver(start: { _ in .finished }, readIdentity: { _ in }, openChannel: { _ in },
                  send: { _, _ in }, closeChannel: { _ in }, stop: {})
    }

    public static let testValue = BLEDriver(
        start: unimplemented("BLEDriver.start", placeholder: AsyncStream { $0.finish() }),
        readIdentity: unimplemented("BLEDriver.readIdentity"),
        openChannel: unimplemented("BLEDriver.openChannel"),
        send: unimplemented("BLEDriver.send"),
        closeChannel: unimplemented("BLEDriver.closeChannel"),
        disconnect: unimplemented("BLEDriver.disconnect"),
        stop: unimplemented("BLEDriver.stop")
    )
}

extension DependencyValues {
    public var bleDriver: BLEDriver {
        get { self[BLEDriver.self] }
        set { self[BLEDriver.self] = newValue }
    }
}

// "now" for greylist / reassembly arithmetic. \.date's testValue is unimplemented in this TCA
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
```

- [ ] **Step 2: Replace `BLEInterface.swift`**

```swift
import Foundation
import ComposableArchitecture
import ReTiCA

public enum BLEInterfaceStatus: Equatable, Sendable {
    case stopped, starting, online, waitingForAdapter
    /// Terminal: the adapter is unavailable for a reason retrying cannot fix. A fresh `.start` leaves it.
    case unavailable(BLEAdapterUnavailable)

    var isUnavailableTerminal: Bool {
        if case .unavailable = self { return true }
        return false
    }
}

/// The Reticulum BLE interface speaking ble-reticulum protocol v2.2. Parent lifecycle + all policy:
/// discovery gating, establishment, identity handshake, duplicate resolution, fragmentation,
/// greylist, peer cap, keepalive, adapter-loss recovery. The driver underneath is mechanism only.
@Reducer
public struct BLEInterface {
    public static let defaultMaxPeers = 7
    public static let establishTimeout: Duration = .seconds(15)
    public static let handshakeTimeout: Duration = .seconds(10)
    public static let defaultKeepaliveInterval: Duration = .seconds(15)
    public static let churnMinLifetime: TimeInterval = 10
    public static let adapterRetryMin: Duration = .seconds(5)
    public static let adapterRetryMax: Duration = .seconds(120)

    public struct ChannelState: Equatable, Sendable {
        public var peer: BLEPeerHandle
        public var direction: BLEChannelDirection
        var fragmenter: BLEFragmenter
        var reassembler: BLEReassembler
        /// Outbound: set at channelOpened (from identityRead). Inbound: nil until the handshake.
        var peerIdentity: Data?
        var openedAt: Date
    }

    @ObservableState
    public struct State: Equatable {
        public var status: BLEInterfaceStatus = .stopped
        public var maxPeers: Int
        /// This node's 16-byte identity hash — served on Identity and sent as the handshake.
        public let localIdentity: Data
        /// Outbound-channel keepalive cadence; nil disables (spec §2.6).
        public var keepaliveInterval: Duration?
        var channels: [BLEChannelID: ChannelState] = [:]
        var peers: [Data: BLEChannelID] = [:]            // established peers by identity
        var pendingPeers: Set<BLEPeerHandle> = []        // establishment in flight
        var pendingIdentities: [BLEPeerHandle: Data] = [:]  // identity read, channel not yet open
        var greylist = BLEPeerGreylist<BLEPeerHandle>()
        var adapterRetryDelay: Duration = BLEInterface.adapterRetryMin

        public init(localIdentity: Data,
                    maxPeers: Int = BLEInterface.defaultMaxPeers,
                    keepaliveInterval: Duration? = BLEInterface.defaultKeepaliveInterval) {
            precondition(localIdentity.count == BLEProtocol.identityLength, "localIdentity must be 16 bytes")
            self.localIdentity = localIdentity
            self.maxPeers = maxPeers
            self.keepaliveInterval = keepaliveInterval
        }
    }

    public enum Action: Equatable {
        case start
        case stop
        case driverEvent(BLEDriverEvent)
        case send(peer: Data, packet: Data)
        case handshakeDeadline(BLEChannelID)
        case establishDeadline(BLEPeerHandle)
        case keepalive(BLEChannelID)
        case adapterRetry
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case peerOnline(Data)
            case peerOffline(Data)
            case packetReceived(peer: Data, packet: Data)
            case sendFailed(peer: Data, reason: SendFailedReason)
            case adapterUnavailable(BLEAdapterUnavailable)
        }
        public enum SendFailedReason: Equatable {
            /// Empty packet or more than 65 535 fragments: a programmer error, not a lifecycle race.
            case unfragmentable
        }
    }

    @Dependency(\.bleDriver) var bleDriver
    @Dependency(\.continuousClock) var clock
    @Dependency(\.bleDate) var date

    private enum CancelID: Hashable {
        case driver, retry
        case handshake(BLEChannelID)
        case keepalive(BLEChannelID)
        case establish(BLEPeerHandle)
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case .start:
                guard state.status == .stopped || state.status.isUnavailableTerminal else { return .none }
                state.status = .starting
                return startDriver(state: &state)

            case .stop:
                let established = Array(state.peers.keys)
                let channelIDs = Array(state.channels.keys)
                let pending = Array(state.pendingPeers)
                state.channels = [:]
                state.peers = [:]
                state.pendingPeers = []
                state.pendingIdentities = [:]
                state.adapterRetryDelay = Self.adapterRetryMin
                state.status = .stopped
                var effects: [Effect<Action>] = [.cancel(id: CancelID.driver), .cancel(id: CancelID.retry)]
                effects += channelIDs.flatMap { [.cancel(id: CancelID.handshake($0)), .cancel(id: CancelID.keepalive($0))] }
                effects += pending.map { .cancel(id: CancelID.establish($0)) }
                effects.append(.run { [bleDriver] _ in await bleDriver.stop() })
                effects += established.map { .send(.delegate(.peerOffline($0))) }
                return .merge(effects)

            case .driverEvent(.ready):
                state.status = .online
                state.adapterRetryDelay = Self.adapterRetryMin
                return .none

            case let .driverEvent(.peerDiscovered(handle)):
                guard state.status == .online,
                      !state.pendingPeers.contains(handle),
                      !state.channels.values.contains(where: { $0.peer == handle }),
                      state.peers.count + state.pendingPeers.count < state.maxPeers,
                      !state.greylist.isBlocked(handle, now: date())
                else { return .none }
                state.pendingPeers.insert(handle)
                return .merge(
                    .run { [bleDriver] _ in await bleDriver.readIdentity(handle) },
                    .run { [clock] send in
                        try await clock.sleep(for: Self.establishTimeout)
                        await send(.establishDeadline(handle))
                    }
                    .cancellable(id: CancelID.establish(handle), cancelInFlight: true)
                )

            case let .driverEvent(.identityRead(handle, identity)):
                guard state.pendingPeers.contains(handle) else { return .none }
                guard identity.count == BLEProtocol.identityLength, identity != state.localIdentity else {
                    state.pendingPeers.remove(handle)
                    state.greylist.recordFailure(handle, now: date())
                    return .merge(.cancel(id: CancelID.establish(handle)),
                                  .run { [bleDriver] _ in await bleDriver.disconnect(handle) })
                }
                // Cheap pre-check (ble-reticulum does the same before dialing): if this identity
                // already has a channel the duplicate rule would keep, don't open a second one.
                if let existingID = state.peers[identity], let existing = state.channels[existingID],
                   bleResolveDuplicate(localToken: state.localIdentity, peerToken: identity,
                                       existingDirection: existing.direction, newDirection: .outbound) == .keepExisting {
                    state.pendingPeers.remove(handle)
                    return .merge(.cancel(id: CancelID.establish(handle)),
                                  .run { [bleDriver] _ in await bleDriver.disconnect(handle) })
                }
                state.pendingIdentities[handle] = identity
                return .run { [bleDriver] _ in await bleDriver.openChannel(handle) }

            case let .driverEvent(.identityFailed(handle, _)),
                 let .driverEvent(.channelFailed(handle, _)):
                guard state.pendingPeers.contains(handle) else { return .none }
                state.pendingPeers.remove(handle)
                state.pendingIdentities[handle] = nil
                state.greylist.recordFailure(handle, now: date())
                return .cancel(id: CancelID.establish(handle))

            case let .establishDeadline(handle):
                guard state.pendingPeers.contains(handle) else { return .none }
                state.pendingPeers.remove(handle)
                state.pendingIdentities[handle] = nil
                state.greylist.recordFailure(handle, now: date())
                return .run { [bleDriver] _ in await bleDriver.disconnect(handle) }

            case let .driverEvent(.channelOpened(channelID, handle, direction, mtu)):
                var effects: [Effect<Action>] = [.cancel(id: CancelID.establish(handle))]
                state.pendingPeers.remove(handle)
                let pendingIdentity = state.pendingIdentities.removeValue(forKey: handle)
                let now = date()
                guard state.status == .online,
                      state.peers.count < state.maxPeers,
                      !state.greylist.isBlocked(handle, now: now),
                      direction == .inbound || pendingIdentity != nil
                else {
                    effects.append(.run { [bleDriver] _ in await bleDriver.closeChannel(channelID) })
                    return .merge(effects)
                }
                state.channels[channelID] = ChannelState(
                    peer: handle, direction: direction,
                    fragmenter: BLEFragmenter(mtu: mtu), reassembler: BLEReassembler(),
                    peerIdentity: nil, openedAt: now)
                switch direction {
                case .outbound:
                    effects.append(establish(&state, channelID: channelID, identity: pendingIdentity!))
                case .inbound:
                    effects.append(.run { [clock] send in
                        try await clock.sleep(for: Self.handshakeTimeout)
                        await send(.handshakeDeadline(channelID))
                    }
                    .cancellable(id: CancelID.handshake(channelID), cancelInFlight: true))
                }
                return .merge(effects)

            case let .driverEvent(.channelData(channelID, bytes)):
                guard var channel = state.channels[channelID] else { return .none }
                if BLEKeepalive.isKeepalive(bytes) { return .none }
                guard channel.peerIdentity != nil else {
                    // Inbound, pre-handshake: only a 16-byte write that is not our own identity counts.
                    guard bytes.count == BLEProtocol.identityLength, bytes != state.localIdentity else { return .none }
                    return .merge(.cancel(id: CancelID.handshake(channelID)),
                                  establish(&state, channelID: channelID, identity: Data(bytes)))
                }
                let packet: Data?
                do {
                    packet = try channel.reassembler.receive(bytes, now: date())
                } catch {
                    packet = nil   // malformed: that packet's buffer is gone, the channel stays up
                }
                state.channels[channelID] = channel
                guard let packet, let identity = channel.peerIdentity else { return .none }
                return .send(.delegate(.packetReceived(peer: identity, packet: packet)))

            case let .send(peer, packet):
                guard let channelID = state.peers[peer], let channel = state.channels[channelID] else { return .none }
                guard let fragments = try? channel.fragmenter.fragment(packet) else {
                    return .send(.delegate(.sendFailed(peer: peer, reason: .unfragmentable)))
                }
                return .run { [bleDriver] _ in
                    for fragment in fragments { await bleDriver.send(channelID, fragment) }
                }

            case let .keepalive(channelID):
                guard let channel = state.channels[channelID], channel.direction == .outbound,
                      channel.peerIdentity != nil else { return .none }
                return .run { [bleDriver] _ in await bleDriver.send(channelID, BLEKeepalive.frame) }

            case let .handshakeDeadline(channelID):
                guard let channel = state.channels[channelID], channel.peerIdentity == nil else { return .none }
                return tearDown(&state, channelID: channelID, strike: true)

            case let .driverEvent(.channelClosed(channelID, _)):
                guard let channel = state.channels.removeValue(forKey: channelID) else { return .none }
                var effects: [Effect<Action>] = [.cancel(id: CancelID.handshake(channelID)),
                                                 .cancel(id: CancelID.keepalive(channelID))]
                if let identity = channel.peerIdentity, state.peers[identity] == channelID {
                    state.peers[identity] = nil
                    effects.append(.send(.delegate(.peerOffline(identity))))
                }
                let now = date()
                if now.timeIntervalSince(channel.openedAt) < Self.churnMinLifetime {
                    state.greylist.recordFailure(channel.peer, now: now)
                }
                return .merge(effects)

            case let .driverEvent(.unavailable(cause)):
                guard state.status != .stopped else { return .none }
                let established = Array(state.peers.keys)
                let channelIDs = Array(state.channels.keys)
                let pending = Array(state.pendingPeers)
                state.channels = [:]
                state.peers = [:]
                state.pendingPeers = []
                state.pendingIdentities = [:]
                var effects: [Effect<Action>] = [.cancel(id: CancelID.driver)]
                effects += channelIDs.flatMap { [.cancel(id: CancelID.handshake($0)), .cancel(id: CancelID.keepalive($0))] }
                effects += pending.map { .cancel(id: CancelID.establish($0)) }
                effects += established.map { .send(.delegate(.peerOffline($0))) }
                if cause.isTerminal {
                    state.status = .unavailable(cause)
                    effects.append(.cancel(id: CancelID.retry))
                    effects.append(.send(.delegate(.adapterUnavailable(cause))))
                } else {
                    state.status = .waitingForAdapter
                    let delay = state.adapterRetryDelay
                    state.adapterRetryDelay = min(delay * 2, Self.adapterRetryMax)
                    effects.append(.run { [clock] send in
                        try await clock.sleep(for: delay)
                        await send(.adapterRetry)
                    }
                    .cancellable(id: CancelID.retry, cancelInFlight: true))
                }
                return .merge(effects)

            case .adapterRetry:
                guard state.status == .waitingForAdapter else { return .none }
                state.status = .starting
                return startDriver(state: &state)

            case .delegate:
                return .none
            }
        }
    }

    private func startDriver(state: inout State) -> Effect<Action> {
        let config = BLEDriverConfig(localIdentity: state.localIdentity)
        return .run { [bleDriver] send in
            for await event in bleDriver.start(config) {
                await send(.driverEvent(event))
            }
        }
        .cancellable(id: CancelID.driver, cancelInFlight: true)
    }

    /// Marks `channelID` established for `identity`: runs the duplicate rule against any existing
    /// channel for that identity, registers the survivor, emits `peerOnline` for a new peer, and
    /// arms the keepalive on outbound channels.
    private func establish(_ state: inout State, channelID: BLEChannelID, identity: Data) -> Effect<Action> {
        guard var current = state.channels[channelID] else { return .none }
        var effects: [Effect<Action>] = []
        if let existingID = state.peers[identity], let existing = state.channels[existingID], existingID != channelID {
            switch bleResolveDuplicate(localToken: state.localIdentity, peerToken: identity,
                                       existingDirection: existing.direction, newDirection: current.direction) {
            case .keepExisting:
                state.channels[channelID] = nil
                effects.append(.run { [bleDriver] _ in await bleDriver.closeChannel(channelID) })
                return .merge(effects)
            case .keepNew:
                state.channels[existingID] = nil
                effects.append(.cancel(id: CancelID.handshake(existingID)))
                effects.append(.cancel(id: CancelID.keepalive(existingID)))
                effects.append(.run { [bleDriver] _ in await bleDriver.closeChannel(existingID) })
                current.peerIdentity = identity
                state.channels[channelID] = current
                state.peers[identity] = channelID
            }
        } else {
            current.peerIdentity = identity
            state.channels[channelID] = current
            state.peers[identity] = channelID
            effects.append(.send(.delegate(.peerOnline(identity))))
        }
        if current.direction == .outbound, let interval = state.keepaliveInterval {
            effects.append(.run { [clock] send in
                while true {
                    try await clock.sleep(for: interval)
                    await send(.keepalive(channelID))
                }
            }
            .cancellable(id: CancelID.keepalive(channelID), cancelInFlight: true))
        }
        return .merge(effects)
    }

    private func tearDown(_ state: inout State, channelID: BLEChannelID, strike: Bool) -> Effect<Action> {
        guard let channel = state.channels.removeValue(forKey: channelID) else { return .none }
        var effects: [Effect<Action>] = [
            .cancel(id: CancelID.handshake(channelID)),
            .cancel(id: CancelID.keepalive(channelID)),
            .run { [bleDriver] _ in await bleDriver.closeChannel(channelID) },
        ]
        if let identity = channel.peerIdentity, state.peers[identity] == channelID {
            state.peers[identity] = nil
            effects.append(.send(.delegate(.peerOffline(identity))))
        }
        if strike { state.greylist.recordFailure(channel.peer, now: date()) }
        return .merge(effects)
    }
}
```

- [ ] **Step 3: Trim `BLESupport.swift` and remove the RBTP adapter**

Delete from `BLESupport.swift`: `BLEFramingError`, `BLEFraming`, `BLEFrameBuffer`, `BLEHello` (everything from the file's first `public enum BLEFramingError` through the end of `BLEHello`). Update the file's header comment to: `/// Pure support logic for the Reticulum BLE interface (ble-reticulum protocol v2.2). Ports of ble_reticulum.BLEFragmentation and the fork's ble_support.PeerGreylist — no CoreBluetooth, no TCA, testable everywhere.`

```bash
git -C /Users/ell/development/ios/pods/ReTiCA rm Sources/ReTiCAInterfaces/FCBDriverAdapter.swift Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMTests.swift
```

Delete the `// MARK: - Framing` and `// MARK: - HELLO` sections from `BLESupportTests.swift` (the tests `frameProducesBigEndianLengthPrefix` … `helloParseRejectsBadInput`).

`Packet.swift:77` comment: replace `BLEFrameBuffer caps at 1196` with `the BLE reassembler is bounded by the 500-byte HW_MTU`. `PacketTests.swift:87` comment: replace `` `BLEFrameBuffer` caps at 1196 `` with `` the BLE data plane is bounded by `HW_MTU` 500 ``.

- [ ] **Step 4: Update `BLEEndpoint.swift`**

Replace the `State` struct's stored `ble` init and the doc comments that mention "session token":

```swift
/// Deterministic Transport `InterfaceID` for a BLE peer, keyed by its 16-byte identity hash.
public func bleInterfaceID(_ identity: Data) -> InterfaceID {
    let hex = identity.map { String(format: "%02x", $0) }.joined()
    return InterfaceID("ble:" + hex)
}
```
and in `State`:
```swift
        /// InterfaceID → 16-byte peer identity, maintained by the container as peers come and go.
        public internal(set) var peerInterfaces: [InterfaceID: Data] = [:]
        public let profile: InterfaceProfile

        public init(localIdentity: Data,
                    maxPeers: Int = BLEInterface.defaultMaxPeers,
                    profile: InterfaceProfile = .ble) {
            self.ble = BLEInterface.State(localIdentity: localIdentity, maxPeers: maxPeers)
            self.profile = profile
        }
```
Delete every `pairingMode` mention in the file. Delegate doc comments: "token" → "identity" (three places).

- [ ] **Step 5: Rewrite `BLEInterfaceTests.swift`**

Replace the whole file:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCAInterfaces

enum MockDriverCall: Equatable {
    case start
    case stop
    case readIdentity(BLEPeerHandle)
    case openChannel(BLEPeerHandle)
    case send(BLEChannelID, Data)
    case closeChannel(BLEChannelID)
    case disconnect(BLEPeerHandle)
}

// Deterministic fixtures shared by all reducer tests.
let localIdentity = Data(repeating: 0x11, count: 16)
let peerHandleA = BLEPeerHandle(id: UUID(uuidString: "AAAAAAAA-0000-0000-0000-000000000001")!)
let peerHandleB = BLEPeerHandle(id: UUID(uuidString: "BBBBBBBB-0000-0000-0000-000000000002")!)
let channel1 = BLEChannelID(id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000001")!)
let channel2 = BLEChannelID(id: UUID(uuidString: "CCCCCCCC-0000-0000-0000-000000000002")!)
let identityLow = Data(repeating: 0x01, count: 16)    // sorts below localIdentity
let identityHigh = Data(repeating: 0xEE, count: 16)   // sorts above localIdentity
let testMTU = 512                                     // payload 507: any ≤500 B packet is one fragment

func frags(_ packet: Data, mtu: Int = testMTU) -> [Data] { try! BLEFragmenter(mtu: mtu).fragment(packet) }

@MainActor
func makeStore(maxPeers: Int = BLEInterface.defaultMaxPeers, streams: Int = 1,
               keepalive: Duration? = BLEInterface.defaultKeepaliveInterval)
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
    let store = TestStore(initialState: BLEInterface.State(localIdentity: localIdentity, maxPeers: maxPeers,
                                                           keepaliveInterval: keepalive)) {
        BLEInterface()
    } withDependencies: {
        $0.bleDriver = BLEDriver(
            start: { _ in
                calls.withValue { $0.append(.start) }
                let n = startCount.withValue { $0 += 1; return $0 }
                return n <= made.count ? made[n - 1].stream : AsyncStream { _ in }
            },
            readIdentity: { h in calls.withValue { $0.append(.readIdentity(h)) } },
            openChannel: { h in calls.withValue { $0.append(.openChannel(h)) } },
            send: { c, d in calls.withValue { $0.append(.send(c, d)) } },
            closeChannel: { c in calls.withValue { $0.append(.closeChannel(c)) } },
            disconnect: { h in calls.withValue { $0.append(.disconnect(h)) } },
            stop: { calls.withValue { $0.append(.stop) } }
        )
        $0.continuousClock = clock
        $0.bleDate = DateGenerator { now.value }
    }
    store.exhaustivity = .off
    return (store, made.map { $0.continuation }, calls, clock, now)
}

@MainActor
func makeOnlineStore(maxPeers: Int = BLEInterface.defaultMaxPeers, streams: Int = 1,
                     keepalive: Duration? = BLEInterface.defaultKeepaliveInterval)
    async -> (store: TestStore<BLEInterface.State, BLEInterface.Action>,
              events: [AsyncStream<BLEDriverEvent>.Continuation],
              calls: LockIsolated<[MockDriverCall]>,
              clock: TestClock<Duration>,
              now: LockIsolated<Date>)
{
    let (store, events, calls, clock, now) = makeStore(maxPeers: maxPeers, streams: streams, keepalive: keepalive)
    await store.send(.start) { $0.status = .starting }
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    return (store, events, calls, clock, now)
}

/// Outbound establishment: discovery → identityRead → channelOpened(.outbound) → peerOnline.
@MainActor
func establishOutbound(
    _ store: TestStore<BLEInterface.State, BLEInterface.Action>,
    _ events: AsyncStream<BLEDriverEvent>.Continuation,
    handle: BLEPeerHandle, channel: BLEChannelID, identity: Data
) async {
    events.yield(.peerDiscovered(handle))
    await store.receive(.driverEvent(.peerDiscovered(handle)))
    events.yield(.identityRead(handle, identity: identity))
    await store.receive(.driverEvent(.identityRead(handle, identity: identity)))
    events.yield(.channelOpened(channel, handle, direction: .outbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel, handle, direction: .outbound, mtu: testMTU)))
    await store.receive(.delegate(.peerOnline(identity)))
}

/// Inbound establishment: channelOpened(.inbound) → 16-byte handshake → peerOnline.
@MainActor
func establishInbound(
    _ store: TestStore<BLEInterface.State, BLEInterface.Action>,
    _ events: AsyncStream<BLEDriverEvent>.Continuation,
    handle: BLEPeerHandle, channel: BLEChannelID, identity: Data
) async {
    events.yield(.channelOpened(channel, handle, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel, handle, direction: .inbound, mtu: testMTU)))
    events.yield(.channelData(channel, identity))
    await store.receive(.driverEvent(.channelData(channel, identity)))
    await store.receive(.delegate(.peerOnline(identity)))
}

// MARK: - Lifecycle

@Test @MainActor func startComesOnlineOnReady() async {
    let (store, events, calls, _, _) = makeStore()
    await store.send(.start) { $0.status = .starting }
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
    await store.send(.start)
    #expect(calls.value.filter { $0 == .start }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func stopCallsDriverStop() async {
    let (store, events, calls, _, _) = makeStore()
    await store.send(.start) { $0.status = .starting }
    events[0].yield(.ready)
    await store.receive(.driverEvent(.ready)) { $0.status = .online }
    await store.send(.stop) { $0.status = .stopped }
    #expect(calls.value.contains(.stop))
}

// MARK: - Discovery / establishment (central role)

@Test @MainActor func discoveryReadsIdentityThenOpensChannel() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA))) { $0.pendingPeers = [peerHandleA] }
    #expect(calls.value.contains(.readIdentity(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh))) {
        $0.pendingIdentities = [peerHandleA: identityHigh]
    }
    #expect(calls.value.contains(.openChannel(peerHandleA)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func ownIdentityIsRefusedDisconnectedAndGreylisted() async {
    let (store, events, calls, _, now) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: localIdentity))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: localIdentity))) { $0.pendingPeers = [] }
    await store.finish()
    #expect(!calls.value.contains(.openChannel(peerHandleA)))
    #expect(calls.value.contains(.disconnect(peerHandleA)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 1)   // blocked
    now.setValue(now.value.addingTimeInterval(5.01))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 2)   // backoff expired
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func shortIdentityIsRefused() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: Data(repeating: 1, count: 15)))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: Data(repeating: 1, count: 15)))) { $0.pendingPeers = [] }
    #expect(!calls.value.contains(.openChannel(peerHandleA)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func identityFailureStrikesAndPendingPeerIsNotRediscovered() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.peerDiscovered(peerHandleA))                     // pending: ignored
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 1)
    events[0].yield(.identityFailed(peerHandleA, reason: "no identity characteristic"))
    await store.receive(.driverEvent(.identityFailed(peerHandleA, reason: "no identity characteristic"))) { $0.pendingPeers = [] }
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 1)   // strike blocks
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func establishDeadlineAbandonsStrikesAndDisconnects() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh)))
    await clock.advance(by: BLEInterface.establishTimeout)
    await store.receive(.establishDeadline(peerHandleA)) {
        $0.pendingPeers = []
        $0.pendingIdentities = [:]
    }
    // A late channelOpened for the abandoned peer has no pending identity → closed, no peer.
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .outbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .outbound, mtu: testMTU)))
    await store.finish()
    #expect(calls.value.contains(.disconnect(peerHandleA)))
    #expect(calls.value.contains(.closeChannel(channel1)))
    #expect(store.state.peers.isEmpty)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func discoveryIsIgnoredAtPeerCap() async {
    let (store, events, calls, _, _) = await makeOnlineStore(maxPeers: 1)
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.peerDiscovered(peerHandleB))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleB)))
    #expect(calls.value.filter { if case .readIdentity = $0 { return true } else { return false } }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func identityPreCheckAbandonsRedundantDial() async {
    // Peer HIGH is already connected inbound. HIGH > local, so on a cross-connect the channel
    // initiated by LOCAL (lower) would win — i.e. the rule says keepNew for an outbound dial.
    // Use LOW instead: LOW < local → the peer-initiated (inbound) channel wins → keepExisting → skip.
    let (store, events, calls, _, _) = await makeOnlineStore()
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityLow)
    events[0].yield(.peerDiscovered(peerHandleB))          // same device seen under a new handle
    await store.receive(.driverEvent(.peerDiscovered(peerHandleB)))
    events[0].yield(.identityRead(peerHandleB, identity: identityLow))
    await store.receive(.driverEvent(.identityRead(peerHandleB, identity: identityLow))) { $0.pendingPeers = [] }
    await store.finish()
    #expect(!calls.value.contains(.openChannel(peerHandleB)))
    #expect(calls.value.contains(.disconnect(peerHandleB)))
    // Not a strike: a fresh discovery of handle B reads its identity again.
    events[0].yield(.peerDiscovered(peerHandleB))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleB)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleB) }.count == 2)
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Handshake (peripheral role)

@Test @MainActor func outboundEstablishmentReportsPeerOnlineWithoutAnyHandshakeFrame() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    // The driver wrote the handshake itself; the reducer sends nothing at establishment.
    #expect(!calls.value.contains { if case .send = $0 { return true } else { return false } })
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func inboundHandshakeReportsPeerOnline() async {
    let (store, events, _, _, _) = await makeOnlineStore()
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    #expect(store.state.peers[identityHigh] == channel1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func preHandshakeJunkIsDroppedWithoutStrike() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU)))
    let junk = frags(Data([1, 2, 3]))[0]                       // a fragment before any handshake
    events[0].yield(.channelData(channel1, junk))
    await store.receive(.driverEvent(.channelData(channel1, junk)))
    #expect(!calls.value.contains(.closeChannel(channel1)))
    // The handshake can still arrive afterwards.
    events[0].yield(.channelData(channel1, identityHigh))
    await store.receive(.driverEvent(.channelData(channel1, identityHigh)))
    await store.receive(.delegate(.peerOnline(identityHigh)))
    await clock.advance(by: BLEInterface.handshakeTimeout)   // deadline was cancelled: no teardown
    #expect(!calls.value.contains(.closeChannel(channel1)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func handshakeEchoingOurOwnIdentityIsIgnored() async {
    let (store, events, _, clock, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU)))
    events[0].yield(.channelData(channel1, localIdentity))
    await store.receive(.driverEvent(.channelData(channel1, localIdentity)))
    #expect(store.state.peers.isEmpty)
    await clock.advance(by: BLEInterface.handshakeTimeout)
    await store.receive(.handshakeDeadline(channel1))
    #expect(store.state.channels.isEmpty)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func handshakeTimeoutDropsChannelAndStrikes() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU)))
    await clock.advance(by: BLEInterface.handshakeTimeout)
    await store.receive(.handshakeDeadline(channel1))
    #expect(calls.value.contains(.closeChannel(channel1)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(!calls.value.contains(.readIdentity(peerHandleA)))   // struck
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func inboundChannelRefusedAtPeerCap() async {
    let (store, events, calls, _, _) = await makeOnlineStore(maxPeers: 1)
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    events[0].yield(.channelOpened(channel2, peerHandleB, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleB, direction: .inbound, mtu: testMTU)))
    #expect(calls.value.contains(.closeChannel(channel2)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func inboundOpenClearsPendingOutboundEstablishment() async {
    let (store, events, calls, _, now) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA))) { $0.pendingPeers = [peerHandleA] }
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: testMTU))) {
        $0.pendingPeers = []
    }
    events[0].yield(.channelData(channel1, identityHigh))
    await store.receive(.driverEvent(.channelData(channel1, identityHigh)))
    await store.receive(.delegate(.peerOnline(identityHigh)))
    events[0].yield(.identityFailed(peerHandleA, reason: "late failure"))
    await store.receive(.driverEvent(.identityFailed(peerHandleA, reason: "late failure"))) { $0.pendingPeers = [] }
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime + 1))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(identityHigh)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 2)   // no strike
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Data plane

@Test @MainActor func packetsFlowBothWaysFragmented() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    // Inbound: three fragments at the peer's MTU 23 → one packetReceived.
    let packet = Data((0..<40).map { UInt8($0) })
    let inbound = frags(packet, mtu: 23)
    for f in inbound {
        events[0].yield(.channelData(channel1, f))
        await store.receive(.driverEvent(.channelData(channel1, f)))
    }
    await store.receive(.delegate(.packetReceived(peer: identityHigh, packet: packet)))
    // Outbound: .send fragments at OUR channel MTU (512) → one driver send here.
    let outbound = Data(repeating: 0xCD, count: 21)
    await store.send(.send(peer: identityHigh, packet: outbound))
    await store.finish()
    #expect(calls.value.contains(.send(channel1, frags(outbound)[0])))
    let before = calls.value.count
    await store.send(.send(peer: identityLow, packet: outbound))   // unknown peer: dropped
    #expect(calls.value.count == before)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func outboundSendIssuesOneDriverSendPerFragmentInOrder() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: 23))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: 23)))
    events[0].yield(.channelData(channel1, identityHigh))
    await store.receive(.driverEvent(.channelData(channel1, identityHigh)))
    await store.receive(.delegate(.peerOnline(identityHigh)))
    let packet = Data(repeating: 0xAB, count: 50)             // 3 fragments at MTU 23
    await store.send(.send(peer: identityHigh, packet: packet))
    await store.finish()
    let sends = calls.value.compactMap { if case let .send(c, d) = $0, c == channel1 { return d } else { return nil } }
    #expect(sends == frags(packet, mtu: 23))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func malformedFragmentLeavesChannelUp() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    events[0].yield(.channelData(channel1, Data([0x07, 0, 0, 0, 1, 0xAA])))   // bad type
    await store.receive(.driverEvent(.channelData(channel1, Data([0x07, 0, 0, 0, 1, 0xAA]))))
    #expect(!calls.value.contains(.closeChannel(channel1)))
    let packet = Data([9, 9, 9])
    events[0].yield(.channelData(channel1, frags(packet)[0]))
    await store.receive(.driverEvent(.channelData(channel1, frags(packet)[0])))
    await store.receive(.delegate(.packetReceived(peer: identityHigh, packet: packet)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func keepaliveByteIsIgnoredOnReceipt() async {
    let (store, events, _, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    store.exhaustivity = .on
    events[0].yield(.channelData(channel1, BLEKeepalive.frame))
    await store.receive(.driverEvent(.channelData(channel1, BLEKeepalive.frame)))   // no delegate
    store.exhaustivity = .off
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func sixteenByteFragmentAfterHandshakeIsData() async {
    // Review Focus 1: once the identity is known, a 16-byte write is a fragment, not a handshake.
    let (store, events, _, _, _) = await makeOnlineStore(keepalive: nil)
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    let packet = Data(repeating: 0x42, count: 11)              // 5 header + 11 = 16 bytes on the wire
    let f = frags(packet)[0]
    #expect(f.count == 16)
    events[0].yield(.channelData(channel1, f))
    await store.receive(.driverEvent(.channelData(channel1, f)))
    await store.receive(.delegate(.packetReceived(peer: identityHigh, packet: packet)))
    #expect(store.state.peers.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func lateEventsForTornDownChannelAreIgnored() async {
    // Review Focus 2.
    let (store, events, calls, _, now) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime + 1))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(identityHigh)))
    store.exhaustivity = .on
    events[0].yield(.channelData(channel1, frags(Data([1]))[0]))
    await store.receive(.driverEvent(.channelData(channel1, frags(Data([1]))[0])))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    store.exhaustivity = .off
    // No strike from the duplicate close: rediscovery reads identity again.
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 2)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func sendOfUnfragmentablePacketIsDistinguishedFromAbsentChannel() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    let before = calls.value.count
    await store.send(.send(peer: identityHigh, packet: Data()))
    #expect(calls.value.count == before)
    await store.receive(.delegate(.sendFailed(peer: identityHigh, reason: .unfragmentable)))
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Keepalive

@Test @MainActor func keepaliveFiresOnOutboundChannelsEveryIntervalAndStopsOnClose() async {
    let (store, events, calls, clock, now) = await makeOnlineStore()
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    await clock.advance(by: BLEInterface.defaultKeepaliveInterval)
    await store.receive(.keepalive(channel1))
    await clock.advance(by: BLEInterface.defaultKeepaliveInterval)
    await store.receive(.keepalive(channel1))
    await store.finish()
    #expect(calls.value.filter { $0 == .send(channel1, BLEKeepalive.frame) }.count == 2)
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime + 1))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(identityHigh)))
    await clock.advance(by: BLEInterface.defaultKeepaliveInterval * 2)
    #expect(calls.value.filter { $0 == .send(channel1, BLEKeepalive.frame) }.count == 2)   // stopped
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func keepaliveNeverRunsOnInboundChannels() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    await clock.advance(by: BLEInterface.defaultKeepaliveInterval * 2)
    #expect(!calls.value.contains(.send(channel1, BLEKeepalive.frame)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func keepaliveCanBeDisabled() async {
    let (store, events, calls, clock, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    await clock.advance(by: BLEInterface.defaultKeepaliveInterval * 2)
    #expect(!calls.value.contains(.send(channel1, BLEKeepalive.frame)))
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Duplicate resolution

@Test @MainActor func crossConnectKeepsLowerInitiatorsChannelFromBothPerspectives() async {
    // Peer LOW < local: the peer-initiated (inbound-at-us) channel survives regardless of order.
    var (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityLow)
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU)))
    events[0].yield(.channelData(channel2, identityLow))
    await store.receive(.driverEvent(.channelData(channel2, identityLow)))
    await store.finish()
    #expect(calls.value.contains(.closeChannel(channel1)))
    #expect(!calls.value.contains(.closeChannel(channel2)))
    let packet = Data([0x0A, 0x0B, 0x0C])
    await store.send(.send(peer: identityLow, packet: packet))
    await store.finish()
    #expect(calls.value.contains(.send(channel2, frags(packet)[0])))
    await store.send(.stop) { $0.status = .stopped }

    // Order 2: inbound first, then our outbound completes → ours still loses.
    (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel2, identity: identityLow)
    events[0].yield(.peerDiscovered(peerHandleB))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleB)))
    events[0].yield(.identityRead(peerHandleB, identity: identityLow))
    await store.receive(.driverEvent(.identityRead(peerHandleB, identity: identityLow)))
    await store.finish()
    #expect(!calls.value.contains(.openChannel(peerHandleB)))   // pre-check: never dialed
    await store.send(.send(peer: identityLow, packet: Data([0x0D])))
    await store.finish()
    #expect(calls.value.contains(.send(channel2, frags(Data([0x0D]))[0])))
    await store.send(.stop) { $0.status = .stopped }

    // Peer HIGH > local: OUR outbound channel survives a later inbound.
    (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU)))
    events[0].yield(.channelData(channel2, identityHigh))
    await store.receive(.driverEvent(.channelData(channel2, identityHigh)))
    await store.finish()
    #expect(calls.value.contains(.closeChannel(channel2)))
    #expect(!calls.value.contains(.closeChannel(channel1)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func sameDirectionHandshakeReplacesStaleChannelWithoutOfflineBlip() async {
    // Review Focus 4 (reducer half).
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    store.exhaustivity = .on
    events[0].yield(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel2, peerHandleA, direction: .inbound, mtu: testMTU))) {
        $0.channels[channel2] = BLEInterface.ChannelState(
            peer: peerHandleA, direction: .inbound, fragmenter: BLEFragmenter(mtu: testMTU),
            reassembler: BLEReassembler(), peerIdentity: nil, openedAt: Date(timeIntervalSince1970: 1_000))
    }
    events[0].yield(.channelData(channel2, identityHigh))
    await store.receive(.driverEvent(.channelData(channel2, identityHigh))) {
        $0.channels[channel1] = nil
        $0.channels[channel2]?.peerIdentity = identityHigh
        $0.peers[identityHigh] = channel2
    }
    store.exhaustivity = .off
    await store.finish()
    #expect(calls.value.contains(.closeChannel(channel1)))
    await store.send(.send(peer: identityHigh, packet: Data([0x01])))
    await store.finish()
    #expect(calls.value.contains(.send(channel2, frags(Data([0x01]))[0])))
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - Close policy / churn / adapter loss

@Test @MainActor func channelClosedTakesPeerOfflineWithoutChurnStrike() async {
    let (store, events, calls, _, now) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime))
    events[0].yield(.channelClosed(channel1, reason: "supervision timeout"))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: "supervision timeout")))
    await store.receive(.delegate(.peerOffline(identityHigh)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 2)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func shortLivedChannelEarnsChurnStrike() async {
    let (store, events, calls, _, now) = await makeOnlineStore(keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime - 0.5))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(identityHigh)))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    #expect(calls.value.filter { $0 == .readIdentity(peerHandleA) }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func adapterLossTakesPeersOfflineThenRecoversWithBackoff() async {
    let (store, events, calls, clock, _) = await makeOnlineStore(streams: 2, keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    events[0].yield(.unavailable(.poweredOff))
    await store.receive(.driverEvent(.unavailable(.poweredOff))) {
        $0.status = .waitingForAdapter
        $0.channels = [:]
        $0.peers = [:]
        $0.pendingPeers = []
    }
    await store.receive(.delegate(.peerOffline(identityHigh)))
    await clock.advance(by: BLEInterface.adapterRetryMin)
    await store.receive(.adapterRetry) { $0.status = .starting }
    #expect(calls.value.filter { $0 == .start }.count == 2)
    events[1].yield(.ready)
    await store.receive(.driverEvent(.ready)) {
        $0.status = .online
        $0.adapterRetryDelay = BLEInterface.adapterRetryMin
    }
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func adapterRetryDelayDoublesUpToCap() async {
    let (store, events, _, clock, _) = await makeOnlineStore(streams: 2)
    events[0].yield(.unavailable(.other(nil)))
    await store.receive(.driverEvent(.unavailable(.other(nil)))) {
        $0.status = .waitingForAdapter
        $0.adapterRetryDelay = .seconds(10)
    }
    await clock.advance(by: BLEInterface.adapterRetryMin)
    await store.receive(.adapterRetry) { $0.status = .starting }
    events[1].yield(.unavailable(.other(nil)))
    await store.receive(.driverEvent(.unavailable(.other(nil)))) {
        $0.status = .waitingForAdapter
        $0.adapterRetryDelay = .seconds(20)
    }
    await clock.advance(by: .seconds(5))
    await clock.advance(by: .seconds(5))
    await store.receive(.adapterRetry) { $0.status = .starting }
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func unauthorizedIsTerminalStopsRetryingAndSurfaces() async {
    let (store, events, calls, clock, _) = await makeOnlineStore(streams: 2, keepalive: nil)
    await establishOutbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    events[0].yield(.unavailable(.unauthorized))
    await store.receive(.driverEvent(.unavailable(.unauthorized))) {
        $0.status = .unavailable(.unauthorized)
        $0.channels = [:]
        $0.peers = [:]
        $0.pendingPeers = []
    }
    await store.receive(.delegate(.peerOffline(identityHigh)))
    await store.receive(.delegate(.adapterUnavailable(.unauthorized)))
    let startsBefore = calls.value.filter { $0 == .start }.count
    await clock.advance(by: BLEInterface.adapterRetryMax)
    #expect(calls.value.filter { $0 == .start }.count == startsBefore)
    await store.send(.start) { $0.status = .starting }
    #expect(calls.value.filter { $0 == .start }.count == startsBefore + 1)
    await store.send(.stop) { $0.status = .stopped }
}
```

- [ ] **Step 6: Migrate the node-layer tests (mechanical)**

`EndpointTestSupport.swift`:
```swift
/// A `TransportEndpoint.State` running a BLE driver keyed by `localIdentity`.
func bleDriverEndpoint(localIdentity: Data = Data(repeating: 0x5A, count: 16),
                       maxPeers: Int = BLEInterface.defaultMaxPeers,
                       profile: InterfaceProfile = .ble) -> TransportEndpoint.State {
    .ble(BLEEndpoint.State(localIdentity: localIdentity, maxPeers: maxPeers, profile: profile))
}
```

In each of `BLEEndpointIntegrationTests.swift`, `BLEEndpointLinkTests.swift`, `LXMFNodeBLETests.swift`, `TransportEndpointCharacterizationTests.swift`, `TransportEndpointTests.swift` apply exactly these replacements:

1. Delete the private `framedHello` function. Add once per file, after the file-level constants:
   ```swift
   private let bleMTU = 512
   /// One fragment (payload 507 ≥ any test packet) with the 5-byte v2.2 header.
   private func bleFrag(_ packet: Data) -> Data { try! BLEFragmenter(mtu: bleMTU).fragment(packet)[0] }
   ```
2. `.channelOpened(X, Y, direction: .inbound)` → `.channelOpened(X, Y, direction: .inbound, mtu: bleMTU)` (all occurrences).
3. `.channelData(C, framedHello(T))` / `framedHello(token)` → `.channelData(C, T)` — the handshake is the bare 16-byte identity.
4. `try! BLEFraming.frame(X)` → `bleFrag(X)`.
5. `dropFirst(BLEFraming.headerLength)` → `dropFirst(BLEFragmenter.headerLength)`.
6. Delete every `$0.bleRandomBytes = ...` line.
7. In mock `BLEDriver(...)` literals: `readDirectory: { _ in }, openChannel: { _, _ in }` → `readIdentity: { _ in }, openChannel: { _ in }`.
8. `BLEEndpoint.State()` → `BLEEndpoint.State(localIdentity: ownToken)` where the file defines `ownToken`; in `TransportEndpointTests.swift` (no `ownToken`) use `BLEEndpoint.State(localIdentity: Data(repeating: 0x5A, count: 16))`. `bleDriverEndpoint()` calls need no change (default identity 0x5A…).
9. In `TransportEndpointCharacterizationTests.swift` `makeBLE(tokenForChannel:ownToken:)`: `TransportEndpoint.State.ble(BLEEndpoint.State())` → `.ble(BLEEndpoint.State(localIdentity: ownToken))`.
10. Keepalive timers: every node test that brings an OUTBOUND peer online would arm a 15 s keepalive on the TestClock; the node tests only use inbound peers (`direction: .inbound`), so nothing to do. If a test's TestStore teardown reports an in-flight effect, that test opened an outbound channel — pass `keepaliveInterval: nil` by constructing `BLEEndpoint.State` and setting `state.ble.keepaliveInterval = nil` before building the store.

Grep to confirm nothing is left:
`grep -rn "framedHello\|BLEFraming\|BLEHello\|bleRandomBytes\|readDirectory\|pairingMode" Sources Tests` → expected: no output.

- [ ] **Step 7: Build and run the reducer tests**

Run: `swift build --build-tests` — expected: success (fix any residue the grep missed).
Run: `swift test --filter BLEInterfaceTests` — expected: all PASS.
Run: `swift test --filter ReTiCANodeTests` — expected: all PASS.

- [ ] **Step 8: Mutate, verify, revert**

Mutation batch in `BLEInterface.swift`: (a) in `.channelData` pre-handshake guard, drop `bytes != state.localIdentity`; (b) in `.send`, iterate `fragments.reversed()`; (c) in `establish`, skip `state.peers[identity] = channelID` on the `.keepNew` path; (d) in `.keepalive`, drop `channel.direction == .outbound`; (e) in `.channelData`, on reassembly `catch` call `tearDown(&state, channelID: channelID, strike: true)` and return it. Run `swift test --filter BLEInterfaceTests` — expected FAIL at least: `handshakeEchoingOurOwnIdentityIsIgnored`, `outboundSendIssuesOneDriverSendPerFragmentInOrder`, `sameDirectionHandshakeReplacesStaleChannelWithoutOfflineBlip`, `keepaliveNeverRunsOnInboundChannels`, `malformedFragmentLeavesChannelUp`. Revert all five. Run — all PASS.

- [ ] **Step 9: Full package run and commit**

Run: `swift test` — expected: all PASS (the only deleted coverage is the RBTP adapter's, restored in Tasks 6–8).

```bash
git -C /Users/ell/development/ios/pods/ReTiCA add -A Sources/ReTiCAInterfaces Sources/ReTiCANode/BLEEndpoint.swift Sources/ReTiCA/Packet/Packet.swift Tests/ReTiCAInterfacesTests Tests/ReTiCANodeTests Tests/ReTiCATests/Packet/PacketTests.swift
```
Commit: `feat: BLE reducer and driver seam speak ble-reticulum v2.2`.

---
### Task 6: FCB adapter — bring-up and central role (identity read, subscribe + handshake, writes)

**Files:**
- Create: `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift`
- Modify: `Sources/ReTiCAInterfaces/BLEDriver.swift` (`liveValue` → FCB-backed)
- Create: `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift`

**Interfaces:**
- Consumes: `BLEDriver`, `BLEDriverEvent`, `BLEDriverConfig` (Task 5); `BLEProtocol` (Task 2); FCB `BluetoothCentralClient` / `BluetoothPeripheralClient` (Task 1 signature).
- Produces: `actor FCBDriverAdapter` with `init(central:peripheral:now:)`, `nonisolated start(_:)`, `readIdentity(_:)`, `openChannel(_:)`, `send(_:data:)`, `closeChannel(_:)`, `disconnect(_:)`, `stop()`, `static let discoveryCooldown`; `func bleV22Service(localIdentity: Data) -> MutableService`; `extension BLEDriver { static func fcb(central:peripheral:) -> BLEDriver }`. Task 7 adds the peripheral data path to this same actor.

- [ ] **Step 1: Write the stubs and central-role tests**

Create `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift`:

```swift
import Testing
import Foundation
@preconcurrency import CoreBluetooth
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import FCBComposable

let serviceUUID = CBUUID(string: BLEProtocol.serviceUUID)
let txCharUUID = CBUUID(string: BLEProtocol.txCharUUID)
let rxCharUUID = CBUUID(string: BLEProtocol.rxCharUUID)
let identityCharUUID = CBUUID(string: BLEProtocol.identityCharUUID)
let adapterLocalIdentity = Data(repeating: 0x11, count: 16)
let adapterPeerIdentity = Data(repeating: 0xEE, count: 16)

/// Records the FCB commands the adapter invokes.
actor AdapterCalls {
    var addedServices: [MutableService] = []
    var advertised: [AdvertisementData?] = []
    var scanned = 0
    var stopScanned = 0
    var stoppedAdvertising = 0
    var removedAll = 0
    var connected: [UUID] = []
    var disconnected: [UUID] = []
    var discoveredServices: [UUID] = []
    var discoveredChars: [(UUID, CBUUID)] = []
    var readValues: [(UUID, CBUUID)] = []
    var setNotify: [(Bool, UUID, CBUUID)] = []
    var writes: [(Data, UUID, CBUUID, CBCharacteristicWriteType)] = []
    var responded: [(UUID, CBATTError.Code)] = []
    var updates: [(Data, CBUUID, [UUID]?)] = []

    func addService(_ s: MutableService) { addedServices.append(s) }
    func advertise(_ d: AdvertisementData?) { advertised.append(d) }
    func scan() { scanned += 1 }
    func stopScan() { stopScanned += 1 }
    func stopAdvertising() { stoppedAdvertising += 1 }
    func removeAll() { removedAll += 1 }
    func connect(_ id: UUID) { connected.append(id) }
    func disconnect(_ id: UUID) { disconnected.append(id) }
    func discoverServices(_ id: UUID) { discoveredServices.append(id) }
    func discoverChars(_ id: UUID, _ s: CBUUID) { discoveredChars.append((id, s)) }
    func read(_ id: UUID, _ c: CBUUID) { readValues.append((id, c)) }
    func notify(_ on: Bool, _ id: UUID, _ c: CBUUID) { setNotify.append((on, id, c)) }
    func write(_ d: Data, _ id: UUID, _ c: CBUUID, _ t: CBCharacteristicWriteType) { writes.append((d, id, c, t)) }
    func respond(_ id: UUID, _ code: CBATTError.Code) { responded.append((id, code)) }
    func update(_ d: Data, _ c: CBUUID, _ ids: [UUID]?) { updates.append((d, c, ids)) }
}

@MainActor
struct AdapterStubs {
    var central: BluetoothCentralClient
    var peripheral: BluetoothPeripheralClient
    let calls: AdapterCalls
    let centralState: AsyncStream<CBManagerState>.Continuation
    let peripheralState: AsyncStream<CBManagerState>.Continuation
    let scanCont: AsyncStream<DiscoveredPeripheral>.Continuation
    let centralEvents: AsyncStream<CentralEvent>.Continuation
    let writeRequests: AsyncStream<[WriteRequest]>.Continuation
    let subscriptions: AsyncStream<SubscriptionEvent>.Continuation
    let peripheralEvents: AsyncStream<PeripheralManagerEvent>.Continuation
    // Configurable behaviour.
    let identityResult: LockIsolated<Data?>            // nil → readValue throws
    let charsResult: LockIsolated<[CBUUID]>            // characteristics "discovered"
    let writeShouldThrow: LockIsolated<Bool>
    let mtu: LockIsolated<Int>
    let updateResult: LockIsolated<Bool>               // peripheral.updateValue return
    /// Notification continuations per peripheral id, minted when the adapter subscribes.
    let notifications: LockIsolated<[UUID: AsyncThrowingStream<Data, any Error>.Continuation]>
}

@MainActor
func makeStubs() -> AdapterStubs {
    let calls = AdapterCalls()
    let cState = AsyncStream<CBManagerState>.makeStream()
    let pState = AsyncStream<CBManagerState>.makeStream()
    let scan = AsyncStream<DiscoveredPeripheral>.makeStream()
    let cEvents = AsyncStream<CentralEvent>.makeStream()
    let writes = AsyncStream<[WriteRequest]>.makeStream()
    let subs = AsyncStream<SubscriptionEvent>.makeStream()
    let pEvents = AsyncStream<PeripheralManagerEvent>.makeStream()
    let identityResult = LockIsolated<Data?>(adapterPeerIdentity)
    let charsResult = LockIsolated<[CBUUID]>([txCharUUID, rxCharUUID, identityCharUUID])
    let writeShouldThrow = LockIsolated(false)
    let mtu = LockIsolated(512)
    let updateResult = LockIsolated(true)
    let notifications = LockIsolated<[UUID: AsyncThrowingStream<Data, any Error>.Continuation]>([:])

    let central = BluetoothCentralClient(
        state: { cState.stream },
        authorization: { .allowedAlways },
        scan: { _, _ in Task { await calls.scan() }; return scan.stream },
        stopScan: { await calls.stopScan() },
        connect: { id, _ in await calls.connect(id); return Peripheral(id: id, name: nil, state: .connected) },
        disconnect: { id in await calls.disconnect(id) },
        retrievePeripherals: { _ in [] },
        retrieveConnected: { _ in [] },
        discoverServices: { id, _ in await calls.discoverServices(id); return [Service(id: serviceUUID, peripheralID: id, isPrimary: true)] },
        discoverCharacteristics: { id, s, _ in
            await calls.discoverChars(id, s)
            return charsResult.value.map {
                Characteristic(id: $0, serviceID: serviceUUID, peripheralID: id, properties: .read, value: nil, isNotifying: false)
            }
        },
        readValue: { id, c in
            await calls.read(id, c)
            guard let r = identityResult.value else { throw BluetoothError.operationCancelled }
            return r
        },
        writeValue: { d, id, c, t in
            await calls.write(d, id, c, t)
            if writeShouldThrow.value { throw BluetoothError.disconnected(id, nil) }
        },
        setNotify: { on, id, c in await calls.notify(on, id, c) },
        maximumWriteValueLength: { _, _ in mtu.value },
        notifications: { id, _ in
            AsyncThrowingStream { cont in notifications.withValue { $0[id] = cont } }
        },
        openL2CAPChannel: { _, _ in throw BluetoothError.l2capNotSupported },
        events: { cEvents.stream }
    )

    let peripheral = BluetoothPeripheralClient(
        state: { pState.stream },
        authorization: { .allowedAlways },
        add: { s in await calls.addService(s); return Service(id: s.id, peripheralID: UUID(), isPrimary: true) },
        remove: { _ in },
        removeAll: { await calls.removeAll() },
        startAdvertising: { d in await calls.advertise(d) },
        stopAdvertising: { await calls.stopAdvertising() },
        isAdvertising: { true },
        respond: { id, code in await calls.respond(id, code) },
        updateValue: { d, c, ids in await calls.update(d, c, ids); return updateResult.value },
        publishL2CAPChannel: { _ in 0 },
        unpublishL2CAPChannel: { _ in },
        l2capConnections: { .finished },
        readRequests: { .finished },
        writeRequests: { writes.stream },
        subscriptions: { subs.stream },
        events: { pEvents.stream }
    )
    // NOTE: both initialisers are @DependencyClient memberwise inits — argument order MUST match
    // each client's property declaration order in FCBComposable.

    return AdapterStubs(
        central: central, peripheral: peripheral, calls: calls,
        centralState: cState.continuation, peripheralState: pState.continuation,
        scanCont: scan.continuation, centralEvents: cEvents.continuation,
        writeRequests: writes.continuation, subscriptions: subs.continuation,
        peripheralEvents: pEvents.continuation,
        identityResult: identityResult, charsResult: charsResult, writeShouldThrow: writeShouldThrow,
        mtu: mtu, updateResult: updateResult, notifications: notifications)
}

/// Collect up to `count` events (or until the stream ends) with a bounded wait.
func collect(_ stream: AsyncStream<BLEDriverEvent>, count: Int) async -> [BLEDriverEvent] {
    var out: [BLEDriverEvent] = []
    await withTaskGroup(of: [BLEDriverEvent].self) { group in
        group.addTask {
            var acc: [BLEDriverEvent] = []
            for await e in stream { acc.append(e); if acc.count >= count { break } }
            return acc
        }
        group.addTask { try? await Task.sleep(nanoseconds: 2_000_000_000); return [] }
        out = await group.next() ?? []
        group.cancelAll()
    }
    return out
}

func peer(_ b: UInt8) -> BLEPeerHandle { BLEPeerHandle(id: UUID(uuidString: "0000000\(b)-0000-0000-0000-000000000000")!) }

func disc(_ h: BLEPeerHandle) -> DiscoveredPeripheral {
    DiscoveredPeripheral(peripheral: Peripheral(id: h.id, name: nil, state: .disconnected),
                         advertisementData: AdvertisementData(serviceUUIDs: [serviceUUID]), rssi: -50)
}

@MainActor
func onlineAdapter() async -> (FCBDriverAdapter, AdapterStubs, AsyncStream<BLEDriverEvent>) {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    _ = await collect(events, count: 1)   // .ready
    return (adapter, stubs, events)
}

/// Drives readIdentity + openChannel for `p`; returns the outbound channel id.
@MainActor
func openOutbound(_ adapter: FCBDriverAdapter, _ stubs: AdapterStubs, _ events: AsyncStream<BLEDriverEvent>,
                  _ p: BLEPeerHandle) async -> BLEChannelID? {
    await adapter.readIdentity(p)
    _ = await collect(events, count: 1)   // identityRead
    await adapter.openChannel(p)
    let opened = await collect(events, count: 1)
    guard case let .channelOpened(cid, _, _, _)? = opened.first else { Issue.record("no channelOpened: \(opened)"); return nil }
    return cid
}

// MARK: - Bring-up

@Test @MainActor func startupPublishesV22ServiceAdvertisesScansThenReady() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    #expect(await collect(events, count: 1) == [.ready])
    let added = await stubs.calls.addedServices
    #expect(added.count == 1)
    let svc = added[0]
    #expect(svc.id == serviceUUID && svc.isPrimary)
    #expect(svc.characteristics.contains { $0.id == txCharUUID && $0.properties == [.read, .notify] && $0.value == nil })
    #expect(svc.characteristics.contains { $0.id == rxCharUUID && $0.properties == [.write, .writeWithoutResponse] && $0.permissions == .writeable })
    #expect(svc.characteristics.contains { $0.id == identityCharUUID && $0.properties == .read && $0.value == adapterLocalIdentity })
    #expect(await stubs.calls.advertised.first??.serviceUUIDs == [serviceUUID])
    #expect(await stubs.calls.scanned == 1)
    await adapter.stop()
}

@Test @MainActor func poweredOffEmitsUnavailableOnce() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.centralState.yield(.poweredOff)
    stubs.peripheralState.yield(.poweredOff)
    #expect(await collect(events, count: 1) == [.unavailable(.poweredOff)])
    await adapter.stop()
}

@Test @MainActor func readyWaitsForAdvertisingNotJustScanning() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    let recorded = LockIsolated<[BLEDriverEvent]>([])
    let drain = Task { for await e in events { recorded.withValue { $0.append(e) } } }
    stubs.centralState.yield(.poweredOn)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(recorded.value == [])
    stubs.peripheralState.yield(.poweredOn)
    try? await Task.sleep(nanoseconds: 300_000_000)
    #expect(recorded.value == [.ready])
    await adapter.stop()
    drain.cancel()
}

@Test @MainActor func adapterRetryStartWithoutStopFinishesPriorStream() async {
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events1 = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    #expect(await collect(events1, count: 1) == [.ready])
    _ = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    #expect(await collect(events1, count: 1) == [])   // finished, not hung
    await adapter.stop()
}

// MARK: - Discovery

@Test @MainActor func discoveryDedupsWithinCooldownAndReOffersAfter() async {
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral, now: { now.value })
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    _ = await collect(events, count: 1)
    let p1 = peer(1), p2 = peer(7)
    stubs.scanCont.yield(disc(p1)); stubs.scanCont.yield(disc(p1)); stubs.scanCont.yield(disc(p2))
    #expect(await collect(events, count: 2) == [.peerDiscovered(p1), .peerDiscovered(p2)])
    now.withValue { $0 = $0.addingTimeInterval(FCBDriverAdapter.discoveryCooldown + 1) }
    stubs.scanCont.yield(disc(p1))
    #expect(await collect(events, count: 1) == [.peerDiscovered(p1)])
    await adapter.stop()
}

// MARK: - Central role

@Test @MainActor func readIdentityHappyPath() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(2)
    await adapter.readIdentity(p)
    #expect(await collect(events, count: 1) == [.identityRead(p, identity: adapterPeerIdentity)])
    #expect(await stubs.calls.connected == [p.id])
    #expect(await stubs.calls.discoveredChars.map(\.1) == [serviceUUID])
    #expect(await stubs.calls.readValues.map(\.1) == [identityCharUUID])
    await adapter.stop()
}

@Test @MainActor func missingIdentityCharacteristicFailsAndDisconnects() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(3)
    stubs.charsResult.setValue([txCharUUID, rxCharUUID])
    await adapter.readIdentity(p)
    let got = await collect(events, count: 1)
    guard case .identityFailed(p, _)? = got.first else { Issue.record("expected identityFailed, got \(got)"); await adapter.stop(); return }
    #expect(await stubs.calls.disconnected.contains(p.id))
    #expect(await stubs.calls.readValues.isEmpty)
    await adapter.stop()
}

@Test @MainActor func shortIdentityReadFails() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(4)
    stubs.identityResult.setValue(Data(repeating: 1, count: 8))
    await adapter.readIdentity(p)
    guard case .identityFailed(p, _)? = (await collect(events, count: 1)).first else { Issue.record("expected identityFailed"); await adapter.stop(); return }
    #expect(await stubs.calls.disconnected.contains(p.id))
    await adapter.stop()
}

@Test @MainActor func readThrowFailsForgetsAndDisconnects() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(5)
    stubs.identityResult.setValue(nil)
    await adapter.readIdentity(p)
    guard case .identityFailed(p, _)? = (await collect(events, count: 1)).first else { Issue.record("expected identityFailed"); await adapter.stop(); return }
    #expect(await stubs.calls.disconnected.contains(p.id))
    stubs.scanCont.yield(disc(p))
    #expect(await collect(events, count: 1) == [.peerDiscovered(p)])   // forgotten → re-offered
    await adapter.stop()
}

@Test @MainActor func openChannelSubscribesWritesHandshakeAndReportsMTU() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(6)
    stubs.mtu.setValue(185)
    await adapter.readIdentity(p)
    _ = await collect(events, count: 1)
    await adapter.openChannel(p)
    let opened = await collect(events, count: 1)
    guard case let .channelOpened(_, hp, dir, mtu)? = opened.first else { Issue.record("no channelOpened: \(opened)"); await adapter.stop(); return }
    #expect(hp == p && dir == .outbound && mtu == 185)
    let notify = await stubs.calls.setNotify
    #expect(notify.count == 1 && notify[0].0 == true && notify[0].2 == txCharUUID)
    let writes = await stubs.calls.writes
    #expect(writes.count == 1 && writes[0].0 == adapterLocalIdentity && writes[0].2 == rxCharUUID && writes[0].3 == .withResponse)
    await adapter.stop()
}

@Test @MainActor func handshakeWriteFailureEmitsChannelFailedAndForgets() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(7)
    stubs.writeShouldThrow.setValue(true)
    await adapter.readIdentity(p)
    _ = await collect(events, count: 1)
    await adapter.openChannel(p)
    guard case .channelFailed(p, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelFailed"); await adapter.stop(); return }
    #expect(await stubs.calls.disconnected.contains(p.id))
    await adapter.stop()
}

@Test @MainActor func notificationsSurfaceAsChannelDataAndStreamEndCloses() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(8)
    guard let cid = await openOutbound(adapter, stubs, events, p) else { await adapter.stop(); return }
    let cont = stubs.notifications.value[p.id]
    cont?.yield(Data([0xAB, 0xCD]))
    #expect(await collect(events, count: 1) == [.channelData(cid, Data([0xAB, 0xCD]))])
    cont?.finish()
    guard case .channelClosed(cid, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelClosed"); await adapter.stop(); return }
    await adapter.stop()
}

@Test @MainActor func sendOnOutboundChannelWritesWithoutResponse() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(9)
    guard let cid = await openOutbound(adapter, stubs, events, p) else { await adapter.stop(); return }
    await adapter.send(cid, data: Data([1, 2, 3]))
    let writes = await stubs.calls.writes
    #expect(writes.last?.0 == Data([1, 2, 3]) && writes.last?.2 == rxCharUUID && writes.last?.3 == .withoutResponse)
    await adapter.stop()
}

@Test @MainActor func sendFailureClosesOutboundChannel() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(1)
    guard let cid = await openOutbound(adapter, stubs, events, p) else { await adapter.stop(); return }
    stubs.writeShouldThrow.setValue(true)
    await adapter.send(cid, data: Data([1]))
    guard case .channelClosed(cid, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelClosed"); await adapter.stop(); return }
    await adapter.stop()
}

@Test @MainActor func closeChannelDisconnectsSilently() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(2)
    guard let cid = await openOutbound(adapter, stubs, events, p) else { await adapter.stop(); return }
    await adapter.closeChannel(cid)
    #expect(await stubs.calls.disconnected.contains(p.id))
    stubs.notifications.value[p.id]?.finish()
    await adapter.stop()
    let tail = await collect(events, count: 5)
    #expect(!tail.contains { if case .channelClosed(cid, _) = $0 { return true }; return false })
}

@Test @MainActor func centralDisconnectEventClosesOutboundChannelAndForgets() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(3)
    guard let cid = await openOutbound(adapter, stubs, events, p) else { await adapter.stop(); return }
    stubs.centralEvents.yield(.didDisconnect(Peripheral(id: p.id, name: nil, state: .disconnected), nil))
    guard case .channelClosed(cid, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelClosed"); await adapter.stop(); return }
    stubs.scanCont.yield(disc(p))
    #expect(await collect(events, count: 1) == [.peerDiscovered(p)])
    await adapter.stop()
}

@Test @MainActor func disconnectVerbDropsTheGattConnection() async {
    let (adapter, stubs, _) = await onlineAdapter()
    await adapter.disconnect(peer(4))
    #expect(await stubs.calls.disconnected.contains(peer(4).id))
    await adapter.stop()
}

@Test @MainActor func sendToUnknownChannelIsDropped() async {
    let (adapter, _, _) = await onlineAdapter()
    await adapter.send(BLEChannelID(id: UUID()), data: Data([1]))
    await adapter.stop()
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FCBDriverAdapterTests` — expected: compile error, `FCBDriverAdapter` not found.

- [ ] **Step 3: Create the adapter**

`Sources/ReTiCAInterfaces/FCBDriverAdapter.swift`:

```swift
import Foundation
@preconcurrency import CoreBluetooth
import ComposableArchitecture
import FCBComposable

let bleV22ServiceUUID = CBUUID(string: BLEProtocol.serviceUUID)
let bleV22TXCharUUID = CBUUID(string: BLEProtocol.txCharUUID)
let bleV22RXCharUUID = CBUUID(string: BLEProtocol.rxCharUUID)
let bleV22IdentityCharUUID = CBUUID(string: BLEProtocol.identityCharUUID)

/// The ble-reticulum v2.2 GATT service: TX (read+notify), RX (write+WWR), Identity (read, static).
func bleV22Service(localIdentity: Data) -> MutableService {
    MutableService(id: bleV22ServiceUUID, isPrimary: true, characteristics: [
        MutableCharacteristic(id: bleV22TXCharUUID, properties: [.read, .notify], permissions: .readable, value: nil),
        MutableCharacteristic(id: bleV22RXCharUUID, properties: [.write, .writeWithoutResponse], permissions: .writeable, value: nil),
        MutableCharacteristic(id: bleV22IdentityCharUUID, properties: .read, permissions: .readable, value: localIdentity),
    ])
}

enum FCBAdapterError: Error, CustomStringConvertible {
    case missingCharacteristic(String)
    case shortIdentity(Int)
    var description: String {
        switch self {
        case let .missingCharacteristic(name): return "peer lacks \(name) characteristic"
        case let .shortIdentity(n): return "identity read returned \(n) bytes"
        }
    }
}

/// Mechanism-only adapter mapping FCB's two clients onto the BLEDriver contract.
/// No policy, no retries, no fragmentation — the BLEInterface reducer owns all of that.
actor FCBDriverAdapter {
    private let central: BluetoothCentralClient
    private let peripheral: BluetoothPeripheralClient
    private let now: @Sendable () -> Date

    /// Re-offer a seen peer after this long (discovery is a heartbeat the reducer re-evaluates).
    static let discoveryCooldown: TimeInterval = 5

    private var continuation: AsyncStream<BLEDriverEvent>.Continuation?
    private var config = BLEDriverConfig(localIdentity: Data(repeating: 0, count: BLEProtocol.identityLength))
    private var tasks: [Task<Void, Never>] = []

    private var advertising = false
    private var scanning = false
    private var announcedReady = false
    private var announcedUnavailable = false

    private var seenPeers: [UUID: Date] = [:]
    // Central role: outbound channels.
    private var outbound: [BLEChannelID: UUID] = [:]      // channel → peripheral id
    private var outboundByPeer: [UUID: BLEChannelID] = [:]
    private var reducerClosed: Set<BLEChannelID> = []

    init(central: BluetoothCentralClient, peripheral: BluetoothPeripheralClient,
         now: @escaping @Sendable () -> Date = { Date() }) {
        self.central = central
        self.peripheral = peripheral
        self.now = now
    }

    nonisolated func start(_ config: BLEDriverConfig) -> AsyncStream<BLEDriverEvent> {
        AsyncStream<BLEDriverEvent> { continuation in
            Task { await self.begin(config: config, continuation: continuation) }
        }
    }

    private func begin(config: BLEDriverConfig, continuation: AsyncStream<BLEDriverEvent>.Continuation) async {
        await resetSession()
        self.config = config
        self.continuation = continuation
        announcedReady = false
        announcedUnavailable = false
        seenPeers = [:]
        tasks.append(Task { [peripheral] in
            for await state in peripheral.state() { await self.handlePeripheralState(state) }
        })
        tasks.append(Task { [central] in
            for await state in central.state() { await self.handleCentralState(state) }
        })
        subscribeCentralEvents()
        subscribePeripheralStreams()
    }

    // MARK: - Bring-up

    private func handlePeripheralState(_ state: CBManagerState) async {
        switch state {
        case .poweredOn: await bringUpPeripheral()
        case .poweredOff, .unauthorized, .unsupported: fireUnavailable(Self.cause(state))
        default: break
        }
    }

    private func handleCentralState(_ state: CBManagerState) async {
        switch state {
        case .poweredOn: bringUpCentral()
        case .poweredOff, .unauthorized, .unsupported: fireUnavailable(Self.cause(state))
        default: break
        }
    }

    private func bringUpPeripheral() async {
        do {
            _ = try await peripheral.add(bleV22Service(localIdentity: config.localIdentity))
            try await peripheral.startAdvertising(AdvertisementData(serviceUUIDs: [bleV22ServiceUUID]))
            advertising = true
            checkReady()
        } catch {
            fireUnavailable(.other("peripheral setup failed: \(error)"))
        }
    }

    private func bringUpCentral() {
        tasks.append(Task { [central] in
            for await discovered in central.scan([bleV22ServiceUUID], ScanOptions(allowDuplicates: true)) {
                await self.handleDiscovered(discovered)
            }
        })
        scanning = true
        checkReady()
    }

    private func checkReady() {
        guard advertising, scanning, !announcedReady else { return }
        announcedReady = true
        continuation?.yield(.ready)
    }

    private func fireUnavailable(_ cause: BLEAdapterUnavailable) {
        guard !announcedUnavailable else { return }
        announcedUnavailable = true
        continuation?.yield(.unavailable(cause))
    }

    static func cause(_ s: CBManagerState) -> BLEAdapterUnavailable {
        switch s {
        case .poweredOff:   return .poweredOff
        case .unauthorized: return .unauthorized
        case .unsupported:  return .unsupported
        default:            return .other(nil)
        }
    }

    private func resetSession() async {
        for t in tasks { t.cancel() }
        tasks = []
        advertising = false
        scanning = false
        for peerID in outbound.values { try? await central.disconnect(peerID) }
        outbound = [:]
        outboundByPeer = [:]
        reducerClosed = []
        resetPeripheralSession()
        continuation?.finish()
        continuation = nil
    }

    // MARK: - Discovery

    private func subscribeCentralEvents() {
        tasks.append(Task { [central] in
            for await event in central.events() { await self.handleCentralEvent(event) }
        })
    }

    private func handleCentralEvent(_ event: CentralEvent) {
        if case let .didDisconnect(p, _) = event {
            forget(p.id)
            if let cid = outboundByPeer[p.id] { outboundDidClose(cid, reason: "disconnected") }
        }
    }

    private func handleDiscovered(_ discovered: DiscoveredPeripheral) {
        let id = discovered.peripheral.id
        let t = now()
        if let last = seenPeers[id], t.timeIntervalSince(last) < Self.discoveryCooldown { return }
        seenPeers[id] = t
        continuation?.yield(.peerDiscovered(BLEPeerHandle(id: id)))
    }

    private func forget(_ id: UUID) { seenPeers[id] = nil }

    // MARK: - Central role

    func readIdentity(_ peer: BLEPeerHandle) async {
        do {
            _ = try await central.connect(peer.id, nil)
            _ = try await central.discoverServices(peer.id, [bleV22ServiceUUID])
            let chars = try await central.discoverCharacteristics(
                peer.id, bleV22ServiceUUID, [bleV22TXCharUUID, bleV22RXCharUUID, bleV22IdentityCharUUID])
            guard chars.contains(where: { $0.id == bleV22IdentityCharUUID }) else {
                throw FCBAdapterError.missingCharacteristic("Identity")
            }
            let identity = try await central.readValue(peer.id, bleV22IdentityCharUUID)
            guard identity.count == BLEProtocol.identityLength else { throw FCBAdapterError.shortIdentity(identity.count) }
            continuation?.yield(.identityRead(peer, identity: Data(identity)))
        } catch {
            forget(peer.id)
            try? await central.disconnect(peer.id)
            continuation?.yield(.identityFailed(peer, reason: "\(error)"))
        }
    }

    func openChannel(_ peer: BLEPeerHandle) async {
        let channelID = BLEChannelID(id: UUID())
        // Create the notification stream BEFORE enabling notifications so nothing is missed.
        let stream = central.notifications(peer.id, bleV22TXCharUUID)
        let pump = Task { [stream] in
            do { for try await chunk in stream { await self.emitChannelData(channelID, chunk) } } catch {}
            await self.outboundDidClose(channelID, reason: "notifications ended")
        }
        do {
            try await central.setNotify(true, peer.id, bleV22TXCharUUID)
            try await central.writeValue(config.localIdentity, peer.id, bleV22RXCharUUID, .withResponse)
            let mtu = await central.maximumWriteValueLength(peer.id, .withoutResponse)
            outbound[channelID] = peer.id
            outboundByPeer[peer.id] = channelID
            tasks.append(pump)
            continuation?.yield(.channelOpened(channelID, peer, direction: .outbound, mtu: mtu))
        } catch {
            pump.cancel()
            forget(peer.id)
            try? await central.disconnect(peer.id)
            continuation?.yield(.channelFailed(peer, reason: "\(error)"))
        }
    }

    private func emitChannelData(_ id: BLEChannelID, _ data: Data) {
        guard outbound[id] != nil || isInbound(id) else { return }
        continuation?.yield(.channelData(id, data))
    }

    private func outboundDidClose(_ id: BLEChannelID, reason: String?) {
        guard let peerID = outbound.removeValue(forKey: id) else { return }
        outboundByPeer[peerID] = nil
        if reducerClosed.remove(id) == nil {
            continuation?.yield(.channelClosed(id, reason: reason))
        }
    }

    // MARK: - BLEDriver verbs

    func send(_ channel: BLEChannelID, data: Data) async {
        if let peerID = outbound[channel] {
            do { try await central.writeValue(data, peerID, bleV22RXCharUUID, .withoutResponse) }
            catch { outboundDidClose(channel, reason: "write failed: \(error)") }
            return
        }
        await sendInbound(channel, data: data)
    }

    func closeChannel(_ channel: BLEChannelID) async {
        if let peerID = outbound[channel] {
            reducerClosed.insert(channel)
            outbound[channel] = nil
            outboundByPeer[peerID] = nil
            try? await central.disconnect(peerID)
            return
        }
        closeInbound(channel)
    }

    func disconnect(_ peer: BLEPeerHandle) async {
        try? await central.disconnect(peer.id)
    }

    func stop() async {
        await resetSession()
        await central.stopScan()
        await peripheral.stopAdvertising()
        await peripheral.removeAll()
    }

    // MARK: - Peripheral role (Task 7 fills these in)

    private func subscribePeripheralStreams() {}
    private func resetPeripheralSession() {}
    private func isInbound(_ id: BLEChannelID) -> Bool { false }
    private func sendInbound(_ channel: BLEChannelID, data: Data) async {}
    private func closeInbound(_ channel: BLEChannelID) {}
}

extension BLEDriver {
    /// Composes FCB's clients into the BLEDriver contract.
    public static func fcb(central: BluetoothCentralClient, peripheral: BluetoothPeripheralClient) -> BLEDriver {
        let adapter = FCBDriverAdapter(central: central, peripheral: peripheral)
        return BLEDriver(
            start: { config in adapter.start(config) },
            readIdentity: { peer in await adapter.readIdentity(peer) },
            openChannel: { peer in await adapter.openChannel(peer) },
            send: { channel, data in await adapter.send(channel, data: data) },
            closeChannel: { channel in await adapter.closeChannel(channel) },
            disconnect: { peer in await adapter.disconnect(peer) },
            stop: { await adapter.stop() }
        )
    }
}
```

The five one-line peripheral hooks at the bottom are the seam Task 7 replaces; they are complete no-ops for this task's scope (inbound channels do not exist yet), not placeholders.

In `BLEDriver.swift` restore the live value:
```swift
    public static var liveValue: BLEDriver {
        #if canImport(CoreBluetooth) && (os(iOS) || os(macOS))
        return .fcb(central: .liveValue, peripheral: .liveValue)
        #else
        return BLEDriver(start: { _ in .finished }, readIdentity: { _ in }, openChannel: { _ in },
                         send: { _, _ in }, closeChannel: { _ in }, stop: {})
        #endif
    }
```

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter FCBDriverAdapterTests` — expected: all PASS.

- [ ] **Step 5: Mutate, verify, revert**

Batch: (a) in `readIdentity` drop the `chars.contains(...)` guard; (b) in `openChannel` write the handshake with `.withoutResponse`; (c) in `send` swallow the write error (no `outboundDidClose`); (d) in `closeChannel` skip `reducerClosed.insert(channel)` and call `outboundDidClose(channel, reason: nil)` instead of clearing maps. Run `swift test --filter FCBDriverAdapterTests` — expected FAIL: `missingIdentityCharacteristicFailsAndDisconnects`, `openChannelSubscribesWritesHandshakeAndReportsMTU`, `sendFailureClosesOutboundChannel`, `closeChannelDisconnectsSilently`. Revert. Run — all PASS.

- [ ] **Step 6: Commit**

`git add Sources/ReTiCAInterfaces/FCBDriverAdapter.swift Sources/ReTiCAInterfaces/BLEDriver.swift Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift` — `feat: FCB adapter central role for BLE v2.2`.

---
### Task 7: FCB adapter — peripheral role (subscriptions, RX writes, notify FIFO, held handshake)

**Files:**
- Modify: `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift` (replace the five peripheral hooks; add state)
- Modify: `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift` (append)

**Interfaces:**
- Consumes: Task 6's actor and stubs; FCB `subscriptions()`, `writeRequests()`, `readRequests()`, `events()`, `respond`, `updateValue -> Bool`; `Central.maximumUpdateValueLength`.
- Produces: inbound channels — `channelOpened(.inbound, mtu: central.maximumUpdateValueLength)` on TX subscription; RX writes → `channelData`; `send` on an inbound channel → TX notify targeted at that central through a per-channel FIFO (cap `notifyQueueCap = 256`) that parks on `false` until `.isReadyToUpdateSubscribers`; held RX write replay (`heldWriteWindow = 2 s`); `closeChannel` on inbound drops the mapping silently.

- [ ] **Step 1: Write the failing tests**

Append to `FCBDriverAdapterTests.swift`:

```swift
// MARK: - Peripheral role

func centralValue(_ b: UInt8, mtu: Int = 185) -> Central {
    Central(id: UUID(uuidString: "C000000\(b)-0000-0000-0000-000000000000")!, maximumUpdateValueLength: mtu)
}
func txChar() -> Characteristic {
    Characteristic(id: txCharUUID, serviceID: serviceUUID, peripheralID: UUID(), properties: [.read, .notify], value: nil, isNotifying: true)
}
func rxWrite(_ c: Central, _ value: Data) -> WriteRequest {
    WriteRequest(id: UUID(), central: c, characteristic:
        Characteristic(id: rxCharUUID, serviceID: serviceUUID, peripheralID: UUID(), properties: [.write, .writeWithoutResponse], value: nil, isNotifying: false),
        offset: 0, value: value)
}

/// Subscribes `c` to TX and returns the inbound channel id.
@MainActor
func subscribeInbound(_ stubs: AdapterStubs, _ events: AsyncStream<BLEDriverEvent>, _ c: Central) async -> BLEChannelID? {
    stubs.subscriptions.yield(.subscribed(central: c, characteristic: txChar()))
    let got = await collect(events, count: 1)
    guard case let .channelOpened(cid, hp, dir, mtu)? = got.first else { Issue.record("no inbound channelOpened: \(got)"); return nil }
    #expect(hp == BLEPeerHandle(id: c.id) && dir == .inbound && mtu == c.maximumUpdateValueLength)
    return cid
}

@Test @MainActor func txSubscriptionOpensInboundChannelWithCentralsMTU() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let c = centralValue(1, mtu: 244)
    let cid = await subscribeInbound(stubs, events, c)
    #expect(cid != nil)
    await adapter.stop()
}

@Test @MainActor func rxWritesSurfaceAsChannelDataAndAreResponded() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let c = centralValue(2)
    guard let cid = await subscribeInbound(stubs, events, c) else { await adapter.stop(); return }
    let req = rxWrite(c, adapterPeerIdentity)
    stubs.writeRequests.yield([req])
    #expect(await collect(events, count: 1) == [.channelData(cid, adapterPeerIdentity)])
    let responded = await stubs.calls.responded
    #expect(responded.contains { $0.0 == req.id && $0.1 == .success })
    await adapter.stop()
}

@Test @MainActor func writeBatchEmitsEachValueInOrder() async {
    // Review Focus 3.
    let (adapter, stubs, events) = await onlineAdapter()
    let c = centralValue(3)
    guard let cid = await subscribeInbound(stubs, events, c) else { await adapter.stop(); return }
    stubs.writeRequests.yield([rxWrite(c, Data([1])), rxWrite(c, Data([2])), rxWrite(c, Data([3]))])
    #expect(await collect(events, count: 3) == [.channelData(cid, Data([1])), .channelData(cid, Data([2])), .channelData(cid, Data([3]))])
    await adapter.stop()
}

@Test @MainActor func unsubscribeClosesInboundChannel() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let c = centralValue(4)
    guard let cid = await subscribeInbound(stubs, events, c) else { await adapter.stop(); return }
    stubs.subscriptions.yield(.unsubscribed(central: c, characteristic: txChar()))
    guard case .channelClosed(cid, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelClosed"); await adapter.stop(); return }
    await adapter.stop()
}

@Test @MainActor func resubscribeMintsNewChannelAndClosesOld() async {
    // Review Focus 4 (adapter half).
    let (adapter, stubs, events) = await onlineAdapter()
    let c = centralValue(5)
    guard let first = await subscribeInbound(stubs, events, c) else { await adapter.stop(); return }
    stubs.subscriptions.yield(.subscribed(central: c, characteristic: txChar()))
    let got = await collect(events, count: 2)
    #expect(got.contains { if case .channelClosed(first, _) = $0 { return true }; return false })
    #expect(got.contains { if case let .channelOpened(cid, _, .inbound, _) = $0 { return cid != first }; return false })
    await adapter.stop()
}

@Test @MainActor func sendOnInboundChannelNotifiesOnlyThatCentral() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let c = centralValue(6)
    guard let cid = await subscribeInbound(stubs, events, c) else { await adapter.stop(); return }
    await adapter.send(cid, data: Data([9, 9]))
    try? await Task.sleep(nanoseconds: 100_000_000)
    let updates = await stubs.calls.updates
    #expect(updates.count == 1 && updates[0].0 == Data([9, 9]) && updates[0].1 == txCharUUID && updates[0].2 == [c.id])
    await adapter.stop()
}

@Test @MainActor func notifyQueueParksOnFalseAndResumesOnReady() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let c = centralValue(7)
    guard let cid = await subscribeInbound(stubs, events, c) else { await adapter.stop(); return }
    stubs.updateResult.setValue(false)              // CoreBluetooth queue full
    await adapter.send(cid, data: Data([1]))
    await adapter.send(cid, data: Data([2]))
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(await stubs.calls.updates.count == 1)   // tried [1] once, parked; [2] never attempted
    stubs.updateResult.setValue(true)
    stubs.peripheralEvents.yield(.isReadyToUpdateSubscribers)
    try? await Task.sleep(nanoseconds: 200_000_000)
    let updates = await stubs.calls.updates
    #expect(updates.map(\.0) == [Data([1]), Data([1]), Data([2])])   // [1] retried, then [2]
    await adapter.stop()
}

@Test @MainActor func notifyQueueOverflowClosesChannel() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let c = centralValue(8)
    guard let cid = await subscribeInbound(stubs, events, c) else { await adapter.stop(); return }
    stubs.updateResult.setValue(false)
    for i in 0...FCBDriverAdapter.notifyQueueCap { await adapter.send(cid, data: Data([UInt8(i & 0xFF)])) }
    guard case .channelClosed(cid, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelClosed on overflow"); await adapter.stop(); return }
    await adapter.stop()
}

@Test @MainActor func heldHandshakeIsReplayedWhenSubscriptionArrivesLate() async {
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral, now: { now.value })
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    _ = await collect(events, count: 1)
    let c = centralValue(9)
    stubs.writeRequests.yield([rxWrite(c, adapterPeerIdentity)])   // before any subscription
    try? await Task.sleep(nanoseconds: 100_000_000)
    now.withValue { $0 = $0.addingTimeInterval(1) }
    stubs.subscriptions.yield(.subscribed(central: c, characteristic: txChar()))
    let got = await collect(events, count: 2)
    guard got.count == 2, case let .channelOpened(cid, _, .inbound, _) = got[0] else { Issue.record("unexpected: \(got)"); await adapter.stop(); return }
    #expect(got[1] == .channelData(cid, adapterPeerIdentity))
    await adapter.stop()
}

@Test @MainActor func heldWriteExpiresAfterWindow() async {
    let now = LockIsolated(Date(timeIntervalSince1970: 1000))
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral, now: { now.value })
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    _ = await collect(events, count: 1)
    let c = centralValue(1)
    stubs.writeRequests.yield([rxWrite(c, adapterPeerIdentity)])
    try? await Task.sleep(nanoseconds: 100_000_000)
    now.withValue { $0 = $0.addingTimeInterval(FCBDriverAdapter.heldWriteWindow + 0.5) }
    stubs.subscriptions.yield(.subscribed(central: c, characteristic: txChar()))
    let got = await collect(events, count: 2)   // times out after the single channelOpened
    #expect(got.count == 1)
    await adapter.stop()
}

@Test @MainActor func closeInboundChannelIsSilent() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let c = centralValue(2)
    guard let cid = await subscribeInbound(stubs, events, c) else { await adapter.stop(); return }
    await adapter.closeChannel(cid)
    stubs.subscriptions.yield(.unsubscribed(central: c, characteristic: txChar()))
    stubs.writeRequests.yield([rxWrite(c, Data([1]))])   // after close: dropped
    await adapter.stop()
    let tail = await collect(events, count: 5)
    #expect(!tail.contains { if case .channelClosed(cid, _) = $0 { return true }; return false })
    #expect(!tail.contains { if case .channelData(cid, _) = $0 { return true }; return false })
}

@Test @MainActor func readRequestsOnTXAreAnsweredSuccess() async {
    let stubs = makeStubs()
    let reads = AsyncStream<ReadRequest>.makeStream()
    var p = stubs.peripheral
    p.readRequests = { reads.stream }
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: p)
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    _ = await collect(events, count: 1)
    let req = ReadRequest(id: UUID(), central: centralValue(3), characteristic: txChar(), offset: 0)
    reads.continuation.yield(req)
    try? await Task.sleep(nanoseconds: 100_000_000)
    #expect(await stubs.calls.responded.contains { $0.0 == req.id && $0.1 == .success })
    await adapter.stop()
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter FCBDriverAdapterTests` — expected: compile errors (`notifyQueueCap`, `heldWriteWindow` missing), and the peripheral tests fail once those constants exist.

- [ ] **Step 3: Implement the peripheral role**

In `FCBDriverAdapter.swift` add state after `reducerClosed`:

```swift
    // Peripheral role: inbound channels (one per subscribed central).
    static let notifyQueueCap = 256
    static let heldWriteWindow: TimeInterval = 2
    private var inbound: [BLEChannelID: Central] = [:]
    private var inboundByCentral: [UUID: BLEChannelID] = [:]
    private var notifyQueues: [BLEChannelID: [Data]] = [:]
    private var notifyParked = false
    private var heldWrites: [UUID: (data: Data, at: Date)] = [:]
```

Replace the five hooks with:

```swift
    // MARK: - Peripheral role

    private func subscribePeripheralStreams() {
        tasks.append(Task { [peripheral] in
            for await event in peripheral.subscriptions() { await self.handleSubscription(event) }
        })
        tasks.append(Task { [peripheral] in
            for await batch in peripheral.writeRequests() { await self.handleWrites(batch) }
        })
        tasks.append(Task { [peripheral] in
            for await request in peripheral.readRequests() { await peripheral.respond(request.id, .success) }
        })
        tasks.append(Task { [peripheral] in
            for await event in peripheral.events() {
                if case .isReadyToUpdateSubscribers = event { await self.notifyReady() }
            }
        })
    }

    private func resetPeripheralSession() {
        inbound = [:]
        inboundByCentral = [:]
        notifyQueues = [:]
        notifyParked = false
        heldWrites = [:]
    }

    private func isInbound(_ id: BLEChannelID) -> Bool { inbound[id] != nil }

    private func handleSubscription(_ event: SubscriptionEvent) {
        switch event {
        case let .subscribed(central, characteristic):
            guard characteristic.id == bleV22TXCharUUID else { return }
            if let old = inboundByCentral[central.id] { inboundDidClose(old, reason: "resubscribed") }
            let channelID = BLEChannelID(id: UUID())
            inbound[channelID] = central
            inboundByCentral[central.id] = channelID
            continuation?.yield(.channelOpened(channelID, BLEPeerHandle(id: central.id), direction: .inbound,
                                               mtu: central.maximumUpdateValueLength))
            if let held = heldWrites.removeValue(forKey: central.id),
               now().timeIntervalSince(held.at) <= Self.heldWriteWindow {
                continuation?.yield(.channelData(channelID, held.data))
            }
        case let .unsubscribed(central, characteristic):
            guard characteristic.id == bleV22TXCharUUID, let cid = inboundByCentral[central.id] else { return }
            inboundDidClose(cid, reason: "unsubscribed")
        }
    }

    private func handleWrites(_ batch: [WriteRequest]) async {
        // CoreBluetooth wants ONE respond per batch (the first request); a without-response
        // write's respond is a harmless no-op.
        if let first = batch.first { await peripheral.respond(first.id, .success) }
        for request in batch where request.characteristic.id == bleV22RXCharUUID {
            guard let value = request.value else { continue }
            if let cid = inboundByCentral[request.central.id] {
                continuation?.yield(.channelData(cid, Data(value)))
            } else {
                let t = now()
                heldWrites = heldWrites.filter { t.timeIntervalSince($0.value.at) <= Self.heldWriteWindow }
                heldWrites[request.central.id] = (Data(value), t)
            }
        }
    }

    private func sendInbound(_ channel: BLEChannelID, data: Data) async {
        guard inbound[channel] != nil else { return }
        notifyQueues[channel, default: []].append(data)
        if notifyQueues[channel]!.count > Self.notifyQueueCap {
            inboundDidClose(channel, reason: "notify backlog")
            return
        }
        await drainNotifyQueues()
    }

    private func drainNotifyQueues() async {
        guard !notifyParked else { return }
        for channel in notifyQueues.keys.sorted(by: { $0.id.uuidString < $1.id.uuidString }) {
            guard let central = inbound[channel] else { notifyQueues[channel] = nil; continue }
            while let next = notifyQueues[channel]?.first {
                let ok: Bool
                do { ok = try await peripheral.updateValue(next, bleV22TXCharUUID, [central.id]) }
                catch { inboundDidClose(channel, reason: "notify failed: \(error)"); break }
                if !ok { notifyParked = true; return }   // leave `next` queued; retry on ready
                notifyQueues[channel]?.removeFirst()
            }
            if notifyQueues[channel]?.isEmpty == true { notifyQueues[channel] = nil }
        }
    }

    private func notifyReady() async {
        notifyParked = false
        await drainNotifyQueues()
    }

    private func closeInbound(_ channel: BLEChannelID) {
        guard let central = inbound.removeValue(forKey: channel) else { return }
        inboundByCentral[central.id] = nil
        notifyQueues[channel] = nil
        reducerClosed.insert(channel)
    }

    private func inboundDidClose(_ channel: BLEChannelID, reason: String?) {
        guard let central = inbound.removeValue(forKey: channel) else { return }
        inboundByCentral[central.id] = nil
        notifyQueues[channel] = nil
        if reducerClosed.remove(channel) == nil {
            continuation?.yield(.channelClosed(channel, reason: reason))
        }
    }
```

`closeInbound` marks the channel reducer-closed so a later `unsubscribed` for that central emits nothing; `handleSubscription`'s unsubscribed branch finds no mapping and returns, which already satisfies that. Remove the `reducerClosed.insert(channel)` line from `closeInbound` if the compiler warns it is never read for inbound ids — it is not needed because the mapping is gone.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter FCBDriverAdapterTests` — expected: all PASS.

- [ ] **Step 5: Mutate, verify, revert**

Batch: (a) in `handleSubscription` pass `mtu: 23` instead of the central's; (b) in `drainNotifyQueues` treat `!ok` as success (`removeFirst` regardless); (c) in `sendInbound` remove the cap check; (d) in `handleSubscription` drop the held-write replay; (e) in `handleWrites` emit only `batch.first`. Run `swift test --filter FCBDriverAdapterTests` — expected FAIL: `txSubscriptionOpensInboundChannelWithCentralsMTU`, `notifyQueueParksOnFalseAndResumesOnReady`, `notifyQueueOverflowClosesChannel`, `heldHandshakeIsReplayedWhenSubscriptionArrivesLate`, `writeBatchEmitsEachValueInOrder`. Revert. Run — all PASS.

- [ ] **Step 6: Commit**

`git add Sources/ReTiCAInterfaces/FCBDriverAdapter.swift Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift` — `feat: FCB adapter peripheral role for BLE v2.2`.

---

### Task 8: CoreBluetoothMock integration — real FCB central against a simulated v2.2 peripheral

**Files:**
- Create: `Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMTests.swift`

**Interfaces:**
- Consumes: `BLEDriver.fcb(central: .mocked(), peripheral:)` (FCB provides `.mocked()` for the central, as the deleted RBTP test used), CoreBluetoothMock's `CBMPeripheralSpec`, `CBMPeripheralSpecDelegate`.

- [ ] **Step 1: Write the test**

```swift
import Testing
import Foundation
@preconcurrency import CoreBluetooth
@preconcurrency import CoreBluetoothMock
import ComposableArchitecture
@testable import ReTiCAInterfaces
@testable import FCBComposable

/// Simulated ble-reticulum peripheral: answers the Identity read, accepts the RX handshake write,
/// and records what was written.
final class V22SpecDelegate: CBMPeripheralSpecDelegate, @unchecked Sendable {
    let identity = Data(repeating: 0xEE, count: 16)
    let writes = LockIsolated<[Data]>([])

    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveReadRequestFor characteristic: CBMCharacteristicMock) -> Result<Data, any Error> {
        characteristic.uuid == identityCharUUID ? .success(identity) : .failure(CBATTError(.attributeNotFound))
    }
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveWriteRequestFor characteristic: CBMCharacteristicMock, data: Data) -> Result<Void, any Error> {
        writes.withValue { $0.append(data) }
        return .success(())
    }
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveWriteCommandFor characteristic: CBMCharacteristicMock, data: Data) {
        writes.withValue { $0.append(data) }
    }
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveSetNotifyRequest enabled: Bool, for characteristic: CBMCharacteristicMock) -> Result<Void, any Error> {
        .success(())
    }
}

@MainActor
func noopPeripheralClient() -> BluetoothPeripheralClient {
    var client = BluetoothPeripheralClient.testValue
    client.state = { AsyncStream { $0.finish() } }
    client.add = { s in Service(id: s.id, peripheralID: UUID(), isPrimary: true) }
    client.startAdvertising = { _ in }
    client.stopAdvertising = { }
    client.removeAll = { }
    client.respond = { _, _ in }
    client.subscriptions = { .finished }
    client.writeRequests = { .finished }
    client.readRequests = { .finished }
    client.events = { .finished }
    return client
}

/// CBM simulation is process-global; keep this in its own serialized suite.
@Suite(.serialized) @MainActor
struct FCBDriverAdapterCBMTests {
    @Test func realCentralReadsIdentitySubscribesAndHandshakesAgainstMock() async throws {
        CBMCentralManagerMock.tearDownSimulation()
        CBMCentralManagerMock.simulateInitialState(.poweredOn)

        let id = UUID()
        let tx = CBMCharacteristicMock(type: txCharUUID, properties: [.read, .notify])
        let rx = CBMCharacteristicMock(type: rxCharUUID, properties: [.write, .writeWithoutResponse])
        let ident = CBMCharacteristicMock(type: identityCharUUID, properties: [.read])
        let service = CBMServiceMock(type: serviceUUID, primary: true, characteristics: tx, rx, ident)
        let delegate = V22SpecDelegate()
        let spec = CBMPeripheralSpec
            .simulatePeripheral(identifier: id, proximity: .near)
            .advertising(advertisementData: [CBMAdvertisementDataServiceUUIDsKey: [serviceUUID],
                                             CBMAdvertisementDataIsConnectable: true as NSNumber],
                         withInterval: 0.05)
            .connectable(name: "rns-pi", services: [service], delegate: delegate, connectionInterval: 0.01)
            .build()
        CBMCentralManagerMock.simulatePeripherals([spec])

        let driver = BLEDriver.fcb(central: .mocked(), peripheral: noopPeripheralClient())
        let events = driver.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
        let buffer = LockIsolated<[BLEDriverEvent]>([])
        let pump = Task { for await e in events { buffer.withValue { $0.append(e) } } }
        defer { pump.cancel() }

        func waitFor(_ match: @Sendable @escaping (BLEDriverEvent) -> Bool) async -> BLEDriverEvent? {
            for _ in 0..<300 {
                if let hit = buffer.withValue({ $0.first(where: match) }) { return hit }
                try? await Task.sleep(nanoseconds: 20_000_000)
            }
            return nil
        }

        guard case let .peerDiscovered(handle)? = await waitFor({ if case .peerDiscovered = $0 { return true }; return false })
        else { Issue.record("no peerDiscovered"); await driver.stop(); return }

        await driver.readIdentity(handle)
        let read = await waitFor { if case .identityRead = $0 { return true }; if case .identityFailed = $0 { return true }; return false }
        #expect(read == .identityRead(handle, identity: delegate.identity))

        await driver.openChannel(handle)
        let opened = await waitFor { if case .channelOpened = $0 { return true }; if case .channelFailed = $0 { return true }; return false }
        guard case let .channelOpened(cid, h, dir, mtu)? = opened else { Issue.record("expected channelOpened, got \(String(describing: opened))"); await driver.stop(); return }
        #expect(h == handle && dir == .outbound && mtu >= BLEFragmenter.minimumMTU)
        #expect(delegate.writes.value.first == adapterLocalIdentity)   // the handshake reached the peripheral

        // A notification from the mock peripheral surfaces as channelData.
        _ = spec.simulateValueUpdate(Data([0x01, 0x00, 0x00, 0x00, 0x01, 0x42]), for: tx)
        let data = await waitFor { if case .channelData = $0 { return true }; return false }
        #expect(data == .channelData(cid, Data([0x01, 0x00, 0x00, 0x00, 0x01, 0x42])))

        await driver.stop()
    }
}
```

The `CBMPeripheralSpecDelegate` method names above match CoreBluetoothMock 1.x; if the compiler rejects one, open `.build/checkouts/IOS-CoreBluetooth-Mock/CoreBluetoothMock/Classes/CBMPeripheralSpec.swift` and use the exact signature declared there — the intent of each method is unchanged.

- [ ] **Step 2: Run**

Run: `swift test --filter FCBDriverAdapterCBMTests` — expected: PASS.

- [ ] **Step 3: Mutate, verify, revert**

Mutation: in `FCBDriverAdapter.openChannel` swap the order so `writeValue` runs before `setNotify` AND write `Data(repeating: 0, count: 16)` instead of `config.localIdentity`. Run — expected FAIL on the handshake expectation. Revert. Run — PASS.

- [ ] **Step 4: Commit**

`git add Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMTests.swift` — `test: CoreBluetoothMock run of the v2.2 central path`.

---
### Task 9: `HW_MTU` 500, hardware checklist, punch-list note, final verification

**Files:**
- Modify: `Sources/ReTiCATransport/InterfaceProfile.swift:51`
- Modify: `Tests/ReTiCATransportTests/InterfaceProfileTests.swift:23`
- Create: `docs/superpowers/plans/2026-09-26-ble-v22-hardware-checklist.md`
- Modify: `docs/superpowers/2026-08-24-ble-punch-list.md` (prepend a status note)

**Interfaces:**
- Produces: `InterfaceProfile.ble.hwMTU == 500` (spec §2.8) — Transport's outbound sizing for BLE peers now matches ble-reticulum's `HW_MTU`.

- [ ] **Step 1: Flip the profile test first**

`InterfaceProfileTests.swift:23`: `#expect(InterfaceProfile.ble.hwMTU == 500)`.
Run: `swift test --filter InterfaceProfileTests` — expected: FAIL (still 1196).

- [ ] **Step 2: Change the profile**

`InterfaceProfile.swift:51`:
```swift
    /// ble-reticulum protocol v2.2 peers: HW_MTU 500 (BLEInterface.HW_MTU in the reference);
    /// 80 kbps is a conservative guess until measured live (spec §2.8).
    public static let ble = InterfaceProfile(name: "ble", bitrate: 80_000, hwMTU: 500)
```
Run: `swift test --filter InterfaceProfileTests` — expected: PASS. (No mutation step: the test is a pinned constant; the failing run in Step 1 is the proof.)

- [ ] **Step 3: Write the hardware checklist**

Create `docs/superpowers/plans/2026-09-26-ble-v22-hardware-checklist.md`:

```markdown
# BLE v2.2 — Hardware Verification Checklist

Manual verification of the live FCB adapter against real radios (no automated coverage —
the reducer owns all policy and is TestStore-tested; this checks the mechanism and interop).
Spec: `docs/superpowers/specs/2026-09-26-ble-v22-gatt-driver-design.md`.

## Pi reference node (do this first)
- [ ] Raspberry Pi (Pi 4 / Zero 2 W preferred) with stock `rns` installed and ble-reticulum
      v0.2.2 installed per its README (`./install.sh`, experimental BlueZ, JustWorksRepairing).
- [ ] `rnsd -vvv` shows `BLEInterface` advertising and scanning; a second Pi (or Columba)
      connects and exchanges an LXMF message — proves the reference before touching iOS.

## App prerequisites (consuming app, not this package)
- [ ] `NSBluetoothAlwaysUsageDescription` in Info.plist (punch-list A2).
- [ ] BLE endpoint slot constructed with `BLEEndpoint.State(localIdentity: identity.hash)` (A1).
- [ ] Foreground both sides for bring-up; backgrounded iPhones are invisible to BlueZ.

## iPhone → Pi (iPhone as central)
- [ ] iPhone discovers the Pi (`peerDiscovered`) within a few seconds of both being up.
- [ ] `identityRead` carries the Pi's 16-byte identity; Pi log shows a central connect.
- [ ] `channelOpened(.outbound, mtu: …)` — record the MTU CoreBluetooth reports.
- [ ] Pi log: `received identity handshake from central …` and `created peer interface`.
- [ ] `rnstatus` on the Pi lists the iPhone peer interface.
- [ ] Small LXMF message Pi → iPhone and iPhone → Pi (single-fragment packets).
- [ ] > 391 B LXMF message both ways (resource transfer over fragmented packets).
- [ ] Keepalive: Pi log at EXTREME level shows `received keep-alive from central` every 15 s.
- [ ] Walk out of range and back: `peerOffline`, then re-establishment without restarting either side.
- [ ] Kill/relaunch the iOS app three times within 10 s windows: Pi greylists (`blacklisted`
      log lines) and recovers after backoff; iOS side strikes likewise.

## Pi → iPhone (Pi as central) — EXPECTED TO FAIL until the upstream fix
- [ ] Confirm the Pi never completes a connection to the iPhone (ble-reticulum dials with
      `AddressType: public`; iPhones use random addresses). Record the Pi's error text for the
      upstream PR. iPhone → Pi must keep working while the Pi retries.

## iPhone ↔ iPhone
- [ ] Both discover each other; exactly ONE surviving channel after duplicate resolution (the
      lower identity's outbound channel wins; both logs agree on the direction).
- [ ] Packets flow both ways; > 391 B message both ways.
- [ ] Toggle Bluetooth off on A: A `waitingForAdapter`, peers offline; toggle on: recovers.

## Columba (Android) — when available
- [ ] iPhone → Columba and Columba → iPhone establish; check for duplicate-rule disagreement
      on a simultaneous cross-connect (spec §2.7): at worst one churn cycle, never a wedge.

## Results
Record MTU, throughput and latency here for the spec's §2.8 bitrate revision.
```

- [ ] **Step 4: Note the protocol switch in the punch list**

Prepend to `docs/superpowers/2026-08-24-ble-punch-list.md`, directly under the title line:

```markdown
> **2026-09-26 update:** the wire protocol changed. ReTiCA now speaks ble-reticulum v2.2
> (spec `docs/superpowers/specs/2026-09-26-ble-v22-gatt-driver-design.md`); items P1, P1a,
> P1b, P1c, P2, P3, P4 (the Python-fork work) are obsolete — the Pi runs stock ble-reticulum.
> S1, S2 and S6 are carried into the new adapter. A1–A4 and R1–R3 still apply. Live
> verification now follows `docs/superpowers/plans/2026-09-26-ble-v22-hardware-checklist.md`.
```

- [ ] **Step 5: Full verification, both packages**

Run (in FCB): `swift test` — expected: all PASS.
Run (in ReTiCA): `swift test` — expected: all PASS.
Run (in ReTiCA): `grep -rn "RBTP\|BLEFraming\|BLEHello\|readDirectory\|pairingMode\|bleRandomBytes\|1196" Sources Tests` — expected: no output.

- [ ] **Step 6: Commit**

`git add Sources/ReTiCATransport/InterfaceProfile.swift Tests/ReTiCATransportTests/InterfaceProfileTests.swift docs/superpowers/plans/2026-09-26-ble-v22-hardware-checklist.md docs/superpowers/2026-08-24-ble-punch-list.md` — `feat: BLE profile HW_MTU 500; v2.2 hardware checklist`.

(The punch list was untracked before this task; adding it here is intentional — it becomes tracked with the status note.)

---

## Done criteria

- `swift test` green in both packages; the grep in Task 9 Step 5 is empty.
- Every task's mutation step was run and reverted (the reviewer checks commit history shows no mutation residue).
- The hardware checklist exists; nothing in it is ticked (live runs are outside this plan).
