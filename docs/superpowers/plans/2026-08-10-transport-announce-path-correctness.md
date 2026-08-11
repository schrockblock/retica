# Transport Announce and Path Correctness Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close three independent correctness defects in `Transport`: a 500×-undersized packet-dedup window, path responses being re-broadcast (announce amplification), and local path responses erasing the requester's learned app data.

**Architecture:** All three tasks are confined to `Sources/ReTiCATransport/Transport.swift` plus a one-line default change in `RingSet.swift`. They are mutually independent and can land in any order; the sequence below is cheapest-first. Task 3 introduces one new piece of state — the app data most recently announced for each local destination — mirroring reference `Destination.default_app_data`.

**Tech Stack:** Swift 6, The Composable Architecture (`@Reducer`, `TestStore`), `swift-testing`, `TestClock`.

## Global Constraints

- Platform floor: iOS 16 / macOS 13 (package-wide; do not raise).
- `ReTiCATransport` is interface-agnostic — no Network.framework, no CoreBluetooth.
- Wire compatibility with Python-RNS 1.4.1/1.4.2 is mandatory.
- Tests use `swift-testing` (`import Testing`, `@Test @MainActor func …`, `#expect`), not XCTest.
- House style for Transport tests: `store.exhaustivity = .off`. To prove a packet was NOT sent, send in `.off` and flip `.on` **last** — teardown reads exhaustivity at call time and catches a stray transmit. This is necessary even for fan-out assertions, because capturing only the first transmit plus `Set` iteration non-determinism can mask a stray.
- Transport timer tests need `ImmediateClock`/`TestClock`; note that `\.date` and `\.continuousClock` `testValues` are UNIMPLEMENTED here — the codebase uses a custom `\.transportDate`. Follow the existing pattern in `Tests/ReTiCATransportTests/TransportTests.swift`.
- PATH_REQUEST is a `.data` packet, so byte-identical duplicates die at `seenPacketHashes` **before** reaching the tag gate. A tag-dedup test therefore needs a same-tag, *different*-transport_id packet.
- Verify tests per the three-step process: (a) run and confirm pass, (b) batch-mutate the production code so they should fail and confirm every one fails, (c) revert and confirm pass again.
- Commit after each task. Trailers must start at column 0:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

### Task 1: Size the packet-dedup ring to the reference window

**Why:** `seenPacketHashes = RingSet()` (`Transport.swift:32`) silently takes `RingSet`'s default `capacity: 1000` (`RingSet.swift:10`). Reference keeps `hashlist_maxsize = 1000000` with a two-generation flip holding 500k–1M hashes live (`Transport.py:177, 656-657, 1417`). This is an oversight rather than a mobile tuning decision: the two sibling rings in the same struct are explicitly sized against named reference constants (`Transport.swift:973` `pathRequestTagRingSize = 32000 // RNS max_pr_tags`, `:975` `announceBlobRingSize = 64`). Loop protection and duplicate suppression currently evaporate after 1000 distinct packets.

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift:32`, and add a constant near `:973`
- Modify: `Sources/ReTiCATransport/RingSet.swift:10` (remove the defaulted capacity)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: `RingSet.init(capacity:)`.
- Produces: `static let seenPacketRingSize = 262_144` on `Transport`.

**Sizing note:** reference's 500k–1M costs 16–32 MB. On iOS that is too much for a background-eligible app, so this plan uses **262 144** (~8 MB at 32 B/hash plus `Set`/array overhead — budget ~20 MB worst case). That is 262× the current window and comfortably exceeds any realistic packet-to-echo distance, while staying inside a mobile memory budget. Record the divergence in the comment; do not silently adopt the reference number.

> **CORRECTION (whole-branch review, 2026-08-11):** this note took reference's *number* without reference's *structure*, and was wrong on both cost axes. `RingSet` as written was O(ring) per insert twice over — `order.removeFirst()` is an `Array.remove(at: 0)` memmove, and TCA's per-action `State` copy left both collections non-uniquely referenced so every new hash paid a full copy-on-write. Measured: **67–82 ms and ~44 MB per received packet** at 262 144, versus 142 µs at 1000. Reference affords 1 M only because it is O(1) on both paths (a plain `set` plus a generation flip that drops the old generation by reference, `Transport.py:656-658`). Resolution (human ruling): box `RingSet`'s storage in a `final class` with a circular buffer and 128-bit inline digests — O(1) per insert, ~12.1 MB at 262 144 — and keep the large window. See `Sources/ReTiCATransport/RingSet.swift`.

- [ ] **Step 1: Write the failing test**

Append to `Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
// The dedup ring must be large enough that ordinary relay traffic cannot flush a packet's
// own echo out of memory. Reference holds 500k-1M (RNS Transport.py:177); we hold 262144.
@Test func seenPacketRingIsSizedForRelayTraffic() {
    #expect(Transport.seenPacketRingSize == 262_144)
    var ring = RingSet(capacity: Transport.seenPacketRingSize)
    let first = Data(repeating: 0x01, count: 32)
    #expect(ring.insert(first))
    // Push far more than the OLD 1000-entry default through the ring.
    for i in 0..<5000 {
        var h = Data(repeating: 0x00, count: 30)
        h.append(UInt8(i >> 8)); h.append(UInt8(i & 0xFF))
        _ = ring.insert(h)
    }
    // The original packet must still be remembered.
    #expect(ring.contains(first))
    #expect(!ring.insert(first))
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter seenPacketRingIsSizedForRelayTraffic`
Expected: FAIL to compile — `Transport.seenPacketRingSize` does not exist.

- [ ] **Step 3: Add the constant and use it**

In `Sources/ReTiCATransport/Transport.swift`, next to the other ring constants (around line 973-975) add:

```swift
    /// Packet-hash dedup window. Reference `hashlist_maxsize` is 1_000_000 with a two-generation
    /// flip keeping 500k-1M live (RNS Transport.py:177, 656-657), costing 16-32 MB. That is too
    /// much for a background-eligible iOS app, so we hold 262144 (~8 MB of hashes) — 262x the
    /// previous accidental 1000-entry default, and far beyond any realistic packet-to-echo
    /// distance. DELIBERATE DIVERGENCE, not a port of the reference number.
    static let seenPacketRingSize = 262_144
```

Change line 32 from:

```swift
        var seenPacketHashes = RingSet()
```

to:

```swift
        var seenPacketHashes = RingSet(capacity: Transport.seenPacketRingSize)
```

- [ ] **Step 4: Remove the defaulted capacity so this cannot recur**

In `Sources/ReTiCATransport/RingSet.swift`, change line 10 from:

```swift
    public init(capacity: Int = 1000) { self.capacity = capacity }
```

to:

```swift
    /// No default: every ring must state its size against the reference constant it mirrors.
    /// A defaulted capacity is how `seenPacketHashes` silently ran at 1000 instead of 262144.
    public init(capacity: Int) { self.capacity = capacity }
```

Fix any resulting compile errors by supplying an explicit capacity at each call site. Check `LXMFRouter.swift:21` (`seen = RingSet(capacity: 10_000)`) — it is already explicit; grep for `RingSet()` across `Sources/` and `Tests/` to find the rest.

- [ ] **Step 5: Run the tests**

Run: `swift test --filter Transport`
Expected: all pass.

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Sources/ReTiCATransport/RingSet.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -m "fix: size the packet-dedup ring for relay traffic instead of the 1000 default"
```

---

### Task 2: Do not re-broadcast path responses

**Why:** Reference gates announce-table insertion on `packet.context != RNS.Packet.PATH_RESPONSE` (`Transport.py:1945`): a transport node **adopts** a path response into its path table but never re-broadcasts it. ReTiCA's relay block copies `context: packet.context` through with no such test (`Transport.swift:451`). Because a *locally minted* path response carries a fresh `random_hash`, every ReTiCA relay that hears one sees an unseen blob, passes `shouldReplace` on the newer timestamp, and schedules a network-wide re-broadcast — so one path request floods proportionally to the number of ReTiCA relays. (A *relayed* path response replays the cached announce payload verbatim, so it carries the original `random_hash` and does die at the receiver's blob ring; the gate is what makes both cases safe.)

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift:443-465`
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: `PacketContext.pathResponse`, `Packet.context`.
- Produces: no new symbols.

- [ ] **Step 1: Write the failing test**

```swift
// RNS Transport.py:1945 — a relay ADOPTS a path response into its path table but never
// re-broadcasts it. Re-broadcasting turns one path request into a flood.
@Test @MainActor func pathResponseIsAdoptedButNotRebroadcast() async {
    let relayID = Identity()
    let store = TestStore(initialState: Transport.State()) { Transport() }
        withDependencies: { configureTransportDependencies(&$0) }
    store.exhaustivity = .off

    await store.send(.interfaceConnected(InterfaceID("a"), .init(name: "a")))
    await store.send(.interfaceConnected(InterfaceID("b"), .init(name: "b")))
    await store.send(.setTransportIdentity(relayID))

    // Build a genuine announce and re-frame it as a HEADER_2 path response arriving on "a".
    let peer = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "test",
                           aspects: ["pathresp"], identity: peer)!
    let payload = Announce.buildPayload(identity: peer, destinationHash: dest.hash,
                                        nameHash: dest.nameHash,
                                        randomHash: Announce.randomHash(now: 1, randomPrefix: Data(repeating: 0x01, count: 5)),
                                        ratchet: nil, appData: Data([0xAB]))
    let response = Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                          destinationType: .single, context: .pathResponse, contextFlag: false,
                          hops: 1, destinationHash: dest.hash,
                          transportId: Data(repeating: 0x09, count: 16), payload: payload)

    store.exhaustivity = .on
    await store.send(.received(InterfaceID("a"), try! response.packed())) {
        // Adoption still happens.
        $0.learned[dest.hash] = $0.learned[dest.hash]
    }
    store.exhaustivity = .off

    // The path was learned...
    #expect(store.state.learned[dest.hash] != nil)
    // ...but nothing was queued for re-broadcast.
    #expect(store.state.announceTable[dest.hash] == nil)
}
```

Adapt `configureTransportDependencies` and the `InterfaceProfile` initialiser to whatever `TransportTests.swift` already uses — read the top of that file first and match its helper names exactly rather than inventing new ones. The two assertions at the end are the load-bearing part; the `store.send` shape is negotiable.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter pathResponseIsAdoptedButNotRebroadcast`
Expected: FAIL — `announceTable[dest.hash]` is non-nil, because the relay scheduled a re-broadcast.

- [ ] **Step 3: Add the gate**

In `Sources/ReTiCATransport/Transport.swift`, in the relay re-broadcast block starting at line 443, change the condition from:

```swift
                    let arrivalMode = state.interfaces[interfaceID]?.mode
                    if let relayID = state.transportIdentity,
                       Int(packet.hops) + 1 < Int(Packet.maxHops),
```

to:

```swift
                    let arrivalMode = state.interfaces[interfaceID]?.mode
                    // RNS Transport.py:1945 gates announce-table insertion on
                    // `packet.context != PATH_RESPONSE`. A path response is a targeted answer to
                    // one requester, not a network-wide advertisement — and because each carries a
                    // fresh random_hash it defeats blob dedup, so re-broadcasting it makes one
                    // path request flood proportionally to the number of relays. Adoption above
                    // still happens; only the re-broadcast is suppressed.
                    if packet.context != .pathResponse,
                       let relayID = state.transportIdentity,
                       Int(packet.hops) + 1 < Int(Packet.maxHops),
```

- [ ] **Step 4: Run the tests**

Run: `swift test --filter Transport`
Expected: all pass. Check `Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift` in particular — if a cross-validation test feeds a path-response fixture and asserts a re-broadcast, read it carefully: that assertion was encoding the bug and should be updated to assert adoption-without-rebroadcast.

- [ ] **Step 5: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -m "fix: adopt path responses without re-broadcasting them"
```

---

### Task 3: Local path responses carry the destination's announced app data

**Why:** `Transport.swift:490-492` builds the local path response with `ratchet: nil, appData: nil` and a fresh `randomHash` stamped at `now`. On the requester the resulting `announceEmitted` is therefore *newer* than the entry learned from a normal announce, so `shouldReplace` (`:997-1002`) returns true and the richer entry is overwritten with nils (`:428-431`). Requesting a path to a peer erases that peer's app data — which for LXMF is where display name and propagation-node metadata live (read at `LXMFNode.swift:337`).

Reference sends a full announce carrying `default_app_data` (`Destination.py:283-304`, set for LXMF at `LXMRouter.py:365-368`). This task adds the equivalent: Transport remembers the app data most recently announced for each local destination and replays it.

**Scope note:** this fixes the *mechanism*. A destination that has only ever announced `appData: nil` will still produce a nil-app-data path response — correctly, since it has no app data. `LXMFNode.registerDelivery` announcing `appData: nil` (`LXMFNode.swift:92`) is a separate gap (§6 of the gap analysis) and is **not** in scope here.

**Ratchet note:** `ratchet: nil` stays. ReTiCA has no own-ratchet lifecycle at all (§7 of the gap analysis); synthesising one here would be wrong. Leave the parameter and extend the comment.

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` — add `localAppData` to `State`, write it in `.announce` (`:791-802`), read it in the path-response builder (`:486-496`), clear it in `.registerLocalDestination` if the destination is re-registered
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: `State.localDestinations`, `Announce.buildPayload(identity:destinationHash:nameHash:randomHash:ratchet:appData:)`.
- Produces: `public var localAppData: [Data: Data] = [:]` on `Transport.State`.

- [ ] **Step 1: Write the failing test**

```swift
// A path response must carry the destination's announced app data. Without it the response —
// which has a NEWER timestamp than the original announce — overwrites the requester's entry
// with nil, erasing display name / PN metadata (Destination.py:283-304).
@Test @MainActor func localPathResponseCarriesAnnouncedAppData() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
        withDependencies: { configureTransportDependencies(&$0) }
    store.exhaustivity = .off

    await store.send(.interfaceConnected(InterfaceID("a"), .init(name: "a")))

    let me = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "test",
                           aspects: ["appdata"], identity: me)!
    let appData = Data([0xDE, 0xAD, 0xBE, 0xEF])
    await store.send(.registerLocalDestination(dest))
    await store.send(.announce(destinationHash: dest.hash, appData: appData))
    _ = await captureTransportTransmit(store)              // the announce itself

    // A path request for our own destination.
    var payload = dest.hash
    payload.append(Data(repeating: 0x77, count: 16))       // request tag
    let pr = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                    destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                    destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                    payload: payload)
    await store.send(.received(InterfaceID("a"), try! pr.packed()))
    let raw = await captureTransportTransmit(store)        // the path response

    let responsePacket = Packet(raw: raw)!
    #expect(responsePacket.context == .pathResponse)
    let parsed = Announce.parse(payload: responsePacket.payload,
                                destinationHash: responsePacket.destinationHash)
    #expect(parsed?.appData == appData)
}
```

Match `captureTransportTransmit` to whatever the file already uses to pull raw bytes out of a `delegate(.transmit)`; if no such helper exists, copy the `captureTransmit` pattern from `LinkSessionTests.swift:11-18`.

- [ ] **Step 2: Run the test to verify it fails**

Run: `swift test --filter localPathResponseCarriesAnnouncedAppData`
Expected: FAIL — `parsed?.appData` is `nil`, not `appData`.

- [ ] **Step 3: Add the state**

In `Sources/ReTiCATransport/Transport.swift`, next to `localDestinations` in `State`, add:

```swift
        /// App data most recently announced for each local destination, replayed in path
        /// responses. Reference equivalent: `Destination.default_app_data` (RNS/Destination.py:193),
        /// which `announce()` falls back to and which path responses therefore always carry
        /// (RNS/Destination.py:283-304). Without this a path response — which is stamped NOW and so
        /// wins `shouldReplace` — overwrites the requester's richer entry with nil.
        public var localAppData: [Data: Data] = [:]
```

- [ ] **Step 4: Write it on announce**

In `.announce` (line 791-802), after the `guard let dest = …` and before building the payload, add:

```swift
                if let appData { state.localAppData[destinationHash] = appData }
```

Place it after the guard so an announce for an unregistered destination does not record anything. Note this deliberately does **not** clear on `appData == nil`: reference `default_app_data` is sticky until explicitly cleared with `clear_default_app_data()`, and an announce that omits app data falls back to it rather than erasing it.

- [ ] **Step 5: Clear it when a destination is re-registered**

In `.registerLocalDestination` (line 246-248), change:

```swift
            case let .registerLocalDestination(destination):
                state.localDestinations[destination.hash] = destination
                return .none
```

to:

```swift
            case let .registerLocalDestination(destination):
                // Re-registering a destination resets its announced app data: the new registration
                // has made no claim about it yet, and replaying a previous composition's app data
                // would publish stale metadata.
                if state.localDestinations[destination.hash] == nil {
                    state.localAppData[destination.hash] = nil
                }
                state.localDestinations[destination.hash] = destination
                return .none
```

- [ ] **Step 6: Read it in the path-response builder**

In the local path-response branch (lines 486-496), change:

```swift
                            let respPayload = Announce.buildPayload(identity: identity, destinationHash: dest.hash,
                                                                    nameHash: dest.nameHash, randomHash: randomHash,
                                                                    ratchet: nil, appData: nil)
```

to:

```swift
                            // Replay the app data this destination last announced. A path response
                            // is stamped NOW, so it always wins `shouldReplace` on the requester —
                            // sending nil here would erase whatever richer entry the requester had
                            // learned from a normal announce (display name, PN metadata, ...).
                            //
                            // `ratchet` stays nil: ReTiCA has no own-ratchet lifecycle at all (it
                            // only honours a PEER's announced ratchet when encrypting), so there is
                            // nothing truthful to put here. Revisit when ratchets land.
                            let respPayload = Announce.buildPayload(identity: identity, destinationHash: dest.hash,
                                                                    nameHash: dest.nameHash, randomHash: randomHash,
                                                                    ratchet: nil,
                                                                    appData: state.localAppData[dest.hash])
```

- [ ] **Step 7: Run the tests**

Run: `swift test --filter Transport`
Expected: all pass.

- [ ] **Step 8: Verify the test set per the three-step process**

(a) `swift test --filter Transport` — all pass.
(b) Batch-mutate: revert Task 1's constant to `RingSet(capacity: 1000)`; drop Task 2's `packet.context != .pathResponse` clause; change Task 3's `appData:` argument back to `nil`. Run once — all three new tests must fail.
(c) Revert all mutations, run again — all pass.

- [ ] **Step 9: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -m "fix: path responses replay the destination's announced app data"
```

---

## Self-review notes

- **Coverage:** §1.4 → Task 1; §1.3 → Task 2; §1.2 → Task 3.
- **Independence:** the three tasks touch disjoint code and can be reordered or split across sessions. Only the Step 8 mutation batch assumes all three have landed.
- **Type consistency:** `Transport.seenPacketRingSize` (Task 1) and `State.localAppData` (Task 3) are the only new symbols; neither is referenced by the other task.
- **Deliberate divergence:** Task 1 uses 262 144 rather than the reference's 500k–1M, for iOS memory reasons, and says so in the code comment. This is the one place in the plan where ReTiCA intentionally does not match reference.
- **Out of scope, deliberately:** the receiver-side half of §1.2 (preserving a richer `LearnedDestination` when a poorer announce arrives) is *not* changed — reference has no such preservation either, and adding it would be a divergence. The sender-side fix is the faithful one.
