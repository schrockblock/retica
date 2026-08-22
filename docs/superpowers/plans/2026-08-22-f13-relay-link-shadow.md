# F13 — Relay Link Shadow Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a reflected LINKREQUEST from making a relay forward its own link's traffic to the attacker, and harden the relay `linkTable` against GC-evasion — behavior-aligned with stock RNS.

**Architecture:** `Transport` owns the relay `linkTable`; our local links live in `LinkPlane`. Give `Transport` a `localLinkIDs` set so it never relays or shadows a link we're an endpoint of (Task 1), wire that set from the link lifecycle (Task 2), and add a reference-aligned validated/unvalidated split with a hard unvalidated proof-deadline and refresh-only-on-data to the `linkTable` (Task 3). No wire-format change.

**Tech Stack:** Swift, The Composable Architecture (TCA / swift-testing). Package: ReTiCA (`/Users/ell/development/ios/pods/ReTiCA`), targets `ReTiCATransport` and `ReTiCANode`.

## Global Constraints

- Repo: `/Users/ell/development/ios/pods/ReTiCA`. Edits in `Sources/ReTiCATransport` and `Sources/ReTiCANode` only. No wire-format change; no change to `Link.linkID` derivation. Do NOT add an `enableRelay` caller.
- Commit directly to `main`. No feature branch.
- Commit trailers must start at **column 0**. Every commit ends with exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
  ```
  Write the message to a file and use `git commit -F <file>`. Verify after: `git -C /Users/ell/development/ios/pods/ReTiCA log -1 --format='%(trailers:key=Claude-Session)'` must echo the trailer.
- **One command per shell invocation.** No `|`, `&&`, `||`, `;`, `$(...)`, or `xargs`. Redirect a single command's output to a file under /tmp/ReTiCA/ (create with one `mkdir -p`) and Read it back.
- Run tests: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter <TestName>` (single) or without `--filter` for the full suite (1007 tests + 1 known issue `holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`; ~50s). If you hit a spurious signal-11/signal-10 or a stale-link `LinkSessionRequestTests` failure, run `swift package clean --package-path /Users/ell/development/ios/pods/ReTiCA` once and retry — known incremental-build flake.
- **Mutation verification mandatory** per task (user's global rule): after green, apply the stated behavioral mutation, run the task's tests, confirm RED, revert, confirm GREEN — before committing.
- Relay behavior is gated on `transportIdentity != nil`; tests set it directly via `.setTransportIdentity(Identity())`, as existing relay tests do. Transport timer/GC tests use `TestClock`.

---

### Task 1: Transport core — never relay or shadow a local link

Add the `localLinkIDs` registry and the two guards. Fully testable within `Transport` by seeding the set with the `registerLocalLink` action; Task 2 wires it to the real link lifecycle.

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` — State field (near `:34`), Action cases (near `.setTransportIdentity`, `:200`), two handlers (near `:318`), link-packet routing guard (`:387-402`), LINKREQUEST relay guard (`:666-680`).
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`.

**Interfaces:**
- Consumes (existing): `Link.linkID(requestPacket: Packet) -> Data`; `state.linkTable: [Data: LinkTableEntry]`; the `.delegate(.transmit(...))` / `.delegate(.linkPacket(...))` delegate cases; test helpers `relayStoreKnowingDestDirectly()`, `relayHostingLinkTableEntry(rcvdIf:nhIf:)`, `makeHeader2LinkRequestPacket(transportId:destHash:hops:payload:)`, `makeLinkPacket(linkID:hops:payload:)`.
- Produces (used by Task 2): `Transport.Action.registerLocalLink(Data)` and `.unregisterLocalLink(Data)`; `Transport.State.localLinkIDs: Set<Data>`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
@Test @MainActor func reflectedLinkRequestForOurOwnLinkIsNotTabled() async {
    // A relay that has opened its OWN link (registered its linkID) must NOT create a relay
    // linkTable entry for a reflected HEADER_2 copy of that request — doing so shadows the link.
    let (store, relay, destHash, _) = await relayStoreKnowingDestDirectly()
    store.exhaustivity = .off
    let payload = Data(repeating: 0x11, count: 64) + Data([0x00, 0x00, 0x00])
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    // We are an endpoint of this link.
    await store.send(.registerLocalLink(linkID))
    // The attacker reflects our own request back to us as a relay request.
    await store.send(.received(InterfaceID("in"), lr))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkTable[linkID] == nil,
            "a reflection of our own LINKREQUEST must not be tabled as relay traffic")
    await store.finish()
}

@Test @MainActor func linkPacketForOurOwnLinkDeliversLocallyNotForwarded() async {
    // Even if a relay entry exists for a linkID we own, an inbound link packet for it must be
    // delivered locally (.linkPacket), never forwarded (.transmit).
    let (store, linkID) = await relayHostingLinkTableEntry(rcvdIf: "ar", nhIf: "rb")
    store.exhaustivity = .off
    await store.send(.registerLocalLink(linkID))
    let lp = makeLinkPacket(linkID: linkID, hops: 0, payload: Data([1, 2, 3]))
    let sawLocal = LockIsolated<Bool>(false)
    let sawForward = LockIsolated<Bool>(false)
    await store.send(.received(InterfaceID("ar"), lp))
    await store.receive { action in
        if case .delegate(.linkPacket) = action { sawLocal.setValue(true); return true }
        if case .delegate(.transmit) = action { sawForward.setValue(true); return true }
        return false
    }
    #expect(sawLocal.value == true, "our own link's packet must be delivered locally")
    #expect(sawForward.value == false, "our own link's packet must not be forwarded")
    await store.finish()
}

@Test @MainActor func genuineRelayStillTablesWhenLinkIsNotOurs() async {
    // A non-local linkID is still tabled and forwarded — the fix must not break real relaying.
    let (store, relay, destHash, outIf) = await relayStoreKnowingDestDirectly()
    store.exhaustivity = .off
    // Register some UNRELATED local link, to prove the guard keys on the specific linkID.
    await store.send(.registerLocalLink(Data(repeating: 0xAB, count: 16)))
    let payload = Data(repeating: 0x11, count: 64) + Data([0x00, 0x00, 0x00])
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    let forwarded = LockIsolated<Bool>(false)
    await store.send(.received(InterfaceID("in"), lr))
    await store.receive { action in
        if case .delegate(.transmit) = action { forwarded.setValue(true); return true }
        return false
    }
    #expect(store.state.linkTable[linkID]?.rcvdIf == InterfaceID("in"))
    #expect(store.state.linkTable[linkID]?.nhIf == outIf)
    #expect(forwarded.value == true)
    await store.finish()
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter reflectedLinkRequestForOurOwnLinkIsNotTabled`
Expected: FAILS to compile first (no `registerLocalLink` case) — that IS the red state; after Step 3's field/action exist but before the guards, it fails on the assertion (entry IS tabled). `genuineRelayStillTablesWhenLinkIsNotOurs` passes once it compiles (guards don't affect non-local). Run each new test by name.

- [ ] **Step 3: Add the state field**

In `Transport.State` (after the `linkTable` line, `Transport.swift:34`), add:
```swift
        /// LinkIDs of links we are an endpoint of (initiator or responder). A link we own is never
        /// relay traffic: Transport must not table a reflected LINKREQUEST that collides with our
        /// own linkID, nor forward our own link's packets. Kept in sync by LinkPlane via
        /// register/unregister (see TransportEndpoint wiring). Session-only.
        public var localLinkIDs: Set<Data> = []
```

- [ ] **Step 4: Add the actions**

In `Transport.Action` (after `case setTransportIdentity(Identity?)`, `Transport.swift:200`), add:
```swift
        case registerLocalLink(Data)
        case unregisterLocalLink(Data)
```

- [ ] **Step 5: Add the handlers**

In the `Reduce` switch (after the `.setRecursivePathRequests` handler, `Transport.swift:~324`), add:
```swift
        case let .registerLocalLink(linkID):
            state.localLinkIDs.insert(linkID)
            return .none

        case let .unregisterLocalLink(linkID):
            state.localLinkIDs.remove(linkID)
            return .none
```

- [ ] **Step 6: Guard the link-packet routing branch**

In `Transport.received`'s `if packet.destinationType == .link` block (`Transport.swift:387-402`), change the relay-forward condition so a local linkID never takes it. Replace:
```swift
    if let entry = state.linkTable[packet.destinationHash],
       Int(packet.hops) + 1 < Int(Packet.maxHops) {
```
with:
```swift
    // A link we are an endpoint of is never relay traffic — fall through to local delivery.
    // Without this, a reflected LINKREQUEST that tabled our own linkID would shadow us.
    if !state.localLinkIDs.contains(packet.destinationHash),
       let entry = state.linkTable[packet.destinationHash],
       Int(packet.hops) + 1 < Int(Packet.maxHops) {
```

- [ ] **Step 7: Guard the LINKREQUEST relay branch**

In the `case .linkRequest:` relay branch (`Transport.swift:666-680`), after `let linkID = Link.linkID(requestPacket: packet)` and before the `state.linkTable[linkID] = ...` assignment, insert:
```swift
        // A reflection of our OWN LINKREQUEST carries our own linkID (hashablePart excludes
        // header/transport fields), so it would otherwise table a shadow of our live link. Drop it.
        guard !state.localLinkIDs.contains(linkID) else { return .none }
```

- [ ] **Step 8: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter reflectedLinkRequestForOurOwnLinkIsNotTabled`
Then: `--filter linkPacketForOurOwnLinkDeliversLocallyNotForwarded` and `--filter genuineRelayStillTablesWhenLinkIsNotOurs`.
Expected: all PASS.

- [ ] **Step 9: Mutation-verify the guards are load-bearing**

Comment out the two guards added in Steps 6 and 7 (the `!state.localLinkIDs.contains(...)` clause in Step 6 and the whole `guard` line in Step 7).
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter reflectedLinkRequestForOurOwnLinkIsNotTabled` — Expected: FAIL.
Run: `--filter linkPacketForOurOwnLinkDeliversLocallyNotForwarded` — Expected: FAIL.
Revert both guards. Re-run both — Expected: PASS.

- [ ] **Step 10: Full suite regression + commit**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA` — Expected: all pass except the pre-existing known issue. Existing relay tests (`relayForwardsLinkRequestAndRecordsLinkTable`, `relayForwardsLinkPacketTowardDest`) must stay green (they never register a local link, so the guards don't fire).
Stage only `Sources/ReTiCATransport/Transport.swift` and `Tests/ReTiCATransportTests/TransportTests.swift`. Commit (message body below; trailers at column 0, via `-F`):
```
fix: F13 — Transport must not relay or shadow our own links

Transport owned the relay linkTable but had no knowledge of which linkIDs
are our own local links, and its relay lookup ran ahead of local delivery.
Because Link.linkID excludes header/transport fields, a reflected HEADER_2
copy of our own LINKREQUEST yields our own linkID and shadowed local
delivery. Add a localLinkIDs registry and skip relay entry-creation and
link-packet forwarding for any linkID we own.
```
Verify the trailer parses.

---

### Task 2: Wire register/unregister from the link lifecycle

Populate `Transport.localLinkIDs` from real links: register when a link's linkID is assigned (initiator establish, responder accept), unregister when `LinkPlane` removes the element (close or establishment failure).

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — add a `Delegate` case, emit at `:278` (establish) and after `state.linkID = linkID` in `.acceptRequest` (`:~344`).
- Modify: `Sources/ReTiCANode/LinkPlane.swift` — add two `Delegate` cases, handle the new LinkSession delegate, emit unregister at the two element-removal sites (`:342`, `:347`).
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift` — map the two new `LinkPlane` delegates to `Transport` actions (`:261-292`).
- Test: `Tests/ReTiCANodeTests/TransportEndpointTests.swift`.

**Interfaces:**
- Consumes: `Transport.Action.registerLocalLink(Data)` / `.unregisterLocalLink(Data)` (Task 1).
- Produces: `LinkSession.Delegate.linkIDAssigned(Data)`; `LinkPlane.Delegate.localLinkOpened(linkID: Data)` and `.localLinkClosed(linkID: Data)`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCANodeTests/TransportEndpointTests.swift` (uses the file's existing `makeTCP()` helper for a full Transport+LinkPlane stack):

```swift
@Test @MainActor func openingAnInitiatorLinkRegistersItsLinkIDWithTransport() async {
    let store = makeTCP()
    await store.send(.linkPlane(.openLink(initiatorTo: Identity(),
                                          destinationHash: Data(repeating: 0x02, count: 16),
                                          interfaceID: InterfaceID("tcp"), relayNextHop: nil)))
    await store.skipReceivedActions(strict: false)
    let linkID = store.state.linkPlane.links[0].linkID
    #expect(!linkID.isEmpty)
    #expect(store.state.transport.localLinkIDs.contains(linkID),
            "opening an initiator link must register its linkID with Transport")
    await store.finish()
}

@Test @MainActor func acceptingAResponderLinkRegistersItsLinkIDWithTransport() async {
    let store = makeTCP()
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    await store.send(.linkPlane(.acceptLinkRequest(owner: owner, destinationHash: dest.hash,
                                                   interfaceID: InterfaceID("tcp"), data: try! request.packed())))
    await store.skipReceivedActions(strict: false)
    let linkID = store.state.linkPlane.links[0].linkID
    #expect(!linkID.isEmpty)
    #expect(store.state.transport.localLinkIDs.contains(linkID),
            "accepting a responder link must register its linkID with Transport")
    await store.finish()
}

@Test @MainActor func aFailedInitiatorLinkUnregistersItsLinkID() async {
    // Drive an initiator link to establishment timeout; LinkPlane removes the element and must
    // unregister its linkID from Transport.
    let clock = TestClock()
    let store = TestStore(
        initialState: TransportEndpoint.State.tcp(
            TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) { TransportEndpoint() } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.linkPlane(.openLink(initiatorTo: Identity(),
                                          destinationHash: Data(repeating: 0x02, count: 16),
                                          interfaceID: InterfaceID("tcp"), relayNextHop: nil)))
    await store.skipReceivedActions(strict: false)
    let linkID = store.state.linkPlane.links[0].linkID
    #expect(store.state.transport.localLinkIDs.contains(linkID))
    // Establishment timeout is 15s; advance past it.
    await clock.advance(by: .seconds(16))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkPlane.links.isEmpty, "the link element is removed on timeout")
    #expect(!store.state.transport.localLinkIDs.contains(linkID),
            "a removed link must be unregistered from Transport")
    await store.finish()
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter openingAnInitiatorLinkRegistersItsLinkIDWithTransport`
Expected: FAIL — `localLinkIDs` stays empty (no wiring yet).

- [ ] **Step 3: Add and emit the LinkSession delegate**

In `LinkSession.swift`, add to the `Delegate` enum (`:175-196`, after `case established(...)`):
```swift
        /// This link's linkID is now assigned — register it so Transport treats it as local
        /// (never relays or shadows it). Emitted for both initiator (.establish) and responder
        /// (.acceptRequest).
        case linkIDAssigned(Data)
```
In `.establish`, immediately after `state.linkID = Link.linkID(requestPacket: packet)` (`:278`), emit the delegate. The handler currently returns effects including the transmit; add `.send(.delegate(.linkIDAssigned(state.linkID)))` to that returned `.merge(...)` (register must be applied at/before the LINKREQUEST transmit so no reflection can race ahead of it — put the linkIDAssigned send FIRST in the merge). 
In `.acceptRequest`, immediately after `state.linkID = linkID` (`:~344`, before status/proof), add `.send(.delegate(.linkIDAssigned(linkID)))` to that handler's returned effects (first in the merge).

- [ ] **Step 4: Forward + unregister in LinkPlane**

In `LinkPlane.swift`, add to the `Delegate` enum:
```swift
        /// A local link's linkID was assigned / released — Transport tracks these to avoid
        /// relaying or shadowing links we are an endpoint of.
        case localLinkOpened(linkID: Data)
        case localLinkClosed(linkID: Data)
```
Handle the new LinkSession delegate (add alongside the other `.link(.element(...))` cases, near `:336`):
```swift
        case let .link(.element(_, .delegate(.linkIDAssigned(linkID)))):
            return .send(.delegate(.localLinkOpened(linkID: linkID)))
```
At the `.closed` removal site (`:340-343`), also emit the unregister — replace the single return with:
```swift
            state.links.remove(id: elementID)
            return .merge(.send(.delegate(.linkClosed(linkID: linkID, reason: reason))),
                          .send(.delegate(.localLinkClosed(linkID: linkID))))
```
At the `.establishmentFailed` removal site (`:345-363`): capture the linkID before removal and emit unregister on BOTH the responder (`.none`) and initiator paths. Change the head of that case to:
```swift
        case let .link(.element(elementID, .delegate(.establishmentFailed(kind)))):
            guard let session = state.links[id: elementID] else { return .none }
            let releasedLinkID = session.linkID
            state.links.remove(id: elementID)
            let unregister = Effect<Action>.send(.delegate(.localLinkClosed(linkID: releasedLinkID)))
            guard session.role == .initiator else { return unregister }
```
and change the final `return .send(.delegate(.linkFailed(...)))` of that case to:
```swift
            return .merge(unregister, .send(.delegate(.linkFailed(destinationHash: session.destinationHash, reason: reason))))
```
(A responder that failed before assigning a linkID has `releasedLinkID` empty; `unregisterLocalLink` of an empty/absent id is a harmless no-op.)

- [ ] **Step 5: Map to Transport in TransportEndpoint**

In `TransportEndpoint.swift`, among the `.linkPlane(.delegate(...))` handlers (`:261-292`), add:
```swift
        case let .linkPlane(.delegate(.localLinkOpened(linkID))):
            return .send(.transport(.registerLocalLink(linkID)))
        case let .linkPlane(.delegate(.localLinkClosed(linkID))):
            return .send(.transport(.unregisterLocalLink(linkID)))
```

- [ ] **Step 6: Run the tests to verify they pass**

Run each new test by name (`openingAnInitiatorLinkRegistersItsLinkIDWithTransport`, `acceptingAResponderLinkRegistersItsLinkIDWithTransport`, `aFailedInitiatorLinkUnregistersItsLinkID`).
Expected: all PASS.

- [ ] **Step 7: Mutation-verify the wiring is load-bearing**

Comment out the `.localLinkOpened` mapping in TransportEndpoint (Step 5) → the two register tests FAIL. Restore it. Comment out the `unregister`/`localLinkClosed` emission at the `.establishmentFailed` site (Step 4) → `aFailedInitiatorLinkUnregistersItsLinkID` FAILS. Restore. Re-run all three → PASS.

- [ ] **Step 8: Full suite regression + commit**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA` — Expected: all pass except the known issue. Existing LinkPlane/LinkSession/TransportEndpoint tests must stay green (the new delegate is additive; existing tests use `.off` exhaustivity and ignore the extra `.linkIDAssigned`/`localLink*` actions).
Stage only the three source files and the test file. Commit:
```
fix: F13 — wire local-link registry from the link lifecycle

LinkSession reports its linkID on assignment (initiator establish and
responder accept); LinkPlane forwards it and, on element removal (close or
establishment failure), reports the release; TransportEndpoint maps both to
Transport.registerLocalLink/unregisterLocalLink. This populates the
localLinkIDs set the Task 1 guards consult.
```
Verify the trailer parses.

---

### Task 3: Table hardening — validated/unvalidated split (reference-aligned)

Give each relay `linkTable` entry a validation state so unvalidated junk is reaped at a hard deadline and can't be kept alive by replayed traffic — matching stock RNS.

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` — `LinkTableEntry` (`:165-175`), a new constant (near `:1115`), the LINKREQUEST relay creation (`:675-676`), the link-packet routing refresh (`:387-402`), the `maintenanceTick` GC (`:708-711`).
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`.

**Interfaces:**
- Consumes (existing): `LinkTableEntry`; `Transport.linkTableExpiry` (`= 900`); `LearnedDestination.hops`; `makeLinkPacket(...)`, `relayHostingLinkTableEntry(...)`, `relayStoreKnowingDestDirectly()`.
- Produces: `LinkTableEntry.validated: Bool`, `LinkTableEntry.proofDeadline: Date`; `Transport.establishmentTimeoutPerHop`.

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCATransportTests/TransportTests.swift`. Note `relayHostingLinkTableEntry` seeds an entry via the `LinkTableEntry` init; after Step 3 it defaults `validated: false`, `proofDeadline: epoch` — so to test the validated-rolling path, tests build entries explicitly.

```swift
// A relayed entry is created UNVALIDATED, and junk data traffic must not validate it. (The hard
// proofDeadline reaping is verified by the next test, which controls the clock; this harness pins
// date to epoch, so it asserts only creation state and the no-validate-on-junk property.)
@Test @MainActor func relayedLinkRequestCreatesUnvalidatedEntryAndJunkDoesNotValidateIt() async {
    let (store, relay, destHash, _) = await relayStoreKnowingDestDirectly()
    store.exhaustivity = .off
    let payload = Data(repeating: 0x11, count: 64) + Data([0x00, 0x00, 0x00])
    let lr = makeHeader2LinkRequestPacket(transportId: relay.hash, destHash: destHash, hops: 0, payload: payload)
    let linkID = Link.linkID(requestPacket: Packet(raw: lr)!)
    await store.send(.received(InterfaceID("in"), lr))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkTable[linkID] != nil)
    #expect(store.state.linkTable[linkID]?.validated == false, "a relayed entry starts unvalidated")
    // A junk data packet for the link must not flip validated (only an LRPROOF may).
    let junk = makeLinkPacket(linkID: linkID, hops: 0, payload: Data([9, 9, 9]))
    await store.send(.received(InterfaceID("in"), junk))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkTable[linkID]?.validated == false, "junk data must not validate an entry")
    await store.finish()
}

@Test @MainActor func maintenanceReapsUnvalidatedByDeadlineAndKeepsValidatedByRefresh() async {
    // Two entries in a controllable-clock store: one unvalidated past its deadline (reaped),
    // one validated and freshly refreshed (kept).
    let now = Date(timeIntervalSince1970: 100_000)
    var initial = Transport.State()
    initial.interfaces = [InterfaceID("a"): .default, InterfaceID("b"): .default]
    let staleUnvalidated = Data(repeating: 0x01, count: 16)
    let freshValidated = Data(repeating: 0x02, count: 16)
    initial.linkTable[staleUnvalidated] = Transport.State.LinkTableEntry(
        rcvdIf: InterfaceID("a"), nhIf: InterfaceID("b"),
        refreshedAt: now, validated: false,
        proofDeadline: Date(timeIntervalSince1970: 99_000))          // already past
    initial.linkTable[freshValidated] = Transport.State.LinkTableEntry(
        rcvdIf: InterfaceID("a"), nhIf: InterfaceID("b"),
        refreshedAt: now, validated: true,
        proofDeadline: Date(timeIntervalSince1970: 0))               // ignored for validated
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.date = .constant(now)
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.maintenanceTick)
    #expect(store.state.linkTable[staleUnvalidated] == nil, "unvalidated past deadline is reaped")
    #expect(store.state.linkTable[freshValidated] != nil, "validated + fresh survives")
    await store.finish()
}

@Test @MainActor func lrproofValidatesEntryWithoutRefreshingAndDataRefreshes() async {
    // Forwarding an LRPROOF marks the entry validated but does NOT bump refreshedAt; a data
    // packet DOES bump refreshedAt.
    let seededAt = Date(timeIntervalSince1970: 0)
    var initial = Transport.State()
    initial.interfaces = [InterfaceID("ar"): .default, InterfaceID("rb"): .default]
    let linkID = Data(repeating: 0xEE, count: 16)
    initial.linkTable[linkID] = Transport.State.LinkTableEntry(
        rcvdIf: InterfaceID("ar"), nhIf: InterfaceID("rb"),
        refreshedAt: seededAt, validated: false,
        proofDeadline: Date(timeIntervalSince1970: 1_000_000))
    let now = Date(timeIntervalSince1970: 500)
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.date = .constant(now)
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    // Forward an LRPROOF (packetType .proof, context .linkRequestProof) for the link.
    let proof = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                       destinationType: .link, context: .linkRequestProof, contextFlag: false, hops: 0,
                       destinationHash: linkID, transportId: nil, payload: Data(repeating: 0x1, count: 96))
    await store.send(.received(InterfaceID("ar"), try! proof.packed()))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkTable[linkID]?.validated == true, "LRPROOF validates the entry")
    #expect(store.state.linkTable[linkID]?.refreshedAt == seededAt, "LRPROOF must not refresh")
    // Now a data packet refreshes.
    let data = makeLinkPacket(linkID: linkID, hops: 0, payload: Data([1, 2, 3]))
    await store.send(.received(InterfaceID("ar"), data))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.linkTable[linkID]?.refreshedAt == now, "a data packet refreshes")
    await store.finish()
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter maintenanceReapsUnvalidatedByDeadlineAndKeepsValidatedByRefresh`
Expected: FAILS to compile (no `validated`/`proofDeadline` on `LinkTableEntry`) — the red state. After Step 3 compiles, the timing/validation tests fail on assertions until Steps 4-6.

- [ ] **Step 3: Extend `LinkTableEntry` and add the constant**

Replace the `LinkTableEntry` struct (`Transport.swift:165-175`) with:
```swift
    public struct LinkTableEntry: Equatable, Sendable {
        public var rcvdIf: InterfaceID
        public var nhIf: InterfaceID
        public var refreshedAt: Date
        /// True once a link proof (LRPROOF) has flowed through this relay for the link — RNS
        /// `IDX_LT_VALIDATED`. Validated entries roll on data traffic; unvalidated entries die at
        /// `proofDeadline` and cannot be kept alive by junk.
        public var validated: Bool
        /// Hard deadline for an unvalidated entry (RNS `IDX_LT_PROOF_TMO`). Ignored once validated.
        public var proofDeadline: Date
        public init(rcvdIf: InterfaceID, nhIf: InterfaceID,
                    refreshedAt: Date = Date(timeIntervalSince1970: 0),
                    validated: Bool = false,
                    proofDeadline: Date = Date(timeIntervalSince1970: 0)) {
            self.rcvdIf = rcvdIf
            self.nhIf = nhIf
            self.refreshedAt = refreshedAt
            self.validated = validated
            self.proofDeadline = proofDeadline
        }
    }
```
Near the `linkTableExpiry` constant (`Transport.swift:1115`), add:
```swift
    /// RNS ESTABLISHMENT_TIMEOUT_PER_HOP (Link.py). An unvalidated relay entry gets a hard deadline
    /// of now + this * max(1, hops-to-dest); if no proof flows through by then it is reaped, so junk
    /// LINKREQUESTs cannot accumulate.
    static let establishmentTimeoutPerHop: TimeInterval = 6
```

- [ ] **Step 4: Set validation state on creation**

In the LINKREQUEST relay branch (`Transport.swift:675-676`), replace the entry creation with:
```swift
        state.linkTable[linkID] = State.LinkTableEntry(
            rcvdIf: interfaceID, nhIf: entry.interfaceID, refreshedAt: date.now,
            validated: false,
            proofDeadline: date.now.addingTimeInterval(
                Self.establishmentTimeoutPerHop * Double(max(1, entry.hops))))
```
(`entry` is the `state.learned[packet.destinationHash]` value already bound in this branch; `entry.hops` is the hop count to the destination.)

- [ ] **Step 5: Validate on LRPROOF, refresh only on data**

In the link-packet routing branch (`Transport.swift:387-402`), replace the unconditional refresh line
`state.linkTable[packet.destinationHash]?.refreshedAt = date.now   // keep active links alive`
with:
```swift
        // Reference refresh semantics: a link proof VALIDATES the entry (but does not refresh its
        // timestamp); only forwarded DATA refreshes. Never refresh on proof/other, so junk cannot
        // keep an unvalidated entry alive.
        if packet.packetType == .proof, packet.context == .linkRequestProof {
            state.linkTable[packet.destinationHash]?.validated = true
        } else if packet.packetType == .data {
            state.linkTable[packet.destinationHash]?.refreshedAt = date.now
        }
```

- [ ] **Step 6: Two-path GC in `maintenanceTick`**

In `maintenanceTick` (`Transport.swift:708-711`), replace the `linkTable` sweep:
```swift
    for (link, entry) in state.linkTable
    where now.timeIntervalSince(entry.refreshedAt) > Transport.linkTableExpiry {
        state.linkTable[link] = nil
    }
```
with:
```swift
    for (link, entry) in state.linkTable {
        let expired = entry.validated
            ? now.timeIntervalSince(entry.refreshedAt) > Transport.linkTableExpiry
            : now > entry.proofDeadline
        if expired { state.linkTable[link] = nil }
    }
```

- [ ] **Step 7: Run the tests to verify they pass**

Run each new test by name. Expected: all PASS.

- [ ] **Step 8: Mutation-verify**

(a) In Step 6, force the validated branch condition for all entries (change `entry.validated ?` to `true ?`) → `maintenanceReapsUnvalidatedByDeadlineAndKeepsValidatedByRefresh` FAILS (the unvalidated stale entry, refreshed at `now`, would survive). Revert.
(b) In Step 5, change `packet.packetType == .data` refresh to also run on proof (drop the `else`, refresh unconditionally) → `lrproofValidatesEntryWithoutRefreshingAndDataRefreshes` FAILS (LRPROOF would bump refreshedAt). Revert.
Re-run both tests → PASS.

- [ ] **Step 9: Full suite regression + commit**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA` — Expected: all pass except the known issue. Existing relay tests that build a `LinkTableEntry` via the defaulted init still compile (new params default) and stay green.
Stage only `Sources/ReTiCATransport/Transport.swift` and `Tests/ReTiCATransportTests/TransportTests.swift`. Commit:
```
fix: F13 — reference-aligned validated/unvalidated relay linkTable

A relay linkTable entry starts unvalidated with a hard proof-deadline
(RNS IDX_LT_PROOF_TMO), becomes validated only when an LRPROOF flows
through, and is refreshed only by forwarded data packets. Unvalidated junk
is reaped at the deadline and cannot be kept alive by replayed packets.
No count cap, matching stock RNS.
```
Verify the trailer parses.

---

## Notes for the executor

- **No `enableRelay` caller / no wire change** — if a step seems to want either, stop; it does not.
- **Accepted limitation (do not "fix"):** no count cap on `linkTable`; a determined attacker can still accumulate *validated*-junk entries, exactly as stock RNS allows. This is deliberate (see the spec's "Accepted limitations").
- **`.off` exhaustivity throughout** — the link/relay effects arm timers; an `.off` store tolerates in-flight timers at `store.finish()`. Do not flip to `.on`.
- If a `LinkTableEntry` `Equatable` comparison in an unrelated existing test breaks because of the new fields, that test compared whole entries — update its expected entry to include `validated`/`proofDeadline`, do not weaken the new fields.
