# Transport #4c-1 — Path Request → Local-Destination Response → Learn

**Status:** approved (design)
**Date:** 2026-07-26
**Sub-project:** #4c path requests (on-demand path discovery), first sub-slice. Prior: all of #4b
(relaying + announce robustness + maintenance) merged.

## Problem

A node that wants to reach a destination `D` for which it holds no learned path currently cannot
discover one on demand — it can only wait for a periodic announce. RNS solves this with **path
requests**: the node broadcasts a `PATH_REQUEST` to a well-known control destination; any node that
knows the path answers with a path-response announce. This slice implements the foundational case —
a node that **owns** the requested destination answers by re-announcing it.

## Goal

- A requester broadcasts a `PATH_REQUEST` for a destination hash.
- A node that owns that destination locally emits a **path-response announce** for it.
- The requester learns the path from that announce (existing announce-learning; no change there).

Wire-compatible with genuine RNS `Transport.request_path` / `path_request_handler` / `path_request`.

## Design

All changes in `Sources/ReTiCATransport/Transport.swift`. Core `Sources/ReTiCA/*` is untouched — it
already models `.plain` destinations (`Destination.swift:51`) and the `.pathResponse` announce
context (`Packet.announce(…, pathResponse:)`, `Packet.swift:116`).

### 1. The well-known control destination (cross-validated)

RNS registers a PLAIN control destination `Destination(None, IN, PLAIN, "rnstransport", "path",
"request")` (`Transport.py:61,256`). Its hash is deterministic (no identity). We compute it once:

```swift
/// RNS Transport path-request control destination: PLAIN "rnstransport"/["path","request"]
/// (Transport.py:61,256). Deterministic (no identity). Cross-validated against genuine RNS.
static let pathRequestDestinationHash: Data =
    Destination.hash(identityHash: nil, appName: "rnstransport", aspects: ["path", "request"])
```

(`Destination.hash(identityHash: nil, …)` = `truncatedHash(nameHash)` — the RNS PLAIN branch;
16 bytes = `TRUNCATED_HASHLENGTH/8`.)

### 2. Requester — `.requestPath(destinationHash: Data)`

New action. Build a `PATH_REQUEST` and broadcast it:

```swift
case let .requestPath(destinationHash):
    var payload = destinationHash                                   // 16 bytes
    if let relayID = state.transportIdentity { payload += relayID.hash }   // optional transport_id (16)
    payload += randomBytes(16)                                      // request tag (RNS get_random_hash)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .plain, context: .none, contextFlag: false, hops: 0,
                        destinationHash: Transport.pathRequestDestinationHash, transportId: nil,
                        payload: payload)
    guard let raw = try? packet.packed() else { return .none }
    let sends = state.interfaces.map { Effect<Action>.send(.delegate(.transmit($0, raw))) }
    return sends.isEmpty ? .none : .merge(sends)
```

Matches RNS `request_path`: `path_request_data = destination_hash [+ Transport.identity.hash] +
request_tag`, sent `DATA`/`BROADCAST`/`HEADER_1`. (The `path_requests` bookkeeping table and the
recursive/`on_interface` throttling are #4c-3.)

### 3. Responder — recognize the control destination, answer if local

In the inbound `.received` `.data` case, **before** the normal data-delivery/relay logic, recognize
the control destination:

```swift
case .data:
    if packet.destinationHash == Transport.pathRequestDestinationHash {
        // A PATH_REQUEST. The requested destination hash is the first 16 payload bytes.
        guard packet.payload.count >= 16 else { return .none }
        let requested = Data(packet.payload.prefix(16))
        guard let dest = state.localDestinations[requested] else { return .none }   // only answer for OUR dests
        // Path-response announce for the owned destination, on the interface the request arrived on.
        let now = UInt64(date.now.timeIntervalSince1970)
        let randomHash = Announce.randomHash(now: now, randomPrefix: SecureRandom.bytes(5))
        let annPayload = Announce.buildPayload(identity: dest.identity!, destinationHash: dest.hash,
                                               nameHash: dest.nameHash, randomHash: randomHash,
                                               appData: dest.appData)     // match the outbound-announce build
        let response = Packet.announce(from: dest, payload: annPayload, pathResponse: true)
        guard let raw = try? response.packed() else { return .none }
        return .send(.delegate(.transmit(interfaceID, raw)))
    }
    // …existing .data relay/deliver logic unchanged…
```

Matches RNS `path_request` → `local_destination.announce(path_response=True,
attached_interface=…)`. The exact `Announce.buildPayload` argument list mirrors the outbound
`.announce` action (`Transport.swift:367-376`); the plan pins the precise call (incl. `dest.appData`
/ ratchet handling) to that site.

### 4. Requester learns

The path-response announce is an ordinary announce (context `.pathResponse`) arriving at the
requester; the existing `.announce` handling learns it (blob-dedup, `shouldReplace`, `pathLearned`).
No change. (Whether a path-response announce should be *re-broadcast* differently is a relay concern
deferred to #4c-2; a leaf requester re-broadcasts nothing anyway.)

## Scope

**In scope (#4c-1):** the control-destination hash; `.requestPath` (build + broadcast a PATH_REQUEST);
the local-destination responder (recognize the control dest → path-response announce on the arrival
interface); cross-validation of the control-dest hash + PATH_REQUEST wire format.

**Out of scope (later):** relay-answers-from-cache + recursive re-broadcast (#4c-2, needs raw-announce
caching); grace timing (`PATH_REQUEST_GRACE`/`RG`), the `discovery_pr_tags` tag-dedup, the
`path_requests` table, `PATH_REQUEST_MI` throttle (#4c-3); Endpoint-level `.requestPath` forwarding.

## Testing

### Unit (`Tests/ReTiCATransportTests/TransportTests.swift`)
- **Requester builds a broadcast PATH_REQUEST:** `.requestPath(destHash)` on a store with two
  interfaces (non-relay) → a `.transmit` on each; the packet is `DATA`/`BROADCAST`/`HEADER_1`,
  `destinationType == .plain`, `destinationHash == pathRequestDestinationHash`, and the payload's
  first 16 bytes == `destHash`, remaining 16 bytes == the (controlled `randomBytes`) tag.
- **Relay requester includes transport_id:** with `transportIdentity` set, the payload is
  `destHash(16) ‖ transportId(16) ‖ tag(16)`.
- **Local-destination responder answers:** register a local destination `D` (with a private key);
  feed a PATH_REQUEST for `D` on interface `in` → exactly one `.transmit` on `in` whose bytes parse
  as a valid announce for `D` (context `.pathResponse`, recovered identity == D's) and nothing else.
- **No answer for a non-local destination:** a PATH_REQUEST for an unknown/remote dest → no transmit.
- **End-to-end learn:** feed the responder's path-response announce into a second (requester)
  Transport → it learns the path (`learned[D]` set, `pathLearned`), exactly as a normal announce.

### Cross-validation (drive real RNS — [[cross-validation-drive-real-rns]])
The generator emits, from genuine RNS: the control-destination hash
(`RNS.Destination.hash(None, "rnstransport", "path", "request")`) and a genuine `PATH_REQUEST`
payload for a known destination hash. The Swift test asserts `Transport.pathRequestDestinationHash`
byte-equals RNS's control hash, and that our responder extracts the correct requested destination
hash from RNS's genuine PATH_REQUEST payload (`data[:16]`).

## Constraints (project-wide)

- Wire-compatible with Python-RNS 1.3.8; core `Sources/ReTiCA/*` stays zero-dep and **untouched**.
- Commit **directly to `main`** — no feature branch ([[commit-directly-to-main]]). Every commit leaves
  the full suite green.
- No compound shell commands; temp files under `/tmp/ReTiCA/`.
- Mutation-testing verification for every new test; non-exhaustive outcome-focused TCA tests
  ([[tca-tests-non-exhaustive]]).
- Reference RNS at `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/RNS/`
  ([[rns-reference-env]]).
- Commit trailers (exact):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
