# Large (Resource-based) Request/Response — Design

**Status:** Approved (design phase)
**Date:** 2026-07-22
**Depends on:** the merged Resource stack (6a–6c + Link/Resource integration + HMU) and the merged Link
IDENTIFY + inline request/response slice.

## Goal

Transfer requests and responses whose packed msgpack exceeds `Link.MDU` (431 bytes) as Resources, so
request/response works for any payload size — byte-compatible with Python-RNS 1.3.8.

## Scope

**In scope**

1. The sender `ResourceTransfer` can carry a `request_id` and an `is_request`/`is_response` marker in its
   advertisement (`q` + flag bits 3/4).
2. `LinkSession`'s oversize `sendRequest`/`sendResponse` branches (currently `.none` stubs) spawn a
   request/response Resource.
3. `LinkSession` routes an inbound request/response-Resource: the ADV-spawn gates a response by pending
   `request_id` (and cancels the request timeout), and a completed request/response transfer surfaces
   `requestReceived`/`responseReceived` (matched by `request_id`) instead of `resourceReceived`.

**Explicitly deferred (out of scope)**

- The in-library handler registry + allow-policy (`ALLOW_NONE`/`ALLOW_ALL`/`ALLOW_LIST`) — app-side policy
  continues, as in the inline request/response slice. Its own follow-up.
- File-response resources + response metadata; request `progress` callbacks; auto-compression.

## Reference mechanics (Python-RNS 1.3.8)

- **Advertisement flags** (`f` byte): bit 3 (`0x08`) = `u` (is_request), bit 4 (`0x10`) = `p` (is_response),
  mutually exclusive; `q` = `request_id` (16-byte msgpack `bin`, or nil). Set from `(q != None,
  is_response)`.
- **Large REQUEST** (`Link.request`, packed > mdu): `request_id = truncated_hash(packed_request)` — the
  msgpack blob itself, NOT a packet hash; `Resource(packed_request, is_response=False, request_id=...)`.
  The responder, on completion, **recomputes** `request_id = truncated_hash(reassembled bytes)` (it does
  NOT read `q`), unpacks `[time, path_hash, data]`, and handles it.
- **Large RESPONSE** (`handle_request`, packed > mdu): `packed_response = msgpack([request_id, response])`;
  `Resource(packed_response, is_response=True, request_id=...)`. The requester reads `q` from the ADV
  (`read_request_id`) to match `pending_requests`, accepts, and on completion unpacks `[request_id,
  response_data]`.
- `request_id` derivations differ by path: inline request → the REQUEST packet's truncated hash; large
  request → `truncated_hash(packed_request)`. Each request is internally consistent (requester and
  responder use the same derivation), and the response echoes the request's `request_id` regardless of
  path.
- `Link.MDU` = 431 bytes (the inline threshold, our `requestMDU`).

## Current state (what exists / what's missing)

- `ResourceAdvertisement` fully models `requestID` (`q`, nil→msgpack null) + `isRequest`/`isResponse`
  accessors (bits 3/4); pack/unpack are correct. **No** static "inspect raw ADV" helpers (we always fully
  `unpack`).
- `ResourceTransfer.init(sending:)` hard-codes `requestID: nil, flags: 0x01` — no way to set `q`/flags.
  `State` has no request/response marker; the receiver `.accept` ignores `requestID`/`isRequest`/
  `isResponse`; completion surfaces raw bytes via `delegate(.received)`.
- `LinkSession.sendRequest`/`sendResponse` oversize branches `return .none` (stubs). The ADV-spawn always
  spawns a plain receiver (ignores the flags). The transfer `.received` interception always maps to
  `resourceReceived`. `LinkSession.State` keeps each transfer's parsed `advertisement` (so it can route by
  reading `transfer.advertisement.isRequest/.isResponse` — no new field needed). `remoteIdentity` is on
  State.

## Architecture

The only `ResourceTransfer` change is sender-side ADV plumbing. All routing lives in `LinkSession`, which
already hosts the transfers and holds `pendingRequests`. **`Endpoint` is unchanged** — the existing
`sendRequestOverLink`/`sendResponseOverLink` actions and `requestReceived`/`responseReceived`/
`requestFailed` delegates handle large payloads transparently.

### `ResourceTransfer` (`Sources/ReTiCATransport/ResourceTransfer.swift`)

`init(sending:)` gains two defaulted parameters:
```
public init(sending data: Data, linkID:, sessionKey:, interfaceID:, prefix:, randomHash:, sdu:,
            requestID: Data? = nil, isResponse: Bool = false, rtt: Duration = .seconds(1), id: UUID = UUID())
```
The advertisement is built with:
```
let advFlags: UInt8 = 0x01 | (requestID != nil ? (isResponse ? 0x10 : 0x08) : 0)
ResourceAdvertisement(... requestID: requestID, flags: advFlags, ...)
```
No new `State` field, no new delegate. Existing `sending:` call sites (plain resources) pass neither new
parameter → `requestID: nil, flags: 0x01`, unchanged behavior.

### `LinkSession` (`Sources/ReTiCATransport/LinkSession.swift`)

Add a `static func requestResourcePrefix` helper is not needed; reuse the existing `randomBytes(8)` split
used by `sendResource`.

**`sendRequest` oversize branch** (replace the `else` after `guard packed.count <= requestMDU`): compute
`requestID = Crypto.truncatedHash(packed)`; `state.pendingRequests.insert(requestID)`; build
`prefix`/`randomHash` from `randomBytes(8)`; append `ResourceTransfer.State(sending: packed, …,
requestID: requestID, isResponse: false, …)`; dispatch `.transfer(.element(id:action:.advertise))` AND arm
the request timeout `.run { clock.sleep(rtt·6+11.25); send(.requestDeadline(requestID)) }.cancellable(id:
CancelID.request(requestID), cancelInFlight: true)`.

**`sendResponse` oversize branch:** `packed = MsgPack([.bin(requestID), .bin(data)])`; build
`prefix`/`randomHash`; append `ResourceTransfer.State(sending: packed, …, requestID: requestID,
isResponse: true, …)`; dispatch `.advertise`. No pending/timeout.

**ADV-spawn** (`.resourceAdvertisement`, after unpack + resourceHash dedup): if `adv.isResponse` and
`!state.pendingRequests.contains(adv.requestID ?? Data())` → `.none` (not ours). If `adv.isResponse` and it
IS pending → include `.cancel(id: CancelID.request(adv.requestID!))` in the returned effect (stop the
request timeout while the response downloads). Otherwise spawn as today (request / matched-response / plain
all take the existing spawn path).

**Transfer-completion interception** — the existing `.transfer(.element(elementID, .delegate(...)))` cases
gain request/response routing by reading `let t = state.transfers[id: elementID]` (its `role` +
`advertisement`):
- **`.received(payload)`** (receiver):
  - `t?.advertisement?.isRequest == true` → `guard case .array([_, .bin(pathHash), .bin(data)]) =
    MsgPack.decodeValue(payload)` → `delegate(.requestReceived(requestID: Crypto.truncatedHash(payload),
    pathHash: pathHash, data: data))`.
  - `t?.advertisement?.isResponse == true` → `guard case .array([.bin(rid), .bin(data)]) =
    MsgPack.decodeValue(payload), state.pendingRequests.contains(rid)` → remove `rid` +
    `delegate(.responseReceived(requestID: rid, data: data))`.
  - else → `delegate(.resourceReceived(payload))` (existing).
- **`.concluded`** (sender proof validated): if the transfer is a request/response resource (its ADV has
  `isRequest`/`isResponse`) → `.none` (internal delivery, nothing to surface); else
  `resourceConcluded(hash)` (existing).
- **`.failed`**: if the transfer is a request-sender OR a response-receiver tied to a pending `request_id`
  (its ADV `requestID` is in `pendingRequests`) → remove it + `delegate(.requestFailed(requestID))`; else
  `resourceFailed(hash)` (existing).

## Data flow (large round-trip)

1. Requester `sendRequestOverLink(path, data)` where `msgpack([time, path_hash, data]) > 431` → LinkSession
   spawns a sender request-Resource (`is_request`, `q = truncatedHash(packed)`), records `request_id` in
   `pendingRequests`, arms the timeout.
2. Responder's ADV-spawn sees `is_request` → spawns a receiver; on completion the assembled bytes =
   `packed_request`; LinkSession recomputes `request_id = truncatedHash(payload)`, unpacks, and surfaces
   `requestReceived(request_id, path_hash, data)`.
3. App replies `sendResponseOverLink(request_id, data)` where `msgpack([request_id, data]) > 431` →
   responder spawns a sender response-Resource (`is_response`, `q = request_id`).
4. Requester's ADV-spawn sees `is_response`, matches `q` against `pendingRequests`, cancels the timeout,
   spawns a receiver; on completion unpacks `[request_id, data]` and surfaces `responseReceived(request_id,
   data)`, removing the pending entry.

Cross-paths (inline request + large response, and vice versa) correlate because the response always echoes
the request's `request_id`.

## Error handling

- A response ADV whose `q` isn't in `pendingRequests` → ignored (not spawned).
- A malformed request/response resource payload (msgpack shape mismatch) → dropped (`.none`); the transfer
  itself already completed.
- A failed request/response resource → `requestFailed(request_id)` on the requester side (request-sender
  fail, or response-receiver fail) + pending removed; swallowed on the responder side.
- Timeout is armed at send and cancelled when the response ADV arrives (a simplification vs RNS's
  arm-at-delivery; a very slow large-request *send* could time out before the response — acceptable,
  noted).

## Testing

- **`ResourceTransfer`:** `init(sending:, requestID:, isResponse:)` builds an advertisement with the right
  `requestID` (`q`) and `isRequest`/`isResponse` flag bit; `requestID: nil` keeps `flags: 0x01` (plain).
  **Cross-validation:** our `ResourceAdvertisement(requestID:flags:…).pack()`'s `q` + `f` bytes match
  genuine RNS `ResourceAdvertisement.pack()` for a request-resource (`u=1`) and a response-resource
  (`p=1`).
- **`LinkSession`:** an oversize `sendRequest` spawns a sender transfer whose ADV is `isRequest` with
  `requestID == truncatedHash(packed)`, `pendingRequests` + timeout armed; an oversize `sendResponse`
  spawns an `isResponse` transfer; an inbound response ADV whose `requestID` isn't pending is ignored, a
  matched one cancels the timeout; a completed request-resource surfaces `requestReceived` (with
  `truncatedHash(payload)`), a completed response-resource surfaces `responseReceived` matched to pending +
  clears it.
- **E2E:** two `Endpoint`s establish a link, then round-trip a **>431-byte** request → **>431-byte**
  response (both ride Resources, crossing HMU if the part count exceeds 74), asserting
  `requestReceived`/`responseReceived` with the exact data and the matched `request_id`.
- Cross-validation reuses the resource/msgpack vectors; adds the request/response advertisement `q`/`f`
  vector.
- Every new/changed test is mutation-swept. Committed directly to `main` (no feature branch).

## Known simplifications (carry to review)

- No new `ResourceTransfer.State` field — `LinkSession` routes by reading the transfer's stored
  `advertisement.isRequest/.isResponse` (+ `role`) at the interception point.
- `Endpoint` is untouched (existing API/delegates handle large transparently).
- Request timeout armed at send, cancelled on response-ADV arrival (not RNS's arm-at-delivery).
- Inline-only allow-policy stays app-side (in-library registry deferred).
- File responses / metadata / auto-compression are out of scope.
