# Link IDENTIFY + Inline Request/Response — Design

**Status:** Approved (design phase)
**Date:** 2026-07-22
**Depends on:** Link establishment + data/close/watchdog (5-links-*), Link↔Endpoint integration, and the `Identity`/`Link.encrypt`/`Packet.truncatedHash`/`MsgPack` primitives already in the core.

## Goal

Let the responder authenticate the (otherwise anonymous) initiator over an established link
(**IDENTIFY**), and provide an authenticated **request/response** RPC for payloads up to `Link.MDU`
(431 bytes) — byte-compatible with Python-RNS 1.3.8.

## Scope

**In scope**

1. **IDENTIFY:** the initiator signs and sends its identity; the responder verifies the Ed25519
   signature and stores the peer identity, surfaced via a delegate.
2. **Inline request (requester side):** `sendRequest(path, data)` → a single `REQUEST` packet when the
   packed request ≤ 431 bytes; a `pendingRequests` table with per-request timeout; response matching by
   `request_id`.
3. **Inline response (responder side):** an inbound `REQUEST` is surfaced to the app; the app replies via
   `sendResponse(requestID, data)` → a single `RESPONSE` packet.
4. Endpoint public API + delegates mirroring `sendOverLink`.

**Explicitly deferred (out of scope)**

- **Large (Resource-based) requests/responses** (packed > 431 bytes) — these ride the Resource stack with
  the advertisement's `requestID`/`is_response` flags (present in `ResourceAdvertisement` but not yet
  wired). Its own follow-up slice.
- **In-library handler registry + allow-policy** (`ALLOW_NONE`/`ALLOW_ALL`/`ALLOW_LIST`). See "Policy" below
  — the reducer surfaces requests to the app, which enforces policy using the identified `remoteIdentity`.
- Request `progress` callbacks; the `time` field is carried on the wire but not surfaced.

## Reference mechanics (Python-RNS 1.3.8)

- **Contexts** (already in our `PacketContext`): `linkIdentify = 0xFB`, `request = 0x09`, `response =
  0x0A`. All are DATA packets, **encrypted** with the link session key.
- **IDENTIFY** (`Link.identify`): `signed = link_id ‖ identity.get_public_key()`; payload =
  `identity.get_public_key() ‖ identity.sign(signed)`. `get_public_key()` = X25519_pub(32) ‖ Ed25519_pub(32)
  = 64 B; signature = 64 B; total 128 B. Only the initiator sends; only the responder processes. On success
  the responder stores `__remote_identity` and fires `remote_identified(link, identity)`.
- **REQUEST** (`Link.request`): `path_hash = Identity.truncated_hash(path.utf8)` (16 B);
  `packed = umsgpack.packb([time.time(), path_hash, data])`. If `len(packed) ≤ link.mdu` (431) → single
  `REQUEST` DATA packet; else a Resource (deferred). `request_id` = the sent packet's truncated hash (16 B).
- **RESPONSE** (`handle_request`): the responder computes `request_id = packet.getTruncatedHash()` of the
  received REQUEST, looks up the handler by `path_hash`, checks the allow-policy, generates a response, and
  sends `packed = umsgpack.packb([request_id, response])` as a `RESPONSE` DATA packet if ≤ 431 else a
  Resource. The requester matches `unpacked_response[0]` against `pending_requests[*].request_id`.
- **Timeout:** `rtt · TRAFFIC_TIMEOUT_FACTOR(6) + RESPONSE_MAX_GRACE_TIME(10) · 1.125` = `rtt·6 + 11.25 s`.
- `Link.MDU` = `floor((500 − 1 − 19 − 48)/16)·16 − 1 = 431` bytes.

## Architecture

All work lives in `LinkSession` (`ReTiCATransport`) — the identity/crypto/msgpack/packet primitives it
needs are already in the `ReTiCA` core — plus the `Endpoint` (`ReTiCANode`) public surface, mirroring the
existing `sendOverLink`/`sendResourceOverLink` dispatch and delegate re-surfacing.

### Primitives reused (no core changes)
- `Identity`: `publicKey` (64 B), `sign(_:) -> Data` (Ed25519, 64 B), `validate(signature:message:) -> Bool`,
  `init?(publicKey:)`, `hash` (16 B). `Identity` is `Equatable` (already held in `LinkSession.State`).
- `Crypto.truncatedHash(_:) -> Data` (16 B) for `path_hash`.
- `Link.encrypt(_:sessionKey:)` / `Link.decrypt(_:sessionKey:)`.
- `Packet.truncatedHash` (RNS `get_hashable_part`: `destType<<2|packetType ‖ destHash ‖ context ‖ payload`,
  then `truncatedHash`) for `request_id`.
- `MsgPack.encode(.array([...]))` / `decodeValue` with `.double`/`.bin`.
- `linkPacket(_ linkID:_ context:_ payload:)` (the existing outbound builder).

## LinkSession changes (`Sources/ReTiCATransport/LinkSession.swift`)

### State additions
- `public var remoteIdentity: Identity?` — responder: the verified initiator identity (nil until IDENTIFY).
- `public var pendingRequests: Set<Data>` — requester: outstanding `request_id`s awaiting a response.

Both default to `nil`/`[]` and are set in both initializers (so the memberwise/custom inits still work).

### Action additions
- `case identify(Identity)` — initiator sends LINKIDENTIFY.
- `case sendRequest(path: String, data: Data)` — requester sends a REQUEST.
- `case sendResponse(requestID: Data, data: Data)` — responder sends a RESPONSE.
- `case requestDeadline(Data)` — a pending request's timeout fired.
- Delegate additions: `identified(Identity)`, `requestReceived(requestID: Data, pathHash: Data, data: Data)`,
  `responseReceived(requestID: Data, data: Data)`, `requestFailed(requestID: Data)`.

### CancelID
Add `case request(Data)` to the existing `CancelID` (Data is Hashable) for per-request timeouts.

### Behavior

**`.identify(identity)`** — guard `role == .initiator, status == .active`; build
`payload = identity.publicKey + identity.sign(state.linkID + identity.publicKey)` (128 B); send
`linkPacket(.data, .linkIdentify, Link.encrypt(payload, sessionKey:))`.

**Inbound `(_, .active, .data, .linkIdentify)`** — guard `role == .responder`;
`Link.decrypt`; require `plain.count == 128`; `publicKey = plain[0..<64]`, `signature = plain[64..<128]`;
`guard let peer = Identity(publicKey: publicKey), peer.validate(signature: signature, message: linkID + publicKey)`;
set `state.remoteIdentity = peer`; emit `delegate(.identified(peer))`. Any failure → `.none`.

**`.sendRequest(path, data)`** — guard `.active`; `pathHash = Crypto.truncatedHash(Data(path.utf8))`;
`packed = MsgPack.encode(.array([.double(date.now.timeIntervalSince1970), .bin(pathHash), .bin(data)]))`;
**guard `packed.count <= 431`** (else `.none` — deferred); build the `.request` packet with
`Link.encrypt(packed)`; compute `requestID = packet.truncatedHash`; `state.pendingRequests.insert(requestID)`;
emit the transmit + arm a one-shot timeout `.run { sleep(rtt·6 + 11.25); send(.requestDeadline(requestID)) }
.cancellable(id: .request(requestID), cancelInFlight: true)`.

**Inbound `(_, .active, .data, .response)`** — `Link.decrypt`; `MsgPack.decodeValue` →
`.array([.bin(requestID), .bin(responseData)])`; `guard state.pendingRequests.contains(requestID)`;
`state.pendingRequests.remove(requestID)`; emit `.merge(.cancel(id: .request(requestID)),
.send(.delegate(.responseReceived(requestID, responseData))))`.

**`.requestDeadline(requestID)`** — `guard state.pendingRequests.contains(requestID)`; remove; emit
`delegate(.requestFailed(requestID))`.

**Inbound `(_, .active, .data, .request)`** — `requestID = packet.truncatedHash` (from the received packet);
`Link.decrypt`; `MsgPack.decodeValue` → `.array([.double(_), .bin(pathHash), .bin(data)])`; emit
`delegate(.requestReceived(requestID, pathHash, data))`.

**`.sendResponse(requestID, data)`** — guard `.active`;
`packed = MsgPack.encode(.array([.bin(requestID), .bin(data)]))`; guard `packed.count <= 431` (else `.none`);
send `linkPacket(.data, .response, Link.encrypt(packed))`.

These three inbound cases slot in before the current `default: return .none` in the received switch. They
are handled directly by `LinkSession` (NOT broadcast to the child resource transfers).

## Policy (a deliberate architecture decision)

A TCA reducer cannot hold the app-provided response-generator closures that RNS's request handlers use, so
**the reducer surfaces every inbound request to the app via `requestReceived`, and the app generates and
sends the response** (`sendResponse`). The app enforces its own allow-policy using the `remoteIdentity` it
learned from `linkIdentified` — so IDENTIFY still does its job (the app can implement `ALLOW_LIST` itself).
RNS's in-library handler-registry + `ALLOW_NONE`/`ALLOW_ALL`/`ALLOW_LIST` is a convenience layer deferred to
a later slice. **The wire format is identical** — only where policy lives differs.

## Endpoint changes (`Sources/ReTiCANode/Endpoint.swift`)

- **Actions:** `identifyOverLink(linkID: Data, identity: Identity)`,
  `sendRequestOverLink(linkID: Data, path: String, data: Data)`,
  `sendResponseOverLink(linkID: Data, requestID: Data, data: Data)` — each finds the link element by
  `linkID` and dispatches the matching `LinkSession` action (mirroring `.sendOverLink`).
- **Delegates:** `linkIdentified(linkID: Data, remoteIdentity: Identity)`,
  `requestReceived(linkID: Data, requestID: Data, pathHash: Data, data: Data)`,
  `responseReceived(linkID: Data, requestID: Data, data: Data)`,
  `requestFailed(linkID: Data, requestID: Data)` — re-surfaced from the LinkSession delegates keyed by the
  element's `linkID` (mirroring `.dataReceived` → `.linkDataReceived`).

## Error handling

- IDENTIFY: wrong size (≠128), bad signature, wrong role, or undecryptable → ignored (`.none`); the link
  stays active.
- REQUEST/RESPONSE: undecryptable, malformed msgpack, or an unmatched `request_id` → ignored.
- Over-MDU request/response → `.none` (the deferred large path); no partial send.
- A lost RESPONSE → `requestFailed` when the request timeout fires.

## Testing

- **IDENTIFY:** an initiator `.identify` emits a 128-byte payload decrypting to
  `publicKey ‖ sign(linkID‖publicKey)`; a responder accepts a valid inbound one (sets `remoteIdentity`,
  emits `identified`), and rejects a tampered signature, a wrong-size payload, and (role guard) an
  initiator receiving IDENTIFY. **Cross-validation:** Ed25519 signatures are deterministic (RFC 8032), so
  the exact 128-byte IDENTIFY payload for a fixed identity (private key seed) + fixed `linkID` is generated
  by genuine RNS and asserted byte-equal to ours.
- **Requester:** `sendRequest` emits a `.request` packet whose decrypted payload is
  `[time, pathHash, data]` with `pathHash == truncatedHash(path)`; the `requestID` is recorded in
  `pendingRequests`; an inbound `.response` echoing that `requestID` emits `responseReceived` and clears the
  pending entry (+ cancels the timeout); the `requestDeadline` path emits `requestFailed`; an over-431-byte
  request emits nothing.
- **Responder:** an inbound `.request` emits `requestReceived` with the packet-derived `requestID` and the
  unpacked `pathHash`/`data`; `sendResponse` emits a `.response` packet decrypting to `[requestID, data]`.
- **Cross-validation:** `pathHash == RNS Identity.truncated_hash(path)`; the REQUEST/RESPONSE msgpack array
  encodings vs genuine `umsgpack` for representative `[double, bin, bin]` / `[bin, bin]` payloads.
- **E2E:** two `Endpoint`s establish a link, the initiator identifies (responder surfaces `linkIdentified`),
  then the requester round-trips `sendRequestOverLink` → `requestReceived` → `sendResponseOverLink` →
  `responseReceived` matched by `requestID`. Both stores drive packets directly (no clock advance) so link
  timers don't interfere.
- Every new/changed test is mutation-swept per the project's discipline. Committed directly to `main` (no
  feature branch).

## Known simplifications (carry to review)

- App-side policy (no in-library handler registry / allow-policy) — deferred, documented above.
- Inline-only (≤431 B); large request/response via Resource deferred.
- `request_id` is the encrypted REQUEST packet's truncated hash — non-deterministic per call (random IV),
  which is fine (unique + matchable; tests derive it from the captured packet, not by prediction).
- The wire `time` field is carried (from the injected `date`) but not surfaced to the app.
