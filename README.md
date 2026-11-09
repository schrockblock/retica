# ReTiCA

ReTiCA is a Swift implementation of [Reticulum](https://reticulum.network/) (RNS) and
[LXMF](https://github.com/markqvist/LXMF) for Apple platforms. It speaks the same wire format
as the reference Python implementation, so a ReTiCA app can exchange packets, links, resources
and LXMF messages with `rnsd`, `lxmd`, Sideband, NomadNet and other software built on the
reference.

It does not copy the Python code's structure. The cryptographic and wire-format core is plain
Swift with no third-party dependencies; everything stateful (transport, links, resource
transfers, the LXMF router, interfaces) is written as reducers for
[The Composable Architecture](https://github.com/pointfreeco/swift-composable-architecture) (TCA).

This README has two parts:

- [Part 1: using ReTiCA in an app](#part-1-using-retica-in-an-app), for iOS and macOS developers.
- [Part 2: compatibility with reference Reticulum](#part-2-compatibility-with-reference-reticulum),
  for people who want to know how close it is to RNS/LXMF and how to check that for themselves.

At the end: [repository layout](#repository-layout) and [running the tests](#running-the-tests).

---

# Part 1: using ReTiCA in an app

## Requirements

From `Package.swift`:

| | |
|---|---|
| Swift tools | 6.3 (`swift-tools-version: 6.3`), Swift 6 language mode |
| iOS | 17.0 or later |
| Mac Catalyst | 17.0 or later |
| macOS | 13.0 or later |

No other platforms are declared. Earlier versions of this README listed tvOS and watchOS; the
package no longer declares them.

## Getting the package

**There is no published package URL.** The git remote is `git@github.com:schrockblock/retica.git`,
but the package cannot be consumed from a URL as it stands, because `Package.swift` has two
local path dependencies:

```swift
.package(path: "../FCB"),            // CoreBluetooth wrapper, used by the BLE interface
.package(path: "../MeshtasticKit"),  // Meshtastic radio client, used by ReTiCAMeshtasticLive
```

Neither of those has a public remote. To build ReTiCA you need checkouts of `FCB` and
`MeshtasticKit` next to the ReTiCA directory, and your app depends on ReTiCA by path as well.
This is how the one known consumer (the ReTiCAMsgr app) does it:

```swift
// In your app's Package.swift, with ReTiCA, FCB and MeshtasticKit checked out side by side:
dependencies: [
    .package(path: "../pods/ReTiCA"),
],
targets: [
    .target(name: "MyApp", dependencies: [
        .product(name: "ReTiCANode", package: "ReTiCA"),
        .product(name: "ReTiCAKeychain", package: "ReTiCA"),
    ]),
]
```

SwiftPM fetches the remaining dependencies: swift-composable-architecture (from 1.15.0),
SwiftEdDSA 4.1.0 (exact; used only for IFAC, see Part 2) and IOS-CoreBluetooth-Mock (tests only).
libbzip2 is vendored as the `Cbzip2` target.

## Products

| Product | Depends on | What it is for |
|---|---|---|
| `ReTiCA` | nothing | The wire-format core: `Identity`, `Token`, `Destination`, `Packet`, `Announce`, `Link` handshake primitives, `Resource` primitives, HDLC framing, `MsgPack`, and the LXMF types (`LXMessage`, `LXStamper`, `LXMFPropagation`, `LXMFAnnounceData`, `PNAnnounce`). Pure functions, no TCA. Use it alone if you only need to build or parse packets and messages. |
| `ReTiCATransport` | `ReTiCA`, TCA, SwiftEdDSA | The interface-agnostic stateful layer: `Transport` (path table, announces, path requests, relaying, IFAC), `LinkSession` (one link), `ResourceTransfer` (one resource), `InterfaceProfile`, `InterfaceID`, `LearnedDestination`, `KnownDestination`. |
| `ReTiCAInterfaces` | `ReTiCA`, TCA, FCB | Interface reducers: `TCPClientInterface`, `TCPServerInterface` (Network.framework), `BLEInterface` (ble-reticulum protocol), `MeshtasticInterface`. |
| `ReTiCANode` | the three above | The compositions you run: `TransportEndpoint` (one shared router and link plane over any mix of TCP client, TCP server, BLE and Meshtastic slots), `LXMFNode` (LXMF client), `LXMFServiceNode` (client plus optional propagation node), `PNNode` (standalone propagation node). **Most apps depend on this.** |
| `ReTiCAKeychain` | `ReTiCA` | `IdentityKeychain`: one Reticulum identity per device in a Keychain access group, with rules that refuse to silently replace an existing identity. `IdentityBackup`: a base32 codec for backing a key up. Optional. |
| `ReTiCAMeshtasticLive` | `ReTiCAInterfaces`, MeshtasticKit, FCB | The live `MeshtasticDriver` (`MeshtasticDriver.live(session:)`, `MeshtasticLive.makeSession()`, `MeshtasticLive.scanRadios()`). Only needed if you use a Meshtastic radio as an interface. |

`ReTiCANode` does not re-export the lower targets, so import `ReTiCA` and `ReTiCATransport` as
well when you name their types (`Identity`, `InterfaceID`, ...).

## How the library is shaped

Three things to know before writing code:

1. **Everything stateful is a TCA reducer.** You run ReTiCA by holding `LXMFNode.State` (or
   `TransportEndpoint.State`) in a `Store`, usually scoped into your own app reducer, and sending
   it actions. Results come back as `delegate` actions that your parent reducer matches on.
   There is no callback or delegate-protocol API.
2. **The library holds state; the host persists it.** ReTiCA writes nothing to disk. Paths,
   known identities, dedup sets and learned stamp costs live in memory, and the host is expected
   to save them and hand them back at launch through `rehydrate…` actions (see
   [What the host must persist](#what-the-host-must-persist)). Received messages are handed to
   you once, as `.delegate(.messageReceived)`; storing them is up to you.
3. **Addresses are 16-byte destination hashes.** An LXMF address (what Sideband shows as the
   LXMF address) is the hash of an identity's `lxmf.delivery` destination:
   `LXMessage.deliveryHash(identityHash: identity.hash)`. It is not the identity hash.

## Minimal example: connect, announce, send, receive

This connects to a Reticulum node over TCP (for example a local `rnsd` with a
`TCPServerInterface` on port 4242), registers and announces an LXMF delivery destination, sends
a message and collects incoming ones. It was checked by compiling it in a scratch package that
depends on ReTiCA by path, so it uses only the public API.

```swift
import ComposableArchitecture
import Foundation
import ReTiCA
import ReTiCANode
import ReTiCATransport

@Reducer
struct Messenger {
    @ObservableState
    struct State {
        var node: LXMFNode.State
        var inbox: [String] = []
        var outbox: [Data: String] = [:]   // message hash -> status
    }

    enum Action {
        case node(LXMFNode.Action)
        case connect
        case disconnect
        case send(to: Data, text: String)
    }

    var body: some ReducerOf<Self> {
        Scope(state: \.node, action: \.node) { LXMFNode() }
        Reduce { state, action in
            switch action {
            case .connect:
                return .send(.node(.endpoint(.start)))      // dials every configured interface

            case .disconnect:
                return .send(.node(.endpoint(.stop)))

            case .node(.endpoint(.transport(.interfaceConnected))):
                // First interface up: register our lxmf.delivery destination, which also
                // announces it. Set the name first so the announce carries it.
                guard state.node.deliveryDestinationHash == nil else { return .none }
                return .concatenate(
                    .send(.node(.setDisplayName("Alice", stampCost: nil))),
                    .send(.node(.registerDelivery))
                )

            case let .send(to, text):
                // `to` is the recipient's 16-byte LXMF address (their lxmf.delivery hash).
                return .send(.node(.send(destinationHash: to, title: Data(),
                                         content: Data(text.utf8), method: .opportunistic)))

            case let .node(.delegate(.messageReceived(message, signatureValidated, method))):
                let text = String(decoding: message.content, as: UTF8.self)
                state.inbox.append("\(signatureValidated ? "" : "[unverified] ")\(text) via \(method)")
                return .none

            case let .node(.delegate(.deliveryConfirmed(hash))):
                state.outbox[hash] = "delivered"
                return .none

            case let .node(.delegate(.deliveryFailed(hash))):
                state.outbox[hash] = "failed"
                return .none

            case .node:
                return .none
            }
        }
    }
}

@MainActor
func makeMessenger(identity: Identity) -> StoreOf<Messenger> {
    Store(initialState: Messenger.State(
        node: LXMFNode.State(
            identity: identity,
            endpoint: TCPEndpoint.State(host: "127.0.0.1", port: 4242)
        )
    )) {
        Messenger()
    }
}
```

Then `store.send(.connect)`, and later `store.send(.send(to: recipient, text: "hello"))`.

What the example relies on:

- **Identity.** `Identity()` makes a new X25519 + Ed25519 keypair. `identity.privateKey` is the
  64-byte key to store; `Identity(privateKey:)` restores it. Lose it and your address changes.
  For a Keychain-backed identity shared across your apps, see [Identity storage](#identity-storage).
- **Your address** is `state.node.deliveryDestinationHash` after `.registerDelivery`, or
  `LXMessage.deliveryHash(identityHash: identity.hash)` at any time.
- **Registration order.** `.setDisplayName` only changes state; `.registerDelivery` registers the
  destination and announces it with the current name and stamp cost. The `stampCost` you pass
  to `.setDisplayName` is stored only in 1...99 (reference LXMF 1.3.0 rejects 100 and above, because
  RNS 1.6.0 caps stamp cost at 100 and its senders cannot stamp above that). A value below 1 clears
  the cost; a value of 100 or more is ignored and the previous cost stays. To re-announce later, send
  `.announceDelivery` (every interface) or `.announceDeliveryOnInterface(_:)` (one). Do not bind
  a text field straight to an announce: nothing throttles locally originated announces.
- **Sending.** `.send(destinationHash:title:content:method:)` builds, signs and sends a message.
  `.opportunistic` goes as a single packet when it fits and is promoted to a link (`.direct`)
  when it does not. If no path is known, the router requests one. To know the message hash
  before sending, or to add `fields`, build the message with
  `LXMessage.create(source:destinationHash:timestamp:title:content:fields:)` and send
  `.sendMessage(message:fallbackToPropagation:)`, which is what ReTiCAMsgr does.
- **Outcomes.** Every outbound message ends with at least one of `deliveryConfirmed`,
  `propagationAccepted`, `deliveryFailed`, `deliveryRejected`, `deliveryCancelled`. It can get
  two successes (a direct and a propagated copy both landing), so handle them idempotently.
  Progress arrives as `deliveryProgress` / `propagationProgress` on the reference 0...1 scale.
- **`signatureValidated`** is false when the sender's identity is not known yet (no announce
  heard), so the signature could not be checked. Messages with a bad signature from a known
  sender, or not addressed to you, are dropped and never reach the delegate.

### Lower-level use

`TransportEndpoint` on its own (without `LXMFNode`) is plain Reticulum: `.registerLocalDestination`,
`.announce`, `.send(destinationHash:plaintext:)`, `.openLink`, `.sendOverLink`,
`.sendResourceOverLink`, `.identifyOverLink`, `.sendRequestOverLink`, `.registerRequestHandler`,
and delegates such as `messageReceived`, `pathLearned`, `linkEstablished`, `linkDataReceived`,
`resourceReceived`, `requestReceived` and `responseReceived`. The pure `ReTiCA` target can be
used without TCA to build and parse packets, announces and LXMF messages.

## Interfaces

`TransportEndpoint.State` holds one shared router and any combination of these driver slots;
a packet can arrive on one and leave on another:

| Slot | State | Notes |
|---|---|---|
| TCP client | `tcpClients: IdentifiedArrayOf<TCPEndpoint.State>` | One socket per node dialled. Give each a distinct `interfaceID` (ReTiCAMsgr uses `"tcp:<host>:<port>"`). Reconnects on drop by default. Remove one with `.removeTCPClient(_:)`. |
| TCP server | `tcpServer: TCPServerEndpoint.State?` | Listens on a port so peers can dial you. No connection cap. Not discoverable: peers must be told your address and port. |
| BLE | `ble: BLEEndpoint.State?` | ble-reticulum protocol v2.2 over GATT, with an L2CAP path (v3) when the peer publishes a PSM. `BLEEndpoint.State(localIdentity: identity.hash)`. |
| Meshtastic | `meshtastic: MeshtasticEndpoint.State?` | Reticulum over a Meshtastic radio, compatible with landandair's RNS_Over_Meshtastic interface. Needs `ReTiCAMeshtasticLive` and `$0.meshtasticDriver = .live(session:)`; without it the slot reports the adapter as unavailable. |

```swift
var protected = InterfaceProfile.tcp
protected.ifac = IFAC(networkName: "my-network", passphrase: "secret", size: 16)

let endpoint = TransportEndpoint.State(
    tcpClients: [
        TCPEndpoint.State(host: "10.0.0.2", port: 4242,
                          interfaceID: InterfaceID("tcp:10.0.0.2:4242")),
        TCPEndpoint.State(host: "rns.example.org", port: 4242,
                          interfaceID: InterfaceID("tcp:rns.example.org:4242"),
                          profile: protected),
    ],
    tcpServer: TCPServerEndpoint.State(port: 4242),        // listen for peers on the LAN
    ble: BLEEndpoint.State(localIdentity: identity.hash)    // ble-reticulum peers nearby
)
let node = LXMFNode.State(identity: identity, endpoint: endpoint)
```

`InterfaceProfile` carries the interface's bitrate, mode (`.full`, `.accessPoint`, `.roaming`,
...), hardware MTU, announce bandwidth cap and optional IFAC. The presets `.tcp` and `.ble` use
the reference interfaces' declared values.

There is no AutoInterface, UDP, RNode/KISS, serial or I2P interface, and no shared-instance
client: to use a local `rnsd`, dial its `TCPServerInterface`.

## What the host must persist

ReTiCA starts empty on every launch. On iOS the process is killed routinely, so without
rehydration every cold start forgets all paths (nothing routes until announces are heard again),
re-downloads messages a propagation node still holds, and sends unstamped to peers that require
stamps. Save these and replay them at launch:

| Save | Read it from | Restore with |
|---|---|---|
| Your identity's private key | `identity.privateKey` | `Identity(privateKey:)` |
| Path table | `state.endpoint.learned` (`[Data: LearnedDestination]`) | `.endpoint(.transport(.rehydrateLearnedDestinations(_:)))`. `LearnedDestination.ratchet` is deprecated and ignored: a peer's ratchet is saved with its known destination (next row). |
| Known identities (recall), the link costs they announced, and their ratchets | `state.endpoint.knownDestinations`, including `ratchet` and `ratchetReceived` | `.endpoint(.transport(.rehydrateKnownDestinations(_:)))`. Without it the first link to a peer enforcing link-request stamps fails until it announces again. Without the two ratchet fields, messages to a peer go to its identity key until it announces again, and a peer that enforces ratchets drops them. A ratchet older than 30 days (`Transport.ratchetExpiry`) is dropped on restore. |
| Hashes of messages already received | `message.hash` from each `.delegate(.messageReceived)` | `.router(.rehydrateDedup(seenHashes:downloadedTransientIds:))`, **oldest first** |
| Transient ids downloaded from a propagation node | `.router(.messagesDownloaded(transientIds:))` actions, or `state.router.downloadedTransientIds` | the same action |
| Peers' display names and stamp costs | `state.learnedPeers` | `.rehydrateLearnedPeers(_:)` |
| Blocked senders | `state.ignoredDestinations` | `.rehydrateIgnoredDestinations(_:)` |
| Stamp tickets peers gave you (one per peer) | `.delegate(.ticketReceived(destinationHash:ticket:))`, or `state.outboundTickets` | `.rehydrateTickets(outbound:inbound:lastDeliveries:)`, `outbound:`. Without them every send to a stamp-enforcing peer does proof-of-work again until it sends you a new ticket. |
| Stamp tickets you issued (only with `issueTickets` on, or if you add ticket fields yourself) | `.delegate(.ticketIssued(destinationHash:ticket:))`, or `state.inboundTickets` | the same action, `inbound:`. Without them, once you set a delivery stamp cost, a peer's ticket-stamped messages fail validation (and are dropped if you enforce stamps). `.ticketIssued` can repeat a ticket you already saved (a resend before `.rehydrateTickets` lands), so upsert by the ticket bytes. |
| When a ticket you issued was last delivered to each peer | `.delegate(.ticketDelivered(destinationHash:at:))`, or `state.lastTicketDeliveries` | the same action, `lastDeliveries:`. Without them a ticket goes out again within a day of the last delivered one. |
| Your destination's own ratchets (only if you enable them) | `.node(.endpoint(.delegate(.ratchetsChanged(destinationHash:ring:))))`; in an `LXMFServiceNode` host (ReTiCAMsgr), `.node(.client(.endpoint(.delegate(.ratchetsChanged(...)))))`. The whole ring, X25519 **private keys**, newest first: replace the saved ring each time, and keep it where you keep private keys (the Keychain on iOS) | `.node(.endpoint(.enableRatchets(destinationHash:ring:)))`; in an `LXMFServiceNode` host, `.node(.client(.endpoint(.enableRatchets(...))))`. Pass the saved ring, or `[]` the first time, keyed by `LXMessage.deliveryHash(identityHash:)`, **before `.registerDelivery`** (it announces). See [Own ratchets](#own-ratchets). |
| Your destinations' network stamps (only with `stampDestinations` on) | `.node(.endpoint(.delegate(.destinationStampGenerated(destinationHash:stamp:value:))))`; in an `LXMFServiceNode` host (ReTiCAMsgr), `.node(.client(.endpoint(.delegate(.destinationStampGenerated(...)))))` | `.node(.endpoint(.rehydrateDestinationStamp(destinationHash:stamp:)))`; in an `LXMFServiceNode` host, `.node(.client(.endpoint(.rehydrateDestinationStamp(...))))` |
| A propagation node's stored messages (only if you run one) | the stored entries | `.pn(.ingestContainer(LXMFPropagation.container(timestamp:entries:)))` on `LXMFServiceNode` |

Ordering matters for `seenHashes`: it is a ring of 10,000, so supplying newest-first keeps the
wrong half. The rehydrate actions drop expired, malformed or future-dated rows and never
overwrite an entry the network has already refreshed, so they are safe to send after
`.endpoint(.start)` (ReTiCAMsgr runs its database reads alongside starting the interfaces).
A ticket restored after `.endpoint(.start)` still applies to a send that is waiting for the peer's
stamp cost: that send is handed over with the ticket stamp as soon as the ticket lands. A send
that already started its proof-of-work search keeps searching, and finishes with a valid stamp.
One exception: `.rehydrateTickets` does **not** drop a ticket whose expiry is far in the future.
A peer chooses the expiry of a ticket it gives you, and reference accepts any value. A ticket you
issued only expires later than 21 days from now if your clock went backwards, and dropping it
would make that peer's ticket stamps fail while the peer still holds the ticket. It does drop
future delivery times, which would stop issuing to that peer until the clock caught up. The
rehydrate actions cannot tell you to delete expired rows from disk; prune those yourself with
`Transport.pathExpiry` (7 days), `Transport.knownDestinationExpiry` (8.75 days),
`LXMFNode.stampCostExpiry` (45 days), a ticket's `expires` for tickets peers gave you,
`expires` plus `LXMessage.ticketGrace` (5 days) for tickets you issued, and
`LXMessage.ticketInterval` (1 day) for ticket delivery times (an older one has no effect).
`LearnedDestination` and `KnownDestination` are not
`Codable`; store their public fields (the identity as `identity.publicKey`) and rebuild them with
their public initialisers. A destination stamp is mined once per destination: about 45 s at the
default value on a Mac (see [Network stamps](#network-stamps-rns-16)); on a phone it has not been
measured. Without it every cold start mines again before the first announce goes out.
A rehydrated stamp is checked against `destinationValue` and mined again if it falls short.

### Own ratchets

Reference LXMF enables ratchets on every delivery destination. ReTiCA leaves them **off** until the
host sends `.endpoint(.enableRatchets(destinationHash:ring:))` with the ring it saved. An LXMF host
sends it before `.registerDelivery`, because registering announces, and the destination's first
announce should already carry a ratchet.
The ring is X25519 private keys that only the host can store safely. If it is lost on relaunch,
every message a peer encrypted to an old ratchet can no longer be decrypted, and that includes
messages a propagation node holds for days. A library that enabled ratchets by default would
lose them that way for every host that does not persist the ring.

Once enabled, ReTiCA behaves as reference (RNS 1.6.0 `Destination.py`):
- Each announce and local path response for the destination rotates the ring if more than 30
  minutes (`Transport.ratchetInterval`) have passed since the last rotation. The first one after
  `.enableRatchets` always rotates.
- Each rotation reports the whole ring, at most 512 keys (`Transport.ratchetCount`), with
  `.ratchetsChanged`.
- Each announce and path response carries the newest ratchet's public key (32 bytes), with the
  context flag set.
- An inbound packet to the destination is tried with every retained ratchet first, then with the
  identity key. So is a propagated LXMF message downloaded for it.
- `.endpoint(.setEnforceRatchets(destinationHash:_:))` drops anything only the identity key opens.
  It is ignored until ratchets are enabled, as in reference.
- Cost: with a full ring, a packet that no ratchet opens costs up to 513 key agreements. That
  covers junk and every packet a peer encrypted to the identity key. It was measured at about
  15-20 ms on a Mac, and it runs on the reducer's thread (the main actor in a TCA host). Reference
  costs the same or more. The ring fills in no less than 10.7 days. A downloaded propagated
  message costs one decrypt, and one addressed to another destination costs none.
- The announce grows by 32 bytes, so `LXMFNode` cuts the display name to
  `LXMFAnnounceData.maxAppDataBytesWithRatchet` (283 bytes of app data, 32 fewer than without a
  ratchet).
- Enabling forgets captured app data that no longer fits, so later announces without app data
  and path responses still go out. They go out with **no** app data, though, which erases the
  requester's copy of your display name until your next announce with app data. `LXMFNode` sends
  one every time it announces.

A restored entry that is not 32 bytes is dropped. That cleaning is reported only with the next
rotation, which the next announce always performs. Received messages do not report which ratchet
decrypted them.

## Stamp tickets (LXMF 1.3)

A ticket a peer gives you in a message whose signature validated (so the sender's identity must
already be known) is kept and used: sends to that peer are stamped with it instead
of proof-of-work until it expires. Issuing tickets yourself is **off by default**, as in reference,
where the client opts in per message (`include_ticket`). Turn it on with `.setIssueTickets(true)`.
Then every message the node builds (`.send`, `.sendViaPropagation`) carries a ticket for its
recipient, following reference `generate_ticket`: none if a ticket was delivered to that peer less
than a day ago; otherwise the ticket already issued to that peer if it has more than 14 days left;
otherwise a new one valid for 21 days.

A message you build yourself and send with `.sendMessage` is already hashed and signed, so the node
cannot add the field. Ask for it before creating the message and include it in `fields`:

```swift
let now = Date()
let field = state.ticketFieldToIssue(destinationHash: peer, now: now)   // nil when off or not due
let message = LXMessage.create(source: identity, destinationHash: peer, timestamp: now.timeIntervalSince1970,
                               title: title, content: content, fields: fields + (field.map { [$0] } ?? []))
store.send(.sendMessage(message: message, fallbackToPropagation: true))
```

The node records the ticket (and reports `.ticketIssued`) when that message reaches `.sendMessage`.
A delivery confirmation of a message carrying one of your tickets is reported as
`.ticketDelivered`. Persist all three kinds of ticket state (see the table above).

## Network stamps (RNS 1.6)

RNS 1.6.0 adds proof of work to announces, path requests and link requests. ReTiCA has the same
three switches as reference's `[stamps]` section, all off by default, as in 1.6.0. They live on
`Transport.State`; a host sets them before starting, through `TransportEndpoint.State.transport`:

```swift
var node = LXMFNode.State(identity: identity, endpoint: TCPEndpoint.State(host: host, port: port))
node.endpoint.transport.stampDestinations = true   // stamp our announces
node.endpoint.transport.stampPathRequests = true   // stamp our path requests
node.endpoint.transport.enforceStamps = true       // refuse unstamped traffic we receive
```

| Setting | Default | Reference | What it does |
|---|---|---|---|
| `stampDestinations` | off | `stamp_destinations` | Every announce and path response carries a stamp of `destinationValue` (default 25) and the destination's link cost. Mined once per destination; persist it (above). |
| `stampPathRequests` | off | `stamp_path_requests` | Each path request is sent only after a stamp of `pathRequestValue` (default 15.8) is found, up to 15 s. A relay marks unstamped requests it forwards. |
| `enforceStamps` | off | `enforce_stamps` | Announces below `destinationCost` (default 23.5) are not learned or relayed; path requests below `pathRequestCost` (default 15.8) are not answered or forwarded; link requests to our destinations below their link cost (LXMF 3.25, otherwise 12.5) are not answered. Our own outbound traffic is unaffected. |

Link requests are stamped whatever these say, as in 1.6.0: when a destination announced a link
cost, the link waits for a key meeting it (up to 15 s, cost 20 at most). With `enforceStamps` on
and `stampDestinations` off, peers never learn our link cost, so a 1.6.0 peer opens its links to us
unstamped and every one is refused; reference behaves the same way.

The two receive costs can be set per interface, as reference's per-interface `destination_cost` and
`pr_cost` options can. Set them on the `InterfaceProfile` a driver registers; `nil` (the default)
uses the Transport-wide `destinationCost` or `pathRequestCost`. An announce or path request is
checked against the cost of the interface it arrived on. Values are clamped to 0...100 as
reference's config parser clamps them. A cost of 0 accepts any stamp, but with `enforceStamps` on
an announce or path request carrying no stamp is still refused, as in reference.

```swift
var profile = InterfaceProfile.tcp
profile.destinationCost = 8         // announces arriving on this interface need a stamp of 8
profile.pathRequestCost = nil       // path requests use transport.pathRequestCost
let client = TCPEndpoint.State(host: host, port: port, profile: profile)
```

A TCP server's accepted connections and a BLE driver's peers all take the driver's profile, and
the Meshtastic, RNode and MeshCore radio drivers keep the costs of the profile they were given
(and its other fields, except the name, bitrate and hardware MTU, which the radio decides).

What it costs. Hash rates measured on a Mac (release build, about +/-15%) are in
`NetworkStamp.swift`: about 790,000 stamp rounds a second and 14,000 link keys a second. From
those, a path-request stamp (15.8) takes well under a second, a destination stamp at 23.5 about
15 s and at the default 25 roughly three times that, and a link key at 12.5 about 0.4 s.
**Rates on a phone have not been measured.** Checking a path-request or link-request stamp is one
SHA-256, and an announce's two (its validity and its value). With `enforceStamps` on, all three are
checked before any public-key work (the signature, the DH, the ratchet's trial agreement), so junk
costs those hashes and nothing more.

## iOS lifecycle

- **Background.** When iOS suspends the app its sockets go quiet, but the other end may keep
  writing into them. ReTiCAMsgr closes its sockets when it goes to the background (after
  finishing in-flight sends inside a background task) and redials on foreground. Before closing,
  send `.holdOutbound(true)`: held messages keep their retry state instead of failing, or falling
  back to a propagation node, while the app is suspended. Send `.holdOutbound(false)` on
  foreground and when an interface reconnects.

  ```swift
  // going to the background: hold first, then close
  store.send(.node(.holdOutbound(true)))
  store.send(.node(.endpoint(.stop)))

  // back in the foreground
  store.send(.node(.endpoint(.start)))
  store.send(.node(.holdOutbound(false)))
  ```

- **Stamp work.** Delivery and propagation stamps are proof-of-work searches that can take
  minutes. `.cancelDeliveryStamps` and `.cancelPropagationStamps` stop them; a message whose
  search is cancelled is reported `deliveryFailed`, not sent unstamped, unless its propagated copy
  is still out (that copy's outcome is reported instead) or a copy already succeeded. A
  `.sendViaPropagation` still stamping when `.cancelPropagationStamps` arrives, or when
  `.setPropagationNode` names a different node, is likewise reported `deliveryFailed` and never
  handed over.
  `.cancelOutbound(messageHash:)` cancels one message wherever it is. Network stamp searches
  (destination, path-request and link-request stamps) are cancelled by `.endpoint(.stop)`; a link
  waiting for its key fails with `.pathStale`, and an announce waiting for its stamp is dropped.
  While a send is prepared before the router has it, the node reports
  `.delegate(.deliveryPreparing(messageHash:phase:))`: `.waitingForPeer` for a first send waiting
  for the peer's announce (its stamp cost), `.stamping` while a stamp search runs (also for
  `.sendViaPropagation`, and again for a copy taken back and re-stamped after a late announce), and
  `.handedOver` when the message reaches the router. A send that goes straight to the router reports
  nothing, and `.handedOver` is reported only for a message that reported an earlier phase. A
  message that ends or is cancelled while preparing gets its terminal outcome and no `.handedOver`.
  A host can show "Preparing…" between the first phase and `.handedOver`.
- **Receiving while suspended.** A suspended app receives nothing. The options are a propagation
  node (sync when the app comes back with `.syncFromPropagationNode`) and push wake-ups (below).
- **Main actor and dependencies.** Run the `Store` on the main actor, as TCA expects. Sockets,
  clocks and CoreBluetooth come from the library's `liveValue` dependencies. In a test context
  several of them are `unimplemented`, so override them in tests.

## Identity storage

`ReTiCAKeychain` keeps one identity per device in a Keychain access group so several of your
apps can share it:

```swift
import ReTiCAKeychain

let location = IdentityKeychain.Location(service: "reticulum.identity",
                                         accessGroup: "TEAMID.com.example.reticulum.identity")
switch IdentityKeychain.loadOrCreate(shared: location) {
case let .loaded(identity), let .created(identity), let .migrated(identity):
    use(identity)
case let .failed(failure):
    // e.g. the Keychain is locked before first unlock: try again later, never mint a replacement
    report(failure)
}
```

It refuses to overwrite an existing identity, fails closed on any Keychain error, never writes
iCloud-synchronisable items, and offers `load` (never mints) and `importIdentity` (add-only
restore) for apps that must not create a new identity. Read the doc comment on `IdentityKeychain`
before adopting it.

## Permissions and entitlements

The library declares nothing itself. The host app needs:

| For | Needed |
|---|---|
| BLE or Meshtastic interface | `NSBluetoothAlwaysUsageDescription`. To keep BLE running in the background, `UIBackgroundModes` `bluetooth-central` and `bluetooth-peripheral` (the BLE interface is both central and peripheral). |
| TCP to a private LAN address, or the TCP server | iOS shows the Local Network permission prompt; add `NSLocalNetworkUsageDescription` to explain it. |
| macOS, sandboxed | `com.apple.security.network.client`; `com.apple.security.network.server` for the TCP server; `com.apple.security.device.bluetooth` for BLE. |
| `ReTiCAKeychain` | `keychain-access-groups` containing the group you pass to `IdentityKeychain.Location`. |
| Push wake-ups (ReTiCAPush) | `aps-environment`, the `remote-notification` background mode, and an App Group shared with the Notification Service Extension. |

These are the keys ReTiCAMsgr uses, except `NSLocalNetworkUsageDescription`, which it does not
set; that row comes from how iOS behaves, not from this codebase.

## Propagation nodes

A propagation node stores messages for recipients that are offline (`lxmd -p` in the reference).

```swift
store.send(.node(.setPropagationNode(destinationHash: nodeHash)))   // the node's lxmf.propagation hash
store.send(.node(.sendMessage(message: message, fallbackToPropagation: true)))
store.send(.node(.syncFromPropagationNode))                          // download what is waiting for us
```

With `fallbackToPropagation`, ReTiCA tries direct delivery first and hands a copy to the node
after the third direct attempt or when direct delivery fails (see the divergences in Part 2).
`.sendViaPropagation(destinationHash:title:content:)` sends through the node only. The node's
stamp cost and size limit are read from its announce; a copy larger than its limit is reported
`propagationRefused` instead of being sent.

ReTiCA can also be a propagation node: `LXMFServiceNode` (an LXMF client that turns node mode
on with `.setNodeMode(true)`) or `PNNode` (a standalone node with peer sync). Neither writes its
store to disk.

## Push wake-ups

Push is a separate package, `ReTiCAPush` (products `ReTiCAPushCore`, `ReTiCAPush`,
`ReTiCAPushExtension`), which depends on ReTiCA by path. It registers the device with a
push-capable Reticulum hub over a Reticulum link; the hub sends an APNs push when traffic for the
device arrives while it is away, and a Notification Service Extension can decrypt and prove
single-packet messages. Only opportunistic (single-packet) messages arrive this way; link-based
senders (Sideband, NomadNet) produce a wake-up, and a propagation node has to carry their
content. See that package's README and its `docs/server-contract.md`.

---

# Part 2: compatibility with reference Reticulum

## Which reference versions

| Reference | Version | Where it shows |
|---|---|---|
| RNS (Python) | **1.4.2** | Current fixtures and source comments (IFAC, proofs, transport, the link probe harness). |
| RNS (Python) | 1.3.8 | The first fixtures (crypto, packets, links, resources); some source comments still cite it. |
| LXMF (Python) | **1.1.0** | Almost all LXMF fixtures and source comments. One comment cites 1.1.1 (the ignore list). |
| RNS 1.6.0 with LXMF 1.3.0 | The latest, partly covered | Network stamp fixtures (stamp arithmetic, stamped announces, destination stamps, path requests, link requests) and the live stamp tests only, in the conda env `rns-latest`. |
| ble-reticulum | a local checkout of torlando-tech/ble-reticulum, plus `ble_support.py` from a Reticulum fork | BLE fragmentation and greylist fixtures. The script calls the checkout pinned but does not record which commit. |
| RNS_Over_Meshtastic | landandair, commit `e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a` | Meshtastic fragment fixtures (an unmodified copy of the reference file is in the repo). |

Source comments cite reference files and line numbers (`Transport.py:1442`, `LXMRouter.py:1034`)
for those versions. Apart from that one row, the fixtures have not been regenerated against newer
releases, so most changes introduced after RNS 1.4.2 / LXMF 1.1.0 would not be caught.

## Reticulum (RNS) features

"Cross-validated" means a committed test feeds ReTiCA bytes produced by the genuine Python code,
or compares ReTiCA's output with them. [The evidence](#how-to-tell-the-evidence) lists the files.

| Feature | Status | Notes |
|---|---|---|
| Identity: X25519/Ed25519 keys, hashes, encrypt/decrypt, sign/validate | Implemented, cross-validated | CryptoKit for X25519, Ed25519, SHA-256 and HMAC; CommonCrypto for AES. CryptoKit's Ed25519 signatures are randomised (valid, but not byte-identical to the reference's), so tests validate signatures rather than compare them. |
| Token (AES-256-CBC + HMAC), HKDF, PKCS7 | Implemented, cross-validated | The AES-128 token mode is supported too. |
| Packet framing (HEADER_1/HEADER_2, flags, contexts), packet hash | Implemented, cross-validated | |
| Destinations: SINGLE, GROUP, PLAIN; name hashing | Implemented, cross-validated | Link destinations via `LinkSession`. |
| Announces: build, validate, app data | Implemented, cross-validated | |
| Network stamps (RNS 1.6): arithmetic, validation | Implemented, cross-validated against RNS 1.6.0 | Fixed-point costs, targets, values and stamped keys. |
| Network stamps on our announces (`stampDestinations`) | Implemented, cross-validated, tested live against RNS 1.6.0. **Off by default** | The extension layout is compared with reference announces; an enforcing reference peer accepts a stamped ReTiCA announce and drops an unstamped one. The stamp is persisted by the host. |
| Network stamps on our path requests (`stampPathRequests`) | Implemented, tested live against RNS 1.6.0. **Off by default** | Inbound parsing is checked against reference requests. An enforcing reference peer answers a stamped ReTiCA request and drops an unstamped one. |
| Network stamps on our link requests | Implemented, tested live against RNS 1.6.0. **On, as in 1.6.0** | Only to a destination that announced a link cost, and only up to cost 20 (reference has no ceiling). An enforcing reference peer accepts the stamped request and ignores an unstamped one. |
| Enforcing network stamps (`enforceStamps`) | Implemented, tested against reference fixtures; announces also tested live against RNS 1.6.0. **Off by default**, as in 1.6.0 | Refuses announces, path requests and link requests whose stamp falls short (see Part 1). Announce and path-request costs can be set per interface, as in reference. Inbound path- and link-request enforcement is tested only with fixtures, not against a live reference peer. |
| Announce propagation as a transport node | Implemented | Relay mode (`.enableRelay`), HEADER_2 rewrite; rebroadcast and retry constants cross-validated; per-interface announce bandwidth cap. |
| Ratchets | **Implemented** (own ratchets are a host opt-in) | A peer's announced ratchet is kept with its known destination (refreshed by every fresh announce, kept when an announce carries none, expired after 30 days, persisted by the host) and used for opportunistic packets and propagated LXMF payloads to it; the propagated payload is cross-validated byte for byte against LXMF 1.3.0. Live-tested against an LXMF 1.3.0 router with `enforce_ratchets=True` (`LiveRatchetInteropTests`, gated on `RETICA_LIVE_STAMP_PYTHON`): it receives our opportunistic and propagated messages decrypted with its ratchet, and we decrypt its reply encrypted to ours. Own ratchets are a host opt-in (see [Own ratchets](#own-ratchets)): when enabled, a destination rotates, announces and decrypts with its own ring, optionally enforced. A reference RNS 1.6.0 validates our ratcheted announce and encrypts to its ratchet, and we decrypt that (a test gated on `RETICA_REFERENCE_PYTHON`); reference-encrypted packets and propagated messages to our ratchets are cross-validated from committed fixtures. Without the opt-in there is no forward secrecy for traffic *to* a ReTiCA destination. |
| Path table, path requests and responses | Implemented, cross-validated (request and response layout) | Path expiry by interface mode. Persisted by the host. No rate limiting of inbound path requests. |
| Forwarding as a relay | Implemented | Multi-hop data forwarding, and a link table so links can be established through a relay. |
| Proofs | **Partial** | Single-packet proofs (implicit and explicit) are sent and validated; link packet proofs too. A ReTiCA relay keeps no reverse table, so it does not route proofs for third parties. |
| Tunnels | Missing | Routes to a ReTiCA node are not restored when a transport peer reconnects. |
| Links: establishment, RTT, keepalive, timeouts, close, identify | Implemented, cross-validated (handshake, proof, close) | Only `AES_256_CBC` mode. **Link MTU is fixed at 500** and not negotiated (the signalling bytes are sent with fixed values). |
| Requests and responses over links | Implemented, cross-validated (large requests) | Inline up to 431 bytes, as a Resource above that. Payloads over about 3 MB are not split into segments, so they cannot reach a reference peer. |
| Resources: windowed transfer, hashmap updates, multi-segment (over 1 MB), bzip2, cancel | Implemented, cross-validated (advertisements, hashmap updates, segments, compression) | **The window is capped at the slow limit (10)**; reference grows to 75 on fast links, so large transfers are slower. One Resource at a time per link; further ones queue. |
| Channel / Buffer | **Missing** | A peer that opens a `Channel` on a link gets no answer and eventually tears the link down. |
| IFAC (interface access codes) | Implemented, cross-validated | Network name and/or passphrase, configurable size. |
| Interface modes, bitrates, announce caps | Implemented | Through `InterfaceProfile`. |
| Interfaces: TCP client and server | Implemented | HDLC framing cross-validated. |
| Interface: BLE | Implemented | ble-reticulum protocol v2.2 (GATT) plus v3 (L2CAP). Fragmentation cross-validated against ble-reticulum. |
| Interface: Meshtastic | Implemented | Fragment codec cross-validated against landandair's RNS_Over_Meshtastic. |
| Interfaces: AutoInterface, UDP, RNode/KISS, serial, I2P, pipe, shared instance (LocalInterface) | **Missing** | |
| Persistence | The host's job | See Part 1. The packet-hash dedup ring and the announce cache are deliberately not persisted. |
| Admission control | **Partial** | The number of inbound links is capped; Resources per link are not, and there is no `accepts_links`-style per-destination policy. |

## LXMF features

| Feature | Status | Notes |
|---|---|---|
| Message format: pack, unpack, hash, signature | Implemented, cross-validated | A received message keeps its original bytes, so passing it on does not re-encode it. `fields` round-trip byte-for-byte; the library does not interpret them (attachments, images and so on are up to the app). |
| MessagePack | Implemented, cross-validated | Every type the reference emits except ext, which RNS/LXMF payloads do not use. |
| Opportunistic delivery | Implemented | With single-packet delivery proofs in both directions. |
| Direct delivery (over a link; Resource for large messages) | Implemented | Progress, cancel, no resend while a transfer runs. |
| Propagated delivery (client sends to a node) | Implemented, cross-validated (container, stamps) | |
| Sync from a propagation node (`/get`) | Implemented | Identifies on the link first, as the reference node requires. |
| Running a propagation node (serving clients) | Implemented | `LXMFServiceNode`, `PNNode`. In memory; the host persists. |
| Propagation node peering (node-to-node sync, peering keys) | **Partial** | Offer/wanted exchange and peering-key generation and validation exist, and the keys are cross-validated. Stamp validation is not throttled (reference refuses with `ERROR_THROTTLED`), and peering has not been tested against a reference `lxmd` in this repo. |
| Delivery announce app data (display name, stamp cost) | Implemented, cross-validated, including RNS 1.6.0 / LXMF 1.3.0 | A fractional cost is read as its ceiling. |
| Propagation node announces | Implemented, cross-validated, including RNS 1.6.0 / LXMF 1.3.0 | Fractional costs are read as their ceiling, and float limits are accepted. |
| Delivery stamps | Implemented, cross-validated, tested live against RNS 1.6.0 / LXMF 1.3.0 | Generated when a peer asks for a cost of 20 or less, on the delivery copy and on propagated copies; above 20 ReTiCA sends unstamped (reference has no ceiling). Inbound validation once you set a cost; enforcement off by default, as in reference. MeshChatX turns enforcement on with a default cost of 8. |
| Propagation stamps | Implemented, cross-validated | Cost ceiling 20 (reference has none). |
| Tickets | Implemented, cross-validated against LXMF 1.3.0 (ticket stamps, `FIELD_TICKET` read and written) | Received tickets are kept and used; inbound ticket stamps are validated. Issuing is **off by default** (`.setIssueTickets`). The host persists ticket state. Expired tickets are dropped when `.rehydrateTickets` runs at launch, not every ~8 minutes as in reference. Not tested against a live reference peer. |
| Paper messages (`lxm://`, QR) | **Missing** | |
| Ignore list | Implemented | `.ignoreDestination` / `.unignoreDestination`. |

### Deliberate divergences

These are choices, explained at the relevant place in the source:

- **Falling back to a propagation node earlier than reference.** Reference goes to the
  propagation node only after direct delivery has failed for good. ReTiCA starts the propagated
  copy after the third direct attempt and keeps retrying directly, so both copies can arrive.
- **Stamp cost ceilings** of 20 for delivery and propagation stamps. Reference relies on
  cancellation alone; a phone should not spend minutes of CPU because an unauthenticated
  announce asked it to.
- **A first message to a peer with no known path waits for its announce**, up to 21 seconds, so
  it can carry the stamp that peer requires. Reference reads the cost once at send time, so its
  first message goes out unstamped. If the announce comes later than that, the message has been
  handed on unstamped but has not gone out (there was no path), so ReTiCA takes it back, stamps it
  and sends it then.

  **What still loses a message:** one already transmitted before the cost was known. An
  enforcing peer proves it and drops it, and ReTiCA reports it delivered. That happens when we
  hold a path to the peer but no cost for it (a path table restored without its `learnedPeers`
  row), when the peer raised its cost after we sent, and for a propagated copy packed before the
  cost was known. Nothing on the wire can be recalled.
- **One Resource per link**, the rest queued.
- **An oversized propagated copy is refused up front** instead of being sent and rejected by the node.
- **Outbound retries can be held** while the app is suspended (no reference equivalent).
- **The number of inbound links is capped** (reference has no cap).
- **Deregistering a destination closes its open links** (reference leaves them up).

`docs/reference-parity-checklist.md` lists the open gaps in priority order, with the reference
line numbers behind each claim. Its header was last re-verified on 2026-08-14 and later fixes
are recorded inline with their commits, so check an item against the code before relying on it.

## How to tell: the evidence

### 1. Cross-validation fixtures

Python scripts that import the real `RNS` and `LXMF` packages produce JSON fixtures, which are
committed. The Swift tests load them and check that ReTiCA decrypts, validates, parses or
byte-for-byte reproduces what the reference produced. Running the tests does not need Python.

| Area | Generator (runs genuine reference code) | Fixture | Swift tests |
|---|---|---|---|
| Identity, Token, signatures, packets, destinations, announces, HDLC, link handshake, MsgPack, resources | `Tests/ReTiCATests/Vectors/generate_fixtures.py` | `fixtures.json` | `CrossValidationTests.swift`, `PacketDestinationCrossValidationTests.swift`, `HDLCCrossValidationTests.swift`, `LinkCrossValidationTests.swift`, `LinkRequestCrossValidationTests.swift`, `ResourceCrossValidationTests.swift`, `HmuCrossValidationTests.swift`, `LargeRequestCrossValidationTests.swift`, `ResourceTransferCrossValidationTests.swift` (all in `Tests/ReTiCATests/Vectors/`) |
| MsgPack types the reference emits, in signed payloads | `generate_msgpack_signed_fixtures.py` | `msgpack_signed_fixtures.json` | `MsgPackSignedCrossValidationTests.swift` |
| LXMF message format | `generate_lxmf_fixtures.py`, `generate_lxmf_rich_fixtures.py`, `generate_lxmf_signed_fixtures.py` | `lxmf_fixtures.json`, `lxmf_rich_fixtures.json`, `lxmf_signed_fixtures.json` | `LXMessageCrossValidationTests.swift`, `LXMFRichCrossValidationTests.swift`, `MsgPackSignedCrossValidationTests.swift` |
| Announce app data as RNS 1.6.0 / LXMF 1.3.0 send it, with network stamps | `generate_lxmf_stamped_announce_fixtures.py` | `lxmf_stamped_announce_fixtures.json` | `LXMFStampedAnnounceCrossValidationTests.swift` |
| RNS 1.6.0 network stamp arithmetic and stamped keys | `generate_network_stamp_fixtures.py` | `network_stamp_fixtures.json` | `NetworkStampCrossValidationTests.swift` |
| RNS 1.6.0 stamped announce packets | `generate_stamped_announce_packet_fixtures.py` | `stamped_announce_packet_fixtures.json` (copied to the transport and node tests) | `Tests/ReTiCATests/Destination/StampedAnnounceTests.swift`, `StampedAnnounceTransportTests.swift`, `StampEnforcementTests.swift` |
| RNS 1.6.0 destination stamps, path requests, link requests | `Tests/ReTiCATransportTests/Vectors/generate_destination_stamp_fixtures.py`, `generate_path_request_fixtures.py`, `generate_link_request_stamp_fixtures.py` | `destination_stamp_fixtures.json`, `path_request_fixtures.json`, `link_request_stamp_fixtures.json` | `DestinationStampTests.swift`, `PathRequestStampTests.swift`, `StampEnforcementTests.swift` |
| LXMF stamps and peering keys | `generate_lxmf_stamp_fixtures.py`, `generate_lxmf_peering_fixtures.py` | `lxmf_stamp_fixtures.json`, `lxmf_peering_fixtures.json` | `LXStamperCrossValidationTests.swift`, `LXStamperPeeringCrossValidationTests.swift`, `LXMFStampMessageCrossValidationTests.swift` |
| LXMF 1.3.0 stamp tickets: ticket stamps both ways, and the `FIELD_TICKET` an issuer writes | `generate_lxmf_ticket_fixtures.py`; `Tests/ReTiCANodeTests/Vectors/generate_lxmf_ticket_issue_fixtures.py` | `lxmf_ticket_fixtures.json`; values pasted into the test | `LXMFTicketCrossValidationTests.swift`; `Tests/ReTiCANodeTests/LXMFNodeTicketIssueTests.swift` |
| Propagation container | `generate_lxmf_propagation_fixtures.py` | `lxmf_propagation_fixtures.json` | `LXMFPropagationCrossValidationTests.swift` |
| Delivery announce app data, propagation node announces | `generate_lxmf_announce_fixtures.py`, `generate_lxmf_pn_announce_fixtures.py` | `lxmf_announce_fixtures.json`, `lxmf_pn_announce_fixtures.json` | `Tests/ReTiCATests/LXMFAnnounceDataCrossValidationTests.swift`, `PNAnnounceCrossValidationTests.swift` |
| Transport: announce ingest, rebroadcast, path requests, relaying, compression, multi-segment resources | `Tests/ReTiCATransportTests/Vectors/generate_transport_fixtures.py` | `transport_fixtures.json` | `TransportCrossValidationTests.swift`, `RelayCrossValidationTests.swift`, `CompressionCrossValidationTests.swift`, `MultiSegmentCrossValidationTests.swift` |
| Single-packet proofs (RNS 1.4.2) | `generate_proof_fixtures.py` | `proof_fixtures.json` | `ProofCrossValidationTests.swift` |
| IFAC (RNS 1.4.2) | `generate_ifac_fixtures.py` | values pasted into the test | `Tests/ReTiCATransportTests/IFACCrossValidationTests.swift` |
| BLE fragmentation | `Tests/ReTiCAInterfacesTests/Vectors/generate_ble_fixtures.py` | `ble_fixtures.json` | `BLEFixtureTests.swift` |
| Meshtastic fragments | `generate_meshtastic_fixtures.py` (drives `landandair_Meshtastic_Interface.py`) | `meshtastic_fixtures.json` | `MeshtasticCrossValidationTests.swift` |

Two more scripts check reference behaviour instead of emitting fixtures:
`verify_lxmf_transfer_limit_semantics.py`, and `validate_retica_delivery_stamp.py`, which asks
reference LXMF to validate a stamp ReTiCA generated. The second reads its input from a file that
no committed test writes, so it cannot be re-run from a fresh checkout without writing that test.

What the fixtures do not prove: they pin formats and individual computations. Behaviour over time
(retries, windows, timers, ordering) is tested ReTiCA against ReTiCA, with the reference constants
cross-checked but not the reference state machines.

### 2. Run them

```sh
swift test --filter ReTiCATests            # core: crypto, packets, links, resources, LXMF formats
swift test --filter ReTiCATransportTests   # transport, proofs, IFAC, relaying
swift test                                 # everything, including BLE, Meshtastic and node tests
```

The build needs the `FCB` and `MeshtasticKit` sibling checkouts (see Part 1).

### 3. Regenerate the fixtures against your RNS

To check a different reference version, install it and regenerate:

```sh
python -m pip install rns==1.4.2 lxmf==1.1.0      # or the versions you want to check
cd Tests/ReTiCATests/Vectors
python generate_fixtures.py > fixtures.json
python generate_lxmf_fixtures.py > lxmf_fixtures.json
# ...and likewise for the other generators. generate_proof_fixtures.py writes its own file;
# generate_ifac_fixtures.py prints values to compare with IFACCrossValidationTests.swift.
cd -
swift test
```

Most generators use fresh random keys, so a regenerated fixture differs from the committed one;
that is expected, and the tests must still pass. Each script's header names the reference version
it was written against and anything it stubs (for example `Transport.register_destination`,
because no Reticulum instance is running). `generate_ble_fixtures.py` loads
`BLEFragmentation.py` from a torlando-tech/ble-reticulum checkout and `ble_support.py` from a
Reticulum fork (stock RNS has no BLE interface), both from absolute paths hard-coded at the top
of the script; edit them before running it.

### 4. Live tests against a running reference node

Both are skipped unless an environment variable is set.

- **Learning announces from a real node** (`Tests/ReTiCANodeTests/LiveEndpointTests.swift`):
  connects to a TCP node and expects at least one learned path within 10 seconds.

  ```sh
  RETICA_LIVE_HOST=127.0.0.1 RETICA_LIVE_PORT=4242 swift test --filter LiveEndpoint
  ```

- **ReTiCA opening a link to a stock LXMF peer through a stock transport node**
  (`Tests/ReTiCANodeTests/LiveLinkProbeTests.swift`, harness `Scripts/linkprobe/harness.py`,
  RNS 1.4.2 and LXMF 1.1.0). The link request is relayed, so it takes the HEADER_2 path. Run
  `prober` first: it does the same thing with stock RNS, so if it fails the harness is broken,
  not ReTiCA.

  ```sh
  python Scripts/linkprobe/harness.py hub       # terminal 1: rnsd transport node on 127.0.0.1:4250
  python Scripts/linkprobe/harness.py peer      # terminal 2: stock LXMF peer
  python Scripts/linkprobe/harness.py prober    # terminal 3: stock RNS check, expect RESULT=ESTABLISHED
  RETICA_LIVE_PROBE=1 swift test --no-parallel --filter LiveLinkProbe
  ```

- **Messages surviving a peer that enforces stamps**
  (`Tests/ReTiCANodeTests/LiveStampInteropTests.swift`, peer `Scripts/stampprobe/peer.py`, RNS 1.6.0
  and LXMF 1.3.0, peer configured as MeshChatX configures its router). Covers stamped announces, a
  first message before any announce, a first message to a peer that comes online 30 s later (after
  the wait), a large message over a link, a message from the peer, and a
  propagated message through a real node to a recipient that syncs. For RNS network stamps, peers
  that enforce them (`--enforce-network`) accept ReTiCA's stamped link requests, path requests and
  announces and drop its unstamped ones, and a ReTiCA node with `enforceStamps` on learns a
  stamped reference announce and drops an unstamped one. The tests start the peers
  themselves and assert on what the peer logged, because an enforcing peer proves a packet before
  it drops it, so `deliveryConfirmed` does not show receipt.

  ```sh
  python -m pip install rns==1.6.0 lxmf==1.3.0
  RETICA_LIVE_STAMP_PYTHON="$(which python)" swift test --no-parallel --filter LiveStampInteropTests
  ```

  The harness keeps its configs and identities under `/tmp/ReTiCA/linkprobe`.

### 5. By hand

1. Run `rnsd` with a TCP server interface, for example:

   ```
   [reticulum]
     enable_transport = Yes
     share_instance = Yes

   [interfaces]
     [[TCP Server Interface]]
       type = TCPServerInterface
       interface_enabled = True
       listen_ip = 0.0.0.0
       listen_port = 4242
   ```

2. Point a ReTiCA app at it: `TCPEndpoint.State(host: "<that machine>", port: 4242)`.
3. On the same machine, attach a reference LXMF client to the shared instance:
   - `python Scripts/meshtastic-hardware/lxmf_probe.py --name "probe"` prints its own LXMF
     address, every LXMF delivery announce it hears (with the display name), and every message
     it receives. With `--send <address> --text "hi" --method opportunistic` (or `direct`) it
     sends one.
   - NomadNet attaches to the shared instance by itself; Sideband or MeshChat can add a TCP
     client interface pointing at port 4242.
4. Check both directions: the reference side shows the ReTiCA node's display name (from its
   announce), messages arrive both ways, opportunistic and direct, and each sender sees its
   message confirmed.
5. For propagation, run `lxmd -p` on the same instance, give its `lxmf.propagation` hash to
   `.setPropagationNode`, send to a recipient that is offline, then sync from the recipient.
6. `rnstatus` shows interfaces and traffic; `rnpath <hash>` shows whether a path to the ReTiCA
   destination was learned.

### What has not been verified

So that nobody reads more into the tables than is there:

- **No interop runs against Sideband, NomadNet, MeshChat or `lxmd` are recorded in this
  repository.** Read "Implemented" above as "implemented and checked against fixtures", not
  "tested against every client".
- The live link probe exists, but no passing run is recorded.
- The BLE and Meshtastic hardware checklists
  (`docs/superpowers/plans/2026-08-01-ble-hardware-checklist.md`,
  `docs/superpowers/plans/2026-10-16-meshtastic-hardware-checklist.md`) have no recorded results.
  BLE compatibility is cross-validated only at the fragmentation level.
- Propagation node peering has not been tested against a reference `lxmd`.
- Against RNS 1.6.0 and LXMF 1.3.0, only the network stamp fixtures and the live stamp tests have
  been checked. RNS 1.6's other changes (table culling, SQLite storage) are not implemented.
- Network stamps are off by default. A network enforcing them drops ReTiCA's announces and path
  requests unless the host turns on `stampDestinations` and `stampPathRequests`. Link requests
  are stamped regardless.
- ReTiCA's own enforcement (`enforceStamps`) has been run live only for announces. Refusing
  inbound path requests and link requests is tested only with reference fixtures.
- **Hash rates on a phone have not been measured.** The figures in Part 1 are from a Mac. Nothing
  about network stamps has been tried on a phone.
- The real MeshChatX application has not been run against ReTiCA, only a router configured from
  its source.

---

# Repository layout

```
Sources/
  ReTiCA/                 pure core: Crypto, Identity, Packet, Destination, Link, Resource,
                          Framing (HDLC), Support (MsgPack), LXMF
  Cbzip2/                 vendored libbzip2 (compression byte-identical to Python's bz2)
  ReTiCATransport/        Transport, LinkSession, ResourceTransfer, IFAC, InterfaceProfile
  ReTiCAInterfaces/       TCP client and server, BLE, Meshtastic interfaces
  ReTiCANode/             TransportEndpoint, LXMFNode, LXMFRouter, LXMFServiceNode, PNNode
  ReTiCAKeychain/         IdentityKeychain, IdentityBackup
  ReTiCAMeshtasticLive/   live Meshtastic driver
Tests/                    one test target per library target; Vectors/ hold the reference fixtures
Scripts/                  link probe harness, LXMF probe, wire-narrowing checker
docs/                     reference-parity-checklist.md, reference-gap-analysis-2026-08-10.md,
                          wire-narrowing-inventory.md, design specs and plans
```

# Running the tests

```sh
swift build
swift test
```

The tests use Swift Testing and TCA's `TestStore`. Socket, BLE and radio I/O sit behind TCA
dependencies, so the suite needs no network or hardware; the live tests above are opt-in.

`Scripts/check-wire-narrowing.swift` is a lexical check that every bare integer conversion in
`Sources/` (each one a potential crash on hostile input) has been reviewed and allow-listed; see
`docs/wire-narrowing-inventory.md`.
