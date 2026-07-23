# Resource Compression (bzip2) — Design

**Status:** Approved (design phase)
**Date:** 2026-07-23
**Depends on:** the merged Resource stack (6a–6c + Link/Resource integration + HMU + request/response).

## Goal

Auto-compress resource payloads with bzip2, matching Python-RNS 1.3.8 byte-for-byte. Full bidirectional:
compress on send (set the advertisement compression flag when the compressed payload is smaller) and
decompress on receive. Wire-compatible and cross-validated against genuine RNS.

## Scope

**In scope**

1. A vendored reference bzip2 C library as a new SPM target (`Cbzip2`), with a thin Swift wrapper in
   `ReTiCATransport`. Core `ReTiCA` stays zero-dependency and untouched.
2. Sender-side compression in `ResourceTransfer.init(sending:)`: compress `data`; if the result is smaller,
   use it as the stream payload and set the compression flag (bit 1, `0x02`); else send uncompressed.
3. Receiver-side decompression in the `ResourceTransfer` receiver-assembly path: when the accepted
   advertisement's `isCompressed` is set, decompress the assembled payload (using the known `dataSize`)
   before verifying / proofing / surfacing it.
4. Cross-validation against genuine RNS bz2 (byte-identical compression + decompressing a genuine-RNS
   stream).

**Explicitly deferred (out of scope)**

- True >1MB multi-segment resources (already deferred); the RNS `RESOURCE_MAX_EFFICIENT_SIZE` heuristic
  that skips auto-compression on very large payloads is therefore moot here.
- Any change to the `ReTiCA` core, the wire advertisement model, or the request/response layers.

## Reference mechanics (Python-RNS 1.3.8)

- RNS compresses a resource's data with `bz2.compress(data)` (default `compresslevel=9`) BEFORE encryption.
  If `len(compressed) < len(data)`, it transmits the compressed bytes and sets the compression flag; else it
  transmits the uncompressed bytes and leaves the flag clear.
- The compression flag is **bit 1** of the advertisement `f` field (`0x02`). Our `ResourceAdvertisement`
  already models it: `isCompressed { (flags >> 1) & 1 == 1 }`. Bit 0 (`0x01`) = encrypted.
- The resource `hash` (`h`) and `dataSize` (`d`) are computed over the **original uncompressed** data. The
  `transferSize` (`t`) is the size of the encrypted transfer stream (i.e. over the compressed-or-not
  payload). The receiver knows the original size from `d`, so it can size the decompression buffer exactly.
- Python's `bz2.compress(data, 9)` wraps libbzip2's one-shot compression with block size 900k
  (`blockSize100k = 9`), default work factor, verbosity 0. The reference `BZ2_bzBuffToBuffCompress` with the
  same parameters produces byte-identical output.

## Current state (what exists / what's missing)

- `Sources/ReTiCA/Resource/Resource.swift`: `buildStream(data:prefix:sessionKey:)` = `Token(key).encrypt(prefix
  ‖ data)`; `parts(stream:sdu:)` chunks the encrypted stream; `assemble(parts:sessionKey:)` = decrypt + drop
  the 4-byte prefix; `resourceHash(data:randomHash:)` = `full_hash(data ‖ r)`; `verify`, `proofData`. **None
  of these change** — they operate on whatever bytes they are handed.
- `Sources/ReTiCA/Resource/ResourceAdvertisement.swift`: `isCompressed` accessor already exists (bit 1);
  pack/unpack already round-trip `flags`. **No change.**
- `Sources/ReTiCATransport/ResourceTransfer.swift`: the sender `init(sending:)` builds `advFlags = 0x01 |
  (requestID != nil ? ...)` and never sets `0x02`; it calls `buildStream(data: data, ...)` and
  `resourceHash(data: data, ...)` on the raw `data`. The receiver path calls `assemble` then `verify` on the
  assembled bytes and surfaces `.received(out)`. The accepted advertisement (with its flags) is available on
  the receiver's state.
- `Package.swift`: four targets (`ReTiCA` zero-dep, `ReTiCAInterfaces`, `ReTiCATransport`, `ReTiCANode`);
  only external dep is Point-Free's Composable Architecture. **No C-interop / system-library targets today.**
- No compression code anywhere; Apple's Compression framework has no bzip2.

## Architecture

All compression logic lives in `ReTiCATransport` (where `advFlags` is already built and where `assemble` /
`verify` are already called). The `ReTiCA` core and the wire model are untouched.

### `Cbzip2` target + `Bzip2.swift` wrapper

- `Sources/Cbzip2/`: the reference libbzip2 source (`blocksort.c`, `bzlib.c`, `compress.c`, `crctable.c`,
  `decompress.c`, `huffman.c`, `randtable.c`, `bzlib.h`, `bzlib_private.h`) + `include/module.modulemap`
  exposing `bzlib.h`. BSD-style license header retained.
- `Package.swift`: add `.target(name: "Cbzip2")`; `ReTiCATransport` gains `"Cbzip2"` in its dependencies.
- `Sources/ReTiCATransport/Bzip2.swift`:
  ```
  enum Bzip2 {
      static func compress(_ data: Data) -> Data?      // BZ2_bzBuffToBuffCompress, blockSize100k=9, workFactor=0, verbosity=0
      static func decompress(_ data: Data, expectedSize: Int) -> Data?   // BZ2_bzBuffToBuffDecompress, small=0, verbosity=0
  }
  ```
  `compress` allocates a dest buffer of `data.count + data.count/100 + 600` (the libbzip2-documented
  worst-case bound) and returns the exact-length result, or `nil` on error. `decompress` allocates
  `expectedSize` bytes (the known original size) and returns the result, or `nil` on error/size mismatch.

### Sender (`ResourceTransfer.init(sending:)`)

- Compute `let payload: Data; let compressed = Bzip2.compress(data)`. If `compressed` is non-nil and
  `compressed.count < data.count`, set `payload = compressed` and OR `0x02` into `advFlags`; else `payload =
  data` (flag unset).
- Build the stream from `payload`: `Resource.buildStream(data: payload, prefix: prefix, sessionKey:
  sessionKey)`. **`resourceHash` and `dataSize` are still computed over the original `data`** (unchanged),
  and `transferSize = stream.count`. `numberOfParts` / `hashmap` derive from the `payload`-based stream.

### Receiver (`ResourceTransfer` receiver-assembly path)

- After `assemble(parts:sessionKey:)` yields the prefix-stripped `payload`: if the accepted advertisement's
  `isCompressed` is set, `let data = Bzip2.decompress(payload, expectedSize: Int(adv.dataSize))` (fail the
  transfer if `nil`); else `data = payload`.
- Run the existing `verify(data:randomHash:hash:)`, `proofData(data:hash:)`, and `.delegate(.received(data))`
  on `data` (the decompressed original), so all hash/proof logic is unchanged and matches the
  original-data hash.

## Data flow (compressed round-trip)

1. Sender: `compressed = bz2(data)`; smaller → `payload = compressed`, `advFlags |= 0x02`. `stream =
   encrypt(prefix ‖ payload)`; `hash = full_hash(data ‖ r)`, `dataSize = data.count`, `transferSize =
   stream.count`. Advertise + serve parts (unchanged transfer machinery).
2. Receiver: accept ADV (records `isCompressed`, `dataSize`), request + collect parts, `assemble` →
   `payload`. `isCompressed` → `data = bz2_decompress(payload, dataSize)`. `verify(data ‖ r) == hash` →
   proof + `.received(data)`.

## Error handling / edge cases

- **Incompressible/random data:** `bz2` output ≥ input → send uncompressed, flag clear. Correct.
- **`compress` returns nil** (allocation/library error): treat as "not smaller" → send uncompressed. A send
  is never blocked by a compression failure.
- **`decompress` returns nil** (corrupt stream / size mismatch): the receiver fails the transfer
  (`.delegate(.failed)`), same as a verify failure.
- **Empty data:** `bz2("")` is larger than empty → sent uncompressed. Safe.
- **A genuine-RNS peer sends compressed:** we decompress via the flag — required for interop.
- **We send uncompressed to a genuine-RNS peer:** always valid (flag clear).

## Testing

- **`Bzip2` unit:** `decompress(compress(x)) == x` for representative payloads (compressible text, random
  bytes, empty); `compress` of random data is not used when not smaller.
- **Cross-validation (genuine RNS bz2):**
  - `Bzip2.compress(originalData)` byte-equals the fixture's `bz2.compress(originalData)` (byte-identical vs
    Python). If a parameter nuance breaks byte-equality, that is a real finding — investigate the
    blockSize/workFactor mapping; only if genuinely non-deterministic across the reference impl do we fall
    back to interop (round-trip) for the compress direction, as with the Ed25519-sign precedent.
  - `Bzip2.decompress(fixture.compressed, expectedSize: d)` equals the fixture's original data (decoding a
    genuine-RNS stream).
  - Our `ResourceAdvertisement` for the compressed resource packs to the same bytes as the genuine-RNS
    flagged advertisement (reusing the existing advertisement cross-val pattern, now with `f = 0x03`).
- **End-to-end (transport):** a sender `ResourceTransfer` built from compressible data sets the flag and
  serves parts; a receiver assembles, decompresses, verifies, and surfaces the exact original bytes. Include
  an incompressible-data case that stays uncompressed (flag clear) and still round-trips.
- Every new/changed test is mutation-swept. Committed directly to `main`.

## Known simplifications (carry to review)

- Compression is always attempted for our (single-segment) resources; RNS's `RESOURCE_MAX_EFFICIENT_SIZE`
  large-payload skip is moot until >1MB multi-segment lands, and interop holds regardless (uncompressed is
  always valid).
- Byte-identical compression relies on the vendored reference libbzip2 with Python's default parameters; the
  cross-val test is what actually proves it.
- All compression logic is transport-layer; the `ReTiCA` core and the wire advertisement model are unchanged.
