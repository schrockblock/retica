# AutoInterface for ReTiCA: design spec

**Date:** 2026-11-10 · **Status:** spec, not started · **Reference:** RNS 1.6.0 (conda env `rns-latest`)

This supersedes the requirements note `AUTOINTERFACE.md` (untracked, Sept 2026). §10 lists what that
note got wrong.

Citation keys (all under `/Users/ell/opt/anaconda3/envs/rns-latest/lib/python3.12/site-packages/RNS/`):
`AI` = `Interfaces/AutoInterface.py` (713 lines), `IF` = `Interfaces/Interface.py`, `TP` = `Transport.py`,
`RT` = `Reticulum.py`, `NI` = `Interfaces/util/netinfo.py`, `ID` = `Identity.py`.
Tags: **[read]** means read in source. **[ran]** means observed on this Mac (Darwin 27.2, en0) with the
probes `/tmp/ReTiCA/autoif_probe.py` and `/tmp/ReTiCA/autoif_gen_proto.py` and with `rnsd` 1.6.0. Untagged
Apple-platform statements are background knowledge; §8 says which ones need checking on a device.

---

## 1. What it is

A parent interface adopts every eligible network interface (NIC) that has an IPv6 link-local address. On
each one it multicasts a 32-byte discovery token. When a peer's token validates, the parent spawns one
RNS interface (`AutoInterfacePeer`) for that peer address, and RNS packets then travel as unicast UDP
between link-local addresses. The parent's own `process_outgoing` does nothing (`AI:617`). The parent is
still registered with Transport (`RT:1196`), but all traffic goes through the spawned peers.

## 2. Constants [read]

| Name | Value | Source |
|---|---|---|
| `HW_MTU` | 1196 | `AI:44` |
| `FIXED_MTU` | True (copied to peers, `AI:647`) | `AI:45` |
| `DEFAULT_DISCOVERY_PORT` | 29716 | `AI:47` |
| unicast discovery port | `discovery_port + 1` (29717) | `AI:174` |
| `DEFAULT_DATA_PORT` | 42671 | `AI:48` |
| `DEFAULT_GROUP_ID` | `b"reticulum"` | `AI:49` |
| `DEFAULT_IFAC_SIZE` | 16 bytes | `AI:50` |
| scope nibbles | link `2`, admin `4`, site `5`, organisation `8`, global `e` | `AI:52-56` |
| address-type nibbles | permanent `0`, temporary `1` | `AI:58-59` |
| `PEERING_TIMEOUT` | 22.0 s (×1.25 on Android only) | `AI:61`, `AI:151-152` |
| `ANNOUNCE_INTERVAL` | 1.6 s | `AI:62` |
| `PEER_JOB_INTERVAL` | 4.0 s | `AI:63` |
| `MCAST_ECHO_TIMEOUT` | 6.5 s | `AI:64` |
| reverse peering interval | `1.6 × 3.25` = 5.2 s | `AI:147` |
| initial peering wait | `1.6 × 1.2` = 1.92 s | `AI:332` |
| `BITRATE_GUESS` | 10 000 000 | `AI:70` |
| `MULTI_IF_DEQUE_LEN` / `_TTL` | 48 / 0.75 s | `AI:72-73` |
| `ALL_IGNORE_IFS` | `["lo0"]` | `AI:66` |
| `DARWIN_IGNORE_IFS` | `["awdl0","llw0","lo0","en5"]` | `AI:67` |
| discovery `recvfrom` size | 1024 | `AI:367` |
| data `recvfrom` size | 8192 (`socketserver.UDPServer.max_packet_size`) [ran] | `AI:342` |
| multicast hop limit / loop | kernel defaults 1 / 1 (never set) [ran] | `AI:278-285` |

`ID:83`: `HASHLENGTH = 256` bits, so `data[:HASHLENGTH//8]` compares all 32 bytes (`AI:369`).

## 3. Config knobs

| Key (RNS config) | Default | Parse | Source |
|---|---|---|---|
| `group_id` | `"reticulum"` | UTF-8 encoded | `AI:106`, `AI:164-167` |
| `discovery_scope` | `link` | `link/admin/site/organisation/global`, case-insensitive. **Any other value crashes the constructor** with `AttributeError` [ran] | `AI:190-201` |
| `multicast_address_type` | `temporary` | `temporary/permanent`; anything else → temporary | `AI:176-183` |
| `discovery_port` | 29716 | int; unicast discovery = +1 | `AI:108`, `AI:169-174` |
| `data_port` | 42671 | int | `AI:110`, `AI:185-188` |
| `devices` | `[]` (all) | list; allow-list | `AI:111`, `AI:154-157` |
| `ignored_devices` | `[]` | list | `AI:112`, `AI:159-162` |
| `bitrate` | 10 Mb/s | the generic key, `>= 5`; it reaches the interface as `configured_bitrate` | `RT:1018-1020`, `RT:1204`, `AI:326-329`, `RT:1127` |
| `ifac_size` | 16 bytes | given in **bits**, `//8`, must be `>= 8` | `RT:973-975`, `RT:1130-1131` |
| `networkname` / `passphrase` | none | IFAC credentials | `RT:977-991` |
| `announce_cap`, `mode`, `outgoing`, `ingress_control`, `ic_*`, `ec_*`, `announce_rate_*`, `destination_cost`, `pr_cost` | generic | set on the parent, copied to each peer (§4.9) | `RT:1117-1170` |

There is no knob for any timing constant or for the hop limit.

## 4. Wire behaviour a Swift peer must match

### 4.1 Group address [read, ran]
`g = SHA-256(group_id)`. The text form is `"ff" + type + scope + ":0:" + hex16(g[2],g[3]) + … +
hex16(g[12],g[13])`, written with `"{:02x}"` of a 16-bit value, so there is no zero padding past two
digits (`AI:203-213`). Only the **bytes** go on the wire, through `inet_pton`/`getaddrinfo` (`AI:284`,
`AI:296`, `AI:509`). Build them directly:

```
group[0]  = 0xff
group[1]  = (typeNibble << 4) | scopeNibble      // 0x12 by default
group[2..3] = 0x00 0x00
group[4..15] = g[2..13]
```

Vectors [ran]: the default is `ff12:0:d70b:fb1c:16e4:5e39:485e:31e1`, with
`g = eac4d70bfb1c16e45e39485e31e1f5cc…`. `testgroup` gives `ff12:0:aa67:38a6:434:4ae8:6ee3:36ad`. Site
scope gives `ff15:…`. Global with the permanent type gives `ff0e:…`.

### 4.2 Discovery token [read, ran]
`token = SHA-256(group_id ‖ utf8(descopedLinkLocal))`, 32 bytes. The datagram is exactly the token
(`AI:493`, `AI:507`). Vector [ran]: `SHA-256(b"reticulum" + b"fe80::1") =
97b25576749ea936b0d8a8536ffaf442d157cf47d460dcf13c48b7bd18b6c163`.

### 4.3 Address text form and descoping [read, ran]
The string a token hashes must match byte for byte between the sender and the receiver.
1. **Sender side.** Each address comes from `getifaddrs`, formatted by Python's `ipaddress` with no
   scope (`NI:164-170`, `NI:73`). The `fe80:` prefix is checked (`AI:237`), then `descope_linklocal`
   runs: `split("%")[0]`, then `re.sub(r"fe80:[0-9a-f]*::", "fe80::", s)` (`AI:80-85`).
2. **Receiver side.** The source comes from CPython `recvfrom`: the first tuple element is `inet_ntop`
   text with **no `%scope`**, and the scope id is a separate fourth element. [ran] on en0:
   `('fe80::1425:a9a9:777d:c72f', 58703, 0, 11)`.
3. On Darwin 27, `getifaddrs` does **not** embed the scope in `sin6_addr` (en0 reads
   `fe80::1425:…`, not `fe80:b::…`), so the regex does nothing here [ran]. `lsof` shows the
   kernel-internal embedded form (`fe80:b::…`). Do not copy addresses from `lsof`.
4. A quirk to reproduce exactly [ran]: `fe80:4:0:0:a::` comes out unchanged, because the zero run is
   compressed at the end. `fe80:ab::1%en0` becomes `fe80::1`.
5. Swift: format with `inet_ntop(AF_INET6, &sin6_addr)` on both sides (it compresses the same way as
   Python `ipaddress` for `fe80::/10`: leftmost longest run of two or more groups, lowercase), then apply
   the same split and regex. The fixtures pin this (§7.1).

### 4.4 Sockets, ports and directions [read, ran]
For each adopted NIC, with `idx = if_nametoindex(name)`:

| Socket | Options | Bind | Purpose |
|---|---|---|---|
| multicast discovery | `SO_REUSEADDR`, `SO_REUSEPORT`, `IPV6_MULTICAST_IF=idx`, `IPV6_JOIN_GROUP{group, idx}` | `(group, discovery_port, 0, idx)`. For non-link scopes: `(group, port)` with no scope | `AI:278-300` |
| unicast discovery | `SO_REUSEADDR`, `SO_REUSEPORT` | `(ll, discovery_port+1, 0, idx)` | `AI:257-270` |
| data (`UDPServer`) | **no** reuse options (`allow_reuse_address=False`) [ran] | `(ll, data_port, 0, idx)` | `AI:337-347` |

Outbound traffic always uses a fresh or unbound socket, so the source port is ephemeral and receivers
ignore it:
1. **Multicast announce**, every 1.6 s per NIC: a new socket with `IPV6_MULTICAST_IF=idx`,
   `sendto(token, (group, discovery_port, 0, 0))` (`AI:504-513`; [ran] captured sockaddr).
2. **Reverse announce** (unicast): a new socket, **no** `MULTICAST_IF`,
   `sendto(token_for_this_NIC, (peer, discovery_port+1, 0, idx))` (`AI:490-499`; [ran]). The
   `ifis` computed there is unused (`AI:497`).
3. **Data**: one shared unbound socket per parent, `sendto(raw, (peer, data_port, 0, idx))`
   (`AI:670-677`). The destination port is **our own** configured `data_port`, so both sides must
   agree on it.

Multicast hop limit stays at the kernel default of 1 [ran], so admin, site, organisation and global
scopes change only the group address. Traffic never leaves the link.

### 4.5 Inbound discovery [read]
Both discovery sockets feed `discovery_handler` (`AI:358-374`):
1. A datagram is **dropped until `final_init_done`**, which is set after the 1.92 s initial wait
   (`AI:353-356`, `AI:368`). Tokens and echoes in that window are lost.
2. Validation: `data[:32] == SHA-256(group_id ‖ srcText)`. Shorter data fails. Longer data with a
   valid 32-byte prefix is accepted.
3. On a match, `add_peer(srcText, ifnameOfTheReceivingSocket)` (`AI:372`).

### 4.6 add_peer, echo and refresh [read]
1. **Echo.** If `src` is one of our own link-local addresses (`AI:527`), find the NIC whose adopted
   address equals `src`, which need not be the arrival NIC. Set `multicast_echoes[nic]=now`, and set
   `initial_echoes[nic]` once. No peer is created (`AI:527-537`). The echo comes from kernel multicast
   loopback (`IPV6_MULTICAST_LOOP=1` [ran]), so it shows that **this host** let the send out. It says
   nothing about whether the access point forwards multicast.
2. **New peer.** `peers[src] = [ifname, now, now]`, meaning `[nic, lastHeard, lastOutbound]`. Spawn and
   register the peer (`AI:540-605`). Peers are keyed by **address only**. The first NIC an address is
   heard on stays its NIC.
3. **Known peer.** `refresh_peer`: `lastHeard = now` (`AI:606-611`).
4. **Unbounded.** There is no peer cap.

### 4.7 Peer job, every 4.0 s, first tick 4 s after `final_init` starts [read]
In this order (`AI:376-482`):
1. **Evict** peers with `now > lastHeard + 22`: detach, teardown, `Transport.remove_interface`
   (`AI:383-396`, `AI:683-703`). Effective eviction time is 22–26 s.
2. **Reverse announce** to each peer with `now > lastOutbound + 5.2`, then `lastOutbound = now`
   (`AI:399-408`). A new peer's first reverse announce goes out at the first tick after 5.2 s.
3. **Link-local change**, per adopted NIC: re-read the addresses. A changed `fe80:` address replaces
   the adopted one and **restarts only the data listener** (old one shut down; new bind retried every
   1.25 s). The discovery sockets are **not** rebound, so the unicast-discovery socket stays on the old
   address (`AI:410-457`). Tokens use the new address from then on. Peers see a new address, and the
   old one times out. Reference bug: a NIC with two `fe80:` addresses flaps between them on every tick
   (`AI:416-424`).
4. **Echo watchdog**: a NIC becomes timed-out when `now - lastEcho > 6.5`. It logs "Carrier lost" or
   "recovered" only on a transition, and the first evaluation sets state silently (`AI:462-477`).
   `multicast_echoes[nic]` is seeded at adoption (`AI:241`). If no echo has **ever** arrived, it logs
   ERROR "No multicast echoes received … firewall may be blocking multicast" **every tick**
   (`AI:479-480`). The `carrier_changed` flag it sets is read nowhere else in RNS 1.6.0 (repo-wide
   grep), so the watchdog is purely diagnostic.

NICs are adopted **once**, in `__init__` (`AI:215-312`). A NIC that appears later, or had no link-local
address at start, is never adopted. A NIC that disappears is never dropped: its announce sends fail
with a "possible carrier loss" warning (`AI:516-518`). If no NIC qualifies, the interface stays with
"no connectivity" (`AI:321-322`), and its bitrate then stays at the base 62 500 [ran].

### 4.8 Data plane [read, ran]
1. **One UDP datagram is exactly one raw RNS packet.** There is no HDLC, no length prefix and no
   fragmentation. `UDPServer` hands `request[0]` straight through (`AI:705-713`), and the sender
   `sendto`s the masked raw bytes (`AI:677`).
2. Inbound is dispatched by **source address only**: a datagram is dropped unless `online` is true and
   `src` is a spawned peer (`AI:613-615`). Data from an address that has not been discovered is dropped
   silently.
3. Dedupe across the whole parent: `h = SHA-256(datagram)`. It is a hit if any ring entry has the same
   `h` and `now < t + 0.75`. A hit is dropped **and does not refresh the peer**. A miss refreshes
   `lastHeard`, appends `(h, now)` to a 48-entry ring and goes to `Transport.inbound(data, peer)`
   (`AI:652-668`). The ring holds the raw (IFAC-masked) bytes. Masking is deterministic, so copies of
   one packet sent over two of a remote's NICs collide. That is the case dedupe exists for: a remote
   with Wi-Fi and Ethernet on one segment is **two peers**, Transport sends every broadcast to both, and
   the copies arrive twice.
4. Transport then drops `len(raw) > HW_MTU + ifac_size`, which is 1212 by default (`TP:2017-2018`).

### 4.9 Spawned peers: what they inherit [read]
At spawn (`AI:543-598`), a peer copies the parent's IN, OUT, `ingress_control` and every `ic_*`,
`egress_control`, `ec_pr_freq`, both stamp costs, `bitrate`, `ifac_size`, `ifac_netname`/`netkey`
(it re-derives its own IFAC key and identity, with the same result as the parent, `AI:567-585` against
`RT:1175-1189`), the announce-rate fields, `mode`, `gravity`, `announce_cap` and `HW_MTU`.
1. **IFAC**: same key and size on every peer.
2. **Announce cap**: per peer, copied from the parent (default 2 %, `RT:1037-1040`).
3. **Bitrate**: per peer, copied.
4. **Ingress control**: each peer is its own domain. `Transport` asks `packet.receiving_interface`, which
   is the peer, never the parent (`TP:2066`, `TP:2133`, `TP:3777`). The parent does get aggregated
   counters (`IF:307-311`) and its own `should_ingress_limit()` runs (`TP:1334-1337`), but nothing
   consults the result for traffic that arrives on a peer.
5. Every spawn is a **new object**, so `created=now` (`IF:110`). A peer that times out and comes back
   restarts its 2 h new-interface ingress window (`IF:76`, `IF:195`).
6. Link MTU: peers have `FIXED_MTU`, so `next_hop_interface_hw_mtu` returns 1196 (`TP:3518-3522`).
   ReTiCA always signals 500 (`Sources/ReTiCA/Link/Link.swift:21`), so links stay at 500.
   Interoperable, no change needed.

### 4.10 Same host [ran]
1. Two instances on one host share each NIC's link-local address, so every token from the other is
   treated as an **echo** and they **never peer**. `rnsd` (`data_port=42672`) ran next to the
   AutoInterface of a NomadNet already running here for over a minute: no peer was added.
2. With the same `data_port`, the second instance's data bind fails `EADDRINUSE`, and **rnsd panics and
   exits** (exit 255; `RT:1307-1311`; logged traceback at `AI:342`). Discovery sockets coexist
   (`SO_REUSEPORT`).
3. So a ReTiCA Mac app and an `rnsd` with the default config (`RT:2558-2560` enables AutoInterface)
   cannot both run AutoInterface on one Mac, and whichever starts second loses. The iOS Simulator
   shares the host's network stack, so it falls under the same rule.
4. The reference adopts `utun0`…`utun9` on macOS, because they are not on the ignore list: the running
   NomadNet holds 11 socket trios (en0 plus 10 utuns) [ran, `lsof`]. It does not check `IFF_UP` or
   `IFF_RUNNING`. Its only filter is having an `fe80:` address (`AI:216-249`; `NI:35-37`).

## 5. How ReTiCA hosts it

### 5.1 Shape (existing patterns)
- `TransportEndpoint` is a struct product with kind-indexed optional slots, one shared `Transport` and
  one shared `LinkPlane` (`Sources/ReTiCANode/TransportEndpoint.swift:24-133`).
- The 1:N precedents are the TCP server (`connInterfaces`, `TransportEndpoint.swift:382-413`,
  `TCPServerEndpoint.swift:10-12`) and BLE (`peerInterfaces`, `TransportEndpoint.swift:416-433`,
  `BLEEndpoint.swift:13-16`).
- Maintenance start/stop is driven by the **shared** interface count
  (`TransportEndpoint.swift:663-711`). Bulk disconnect reuses `disconnectAllServerConnections`
  (`:700-711`).
- Transmit routing runs through `transmit(_:to:masked:unmasked:)` (`:722-760`). IFAC masking is central
  (`:562-569`).
- The driver dependency follows `TCPListener`: a `Sendable` struct of closures, an `AsyncStream` of
  events, `liveValue`/`testValue`, and an actor with a generation counter guarding against stale
  callbacks (`Sources/ReTiCAInterfaces/TCPListener.swift:38-229`, `TCPConnection.swift:93-197`).
  `DriverEpoch` orders start against stop (`DriverEpoch.swift:24-41`).

### 5.2 New files

| File | Contents |
|---|---|
| `Sources/ReTiCAInterfaces/AutoInterface/AutoInterfaceWire.swift` | Pure functions: `groupAddress(groupID:scope:type:) -> [UInt8]` (16 bytes), `discoveryToken(groupID:linkLocal:) -> Data`, `descope(_:) -> String`, `formatIPv6(_ bytes:) -> String` (calls `inet_ntop`), constants (§2) |
| `Sources/ReTiCAInterfaces/AutoInterface/AutoInterfaceConfig.swift` | `AutoInterfaceConfig`: `groupID`, `scope: Scope` (enum, so an invalid value cannot be expressed), `addressType`, `discoveryPort`, `dataPort`, `devices: [String]`, `ignoredDevices: [String]`, `peerCap`, plus the eligibility predicate (§5.5) |
| `Sources/ReTiCAInterfaces/AutoInterface/AutoInterfaceDriver.swift` | The dependency (§5.3) and `liveValue` over a private `AutoSocketActor` (Darwin) |
| `Sources/ReTiCAInterfaces/AutoInterface/AutoInterface.swift` | The `@Reducer` mechanism (§5.4) |
| `Sources/ReTiCANode/AutoEndpoint.swift` | Driver slot: `AutoInterface.State`, `peerInterfaces: [InterfaceID: AutoPeer]`, `profile`, and `autoInterfaceID(nic:addr:)` |
| `InterfaceProfile.swift` (edit) | `static let auto = InterfaceProfile(name: "auto", bitrate: 10_000_000, hwMTU: 1196)`. IFAC size 16 is passed to `IFAC(networkName:passphrase:size:)`; `InterfaceProfile` has no size field |
| `TransportEndpoint.swift` (edit) | `auto: AutoEndpoint.State?`, `State.auto(_:)`, `Action.auto(AutoEndpoint.Action)`, `.removeAuto`, `.start`/`.stop` arms, peer arms, one `transmit` branch, and `state.auto != nil` added to the `.interfaceUnavailable` guard (`:758`) |

**Interface IDs:** `InterfaceID("auto:\(nic)/\(addr)")`, for example `auto:en0/fe80::1c2b:…`. This
mirrors the reference name `AutoInterfacePeer[ifname/addr]` (`AI:649-650`), so logs line up. The peer
table is still keyed by `addr` (§4.6.2).

### 5.3 Driver dependency surface

```swift
public struct AutoNIC: Equatable, Sendable { name: String; index: UInt32; linkLocals: [String] }  // getifaddrs order, inet_ntop text
public struct AutoBinding: Equatable, Sendable {
    nic: String; index: UInt32; linkLocal: String; group: [UInt8]   // 16 bytes
    linkScope: Bool; discoveryPort: UInt16; dataPort: UInt16
}
public enum AutoPlane: Sendable, Equatable { case multicastDiscovery, unicastDiscovery, data }
public enum AutoSocketEvent: Sendable, Equatable {
    case bound(nic: String)
    case bindFailed(nic: String, plane: AutoPlane, errno: Int32)       // EADDRINUSE on .data → §4.10
    case datagram(nic: String, plane: AutoPlane, source: String, sourceScope: UInt32, payload: Data)
    case readFailed(nic: String, plane: AutoPlane, errno: Int32)
}
public enum AutoSendResult: Sendable, Equatable { case sent, failed(errno: Int32) }

public struct AutoInterfaceDriver: Sendable {
    public var interfaces:    @Sendable () -> [AutoNIC]                              // getifaddrs snapshot
    public var run:           @Sendable ([AutoBinding]) -> AsyncStream<AutoSocketEvent>
    public var rebind:        @Sendable (AutoBinding) async -> Void                  // address change / NIC added
    public var unbind:        @Sendable (_ nic: String) async -> Void                // NIC vanished
    public var sendMulticast: @Sendable (_ nic: String, _ token: Data, _ port: UInt16) async -> AutoSendResult
    public var sendUnicast:   @Sendable (_ addr: String, _ index: UInt32, _ port: UInt16, _ datagram: Data) async -> AutoSendResult
    public var stop:          @Sendable () async -> Void
}
```

Live actor (Darwin, `import Darwin`):
1. `getifaddrs`: keep `AF_INET6` entries whose `inet_ntop` text starts with `fe80:`. `if_nametoindex`
   gives the index.
2. Per binding, three sockets as in §4.4: `socket(AF_INET6, SOCK_DGRAM, IPPROTO_UDP)`, `setsockopt` with
   `ipv6_mreq{ipv6mr_multiaddr, ipv6mr_interface}`, and `sockaddr_in6.sin6_scope_id = index`.
   **No** reuse options on the data socket, to match the reference (so a clash fails loudly rather than
   splitting unicast). Use `O_NONBLOCK`.
3. Senders: one unbound socket per NIC with `IPV6_MULTICAST_IF` for announces. Do not send from the
   socket bound to the group address. One shared unbound socket for every unicast send, with
   `sin6_scope_id = index`.
4. Reads: a `DispatchSourceRead` per fd; `recvfrom` into an 8192-byte buffer. Close the fd **only** in
   the source's `cancelHandler`, never while the source is live. Each event carries the actor's
   generation. `stop`/`unbind`/`rebind` bump it, and stale events are dropped before they reach the
   continuation (the `NWConnectionActor` lesson, `TCPConnection.swift:97-112`).
5. `source` = `inet_ntop` text with no scope; `sourceScope` = `sin6_scope_id`.

Network.framework is **possible**: `NWConnectionGroup`/`NWMulticastGroup`, `requiredInterface` and
`requiredLocalEndpoint` all exist. POSIX is still recommended. It reproduces the reference's per-NIC
binds and its `inet_ntop` text exactly, and `NWListener` UDP flows would add an object per peer
4-tuple for no gain.

### 5.4 Reducer `AutoInterface`
State: `config`, `status (.stopped/.starting/.running/.noUsableInterfaces)`,
`nics: [String: NIC{index, linkLocal, lastEcho, firstEcho: Date?, timedOut: Bool?, failed: Set<AutoPlane>}]`,
`peers: [String: Peer{nic, index, lastHeard, lastOutbound}]`, `mif: RingOf48<(Data, Date)>`, `accepting: Bool`
(the reference's `final_init_done`), and `epoch: DriverEpoch`.
Clocks: `@Dependency(\.continuousClock)` for timers, and a date dependency for stamps (`TestClock` in
tests).

Actions and behaviour, numbered to match §4:
1. `.start`: read `driver.interfaces()`, filter (§5.5), build bindings, run the stream (cancellable).
   Start the announce timer **immediately** (1.6 s, every NIC), the peer-job timer (4.0 s) and a
   one-shot 1.92 s timer that sets `accepting = true`. Seed `lastEcho = now` per NIC. With no
   bindings: `.noUsableInterfaces`, keep the peer-job timer so later NICs get adopted (§5.6 D2).
2. `.announceTick`: `sendMulticast(nic, token(nic.linkLocal), discoveryPort)` for each NIC.
3. `.socketEvent(.datagram(_, .multicastDiscovery | .unicastDiscovery, src, scope, payload))`: ignore
   unless `accepting`. Validate the prefix (§4.5). Echo if `src` is ours (§4.6.1). Otherwise add or
   refresh. Attribute the NIC by `sourceScope` and drop when it does not match a known NIC (hardening
   only). A new peer beyond `peerCap` is dropped (§9 R4). A new peer emits
   `.delegate(.peerAdded(addr:nic:))`.
4. `.socketEvent(.datagram(_, .data, src, _, payload))`: drop unless `accepting` and `peers[src]`
   exists. Drop if `payload.count > 1196 + ifacSize` (Transport has no MTU check: grep of
   `Transport.swift`). Dedupe (§4.8.3). Refresh, then `.delegate(.packetReceived(addr:data:))`.
5. `.peerJobTick`, in the order of §4.7: evict (`.peerRemoved`), reverse announce, re-enumerate NICs
   (change → `rebind`, plus D1 and D2 below), then the echo watchdog. The watchdog emits
   `.carrierLost(nic)` / `.carrierRecovered(nic)` on transitions and `.multicastUnavailable(nic)`
   **once** while no echo has ever arrived after 6.5 s.
6. `.send(addr:data:)`: `sendUnicast(addr, peer.index, dataPort, data)`. `.failed(EHOSTUNREACH |
   ENETUNREACH | EPERM)` feeds §8.4.
7. `.stop`: invalidate the epoch, cancel every timer and the stream, `driver.stop()`, clear peers, the
   ring and `accepting`. Peer deregistration happens in the container (§5.7), from its own map, the way
   `.tcpServer(.interface(.stop))` does it (`TransportEndpoint.swift:397-398`).

### 5.5 NIC eligibility (keeps the reference's order, `AI:218-231`)
1. `lo0`: always skipped on Darwin, even if listed in `devices` (`AI:220`).
2. Darwin ignore list (`awdl0, llw0, en5`): skipped unless listed in `devices`.
3. Listed in `ignored_devices`: skipped.
4. `devices` non-empty and the NIC not in it: skipped.
5. **ReTiCA addition** (no wire effect): also skip by prefix `utun`, `ipsec` and `pdp_ip` unless the
   NIC is in `devices` (§8.3). The reference adopts utuns (§4.10.4).
6. When a NIC has several `fe80:` addresses, adopt the **last** in getifaddrs order, as the reference
   does (`AI:235-240`), and never flap (fixes `AI:416-424`).

### 5.6 Deliberate divergences (none visible on the wire)
- D1: an address change rebinds **all three** sockets. The reference rebinds only data, which leaves
  reverse peering to it broken.
- D2: NICs are re-enumerated every peer-job tick, so ones that appear are adopted and ones that vanish
  are unbound, with their peers evicted at once. The reference adopts only at init. On iOS that would
  leave AutoInterface dead if Wi-Fi was off at launch.
- D3: a data bind that hits `EADDRINUSE` fails only that NIC, surfaces `.dataPortInUse(nic)`, and retries
  every tick. The reference panics the whole process.
- D4: a peer cap (§9 R4).
- D5: a returning peer keeps its first-connect ingress age, because Transport resumes it for a
  re-registered ID (`Transport.swift:992-1003`). The reference gives a new peer object a new 2 h
  window (§4.9.5). Accept this. It matches the policy already chosen for TCP and radio reconnects.

### 5.7 TransportEndpoint wiring
- `.auto(.interface(.delegate(.peerAdded(addr, nic))))`: `id = autoInterfaceID`. Compute
  `maintenanceStartEffect(state)` **before** mutating `peerInterfaces[id]`. Then
  `.transport(.interfaceConnected(id, profile))`. This is the BLE arm's shape
  (`TransportEndpoint.swift:416-422`).
- `.peerRemoved`: `interfaceDisconnected`, then `linkPlane(.interfaceDisconnected)`, then
  `maintenanceStopEffect(state, departing: id)`.
- `.packetReceived(addr, data)`: `.transport(.received(id, data))`.
- `.auto(.interface(.stop))` and stream failure: a bulk disconnect from `peerInterfaces`, modelled on
  `disconnectAllServerConnections`.
- `transmit`: `if let peer = state.auto?.peerInterfaces[txID] { return .send(.auto(.interface(.send(addr: peer.addr, masked)))) }`.
- `.removeAuto`: deregister every peer, then `driver.stop()`, then `auto = nil`. Never set
  `auto = nil` without stopping the driver first: BLE learned this the hard way
  (`AppFeature.swift:3921-3925` in ReTiCAMsgr).
- Do **not** register a parent interface with Transport. The reference's parent is a no-op sink
  (`AI:617`).
- ReTiCA's ingress control already runs one domain per InterfaceID with no parent, which matches
  §4.9.4. The "KNOWN DEFERRAL (I2)" comment at `Transport.swift:1284-1290` says the reference gates on
  the aggregate. The 1.6.0 call sites in §4.9.4 show it does not. Re-check that comment, at least
  regarding AutoInterface, when this lands.

### 5.8 App wiring (ReTiCAMsgr, read-only survey)
- Toggle: add `@Shared(.appStorage("autoInterfaceEnabled"))`, next to `listenEnabled`
  (`ReTiCAMsgrCore/.../AppFeature.swift:298`, which `6f1aec7` made default-on).
- Slot sync goes in `syncEndpointNodes` (`AppFeature.swift:3885-3915`). A running slot must be kept,
  not recreated, because a fresh state would drop every live peer (see the BLE note at `:3921-3925`).
  Removal goes through `.removeAuto`.
- Restart on `.foregrounded` from `redialDownNodes` (`:4072-4107`). iOS stops the slot on
  `.backgrounded`; the Mac does not (`:614-625`). Add the toggle to `somethingWillDial`
  (`AppFeature+MeshtasticRadio.swift:36`).
- `isLoRaRadio` (`:928-931`) needs no change: `auto:` IDs count as fast links.
- Settings row: the caption reads like the listener's. The toggle row is whole-row tappable
  (`.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())`).
- `Info.plist` today has **no** `NSLocalNetworkUsageDescription` (`ReTiCAMsgr/Info.plist:1-16`, and no
  `INFOPLIST_KEY_NSLocalNetwork*` in `project.pbxproj`), even though the default-on TCP listener and the
  LAN dialing already touch the local network. Add it now, independently of this work.
- Entitlements: the iOS file has none for networking (`ReTiCAMsgr.entitlements:1-16`). Add
  `com.apple.developer.networking.multicast = true` once Apple approves it. The macOS file is
  sandboxed and already has `network.client` and `network.server` (`ReTiCAMsgr-macOS.entitlements:5-10`).
  Do not add the multicast key there.

## 6. Delegates for the app

`.peerAdded`, `.peerRemoved`, `.carrierLost`/`.carrierRecovered`, `.multicastUnavailable(nic)`,
`.dataPortInUse(nic)` (on a Mac this usually means a local rnsd or NomadNet is running: say so),
`.noUsableInterfaces`, and `.localNetworkDenied` (§8.4). Keep them hatch-only, off the unified
surface, the way BLE's `adapterUnavailable` is (`TransportEndpoint.swift:435-439`).

## 7. Tests

### 7.1 Reference-generated fixtures
Generator: `Tests/ReTiCAInterfacesTests/Vectors/generate_autointerface_fixtures.py`. Run it as
`/Users/ell/opt/anaconda3/envs/rns-latest/bin/python -I generate_autointerface_fixtures.py autointerface_fixtures.json`.
It writes the output path given as an argument, because `RNS.log` writes to stdout; set
`RNS.loglevel = -1` as well. Commit the generator. The technique is proven in
`/tmp/ReTiCA/autoif_gen_proto.py` [ran]:
1. Stub `RNS.Reticulum.get_instance` with an object whose `_default_*()` return `None`. Construct the
   **real** `AutoInterface(None, {...,"devices":"__none__"})`, so no NIC qualifies and no socket opens.
   Read `mcast_discovery_address`, `group_hash`, the ports and the bitrate. Matrix: group ids
   (`reticulum`, `testgroup`, a non-ASCII one, empty), every scope, both address types, custom ports.
   Plus the `bogus` scope, recorded as `error`.
2. `descope_linklocal` cases: `%ifname`, embedded scope, the `fe80:4:0:0:a::` quirk, `fe80:ab::1%en0`.
3. `peer_announce` and `reverse_announce`, with `socket.socket` monkeypatched in the module to a
   recorder. Capture the exact datagram, the sockaddr tuple and the `setsockopt` calls (expected
   `IPV6_MULTICAST_IF` = `41, 9, 01000000` for index 1).
4. Formatting: for about 30 sixteen-byte `fe80::/10` addresses (zero runs at the start, middle, end and
   tied), record `str(ipaddress.IPv6Address(b))` and `socket.inet_ntop`. Swift `formatIPv6` must equal
   both.
5. Behaviour traces: drive `discovery_handler` with a fake socket whose `recvfrom` replays a script and
   then sets `detached`. Drive `AutoInterfacePeer.process_incoming` with `time.time` patched and
   `RNS.Transport.add_interface`/`inbound` stubbed. Record which inputs created peers, which were
   echoes, and which data was deduped (48-entry eviction, the TTL boundary). Swift replays the same
   scripts into the reducer.

Swift tests: `AutoInterfaceCrossValidationTests` (fixtures 1-4) and `AutoInterfaceTraceTests` (5).

### 7.2 Reducer tests (mock driver, `TestClock`)
Prefer `.off` TestStores that assert outcomes, then mutate each clause (see memories: TestStore vacuity
traps, test name claims two). Cover:
1. Eligibility order (§5.5), including `lo0` listed in `devices` still being skipped.
2. An announce at t=0 and every 1.6 s per NIC, with the exact token bytes.
3. Discovery before 1.92 s dropped. After that: valid → one `peerAdded`; repeated → refresh only;
   bad hash, short data and wrong group dropped; trailing bytes accepted.
4. Echo: no peer is created, and `multicastUnavailable` fires once with no echo; `carrierLost` at the
   second tick, `carrierRecovered` after an echo.
5. Eviction at the first tick past 22 s. Data keeps a peer alive. A **deduped** datagram does not.
6. Reverse announce at the first tick past 5.2 s: to `discoveryPort+1`, carrying **our** token for the
   peer's NIC.
7. Data from an unknown address dropped, oversize dropped. Dedupe window is 0.75 s. The ring evicts at
   49 entries.
8. Address change: rebind is called, the new token is used, the existing peer keeps working until it
   times out.
9. Stop, then stale socket events are ignored. Stop racing start (`DriverEpoch`).
10. Endpoint: register and deregister, maintenance start and stop across `auto` + `tcpClients` together
    (the whole-slice probe: the shared-maintenance lesson), IFAC-masked transmit, and `sendFailed` for a
    stale ID.

### 7.3 Live driver over loopback (the mock hides this layer)
`lo0` (`fe80::1%lo0`, index 1) carries link-local unicast **and** multicast with loopback [ran]. Drive
the **live** `AutoInterfaceDriver` there directly: bind the trio, send a token to the group, receive it
(`source == "fe80::1"`, `sourceScope == 1`), send a data datagram of 1200 bytes, `rebind`, and check
that events from before the rebind never surface. Also assert that a second data bind on the same port
reports `bindFailed(.data, EADDRINUSE)`.

### 7.4 Live interop against real rnsd
**One Mac is not enough** (§4.10). Use a second host on the same L2 segment (Pi, Linux box or second
Mac), or a Linux VM with **bridged** networking. NAT networking will not do.

Host B config (`/tmp/rns-auto/config`):
```
[reticulum]
  enable_transport = Yes
  respond_to_probes = Yes
  share_instance = Yes
  shared_instance_port = 47428
  instance_control_port = 47429
[logging]
  loglevel = 6
[interfaces]
  [[Auto]]
    type = AutoInterface
    enabled = Yes
    devices = en0            # B's LAN NIC
```
1. `…/rns-latest/bin/rnsd --config /tmp/rns-auto -vv`. Note the probe hash in the log line "will
   respond to probe requests on <…>" (`TP:645-650`).
2. On the Mac (the test is `Tests/ReTiCANodeTests/LiveAutoInterfaceTests.swift`, enabled only when BOTH
   variables are set, so it shows as skipped otherwise):
   ```
   RETICA_LIVE_AUTO_DEVICE=en0 RETICA_LIVE_AUTO_PROBE=<32-hex probe hash from step 1> \
     swift test --no-parallel --filter LiveAutoInterface
   ```
   `RETICA_LIVE_AUTO_DEVICE` is this Mac's LAN NIC (check `route get default`). **Stop NomadNet and any
   `rnsd` on this Mac first**: they hold the default discovery and data ports (§4.10), and ReTiCA
   then reports `dataPortInUse` (the test fails with that message named).
   The test asserts, in order: no `dataPortInUse`/`noUsableInterfaces`/`localNetworkDenied`; a
   `peerAdded` on that NIC with an `fe80:` address within 8 s (the elapsed time is printed, the spec
   target is about 2 s); a path request makes B announce the probe destination and the learned route
   is `auto:<nic>/fe80:...`; a packet to the probe destination gets `singlePacketDelivered`; after
   `.stop` no peer interface remains.
   **Status: written, compiles, skipped by default. No second-host run has been recorded yet.**
   The user runs it and records the result here.
3. Pass criteria: ReTiCA emits `peerAdded` for B within about 2 s. `rnstatus --config /tmp/rns-auto -a`
   on B lists `AutoInterfacePeer[en0/<Mac fe80>]` (`rnstatus.py:464`, `RT:1727`). ReTiCA sends a path
   request, receives B's announce (path learned via `auto:en0/<B fe80>`), sends a packet to the probe
   destination and gets `singlePacketDelivered` (PROVE_ALL, `TP:648`). That covers both directions of
   discovery, data and proof.
4. Negative checks: stop ReTiCA, and B logs "removed peer" 22–26 s later. Start ReTiCA while rnsd (or
   NomadNet) runs **on the Mac**, and `.dataPortInUse(en0)` must surface.
5. Single-Mac fallback, **unverified**: a `feth` pair (`sudo ifconfig feth0 create`, `feth1`, then
   `feth0 peer feth1`, enable IPv6 on both), rnsd with `devices = feth1` and ReTiCA with
   `devices = feth0`. Whether Darwin routes scoped link-local traffic across the pair instead of
   delivering it locally is untested. Record the result in this spec.

## 8. iOS specifics

1. **Multicast entitlement** `com.apple.developer.networking.multicast`: required on iOS for sending
   and receiving multicast over BSD sockets. Request it from Apple with the form; it is not
   self-service. It is not used on macOS. Without it, the join or send fails, no echo arrives, and the
   reducer surfaces `.multicastUnavailable`. Unicast alone cannot discover anyone, so AutoInterface is
   useless on iOS without the entitlement.
2. **Local network permission**: needs `NSLocalNetworkUsageDescription`. The first local-network
   traffic triggers the prompt. There is no API to query the state. macOS 15+ applies the same privacy
   gate to apps. Our probes from this shell worked [ran]; the sandboxed Mac app will prompt.
3. **Which NICs**: `en0` (Wi-Fi) and `bridge100` (Personal Hotspot host, which can peer with tethered
   laptops) are useful. `pdp_ip*` (cellular) has no LAN peers and would burn about 80 B × 54 000
   announces per day (roughly 4 MB/day) per NIC, so ignore it by default. Ignore `utun*`/`ipsec*`
   (VPN, Private Relay) and `awdl0`/`llw0` (the reference's list) too (§5.5.5).
4. **Permission denied, or entitlement missing**: both show up the same way, as send errors
   (`EHOSTUNREACH`/`ENETUNREACH`/`EPERM`; the exact errno must be checked on a device) and no echo
   after 6.5 s. Emit `.localNetworkDenied` once. Keep the timers running, since a send costs little.
   Do not tear down. The next foreground restart picks up a grant. The app shows an alert that points
   to Settings › Privacy › Local Network. It must not hang `connection = .connecting`: exclude a
   denied auto slot from `somethingWillDial`.
5. **Background**: there is no background mode for UDP, and the app has only BLE and remote-notification
   modes (`Info.plist:9-14`). Stop on `.backgrounded`: the remote side evicts us after 22–26 s anyway,
   and sockets can be reclaimed while suspended. On `.foregrounded`, start fresh: rebind, re-announce,
   and peers come back in ≤ 1.92 + 1.6 s. A BLE background wake must not start it.
6. **Simulator**: it shares the Mac's stack and link-local addresses, so it cannot peer with anything on
   the same Mac (§4.10). Use it only for the UI.

## 9. Risks and open questions (each with a recommended answer)

| # | Question | Recommendation |
|---|---|---|
| R1 | Apple may refuse or delay the multicast entitlement | Build and ship macOS first. Hide the iOS toggle behind a build setting (`AUTOINTERFACE_ENTITLED`) until approval |
| R2 | Same-Mac conflict with rnsd or NomadNet (rnsd panics if it starts second) | Default **on** for the Mac to match `6f1aec7`'s default-on listener. Surface `.dataPortInUse` clearly with text that suggests "connect to your local rnsd over TCP instead". Never set `SO_REUSEPORT` on the data socket (it would not help: the reference does not set it) |
| R3 | Default on iOS | On once entitled, and in the foreground only |
| R4 | No peer cap in the reference; anyone on the link can mint valid tokens for spoofed source addresses (the token is public: `SHA-256(group ‖ addr)`) | Cap at 64 peers (configurable), drop new ones past it, log once. It is invisible to honest peers |
| R5 | Access point blocks multicast (guest or enterprise Wi-Fi): echo OK, no peers | No fix exists. Add a UI hint when echoes are OK, peers are zero and the duration exceeds 30 s |
| R6 | Two `fe80:` addresses on one NIC: the kernel may use the other one as the multicast source, so peers reject our token | Adopt the last one (parity). Cross-check with `connect()`+`getsockname()` toward the group; on a mismatch, log it and use the source address the kernel actually picks |
| R7 | Ingress age resumes on re-peer (D5) | Accept and document it |
| R8 | Fixture env: the memories name `rns` (stock 1.4.2) for fixtures, but 1.6.0 is the reference | Generate from `rns-latest`. The AutoInterface code under study is the 1.6.0 file |
| R9 | IFAC size on the Swift side | Pass `16` explicitly in `AutoEndpoint`; never inherit another profile's IFAC |
| R10 | Swift `UInt8` shift overflow if someone ports `g[2i+3] + (g[2i+2] << 8)` literally | Build the group bytes directly (§4.1). Never go through the text form |
| R11 | Darwin `IPV6_JOIN_GROUP` on a NIC without multicast (for example `utun` on some systems) | Treat `bindFailed(.multicastDiscovery)` as "skip this NIC", as the reference's per-NIC `try` does (`AI:314-319`) |

## 10. Corrections to `AUTOINTERFACE.md`

1. "3 of 15 interfaces": stale. ReTiCA now also has Meshtastic, MeshCore and RNode slots
   (`TransportEndpoint.swift:40-52`).
2. Citations are stale. `README.md:324` is now `:264`/`:622`. `reference-parity-checklist.md:614` is now
   `:680`. `reference-gap-analysis…:574` is now `:583`. "AutoInterface.py (688 lines)": it has 713 in
   1.6.0.
3. The port table attributes echo handling to the unicast plane. It is wrong: an echo is our own
   **multicast** looping back (§4.6.1). The unicast plane carries only reverse peering.
4. A3 says Network.framework "provides no way" to pin the interface or the local endpoint and to
   receive multicast. Overstated: `requiredInterface`, `requiredLocalEndpoint` and `NWConnectionGroup`
   exist. POSIX is still the recommendation, for parity (§5.3).
5. The A3 setsockopt sketch puts `SO_REUSEADDR`/`SO_REUSEPORT` everywhere. The data socket has
   **none** (§4.4).
6. A4 says the reference selects interfaces that are "up and running". It checks no flags at all. It
   adopts any NIC with an `fe80:` address, `utun*` on macOS included (§4.10.4).
7. A4 says "On iOS this leaves `en0` and `pdp_ip0`". It also leaves `utun*`, `ipsec*`, `bridge100` and
   others, and cellular should be ignored (§8.3).
8. A4 says the descoped string "must match byte-for-byte with a Python peer". True, but the receiver
   side is CPython `recvfrom` text with no scope, not the descope function. On Darwin 27 `getifaddrs`
   embeds nothing (§4.3).
9. B1 says the derivation works through `String(format:)` of `g[2i+3] + (g[2i+2] << 8)`. Only the
   **bytes** matter, and the literal Swift port overflows (§4.1, R10).
10. B1 omits the `final_init_done` gate: nothing is accepted for the first 1.92 s (§4.5.1).
11. B2 presents the echo watchdog as a carrier signal. In 1.6.0 it only logs; nothing reads
    `carrier_changed`. It cannot detect an access point that drops multicast either, because the echo
    is host loopback (§4.6.1, §4.7.4).
12. B2 says dedupe exists for "a peer reachable over several interfaces". More precisely: a remote with
    several NICs is **several peers**. Dedupe is parent-wide, keyed by SHA-256 of the raw datagram, and
    a hit does not refresh the peer (§4.8.3).
13. B3 says "IFAC size 16" belongs in the `.auto` profile. `InterfaceProfile` has no IFAC-size field.
    The size goes into `IFAC.init` (R9).
14. B4's ID scheme `auto:<addr>%<ifname>`. Recommend `auto:<ifname>/<addr>` to match the reference's
    `AutoInterfacePeer[ifname/addr]` (§5.2). Either works.
15. A1 says the multicast entitlement is unnecessary on macOS "outside the App Sandbox". The Mac app
    **is** sandboxed (`ReTiCAMsgr-macOS.entitlements:5-6`). The sandbox needs `network.client` and
    `network.server`, which it has. The multicast entitlement is not a macOS entitlement.
16. Missing from the note entirely: the same-host impossibility, and rnsd panicking on a data-port
    clash (§4.10). The note's own suggested step 4 ("validate against a running rnsd") cannot be done on
    one Mac.
