# Transport — Endpoint Core — Design

**Date:** 2026-07-19
**Status:** Approved
**Sub-project:** #4 (slice 4a) of the native iOS Reticulum (RNS) implementation

## Context

Sub-projects #1 (Crypto + Identity), #2 (Packet + Destination), and #3 (Interfaces:
TCP client) are complete and merged. The pure `ReTiCA` core provides crypto, `Identity`,
`Packet`, `Destination`, `Announce`, and `HDLC`. `ReTiCAInterfaces` provides a TCA
`TCPClientInterface` over `NWConnection`, exposing `delegate(.packetReceived(Data))` up and
`.send(Data)` down.

This slice adds **Transport, endpoint core** — the routing brain that consumes the
interface contract. It is the second TCA slice. Reticulum's `Transport` is ~3600 lines;
this slice is the **endpoint (leaf) subset**: hear announces, build the path/known-
destination tables, deliver inbound packets addressed to our local destinations, and
route outbound packets to destinations we have a path to. Combined with #3, this makes a
**functioning endpoint** on a real Reticulum network.

Inherited constraints:
- **Full wire compatibility** with reference Reticulum, validated against Python-RNS 1.3.8.
- **TCA confined to non-core targets;** the `ReTiCA` core stays dependency-free.
- **Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / Mac Catalyst 16** (set in #3).

### Decisions

- **New `ReTiCATransport` target** (depends on `ReTiCA` core + The Composable
  Architecture). Deliberately **interface-agnostic**: no Network.framework dependency;
  interfaces are referenced by an opaque `InterfaceID`. A thin app/composition layer wires
  Transport ↔ interface reducers.
- **Delegate contract** (how the app wires it): interface `packetReceived` →
  `Transport.received(interfaceID, Data)`; `Transport.delegate(.transmit(interfaceID, Data))`
  → interface `.send`.

### Scope

**In:** announce ingest → learned path/identity table (with recency + dedup); inbound DATA
demux → decrypt + deliver for local destinations; outbound `.send` (encrypt + route to a
known path); `.announce` of our own destinations; store + use **received** ratchets for
outbound encryption.

**Out (deferred):** transport-node relaying (announce rebroadcast, foreign-packet relay,
reverse table, HEADER_2 transport-id rewriting) — slice 4b; path requests + expiry/cull
job loops + persistence — slice 4c; links (link_table) — #5; resources — #6; generating/
rotating our *own* ratchets and inbound ratchet enforcement; proofs/PacketReceipt.

## Reference constructions (confirmed against `markqvist/Reticulum`)

Line references are to `/tmp/ReTiCA/Reticulum-ref/RNS/Transport.py`.

### Path table entry (line 341)

`path_table[destination_hash] = [timestamp, received_from, hops, expires, random_blobs,
receiving_interface, announce_packet_hash]`. Field indices: `IDX_PT_TIMESTAMP=0`,
`IDX_PT_NEXT_HOP=1` (`received_from`), `IDX_PT_HOPS=2`, `IDX_PT_EXPIRES=3`,
`IDX_PT_RANDBLOBS=4`, `IDX_PT_RVCD_IF=5`, `IDX_PT_PACKET=6`.

### Inbound ANNOUNCE (lines 1743–2045)

- `validate_announce(packet)` (our `Announce.parse`, which checks signature AND
  `destHash == SHA256(nameHash ‖ identity.hash)[:16]`).
- Skip if `destination_hash` is one of our local destinations (don't learn a path to self).
- `received_from = packet.transport_id if packet.transport_id != None else packet.destination_hash`
  (the next hop toward the destination).
- `random_blob = packet.data[74:84]` — this is the announce's `random_hash` (10 bytes:
  5 random + 5 big-endian emission time). `announce_emitted = int.from_bytes(random_hash[5:10], "big")`.
- Recency: the reference tracks `random_blobs` and prefers newer emissions / fewer hops.
  Endpoint-simplified rule (this slice): replace the learned entry when the new announce
  has a **newer** `announceEmitted`, or an **equal** `announceEmitted` with **fewer hops**;
  otherwise ignore. (A faithful superset of the reference's "prefer recent, prefer short.")
- Hop cap: ignore announces with `hops >= PATHFINDER_M` (128) — already enforced by
  `Packet(raw:)` which rejects `hops >= 128`.

### Inbound DATA (lines 2181–2196)

- Look up `destinations_map[destination_hash]`; require `destination.type ==
  packet.destination_type`; then `destination.receive(packet)` → `decrypt(packet.data)` →
  deliver plaintext to the destination's packet callback. (Endpoint: our local `Destination`
  holds the private `Identity`; decrypt with the static key — own-ratchet enforcement is
  deferred.)

### Duplicate suppression

The reference keeps `packet_hashlist` and drops already-seen `packet.packet_hash`. This
slice keeps a bounded `seenPacketHashes` set and drops duplicates.

### Outbound (endpoint, leaf behavior)

A leaf endpoint sending to a remote destination it has heard: build a **HEADER_1 DATA**
packet addressed to `destination_hash`, payload = `identity.encrypt(plaintext, ratchet:)`,
and transmit it on the interface that heard the announce (`IDX_PT_RVCD_IF`). The upstream
transport node relays it. (HEADER_2 / next-hop transport-id rewriting is transport-node
behavior — slice 4b.)

## Target & module structure

```
Package.swift  (modified): + product ReTiCATransport; + target ReTiCATransport
  (deps: ReTiCA, ComposableArchitecture); + test target ReTiCATransportTests
  (also bundles Vectors/fixtures.json for cross-validation).

Sources/ReTiCATransport/
  InterfaceID.swift          // opaque Hashable/Sendable interface handle
  LearnedDestination.swift   // learned path + identity entry (value type)
  Transport.swift            // @Reducer

Tests/ReTiCATransportTests/
  TransportTests.swift               // TestStore reducer tests
  TransportCrossValidationTests.swift// consumes a reference announce packet fixture

Tests/ReTiCATests/Vectors/ (extend generator + fixtures with `announce_packet`)
```

## Public API sketch

```swift
import ComposableArchitecture
import ReTiCA

public struct InterfaceID: Hashable, Sendable {
    public let rawValue: String
    public init(_ rawValue: String)
}

public struct LearnedDestination: Equatable, Sendable {
    public let identity: Identity     // public-only, recovered from the announce
    public var appData: Data?
    public var ratchet: Data?         // received ratchet public key (32 bytes) or nil
    public var interfaceID: InterfaceID
    public var hops: UInt8
    public var nextHop: Data?         // transport_id, or nil for directly-heard
    public var announceEmitted: UInt64
}

@Reducer
public struct Transport {
    @ObservableState
    public struct State: Equatable {
        public var localDestinations: [Data: Destination]     // ours (private Identity)
        public var learned: [Data: LearnedDestination]        // path + identity table
        public var interfaces: Set<InterfaceID>
        var seenPacketHashes: RingSet                          // bounded dedup
        public init()
    }

    public enum Action: Equatable {
        case interfaceConnected(InterfaceID)
        case interfaceDisconnected(InterfaceID)
        case registerLocalDestination(Destination)
        case received(InterfaceID, Data)          // deframed packet bytes from an interface
        case announce(destinationHash: Data, appData: Data?)
        case send(destinationHash: Data, plaintext: Data)
        case delegate(Delegate)

        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)               // raw packet bytes → interface .send
            case received(destinationHash: Data, plaintext: Data)
            case pathLearned(destinationHash: Data, hops: UInt8)
            case sendFailed(destinationHash: Data, reason: SendFailure)
        }
    }
    public enum SendFailure: Equatable { case noPath, notLearned }

    @Dependency(\.date) var date
    public init()
    public var body: some ReducerOf<Self>
}
```

`RingSet` is a small bounded insertion-ordered set (fixed capacity, evicts oldest) used for
`seenPacketHashes`; kept internal.

## Behavior

- **`.interfaceConnected(id)` / `.interfaceDisconnected(id)`** — maintain `interfaces`.
- **`.registerLocalDestination(dest)`** — `localDestinations[dest.hash] = dest`.
- **`.received(id, data)`:**
  1. `guard let packet = Packet(raw: data) else { return .none }`.
  2. Dedup: `guard seenPacketHashes.insert(packet.packetHash) else { return .none }`.
  3. By `packet.packetType`:
     - **`.announce`**: `guard localDestinations[packet.destinationHash] == nil` (skip self);
       `guard let parsed = Announce.parse(payload: packet.payload, destinationHash:
       packet.destinationHash, contextFlagSet: packet.contextFlag)`. Compute
       `announceEmitted = bigEndian(parsed.randomHash[5..<10])`. Build a `LearnedDestination`
       (identity=parsed.identity, appData=parsed.appData, ratchet=parsed.ratchet,
       interfaceID=id, hops=packet.hops, nextHop=packet.transportId, announceEmitted).
       Apply the recency rule; if accepted, store and emit `.delegate(.pathLearned(...))`.
     - **`.data`**: `guard let dest = localDestinations[packet.destinationHash], dest.kind ==
       packet.destinationType` else drop. `guard let pt = dest.decrypt(packet.payload)` →
       `.delegate(.received(destinationHash: packet.destinationHash, plaintext: pt))`.
     - else → `.none`.
- **`.announce(destHash, appData)`** — `guard let dest = localDestinations[destHash]` and it
  holds a private identity. Build `randomHash = Announce.randomHash(now: bigEndianTime,
  randomPrefix: SecureRandom.bytes(5))` (time from `@Dependency(\.date)`); `payload =
  Announce.buildPayload(identity:, destinationHash: destHash, nameHash: dest.nameHash,
  randomHash:, ratchet: nil, appData:)`; `packet = Packet.announce(from: dest, payload:
  payload)`; emit `.delegate(.transmit(id, packet.packed()))` for each `id` in `interfaces`.
- **`.send(destHash, plaintext)`** — `guard let entry = learned[destHash]` else
  `.delegate(.sendFailed(destHash, .notLearned))`. Encrypt: `ct = entry.identity.encrypt(
  plaintext, ratchet: entry.ratchet)`. Build `packet = Packet(headerType: .header1,
  packetType: .data, destinationType: .single, destinationHash: destHash, payload: ct)`.
  Emit `.delegate(.transmit(entry.interfaceID, try packet.packed()))`.

Errors: malformed inbound bytes are dropped (return `.none`, never trap). `.send` to an
unknown destination emits `.sendFailed`. Packet `packed()` failures (over-MTU) are dropped
with a `.sendFailed`.

## Verification strategy

Under the project's mutation-testing discipline.

1. **`TestStore` reducer tests** (`ReTiCATransportTests`):
   - Feed an announce (built in-test via `Announce.buildPayload` + `Packet.announce` for a
     synthetic identity) → assert `learned[destHash]` populated (identity, hops, interfaceID,
     ratchet, appData) and `.delegate(.pathLearned)`.
   - Register a local destination; encrypt a plaintext to it and wrap in a DATA packet; feed
     `.received` → assert `.delegate(.received(destHash, plaintext))`.
   - Learn a destination, then `.send(destHash, plaintext)` → assert `.delegate(.transmit(
     interfaceID, raw))`; decrypt the emitted packet's payload with the destination's private
     identity in-test → recovers plaintext (round-trip; ciphertext is non-deterministic).
   - `.announce(destHash)` with connected interfaces → assert one `.delegate(.transmit(id,·))`
     per interface, each carrying a payload that `Announce.parse` validates.
   - Recency: an older announce (smaller `announceEmitted`) does not replace a newer entry;
     a shorter-hop announce at equal emission does.
   - Dedup: the same packet fed twice is processed once.
   - `.send` to an unlearned destination → `.delegate(.sendFailed(_, .notLearned))`.
   Reducer tests use non-exhaustive `TestStore` where internal `seenPacketHashes` bookkeeping
   is incidental; `@MainActor` per TCA `TestStore` requirements.
2. **Cross-validation vs Python-RNS 1.3.8:** extend the generator to emit `announce_packet`
   (the full HEADER_1 ANNOUNCE packet raw bytes wrapping the reference-authentic
   `announce_payload`). Feed it to `Transport.received(id, announcePacket)` → assert Transport
   learns the destination with the reference identity hash, appData, and hops. Proves the whole
   inbound announce path (Packet unpack + Announce parse + learn) against reference bytes.
3. **Optional live** (manual): wire Transport to a live #3 TCP connection and watch `learned`
   populate from real network announces; send to a heard destination. Not a CI gate.

Fixture generation uses the conda `rns` env by absolute-path Python. Note: an external
process intermittently reverts the generator/fixtures — after regenerating, verify the
committed content contains the new fields.

## Success criteria

- Announce ingest builds a correct `learned` entry (identity, hops, interfaceID, ratchet,
  appData, emission time) with recency + dedup; validated against a reference announce packet.
- Inbound DATA to a local destination decrypts and delivers.
- `.send` to a learned destination emits a routable packet whose payload round-trips.
- `.announce` emits a valid, parseable announce per connected interface.
- `ReTiCATransport` depends only on `ReTiCA` + TCA (no Network.framework); the core stays
  dependency-free.
