# Link Establishment State Machine — Design (slice 5-links-b)

**Status:** Approved
**Date:** 2026-07-19
**Depends on:** 5-links-a (pure `Link` handshake primitives, merged)

## Goal

Implement the Reticulum Link **establishment** state machine as a TCA reducer: drive
both the initiator and the responder through `PENDING → HANDSHAKE → ACTIVE` via the
three-packet handshake (LINKREQUEST → LRPROOF → LRRTT), ending with both sides holding
an equal derived session key. Nothing beyond establishment: no application data flow, no
close/teardown, no keepalive/watchdog/timeouts, no identify/requests/resources/channels.

This is the tightest useful Link-session slice, mirroring the "pure primitives first"
scoping of 5-links-a. Wire-compatible with reference Reticulum (Python-RNS 1.3.8).

## Scope

**In scope**
- A single `LinkSession` `@Reducer` (one instance per link) in the `ReTiCATransport` target.
- Initiator role: build/emit LINKREQUEST; validate inbound LRPROOF; derive session key;
  emit LRRTT; reach ACTIVE.
- Responder role: accept an inbound LINKREQUEST; derive session key; build/emit LRPROOF;
  validate inbound LRRTT; reach ACTIVE.
- A minimal, double-only `msgpack` codec in the pure core (`Sources/ReTiCA/Support/`), for
  the LRRTT payload.
- Cross-validation vectors vs RNS 1.3.8 for the new pieces.

**Explicitly out of scope** (future slices)
- Application data flow over the active link, and link close/teardown (LINKCLOSE).
- Keepalive, watchdog, STALE detection, establishment/inactivity timeouts (the timer layer).
- `identify()`, requests/responses, resources (#6), channels/buffers.
- MTU negotiation (fixed-default signalling only, per 5-links-a).
- Any `Transport` changes or Node-layer routing of link packets by `link_id`. The
  `LinkSession` reducer is standalone and interface-agnostic; the parent supplies inbound
  packet bytes and the owning identity, and consumes emitted transmits. Wiring links into
  `Transport`/`Endpoint` is deferred to the slice where links carry data.

## Architecture

One `LinkSession` reducer with a `role` discriminator in state and a unified
`received(Data)` entry point, dispatched by packet type/context. The handshake is
symmetric enough (shared `linkID`, keys, ephemerals) that one reducer is cleaner than two,
and it matches the existing single-feature pattern of `Transport` and `TCPClientInterface`.
Interface-agnostic: packets arrive as raw `Data`, outbound bytes leave via
`delegate(.transmit(InterfaceID, Data))`.

### State

```
public enum Role: Equatable, Sendable { case initiator, responder }
public enum Status: Equatable, Sendable { case pending, handshake, active }

@ObservableState struct State: Equatable {
    var role: Role
    var status: Status
    var interfaceID: InterfaceID
    var linkID: Data                 // 16 bytes (set once known)
    var ephemeral: Identity          // our ephemeral X25519+Ed25519 keypair
    var destinationHash: Data        // 16 bytes (initiator: the SINGLE dest; used for LINKREQUEST)
    var destinationIdentity: Identity? // initiator: peer's known identity (to validate proof)
    var owningIdentity: Identity?    // responder: the local identity that owns the destination (signs proof)
    var peerX25519Pub: Data?         // learned during handshake
    var sessionKey: Data             // empty until derived
    var requestedAt: Double?         // initiator: send time, for RTT
    var rtt: Double?
}
```

The initiator and responder initial states are constructed by the parent through two
factory initializers (or `establish` / `acceptRequest` actions that populate them).

### Actions

```
enum Action: Equatable {
    case establish                       // initiator kickoff (state already carries dest info)
    case acceptRequest(Data)             // responder: raw inbound LINKREQUEST bytes
    case received(Data)                  // raw inbound link packet bytes (LRPROOF / LRRTT)
    case delegate(Delegate)

    enum Delegate: Equatable {
        case transmit(InterfaceID, Data)
        case established(linkID: Data, sessionKey: Data)
        case establishmentFailed
    }
}
```

(Whether initiator setup is an `establish` action on a pre-populated state or a factory
init is a plan-level detail; both are acceptable. Responder setup is `acceptRequest`,
which parses the request and populates state.)

## Data flow

### Packet framing per role

| Packet     | packetType   | context             | destinationType | destinationHash | payload                                  |
|------------|--------------|---------------------|-----------------|-----------------|------------------------------------------|
| LINKREQUEST| `.linkRequest`| `.none`            | `.single`       | destination hash| `ephemeralPub(64) ‖ signalling(3)` = 67B |
| LRPROOF    | `.proof`     | `.linkRequestProof` (0xFF) | `.link`  | `link_id`       | `Link.buildProof(...)` = 99B             |
| LRRTT      | `.data`      | `.linkRequestRTT` (0xFE)   | `.link`  | `link_id`       | `Link.encrypt(msgpack(rtt), sessionKey)` |

`signalling` = the fixed `0x2001f4` from 5-links-a.

### Initiator

1. `establish` → payload = `ephemeral.publicKey (64) ‖ signalling (3)` = 67 bytes; build
   LINKREQUEST packet; `linkID = Link.linkID(requestPacket:)`; `status = .pending`;
   `requestedAt = now`; emit `.transmit(LINKREQUEST bytes)`.
2. `received` a `.proof` / `.linkRequestProof` packet whose `destinationHash == linkID`:
   - `peerPub = Link.validateProof(payload, linkID, destinationIdentity!)`.
   - `peerPub == nil` → `.establishmentFailed` (no transition).
   - else: `sessionKey = Link.sessionKey(ourX25519Priv, peerPub, linkID)`;
     `status = .active`; `rtt = now − requestedAt`; build LRRTT
     (`Link.encrypt(msgpack(rtt), sessionKey)`); emit **both** `.transmit(LRRTT bytes)` and
     `.established(linkID, sessionKey)`.

`ourX25519Priv = ephemeral.privateKey.prefix(32)`.

### Responder

1. `acceptRequest(bytes)` → parse packet; require `packetType == .linkRequest`;
   `linkID = Link.linkID(requestPacket:)`; `peerX25519Pub = payload[0..<32]`; generate
   responder `ephemeral`; `sessionKey = Link.sessionKey(respX25519Priv, peerX25519Pub, linkID)`;
   `status = .handshake`; `proof = Link.buildProof(linkID, responderEphemeral: ephemeral,
   destinationIdentity: owningIdentity!)`; emit `.transmit(LRPROOF bytes)`.
2. `received` a `.data` / `.linkRequestRTT` packet whose `destinationHash == linkID`:
   - `plaintext = Link.decrypt(payload, sessionKey)`.
   - `plaintext == nil` → `.establishmentFailed`.
   - else decode `msgpack` double → `rtt`; `status = .active`; emit
     `.established(linkID, sessionKey)`.

### Error handling (establish-only)

- A definitive crypto failure on the **awaited** packet (initiator: bad proof; responder:
  undecryptable LRRTT) → `delegate(.establishmentFailed)` with no state transition. There is
  no `closed` state in this slice; the parent discards the session.
- A packet whose type/context/`destinationHash` does not match the current role+status
  (stray, duplicate, late, or already-active) → ignored (`.none`), mirroring how `Transport`
  drops unexpected packets.

## msgpack codec (pure core)

Minimal, double-only, matching `umsgpack.packb(float)` (float64):

```
enum MsgPack {
    static func encode(_ value: Double) -> Data   // [0xCB] ‖ bigEndian(value.bitPattern)  → 9 bytes
    static func decodeDouble(_ data: Data) -> Double?  // require 0xCB tag + 8 BE bytes
}
```

Lives in `Sources/ReTiCA/Support/MsgPack.swift`. Only the `Double`/float64 form is
implemented (YAGNI); other msgpack types are out of scope.

## Testing

- **TestStore unit tests (per role):**
  - Initiator: `establish` → asserts `status == .pending` and a `.transmit` of a LINKREQUEST
    whose parsed `link_id` equals `state.linkID`. Feed a valid LRPROOF → asserts
    `status == .active`, a `.transmit` of an LRRTT, and `.established(linkID, sessionKey)`.
  - Responder: `acceptRequest` → asserts `status == .handshake` and a `.transmit` of an
    LRPROOF (destHash == linkID). Feed a valid LRRTT → asserts `status == .active` and
    `.established`.
- **End-to-end handshake test:** instantiate an initiator and a responder `LinkSession`;
  feed each emitted `.transmit` payload into the other's `received`/`acceptRequest`; assert
  both reach `.active` and hold an **equal** `sessionKey`.
- **Failure test:** feed the initiator a tampered LRPROOF → `.establishmentFailed`, no
  transition.
- **Cross-validation vs Python-RNS 1.3.8** (`Tests/ReTiCATests/Vectors/`):
  - `MsgPack.encode(rtt)` is **byte-exact** against genuine `umsgpack.packb(rtt)` for a fixed
    `rtt` (deterministic — no IV).
  - Swift decrypts a genuine RNS `Token(derived_key).encrypt(umsgpack.packb(rtt))` LRRTT
    payload and recovers `rtt`.
  - Reuse the 5-links-a `link_id` / `link_derived_key` / `link_proof` vectors (they already
    prove the establishment crypto). The fixture generator drives genuine reference code
    (`umsgpack.packb`, `RNS.Cryptography.Token`), never a reimplementation.
- **Mutation testing** per the project's three-step discipline for every new/changed test.

## Global constraints

- Full wire compatibility with reference RNS 1.3.8; cross-validation is the proof, and
  fixtures must drive genuine reference code paths (never hand-rolled reimplementations).
- The `ReTiCA` core target has **zero** external dependencies (the `msgpack` codec uses only
  the Swift stdlib). TCA stays confined to `ReTiCATransport`/other non-core targets.
- Swift 6 strict concurrency; `LinkSession.State` is `Equatable`; `Identity` is `Sendable`.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.

## Non-goals recap

Data flow, close, timers, identify, requests, resources, channels, MTU negotiation, and
`Transport`/`Endpoint` integration are all deferred to later slices. This slice delivers a
standalone, interface-agnostic establishment reducer with an equal-session-key guarantee,
cross-validated against real RNS.
