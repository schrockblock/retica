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

### Link handshake primitives (`Link`)

The `Link` namespace (pure core) implements the cryptographic handshake of a Reticulum Link — an encrypted end-to-end session with forward secrecy:

- `Link.linkID(requestPacket:)` — the deterministic link id from a link-request packet (truncated hash of its hashable part, with trailing signalling bytes stripped as in RNS `link_id_from_lr_packet`)
- `Link.sessionKey(ephemeralPrivateX25519:peerPublicX25519:linkID:)` — the shared session key both sides derive (X25519 ECDH → HKDF salted by the link id); returns an empty `Data()` sentinel on bad-key input rather than trapping
- `Link.buildProof` / `Link.validateProof` — the LRPROOF signed by the destination identity, proving ownership while the X25519 half stays ephemeral (forward secrecy)
- `Link.encrypt` / `Link.decrypt` — link data over the session key (wraps `Token`)

Only `MODE_AES256_CBC` is implemented, and MTU is not negotiated. Reticulum nonetheless bakes 3 fixed **signalling bytes** (MTU 500 / AES-256-CBC) into the link-request and proof wire layouts unconditionally, so these primitives include them (`buildProof` emits a 99-byte proof; `validateProof` also accepts the 96-byte signalling-free form, mirroring RNS `validate_proof`) to stay byte-exact with real 1.3.8 peers. The stateful Link session that drives these primitives (establishment state machine, RTT,
data flow, close, and the keepalive/timeout watchdog) is the `LinkSession` reducer described
below; requests and resources remain future slices. All four handshake constructions are
cross-validated against Python-RNS 1.3.8
(the fixture generator drives the reference `RNS.Link` signalling/handshake code paths, not a
reimplementation).

### Link establishment, data flow, and close (`LinkSession`)

`LinkSession` (in `ReTiCATransport`) drives the Link establishment handshake as a TCA
reducer — one instance per link, for either role:

- **Initiator:** `establish` builds and emits the LINKREQUEST, then validates the returned
  LRPROOF, derives the session key, emits the LRRTT packet, and reaches `active`.
- **Responder:** `acceptRequest` parses an inbound LINKREQUEST, derives the session key,
  emits the LRPROOF, then validates the LRRTT and reaches `active`.

Both sides progress `pending → handshake → active` and finish holding an equal derived
session key (`delegate(.established(linkID:sessionKey:))`). The reducer is interface-agnostic
(raw packet bytes in, `delegate(.transmit)` out). The LRRTT payload is `msgpack(rtt)`
encrypted under the session key; a minimal double-only `MsgPack` codec lives in the pure core.

An established link can then carry encrypted application data in both directions (`send(_:)` →
a DATA/NONE packet; inbound data surfaces via `delegate(.dataReceived(_:))`) and be explicitly
closed (`close` → a LINKCLOSE packet carrying `encrypt(link_id)`; either side reaching
`.closed` emits `delegate(.closed(_:))` with the RNS-faithful reason). Data payloads and the
close packet are encrypted under the session key; the close packet and its `encrypt(link_id)`
format are cross-validated against Python-RNS 1.3.8.

A `LinkSession` is self-maintaining once it has a clock (`@Dependency(\.continuousClock)`): a
hung handshake times out (`.pending`/`.handshake` past `establishmentTimeout` → `.closed` with
`CloseReason.timedOut`); the initiator sends an unencrypted `0xFF` keepalive every
`keepaliveInterval` and the responder replies `0xFE`, which keeps both sides' inactivity timers
fresh; and a link that hears nothing for `staleTime` (`2 × keepaliveInterval`) tears itself down
(LINKCLOSE + `.closed(.timedOut)`). Durations are local policy (simplified from RNS's per-hop
computation, which needs Transport); only the keepalive packet (`context .keepalive`,
unencrypted `0xFF`/`0xFE`) is wire-visible and matches RNS 1.3.8.

Still deferred to later slices: RTT-adaptive keepalive intervals, identify, requests, resources,
and wiring `LinkSession` into `Transport`/`Endpoint`.

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

## App composition: `ReTiCANode`

`ReTiCANode` assembles the stack into a working endpoint. The `Endpoint` reducer composes `TCPClientInterface` (interfaces) and `Transport` (routing), wiring them bidirectionally:

- **inbound:** interface deframes → `Transport.received` → learn / deliver → `Endpoint.delegate(.messageReceived / .pathLearned)`
- **outbound:** `Endpoint.send`/`.announce` → `Transport` → `.transmit` → `interface.send` → socket
- **lifecycle:** `.connect` → `interfaceConnected`

This is the first target that runs the whole stack. A `Store<Endpoint>` connected to a real Reticulum TCP node populates its path table from real network announces.

### Links in the endpoint

`Endpoint` composes a collection of `LinkSession`s (`IdentifiedArrayOf` via `.forEach`). `Transport`
recognizes link-addressed traffic and surfaces it (`delegate(.linkPacket/.linkRequest)`, bypassing
the announce/data dedup so keepalives aren't dropped); the endpoint routes each inbound link packet
to the matching link by `link_id`, creates a responder link on an inbound LINKREQUEST to a local
destination, and can `openLink(destinationHash:)` to a learned destination. Link lifecycle surfaces
as `Endpoint.delegate(.linkEstablished/.linkDataReceived/.linkClosed/.linkFailed)`, and
`sendOverLink`/`closeLink` drive an active link. Two endpoints can establish a link, exchange data,
and close — verified end-to-end. (Closed links remain inert in the collection; link GC and multiple
interfaces per endpoint are future work.)

### Link identify & request/response (`Endpoint`)

Over an established link, the initiator can prove its identity and either peer can make an
authenticated request:

- `Endpoint.identifyOverLink(linkID:identity:)` sends `publicKey ‖ sign(linkID ‖ publicKey)` (encrypted,
  context `LINKIDENTIFY`); the responder verifies the Ed25519 signature and surfaces
  `linkIdentified(linkID:remoteIdentity:)`.
- `Endpoint.sendRequestOverLink(linkID:path:data:)` sends `REQUEST` = `msgpack([time, path_hash, data])`
  (encrypted); the peer surfaces `requestReceived(linkID:requestID:pathHash:data:)` and replies with
  `sendResponseOverLink(linkID:requestID:data:)` → `RESPONSE` = `msgpack([request_id, data])`, matched
  back to `responseReceived(...)` by `request_id` (the request packet's truncated hash). A lost response
  surfaces `requestFailed(...)` after `rtt·6 + 11.25 s`.

Requests and responses with packed payloads ≤ 431 bytes are sent inline. Requests and responses larger
than 431 bytes are transferred as Resources: the sender advertises a resource whose advertisement carries
the `request_id` (`q`) and an is_request / is_response flag, and the peer routes the completed transfer
to `requestReceived` / `responseReceived` (matched by `request_id`) rather than the plain
`resourceReceived`. A large request's `request_id` is `truncatedHash` of the packed request. This makes
request/response work for any payload size, wire-compatible with Python-RNS 1.3.8. The application
generates responses and enforces its own allow-policy using the identified `remoteIdentity`;
RNS's in-library handler-registry/allow-policy remains a future slice.

### Resource primitives (`Resource`, `ResourceAdvertisement`)

The `Resource` namespace (pure core) implements the single-segment, uncompressed representation
primitives of a Reticulum Resource — the chunked large-object transfer that rides over a link:

- `Resource.buildStream` / `parts` — the data is prefixed with a 4-byte random hash, encrypted as
  one stream under the link's session key (`Token`), then split into SDU-sized ciphertext parts.
- `Resource.resourceHash` / `mapHash` / `hashmap` — the resource hash `full_hash(data ‖ r)` and the
  per-part map hashes `full_hash(chunk ‖ r)[:4]`.
- `Resource.assemble` / `verify` — reassemble (decrypt + strip prefix) and verify against the hash.
- `Resource.proofData` / `expectedProof` / `validateProof` — the receiver's `h ‖ full_hash(data ‖ h)`
  proof and the sender's validation.
- `ResourceAdvertisement.pack` / `unpack` — the `RESOURCE_ADV` MessagePack dictionary
  (`t,d,n,h,r,o,i,l,q,f,m`), built on a `MsgPack` value codec (uint/bin/string/nil/ordered-map).

All of it is cross-validated against Python-RNS 1.3.8 (msgpack bytes, hashes, `Token` decrypt, and a
genuine `ResourceAdvertisement.pack`). Multi-segment resources, compression, and the transfer state
machine (advertise → request → send → assemble → prove, with windowing/retransmission) are future
slices, as is wiring resources over a live `LinkSession`.

### Resource transfer (`ResourceTransfer`)

`ResourceTransfer` (in `ReTiCATransport`) drives a single-segment Reticulum resource transfer over
a link's session key, as a TCA reducer with a sender and a receiver role:

- **Sender:** `advertise` emits a `RESOURCE_ADV` (the encrypted `ResourceAdvertisement`); on a
  `RESOURCE_REQ` it sends the requested `RESOURCE` part-packets (raw ciphertext chunks); on the
  `RESOURCE_PRF` proof it validates and reaches `.complete` (`delegate(.concluded)`).
- **Receiver:** `accept` decrypts+unpacks the advertisement and requests all parts in one
  `RESOURCE_REQ` (`0x00 ‖ hash ‖ hashmap`); as `RESOURCE` parts arrive it places each by map-hash,
  and when all are in, reassembles + verifies the data, emits the `RESOURCE_PRF` proof, and surfaces
  the reconstructed data via `delegate(.received(_:))`.

Two `ResourceTransfer` reducers sharing a session key complete a transfer end-to-end. The
control-packet formats and their encryption status (`RESOURCE_ADV`/`RESOURCE_REQ` encrypted;
`RESOURCE` parts and `RESOURCE_PRF` raw) are wire-compatible with Python-RNS 1.3.8.

Transfers are **windowed and self-healing**: the receiver requests parts a window at a time (start 4,
growing +1 per completed round up to the slow cap of 10, shrinking on timeout), tracks a
consecutive-completed height, and retransmits outstanding parts on an rtt-seeded watchdog, failing
after 16 retries. The sender re-advertises when no request arrives (up to 4 times), waits for the
proof in an `awaitingProof` state, and gives up after its patience elapses. Either side can abort:
`RESOURCE_ICL` (sender) and `RESOURCE_RCL` (receiver) — each carrying the resource hash encrypted with
the link key — drive the peer to a failed state. Rate-adaptive window escalation (fast/very-slow),
and compression remain future slices.

### Large resources: hashmap-update (HMU)

A resource with more than `HASHMAP_MAX_LEN` = 74 parts (~34 KB at SDU 464) is transferred in a single
`ResourceTransfer` whose part-hashmap is delivered incrementally. The advertisement carries only the
first 74 map-hashes; as the receiver's window reaches an unknown slot it sends an exhausted-flagged
`RESOURCE_REQ` (`0xFF ‖ last-hash ‖ hash ‖ requested`), and the sender replies with the next 74-hash
`RESOURCE_HMU` chunk (`hash ‖ msgpack([chunkIndex, hashes])`, encrypted). This lifts the single-transfer
ceiling to ~1 MB, wire-compatible with Python-RNS 1.3.8. Resources larger than that (true multi-segment
sub-resources) remain a future slice.

### Sending resources over a link (`Endpoint`)

Once a link is established, a resource is sent end-to-end through the public API:

- `Endpoint.sendResourceOverLink(linkID:data:)` hands the bytes to that link's `LinkSession`, which
  spawns a sender `ResourceTransfer` (its random prefix/hash come from the `RandomBytes` dependency) and
  advertises it.
- The peer `LinkSession` recognises the inbound `RESOURCE_ADV`, spawns a receiver transfer (deduping
  re-advertisements by resource hash), and drives the windowed request/serve/assemble/prove exchange —
  all resource packets ride the link's existing transmit path.
- Completion surfaces as `Endpoint` delegates: `resourceReceived(linkID:data:)` on the receiver, and
  `resourceConcluded(linkID:resourceHash:)` / `resourceFailed(linkID:resourceHash:)` on either side.

`ResourceTransfer` instances live inside their `LinkSession` (link-scoped). Terminal transfers are
retained (no GC yet); MTU/SDU negotiation, multi-segment, and compression remain future slices.

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

Transport-node relaying, path requests, and Resource delivery are **not** part of this sub-project and will be addressed in subsequent deliverables of the decomposition. Other interfaces (TCP server, UDP, AutoInterface, RNode) are likewise future work. Multi-interface composition (connecting `Endpoint` to more than one `TCPClientInterface`) is likewise deferred.

The **Link session lifecycle** is now substantially complete: establishment (PENDING → HANDSHAKE → ACTIVE), encrypted application data, explicit link close, keepalive/inactivity watchdog, inline identify (IDENTIFY payload + Ed25519 verification), and request/response (both inline ≤ 431 bytes and large Resource-based, matched by `request_id`). All are wire-compatible with Python-RNS 1.3.8 and verified by cross-validation vectors.

## Requirements

- Swift 6 (swift-tools-version 6.3)
- iOS 16+ / macOS 13+ / tvOS 16+ / watchOS 9+ / Mac Catalyst 16+

The platform floor was raised from the CryptoKit minimums (iOS 13 / macOS 10.15) to iOS 16 / macOS 13 because The Composable Architecture requires it. The pure `ReTiCA` core has no third-party dependencies but shares the package's platform floor.

## Running Tests

```
swift test
```

All tests should pass, including the Python-RNS cross-validation vectors and the `TestStore`-based TCP client interface tests.
