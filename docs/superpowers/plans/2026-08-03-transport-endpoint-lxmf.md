# TransportEndpoint / LXMF over TCP or BLE Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `LXMFNode` transport-agnostic so full LXMF (opportunistic + direct + propagation) runs over TCP **or** BLE, via a concrete `TransportEndpoint` sum-type reducer — no generics.

**Architecture:** Four stages. (0) Rename `Endpoint` → `TCPEndpoint` so names match `BLEEndpoint`. (1) Add `TransportEndpoint`: an enum-state reducer with `.tcp`/`.ble` cases exposing ONE unified action/delegate surface plus `learned`/`links`/`registrations` state passthroughs. (2) `LXMFNode` composes `TransportEndpoint` instead of the TCP endpoint. (3) Prove LXMF works over BLE end to end.

**Tech Stack:** Swift 6, ComposableArchitecture (TCA), Swift Testing (`@Test`/`#expect`), `ReTiCA` / `ReTiCATransport` / `ReTiCAInterfaces` / `ReTiCANode`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-03-transport-endpoint-lxmf-design.md`.
- **Do NOT modify** `LXMFRouter.swift` (already transport-agnostic), `LinkPlane.swift`, `LinkSession.swift`, `BLEInterface.swift`, `FCBDriverAdapter.swift`, `Transport.swift`, or anything under `Sources/ReTiCA/LXMF`. `PNNode`/`PropagationNode` are touched ONLY by Task 1's mechanical rename.
- The user may commit unrelated LXMF/core work to `main` concurrently. Use `<commit>^` when reasoning about your own diff, never a pre-recorded base. Full-suite failures ONLY in files you did not touch are the user's WIP — report as an observation, do not fix.
- **The rename trap (Task 1):** `BLEEndpoint` must NOT become `BLETCPEndpoint`. Verified safe: the regex `\bEndpoint\b` has ZERO matches in `BLEEndpoint.swift` / `BLEEndpointTests.swift` / `BLEEndpointIntegrationTests.swift` / `BLEEndpointLinkTests.swift` (no word boundary between `BLE` and `Endpoint`). Use word-boundary-aware replacement only. Also: `Sources/ReTiCA/LXMF/LXMFPropagation.swift:8` contains the prose "Transport/Endpoint boundary" in a doc comment — **leave it alone** (different module, prose, user's area).
- Exact upstream signatures (verified — use verbatim):
  - `TCPEndpoint` (post-rename) public actions: `.interface(TCPClientInterface.Action)`, `.transport(Transport.Action)`, `.link(IdentifiedActionOf<LinkSession>)`, `.linkPlane(LinkPlane.Action)`, `.connect`, `.disconnect`, `.registerLocalDestination(Destination)`, `.announce(destinationHash: Data, appData: Data?)`, `.send(destinationHash: Data, plaintext: Data)`, `.enableRelay(Identity)`, `.openLink(destinationHash: Data)`, `.requestPath(destinationHash: Data)`, `.sendOverLink(linkID: Data, data: Data)`, `.sendResourceOverLink(linkID: Data, data: Data)`, `.closeLink(linkID: Data)`, `.identifyOverLink(linkID: Data, identity: Identity)`, `.sendRequestOverLink(linkID: Data, path: String, data: Data)`, `.sendResponseOverLink(linkID: Data, requestID: Data, data: Data)`, `.sendWithReceiptOverLink(linkID: Data, data: Data, token: Data)`, `.registerRequestHandler(path: String, policy: RequestPolicy)`, `.deregisterRequestHandler(path: String)`, `.delegate(Delegate)`. Init: `TCPEndpoint.State(host: String, port: UInt16, reconnectOnDrop: Bool = true, interfaceID: InterfaceID = InterfaceID("tcp"))`. State has `transport`, `linkPlane`, computed `links`/`registrations`, `interfaceID`.
  - `BLEEndpoint` public actions: identical to the above EXCEPT `.ble(BLEInterface.Action)` instead of `.interface(...)`, `.start`/`.stop` instead of `.connect`/`.disconnect`, and NO `.link(...)` case. Init: `BLEEndpoint.State(maxPeers: Int = BLEInterface.defaultMaxPeers, pairingMode: BLEPairingMode = .open)`. State has `ble`, `transport`, `linkPlane`, `peerInterfaces`, computed `links`/`registrations`.
  - **The 16 shared delegates** (identical shapes on both): `messageReceived(destinationHash: Data, plaintext: Data)`, `pathLearned(destinationHash: Data, hops: UInt8)`, `sendFailed(destinationHash: Data, reason: Transport.SendFailure)`, `linkEstablished(linkID: Data, destinationHash: Data)`, `linkDataReceived(linkID: Data, data: Data)`, `linkClosed(linkID: Data, reason: LinkSession.CloseReason)`, `linkFailed(destinationHash: Data)`, `resourceReceived(linkID: Data, data: Data)`, `resourceConcluded(linkID: Data, resourceHash: Data)`, `resourceFailed(linkID: Data, resourceHash: Data)`, `linkIdentified(linkID: Data, remoteIdentity: Identity)`, `requestReceived(linkID: Data, requestID: Data, pathHash: Data, data: Data)`, `responseReceived(linkID: Data, requestID: Data, data: Data)`, `requestFailed(linkID: Data, requestID: Data)`, `packetDelivered(token: Data)`, `packetDeliveryFailed(token: Data)`. BLE additionally has `peerOnline(Data)` / `peerOffline(Data)` — deliberately NOT on the unified surface.
  - `Transport.State.learned: [Data: LearnedDestination]`; `LearnedDestination` has `.identity`, `.appData`, `.interfaceID`, `.hops`, `.nextHop`.
- TCA discipline: `store.exhaustivity = .off`; assert outcomes. Mutation verification mandatory for every test-bearing task: (a) tests pass; (b) apply the listed mutations in one batch, run, named tests FAIL; (c) revert, run, pass. Commit only after (c) is green.
- Never chain shell commands (no `&&`, `|`, `;`, `$(...)`, xargs, inline interpreter scripts). One command per Bash invocation. Commit messages via a file under `/tmp/ReTiCA/` (Write tool) + `git commit -F <file>`. Every message ends with these two trailer lines at column 0 (no indent), exactly:

```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```

Verify after committing: `git log -1 --format='%(trailers:key=Claude-Session)'` prints the line.
- Test iteration: `swift test --filter <SuiteOrTestName>`. Run full `swift test` before each commit.

---

### Task 1: Rename `Endpoint` → `TCPEndpoint`

**Files:**
- Rename: `Sources/ReTiCANode/Endpoint.swift` → `Sources/ReTiCANode/TCPEndpoint.swift`
- Rename: `Tests/ReTiCANodeTests/EndpointTests.swift` → `Tests/ReTiCANodeTests/TCPEndpointTests.swift`
- Modify (references only): `Sources/ReTiCANode/LXMFNode.swift`, `Sources/ReTiCANode/PNNode.swift`, and every test file that references the bare type.

**Interfaces:**
- Consumes: nothing.
- Produces (used by Tasks 2–4): the type `TCPEndpoint` with `TCPEndpoint.State` / `TCPEndpoint.Action`, otherwise byte-identical behavior.

**SUCCESS CRITERION: the entire test suite passes unchanged.** This is a pure rename — no behavior change, no signature change beyond the type's name.

- [ ] **Step 1: Find every bare reference**

Run: `grep -rn "\bEndpoint\b" Sources/ReTiCANode Tests/ReTiCANodeTests`
Expected: matches in `Endpoint.swift`, `LXMFNode.swift`, `PNNode.swift`, `LXMFRouter.swift`, `PropagationNode.swift` (doc comments), `EndpointTests.swift`, `LiveEndpointTests.swift`, and the `LXMF*`/`PN*` test files. **Zero matches** in any `BLEEndpoint*` file — confirm this before proceeding; if a `BLEEndpoint*` file matches, STOP and report (the boundary assumption is wrong).

- [ ] **Step 2: Rename the type across those files**

Replace the whole-word token `Endpoint` with `TCPEndpoint` in the files from Step 1. Use word-boundary matching so `BLEEndpoint` is never touched. Do NOT touch `Sources/ReTiCA/LXMF/LXMFPropagation.swift` (its "Transport/Endpoint" mention is prose in another module).

Notes:
- `LiveEndpointTests.swift` keeps its FILE name (it describes live-network endpoint tests); only its `Endpoint` type references change.
- Doc comments mentioning `Endpoint` as the type (e.g. `LXMFNode.swift:7` "Composes `Endpoint` + `LXMFRouter`") should become `TCPEndpoint` too.
- Lowercase identifiers (`endpoint`, `endpointWithActiveLink`) are NOT affected by whole-word `Endpoint`.

- [ ] **Step 3: Rename the two files**

```bash
git mv Sources/ReTiCANode/Endpoint.swift Sources/ReTiCANode/TCPEndpoint.swift
```

then, as a separate command:

```bash
git mv Tests/ReTiCANodeTests/EndpointTests.swift Tests/ReTiCANodeTests/TCPEndpointTests.swift
```

- [ ] **Step 4: Build and run the full suite**

Run: `swift build`
Expected: clean.
Run: `swift test`
Expected: the ENTIRE suite passes, same count as before the rename. Any failure means the rename was not mechanical — fix it, do not adjust tests' logic.

- [ ] **Step 5: Verify nothing was over-renamed**

Run: `grep -rn "BLETCPEndpoint\|TCPBLEEndpoint" Sources Tests`
Expected: NO output (if there is any, a `BLEEndpoint` got corrupted — fix immediately).
Run: `grep -rn "\bEndpoint\b" Sources/ReTiCANode Tests/ReTiCANodeTests`
Expected: NO output (every bare reference is now `TCPEndpoint`).

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task1-msg.txt` (subject `refactor: rename Endpoint to TCPEndpoint to match BLEEndpoint`), then:

```bash
git add -A Sources/ReTiCANode Tests/ReTiCANodeTests
git commit -F /tmp/ReTiCA/task1-msg.txt
```

---

### Task 2: `TransportEndpoint` sum-type reducer

**Files:**
- Create: `Sources/ReTiCANode/TransportEndpoint.swift`
- Test: `Tests/ReTiCANodeTests/TransportEndpointTests.swift`

**Interfaces:**
- Consumes: `TCPEndpoint` (Task 1), `BLEEndpoint`, `LearnedDestination`, `LinkSession`, `RequestRegistration`, `RequestPolicy`, `Destination`, `Identity`, `Transport.SendFailure`.
- Produces (used by Tasks 3–4): `TransportEndpoint` reducer; `TransportEndpoint.State` (enum: `.tcp(TCPEndpoint.State)` / `.ble(BLEEndpoint.State)`) with computed `learned`, `links`, `registrations`; `TransportEndpoint.Action` with `.tcp`, `.ble`, `.start`, `.stop`, the 15 shared verbs, and `.delegate(TransportEndpoint.Action.Delegate)` carrying the 16 shared delegates.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/TransportEndpointTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

@MainActor
private func makeTCP() -> TestStore<TransportEndpoint.State, TransportEndpoint.Action> {
    let store = TestStore(
        initialState: TransportEndpoint.State.tcp(
            TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

@MainActor
private func makeBLE() -> TestStore<TransportEndpoint.State, TransportEndpoint.Action> {
    let store = TestStore(initialState: TransportEndpoint.State.ble(BLEEndpoint.State())) {
        TransportEndpoint()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.bleDriver = BLEDriver(
            start: { _ in AsyncStream { $0.finish() } },
            readDirectory: { _ in }, openChannel: { _, _ in },
            send: { _, _ in }, closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func startAndStopMapToEachTransportsLifecycle() async {
    let tcp = makeTCP()
    await tcp.send(.start)
    await tcp.receive(.tcp(.connect))
    await tcp.send(.stop)
    await tcp.receive(.tcp(.disconnect))

    let ble = makeBLE()
    await ble.send(.start)
    await ble.receive(.ble(.start))
    await ble.send(.stop)
    await ble.receive(.ble(.stop))
}

@Test @MainActor func sharedVerbsReachTheActiveChildOnBothTransports() async {
    let dest = Data(repeating: 0x11, count: 16)
    let plaintext = Data("hi".utf8)

    let tcp = makeTCP()
    await tcp.send(.send(destinationHash: dest, plaintext: plaintext))
    await tcp.receive(.tcp(.send(destinationHash: dest, plaintext: plaintext)))
    await tcp.send(.requestPath(destinationHash: dest))
    await tcp.receive(.tcp(.requestPath(destinationHash: dest)))
    await tcp.send(.sendOverLink(linkID: dest, data: plaintext))
    await tcp.receive(.tcp(.sendOverLink(linkID: dest, data: plaintext)))

    let ble = makeBLE()
    await ble.send(.send(destinationHash: dest, plaintext: plaintext))
    await ble.receive(.ble(.send(destinationHash: dest, plaintext: plaintext)))
    await ble.send(.requestPath(destinationHash: dest))
    await ble.receive(.ble(.requestPath(destinationHash: dest)))
    await ble.send(.sendOverLink(linkID: dest, data: plaintext))
    await ble.receive(.ble(.sendOverLink(linkID: dest, data: plaintext)))
}

@Test @MainActor func childDelegatesSurfaceAsUnifiedDelegates() async {
    let h = Data(repeating: 0x22, count: 16)

    let tcp = makeTCP()
    await tcp.send(.tcp(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x01])))))
    await tcp.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x01]))))
    await tcp.send(.tcp(.delegate(.pathLearned(destinationHash: h, hops: 2))))
    await tcp.receive(.delegate(.pathLearned(destinationHash: h, hops: 2)))
    await tcp.send(.tcp(.delegate(.linkEstablished(linkID: h, destinationHash: h))))
    await tcp.receive(.delegate(.linkEstablished(linkID: h, destinationHash: h)))

    let ble = makeBLE()
    await ble.send(.ble(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x02])))))
    await ble.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x02]))))
    await ble.send(.ble(.delegate(.resourceConcluded(linkID: h, resourceHash: h))))
    await ble.receive(.delegate(.resourceConcluded(linkID: h, resourceHash: h)))
}

@Test @MainActor func bleOnlyDelegatesDoNotSurfaceOnTheUnifiedSurface() async {
    let ble = makeBLE()
    let token = Data(repeating: 0xC7, count: 16)
    // peerOnline/peerOffline are BLE-specific; they must NOT map to a unified delegate.
    await ble.send(.ble(.delegate(.peerOnline(token))))
    await ble.send(.ble(.delegate(.peerOffline(token))))
    await ble.finish()
}

@Test @MainActor func stateReadsPassThroughToTheActiveCase() async {
    // learned: seed each child's transport table and read it transport-agnostically.
    let dest = Data(repeating: 0x33, count: 16)
    let identity = Identity()
    let learned = LearnedDestination(identity: identity, hops: 1,
                                     interfaceID: InterfaceID("tcp"), nextHop: dest,
                                     appData: Data("meta".utf8))

    var tcpState = TCPEndpoint.State(host: "h", port: 1, reconnectOnDrop: false)
    tcpState.transport.learned[dest] = learned
    let tcpWrapped = TransportEndpoint.State.tcp(tcpState)
    #expect(tcpWrapped.learned[dest]?.identity.hash == identity.hash)
    #expect(tcpWrapped.learned[dest]?.appData == Data("meta".utf8))
    #expect(tcpWrapped.links.isEmpty)
    #expect(tcpWrapped.registrations.isEmpty)

    var bleState = BLEEndpoint.State()
    bleState.transport.learned[dest] = learned
    let bleWrapped = TransportEndpoint.State.ble(bleState)
    #expect(bleWrapped.learned[dest]?.identity.hash == identity.hash)
    #expect(bleWrapped.links.isEmpty)
    #expect(bleWrapped.registrations.isEmpty)
}
```

**If `LearnedDestination`'s memberwise init differs from the call above,** read `Sources/ReTiCATransport/LearnedDestination.swift` and use its real init; document the adjustment.

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter TransportEndpointTests`
Expected: compile FAILURE (`TransportEndpoint` not defined).

- [ ] **Step 3: Write `TransportEndpoint.swift`**

Create `Sources/ReTiCANode/TransportEndpoint.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCAInterfaces
import ReTiCATransport

/// A Reticulum endpoint over one concrete transport. Presents ONE unified action/delegate
/// surface so compositions above it (`LXMFNode`) stay transport-agnostic: the same
/// `.send`/`.openLink`/`.sendRequestOverLink`… reach whichever endpoint is active, and both
/// endpoints' delegates surface under the same names.
///
/// Transport-specific driving stays available through the `.tcp` / `.ble` escape hatches —
/// which is also where BLE-only delegates (`peerOnline`/`peerOffline`) remain observable; they
/// are deliberately absent from the unified surface because LXMF has no use for them.
@Reducer
public struct TransportEndpoint {
    @ObservableState
    public enum State: Equatable {
        case tcp(TCPEndpoint.State)
        case ble(BLEEndpoint.State)

        /// Learned-destination table of the active transport (identity / appData / path).
        public var learned: [Data: LearnedDestination] {
            switch self {
            case let .tcp(s): return s.transport.learned
            case let .ble(s): return s.transport.learned
            }
        }

        /// Live links of the active transport.
        public var links: IdentifiedArrayOf<LinkSession.State> {
            switch self {
            case let .tcp(s): return s.links
            case let .ble(s): return s.links
            }
        }

        /// Request-handler registrations of the active transport.
        public var registrations: [Data: RequestRegistration] {
            switch self {
            case let .tcp(s): return s.registrations
            case let .ble(s): return s.registrations
            }
        }
    }

    public enum Action: Equatable {
        case tcp(TCPEndpoint.Action)
        case ble(BLEEndpoint.Action)

        case start
        case stop
        case registerLocalDestination(Destination)
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case enableRelay(Identity)
        case requestPath(destinationHash: Data)
        case openLink(destinationHash: Data)
        case sendOverLink(linkID: Data, data: Data)
        case sendResourceOverLink(linkID: Data, data: Data)
        case identifyOverLink(linkID: Data, identity: Identity)
        case sendRequestOverLink(linkID: Data, path: String, data: Data)
        case sendResponseOverLink(linkID: Data, requestID: Data, data: Data)
        case sendWithReceiptOverLink(linkID: Data, data: Data, token: Data)
        case closeLink(linkID: Data)
        case registerRequestHandler(path: String, policy: RequestPolicy)
        case deregisterRequestHandler(path: String)

        case delegate(Delegate)
        @CasePathable
        public enum Delegate: Equatable {
            case messageReceived(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: Transport.SendFailure)
            case linkEstablished(linkID: Data, destinationHash: Data)
            case linkDataReceived(linkID: Data, data: Data)
            case linkClosed(linkID: Data, reason: LinkSession.CloseReason)
            case linkFailed(destinationHash: Data)
            case resourceReceived(linkID: Data, data: Data)
            case resourceConcluded(linkID: Data, resourceHash: Data)
            case resourceFailed(linkID: Data, resourceHash: Data)
            case linkIdentified(linkID: Data, remoteIdentity: Identity)
            case requestReceived(linkID: Data, requestID: Data, pathHash: Data, data: Data)
            case responseReceived(linkID: Data, requestID: Data, data: Data)
            case requestFailed(linkID: Data, requestID: Data)
            case packetDelivered(token: Data)
            case packetDeliveryFailed(token: Data)
        }
    }

    public init() {}

    public var body: some ReducerOf<Self> {
        Scope(state: \.tcp, action: \.tcp) { TCPEndpoint() }
        Scope(state: \.ble, action: \.ble) { BLEEndpoint() }
        Reduce { state, action in
            switch action {
            // --- unified → the active transport ---
            case .start:
                return route(state, tcp: .connect, ble: .start)
            case .stop:
                return route(state, tcp: .disconnect, ble: .stop)
            case let .registerLocalDestination(d):
                return route(state, tcp: .registerLocalDestination(d), ble: .registerLocalDestination(d))
            case let .announce(h, a):
                return route(state, tcp: .announce(destinationHash: h, appData: a),
                                    ble: .announce(destinationHash: h, appData: a))
            case let .send(h, p):
                return route(state, tcp: .send(destinationHash: h, plaintext: p),
                                    ble: .send(destinationHash: h, plaintext: p))
            case let .enableRelay(i):
                return route(state, tcp: .enableRelay(i), ble: .enableRelay(i))
            case let .requestPath(h):
                return route(state, tcp: .requestPath(destinationHash: h),
                                    ble: .requestPath(destinationHash: h))
            case let .openLink(h):
                return route(state, tcp: .openLink(destinationHash: h),
                                    ble: .openLink(destinationHash: h))
            case let .sendOverLink(l, d):
                return route(state, tcp: .sendOverLink(linkID: l, data: d),
                                    ble: .sendOverLink(linkID: l, data: d))
            case let .sendResourceOverLink(l, d):
                return route(state, tcp: .sendResourceOverLink(linkID: l, data: d),
                                    ble: .sendResourceOverLink(linkID: l, data: d))
            case let .identifyOverLink(l, i):
                return route(state, tcp: .identifyOverLink(linkID: l, identity: i),
                                    ble: .identifyOverLink(linkID: l, identity: i))
            case let .sendRequestOverLink(l, p, d):
                return route(state, tcp: .sendRequestOverLink(linkID: l, path: p, data: d),
                                    ble: .sendRequestOverLink(linkID: l, path: p, data: d))
            case let .sendResponseOverLink(l, r, d):
                return route(state, tcp: .sendResponseOverLink(linkID: l, requestID: r, data: d),
                                    ble: .sendResponseOverLink(linkID: l, requestID: r, data: d))
            case let .sendWithReceiptOverLink(l, d, t):
                return route(state, tcp: .sendWithReceiptOverLink(linkID: l, data: d, token: t),
                                    ble: .sendWithReceiptOverLink(linkID: l, data: d, token: t))
            case let .closeLink(l):
                return route(state, tcp: .closeLink(linkID: l), ble: .closeLink(linkID: l))
            case let .registerRequestHandler(p, pol):
                return route(state, tcp: .registerRequestHandler(path: p, policy: pol),
                                    ble: .registerRequestHandler(path: p, policy: pol))
            case let .deregisterRequestHandler(p):
                return route(state, tcp: .deregisterRequestHandler(path: p),
                                    ble: .deregisterRequestHandler(path: p))

            // --- child delegates → the unified delegate ---
            case let .tcp(.delegate(d)):
                return .send(.delegate(unify(d)))
            case let .ble(.delegate(d)):
                guard let unified = unify(d) else { return .none }   // BLE-only → not surfaced
                return .send(.delegate(unified))

            case .tcp, .ble, .delegate:
                return .none
            }
        }
    }

    /// Sends the transport-appropriate action to whichever case is active.
    private func route(_ state: State,
                       tcp: TCPEndpoint.Action,
                       ble: BLEEndpoint.Action) -> Effect<Action> {
        switch state {
        case .tcp: return .send(.tcp(tcp))
        case .ble: return .send(.ble(ble))
        }
    }

    /// TCP delegates map 1:1 onto the unified surface.
    private func unify(_ d: TCPEndpoint.Action.Delegate) -> Action.Delegate {
        switch d {
        case let .messageReceived(h, p):        return .messageReceived(destinationHash: h, plaintext: p)
        case let .pathLearned(h, hops):         return .pathLearned(destinationHash: h, hops: hops)
        case let .sendFailed(h, r):             return .sendFailed(destinationHash: h, reason: r)
        case let .linkEstablished(l, h):        return .linkEstablished(linkID: l, destinationHash: h)
        case let .linkDataReceived(l, d):       return .linkDataReceived(linkID: l, data: d)
        case let .linkClosed(l, r):             return .linkClosed(linkID: l, reason: r)
        case let .linkFailed(h):                return .linkFailed(destinationHash: h)
        case let .resourceReceived(l, d):       return .resourceReceived(linkID: l, data: d)
        case let .resourceConcluded(l, h):      return .resourceConcluded(linkID: l, resourceHash: h)
        case let .resourceFailed(l, h):         return .resourceFailed(linkID: l, resourceHash: h)
        case let .linkIdentified(l, i):         return .linkIdentified(linkID: l, remoteIdentity: i)
        case let .requestReceived(l, r, p, d):  return .requestReceived(linkID: l, requestID: r, pathHash: p, data: d)
        case let .responseReceived(l, r, d):    return .responseReceived(linkID: l, requestID: r, data: d)
        case let .requestFailed(l, r):          return .requestFailed(linkID: l, requestID: r)
        case let .packetDelivered(t):           return .packetDelivered(token: t)
        case let .packetDeliveryFailed(t):      return .packetDeliveryFailed(token: t)
        }
    }

    /// BLE delegates map 1:1 EXCEPT the BLE-only peer lifecycle, which returns nil.
    private func unify(_ d: BLEEndpoint.Action.Delegate) -> Action.Delegate? {
        switch d {
        case .peerOnline, .peerOffline:         return nil     // BLE-only: observe via `.ble`
        case let .messageReceived(h, p):        return .messageReceived(destinationHash: h, plaintext: p)
        case let .pathLearned(h, hops):         return .pathLearned(destinationHash: h, hops: hops)
        case let .sendFailed(h, r):             return .sendFailed(destinationHash: h, reason: r)
        case let .linkEstablished(l, h):        return .linkEstablished(linkID: l, destinationHash: h)
        case let .linkDataReceived(l, d):       return .linkDataReceived(linkID: l, data: d)
        case let .linkClosed(l, r):             return .linkClosed(linkID: l, reason: r)
        case let .linkFailed(h):                return .linkFailed(destinationHash: h)
        case let .resourceReceived(l, d):       return .resourceReceived(linkID: l, data: d)
        case let .resourceConcluded(l, h):      return .resourceConcluded(linkID: l, resourceHash: h)
        case let .resourceFailed(l, h):         return .resourceFailed(linkID: l, resourceHash: h)
        case let .linkIdentified(l, i):         return .linkIdentified(linkID: l, remoteIdentity: i)
        case let .requestReceived(l, r, p, d):  return .requestReceived(linkID: l, requestID: r, pathHash: p, data: d)
        case let .responseReceived(l, r, d):    return .responseReceived(linkID: l, requestID: r, data: d)
        case let .requestFailed(l, r):          return .requestFailed(linkID: l, requestID: r)
        case let .packetDelivered(t):           return .packetDelivered(token: t)
        case let .packetDeliveryFailed(t):      return .packetDeliveryFailed(token: t)
        }
    }
}
```

**TCA note:** `Scope(state: \.tcp, action: \.tcp)` scopes onto an enum-state case via case key paths — supported when the state enum is `@ObservableState` (which also makes it `@CasePathable`). If this TCA version needs a different spelling, consult `.build/checkouts/swift-composable-architecture/Sources/ComposableArchitecture/Reducer/Reducers/Scope.swift` for the enum-state initializer and adjust minimally, documenting the change. Do NOT change the action/delegate surface to work around it.

Both `unify` overloads are exhaustive switches (no `default:`) so a future delegate added to either endpoint is a compile error here rather than a silent drop.

- [ ] **Step 4: Run tests to verify they pass**

Run: `swift test --filter TransportEndpointTests`
Expected: all 5 PASS.

- [ ] **Step 5: Mutation verification (batch)**

Apply all three mutations at once to `TransportEndpoint.swift`:
1. In `route`, return `.send(.tcp(tcp))` unconditionally (ignore the `.ble` case).
2. In `.start`, swap the pair: `route(state, tcp: .disconnect, ble: .stop)`.
3. In the BLE `unify`, change `case .peerOnline, .peerOffline: return nil` to map `peerOnline` onto `.pathLearned(destinationHash: Data(), hops: 0)`.

Run: `swift test --filter TransportEndpointTests`
Expected: `sharedVerbsReachTheActiveChildOnBothTransports` + `startAndStopMapToEachTransportsLifecycle` FAIL (1, 2), `bleOnlyDelegatesDoNotSurfaceOnTheUnifiedSurface` FAILS (3). Revert all three; re-run — all PASS. Then full `swift test` — green apart from any pre-existing user WIP failures.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task2-msg.txt` (subject `feat: TransportEndpoint sum type unifying TCP and BLE endpoints`), then:

```bash
git add Sources/ReTiCANode/TransportEndpoint.swift Tests/ReTiCANodeTests/TransportEndpointTests.swift
git commit -F /tmp/ReTiCA/task2-msg.txt
```

---

### Task 3: `LXMFNode` composes `TransportEndpoint`

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Modify (mechanical touch-ups only): the LXMF test files listed in Step 3.

**Interfaces:**
- Consumes: `TransportEndpoint` (Task 2).
- Produces (used by Task 4): `LXMFNode.State.endpoint: TransportEndpoint.State`; `LXMFNode.Action.endpoint(TransportEndpoint.Action)`; the convenience inits `LXMFNode.State(identity:endpoint: TCPEndpoint.State)` and `LXMFNode.State(identity:endpoint: BLEEndpoint.State)`.

**SUCCESS CRITERION: the existing LXMF suites pass with ONLY the mechanical touch-ups in Step 3** — no test logic changes, no assertion changes, no payload changes. The touch-ups are name-level only (a lifecycle rename and a `.tcp` hop); if a test needs anything more to compile or pass, the refactor changed behavior — STOP and report.

- [ ] **Step 1: Repoint `LXMFNode` at `TransportEndpoint`**

In `Sources/ReTiCANode/LXMFNode.swift`:

1. State — change the endpoint property and add the convenience inits:

```swift
        public var endpoint: TransportEndpoint.State
```

```swift
        public init(identity: Identity, endpoint: TransportEndpoint.State) {
            self.identity = identity
            self.endpoint = endpoint
            self.router = LXMFRouter.State()
        }

        /// Convenience: run this node over TCP.
        public init(identity: Identity, endpoint: TCPEndpoint.State) {
            self.init(identity: identity, endpoint: .tcp(endpoint))
        }

        /// Convenience: run this node over BLE.
        public init(identity: Identity, endpoint: BLEEndpoint.State) {
            self.init(identity: identity, endpoint: .ble(endpoint))
        }
```

2. Action — change the child case:

```swift
        case endpoint(TransportEndpoint.Action)
```

3. Body — change the scoped reducer:

```swift
        Scope(state: \.endpoint, action: \.endpoint) { TransportEndpoint() }
```

4. State reads — the four `state.endpoint.transport.learned[…]` sites become `state.endpoint.learned[…]` (lines ~77, ~94, ~170, ~249 pre-edit):

```swift
                guard let recipient = state.endpoint.learned[destinationHash]?.identity
```
```swift
                   let recipient = state.endpoint.learned[message.destinationHash]?.identity {
```
```swift
                if let identity = state.endpoint.learned[h]?.identity {
```
```swift
              let appData = state.endpoint.learned[pn]?.appData,
```

5. Update the file's doc comment to say it composes `TransportEndpoint` (so a node runs over TCP or BLE) rather than `TCPEndpoint`.

Everything else in `LXMFNode` — every `.endpoint(.foo)` send, every `.endpoint(.delegate(.bar))` match — stays **verbatim**: the unified action and delegate names are identical to what it already used.

- [ ] **Step 2: Build to find the test breakage**

Run: `swift build`
Expected: clean (sources only).
Run: `swift test --filter LXMFNode`
Expected: COMPILE FAILURES in the LXMF test files — that is expected and is what Step 3 fixes.

- [ ] **Step 3: Mechanical test touch-ups**

In these files: `LXMFNodeOpportunisticTests.swift`, `LXMFNodeDirectTests.swift`, `LXMFNodeSyncTests.swift`, `LXMFNodePropagationTests.swift`, `LXMFNodeSendMessageTests.swift`, `LXMFDirectDeliveryTests.swift`, `LXMFOpportunisticDeliveryTests.swift`, `LXMFPropagationCapstoneTests.swift` — apply ONLY these three mechanical changes:

1. **Lifecycle:** `.endpoint(.connect)` → `.endpoint(.start)`, `.endpoint(.disconnect)` → `.endpoint(.stop)`.
2. **Child-action hop (~9 sites total):** any reference that reaches THROUGH the endpoint into its transport-specific child gains a `.tcp` hop. Both spellings occur:
   - pattern matches — `if case .endpoint(.interface(.send)) = $0` → `if case .endpoint(.tcp(.interface(.send))) = $0`; likewise `.endpoint(.transport(…))` → `.endpoint(.tcp(.transport(…)))` and `.endpoint(.link(…))` → `.endpoint(.tcp(.link(…)))`;
   - key paths — `\.endpoint.interface.send` → `\.endpoint.tcp.interface.send`, `\.endpoint.transport.…` → `\.endpoint.tcp.transport.…`.
   Counts to expect: `LXMFNodeOpportunisticTests` 3, `LXMFPropagationCapstoneTests` 3, `LXMFNodePropagationTests` 1, `LXMFNodeDirectTests` 1, `LXMFNodeSyncTests` 1 (the other three files may have none). Find them with `grep -rn "endpoint(\.interface\|endpoint(\.transport\|endpoint(\.link\|endpoint\.interface\|endpoint\.transport" Tests/ReTiCANodeTests`.
3. **Unified delegates need NO hop:** `.endpoint(.delegate(.pathLearned))` etc. stay exactly as they are — the unified delegate is surfaced by `TransportEndpoint` itself.

`LXMFNode.State(identity:endpoint: TCPEndpoint.State(...))` call sites need NO change — the convenience init handles them.

The three deep reads (`LXMFPropagationCapstoneTests.swift` ~line 161, `LXMFNodePropagationTests.swift` ~line 112, `LXMFNodeDirectTests.swift` ~line 107 — all `state.endpoint.links[…]`) need NO change — the `links` passthrough handles them.

**Do NOT change any assertion, any payload, or any test's logic.** If a test needs more than the two mechanical changes above to compile or pass, STOP and report it — that means the refactor changed behavior.

- [ ] **Step 4: Run the LXMF suites**

Run: `swift test --filter LXMFNode`
Expected: PASS.
Run: `swift test --filter LXMF`
Expected: PASS (covers the delivery/propagation/capstone suites too).
Run: `swift test`
Expected: full suite green apart from any pre-existing user WIP failures.

- [ ] **Step 5: Mutation verification (batch)**

Apply both mutations at once to `Sources/ReTiCANode/LXMFNode.swift`:
1. In the `.sendViaPropagation` handler, change `state.endpoint.learned[destinationHash]?.identity` to `nil` (i.e. `guard let recipient: Identity = nil`) so the recipient lookup always fails.
2. In the `pathLearned` handler, delete the `state.endpoint.learned[h]?.identity` lookup and the `.learnedIdentity` effect it feeds.

Run: `swift test --filter LXMF`
Expected: propagation/opportunistic tests FAIL (the recipient/identity paths are load-bearing — mutation 1 breaks propagation packing, mutation 2 breaks signature validation on receive). Revert both; re-run — PASS.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task3-msg.txt` (subject `refactor: LXMFNode composes TransportEndpoint (TCP or BLE)`), then:

```bash
git add Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests
git commit -F /tmp/ReTiCA/task3-msg.txt
```

(Use `git add Tests/ReTiCANodeTests` only if every change in it is yours — check `git status --short` first and stage individual files if the user has concurrent edits there.)

---

### Task 4: LXMF over BLE proof

**Files:**
- Test: `Tests/ReTiCANodeTests/LXMFNodeBLETests.swift` (new)

**Interfaces:**
- Consumes: `LXMFNode` with the BLE convenience init (Task 3); `TransportEndpoint` (Task 2); `BLEEndpoint`, `BLEDriver`, `BLEDriverEvent`, `BLEChannelID`, `BLEPeerHandle`, `BLEHello`, `BLEFraming`, `BLEInterface.protocolVersion`, `bleInterfaceID`.
- Produces: nothing (proof only).

- [ ] **Step 1: Write the tests**

Create `Tests/ReTiCANodeTests/LXMFNodeBLETests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private func framedHello(_ token: Data) -> Data {
    try! BLEFraming.frame(BLEHello.pack(version: BLEInterface.protocolVersion, token: token))
}

private let ownToken  = Data(repeating: 0x5A, count: 16)
private let peerToken = Data(repeating: 0xC7, count: 16)
private let channel   = BLEChannelID(id: UUID(uuidString: "11111111-0000-0000-0000-000000000001")!)
private let handle    = BLEPeerHandle(id: UUID(uuidString: "22222222-0000-0000-0000-000000000002")!)

/// An LXMFNode running over BLE, with a controllable mock driver.
@MainActor
private func makeBLENode(_ identity: Identity)
    -> (TestStore<LXMFNode.State, LXMFNode.Action>,
        AsyncStream<BLEDriverEvent>.Continuation,
        LockIsolated<[Data]>) {
    let events = AsyncStream<BLEDriverEvent>.makeStream()
    let sent = LockIsolated<[Data]>([])          // framed bytes handed to the driver
    let store = TestStore(
        initialState: LXMFNode.State(identity: identity, endpoint: BLEEndpoint.State())
    ) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.bleRandomBytes = BLERandomBytesGenerator { _ in ownToken }
        $0.bleDriver = BLEDriver(
            start: { _ in events.stream },
            readDirectory: { _ in }, openChannel: { _, _ in },
            send: { _, data in sent.withValue { $0.append(data) } },
            closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off
    return (store, events.continuation, sent)
}

/// Bring one inbound BLE peer online through the real BLEInterface handshake.
@MainActor
private func bringPeerOnline(_ store: TestStore<LXMFNode.State, LXMFNode.Action>,
                             _ events: AsyncStream<BLEDriverEvent>.Continuation) async {
    await store.send(.endpoint(.start))
    events.yield(.ready)                  // BLEInterface gates channelOpened on .online
    events.yield(.channelOpened(channel, handle, direction: .inbound))
    events.yield(.channelData(channel, framedHello(peerToken)))
    await store.receive { action in
        if case .endpoint(.ble(.transport(.interfaceConnected))) = action { return true }
        return false
    }
}

@MainActor
private func teardown(_ store: TestStore<LXMFNode.State, LXMFNode.Action>) async {
    await store.send(.endpoint(.stop))
    await store.receive { action in
        if case .endpoint(.ble(.transport(.stopMaintenance))) = action { return true }
        return false
    }
}

@Test @MainActor func lxmfNodeOverBLEDeliversAnInboundOpportunisticMessage() async {
    let bIdentity = Identity()                     // us (the receiver)
    let aIdentity = Identity()                     // the sender
    let (store, events, _) = makeBLENode(bIdentity)
    await bringPeerOnline(store, events)

    // We register + announce our lxmf.delivery destination.
    await store.send(.registerDelivery)
    await store.receive { if case .endpoint(.ble(.send)) = $0 { return true }; return false }

    // Craft A's opportunistic LXMF message addressed to our delivery destination and deliver
    // it over the peer's channel, exactly as a real peer would.
    let bDeliveryHash = LXMessage.deliveryHash(identityHash: bIdentity.hash)
    let msg = LXMessage.create(source: aIdentity, destinationHash: bDeliveryHash,
                               timestamp: 1700000000.5,
                               title: Data("hi".utf8), content: Data("hello over ble".utf8))
    let dest = Destination(kind: .single, direction: .out, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identityPublicKey: bIdentity.publicKey)!
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: bDeliveryHash, transportId: nil,
                        payload: dest.encrypt(msg.opportunisticPayload))
    events.yield(.channelData(channel, try! BLEFraming.frame(try! packet.packed())))

    let gotContent = LockIsolated<Data?>(nil)
    await store.receive { action in
        if case let .delegate(.messageReceived(m, _)) = action { gotContent.setValue(m.content); return true }
        return false
    }
    #expect(gotContent.value == Data("hello over ble".utf8))

    await teardown(store)
}

@Test @MainActor func lxmfNodeOverBLESendsAnOpportunisticMessageToThePeer() async {
    let aIdentity = Identity()                     // us (the sender)
    let bIdentity = Identity()                     // the recipient
    let (store, events, sent) = makeBLENode(aIdentity)
    await bringPeerOnline(store, events)

    // Learn B's delivery destination from an announce arriving over the peer channel.
    let bDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                            aspects: LXMessage.deliveryAspects, identity: bIdentity)!
    let nameHash = Destination.nameHash(appName: LXMessage.appName, aspects: LXMessage.deliveryAspects)
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0xA5, count: 5))
    let payload = Announce.buildPayload(identity: bIdentity, destinationHash: bDest.hash,
                                        nameHash: nameHash, randomHash: randomHash, appData: nil)
    let announce = Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                          destinationType: .single, context: .none, contextFlag: false, hops: 1,
                          destinationHash: bDest.hash, transportId: nil, payload: payload)
    events.yield(.channelData(channel, try! BLEFraming.frame(try! announce.packed())))
    await store.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }

    // Send an opportunistic LXMF message; it must reach the peer as a framed DATA packet.
    let before = sent.value.count
    await store.send(.send(destinationHash: bDest.hash, title: Data("hi".utf8),
                           content: Data("ping".utf8), method: .opportunistic))
    await store.receive { if case .endpoint(.ble(.send)) = $0 { return true }; return false }
    #expect(sent.value.count > before)
    let raw = Data(sent.value.last!.dropFirst(BLEFraming.headerLength))   // driver sees FRAMED bytes
    let outPacket = Packet(raw: raw)
    #expect(outPacket?.packetType == .data)
    #expect(outPacket?.destinationHash == bDest.hash)

    await teardown(store)
}
```

**If any constructor above differs from the real API** (`LXMessage.create`, `LXMessage.deliveryHash`, `Destination(kind:direction:appName:aspects:identityPublicKey:)`, `Announce.buildPayload`, `msg.opportunisticPayload`), consult `Tests/ReTiCANodeTests/LXMFNodeOpportunisticTests.swift` and `Tests/ReTiCANodeTests/BLEEndpointIntegrationTests.swift` — both already build these exact artifacts — and adjust minimally, documenting each change.

- [ ] **Step 2: Run the tests**

Run: `swift test --filter LXMFNodeBLETests`
Expected: both PASS (run twice for stability — the driver handshake is async).

- [ ] **Step 3: Mutation verification (batch)**

Apply both mutations at once:
1. In `Sources/ReTiCANode/TransportEndpoint.swift`'s `route`, return `.send(.tcp(tcp))` unconditionally (BLE actions never reach the BLE endpoint).
2. In `Sources/ReTiCANode/TransportEndpoint.swift`'s BLE `unify`, return `nil` for `.messageReceived`.

Run: `swift test --filter LXMFNodeBLETests`
Expected: `lxmfNodeOverBLESendsAnOpportunisticMessageToThePeer` FAILS (1 — nothing reaches the driver) and `lxmfNodeOverBLEDeliversAnInboundOpportunisticMessage` FAILS (2 — the message never surfaces). Revert both; re-run — PASS. Then full `swift test` — green apart from pre-existing user WIP failures.

- [ ] **Step 4: Commit**

Write `/tmp/ReTiCA/task4-msg.txt` (subject `test: LXMF over BLE end-to-end through LXMFNode`), then:

```bash
git add Tests/ReTiCANodeTests/LXMFNodeBLETests.swift
git commit -F /tmp/ReTiCA/task4-msg.txt
```

---

## Final verification (after Task 4)

- [ ] `swift test` — full suite green apart from pre-existing user WIP failures (none in files this plan touched).
- [ ] `grep -rn "\bEndpoint\b" Sources/ReTiCANode Tests/ReTiCANodeTests` — NO output (the rename is complete).
- [ ] `grep -rn "BLETCPEndpoint\|TCPBLEEndpoint" Sources Tests` — NO output (no over-rename).
- [ ] `git log --format='%(trailers:key=Claude-Session)' -4` — all four task commits' trailers parse.
- [ ] Confirm `LXMFRouter.swift`, `LinkPlane.swift`, `LinkSession.swift`, `Transport.swift`, `BLEInterface.swift` are unchanged by this plan (`git diff <plan-base> HEAD --stat` should show only the renamed/created/edited files listed in the tasks).
