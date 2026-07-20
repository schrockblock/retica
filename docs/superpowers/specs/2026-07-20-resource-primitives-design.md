# Resource Primitives — Design (slice 6a)

**Status:** Approved
**Date:** 2026-07-20
**Depends on:** Crypto/Identity/Token (#1), Packet (#2), Link `Token` cipher (5-links-a), the double-only `MsgPack` (5-links-b). All merged.

## Goal

Implement the pure, single-segment, uncompressed **Resource representation primitives** of the
Reticulum Resource protocol in the `ReTiCA` core: a richer `MsgPack` codec, the resource
content computations (hash, encrypted-stream build, part split + map-hashes, assembly, proof),
and `ResourceAdvertisement` pack/unpack. Byte-for-byte wire-compatible with reference RNS 1.3.8,
cross-validated. No transfer state machine, TCA, or integration — this is the primitives layer,
mirroring the 5-links-a "pure handshake primitives" approach.

## Scope

**In scope** (pure `ReTiCA` core, zero deps)
- `MsgPack` codec extended to a `MsgPackValue` model: `.uint`, `.bin`, `.string`, `.nil`,
  ordered `.map`, plus the existing `.double`. `encode`/`decode`, emitting the minimal msgpack
  forms `umsgpack` uses.
- `Resource` content primitives (session-key-parameterized, since resources are Link-coupled):
  resource hash, encrypted-stream build, part split + map-hashes + hashmap, assembly, hash
  verification, proof build/validate.
- `ResourceAdvertisement` struct with `pack()`/`unpack(_:)` and flag accessors.
- Cross-validation vs RNS 1.3.8 (drives genuine `umsgpack`, `full_hash`, `Token`, and
  `ResourceAdvertisement`).

**Explicitly out of scope** (future slices)
- Multi-segment resources (data whose parts exceed one advertisement's `HASHMAP_MAX_LEN`).
- Compression (bz2), auto-compress.
- The transfer state machine: advertise → request parts → send parts → window flow control →
  assemble → prove, with retransmission/timeouts/watchdog.
- Request/response resource mode, metadata.
- TCA reducer, LinkSession/Endpoint wiring (resources over a live link).

## Reference facts (RNS 1.3.8, verified against `RNS/Resource.py`)

- **Stream:** `stream = Token(link_key).encrypt(prefix_random_hash(4) ‖ data)`. The whole data is
  encrypted as one stream (Token, random IV), then split. Parts are ciphertext chunks.
- **Parts:** `stream` split into `sdu`-sized chunks (`sdu = link.mdu` or `Packet.MDU`); each chunk
  is carried in a `RESOURCE`-context packet (plaintext-exempt — the chunk is already ciphertext).
- **Resource random hash `r`:** `r = random_hash()[:4]` (distinct from the 4-byte stream prefix).
- **Resource hash `h`:** `h = full_hash(data ‖ r)` over the ORIGINAL (pre-prefix, pre-encryption)
  data (confirmed by the assembly round-trip at `Resource.py:694`).
- **Map hash:** `map_hash(chunk) = full_hash(chunk ‖ r)[:4]` (`MAPHASH_LEN = 4`). `hashmap` =
  concatenation of map hashes.
- **Assembly:** `data = decrypt(join(chunks))`, then strip the first 4 bytes (prefix) → original
  data; verify `full_hash(data ‖ r) == h`.
- **Proof:** receiver computes `proof = full_hash(data ‖ h)`; `proof_data = h ‖ proof` (32+32=64).
  Sender precomputes `expected_proof = full_hash(data ‖ h)` and validates `proof_data[32:] ==
  expected_proof` (with `len(proof_data) == 64`).
- **Advertisement:** `umsgpack.packb({t,d,n,h,r,o,i,l,q,f,m})` in that key order. `t`=transfer
  (encrypted stream) size, `d`=original data size, `n`=number of parts, `h`=hash, `r`=random hash,
  `o`=original (first-segment) hash (== `h` for a single segment), `i`=segment index (0),
  `l`=total segments (1), `q`=request id (nil here), `f`=flags int, `m`=hashmap bytes.
  Flags: `f = (has_metadata<<5)|(is_response<<4)|(is_request<<3)|(split<<2)|(compressed<<1)|encrypted`.
  For this slice: `encrypted=1`, others 0 → `f = 0x01`.

## Architecture

### MsgPack (`Sources/ReTiCA/Support/MsgPack.swift`, extend)

Keep the existing `encode(Double)`/`decodeDouble` (used by Link RTT). Add:

```
public indirect enum MsgPackValue: Equatable {
    case uint(UInt64)
    case bin(Data)
    case string(String)
    case double(Double)
    case null
    case map([(String, MsgPackValue)])   // ordered; keys are strings
}

public static func encode(_ value: MsgPackValue) -> Data
public static func decodeValue(_ data: Data) -> MsgPackValue?
```

Encoding uses the minimal forms `umsgpack` emits: positive fixint (0–127) / uint8 (`0xCC`) /
uint16 (`0xCD`) / uint32 (`0xCE`) / uint64 (`0xCF`) by magnitude; `bin8`/`bin16`/`bin32`
(`0xC4`/`0xC5`/`0xC6`) by length; `fixstr` (`0xA0|len`, len ≤ 31) / `str8` (`0xD9`) for keys;
`null` = `0xC0`; `fixmap` (`0x80|n`, n ≤ 15) / `map16` (`0xDE`). `double` stays `0xCB` + 8 BE
bytes. `Map` equality compares ordered key/value pairs. (Arrays, negative ints, bool, ext, and
str16/32 are out of scope — the advertisement needs none of them.)

### Resource (`Sources/ReTiCA/Resource/Resource.swift`, new — pure `enum Resource`)

```
public enum Resource {
    public static let mapHashLength = 4
    public static let randomHashSize = 4

    // sender
    public static func resourceHash(data: Data, randomHash: Data) -> Data            // full_hash(data ‖ r)
    public static func buildStream(data: Data, prefix: Data, sessionKey: Data) -> Data  // Token.encrypt(prefix ‖ data); Data() on bad key
    public static func parts(stream: Data, sdu: Int) -> [Data]                         // sdu-sized chunks
    public static func mapHash(chunk: Data, randomHash: Data) -> Data                  // full_hash(chunk ‖ r)[:4]
    public static func hashmap(parts: [Data], randomHash: Data) -> Data                // concat map hashes
    public static func expectedProof(data: Data, hash: Data) -> Data                   // full_hash(data ‖ h)

    // receiver
    public static func assemble(parts: [Data], sessionKey: Data) -> Data?              // decrypt(join) then drop 4-byte prefix
    public static func verify(data: Data, randomHash: Data, hash: Data) -> Bool        // full_hash(data ‖ r) == h
    public static func proofData(data: Data, hash: Data) -> Data                       // h ‖ full_hash(data ‖ h)  (64B)
    public static func validateProof(proofData: Data, expectedProof: Data) -> Bool     // count==64 && proofData[32:]==expectedProof
}
```

`buildStream`/`assemble` wrap `Token(key:)` (like `Link.encrypt`/`Link.decrypt`), returning a
`Data()` / `nil` sentinel on a bad key rather than trapping.

### ResourceAdvertisement (`Sources/ReTiCA/Resource/ResourceAdvertisement.swift`, new)

```
public struct ResourceAdvertisement: Equatable {
    public var transferSize: UInt64   // t
    public var dataSize: UInt64       // d
    public var numberOfParts: UInt64  // n
    public var hash: Data             // h
    public var randomHash: Data       // r
    public var originalHash: Data     // o
    public var segmentIndex: UInt64   // i
    public var totalSegments: UInt64  // l
    public var requestID: Data?       // q (nil this slice)
    public var flags: UInt8           // f
    public var hashmap: Data          // m

    public func pack() -> Data                             // MsgPack map in RNS key order t,d,n,h,r,o,i,l,q,f,m
    public static func unpack(_ data: Data) -> ResourceAdvertisement?

    public var isEncrypted: Bool { flags & 0x01 == 0x01 }
    public var isCompressed: Bool { (flags >> 1) & 0x01 == 0x01 }
    public var isSplit: Bool { (flags >> 2) & 0x01 == 0x01 }
    public var isRequest: Bool { (flags >> 3) & 0x01 == 0x01 }
    public var isResponse: Bool { (flags >> 4) & 0x01 == 0x01 }
    public var hasMetadata: Bool { (flags >> 5) & 0x01 == 0x01 }
}
```

`pack()` builds `MsgPackValue.map([("t", .uint(t)), ("d", .uint(d)), ("n", .uint(n)), ("h",
.bin(h)), ("r", .bin(r)), ("o", .bin(o)), ("i", .uint(i)), ("l", .uint(l)), ("q", q.map(bin) ??
.null), ("f", .uint(UInt64(flags))), ("m", .bin(m))])` and `MsgPack.encode`s it. `unpack` decodes
and reads each key. Key order matches RNS `ResourceAdvertisement.pack` for byte-exactness.

## Cross-validation (vs Python-RNS 1.3.8, non-circular)

The fixture generator (`Tests/ReTiCATests/Vectors/generate_fixtures.py`) drives genuine reference
code — no full `RNS.Resource`/`RNS.Link` needed:
- **MsgPack:** `umsgpack.packb({...})` for a representative dict (uint/bin/str/nil/map) →
  byte-exact vs `MsgPack.encode`; and our `decodeValue` recovers a umsgpack-packed dict.
- **Resource hashes/proof:** `RNS.Identity.full_hash(data + r)` (resource hash),
  `full_hash(chunk + r)[:4]` (map hash), `full_hash(data + h)` (proof) → match our functions.
- **Stream cipher:** `RNS.Cryptography.Token(key).encrypt(prefix + data)` → our `assemble`
  decrypts it back to `prefix ‖ data` → strips to `data`. (Byte-exact encrypt isn't possible —
  random IV — so validate the decrypt direction, as with the Link cipher.)
- **Advertisement:** construct a genuine `RNS.ResourceAdvertisement()`, set `t/d/n/h/r/o/i/l/q/f/m`,
  call `.pack()` → byte-exact vs our `ResourceAdvertisement.pack()`; and our `unpack` decodes it.

## Testing

- **MsgPack unit tests:** encode each `MsgPackValue` form to its exact bytes (fixint/uint8-32/64,
  bin8/16/32, fixstr, null, fixmap); round-trip; decode rejects malformed. Cross-validate the
  advertisement dict bytes vs `umsgpack.packb`.
- **Resource primitive unit tests:** `resourceHash`/`mapHash`/`expectedProof` equal the expected
  `fullHash` compositions; `buildStream`→`assemble` round-trips to the original data under a known
  key; `parts` splits at `sdu` boundaries and `hashmap` length is `4·n`; `verify` accepts the right
  hash and rejects a tampered one; `proofData` is 64 bytes and `validateProof` accepts the matching
  proof, rejects wrong length / wrong proof.
- **End-to-end primitive round-trip:** sender: `stream = buildStream(data, prefix, key)`; `parts`;
  `hashmap`; `h = resourceHash(data, r)`; `expected = expectedProof(data, h)`; build a
  `ResourceAdvertisement` and `pack()`/`unpack()` it. Receiver: `unpack` the advertisement;
  `assemble(parts, key)` → data'; `verify(data', r, h)` true; `proofData(data', h)`. Sender:
  `validateProof(proofData, expected)` true. Assert data' == data.
- **Cross-validation tests** vs the reference fixtures (msgpack bytes, hashes, decrypt, advertisement
  bytes).
- **Mutation testing** per the project three-step discipline for every new/changed test.

## Global constraints

- Full wire compatibility with reference RNS 1.3.8; cross-validation drives genuine reference code
  (never a reimplementation).
- The `ReTiCA` core stays dependency-free (`MsgPack`/`Resource`/`ResourceAdvertisement` use only the
  Swift stdlib + the existing in-core `Crypto`/`Token`).
- Swift 6 strict concurrency; all new types `Equatable` where they hold state.
- Platform floor iOS 16 / macOS 13 / tvOS 16 / watchOS 9 / macCatalyst 16.
- Single-segment, uncompressed only; no state machine, no TCA, no integration.

## Non-goals recap

Multi-segment, compression, the transfer/windowing state machine, retransmission, request/response,
metadata, and any TCA/Link/Endpoint integration are all deferred. This slice delivers the pure,
cross-validated building blocks to represent, chunk, hash, encrypt, assemble, and prove a
single-segment resource.
