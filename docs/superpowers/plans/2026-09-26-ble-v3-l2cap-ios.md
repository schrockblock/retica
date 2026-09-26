# BLE v3 L2CAP Fast Path (iOS) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ReTiCA speaks BLE Protocol v3: as a peripheral it publishes an L2CAP listener and the PSM characteristic; as a central it prefers an L2CAP channel when the peer publishes a PSM and falls back to the v2.2 GATT path otherwise.

**Architecture:** Additive changes at every layer of the existing v2.2 stack. The seam gains a transport tag, an optional PSM on `identityRead` and one new verb; the reducer gains path selection with a single GATT fallback and a length-framed L2CAP data plane beside the fragmented GATT one; the adapter gains PSM publish/read, L2CAP open with a 10 s limit, inbound L2CAP registration and a send branch over FCB's `L2CAPConnection`. No node-layer change.

**Tech Stack:** Swift 6 / SwiftPM, swift-composable-architecture, FCBComposable (`../FCB`, main at 57ae574 or later — it already has `publishL2CAPChannel`, `l2capConnections()`, `openL2CAPChannel`, `L2CAPConnection`), CoreBluetoothMock, Swift Testing.

**Spec:** `docs/superpowers/specs/2026-09-26-ble-v3-l2cap-ios-design.md` (ReTiCA side) and the wire spec `BLE_PROTOCOL_v3.md` at `/Users/ell/development/python/ble-reticulum-v3/BLE_PROTOCOL_v3.md`. The wire spec wins on conflicts.

## Global Constraints

- Work in the worktree `/Users/ell/development/ios/pods/ReTiCA-v3` (branch `feat/ble-v3-l2cap`, based on `main` 314b812). FCB is `/Users/ell/development/ios/pods/FCB` on `main` (57ae574); it is NOT modified by this plan. Never `git add -A`; stage by name.
- One command per Bash invocation; never chain with `&&`, `|`, `;`, `||`, `$(...)`, `xargs`, or heredocs; never inline scripts. Foreground only, long timeouts (≤ 600000 ms) on Swift commands. `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-v3 --filter <name>`; the full suite runs in the DEFAULT parallel mode and must be green.
- Every task: RED → GREEN → mutation batch (named tests fail) → revert → green → commit. Test output pristine (1 pre-existing known issue in TransportTests).
- Wire constants: PSM characteristic `37145b00-442d-4a94-917f-8f42c5da28e7`, read-only, uint16 little-endian, 0 = not listening; L2CAP framing `[len:2 BE][payload]`, 1 ≤ len ≤ 1196; handshake frame = `[0x00, 0x10] + localIdentity`; keepalive frame = `[0x00, 0x01, 0x00]`; L2CAP open limit 10 s; channels opened without encryption; the GATT link stays connected under the channel; one GATT fallback per dial.
- Existing v2.2 behaviour, constants and tests are unchanged unless a task says otherwise; `HW_MTU` stays 500 for every BLE peer.
- Commit messages: subject, blank line, then exactly:
  `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_01TRTeyiHdN7Mnmb6e6AifR7`
  (never substitute another model name). Write the message to a file in the scratch directory and `git -C <worktree> commit -F <file>`.

## Review Focus

1. **A PSM characteristic that reads as 1 byte or as `0x0000`** must be treated as "GATT only", never as PSM 0 to dial. Test in Task 4 (`shortOrZeroPSMReadsAsNil`).
2. **An L2CAP open that times out after the peer already accepted** (channel arrives late) must not leak a half-open connection: the adapter closes anything the race returns after the limit. Test in Task 4 (`lateL2CAPOpenAfterTimeoutIsClosed`).
3. **A framing error on an established L2CAP channel** must tear the channel down with a strike and emit `peerOffline` exactly once, not drop silently as the GATT reassembler does. Test in Task 3 (`l2capFramingErrorTearsDownWithStrike`).
4. **The GATT fallback must run at most once per dial**: a second `channelFailed` for the same handle strikes and clears. Test in Task 3 (`gattFallbackFailureStrikesAndStopsRetrying`).
5. **A peer that publishes a PSM but whose channel closes right after the handshake** (churn) must leave the peer greylisted like any short-lived channel, and the next dial must still try L2CAP first (no sticky demotion). Test in Task 3 (`l2capChurnStrikesButNextDialStillPrefersL2CAP`).

---

### Task 1: Restore length framing at the v3 ceiling (pure)

**Files:**
- Modify: `Sources/ReTiCAInterfaces/BLESupport.swift` (append)
- Test: `Tests/ReTiCAInterfacesTests/BLESupportTests.swift` (append)

**Interfaces:**
- Produces: `BLEFramingError.invalidLength(Int)`, `BLEFraming.maxFrameLength = 1196`, `BLEFraming.headerLength = 2`, `BLEFraming.frame(_:) throws -> Data`, `BLEFraming.keepaliveFrame`, `BLEFrameBuffer(maxFrameLength:)` with `mutating append(_:) throws -> [Data]`.

- [ ] **Step 1: Write the failing tests**

Append to `BLESupportTests.swift`:

```swift
// MARK: - L2CAP length framing (v3)

@Test func l2capFrameIsBigEndianLengthPrefixed() throws {
    #expect(try BLEFraming.frame(Data([0xAA, 0xBB, 0xCC])) == Data([0x00, 0x03, 0xAA, 0xBB, 0xCC]))
    let big = Data(repeating: 0x42, count: 300)
    #expect(try BLEFraming.frame(big) == Data([0x01, 0x2C]) + big)
    #expect(BLEFraming.keepaliveFrame == Data([0x00, 0x01, 0x00]))
}

@Test func l2capFrameRejectsEmptyAndOversized() {
    #expect(throws: BLEFramingError.invalidLength(0)) { try BLEFraming.frame(Data()) }
    #expect(throws: BLEFramingError.invalidLength(1197)) { try BLEFraming.frame(Data(repeating: 0, count: 1197)) }
    #expect((try? BLEFraming.frame(Data(repeating: 0, count: 1196))) != nil)
}

@Test func l2capDeframerRecoversCoalescedAndSplitRecords() throws {
    var buffer = BLEFrameBuffer()
    let a = Data([0x01]); let b = Data((0..<30).map { UInt8($0) })
    #expect(try buffer.append(BLEFraming.frame(a) + BLEFraming.frame(b)) == [a, b])
    let framed = try BLEFraming.frame(b)
    #expect(try buffer.append(framed.prefix(1)) == [])
    #expect(try buffer.append(framed.dropFirst(1).prefix(10)) == [])
    #expect(try buffer.append(framed.dropFirst(11)) == [b])
}

@Test func l2capDeframerThrowsOnZeroOrOversizedLength() {
    var zero = BLEFrameBuffer()
    #expect(throws: BLEFramingError.invalidLength(0)) { _ = try zero.append(Data([0x00, 0x00, 0xFF])) }
    var big = BLEFrameBuffer()
    #expect(throws: BLEFramingError.invalidLength(1197)) { _ = try big.append(Data([0x04, 0xAD])) }   // 0x04AD = 1197
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-v3 --filter BLESupportTests` — expected: compile error, `BLEFraming` undefined.

- [ ] **Step 3: Implement**

Append to `BLESupport.swift`:

```swift
// MARK: - L2CAP length framing (BLE Protocol v3)

public enum BLEFramingError: Error, Equatable {
    case invalidLength(Int)
}

/// v3 channel framing: [len: 2 bytes big-endian][payload], 1 <= len <= 1196. No fragmentation
/// layer rides on top; the kernel's credit-based flow control segments the stream.
public enum BLEFraming {
    public static let maxFrameLength = 1196
    public static let headerLength = 2
    /// len 1, payload 0x00 — ignored by receivers (wire spec §Keepalive).
    public static let keepaliveFrame = Data([0x00, 0x01, 0x00])

    public static func frame(_ packet: Data) throws -> Data {
        guard packet.count >= 1, packet.count <= maxFrameLength else {
            throw BLEFramingError.invalidLength(packet.count)
        }
        var out = Data([UInt8(packet.count >> 8), UInt8(packet.count & 0xFF)])
        out.append(packet)
        return out
    }
}

/// Streaming deframer. Accumulates bytes and yields complete records; throws on a malformed
/// length prefix. There is no resynchronisation: the caller closes the channel.
public struct BLEFrameBuffer: Equatable, Sendable {
    public let maxFrameLength: Int
    var buffer: Data

    public init(maxFrameLength: Int = BLEFraming.maxFrameLength) {
        self.maxFrameLength = maxFrameLength
        self.buffer = Data()
    }

    public mutating func append(_ data: Data) throws -> [Data] {
        buffer.append(data)
        var records: [Data] = []
        while buffer.count >= BLEFraming.headerLength {
            let b0 = Int(buffer[buffer.startIndex])
            let b1 = Int(buffer[buffer.startIndex + 1])
            let length = (b0 << 8) | b1
            guard length >= 1, length <= maxFrameLength else { throw BLEFramingError.invalidLength(length) }
            guard buffer.count >= BLEFraming.headerLength + length else { break }
            let start = buffer.startIndex + BLEFraming.headerLength
            records.append(Data(buffer[start ..< start + length]))
            buffer = Data(buffer[(start + length)...])
        }
        return records
    }
}
```

- [ ] **Step 4: Run to verify pass** — `--filter BLESupportTests`, all PASS.

- [ ] **Step 5: Mutate, verify, revert** — batch: (a) `frame` writes the length little-endian; (b) `append` drops the `length >= 1` check. Expected FAIL: `l2capFrameIsBigEndianLengthPrefixed`, `l2capDeframerRecoversCoalescedAndSplitRecords`, `l2capDeframerThrowsOnZeroOrOversizedLength`. Revert; all PASS.

- [ ] **Step 6: Commit** — `feat: v3 L2CAP length framing at the 1196-byte ceiling`.

---

### Task 2: Seam additions (transport tag, PSM on identityRead, openL2CAPChannel verb)

**Files:**
- Modify: `Sources/ReTiCAInterfaces/BLEDriver.swift`
- Modify: `Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift` (mock driver records the new verb)

**Interfaces:**
- Produces:
  ```swift
  public enum BLEChannelTransport: Equatable, Sendable { case gatt, l2cap }
  case identityRead(BLEPeerHandle, identity: Data, psm: UInt16? = nil)
  case channelOpened(BLEChannelID, BLEPeerHandle, direction: BLEChannelDirection, mtu: Int,
                     transport: BLEChannelTransport = .gatt)
  public var openL2CAPChannel: @Sendable (BLEPeerHandle, UInt16) async -> Void   // default { _, _ in }
  MockDriverCall.openL2CAPChannel(BLEPeerHandle, UInt16)
  ```
  Default associated values keep every existing construction site compiling; every `switch`/`case let` that destructures these cases must list the new field.

- [ ] **Step 1: Write the failing test**

Append to `BLEInterfaceTests.swift` (after the existing lifecycle tests):

```swift
@Test @MainActor func seamCarriesTransportAndPSMWithGattDefaults() {
    let opened = BLEDriverEvent.channelOpened(channel1, peerHandleA, direction: .outbound, mtu: 23)
    #expect(opened == .channelOpened(channel1, peerHandleA, direction: .outbound, mtu: 23, transport: .gatt))
    let read = BLEDriverEvent.identityRead(peerHandleA, identity: identityHigh)
    #expect(read == .identityRead(peerHandleA, identity: identityHigh, psm: nil))
    #expect(BLEDriverEvent.identityRead(peerHandleA, identity: identityHigh, psm: 0x0081)
            != .identityRead(peerHandleA, identity: identityHigh))
}
```

Also add `case openL2CAPChannel(BLEPeerHandle, UInt16)` to `MockDriverCall`, and in `makeStore`'s mock driver add `openL2CAPChannel: { h, psm in calls.withValue { $0.append(.openL2CAPChannel(h, psm)) } }` (before `send:`; match the declaration order you give the property in `BLEDriver`).

- [ ] **Step 2: Run to verify failure** — `--filter BLEInterfaceTests`: compile errors (`transport:`, `psm:`, `openL2CAPChannel` unknown).

- [ ] **Step 3: Implement**

In `BLEDriver.swift`:
```swift
/// Which data plane a channel uses. `.gatt` = v2.2 characteristics with fragmentation;
/// `.l2cap` = v3 length-framed L2CAP CoC (no fragmentation).
public enum BLEChannelTransport: Equatable, Sendable { case gatt, l2cap }
```
Change the two event cases:
```swift
    /// Central role: the peer's Identity characteristic was read (16 bytes). `psm` is the peer's
    /// v3 L2CAP listener if it publishes one (nil: absent, unreadable, short, or 0 → GATT only).
    case identityRead(BLEPeerHandle, identity: Data, psm: UInt16? = nil)
    /// Outbound: after the handshake succeeded on the chosen path. Inbound: a central subscribed
    /// to our TX (.gatt) or opened an L2CAP channel to us (.l2cap). `mtu` is the GATT fragment size
    /// and is 0 for .l2cap.
    case channelOpened(BLEChannelID, BLEPeerHandle, direction: BLEChannelDirection, mtu: Int,
                       transport: BLEChannelTransport = .gatt)
```
Add the verb after `openChannel`:
```swift
    /// v3: open an L2CAP CoC to `psm` on the peer's existing link (10 s limit), send the 16-byte
    /// handshake frame, then emit channelOpened(.outbound, transport: .l2cap). Failure emits
    /// channelFailed WITHOUT disconnecting — the reducer falls back to the GATT path on the same link.
    public var openL2CAPChannel: @Sendable (BLEPeerHandle, UInt16) async -> Void
```
with an `init` parameter `openL2CAPChannel: @escaping @Sendable (BLEPeerHandle, UInt16) async -> Void = { _, _ in }` placed right after `openChannel`, assigned in the body; add `openL2CAPChannel: { _, _ in }` to the `#else` inert `liveValue` and `openL2CAPChannel: unimplemented("BLEDriver.openL2CAPChannel")` to `testValue`. Update `FCBDriverAdapter.swift`'s `BLEDriver.fcb(...)` to pass `openL2CAPChannel: { peer, psm in await adapter.openL2CAPChannel(peer, psm: psm) }` and add a stub `func openL2CAPChannel(_ peer: BLEPeerHandle, psm: UInt16) async { continuation?.yield(.channelFailed(peer, reason: "L2CAP not implemented yet")) }` to the actor (Task 4 replaces it). In `BLEInterface.swift` update the two `case let .driverEvent(.identityRead(handle, identity))` / `.channelOpened(channelID, handle, direction, mtu)` patterns to bind the new fields (`psm` unused for now → `_`; `transport` unused → `_`).

- [ ] **Step 4: Build everything and run** — `swift build --package-path … --build-tests` succeeds; `--filter BLEInterfaceTests` all PASS; `--filter ReTiCANodeTests` all PASS (node mocks compile unchanged thanks to the defaults).

- [ ] **Step 5: Mutate, verify, revert** — mutation: make the `transport` default `.l2cap` → `seamCarriesTransportAndPSMWithGattDefaults` fails. Revert; PASS.

- [ ] **Step 6: Commit** — `feat: BLE driver seam carries transport, PSM and an L2CAP open verb`.

---

### Task 3: Reducer — path selection, single GATT fallback, L2CAP data plane

**Files:**
- Modify: `Sources/ReTiCAInterfaces/BLEInterface.swift`
- Modify: `Tests/ReTiCAInterfacesTests/BLEInterfaceTests.swift` (append tests; extend `makeStore`)

**Interfaces:**
- Consumes: Task 1 framing; Task 2 seam (`BLEChannelTransport`, `identityRead(_:identity:psm:)`, `channelOpened(_:_:direction:mtu:transport:)`, `openL2CAPChannel`).
- Produces: `BLEInterface.State.init(localIdentity:maxPeers:keepaliveInterval:l2capEnabled: Bool = true)`; `State.l2capEnabled`; `ChannelState.transport`, `ChannelState.frameBuffer`; `State.pendingPaths: [BLEPeerHandle: BLEChannelTransport]`; `Action.SendFailedReason.unframable`. Behaviour per spec §2.3.

- [ ] **Step 1: Extend the test helpers and write the failing tests**

In `BLEInterfaceTests.swift`: give `makeStore`/`makeOnlineStore` a trailing parameter `l2cap: Bool = true` passed as `l2capEnabled:` to `BLEInterface.State`. Add after `establishInbound`:

```swift
let testPSM: UInt16 = 0x0081
func l2capFrame(_ packet: Data) -> Data { try! BLEFraming.frame(packet) }

/// Outbound over L2CAP: discovery → identityRead(psm) → openL2CAPChannel → channelOpened(.l2cap) → peerOnline.
@MainActor
func establishOutboundL2CAP(
    _ store: TestStore<BLEInterface.State, BLEInterface.Action>,
    _ events: AsyncStream<BLEDriverEvent>.Continuation,
    handle: BLEPeerHandle, channel: BLEChannelID, identity: Data
) async {
    events.yield(.peerDiscovered(handle))
    await store.receive(.driverEvent(.peerDiscovered(handle)))
    events.yield(.identityRead(handle, identity: identity, psm: testPSM))
    await store.receive(.driverEvent(.identityRead(handle, identity: identity, psm: testPSM)))
    events.yield(.channelOpened(channel, handle, direction: .outbound, mtu: 0, transport: .l2cap))
    await store.receive(.driverEvent(.channelOpened(channel, handle, direction: .outbound, mtu: 0, transport: .l2cap)))
    await store.receive(.delegate(.peerOnline(identity)))
}

/// Inbound over L2CAP: channelOpened(.inbound, .l2cap) → framed 16-byte handshake → peerOnline.
@MainActor
func establishInboundL2CAP(
    _ store: TestStore<BLEInterface.State, BLEInterface.Action>,
    _ events: AsyncStream<BLEDriverEvent>.Continuation,
    handle: BLEPeerHandle, channel: BLEChannelID, identity: Data
) async {
    events.yield(.channelOpened(channel, handle, direction: .inbound, mtu: 0, transport: .l2cap))
    await store.receive(.driverEvent(.channelOpened(channel, handle, direction: .inbound, mtu: 0, transport: .l2cap)))
    events.yield(.channelData(channel, l2capFrame(identity)))
    await store.receive(.driverEvent(.channelData(channel, l2capFrame(identity))))
    await store.receive(.delegate(.peerOnline(identity)))
}
```

Append the tests:

```swift
// MARK: - v3 path selection and fallback

@Test @MainActor func identityWithPSMOpensL2CAP() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM))) {
        $0.pendingIdentities = [peerHandleA: identityHigh]
        $0.pendingPaths = [peerHandleA: .l2cap]
    }
    await store.finish()
    #expect(calls.value.contains(.openL2CAPChannel(peerHandleA, testPSM)))
    #expect(!calls.value.contains(.openChannel(peerHandleA)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func identityWithoutPSMOpensGATT() async {
    let (store, events, calls, _, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh))) {
        $0.pendingIdentities = [peerHandleA: identityHigh]
        $0.pendingPaths = [peerHandleA: .gatt]
    }
    await store.finish()
    #expect(calls.value.contains(.openChannel(peerHandleA)))
    #expect(!calls.value.contains { if case .openL2CAPChannel = $0 { return true } else { return false } })
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func l2capDisabledIgnoresPSM() async {
    let (store, events, calls, _, _) = await makeOnlineStore(l2cap: false)
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM)))
    await store.finish()
    #expect(calls.value.contains(.openChannel(peerHandleA)))
    #expect(!calls.value.contains(.openL2CAPChannel(peerHandleA, testPSM)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func l2capOpenFailureFallsBackToGATTOnce() async {
    let (store, events, calls, _, now) = await makeOnlineStore(keepalive: nil)
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM)))
    events[0].yield(.channelFailed(peerHandleA, reason: "l2cap open failed"))
    await store.receive(.driverEvent(.channelFailed(peerHandleA, reason: "l2cap open failed"))) {
        $0.pendingPaths = [peerHandleA: .gatt]          // still pending, now on the GATT path
    }
    await store.finish()
    #expect(store.state.pendingPeers == [peerHandleA])
    #expect(calls.value.contains(.openChannel(peerHandleA)))
    #expect(!store.state.greylist.isBlocked(peerHandleA, now: now.value), "an L2CAP miss is not a strike")
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .outbound, mtu: testMTU))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .outbound, mtu: testMTU)))
    await store.receive(.delegate(.peerOnline(identityHigh)))
    #expect(store.state.channels[channel1]?.transport == .gatt)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func gattFallbackFailureStrikesAndStopsRetrying() async {
    // Review Focus 4.
    let (store, events, calls, _, now) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM)))
    events[0].yield(.channelFailed(peerHandleA, reason: "l2cap"))
    await store.receive(.driverEvent(.channelFailed(peerHandleA, reason: "l2cap")))
    events[0].yield(.channelFailed(peerHandleA, reason: "gatt"))
    await store.receive(.driverEvent(.channelFailed(peerHandleA, reason: "gatt"))) {
        $0.pendingPeers = []
        $0.pendingIdentities = [:]
        $0.pendingPaths = [:]
    }
    await store.finish()
    #expect(store.state.greylist.isBlocked(peerHandleA, now: now.value))
    #expect(calls.value.filter { $0 == .openChannel(peerHandleA) }.count == 1)
    #expect(calls.value.filter { $0 == .openL2CAPChannel(peerHandleA, testPSM) }.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func fallbackReArmsTheEstablishDeadline() async {
    let (store, events, _, clock, _) = await makeOnlineStore()
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    await clock.advance(by: .seconds(10))                    // 10 s into the original 15 s window
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM)))
    events[0].yield(.channelFailed(peerHandleA, reason: "l2cap"))
    await store.receive(.driverEvent(.channelFailed(peerHandleA, reason: "l2cap")))
    await clock.advance(by: .seconds(14))                    // 24 s after discovery, 14 s after fallback: no deadline yet
    #expect(store.state.pendingPeers == [peerHandleA])
    await clock.advance(by: .seconds(1))
    await store.receive(.establishDeadline(peerHandleA)) { $0.pendingPeers = []; $0.pendingIdentities = [:]; $0.pendingPaths = [:] }
    await store.send(.stop) { $0.status = .stopped }
}

// MARK: - v3 L2CAP data plane

@Test @MainActor func l2capOutboundEstablishmentReportsPeerOnline() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutboundL2CAP(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    #expect(store.state.channels[channel1]?.transport == .l2cap)
    #expect(store.state.pendingPaths.isEmpty)
    #expect(!calls.value.contains { if case .send = $0 { return true } else { return false } })   // adapter sent the handshake
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func l2capInboundHandshakeReportsPeerOnline() async {
    let (store, events, _, _, _) = await makeOnlineStore()
    await establishInboundL2CAP(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    #expect(store.state.peers[identityHigh] == channel1)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func l2capInboundBadFirstFrameTearsDownWithStrike() async {
    let (store, events, calls, _, now) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: 0, transport: .l2cap))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: 0, transport: .l2cap)))
    let bad = l2capFrame(Data([1, 2, 3, 4, 5]))
    events[0].yield(.channelData(channel1, bad))
    await store.receive(.driverEvent(.channelData(channel1, bad))) { $0.channels = [:] }
    await store.finish()
    #expect(calls.value.contains(.closeChannel(channel1)))
    #expect(store.state.greylist.isBlocked(peerHandleA, now: now.value))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func l2capInboundHandshakeDeadlineApplies() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    events[0].yield(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: 0, transport: .l2cap))
    await store.receive(.driverEvent(.channelOpened(channel1, peerHandleA, direction: .inbound, mtu: 0, transport: .l2cap)))
    await clock.advance(by: BLEInterface.handshakeTimeout)
    await store.receive(.handshakeDeadline(channel1))
    #expect(calls.value.contains(.closeChannel(channel1)))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func l2capPacketsFlowFramedBothWays() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutboundL2CAP(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    // Inbound: one record split across two deliveries, then two records coalesced in one.
    let p1 = Data(repeating: 0xAB, count: 40)
    let framed = l2capFrame(p1)
    events[0].yield(.channelData(channel1, framed.prefix(7)))
    await store.receive(.driverEvent(.channelData(channel1, framed.prefix(7))))
    events[0].yield(.channelData(channel1, Data(framed.dropFirst(7))))
    await store.receive(.driverEvent(.channelData(channel1, Data(framed.dropFirst(7)))))
    await store.receive(.delegate(.packetReceived(peer: identityHigh, packet: p1)))
    let p2 = Data([1]); let p3 = Data([2, 3])
    events[0].yield(.channelData(channel1, l2capFrame(p2) + l2capFrame(p3)))
    await store.receive(.driverEvent(.channelData(channel1, l2capFrame(p2) + l2capFrame(p3))))
    await store.receive(.delegate(.packetReceived(peer: identityHigh, packet: p2)))
    await store.receive(.delegate(.packetReceived(peer: identityHigh, packet: p3)))
    // Outbound: one framed record per packet, no fragmentation header.
    let out = Data(repeating: 0xCD, count: 500)
    await store.send(.send(peer: identityHigh, packet: out))
    await store.finish()
    #expect(calls.value.contains(.send(channel1, [l2capFrame(out)])))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func l2capFramingErrorTearsDownWithStrike() async {
    // Review Focus 3.
    let (store, events, calls, _, now) = await makeOnlineStore(keepalive: nil)
    await establishOutboundL2CAP(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    events[0].yield(.channelData(channel1, Data([0x00, 0x00])))          // length 0: invalid on the wire
    await store.receive(.driverEvent(.channelData(channel1, Data([0x00, 0x00])))) {
        $0.channels = [:]
        $0.peers = [:]
    }
    await store.receive(.delegate(.peerOffline(identityHigh)))
    await store.finish()
    #expect(calls.value.contains(.closeChannel(channel1)))
    #expect(store.state.greylist.isBlocked(peerHandleA, now: now.value))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func l2capKeepaliveFrameIgnoredOnReceiptAndSentOnTimer() async {
    let (store, events, calls, clock, _) = await makeOnlineStore()
    await establishOutboundL2CAP(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    store.exhaustivity = .on
    events[0].yield(.channelData(channel1, BLEFraming.keepaliveFrame))
    await store.receive(.driverEvent(.channelData(channel1, BLEFraming.keepaliveFrame)))   // no delegate
    store.exhaustivity = .off
    await clock.advance(by: BLEInterface.defaultKeepaliveInterval)
    await store.receive(.keepalive(channel1))
    await store.finish()
    #expect(calls.value.contains(.send(channel1, [BLEFraming.keepaliveFrame])))
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func l2capOversizedPacketReportsUnframable() async {
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishOutboundL2CAP(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    let before = calls.value.count
    await store.send(.send(peer: identityHigh, packet: Data(repeating: 1, count: 1197)))
    await store.receive(.delegate(.sendFailed(peer: identityHigh, reason: .unframable)))
    #expect(calls.value.count == before)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func l2capChurnStrikesButNextDialStillPrefersL2CAP() async {
    // Review Focus 5.
    let (store, events, calls, _, now) = await makeOnlineStore(keepalive: nil)
    await establishOutboundL2CAP(store, events[0], handle: peerHandleA, channel: channel1, identity: identityHigh)
    now.setValue(now.value.addingTimeInterval(BLEInterface.churnMinLifetime - 0.5))
    events[0].yield(.channelClosed(channel1, reason: nil))
    await store.receive(.driverEvent(.channelClosed(channel1, reason: nil)))
    await store.receive(.delegate(.peerOffline(identityHigh)))
    #expect(store.state.greylist.isBlocked(peerHandleA, now: now.value))
    now.setValue(now.value.addingTimeInterval(5.01))
    events[0].yield(.peerDiscovered(peerHandleA))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleA)))
    events[0].yield(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM))
    await store.receive(.driverEvent(.identityRead(peerHandleA, identity: identityHigh, psm: testPSM)))
    await store.finish()
    #expect(calls.value.filter { $0 == .openL2CAPChannel(peerHandleA, testPSM) }.count == 2)
    await store.send(.stop) { $0.status = .stopped }
}

@Test @MainActor func mixedTransportCrossConnectKeepsOneChannel() async {
    // Peer LOW is established inbound over GATT; our outbound L2CAP to the same identity loses.
    let (store, events, calls, _, _) = await makeOnlineStore(keepalive: nil)
    await establishInbound(store, events[0], handle: peerHandleA, channel: channel1, identity: identityLow)
    events[0].yield(.peerDiscovered(peerHandleB))
    await store.receive(.driverEvent(.peerDiscovered(peerHandleB)))
    events[0].yield(.identityRead(peerHandleB, identity: identityLow, psm: testPSM))
    await store.receive(.driverEvent(.identityRead(peerHandleB, identity: identityLow, psm: testPSM)))
    await store.finish()
    #expect(!calls.value.contains(.openL2CAPChannel(peerHandleB, testPSM)))   // pre-check abandons the dial
    #expect(store.state.channels.count == 1)
    await store.send(.stop) { $0.status = .stopped }
}
```

- [ ] **Step 2: Run to verify failure** — `--filter BLEInterfaceTests`: compile errors (`l2capEnabled`, `pendingPaths`, `transport`, `.unframable`).

- [ ] **Step 3: Implement**

In `BLEInterface.swift`:

State and types:
```swift
    public struct ChannelState: Equatable, Sendable {
        public var peer: BLEPeerHandle
        public var direction: BLEChannelDirection
        public var transport: BLEChannelTransport
        var fragmenter: BLEFragmenter          // .gatt only
        var reassembler: BLEReassembler        // .gatt only
        var frameBuffer: BLEFrameBuffer        // .l2cap only
        var peerIdentity: Data?
        var openedAt: Date
    }
    // State:
        /// v3: dial L2CAP when the peer publishes a PSM. false forces the GATT path for every peer.
        public var l2capEnabled: Bool
        var pendingPaths: [BLEPeerHandle: BLEChannelTransport] = [:]   // which path the in-flight dial is on
        public init(localIdentity: Data, maxPeers: Int = BLEInterface.defaultMaxPeers,
                    keepaliveInterval: Duration? = BLEInterface.defaultKeepaliveInterval,
                    l2capEnabled: Bool = true)
    // SendFailedReason:
            /// L2CAP path: the packet is empty or exceeds BLEFraming.maxFrameLength.
            case unframable
```

`identityRead`: change the pattern Task 2 left as `.identityRead(handle, identity, _)` to bind `psm`, then replace the tail after the duplicate pre-check:
```swift
                state.pendingIdentities[handle] = identity
                if state.l2capEnabled, let psm, psm != 0 {
                    state.pendingPaths[handle] = .l2cap
                    return .run { [bleDriver] _ in await bleDriver.openL2CAPChannel(handle, psm) }
                }
                state.pendingPaths[handle] = .gatt
                return .run { [bleDriver] _ in await bleDriver.openChannel(handle) }
```

Split the combined failure case; `channelFailed` falls back once:
```swift
            case let .driverEvent(.identityFailed(handle, _)):
                guard state.pendingPeers.contains(handle) else { return .none }
                state.pendingPeers.remove(handle)
                state.pendingIdentities[handle] = nil
                state.pendingPaths[handle] = nil
                if !hasEstablishedChannel(state, handle) { state.greylist.recordFailure(handle, now: date()) }
                return .cancel(id: CancelID.establish(handle))

            case let .driverEvent(.channelFailed(handle, _)):
                guard state.pendingPeers.contains(handle) else { return .none }
                if state.pendingPaths[handle] == .l2cap {
                    // v3: an L2CAP miss is not a failure of the peer — fall back to GATT on the same
                    // link, exactly once, with a fresh establishment window.
                    state.pendingPaths[handle] = .gatt
                    return .merge(
                        .run { [bleDriver] _ in await bleDriver.openChannel(handle) },
                        .run { [clock] send in
                            try await clock.sleep(for: Self.establishTimeout)
                            await send(.establishDeadline(handle))
                        }
                        .cancellable(id: CancelID.establish(handle), cancelInFlight: true))
                }
                state.pendingPeers.remove(handle)
                state.pendingIdentities[handle] = nil
                state.pendingPaths[handle] = nil
                if !hasEstablishedChannel(state, handle) { state.greylist.recordFailure(handle, now: date()) }
                return .cancel(id: CancelID.establish(handle))
```
Clear `pendingPaths` alongside `pendingIdentities` in `.stop`, `.unavailable`, `establishDeadline`, and in `channelOpened`'s outbound branch (`state.pendingPaths[handle] = nil`).

`channelOpened`: bind `transport`; build `ChannelState(peer:, direction:, transport: transport, fragmenter: BLEFragmenter(mtu: mtu), reassembler: BLEReassembler(), frameBuffer: BLEFrameBuffer(), peerIdentity: nil, openedAt: now)`.

`channelData` — wrap the existing body as the `.gatt` branch and add `.l2cap`:
```swift
            case let .driverEvent(.channelData(channelID, bytes)):
                guard var channel = state.channels[channelID] else { return .none }
                switch channel.transport {
                case .gatt:
                    // (existing v2.2 body, unchanged)
                case .l2cap:
                    let records: [Data]
                    do {
                        records = try channel.frameBuffer.append(bytes)
                        state.channels[channelID] = channel
                    } catch {
                        // Wire spec: a bad length prefix closes the channel. No resynchronisation.
                        state.channels[channelID] = channel
                        return tearDown(&state, channelID: channelID, strike: true)
                    }
                    var effects: [Effect<Action>] = []
                    for record in records {
                        guard let current = state.channels[channelID] else { break }   // torn down or replaced
                        if BLEKeepalive.isKeepalive(record) { continue }
                        guard let identity = current.peerIdentity else {
                            guard record.count == BLEProtocol.identityLength, record != state.localIdentity else {
                                effects.append(tearDown(&state, channelID: channelID, strike: true))
                                break
                            }
                            effects.append(.cancel(id: CancelID.handshake(channelID)))
                            effects.append(establish(&state, channelID: channelID, identity: Data(record)))
                            continue
                        }
                        effects.append(.send(.delegate(.packetReceived(peer: identity, packet: record))))
                    }
                    return .merge(effects)
                }
```

`.send` and `.keepalive`:
```swift
            case let .send(peer, packet):
                guard let channelID = state.peers[peer], let channel = state.channels[channelID] else { return .none }
                switch channel.transport {
                case .gatt:
                    // (existing fragment + sanitize path)
                case .l2cap:
                    guard let frame = try? BLEFraming.frame(packet) else {
                        return .send(.delegate(.sendFailed(peer: peer, reason: .unframable)))
                    }
                    return .run { [bleDriver] _ in await bleDriver.send(channelID, [frame]) }
                }

            case let .keepalive(channelID):
                guard let channel = state.channels[channelID], channel.direction == .outbound,
                      channel.peerIdentity != nil else { return .none }
                let frame = channel.transport == .l2cap ? BLEFraming.keepaliveFrame : BLEKeepalive.frame
                return .run { [bleDriver] _ in await bleDriver.send(channelID, [frame]) }
```

- [ ] **Step 4: Run** — `--filter BLEInterfaceTests` all PASS; `--filter ReTiCANodeTests` all PASS (unchanged node tests still construct GATT channels).

- [ ] **Step 5: Mutate, verify, revert** — batch: (a) in `identityRead` always take the GATT branch → `identityWithPSMOpensL2CAP` fails; (b) in `channelFailed` drop the `pendingPaths[handle] == .l2cap` fallback → `l2capOpenFailureFallsBackToGATTOnce` fails; (c) in the L2CAP framing `catch`, return `.none` instead of tearing down → `l2capFramingErrorTearsDownWithStrike` fails; (d) in `.send` route `.l2cap` through the fragmenter path → `l2capPacketsFlowFramedBothWays` fails; (e) in the fallback keep `pendingPaths[handle] = .l2cap` → `gattFallbackFailureStrikesAndStopsRetrying` fails. Revert all; PASS.

- [ ] **Step 6: Commit** — `feat: BLE reducer dials L2CAP when a PSM is published, falls back to GATT once`.

---

### Task 4: Adapter — PSM publish/read, L2CAP open, inbound channels, send and close

**Files:**
- Modify: `Sources/ReTiCAInterfaces/FCBDriverAdapter.swift`
- Modify: `Tests/ReTiCAInterfacesTests/FCBDriverAdapterTests.swift` (extend stubs; append tests)

**Interfaces:**
- Consumes: FCB `BluetoothPeripheralClient.publishL2CAPChannel(Bool) async throws -> UInt16`, `unpublishL2CAPChannel(UInt16)`, `l2capConnections() -> AsyncStream<L2CAPConnection>`; `BluetoothCentralClient.openL2CAPChannel(UUID, UInt16) async throws -> L2CAPConnection`; `L2CAPConnection` (public init: `id, peerID, psm, incoming, send, close`). Task 2's seam.
- Produces: `FCBDriverAdapter.init(central:peripheral:now:l2capOpenLimit: Duration = .seconds(10))`; `bleV3PSMCharUUID`; `bleV22Service(localIdentity:psm:)`; `func openL2CAPChannel(_:psm:)`; `static let handshakeFrame(for identity:)`.

- [ ] **Step 1: Extend the stubs and write the failing tests**

First, in `Sources/ReTiCAInterfaces/BLESupport.swift` add to `BLEProtocol` (after `identityCharUUID`):
```swift
    /// v3: read-only, 2 bytes little-endian; the peer's L2CAP PSM, absent or 0 when not listening.
    public static let psmCharUUID      = "37145b00-442d-4a94-917f-8f42c5da28e7"
```
and in `FCBDriverAdapterTests.swift` next to the other CBUUID constants:
```swift
let psmCharUUID = CBUUID(string: BLEProtocol.psmCharUUID)
```

The stubs already wire `openL2CAPChannel` (throws `l2capNotSupported`), `publishL2CAPChannel` (returns 0), `unpublishL2CAPChannel` and `l2capConnections` (`.finished`) as inert endpoints — replace those four closures with the knob-driven ones below. In `AdapterStubs` add: `let publishPSM: LockIsolated<UInt16?>` (default `0x0081`; nil → `publishL2CAPChannel` throws `BluetoothError.l2capNotSupported`), `let unpublished: LockIsolated<[UInt16]>`, `let openL2CAPResult: LockIsolated<L2CAPConnection?>` (nil → throws `l2capNotSupported`), `let openL2CAPDelayNanos: LockIsolated<UInt64>` (0), `let psmResult: LockIsolated<Data?>` (default `Data([0x81, 0x00])`; the central `readValue` stub returns it for `bleV3PSMCharUUID` and `identityResult` for the identity UUID), `let l2capInbound: AsyncStream<L2CAPConnection>.Continuation`. Wire them: peripheral `publishL2CAPChannel: { _ in guard let p = publishPSM.value else { throw BluetoothError.l2capNotSupported }; return p }`, `unpublishL2CAPChannel: { psm in unpublished.withValue { $0.append(psm) } }`, `l2capConnections: { inbound.stream }`; central `openL2CAPChannel: { _, _ in if openL2CAPDelayNanos.value > 0 { try? await Task.sleep(nanoseconds: openL2CAPDelayNanos.value) }; guard let c = openL2CAPResult.value else { throw BluetoothError.l2capNotSupported }; return c }`. `charsResult` default gains `psmCharUUID` (a fourth characteristic). In `FCBDriverAdapterCBMTests.swift`, `noopPeripheralClient()` starts from `testValue`, whose L2CAP endpoints are unimplemented and would fail the CBM test once bring-up calls them — add these three lines to it:
```swift
    client.publishL2CAPChannel = { _ in throw BluetoothError.l2capNotSupported }
    client.unpublishL2CAPChannel = { _ in }
    client.l2capConnections = { .finished }
```
Add the fake connection helper (from the RBTP-era tests) to `FCBDriverAdapterTests.swift`:

```swift
@MainActor
func fakeConnection(peerID: UUID, psm: UInt16, inbound: [Data] = [],
                    sent: LockIsolated<[Data]>? = nil, closed: LockIsolated<Bool>? = nil,
                    finishAfterInbound: Bool = false) -> L2CAPConnection {
    L2CAPConnection(
        id: UUID(), peerID: peerID, psm: psm,
        incoming: {
            AsyncStream { cont in
                for c in inbound { cont.yield(c) }
                if finishAfterInbound { cont.finish() }
            }
        },
        send: { d in sent?.withValue { $0.append(d) } },
        close: { closed?.setValue(true) }
    )
}
```

Append the tests (`l2capHandshake` = `Data([0x00, 0x10]) + adapterLocalIdentity`):

```swift
// MARK: - v3 L2CAP

@Test @MainActor func bringUpPublishesPSMCharacteristic() async {
    let (adapter, stubs, _) = await onlineAdapter()
    let svc = await stubs.calls.addedServices.last
    #expect(svc?.characteristics.contains { $0.id == psmCharUUID && $0.properties == .read && $0.value == Data([0x81, 0x00]) } == true)
    await adapter.stop()
    #expect(stubs.unpublished.value == [0x0081])
}

@Test @MainActor func bringUpWithoutL2CAPSupportOmitsPSMCharacteristic() async {
    let stubs = makeStubs()
    stubs.publishPSM.setValue(nil)
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral)
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn)
    stubs.centralState.yield(.poweredOn)
    #expect(await collect(events, count: 1) == [.ready])                      // bring-up still succeeds
    let svc = await stubs.calls.addedServices.last
    #expect(svc?.characteristics.contains { $0.id == psmCharUUID } == false)
    await adapter.stop()
}

@Test @MainActor func readIdentityReportsPSM() async {
    let (adapter, _, events) = await onlineAdapter()
    let p = peer(1)
    await adapter.readIdentity(p)
    #expect(await collect(events, count: 1) == [.identityRead(p, identity: adapterPeerIdentity, psm: 0x0081)])
    await adapter.stop()
}

@Test @MainActor func shortOrZeroPSMReadsAsNil() async {
    // Review Focus 1.
    let (adapter, stubs, events) = await onlineAdapter()
    stubs.psmResult.setValue(Data([0x81]))
    await adapter.readIdentity(peer(2))
    #expect(await collect(events, count: 1) == [.identityRead(peer(2), identity: adapterPeerIdentity, psm: nil)])
    stubs.psmResult.setValue(Data([0x00, 0x00]))
    await adapter.readIdentity(peer(3))
    #expect(await collect(events, count: 1) == [.identityRead(peer(3), identity: adapterPeerIdentity, psm: nil)])
    stubs.charsResult.setValue([txCharUUID, rxCharUUID, identityCharUUID])   // v2.2 peer: no PSM characteristic
    await adapter.readIdentity(peer(4))
    #expect(await collect(events, count: 1) == [.identityRead(peer(4), identity: adapterPeerIdentity, psm: nil)])
    await adapter.stop()
}

@Test @MainActor func openL2CAPSendsHandshakeFirstThenChannelOpened() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(5)
    let sent = LockIsolated<[Data]>([])
    stubs.openL2CAPResult.setValue(fakeConnection(peerID: p.id, psm: 0x0081, sent: sent))
    await adapter.openL2CAPChannel(p, psm: 0x0081)
    let got = await collect(events, count: 1)
    guard case let .channelOpened(cid, hp, dir, mtu, transport)? = got.first else { Issue.record("no channelOpened: \(got)"); await adapter.stop(); return }
    #expect(hp == p && dir == .outbound && mtu == 0 && transport == .l2cap)
    #expect(sent.value == [Data([0x00, 0x10]) + adapterLocalIdentity])
    await adapter.send(cid, fragments: [Data([0x00, 0x02, 0xAA, 0xBB])])
    #expect(sent.value.last == Data([0x00, 0x02, 0xAA, 0xBB]))
    await adapter.stop()
}

@Test @MainActor func openL2CAPFailureEmitsChannelFailedWithoutDisconnect() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(6)
    stubs.openL2CAPResult.setValue(nil)
    await adapter.openL2CAPChannel(p, psm: 0x0081)
    guard case .channelFailed(p, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelFailed"); await adapter.stop(); return }
    #expect(!(await stubs.calls.disconnected).contains(p.id), "the GATT link must survive for the fallback")
    await adapter.stop()
}

@Test @MainActor func lateL2CAPOpenAfterTimeoutIsClosed() async {
    // Review Focus 2.
    let stubs = makeStubs()
    let adapter = FCBDriverAdapter(central: stubs.central, peripheral: stubs.peripheral, l2capOpenLimit: .milliseconds(200))
    let events = adapter.start(BLEDriverConfig(localIdentity: adapterLocalIdentity))
    stubs.peripheralState.yield(.poweredOn); stubs.centralState.yield(.poweredOn)
    _ = await collect(events, count: 1)
    let p = peer(7)
    let closed = LockIsolated(false)
    stubs.openL2CAPResult.setValue(fakeConnection(peerID: p.id, psm: 0x0081, closed: closed))
    stubs.openL2CAPDelayNanos.setValue(600_000_000)
    await adapter.openL2CAPChannel(p, psm: 0x0081)
    guard case .channelFailed(p, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelFailed on timeout"); await adapter.stop(); return }
    #expect(await waitUntil(within: eventWait) { closed.value }, "a connection that arrives after the limit must be closed")
    await adapter.stop()
}

@Test @MainActor func inboundL2CAPRegistersAndPumps() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let central = UUID()
    let conn = fakeConnection(peerID: central, psm: 0x0081, inbound: [Data([0x00, 0x01, 0x42])], finishAfterInbound: true)
    stubs.l2capInbound.yield(conn)
    let got = await collect(events, count: 3)
    guard got.count == 3, case let .channelOpened(cid, hp, .inbound, 0, .l2cap) = got[0] else { Issue.record("unexpected: \(got)"); await adapter.stop(); return }
    #expect(hp == BLEPeerHandle(id: central))
    #expect(got[1] == .channelData(cid, Data([0x00, 0x01, 0x42])))
    guard case .channelClosed(cid, _) = got[2] else { Issue.record("expected channelClosed"); await adapter.stop(); return }
    await adapter.stop()
}

@Test @MainActor func closeOutboundL2CAPDisconnectsAndInboundDoesNot() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(8)
    let closedOut = LockIsolated(false)
    stubs.openL2CAPResult.setValue(fakeConnection(peerID: p.id, psm: 0x0081, closed: closedOut))
    await adapter.openL2CAPChannel(p, psm: 0x0081)
    guard case let .channelOpened(out, _, _, _, _)? = (await collect(events, count: 1)).first else { Issue.record("no open"); await adapter.stop(); return }
    await adapter.closeChannel(out)
    #expect(closedOut.value && (await stubs.calls.disconnected).contains(p.id))
    let central = UUID()
    let closedIn = LockIsolated(false)
    stubs.l2capInbound.yield(fakeConnection(peerID: central, psm: 0x0081, closed: closedIn))
    guard case let .channelOpened(inb, _, _, _, _)? = (await collect(events, count: 1)).first else { Issue.record("no inbound"); await adapter.stop(); return }
    let disconnectsBefore = (await stubs.calls.disconnected).count
    await adapter.closeChannel(inb)
    #expect(closedIn.value && (await stubs.calls.disconnected).count == disconnectsBefore)
    await adapter.stop()
    let tail = await collect(events, count: 5)
    #expect(!tail.contains { if case .channelClosed = $0 { return true }; return false })   // reducer-initiated closes are silent
}

@Test @MainActor func didDisconnectClosesThePeersL2CAPChannel() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(9)
    let closed = LockIsolated(false)
    stubs.openL2CAPResult.setValue(fakeConnection(peerID: p.id, psm: 0x0081, closed: closed))
    await adapter.openL2CAPChannel(p, psm: 0x0081)
    guard case let .channelOpened(cid, _, _, _, _)? = (await collect(events, count: 1)).first else { Issue.record("no open"); await adapter.stop(); return }
    stubs.centralEvents.yield(.didDisconnect(Peripheral(id: p.id, name: nil, state: .disconnected), nil))
    guard case .channelClosed(cid, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelClosed"); await adapter.stop(); return }
    #expect(closed.value)
    await adapter.stop()
}

@Test @MainActor func handshakeWriteFailureEmitsChannelFailed() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(1)
    var conn = fakeConnection(peerID: p.id, psm: 0x0081)
    conn.send = { _ in throw BluetoothError.operationCancelled }
    stubs.openL2CAPResult.setValue(conn)
    await adapter.openL2CAPChannel(p, psm: 0x0081)
    // The handshake write itself fails → channelFailed, no channel, link kept for the fallback.
    guard case .channelFailed(p, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelFailed"); await adapter.stop(); return }
    #expect(!(await stubs.calls.disconnected).contains(p.id))
    await adapter.stop()
}

@Test @MainActor func l2capWriteFailureAfterOpenClosesAndDisconnects() async {
    let (adapter, stubs, events) = await onlineAdapter()
    let p = peer(2)
    let sends = LockIsolated(0)
    let closed = LockIsolated(false)
    var conn = fakeConnection(peerID: p.id, psm: 0x0081, closed: closed)
    conn.send = { _ in
        let n = sends.withValue { $0 += 1; return $0 }
        if n > 1 { throw BluetoothError.operationCancelled }          // handshake succeeds, data write fails
    }
    stubs.openL2CAPResult.setValue(conn)
    await adapter.openL2CAPChannel(p, psm: 0x0081)
    guard case let .channelOpened(cid, _, _, _, _)? = (await collect(events, count: 1)).first else { Issue.record("no open"); await adapter.stop(); return }
    await adapter.send(cid, fragments: [Data([0x00, 0x01, 0x42])])
    guard case .channelClosed(cid, _)? = (await collect(events, count: 1)).first else { Issue.record("expected channelClosed"); await adapter.stop(); return }
    #expect(closed.value && (await stubs.calls.disconnected).contains(p.id))
    await adapter.stop()
}
```

- [ ] **Step 2: Run to verify failure** — `--filter FCBDriverAdapterTests`: compile errors (`psmCharUUID`, `openL2CAPChannel(_:psm:)`, `l2capOpenLimit:`), then the new tests fail.

- [ ] **Step 3: Implement**

In `FCBDriverAdapter.swift`:

Constants and service:
```swift
let bleV3PSMCharUUID = CBUUID(string: BLEProtocol.psmCharUUID)   // add `psmCharUUID = "37145b00-442d-4a94-917f-8f42c5da28e7"` to BLEProtocol in BLESupport.swift

/// v2.2 service, plus the v3 PSM characteristic when this node can accept L2CAP channels.
func bleV22Service(localIdentity: Data, psm: UInt16? = nil) -> MutableService {
    var chars = [ /* TX, RX, Identity as today */ ]
    if let psm {
        chars.append(MutableCharacteristic(id: bleV3PSMCharUUID, properties: .read, permissions: .readable,
                                           value: Data([UInt8(psm & 0xFF), UInt8(psm >> 8)])))
    }
    return MutableService(id: bleV22ServiceUUID, isPrimary: true, characteristics: chars)
}

extension FCBAdapterError { case l2capOpenTimeout }   // description "L2CAP open exceeded the limit"
```
(Add the case to the enum itself, not an extension, with its description.)

Actor state: `private let l2capOpenLimit: Duration` (init parameter, default `.seconds(10)`); `private var publishedPSM: UInt16?`; `private var l2cap: [BLEChannelID: L2CAPConnection] = [:]`; `private var inboundL2CAP: [BLEChannelID: UUID] = [:]`; `static func handshakeFrame(for identity: Data) -> Data { Data([0x00, UInt8(BLEProtocol.identityLength)]) + identity }`.

`bringUpPeripheral`: after `removeAll` (and its epoch guard):
```swift
        // nil (throw) or 0: this platform cannot listen → publish the v2.2 service only.
        let published = try? await peripheral.publishL2CAPChannel(false)
        guard epoch == myEpoch else { return }
        let psm: UInt16? = (published ?? 0) == 0 ? nil : published
        publishedPSM = psm
        _ = try await peripheral.add(bleV22Service(localIdentity: config.localIdentity, psm: psm))
```
`resetSession`: after the state clearing and before `stopScan`: snapshot `let conns = Array(l2cap.values)`, `l2cap = [:]`, `inboundL2CAP = [:]`, then `for c in conns { await c.close() }`; after `removeAll`: `if let psm = publishedPSM { await peripheral.unpublishL2CAPChannel(psm); publishedPSM = nil }`.

`subscribePeripheralStreams`: add `tasks.append(Task { [peripheral] in for await conn in peripheral.l2capConnections() { await self.registerInboundL2CAP(conn) } })`.

```swift
    private func registerInboundL2CAP(_ conn: L2CAPConnection) {
        let channelID = BLEChannelID(id: UUID())
        l2cap[channelID] = conn
        inboundL2CAP[channelID] = conn.peerID
        pumps[channelID] = Task { [conn] in
            for await chunk in conn.incoming() { self.emitChannelData(channelID, chunk) }
            await self.l2capDidClose(channelID, reason: "channel ended", disconnect: false)
        }
        continuation?.yield(.channelOpened(channelID, BLEPeerHandle(id: conn.peerID), direction: .inbound, mtu: 0, transport: .l2cap))
    }
```
`isInbound(_:)` returns `inbound[id] != nil || inboundL2CAP[id] != nil`; `emitChannelData`'s first guard also accepts `l2cap[id] != nil`.

`readIdentity`: add `bleV3PSMCharUUID` to the `discoverCharacteristics` UUID list (it stays optional: a v2.2 peer simply does not return it); after the `identity.count` guard and before the `identityRead` yield:
```swift
            var psm: UInt16? = nil
            if chars.contains(where: { $0.id == bleV3PSMCharUUID }) {
                if let raw = try? await central.readValue(peer.id, bleV3PSMCharUUID), raw.count >= 2 {
                    let value = UInt16(raw[raw.startIndex]) | (UInt16(raw[raw.startIndex + 1]) << 8)
                    psm = value == 0 ? nil : value
                }
                guard epoch == myEpoch else { try? await central.disconnect(peer.id); return }
            }
            continuation?.yield(.identityRead(peer, identity: Data(identity), psm: psm))
```

`openL2CAPChannel`:
```swift
    func openL2CAPChannel(_ peer: BLEPeerHandle, psm: UInt16) async {
        let myEpoch = epoch
        let channelID = BLEChannelID(id: UUID())
        opening.insert(channelID)
        defer { opening.remove(channelID) }
        pendingOpens.insert(peer.id)
        abortedOpens.remove(peer.id)
        defer { pendingOpens.remove(peer.id) }
        // Race the open against the limit. FCB cannot cancel a pending open, so a late arrival is
        // closed by the trailing task rather than leaked.
        enum OpenOutcome { case opened(L2CAPConnection), failed(String), timedOut }
        let open = Task { [central] () -> OpenOutcome in
            do { return .opened(try await central.openL2CAPChannel(peer.id, psm)) }
            catch { return .failed("\(error)") }
        }
        let limit = l2capOpenLimit
        let outcome: OpenOutcome = await withTaskGroup(of: OpenOutcome.self) { group in
            group.addTask { await open.value }
            group.addTask { try? await Task.sleep(for: limit); return .timedOut }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }
        let conn: L2CAPConnection
        switch outcome {
        case let .opened(c):
            conn = c
        case let .failed(reason):
            if epoch == myEpoch { continuation?.yield(.channelFailed(peer, reason: reason)) }
            return
        case .timedOut:
            Task { if case let .opened(late) = await open.value { await late.close() } }
            if epoch == myEpoch { continuation?.yield(.channelFailed(peer, reason: "\(FCBAdapterError.l2capOpenTimeout)")) }
            return
        }
        guard epoch == myEpoch, !abortedOpens.contains(peer.id) else { await conn.close(); return }
        let pump = Task { [conn] in
            for await chunk in conn.incoming() { self.emitChannelData(channelID, chunk) }
            await self.l2capDidClose(channelID, reason: "channel ended", disconnect: true)
        }
        do {
            try await conn.send(Self.handshakeFrame(for: config.localIdentity))
            guard epoch == myEpoch, !abortedOpens.contains(peer.id) else { throw FCBAdapterError.sessionEnded }
            outbound[channelID] = peer.id
            outboundByPeer[peer.id] = channelID
            l2cap[channelID] = conn
            pumps[channelID] = pump
            continuation?.yield(.channelOpened(channelID, peer, direction: .outbound, mtu: 0, transport: .l2cap))
            for chunk in earlyChunks.removeValue(forKey: channelID) ?? [] { continuation?.yield(.channelData(channelID, chunk)) }
        } catch {
            pump.cancel()
            await conn.close()
            earlyChunks[channelID] = nil
            abortedOpens.remove(peer.id)
            // No disconnect and no forget: the reducer falls back to GATT on this same link.
            if epoch == myEpoch { continuation?.yield(.channelFailed(peer, reason: "\(error)")) }
        }
    }
```
```swift
    private func l2capDidClose(_ id: BLEChannelID, reason: String?, disconnect: Bool) async {
        guard let conn = l2cap.removeValue(forKey: id) else { return }
        let peerID = outbound.removeValue(forKey: id)
        if let peerID { outboundByPeer[peerID] = nil }
        inboundL2CAP[id] = nil
        sendQueues[id] = nil
        pumps.removeValue(forKey: id)?.cancel()
        continuation?.yield(.channelClosed(id, reason: reason))
        await conn.close()
        if disconnect, let peerID { try? await central.disconnect(peerID) }
    }
```
`drain`: first branch `if let conn = l2cap[channel] { do { try await conn.send(next) } catch { await l2capDidClose(channel, reason: "write failed: \(error)", disconnect: outbound[channel] != nil); return } }` before the existing outbound-GATT branch. `send`'s overflow: for an L2CAP channel call `l2capDidClose(channel, reason: "send backlog", disconnect: outbound[channel] != nil)`. `closeChannel`: if `l2cap[channel] != nil` → `pumps.removeValue(forKey:)?.cancel()`, remove from `l2cap`, `inboundL2CAP`, `outbound`/`outboundByPeer`, `sendQueues`, `await conn.close()`, and `try? await central.disconnect(peerID)` only when it was outbound; return. `handleCentralEvent` `.didDisconnect`: if `outboundByPeer[p.id]` maps to a channel in `l2cap`, `await l2capDidClose(cid, reason: "disconnected", disconnect: false)`, else the existing `outboundDidClose`. Keep `writeOutbound` GATT-only (it is never reached for L2CAP channels because `drain` checks `l2cap` first).

- [ ] **Step 4: Run** — `--filter FCBDriverAdapterTests` all PASS; `--filter ReTiCAInterfacesTests` all PASS.

- [ ] **Step 5: Mutate, verify, revert** — batch: (a) skip `conn.send(handshakeFrame)` → `openL2CAPSendsHandshakeFirstThenChannelOpened` fails; (b) add `try? await central.disconnect(peer.id)` in the failure path → `openL2CAPFailureEmitsChannelFailedWithoutDisconnect` fails; (c) drop the trailing `late.close()` task → `lateL2CAPOpenAfterTimeoutIsClosed` fails; (d) parse the PSM from a 1-byte read (`raw.count >= 1`) → `shortOrZeroPSMReadsAsNil` fails; (e) drop `unpublishL2CAPChannel` from `resetSession` → `bringUpPublishesPSMCharacteristic` fails. Revert all; PASS.

- [ ] **Step 6: Commit** — `feat: FCB adapter publishes a PSM and opens, accepts and drives L2CAP channels`.

---

### Task 5: CoreBluetoothMock — real central sees a PSM, L2CAP open fails, GATT fallback end to end

**Files:**
- Modify: `Tests/ReTiCAInterfacesTests/FCBDriverAdapterCBMTests.swift` (append one test; extend the spec delegate)

**Interfaces:**
- Consumes: Task 4's adapter; CBM's `openL2CAPChannel` (throws `l2capNotSupported` under the mock, which is exactly the fallback trigger).

- [ ] **Step 1: Write the test**

First change `V22SpecDelegate`'s read handler from the ternary to a switch so it also serves the PSM:

```swift
    func peripheral(_ peripheral: CBMPeripheralSpec,
                    didReceiveReadRequestFor characteristic: CBMCharacteristicMock) -> Result<Data, any Error> {
        switch characteristic.uuid {
        case identityCharUUID: return .success(identity)
        case psmCharUUID:      return .success(Data([0x81, 0x00]))     // 0x0081 little-endian
        default:               return .failure(CBATTError(.attributeNotFound))
        }
    }
```

The existing v2.2 CBM test keeps passing: its mock service has no PSM characteristic, so the adapter never reads it. Then append to the `FCBDriverAdapterCBMTests` suite:

```swift
    @Test func realCentralFallsBackToGattWhenL2CAPOpenIsUnsupported() async throws {
        CBMCentralManagerMock.tearDownSimulation()
        CBMCentralManagerMock.simulateInitialState(.poweredOn)
        let id = UUID()
        let tx = CBMCharacteristicMock(type: txCharUUID, properties: [.read, .notify])
        let rx = CBMCharacteristicMock(type: rxCharUUID, properties: [.write, .writeWithoutResponse])
        let ident = CBMCharacteristicMock(type: identityCharUUID, properties: [.read])
        let psm = CBMCharacteristicMock(type: psmCharUUID, properties: [.read])
        let service = CBMServiceMock(type: serviceUUID, primary: true, characteristics: tx, rx, ident, psm)
        let delegate = V22SpecDelegate()
        let spec = CBMPeripheralSpec
            .simulatePeripheral(identifier: id, proximity: .near)
            .advertising(advertisementData: [CBMAdvertisementDataServiceUUIDsKey: [serviceUUID],
                                             CBMAdvertisementDataIsConnectable: true as NSNumber], withInterval: 0.05)
            .connectable(name: "v3-node", services: [service], delegate: delegate, connectionInterval: 0.01)
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
        #expect(read == .identityRead(handle, identity: delegate.identity, psm: 0x0081))

        await driver.openL2CAPChannel(handle, 0x0081)          // CBM cannot open L2CAP → channelFailed, link kept
        let failed = await waitFor { if case .channelFailed = $0 { return true }; return false }
        #expect(failed != nil)
        await driver.openChannel(handle)                        // the reducer's fallback, driven by hand here
        let opened = await waitFor { if case .channelOpened = $0 { return true }; return false }
        guard case let .channelOpened(_, h, dir, _, transport)? = opened else { Issue.record("expected channelOpened after fallback, got \(String(describing: opened))"); await driver.stop(); return }
        #expect(h == handle && dir == .outbound && transport == .gatt)
        #expect(delegate.writes.value.first == adapterLocalIdentity)   // the GATT handshake reached the peripheral
        await driver.stop()
    }
```

- [ ] **Step 2: Run** — `--filter FCBDriverAdapterCBMTests` — expected PASS (both tests).

- [ ] **Step 3: Mutate, verify, revert** — in the adapter's `openL2CAPChannel` failure path add `try? await central.disconnect(peer.id)` → the fallback `openChannel` then fails (`channelOpened` never arrives) and the test fails. Revert; PASS.

- [ ] **Step 4: Commit** — `test: CoreBluetoothMock run of the v3 PSM read and GATT fallback`.

---

### Task 6: Docs, hardware checklist, full verification

**Files:**
- Modify: `docs/superpowers/specs/2026-09-26-ble-v3-l2cap-ios-design.md` (only if Tasks 2–5 deviated; record the deviation under a "Deviations during implementation" heading)
- Modify: `docs/superpowers/plans/2026-09-26-ble-v22-hardware-checklist.md` (append a v3 section)
- Modify: `docs/superpowers/2026-08-24-ble-punch-list.md` (one status line under the 2026-09-26 note)

- [ ] **Step 1: Checklist**

Append to the hardware checklist:

```markdown
## v3 L2CAP fast path (iPhone ↔ iPhone; Pi and Columba stay on GATT)
- [ ] Both iPhones publish a PSM (LightBlue or nRF Connect shows `…28e7` with a non-zero LE value that changes across app relaunches).
- [ ] The lower identity's outbound L2CAP channel is the one surviving channel; logs on both sides show `transport: .l2cap`.
- [ ] Small and > 391 B LXMF messages both ways over the channel; no fragmentation headers on the wire (packet capture or driver log).
- [ ] Kill one app mid-transfer: the survivor gets `channelClosed` within the supervision timeout and re-establishes over L2CAP on relaunch.
- [ ] Force the fallback: run one side with `l2capEnabled = false` — the pair establishes over GATT; then with both enabled but one side's PSM characteristic removed — GATT again; then with a PSM published but the listener unpublished — the 10 s open limit fires and the pair falls back to GATT on the same link without a reconnect.
- [ ] iPhone ↔ Pi (v2.2): unchanged behaviour over GATT; the Pi never sees the PSM characteristic.
- [ ] Record throughput on L2CAP vs GATT for the spec's bitrate revision.
```

- [ ] **Step 2: Punch list** — under the existing "2026-09-26 update" blockquote add one line: `> v3 (L2CAP fast path) landed on the iOS side per `docs/superpowers/specs/2026-09-26-ble-v3-l2cap-ios-design.md`; the Pi gains it in a separate ble-reticulum contribution.`

- [ ] **Step 3: Full verification** — `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-v3` (parallel) TWICE, both green; then `grep -rn "readDirectory\|BLEHello\|pairingMode" Sources Tests` → empty.

- [ ] **Step 4: Commit** — `docs: v3 hardware checklist and status`.

---

## Done criteria

- All six tasks committed on `feat/ble-v3-l2cap` in the worktree; two consecutive parallel full-suite runs green.
- Every task's mutation step run and reverted.
- Spec §2 still matches the code (or a deviation is recorded).
