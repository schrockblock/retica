# Packet + Destination — Design

**Date:** 2026-07-18
**Status:** Approved
**Sub-project:** #2 of the native iOS Reticulum (RNS) implementation

## Context

Sub-project #2 of the native iOS Reticulum library. Sub-project #1 (Crypto +
Identity core) is complete and merged: `Crypto` (SHA-256, HMAC, HKDF, PKCS7,
AES-CBC), `Token`, and `Identity` (X25519+Ed25519, encrypt/decrypt/sign/validate),
all wire-compatible with reference Reticulum (`markqvist/Reticulum`) and proven
against Python-RNS 1.3.8 cross-validation fixtures.

Inherited constraints (unchanged from #1):
- **Full wire compatibility** with reference Reticulum — byte-for-byte.
- **Pure Swift, zero third-party dependencies** — CryptoKit + CommonCrypto only.
- **No TCA in this slice** — the pure core continues. TCA enters at sub-project #3
  (Interfaces).
- **Value semantics** — `struct` types, no shared mutable global state.

This slice adds the **Packet** wire format and the **Destination** addressing +
announce model — the layer directly above crypto and directly below Transport.

**Architectural decision (this slice):** framing and crypto are **separated**. The
reference couples them (`Packet.pack()` calls `destination.encrypt()`); here `Packet`
is pure framing over opaque payload bytes, `Destination` owns crypto delegation, and
thin composers wire them for the common cases. Each unit has one responsibility and is
independently testable.

## Reference constructions (confirmed against `markqvist/Reticulum`)

Line references are to the clone at `/tmp/ReTiCA/Reticulum-ref`.

### Constants (`RNS/Reticulum.py`, `RNS/Packet.py`, `RNS/Transport.py`, `RNS/Destination.py`)

- `MTU = 500`; `TRUNCATED_HASHLENGTH = 128` bits → `DST_LEN = 16` bytes.
- `HEADER_MINSIZE = 2 + 1 + 16 = 19`; `HEADER_MAXSIZE = 2 + 1 + 32 = 35`;
  `IFAC_MIN_SIZE = 1`; `MDU = MTU - HEADER_MAXSIZE - IFAC_MIN_SIZE = 464`.
- `NAME_HASH_LENGTH = 80` bits → 10 bytes.
- **Packet types:** `DATA=0x00`, `ANNOUNCE=0x01`, `LINKREQUEST=0x02`, `PROOF=0x03`.
- **Header types:** `HEADER_1=0x00` (normal), `HEADER_2=0x01` (in transport, carries a
  transport id).
- **Transport types (packet flag, 1 bit):** `BROADCAST=0x00`, `TRANSPORT=0x01`.
  (`RELAY=0x02`/`TUNNEL=0x03` exist in `Transport` but do not fit the 1-bit packet
  flag; not used in packet framing.)
- **Destination types (2 bits):** `SINGLE=0x00`, `GROUP=0x01`, `PLAIN=0x02`, `LINK=0x03`.
- **Directions:** `IN=0x11`, `OUT=0x12`.
- **Context flag:** `FLAG_UNSET=0x00`, `FLAG_SET=0x01`.
- **Packet contexts:** `NONE=0x00`, `RESOURCE=0x01`, `RESOURCE_ADV=0x02`,
  `RESOURCE_REQ=0x03`, `RESOURCE_HMU=0x04`, `RESOURCE_PRF=0x05`, `RESOURCE_ICL=0x06`,
  `RESOURCE_RCL=0x07`, `CACHE_REQUEST=0x08`, `REQUEST=0x09`, `RESPONSE=0x0A`,
  `PATH_RESPONSE=0x0B`, `COMMAND=0x0C`, `COMMAND_STATUS=0x0D`, `CHANNEL=0x0E`,
  `KEEPALIVE=0xFA`, `LINKIDENTIFY=0xFB`, `LINKCLOSE=0xFC`, `LINKPROOF=0xFD`,
  `LRRTT=0xFE`, `LRPROOF=0xFF`.
- Hop limit: `PATHFINDER_M = 128` — `unpack` rejects `hops >= 128`.

### Packet wire format (`RNS/Packet.py` `pack`/`unpack`)

Flags byte (byte 0):
```
flags = (header_type << 6) | (context_flag << 5) | (transport_type << 4)
        | (destination_type << 2) | packet_type
```
Decode:
```
header_type      = (flags & 0b01000000) >> 6
context_flag     = (flags & 0b00100000) >> 5
transport_type   = (flags & 0b00010000) >> 4
destination_type = (flags & 0b00001100) >> 2
packet_type      = (flags & 0b00000011)
```

Layout:
- **HEADER_1:** `flags(1) ‖ hops(1) ‖ destination_hash(16) ‖ context(1) ‖ payload`
- **HEADER_2:** `flags(1) ‖ hops(1) ‖ transport_id(16) ‖ destination_hash(16) ‖ context(1) ‖ payload`

`unpack` offsets (`DST_LEN = 16`):
- HEADER_1: `dest = raw[2:18]`, `context = raw[18]`, `payload = raw[19:]`.
- HEADER_2: `transport_id = raw[2:18]`, `dest = raw[18:34]`, `context = raw[34]`,
  `payload = raw[35:]`.

**LRPROOF special case:** when `context == LRPROOF`, `pack` writes the destination's
`link_id` into the 16-byte address slot instead of `destination_hash` (and the payload
is not encrypted). On the wire this is framed identically to HEADER_1 — the address slot
just carries a link id. Our generic framing handles it; the caller supplies the 16-byte
address. No special-case code needed in `Packet`.

**MTU guard:** `pack` raises if `len(raw) > MTU` (500).

### Packet hash (`get_hashable_part` / `get_hash`)

```
hashable_part = bytes([raw[0] & 0b00001111])           # keeps dest_type + packet_type only
hashable_part += raw[18:]  if HEADER_2  else  raw[2:]  # skips transport_id (and flags/hops)
packet_hash    = SHA256(hashable_part)                 # 32 bytes
truncated_hash = packet_hash[:16]
```
Masking `raw[0] & 0x0F` and skipping `transport_id` make the hash stable as `hops`,
`header_type`, and `transport_id` change in transit.

### Destination addressing (`RNS/Destination.py`)

- `expand_name(identity, app_name, *aspects)`:
  `app_name` then `"." + aspect` for each aspect; if `identity != None`, append
  `"." + identity.hexhash`. Dots are forbidden in `app_name`/aspects (`ValueError`).
- `name_hash = SHA256( expand_name(None, app_name, *aspects).utf8 )[:10]`
  (i.e. the name **without** the identity component).
- `Destination.hash(identity, app_name, *aspects)`:
  `addr_hash_material = name_hash(10)`; if identity present, append `identity.hash(16)`
  (accepts an `Identity` or a raw 16-byte hash); return `SHA256(addr_hash_material)[:16]`.
- `hexhash = hash.hex()`.

### Destination encrypt/decrypt dispatch

- **PLAIN:** passthrough (`return plaintext` / `return ciphertext`).
- **SINGLE:** delegate to `Identity.encrypt(plaintext, ratchet:)` /
  `Identity.decrypt(ciphertext, ratchets:enforceRatchets:)`.
- **GROUP:** delegate to `Token(groupKey)` (`Token.generate_key()` returns 32 or 64
  bytes → AES-128/256). Symmetric pre-shared key.

### Announce (`RNS/Destination.py` `announce`, `RNS/Identity.py` `validate_announce`)

Only `SINGLE`, `IN` destinations announce.

- `random_hash = get_random_hash()[:5] ‖ int(time.time()).to_bytes(5, "big")` → 10 bytes.
- `ratchet = b""` normally, or the 32-byte ratchet public key if ratchets enabled.
- `signed_data = destination_hash(16) ‖ public_key(64) ‖ name_hash(10) ‖ random_hash(10)
  ‖ ratchet(0|32) [‖ app_data]`.
- `signature = identity.sign(signed_data)` (64 bytes).
- `announce_data (payload) = public_key(64) ‖ name_hash(10) ‖ random_hash(10)
  ‖ ratchet(0|32) ‖ signature(64) [‖ app_data]`.
- The announce Packet uses `context_flag = FLAG_SET` iff a ratchet is present, and
  `context = PATH_RESPONSE` for path responses else `NONE`.

Validation (`validate_announce`, pure part):
- Parse `public_key = data[:64]`. If `context_flag` set, the layout includes the 32-byte
  ratchet between `random_hash` and `signature`; else no ratchet. Field offsets:
  `name_hash = data[64:74]`, `random_hash = data[74:84]`, then (ratchet(32) if flag),
  then `signature(64)`, then optional `app_data`.
- `signed_data = destination_hash ‖ public_key ‖ name_hash ‖ random_hash ‖ ratchet
  ‖ app_data`; verify with the announced identity's Ed25519 key.
- Recompute `expected_hash = SHA256(name_hash ‖ announced_identity.hash)[:16]`; require
  `destination_hash == expected_hash`.
- (Deferred to Transport: `remember`, ratchet persistence, blackhole checks, path table.)

## Scope

### In scope

- **Packet framing** — `Packet` value type: fields ⇄ raw (`packed()`/`init?(raw:)`),
  flags encode/decode, packet hash + truncated hash, MTU guard, all wire constants.
- **Destination addressing** — static `expandName`/`nameHash`/`hash`; instance holding
  `kind`, `direction`, `appName`, `aspects`, and `identity?`/`groupKey?`; `hash`,
  `nameHash`; `encrypt`/`decrypt` dispatch for SINGLE, GROUP, PLAIN.
- **Announce** — `buildPayload(...)` (signed announce payload) and
  `parse(payload:destinationHash:contextFlagSet:) -> Parsed?` (signature + hash
  validation, returns recovered `Identity` + fields). Ratchet field carried as bytes.
- **Composers** — `Packet.data(to:plaintext:ratchet:)` and `Packet.announce(from:...)`
  wiring Destination crypto + Packet framing for the common cases.
- **Determinism seams** — inject `randomHash` (prefix + big-endian time) for announce
  tests; random-by-default in the public path.

### Out of scope (deferred)

- Transport: routing, path tables, `known_destinations`/`remember`, hop mutation in
  transit, HEADER_2 transport-id *injection decisions* (parsing/emitting HEADER_2 bytes
  is in scope; deciding when to add a transport id is Transport, #4).
- `send`/`resend`/`PacketReceipt`/`prove`/proof validation (Transport/Link).
- Ratchet rotation, persistence, `enable_ratchets`; callbacks; request handlers; links;
  Transport registration.
- LINK **session** crypto (#5). The LINK dest-type constant and LRPROOF framing are
  recognized; the link handshake is not implemented.
- Announce "remember" side effects (known-destination/ratchet tables) — Transport, #4.
- Any TCA. This slice is pure Swift.

## Module structure

```
Sources/ReTiCA/
  Packet/
    PacketConstants.swift  // PacketType, HeaderType, TransportType, DestinationType,
                           // PacketContext enums + Packet.mtu / header sizes
    Packet.swift           // Packet struct: packed() / init?(raw:) / packetHash + composers
  Destination/
    Destination.swift      // addressing (static) + instance + encrypt/decrypt dispatch
    Announce.swift         // buildPayload + parse/validate

Tests/ReTiCATests/
  Packet/PacketTests.swift
  Destination/DestinationTests.swift
  Destination/AnnounceTests.swift
  Vectors/  (extend generate_fixtures.py + fixtures.json; extend VectorFixtures.swift;
             add PacketCrossValidationTests / AnnounceCrossValidationTests)
```

## Public API sketch

```swift
public enum PacketType: UInt8 { case data = 0, announce = 1, linkRequest = 2, proof = 3 }
public enum HeaderType: UInt8 { case header1 = 0, header2 = 1 }
public enum TransportType: UInt8 { case broadcast = 0, transport = 1 }
public enum DestinationType: UInt8 { case single = 0, group = 1, plain = 2, link = 3 }
public enum PacketContext: UInt8 { case none = 0, resource = 1, /* … */ lrproof = 0xFF }

public struct Packet: Equatable {
    public var headerType: HeaderType
    public var packetType: PacketType
    public var transportType: TransportType
    public var destinationType: DestinationType
    public var context: PacketContext
    public var contextFlag: Bool
    public var hops: UInt8
    public var destinationHash: Data     // 16 bytes (or link_id for LRPROOF)
    public var transportId: Data?        // 16 bytes, present iff headerType == .header2
    public var payload: Data             // opaque: ciphertext or plaintext

    public init(...)                     // validates field sizes
    public func packed() throws -> Data  // throws PacketError.exceedsMTU / .missingTransportId
    public init?(raw: Data)              // nil on malformed (too short, hops >= 128, bad transportId)

    public var packetHash: Data { get }      // 32 bytes
    public var truncatedHash: Data { get }   // 16 bytes

    public static let mtu = 500

    // Composers
    public static func data(to destination: Destination, plaintext: Data,
                            ratchet: Data? = nil) -> Packet
    public static func announce(from destination: Destination, payload: Data,
                                pathResponse: Bool, ratchetPresent: Bool) -> Packet
}

public struct Destination {
    public enum Kind: UInt8 { case single = 0, group = 1, plain = 2, link = 3 }
    public enum Direction: UInt8 { case `in` = 0x11, out = 0x12 }

    // Addressing (pure statics)
    public static func expandName(appName: String, aspects: [String],
                                  identityHexHash: String?) -> String
    public static func nameHash(appName: String, aspects: [String]) -> Data   // 10 bytes
    public static func hash(identityHash: Data?, appName: String,
                            aspects: [String]) -> Data                        // 16 bytes

    public let kind: Kind
    public let direction: Direction
    public let appName: String
    public let aspects: [String]
    public var identity: Identity?    // SINGLE
    public var groupKey: Data?        // GROUP (Token key)

    public var hash: Data { get }
    public var nameHash: Data { get }

    public func encrypt(_ plaintext: Data, ratchet: Data? = nil) -> Data
    public func decrypt(_ ciphertext: Data, ratchets: [Data]? = nil,
                        enforceRatchets: Bool = false) -> Data?
}

public struct Announce {
    public struct Parsed: Equatable {
        public let identity: Identity      // public-only, recovered from the announce
        public let publicKey: Data
        public let nameHash: Data
        public let randomHash: Data
        public let ratchet: Data?
        public let signature: Data
        public let appData: Data?
    }

    public static func buildPayload(identity: Identity, destinationHash: Data,
                                    nameHash: Data, randomHash: Data,
                                    ratchet: Data? = nil, appData: Data? = nil) -> Data
    public static func parse(payload: Data, destinationHash: Data,
                             contextFlagSet: Bool) -> Parsed?

    public static func randomHash(now: UInt64, randomPrefix: Data) -> Data  // prefix(5) ‖ time-be(5)
}

public enum PacketError: Error { case exceedsMTU, missingTransportId, malformed }
```

Errors: `Packet.init?(raw:)` returns `nil` on any malformed input (matching the
reference's drop-on-malformed behavior); `packed()` throws for programmer errors
(over-MTU, HEADER_2 without a transport id). `Announce.parse` returns `nil` on invalid
signature or destination-hash mismatch.

## Data flow

- **Outbound data:** `ct = destination.encrypt(pt, ratchet:)` → `Packet(…, payload: ct)`
  → `packed()`. Convenience: `Packet.data(to:plaintext:ratchet:)`.
- **Inbound data:** `Packet(raw:)` → for encrypted DATA, `destination.decrypt(payload)`.
- **Announce out:** `Announce.buildPayload(...)` → `Packet.announce(from:payload:…)` →
  `packed()`.
- **Announce in:** `Packet(raw:)` (ANNOUNCE) → `Announce.parse(payload:destinationHash:
  contextFlagSet:)` → validated `Identity` + fields. (`remember` deferred to Transport.)

## Verification strategy

Three layers, under the project's mutation-testing discipline (write → pass → mutate →
fail → revert → pass).

1. **Known-answer / structural tests:**
   - Flags byte encode/decode for every combination of header/context-flag/transport/
     dest/packet fields.
   - `packed()` ⇄ `init?(raw:)` round-trip for HEADER_1 and HEADER_2 across packet types.
   - MTU-exceed → throw; malformed (too short, `hops >= 128`, HEADER_2 missing transport
     id) → `nil`.
   - `packetHash` stability: same hash when `hops`/`transportId`/`headerType` change but
     `destination_hash`/`context`/`payload` are equal.
   - `Destination.expandName`/`nameHash`/`hash` structural checks; dots rejected.
   - `Announce.buildPayload` ⇄ `parse` round-trip (with and without ratchet, with and
     without app_data); tampered signature → `nil`; wrong destination hash → `nil`.
2. **Python-RNS 1.3.8 cross-validation fixtures** (extend `generate_fixtures.py`):
   - A reference-packed **PLAIN** DATA packet (deterministic): our `init?(raw:)` fields
     match, and our `packed()` reproduces the reference bytes byte-for-byte.
   - A reference-packed **GROUP** packet with a fixed key + fixed IV is non-deterministic
     due to the random IV; instead assert our `Destination(group).decrypt` recovers the
     reference plaintext (like the #1 Token vector), and round-trip our own pack/unpack.
   - `packetHash` of a reference raw packet matches reference `get_hash`.
   - `Destination.hash(identityHash, app_name, aspects)` matches reference
     `Destination.hash` for a known app_name/aspects/identity.
   - A reference **announce** (`Destination.announce(send=False)` payload) validates via
     `Announce.parse` (signature + hash), and parsed fields match.
3. **Round-trips + cross-decrypt:** Swift encrypt→Packet→unpack→decrypt for SINGLE
   (using the #1 Identity), GROUP (Token), PLAIN.

Fixture generation uses the conda `rns` env (see the project's RNS reference notes:
invoke with `python`, not `python3`).

## Success criteria

- Byte-exact `Packet` framing: our `packed()` reproduces reference raw bytes for
  deterministic (PLAIN) packets; our `init?(raw:)` parses reference packets correctly.
- `packetHash` matches reference `get_hash` byte-for-byte.
- `Destination.hash`/`nameHash` match reference for known inputs.
- `Announce.parse` validates reference-generated announces (signature + hash); build⇄parse
  round-trips including ratchet and app_data.
- SINGLE/GROUP/PLAIN encrypt→pack→unpack→decrypt round-trips succeed.
- Zero third-party dependencies; no TCA; value semantics throughout.
