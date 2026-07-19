# ReTiCA

A native iOS library for the [Reticulum Network Stack (RNS)](https://reticulum.network/), written in pure Swift.

## Architecture

The library follows a two-layer design:

1. **Pure Swift core** (sub-projects #1 and #2, complete) — zero third-party dependencies. Implements the cryptographic primitives, Identity, Packet framing, Destination addressing, and Announce validation required by RNS, wire-compatible with reference Reticulum 1.3.8.

2. **TCA orchestration layer** (planned) — will use [The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) to model Transport, Links, Announcements, and Resource delivery as reducers/effects on top of the crypto core.

## Sub-project #1: Crypto + Identity Core

This is the first deliverable of the decomposition. It covers:

| Module | What it implements |
|--------|--------------------|
| `Crypto.fullHash` / `truncatedHash` / `randomHash` | SHA-256 and the 16-byte truncated hash used for RNS addressing |
| `Crypto.hmacSHA256` | HMAC-SHA-256 (RFC 2104) |
| `Crypto.hkdf` | HKDF-SHA-256 (RFC 5869), reference-exact counter encoding |
| `PKCS7` | PKCS#7 padding at 16-byte block size, matching `RNS/Cryptography/PKCS7.py` |
| `AESCBC` | AES-128-CBC and AES-256-CBC via CommonCrypto |
| `Token` | Simplified Fernet (IV ‖ AES-CBC ciphertext ‖ HMAC-SHA-256), mode selected by key length: a 32-byte key → AES-128 (16-byte HMAC key + 16-byte AES key), a 64-byte key → AES-256 (32-byte HMAC key + 32-byte AES key); constant-time HMAC verification |
| `Identity` | X25519 + Ed25519 keypair; 64-byte serialization; HKDF-derived Token encryption with optional ratchet key; Ed25519 sign/validate; public-only variant |

### Cryptographic Backend

- **CryptoKit** — X25519 key agreement, Ed25519 signing/verification, SHA-256, HMAC
- **CommonCrypto** — AES-CBC block cipher
- No third-party dependencies.

### Wire Compatibility

Compatibility with reference Reticulum is verified through cross-validation tests (`Tests/ReTiCATests/Vectors/`) that decrypt ciphertexts and validate signatures produced by Python-RNS 1.3.8 fixtures, covering: identity hash, Token decryption, Identity-layer Token decryption, and Ed25519 signature verification.

## Sub-project #2: Packet + Destination

| Module | What it implements |
|--------|--------------------|
| `Packet` | Byte-exact Reticulum packet framing (flags, HEADER_1/HEADER_2, pack/unpack) and the transport-stable packet hash |
| `PacketContext` / `PacketType` / `HeaderType` / `TransportType` / `DestinationType` | Wire constants |
| `Destination` | Addressing (`expandName`/`nameHash`/`hash`) and encrypt/decrypt dispatch for SINGLE/GROUP/PLAIN |
| `Announce` | Signed announce payload build + signature/hash validation |

Framing is separated from crypto: `Packet` is pure framing over opaque payload bytes; `Destination` owns encryption; `Packet.data`/`Packet.announce` compose them. Wire compatibility is verified against Python-RNS 1.3.8 fixtures (packet bytes, packet hash, destination hash, announce validation).

## Sub-project #3: Interfaces (TCP client)

| Module | Target | What it implements |
|--------|--------|--------------------|
| `HDLC` / `HDLCDeframer` | `ReTiCA` (pure core) | Byte-exact HDLC framing/deframing for byte-stream interfaces |
| `TCPConnection` | `ReTiCAInterfaces` | Network.framework (`NWConnection`) socket behind a TCA `@Dependency` |
| `TCPClientInterface` | `ReTiCAInterfaces` | TCA reducer: connect, deframe inbound → `delegate(.packetReceived)`, frame+send outbound, reconnect on drop |

The Composable Architecture enters here, confined to the new **`ReTiCAInterfaces`** product; the `ReTiCA` core stays dependency-free. Socket I/O is behind a `@Dependency`, so the reducer is tested deterministically with `TestStore` and a mock connection — no real socket. HDLC framing is cross-validated against Python-RNS 1.3.8.

### Live integration (manual)

The live `TCPConnection` + `TCPClientInterface` can be pointed at a real Reticulum TCP node (e.g. a local `rnsd` TCP server) to receive real HDLC-framed packets. Received frames are delivered as raw `Data` via `delegate(.packetReceived(_:))` and can be parsed by the core `Packet`/`Announce` types. This is a manual check and is not part of `swift test`.

## Sub-project #4: Transport (endpoint core)

| Module | Target | What it implements |
|--------|--------|--------------------|
| `Transport` | `ReTiCATransport` | TCA reducer: announce ingest → path/known-destination table (recency + dedup), inbound DATA decrypt+deliver to local destinations, outbound routing to learned paths, self-announce |
| `InterfaceID` / `LearnedDestination` | `ReTiCATransport` | Interface handle and the learned path+identity entry |

`ReTiCATransport` is interface-agnostic (no Network.framework): interfaces are referenced by `InterfaceID`, inbound bytes arrive via `.received(InterfaceID, Data)`, and outbound bytes leave via `.delegate(.transmit(InterfaceID, Data))`, so an app layer wires Transport ↔ `ReTiCAInterfaces`. This is the endpoint (leaf) subset of RNS Transport; relaying, path requests, expiry/cull jobs, persistence, and links are future slices. Announce learning is cross-validated against a Python-RNS 1.3.8 announce packet.

### Products

- **`ReTiCA`** — pure Swift core (crypto, Identity, Packet, Destination, Announce, HDLC). Zero third-party dependencies.
- **`ReTiCAInterfaces`** — TCA-based interfaces (TCP client). Depends on `ReTiCA` + The Composable Architecture.
- **`ReTiCATransport`** — TCA endpoint-core Transport (no Network.framework). Depends on `ReTiCA` + The Composable Architecture.

## App composition: `ReTiCANode`

`ReTiCANode` assembles the stack into a working endpoint. The `Endpoint` reducer composes `TCPClientInterface` (interfaces) and `Transport` (routing), wiring them bidirectionally:

- **inbound:** interface deframes → `Transport.received` → learn / deliver → `Endpoint.delegate(.messageReceived / .pathLearned)`
- **outbound:** `Endpoint.send`/`.announce` → `Transport` → `.transmit` → `interface.send` → socket
- **lifecycle:** `.connect` → `interfaceConnected`

This is the first target that runs the whole stack. A `Store<Endpoint>` connected to a real Reticulum TCP node populates its path table from real network announces.

### Live endpoint test (opt-in)

`LiveEndpointTests` is skipped unless `RETICA_LIVE_HOST` is set. To run it against a real node (e.g. a local `rnsd` with a `TCPServerInterface`, or a testnet node):

```
RETICA_LIVE_HOST=127.0.0.1 RETICA_LIVE_PORT=4242 swift test --filter LiveEndpoint
```

### Products

- **`ReTiCA`** — pure Swift core (crypto, Identity, Packet, Destination, Announce, HDLC). Zero third-party dependencies.
- **`ReTiCAInterfaces`** — TCA TCP-client interface (Network.framework).
- **`ReTiCATransport`** — TCA endpoint-core Transport (interface-agnostic).
- **`ReTiCANode`** — composition of interface + transport into a working endpoint.

## Not Yet Implemented

Transport-node relaying, path requests, Link establishment, and Resource delivery are **not** part of this sub-project and will be addressed in subsequent deliverables of the decomposition. Other interfaces (TCP server, UDP, AutoInterface, RNode) are likewise future work. Multi-interface composition (connecting `Endpoint` to more than one `TCPClientInterface`) is likewise deferred.

## Requirements

- Swift 6 (swift-tools-version 6.3)
- iOS 16+ / macOS 13+ / tvOS 16+ / watchOS 9+ / Mac Catalyst 16+

The platform floor was raised from the CryptoKit minimums (iOS 13 / macOS 10.15) to iOS 16 / macOS 13 because The Composable Architecture requires it. The pure `ReTiCA` core has no third-party dependencies but shares the package's platform floor.

## Running Tests

```
swift test
```

All tests should pass, including the Python-RNS cross-validation vectors and the `TestStore`-based TCP client interface tests.
