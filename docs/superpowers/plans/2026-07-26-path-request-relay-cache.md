# Transport #4c-2: Relay Answers a Path Request From Cache — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A relay that has learned a path to a destination D (but does not own D) answers an inbound `PATH_REQUEST` for D by re-emitting D's cached announce as a HEADER_2 `pathResponse`, so a requester can discover a multi-hop destination via the relay.

**Architecture:** All changes in `Sources/ReTiCATransport/Transport.swift` (TCA state + reducer) plus its tests and the cross-val fixture generator/vectors. Pure core (`Sources/ReTiCA/*`) untouched. Add an `announceCache: [Data: Data]` (destHash → announce payload) populated when a path is learned and GC'd with the path; extend the #4c-1 `PATH_REQUEST` responder so that, when we do not own D but are a relay with a cached path, we re-emit the cached announce (verbatim payload, original signature) as a HEADER_2 `pathResponse` on the arrival interface, guarded so we never answer when the requester is our own next hop toward D.

**Tech Stack:** Swift, The Composable Architecture (TCA), Swift Testing (`@Test`), genuine RNS 1.3.8 in the conda `rns` env for cross-validation fixtures.

## Global Constraints

- Commit directly to `main`; no feature branch, no merge dance.
- No compound shell commands (no `|` beyond a single pipeline, `&&`, `||`, `;`, `$(...)`-feeding, `xargs`, inline interpreter scripts). One command per Bash call. A single `>` redirect is allowed. Never use `echo`/`printf`/heredoc to write files (use editor tools); redirecting a real command's output to a file is fine.
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test: (a) run pass; (b) batch-mutate production to force fail + confirm each fails; (c) revert + confirm pass.
- TCA tests are non-exhaustive (`store.exhaustivity = .off`) and assert outcomes/behavior, not implementation path.
- Data slicing is COUNT-based (`Data(payload.prefix(16))`, `Data(payload.dropFirst(16).prefix(16))`), never index-based — `packet.payload` may be a non-zero-startIndex slice.
- Wire constants pinned against RNS source: `PATH_RESPONSE = 0x0B` (RNS Packet.py:83, our `PacketContext.pathResponse = 0x0B`); HEADER_2 announce wire layout = `flags | hops | transport_id(16) | dest_hash(16) | context(1) | payload` (confirmed via genuine `RNS.Packet.pack()`); relay-answer hops = `entry.hops + 1` (matches our normal relay re-broadcast at Transport.swift:248 and RNS's re-emitted wire hop count, RNS Transport.py:631 with inbound increment at 1491).
- Cross-validation fixtures MUST drive genuine RNS code (here: `RNS.Packet.pack()`), never hand-rolled bytes.
- Build gotcha: on signal-11/SIGILL, run `swift package clean` then retry (stale cache, not a real failure).
- Commit trailers, exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

**Spec:** `docs/superpowers/specs/2026-07-27-path-request-relay-cache-design.md`

**Base:** this plan's own commit (verify the real range with `git log --oneline <planCommit>..HEAD`, never `HEAD~1`).

---

## File Structure

- **Modify** `Sources/ReTiCATransport/Transport.swift`
  - `State`: add `announceCache: [Data: Data]`.
  - `.announce` handler (`shouldReplace` block, ~line 235): populate `announceCache`.
  - `.maintenanceTick` handler (~line 334): GC `announceCache` with the path.
  - `.data` `PATH_REQUEST` responder (~line 268): after the owner check, add the relay-answer-from-cache branch + loop guard.
- **Modify** `Tests/ReTiCATransportTests/TransportTests.swift`: cache-populate test; extend the existing expiry test with cache-GC assertions; relay-answer + guard + e2e tests.
- **Modify** `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`: emit the genuine-RNS HEADER_2 `pathResponse` announce fixture.
- **Regenerate** `Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`.
- **Modify** `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`: add the new fixture fields.
- **Modify** `Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift`: add the HEADER_2 serialization byte-parity test.

---

## Task 1: Announce cache — state, populate on learn, GC with path

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (State field; `.announce` handler; `.maintenanceTick` handler)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Produces: `Transport.State.announceCache: [Data: Data]` — destHash → the announce payload bytes for the currently-learned path. Task 2 reads it.

- [ ] **Step 1: Write the failing tests**

Add near the other #4c helpers in `Tests/ReTiCATransportTests/TransportTests.swift` (the `makeAnnouncePacket(hops:)` helper at line 353 already exists):

```swift
// MARK: - #4c-2 announce cache

/// Learning a path caches the announce payload verbatim (for later relay path-responses).
@Test @MainActor func learningPathCachesAnnouncePayload() async {
    let (raw, destHash) = makeAnnouncePacket(hops: 2)
    let expectedPayload = Packet(raw: raw)!.payload
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceCache[destHash] == expectedPayload)
}
```

Then extend the existing `expiredPathAndBlobsAreSweptByMaintenanceTick` test (line 1603) to also assert the cache is populated then swept. Add one assertion after line 1615 (`#expect(store.state.announceBlobs[destHash] != nil)`):

```swift
    #expect(store.state.announceCache[destHash] != nil)
```

and one after line 1628 (`#expect(store.state.announceBlobs[destHash] == nil)`):

```swift
    #expect(store.state.announceCache[destHash] == nil)
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TransportTests 2>&1 | tail -40`
Expected: `learningPathCachesAnnouncePayload` FAILS (`announceCache` does not exist → compile error, or nil once the field is added but not populated); the extended expiry test FAILS on the new cache assertions.

- [ ] **Step 3: Add the state field**

In `Sources/ReTiCATransport/Transport.swift`, in `State`, next to `announceBlobs` (line 38):

```swift
        /// destHash → the announce payload (carries the destination's valid signature)
        /// for the currently-learned path. Enables a relay to re-emit a cached announce as
        /// a path response (RNS get_cached_packet, Transport.py:2973). GC'd with the path.
        public var announceCache: [Data: Data] = [:]
```

- [ ] **Step 4: Populate on learn**

In the `.announce` handler, inside the `shouldReplace` block (lines 234-238), add the cache write alongside the learned-path update:

```swift
                    if Transport.shouldReplace(state.learned[packet.destinationHash], with: candidate) {
                        state.learned[packet.destinationHash] = candidate
                        state.announceCache[packet.destinationHash] = packet.payload
                        effects.append(.send(.delegate(.pathLearned(
                            destinationHash: packet.destinationHash, hops: packet.hops))))
                    }
```

- [ ] **Step 5: GC with the path**

In the `.maintenanceTick` handler, in the path-expiry sweep (lines 331-335), remove the cache entry with the path and its blob ring:

```swift
                for (dest, entry) in state.learned
                where now.timeIntervalSince(entry.learnedAt) > Transport.pathExpiry {
                    state.learned[dest] = nil
                    state.announceBlobs[dest] = nil          // blob GC piggybacks on path expiry
                    state.announceCache[dest] = nil          // cached announce GC piggybacks too
                }
```

- [ ] **Step 6: Run the tests to verify they pass**

Run: `swift test --filter TransportTests 2>&1 | tail -40`
Expected: `learningPathCachesAnnouncePayload` and `expiredPathAndBlobsAreSweptByMaintenanceTick` PASS.

- [ ] **Step 7: Mutation-verify (three-step)**

Batch-mutate: (1) comment out the `state.announceCache[packet.destinationHash] = packet.payload` line; (2) comment out the `state.announceCache[dest] = nil` line. Run `swift test --filter TransportTests`. Expected: mutation (1) fails `learningPathCachesAnnouncePayload` and the populate assertion in the expiry test; mutation (2) fails the GC assertion in the expiry test. Revert both; run again; expected all PASS.

- [ ] **Step 8: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/commit-4c2-t1.txt
```

(Write the message to `/tmp/ReTiCA/commit-4c2-t1.txt` first, e.g. `feat: transport #4c-2 task 1 — announce cache (populate on learn, GC with path)` plus the two required trailers.)

---

## Task 2: Relay answers a path request from cache + loop guard

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (the `.data` `PATH_REQUEST` responder, ~lines 264-282)
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: `State.announceCache` (Task 1), `State.learned` (`LearnedDestination` with `.hops`, `.nextHop`, `.ratchet`), `State.transportIdentity`, `Transport.pathRequestDestinationHash`, `Packet.maxHops`, `PacketContext.pathResponse`.

**Context:** The #4c-1 responder is the first branch of the inbound `.data` case (Transport.swift:268), guarded by `packet.destinationHash == Transport.pathRequestDestinationHash`. It currently owner-answers and otherwise `return .none`. This task restructures the owner check from a `guard/else return` into an `if let` so control can fall through to the new relay-answer branch. The owner-response body is unchanged — only re-nested.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCATransportTests/TransportTests.swift` in the `#4c-1 path requests` section. These reuse `makeAnnouncePacket(hops:)` (line 353) to seed a learned path and `makePathRequest(for:tag:)` (line 1742) for a non-relay request. Add a relay-request helper first:

```swift
/// A relay's PATH_REQUEST: destHash ‖ requestor_transport_id ‖ tag.
private func makeRelayPathRequest(for destHash: Data, requestorTransportId: Data,
                                  tag: Data = Data(repeating: 0x5A, count: 16)) -> Data {
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                        payload: destHash + requestorTransportId + tag)
    return try! packet.packed()
}
```

Tests:

```swift
/// A relay that has learned a path answers a PATH_REQUEST from cache with a HEADER_2
/// pathResponse announce (our transport_id, hops = learned+1, verbatim cached payload)
/// on the arrival interface.
@Test @MainActor func relayAnswersPathRequestFromCache() async {
    let relay = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(hops: 2)
    let cachedPayload = Packet(raw: announceRaw)!.payload
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.setTransportIdentity(relay))
    // Learn a path to destHash (HEADER_1 announce, directly heard → nextHop == destHash).
    await store.send(.received(InterfaceID("i0"), announceRaw))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }

    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: destHash)))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == InterfaceID("i0") {
            captured.setValue(raw); return true
        }
        return false
    }
    let resp = Packet(raw: captured.value!)!
    #expect(resp.packetType == .announce)
    #expect(resp.headerType == .header2)
    #expect(resp.transportType == .transport)
    #expect(resp.context == .pathResponse)
    #expect(resp.transportId == relay.hash)
    #expect(resp.destinationHash == destHash)
    #expect(resp.hops == 3)                       // learned hops (2) + 1
    #expect(resp.payload == cachedPayload)        // verbatim → signature intact
}

/// A non-relay (transportIdentity == nil) never answers from cache — that is the relay-only path.
@Test @MainActor func nonRelayDoesNotAnswerPathRequestFromCache() async {
    let (announceRaw, destHash) = makeAnnouncePacket(hops: 2)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.received(InterfaceID("i0"), announceRaw))     // learns + caches, but leaf mode
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: destHash)))
    store.exhaustivity = .on                                        // no transmit
}

/// A relay with no cached path for the requested destination does not answer (bounds the
/// relay-answer to known paths; recursive re-broadcast is #4c-3).
@Test @MainActor func relayWithoutCachedPathDoesNotAnswer() async {
    let relay = Identity()
    let unknown = Data(repeating: 0x77, count: 16)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.setTransportIdentity(relay))
    await store.send(.received(InterfaceID("i0"), makePathRequest(for: unknown)))
    store.exhaustivity = .on                                        // no transmit
}

/// Loop guard: a relay does not answer when the requester's transport_id equals our next hop
/// toward the destination (RNS Transport.py:2987) — but answers when it differs.
@Test @MainActor func relayLoopGuardOnRequestorEqualsNextHop() async {
    let relay = Identity()
    // Learn the path via a HEADER_2 announce so nextHop == the relaying transport_id we choose.
    let upstream = Identity()
    let (h1Raw, destHash) = makeAnnouncePacket(hops: 2)
    let h1 = Packet(raw: h1Raw)!
    let relayedAnnounce = Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                                 destinationType: .single, context: .none, contextFlag: false, hops: 2,
                                 destinationHash: destHash, transportId: upstream.hash, payload: h1.payload)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.setTransportIdentity(relay))
    await store.send(.received(InterfaceID("i0"), try! relayedAnnounce.packed()))
    await store.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(store.state.learned[destHash]?.nextHop == upstream.hash)

    // Requester IS our next hop → do not answer.
    await store.send(.received(InterfaceID("i0"),
                               makeRelayPathRequest(for: destHash, requestorTransportId: upstream.hash)))
    store.exhaustivity = .on

    // Different requestor transport_id → we answer.
    store.exhaustivity = .off
    let other = Data(repeating: 0x33, count: 16)
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("i0"),
                               makeRelayPathRequest(for: destHash, requestorTransportId: other)))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    #expect(Packet(raw: captured.value!)?.context == .pathResponse)
}

/// End-to-end: a requester learns the destination from the relay's cache path-response.
@Test @MainActor func relayCachePathResponseIsLearnedByRequester() async {
    let relay = Identity()
    let (announceRaw, destHash) = makeAnnouncePacket(hops: 2)
    let identityHash = Announce.parse(payload: Packet(raw: announceRaw)!.payload,
                                      destinationHash: destHash, contextFlagSet: false)!.identity.hash
    let relayStore = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.continuousClock = ImmediateClock()
    }
    relayStore.exhaustivity = .off
    await relayStore.send(.interfaceConnected(InterfaceID("i0")))
    await relayStore.send(.setTransportIdentity(relay))
    await relayStore.send(.received(InterfaceID("i0"), announceRaw))
    await relayStore.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    let response = LockIsolated<Data?>(nil)
    await relayStore.send(.received(InterfaceID("i0"), makePathRequest(for: destHash)))
    await relayStore.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { response.setValue(raw); return true }
        return false
    }
    // Requester learns from the relay's path-response like any announce.
    let requester = TestStore(initialState: Transport.State()) { Transport() }
    requester.exhaustivity = .off
    await requester.send(.received(InterfaceID("up"), response.value!))
    await requester.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(requester.state.learned[destHash]?.identity.hash == identityHash)
    #expect(requester.state.learned[destHash]?.nextHop == relay.hash)   // reachable via the relay
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter TransportTests 2>&1 | tail -50`
Expected: the five new tests FAIL (no relay-answer branch yet — no transmit for the relay cases; the guard/e2e expectations unmet).

- [ ] **Step 3: Restructure the responder + add the relay-answer branch**

In `Sources/ReTiCATransport/Transport.swift`, replace the current owner-answer block (lines 268-282) with:

```swift
                    if packet.destinationHash == Transport.pathRequestDestinationHash {
                        guard packet.payload.count >= 16 else { return .none }
                        let requested = Data(packet.payload.prefix(16))
                        // (1) We OWN the requested destination → answer with a fresh path-response.
                        if let dest = state.localDestinations[requested],
                           let identity = dest.identity, identity.privateKey != nil {
                            let now = UInt64(date.now.timeIntervalSince1970)
                            let randomHash = Announce.randomHash(now: now, randomPrefix: SecureRandom.bytes(5))
                            let respPayload = Announce.buildPayload(identity: identity, destinationHash: dest.hash,
                                                                    nameHash: dest.nameHash, randomHash: randomHash,
                                                                    ratchet: nil, appData: nil)
                            let response = Packet.announce(from: dest, payload: respPayload, pathResponse: true)
                            guard let raw = try? response.packed() else { return .none }
                            return .send(.delegate(.transmit(interfaceID, raw)))
                        }
                        // (2) We are a relay that has learned + cached a path to the destination →
                        // re-emit the cached announce (verbatim payload, original signature) as a
                        // HEADER_2 pathResponse so the requester learns the destination via us.
                        // RNS Transport.py:2972-3033 (get_cached_packet + rebroadcast as path response).
                        if let relayID = state.transportIdentity,
                           let cachedPayload = state.announceCache[requested],
                           let entry = state.learned[requested],
                           Int(entry.hops) + 1 < Int(Packet.maxHops) {
                            // Loop guard: a relay requester carries its transport_id (48-byte payload).
                            // If that equals our next hop toward the destination, the requester is
                            // already on our path — do not answer (RNS Transport.py:2987).
                            let requestorTransportId: Data? = packet.payload.count > 32
                                ? Data(packet.payload.dropFirst(16).prefix(16)) : nil
                            guard requestorTransportId != entry.nextHop else { return .none }
                            let response = Packet(
                                headerType: .header2, packetType: .announce, transportType: .transport,
                                destinationType: .single, context: .pathResponse,
                                contextFlag: entry.ratchet != nil, hops: entry.hops + 1,
                                destinationHash: requested, transportId: relayID.hash, payload: cachedPayload)
                            guard let raw = try? response.packed() else { return .none }
                            return .send(.delegate(.transmit(interfaceID, raw)))
                        }
                        return .none
                    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter TransportTests 2>&1 | tail -50`
Expected: all five new tests PASS; the existing #4c-1 responder tests (`localDestinationAnswersPathRequestWithPathResponse`, `pathRequestForNonLocalDestinationIsNotAnswered`, `pathResponseAnnounceIsLearnedByRequester`) still PASS (owner body unchanged).

- [ ] **Step 5: Mutation-verify (three-step)**

Verify these mutations independently (they touch interacting branches, so run one at a time, reverting between):
1. Change `contextFlag: entry.ratchet != nil` → `hops: entry.hops` (drop the `+1`): `relayAnswersPathRequestFromCache` fails (`resp.hops == 3` expectation).
2. Invert the loop guard: `guard requestorTransportId == entry.nextHop else { return .none }`: `relayLoopGuardOnRequestorEqualsNextHop` fails (answers the equal case / drops the different case).
3. Change `context: .pathResponse` → `context: .none`: `relayAnswersPathRequestFromCache` and the guard test's context assertion fail.
4. Drop the relay branch entirely (replace its body with `return .none`): the four relay tests fail.

For each: apply, `swift test --filter TransportTests`, confirm the named test fails, revert. Then a final clean run: all PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/commit-4c2-t2.txt
```

(Message e.g. `feat: transport #4c-2 task 2 — relay answers path request from cache + loop guard` plus trailers.)

---

## Task 3: Cross-validate HEADER_2 pathResponse serialization vs genuine RNS

**Files:**
- Modify: `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`
- Regenerate: `Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`
- Modify: `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`
- Modify: `Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift`

**Interfaces:**
- Consumes: the relay-answer `Packet(...)` construction from Task 2 (HEADER_2 announce, `context: .pathResponse`).

**Context:** This is the first byte-level cross-validation of our HEADER_2 announce serialization against the genuine RNS serializer. The fixture drives real `RNS.Packet.pack()` (mirroring RNS Transport.py:616-629, where a relay re-emits a cached announce as a path response). Confirmed feasible: `RNS.Packet.pack()` serializes a standalone HEADER_2 PATH_RESPONSE announce to 192 bytes with layout `flags(0x51) | hops | transport_id(16) | dest_hash(16) | context(0x0B) | payload`. The Swift side builds the same `Packet` from the same payload/transport_id/hops and asserts `.packed()` is byte-identical.

- [ ] **Step 1: Extend the fixture generator**

In `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`, after the `#4c-1 path request` block (line 82), add:

```python
# --- #4c-2 relay cache path-response cross-validation ---
# Genuine RNS packs the HEADER_2 PATH_RESPONSE announce a relay re-emits from cache
# (mirrors Transport.py:616-629). Drives real RNS.Packet.pack() — the wire serializer —
# wrapping the SAME reference announce payload above (non-circular: payload + packing both genuine).
_pr_relay = RNS.Identity()                          # the relay's transport identity
_pr_ann_dest = RNS.Destination(identity, RNS.Destination.OUT, RNS.Destination.SINGLE, app, aspect)
_pr_ann_dest.hash = dest_hash
_pr_resp_hops = 4
_pr_resp_pkt = RNS.Packet(_pr_ann_dest, payload, RNS.Packet.ANNOUNCE,
                          context=RNS.Packet.PATH_RESPONSE,
                          header_type=RNS.Packet.HEADER_2,
                          transport_type=RNS.Transport.TRANSPORT,
                          transport_id=_pr_relay.hash,
                          context_flag=RNS.Packet.FLAG_UNSET)
_pr_resp_pkt.hops = _pr_resp_hops
_pr_resp_pkt.pack()
```

And add these keys to the `json.dumps({...})` dict (after `pr_request_payload`):

```python
    "pr_resp_relay_hash": _pr_relay.hash.hex(),
    "pr_resp_payload": payload.hex(),
    "pr_resp_hops": _pr_resp_hops,
    "pr_resp_packet": _pr_resp_pkt.raw.hex(),
```

- [ ] **Step 2: Regenerate the fixture JSON**

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py > Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`
Expected: exit 0; the JSON now contains `pr_resp_relay_hash`, `pr_resp_payload`, `pr_resp_hops`, `pr_resp_packet`. (`dest_hash` for the response equals the existing `announce_dest_hash`.)

- [ ] **Step 3: Add the fixture fields to the Swift struct**

In `Tests/ReTiCATransportTests/Vectors/TransportVectorFixtures.swift`, add properties after `prRequestPayload` (line 36):

```swift
    let prRespRelayHash: String
    let prRespPayload: String
    let prRespHops: Int
    let prRespPacket: String
```

and `CodingKeys` cases after `prRequestPayload` (line 70):

```swift
        case prRespRelayHash = "pr_resp_relay_hash"
        case prRespPayload = "pr_resp_payload"
        case prRespHops = "pr_resp_hops"
        case prRespPacket = "pr_resp_packet"
```

- [ ] **Step 4: Write the failing cross-val test**

In `Tests/ReTiCATransportTests/Vectors/TransportCrossValidationTests.swift`, add:

```swift
/// Our HEADER_2 pathResponse announce serialization is byte-identical to what genuine RNS emits
/// when a relay re-broadcasts a cached announce as a path response (RNS Transport.py:616-629).
@Test func relayCachePathResponseSerializationMatchesRns() throws {
    let f = try TransportVectorFixtures.load()
    let response = Packet(
        headerType: .header2, packetType: .announce, transportType: .transport,
        destinationType: .single, context: .pathResponse, contextFlag: false,
        hops: UInt8(f.prRespHops),
        destinationHash: Data(hexString: f.announceDestHash)!,
        transportId: Data(hexString: f.prRespRelayHash)!,
        payload: Data(hexString: f.prRespPayload)!)
    #expect(try response.packed() == Data(hexString: f.prRespPacket)!)
}
```

- [ ] **Step 5: Run to verify it fails, then passes**

Run: `swift test --filter relayCachePathResponseSerializationMatchesRns 2>&1 | tail -20`
First run (before Step 3's struct fields compile / with a deliberately wrong expectation) it fails; with the regenerated JSON and struct fields in place it PASSES on the real comparison. If it fails on the real comparison, our HEADER_2 serialization diverges from RNS — a genuine wire bug to fix in `Packet`, not the test.

- [ ] **Step 6: Mutation-verify**

Mutate the test's construction (e.g. `context: .pathResponse` → `context: .none`, or `hops: UInt8(f.prRespHops)` → `hops: 0`) and confirm the byte comparison fails; revert and confirm it passes. (This confirms the assertion is load-bearing on the exact serialized bytes.)

- [ ] **Step 7: Commit**

```bash
git add Tests/ReTiCATransportTests/Vectors/
git commit -F /tmp/ReTiCA/commit-4c2-t3.txt
```

(Message e.g. `test: transport #4c-2 task 3 — cross-validate HEADER_2 pathResponse serialization vs RNS` plus trailers.)

---

## Self-Review

- **Spec coverage:** announce cache (Task 1 populate + GC); relay-answer from cache (Task 2); loop guard (Task 2); byte-faithful cross-val (Task 3). Recursive re-broadcast + grace + dedup are explicitly deferred to #4c-3 (spec §Scope) — no task, by design.
- **Placeholder scan:** none — every step has concrete code/commands.
- **Type consistency:** `announceCache: [Data: Data]` defined in Task 1, consumed in Task 2; `LearnedDestination.hops/nextHop/ratchet`, `Packet.maxHops`, `PacketContext.pathResponse`, `Packet(headerType:...)` initializer all match existing signatures in `Transport.swift`/`Packet.swift`. Fixture field names (`prResp*`) consistent between generator keys, struct properties, CodingKeys, and the test.
- **Wire correctness:** hops `entry.hops + 1` matches both our re-broadcast (Transport.swift:248) and RNS wire output; context `0x0B` and HEADER_2 layout pinned via genuine `RNS.Packet.pack()`; `contextFlag` derived from `entry.ratchet != nil` matches `Announce.parse(contextFlagSet:)` semantics.
