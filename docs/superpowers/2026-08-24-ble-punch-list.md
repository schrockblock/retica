# BLE punch list — ReTiCaMsgr over BLE to iOS and Raspberry Pi, with relay

> **2026-09-26 update:** the wire protocol changed. ReTiCA now speaks ble-reticulum v2.2
> (spec `docs/superpowers/specs/2026-09-26-ble-v22-gatt-driver-design.md`); items P1, P1a,
> P1b, P1c, P2, P3, P4 (the Python-fork work) are obsolete — the Pi runs stock ble-reticulum.
> S1, S2 and S6 are carried into the new adapter. A1–A4 and R1–R3 still apply. Live
> verification now follows `docs/superpowers/plans/2026-09-26-ble-v22-hardware-checklist.md`.

**Date:** 2026-08-24. **ReTiCA HEAD:** `cd347e4`. **Python fork HEAD:** `112fef0b`
(`~/development/python/Reticulum`, branch `master`, clean tree).

**Goal:** ReTiCaMsgr connects to other iOS devices AND Raspberry Pi devices over
BLE to send and RELAY messages. This document is the build-list toward that goal.

**How this was produced, and how much to trust it.** Four parallel review agents
(Swift BLE stack with probe licence; Python fork; wire-level comparison; app +
relay readiness) plus a read of the 2026-08-10 handoff and its updates. Items are
tagged **[probed]** (settled by an executed probe), **[read]** (verified by
opening the cited code), or **[reasoned]** (inferred, not executed). The four
headline claims (version split, app is TCP-only, `enableRelay` has no production
caller, no Bluetooth plist keys) were independently re-grepped by the controller
after the agents reported. Per this repo's standing rule: **relayed findings have
been wrong before — verify each item against the code before building on it.**
Numbering here is deliberately disjoint from the handoff's F-numbers: **P** =
Python fork, **A** = app, **S** = Swift library, **R** = relay, **V** = live
verification.

---

## 0. The critical path, in order

Nothing below is speculative polish; each item gates the goal or a milestone of it.

1. **A1 + A2 + A3** — wire BLE into the app at all (BLE slot + toggle, Bluetooth
   usage-description key, background modes). Nothing works without this.
2. **S1 + S2** — fix the iOS discovery/retry seam and add a driver disconnect
   verb + connect timeout. Without these, real-world BLE sessions degrade to
   permanently unreachable peers within minutes of ordinary churn.
3. **V1** — first live iOS↔iOS hardware run (the 2026-08-01 checklist, still
   entirely unchecked). Do this before Pi work: it validates the whole FCB/L2CAP
   mechanism the simulators and mocks cannot.
4. **P1** — port RBTP v2 to the Python fork (version 2 + HELLO + token dedup).
   Gates every iOS↔Pi packet. Do it before burning Pi bench time on v1 behavior
   that v2 will delete.
5. **P2** — fork: re-discovery/re-dial after a clean peer close. A Pi relay that
   never re-forms links is useless in practice.
6. **V2–V4** — Pi↔Pi hardware checklist, then iOS↔Pi bring-up, then the >391 B
   direct-over-link and propagation paths live.
7. **R1 + R2** — turn relay on (one `enableRelay` send behind a toggle;
   periodic announce for headless compositions) and run a three-node relay
   (V5), including a mixed BLE↔TCP hop.
8. **S3** — decide the backgrounding story (design decision, not just plumbing —
   see the overflow-area constraint).

---

## 1. Protocol interop — iOS↔Pi is impossible today

### P1 — the fork is RBTP v1; iOS speaks v2. Mutual clean refusal, zero packets. **[Critical] [read, ×3 agents]**

- Swift serves and accepts only version **2** (`BLEInterface.swift`
  `protocolVersion` / the version guard in `directoryRead` handling) and requires
  a HELLO ("RBT" + `0x02` + 16-byte token) as the first frame both directions,
  with a `helloTimeout` teardown. The fork serves and accepts only version **1**
  (`BLEInterface.py` `PROTOCOL_VERSION`), has **no HELLO anywhere** (grep: zero
  hits), and keeps the v1 lower-bdaddr `should_initiate` tie-break
  (`ble_support.py`).
- Live behavior: each side reads the other's Version characteristic, refuses,
  greylists. No hang — but also never a channel. Even with versions forced equal,
  the Pi feeds iOS's HELLO to RNS as junk and iOS tears down at the HELLO
  deadline. Defense-in-depth on the fork side is sound: "RB" parses as length
  21058 > 1196 → framing error → drop. **[read]**
- **All protocol changes land on the Python side** — the v1 bdaddr tie-break is
  uncomputable on Apple (CoreBluetooth exposes no BD addresses). This matches the
  plan already recorded in
  `docs/superpowers/specs/2026-08-01-ble-interface-swift-design.md` ("Linux
  interop … requires the Python fork to adopt the v2 changes").
- Concrete fork work: (a) serve/accept `0x02`; (b) send/require the 20-byte HELLO
  as first frame both directions with a timeout, before handing the channel to
  `BLEPeerInterface`; (c) delete the `should_initiate` gate — both sides
  initiate; dedup post-HELLO by token (cross-connect → lower-token initiator's
  channel survives; same-direction duplicate → new wins); (d) re-key peer
  identity/dedup on session token, NOT bdaddr — iOS resolvable private addresses
  rotate, so bdaddr-keyed identity sees one iPhone as a stream of new peers;
  (e) mirror `BLESupport.swift` exactly (`helloFrame`, `parseHello`, the dedup
  rules) — a byte-for-byte port target, and the existing
  `generate_ble_fixtures.py` cross-val harness should grow HELLO fixtures.

### P1a — update `docs/ble_interface_spec.md` to v2 **[High] [read]**

The spec is `Version: 1 / Status: Normative` and matches the fork; it does not
describe the iOS implementation at all (no HELLO, bdaddr tie-break, version 1).
Once P1 lands, the spec must document v2 (HELLO layout, both-initiate, token
dedup) or every future implementer inherits the divergence. Note: the Version
characteristic is one byte and single-valued — bumping to 2 cleanly cuts off
unupgraded v1 nodes by design.

### P1b — verify the L2CAP MTU floor live **[Medium] [reasoned]**

The fork sends each frame as one SDU up to 1198 B (`sendall`) and sets only its
*receive* MTU (`BT_RCVMTU` 1280). iOS cannot request a CoC MTU at all. A live
iOS↔Pi run must confirm the iOS receive MTU ≥ 1198; if it ever isn't, the Python
sender chunks its writes (both deframers already tolerate arbitrary chunking).
Cheap adjunct on the fork: `getsockopt(BT_SNDMTU)` after connect and assert it
fits a max frame, else every large frame is `EMSGSIZE` → teardown → greylist loop.

### P1c — version-mismatch greylist should be brief **[Low] [read]**

Spec §6.3.3 says a version-mismatch greylist entry "SHOULD be brief"; the fork
uses the same exponential backoff (5 s → 300 s) as failures. Against pre-upgrade
peers this compounds with iOS address rotation into constant re-probing. Separate
short fixed backoff for version mismatch.

---

## 2. App wiring — ReTiCaMsgr is TCP-only today

### A1 — the BLE endpoint slot is never constructed **[Critical] [read, ×2 agents + controller grep]**

`AppFeature.State.init` builds `LXMFServiceNode.State(identity:, endpoint:
TCPEndpoint.State(...))`; a repo-wide grep of app + core for
`BLE`/`Bluetooth`/`.ble` finds zero code hits. Fix shape: mirror the existing
`listenEnabled` listener toggle — an `@Shared(.appStorage("bleEnabled"))` toggle
that sets `state.node.client.endpoint.ble = BLEEndpoint.State(...)`; the
container's `.start` already starts every populated slot.

### A2 — `NSBluetoothAlwaysUsageDescription` is missing **[Critical] [read + controller grep]**

The app uses `GENERATE_INFOPLIST_FILE = YES`; the pbxproj contains no
`NSBluetooth` key. First `CBCentralManager` init after A1 would crash the app.
Add `INFOPLIST_KEY_NSBluetoothAlwaysUsageDescription` to both configurations.

### A3 — no Bluetooth background modes **[High] [read]**

No `UIBackgroundModes` in the pbxproj. Without `bluetooth-central` +
`bluetooth-peripheral`, the mesh dies the moment the app backgrounds — fatal for
a node that is supposed to carry other people's traffic. See S3 for the library
half and the hard platform constraint.

### A4 — the app's connection model is single-interface **[High] [read]**

Any `interfaceDisconnected` sets `connection = .disconnected`
(`AppFeature` transport handler), so one BLE peer dropping would mark the whole
app offline while TCP is healthy; `.foregrounded` skips the TCP re-dial whenever
`connection == .connected`, which a live BLE peer would cause; and
`DiagnosticsSnapshot` reads only `endpoint.tcpClient`. BLE `peerOnline`/
`peerOffline` are observable only via the `.ble` escape hatch
(`TransportEndpoint` re-emits them), which the app never matches — this is the
KNOWN LEAK recorded in the ble-interface memory, now with a consumer that needs
it. Fix shape: per-interface connection state (count/kind map), consume the
`.ble` hatch delegates, extend diagnostics to render BLE peers.

### A5 — no permission-denied UX **[Medium] [read]**

See S6: the library folds `unauthorized` into `waitingForAdapter` and retries
forever. The app needs a "Bluetooth permission denied — open Settings" surface
once the library can distinguish it.

---

## 3. Swift library gaps (ReTiCA + FCB)

### S1 — one dropped discovery permanently consumes a peer for the session **[High] [PROBED]**

The adapter dedups discoveries in `seenPeers` and re-emits `peerDiscovered` only
after `forget()` — which runs solely on central disconnect, `directoryFailed`,
or `channelFailed` (`FCBDriverAdapter`). The reducer's only outbound-establishment
entry is `peerDiscovered`, and it silently drops it while greylisted / at peer
cap / not yet `.online` (`BLEInterface` `peerDiscovered` guards). Sequence:
failure → adapter forgets → immediate rediscovery (ms) → reducer drops (greylist
≥ 5 s) → `seenPeers` repopulated → **no further `peerDiscovered` ever**. Probe
(real `FCBDriverAdapter`, stubbed FCB clients): after the one post-failure
rediscovery, two further advertisements emitted nothing in a 2 s window.
Affected: every directory/channel failure, HELLO timeout, churn strike, version
mismatch (i.e. every v1 Pi, constantly), and the startup race where the central
discovers before the peripheral finishes bring-up. Recovery only if the peer
initiates inbound, or on full BLE restart. Note `BLEInterfaceTests` hand-feed
repeated `peerDiscovered` events the production adapter will never deliver — the
seam is untested. Fix shape: make the dedup a cooldown (re-emit per peer every
N s), or add a `release(peer)` driver verb the reducer calls whenever it drops a
discovery, plus on greylist expiry.

### S2 — no driver disconnect verb; no connect timeout **[High] [read]**

`central.connect` has no timeout — `pendingConnect` awaits forever; the reducer's
15 s establish deadline abandons the peer but nothing cancels the in-flight
`readDirectory`, whose GATT connection may complete much later and then sits
open. The version-mismatch refusal likewise leaves the just-read GATT connection
open forever: the `BLEDriver` contract has no way to disconnect a peer without a
channel. iOS concurrent BLE connections are scarce. Minor variant: a second
`readDirectory` for the same peer overwrites `pendingConnect[id]`, leaking the
first continuation. Fix: add `disconnect(peer)` to `BLEDriver`; call it on
version mismatch and establish deadline; add a connect timeout in the adapter
(the fork has `CONNECT_TIMEOUT`; the Swift side has no equivalent).

### S3 — backgrounding is a total gap, and part of it is a platform wall **[High, and a design decision] [read + reasoned]**

No `CBCentralManagerOptionRestoreIdentifierKey`, no `willRestoreState`, no
restoration wiring anywhere in FCB (`CBMCentralManagerFactory.instance()` takes
no options; `Models/RestorationState.swift` is dead code). With A3's background
modes plus restore identifiers, iOS↔iOS can partially survive backgrounding
(iOS centrals can match overflow-area adverts). **Pi→backgrounded-iPhone cannot
work at all**: a backgrounded iOS peripheral advertises only in Apple's overflow
area, which BlueZ scanners cannot match — so Linux discovery of a backgrounded
iPhone is off the table regardless of code. The reachable target: backgrounded
iPhone as *central* (it can still connect to an advertising Pi), foreground
required for Pi→iPhone discovery. This needs a deliberate design pass, not just
plumbing; document the constraint in the spec's v2 section.

### S4 — write buffer is unbounded, no backpressure **[Medium] [read]**

`L2CAPChannelPump.outBuffer` grows without cap; `FCBDriverAdapter.send` is
fire-and-forget; nothing above sees drain state. At the BLE profile's 80 kbps, a
resource transfer or announce burst to a stalled peer accumulates memory
indefinitely and flushes stale traffic on recovery. Fix: cap `outBuffer` and
kill the channel on overflow (matches the drop-the-connection recovery model),
or surface buffer depth to pace resource windows. (The fork has the mirror-image
defect — see P4.)

### S5 — the "no-channel window" silent send drop **[Medium] [read; known, still present]**

`BLEInterface` clears peers synchronously on adapter loss/stop while
`peerOffline` propagates as an effect; `TransportEndpoint`'s `peerInterfaces`
lookup can still succeed during that one-action-hop window and the send dies
silently at the interface's `peers` guard. The endpoint-level
`sendFailed(.interfaceUnavailable)` covers only the other ordering.

### S6 — Bluetooth authorization is invisible **[Medium] [read]**

`.unavailable` (including `unauthorized`) → `waitingForAdapter` → 5 s→120 s
backoff forever; the reason string dies in the reducer; no delegate carries
status up through `BLEEndpoint`/`TransportEndpoint`. FCB exposes `authorization`
but the adapter never consults it. Fix: an `adapterUnavailable(reason:)`
delegate distinguishing `unauthorized` (stop retrying, surface to user — A5)
from `poweredOff` (keep waiting).

### S7 — greylist never evicts and never clears on success **[Medium] [read + controller grep]**

`BLEPeerGreylist.entries` grows for the session; `clear()` has zero callers. A
successful connection does not reset strikes, so the next failure escalates from
stale history unless 600 s of quiet passed. Small memory impact; the behavioral
half compounds S1. (The fork matches — never calls clear on success — but the
fork has working rediscovery; see P5 for its unbounded-growth half.)

### S8 — small items **[Low] [read]**

- `sendFailed(peer:reason:)` still consumed by nobody; its only reason
  (`.unframable`) is unreachable for Transport-emitted packets (MTU 500 ≪ 1196).
  Wire it up or delete it — as-is it reads like coverage. (Handoff F5.1's BLE
  corner.)
- Pre-HELLO channel count is uncapped (`channelOpened` gates on established
  `peers`, not `channels`); each pre-HELLO channel costs a frame buffer and a
  10 s timer. Bounded in practice by iOS's own connection limits.

---

## 4. Python fork robustness (beyond P1)

### P2 — no re-dial after a peer link closes **[High] [reasoned]**

`peer_closed` never notifies the driver; `_consider_device` dedups on
`_seen_peers` forever; discard happens only on `InterfacesRemoved` or
read/connect *failure*. After a clean EOF (peer walked away/rebooted), the
initiator side never re-fires `on_peer_discovered` — with discovery running,
BlueZ typically won't remove the device object — so the lower-address side may
never reconnect. Same root cause makes greylist-expiry and cap-freed peers
unreachable: `peer_discovered`'s early returns leave the address permanently
consumed with no retry timer. Fix: a driver `forget_peer(bdaddr)` hook called
from `peer_closed`/refusals, plus a periodic re-offer sweep. This is the fork's
structural twin of S1 — both sides currently fail the "walk away and come back"
checklist item, and neither side's mocks can express it.

### P3 — camper timebox can kill our own outbound link **[Medium] [reasoned]**

`_initiated` covers the peer only during `_read_directory`; the `Connected=True`
signal is processed on another thread. If it lands after the `finally` discard,
the peer becomes a "camper" and 10 s later the driver calls `Device1.Disconnect`
on the device carrying our live CoC (`_drop_camper_for` runs only for inbound
channels). Fix: extend `_initiated` (or drop the camper) through `connect()` and
successful outbound channel creation.

### P4 — blocking `sendall`, no write timeout or buffer cap **[Medium] [reasoned]**

A stalled peer (credit exhaustion, radio fade without disconnect) blocks
`process_outgoing` indefinitely inside `write_lock`, on the thread RNS Transport
calls from — one dead-air peer stalls outbound processing that should reach
other peers. Fix: send timeout + teardown, or a bounded per-peer write queue
with a writer thread. (Mirror of S4.)

### P5 — unbounded greylist + `_seen_peers` growth **[Low] [read]**

`greylist.entries` is never pruned and `clear()` is never called; with iOS
address rotation every failed rotated address leaves a permanent dict entry on a
long-running Pi. Expire entries past `strike_forget + max_delay`; clear on
successful long-lived connections.

### P6 — smaller fork items **[Low] [reasoned]**

- Outbound CoC never sets `BT_SECURITY` (`connect()` has no `_set_security`);
  arguably spec-conformant (paired mode enforces at accept), irrelevant to iOS
  (open mode), but an outbound dial from a paired-mode node runs at
  SECURITY_LOW if the remote doesn't enforce.
- `online = True` is set before `driver.start()` succeeds (both initial and
  retry paths); `peer_discovered`/`inbound_channel` gate on `online` and can
  race into a half-started driver.
- In-flight outbound + inbound accepts can transiently exceed `max_peers`
  (`pending_peers` not counted at the accept site). Cosmetic at cap 7.

---

## 5. Relay enablement

### R1 — relaying is dead code: `enableRelay` has no production caller **[Critical for the relay goal] [read + controller grep]**

Every relay branch in `Transport` gates on `transportIdentity != nil`, set only
via `TransportEndpoint.enableRelay` — which only tests invoke. Likewise
`recursivePathRequests` defaults false with no production setter. Minimal
enablement: one `.node(.client(.endpoint(.enableRelay(nodeIdentity))))` send
from `AppFeature` (next to `.registerDelivery`), behind a "relay mode" settings
toggle, optionally with `.transport(.setRecursivePathRequests(true))` for
cold-path discovery. **Note:** F13 (relay link shadow) was closed but is
*latent until relay mode is enabled* — enabling relay is the moment its fix
becomes load-bearing, and the accepted no-cap on `linkTable` (matching stock
RNS) becomes live exposure. Budget a relay-mode review pass when this flips on.

### R2 — nothing announces to a newly connected peer in library-only compositions **[Medium] [read]**

`Transport.interfaceConnected` only records the profile — no announce, no
`announceCache` replay, and **no periodic re-announce exists anywhere** (no
timer drives `LXMFNode`/`PNNode`/`LXMFServiceNode` announces). The app
compensates: `AppFeature` re-sends `.registerDelivery` (which announces on ALL
interfaces) on every `.transport(.interfaceConnected)`, and BLE `peerOnline`
maps to `interfaceConnected` per peer — so the app-hosted node introduces
itself to each new BLE peer. But a headless Pi-side or library-only composition
stays silent until manually announced, and a new peer learns nothing about
*third parties* until they re-announce or it path-requests (answered from
`announceCache` only when relay is on). Fix: a periodic announce timer
(RNS-style interval) in the LXMF layer, or an announce-on-connect hook in
`TransportEndpoint`.

### R3 — relay fan-out over BLE: structurally sound, unproven live **[read; verify at V5]**

Verified by reading, driver-agnostic throughout: announce re-broadcast excludes
only the arrival interface and fans to every other eligible `InterfaceID`
(per-BLE-peer IDs included, `.full` mode, 80 kbps pacing per interface); egress
routing resolves `tcpClient` → `tcpServer` → `ble.peerInterfaces` →
`ble.send(peer:)`; HEADER_2 link transit records arrival/next-hop interfaces as
bare `InterfaceID`s so BLE↔BLE and BLE↔TCP transit are the same code path;
path requests answer on the arrival interface and recursive re-broadcast
excludes it. All of it is unit/cross-val tested over TCP-shaped fixtures only —
no live multi-radio relay run exists (V5).

---

## 6. Live verification — nothing has ever run on real radios

**Both hardware checklists are entirely unchecked:** the iOS one
(`docs/superpowers/plans/2026-08-01-ble-hardware-checklist.md`) and the fork's
(`docs/superpowers/plans/2026-07-25-ble-hardware-checklist.md` in the Python
repo — its ctypes L2CAP constants, sockaddr layout, PSM assignment, D-Bus
registration, camper timebox, adapter-loss path: all pending; its 52 tests are
mock/off-Linux only and all pass on macOS **[probed]**). The fork has never
opened a real L2CAP CoC. On the iOS side, nothing in-repo exercises live
CoreBluetooth.

What is proven vs not, over BLE, at today's HEAD **[read]**:

| Path | Status |
|---|---|
| Framing/greylist arithmetic vs fork | byte-identical, cross-val fixtures |
| Opportunistic LXMF in/out over BLE (stubbed driver, real reducers) | proven at LXMFNode level |
| Link handshake, path-stale gating, re-homing across peer reconnect | proven (probe-grade tests) |
| Two simultaneous BLE peers, per-peer transmit routing | proven (characterization test) |
| Direct-over-link LXMF (>391 B → resource) end-to-end over a byte channel | **unproven** — and every LXMF message >391 B silently takes this path |
| Propagation sync over BLE | **unproven** |
| Any relay hop involving BLE | **unproven** |
| Any live 2-device run (either platform) | **never happened** |

Ordered milestones:

- **V1** — iOS↔iOS live bring-up: run the 2026-08-01 checklist (needs A1/A2
  first; a scratch harness app is acceptable if the msgr wiring isn't ready).
  Record throughput/latency into the spec's Reference Values.
- **V2** — Pi↔Pi live: run the fork checklist *after* P1 lands (don't bench v1
  behavior v2 deletes). Includes rfkill/adapter-loss, walk-away (P2's test),
  three-node relay, benchmark harness.
- **V3** — iOS↔Pi bring-up: version 2 both sides, HELLO settles, one surviving
  channel, opportunistic LXMF both directions. Verify P1b's MTU floor here.
- **V4** — iOS↔Pi >391 B message (direct-over-link resource transfer) and a
  propagation-node sync over BLE.
- **V5** — three-node relay with a BLE hop: iPhone↔Pi(relay)↔iPhone and
  Pi↔iPhone(relay, R1 enabled)↔TCP — the second exercises the BLE↔TCP
  cross-driver path live and the F13 fix under real traffic.

---

## 7. Handoff residuals that ride along (2026-08-10 doc, current statuses)

Not BLE work items per se, but they shape BLE behavior and should be re-read by
whoever takes the slices above:

- **F9** (open, accepted residual): no per-packet replay rejection anywhere in
  the link path — one captured ciphertext re-homes a link from any interface.
  Multi-peer BLE widens the attacker surface (any connected peer can replay).
- **F10** (open, accepted residual): the local-disconnect re-home grant is
  spendable by *any* interface — explicitly reachable by a second connected BLE
  peer that observed a cleartext linkID. Deliberate trade (the grant is what
  lets links survive BLE reconnects); revisit only with F9.
- **F5.1** (open): `sendFailed` is unconsumable by design — a delegate redesign,
  of which S8's BLE `sendFailed` is one corner.
- **F16** (accepted won't-fix): any link-addressed packet re-arms inactivity;
  RNS-faithful; bounded by F11's eviction policy.
- **F17/F18** (open, low): concurrent-receiver segment collision + advertisement
  field validation. F17's duplication precondition (retry timer duplicating slow
  resource sends) is *more* likely over BLE's 80 kbps than over TCP — worth
  re-ranking once V4 exists.
- **App, unexplained (2026-08-21 handoff §4):** outbound link to a backgrounded
  Sideband times out (Doze hypothesis, untested); empty-content messages
  (control-field hypothesis, diagnostic logging live). Both will muddy V3/V4
  debugging if forgotten.

---

## 8. Checked and fine (don't re-litigate)

- `FCBDriverAdapter.begin()` self-resets a prior session (the old adapter-retry
  leak is FIXED, pinned by `adapterRetryStartWithoutStopResetsPriorSession`).
- Wire primitives match the fork byte-for-byte except version/HELLO: service and
  characteristic UUIDs, PSM little-endian uint16 both sides, framing (2 B BE,
  1..1196, drop-on-malformed), greylist arithmetic (inclusive boundary), peer
  cap 7, churn threshold 10 s, adapter backoff 5→120 s, `HW_MTU` 1196 /
  bitrate 80 000 both sides.
- HELLO/dedup on the Swift side: echo rejection, symmetric cross-connect
  resolution, same-direction replace without an offline blip — tested.
- Peer reconnect staleness: new token → new `InterfaceID`; links re-home on next
  inbound link packet; stale learned paths fail fast as `.pathStale`;
  `peerInterfaces` cannot leak (cleared on `peerOffline`; `.stop`/`.unavailable`
  emit it for every established peer).
- Shared maintenance loop arms/stops off the shared interface count (the
  multi-driver seam fix) — BLE peers counted correctly.
- The app announces on every `interfaceConnected` (per BLE peer once A1 lands).
- `LXMFServiceNode`/`PNNode` are endpoint-agnostic with explicit BLE inits —
  propagation-node serving over BLE is composition-ready (V4 proves it live).
- Relay core (announce hold/jitter/pacing, mode gating, HEADER_2 forwarding,
  path-request answering, loop guards) is `InterfaceID`-keyed and
  driver-agnostic throughout (R3).
- Fork: RNS config registration + documented config block; UUID-filtered
  discovery; bounded frame buffer; the three-connection D-Bus topology's
  concurrency reasoning holds; adapter-loss recovery exists and is
  interruptible.
