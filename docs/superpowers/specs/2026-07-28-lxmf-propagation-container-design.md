# LXMF-4d-1: Propagation Container + `transient_id` — Design

**Sub-project:** LXMF-4d (propagation), first slice. LXMF-4d decomposes into: **4d-1 propagation container + transient_id [this]** → 4d-2 client outbound via a propagation node → 4d-3 propagation node store + serve → 4d-4 client inbound sync → 4d-5 PN↔PN peering (mesh, deferrable). Stamps/cost stay with LXMF-5. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMessage.pack()` PROPAGATED branch (`LXMessage.py:429-436`); `transient_id = RNS.Identity.full_hash(lxmf_data)`.

## Goal

Establish the pure, byte-cross-validated foundation for propagation: the container format a propagation node (PN) stores and serves, and the `transient_id` that identifies/dedups a propagated message. Everything downstream (send, store, serve, sync) builds on this.

## The format

Genuine LXMF (`LXMessage.py:429-436`) prepares a message for a PN as:

```
lxmf_data          = destHash(16) ‖ destination-encrypted(sourceHash ‖ signature ‖ payload_msgpack)
transient_id       = full_hash(lxmf_data)                       # SHA-256 (32 bytes) — propagation identity/dedup key
propagation_packed = msgpack([ timestamp, [ lxmf_data, … ] ])   # the container a PN stores/serves
```

- `destination-encrypted(...)` is `destination.encrypt(self.packed[DESTINATION_LENGTH:])` — the recipient-encrypted tail of the normal delivery packing (everything after the leading destHash). This is the SAME encryption opportunistic delivery uses.
- `transient_id` is keyed on the encrypted blob, so a PN can store, dedup, and serve a message without ever seeing plaintext. It is deliberately distinct from `message.hash` (the delivery dedup key, keyed on the plaintext payload).
- The container's outer array is `[timestamp, [entries]]`: a wall-clock time (when the PN packed/received it) and a list of `lxmf_data` entries (a single message when a client submits one; multiple when a PN batches).

## Scope

**In (pure, `Sources/ReTiCA/LXMF/LXMFPropagation.swift`, zero-dep like `LXMessage`):** a `LXMFPropagation` namespace operating on opaque `lxmf_data` blobs.

```swift
public enum LXMFPropagation {
    /// Propagation identity / dedup key: SHA-256 of a full lxmf_data entry (RNS Identity.full_hash).
    public static func transientId(lxmfData: Data) -> Data          // Crypto.fullHash(lxmfData)
    /// The recipient's lxmf.delivery destination hash — the leading 16 bytes of an entry.
    public static func destinationHash(lxmfData: Data) -> Data?     // nil if entry < 16 bytes
    /// Assemble one entry from a destination hash and the recipient-encrypted tail.
    public static func lxmfData(destinationHash: Data, encryptedData: Data) -> Data
    /// Pack the PN container: msgpack([timestamp, [entries…]]).
    public static func container(timestamp: Double, entries: [Data]) -> Data
    /// Parse a PN container back into its timestamp and entries; nil if malformed.
    public static func parseContainer(_ data: Data) -> (timestamp: Double, entries: [Data])?
}
```

- `container` = `MsgPack.encode(.array([.double(timestamp), .array(entries.map { .bin($0) })]))`.
- `parseContainer` = `MsgPack.decodeValue`, expecting `.array([.double(ts), .array([.bin, …])])`; returns `nil` on any shape mismatch.
- `destinationHash` uses the existing `LXMessage.destinationLength` (16).
- `transientId` = `Crypto.fullHash(lxmfData)` (the same SHA-256 primitive as `message.hash`).

**Out (deferred to later 4d slices):** the destination *encryption/decryption* of the tail. That lives at the Transport/Endpoint boundary — exactly where opportunistic delivery already encrypts (`Transport.send`) and decrypts — and gets wired in 4d-2 (send) / 4d-4 (sync). In this slice the encrypted tail is opaque bytes.

## Architecture

`LXMFPropagation` depends only on `Crypto.fullHash`, `MsgPack`, and `LXMessage.destinationLength` — no Identity crypto, no TCA, no Transport. It sits beside `LXMessage` in the pure core. This keeps the propagation *wire* concern isolated and independently testable, matching how `LXMessage+Opportunistic`/`+Direct` isolate their concerns.

## Cross-validation

New fixture + generator, isolated from the existing `lxmf_fixtures.json` (which stays stable — no churn):
`Tests/ReTiCATests/Vectors/{generate_lxmf_propagation_fixtures.py, lxmf_propagation_fixtures.json, LXMFPropagationFixtures.swift, LXMFPropagationCrossValidationTests.swift}`.

- **Generator** (drives genuine LXMF, conda `rns` env): builds a real `PROPAGATED` `LXMessage` (fixed `msg.timestamp`; container timestamp fixed via a monkeypatched `time.time` so `propagation_packed` is reproducible for our re-encode check), calls `pack()`, and emits: `destination_hash`, `transient_id`, `propagation_packed` (hex), the container `timestamp`, plus recipient private key + title/content for future slices.
- **Tests** (deterministic parts; the encrypted blob is opaque — hedged/ephemeral destination encryption, same rule as Ed25519, so never byte-compared):
  1. `parseContainer(reference propagation_packed)` returns `(ts, [lxmf_data])` with `ts == reference timestamp` and exactly one entry.
  2. `transientId(lxmf_data) == reference transient_id` — byte-parity (full_hash of given bytes is deterministic).
  3. `destinationHash(lxmf_data) == reference destination_hash` — byte-parity.
  4. `container(timestamp: ts, entries: [lxmf_data]) == reference propagation_packed` — byte-parity (re-encoding the same extracted values is byte-identical, proving our container packing round-trips genuine LXMF).
  5. `lxmfData(destinationHash: destHash, encryptedData: lxmf_data.dropFirst(16))` reconstructs the exact `lxmf_data`, and its `transientId` matches — proves the assemble helper.

The decrypt-and-validate round trip (recovering the full `LXMessage` from `lxmf_data`) is deferred to 4d-2/4d-4, where the encryption boundary is wired.

## Testing

The cross-val above is the whole test surface (this slice is pure wire). Mutation-verify each assertion. No TCA/reducer tests (no behavior).

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- Cross-val fixtures must drive genuine LXMF (`cross-validation-drive-real-rns`), never hand-rolled. New isolated fixture (no churn to `lxmf_fixtures.json`). Reference env: conda `rns` (`rns-reference-env`; rns 1.4.2 / lxmf 1.1.0).
- Destination encryption is hedged/ephemeral → the encrypted blob and any artifact containing it are never byte-compared; only the deterministic container structure + `transient_id` (full_hash of given bytes) are pinned (`ed25519-hedged-nondeterministic` generalizes to encryption).
- New production is pure core (`Sources/ReTiCA/LXMF/LXMFPropagation.swift`); tests in `ReTiCATests`. No ReTiCANode/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
