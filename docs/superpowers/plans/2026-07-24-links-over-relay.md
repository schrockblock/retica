# Transport Relaying 4b-2b: Links Over a Relay (minimal) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Establish and carry a bidirectional Reticulum LINK across ONE transport relay — the initiator's LINKREQUEST is forwarded to the responder, the relay records reverse-routing state (`linkTable`), the LRPROOF routes back, and established link traffic flows both ways by `link_id`. Wire-compatible with Python-RNS 1.3.8. Minimal robustness.

**Architecture:** `LinkSession` builds a HEADER_2 LINKREQUEST when a destination is via a relay (`Endpoint.openLink` threads the learned next-hop). `Transport` gains a `linkTable[link_id] = (rcvdIf, nhIf)`: a transport-id-addressed LINKREQUEST creates the entry + forwards toward the dest (reusing the 4b-2 forward rewrite); a `destType == .link` packet (LRPROOF + established traffic) with a known `link_id` is forwarded direction-aware. Responder/initiator link processing is unchanged. Core `Packet`/`Link` unchanged (`link_id` is header-independent, already matches RNS).

**Tech Stack:** Swift 6, The Composable Architecture (~1.26); the in-core `Packet` (HEADER_1/HEADER_2, `hops`), `Link.linkID`, `Identity`; wire cross-validation of `link_id` parity + a 3-node link E2E.

## Global Constraints

- **`link_id` parity:** `Link.linkID(requestPacket:)` is header-independent (hashablePart excludes header_type/transport_id) and byte-identical to RNS `link_id_from_lr_packet`. The relay derives the SAME `link_id` from the received LINKREQUEST that the endpoints use. Do NOT change `Link`/`Packet`.
- **Forwarding rewrite** reuses 4b-2: onward → keep HEADER_2, swap `transport_id = nextHop`, `contextFlag` preserved, `hops+1`; final hop → HEADER_1, `.broadcast`, `transport_id = nil`, `contextFlag = false`, `hops+1`; payload verbatim; hop-limit `Int(hops)+1 < Int(Packet.maxHops)`.
- **Link-packet forward** (`destType == .link`, `link_id ∈ linkTable`): direction-aware — arrived on `rcvdIf` → out `nhIf`; arrived on `nhIf` → out `rcvdIf`; `hops+1`; packet otherwise byte-identical (re-pack the parsed packet with `hops` incremented). Arrived on an unrelated interface → `.none`.
- **Relay-gated + opt-in:** `linkTable` entries are only created in relay mode (`transportIdentity != nil`); a leaf's `linkTable` stays empty, so a leaf's `destType == .link` handling is unchanged (existing `linkPacket` delegate). The initiator HEADER_2 LINKREQUEST applies to ALL nodes (a leaf can originate a link via a relay).
- **Two-layer purity:** changes in `ReTiCATransport` (`LinkSession`, `Transport`) + a thin `ReTiCANode`/`Endpoint` edit. `Sources/ReTiCA/*` (core `Packet`/`Link`/`Identity`) UNCHANGED.
- Build gotcha: signal-11/SIGILL during `swift test` → `swift package clean` then retry; never delete State fields to "fix".
- **Mutation-test discipline** for every new/changed test. **Commit directly to `main`.** Trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCATransport/LinkSession.swift` (**modify**, Task 1) — `relayNextHop` + HEADER_2 LINKREQUEST.
- `Sources/ReTiCANode/Endpoint.swift` (**modify**, Task 1) — thread learned next-hop into `openLink`.
- `Sources/ReTiCATransport/Transport.swift` (**modify**, Tasks 2 & 3) — `linkTable`, LINKREQUEST relay, link-packet relay.
- `Tests/ReTiCATransportTests/LinkSessionTests.swift` / `TransportTests.swift` / `Tests/ReTiCANodeTests/EndpointTests.swift` (**modify**, Tasks 1–4).
- `README.md` (**modify**, Task 4).

---

### Task 1: Initiator HEADER_2 LINKREQUEST (path-aware)

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift`, `Sources/ReTiCANode/Endpoint.swift`
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`, `Tests/ReTiCANodeTests/EndpointTests.swift`

**Interfaces:**
- Produces: `LinkSession.State.relayNextHop: Data?` (initiator init param); `.establish` emits HEADER_2 LINKREQUEST when set; `Endpoint.openLink` passes `learned[dest].nextHop` when the dest is via a relay.

- [ ] **Step 1: Add `relayNextHop` to the initiator**

In `LinkSession.swift`: add `public var relayNextHop: Data? = nil` to `State` (near `destinationIdentity`). Add a defaulted param to the initiator init (`initiatorTo:`), after `keepaliveInterval`:
```swift
        public init(id: UUID = UUID(), initiatorTo destinationIdentity: Identity, destinationHash: Data,
                    interfaceID: InterfaceID, ephemeral: Identity = Identity(),
                    establishmentTimeout: TimeInterval = 15, keepaliveInterval: TimeInterval = 30,
                    relayNextHop: Data? = nil) {
```
and set `self.relayNextHop = relayNextHop` in the body. (The responder init leaves it nil.)

- [ ] **Step 2: `.establish` builds HEADER_2 when relayed**

Replace the `.establish` packet construction (currently always HEADER_1):
```swift
            case .establish:
                guard state.role == .initiator, state.status == .pending, state.linkID.isEmpty
                else { return .none }
                let payload = state.ephemeral.publicKey + Link.signallingBytes
                let packet: Packet
                if let relay = state.relayNextHop {
                    // Destination is via a relay → HEADER_2 LINKREQUEST to the next hop.
                    packet = Packet(headerType: .header2, packetType: .linkRequest, transportType: .transport,
                                    destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: state.destinationHash, transportId: relay, payload: payload)
                } else {
                    packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                                    destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                    destinationHash: state.destinationHash, transportId: nil, payload: payload)
                }
                state.linkID = Link.linkID(requestPacket: packet)     // header-independent — same id either way
                state.requestedAt = date.now.timeIntervalSince1970
                guard let raw = try? packet.packed() else { return .none }
                let id = state.interfaceID
                return .merge(.send(.delegate(.transmit(id, raw))), establishmentTimer(state.establishmentTimeout))
```

- [ ] **Step 3: `Endpoint.openLink` threads the learned next-hop**

In `Endpoint.swift` `.openLink`:
```swift
            case let .openLink(destinationHash):
                guard let learned = state.transport.learned[destinationHash] else {
                    return .send(.delegate(.linkFailed(destinationHash: destinationHash)))
                }
                let newID = uuid()
                // Via a relay (learned nextHop != the destination) → HEADER_2 LINKREQUEST to the relay.
                let relayNextHop: Data? = learned.nextHop == destinationHash ? nil : learned.nextHop
                state.links.append(LinkSession.State(id: newID, initiatorTo: learned.identity,
                                                     destinationHash: destinationHash, interfaceID: id,
                                                     relayNextHop: relayNextHop))
                return .send(.link(.element(id: newID, action: .establish)))
```

- [ ] **Step 4: Write the tests**

Append to `Tests/ReTiCATransportTests/LinkSessionTests.swift`:
```swift
@Test @MainActor func initiatorViaRelayBuildsHeader2LinkRequest() async {
    let clock = TestClock<Duration>()
    let relay = Data(repeating: 0x5A, count: 16)
    var s = LinkSession.State(initiatorTo: Identity(), destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"), relayNextHop: relay)
    let store = TestStore(initialState: s) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock
    }
    store.exhaustivity = .off
    let captured = LockIsolated<Data?>(nil)
    await store.send(.establish)
    await store.receive { if case let .delegate(.transmit(_, raw)) = $0 { captured.setValue(raw) }; return false }
    let p = Packet(raw: captured.value!)!
    #expect(p.headerType == .header2)
    #expect(p.transportType == .transport)
    #expect(p.transportId == relay)
    #expect(p.packetType == .linkRequest)
    // link_id is header-independent: the id LinkSession stored == Link.linkID of the packet.
    #expect(store.state.linkID == Link.linkID(requestPacket: p))
    await clock.advance(by: .seconds(30))    // quiesce the establishment timer
}

@Test @MainActor func initiatorDirectBuildsHeader1LinkRequest() async {
    // relayNextHop == nil → HEADER_1 as before.
    ... build with relayNextHop: nil, assert p.headerType == .header1, p.transportId == nil ...
}
```
And an `Endpoint` wiring test: learn a destination via a relay (nextHop != destHash), `openLink`, assert the LINKREQUEST that reaches the interface is HEADER_2 with `transportId == the relay`. (Reuse the file's learn-a-path + openLink idioms.)

> Implementer note: reuse the file's real helpers (`epoch`, active/announce store builders). To make `Endpoint.openLink` produce a relay LINKREQUEST, seed `state.transport.learned[dest]` with `nextHop != dest` (drive a HEADER_2 announce, or seed learned). The REQUIRED assertions (do NOT weaken): via-relay → HEADER_2 LINKREQUEST with `transportId == nextHop`; direct → HEADER_1; `linkID` equals `Link.linkID` of the emitted packet (parity).

- [ ] **Step 5: Run + mutation sweep** — `swift test --filter LinkSession` and `--filter Endpoint` PASS (existing direct-link tests unchanged since `relayNextHop` defaults nil). Mutations: change `if let relay = state.relayNextHop` → `if false` (never HEADER_2) → `initiatorViaRelayBuildsHeader2LinkRequest` fails; change `transportId: relay` → `transportId: nil` → fails; in `openLink` change `learned.nextHop == destinationHash ? nil : learned.nextHop` → `nil` → the Endpoint wiring test fails.

- [ ] **Step 6: Commit** — `git add` the two sources + two test files; `git commit -F /tmp/ReTiCA/commit-4b2b-t1.txt` (first line: `feat: initiator builds HEADER_2 LINKREQUEST for a via-relay destination`).

---

### Task 2: Relay LINKREQUEST forward + `linkTable`

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift`
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: `Link.linkID(requestPacket:)`, `state.learned`, `state.transportIdentity`, the 4b-2 forward rewrite.
- Produces: `Transport.State.linkTable: [Data: LinkTableEntry]`; a transport-id-addressed remote LINKREQUEST creates a `linkTable` entry + forwards toward the dest.

- [ ] **Step 1: Add `linkTable` state + extract the forward helper**

In `Transport.swift`:
- Add to `State`: `public struct LinkTableEntry: Equatable, Sendable { public var rcvdIf: InterfaceID; public var nhIf: InterfaceID }` and `public var linkTable: [Data: LinkTableEntry] = [:]`.
- Extract the 4b-2 forward rewrite (currently inline in `.data`, lines ~129-148) into a nested helper in the `Reduce` closure, used by BOTH `.data` and the new `.linkRequest` case (DRY — no verbatim duplication):
```swift
            func forwardTowardDest(_ packet: Packet, _ entry: LearnedDestination) -> Data? {
                let fwd: Packet
                if entry.nextHop == packet.destinationHash {
                    fwd = Packet(headerType: .header1, packetType: packet.packetType, transportType: .broadcast,
                                 destinationType: packet.destinationType, context: packet.context,
                                 contextFlag: false, hops: packet.hops + 1,
                                 destinationHash: packet.destinationHash, transportId: nil, payload: packet.payload)
                } else {
                    fwd = Packet(headerType: .header2, packetType: packet.packetType, transportType: .transport,
                                 destinationType: packet.destinationType, context: packet.context,
                                 contextFlag: packet.contextFlag, hops: packet.hops + 1,
                                 destinationHash: packet.destinationHash, transportId: entry.nextHop,
                                 payload: packet.payload)
                }
                return try? fwd.packed()
            }
```
Refactor `case .data:` to call `forwardTowardDest(packet, entry)` in place of the inline `fwd`/`packed()` (behavior identical — a test in Step 4 confirms `.data` still forwards the same bytes).

- [ ] **Step 2: LINKREQUEST relay case**

Replace `default: return .none` in the packetType switch with a `.linkRequest` case + the default:
```swift
                case .linkRequest:
                    // Relay: a HEADER_2 LINKREQUEST naming us as next hop, for a REMOTE destination, is
                    // forwarded toward the dest and a link_table entry is recorded for reverse routing.
                    if let relayID = state.transportIdentity, packet.headerType == .header2,
                       packet.transportId == relayID.hash,
                       state.localDestinations[packet.destinationHash] == nil {
                        guard let entry = state.learned[packet.destinationHash],
                              Int(packet.hops) + 1 < Int(Packet.maxHops) else { return .none }
                        let linkID = Link.linkID(requestPacket: packet)
                        state.linkTable[linkID] = State.LinkTableEntry(rcvdIf: interfaceID, nhIf: entry.interfaceID)
                        guard let raw = forwardTowardDest(packet, entry) else { return .none }
                        return .send(.delegate(.transmit(entry.interfaceID, raw)))
                    }
                    return .none
                default:
                    return .none
```

- [ ] **Step 3: Write the tests**

Append to `TransportTests.swift`:
```swift
@Test @MainActor func relayForwardsLinkRequestAndRecordsLinkTable() async {
    // Relay knows dest D directly (nextHop == D). Inbound HEADER_2 LINKREQUEST, transport_id == R.
    let (store, relay, destHash, outIf) = await relayStoreKnowingDestDirectly()
    store.exhaustivity = .off
    let payload = Data(repeating: 0x11, count: 64) + Data([0x00, 0x00, 0x00])   // ephemeral(64) + signalling(3)
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("in"), lr))
    await store.receive { if case let .delegate(.transmit(i, r)) = $0 { captured.setValue((i, r)) }; return false }
    // A linkTable entry keyed by the LINKREQUEST's link_id, rcvdIf = arrival, nhIf = toward dest.
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    #expect(store.state.linkTable[linkID]?.rcvdIf == InterfaceID("in"))
    #expect(store.state.linkTable[linkID]?.nhIf == outIf)
    // Forwarded HEADER_1 LINKREQUEST toward the dest, on outIf.
    #expect(captured.value?.0 == outIf)
    let f = Packet(raw: captured.value!.1)!
    #expect(f.headerType == .header1)
    #expect(f.packetType == .linkRequest)
    #expect(f.destinationHash == destHash)
    #expect(Link.linkID(requestPacket: f) == linkID)     // same link_id after the rewrite
}

@Test @MainActor func dataForwardStillWorksAfterHelperExtraction() async {
    // Regression: the .data forward (refactored to forwardTowardDest) still produces the same bytes.
    ... reuse the existing relay data-forward test assertions (final-hop HEADER_1, hops+1, payload) ...
}
```

> Implementer note: `makeHeader2LinkRequestPacket` mirrors the file's `makeHeader2DataPacket` but with `packetType: .linkRequest` and the ephemeral+signalling payload shape. `relayStoreKnowingDestDirectly()` already exists (from 4b-2). REQUIRED: linkTable entry created with correct rcvdIf/nhIf keyed by `Link.linkID`; LINKREQUEST forwarded (final-hop HEADER_1) toward the dest with the same link_id; the `.data` regression test confirms the helper extraction didn't change data forwarding.

- [ ] **Step 4: Run + mutation sweep** — `swift test --filter Transport` PASS. Mutations: `state.linkTable[linkID] = …` removed → `relayForwardsLinkRequestAndRecordsLinkTable` fails (no entry); `rcvdIf: interfaceID` → `rcvdIf: entry.interfaceID` (both = wrong) → the rcvdIf assertion fails; the `.linkRequest` guard `transportId == relayID.hash` broken → verify a non-addressed LINKREQUEST isn't forwarded.

- [ ] **Step 5: Commit** — `git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift`; `git commit -F /tmp/ReTiCA/commit-4b2b-t2.txt` (first line: `feat: Transport relays LINKREQUEST + records link_table (reverse routing)`).

---

### Task 3: Relay link-packet + LRPROOF bidirectional forward

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift`
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`

**Interfaces:**
- Consumes: `state.linkTable`; the pre-dedup `destType == .link` branch.
- Produces: a `destType == .link` packet with `link_id ∈ linkTable` is forwarded direction-aware instead of surfacing `linkPacket`.

- [ ] **Step 1: Forward transited link packets**

Replace the `destType == .link` branch (pre-dedup):
```swift
                if packet.destinationType == .link {
                    // Relay: a transited link's packets (LRPROOF + established traffic) are forwarded
                    // direction-aware by link_id; a local link surfaces to the endpoint as today.
                    if let entry = state.linkTable[packet.destinationHash],
                       Int(packet.hops) + 1 < Int(Packet.maxHops) {
                        let outIf: InterfaceID
                        if interfaceID == entry.rcvdIf { outIf = entry.nhIf }        // toward dest
                        else if interfaceID == entry.nhIf { outIf = entry.rcvdIf }   // toward initiator
                        else { return .none }
                        var fwd = packet
                        fwd.hops = packet.hops + 1
                        guard let raw = try? fwd.packed() else { return .none }
                        return .send(.delegate(.transmit(outIf, raw)))
                    }
                    return .send(.delegate(.linkPacket(linkID: packet.destinationHash, data: data)))
                }
```
(`var fwd = packet; fwd.hops = packet.hops + 1` re-packs the parsed packet with `hops` incremented; all else — `destType == .link`, `destHash == link_id`, HEADER_1, payload — is byte-identical. A leaf's `linkTable` is empty, so a leaf still surfaces `linkPacket` unchanged.)

- [ ] **Step 2: Write the tests**

Append to `TransportTests.swift`. Seed a `linkTable` entry (via `relayForwardsLinkRequestAndRecordsLinkTable`'s setup, or seed state), then feed link packets from each side.
```swift
@Test @MainActor func relayForwardsLinkPacketTowardDest() async {
    // linkTable[link_id] = (rcvdIf: "ar", nhIf: "rb"). A link packet arriving on "ar" → forwarded out "rb".
    let (store, linkID) = await relayHostingLinkTableEntry(rcvdIf: "ar", nhIf: "rb")
    store.exhaustivity = .off
    let lp = makeLinkPacket(linkID: linkID, hops: 0, payload: Data([1, 2, 3]))
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.send(.received(InterfaceID("ar"), lp))
    await store.receive { if case let .delegate(.transmit(i, r)) = $0 { captured.setValue((i, r)) }; return false }
    #expect(captured.value?.0 == InterfaceID("rb"))
    let f = Packet(raw: captured.value!.1)!
    #expect(f.hops == 1)
    #expect(f.destinationType == .link)
    #expect(f.destinationHash == linkID)
    #expect(f.payload == Data([1, 2, 3]))
}

@Test @MainActor func relayForwardsLinkPacketTowardInitiator() async {
    // Same entry; a packet arriving on "rb" (nhIf) → forwarded out "ar" (rcvdIf).
    ... assert out "ar" ...
}

@Test @MainActor func unknownLinkIdSurfacesLinkPacketDelegate() async {
    // No linkTable entry (or leaf) → the existing linkPacket delegate is emitted (not forwarded).
    ...
}
```

> Implementer note: `relayHostingLinkTableEntry(rcvdIf:nhIf:)` builds a relay store whose `state.linkTable` has one entry (seed directly, or run the Task-2 LINKREQUEST flow and capture the `link_id`). `makeLinkPacket(linkID:hops:payload:)` builds a HEADER_1 `destType == .link` packet. REQUIRED (do NOT weaken): arrive-on-rcvdIf → out nhIf; arrive-on-nhIf → out rcvdIf; hops+1; payload verbatim; unknown link_id → `linkPacket` delegate (not forwarded). Also confirm the existing single-endpoint link tests (a `destType == .link` packet with no linkTable entry) still surface `linkPacket`.

- [ ] **Step 3: Run + mutation sweep** — `swift test --filter Transport` PASS. Mutations: swap `outIf = entry.nhIf` / `entry.rcvdIf` (invert direction) → `relayForwardsLinkPacketTowardDest` fails (wrong out interface); remove the `linkTable` lookup (always `linkPacket` delegate) → both forward tests fail; `fwd.hops = packet.hops + 1` → `packet.hops` → the `hops == 1` assertion fails.

- [ ] **Step 4: Commit** — `git add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/TransportTests.swift`; `git commit -F /tmp/ReTiCA/commit-4b2b-t3.txt` (first line: `feat: Transport relays established link packets bidirectionally by link_id`).

---

### Task 4: 3-node link E2E + link_id parity cross-val + gate + README

**Files:**
- Modify: `Tests/ReTiCANodeTests/EndpointTests.swift`, `Tests/ReTiCATransportTests/TransportTests.swift`
- Modify: `README.md`

- [ ] **Step 1: link_id parity cross-validation**

Append a test asserting the relay derives the SAME `link_id` the initiator and responder use (all three agree across HEADER_2/HEADER_1). Construct the initiator's HEADER_2 LINKREQUEST, feed it through the relay's forward (Task 2) to get the HEADER_1 forwarded LINKREQUEST, and assert `Link.linkID(initiatorHeader2) == Link.linkID(relayForwardedHeader1) == linkTable key`. (Genuine wire-compat check: `link_id` is header-independent and matches RNS `link_id_from_lr_packet`.)

- [ ] **Step 2: 3-node A—R—B link end-to-end**

Append to `EndpointTests.swift` the full multi-hop link E2E: A (Endpoint, interface "ar"), R (a relay `Transport` store with interfaces "ar"+"rb", `setTransportIdentity`), B (Endpoint, interface "rb"). Reuse the two-Endpoint link E2E (`twoEndpointsEstablishLinkExchangeDataAndClose`) + the 4b-2 3-node relay pump idioms, inserting R between A and B. Flow: B registers dest D + announces → R re-broadcasts → A learns D via R → A `.openLink(D)` → the HEADER_2 LINKREQUEST is relayed by R to B → B's responder LRPROOF is relayed back by R to A → both sides reach `linkEstablished` → A `.sendOverLink(msg)` → relayed to B → B surfaces `linkDataReceived` with the exact plaintext; and the reverse direction.

Required assertions (do NOT weaken): both A and B surface `linkEstablished(linkID:)` for the SAME `link_id`; A→B link data arrives at B with the exact bytes; B→A link data arrives at A with the exact bytes — proving the link established AND carries bidirectional traffic across the relay.

> Implementer note: this is the payoff integration. A and B are `Endpoint` stores; R is a bare relay `Transport` store (Endpoint is single-interface, so R must be a Transport with two interfaces). Hand-pump frames: A.Endpoint `interface(.send)` → R.Transport `.received("ar", …)`; R `transmit("rb", …)` → B.Endpoint interface; and symmetrically. Reuse the proven link-handshake pump + the 4b-2 relay frame relay. If, after genuinely building it, the full handshake pump proves intractable, deliver the link_id-parity + Task 1–3 unit coverage and report the E2E as BLOCKED with exactly where the handshake stalls (which packet/receive) — do NOT fake it. This E2E is the whole point of 4b-2b; make a real effort.

- [ ] **Step 3: Run + full gate** — `swift test --filter Endpoint` and `swift test --filter Transport` PASS; then `swift test` → report pass/skip.

- [ ] **Step 4: Mutation sweep (cross-cutting)** — invert the Task-3 direction (`entry.nhIf`↔`entry.rcvdIf`) → the 3-node E2E fails (link data misrouted / not delivered); revert. Confirm final full `swift test` green.

- [ ] **Step 5: Commit (tests)** — `git add` the two test files; `git commit -F /tmp/ReTiCA/commit-4b2b-t4a.txt` (first line: `test: link_id parity + 3-node link-over-relay end-to-end`).

- [ ] **Step 6: README** — document that a LINK now establishes and carries traffic across a relay: the initiator sends a HEADER_2 LINKREQUEST to the relay, the relay records a reverse-routing `link_table` keyed by `link_id` and forwards the LINKREQUEST/LRPROOF/established link packets bidirectionally, so links (and the resources/requests they carry) work multi-hop. Note the minimal-robustness deferrals (relay-side proof validation, per-hop timeout, link_table expiry, MTU, multi-relay) remain future work.

- [ ] **Step 7: Commit (README)** — `git add README.md`; `git commit -F /tmp/ReTiCA/commit-4b2b-t4b.txt` (first line: `docs: links over a relay (bidirectional)`).

---

## Self-Review

**Spec coverage:**
- Initiator HEADER_2 LINKREQUEST via `relayNextHop` + `openLink` threading → Task 1. ✓
- Relay `linkTable` + LINKREQUEST forward (link_id keyed, rcvdIf/nhIf) → Task 2. ✓
- Bidirectional link-packet + LRPROOF forward (direction-aware by arrival interface) → Task 3. ✓
- link_id parity cross-val + 3-node link E2E + gate + README → Task 4. ✓
- Forward rewrite reused from 4b-2 (DRY helper); leaf/local behavior unchanged; core untouched → Global Constraints. ✓
- Deferred (relay proof-validation, per-hop timeout, link_table expiry, MTU, shared-interface hop-matching, multi-relay) → untouched. ✓

**Placeholder scan:** No TBD/TODO in production steps. The test-helper notes (`makeHeader2LinkRequestPacket`, `relayHostingLinkTableEntry`, `makeLinkPacket`, the 3-node link pump) and the stubbed second-direction tests are explicit implementer guidance (reuse the file's real idioms, fill in the symmetric case) with the assertions locked — not missing implementation.

**Type consistency:** `LinkSession.State.relayNextHop: Data?` / `initiatorTo:…relayNextHop:`; `Transport.State.LinkTableEntry(rcvdIf:nhIf:)` / `linkTable[link_id]`; `Link.linkID(requestPacket:)` (header-independent); `forwardTowardDest(_:_:)` shared by `.data` + `.linkRequest`; the direction-aware `rcvdIf`/`nhIf` forwarding; and `Int(hops)+1 < Int(Packet.maxHops)` are used identically across tasks. The forward rewrite matches 4b-2 exactly (contextFlag false final / verbatim onward).
