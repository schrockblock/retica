# Transport Relaying 4b-1: Announce Propagation + Path Table Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `Transport` an opt-in relay capability — on hearing an announce for a non-local destination, re-broadcast it (RNS-faithful HEADER_2 rewrite so downstream routes through us) and record a usable next-hop in the path table. No data forwarding (that is 4b-2).

**Architecture:** `Transport.State` gains `transportIdentity: Identity?` (nil = leaf, unchanged; non-nil = relay). In the announce-learn branch: store `nextHop = transportId ?? destinationHash` (the deferred fallback), and — in relay mode — re-broadcast the SAME announce payload as HEADER_2 (`transport_id` = our hash, `hops` = received+1) to every interface except the received-from one. `Endpoint` gets a thin `enableRelay(Identity)` pass-through. Core `ReTiCA` (`Packet`) is unchanged (HEADER_2 already modeled).

**Tech Stack:** Swift 6, The Composable Architecture (~1.26) — `Reduce`, `Scope`, `TestStore`; the in-core `Packet` (HEADER_2/`transportId`), `Announce`, `Identity`; cross-validation against a genuine Python-RNS 1.3.8 announce.

## Global Constraints

- **RNS-faithful re-broadcast** (from `Transport.py:616-635`): same announce payload verbatim (no re-sign), `headerType = .header2`, `transportType = .transport`, `transportId = transportIdentity.hash`, `hops = received + 1`. Hop limit: only if `Int(received) + 1 < Int(Packet.maxHops)` (128). Sent to `state.interfaces` **minus** the received-from `interfaceID`.
- **Path-table next-hop fallback:** `nextHop = packet.transportId ?? packet.destinationHash` (HEADER_2 → its transport_id; HEADER_1 → the destination hash). `learned.hops` stays `packet.hops` (received wire value) — the re-broadcast wire hops is still received+1 (matches RNS); RNS's internal stored-hops off-by-one is reconciled in 4b-2.
- **Opt-in only:** with `transportIdentity == nil`, behavior is byte-for-byte the current leaf Transport — the re-broadcast block is skipped. Do NOT change any leaf path (link routing, dedup, data delivery, own-announce origination).
- **Two-layer purity:** all changes in `ReTiCATransport` + a thin `ReTiCANode`/`Endpoint` action. `Sources/ReTiCA/*` (core `Packet`/`Announce`/`Identity`) is UNCHANGED.
- Build gotcha: signal-11/SIGILL during `swift test` → `swift package clean` then retry; never delete State fields to "fix" a crash.
- **Mutation-test discipline** for every new/changed test. **Commit directly to `main`.** Trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCATransport/Transport.swift` (**modify**, Task 1) — `transportIdentity` state, `setTransportIdentity` action, nextHop fallback, re-broadcast.
- `Tests/ReTiCATransportTests/TransportTests.swift` (**modify**, Task 1) — relay unit tests.
- `Sources/ReTiCANode/Endpoint.swift` (**modify**, Task 2) — `enableRelay(Identity)` pass-through.
- `Tests/ReTiCANodeTests/EndpointTests.swift` (**modify**, Task 2) — enable-relay wiring test.
- `Tests/ReTiCATransportTests/Vectors/*` + new cross-val test (**modify/create**, Task 2) — genuine-RNS re-broadcast cross-validation.
- `README.md` (**modify**, Task 2).

---

### Task 1: `Transport` relay mode + announce re-broadcast

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift`
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: `Packet` (HEADER_2 init + `packed()`/`Packet(raw:)`), `Identity.hash`, `state.interfaces`, the existing announce-learn branch.
- Produces: `Transport.State.transportIdentity: Identity?`; `Transport.Action.setTransportIdentity(Identity?)`; relay re-broadcast on inbound non-local announce.

- [ ] **Step 1: Add state + action**

In `Sources/ReTiCATransport/Transport.swift`:
- `State`: add `public var transportIdentity: Identity? = nil` (after `interfaces`).
- `Action`: add `case setTransportIdentity(Identity?)`.
- Handle it in the reducer (e.g. next to `registerLocalDestination`):
```swift
            case let .setTransportIdentity(identity):
                state.transportIdentity = identity
                return .none
```

- [ ] **Step 2: nextHop fallback + re-broadcast in the announce-learn branch**

Replace the announce-learn branch (currently: builds `candidate` with `nextHop: packet.transportId`, `shouldReplace` guard, stores, returns `pathLearned`) with the fallback + relay re-broadcast:

```swift
                case .announce:
                    guard state.localDestinations[packet.destinationHash] == nil else { return .none }
                    guard let parsed = Announce.parse(payload: packet.payload,
                                                      destinationHash: packet.destinationHash,
                                                      contextFlagSet: packet.contextFlag)
                    else { return .none }
                    let emitted = Transport.announceEmitted(parsed.randomHash)
                    // Path-table next hop: relayed (HEADER_2) → its transport_id; directly heard → the dest.
                    let nextHop = packet.transportId ?? packet.destinationHash
                    let candidate = LearnedDestination(
                        identity: parsed.identity, appData: parsed.appData, ratchet: parsed.ratchet,
                        interfaceID: interfaceID, hops: packet.hops, nextHop: nextHop,
                        announceEmitted: emitted)
                    guard Transport.shouldReplace(state.learned[packet.destinationHash], with: candidate)
                    else { return .none }
                    state.learned[packet.destinationHash] = candidate
                    let learnedEffect = Effect<Action>.send(.delegate(.pathLearned(
                        destinationHash: packet.destinationHash, hops: packet.hops)))
                    // Relay mode: re-broadcast the announce (same payload, HEADER_2, our transport_id,
                    // hops+1) to every interface except the one it arrived on — but respect the hop limit.
                    guard let relayID = state.transportIdentity,
                          Int(packet.hops) + 1 < Int(Packet.maxHops)
                    else { return learnedEffect }
                    let rebroadcast = Packet(
                        headerType: .header2, packetType: .announce, transportType: .transport,
                        destinationType: packet.destinationType, context: packet.context,
                        contextFlag: packet.contextFlag, hops: packet.hops + 1,
                        destinationHash: packet.destinationHash, transportId: relayID.hash,
                        payload: packet.payload)
                    guard let rebroadcastRaw = try? rebroadcast.packed() else { return learnedEffect }
                    let out = state.interfaces
                        .filter { $0 != interfaceID }
                        .map { Effect<Action>.send(.delegate(.transmit($0, rebroadcastRaw))) }
                    return .merge([learnedEffect] + out)
```

(Only the fallback + the relay block are new; the parse/learn/`shouldReplace`/`pathLearned` logic is unchanged. Leaf mode returns exactly `learnedEffect` as before.)

- [ ] **Step 3: Write the failing tests**

Append to `Tests/ReTiCATransportTests/TransportTests.swift`. Reuse the file's helpers for building announce packets + a store (mirror the existing announce-learning tests). Key helper: a way to make a HEADER_1 announce packet for a synthetic identity/destination on a given interface (the existing tests already build announce packets — reuse that).

```swift
@Test @MainActor func relayRebroadcastsAnnounceWithHeader2AndOurTransportId() async {
    let relay = Identity()
    let store = TestStore(initialState: Transport.State()) { Transport() }
        withDependencies: { $0.date = .constant(Date(timeIntervalSince1970: 0)) }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    await store.send(.setTransportIdentity(relay))
    // A genuine-shape HEADER_1 announce for a REMOTE destination, heard on i0 at hops = 2.
    let (announceRaw, destHash) = makeAnnouncePacket(hops: 2)   // reuse existing test helper
    let captured = LockIsolated<[(InterfaceID, Data)]>([])
    await store.send(.received(InterfaceID("i0"), announceRaw))
    // Collect the re-broadcast transmits.
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action { captured.withValue { $0.append((ifID, raw)) } }
        return false
    } timeout: .zero   // drain; adapt to the file's non-exhaustive drain idiom
    // Path learned with the HEADER_1 fallback nextHop == destHash.
    #expect(store.state.learned[destHash]?.nextHop == destHash)
    // Exactly one re-broadcast, on i1 (NOT i0), HEADER_2, our transport_id, hops+1, same payload.
    let sends = captured.value
    #expect(sends.count == 1)
    #expect(sends.first?.0 == InterfaceID("i1"))
    let rb = Packet(raw: sends.first!.1)!
    #expect(rb.headerType == .header2)
    #expect(rb.transportType == .transport)
    #expect(rb.transportId == relay.hash)
    #expect(rb.hops == 3)                                   // received 2 + 1
    #expect(rb.destinationHash == destHash)
    let orig = Packet(raw: announceRaw)!
    #expect(rb.payload == orig.payload)                     // payload verbatim (signature intact)
}

@Test @MainActor func leafDoesNotRebroadcast() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
        withDependencies: { $0.date = .constant(Date(timeIntervalSince1970: 0)) }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    // transportIdentity stays nil → leaf.
    let (announceRaw, destHash) = makeAnnouncePacket(hops: 2)
    let sawTransmit = LockIsolated(false)
    await store.send(.received(InterfaceID("i0"), announceRaw))
    await store.receive { action in
        if case .delegate(.transmit) = action { sawTransmit.setValue(true) }
        if case .delegate(.pathLearned) = action { return true }
        return false
    }
    #expect(sawTransmit.value == false)                     // no re-broadcast in leaf mode
    #expect(store.state.learned[destHash]?.nextHop == destHash)   // fallback still applied
}

@Test @MainActor func relayDoesNotRebroadcastForLocalDestinationOrPastHopLimit() async {
    // (a) announce for a LOCAL destination → not learned, not re-broadcast.
    // (b) announce at hops == maxHops-1 → not re-broadcast (limit).
    // Build both per the file's helpers; assert no .transmit is emitted in either case.
}
```

> Implementer note: adapt to the file's REAL announce-building + store idioms (`makeAnnouncePacket(hops:)` is a stand-in for however `TransportTests.swift` already constructs announce packets — reuse it, adding a `hops` knob if needed). The re-broadcast is emitted as effect actions; drain them the way the file's non-exhaustive tests do (the `store.receive` predicate shape above is illustrative). Fill in the `relayDoesNotRebroadcast…` body concretely (local-dest via `registerLocalDestination` first; hop-limit via `hops = Int(Packet.maxHops) - 1`). REQUIRED assertions (do NOT weaken): relay HEADER_1 announce → one re-broadcast on the non-received interface, HEADER_2, `transportId == relay.hash`, `hops == received+1`, `payload == original`, and `learned.nextHop == destHash`; a HEADER_2 announce → `learned.nextHop == the announce's transportId`; leaf mode → zero transmits; local-dest and hop-limit → zero transmits.

- [ ] **Step 4: Run to verify** — `swift test --filter Transport` → the new tests + all existing Transport tests pass (leaf behavior unchanged: existing announce-learning tests must still pass, since `transportIdentity` defaults nil).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter Transport`, confirm the named test fails, revert; final green:
- Change `transportId: relayID.hash` → `transportId: packet.destinationHash` → `relayRebroadcastsAnnounce…` fails (wrong transport_id).
- Change `hops: packet.hops + 1` → `hops: packet.hops` → fails (`rb.hops == 3` expectation).
- Change `.filter { $0 != interfaceID }` → `.filter { _ in true }` → fails (re-broadcast also on i0 → `sends.count == 1` / interface expectation).
- Change `nextHop = packet.transportId ?? packet.destinationHash` → `packet.transportId` → `leafDoesNotRebroadcast` (nextHop == destHash) fails.
- Change the relay guard `state.transportIdentity` to always-relay (ignore nil) → `leafDoesNotRebroadcast` fails (transmit emitted).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/commit-4b1-t1.txt
```
(First line: `feat: Transport relay mode + announce re-broadcast (HEADER_2, hops+1)`, blank line, trailers.)

---

### Task 2: `Endpoint` enable-relay + genuine-RNS cross-validation + gate + README

**Files:**
- Modify: `Sources/ReTiCANode/Endpoint.swift`
- Test: `Tests/ReTiCANodeTests/EndpointTests.swift`
- Modify: `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift` (if new fields needed) + create `Tests/ReTiCATransportTests/Vectors/RelayCrossValidationTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1's `setTransportIdentity`; the existing `announce_packet` transport fixture (genuine-RNS HEADER_1 announce, `announce_hops`).

- [ ] **Step 1: `Endpoint` enable-relay pass-through**

In `Sources/ReTiCANode/Endpoint.swift`: add `case enableRelay(Identity)` to `Endpoint.Action`, and handle it (next to the other transport forwards):
```swift
            case let .enableRelay(identity):
                return .send(.transport(.setTransportIdentity(identity)))
```
(The `Scope(state: \.transport, action: \.transport)` already forwards `.transport(...)`; this is just an ergonomic top-level action. `pathLearned` already bubbles up, so downstream learning is observable.)

- [ ] **Step 2: `Endpoint` enable-relay test**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift`: send `.enableRelay(Identity())`, assert `store.state.transport.transportIdentity != nil`. (Small wiring test — reuse `makeStore`.)

```swift
@Test @MainActor func enableRelaySetsTransportIdentity() async {
    let (store, _) = makeStore()
    store.exhaustivity = .off
    let id = Identity()
    await store.send(.enableRelay(id))
    #expect(store.state.transport.transportIdentity == id)
}
```

- [ ] **Step 3: Genuine-RNS re-broadcast cross-validation**

The transport fixtures already carry `announce_packet` (a genuine Python-RNS HEADER_1 announce) + `announce_hops`. Create `Tests/ReTiCATransportTests/Vectors/RelayCrossValidationTests.swift`: feed the genuine announce into a relay `Transport` and assert the re-broadcast is a valid RNS-shaped relayed announce.

```swift
import Testing
import Foundation
@testable import ReTiCATransport
@testable import ReTiCA

@Test @MainActor func relayRebroadcastsGenuineRnsAnnounceCorrectly() async {
    let f = try! TransportVectorFixtures.load()
    let announceRaw = Data(hexString: f.announcePacket)!
    let relay = Identity()
    let store = TestStore(initialState: Transport.State()) { Transport() }
        withDependencies: { $0.date = .constant(Date(timeIntervalSince1970: 0)) }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("a")))
    await store.send(.interfaceConnected(InterfaceID("b")))
    await store.send(.setTransportIdentity(relay))
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("a"), announceRaw))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == InterfaceID("b") { captured.setValue(raw) }
        return false
    } timeout: .zero
    let rb = Packet(raw: captured.value!)!
    #expect(rb.headerType == .header2)
    #expect(rb.transportType == .transport)
    #expect(rb.transportId == relay.hash)
    #expect(Int(rb.hops) == f.announceHops + 1)             // genuine hops + 1
    #expect(rb.payload == Packet(raw: announceRaw)!.payload) // payload verbatim
    // The re-broadcast is still a VALID announce: parsing it recovers the same genuine identity.
    let parsed = Announce.parse(payload: rb.payload, destinationHash: rb.destinationHash,
                                contextFlagSet: rb.contextFlag)
    #expect(parsed != nil)
    #expect(parsed?.identity.hash == Data(hexString: f.announceIdentityHash)!)   // signature-validated identity
}
```

(This proves the relay's re-broadcast is wire-faithful against genuine RNS: correct HEADER_2 rewrite, hops+1, our transport_id, and the ORIGINAL genuine-RNS payload preserved so the reference signature still validates. No fixture regeneration needed — reuses `announce_packet`/`announce_hops`/`announce_identity_hash`. If `announce_identity_hash` isn't already decoded in `TransportVectorFixtures.swift`, add it.)

- [ ] **Step 4: Run** — `swift test --filter RelayCrossValidation` and `swift test --filter Endpoint` → PASS.

- [ ] **Step 5: Full gate** — `swift test` → PASS; report pass/skip counts.

- [ ] **Step 6: Mutation sweep (cross-cutting)**

Apply, run the named filter, confirm failure, revert; final full `swift test` green:
- In `Endpoint.enableRelay`, change the forward to `.none` → `enableRelaySetsTransportIdentity` fails.
- In Task 1's re-broadcast, change `transportId: relayID.hash` → `transportId: relayID.hash.reversed()`-style wrong value (e.g. `Data(relayID.hash.reversed())`) → `relayRebroadcastsGenuineRnsAnnounceCorrectly` fails (wrong transport_id). Run under `--filter RelayCrossValidation`.

- [ ] **Step 7: Commit (Endpoint + cross-val)**

```
git add Sources/ReTiCANode/Endpoint.swift Tests/ReTiCANodeTests/EndpointTests.swift Tests/ReTiCATransportTests/Vectors/RelayCrossValidationTests.swift Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift
git commit -F /tmp/ReTiCA/commit-4b1-t2a.txt
```
(First line: `feat: Endpoint enableRelay + genuine-RNS announce re-broadcast cross-validation`, blank line, trailers.)

- [ ] **Step 8: README**

In `README.md`, add a transport-relaying note: a node can be put in **relay mode** via `enableRelay(identity)`; a relay re-broadcasts announces it hears for non-local destinations with the RNS header rewrite (HEADER_2, `transport_id` = the relay's hash, `hops+1`) to its other interfaces, so the mesh learns multi-hop paths (the path table records the next hop toward each destination). Note that **data-packet forwarding** and re-broadcast robustness (retries/rate-limiting/expiry) are subsequent sub-slices (4b-2/4b-3).

- [ ] **Step 9: Commit (README)**

```
git add README.md
git commit -F /tmp/ReTiCA/commit-4b1-t2b.txt
```
(First line: `docs: transport relay mode (announce propagation)`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- Opt-in relay via `transportIdentity` + `setTransportIdentity` → Task 1 Step 1. ✓
- nextHop = transportId ?? destinationHash fallback → Task 1 Step 2. ✓
- Immediate re-broadcast (same payload, HEADER_2, our transport_id, hops+1, ≠received-from, hop-limit) → Task 1 Step 2. ✓
- Leaf mode unchanged → Task 1 Step 2 (guard) + Step 4 (existing tests pass). ✓
- Endpoint enable pass-through → Task 2 Step 1. ✓
- Genuine-RNS re-broadcast cross-val → Task 2 Step 3. ✓
- Gate + README → Task 2 Steps 5, 8. ✓
- Deferred (data forwarding 4b-2; timing/retries/anti-replay/expiry 4b-3; hops-counter reconciliation) → untouched. ✓
- No `Packet`/core change → respected. ✓

**Placeholder scan:** No TBD/TODO in production steps. The test-helper notes (`makeAnnouncePacket(hops:)` reuse, the non-exhaustive drain idiom, the `relayDoesNotRebroadcast…` body) are explicit implementer guidance (reuse the file's real idioms) with the assertions locked — not missing implementation.

**Type consistency:** `transportIdentity: Identity?`, `setTransportIdentity(Identity?)`, `enableRelay(Identity)`, `nextHop = packet.transportId ?? packet.destinationHash`, the HEADER_2 `Packet(...)` init (matching the existing `.send` construction's labels + `transportId:`), `Int(packet.hops) + 1 < Int(Packet.maxHops)`, and `relayID.hash` (16-byte `Identity.hash`) are used identically across tasks. The re-broadcast reuses `packet.payload` verbatim and the `.transmit`/`.pathLearned` delegates are unchanged.
