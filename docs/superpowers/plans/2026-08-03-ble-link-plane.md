# LinkPlane / BLEEndpoint Link Wiring Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Give `BLEEndpoint` the full link/resource/request surface the TCP `Endpoint` has, by factoring the interface-agnostic link machinery into a shared `LinkPlane` reducer that both endpoints embed — so LXMF direct delivery and propagation sync can later run over BLE.

**Architecture:** Three stages. (1) Add `arrivalInterface` to `Transport`'s `linkRequest` delegate so a BLE responder link can reply on the peer the request arrived on. (2) Extract `LinkPlane` — the links collection, request registry, management actions, and link-element delegate mapping — out of `Endpoint`, with a `.delegate(.transmit(InterfaceID, Data))` routing delegate the host resolves to a concrete interface; `Endpoint` becomes a thin host. (3) `BLEEndpoint` embeds the same `LinkPlane`, resolving `transmit` per-peer via its `peerInterfaces` map.

**Tech Stack:** Swift 6, ComposableArchitecture (TCA), Swift Testing (`@Test`/`#expect`), `ReTiCA` / `ReTiCATransport` / `ReTiCAInterfaces` / `ReTiCANode`.

## Global Constraints

- Spec: `docs/superpowers/specs/2026-08-03-ble-link-plane-design.md`.
- **Renaming `Endpoint` → `TCPEndpoint` is OUT OF SCOPE** (deferred to a later pass). Keep the `Endpoint` name everywhere.
- **Do NOT modify** `LinkSession.swift`, `BLEInterface.swift`, `FCBDriverAdapter.swift`, `LXMFNode.swift`, `PNNode.swift`, `PropagationNode.swift`, `LXMFRouter.swift`, or anything under `Sources/ReTiCA/LXMF`. The user has concurrent WIP in `Sources/ReTiCATransport/LinkSession.swift` and `Tests/ReTiCANodeTests/LXMFPropagationCapstoneTests.swift` — never edit or `git add` those two files. If a full-suite run shows failures only in LXMF/core files you did not touch, that is the user's WIP: report it as an observation, do not fix.
- `Endpoint`'s public action/delegate surface must stay **byte-identical** through Task 2 (it is a behavior-preserving refactor). Its consumers (`LXMFNode`, `PNNode`) must keep compiling untouched.
- Exact upstream signatures (verified against source — use verbatim):
  - `LinkSession.Action`: `.establish`, `.acceptRequest(Data)`, `.received(Data)`, `.send(Data)`, `.identify(Identity)`, `.close`, `.sendResource(Data)`, `.sendRequest(path: String, data: Data)`, `.sendResponse(requestID: Data, data: Data)`, `.sendWithReceipt(data: Data, token: Data)`.
  - `LinkSession.Action.Delegate`: `.transmit(InterfaceID, Data)`, `.established(linkID: Data, sessionKey: Data)`, `.establishmentFailed`, `.dataReceived(Data)`, `.closed(CloseReason)`, `.resourceReceived(Data)`, `.resourceConcluded(Data)`, `.resourceFailed(Data)`, `.identified(Identity)`, `.responseReceived(requestID: Data, data: Data)`, `.requestFailed(requestID: Data)`, `.requestReceived(requestID: Data, pathHash: Data, data: Data)`, `.packetDelivered(Data)`, `.packetDeliveryFailed(Data)`.
  - `LinkSession.State` inits: `LinkSession.State(id: UUID, responderFor: Identity, destinationHash: Data, interfaceID: InterfaceID)` and `LinkSession.State(id: UUID, initiatorTo: Identity, destinationHash: Data, interfaceID: InterfaceID, relayNextHop: Data?)`.
  - `Transport.Action.Delegate`: `.transmit(InterfaceID, Data)`, `.received(destinationHash: Data, plaintext: Data)`, `.pathLearned(destinationHash: Data, hops: UInt8)`, `.sendFailed(destinationHash: Data, reason: Transport.SendFailure)`, `.linkPacket(linkID: Data, data: Data)`, `.linkRequest(destinationHash: Data, data: Data)` **(Task 1 changes this one)**.
  - `RequestRegistration(path: String, policy: RequestPolicy)`; `isAllowed(_ policy: RequestPolicy, _ identity: Identity?) -> Bool`; `@Dependency(\.requestResponder)`; `Crypto.truncatedHash(_:)`.
  - `bleInterfaceID(_ token: Data) -> InterfaceID` (in `BLEEndpoint.swift`).
- TCA discipline: `store.exhaustivity = .off`; assert outcomes. Mutation verification mandatory for every test-bearing task: (a) tests pass; (b) apply the listed mutations in one batch, run, named tests FAIL; (c) revert, run, pass. Commit only after (c) is green.
- Never chain shell commands (no `&&`, `|`, `;`, `$(...)`, xargs, inline interpreters). One command per Bash invocation. Commit messages via a file under `/tmp/ReTiCA/` (Write tool) + `git commit -F <file>`. Every message ends with these two trailer lines at column 0 (no indent), exactly:

```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```

Verify after committing: `git log -1 --format='%(trailers:key=Claude-Session)'` prints the line. The user commits to `main` concurrently — use `<commit>^` when reasoning about your own diff, not a pre-recorded base.
- Test iteration: `swift test --filter <SuiteOrTestName>`. Run full `swift test` before each commit.

---

### Task 1: Transport enabler — `arrivalInterface` on the `linkRequest` delegate

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (delegate case + emit site)
- Modify: `Sources/ReTiCANode/Endpoint.swift` (the one pattern match)
- Modify: `Tests/ReTiCATransportTests/TransportTests.swift` (one destructuring site)

**Interfaces:**
- Consumes: nothing.
- Produces (used by Tasks 2–3): `Transport.Action.Delegate.linkRequest(destinationHash: Data, arrivalInterface: InterfaceID, data: Data)`.

**Note on scope:** only FOUR sites destructure this case. The many `await store.receive(\.transport.delegate.linkRequest)` calls are key-paths to the case, not destructurings — they need no change.

- [ ] **Step 1: Change the delegate case**

In `Sources/ReTiCATransport/Transport.swift`, line ~112, change:

```swift
            case linkRequest(destinationHash: Data, data: Data)
```

to:

```swift
            case linkRequest(destinationHash: Data, arrivalInterface: InterfaceID, data: Data)
```

- [ ] **Step 2: Pass the arrival interface at the emit site**

In the same file, line ~195-197, change:

```swift
                if packet.packetType == .linkRequest, state.localDestinations[packet.destinationHash] != nil {
                    return .send(.delegate(.linkRequest(destinationHash: packet.destinationHash, data: data)))
                }
```

to:

```swift
                if packet.packetType == .linkRequest, state.localDestinations[packet.destinationHash] != nil {
                    return .send(.delegate(.linkRequest(destinationHash: packet.destinationHash,
                                                        arrivalInterface: interfaceID, data: data)))
                }
```

(`interfaceID` is the `.received(interfaceID, raw)` parameter already in scope in this case.)

- [ ] **Step 3: Update the `Endpoint` pattern match (ignores the new field)**

In `Sources/ReTiCANode/Endpoint.swift`, line ~115, change:

```swift
            case let .transport(.delegate(.linkRequest(destHash, data))):
```

to:

```swift
            case let .transport(.delegate(.linkRequest(destHash, _, data))):
```

The body is unchanged — `Endpoint` keeps using its single `id` for the link's `interfaceID`, so TCP behavior is identical.

- [ ] **Step 4: Update the one destructuring test site + add an assertion**

In `Tests/ReTiCATransportTests/TransportTests.swift`, line ~327, change:

```swift
        if case let .delegate(.linkRequest(h, _)) = action { captured.setValue(h); return true }
```

to capture and assert the arrival interface as well. Replace the surrounding capture with:

```swift
        if case let .delegate(.linkRequest(h, arrival, _)) = action {
            captured.setValue(h); capturedArrival.setValue(arrival); return true
        }
```

and declare `let capturedArrival = LockIsolated<InterfaceID?>(nil)` beside the existing `captured`, then after the `receive` add an assertion that the arrival interface is the one the packet was fed in on. Read the test to find the `InterfaceID` used in its `.received(...)` call and assert equality with it, e.g.:

```swift
    #expect(capturedArrival.value == <the InterfaceID the test fed .received with>)
```

- [ ] **Step 5: Run the affected suites**

Run: `swift test --filter TransportTests`
Expected: PASS.
Run: `swift test --filter EndpointTests`
Expected: PASS (unchanged behavior).

- [ ] **Step 6: Mutation verification**

Mutation: in `Transport.swift`'s emit site, replace `arrivalInterface: interfaceID` with `arrivalInterface: InterfaceID("wrong")`.
Run: `swift test --filter TransportTests`
Expected: the arrival-interface assertion FAILS. Revert; re-run — PASS. Then `swift test` (full) — green apart from any pre-existing LXMF/core WIP failures (report, don't fix).

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/task1-msg.txt` (subject `feat: carry arrivalInterface on Transport.linkRequest delegate`), then:

```bash
git add Sources/ReTiCATransport/Transport.swift Sources/ReTiCANode/Endpoint.swift Tests/ReTiCATransportTests/TransportTests.swift
git commit -F /tmp/ReTiCA/task1-msg.txt
```

---

### Task 2: Extract `LinkPlane` from `Endpoint` (behavior-preserving refactor)

**Files:**
- Create: `Sources/ReTiCANode/LinkPlane.swift`
- Modify: `Sources/ReTiCANode/Endpoint.swift` (embed + delegate to `LinkPlane`)
- Test: `Tests/ReTiCANodeTests/LinkPlaneTests.swift` (new)

**Interfaces:**
- Consumes: `Transport.Action.Delegate.linkRequest(destinationHash:arrivalInterface:data:)` (Task 1); `LinkSession`, `RequestRegistration`, `RequestPolicy`, `isAllowed`, `\.requestResponder`, `\.uuid`.
- Produces (used by Task 3): the `LinkPlane` reducer — `LinkPlane.State(links:registrations:)` (both defaulted empty), the `LinkPlane.Action` cases listed below, and `LinkPlane.Action.Delegate` including `.transmit(InterfaceID, Data)`.

**THE SUCCESS CRITERION:** every existing test in `Tests/ReTiCANodeTests/EndpointTests.swift` passes **unchanged**. Do not edit `EndpointTests.swift`. If a test fails, the refactor is wrong — fix the refactor, not the test.

- [ ] **Step 1: Create `LinkPlane.swift`**

Create `Sources/ReTiCANode/LinkPlane.swift`:

```swift
import Foundation
import ComposableArchitecture
import ReTiCA
import ReTiCATransport

/// The interface-agnostic link/resource/request plane: owns the live `LinkSession`s and the
/// request-handler registry, and surfaces link lifecycle + resource + request delegates.
///
/// It never reads `Transport` state — the host passes in whatever a link needs at creation
/// time (identity, destination hash, the `InterfaceID` the link rides). Outbound link packets
/// are surfaced as `.delegate(.transmit(interfaceID, raw))`; the host resolves that
/// `InterfaceID` to a concrete interface (one fixed ID for TCP; a per-peer map for BLE).
@Reducer
public struct LinkPlane {
    @ObservableState
    public struct State: Equatable {
        public var links: IdentifiedArrayOf<LinkSession.State> = []
        public var registrations: [Data: RequestRegistration] = [:]
        public init(links: IdentifiedArrayOf<LinkSession.State> = [],
                    registrations: [Data: RequestRegistration] = [:]) {
            self.links = links
            self.registrations = registrations
        }
    }

    public enum Action: Equatable {
        case link(IdentifiedActionOf<LinkSession>)

        /// Create an initiator link and start establishment.
        case openLink(initiatorTo: Identity, destinationHash: Data,
                      interfaceID: InterfaceID, relayNextHop: Data?)
        /// Create a responder link for an inbound LINKREQUEST and accept it.
        case acceptLinkRequest(owner: Identity, destinationHash: Data,
                               interfaceID: InterfaceID, data: Data)
        /// Route an inbound link-addressed packet to the link that owns it.
        case routeLinkPacket(linkID: Data, data: Data)

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
            /// Send `data` on the interface identified by this `InterfaceID`.
            case transmit(InterfaceID, Data)
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

    @Dependency(\.uuid) var uuid
    @Dependency(\.requestResponder) var requestResponder

    public var body: some ReducerOf<Self> {
        Reduce { state, action in
            switch action {
            case let .openLink(identity, destinationHash, interfaceID, relayNextHop):
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, initiatorTo: identity,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID,
                                                     relayNextHop: relayNextHop))
                return .send(.link(.element(id: newID, action: .establish)))

            case let .acceptLinkRequest(owner, destinationHash, interfaceID, data):
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, responderFor: owner,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID))
                return .send(.link(.element(id: newID, action: .acceptRequest(data))))

            case let .routeLinkPacket(linkID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .received(data))))

            case let .sendOverLink(linkID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .send(data))))

            case let .sendResourceOverLink(linkID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendResource(data))))

            case let .identifyOverLink(linkID, identity):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .identify(identity))))

            case let .sendRequestOverLink(linkID, path, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendRequest(path: path, data: data))))

            case let .sendResponseOverLink(linkID, requestID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendResponse(requestID: requestID, data: data))))

            case let .sendWithReceiptOverLink(linkID, data, token):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendWithReceipt(data: data, token: token))))

            case let .closeLink(linkID):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .close)))

            case let .registerRequestHandler(path, policy):
                state.registrations[Crypto.truncatedHash(Data(path.utf8))] = RequestRegistration(path: path, policy: policy)
                return .none

            case let .deregisterRequestHandler(path):
                state.registrations[Crypto.truncatedHash(Data(path.utf8))] = nil
                return .none

            // --- LinkSession element delegates → LinkPlane delegates ---

            case let .link(.element(_, .delegate(.transmit(txID, raw)))):
                return .send(.delegate(.transmit(txID, raw)))

            case let .link(.element(elementID, .delegate(.established(linkID, _)))):
                guard let destHash = state.links[id: elementID]?.destinationHash else { return .none }
                return .send(.delegate(.linkEstablished(linkID: linkID, destinationHash: destHash)))

            case let .link(.element(elementID, .delegate(.dataReceived(data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data)))

            case let .link(.element(elementID, .delegate(.closed(reason)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                state.links.remove(id: elementID)
                return .send(.delegate(.linkClosed(linkID: linkID, reason: reason)))

            case let .link(.element(elementID, .delegate(.establishmentFailed))):
                guard let destHash = state.links[id: elementID]?.destinationHash else { return .none }
                state.links.remove(id: elementID)
                return .send(.delegate(.linkFailed(destinationHash: destHash)))

            case let .link(.element(elementID, .delegate(.resourceReceived(data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceReceived(linkID: linkID, data: data)))

            case let .link(.element(elementID, .delegate(.resourceConcluded(hash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceConcluded(linkID: linkID, resourceHash: hash)))

            case let .link(.element(elementID, .delegate(.resourceFailed(hash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash)))

            case let .link(.element(elementID, .delegate(.identified(identity)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: identity)))

            case let .link(.element(elementID, .delegate(.requestReceived(rid, ph, data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                guard let reg = state.registrations[ph] else {
                    // No registered handler for this path: surface to the app.
                    return .send(.delegate(.requestReceived(linkID: linkID, requestID: rid, pathHash: ph, data: data)))
                }
                let identity = state.links[id: elementID]?.remoteIdentity
                guard isAllowed(reg.policy, identity) else { return .none }   // denied → silent drop
                let path = reg.path
                let responder = requestResponder
                return .run { send in
                    if let response = await responder(path, data, identity) {
                        await send(.sendResponseOverLink(linkID: linkID, requestID: rid, data: response))
                    }
                }

            case let .link(.element(elementID, .delegate(.responseReceived(rid, data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.responseReceived(linkID: linkID, requestID: rid, data: data)))

            case let .link(.element(elementID, .delegate(.requestFailed(rid)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.requestFailed(linkID: linkID, requestID: rid)))

            case let .link(.element(_, .delegate(.packetDelivered(token)))):
                return .send(.delegate(.packetDelivered(token: token)))

            case let .link(.element(_, .delegate(.packetDeliveryFailed(token)))):
                return .send(.delegate(.packetDeliveryFailed(token: token)))

            case .link, .delegate:
                return .none
            }
        }
        .forEach(\.links, action: \.link) { LinkSession() }
    }
}
```

- [ ] **Step 2: Refactor `Endpoint` to embed `LinkPlane`**

In `Sources/ReTiCANode/Endpoint.swift`:

**State** — replace the `links` and `registrations` properties with a `linkPlane`:

```swift
        public var interface: TCPClientInterface.State
        public var transport: Transport.State
        public var linkPlane: LinkPlane.State = LinkPlane.State()
        public let interfaceID: InterfaceID
```

Add computed passthroughs so existing tests that read `state.links` / `state.registrations` keep working **unchanged**:

```swift
        /// Live links (owned by the embedded LinkPlane).
        public var links: IdentifiedArrayOf<LinkSession.State> {
            get { linkPlane.links }
            set { linkPlane.links = newValue }
        }
        /// Request-handler registrations (owned by the embedded LinkPlane).
        public var registrations: [Data: RequestRegistration] {
            get { linkPlane.registrations }
            set { linkPlane.registrations = newValue }
        }
```

**Action** — keep every existing case, and add the child action case:

```swift
        case linkPlane(LinkPlane.Action)
```

Keep `case link(IdentifiedActionOf<LinkSession>)` in `Endpoint.Action` — existing tests send and receive `.link(.element(...))` directly. Forward it to the plane (see the Reduce below).

**Body** — replace `.forEach(\.links, action: \.link) { LinkSession() }` with a `Scope` onto the plane, and rewrite the link-related cases:

```swift
    public var body: some ReducerOf<Self> {
        Scope(state: \.interface, action: \.interface) { TCPClientInterface() }
        Scope(state: \.transport, action: \.transport) { Transport() }
        Scope(state: \.linkPlane, action: \.linkPlane) { LinkPlane() }
        Reduce { state, action in
            let id = state.interfaceID
            switch action {
            // ... unchanged: .connect/.disconnect/.registerLocalDestination/.announce/.send/.enableRelay,
            //     the .interface(...) cases, and the transport transmit/received/pathLearned/sendFailed cases ...

            // --- Transport → LinkPlane ---
            case let .transport(.delegate(.linkPacket(linkID, data))):
                return .send(.linkPlane(.routeLinkPacket(linkID: linkID, data: data)))

            case let .transport(.delegate(.linkRequest(destHash, _, data))):
                guard let owner = state.transport.localDestinations[destHash]?.identity,
                      owner.privateKey != nil
                else { return .none }
                return .send(.linkPlane(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                                           interfaceID: id, data: data)))

            // --- Public link actions → LinkPlane ---
            case let .openLink(destinationHash):
                guard let learned = state.transport.learned[destinationHash] else {
                    return .send(.delegate(.linkFailed(destinationHash: destinationHash)))
                }
                // Via a relay (learned nextHop != the destination) → HEADER_2 LINKREQUEST to the relay.
                let relayNextHop: Data? = learned.nextHop == destinationHash ? nil : learned.nextHop
                return .send(.linkPlane(.openLink(initiatorTo: learned.identity,
                                                  destinationHash: destinationHash,
                                                  interfaceID: id, relayNextHop: relayNextHop)))

            case let .sendOverLink(linkID, data):
                return .send(.linkPlane(.sendOverLink(linkID: linkID, data: data)))
            case let .sendResourceOverLink(linkID, data):
                return .send(.linkPlane(.sendResourceOverLink(linkID: linkID, data: data)))
            case let .identifyOverLink(linkID, identity):
                return .send(.linkPlane(.identifyOverLink(linkID: linkID, identity: identity)))
            case let .sendRequestOverLink(linkID, path, data):
                return .send(.linkPlane(.sendRequestOverLink(linkID: linkID, path: path, data: data)))
            case let .sendResponseOverLink(linkID, requestID, data):
                return .send(.linkPlane(.sendResponseOverLink(linkID: linkID, requestID: requestID, data: data)))
            case let .sendWithReceiptOverLink(linkID, data, token):
                return .send(.linkPlane(.sendWithReceiptOverLink(linkID: linkID, data: data, token: token)))
            case let .closeLink(linkID):
                return .send(.linkPlane(.closeLink(linkID: linkID)))
            case let .registerRequestHandler(path, policy):
                return .send(.linkPlane(.registerRequestHandler(path: path, policy: policy)))
            case let .deregisterRequestHandler(path):
                return .send(.linkPlane(.deregisterRequestHandler(path: path)))

            case let .requestPath(destinationHash):
                return .send(.transport(.requestPath(destinationHash: destinationHash)))

            // --- Direct .link(...) actions from callers/tests → forward into the plane ---
            case let .link(linkAction):
                return .send(.linkPlane(.link(linkAction)))

            // --- LinkPlane delegates → interface / Endpoint delegates ---
            case let .linkPlane(.delegate(.transmit(txID, raw))):
                guard txID == id else { return .none }
                return .send(.interface(.send(raw)))

            case let .linkPlane(.delegate(.linkEstablished(linkID, destHash))):
                return .send(.delegate(.linkEstablished(linkID: linkID, destinationHash: destHash)))
            case let .linkPlane(.delegate(.linkDataReceived(linkID, data))):
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data)))
            case let .linkPlane(.delegate(.linkClosed(linkID, reason))):
                return .send(.delegate(.linkClosed(linkID: linkID, reason: reason)))
            case let .linkPlane(.delegate(.linkFailed(destHash))):
                return .send(.delegate(.linkFailed(destinationHash: destHash)))
            case let .linkPlane(.delegate(.resourceReceived(linkID, data))):
                return .send(.delegate(.resourceReceived(linkID: linkID, data: data)))
            case let .linkPlane(.delegate(.resourceConcluded(linkID, hash))):
                return .send(.delegate(.resourceConcluded(linkID: linkID, resourceHash: hash)))
            case let .linkPlane(.delegate(.resourceFailed(linkID, hash))):
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash)))
            case let .linkPlane(.delegate(.linkIdentified(linkID, identity))):
                return .send(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: identity)))
            case let .linkPlane(.delegate(.requestReceived(linkID, rid, ph, data))):
                return .send(.delegate(.requestReceived(linkID: linkID, requestID: rid, pathHash: ph, data: data)))
            case let .linkPlane(.delegate(.responseReceived(linkID, rid, data))):
                return .send(.delegate(.responseReceived(linkID: linkID, requestID: rid, data: data)))
            case let .linkPlane(.delegate(.requestFailed(linkID, rid))):
                return .send(.delegate(.requestFailed(linkID: linkID, requestID: rid)))
            case let .linkPlane(.delegate(.packetDelivered(token))):
                return .send(.delegate(.packetDelivered(token: token)))
            case let .linkPlane(.delegate(.packetDeliveryFailed(token))):
                return .send(.delegate(.packetDeliveryFailed(token: token)))

            case .interface, .transport, .delegate, .linkPlane:
                return .none
            }
        }
    }
```

Delete `Endpoint`'s now-migrated link bodies (the old `.link(.element(...))` delegate cases, the inline registry mutation, and the old `openLink`/`sendOverLink`/... bodies) — the plane owns them. Remove the now-unused `@Dependency(\.requestResponder)` from `Endpoint` **only if** the compiler reports it unused; `@Dependency(\.uuid)` likewise (the plane mints link ids now).

**Test-compat note:** existing tests do `store.send(.link(.element(id: UUID(0), action: ...)))` and `store.receive { if case .link(.element(_, .delegate(.transmit))) = $0 ... }`. With the forwarding case above, sends still work. Receives of `.link(...)` will now arrive as `.linkPlane(.link(...))`. Because `EndpointTests` uses `.off` exhaustivity and its `receive` predicates scan for a matching action, a predicate looking for `.link(.element(_, .delegate(.transmit)))` will NOT match `.linkPlane(.link(...))`. **If any existing test fails for this reason, do NOT edit the test** — instead ALSO emit the legacy `.link` action alongside the plane forward so the old action still appears in the stream:

```swift
            case let .linkPlane(.link(linkAction)):
                return .send(.link(linkAction))   // legacy mirror for existing consumers/tests
```
plus change the direct-forward case to avoid an infinite loop:
```swift
            case let .link(linkAction):
                // Forward caller/test-issued element actions into the plane. The plane mirrors
                // its own element actions back out as `.link` (above) for legacy observers.
                return .send(.linkPlane(.link(linkAction)))
```
If mirroring creates a cycle (plane emits `.link` → forwarded back into plane), gate the mirror so only plane-originated actions mirror: keep the mirror ONLY for element actions the plane itself produced. The simplest cycle-free arrangement, if needed: drop the `.link` → plane forward and have tests' direct `.link` sends handled by mapping them to the equivalent public action. **Prefer the arrangement that keeps `EndpointTests` unedited; report in your report which arrangement you used and why.**

- [ ] **Step 3: Write `LinkPlaneTests`**

Create `Tests/ReTiCANodeTests/LinkPlaneTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let ifA = InterfaceID("iface-a")

@Test @MainActor func openLinkMintsInitiatorLinkOnTheGivenInterface() async {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let dest = Data(repeating: 0x02, count: 16)
    await store.send(.openLink(initiatorTo: Identity(), destinationHash: dest,
                               interfaceID: ifA, relayNextHop: nil))
    #expect(store.state.links.count == 1)
    #expect(store.state.links[0].interfaceID == ifA)
    #expect(store.state.links[0].destinationHash == dest)
    // Establishment emits an outbound LINKREQUEST as a routing delegate on that interface.
    let captured = LockIsolated<InterfaceID?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(txID, _)) = action { captured.setValue(txID); return true }
        return false
    }
    #expect(captured.value == ifA)
    await store.send(.closeLink(linkID: store.state.links[0].linkID))
}

@Test @MainActor func acceptLinkRequestMintsResponderLinkOnTheArrivalInterface() async {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    await store.send(.acceptLinkRequest(owner: owner, destinationHash: dest.hash,
                                        interfaceID: ifA, data: try! request.packed()))
    #expect(store.state.links.count == 1)
    #expect(store.state.links[0].interfaceID == ifA)
    // The responder emits its LRPROOF as a routing delegate on the ARRIVAL interface.
    let captured = LockIsolated<(InterfaceID, Data)?>(nil)
    await store.receive { action in
        if case let .delegate(.transmit(txID, raw)) = action { captured.setValue((txID, raw)); return true }
        return false
    }
    #expect(captured.value?.0 == ifA)
    #expect(Packet(raw: captured.value!.1)?.packetType == .proof)
    await store.send(.closeLink(linkID: store.state.links[0].linkID))
}

@Test @MainActor func registerThenDeregisterMutatesRegistrations() async {
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    let ph = Crypto.truncatedHash(Data("svc/echo".utf8))
    await store.send(.registerRequestHandler(path: "svc/echo", policy: .all)) {
        $0.registrations[ph] = RequestRegistration(path: "svc/echo", policy: .all)
    }
    await store.send(.deregisterRequestHandler(path: "svc/echo")) {
        $0.registrations[ph] = nil
    }
}
```

- [ ] **Step 4: Run the suites**

Run: `swift test --filter LinkPlaneTests`
Expected: 3 PASS.
Run: `swift test --filter EndpointTests`
Expected: **ALL PASS, with `EndpointTests.swift` unedited.** This is the refactor's proof.

- [ ] **Step 5: Mutation verification**

Apply both mutations at once to `Sources/ReTiCANode/LinkPlane.swift`:
1. In `.openLink`, pass `interfaceID: InterfaceID("wrong")` to the `LinkSession.State` init instead of the parameter.
2. In `.link(.element(_, .delegate(.transmit(txID, raw))))`, change the body to `return .none`.

Run: `swift test --filter LinkPlaneTests`
Expected: `openLinkMintsInitiatorLinkOnTheGivenInterface` FAILS on both (wrong interfaceID; no transmit delegate) and `acceptLinkRequestMintsResponderLinkOnTheArrivalInterface` FAILS on mutation 2.
Run: `swift test --filter EndpointTests` — many FAIL under mutation 2 (no link packets ever reach the interface), further proving the plane is load-bearing.
Revert both; re-run both suites — all PASS. Then `swift test` (full) — green apart from pre-existing LXMF/core WIP failures.

- [ ] **Step 6: Commit**

Write `/tmp/ReTiCA/task2-msg.txt` (subject `refactor: extract LinkPlane from Endpoint`), then:

```bash
git add Sources/ReTiCANode/LinkPlane.swift Sources/ReTiCANode/Endpoint.swift Tests/ReTiCANodeTests/LinkPlaneTests.swift
git commit -F /tmp/ReTiCA/task2-msg.txt
```

---

### Task 3: `BLEEndpoint` gains `LinkPlane`

**Files:**
- Modify: `Sources/ReTiCANode/BLEEndpoint.swift`
- Test: `Tests/ReTiCANodeTests/BLEEndpointLinkTests.swift` (new)

**Interfaces:**
- Consumes: `LinkPlane` (Task 2) — `LinkPlane.State()`, the `LinkPlane.Action` cases, and `LinkPlane.Action.Delegate.transmit(InterfaceID, Data)`; `Transport.Action.Delegate.linkRequest(destinationHash:arrivalInterface:data:)` (Task 1); `bleInterfaceID(_:)`; the existing `BLEEndpoint.State.peerInterfaces: [InterfaceID: Data]`.
- Produces: `BLEEndpoint`'s link surface (actions + delegates) at parity with `Endpoint`.

- [ ] **Step 1: Add the link surface to `BLEEndpoint`**

In `Sources/ReTiCANode/BLEEndpoint.swift`:

**State** — add the plane beside the existing properties:

```swift
        public var linkPlane: LinkPlane.State = LinkPlane.State()
```

(Keep `ble`, `transport`, `peerInterfaces` as they are.)

**Action** — add the child case, the public link actions, and `requestPath`:

```swift
        case linkPlane(LinkPlane.Action)

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
```

**Delegate** — add the link/resource/request delegates (identical shapes to `Endpoint`'s):

```swift
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
```

**Body** — add `Scope(state: \.linkPlane, action: \.linkPlane) { LinkPlane() }` after the transport scope, and add these cases to the `Reduce`:

```swift
            case let .requestPath(destinationHash):
                return .send(.transport(.requestPath(destinationHash: destinationHash)))

            // --- Transport → LinkPlane (per-peer interface) ---
            case let .transport(.delegate(.linkPacket(linkID, data))):
                return .send(.linkPlane(.routeLinkPacket(linkID: linkID, data: data)))

            case let .transport(.delegate(.linkRequest(destHash, arrivalInterface, data))):
                guard let owner = state.transport.localDestinations[destHash]?.identity,
                      owner.privateKey != nil
                else { return .none }
                // Reply on the peer the request arrived from.
                return .send(.linkPlane(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                                           interfaceID: arrivalInterface, data: data)))

            // --- Public link actions → LinkPlane ---
            case let .openLink(destinationHash):
                guard let learned = state.transport.learned[destinationHash] else {
                    return .send(.delegate(.linkFailed(destinationHash: destinationHash)))
                }
                let relayNextHop: Data? = learned.nextHop == destinationHash ? nil : learned.nextHop
                // The learned entry records which BLE peer's interface the destination was heard on.
                return .send(.linkPlane(.openLink(initiatorTo: learned.identity,
                                                  destinationHash: destinationHash,
                                                  interfaceID: learned.interfaceID,
                                                  relayNextHop: relayNextHop)))

            case let .sendOverLink(linkID, data):
                return .send(.linkPlane(.sendOverLink(linkID: linkID, data: data)))
            case let .sendResourceOverLink(linkID, data):
                return .send(.linkPlane(.sendResourceOverLink(linkID: linkID, data: data)))
            case let .identifyOverLink(linkID, identity):
                return .send(.linkPlane(.identifyOverLink(linkID: linkID, identity: identity)))
            case let .sendRequestOverLink(linkID, path, data):
                return .send(.linkPlane(.sendRequestOverLink(linkID: linkID, path: path, data: data)))
            case let .sendResponseOverLink(linkID, requestID, data):
                return .send(.linkPlane(.sendResponseOverLink(linkID: linkID, requestID: requestID, data: data)))
            case let .sendWithReceiptOverLink(linkID, data, token):
                return .send(.linkPlane(.sendWithReceiptOverLink(linkID: linkID, data: data, token: token)))
            case let .closeLink(linkID):
                return .send(.linkPlane(.closeLink(linkID: linkID)))
            case let .registerRequestHandler(path, policy):
                return .send(.linkPlane(.registerRequestHandler(path: path, policy: policy)))
            case let .deregisterRequestHandler(path):
                return .send(.linkPlane(.deregisterRequestHandler(path: path)))

            // --- LinkPlane delegates: route transmit per-peer, forward the rest ---
            case let .linkPlane(.delegate(.transmit(txID, raw))):
                guard let peer = state.peerInterfaces[txID] else { return .none }
                return .send(.ble(.send(peer: peer, packet: raw)))

            case let .linkPlane(.delegate(.linkEstablished(linkID, destHash))):
                return .send(.delegate(.linkEstablished(linkID: linkID, destinationHash: destHash)))
            case let .linkPlane(.delegate(.linkDataReceived(linkID, data))):
                return .send(.delegate(.linkDataReceived(linkID: linkID, data: data)))
            case let .linkPlane(.delegate(.linkClosed(linkID, reason))):
                return .send(.delegate(.linkClosed(linkID: linkID, reason: reason)))
            case let .linkPlane(.delegate(.linkFailed(destHash))):
                return .send(.delegate(.linkFailed(destinationHash: destHash)))
            case let .linkPlane(.delegate(.resourceReceived(linkID, data))):
                return .send(.delegate(.resourceReceived(linkID: linkID, data: data)))
            case let .linkPlane(.delegate(.resourceConcluded(linkID, hash))):
                return .send(.delegate(.resourceConcluded(linkID: linkID, resourceHash: hash)))
            case let .linkPlane(.delegate(.resourceFailed(linkID, hash))):
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash)))
            case let .linkPlane(.delegate(.linkIdentified(linkID, identity))):
                return .send(.delegate(.linkIdentified(linkID: linkID, remoteIdentity: identity)))
            case let .linkPlane(.delegate(.requestReceived(linkID, rid, ph, data))):
                return .send(.delegate(.requestReceived(linkID: linkID, requestID: rid, pathHash: ph, data: data)))
            case let .linkPlane(.delegate(.responseReceived(linkID, rid, data))):
                return .send(.delegate(.responseReceived(linkID: linkID, requestID: rid, data: data)))
            case let .linkPlane(.delegate(.requestFailed(linkID, rid))):
                return .send(.delegate(.requestFailed(linkID: linkID, requestID: rid)))
            case let .linkPlane(.delegate(.packetDelivered(token))):
                return .send(.delegate(.packetDelivered(token: token)))
            case let .linkPlane(.delegate(.packetDeliveryFailed(token))):
                return .send(.delegate(.packetDeliveryFailed(token: token)))
```

Add `.linkPlane` to the final catch-all case list (`case .ble, .transport, .delegate, .linkPlane: return .none`).

- [ ] **Step 2: Write the BLE link tests**

Create `Tests/ReTiCANodeTests/BLEEndpointLinkTests.swift`:

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

@MainActor
private func makeNode() -> (TestStore<BLEEndpoint.State, BLEEndpoint.Action>,
                            AsyncStream<BLEDriverEvent>.Continuation,
                            LockIsolated<[(Data, Data)]>) {
    let events = AsyncStream<BLEDriverEvent>.makeStream()
    let sent = LockIsolated<[(Data, Data)]>([])   // (peerToken, packet)
    let store = TestStore(initialState: BLEEndpoint.State()) {
        BLEEndpoint()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.bleRandomBytes = BLERandomBytesGenerator { _ in ownToken }
        $0.bleDriver = BLEDriver(
            start: { _ in events.stream },
            readDirectory: { _ in }, openChannel: { _, _ in },
            send: { _, data in sent.withValue { $0.append((peerToken, data)) } },
            closeChannel: { _ in }, stop: { }
        )
    }
    store.exhaustivity = .off
    return (store, events.continuation, sent)
}

/// Bring one inbound peer online through the real BLEInterface handshake.
@MainActor
private func bringPeerOnline(_ store: TestStore<BLEEndpoint.State, BLEEndpoint.Action>,
                             _ events: AsyncStream<BLEDriverEvent>.Continuation) async {
    await store.send(.start)
    events.yield(.ready)                       // BLEInterface gates channelOpened on .online
    events.yield(.channelOpened(channel, handle, direction: .inbound))
    events.yield(.channelData(channel, framedHello(peerToken)))
    await store.receive { if case .transport(.interfaceConnected) = $0 { return true }; return false }
}

@MainActor
private func teardown(_ store: TestStore<BLEEndpoint.State, BLEEndpoint.Action>) async {
    await store.send(.stop)
    await store.receive { if case .transport(.stopMaintenance) = $0 { return true }; return false }
}

@Test @MainActor func inboundLinkRequestOverBLERepliesToThatPeer() async {
    let (store, events, sent) = makeNode()
    await bringPeerOnline(store, events)

    // Register a local destination we own, then feed a crafted LINKREQUEST to it over the peer's channel.
    let owner = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["svc"], identity: owner)!
    await store.send(.registerLocalDestination(dest))

    let initEph = Identity()
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    events.yield(.channelData(channel, try! BLEFraming.frame(try! request.packed())))

    // A responder link is created on the arrival peer's interface, and the LRPROOF goes back to that peer.
    await store.receive { if case .ble(.send) = $0 { return true }; return false }
    #expect(store.state.linkPlane.links.count == 1)
    #expect(store.state.linkPlane.links[0].interfaceID == bleInterfaceID(peerToken))
    let last = sent.value.last
    #expect(last?.0 == peerToken)
    #expect(Packet(raw: last!.1)?.packetType == .proof)

    await teardown(store)
}

@Test @MainActor func linkPlaneTransmitToUnknownPeerIsDropped() async {
    let (store, events, sent) = makeNode()
    await bringPeerOnline(store, events)
    let before = sent.value.count
    // A transmit addressed to an interface with no live peer must not reach the driver.
    await store.send(.linkPlane(.delegate(.transmit(InterfaceID("ble:deadbeef"), Data([0x01])))))
    #expect(sent.value.count == before)
    await teardown(store)
}
```

**Note on the driver `send` stub:** it records `(peerToken, data)` unconditionally because this test has exactly one live peer. If you extend these tests to multiple peers, thread the real peer through instead.

- [ ] **Step 3: Run the suites**

Run: `swift test --filter BLEEndpointLinkTests`
Expected: both PASS.
Run: `swift test --filter BLEEndpointTests`
Expected: PASS (the existing packet-plane tests are unaffected).
Run: `swift test --filter EndpointTests`
Expected: PASS (untouched).

- [ ] **Step 4: Mutation verification**

Apply both mutations at once to `Sources/ReTiCANode/BLEEndpoint.swift`:
1. In the `.transport(.delegate(.linkRequest(...)))` case, pass `interfaceID: InterfaceID("wrong")` instead of `arrivalInterface`.
2. In the `.linkPlane(.delegate(.transmit(txID, raw)))` case, replace the body with `return .none`.

Run: `swift test --filter BLEEndpointLinkTests`
Expected: `inboundLinkRequestOverBLERepliesToThatPeer` FAILS on both (wrong link interfaceID; and no `.ble(.send)` at all). Revert both; re-run — PASS. Then `swift test` (full) — green apart from pre-existing LXMF/core WIP failures.

- [ ] **Step 5: Commit**

Write `/tmp/ReTiCA/task3-msg.txt` (subject `feat: BLEEndpoint gains LinkPlane with per-peer link routing`), then:

```bash
git add Sources/ReTiCANode/BLEEndpoint.swift Tests/ReTiCANodeTests/BLEEndpointLinkTests.swift
git commit -F /tmp/ReTiCA/task3-msg.txt
```

---

## Final verification (after Task 3)

- [ ] `swift test --filter EndpointTests` — green, and `git diff <plan-base> -- Tests/ReTiCANodeTests/EndpointTests.swift` is EMPTY (the refactor never edited the TCP tests).
- [ ] `swift test` — full suite green apart from pre-existing LXMF/core WIP failures (which must not be in `ReTiCANode` code this plan touched).
- [ ] `git log --format='%(trailers:key=Claude-Session)' -3` — all three task commits' trailers parse.
- [ ] Confirm no changes to `LinkSession.swift` or `LXMFPropagationCapstoneTests.swift` (the user's concurrent WIP).
