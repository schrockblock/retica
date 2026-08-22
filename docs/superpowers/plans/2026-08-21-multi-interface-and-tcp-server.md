# Multiple interfaces, and a TCP server Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Let one node run several interfaces at once, then add a TCP server — so two phones on one Wi-Fi can peer over IP without a hub in the middle.

**Architecture:** The sum type does not disappear; **it moves down a layer.** Today `TransportEndpoint.State` is `.tcp | .ble` — one transport *or* another — and each case privately owns a `Transport` (the router) and a `LinkPlane` (links + registrations). That means running both would give two independent routers with separate path tables, not one node with two interfaces. The fix is to hoist the router and link plane into a shared container and reduce the endpoints to **drivers**. The enum survives at the driver leaf, where "this driver is a TCP client" is a true statement about one thing.

> **Corrected 2026-08-21, before any code was written.** An earlier draft said drivers are "each identified by an `InterfaceID`". **That is wrong, and the existing code already contradicts it:** `BLEEndpoint.State.peerInterfaces` is `[InterfaceID: Data]` (`BLEEndpoint.swift:29`) — **one driver already owns N InterfaceIDs**, one per peer. Reference does the same for the server case, spawning a per-socket `TCPClientInterface` into `spawned_interfaces` (stock 1.4.2 `TCPInterface.py:449-531`). The relation is **1:N**, so the container needs *driver identity* plus a separate `InterfaceID → driver` map. Designing around a 1:1 assumption would have had to be undone in Task 2.

**Tech Stack:** Swift 6, swift-testing, The Composable Architecture 1.26, Network.framework (`NWListener`).

## Global Constraints

- Platform floor **iOS 17 / macOS 13 / macCatalyst 17**.
- `ReTiCATransport` is interface-agnostic; **no new dependencies**. `NWListener` lives in `ReTiCAInterfaces` beside `NWConnection`, not in the transport core.
- **Wire compatibility with Python-RNS 1.4.1/1.4.2 mandatory — no emitted byte may change.** A TCP server speaks the *same* HDLC-framed protocol the client already speaks; this adds no wire format.
- `swift-testing`, not XCTest. `#expect(optional?.field == x)` **aborts** when nil — use `try #require`, or `#expect(x != nil)` then `if let`.
- Durable records **name the enclosing function**.
- Reference: `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/RNS` is **stock 1.4.2**; the other tree is a 1.4.1 **fork** whose extra import at `Reticulum.py:37` shifts later lines +1. **Cite the version with the line, and verify every reference claim rather than inheriting it** — three of my reference claims in the immediately preceding plan were wrong, two caught by implementers and one by me while writing the tick. All three shared a root: **reading one file and generalising to the codebase.**
- Mutation-verify **per test, individually**. A whole-block mutation failing several tests cannot show which test pins what; that has been misreported twice here and I found it both times.
- Gate (`Scripts/check-wire-narrowing.swift --fail-on-open`) stays at zero known-open.
- Commit trailers at **column 0**:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Background — what is already true, verified 2026-08-21

**The transport core is already multi-interface. This is the fact the whole plan rests on.**

- `Transport.State.interfaces` is `[InterfaceID: InterfaceProfile]` — a dictionary, not a single value. Declared at `Transport.swift:39`; `:283`/`:288` are the reducer's mutation sites. *(An earlier draft cited only the mutation sites as though they were the declaration — right claim, wrong lines, caught by the Task 1 implementer.)*
- A learned path names its interface: `entry.interfaceID`, and reachability is gated on that id still being present (`:160`).
- **Outbound already carries its interface**: `case transmit(InterfaceID, Data)` (`:240`), emitted as `.delegate(.transmit(outIf, raw))` (`:400`).
- Path expiry is already mode-dependent per interface (`pathExpiry(forMode:)`, `:700`).

So the routing decision — *which interface does this packet leave by* — is **solved**. This slice is structural plumbing, not new routing logic. Do not reimplement route selection.

**What blocks multiple interfaces is one layer up:**

- `TransportEndpoint.State` is `enum { case tcp(TCPEndpoint.State); case ble(BLEEndpoint.State) }` (`TransportEndpoint.swift:18-20`), with computed `learned` / `interfaces` / `links` / `registrations` that switch on the active case (`:22-54`).
- `TCPEndpoint.State` (`TCPEndpoint.swift:18-26`) bundles **three separable things**: `interface: TCPClientInterface.State` (the driver), `transport: Transport.State` (the router), `linkPlane: LinkPlane.State` (links + registrations), plus `interfaceID` and `profile`. `BLEEndpoint` mirrors this with its **own** router and link plane.

That last point is the crux: **the router is duplicated per transport today.** Two active endpoints would mean two path tables, two seen-packet rings, two link planes — a packet arriving over BLE could not be routed out over TCP. Fixing the enum without hoisting the router would produce something that compiles and is still wrong.

**Consumers:** 13 switch sites inside `TransportEndpoint.swift`; **zero** in `LXMFNode`/`LXMFServiceNode` (they are already transport-agnostic — the unified surface works); **4** in the app's `AppFeature.swift`.

---

## File Structure

- `Sources/ReTiCANode/TransportEndpoint.swift` — becomes the shared container.
- `Sources/ReTiCANode/TCPEndpoint.swift`, `BLEEndpoint.swift` — reduced to drivers.
- `Sources/ReTiCAInterfaces/TCPListener.swift` — **new**; the `NWListener` dependency.
- `Sources/ReTiCAInterfaces/TCPServerInterface.swift` — **new**; the server driver.
- `ReTiCaMsgr/…/AppFeature.swift` — 4 call sites.

---

### Task 1 — RESHAPED 2026-08-21, before any code was written

**The original Task 1 was unachievable, and its own acceptance criterion is what proved it.** It said: hoist the router and link plane, change no behaviour, and *"any test that changes is a finding."* But **56 tests drive `TCPEndpoint`/`BLEEndpoint` as `TestStore`s and assert exactly the responsibilities being hoisted out** — `TCPEndpointTests` alone makes 126 `.transport` references, e.g. `store.state.transport.interfaces[store.state.interfaceID]` (`:48`), the F8 stale-path gate via `state.transport.learned` (`:224-228`), and `receive(\.transport.interfaceConnected)` (`:1548`). After the hoist, `TCPEndpoint` has no `transport` to read. Add 6 of 7 in `TransportEndpointTests` and 13 nested-path matchers across 6 LXMF files.

So "hoist" and "no test changes" cannot both hold. **And the deeper problem is that rewriting ~75 assertions destroys the proof**: the task's deliverable *is* the argument "suite unchanged and green ⇒ behaviour unchanged". Rewrite the suite and only the refactor remains — the thing this plan says must not be trusted alone.

The fix is to write the proof at a level that **survives** the change, then change.

#### Task 1a: Characterization tests at the unified surface

**Files:** a new test file; no production change.

Pin the behaviours that must survive, **addressed through the unified `TransportEndpoint` surface rather than through `TCPEndpoint`/`BLEEndpoint` internals** — so they still compile and still mean the same thing after the hoist, and become the proof Task 1b needs.

- [ ] **Step 1:** Cover at minimum: the F8 stale-path gate; IFAC masking; maintenance-tick pairing; disconnect fan-out; per-peer transmit routing. Add whatever else reading the 56 tests shows to be behaviour rather than structure.
- [ ] **Step 2:** Each must fail if the behaviour is removed — mutation-verify individually. A characterization test that passes against a broken implementation is worse than none, because Task 1b will trust it.
- [ ] **Step 3:** Full suite green; commit.

#### Task 1b: The hoist

**Files:** `TransportEndpoint.swift`, `TCPEndpoint.swift`, `BLEEndpoint.swift`

- [ ] **Step 1:** Restructure `TransportEndpoint.State` into a product: one `transport: Transport.State`, one `linkPlane: LinkPlane.State`, and a collection of **drivers** — plus an `InterfaceID → driver` map, because the relation is **1:N** (see the Architecture correction). The driver stays a sum (`tcpClient` / `ble`, plus `tcpServer` in Task 2).
- [ ] **Step 2:** Route inbound driver bytes into the shared `Transport` tagged with the arriving `InterfaceID`; route `.delegate(.transmit(interfaceID, data))` back to the owning driver. **Both directions already carry the id.**
- [ ] **Step 3:** Task 1a's tests are the acceptance criterion and **must not be edited.** The endpoint-internal tests *will* need rewriting — that is now expected, not a finding. Report how many and what each was pinning, so anything lost is visible.
- [ ] **Step 4:** Full suite + gate. Commit.

#### Three decisions this task must make explicitly — they were reserved and cannot be

1. **How drivers are indexed, and what TCA forces.** `Scope`'s `action:` needs a *static* case path. Indexing by runtime `InterfaceID` forces `IdentifiedAction`, which is what breaks all 69 `.interface(…)` sites in `TCPEndpointTests`; indexing by *kind* keeps them but caps you at one TCP client — and `TCPEndpointTests.swift:1514` already uses a non-default `interfaceID`. **The entire test cost of this slice turns on this choice.** Decide it deliberately and record the trade.
2. **Whether BLE-only `peerOnline`/`peerOffline` join the unified surface.** `BLEEndpointTests` pins them on `.delegate` in 30+ places; `TransportEndpoint.swift:12-14` deliberately excludes them because LXMF has no use for them. **One enum cannot honour both.** Pick, and say what the loser costs.
3. **What the `.tcp` / `.ble` escape hatches mean when several drivers exist.** "The TCP one" stops being well-defined the moment there can be two.

### Task 2: The TCP server driver

**Files:** `Sources/ReTiCAInterfaces/TCPListener.swift`, `TCPServerInterface.swift`

- [ ] **Step 1: Read `TCPConnection.swift` and `TCPClientInterface.swift` first.** The server speaks the identical protocol — HDLC framing (`HDLC.frame` out, `HDLCDeframer.ingest` in, `TCPClientInterface.swift:91`/`:108-109`). Reuse both; do not write a second framing path.
- [ ] **Step 2: The dependency shape must differ from `TCPConnection`, and this is the main design point.** `TCPConnection` is single-connection by construction — `send: (Data) -> Void` with no peer. A listener accepts **N** simultaneous connections, each needing its own deframer and its own send. Design a `TCPListener` dependency accordingly (accept/data/closed events carrying a connection identifier, and a per-connection send), following `TCPConnection`'s live-value/mock split.
- [ ] **Step 3: Decide how accepted connections map to interfaces, and justify it.** Is the listener one `InterfaceID` with many peers, or one id per accepted connection? This decides how `Transport` sees them, how paths are attributed, and what happens to learned paths when a peer disconnects. **Check what reference does** — `TCPServerInterface` in stock 1.4.2 spawns a per-connection interface object; verify that and cite it before choosing.
- [ ] **Step 4:** Tests: two in-memory endpoints peer, one listening and one dialling, and a packet routes end to end. A second accepted connection is independent of the first. A disconnect cleans up without disturbing the other.
- [ ] **Step 5:** Full suite + gate. Mutation-verify per test. Commit.

### Task 3: App wiring and the checklist

- [ ] **Step 1:** Update the app's 4 `endpoint(.tcp(` sites. Decide the app's default topology — client only, or client *and* listener — and say why.
- [ ] **Step 2:** Tick **both** the Tier 5 "one transport at a time" item and the Tier 6 interfaces item (partially — TCP server only; `AutoInterface` and `RNodeInterface` remain). SHAs inline across both repos.
- [ ] **Step 3: State what is NOT closed**, checked rather than assumed: the remaining 12 of 15 interfaces; whether a listening node is discoverable without `AutoInterface` (it is not — you still need an address); and any per-connection resource bound the server does or does not have. *Seven documentation overclaims here in three weeks have been the same shape — a summary wider than its evidence.*

---

## Self-review notes for the implementer

- **Do not reimplement route selection.** `Transport` already picks the outbound interface and tags inbound arrivals. If you find yourself writing "which interface should this go to", stop — the answer is already in `transmit(InterfaceID, Data)`.
- **Task 1 changing behaviour is a bug, not a trade-off.** It is a refactor whose entire value is that Task 2 becomes possible.
- **A listening socket is an attack surface the dialling client never was.** Anyone on the LAN can connect. Note what bounds the number of accepted connections; if nothing does, say so plainly rather than leaving it implied — Tier 7 already tracks admission control and this belongs in that conversation.
