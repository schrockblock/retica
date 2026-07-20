# Resource Windowing + Retransmission Robustness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make the single-segment `ResourceTransfer` robust over lossy links — adaptive send window, retransmission watchdog, sender-side timers, and cancellation — wire-compatible with Python-RNS 1.3.8.

**Architecture:** Extract the pure window arithmetic (`ResourceWindow`) and next-request selection (`Resource.nextWindowRequest`) into the `ReTiCA` core as unit-testable value logic; extend the `ResourceTransfer` reducer in `ReTiCATransport` to wire those helpers, own `continuousClock` watchdogs (one-shot, re-armed on activity, cancelled on terminal state), and emit/handle cancellation packets.

**Tech Stack:** Swift 6, The Composable Architecture ~1.26 (`@Reducer`, `TestStore`, `TestClock`, `@Dependency(\.continuousClock)`), Swift Testing (`@Test`), CryptoKit via the in-core `Crypto`/`Link`.

## Global Constraints

- **Wire encryption per `Packet.py`:** RESOURCE parts (0x01) and RESOURCE_PRF (PROOF/0x05) are **plaintext**; RESOURCE_ADV (0x02), RESOURCE_REQ (0x03), RESOURCE_ICL (0x06), RESOURCE_RCL (0x07) are **encrypted** with the link session key (`Link.encrypt`). All resource packets use `destinationType == .link`, `destinationHash == linkID`.
- **Window arithmetic mirrors RNS 1.3.8 exactly** (grow +1 bounded by `windowMax`, raise `windowMin` when `(window − windowMin) > (flexibility − 1)`; shrink −1 bounded by `windowMin`, drop `windowMax`, second `windowMax −1` when `(windowMax − window) > (flexibility − 1)`). `windowMax` fixed at the SLOW cap 10 (rate escalation deferred).
- **Request plaintext format** unchanged from 6b: `0x00 ‖ resourceHash ‖ concatenated-4-byte-map-hashes`.
- **Data-slice index safety:** any `Data` from `Link.decrypt`/`dropFirst`/subscript/`hashmap` may have a non-zero `startIndex`; materialize `Data(...)` before subscripting and stride via `startIndex`/`endIndex`, never bare `Int` offsets.
- **Two-layer purity:** the `ReTiCA` core has zero TCA/Combine dependencies; TCA lives only in `ReTiCATransport`. `State` stays `Equatable` + `Identifiable`.
- **No compound shell commands** (one command per invocation; commit via `git commit -F <file>` for multi-line messages under `/tmp/ReTiCA/`).
- **Mutation-test discipline:** every new/changed test is verified by (a) run-pass, (b) batch-mutate production to force fail, (c) revert to green, before commit.
- **Commit trailers:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCA/Resource/ResourceWindow.swift` (**create**, Task 1) — pure `ResourceWindow` value type.
- `Sources/ReTiCA/Resource/Resource.swift` (**modify**, Task 2) — add `nextWindowRequest`.
- `Sources/ReTiCATransport/ResourceTransfer.swift` (**modify**, Tasks 3–5) — windowing, watchdogs, cancellation.
- `Tests/ReTiCATests/Resource/ResourceWindowTests.swift` (**create**, Task 1).
- `Tests/ReTiCATests/Resource/ResourceTests.swift` (**modify**, Task 2) — `nextWindowRequest` tests.
- `Tests/ReTiCATransportTests/ResourceTransferTests.swift` (**modify**, Tasks 3–6) — windowed reducer tests; rework of 6b receiver/sender/E2E tests.
- `README.md` (**modify**, Task 6).

---

### Task 1: `ResourceWindow` pure value type (core)

**Files:**
- Create: `Sources/ReTiCA/Resource/ResourceWindow.swift`
- Test: `Tests/ReTiCATests/Resource/ResourceWindowTests.swift`

**Interfaces:**
- Produces: `ResourceWindow` value type with `init(window:windowMin:windowMax:flexibility:)` (all defaulted to 4/2/10/4), `var window/windowMin/windowMax/flexibility: Int`, `func grown() -> ResourceWindow`, `func shrunk() -> ResourceWindow`. `Equatable`, `Sendable`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCATests/Resource/ResourceWindowTests.swift`:

```swift
import Testing
@testable import ReTiCA

@Test func windowDefaultsMatchRNSSlowStart() {
    let w = ResourceWindow()
    #expect(w.window == 4)
    #expect(w.windowMin == 2)
    #expect(w.windowMax == 10)
    #expect(w.flexibility == 4)
}

@Test func grownIncrementsWindowUpToMax() {
    var w = ResourceWindow()
    let sizes = (0..<10).map { _ -> Int in w = w.grown(); return w.window }
    // 4 -> 5,6,7,8,9,10 then capped at 10
    #expect(sizes == [5, 6, 7, 8, 9, 10, 10, 10, 10, 10])
    #expect(w.windowMax == 10)
}

@Test func grownRaisesWindowMinOnceSpreadExceedsFlexibility() {
    // spread = window - windowMin; windowMin rises when spread > flexibility-1 (== 3).
    var w = ResourceWindow()          // window 4, windowMin 2  (spread 2)
    w = w.grown()                     // window 5, spread 3 -> no bump
    #expect(w.window == 5); #expect(w.windowMin == 2)
    w = w.grown()                     // window 6, spread 4 > 3 -> windowMin 3
    #expect(w.window == 6); #expect(w.windowMin == 3)
    w = w.grown()                     // window 7, spread 4 > 3 -> windowMin 4
    #expect(w.window == 7); #expect(w.windowMin == 4)
}

@Test func shrunkDecrementsWindowAndCeiling() {
    // Start wide so shrink has room: window 8, min 2, max 10 (spread window-min = 6).
    var w = ResourceWindow(window: 8, windowMin: 2, windowMax: 10, flexibility: 4)
    w = w.shrunk()
    // window 7; windowMax 10>2 -> 9; (windowMax-window)=9-7=2, not > 3, so no second drop.
    #expect(w.window == 7); #expect(w.windowMax == 9)
}

@Test func shrunkAppliesSecondCeilingDropOnWideSpread() {
    // window 4, min 2, max 10: shrink -> window 3; max 10->9; (9-3)=6 > 3 -> max 8.
    var w = ResourceWindow(window: 4, windowMin: 2, windowMax: 10, flexibility: 4)
    w = w.shrunk()
    #expect(w.window == 3); #expect(w.windowMax == 8)
}

@Test func shrunkStopsAtWindowMin() {
    var w = ResourceWindow(window: 2, windowMin: 2, windowMax: 10, flexibility: 4)
    w = w.shrunk()   // window == windowMin -> no change to window
    #expect(w.window == 2); #expect(w.windowMax == 10)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter ResourceWindow`
Expected: FAIL (no such type `ResourceWindow`).

- [ ] **Step 3: Implement `ResourceWindow`**

Create `Sources/ReTiCA/Resource/ResourceWindow.swift`:

```swift
import Foundation

/// Adaptive send-window sizing for a Reticulum resource transfer (receiver side).
/// Pure value type mirroring the Python-RNS 1.3.8 window arithmetic. `windowMax` is the
/// SLOW cap; rate-based escalation to the fast cap is deferred to a later slice.
public struct ResourceWindow: Equatable, Sendable {
    public var window: Int
    public var windowMin: Int
    public var windowMax: Int
    public var flexibility: Int

    public static let initialWindow = 4
    public static let minWindow = 2
    public static let maxWindowSlow = 10
    public static let defaultFlexibility = 4

    public init(window: Int = initialWindow, windowMin: Int = minWindow,
                windowMax: Int = maxWindowSlow, flexibility: Int = defaultFlexibility) {
        self.window = window
        self.windowMin = windowMin
        self.windowMax = windowMax
        self.flexibility = flexibility
    }

    /// One completed round: grow the window, raising the floor once the spread is wide enough.
    public func grown() -> ResourceWindow {
        var w = self
        if w.window < w.windowMax {
            w.window += 1
            if (w.window - w.windowMin) > (w.flexibility - 1) {
                w.windowMin += 1
            }
        }
        return w
    }

    /// One timeout: shrink the window and ceiling, tightening the ceiling again on a wide spread.
    public func shrunk() -> ResourceWindow {
        var w = self
        if w.window > w.windowMin {
            w.window -= 1
            if w.windowMax > w.windowMin {
                w.windowMax -= 1
                if (w.windowMax - w.window) > (w.flexibility - 1) {
                    w.windowMax -= 1
                }
            }
        }
        return w
    }
}
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter ResourceWindow`
Expected: PASS (6 tests).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter ResourceWindow`, confirm the named test fails, revert; final green:
- In `grown()`, change `w.window += 1` to `w.window += 2` → `grownIncrementsWindowUpToMax` fails.
- In `grown()`, change the floor guard to `> w.flexibility` (drop the `- 1`) → `grownRaisesWindowMinOnceSpreadExceedsFlexibility` fails.
- In `shrunk()`, remove the second `w.windowMax -= 1` line → `shrunkAppliesSecondCeilingDropOnWideSpread` fails.

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCA/Resource/ResourceWindow.swift Tests/ReTiCATests/Resource/ResourceWindowTests.swift
git commit -F /tmp/ReTiCA/commit-t1.txt
```
(`/tmp/ReTiCA/commit-t1.txt` first line: `feat: ResourceWindow adaptive send-window arithmetic (core)`, then a blank line and the two trailer lines.)

---

### Task 2: `Resource.nextWindowRequest` selection helper (core)

**Files:**
- Modify: `Sources/ReTiCA/Resource/Resource.swift`
- Test: `Tests/ReTiCATests/Resource/ResourceTests.swift`

**Interfaces:**
- Consumes: `Resource.mapHashLength` (== 4).
- Produces: `static func nextWindowRequest(receivedIndices: Set<Int>, hashmap: Data, height: Int, window: Int, partCount: Int) -> (indices: [Int], mapHashes: Data)` — scans the `window` slots after `height`, returning the still-missing indices (those not in `receivedIndices`) and their concatenated 4-byte map-hashes.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCATests/Resource/ResourceTests.swift`:

```swift
@Test func nextWindowRequestSelectsFirstWindowOfMissingParts() {
    // 8 parts, 4-byte map hashes 0x00000000, 0x01010101, ... 0x07070707.
    var hashmap = Data()
    for i in 0..<8 { hashmap += Data(repeating: UInt8(i), count: 4) }
    let req = Resource.nextWindowRequest(receivedIndices: [], hashmap: hashmap,
                                         height: -1, window: 4, partCount: 8)
    #expect(req.indices == [0, 1, 2, 3])
    #expect(req.mapHashes == Data([0,0,0,0, 1,1,1,1, 2,2,2,2, 3,3,3,3]))
}

@Test func nextWindowRequestSkipsAlreadyReceivedSlots() {
    var hashmap = Data()
    for i in 0..<8 { hashmap += Data(repeating: UInt8(i), count: 4) }
    // height 1 (0,1 done); within slots 2..5, slot 3 already received.
    let req = Resource.nextWindowRequest(receivedIndices: [0, 1, 3], hashmap: hashmap,
                                         height: 1, window: 4, partCount: 8)
    #expect(req.indices == [2, 4, 5])                       // slot 3 skipped; 4 slots scanned (2,3,4,5)
    #expect(req.mapHashes == Data([2,2,2,2, 4,4,4,4, 5,5,5,5]))
}

@Test func nextWindowRequestClampsToPartCount() {
    var hashmap = Data()
    for i in 0..<3 { hashmap += Data(repeating: UInt8(i), count: 4) }
    let req = Resource.nextWindowRequest(receivedIndices: [], hashmap: hashmap,
                                         height: -1, window: 4, partCount: 3)
    #expect(req.indices == [0, 1, 2])                      // only 3 parts exist
    #expect(req.mapHashes.count == 12)
}

@Test func nextWindowRequestEmptyWhenAllReceived() {
    var hashmap = Data()
    for i in 0..<3 { hashmap += Data(repeating: UInt8(i), count: 4) }
    let req = Resource.nextWindowRequest(receivedIndices: [0, 1, 2], hashmap: hashmap,
                                         height: 2, window: 4, partCount: 3)
    #expect(req.indices.isEmpty)
    #expect(req.mapHashes.isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter nextWindowRequest`
Expected: FAIL (no such method).

- [ ] **Step 3: Implement `nextWindowRequest`**

Add this method inside the `Resource` enum in `Sources/ReTiCA/Resource/Resource.swift` (e.g. after `hashmap(parts:randomHash:)`):

```swift
    /// Select the next window of still-missing parts to request. Scans the `window` slots after
    /// `height` (bounded by `partCount`), returning the indices not present in `receivedIndices`
    /// and their concatenated 4-byte map hashes sliced from `hashmap`. Index-safe.
    public static func nextWindowRequest(
        receivedIndices: Set<Int>, hashmap: Data, height: Int, window: Int, partCount: Int
    ) -> (indices: [Int], mapHashes: Data) {
        let m = Data(hashmap)
        var indices: [Int] = []
        var mapHashes = Data()
        var pn = height + 1
        let searchEnd = min(height + 1 + window, partCount)
        while pn < searchEnd {
            if !receivedIndices.contains(pn) {
                let start = m.startIndex + pn * mapHashLength
                let end = start + mapHashLength
                guard end <= m.endIndex else { break }
                indices.append(pn)
                mapHashes.append(Data(m[start..<end]))
            }
            pn += 1
        }
        return (indices, mapHashes)
    }
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter nextWindowRequest`
Expected: PASS (4 tests).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter nextWindowRequest`, confirm the named test fails, revert; final green:
- Change `let searchEnd = min(height + 1 + window, partCount)` to `min(height + 1 + window + 1, partCount)` → `nextWindowRequestSkipsAlreadyReceivedSlots` fails (would scan slot 6 and include index 6).
- Change `if !receivedIndices.contains(pn)` to `if true` → `nextWindowRequestSkipsAlreadyReceivedSlots` fails (would include already-received slot 3).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCA/Resource/Resource.swift Tests/ReTiCATests/Resource/ResourceTests.swift
git commit -F /tmp/ReTiCA/commit-t2.txt
```
(First line: `feat: Resource.nextWindowRequest window selection (core)`, blank line, trailers.)

---

### Task 3: Receiver windowing + retransmission watchdog

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift`
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`

**Interfaces:**
- Consumes: `ResourceWindow` (Task 1), `Resource.nextWindowRequest` (Task 2), existing `linkPacket`, `Link.encrypt/decrypt`, `Resource.assemble/verify/proofData/mapHash`.
- Produces: new `State` fields (`window: ResourceWindow`, `consecutiveCompletedHeight: Int`, `outstanding: Set<Int>`, `retriesLeft: Int`, `partTimeoutFactor: Int`, `receivedFirstPart: Bool`, `rtt: Duration`, plus sender fields `sentIndices: Set<Int>`, `advRetriesLeft: Int`, `proofRetriesLeft: Int`), an `rtt: Duration = .seconds(1)` parameter on both initializers, `Action.receiverDeadline`, the `@Dependency(\.continuousClock)`, `CancelID.watchdog`, and the constants enum `Const`. Windowed receiver `accept`/part-handling/`receiverDeadline`.

- [ ] **Step 1: Add state fields, constants, clock, and the new action**

In `ResourceTransfer`, add the constants enum and clock dependency (below `public init() {}`):

```swift
    @Dependency(\.continuousClock) var clock

    enum Const {
        static let maxRetries = 16
        static let maxAdvRetries = 4
        static let proofRetries = 3
        static let partTimeoutFactor = 4
        static let partTimeoutFactorAfterRTT = 2
        static let proofTimeoutFactor = 3
        static let retryGrace: Duration = .milliseconds(250)
        static let perRetryDelay: Duration = .milliseconds(500)
        static let senderGrace: Duration = .seconds(10)
        static let processingGrace: Duration = .seconds(1)
    }

    enum CancelID: Hashable { case watchdog }
```

Add `.awaitingProof` to `Status`:

```swift
    public enum Status: Equatable, Sendable { case idle, advertised, requesting, transferring, awaitingProof, complete, failed }
```

Add the new stored properties to `State` (after `receivedParts`):

```swift
        // windowing / retransmission (receiver)
        public var window: ResourceWindow
        public var consecutiveCompletedHeight: Int
        public var outstanding: Set<Int>
        public var retriesLeft: Int
        public var partTimeoutFactor: Int
        public var receivedFirstPart: Bool
        public var rtt: Duration
        // sender timers
        public var sentIndices: Set<Int>
        public var advRetriesLeft: Int
        public var proofRetriesLeft: Int
```

In the **sending** initializer, add `rtt: Duration = .seconds(1)` as the last parameter before `id`, and set the new fields at the end of the init body:

```swift
        public init(sending data: Data, linkID: Data, sessionKey: Data, interfaceID: InterfaceID,
                    prefix: Data, randomHash: Data, sdu: Int, rtt: Duration = .seconds(1), id: UUID = UUID()) {
            // ... existing assignments unchanged ...
            self.window = ResourceWindow()
            self.consecutiveCompletedHeight = -1
            self.outstanding = []
            self.retriesLeft = Const.maxRetries
            self.partTimeoutFactor = Const.partTimeoutFactor
            self.receivedFirstPart = false
            self.rtt = rtt
            self.sentIndices = []
            self.advRetriesLeft = Const.maxAdvRetries
            self.proofRetriesLeft = Const.proofRetries
        }
```

In the **receiving** initializer, add `rtt: Duration = .seconds(1)` before `id`, and set the same new fields:

```swift
        public init(receivingOn linkID: Data, sessionKey: Data, interfaceID: InterfaceID,
                    rtt: Duration = .seconds(1), id: UUID = UUID()) {
            // ... existing assignments unchanged ...
            self.window = ResourceWindow()
            self.consecutiveCompletedHeight = -1
            self.outstanding = []
            self.retriesLeft = Const.maxRetries
            self.partTimeoutFactor = Const.partTimeoutFactor
            self.receivedFirstPart = false
            self.rtt = rtt
            self.sentIndices = []
            self.advRetriesLeft = Const.maxAdvRetries
            self.proofRetriesLeft = Const.proofRetries
        }
```

Add `.receiverDeadline` to `Action`:

```swift
    public enum Action: Equatable {
        case advertise
        case accept(Data)
        case received(Data)
        case receiverDeadline
        case delegate(Delegate)
        // ... Delegate unchanged ...
    }
```

- [ ] **Step 2: Add the reducer helpers**

Inside `Reduce { state, action in ... }`, alongside the existing `linkPacket` local function, add:

```swift
            func armReceiverWatchdog(_ s: State) -> Effect<Action> {
                let timeout = s.rtt * s.partTimeoutFactor
                    + Const.retryGrace
                    + Const.perRetryDelay * (Const.maxRetries - s.retriesLeft)
                return .run { send in
                    try await clock.sleep(for: timeout)
                    await send(.receiverDeadline)
                }.cancellable(id: CancelID.watchdog, cancelInFlight: true)
            }

            func requestNextWindow(_ s: inout State) -> Effect<Action> {
                let received = Set(s.receivedParts.keys)
                let req = Resource.nextWindowRequest(
                    receivedIndices: received, hashmap: s.advertisement?.hashmap ?? Data(),
                    height: s.consecutiveCompletedHeight, window: s.window.window,
                    partCount: Int(s.expectedParts))
                s.outstanding = Set(req.indices)
                let payload = Data([0x00]) + s.resourceHash + req.mapHashes
                guard let raw = linkPacket(.data, .resourceRequest,
                                           Link.encrypt(payload, sessionKey: s.sessionKey))
                else { return .none }
                return .merge(.send(.delegate(.transmit(s.interfaceID, raw))), armReceiverWatchdog(s))
            }
```

- [ ] **Step 3: Rewrite the receiver `accept` case**

Replace the body of `case let .accept(data):` (keep the same guard/parse/unpack down through `state.advertisement = adv`) so it requests the first window instead of all parts:

```swift
            case let .accept(data):
                guard state.role == .receiver, state.status == .idle,
                      let packet = Packet(raw: data), packet.packetType == .data,
                      packet.context == .resourceAdvertisement,
                      let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                      let adv = ResourceAdvertisement.unpack(plain)
                else { return .none }
                state.resourceHash = adv.hash
                state.randomHash = adv.randomHash
                state.expectedParts = adv.numberOfParts
                state.advertisement = adv
                state.window = ResourceWindow()
                state.consecutiveCompletedHeight = -1
                state.retriesLeft = Const.maxRetries
                state.status = .requesting
                return requestNextWindow(&state)
```

- [ ] **Step 4: Rewrite the receiver part-received case**

Replace the `case (.receiver, .data, .resource):` block with the windowed version:

```swift
                case (.receiver, .data, .resource):
                    guard state.status == .requesting || state.status == .transferring,
                          let adv = state.advertisement else { return .none }
                    let chunk = packet.payload
                    let mh = Resource.mapHash(chunk: chunk, randomHash: state.randomHash)
                    let m = Data(adv.hashmap)
                    var index: Int? = nil
                    var gi = 0
                    var j = m.startIndex
                    while j + 4 <= m.endIndex {
                        if Data(m[j..<(j + 4)]) == mh { index = gi; break }
                        gi += 1; j += 4
                    }
                    guard let idx = index, state.receivedParts[idx] == nil else { return .none }
                    state.receivedParts[idx] = chunk
                    state.outstanding.remove(idx)
                    state.status = .transferring
                    if !state.receivedFirstPart {
                        state.receivedFirstPart = true
                        state.partTimeoutFactor = Const.partTimeoutFactorAfterRTT
                    }
                    while state.receivedParts[state.consecutiveCompletedHeight + 1] != nil {
                        state.consecutiveCompletedHeight += 1
                    }
                    guard state.outstanding.isEmpty else { return armReceiverWatchdog(state) }
                    // round complete
                    if state.receivedParts.count < Int(state.expectedParts) {
                        state.window = state.window.grown()
                        state.retriesLeft = Const.maxRetries
                        return requestNextWindow(&state)
                    }
                    // all parts in: assemble + verify + prove (cancel the watchdog)
                    let ordered = (0..<Int(state.expectedParts)).compactMap { state.receivedParts[$0] }
                    guard ordered.count == Int(state.expectedParts),
                          let out = Resource.assemble(parts: ordered, sessionKey: state.sessionKey),
                          Resource.verify(data: out, randomHash: state.randomHash, hash: state.resourceHash)
                    else {
                        state.status = .failed
                        return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))
                    }
                    state.status = .complete
                    let proof = Resource.proofData(data: out, hash: state.resourceHash)
                    guard let praw = linkPacket(.proof, .resourceProof, proof)
                    else { return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.received(out)))) }
                    return .merge(.cancel(id: CancelID.watchdog),
                                  .send(.delegate(.transmit(state.interfaceID, praw))),
                                  .send(.delegate(.received(out))))
```

- [ ] **Step 5: Add the `receiverDeadline` case**

Add a new top-level `case` in the outer `switch action` (e.g. after the `case let .received(data):` block closes, before `case .delegate:`):

```swift
            case .receiverDeadline:
                guard state.role == .receiver,
                      state.status == .requesting || state.status == .transferring else { return .none }
                guard state.retriesLeft > 0 else {
                    state.status = .failed
                    let rcl = linkPacket(.data, .resourceReceiverCancel,
                                         Link.encrypt(state.resourceHash, sessionKey: state.sessionKey))
                    return .merge(.cancel(id: CancelID.watchdog),
                                  rcl.map { Effect.send(.delegate(.transmit(state.interfaceID, $0))) } ?? .none,
                                  .send(.delegate(.failed)))
                }
                state.window = state.window.shrunk()
                state.retriesLeft -= 1
                return requestNextWindow(&state)
```

- [ ] **Step 6: Rework the two 6b receiver tests + add windowing tests**

In `Tests/ReTiCATransportTests/ResourceTransferTests.swift`, add a clock-carrying receiver store helper near the top (after `receiverState`):

```swift
@MainActor
private func receiverStore(_ clock: TestClock<Duration>) -> TestStore<ResourceTransfer.State, ResourceTransfer.Action> {
    let store = TestStore(initialState: receiverState()) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

// Build a raw RESOURCE part packet for chunk (plaintext, dest .link).
private func partPacket(_ chunk: Data) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: .resource, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil, payload: chunk)
    return try! p.packed()
}
```

**Replace** the existing `receiverAcceptEmitsRequestForAllParts` test with a first-window assertion (a 6-part resource; window 4 → first REQ carries 4 map-hashes), and **replace** `receiverAssemblesPartsAndProves` with a full windowed completion. If `advertisementPacket`/`partPacket` helpers already exist from 6b, reuse them (do not redefine). Use a payload large enough for ≥6 parts at `sdu: 24`:

```swift
@Test @MainActor func receiverAcceptRequestsFirstWindowOnly() async {
    let data = Data(repeating: 0x33, count: 160)          // 160+4 prefix -> stream > 6 parts at sdu 24
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    let raw = (await captureTransmits(store, count: 1))[0]
    let packet = Packet(raw: raw)!
    #expect(packet.context == .resourceRequest)
    let plain = Link.decrypt(packet.payload, sessionKey: key)!
    let body = Data(plain)
    // 1 flag + 32 hash + 4*window map-hashes
    #expect(body.count == 1 + 32 + 4 * 4)                 // window == 4
    #expect(store.state.outstanding == [0, 1, 2, 3])
    // Drive to failure to cancel the armed watchdog (16 timeouts).
    for _ in 0..<ResourceTransfer.Const.maxRetries { await store.send(.receiverDeadline) }
    #expect(store.state.status == .failed)
}

@Test @MainActor func receiverWindowsThroughAllPartsAndProves() async {
    let data = Data("windowed receiver reconstructs this exact payload across multiple request rounds ok".utf8)
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)           // first-window request

    let got = LockIsolated<Data?>(nil)
    let total = sender.parts.count
    // Feed every part in order; each completed window triggers the next request; last completes.
    for (n, chunk) in sender.parts.enumerated() {
        await store.send(.received(partPacket(chunk)))
        if n == total - 1 {
            await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }   // PRF
            await store.receive { action in
                if case let .delegate(.received(d)) = action { got.setValue(d); return true }
                return false
            }
        }
    }
    #expect(got.value == data)
    #expect(store.state.status == .complete)
}

@Test @MainActor func receiverRetransmitsThenFailsAfterMaxRetries() async {
    let data = Data(repeating: 0x5A, count: 160)
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)

    // First timeout: window shrinks (4 -> 3), a retry is spent, a new request goes out.
    await store.send(.receiverDeadline)
    #expect(store.state.window.window == 3)
    #expect(store.state.retriesLeft == ResourceTransfer.Const.maxRetries - 1)
    _ = await captureTransmits(store, count: 1)           // re-request

    // Exhaust the remaining retries; the final timeout fails the transfer and emits an RCL.
    for _ in 0..<(ResourceTransfer.Const.maxRetries - 1) { await store.send(.receiverDeadline) }
    #expect(store.state.status == .failed)
    let rcl = (await captureTransmits(store, count: 1))[0]
    let p = Packet(raw: rcl)!
    #expect(p.context == .resourceReceiverCancel)
    #expect(Link.decrypt(p.payload, sessionKey: key) == sender.resourceHash)
}
```

> Note on `advertisementPacket`: if 6b did not leave a `receiver`-oriented advertisement-packet helper, add one:
> ```swift
> private func advertisementPacket(_ s: ResourceTransfer.State) -> Data {
>     let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
>                    destinationType: .link, context: .resourceAdvertisement, contextFlag: false, hops: 0,
>                    destinationHash: linkID, transportId: nil,
>                    payload: Link.encrypt(s.advertisement!.pack(), sessionKey: key))
>     return try! p.packed()
> }
> ```

- [ ] **Step 7: Run to verify**

Run: `swift test --filter ResourceTransfer`
Expected: PASS — the three windowed receiver tests plus the unchanged sender tests. (The old `endToEndTwoReducerResourceTransfer` still passes here because the sender is unchanged and the receiver completes across windows; if it references removed helpers, it is reworked in Task 6.)

- [ ] **Step 8: Mutation sweep**

Apply each, run `swift test --filter ResourceTransfer`, confirm the named test fails, revert; final green:
- In `requestNextWindow`, force `window: Int.max` in the `nextWindowRequest` call → `receiverAcceptRequestsFirstWindowOnly` fails (requests all parts, not 4).
- In the part-received round-complete branch, change `state.window = state.window.grown()` to `state.window = state.window.shrunk()` — the window never grows, but the transfer still completes; instead change the completion guard `state.receivedParts.count < Int(state.expectedParts)` to `... <= ...` → `receiverWindowsThroughAllPartsAndProves` fails (never assembles).
- In `.receiverDeadline`, change `guard state.retriesLeft > 0` to `>= 0` → `receiverRetransmitsThenFailsAfterMaxRetries` fails (one extra retry before failing).

- [ ] **Step 9: Commit**

```
git add Sources/ReTiCATransport/ResourceTransfer.swift Tests/ReTiCATransportTests/ResourceTransferTests.swift
git commit -F /tmp/ReTiCA/commit-t3.txt
```
(First line: `feat: ResourceTransfer receiver windowing + retransmission watchdog`, blank line, trailers.)

---

### Task 4: Sender-side timers + awaiting-proof

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift`
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`

**Interfaces:**
- Consumes: Task 3's `Const`, `CancelID`, `clock`, `Status.awaitingProof`, `sentIndices`/`advRetriesLeft`/`proofRetriesLeft`.
- Produces: `Action.senderDeadline`; sender watchdog arming on `advertise`/request/awaiting-proof; the sender-side re-advertise, transfer-patience, and proof-timeout behavior; ICL emission on sender abort.

- [ ] **Step 1: Add the sender watchdog helper + action**

Add `.senderDeadline` to `Action` (next to `.receiverDeadline`). Inside `Reduce`, add:

```swift
            func armSenderWatchdog(_ s: State) -> Effect<Action> {
                let timeout: Duration
                switch s.status {
                case .advertised:
                    timeout = s.rtt * Const.partTimeoutFactor + Const.processingGrace
                case .transferring:
                    timeout = s.rtt * Const.partTimeoutFactor * Const.maxRetries + Const.senderGrace
                case .awaitingProof:
                    timeout = s.rtt * Const.proofTimeoutFactor + Const.senderGrace
                default:
                    return .none
                }
                return .run { send in
                    try await clock.sleep(for: timeout)
                    await send(.senderDeadline)
                }.cancellable(id: CancelID.watchdog, cancelInFlight: true)
            }

            func senderCancel(_ s: State) -> Effect<Action> {
                guard let icl = linkPacket(.data, .resourceInitiatorCancel,
                                           Link.encrypt(s.resourceHash, sessionKey: s.sessionKey))
                else { return .none }
                return .send(.delegate(.transmit(s.interfaceID, icl)))
            }
```

- [ ] **Step 2: Arm the sender watchdog on advertise**

At the end of the `case .advertise:` block, change the return to also arm the watchdog:

```swift
                state.status = .advertised
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), armSenderWatchdog(state))
```

- [ ] **Step 3: Record served parts + transition to awaiting-proof in the sender request handler**

In `case (.sender, .data, .resourceRequest):`, after the loop that appends transmit effects (where `idx` is resolved), record each served index, reset retries, and after the loop decide the state transition. Replace the block from `state.status = .transferring` through `return .merge(effects)` with:

```swift
                    state.status = .transferring
                    state.retriesLeft = Const.maxRetries
                    let reqHashes = Data(p.dropFirst(33))
                    var effects: [Effect<Action>] = []
                    var i = reqHashes.startIndex
                    while i + 4 <= reqHashes.endIndex {
                        let mh = Data(reqHashes[i..<(i + 4)])
                        if let idx = state.partMapHashes.firstIndex(of: mh),
                           let raw = linkPacket(.data, .resource, state.parts[idx]) {
                            state.sentIndices.insert(idx)
                            effects.append(.send(.delegate(.transmit(state.interfaceID, raw))))
                        }
                        i += 4
                    }
                    if state.sentIndices.count == state.parts.count {
                        state.status = .awaitingProof
                    }
                    effects.append(armSenderWatchdog(state))
                    return .merge(effects)
```

- [ ] **Step 4: Cancel the watchdog on proof, and add the sender-deadline case**

In `case (.sender, .proof, .resourceProof):`, add a watchdog cancel to both returns:

```swift
                case (.sender, .proof, .resourceProof):
                    if Resource.validateProof(proofData: packet.payload, expectedProof: state.expectedProof) {
                        state.status = .complete
                        return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.concluded)))
                    }
                    state.status = .failed
                    return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))
```

Add the sender-deadline case (next to `.receiverDeadline`):

```swift
            case .senderDeadline:
                guard state.role == .sender else { return .none }
                switch state.status {
                case .advertised:
                    guard state.advRetriesLeft > 0, let adv = state.advertisement,
                          let raw = linkPacket(.data, .resourceAdvertisement,
                                               Link.encrypt(adv.pack(), sessionKey: state.sessionKey))
                    else {
                        state.status = .failed
                        return .merge(.cancel(id: CancelID.watchdog), senderCancel(state), .send(.delegate(.failed)))
                    }
                    state.advRetriesLeft -= 1
                    return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), armSenderWatchdog(state))
                case .transferring:
                    state.status = .failed
                    return .merge(.cancel(id: CancelID.watchdog), senderCancel(state), .send(.delegate(.failed)))
                case .awaitingProof:
                    guard state.proofRetriesLeft > 0 else {
                        state.status = .failed
                        return .merge(.cancel(id: CancelID.watchdog), senderCancel(state), .send(.delegate(.failed)))
                    }
                    state.proofRetriesLeft -= 1
                    return armSenderWatchdog(state)
                default:
                    return .none
                }
```

- [ ] **Step 5: Rework the 6b sender tests to carry a clock and end terminal**

The three 6b sender tests must now supply `$0.continuousClock` and reach a terminal state (so the armed sender watchdog is cancelled). Add a sender-store helper and rework them. Reuse `senderState`, `captureTransmits`, `resourceRequestPacket` from 6b.

```swift
@MainActor
private func senderStore(_ data: Data, _ clock: TestClock<Duration>) -> TestStore<ResourceTransfer.State, ResourceTransfer.Action> {
    let store = TestStore(initialState: senderState(data)) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func senderAdvertiseEmitsResourceAdvertisement() async {
    let data = Data("a small resource to send".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise) { $0.status = .advertised }
    let raw = (await captureTransmits(store, count: 1))[0]
    let packet = Packet(raw: raw)!
    #expect(packet.context == .resourceAdvertisement)
    let adv = ResourceAdvertisement.unpack(Link.decrypt(packet.payload, sessionKey: key)!)!
    #expect(adv.hash == store.state.resourceHash)
    // Cleanup: exhaust adv retries to fail (cancels the watchdog).
    for _ in 0...ResourceTransfer.Const.maxAdvRetries { await store.send(.senderDeadline) }
    #expect(store.state.status == .failed)
}

@Test @MainActor func senderReAdvertisesThenFailsAndCancels() async {
    let data = Data("re-advertise then give up".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)                       // initial ADV
    // Each deadline while ADVERTISED re-advertises, up to maxAdvRetries times.
    for _ in 0..<ResourceTransfer.Const.maxAdvRetries {
        await store.send(.senderDeadline)
        _ = await captureTransmits(store, count: 1)                  // re-ADV
    }
    #expect(store.state.advRetriesLeft == 0)
    await store.send(.senderDeadline)                                // no retries left -> fail + ICL
    #expect(store.state.status == .failed)
    let icl = (await captureTransmits(store, count: 1))[0]
    let p = Packet(raw: icl)!
    #expect(p.context == .resourceInitiatorCancel)
    #expect(Link.decrypt(p.payload, sessionKey: key) == store.state.resourceHash)
}

@Test @MainActor func senderServesAllPartsThenAwaitsProofAndConcludes() async {
    let data = Data("sender serves parts, then awaits and validates the proof".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    let s = store.state
    await store.send(.received(resourceRequestPacket(s)))            // requests all parts
    _ = await captureTransmits(store, count: s.parts.count)
    #expect(store.state.status == .awaitingProof)

    // Valid proof concludes.
    let proof = Resource.proofData(data: data, hash: s.resourceHash)
    let pkt = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: linkID, transportId: nil, payload: proof)
    await store.send(.received(try! pkt.packed()))
    await store.receive(.delegate(.concluded))
    #expect(store.state.status == .complete)
}

@Test @MainActor func senderAwaitingProofTimesOutThenFails() async {
    let data = Data("sender never receives a proof".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    await store.send(.received(resourceRequestPacket(store.state)))
    _ = await captureTransmits(store, count: store.state.parts.count)
    #expect(store.state.status == .awaitingProof)
    // Exhaust proof retries.
    for _ in 0...ResourceTransfer.Const.proofRetries { await store.send(.senderDeadline) }
    #expect(store.state.status == .failed)
    let icl = (await captureTransmits(store, count: 1))[0]
    #expect(Packet(raw: icl)!.context == .resourceInitiatorCancel)
}
```

Remove the old 6b `senderRespondsToRequestWithAllParts` and `senderConcludesOnValidProofFailsOnBad` tests, whose behavior is now covered by `senderServesAllPartsThenAwaitsProofAndConcludes` (serving + conclude) and the proof-timeout test. Keep a dedicated bad-proof assertion:

```swift
@Test @MainActor func senderRejectsInvalidProof() async {
    let data = Data("bad proof path".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    await store.send(.received(resourceRequestPacket(store.state)))
    _ = await captureTransmits(store, count: store.state.parts.count)
    let bad = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: linkID, transportId: nil, payload: Data(repeating: 0x00, count: 64))
    await store.send(.received(try! bad.packed()))
    await store.receive(.delegate(.failed))
    #expect(store.state.status == .failed)
}
```

- [ ] **Step 6: Run to verify**

Run: `swift test --filter ResourceTransfer`
Expected: PASS — all receiver (Task 3) and reworked sender tests.

- [ ] **Step 7: Mutation sweep**

Apply each, run `swift test --filter ResourceTransfer`, confirm the named test fails, revert; final green:
- In the request handler, change `if state.sentIndices.count == state.parts.count` to `> state.parts.count` → `senderServesAllPartsThenAwaitsProofAndConcludes` fails (never reaches `.awaitingProof`).
- In `.senderDeadline` `.advertised`, change `guard state.advRetriesLeft > 0` to `>= 0` → `senderReAdvertisesThenFailsAndCancels` fails (one extra re-advertise before failing).
- In `senderCancel`, change context `.resourceInitiatorCancel` to `.resourceReceiverCancel` → `senderReAdvertisesThenFailsAndCancels` fails (wrong cancel context).

- [ ] **Step 8: Commit**

```
git add Sources/ReTiCATransport/ResourceTransfer.swift Tests/ReTiCATransportTests/ResourceTransferTests.swift
git commit -F /tmp/ReTiCA/commit-t4.txt
```
(First line: `feat: ResourceTransfer sender timers (re-advertise, awaiting-proof, patience)`, blank line, trailers.)

---

### Task 5: Cancellation — inbound ICL/RCL + external `.cancel`

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift`
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`

**Interfaces:**
- Consumes: Task 3/4 `CancelID`, `linkPacket`, `senderCancel`.
- Produces: `Action.cancel`; inbound handling of `(.receiver, .data, .resourceInitiatorCancel)` and `(.sender, .data, .resourceReceiverCancel)`; the external `.cancel` action emitting the role's cancel packet.

- [ ] **Step 1: Add inbound cancel handling**

In the `switch (state.role, packet.packetType, packet.context)` block, add two cases before `default:`:

```swift
                case (.receiver, .data, .resourceInitiatorCancel):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          Data(plain) == state.resourceHash else { return .none }
                    state.status = .failed
                    return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))

                case (.sender, .data, .resourceReceiverCancel):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          Data(plain) == state.resourceHash else { return .none }
                    state.status = .failed
                    return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed)))
```

- [ ] **Step 2: Add the external `.cancel` action**

Add `.cancel` to `Action` (next to the deadline cases). Add the case to the outer switch:

```swift
            case .cancel:
                guard state.status != .complete, state.status != .failed else { return .none }
                let context: PacketContext = state.role == .sender ? .resourceInitiatorCancel : .resourceReceiverCancel
                state.status = .failed
                let cancel = linkPacket(.data, context,
                                        Link.encrypt(state.resourceHash, sessionKey: state.sessionKey))
                return .merge(.cancel(id: CancelID.watchdog),
                              cancel.map { Effect.send(.delegate(.transmit(state.interfaceID, $0))) } ?? .none,
                              .send(.delegate(.failed)))
```

- [ ] **Step 3: Write the tests**

Append to `Tests/ReTiCATransportTests/ResourceTransferTests.swift`:

```swift
// Encrypted cancel packet carrying the resource hash.
private func cancelPacket(_ context: PacketContext, _ hash: Data) -> Data {
    let p = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                   destinationType: .link, context: context, contextFlag: false, hops: 0,
                   destinationHash: linkID, transportId: nil,
                   payload: Link.encrypt(hash, sessionKey: key))
    return try! p.packed()
}

@Test @MainActor func receiverFailsOnInboundInitiatorCancel() async {
    let data = Data(repeating: 0x22, count: 100)
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)
    await store.send(.received(cancelPacket(.resourceInitiatorCancel, sender.resourceHash)))
    await store.receive(.delegate(.failed))
    #expect(store.state.status == .failed)
}

@Test @MainActor func senderFailsOnInboundReceiverCancel() async {
    let data = Data("sender aborts when the receiver rejects".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    await store.send(.received(cancelPacket(.resourceReceiverCancel, store.state.resourceHash)))
    await store.receive(.delegate(.failed))
    #expect(store.state.status == .failed)
}

@Test @MainActor func externalCancelEmitsReceiverCancelPacket() async {
    let data = Data(repeating: 0x77, count: 100)
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)
    await store.send(.cancel)
    let raw = (await captureTransmits(store, count: 1))[0]
    let p = Packet(raw: raw)!
    #expect(p.context == .resourceReceiverCancel)
    #expect(Link.decrypt(p.payload, sessionKey: key) == sender.resourceHash)
    #expect(store.state.status == .failed)
}

@Test @MainActor func inboundCancelWithWrongHashIsIgnored() async {
    let data = Data(repeating: 0x22, count: 100)
    let sender = senderState(data)
    let clock = TestClock<Duration>()
    let store = receiverStore(clock)
    await store.send(.accept(advertisementPacket(sender)))
    _ = await captureTransmits(store, count: 1)
    await store.send(.received(cancelPacket(.resourceInitiatorCancel, Data(repeating: 0xEE, count: 32))))
    #expect(store.state.status != .failed)
    // Cleanup: cancel to a terminal state.
    await store.send(.cancel); _ = await captureTransmits(store, count: 1)
}
```

- [ ] **Step 4: Run to verify**

Run: `swift test --filter ResourceTransfer`
Expected: PASS.

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter ResourceTransfer`, confirm the named test fails, revert; final green:
- In `(.receiver, .data, .resourceInitiatorCancel)`, change `Data(plain) == state.resourceHash` to `!= ` → `receiverFailsOnInboundInitiatorCancel` fails (ignores a valid cancel) and `inboundCancelWithWrongHashIsIgnored` fails (fails on a wrong hash).
- In `.cancel`, change the context ternary to always `.resourceInitiatorCancel` → `externalCancelEmitsReceiverCancelPacket` fails (wrong context for a receiver).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/ResourceTransfer.swift Tests/ReTiCATransportTests/ResourceTransferTests.swift
git commit -F /tmp/ReTiCA/commit-t5.txt
```
(First line: `feat: ResourceTransfer cancellation (inbound ICL/RCL + external .cancel)`, blank line, trailers.)

---

### Task 6: End-to-end windowed+lossy transfer, gate, README

**Files:**
- Modify: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–5.

- [ ] **Step 1: Rework the end-to-end test to windowed + a dropped part**

Replace `endToEndTwoReducerResourceTransfer` with a two-reducer transfer whose data spans several windows and where one part is dropped and then re-requested on a receiver timeout. Both stores carry TestClocks.

```swift
@Test @MainActor func endToEndWindowedTransferWithADroppedPart() async {
    let data = Data("End-to-end windowed resource transfer with retransmission of a dropped part, spanning multiple request rounds so the window actually advances.".utf8)
    let senderClock = TestClock<Duration>()
    let receiverClock = TestClock<Duration>()
    let sender = TestStore(initialState: senderState(data)) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = senderClock }
    sender.exhaustivity = .off
    let receiver = TestStore(initialState: receiverState()) { ResourceTransfer() }
        withDependencies: { $0.continuousClock = receiverClock }
    receiver.exhaustivity = .off

    // Advertise -> accept -> first window request.
    await sender.send(.advertise)
    let adv = (await captureTransmits(sender, count: 1))[0]
    await receiver.send(.accept(adv))
    var req = (await captureTransmits(receiver, count: 1))[0]

    let got = LockIsolated<Data?>(nil)
    var deliveredAll = false
    var droppedOnce = false
    // Pump request/serve rounds until the receiver completes.
    while !deliveredAll {
        // Sender serves the requested parts.
        await sender.send(.received(req))
        // Determine how many parts the sender emits for this request (count requested hashes).
        let reqPlain = Data(Link.decrypt(Packet(raw: req)!.payload, sessionKey: key)!)
        let requested = (reqPlain.count - 33) / 4
        let served = await captureTransmits(sender, count: requested)

        // Deliver served parts to the receiver, dropping exactly one part the first time.
        for (k, part) in served.enumerated() {
            if !droppedOnce && k == served.count - 1 && requested > 1 { droppedOnce = true; continue }
            await receiver.send(.received(part))
        }

        if receiver.state.status == .complete {
            deliveredAll = true
            break
        }
        // If the round did not complete because of the dropped part, fire the receiver watchdog
        // to re-request the outstanding part; otherwise the completed window already emitted a request.
        if !receiver.state.outstanding.isEmpty {
            await receiver.send(.receiverDeadline)
        }
        req = (await captureTransmits(receiver, count: 1))[0]
    }

    // The completing round emits the proof + the reconstructed data.
    await receiver.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await receiver.receive { action in
        if case let .delegate(.received(d)) = action { got.setValue(d); return true }
        return false
    }
    #expect(got.value == data)
    #expect(receiver.state.status == .complete)

    // Feed the proof back to the sender to conclude.
    // (The proof transmit was captured above; re-capture is not needed — assert sender concludes on a fresh proof.)
    let proof = Resource.proofData(data: data, hash: sender.state.resourceHash)
    let pkt = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false, hops: 0,
                     destinationHash: linkID, transportId: nil, payload: proof)
    await sender.send(.received(try! pkt.packed()))
    await sender.receive(.delegate(.concluded))
    #expect(sender.state.status == .complete)
}
```

> Implementer note: if `sender.state.status` is `.awaitingProof` when the proof arrives, `.concluded` fires and the sender watchdog is cancelled — the test ends terminal on both sides, so no dangling effects remain. If the pump loop structure needs a small adjustment to reach completion for the chosen payload size, adjust the payload length (keep it > 6 parts at `sdu: 24`) rather than weakening the assertions.

- [ ] **Step 2: Run the filtered suite**

Run: `swift test --filter ResourceTransfer`
Expected: PASS.

- [ ] **Step 3: Run the full suite (gate)**

Run: `swift test`
Expected: PASS — all prior suites plus the new core `ResourceWindow`/`nextWindowRequest` tests and the reworked reducer tests.

- [ ] **Step 4: Mutation sweep (cross-cutting)**

Apply each, run the named filter, confirm failure, revert; final full `swift test` green:
- In `ResourceWindow.grown()` change `w.window += 1` to a no-op (`w.window += 0`) → `endToEndWindowedTransferWithADroppedPart` still completes but `ResourceWindowTests` fails; run `swift test --filter ResourceWindow`.
- In the receiver `requestNextWindow`, drop the re-arm (`return .send(.delegate(.transmit(s.interfaceID, raw)))` only, no `armReceiverWatchdog`) → `receiverRetransmitsThenFailsAfterMaxRetries` fails (no watchdog to fire after the first request); run `swift test --filter ResourceTransfer`.
Run `swift test` after reverting both → green.

- [ ] **Step 5: Update the README**

In `README.md`, extend the `### Resource transfer (`ResourceTransfer`)` subsection with a windowing paragraph:

```markdown
Transfers are **windowed and self-healing**: the receiver requests parts a window at a time (start 4,
growing +1 per completed round up to the slow cap of 10, shrinking on timeout), tracks a
consecutive-completed height, and retransmits outstanding parts on an rtt-seeded watchdog, failing
after 16 retries. The sender re-advertises when no request arrives (up to 4 times), waits for the
proof in an `awaitingProof` state, and gives up after its patience elapses. Either side can abort:
`RESOURCE_ICL` (sender) and `RESOURCE_RCL` (receiver) — each carrying the resource hash encrypted with
the link key — drive the peer to a failed state. Rate-adaptive window escalation (fast/very-slow),
hashmap-update (multi-segment), and compression remain future slices.
```

- [ ] **Step 6: Commit**

```
git add Tests/ReTiCATransportTests/ResourceTransferTests.swift README.md
git commit -F /tmp/ReTiCA/commit-t6.txt
```
(First line: `test: end-to-end windowed resource transfer with retransmission; docs`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- Windowed requesting → Tasks 2–3 (`nextWindowRequest` + receiver `accept`/round-complete). ✓
- Event-driven window adaptation → Task 1 (`ResourceWindow`) wired in Task 3. ✓
- Retransmission watchdog → Task 3 (`armReceiverWatchdog` + `.receiverDeadline`). ✓
- Sender-side timers (re-advertise, transfer patience, awaiting-proof) → Task 4. ✓
- Cancellation (ICL/RCL inbound + external, encrypted) → Task 5. ✓
- E2E windowed + lossy + gate + README → Task 6. ✓
- Deferred (rate escalation, HMU/multi-segment, compression, integration) → untouched. ✓

**Placeholder scan:** No TBD/TODO; every code step shows complete code. The one implementer note (Task 6) is guidance for adjusting a payload size, not a missing implementation.

**Type consistency:** `ResourceWindow` (`grown`/`shrunk`), `Resource.nextWindowRequest(receivedIndices:hashmap:height:window:partCount:)`, `Const.*`, `CancelID.watchdog`, `Status.awaitingProof`, `Action.receiverDeadline`/`.senderDeadline`/`.cancel`, and the new `State` fields are named identically across Tasks 1–6. The `rtt: Duration = .seconds(1)` default keeps every 6b call site source-compatible. Cancel packets use `PacketContext.resourceInitiatorCancel` (0x06) / `.resourceReceiverCancel` (0x07), which already exist in the core enum.
