# Transport Relaying 4b-2: Data-Packet Forwarding (one-way) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make data packets flow multi-hop — an originator sends HEADER_2 toward the next hop when a destination is reached via a relay, and a relay forwards a HEADER_2 data packet addressed to it (as `transport_id`) toward the destination (HEADER_2 to the next relay / HEADER_1 on the final hop). One-way, connectionless. Wire-compatible with Python-RNS 1.3.8.

**Architecture:** Two edits in `Transport.swift` — the `.send` originator branch (HEADER_2 when `nextHop != destHash`) and a relay-forward block at the top of the inbound `.data` case (forward a HEADER_2 packet whose `transport_id == our hash`, `nextHop`-based). Decision is `nextHop`-based, so no `learned.hops` change. Core `Packet` unchanged.

**Tech Stack:** Swift 6, The Composable Architecture (~1.26) — `Reduce`, `TestStore`; the in-core `Packet` (HEADER_1/HEADER_2 + `transportId`), `Identity`, `Destination`; wire cross-validation against RNS's exact byte rewrite.

## Global Constraints

- **RNS-faithful header rewrite** (`Transport.py:1603-1614`): relay hop keeps the WHOLE original flags byte → stays HEADER_2, `context_flag` preserved, only `transport_id` swapped to `nextHop` and `hops = received+1`; final hop rebuilds `HEADER_1<<6 | BROADCAST<<4 | (flags & 0x0F)` → HEADER_1, `transportType = .broadcast`, `transportId = nil`, **`contextFlag = false`** (context_flag dropped), `hops = received+1`. Payload always verbatim.
- **`nextHop`-based decision:** relay if `entry.nextHop != destHash`, final hop if `entry.nextHop == destHash`. No `learned.hops` read (the 4b-1 off-by-one stays out of the data path).
- **Relay is opt-in:** forwarding happens only when `state.transportIdentity != nil` AND `packet.transportId == transportIdentity.hash`. Leaf mode → today's `.data` behavior (local delivery / drop) unchanged. The originator HEADER_2 send applies to ALL nodes (a leaf can originate multi-hop traffic).
- **Hop limit + loop safety:** forward only if `Int(packet.hops) + 1 < Int(Packet.maxHops)` (128); a looped-back forwarded copy is dropped by the existing `packetHash` dedup (hash excludes hops/transport_id).
- **Two-layer purity:** only `Transport.swift` changes under `Sources/`. `Sources/ReTiCA/*` (core `Packet`) UNCHANGED.
- Build gotcha: signal-11/SIGILL during `swift test` → `swift package clean` then retry; never delete State fields to "fix" a crash.
- **Mutation-test discipline** for every new/changed test. **Commit directly to `main`.** Trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCATransport/Transport.swift` (**modify**, Task 1) — originator HEADER_2 send + relay-forward block.
- `Tests/ReTiCATransportTests/TransportTests.swift` (**modify**, Tasks 1 & 2) — unit tests + byte-fidelity + 3-node E2E.
- `README.md` (**modify**, Task 2).

---

### Task 1: Originator HEADER_2 send + relay data forwarding

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift`
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: `state.learned[dest]` (`LearnedDestination.nextHop`/`.interfaceID`), `state.transportIdentity` (4b-1), `Packet` HEADER_1/HEADER_2 init, `Packet.maxHops`.
- Produces: originator emits HEADER_2 to `nextHop` when via a relay; a relay forwards inbound HEADER_2 data toward the destination.

- [ ] **Step 1: Originator — HEADER_2 when via a relay**

In `Transport.swift`, replace the `.send` packet construction (currently always HEADER_1) with the branch:

```swift
            case let .send(destinationHash, plaintext):
                guard let entry = state.learned[destinationHash] else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .notLearned)))
                }
                let ciphertext = entry.identity.encrypt(plaintext, ratchet: entry.ratchet)
                let packet: Packet
                if let nh = entry.nextHop, nh != destinationHash {
                    // Destination is reached via a relay → send HEADER_2 to the next hop.
                    packet = Packet(headerType: .header2, packetType: .data, transportType: .transport,
                                    destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: destinationHash, transportId: nh, payload: ciphertext)
                } else {
                    // Directly reachable → HEADER_1 as before.
                    packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                    destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: destinationHash, transportId: nil, payload: ciphertext)
                }
                guard let raw = try? packet.packed() else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .tooLarge)))
                }
                return .send(.delegate(.transmit(entry.interfaceID, raw)))
```

- [ ] **Step 2: Relay — forward inbound HEADER_2 data addressed to us**

In the inbound `.data` case, insert the relay-forward block BEFORE the existing local-delivery guard:

```swift
                case .data:
                    // Relay: a HEADER_2 data packet naming us as the next hop, for a REMOTE destination,
                    // is forwarded toward the destination (nextHop-based; RNS Transport.py:1603-1614).
                    if let relayID = state.transportIdentity, packet.headerType == .header2,
                       packet.transportId == relayID.hash,
                       state.localDestinations[packet.destinationHash] == nil {
                        guard let entry = state.learned[packet.destinationHash],
                              Int(packet.hops) + 1 < Int(Packet.maxHops) else { return .none }
                        let fwd: Packet
                        if entry.nextHop == packet.destinationHash {
                            // Final hop → strip transport headers, HEADER_1 direct (context_flag dropped).
                            fwd = Packet(headerType: .header1, packetType: packet.packetType,
                                         transportType: .broadcast, destinationType: packet.destinationType,
                                         context: packet.context, contextFlag: false, hops: packet.hops + 1,
                                         destinationHash: packet.destinationHash, transportId: nil,
                                         payload: packet.payload)
                        } else {
                            // Relay onward → keep HEADER_2, swap transport_id to the next hop.
                            fwd = Packet(headerType: .header2, packetType: packet.packetType,
                                         transportType: .transport, destinationType: packet.destinationType,
                                         context: packet.context, contextFlag: packet.contextFlag,
                                         hops: packet.hops + 1, destinationHash: packet.destinationHash,
                                         transportId: entry.nextHop, payload: packet.payload)
                        }
                        guard let raw = try? fwd.packed() else { return .none }
                        return .send(.delegate(.transmit(entry.interfaceID, raw)))
                    }
                    guard let destination = state.localDestinations[packet.destinationHash],
                          destination.kind == packet.destinationType,
                          let plaintext = destination.decrypt(packet.payload)
                    else { return .none }
                    return .send(.delegate(.received(destinationHash: packet.destinationHash,
                                                     plaintext: plaintext)))
```

(Leaf mode → the `if let relayID …` guard is false → today's local-delivery path exactly.)

- [ ] **Step 3: Write the failing tests**

Append to `Tests/ReTiCATransportTests/TransportTests.swift`. Reuse the file's helpers for a `Transport.State` store + building `LearnedDestination` / injecting a learned path (mirror how existing `.send` tests set up `state.learned`). Key helper: put a learned path into state with a chosen `nextHop`/`interfaceID` (via `.received` of an announce, or by seeding state directly if the file does that).

```swift
@Test @MainActor func originatorSendsHeader2WhenPathViaRelay() async {
    // Learn a destination reachable via relay R (nextHop = R != destHash).
    let (store, destHash, relayHash) = storeWithLearnedPathViaRelay()   // helper: nextHop == relayHash
    store.exhaustivity = .off
    let captured = LockIsolated<Data?>(nil)
    await store.send(.send(destinationHash: destHash, plaintext: Data("hi".utf8)))
    await store.receive { if case let .delegate(.transmit(_, raw)) = $0 { captured.setValue(raw) }; return false } timeout: .zero
    let p = Packet(raw: captured.value!)!
    #expect(p.headerType == .header2)
    #expect(p.transportType == .transport)
    #expect(p.transportId == relayHash)                     // to the next hop
    #expect(p.destinationHash == destHash)
    #expect(p.hops == 0)
}

@Test @MainActor func originatorSendsHeader1WhenDirect() async {
    let (store, destHash) = storeWithLearnedDirectPath()    // nextHop == destHash
    store.exhaustivity = .off
    let captured = LockIsolated<Data?>(nil)
    await store.send(.send(destinationHash: destHash, plaintext: Data("hi".utf8)))
    await store.receive { if case let .delegate(.transmit(_, raw)) = $0 { captured.setValue(raw) }; return false } timeout: .zero
    let p = Packet(raw: captured.value!)!
    #expect(p.headerType == .header1)
    #expect(p.transportId == nil)
}

@Test @MainActor func relayForwardsFinalHopAsHeader1() async {
    // Relay R knows dest D directly (learned[D].nextHop == D). Inbound HEADER_2 data, transport_id == R.
    let (store, relay, destHash, outIf) = relayStoreKnowingDestDirectly()
    store.exhaustivity = .off
    let inbound = makeHeader2DataPacket(transportId: relay.hash, destHash: destHash, hops: 1,
                                        payload: Data([1, 2, 3]))
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("in"), inbound))
    await store.receive { if case let .delegate(.transmit(ifID, raw)) = $0 { captured.setValue((ifID, raw)) }; return false } timeout: .zero
    #expect(captured.value?.0 == outIf)
    let f = Packet(raw: captured.value!.1)!
    #expect(f.headerType == .header1)
    #expect(f.transportType == .broadcast)
    #expect(f.transportId == nil)
    #expect(f.hops == 2)                                    // received 1 + 1
    #expect(f.destinationHash == destHash)
    #expect(f.payload == Data([1, 2, 3]))                   // verbatim
}

@Test @MainActor func relayForwardsOnwardAsHeader2ToNextHop() async {
    // Relay knows dest D via another relay R2 (learned[D].nextHop == R2 != D).
    let (store, relay, destHash, nextRelay, outIf) = relayStoreKnowingDestViaAnotherRelay()
    store.exhaustivity = .off
    let inbound = makeHeader2DataPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: Data([9]))
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("in"), inbound))
    await store.receive { if case let .delegate(.transmit(_, raw)) = $0 { captured.setValue(raw) }; return false } timeout: .zero
    let f = Packet(raw: captured.value!)!
    #expect(f.headerType == .header2)
    #expect(f.transportId == nextRelay)                     // swapped to the next hop
    #expect(f.hops == 1)
    #expect(f.payload == Data([9]))
}

@Test @MainActor func relayDropsWhenNoPathAndLeafDoesNotForward() async {
    // (a) relay, transport_id == us, but no learned path for dest → no transmit.
    // (b) leaf (transportIdentity == nil), same inbound HEADER_2 → no transmit (falls to local delivery / drop).
    // (c) hop limit: inbound hops == maxHops-1 → no transmit.
}
```

> Implementer note: build the helpers to match the file's REAL idioms for seeding `state.learned` and constructing packets (`makeHeader2DataPacket`, `storeWithLearnedPathViaRelay`, etc. are stand-ins — the file already builds announce packets and may seed `learned`; reuse/extend). A learned path can be created by driving an announce `.received` (HEADER_2 announce → `nextHop = its transport_id`; HEADER_1 → `nextHop = destHash`) — that is the cleanest genuine way to set `nextHop`. Drain effects via the file's non-exhaustive idiom. Fill in `relayDropsWhenNoPathAndLeafDoesNotForward` concretely. REQUIRED assertions (do NOT weaken): originator HEADER_2 (to nextHop) vs HEADER_1 (direct); relay final-hop HEADER_1 (transportId nil, broadcast, hops+1, payload verbatim); relay onward HEADER_2 (transportId = nextHop); no-path/leaf/hop-limit → zero transmits; local-dest still delivered.

- [ ] **Step 4: Run to verify** — `swift test --filter Transport` → new tests + all existing pass (leaf `.data`/`.send` behavior unchanged: existing send/deliver tests must still pass; a directly-learned path still yields HEADER_1).

- [ ] **Step 5: Mutation sweep**

Apply each, run `swift test --filter Transport`, confirm the named test fails, revert; final green:
- Originator: change `nh != destinationHash` to `false` (never HEADER_2) → `originatorSendsHeader2WhenPathViaRelay` fails.
- Relay: change `entry.nextHop == packet.destinationHash` to `false` (never final-hop) → `relayForwardsFinalHopAsHeader1` fails (gets HEADER_2 instead).
- Relay: change `transportId: entry.nextHop` → `transportId: packet.destinationHash` → `relayForwardsOnwardAsHeader2ToNextHop` fails.
- Relay: change `hops: packet.hops + 1` → `hops: packet.hops` → the `hops == received+1` expectations fail.
- Relay guard: drop the `state.transportIdentity != nil` condition → the leaf case in `relayDropsWhenNoPathAndLeafDoesNotForward` fails (forwards in leaf mode).

- [ ] **Step 6: Commit**

```
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/commit-4b2-t1.txt
```
(First line: `feat: Transport data forwarding — originator HEADER_2 + relay forward`, blank line, trailers.)

---

### Task 2: Byte-fidelity vs RNS + 3-node E2E + gate + README

**Files:**
- Modify: `Tests/ReTiCATransportTests/TransportTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: Task 1's originator + relay forwarding.

- [ ] **Step 1: Byte-fidelity vs RNS's exact rewrite**

Append a test that constructs the EXPECTED forwarded bytes using RNS's raw-manipulation formula and asserts our relay's output matches byte-for-byte.

```swift
@Test @MainActor func relayForwardBytesMatchRnsRewrite() async {
    // Relay onward (HEADER_2 → next hop): RNS new_raw = raw[0:1] ‖ (hops+1) ‖ nextHop ‖ raw[18:].
    let (store, relay, destHash, nextRelay, _) = relayStoreKnowingDestViaAnotherRelay()
    store.exhaustivity = .off
    let inbound = makeHeader2DataPacket(transportId: relay.hash, destHash: destHash, hops: 2, payload: Data([7, 7]))
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("in"), inbound))
    await store.receive { if case let .delegate(.transmit(_, raw)) = $0 { captured.setValue(raw) }; return false } timeout: .zero
    // Expected per RNS: keep flags byte, hops+1, transport_id = nextHop (16B), keep destHash‖context‖payload.
    var expected = inbound.prefix(1)                       // flags byte (unchanged → HEADER_2)
    expected.append(UInt8(3))                              // hops = 2 + 1
    expected.append(nextRelay)                             // new transport_id (16 bytes)
    expected.append(inbound.suffix(from: inbound.startIndex + 18))   // destHash(16) ‖ context ‖ payload
    #expect(captured.value == Data(expected))
}
```

(This mirrors RNS `Transport.py:1605-1608` exactly — the flags byte, incremented hops, swapped transport_id, and the tail — a genuine cross-implementation wire check. The HEADER_1 final-hop byte layout is already asserted structurally in Task 1; if the file makes it easy, add the analogous raw-formula check for the final hop: `new_flags = HEADER_1<<6 | BROADCAST<<4 | (origFlags & 0x0F)` ‖ (hops+1) ‖ destHash‖context‖payload.)

> Implementer note: verify the exact header offset — HEADER_2 layout is `flags(1) ‖ hops(1) ‖ transportId(16) ‖ destHash(16) ‖ context(1) ‖ payload`, so `raw[18:]` = destHash onward and the transport_id occupies bytes 2..17. Confirm against `Packet.swift`'s serialization and adjust the offset constant if the address length differs (it's 16). If our packed output legitimately differs from RNS ONLY in a documented way (it should not), that is a real finding — investigate before weakening.

- [ ] **Step 2: 3-node A→R→B end-to-end (Transport level)**

Append the multi-hop E2E: three `Transport` stores — A (interface "ar"), R relay-enabled (interfaces "ar" + "rb"), B (interface "rb"). B registers + announces D; pump the announce A←R (R re-broadcasts) so A learns D via R; A `.send(msg)`; pump A→R→B; assert B surfaces `messageReceived(D, msg)` with the exact plaintext.

```swift
@Test @MainActor func threeNodeRelayDeliversMessageEndToEnd() async {
    // A[ar], R[ar,rb] relay, B[rb]. Build three stores; hand-pump .transmit frames between them.
    // 1. B.registerLocalDestination(D); B.announce(D) → capture B's announce frame on "rb".
    // 2. Deliver it to R.received("rb", frame). R (relay) re-broadcasts (4b-1) on "ar" → capture.
    // 3. Deliver R's re-broadcast to A.received("ar", frame). A learns D with nextHop == R.hash.
    // 4. A.send(D, "hello") → A emits HEADER_2 to R on "ar" → capture; deliver to R.received("ar", …).
    // 5. R forwards HEADER_1 to B on "rb" → capture; deliver to B.received("rb", …).
    // 6. B surfaces .delegate(.received(destinationHash: D, plaintext: "hello")).
    // Assert the exact plaintext arrives (proves the encrypted payload survived the relay).
}
```

> Implementer note: this is the meaningful integration test. Reuse the file's real store-construction + announce-building + frame-pump idioms (mirror how existing Transport tests drive `.received`/capture `.transmit`). R must have BOTH interfaces connected (`.interfaceConnected("ar")`, `.interfaceConnected("rb")`) and `.setTransportIdentity(R)`. B's destination D must have a private key (so B can decrypt); A must recover D's public identity from the announce (the normal learn path). REQUIRED assertion (do NOT weaken): B surfaces exactly one `messageReceived(destinationHash: D, plaintext: <A's exact message>)`. If, after genuinely building it, the pump proves intractable, report BLOCKED with exactly where it stalls — do NOT fake it; the unit tests (Task 1) + byte-fidelity already cover the mechanics, but this E2E is the payoff and should be delivered.

- [ ] **Step 3: Run** — `swift test --filter Transport` → PASS. Then full gate `swift test` → report pass/skip.

- [ ] **Step 4: Mutation sweep (cross-cutting)**

Apply, run the named filter, confirm failure, revert; final full `swift test` green:
- In the relay final-hop branch, change `payload: packet.payload` → `payload: Data()` → `threeNodeRelayDeliversMessageEndToEnd` fails (B gets wrong/empty plaintext) AND `relayForwardsFinalHopAsHeader1` fails.
- Revert the `transportId: entry.nextHop` swap to `packet.transportId` (forward unchanged) → `relayForwardBytesMatchRnsRewrite` fails.

- [ ] **Step 5: Commit (tests)**

```
git add Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/commit-4b2-t2a.txt
```
(First line: `test: RNS byte-fidelity + 3-node relay end-to-end for data forwarding`, blank line, trailers.)

- [ ] **Step 6: README**

In `README.md`, extend the transport-relay section: a relay now FORWARDS data packets addressed to it toward the destination (HEADER_2 to the next relay, or HEADER_1 on the final hop), and an originator sends a HEADER_2 packet to the learned next hop when a destination is reached via a relay — so a connectionless message travels multi-hop A→R→B, wire-compatible with Python-RNS 1.3.8. Note bidirectional links-over-a-relay and re-broadcast robustness remain 4b-2b/4b-3.

- [ ] **Step 7: Commit (README)**

```
git add README.md
git commit -F /tmp/ReTiCA/commit-4b2-t2b.txt
```
(First line: `docs: transport data forwarding (one-way multi-hop)`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- Originator HEADER_2 when `nextHop != destHash`, HEADER_1 direct otherwise → Task 1 Step 1. ✓
- Relay forward (nextHop-based: final-hop HEADER_1 / onward HEADER_2), hops+1, hop-limit, relay-mode-gated, payload verbatim → Task 1 Step 2. ✓
- RNS-faithful flag handling (relay keeps flags byte; final-hop drops context_flag) → Task 1 Step 2 (`contextFlag: false` final / `packet.contextFlag` relay) + Task 2 byte-fidelity. ✓
- No `learned.hops` change; leaf behavior unchanged → Global Constraints + Task 1 Step 4. ✓
- Byte-fidelity vs RNS + 3-node E2E + gate + README → Task 2. ✓
- Deferred (reverse path/links-over-relay 4b-2b; robustness 4b-3) → untouched. ✓
- No `Packet`/core change → respected. ✓

**Placeholder scan:** No TBD/TODO in production steps. The test-helper notes (seeding `learned` via announce, `makeHeader2DataPacket`, the 3-node pump) are explicit implementer guidance (reuse the file's real idioms) with the assertions locked — not missing implementation. The `raw[18:]` offset note is a concrete verification step.

**Type consistency:** `entry.nextHop != destinationHash` (originator) and `entry.nextHop == packet.destinationHash` (relay final-hop) use the same `LearnedDestination.nextHop`; `packet.transportId == relayID.hash`, `Int(packet.hops) + 1 < Int(Packet.maxHops)`, `hops: packet.hops + 1`, and the HEADER_1/HEADER_2 `Packet(...)` inits (matching the labels already used in `.send`/`.announce`) are used identically across tasks. `contextFlag: false` (final hop) / `packet.contextFlag` (relay hop) matches the spec's byte-fidelity requirement.
