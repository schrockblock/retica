# Resource Transfer State Machine — Design (slice 6b)

**Status:** Approved
**Date:** 2026-07-20
**Depends on:** 6a Resource primitives (`Resource`, `ResourceAdvertisement`, `MsgPack`), Link `Token` cipher, `LinkSession`/`Packet`. All merged.

## Goal

Implement the minimal single-segment Reticulum Resource **transfer** as a `ResourceTransfer` TCA
reducer (sender + receiver roles) driven over a link's session key: advertise → request all parts
→ send parts → assemble + verify → prove. Wire-compatible with reference RNS 1.3.8. No windowing,
retransmission, hashmap-update, multi-segment, compression, or Link/Endpoint integration.

## Scope

**In scope**
- A standalone `ResourceTransfer` `@Reducer` (in `ReTiCATransport`), one instance per resource,
  with a `role` (sender/receiver), parameterized by the link's `sessionKey`, `linkID`, and
  `interfaceID`. Interface-agnostic: resource packets arrive as raw `Data` via actions; outbound
  bytes leave via `delegate(.transmit(InterfaceID, Data))`.
- **Sender:** `advertise` (emit RESOURCE_ADV) → on RESOURCE_REQ, send the requested RESOURCE
  part-packets → on RESOURCE_PRF, validate the proof → `delegate(.concluded)`.
- **Receiver:** `accept(advertisementRaw)` (decrypt + unpack, emit one RESOURCE_REQ for ALL parts)
  → on each RESOURCE part, place it by map-hash; when all `n` arrive, assemble + verify, emit the
  RESOURCE_PRF proof → `delegate(.received(data))`.
- Cross-validation of the control-packet wire formats vs RNS 1.3.8.
- End-to-end two-reducer transfer.

**Explicitly out of scope** (future Resource sub-slices)
- Windowing / flow control (this slice requests ALL parts in one RESOURCE_REQ).
- Retransmission, part timeouts, the resource watchdog.
- Hashmap-update packets (RESOURCE_HMU) — unneeded because the entire hashmap fits one advertisement.
- Cancel / reject (RESOURCE_ICL / RESOURCE_RCL).
- Multi-segment resources, compression.
- Wiring `ResourceTransfer` into `LinkSession`/`Endpoint`.

## Reference facts (RNS 1.3.8, verified vs `RNS/Resource.py` + `RNS/Packet.py`)

Resource packet contexts (`Packet.py:73-79`): `RESOURCE=0x01`, `RESOURCE_ADV=0x02`,
`RESOURCE_REQ=0x03`, `RESOURCE_HMU=0x04`, `RESOURCE_PRF=0x05`, `RESOURCE_ICL=0x06`,
`RESOURCE_RCL=0x07`. Encryption (`Packet.py:196-216`, confirmed by `Link.receive`):

| Packet | packetType | context | encrypted? | payload |
|--------|------------|---------|------------|---------|
| RESOURCE_ADV | `.data` | `.resourceAdvertisement` (0x02) | yes (link Token) | `advertisement.pack()` |
| RESOURCE_REQ | `.data` | `.resourceRequest` (0x03) | yes | `0x00 ‖ resource_hash(32) ‖ requested_map_hashes` |
| RESOURCE part | `.data` | `.resource` (0x01) | **no** (already ciphertext) | the SDU-sized ciphertext chunk |
| RESOURCE_PRF | `.proof` | `.resourceProof` (0x05) | **no** (proofs are plaintext-exempt) | `resource_hash ‖ full_hash(data ‖ hash)` (64B) |

All resource packets are addressed to the LINK (`destinationType .link`, `destinationHash =
link_id`). The request's first byte is the hashmap-exhausted flag: `0x00` (NOT exhausted) here,
so the request is `0x00 ‖ hash ‖ hashes` (`Resource.py:959-965`, `Link.py:1050-1053`). The sender
parses a request by reading the flag, then the 32-byte hash, then the 4-byte map hashes, and
sends the part whose `full_hash(chunk ‖ r)[:4]` matches each requested hash (`Resource.py:982-1073`).

## Architecture

A single `ResourceTransfer` `@Reducer` with a `role` discriminator, mirroring how `LinkSession`
began (standalone, interface-agnostic, one instance per resource). It uses the 6a `Resource`/
`ResourceAdvertisement` primitives and `Link.encrypt`/`Link.decrypt` for the encrypted control
packets.

### State

```
public enum Role: Equatable, Sendable { case sender, receiver }
public enum Status: Equatable, Sendable { case idle, advertised, requesting, transferring, complete, failed }

@ObservableState struct State: Equatable {
    public let id: UUID            // stable collection key for a future ResourceTransfer collection
    public var role: Role
    public var status: Status
    public var interfaceID: InterfaceID
    public var linkID: Data
    public var sessionKey: Data
    public var resourceHash: Data

    // sender
    public var parts: [Data]              // ciphertext chunks
    public var hashmap: [Data]            // per-part 4-byte map hashes (index-aligned with parts)
    public var advertisement: ResourceAdvertisement?
    public var expectedProof: Data        // full_hash(data ‖ hash)

    // receiver
    public var randomHash: Data           // r, from the advertisement
    public var expectedParts: UInt64      // n, from the advertisement
    public var receivedParts: [Int: Data] // index → chunk
}
```

Two initializers:
- `init(sending data: Data, linkID: Data, sessionKey: Data, interfaceID: InterfaceID, prefix: Data,
  randomHash: Data, sdu: Int, id: UUID = UUID())` — computes `stream = Resource.buildStream(...)`,
  `parts`, `hashmap` (via `Resource.mapHash`), `resourceHash = Resource.resourceHash(data, r)`,
  `expectedProof = Resource.expectedProof(data, resourceHash)`, and the `advertisement`
  (`transferSize = stream.count`, `dataSize = data.count`, `numberOfParts = parts.count`,
  `hash = resourceHash`, `randomHash = r`, `originalHash = resourceHash`, `segmentIndex = 0`,
  `totalSegments = 1`, `requestID = nil`, `flags = 0x01`, `hashmap = concat(hashmap)`).
- `init(receivingOn linkID: Data, sessionKey: Data, interfaceID: InterfaceID, id: UUID = UUID())` —
  fields default; populated on `accept`.

### Actions

```
enum Action: Equatable {
    case advertise                    // sender kickoff
    case accept(Data)                 // receiver: raw RESOURCE_ADV packet bytes
    case received(Data)               // raw inbound resource packet bytes
    case delegate(Delegate)
    enum Delegate: Equatable {
        case transmit(InterfaceID, Data)
        case received(Data)           // receiver: the reconstructed original data
        case concluded                // sender: proof validated
        case failed
    }
}
```

## Data flow

Let `link(context:payload:packetType:)` build a `Packet(headerType: .header1, packetType:,
transportType: .broadcast, destinationType: .link, context:, contextFlag: false, hops: 0,
destinationHash: linkID, transportId: nil, payload:)` and `.packed()`.

### Sender

1. `advertise` (role sender, status idle) → status `.advertised`; emit
   `transmit(link(.data, .resourceAdvertisement, Link.encrypt(advertisement.pack(), sessionKey)))`.
2. `received` a `.data`/`.resourceRequest` packet, destHash == linkID → `plaintext =
   Link.decrypt(payload, sessionKey)`; require `plaintext[0] == 0x00` and `plaintext[1..<33] ==
   resourceHash`; requested = `plaintext[33...]` in 4-byte groups. For each requested map hash,
   find `i` with `hashmap[i] == requested` and emit `transmit(link(.data, .resource, parts[i]))`
   (raw). status `.transferring`. Unknown/mismatched → ignore.
3. `received` a `.proof`/`.resourceProof` packet, destHash == linkID → `Resource.validateProof(
   proofData: payload, expectedProof: expectedProof)`; on success status `.complete`, emit
   `delegate(.concluded)`; on failure → `delegate(.failed)`.

### Receiver

1. `accept(advRaw)` (role receiver, status idle) → parse the packet; require `.data`/
   `.resourceAdvertisement`; `adv = ResourceAdvertisement.unpack(Link.decrypt(payload, sessionKey))`;
   store `resourceHash = adv.hash`, `randomHash = adv.randomHash`, `expectedParts = adv.numberOfParts`,
   `advertisement = adv`; status `.requesting`; build the request plaintext `0x00 ‖ adv.hash ‖
   adv.hashmap` (the full hashmap = all map hashes) and emit `transmit(link(.data, .resourceRequest,
   Link.encrypt(request, sessionKey)))`.
2. `received` a `.data`/`.resource` packet, destHash == linkID (status `.requesting`/`.transferring`)
   → chunk = payload; `mapHash = Resource.mapHash(chunk, randomHash)`; find its index `i` (the
   position of `mapHash` within `advertisement.hashmap` split into 4-byte groups); store
   `receivedParts[i] = chunk`; status `.transferring`. When `receivedParts.count == expectedParts`:
   order the chunks by index → `data = Resource.assemble(orderedParts, sessionKey)`; if `data != nil`
   and `Resource.verify(data, randomHash, resourceHash)` → status `.complete`; emit both
   `transmit(link(.proof, .resourceProof, Resource.proofData(data, resourceHash)))` (raw) and
   `delegate(.received(data))`. If assembly/verify fails → `delegate(.failed)`.

## Error handling

- A packet whose type/context/destHash doesn't match the current role+status → ignored (`.none`).
- Sender: a request whose flag ≠ 0x00 or whose hash ≠ `resourceHash` → ignored. A requested map
  hash with no matching part → skipped.
- Receiver: a part whose map hash isn't in the advertisement's hashmap → ignored. A part for an
  index already received → ignored (idempotent). Assembly/verify failure → `.failed`.
- Sender proof-validation failure → `.failed`.
- No timeouts/retransmission this slice — a lost packet stalls the transfer (acceptable; robustness
  is a later slice).

## Testing

- **Sender unit tests (`TestStore`):** `advertise` → a RESOURCE_ADV transmit whose decrypted
  payload unpacks to the expected advertisement. Feed a RESOURCE_REQ (encrypted `0x00 ‖ hash ‖
  hashmap`) → a RESOURCE part transmit per requested hash (raw ciphertext chunk). Feed a valid
  RESOURCE_PRF → `.concluded`; a tampered proof → `.failed`.
- **Receiver unit tests:** `accept` a RESOURCE_ADV → a RESOURCE_REQ transmit whose decrypted payload
  is `0x00 ‖ hash ‖ full-hashmap`. Feed the RESOURCE parts one by one → after the last, a
  RESOURCE_PRF transmit AND `delegate(.received(data))` with the original data.
- **End-to-end two-reducer transfer:** a sender and a receiver `ResourceTransfer` sharing a
  `sessionKey`/`linkID`; feed each emitted `transmit` into the other's `received`/`accept`. Assert:
  sender advertises → receiver requests → sender sends parts → receiver reconstructs the ORIGINAL
  data (`delegate(.received(data))` equals the input) and emits a proof → sender `.concluded`.
- **Cross-validation vs RNS 1.3.8:** the request plaintext format `0x00 ‖ hash ‖ hashmap` matches a
  reference-constructed request (using the genuine 6a `resource_hash`/`resource_hashmap` vectors);
  the RESOURCE_ADV payload (`encrypt(pack)`) and RESOURCE_PRF payload (`hash ‖ proof`) reuse the 6a
  advertisement/proof vectors (already anchored to genuine RNS).
- **Mutation testing** per the project three-step discipline for every new/changed test.

## Global constraints

- Full wire compatibility with RNS 1.3.8 for the control-packet formats and encryption status.
- TCA confined to `ReTiCATransport`; the `ReTiCA` core stays dependency-free (unchanged this slice —
  the transfer reducer consumes the existing core `Resource`/`ResourceAdvertisement`/`Link`).
- Swift 6 strict concurrency; `ResourceTransfer.State` `Equatable` + `Identifiable` (via `id`).
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.
- Single-segment, single-window, no retransmission/HMU/watchdog/cancel/multi-segment/compression,
  no Link/Endpoint integration.

## Non-goals recap

Windowing, retransmission, timeouts, hashmap-update, cancel/reject, multi-segment, compression, and
`LinkSession`/`Endpoint` wiring are all deferred. This slice delivers a working minimal
single-segment resource transfer between two `ResourceTransfer` reducers, wire-compatible with real
RNS for its packet formats.
