# Path Request → Local-Destination Response Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** On-demand path discovery for the core case — a requester broadcasts a `PATH_REQUEST`; a node that owns the requested destination answers with a path-response announce; the requester learns the path.

**Architecture:** All in `Sources/ReTiCATransport/Transport.swift`. A `pathRequestDestinationHash` static (the well-known PLAIN control dest), a new `.requestPath(destinationHash:)` action that broadcasts a `DATA`/`BROADCAST`/`HEADER_1` PATH_REQUEST, and responder recognition at the start of the inbound `.data` case that answers with a `pathResponse` announce for an owned destination on the arrival interface. Core untouched (`.plain` + `.pathResponse` already exist).

**Tech Stack:** Swift, The Composable Architecture (~1.26). Cross-validated against genuine Python-RNS 1.3.8.

## Global Constraints

- Wire-compatible with Python-RNS 1.3.8. Core `Sources/ReTiCA/*` stays zero-dep and **untouched** — changes only in `Sources/ReTiCATransport/*` and `Tests/*`.
- Commit **directly to `main`** — no feature branch. Every commit leaves the FULL suite green.
- **No compound shell commands** — one command per shell call (a single `|` pipeline or `>` redirect allowed). Run `swift build`, `swift test`, `git add`, `git commit` separately. The generator is a file — run it with a `>` redirect. Never inline a script into an interpreter; write scripts to a file under `/tmp/ReTiCA/`.
- Temp files under `/tmp/ReTiCA/`.
- **Mutation-testing verification** for every new test. New TCA tests are non-exhaustive (`.off`) and assert outcomes ([[tca-tests-non-exhaustive]]).
- Reference RNS at `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/RNS/`; run its python by absolute path `/Users/ell/opt/anaconda3/envs/rns/bin/python`. Build gotcha: signal-11 → `swift package clean` then retry.
- Commit trailers (exact, both lines):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

Spec: `docs/superpowers/specs/2026-07-26-path-request-local-design.md`.

## Grounding facts (verified — do not re-derive)

- `Destination.hash(identityHash: Data?, appName: String, aspects: [String]) -> Data` — for `identityHash: nil` returns `truncatedHash(nameHash)` (16 bytes = `TRUNCATED_HASHLENGTH/8`), the RNS PLAIN branch. `Destination` has NO `appData` field (fields: kind, direction, appName, aspects, identity, groupKey; plus computed `nameHash`, `hash`).
- Outbound `.announce` handler (`Transport.swift:367-378`) is the template for building an announce: guards `let identity = dest.identity, identity.privateKey != nil`; `Announce.randomHash(now:randomPrefix:)`; `Announce.buildPayload(identity:destinationHash:nameHash:randomHash:ratchet:appData:)`; `Packet.announce(from:payload:)`; transmit to `state.interfaces`. `Packet.announce(from destination:, payload:, pathResponse: Bool = false, ratchetPresent: Bool = false)`.
- The `.data` case starts at `Transport.swift:263` (relay HEADER_2 forward, then local delivery). Insert the PATH_REQUEST recognition as the FIRST thing in `.data`. The `.received(interfaceID, data)` binding provides `interfaceID` (the arrival interface).
- Inbound: a `.data` packet passes the `packetHash` dedup guard (`if packetType != .announce { seenPacketHashes.insert }`) before the switch — so exact-duplicate PATH_REQUESTs are deduped; distinct tags (distinct payload) are not.
- `@Dependency(\.randomBytes) var randomBytes` (a `RandomBytesGenerator`; `randomBytes(count) -> Data`); test-overridable via `$0.randomBytes = RandomBytesGenerator { _ in Data(...) }`. The `@Dependency(\.transportDate) var date` is captured `[clock, date, randomBytes]`. `SecureRandom.bytes(5)` is used for the announce random prefix (non-injected — fine, tests parse the emitted announce rather than byte-match it).
- `Transport.Action` is `public enum Action: Equatable`; adding `case requestPath(destinationHash: Data)` is Equatable-safe. `Packet(headerType:packetType:transportType:destinationType:context:contextFlag:hops:destinationHash:transportId:payload:)` is the packet initializer; `DestinationType` has `.plain`; `Context` has `.pathResponse`.
- Cross-val infra: generator `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py` (already `import RNS`, uses `RNS.Destination.hash(identity, app, aspect)`); struct `TransportVectorFixtures.swift`; test file `TransportCrossValidationTests.swift`; `Data(hexString:)` decodes hex fields.

---

### Task 1: Path-request control dest, requester, and local-destination responder

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift`.
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`.

**Interfaces:**
- Produces: `static let Transport.pathRequestDestinationHash: Data`; `Transport.Action.requestPath(destinationHash: Data)` — read by Task 2.

- [ ] **Step 1: Add the control-destination hash static**

Near the other `static let`s (e.g. after `announceMaxRebroadcasts`):

```swift
    /// RNS Transport path-request control destination: PLAIN "rnstransport"/["path","request"]
    /// (Transport.py:61,256). Deterministic (no identity). Cross-validated against genuine RNS.
    static let pathRequestDestinationHash: Data =
        Destination.hash(identityHash: nil, appName: "rnstransport", aspects: ["path", "request"])
```

- [ ] **Step 2: Add the `.requestPath` action**

In `Transport.Action` (e.g. after `announce`):

```swift
        case requestPath(destinationHash: Data)
```

- [ ] **Step 3: Handle `.requestPath` — build + broadcast a PATH_REQUEST**

Add to the top-level `switch action` (e.g. after the `.announce` case at `Transport.swift:378`):

```swift
            case let .requestPath(destinationHash):
                // RNS request_path (Transport.py:2799): a DATA/BROADCAST/HEADER_1 packet to the
                // well-known PLAIN control destination; payload = destHash [+ our transport_id] + tag.
                var payload = destinationHash
                if let relayID = state.transportIdentity { payload.append(relayID.hash) }
                payload.append(randomBytes(16))                        // request tag (RNS get_random_hash)
                let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                                    destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                                    payload: payload)
                guard let raw = try? packet.packed() else { return .none }
                let sends = state.interfaces.map { Effect<Action>.send(.delegate(.transmit($0, raw))) }
                return sends.isEmpty ? .none : .merge(sends)
```

- [ ] **Step 4: Responder — answer a PATH_REQUEST for an owned destination**

At the START of the `.data` case (`Transport.swift:263`, before the relay HEADER_2 check at line 264), insert:

```swift
                case .data:
                    // A PATH_REQUEST (RNS Transport.py:2894/2939): a PLAIN DATA packet to the
                    // well-known control destination. If we OWN the requested destination, answer with
                    // a path-response announce on the arrival interface.
                    if packet.destinationHash == Transport.pathRequestDestinationHash {
                        guard packet.payload.count >= 16 else { return .none }
                        let requested = Data(packet.payload.prefix(16))
                        guard let dest = state.localDestinations[requested],
                              let identity = dest.identity, identity.privateKey != nil
                        else { return .none }
                        let now = UInt64(date.now.timeIntervalSince1970)
                        let randomHash = Announce.randomHash(now: now, randomPrefix: SecureRandom.bytes(5))
                        let respPayload = Announce.buildPayload(identity: identity, destinationHash: dest.hash,
                                                                nameHash: dest.nameHash, randomHash: randomHash,
                                                                ratchet: nil, appData: nil)
                        let response = Packet.announce(from: dest, payload: respPayload, pathResponse: true)
                        guard let raw = try? response.packed() else { return .none }
                        return .send(.delegate(.transmit(interfaceID, raw)))
                    }
                    // Relay: a HEADER_2 data packet naming us as the next hop, for a REMOTE destination,
```

(Leave the rest of the `.data` case — the relay HEADER_2 forward and local delivery — unchanged.)

- [ ] **Step 5: Build**

Run: `swift build`
Expected: compiles. (Editor "No such module 'ComposableArchitecture'" is a known false positive.)

- [ ] **Step 6: Add the tests**

Append to `Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
// MARK: - #4c-1 path requests

/// A helper to build a raw PATH_REQUEST for a destination (non-relay: destHash ‖ tag).
private func makePathRequest(for destHash: Data, tag: Data = Data(repeating: 0x5A, count: 16)) -> Data {
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                        payload: destHash + tag)
    return try! packet.packed()
}

/// requestPath broadcasts a DATA PATH_REQUEST to the control dest with destHash ‖ tag payload.
@Test @MainActor func requestPathBuildsBroadcastPathRequest() async {
    let destHash = Data(repeating: 0x22, count: 16)
    let tag = Data(repeating: 0xAB, count: 16)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.randomBytes = RandomBytesGenerator { _ in tag }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.interfaceConnected(InterfaceID("i1")))
    let captured = LockIsolated<Data?>(nil)
    await store.send(.requestPath(destinationHash: destHash))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let p = Packet(raw: captured.value!)!
    #expect(p.packetType == .data)
    #expect(p.transportType == .broadcast)
    #expect(p.headerType == .header1)
    #expect(p.destinationType == .plain)
    #expect(p.destinationHash == Transport.pathRequestDestinationHash)
    #expect(Data(p.payload.prefix(16)) == destHash)
    #expect(Data(p.payload.dropFirst(16)) == tag)         // non-relay → no transport_id
}

/// A relay's PATH_REQUEST includes its transport_id: destHash ‖ transportId ‖ tag.
@Test @MainActor func relayRequestPathIncludesTransportId() async {
    let relay = Identity()
    let destHash = Data(repeating: 0x22, count: 16)
    let tag = Data(repeating: 0xAB, count: 16)
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.randomBytes = RandomBytesGenerator { _ in tag }
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(InterfaceID("i0")))
    await store.send(.setTransportIdentity(relay))
    let captured = LockIsolated<Data?>(nil)
    await store.send(.requestPath(destinationHash: destHash))
    await store.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { captured.setValue(raw); return true }
        return false
    }
    let payload = Packet(raw: captured.value!)!.payload
    #expect(Data(payload.prefix(16)) == destHash)
    #expect(Data(payload.dropFirst(16).prefix(16)) == relay.hash)
    #expect(Data(payload.dropFirst(32)) == tag)
}

/// A node that OWNS the requested destination answers with a path-response announce on the arrival iface.
@Test @MainActor func localDestinationAnswersPathRequestWithPathResponse() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: identity)!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(dest)) { $0.localDestinations[dest.hash] = dest }
    let captured = LockIsolated<Data?>(nil)
    await store.send(.received(InterfaceID("in"), makePathRequest(for: dest.hash)))
    await store.receive { action in
        if case let .delegate(.transmit(ifID, raw)) = action, ifID == InterfaceID("in") {
            captured.setValue(raw); return true
        }
        return false
    }
    let resp = Packet(raw: captured.value!)!
    #expect(resp.packetType == .announce)
    #expect(resp.context == .pathResponse)
    #expect(resp.destinationHash == dest.hash)
    let parsed = Announce.parse(payload: resp.payload, destinationHash: resp.destinationHash,
                                contextFlagSet: resp.contextFlag)
    #expect(parsed?.identity.hash == identity.hash)
}

/// A PATH_REQUEST for a destination we do not own is not answered.
@Test @MainActor func pathRequestForNonLocalDestinationIsNotAnswered() async {
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    let unknown = Data(repeating: 0x77, count: 16)
    await store.send(.received(InterfaceID("in"), makePathRequest(for: unknown)))
    store.exhaustivity = .on          // no transmit is emitted
}

/// End-to-end: the responder's path-response announce is learned by a second (requester) Transport.
@Test @MainActor func pathResponseAnnounceIsLearnedByRequester() async {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"],
                           identity: identity)!
    // Owner produces a path-response announce.
    let owner = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1000))
    }
    owner.exhaustivity = .off
    await owner.send(.registerLocalDestination(dest)) { $0.localDestinations[dest.hash] = dest }
    let response = LockIsolated<Data?>(nil)
    await owner.send(.received(InterfaceID("in"), makePathRequest(for: dest.hash)))
    await owner.receive { action in
        if case let .delegate(.transmit(_, raw)) = action { response.setValue(raw); return true }
        return false
    }
    // Requester learns the path from that announce, like any announce.
    let requester = TestStore(initialState: Transport.State()) { Transport() }
    requester.exhaustivity = .off
    await requester.send(.received(InterfaceID("up"), response.value!))
    await requester.receive { if case .delegate(.pathLearned) = $0 { return true }; return false }
    #expect(requester.state.learned[dest.hash]?.identity.hash == identity.hash)
}
```

- [ ] **Step 7: Run the new tests**

Run: `swift test --filter TransportTests`
Expected: all pass.

- [ ] **Step 8: Mutation verification**

Apply and confirm the mapped test fails; verify independently if any pair interacts:
1. `.requestPath` sends to the wrong destination — change `destinationHash: Transport.pathRequestDestinationHash` to `destinationHash: destinationHash` → `requestPathBuildsBroadcastPathRequest` fails (`destinationHash != pathRequestDestinationHash`), and `localDestinationAnswersPathRequestWithPathResponse` still works (the helper builds its own request), so this isolates the requester.
2. Responder recognition removed — delete the `if packet.destinationHash == Transport.pathRequestDestinationHash { … }` block → `localDestinationAnswersPathRequestWithPathResponse` and `pathResponseAnnounceIsLearnedByRequester` fail (no response transmit).
3. Responder answers for non-local dests — change `guard let dest = state.localDestinations[requested]` to always answer (e.g. skip the guard using a dummy dest) — not cleanly mutatable; instead drop the `pathResponse: true` flag → `localDestinationAnswersPathRequestWithPathResponse` fails on `resp.context == .pathResponse`.

Run: `swift test --filter TransportTests`. Then revert all and re-run — expect all pass.

- [ ] **Step 9: Full suite**

Run: `swift test`
Expected: all pass (baseline 350 / 1 skip; +5 new → ~355 / 1 skip).

- [ ] **Step 10: Commit**

Write the message to `/tmp/ReTiCA/commit-t1.txt`, `git add` the two files, `git commit -F`.

```
feat: path requests — requester + local-destination responder

Add .requestPath(destinationHash:) which broadcasts a DATA PATH_REQUEST to the
well-known PLAIN rnstransport.path.request control destination (payload =
destHash [+ transport_id] + random tag), and responder recognition in the
inbound .data path: a node that owns the requested destination answers with a
pathResponse announce on the arrival interface. The requester learns the path
via existing announce-learning. Core untouched. RNS Transport.py:2799/2894/2939.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

### Task 2: Cross-validate the control hash + PATH_REQUEST slicing against RNS

**Files:**
- Modify: `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py`, `.../transport_fixtures.json` (regenerated), `.../TransportVectorFixtures.swift`, `.../TransportCrossValidationTests.swift`.

**Interfaces:**
- Consumes: `Transport.pathRequestDestinationHash` (from Task 1).

- [ ] **Step 1: Emit the control hash + a genuine PATH_REQUEST payload**

In `generate_transport_fixtures.py`, before the final `print(json.dumps(...))`, add (reusing the module-level `dest_hash` as a sample requested destination):

```python
# --- #4c-1 path request cross-validation ---
_pr_control_hash = RNS.Destination.hash(None, RNS.Transport.APP_NAME, "path", "request")
_pr_tag = RNS.Identity.get_random_hash()                  # 16-byte request tag (like request_path)
_pr_request_payload = dest_hash + _pr_tag                 # non-relay path_request_data
```

Add these keys to the `json.dumps({...})` dict:

```python
    "pr_control_hash": _pr_control_hash.hex(),
    "pr_requested_dest": dest_hash.hex(),
    "pr_request_payload": _pr_request_payload.hex(),
```

- [ ] **Step 2: Regenerate the fixture**

Run (single command, `>` redirect): `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py > /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json`
Confirm: `grep -c pr_control_hash /Users/ell/development/ios/pods/ReTiCA/Tests/ReTiCATransportTests/Vectors/transport_fixtures.json` → `1`.

- [ ] **Step 3: Decode the new fields**

In `TransportVectorFixtures.swift`, add properties and CodingKeys:

```swift
    let prControlHash: String
    let prRequestedDest: String
    let prRequestPayload: String
```
```swift
        case prControlHash = "pr_control_hash"
        case prRequestedDest = "pr_requested_dest"
        case prRequestPayload = "pr_request_payload"
```

- [ ] **Step 4: Add the cross-val test**

Append to `TransportCrossValidationTests.swift`:

```swift
/// Our path-request control-destination hash equals genuine RNS's, and our responder extracts the
/// correct requested destination from a genuine RNS PATH_REQUEST payload (data[:16]).
@Test func pathRequestControlHashAndSlicingMatchRns() throws {
    let f = try TransportVectorFixtures.load()
    #expect(Transport.pathRequestDestinationHash == Data(hexString: f.prControlHash)!)
    let payload = Data(hexString: f.prRequestPayload)!
    #expect(Data(payload.prefix(16)) == Data(hexString: f.prRequestedDest)!)   // our data[:16] slicing == RNS
}
```

- [ ] **Step 5: Run it, confirm pass**

Run: `swift test --filter pathRequestControlHashAndSlicingMatchRns`
Expected: pass. (If `pathRequestDestinationHash != prControlHash`, our PLAIN-hash derivation drifted from RNS — stop and reconcile; do not weaken the assertion.)

- [ ] **Step 6: Mutation verification**

Corrupt one hex digit of `pr_control_hash` in the JSON → run the test → the first `#expect` FAILS → regenerate the JSON to restore → pass. (The control-hash parity is the load-bearing, mutation-guarded assertion.)

- [ ] **Step 7: Full suite**

Run: `swift test`
Expected: all pass.

- [ ] **Step 8: Commit**

Write the message to `/tmp/ReTiCA/commit-t2.txt`; `git add` the generator, JSON, fixture struct, and cross-val test; `git commit -F`.

```
test: cross-validate path-request control hash + slicing against RNS

Read RNS's PLAIN control-destination hash (Destination.hash(None,
"rnstransport","path","request")) and a genuine PATH_REQUEST payload into the
transport fixture; assert pathRequestDestinationHash equals RNS's control hash
and that our data[:16] slicing extracts the requested destination. Pins the
wire-compat linchpin (a real RNS node must recognise our PATH_REQUEST dest).

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Notes for the executor

- After both tasks, the slice (#4c-1) is done. A final whole-slice review is warranted (new inbound-`.data` recognition + a new wire-visible control destination), then the full `swift test` gate on `main` and updating the `transport-relaying` memory (#4c-1 merged; #4c-2 relay-answers-from-cache + recursive, #4c-3 timing/dedup/throttle remain).
- Do NOT touch `Sources/ReTiCA/*`. The path-response announce carries `appData: nil` (Destination stores no app_data); path discovery only needs the identity/route — a deferrable refinement, not a gap.
