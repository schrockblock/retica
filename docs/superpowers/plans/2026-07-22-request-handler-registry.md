# In-Library Request Handler Registry + Allow-Policy Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let a node register per-path request handlers with an allow-policy so the library answers matching requests directly, while unregistered paths still reach the app — purely additive, zero wire changes.

**Architecture:** New pure value types (`RequestPolicy`/`RequestRegistration` + an `isAllowed` gate) and a `requestResponder` dependency live in `ReTiCANode`. `Endpoint` gains a `pathHash → RequestRegistration` map, register/deregister actions, and interception of the bubbled `requestReceived`: registered+allowed → run the responder → `sendResponseOverLink`; denied/nil-response → drop; unregistered → forward to the app unchanged. `LinkSession`, `ResourceTransfer`, and the `ReTiCA` core are untouched.

**Tech Stack:** Swift 6, The Composable Architecture (~1.26) — `@Reducer`/`@ObservableState`/`@Dependency`/`DependencyKey`, `TestStore`; the in-core `Crypto.truncatedHash`, `Identity` (`.hash`), and the existing `Endpoint`/`LinkSession` request/response machinery.

## Global Constraints

- **Zero wire changes.** This slice adds no new packet/advertisement format; it reuses the already-merged, already-cross-validated request/response packets. **No new RNS cross-validation fixture.**
- **Allow-policy semantics (RNS-faithful):** `.none` rejects all; `.all` accepts all (identity not required); `.list([Data])` accepts only peers whose `remoteIdentity.hash` (16 bytes) is in the list. An un-identified peer (`remoteIdentity == nil`) is allowed **only** under `.all`.
- **Fallback:** registered+allowed → answered in-library; registered+denied → **silent drop** (the requester's own timeout later fires `requestFailed`); registered+responder-returns-`nil` → drop; **unregistered → forwarded to the app's `delegate.requestReceived` exactly as today** (additive; no behavior change for apps that register nothing).
- **`pathHash = Crypto.truncatedHash(Data(path.utf8))`** (16 bytes). `pathHash` cannot be reversed, so a registration stores the original `path` string (the responder needs it).
- **Two-layer purity:** all new code lives in `ReTiCANode` (TCA layer). `Sources/ReTiCATransport/*` and `Sources/ReTiCA/*` (core) must NOT change. TCA `State` stays `Equatable` — **no closures in State** (handler closure lives in the dependency).
- **Data-slice index safety**, Swift 6 strict concurrency (effect captures must be `Sendable` value types: `Identity`, `RequestResponder`, `Data`, `String` all qualify).
- Build gotcha: signal-11/SIGILL during `swift test` → `swift package clean` then retry (stale cache); never delete State fields to "fix" a crash.
- **Mutation-test discipline** for every new/changed test: run-pass → batch-mutate-fail → revert-pass, before commit.
- **Commit directly to `main`** (no feature branch). **Commit trailers:** `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.

## File Structure

- `Sources/ReTiCANode/RequestPolicy.swift` (**create**, Task 1) — `RequestPolicy`, `RequestRegistration`, `isAllowed`.
- `Sources/ReTiCANode/RequestResponder.swift` (**create**, Task 1) — the `requestResponder` dependency.
- `Tests/ReTiCANodeTests/RequestPolicyTests.swift` (**create**, Task 1).
- `Sources/ReTiCANode/Endpoint.swift` (**modify**, Task 2) — state field, register/deregister actions, dependency, interception.
- `Tests/ReTiCANodeTests/EndpointTests.swift` (**modify**, Tasks 2 & 3).
- `README.md` (**modify**, Task 3).

---

### Task 1: `RequestPolicy` + `RequestRegistration` + `isAllowed` gate + `requestResponder` dependency

**Files:**
- Create: `Sources/ReTiCANode/RequestPolicy.swift`
- Create: `Sources/ReTiCANode/RequestResponder.swift`
- Test: `Tests/ReTiCANodeTests/RequestPolicyTests.swift`

**Interfaces:**
- Consumes: `Identity` (`.hash: Data`, 16 bytes) from `ReTiCA`; `DependencyKey`/`DependencyValues` from `ComposableArchitecture`.
- Produces: `enum RequestPolicy: Equatable, Sendable { case none, all, list([Data]) }`; `struct RequestRegistration: Equatable, Sendable { let path: String; let policy: RequestPolicy }`; `func isAllowed(_ policy: RequestPolicy, _ identity: Identity?) -> Bool`; `struct RequestResponder: Sendable` with `respond: @Sendable (String, Data, Identity?) async -> Data?` + `callAsFunction`, registered at `\.requestResponder`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/RequestPolicyTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCANode
import ReTiCA

@Suite struct RequestPolicyTests {
    let idA = Identity()          // fresh keypair; .hash = truncatedHash(publicKey), 16 bytes
    let idB = Identity()

    @Test func noneRejectsEverything() {
        #expect(isAllowed(.none, idA) == false)
        #expect(isAllowed(.none, nil) == false)
    }

    @Test func allAcceptsWithAndWithoutIdentity() {
        #expect(isAllowed(.all, idA) == true)
        #expect(isAllowed(.all, nil) == true)
    }

    @Test func listAcceptsOnlyListedIdentity() {
        #expect(isAllowed(.list([idA.hash]), idA) == true)
        #expect(isAllowed(.list([idA.hash]), idB) == false)
        #expect(isAllowed(.list([idA.hash]), nil) == false)
        #expect(isAllowed(.list([]), idA) == false)
    }

    @Test func responderTestValueDeclines() async {
        let r = RequestResponder.testValue
        #expect(await r("svc/x", Data(), idA) == nil)
    }

    @Test func customResponderDispatchesByPath() async {
        let r = RequestResponder { path, data, _ in path == "echo" ? data : nil }
        #expect(await r("echo", Data([1, 2, 3]), nil) == Data([1, 2, 3]))
        #expect(await r("other", Data([1, 2, 3]), nil) == nil)
    }
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter RequestPolicyTests`
Expected: FAIL to compile (`RequestPolicy`/`isAllowed`/`RequestResponder` undefined).

- [ ] **Step 3: Create `RequestPolicy.swift`**

Create `Sources/ReTiCANode/RequestPolicy.swift`:

```swift
import Foundation
import ReTiCA

/// Who may invoke a registered request handler. Mirrors RNS ALLOW_NONE / ALLOW_ALL / ALLOW_LIST.
public enum RequestPolicy: Equatable, Sendable {
    case none                 // reject all
    case all                  // accept all (identity not required)
    case list([Data])         // accept only these 16-byte identity hashes
}

/// A registered handler's addressing + policy. `path` is retained because a request arrives only as a
/// `pathHash` (a truncated hash that cannot be reversed), and the responder needs the original string.
public struct RequestRegistration: Equatable, Sendable {
    public let path: String
    public let policy: RequestPolicy
    public init(path: String, policy: RequestPolicy) {
        self.path = path
        self.policy = policy
    }
}

/// Pure allow-gate. `.list` matches the link's identified `remoteIdentity` hash; an un-identified peer
/// (`nil`) is allowed only under `.all`.
public func isAllowed(_ policy: RequestPolicy, _ identity: Identity?) -> Bool {
    switch policy {
    case .none:             return false
    case .all:              return true
    case .list(let hashes): guard let id = identity else { return false }
                            return hashes.contains(id.hash)
    }
}
```

- [ ] **Step 4: Create `RequestResponder.swift`**

Create `Sources/ReTiCANode/RequestResponder.swift` (mirrors the existing `RandomBytesGenerator` dependency style):

```swift
import Foundation
import ComposableArchitecture
import ReTiCA

/// App-supplied generator that answers a registered request. Returns the response payload, or `nil` to
/// decline (no response is sent). One closure dispatches all registered paths (the app switches on `path`),
/// keeping handler closures out of TCA state, which must stay `Equatable`.
public struct RequestResponder: Sendable {
    public var respond: @Sendable (_ path: String, _ data: Data, _ remoteIdentity: Identity?) async -> Data?
    public init(respond: @escaping @Sendable (_ path: String, _ data: Data, _ remoteIdentity: Identity?) async -> Data?) {
        self.respond = respond
    }
    public func callAsFunction(_ path: String, _ data: Data, _ remoteIdentity: Identity?) async -> Data? {
        await respond(path, data, remoteIdentity)
    }
}

extension RequestResponder: DependencyKey {
    /// Declines everything by default, so a store that registers no handler behaves exactly as before.
    public static let liveValue = RequestResponder { _, _, _ in nil }
    public static let testValue = RequestResponder { _, _, _ in nil }
    public static let previewValue = testValue
}

extension DependencyValues {
    public var requestResponder: RequestResponder {
        get { self[RequestResponder.self] }
        set { self[RequestResponder.self] = newValue }
    }
}
```

- [ ] **Step 5: Run to verify it passes**

Run: `swift test --filter RequestPolicyTests`
Expected: PASS (all 5 tests).

- [ ] **Step 6: Mutation sweep**

Apply each, run `swift test --filter RequestPolicyTests`, confirm the named test fails, revert; final green:
- `.none: return false` → `return true` → `noneRejectsEverything` fails.
- `.all: return true` → `return false` → `allAcceptsWithAndWithoutIdentity` fails.
- `.list` `guard let id = identity else { return false }` → `else { return true }` → `listAcceptsOnlyListedIdentity` (nil case) fails.
- `hashes.contains(id.hash)` → `!hashes.contains(id.hash)` → `listAcceptsOnlyListedIdentity` fails.

- [ ] **Step 7: Commit**

```
git add Sources/ReTiCANode/RequestPolicy.swift Sources/ReTiCANode/RequestResponder.swift Tests/ReTiCANodeTests/RequestPolicyTests.swift
git commit -F /tmp/ReTiCA/commit-rt1.txt
```
(`/tmp/ReTiCA/commit-rt1.txt` first line: `feat: RequestPolicy allow-gate + requestResponder dependency`, blank line, trailers.)

---

### Task 2: `Endpoint` registry state, register/deregister actions, and request interception

**Files:**
- Modify: `Sources/ReTiCANode/Endpoint.swift`
- Test: `Tests/ReTiCANodeTests/EndpointTests.swift`

**Interfaces:**
- Consumes: Task 1's `RequestPolicy`/`RequestRegistration`/`isAllowed`/`requestResponder`; `Crypto.truncatedHash` (public, from `ReTiCA`); `state.links[id:]?.remoteIdentity` (public `Identity?`); the existing `sendResponseOverLink` action.
- Produces: `Endpoint.State.registrations: [Data: RequestRegistration]`; `Endpoint.Action.registerRequestHandler(path:policy:)` / `.deregisterRequestHandler(path:)`; the interception routing registered/allowed/denied/unregistered requests.

- [ ] **Step 1: Add the state field**

In `Sources/ReTiCANode/Endpoint.swift`, add to `State` after `public var links` (line 15):

```swift
        public var registrations: [Data: RequestRegistration] = [:]
```

(It has a default, so the existing `init` and all call sites compile unchanged. `[Data: RequestRegistration]` is `Equatable` because `RequestRegistration` is.)

- [ ] **Step 2: Add the two actions**

After the `case sendResponseOverLink(...)` line (line 43), add:

```swift
        case registerRequestHandler(path: String, policy: RequestPolicy)
        case deregisterRequestHandler(path: String)
```

- [ ] **Step 3: Declare the dependency**

After `@Dependency(\.uuid) var uuid` (line 67), add:

```swift
    @Dependency(\.requestResponder) var requestResponder
```

- [ ] **Step 4: Handle the register/deregister actions**

In the `Reduce` switch, add these cases (e.g. right after the `case let .closeLink(linkID):` block, before the `.link(.element(...))` delegate cases):

```swift
            case let .registerRequestHandler(path, policy):
                state.registrations[Crypto.truncatedHash(Data(path.utf8))] = RequestRegistration(path: path, policy: policy)
                return .none
            case let .deregisterRequestHandler(path):
                state.registrations[Crypto.truncatedHash(Data(path.utf8))] = nil
                return .none
```

- [ ] **Step 5: Replace the `requestReceived` interception**

Replace the existing case (lines 175-177):

```swift
            case let .link(.element(elementID, .delegate(.requestReceived(rid, ph, data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.requestReceived(linkID: linkID, requestID: rid, pathHash: ph, data: data)))
```

with:

```swift
            case let .link(.element(elementID, .delegate(.requestReceived(rid, ph, data)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                guard let reg = state.registrations[ph] else {
                    // No registered handler for this path: surface to the app exactly as before.
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
```

(`Crypto` is available via the existing `import ReTiCA`. `Identity`, `RequestResponder`, `Data`, `String` are all `Sendable`, so the `.run` capture is Swift 6-clean.)

- [ ] **Step 6: Write the tests**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift`. These build an `Endpoint` store with one active link already present and exercise the interception by sending the child's `requestReceived` delegate action directly. A **spy responder** (records whether it was called) gives positive assertions for the allowed/denied/unregistered paths.

```swift
// Build an Endpoint store holding one active link (so requestReceived can be routed), with the given
// registrations and responder. `remoteIdentity` is optional (nil = un-identified peer).
@MainActor
private func endpointWithActiveLink(
    linkID: Data,
    remoteIdentity: Identity?,
    registrations: [Data: RequestRegistration],
    responder: RequestResponder,
    _ clock: TestClock<Duration>
) -> (TestStore<Endpoint.State, Endpoint.Action>, UUID) {
    var s = Endpoint.State(host: "h", port: 4242, reconnectOnDrop: false)
    let elementID = UUID(0)
    var link = LinkSession.State(id: elementID, responderFor: Identity(),
                                 destinationHash: Data(repeating: 0x02, count: 16), interfaceID: InterfaceID("tcp"))
    link.status = .active
    link.sessionKey = Data(repeating: 0x09, count: 32)
    link.linkID = linkID
    link.remoteIdentity = remoteIdentity
    s.links.append(link)
    s.registrations = registrations
    let store = TestStore(initialState: s) { Endpoint() } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
        $0.requestResponder = responder
    }
    store.exhaustivity = .off
    return (store, elementID)
}

private func pathHash(_ p: String) -> Data { Crypto.truncatedHash(Data(p.utf8)) }

@Test @MainActor func registerThenDeregisterMutatesRegistrations() async {
    let clock = TestClock()
    let store = TestStore(initialState: Endpoint.State(host: "h", port: 1)) { Endpoint() } withDependencies: {
        $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    await store.send(.registerRequestHandler(path: "svc/echo", policy: .all))
    #expect(store.state.registrations[pathHash("svc/echo")]?.policy == .all)
    #expect(store.state.registrations[pathHash("svc/echo")]?.path == "svc/echo")
    await store.send(.deregisterRequestHandler(path: "svc/echo"))
    #expect(store.state.registrations[pathHash("svc/echo")] == nil)
}

@Test @MainActor func unregisteredRequestForwardsToApp() async {
    let clock = TestClock()
    let called = LockIsolated(false)
    let responder = RequestResponder { _, _, _ in called.setValue(true); return Data() }
    let linkID = Data(repeating: 0xAB, count: 16)
    let (store, _) = endpointWithActiveLink(linkID: linkID, remoteIdentity: nil,
                                            registrations: [:], responder: responder, clock)
    await store.send(.link(.element(id: UUID(0),
        action: .delegate(.requestReceived(requestID: Data([1]), pathHash: pathHash("svc/x"), data: Data([9]))))))
    await store.receive { action in
        if case let .delegate(.requestReceived(lid, rid, ph, d)) = action {
            return lid == linkID && rid == Data([1]) && ph == pathHash("svc/x") && d == Data([9])
        }
        return false
    }
    #expect(called.value == false)     // responder never consulted for an unregistered path
}

@Test @MainActor func allowedRequestAutoRespondsAndDoesNotSurface() async {
    let clock = TestClock()
    let called = LockIsolated(false)
    let responder = RequestResponder { path, data, _ in
        called.setValue(true); return path == "svc/echo" ? data : nil
    }
    let linkID = Data(repeating: 0xAB, count: 16)
    let (store, _) = endpointWithActiveLink(linkID: linkID, remoteIdentity: nil,
        registrations: [pathHash("svc/echo"): RequestRegistration(path: "svc/echo", policy: .all)],
        responder: responder, clock)
    await store.send(.link(.element(id: UUID(0),
        action: .delegate(.requestReceived(requestID: Data([7]), pathHash: pathHash("svc/echo"), data: Data([4, 2]))))))
    await store.receive { action in
        if case let .sendResponseOverLink(lid, rid, d) = action {
            return lid == linkID && rid == Data([7]) && d == Data([4, 2])   // echoed payload
        }
        return false
    }
    #expect(called.value == true)
}

@Test @MainActor func deniedRequestDropsWithoutRespondingOrSurfacing() async {
    let clock = TestClock()
    let called = LockIsolated(false)
    let responder = RequestResponder { _, _, _ in called.setValue(true); return Data([0]) }
    let linkID = Data(repeating: 0xAB, count: 16)
    let (store, _) = endpointWithActiveLink(linkID: linkID, remoteIdentity: nil,
        registrations: [pathHash("svc/secret"): RequestRegistration(path: "svc/secret", policy: .none)],
        responder: responder, clock)
    await store.send(.link(.element(id: UUID(0),
        action: .delegate(.requestReceived(requestID: Data([1]), pathHash: pathHash("svc/secret"), data: Data([9]))))))
    #expect(called.value == false)     // gate blocks before the responder; nothing sent, nothing surfaced
}

@Test @MainActor func listPolicyGatesOnRemoteIdentity() async {
    let clock = TestClock()
    let allowed = Identity()
    let called = LockIsolated(false)
    let responder = RequestResponder { _, data, _ in called.setValue(true); return data }
    let linkID = Data(repeating: 0xAB, count: 16)
    // Peer identity is NOT on the allowed list → denied.
    let (store, _) = endpointWithActiveLink(linkID: linkID, remoteIdentity: Identity(),
        registrations: [pathHash("svc/p"): RequestRegistration(path: "svc/p", policy: .list([allowed.hash]))],
        responder: responder, clock)
    await store.send(.link(.element(id: UUID(0),
        action: .delegate(.requestReceived(requestID: Data([1]), pathHash: pathHash("svc/p"), data: Data([9]))))))
    #expect(called.value == false)
}
```

> Implementer notes:
> - Verify the exact `LinkSession.State` initializer label used elsewhere in this test file (the codebase builds responder links via `LinkSession.State(id:responderFor:destinationHash:interfaceID:)`). If `status`/`sessionKey`/`linkID`/`remoteIdentity` are not all writable `public var`s, mirror however the existing two-store tests place an active link into state (they establish it via the handshake pump — you may instead extend that helper). The REQUIRED assertions are: allowed→`sendResponseOverLink` with the responder's bytes + responder consulted; denied/unregistered→responder NOT consulted; unregistered→`delegate.requestReceived` forwarded; register/deregister mutate `registrations`. Do not weaken these.
> - The `allowed…` test lets the emitted `sendResponseOverLink` cascade into the link's inline `sendResponse` (response is 2 bytes, well under 431) → a `transmit` → `interface(.send)` → the no-op `tcpConnection.send`. With `exhaustivity = .off` this settles; if any effect dangles at teardown, drive it to quiescence (the response is inline, so no transfer/watchdog is spawned).
> - Confirm sending `.link(.element(id:, .delegate(.requestReceived(...))))` routes cleanly (the child `LinkSession` returns `.none` for its own inbound `.delegate` output, then the parent interception fires). If the child rejects an inbound delegate action, assert on the parent effect via whatever routing the existing tests use.

- [ ] **Step 7: Run to verify**

Run: `swift test --filter Endpoint`
Expected: PASS (existing Endpoint tests + 5 new).

- [ ] **Step 8: Mutation sweep**

Apply each, run `swift test --filter Endpoint`, confirm the named test fails, revert; final green:
- Interception: change `guard isAllowed(reg.policy, identity) else { return .none }` to `guard true else { return .none }` → `deniedRequestDropsWithoutRespondingOrSurfacing` and `listPolicyGatesOnRemoteIdentity` fail (responder gets called).
- Interception: change the unregistered branch `return .send(.delegate(.requestReceived(...)))` to `return .none` → `unregisteredRequestForwardsToApp` fails (no forward).
- Responder call: change `data: response` to `data: Data()` → `allowedRequestAutoRespondsAndDoesNotSurface` fails (wrong bytes).
- `registerRequestHandler`: change stored value to `RequestRegistration(path: path, policy: .none)` → `registerThenDeregisterMutatesRegistrations` fails (policy mismatch).

- [ ] **Step 9: Commit**

```
git add Sources/ReTiCANode/Endpoint.swift Tests/ReTiCANodeTests/EndpointTests.swift
git commit -F /tmp/ReTiCA/commit-rt2.txt
```
(First line: `feat: Endpoint request handler registry + allow-gated auto-response`, blank line, trailers.)

---

### Task 3: End-to-end auto-answer (incl. large response), full-suite gate, README

**Files:**
- Modify: `Tests/ReTiCANodeTests/EndpointTests.swift`
- Modify: `README.md`

**Interfaces:**
- Consumes: everything from Tasks 1–2, plus the existing two-`Endpoint` link-establishment + resource-pump idioms already in `EndpointTests.swift`.

- [ ] **Step 1: Write the end-to-end auto-answer test(s)**

Append to `Tests/ReTiCANodeTests/EndpointTests.swift`. Model these on the EXISTING working two-store tests — `twoEndpointsIdentifyAndRoundTripARequest` (link establishment + a request round-trip) and `twoEndpointsRoundTripALargeRequestAndResponse` (pumping a multi-part response Resource both directions). COPY their proven `make(...)`/handshake-pump/frame-relay idiom; the code below is the required shape and assertions, not a novel harness.

Two cases:

1. **`handlerAutoAnswersInlineRequestWithoutSurfacing`** — B registers `("svc/echo", .all)` with an echoing `requestResponder`; A `sendRequestOverLink`s a small payload; A receives `responseReceived` with the echoed bytes; **B never surfaces `delegate.requestReceived`** (the library answered it). Wire B's store with `$0.requestResponder = RequestResponder { path, data, _ in path == "svc/echo" ? data : nil }` and, after the link is active, `await b.send(.registerRequestHandler(path: "svc/echo", policy: .all))`.

2. **`handlerAutoAnswersWithLargeResourceResponse`** — same setup, but the responder returns a **> 431-byte** payload, so B's auto-response rides a Resource. Pump the multi-part response B→A (reuse the pump from `twoEndpointsRoundTripALargeRequestAndResponse`) and assert A's `responseReceived` carries the exact large bytes. This proves an in-library handler triggers the large-response Resource path.

Required assertions (do NOT weaken): A observes `responseReceived` matching the request's `requestID` with the exact responder-produced bytes; B does NOT emit `delegate.requestReceived` for the handled path (assert via a `LockIsolated` flag set in a B-side observation, or by confirming the pump reaches `responseReceived` on A without B surfacing the request). For case 2 both the response payload is > 431 bytes and the transfer is genuinely multi-part.

> Implementer note: the exact `.receive`/relay sequence is TCA-version-dependent — the two named existing tests are the source of truth for how two `Endpoint` stores establish a link and how a response Resource is pumped. Reuse their structure; adapt only the responder wiring (`registerRequestHandler` on B + the `requestResponder` dependency) and the assertions above. If, after genuinely studying those tests, the large-response pump proves intractable in the available effort, deliver case 1 (inline) fully and report case 2 as BLOCKED with exactly where the pump stalls — do NOT fake it or weaken assertions.

- [ ] **Step 2: Run the E2E filter**

Run: `swift test --filter Endpoint`
Expected: PASS (both new E2E tests plus all prior Endpoint tests).

- [ ] **Step 3: Full-suite gate**

Run: `swift test`
Expected: PASS. Report the pass/skip counts.

- [ ] **Step 4: Mutation sweep (cross-cutting)**

Apply each, run `swift test --filter Endpoint`, confirm the expected failure, revert; final full `swift test` green:
- In `Endpoint`'s interception, change the responder send `data: response` to `data: Data()` → `handlerAutoAnswersInlineRequestWithoutSurfacing` fails (A's `responseReceived` bytes wrong).
- In the interception, change `guard isAllowed(reg.policy, identity) else { return .none }` to always allow AND change the unregistered branch to also auto-respond — simpler: change the whole registered branch's responder path to `return .send(.delegate(.requestReceived(...)))` (i.e. surface instead of answer) → `handlerAutoAnswersInlineRequestWithoutSurfacing` fails (B surfaces the request / A never gets a response).

- [ ] **Step 5: Commit the tests**

```
git add Tests/ReTiCANodeTests/EndpointTests.swift
git commit -F /tmp/ReTiCA/commit-rt3a.txt
```
(First line: `test: end-to-end in-library request handler auto-response (inline + large)`, blank line, trailers.)

- [ ] **Step 6: Update the README**

In `README.md`, extend the request/response section to document the registry. Replace the stale app-side-only paragraph (the one noting "RNS's in-library handler-registry/allow-policy remains a future slice") with:

```markdown
A node can register in-library request handlers instead of answering every request in the app. Call
`registerRequestHandler(path:policy:)` on the endpoint and supply a `requestResponder` dependency (one
closure that switches on `path` and returns the response bytes, or `nil` to decline). When a request
arrives for a registered path, the library checks the allow-policy against the link's identified
`remoteIdentity` — `.none` rejects all, `.all` accepts all, `.list([identityHash])` accepts only listed
peers (an un-identified peer is allowed only under `.all`) — and, if allowed, generates and sends the
response automatically (routing over a Resource when it exceeds 431 bytes). Denied requests are dropped;
requests for unregistered paths are still surfaced to the app's `requestReceived` delegate, so app-side
handling remains available.
```

Also remove any remaining "handler-registry/allow-policy … future slice" wording elsewhere in the README (e.g. a "Not Yet Implemented" list).

- [ ] **Step 7: Commit the README**

```
git add README.md
git commit -F /tmp/ReTiCA/commit-rt3b.txt
```
(First line: `docs: in-library request handler registry + allow-policy`, blank line, trailers.)

---

## Self-Review

**Spec coverage:**
- `RequestPolicy` (.none/.all/.list) + `RequestRegistration` + pure `isAllowed` gate → Task 1. ✓
- `requestResponder` dependency (async, nil-declines, unimplemented default) → Task 1. ✓
- `Endpoint` registry state + register/deregister actions → Task 2. ✓
- Interception: registered+allowed→responder→`sendResponseOverLink`; denied→drop; unregistered→forward; nil→drop → Task 2. ✓
- Identity semantics (`.list` vs `remoteIdentity.hash`; un-identified allowed only under `.all`) → Tasks 1 & 2. ✓
- E2E auto-answer incl. large-response Resource; full gate; README → Task 3. ✓
- Zero wire changes / no new cross-val fixture; `LinkSession`/`ResourceTransfer`/core untouched → Global Constraints, respected across all tasks. ✓
- Deferred (file responses, metadata, compression, per-destination scoping) → untouched. ✓

**Placeholder scan:** No TBD/TODO in production steps. The Task 2 test helper note and the Task 3 pump note are explicit implementer guidance (the effect-draining / two-store pump shape is TCA-version-dependent) with the assertions locked — not missing implementation.

**Type consistency:** `RequestPolicy`/`RequestRegistration`/`isAllowed(_:_:)`/`RequestResponder.respond(_:_:_:)`/`\.requestResponder`, `registrations: [Data: RequestRegistration]`, `registerRequestHandler(path:policy:)`/`deregisterRequestHandler(path:)`, `pathHash = Crypto.truncatedHash(Data(path.utf8))`, `Identity.hash`, and the reused `sendResponseOverLink(linkID:requestID:data:)` are used identically across Tasks 1–3. The dependency file mirrors the existing `RandomBytesGenerator` shape (struct + `callAsFunction` + `DependencyKey` live/test/preview + `DependencyValues` accessor).
