# Link Data Flow + Explicit Close — Design (slice 5-links-c)

**Status:** Approved
**Date:** 2026-07-19
**Depends on:** 5-links-b (`LinkSession` establishment reducer, merged)

## Goal

Extend the `LinkSession` reducer so an established link can carry encrypted application
data in both directions and be explicitly closed. This turns the establish-only link into a
fully usable session (establish → exchange data → close), wire-compatible with reference
Reticulum 1.3.8. The time-driven robustness layer (keepalive, watchdog, STALE, timeouts) is
a separate follow-up slice (5-links-d).

## Scope

**In scope**
- New `LinkSession` action `send(Data)`: encrypt application plaintext and emit a DATA/NONE
  link packet.
- Inbound DATA/NONE handling: decrypt and surface via `delegate(.dataReceived(Data))`.
- New `LinkSession` action `close`: emit a LINKCLOSE teardown packet and transition to a new
  `.closed` status.
- Inbound LINKCLOSE handling: verify and transition to `.closed`, surfacing
  `delegate(.closed(CloseReason))`.
- A `link_close_ciphertext` cross-validation vector vs Python-RNS 1.3.8.
- Incidental fidelity fix (good hygiene in the file we edit): tighten `acceptRequest`'s
  link-request length check from `payload.count >= 64` to the RNS-exact `== 64 || == 67`.

**Explicitly out of scope** (future slices)
- Keepalive, watchdog, STALE detection, establishment/inactivity timeouts — the entire
  clock-driven layer (→ 5-links-d).
- `identify()`, requests/responses, resources (#6), channels/buffers.
- Transport/Endpoint wiring (routing link-addressed packets to the right `LinkSession` by
  link_id). `LinkSession` remains standalone and interface-agnostic; the parent feeds inbound
  packet bytes and consumes emitted transmits.
- MTU negotiation (fixed-default signalling only, per 5-links-a).

## Architecture

Extend the existing `LinkSession` `@Reducer` (`Sources/ReTiCATransport/LinkSession.swift`);
no new files in `Sources`. The reducer stays interface-agnostic: raw packet bytes arrive via
`received`; outbound bytes leave via `delegate(.transmit(InterfaceID, Data))`.

### State changes

`Status` gains a terminal case:

```
public enum Status: Equatable, Sendable { case pending, handshake, active, closed }
```

A new reason type accompanies close:

```
public enum CloseReason: Equatable, Sendable { case initiatorClosed, destinationClosed }
```

No new stored properties are required — data and close both use the existing
`state.sessionKey` and `state.linkID`.

### Action changes

```
case send(Data)          // application plaintext to transmit over an active link
case close               // initiate teardown of an active link
```

Delegate gains:

```
case dataReceived(Data)          // decrypted inbound application data
case closed(CloseReason)         // link closed (locally or by the peer)
```

## Data flow

All link data/close packets are DATA-type, addressed to the LINK (`destinationHash = link_id`,
`destinationType .link`), and encrypted under the session key (`Link.encrypt`/`Link.decrypt`,
which wrap `Token(sessionKey)`).

| Packet        | packetType | context           | payload (pre-encryption) | encrypted? |
|---------------|------------|-------------------|--------------------------|------------|
| App data      | `.data`    | `.none`           | the application plaintext| yes        |
| LINKCLOSE     | `.data`    | `.linkClose` (0xFC)| `link_id` (16 bytes)     | yes        |

Reference: RNS app data is `RNS.Packet(link, data)` (DATA/NONE, `link.encrypt`); LINKCLOSE is
`RNS.Packet(self, self.link_id, context=LINKCLOSE)` and the receiver checks
`decrypt(packet.data) == self.link_id` (`RNS/Link.py` `__teardown_packet`/`teardown_packet`).

### `send(plaintext)`

- Guard `status == .active`; otherwise `.none`.
- Build DATA/`.none` packet, destHash = `state.linkID`, payload = `Link.encrypt(plaintext,
  sessionKey: state.sessionKey)`.
- Emit `.delegate(.transmit(state.interfaceID, packed))`.

### Inbound DATA/`.none` (when `status == .active`)

- `Link.decrypt(payload, sessionKey)`; on success emit `.delegate(.dataReceived(plaintext))`.
- On decrypt failure → ignore (`.none`). A corrupt/foreign data packet must not close the link.

### `close`

- Guard `status == .active`; otherwise `.none`.
- Build DATA/`.linkClose` packet, destHash = `state.linkID`, payload = `Link.encrypt(state.linkID,
  sessionKey)`.
- `status = .closed`.
- Emit `.merge(.transmit(closePacket), .delegate(.closed(role == .initiator ? .initiatorClosed :
  .destinationClosed)))`.

### Inbound DATA/`.linkClose` (when `status == .active`)

- `Link.decrypt(payload, sessionKey)`; require the plaintext equals `state.linkID`.
- On match → `status = .closed`; emit `.delegate(.closed(role == .initiator ? .destinationClosed :
  .initiatorClosed))`.
- On mismatch or decrypt failure → ignore (`.none`).

### Close-reason mapping (mirrors RNS `teardown_reason`)

| Event                         | initiator role      | responder role     |
|-------------------------------|---------------------|--------------------|
| local `close`                 | `initiatorClosed`   | `destinationClosed`|
| inbound LINKCLOSE from peer    | `destinationClosed` | `initiatorClosed`  |

### Terminal behavior

Once `status == .closed`, all inbound packets and the `send`/`close` actions fall through to
`default: .none` (ignored). No reopen in this slice.

## Error handling

- Decrypt failures on inbound data or close → silently ignored (no state change, no teardown),
  matching RNS (it simply doesn't deliver/act).
- `send`/`close` on a non-active link → ignored.
- Packets whose type/context/`destinationHash` don't match the active-link cases → ignored.

## Testing

- **TestStore unit tests:**
  - Active link `send(data)` → asserts a DATA/`.none` transmit to `link_id` whose payload
    `Link.decrypt`s back to `data`.
  - Inbound DATA/`.none` (payload = `Link.encrypt(data, key)`) → `delegate(.dataReceived(data))`.
  - `close` → asserts a DATA/`.linkClose` transmit (payload decrypts to `link_id`),
    `status == .closed`, and `delegate(.closed(.initiatorClosed))` for an initiator.
  - Inbound LINKCLOSE (payload = `Link.encrypt(link_id, key)`) → `status == .closed` and
    `delegate(.closed)` with the correct reason.
  - A decrypt-failing inbound data packet → no `.dataReceived`, link stays `.active`.
- **End-to-end test:** establish an initiator and a responder `LinkSession` (reuse the
  establishment handshake), then: initiator `send` → responder `dataReceived`; responder
  `send` → initiator `dataReceived`; initiator `close` → responder observes `.closed`
  (`.initiatorClosed`). Uses the two-`TestStore` cross-feeding pattern from 5-links-b.
- **Cross-validation vs Python-RNS 1.3.8:** new fixture `link_close_ciphertext` =
  `Token(link_derived_key).encrypt(link_id)` produced by genuine `RNS.Cryptography.Token`;
  Swift `Link.decrypt(link_close_ciphertext, key)` equals `link_id`. Application-data
  decryption is already covered by the existing `link_ciphertext` vector.
- **Mutation testing** per the project three-step discipline for every new/changed test.

## Global constraints

- Full wire compatibility with reference RNS 1.3.8; cross-validation drives genuine reference
  code (never a reimplementation).
- The `ReTiCA` core stays dependency-free; TCA confined to `ReTiCATransport`.
- Swift 6 strict concurrency; `LinkSession.State` remains `Equatable`; `Identity` is `Sendable`.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.

## Non-goals recap

No timers/keepalive/watchdog/STALE, no identify/requests/resources/channels, no
Transport/Endpoint wiring, no MTU negotiation. This slice makes an established link usable:
send data, receive data, close it — cross-validated against real RNS.
