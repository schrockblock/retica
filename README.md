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
data flow, close, keepalive/timeout watchdog, identify, requests, and resources) is the
`LinkSession` reducer described below. All four handshake constructions are
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

Still deferred to later slices: RTT-adaptive keepalive intervals.

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
| `KnownDestination` / `State.recall(destinationHash:)` / `recall(identityHash:)` / `recallAppData` | `ReTiCATransport` | Identity recall (RNS `Identity.recall` over `known_destinations`): every valid announce is remembered and outlives its path (`knownDestinationExpiry`, 8.75 days pathless); the host persists `knownDestinations` and restores it with `.rehydrateKnownDestinations`. For an unknown hash, `.requestPath` then recall on `pathLearned`. |

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
and close — verified end-to-end. Closed and establishment-failed links are removed from the
endpoint's link collection as soon as their terminal delegate fires (`linkClosed` / `linkFailed`),
and concluded or failed resource transfers are removed from their link. Removing a link also cancels
any of its in-flight timers (keepalive/inactivity) and outstanding request timers, and clears its
pending requests — so terminal state and timers do not accumulate. (Multiple interfaces per endpoint
are future work.)

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
request/response work for any payload size, wire-compatible with Python-RNS 1.3.8.

A node can register in-library request handlers instead of answering every request in the app. Call
`registerRequestHandler(path:policy:)` on the endpoint and supply a `requestResponder` dependency (one
closure that switches on `path` and returns the response bytes, or `nil` to decline). When a request
arrives for a registered path, the library checks the allow-policy against the link's identified
`remoteIdentity` — `.none` rejects all, `.all` accepts all, `.list([identityHash])` accepts only listed
peers (an un-identified peer is allowed only under `.all`) — and, if allowed, generates and sends the
response automatically (routing over a Resource when it exceeds 431 bytes). Denied requests are dropped;
requests for unregistered paths are still surfaced to the app's `requestReceived` delegate, so app-side
handling remains available.

### Resource primitives (`Resource`, `ResourceAdvertisement`)

The `Resource` namespace (pure core) implements the Reticulum Resource primitives — the chunked large-object transfer that rides over a link:

- `Resource.buildStream` / `parts` — the data is prefixed with a 4-byte random hash, encrypted as
  one stream under the link's session key (`Token`), then split into SDU-sized ciphertext parts.
- `Resource.resourceHash` / `mapHash` / `hashmap` — the resource hash `full_hash(data ‖ r)` and the
  per-part map hashes `full_hash(chunk ‖ r)[:4]`.
- `Resource.assemble` / `verify` — reassemble (decrypt + strip prefix) and verify against the hash.
- `Resource.proofData` / `expectedProof` / `validateProof` — the receiver's `h ‖ full_hash(data ‖ h)`
  proof and the sender's validation.
- `ResourceAdvertisement.pack` / `unpack` — the `RESOURCE_ADV` MessagePack dictionary
  (`t,d,n,h,r,o,i,l,q,f,m`), built on a `MsgPack` value codec (uint/bin/string/nil/ordered-map).
  Multi-segment fields (`i` index, `l` total, `o` original-hash, `f` flags) are fully encoded and
  decoded, cross-validated byte-for-byte against genuine Python-RNS 1.3.8 advertisements.

All of it is cross-validated against Python-RNS 1.3.8 (msgpack bytes, hashes, `Token` decrypt, and
genuine `ResourceAdvertisement.pack` output, including multi-segment segment advertisements).

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
the link key — drive the peer to a failed state. Rate-adaptive window escalation (fast/very-slow)
remains a future slice.

Resource payloads are transparently compressed with bzip2 before encryption when it shrinks them: the
sender sets a compression flag in the advertisement and ships the compressed stream, and the receiver
decompresses on assembly (the resource hash stays over the original data). Compression is byte-for-byte
identical to Python-RNS 1.3.8 (a vendored copy of the reference libbzip2). Incompressible payloads are sent
uncompressed automatically.

### Large resources: hashmap-update (HMU)

A resource with more than `HASHMAP_MAX_LEN` = 74 parts (~34 KB at SDU 464) is transferred in a single
`ResourceTransfer` whose part-hashmap is delivered incrementally. The advertisement carries only the
first 74 map-hashes; as the receiver's window reaches an unknown slot it sends an exhausted-flagged
`RESOURCE_REQ` (`0xFF ‖ last-hash ‖ hash ‖ requested`), and the sender replies with the next 74-hash
`RESOURCE_HMU` chunk (`hash ‖ msgpack([chunkIndex, hashes])`, encrypted). This lifts the single-transfer
ceiling to ~1 MB, wire-compatible with Python-RNS 1.3.8.

### Multi-segment resources (> 1 MB)

Payloads larger than `LinkSession.maxEfficientSize` (1,048,575 bytes) are automatically split into
sequential segments and transferred as a series of individual `ResourceTransfer`s. Each segment
advertisement carries the segment index (`i`), total count (`l`), original-hash (`o`, equal to the
first segment's resource hash), and a split flag (`f & 0x04`). The sender tracks outstanding segments
in a `SegmentedSend` and emits the next segment's advertisement only after the previous proof is
received. The receiver accumulates completed segment payloads in a `SegmentAccumulator` keyed by
`originalHash` and surfaces exactly one `resourceReceived(linkID:data:)` delegate action — containing
the full reassembled payload — once all segments are in. A two-Endpoint end-to-end test round-trips a
2-segment resource (1,048,975 bytes) with full windowed transfer, HMU rounds for segment 1, and
payload equality verified against the original. Multi-segment advertisements are cross-validated
byte-for-byte against genuine Python-RNS 1.3.8 output.

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

`ResourceTransfer` instances live inside their `LinkSession` (link-scoped). Both sender and receiver terminal transfers are removed from their `LinkSession` automatically: senders on proof-validated (`.concluded`) or failed (`.failed`), and receivers on assembly-complete (`.received`). This means terminal transfers — including every segment receiver of a multi-segment resource — do not accumulate on the link. MTU/SDU negotiation remains a future slice.

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

## Transport relay mode (announce propagation)

A node can be put in **relay mode** by calling `enableRelay(identity)` on the `Endpoint` (or `setTransportIdentity(identity)` on `Transport` directly). In relay mode, the node re-broadcasts every announce it hears for a non-local destination with the RNS header rewrite: HEADER_2, `transport_id` = the relay's 16-byte identity hash, and `hops+1`. The re-broadcast is sent to every interface *except* the one the announce arrived on, so the mesh learns multi-hop paths. The path table records the `transport_id` of each relayed announce as the next hop toward that destination.

Relay announce propagation is cross-validated against a genuine Python-RNS 1.3.8 announce packet: the test feeds the real fixture into the relay and asserts that the re-broadcast is HEADER_2, carries the relay's hash as `transport_id`, increments hops by 1, preserves the payload byte-for-byte, and that the original Python-RNS Ed25519 signature still validates in the re-broadcast payload (proving no corruption).

### Data-packet forwarding (one-way multi-hop)

A relay now **forwards data packets** addressed to it toward the destination. When a HEADER_2 data packet arrives naming the relay's identity hash as its `transport_id`, the relay looks up the destination in its path table and forwards:

- **Final hop** (`nextHop == destinationHash`): strips the transport header and emits a HEADER_1 packet (broadcast, `context_flag` cleared) directly to the destination.
- **Onward hop** (`nextHop != destinationHash`): keeps HEADER_2, swaps `transport_id` to the next relay, and increments `hops` by 1.

An originator that has learned a destination via a relay sends a HEADER_2 packet (setting `transport_id` to the first relay's hash), so a connectionless message travels multi-hop A→R→B in a single send, wire-compatible with Python-RNS 1.3.8.

The forwarding rewrite (`flags ‖ hops+1 ‖ nextHop ‖ destHash ‖ context ‖ payload`) is verified byte-for-byte against RNS `Transport.py:1605-1608`, and a three-node end-to-end test (A→R→B) confirms that the encrypted payload survives the full relay chain from originator to recipient, with B successfully decrypting A's message.

### Links over a relay (bidirectional, established through a relay node)

A full Reticulum **Link** now establishes and carries bidirectional encrypted traffic across a relay node (A—R—B). The mechanics:

1. **Initiator HEADER_2 LINKREQUEST.** When the originator A has learned destination B's hash via relay R (i.e. `learned[B].nextHop == R.hash`), `openLink(destinationHash: B)` emits a HEADER_2 LINKREQUEST with `transport_id = R.hash` — the same header rewrite used for data packets.

2. **Relay `link_table` + LINKREQUEST forward.** R receives the HEADER_2 LINKREQUEST (naming it as `transport_id`), records a reverse-routing entry in its `link_table` keyed by the link's `link_id`:
   `linkTable[link_id] = (rcvdIf: ifAR, nhIf: ifRB)`,
   then forwards the LINKREQUEST toward B as a HEADER_1 packet (transport header stripped, `hops+1`).

3. **Bidirectional link-packet forward.** Once the `link_table` entry exists, every link-addressed packet (LRPROOF, LRRTT, data, keepalive, close) is forwarded direction-aware by `link_id`: a packet arriving on `rcvdIf` ("ar", from the initiator) is forwarded out `nhIf` ("rb", toward the responder), and vice versa. This is the same path for all link phases — handshake and established traffic.

4. **Link establishment.** The LRPROOF from B travels R→A over the relay; A validates the proof, derives the session key, emits the LRRTT, and surfaces `linkEstablished`. The LRRTT travels A→R→B; B validates it and also surfaces `linkEstablished`. Both sides hold the same `link_id` and derived session key — wire-compatible with Python-RNS 1.3.8.

5. **Data flow.** `sendOverLink(linkID:data:)` on either side encrypts the payload under the shared session key and emits a `.link`-addressed DATA packet; R forwards it to the other side transparently. The receiver decrypts and surfaces `linkDataReceived`. Resources, requests, and responses also ride this path, enabling full multi-hop link semantics.

**link_id parity** (wire-compat guarantee): `Link.linkID(requestPacket:)` is header-independent — it produces the same 16-byte value from the HEADER_2 LINKREQUEST (with `transport_id`), the relay-forwarded HEADER_1 LINKREQUEST (with `transport_id` stripped), and the `link_table` key. This matches RNS `link_id_from_lr_packet` exactly, so all three nodes agree on the `link_id` without coordination.

A three-node end-to-end test (`threeNodeRelayLinkEstablishesAndCarriesData`) proves the complete flow: B registers and announces a destination; A learns it via R; A opens a link; the HEADER_2 LINKREQUEST is relayed by R to B; B's LRPROOF is relayed back to A; both reach `linkEstablished` with the same `link_id`; A→B and B→A data each arrive with the exact plaintext.

**Minimal-robustness deferrals** (future work): relay-side proof validation, per-hop proof timeout, `link_table` expiry, MTU negotiation, shared-interface hop-matching, and multi-relay chains remain unimplemented.

Re-broadcast robustness (retries, rate-limiting, expiry) remains a subsequent sub-slice (4b-3).

## Not Yet Implemented

Path requests, and other deferred relay robustness features are addressed in subsequent deliverables of the decomposition. Other interfaces (TCP server, UDP, AutoInterface, RNode) are likewise future work. Multi-interface composition (connecting `Endpoint` to more than one `TCPClientInterface`) is likewise deferred.

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
