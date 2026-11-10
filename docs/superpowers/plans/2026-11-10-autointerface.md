# AutoInterface Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ReTiCA peers with reference Reticulum nodes on the local network with zero configuration (RNS 1.6.0 AutoInterface), and ReTiCAMsgr turns it on by default on macOS and, once Apple grants the multicast entitlement, on iOS.

**Architecture:** Pure wire functions (group address, token, descoping, formatting) cross-validated against the real reference class; a POSIX socket driver dependency (actor + generation counter, like `TCPListener`); an `AutoInterface` reducer holding the mechanism; an `AutoEndpoint` slot in `TransportEndpoint` that registers one Transport interface per discovered peer (the BLE / TCP-server 1:N shape); app toggle and lifecycle wiring.

**Tech Stack:** Swift 6, TCA, Swift Testing, Darwin sockets; reference RNS 1.6.0 in `/Users/ell/opt/anaconda3/envs/rns-latest`.

**Spec:** `docs/superpowers/specs/2026-11-10-autointerface.md` — binding. Section numbers below (§) refer to it. `AUTOINTERFACE.md` is superseded (spec §10).

## Global Constraints

- Every constant in spec §2 verbatim; config knobs and defaults as spec §3; wire behaviour as spec §4 (group bytes built directly, §4.1 / R10; token = SHA-256(group_id ‖ utf8(descoped link-local)); datagram = exactly one raw RNS packet; data socket has NO reuse options).
- Deliberate divergences D1-D5 (spec §5.6) and the ReTiCA eligibility addition §5.5.5 are rulings, not open questions. Peer cap 64 (R4). IFAC size 16 passed explicitly (R9).
- Interface IDs `auto:<nic>/<addr>` (§5.2); peers keyed by address only (§4.6.2). No parent interface is registered with Transport (§5.7).
- Fixtures are generated from `rns-latest` by a committed generator that constructs the REAL `AutoInterface` class (§7.1), run with `python -I`.
- Shared constraints file for implementers: the SDD workspace's `constraints.md` (one shell command per call, no inline scripts, `/tmp/ReTiCA/`, three-step mutation verification, commit to main, trailers at column 0).
- The app (`/Users/ell/development/ios/apps/ReTiCAMsgr`) builds against this tree by path: a public-type change must be followed by the app change in the same task or the next.

## Review Focus

1. Our own multicast echo never creates a peer (§4.6.1), including an echo that arrives on a different NIC than the one whose address it carries.
2. A datagram arriving before 1.92 s is dropped, and a deduped data datagram does not refresh a peer (§4.5.1, §4.8.3).
3. Stop then late socket events: nothing surfaces after `.stop` (generation counter), and a stop racing a start leaves no running sockets (`DriverEpoch`).
4. Maintenance follows the SHARED interface count: the last auto peer leaving while a TCP client is up must not stop maintenance (multi-interface lesson).
5. Data port already in use on this Mac (a local rnsd / NomadNet — one is running on the dev Mac now) fails that NIC only and surfaces `.dataPortInUse`, never crashes or hangs the app's connection state.

---

### Task 1: Wire functions, config and reference fixtures

**Files:** Create `Sources/ReTiCAInterfaces/AutoInterface/AutoInterfaceWire.swift`, `.../AutoInterfaceConfig.swift`; `Tests/ReTiCAInterfacesTests/Vectors/generate_autointerface_fixtures.py` + `autointerface_fixtures.json`; `Tests/ReTiCAInterfacesTests/AutoInterfaceCrossValidationTests.swift`. Check how other targets load JSON fixtures (Package.swift resources) and follow it.

**Interfaces (produces):** `AutoInterfaceWire.groupAddress(groupID: Data, scope: AutoInterfaceConfig.Scope, type: AutoInterfaceConfig.AddressType) -> [UInt8]` (16 bytes); `discoveryToken(groupID: Data, linkLocal: String) -> Data` (32 bytes); `descope(_ address: String) -> String`; `formatIPv6(_ bytes: [UInt8]) -> String` (`inet_ntop`); `AutoInterfaceWire` constants per §2. `AutoInterfaceConfig` per §5.2 (`groupID`, `scope`, `addressType`, `discoveryPort`, `dataPort`, `devices`, `ignoredDevices`, `peerCap = 64`) and `func isEligible(nicName: String) -> Bool` implementing §5.5 rules 1-5 in order.

- [ ] Generator per §7.1 items 1-4 (real `AutoInterface` with `devices="__none__"`; descope cases; `peer_announce` / `reverse_announce` with a recording socket; ~30 address formatting cases). The `bogus` scope is recorded as `error`; Swift's `Scope` enum makes it unrepresentable — test that config parsing from a string rejects it.
- [ ] Tests: every fixture case; vectors from §4.1/§4.2 inline as a sanity anchor; eligibility order §7.2.1 (incl. `lo0` in `devices` still skipped, `utun0` skipped unless listed). Commit.

### Task 2: Live socket driver

**Files:** Create `Sources/ReTiCAInterfaces/AutoInterface/AutoInterfaceDriver.swift` (dependency surface exactly as §5.3, `liveValue` over a private `AutoSocketActor`, `testValue` unimplemented-style like `TCPListener`'s); `Tests/ReTiCAInterfacesTests/AutoInterfaceDriverLiveTests.swift`.

- [ ] Live actor per §5.3 items 1-5 and the socket table §4.4 (multicast discovery, unicast discovery, data; senders unbound; `O_NONBLOCK`; `DispatchSourceRead`; fd closed only in `cancelHandler`; generation-stamped events).
- [ ] Live tests over `lo0` per §7.3: bind trio on `fe80::1` index 1 (use non-default ports so a running NomadNet/rnsd doesn't collide), multicast token round trip with `source == "fe80::1"` and `sourceScope == 1`, 1200-byte data round trip, `rebind` drops pre-rebind events, second data bind reports `bindFailed(.data, EADDRINUSE)`, `stop` then no events. Mutation check on the generation guard and the data-socket reuse options. Commit.

### Task 3: AutoInterface reducer

**Files:** Create `Sources/ReTiCAInterfaces/AutoInterface/AutoInterface.swift`; `Tests/ReTiCAInterfacesTests/AutoInterfaceReducerTests.swift`, `AutoInterfaceTraceTests.swift`; extend the generator with §7.1 item 5 traces.

**Interfaces (produces):** `@Reducer AutoInterface` with State/Actions per §5.4 (`.start`, `.stop`, `.send(addr:data:)`, `.announceTick`, `.peerJobTick`, `.socketEvent`, internal accept timer) and `Delegate`: `.peerAdded(addr: String, nic: String)`, `.peerRemoved(addr: String)`, `.packetReceived(addr: String, data: Data)`, `.carrierLost(nic:)`, `.carrierRecovered(nic:)`, `.multicastUnavailable(nic:)`, `.dataPortInUse(nic:)`, `.noUsableInterfaces`, `.localNetworkDenied`. Timers via `\.continuousClock`, stamps via `\.date`.

- [ ] Behaviour §5.4 items 1-7 in the order of §4.7, divergences D1-D4, `localNetworkDenied` per §8.4 (emitted once).
- [ ] Tests §7.2 items 1-9 and Review Focus 1-3; trace replay (§7.1.5) from the generator. Commit.

### Task 4: AutoEndpoint and TransportEndpoint wiring

**Files:** Create `Sources/ReTiCANode/AutoEndpoint.swift`; edit `Sources/ReTiCATransport/InterfaceProfile.swift` (`.auto` per §5.2), `Sources/ReTiCANode/TransportEndpoint.swift` (§5.7, every bullet), README interfaces section; recheck the `Transport.swift:1284-1290` "KNOWN DEFERRAL (I2)" comment against §4.9.4 and correct it; tests under `Tests/ReTiCANodeTests/`.

**Interfaces (produces):** `TransportEndpoint.State.auto: AutoEndpoint.State?`, `State.auto(_ config: AutoInterfaceConfig)` factory (or the existing factory pattern), `Action.auto(AutoEndpoint.Action)`, `.removeAuto`, `AutoEndpoint.autoInterfaceID(nic:addr:) -> InterfaceID`. App-facing delegates per §6 stay hatch-only.

- [ ] Tests §7.2 item 10 and Review Focus 4 (whole-slice probe with an auto peer and a TCP client together), plus Review Focus 5 at the endpoint level, IFAC-masked transmit to the right peer, `sendFailed` for a stale ID, `.removeAuto` stops the driver before clearing the slot.
- [ ] Grep the app for exhaustive switches over `TransportEndpoint.Action` / delegate enums that the new case breaks; if the app build breaks, Task 5 fixes it immediately after. Commit.

### Task 5: ReTiCAMsgr wiring

**Files (app repo `/Users/ell/development/ios/apps/ReTiCAMsgr`, commit on its main):** per spec §5.8 and §8 — `AppFeature.swift` toggle `autoInterfaceEnabled` (default on), `syncEndpointNodes` keep-running slot, `.removeAuto`, foreground restart / iOS background stop, `somethingWillDial`, a denied slot excluded from it; Settings row (whole-row tappable); surfacing `.dataPortInUse` (text suggesting a TCP connection to the local rnsd), `.multicastUnavailable` / `.localNetworkDenied` (alert pointing at Settings › Privacy › Local Network); Diagnostics shows auto peers; `Info.plist` gains `NSLocalNetworkUsageDescription` now; iOS toggle hidden behind compile condition `AUTOINTERFACE_ENTITLED` (R1) — do NOT add the multicast entitlement (Apple must grant it first).
- [ ] ReTiCAMsgrCore tests for the toggle, slot sync, lifecycle and the surfaced delegates; app target builds for macOS and iOS. Commit.

### Task 6: Live interop recipe and test

**Files:** `Tests/ReTiCANodeTests/LiveAutoInterfaceTests.swift` gated on `RETICA_LIVE_AUTO_DEVICE` / `RETICA_LIVE_AUTO_PROBE` (§7.4 steps 1-4), `docs/` recipe section in the README or spec §7.4 updated with results.
- [ ] Write the gated test (peerAdded within ~2 s, path learned via `auto:`, probe delivered). Try the single-Mac `feth` fallback only if it needs no sudo the agent cannot get; otherwise leave it documented as unverified. The second-host run is the user's to do; record that clearly. Commit.

---

## Status

Not started.
