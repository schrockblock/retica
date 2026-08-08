# RNS Interface Conformance — Design

**Status:** approved 2026-08-04; re-verified against HEAD `594f046` on
2026-08-08 after the propagation-node work (PNNode / LXMFServiceNode /
delivery-link proving) landed. `Transport.swift` was untouched by that work,
so all `Transport.swift` citations remain exact; endpoint send-site and
silent-drop line numbers were refreshed; the 108-site ripple count re-measured
identical (the ~1500 new test lines added zero sites).
**Supersedes nothing.** Follows sub-project A (LinkPlane) and sub-project B (TransportEndpoint / LXMF-over-BLE).

## Goal

Make ReTiCA's transports first-class RNS interfaces: carry the per-interface
metadata reference Reticulum requires (`name`, `bitrate`, `mode`, `HW_MTU`),
and make `Transport` actually consume it — mode-gated announce relay,
bitrate-paced announce cap, ingress control, and eventually IFAC.

## Why — what the surveys found

Two read-only surveys (ReTiCA parity inventory; reference RNS interface
contract) established the following. Every claim below is cited; these are
facts, not assumptions.

**This is not a BLE gap.** BLE is already at parity with ReTiCA's own TCP
path. What is missing is an interface *contract*, and it is missing
stack-wide:

| Concept | Reference RNS | ReTiCA today |
|---|---|---|
| `bitrate` | `Interface.py:104` (default 62500) | **absent repo-wide** |
| `mode` | `Interface.py:45-51` (7 modes) | **absent repo-wide** |
| `HW_MTU` | `Interface.py:105` | **absent repo-wide** |
| IFAC | `Transport.py:1068-1104`, `:1442-1486` | **absent repo-wide** |
| per-interface stats | `Interface.py:98-99` (`rxb`/`txb`) | **absent repo-wide** |
| announce ingress control | `Interface.py:152-255` | **absent repo-wide** |
| announce egress cap | `Transport.py:1277-1321` | **absent repo-wide** |

`InterfaceID` is a bare `String` wrapper (`Sources/ReTiCATransport/InterfaceID.swift:1-8`)
and `Transport.State.interfaces` is a `Set<InterfaceID>`
(`Sources/ReTiCATransport/Transport.swift:30`). `TCPClientInterface` and
`BLEInterface` are unrelated reducers that happen to share a
`packetReceived`/`send` shape; nothing carries metadata between them and
`Transport`.

**Consequence — ReTiCA is currently a bad network citizen.** `Transport`
re-broadcasts every announce to every interface except the arrival one
(`Transport.swift:270-271`, `:428-430`) with no mode gate and no bandwidth
cap. Reference RNS blocks relay outright on `MODE_ACCESS_POINT`, and on
`MODE_ROAMING` when the announce arrived from another roaming or boundary
peer (`Transport.py:1224-1270`), and paces what remains at
`packet_bits / (bitrate × announce_cap)` with a 2% default
(`Transport.py:1282-1285`). A phone on BLE *is* the roaming case. With BLE
registering one interface per peer (up to `BLEInterface.defaultMaxPeers = 7`),
ReTiCA today amplifies rather than damps.

The pacing spread is the point: a 150-byte announce waits **0.75 s on BLE**
(80 kbps) but **0.006 s on TCP** (10 Mbps). ReTiCA waits neither.

**Bitrate matters less for timing than expected.** `first_hop_timeout` is
`MTU × 8 / bitrate + 6 s` (`Transport.py:2789-2791`), so at BLE's 80 kbps
that is 6.05 s versus TCP's ~6.0 s — negligible at MTU 500. ReTiCA's
hardcoded link timings (15 s establishment, 30 s keepalive, 60 s stale —
`LinkSession.swift:62,67`) are defensible and are **not** in scope. Bitrate's
real teeth are announce pacing and the interface priority sort
(`Transport.py:462`).

**The 1196-byte MTU win is available but is not a conformance gap.** The
Python fork sets `HW_MTU = 1196` yet leaves `FIXED_MTU = False`, so link-MTU
discovery is disabled for BLE upstream too (`Transport.py:2770`). ReTiCA's
hardcoded MTU-500 `Link.signallingBytes` matches reference behaviour.
Enabling negotiation later is a ~2.4× Resource throughput gain
(SDU 1179 vs 483) — an optimisation, tracked as a non-goal here.

## The decisive design steer: mode is configuration, not interface

Every shipped reference interface hardcodes `MODE_FULL` in its `__init__` —
TCP, UDP, Auto, Local, I2P, BLE — and `interface_post_init` then
unconditionally overwrites it from config (`Reticulum.py:736, 911`). Zero
shipped interfaces default to anything else. `gravity` is identical: always
`0` in code, non-zero only via config (`Reticulum.py:772-773`).

Therefore **the profile is supplied by the endpoint at registration time, not
declared inside the interface reducer.** `BLEInterface` and
`TCPClientInterface` stay mechanism-only — the same seam discipline that made
`FCBDriverAdapter` work. A phone declares itself roaming without forking the
BLE interface.

## Shared model

```swift
public enum InterfaceMode: UInt8, Equatable, Sendable {
    case full          = 0x01
    case pointToPoint  = 0x02
    case accessPoint   = 0x03
    case roaming       = 0x04
    case boundary      = 0x05
    case gateway       = 0x06
    case interfaceInternal = 0x07   // `internal` is a Swift keyword
}

public struct InterfaceProfile: Equatable, Sendable {
    public var name: String
    public var bitrate: Int          // bits/sec — 0 is illegal, not "unknown"
    public var mode: InterfaceMode
    public var hwMTU: Int?
    public var announceCap: Double   // FRACTION (0.02), never percent
}
```

Numeric mode values are copied verbatim from `Interface.py:45-51` so the enum
can carry across a wire format later without a translation table.

**Declared values, copied from reference:**

| Preset | bitrate | HW_MTU | mode | source |
|---|---|---|---|---|
| `.tcp` | 10_000_000 | 262144 | `.full` | `TCPInterface.py:76, 42, 131` |
| `.ble` | 80_000 | 1196 | `.full` | `BLEInterface.py:40, 41, 83` |
| `.default` | 62_500 | nil | `.full` | `Interface.py:104-105` |

`announceCap` default `0.02`, from `Reticulum.ANNOUNCE_CAP = 2` percent
converted once at `Reticulum.py:835`.

**Two reference behaviours we deliberately do NOT copy:**

1. **The `announce_cap` percent/fraction bug.** `Interface.py:322-323` lazily
   stores the raw integer `2` where every other path stores `0.02` — a 100×
   pacing error on any interface reaching that fallback. We store the
   fraction once, in one place, and never accept a percent.
2. **Silent defaults for a missing `bitrate`.** Reference leaves it unset and
   then hard-blocks all announce relay at `Transport.py:1282`
   (`if interface.bitrate != None and interface.bitrate != 0`) — a silent
   network-wide failure. `InterfaceProfile` requires an explicit non-zero
   bitrate; zero is a programmer error, not a state.

## Roadmap

Five sub-projects, each independently shippable, testable, and reviewable.
Each gets its own implementation plan; C2–C5 get their own specs when reached.

| | Scope | Risk |
|---|---|---|
| **C1** | Profile seam + mode-based path expiry | Low |
| **C2** | Mode-gated announce relay | Medium — ~30 announce tests re-pointed |
| **C3** | Bitrate-paced announce cap + hop-ordered queue | Medium — new per-interface timers |
| **C4** | Ingress control (burst detect + held announces) | Low — additive |
| **C5** | IFAC | High — wire-level, needs cross-validation |

Ordering decision (user, 2026-08-04): IFAC stays last. It is the only item
gating whether ReTiCA can join a network *at all*; the others govern whether
it behaves *well* on one. With no specific network to join, correctness of
behaviour comes first.

---

## C1 — Interface profile seam (specified in full)

### State and action changes

`Transport.State.interfaces` becomes `[InterfaceID: InterfaceProfile]`
(`Transport.swift:30`).

`Transport.Action.interfaceConnected(InterfaceID)` becomes
`interfaceConnected(InterfaceID, InterfaceProfile)` (`Transport.swift:90`).
`interfaceDisconnected(InterfaceID)` is unchanged (`:91`).

Six read sites migrate from `Set` to `.keys`, each mechanically:

| site | today | becomes |
|---|---|---|
| `Transport.swift:147` | `state.interfaces.insert(id)` | `state.interfaces[id] = profile` |
| `:151` | `.remove(id)` | `state.interfaces[id] = nil` |
| `:270` | `.contains(where:)` | `.keys.contains(where:)` |
| `:356` | `.filter { }` | `.keys.filter { }` |
| `:428-429` | `.filter { }` | `.keys.filter { }` |
| `:481`, `:494` | `.map { }` | `.keys.map { }` |

### Who supplies the profile

`TCPEndpoint.State` and `BLEEndpoint.State` each gain a
`public var profile: InterfaceProfile`, defaulted to `.tcp` / `.ble` in
their inits. The send sites become:

- `TCPEndpoint.swift:112` — `.interfaceConnected(id, state.profile)`
- `BLEEndpoint.swift:121` — `.interfaceConnected(id, state.profile)`

**Downstream consumers (verified 2026-08-08):** `PNNode` composes
`TCPEndpoint` directly (`PNNode.swift:14, 65`) and `LXMFServiceNode` has
three inits mirroring `LXMFNode`'s (`LXMFServiceNode.swift:39-56`). Both are
untouched by C1: because the profile defaults inside the endpoint `State`
inits, every existing construction site inherits it transitively. Neither
composition's tests reference `interfaceConnected` at all.

BLE registers one interface per peer, all sharing the endpoint's profile.
Per-peer profile variation (e.g. a negotiated per-link bitrate) is a non-goal;
`BLEHello` carries no such field and inventing one would diverge from RBTP v2.

### Behaviour change: mode-based path expiry

C1 is not allowed to be a decorative struct. It ships one behaviour that only
works if the metadata is genuinely wired: path expiry varies by the mode of
the interface a path was learned on (`Transport.py:787-792`).

| mode | expiry | reference constant |
|---|---|---|
| `.accessPoint` | 86_400 s (1 day) | `AP_PATH_TIME` |
| `.roaming` | 21_600 s (6 h) | `ROAMING_PATH_TIME` |
| all others | 604_800 s (7 days) | `PATHFINDER_E` |

ReTiCA's 7-day constant is `Transport.pathExpiry` (`Transport.swift:504`),
applied in exactly one place — the `maintenanceTick` sweep at
`Transport.swift:408-415`:

```swift
for (dest, entry) in state.learned
where now.timeIntervalSince(entry.learnedAt) > Transport.pathExpiry {
    state.learned[dest] = nil
    state.announceBlobs[dest] = nil          // blob GC piggybacks on path expiry
    state.announceCache[dest] = nil          // cached announce GC piggybacks too
}
```

`LearnedDestination` already carries `interfaceID` (set at
`Transport.swift:250-263`), so the change is to make the threshold a function
of `state.interfaces[entry.interfaceID]?.mode` instead of a constant.

**Intended second-order effect:** because blob and announce-cache GC
piggyback on this sweep (`:413-414`), access-point and roaming paths will also
shed their dedup rings and cached announce payloads sooner. This is correct
and matches reference, where announce-table expiry branches on the same three
modes (`Transport.py:1934-1939`).

A path whose interface has since disconnected has no profile to consult; it
falls back to the 7-day default rather than expiring early. This is a
deliberate choice — expiring early on disconnect would silently drop paths
every time a BLE peer cycles.

### Test strategy and the measured ripple

108 sites reference the two actions across 9 test files. **Most are
payload-agnostic** and need no edit: `TCPEndpointTests` and the BLE
`bringPeerOnline` helpers use `store.receive(\.transport.interfaceConnected)`
(key-path, matches any associated value) or
`if case .transport(.interfaceConnected) = $0` (case-only predicate).

Real edits:

- ~56 *construction* sites (`store.send(.interfaceConnected(...))`), chiefly
  `TransportTests.swift` (52) and `RelayCrossValidationTests.swift` (2).
- ~10 state assertions of the form `$0.interfaces = [InterfaceID("i1")]`,
  which become `[InterfaceID("i1"): .default]`.

The 56 construction sites collapse to **zero churn** with a test-target-only
shim:

```swift
// Tests only. Production must pass a profile explicitly.
extension Transport.Action {
    static func interfaceConnected(_ id: InterfaceID) -> Self {
        .interfaceConnected(id, .default)
    }
}
```

A static func whose name matches a two-parameter case resolves the
one-argument call sites. Keeping it in the test target — not production —
means production code cannot silently skip declaring a profile.

New tests: profile round-trips into state on connect and clears on
disconnect; a path learned on an `.accessPoint` interface expires at 1 day; on
`.roaming` at 6 h; on `.full` at 7 days; a path whose interface has
disconnected uses the 7-day fallback.

### C1 non-goals

No relay behaviour change (that is C2). No pacing (C3). No `rxb`/`txb`
counters. No `gravity`. No IFAC fields on the profile yet — C5 adds them
rather than shipping unused ones now.

---

## C2 — Mode-gated announce relay (scoped)

Gates go in exactly two places the survey pinned: `Transport.swift:270` (the
"is there another interface" gate, which becomes "is there another interface
*that may relay*") and `:428-430` (the `announceRetransmitDue` fan-out).

The table, from `Transport.py:1224-1270`:

- `.accessPoint` — never relays a received announce; originates only.
- `.roaming` — blocks when the announce arrived on a `.roaming` or
  `.boundary` interface.
- `.boundary` — blocks when the announce arrived on a `.roaming` interface.
- `.full`, `.pointToPoint`, `.gateway` — relay permitted.
- `.interfaceInternal` — deferred to C2's own spec; its rule depends on
  `announces_to_internal`, which has no ReTiCA analogue yet.

**Recorded decision — accept the test churn.** ReTiCA has ~30 tests tightly
focused on announce relay that assert today's unconditional fan-out
(`relayRebroadcastsAnnounceWithHeader2AndOurTransportId`,
`announceFansOutToAllInterfaces`, `leafDoesNotRebroadcast`, …). Because C1
defaults every profile to `.full`, all 30 stay green through C2 — and that
greenness would be *meaningless*, since it only reflects defaults chosen to
preserve old behaviour. C2 must deliberately re-point them: keep the `.full`
cases, and add mode-specific cases that fail under unconditional fan-out.
Green-by-default is treated as a review defect in C2, not a success.

## C3 — Bitrate-paced announce cap (scoped)

`wait = packet_bits / (bitrate × announceCap)`, tracked per interface as an
`allowedAt` timestamp, with over-cap announces queued and drained
hop-count-ordered (`Transport.py:1277-1321`, `Interface.py:322-345`).

Wrinkle to design against: `Transport` has exactly two cancel IDs today
(`announceRetransmit(Data)`, `maintenance` — `Transport.swift:120`). Pacing
needs a per-interface scheduled drain, so seven BLE peers means seven
concurrent timers. Model it on the existing per-destination
`announceRetransmit` pattern, which already proves that shape, with
`CancelID.interfaceDrain(InterfaceID)` started on connect and cancelled on
disconnect (mirroring `startMaintenance`/`stopMaintenance`).

## C4 — Ingress control (scoped)

Burst detection over a rolling announce-arrival deque, held announces
released one at a time as the rate subsides (`Interface.py:152-255`;
`MAX_HELD_ANNOUNCES = 256`, burst threshold 10 Hz, hold 15 s, release
interval 5 s). Additive and defensive; matters most on BLE fan-out.

## C5 — IFAC (scoped)

**STATUS: BLOCKED (2026-08-08) — not implementable on CryptoKit. Do not start
this slice without first resolving the crypto dependency below.**

Truncated Ed25519 signature plus HKDF payload masking behind header flag
`0x80` (`Transport.py:1068-1104` outbound, `:1442-1486` inbound). Wire-level:
a node without IFAC is dropped by an IFAC network and vice versa. Requires
cross-validation fixtures generated by genuinely driving reference RNS —
never hand-rolled — per the project's standing rule. `ifac_size` default 16
(8 for RNode).

### Why it is blocked

IFAC is a **keyed MAC built out of deterministic signing**. Both peers derive
the same `ifac_identity` from the shared netname/netkey
(`Reticulum.py:959-973`: HKDF-64 over `full_hash(ifac_origin)` salted with
`IFAC_SALT`, then `Identity.from_bytes`). The sender computes
`ifac = ifac_identity.sign(raw)[-ifac_size:]` (`Transport.py:1073`); the
receiver **recomputes** `expected_ifac = ifac_identity.sign(new_raw)[-ifac_size:]`
and compares (`Transport.py:1469-1473`). Correctness therefore requires that
signing the same bytes with the same key yields the same signature bytes.

ReTiCA signs via CryptoKit `Curve25519.Signing`, which is **hedged
(randomized)** — RFC 8032 permits randomized nonce derivation and Apple uses
it for side-channel resistance. Empirically verified 2026-08-08: the same key
signing the same message twice produced signature tails `0d06a5f26eb4ca41…`
and `b00f08b3217bcf83…`. See [[ed25519-hedged-nondeterministic]].

Consequence: the truncated-signature MAC cannot be reproduced — **not merely
against reference RNS, but against ourselves**. A ReTiCA node could not verify
its own outbound IFAC. This is not a wire-format subtlety that careful
transcription can solve; it is a missing primitive.

Note the asymmetry with every prior slice: elsewhere, hedged signatures are
harmless because signatures are *validated* rather than byte-compared, and
relayed announces are re-emitted verbatim. IFAC is the one construction that
needs byte-reproducible signing, because it truncates a signature to 16 bytes
— too short to verify, only to compare.

### What would unblock it

A deterministic RFC-8032 Ed25519 signing path (SHA-512 nonce derivation plus
Curve25519 scalar arithmetic), either vendored from an audited implementation
or supplied by a non-CryptoKit backend, cross-validated against RFC 8032
test vectors *before* any IFAC work begins. swift-crypto does not help on
Apple platforms — it shims to CryptoKit. Hand-rolling curve arithmetic is
explicitly out of scope: an error there is a silent security failure rather
than a failing test.

Until then C5 stays closed, and ReTiCA cannot join an IFAC-protected network
on any transport. Everything C1–C4 delivered is unaffected.

## Testing strategy

Unchanged from the rest of the project, and binding:

- Mutation discipline on every task: tests pass → mutate production in one
  batch → confirm the expected tests fail → revert → confirm pass. A mutation
  that fails to break a test means the test is not testing what it claims.
  Mutations must be chosen so they do not mask one another — a batched
  mutation where one disables startup and hides the other produces no
  evidence (learned in sub-project B).
- Cross-validation fixtures must drive real RNS code paths, not reproduce
  ReTiCA's own logic.
- TCA `TestStore`s default to `.off` exhaustivity asserting outcomes; a test
  that cannot fail is a defect regardless of what it asserts.

## Out of scope for this whole roadmap

- Link/resource timing derived from bitrate — ReTiCA's hardcoded values are
  defensible and changing them is unrelated risk.
- Link-MTU negotiation / `FIXED_MTU` (the 1196-byte Resource win) — reference
  BLE does not enable it either.
- `rxb`/`txb` stats and an `rnstatus` analogue.
- `gravity` path-priority weighting.
- The interface priority sort (`Transport.py:462`) — meaningful only once a
  node runs more than one transport at a time.
- A mixed TCP+BLE node. `Transport` already supports it (`Set<InterfaceID>`,
  and BLE already registers N interfaces); the blocker is that
  `TransportEndpoint.State` is a two-case enum. Separate sub-project.
- BLE-specific residue carried from sub-project B: link re-homing when a peer
  reconnects under a new token, `peerOffline` not proactively closing links,
  the silent drops at `BLEEndpoint.swift:142` and `:199`, and the
  >391-byte direct path being unproven over BLE.
- Unified `transportOnline`/`transportOffline` delegates on
  `TransportEndpoint` (the known connectivity leak from sub-project B).
- Linux BLE interop: the Python fork is `PROTOCOL_VERSION = 1`
  (`BLEInterface.py:42`) while ReTiCA serves v2, so BLE interop needs the
  fork to adopt v2 + HELLO first.
