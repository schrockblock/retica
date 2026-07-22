# In-Library Request Handler Registry + Allow-Policy — Design

**Status:** Approved (design phase)
**Date:** 2026-07-22
**Depends on:** the merged Link IDENTIFY + inline request/response slice and the large (Resource-based)
request/response slice.

## Goal

Let a node register per-path request handlers with an allow-policy so the library answers matching
requests directly, instead of surfacing every request to the app. Unregistered paths still fall through to
the app's existing `requestReceived` delegate. This slice is **purely additive** and introduces **zero wire
changes** — it is an in-library orchestration layer on top of the already-merged, already-cross-validated
request/response packets.

## Scope

**In scope**

1. A `RequestPolicy` value type (`.none`/`.all`/`.list([Data])`) and a pure `isAllowed(policy, identity)`
   gate.
2. A `requestResponder` dependency: one app-supplied async closure that maps `(path, data,
   remoteIdentity) -> Data?` (the response bytes, or `nil` to decline).
3. `Endpoint` state + actions to register/deregister handlers keyed by `pathHash`, and interception of the
   bubbling `requestReceived` so registered+allowed requests are answered in-library, denied requests are
   dropped, and unregistered requests are forwarded to the app unchanged.

**Explicitly deferred (out of scope)**

- File-response resources, response metadata, request `progress` callbacks, auto-compression.
- Per-`Destination` scoping of handlers (this slice registers at the `Endpoint` level, applying to all
  inbound links). If multi-destination scoping is needed later, it is its own follow-up.
- Any change to the wire format, `LinkSession`, `ResourceTransfer`, or the `ReTiCA` core.

## Reference mechanics (Python-RNS)

- `Link.register_request_handler(path, response_generator, allow, allowed_list)` registers a path handler.
- `ALLOW_NONE` rejects all; `ALLOW_ALL` accepts all; `ALLOW_LIST` accepts only peers whose identity hash is
  in `allowed_list`.
- The allow-check is against the **link's identified remote identity**. A disallowed request is silently
  ignored (the requester's own timeout eventually fires).
- We follow these semantics, with one deliberate ergonomic choice: the registry lives at the `Endpoint`
  (node) level and applies to all inbound links, rather than being registered per-`Link` object.

## Current state (what exists / what's missing)

- `LinkSession` surfaces every inbound request as `delegate(.requestReceived(requestID:pathHash:data:))`
  (both the inline `.request` packet path and the completed request-Resource interception). `pathHash =
  Crypto.truncatedHash(Data(path.utf8))` (16 bytes). `LinkSession.State.remoteIdentity: Identity?` is set
  only after IDENTIFY (responder side).
- `Endpoint` bubbles this up as `delegate(.requestReceived(linkID:requestID:pathHash:data:))` and exposes
  `sendRequestOverLink`/`sendResponseOverLink`. `Endpoint.State` holds `links: IdentifiedArrayOf<...>`;
  each element carries `linkID` and `remoteIdentity`. There is **no** handler registry today; the app
  enforces its own policy and generates responses.
- `pathHash` cannot be reversed to the path string, so a registry must store the original path alongside
  the policy and match by recomputing hashes.
- `Identity` has a 16-byte `hash` (used for `.list` membership).
- `sendResponseOverLink` already routes responses > `requestMDU` (431 bytes) as a Resource, so large
  auto-generated responses work with no extra code.

## Architecture

All new logic lives at the `Endpoint` layer (`Sources/ReTiCANode/`). `LinkSession`, `ResourceTransfer`, and
the `ReTiCA` core are untouched.

### New value types (`Sources/ReTiCANode/RequestPolicy.swift`)

```swift
public enum RequestPolicy: Equatable, Sendable {
    case none                 // reject all
    case all                  // accept all (identity not required)
    case list([Data])         // accept only these 16-byte identity hashes
}

public struct RequestRegistration: Equatable, Sendable {
    public let path: String
    public let policy: RequestPolicy
}

// Pure gate — no dependencies, fully unit-testable.
public func isAllowed(_ policy: RequestPolicy, _ identity: Identity?) -> Bool {
    switch policy {
    case .none:             return false
    case .all:              return true
    case .list(let hashes): guard let id = identity else { return false }
                            return hashes.contains(id.hash)
    }
}
```

### New dependency (`Sources/ReTiCANode/RequestResponder.swift`)

```swift
public struct RequestResponder: Sendable {
    public var respond: @Sendable (_ path: String, _ data: Data, _ remoteIdentity: Identity?) async -> Data?
}

extension RequestResponder: DependencyKey {
    // Unimplemented default declines everything (returns nil), so a store that never
    // registers a handler behaves exactly as today.
    public static let liveValue = RequestResponder { _, _, _ in nil }
    public static let testValue = RequestResponder { _, _, _ in nil }
}

extension DependencyValues {
    public var requestResponder: RequestResponder {
        get { self[RequestResponder.self] }
        set { self[RequestResponder.self] = newValue }
    }
}
```

The app supplies one closure at store construction; it switches on `path` internally and returns response
bytes (or `nil` to decline). Returning `nil` drops the request without a response.

### `Endpoint` changes (`Sources/ReTiCANode/Endpoint.swift`)

- **State:** `public var registrations: [Data: RequestRegistration] = [:]` keyed by `pathHash`.
- **Actions:**
  - `registerRequestHandler(path: String, policy: RequestPolicy)` → compute `pathHash =
    Crypto.truncatedHash(Data(path.utf8))`; set `state.registrations[pathHash] = RequestRegistration(path:
    path, policy: policy)`. Re-registering a path overwrites.
  - `deregisterRequestHandler(path: String)` → remove `state.registrations[Crypto.truncatedHash(...)]`.
- **Interception** of `.link(.element(id, .delegate(.requestReceived(rid, ph, data))))` (replacing the
  current always-forward):
  - `guard let reg = state.registrations[ph]` — else forward `delegate(.requestReceived(linkID:...))` to the
    app exactly as today (unregistered fall-through).
  - `let identity = state.links[id]?.remoteIdentity`.
  - `guard isAllowed(reg.policy, identity) else { return .none }` — denied → silent drop.
  - allowed → capture `reg.path`, `rid`, `data`, `identity`, and this link's `linkID`, then run an effect:
    ```swift
    @Dependency(\.requestResponder) var requestResponder
    return .run { send in
        if let response = await requestResponder.respond(path, data, identity) {
            await send(.sendResponseOverLink(linkID: linkID, requestID: rid, data: response))
        }
    }
    ```
    (`nil` response → nothing sent.)

## Data flow

1. App calls `.registerRequestHandler(path: "svc/echo", policy: .all)` and constructs the store with a
   `requestResponder` that answers `"svc/echo"`.
2. A peer opens a link, optionally IDENTIFYs, and sends a request to `"svc/echo"`.
3. `LinkSession` surfaces `requestReceived(rid, pathHash, data)` → `Endpoint` receives the bubbled action.
4. `Endpoint` finds the registration for `pathHash`, evaluates `.all` → allowed, runs the responder effect,
   and dispatches `sendResponseOverLink(linkID, rid, response)`. If the response exceeds 431 bytes it
   auto-routes as a Resource (existing behavior).
5. A request to an **unregistered** path reaches the app's `delegate.requestReceived` unchanged.

## Error handling

- **Denied** (policy rejects, including `.list` with an un-identified or non-listed peer) → silent drop.
  The requester receives no response and its existing timeout later fires `requestFailed` — RNS-faithful.
- **Responder returns `nil`** → drop, no response sent.
- **Un-identified peer** (`remoteIdentity == nil`): allowed only under `.all`; denied under `.list`/`.none`.
- **`pathHash` collision** (two distinct paths hashing to the same 16 bytes): astronomically unlikely; the
  map is keyed by `pathHash`, so the last registration wins and its stored `path` is what the responder
  receives.
- **Deregister / overwrite:** deregistering a path removes it (subsequent requests fall through to the app);
  re-registering overwrites the policy.

## Testing

- **Pure `isAllowed`** unit tests: `.none` (always false), `.all` (true with and without identity), `.list`
  (identity absent → false; on-list → true; off-list → false).
- **`Endpoint` reducer tests** (TestStore): registered+allowed → the responder runs and a
  `sendResponseOverLink` (→ transmit) is emitted with the responder's bytes, and the app's
  `delegate.requestReceived` is NOT emitted; registered+denied → no response, not surfaced; unregistered →
  `delegate.requestReceived` surfaced to the app; responder returns `nil` → no response; `.list` gating uses
  the link's `remoteIdentity`; register/deregister mutate `state.registrations`.
- **E2E:** two `Endpoint`s establish a link; the responder registers `("svc/echo", .all)` with a
  `requestResponder` that echoes; the requester `sendRequestOverLink`s and receives `responseReceived` with
  the echoed bytes — the responder side never surfaces `requestReceived`. Include one case whose response
  exceeds 431 bytes to confirm the large-response Resource path auto-triggers from an in-library handler.
- **No new RNS cross-validation fixture** — the wire bytes are identical to the existing, already
  cross-validated request/response packets; this slice introduces no new wire format.
- Every new/changed test is mutation-swept (run-pass → batch-mutate-fail → revert-pass). Committed directly
  to `main` (no feature branch).

## Known simplifications (carry to review)

- Handlers register at the `Endpoint` (node) level, not per-`Link` or per-`Destination` (RNS registers on a
  destination/link). Sufficient for a single-service node; per-destination scoping is a deferred follow-up.
- One `requestResponder` closure dispatches all paths (the app switches on `path`), rather than a per-path
  closure stored in the registry — this keeps closures out of TCA State (which must stay `Equatable`) while
  still answering in-library.
- The allow-policy gates on the link's `remoteIdentity` only; there is no per-request signature check beyond
  what IDENTIFY already established.
- Denied and `nil`-response requests are dropped silently (no `requestDenied` delegate); the requester
  observes only its own timeout.
