# Slow-Link Timing (Meshtastic Lane C) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make link-establishment timeouts, the relay link-table proof deadline and the LXMF retry wait scale with interface bitrate (and, for the initiator, hop count), and let a node announce on just the one interface that came up. TCP/BLE values for paths of up to one relay stay what they are today.

**Architecture:** One pure enum, `LinkTiming` in ReTiCATransport, holds the link formulas. `LXMFDelivery.retryWait(nextHopBitrate:)` in ReTiCA core holds the retry formula. `Transport.State` gets a `nextHopInterfaceProfile(_:)` query, and its relay LINKREQUEST branch adds the arrival interface's latency to the link-table proof deadline. `TransportEndpoint` is the only layer that sees both Transport and LinkPlane, so it computes the initiator timeout and passes it into `LinkPlane.openLink`, and it passes the arrival interface's bitrate into `LinkPlane.acceptLinkRequest`. The responder formula has no hop term. `LXMFRouter` stays decoupled: it reads a per-destination `nextHopRetryWaits` table that `LXMFNode` fills in synchronously from Transport state. A new `interface:` parameter on `Transport.Action.announce` reaches the app through new `TransportEndpoint.announceOn` and `LXMFNode.announceDeliveryOnInterface` actions.

**Tech Stack:** Swift 6 package, The Composable Architecture (TestStore, TestClock), Swift Testing (`@Suite`, `@Test`, `#expect`).

**Spec:** `/Users/ell/development/ios/pods/ReTiCA/docs/superpowers/specs/2026-10-16-meshtastic-interface-design.md`. This plan implements **Lane C only**: Contract 4 (§4, amended 2026-10-16), the lane C rows of §6 (file ownership) and §8 (testing). Read the amended Contract 4 table before starting any task.

## Global Constraints

- **Worktree:** all work happens in `/Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing` on branch `slow-link-timing`. Task 1 creates it. Run every git command as `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing …`.
- **One shell command per Bash call.** No `|`, `&&`, `||`, `;`, no `$(...)` feeding another command, no `xargs`, no inline interpreters (`python -c`, `bash -c`, heredocs into interpreters). Any script goes in a file. Temp files go under `/tmp/slow-link-timing/`.
- **Running tests:** `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter <SuiteName>`, using the exact suite name each task gives. For the whole package, drop `--filter`. Use a 600000 ms timeout. If a full run takes longer than that, rerun it with `run_in_background: true` and wait for the completion notice.
- **Build flakes:** if you see signal 11 / signal 10 or a stale-link failure (spurious `LinkSessionRequestTests` failures), run `swift package --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing clean` and rerun.
- **Test verification, for every new or changed test set, before committing:**
  (a) Run the set and confirm all pass.
  (b) Back up each production file the task tells you to mutate with `cp <file> /tmp/slow-link-timing/<name>.orig`. Apply ALL of the task's listed mutations with the Edit tool (one batch). Run the set once and confirm EVERY test in it fails. If any test still passes, that test is not testing what it claims: fix the test, then restart at (a).
  (c) Restore each file with `cp /tmp/slow-link-timing/<name>.orig <file>`. Run the set and confirm all pass. Then `git -C <worktree> diff --stat` must show only the task's intended files.
  Only commit after (c) succeeds.
- **Commits:** write the message to a new file `/tmp/slow-link-timing/commit-taskN.txt` with the Write tool, then run `git -C <worktree> commit -F /tmp/slow-link-timing/commit-taskN.txt`. The message ends with these two trailer lines, **at column zero, no indent**, after one blank line:
  ```
  Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
  ```
  After each commit, verify with `git -C <worktree> log -1 '--format=%(trailers:key=Claude-Session)'`. It must print the session line.
- **File ownership (amended spec §6):** Lane C owns `Sources/ReTiCATransport/LinkSession.swift`, `Sources/ReTiCANode/LinkPlane.swift`, `Sources/ReTiCATransport/Transport.swift`, `Sources/ReTiCANode/LXMFRouter.swift`, `Sources/ReTiCA/LXMF/LXMFDelivery.swift` and `Sources/ReTiCANode/LXMFNode.swift`, plus the new files this plan creates. `Sources/ReTiCANode/TransportEndpoint.swift` belongs to lane B. Touch it ONLY in these accepted regions: the `.openLink` arm (today :172-191), the `.linkRequest` arm (today :311-317), and one new `announceOn` case directly below `case announce` (today :99) with its arm directly below the `.announce` arm (today :164). Never touch `InterfaceProfile.swift`.
- **No lane-B symbols.** No `.meshtastic` profile, no `MeshtasticEndpoint`, no `meshtasticInterfaceID`. Slow links in tests use `InterfaceProfile(name: "slow-202", bitrate: 202)` (LongFast's paced rate in the spec's table). Fast links use `.tcp` (10_000_000 bps) and `.ble` (80_000 bps).
- **Formulas (amended Contract 4).** `L(b) = 500·8/b`, the time to clock one MTU onto an interface.
  - Initiator = `max(15, L(b) + 6 + 6·h)`, where `b` = next-hop interface bitrate and `h = max(1, wire hops)`, clamped at 128.
  - Responder = `max(15, 2·L(b_recv) + 6)`, where `b_recv` = the arrival interface's bitrate. There is **no hop term**: a LINKREQUEST's hops are attacker-controlled.
  - Relay link-table proof deadline = `now + 6·max(1, entry.hops) + L(b_recv)`, where `b_recv` = the bitrate of the interface the LINKREQUEST ARRIVED on (reference `extra_link_proof_timeout(packet.receiving_interface)`, `RNS/Transport.py:1643`). Unknown `b_recv` adds nothing.
  - LXMF retry wait = `max(10, 4·L(b))`, rounded **up** to whole seconds.
  - Unknown `b` (no path, no profile, `b ≤ 0`) gives today's values: 15 for the link timeouts, 10 for the retry wait.
- **Hop semantics:** `h` uses ReTiCA's ON-WIRE hop count. A directly heard peer is 0, because Transport stores `packet.hops` as heard (`Transport.swift:589`). This is the same convention as the existing per-hop timers (`Transport.swift:757`, `:1009`). `LinkTiming.effectiveHops(wire:)` = `min(max(1, Int(wire)), 128)`, computed in `Int` so wire 255 cannot trap. It does NOT add the reference's +1.
- **TCA test rules:** inject `$0.continuousClock = TestClock()` (never a live clock). `\.date` has no testValue, so always set `$0.date = .constant(...)`. Transport uses `\.transportDate`, whose testValue is epoch 0. Prefer `.off` TestStores that assert outcomes. To assert that something is NOT transmitted, send the action under `.off`, then set `store.exhaustivity = .on` and do any expected `receive`. Under `.on`, `receive` must match the NEXT queued action and teardown fails on anything left over. Never hold an `Effect.cancel(id:)` in a `let` (it cancels when built). A test name claiming two things must assert both.
- **Swift Testing:** every new test lives in an `@Suite` struct with the exact name given, so `--filter <SuiteName>` selects exactly that set.
- **Accepted gaps (document, do not fix):** the single-packet receipt timeout (`Transport.swift:1009-1012`) has no first-hop latency term. A next-hop bitrate change during an LXMF retry run is seen only at the next announce or send. The retry wait is rounded up to whole seconds.

## Review Focus

1. **A LINKREQUEST with a hostile hop count (255).** Expected: no trap. The responder timeout is unaffected by hops: 15 s on TCP, about 45.6 s at 202 bps. The initiator's `h` is clamped at 128. Pinned in Task 1 (`hostileHopCountIsClampedForTheInitiator`) and Task 3 (`hopsNeverStretchTheResponder`).
2. **The next-hop interface disconnects before an LXMF send.** Expected: that send's retry falls back to 10 s. It must not reuse a stale stretched wait. Pinned in Task 5 (`aDisconnectedNextHopFallsBackToTenSecondsAtSend`).
3. **The same InterfaceID re-registers with a new bitrate** (for example a radio preset change). Expected: the next link open and the next LXMF send both read the new bitrate. Pinned in Task 2 (`aReRegisteredInterfaceBitrateIsReadWhenTheLinkOpens`) and Task 5 (`aReRegisteredInterfaceBitrateIsReadAtSend`).
4. **A targeted announce names an interface that is not connected.** Expected: it transmits nothing, with no fallback to every interface. Pinned in Task 6 (`aTargetedAnnounceToADisconnectedInterfaceTransmitsNothing`).
5. **A relay receives a LINKREQUEST on an interface with no registered profile.** Expected: there is no extra term and no crash; the deadline is the plain `6·max(1, hops)`. A slow outbound interface must not be used in its place. Pinned in Task 7 (`anUnknownArrivalBitrateAddsNothing`).

## Decisions recorded (spec amended 2026-10-16) and one open discrepancy

- `h = max(1, wire hops)`, ReTiCA's convention, not reference + 1. The initiator still clamps at 128.
- The responder timeout is `max(15, 2·L(b_recv) + 6)` with no hop term. It is always 15 s at TCP/BLE.
- The `announceOn` case and the `.openLink` / `.linkRequest` arm edits in `TransportEndpoint.swift` are accepted (§6).
- The relay link-table proof deadline gains `L(b_recv)`, the interface the LINKREQUEST arrived on, as reference does (`RNS/Transport.py:1643`). The spec was amended a second time: an earlier `b_out` reading was reversed. In Task 7's tests the inbound and outbound bitrates always differ, and the mutation reads the outbound interface.

---

## File Structure

| File | Change | Responsibility |
|---|---|---|
| `Sources/ReTiCATransport/LinkTiming.swift` | Create | Pure link-timing formulas and the hop clamp |
| `Sources/ReTiCATransport/Transport.swift` | Modify | `State.nextHopInterfaceProfile(_:)`; `establishmentTimeoutPerHop` aliases LinkTiming; relay proof deadline (Task 7); `announce` gains `interface:` (Task 6) |
| `Sources/ReTiCATransport/LinkSession.swift` | Modify | Init defaults reference `LinkTiming.defaultEstablishmentTimeout` (value unchanged) |
| `Sources/ReTiCANode/LinkPlane.swift` | Modify | `openLink(..., establishmentTimeout:)`, `acceptLinkRequest(..., arrivalBitrate:)` |
| `Sources/ReTiCANode/TransportEndpoint.swift` | Modify (lane-B file; accepted regions only) | Computes and threads timing; `announceOn` |
| `Sources/ReTiCA/LXMF/LXMFDelivery.swift` | Modify | `retryWait(nextHopBitrate:)` |
| `Sources/ReTiCANode/LXMFRouter.swift` | Modify | `nextHopRetryWaits`, `deliveryRetryTimer`, all 12 retry sites |
| `Sources/ReTiCANode/LXMFNode.swift` | Modify | `refreshNextHopRetryWait`, `announceDeliveryOnInterface` |
| `Tests/ReTiCATransportTests/LinkTimingTests.swift` | Create | Suite `LinkTimingTests` |
| `Tests/ReTiCANodeTests/LinkEstablishmentTimingTests.swift` | Create | Suites `InitiatorEstablishmentTimingTests`, `ResponderEstablishmentTimingTests` |
| `Tests/ReTiCANodeTests/LXMFSlowLinkRetryTests.swift` | Create | Suite `LXMFSlowLinkRetryTests` |
| `Tests/ReTiCANodeTests/LXMFNodeSlowLinkRetryTests.swift` | Create | Suite `LXMFNodeSlowLinkRetryTests` |
| `Tests/ReTiCANodeTests/TargetedAnnounceTests.swift` | Create | Suite `TargetedAnnounceTests` |
| `Tests/ReTiCATransportTests/RelayLinkProofDeadlineTests.swift` | Create | Suite `RelayLinkProofDeadlineTests` |

Worked values the tests pin (`L(b) = 4000/b`):

| profile | b | L(b) | initiator wire 0/1/2/3 (h 1/1/2/3) | responder (any hops) | relay extra | LXMF retry |
|---|---|---|---|---|---|---|
| `.tcp` | 10_000_000 | 0.0004 | 15 / 15 / 18.0004 / 24.0004 | 15 | 0.0004 | 10 |
| `.ble` | 80_000 | 0.05 | 15 / 15 / 18.05 / 24.05 | 15 | 0.05 | 10 |
| slow-202 | 202 | 19.801980198019802 | 31.801980198019802 / 31.801980198019802 / 37.801980198019802 / — | 45.603960396039604 | 19.801980198019802 | 80 (79.2 rounded up) |
| none | nil | — | 15 at any hops | 15 | 0 | 10 |
| `.tcp`, wire 255 (h clamped 128) | | | 774.0004 | 15 | | |

---

### Task 1: Worktree, LinkTiming formulas, next-hop profile query

**Files:**
- Create: `Sources/ReTiCATransport/LinkTiming.swift`
- Modify: `Sources/ReTiCATransport/Transport.swift` (insert after `reachableLearned`, today :185-189; constant at :1243)
- Modify: `Sources/ReTiCATransport/LinkSession.swift:135`, `:164` (default values only)
- Test: `Tests/ReTiCATransportTests/LinkTimingTests.swift` (suite `LinkTimingTests`)

**Interfaces:**
- Consumes: `Packet.mtu` (500), `Packet.maxHops` (`UInt8` 128) from ReTiCA; `Transport.State.reachableLearned(_:)`.
- Produces:
  - `public enum LinkTiming`
    - `static let defaultEstablishmentTimeout: TimeInterval` (15)
    - `static let establishmentTimeoutPerHop: TimeInterval` (6)
    - `static func firstHopLatency(bitrate: Int) -> TimeInterval`
    - `static func effectiveHops(wire: UInt8) -> Int`
    - `static func initiatorEstablishmentTimeout(bitrate: Int?, wireHops: UInt8) -> TimeInterval`
    - `static func responderEstablishmentTimeout(bitrate: Int?) -> TimeInterval`
    - `static func relayProofExtraTimeout(bitrate: Int?) -> TimeInterval`
  - `Transport.State.nextHopInterfaceProfile(_ destinationHash: Data) -> InterfaceProfile?`

- [ ] **Step 1: Create the worktree and temp dir**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA worktree add ../ReTiCA-worktrees/slow-link-timing -b slow-link-timing`
Expected: `Preparing worktree (new branch 'slow-link-timing')`.

Run: `ls -la /Users/ell/development/ios/pods/ReTiCA-worktrees/FCB`
Expected: a symlink to `/Users/ell/development/ios/pods/FCB`, which `Package.swift`'s `../FCB` needs.

Run: `mkdir -p /tmp/slow-link-timing`

- [ ] **Step 2: Baseline the full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing`
Expected: all tests pass. Write down the total count. If anything fails on the untouched tree, STOP and report it.

- [ ] **Step 3: Write the failing tests**

Create `Tests/ReTiCATransportTests/LinkTimingTests.swift`:

```swift
import Testing
import Foundation
@testable import ReTiCATransport
@testable import ReTiCA

private let slow202 = InterfaceProfile(name: "slow-202", bitrate: 202)
private let tcp = InterfaceProfile.tcp.bitrate      // 10_000_000
private let ble = InterfaceProfile.ble.bitrate      // 80_000

private func approx(_ a: TimeInterval, _ b: TimeInterval) -> Bool { abs(a - b) < 1e-9 }

/// Amended Contract 4 formulas. Hop arguments are ReTiCA's ON-WIRE counts; h = max(1, wire).
@Suite struct LinkTimingTests {
    // --- initiator: max(15, 4000/b + 6 + 6h) ---

    @Test func initiatorFloorHoldsUpToOneWireHopOnFastLinks() {
        // wire 0 and 1 → h 1 → 4000/b + 12 < 15 on TCP and BLE: today's value is unchanged.
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: tcp, wireHops: 0) == 15)
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: tcp, wireHops: 1) == 15)
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: ble, wireHops: 0) == 15)
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: ble, wireHops: 1) == 15)
    }

    @Test func initiatorGrowsSixSecondsPerHopBeyondTheFirst() {
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: tcp, wireHops: 2), 18.0004))   // h 2
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: tcp, wireHops: 3), 24.0004))   // h 3
        // The latency term is pinned exactly, not rounded away: 4000/80_000 = 0.05 s.
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: ble, wireHops: 2), 18.05))
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: ble, wireHops: 3), 24.05))
    }

    // --- responder: max(15, 2·4000/b + 6), no hop term ---

    @Test func responderIsFifteenSecondsOnFastLinks() {
        #expect(LinkTiming.responderEstablishmentTimeout(bitrate: tcp) == 15)   // 6.0008 → floor
        #expect(LinkTiming.responderEstablishmentTimeout(bitrate: ble) == 15)   // 6.1 → floor
    }

    // --- slow links ---

    @Test func aSlowNextHopStretchesTheInitiator() {
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: slow202.bitrate, wireHops: 0), 31.801980198019802))
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: slow202.bitrate, wireHops: 1), 31.801980198019802))
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: slow202.bitrate, wireHops: 2), 37.801980198019802))
    }

    @Test func aSlowArrivalInterfaceStretchesTheResponder() {
        #expect(approx(LinkTiming.responderEstablishmentTimeout(bitrate: slow202.bitrate), 45.603960396039604))
    }

    // --- unknown bitrate: today's values ---

    @Test func anUnknownBitrateKeepsFifteenSecondsForTheInitiator() {
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: nil, wireHops: 5) == 15)
        #expect(LinkTiming.initiatorEstablishmentTimeout(bitrate: 0, wireHops: 5) == 15)
    }

    @Test func anUnknownBitrateKeepsFifteenSecondsForTheResponder() {
        #expect(LinkTiming.responderEstablishmentTimeout(bitrate: nil) == 15)
        #expect(LinkTiming.responderEstablishmentTimeout(bitrate: -1) == 15)
    }

    // --- hostile wire input ---

    @Test func hostileHopCountIsClampedForTheInitiator() {
        // Computed in Int (no UInt8 trap) and clamped at PATHFINDER_M = 128.
        #expect(LinkTiming.effectiveHops(wire: 255) == 128)
        #expect(LinkTiming.effectiveHops(wire: 0) == 1)
        #expect(approx(LinkTiming.initiatorEstablishmentTimeout(bitrate: tcp, wireHops: 255), 774.0004))
    }

    // --- relay proof deadline extra term: 4000/b_recv, unknown → 0 ---

    @Test func theRelayProofExtraIsOneMTUOfAirtimeOrNothing() {
        #expect(approx(LinkTiming.relayProofExtraTimeout(bitrate: tcp), 0.0004))
        #expect(approx(LinkTiming.relayProofExtraTimeout(bitrate: slow202.bitrate), 19.801980198019802))
        #expect(LinkTiming.relayProofExtraTimeout(bitrate: nil) == 0)
        #expect(LinkTiming.relayProofExtraTimeout(bitrate: 0) == 0)
    }

    // --- next-hop profile query ---

    private func state(learnedOn interface: InterfaceID, dest: Data) -> Transport.State {
        var s = Transport.State()
        s.interfaces[InterfaceID("fast")] = .tcp
        s.interfaces[InterfaceID("slow")] = slow202
        s.learned[dest] = LearnedDestination(identity: Identity(), appData: nil, ratchet: nil,
                                             interfaceID: interface, hops: 0, nextHop: dest,
                                             announceEmitted: 0, learnedAt: Date(timeIntervalSince1970: 0))
        return s
    }

    @Test func theNextHopProfileIsTheProfileOfTheInterfaceThePathWasLearnedOn() {
        let dest = Data(repeating: 0x42, count: 16)
        #expect(state(learnedOn: InterfaceID("slow"), dest: dest).nextHopInterfaceProfile(dest) == slow202)
    }

    @Test func theNextHopProfileIsNilWithoutAReachablePath() {
        let dest = Data(repeating: 0x42, count: 16)
        var s = state(learnedOn: InterfaceID("slow"), dest: dest)
        s.interfaces[InterfaceID("slow")] = nil                                   // that interface went away
        #expect(s.nextHopInterfaceProfile(dest) == nil)
        #expect(s.nextHopInterfaceProfile(Data(repeating: 0x43, count: 16)) == nil)   // never learned
    }
}
```

- [ ] **Step 4: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LinkTimingTests`
Expected: compile error, `cannot find 'LinkTiming' in scope`.

- [ ] **Step 5: Implement `LinkTiming`**

Create `Sources/ReTiCATransport/LinkTiming.swift`:

```swift
import Foundation
import ReTiCA

/// Bitrate-aware link timing (2026-10-16 Meshtastic spec, amended Contract 4).
///
/// HOP SEMANTICS. Hop arguments are the ON-WIRE count ReTiCA stores (`LearnedDestination.hops`):
/// Transport never increments on receipt, so a directly heard peer is 0. `h = max(1, wire)` is
/// the convention the existing per-hop timers use (`Transport`'s link-table proof deadline and
/// receipt timeout). It is deliberately NOT the reference's wire + 1 (`RNS/Transport.py:1496`,
/// local 1.4.1 fork increments on receipt) — decided in the spec amendment.
public enum LinkTiming {
    /// The fixed establishment timeout ReTiCA used before Contract 4. Kept as the floor of both
    /// establishment formulas and as the value when the bitrate is unknown.
    public static let defaultEstablishmentTimeout: TimeInterval = 15

    /// RNS `Link.ESTABLISHMENT_TIMEOUT_PER_HOP` = `Reticulum.DEFAULT_PER_HOP_TIMEOUT` = 6 s
    /// (`RNS/Link.py:75`; `RNS/Reticulum.py:143` in the local fork, :142 in stock 1.4.2).
    public static let establishmentTimeoutPerHop: TimeInterval = 6

    /// Seconds to clock one MTU onto an interface of `bitrate` bits/s: the latency term of
    /// reference `Transport.first_hop_timeout`, `Reticulum.MTU * next_hop_per_byte_latency`
    /// (`RNS/Transport.py:2782-2791`). Callers guarantee `bitrate > 0`.
    public static func firstHopLatency(bitrate: Int) -> TimeInterval {
        Double(Packet.mtu * 8) / Double(bitrate)
    }

    /// `max(1, wire)`, clamped at PATHFINDER_M. Computed in `Int` so no hop value can trap.
    public static func effectiveHops(wire: UInt8) -> Int {
        min(max(1, Int(wire)), Int(Packet.maxHops))
    }

    /// Initiator: `max(15, MTU·8/b + 6 + 6·h)` — the shape of reference `Link.py:282-283`
    /// (`first_hop_timeout + ESTABLISHMENT_TIMEOUT_PER_HOP * max(1, hops_to)`) plus the 15 s floor.
    /// `bitrate` is the next-hop interface's (`Transport.State.nextHopInterfaceProfile`); unknown → 15.
    public static func initiatorEstablishmentTimeout(bitrate: Int?, wireHops: UInt8) -> TimeInterval {
        guard let bitrate, bitrate > 0 else { return defaultEstablishmentTimeout }
        let h = Double(effectiveHops(wire: wireHops))
        return max(defaultEstablishmentTimeout,
                   firstHopLatency(bitrate: bitrate) + establishmentTimeoutPerHop + establishmentTimeoutPerHop * h)
    }

    /// Responder: `max(15, 2·MTU·8/b + 6)`, `bitrate` = the interface the LINKREQUEST arrived on;
    /// unknown → 15. Two MTUs of airtime (our LRPROOF out, their LRRTT back) plus one per-hop allowance.
    ///
    /// No hop term: a LINKREQUEST's hop count is attacker-controlled, and this timeout is how long a
    /// half-open element spends `LinkPlane`'s unauthenticated `maxIncompleteResponderLinks` budget.
    /// DELIBERATE DEVIATION from reference `6·hops + KEEPALIVE` (`RNS/Link.py:204`), per the spec.
    public static func responderEstablishmentTimeout(bitrate: Int?) -> TimeInterval {
        guard let bitrate, bitrate > 0 else { return defaultEstablishmentTimeout }
        return max(defaultEstablishmentTimeout,
                   2 * firstHopLatency(bitrate: bitrate) + establishmentTimeoutPerHop)
    }

    /// Extra allowance on a RELAY's link-table proof deadline: one MTU of airtime on the interface
    /// the LINKREQUEST ARRIVED on — reference `extra_link_proof_timeout(packet.receiving_interface)`
    /// (`RNS/Transport.py:2794-2796`, applied at :1643). Unknown → 0.
    public static func relayProofExtraTimeout(bitrate: Int?) -> TimeInterval {
        guard let bitrate, bitrate > 0 else { return 0 }
        return firstHopLatency(bitrate: bitrate)
    }
}
```

- [ ] **Step 6: Add the next-hop profile query**

In `Sources/ReTiCATransport/Transport.swift`, directly after the closing brace of `reachableLearned(_:)` (today :189), insert:

```swift

        /// The profile of the interface the learned path to `destinationHash` leaves on — reference
        /// `Transport.next_hop_interface` / `next_hop_interface_bitrate` (`RNS/Transport.py:2750-2765`,
        /// local 1.4.1 fork), whose interface is the path's receiving interface, as `interfaceID` is
        /// here. `nil` when there is no learned path, or it names an interface that is not connected.
        public func nextHopInterfaceProfile(_ destinationHash: Data) -> InterfaceProfile? {
            guard let entry = reachableLearned(destinationHash) else { return nil }
            return interfaces[entry.interfaceID]
        }
```

In the same file, replace `    static let establishmentTimeoutPerHop: TimeInterval = 6` with `    static let establishmentTimeoutPerHop: TimeInterval = LinkTiming.establishmentTimeoutPerHop`.

In `Sources/ReTiCATransport/LinkSession.swift`, in BOTH inits (today :135 and :164), replace `establishmentTimeout: TimeInterval = 15` with `establishmentTimeout: TimeInterval = LinkTiming.defaultEstablishmentTimeout`. The value stays the same, so every existing `LinkSession.State(...)` construction behaves exactly as before.

- [ ] **Step 7: Run to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LinkTimingTests`
Expected: 11 tests pass.

- [ ] **Step 8: Mutation batch (step b)**

`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/LinkTiming.swift /tmp/slow-link-timing/LinkTiming.swift.orig`
`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/Transport.swift /tmp/slow-link-timing/Transport.swift.orig`

Apply all of these with Edit:
- M1 `effectiveHops`: body becomes `max(1, Int(wire) + 1)` (the rejected reference convention, no clamp).
- M2 the two `guard let bitrate, bitrate > 0 else { return defaultEstablishmentTimeout }` lines return `0`.
- M3 `nextHopInterfaceProfile`: body becomes `return .tcp`.
- M4 both `max(defaultEstablishmentTimeout, X)` become just `X`.
- M5 `firstHopLatency`: body becomes `0`.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LinkTimingTests`
Expected: all 11 FAIL. Which mutation breaks which test:
- the initiator floor and responder-fast tests: M4;
- the growth and hostile-clamp tests: M1 (wire 2 gives h 3, and wire 255 gives 256 instead of 128);
- the slow tests and the relay-extra test: M5;
- the unknown-bitrate tests: M2;
- both profile tests: M3.

- [ ] **Step 9: Revert (step c)**

`cp /tmp/slow-link-timing/LinkTiming.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/LinkTiming.swift`
`cp /tmp/slow-link-timing/Transport.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/Transport.swift`
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LinkTimingTests`
Expected: 11 pass.

- [ ] **Step 10: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing`
Expected: baseline + 11, all pass.

- [ ] **Step 11: Commit**

`git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing add Sources/ReTiCATransport/LinkTiming.swift Sources/ReTiCATransport/Transport.swift Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkTimingTests.swift`

`/tmp/slow-link-timing/commit-task1.txt`:
```
feat: LinkTiming formulas and next-hop profile query

Amended Contract 4 of the 2026-10-16 Meshtastic spec. Initiator
max(15, 4000/b + 6 + 6h) with h = max(1, wire hops) clamped at 128; responder
max(15, 2*4000/b + 6) with no hop term; relay proof extra 4000/b_recv. Unknown
bitrate keeps 15 s / no extra. Transport.State.nextHopInterfaceProfile mirrors RNS
next_hop_interface. No behaviour change yet: nothing calls the formulas.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing commit -F /tmp/slow-link-timing/commit-task1.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing log -1 '--format=%(trailers:key=Claude-Session)'`
Expected: the Claude-Session line.

---

### Task 2: Initiator establishment timeout follows the next hop

**Files:**
- Modify: `Sources/ReTiCANode/LinkPlane.swift:84-86` (case), `:162-168` (arm)
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift:172-191` (`.openLink` arm only)
- Test: `Tests/ReTiCANodeTests/LinkEstablishmentTimingTests.swift` (suite `InitiatorEstablishmentTimingTests`)

**Interfaces:**
- Consumes: `LinkTiming.initiatorEstablishmentTimeout(bitrate:wireHops:)`, `Transport.State.nextHopInterfaceProfile(_:)` (Task 1).
- Produces: `LinkPlane.Action.openLink(initiatorTo: Identity, destinationHash: Data, interfaceID: InterfaceID, relayNextHop: Data?, establishmentTimeout: TimeInterval = LinkTiming.defaultEstablishmentTimeout)`. Existing call sites that omit it still compile and get 15 s. The test file's private helpers `mesh`, `slow202`, `approx` and `makeEndpoint` are reused by Task 3.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LinkEstablishmentTimingTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let mesh = InterfaceID("timing-iface")
private let slow202 = InterfaceProfile(name: "slow-202", bitrate: 202)

private func approx(_ a: TimeInterval?, _ b: TimeInterval) -> Bool {
    guard let a else { return false }
    return abs(a - b) < 1e-9
}

/// A driverless endpoint: interfaces are registered straight on the shared router, and transmits
/// to them go nowhere (no driver owns the id), which is all a timing test needs.
@MainActor
private func makeEndpoint(clock: TestClock<Duration> = TestClock()) -> TestStoreOf<TransportEndpoint> {
    let store = TestStore(initialState: TransportEndpoint.State()) { TransportEndpoint() } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// A signed announce for a fresh SINGLE destination, as heard `wireHops` relays away.
private func announce(wireHops: UInt8) -> (raw: Data, destinationHash: Data) {
    let identity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["timing"], identity: identity)!
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0x01, count: 5))
    let payload = Announce.buildPayload(identity: identity, destinationHash: dest.hash,
                                        nameHash: dest.nameHash, randomHash: randomHash)
    var packet = Packet.announce(from: dest, payload: payload)
    packet.hops = wireHops
    return (try! packet.packed(), dest.hash)
}

/// Learn a path the production way: register `profile` under `mesh`, then deliver an announce on it.
@MainActor
private func learnPath(_ store: TestStoreOf<TransportEndpoint>, over profile: InterfaceProfile,
                       wireHops: UInt8) async -> Data {
    let (raw, destHash) = announce(wireHops: wireHops)
    await store.send(.transport(.interfaceConnected(mesh, profile)))
    await store.send(.transport(.received(mesh, raw)))
    await store.skipReceivedActions(strict: false)
    #expect(store.state.transport.learned[destHash]?.hops == wireHops, "the path must come off the wire")
    return destHash
}

@MainActor
private func initiatorTimeout(over profile: InterfaceProfile, wireHops: UInt8) async -> TimeInterval? {
    let store = makeEndpoint()
    let destHash = await learnPath(store, over: profile, wireHops: wireHops)
    await store.send(.openLink(destinationHash: destHash))
    await store.skipReceivedActions(strict: false)
    return store.state.linkPlane.links.first?.establishmentTimeout
}

/// Contract 4, initiator, driven end to end: announce → learned path → `.openLink` → LinkSession.
/// Wire hops; h = max(1, wire).
@Suite @MainActor struct InitiatorEstablishmentTimingTests {
    @Test func fastLinksKeepFifteenSecondsUpToOneWireHop() async {
        #expect(await initiatorTimeout(over: .tcp, wireHops: 0) == 15)
        #expect(await initiatorTimeout(over: .tcp, wireHops: 1) == 15)
        #expect(await initiatorTimeout(over: .ble, wireHops: 0) == 15)
        #expect(await initiatorTimeout(over: .ble, wireHops: 1) == 15)
    }

    @Test func eachFurtherHopAddsSixSeconds() async {
        #expect(approx(await initiatorTimeout(over: .tcp, wireHops: 2), 18.0004))
        #expect(approx(await initiatorTimeout(over: .tcp, wireHops: 3), 24.0004))
        #expect(approx(await initiatorTimeout(over: .ble, wireHops: 2), 18.05))
    }

    @Test func aSlowNextHopStretchesTheTimeout() async {
        #expect(approx(await initiatorTimeout(over: slow202, wireHops: 0), 31.801980198019802))
        #expect(approx(await initiatorTimeout(over: slow202, wireHops: 1), 31.801980198019802))
        #expect(approx(await initiatorTimeout(over: slow202, wireHops: 2), 37.801980198019802))
    }

    @Test func aReRegisteredInterfaceBitrateIsReadWhenTheLinkOpens() async {
        let store = makeEndpoint()
        let destHash = await learnPath(store, over: .tcp, wireHops: 1)
        await store.send(.transport(.interfaceConnected(mesh, slow202)))   // same id, new bitrate
        await store.send(.openLink(destinationHash: destHash))
        await store.skipReceivedActions(strict: false)
        #expect(approx(store.state.linkPlane.links.first?.establishmentTimeout, 31.801980198019802))
    }

    @Test func aSlowNextHopKeepsTheLinkAliveUntilItsStretchedDeadline() async {
        let clock = TestClock()
        let store = makeEndpoint(clock: clock)
        let destHash = await learnPath(store, over: slow202, wireHops: 2)      // 37.80 s
        await store.send(.openLink(destinationHash: destHash))
        await store.skipReceivedActions(strict: false)
        await clock.advance(by: .seconds(37.7))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.linkPlane.links.count == 1, "the old fixed 15 s would already have failed this link")
        await clock.advance(by: .seconds(0.2))
        await store.receive {
            if case .delegate(.linkFailed(destinationHash: _, reason: .establishmentTimedOut)) = $0 { return true }
            return false
        }
        #expect(store.state.linkPlane.links.isEmpty)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter InitiatorEstablishmentTimingTests`
Expected: `fastLinksKeepFifteenSecondsUpToOneWireHop` passes (that is today's value). The other four FAIL, each getting 15; the clock test's link fails at 15 s. Step 6 makes all five fail.

- [ ] **Step 3: Thread the timeout through LinkPlane**

In `Sources/ReTiCANode/LinkPlane.swift`, replace the case (today :84-86):
```swift
        /// Create an initiator link and start establishment.
        case openLink(initiatorTo: Identity, destinationHash: Data,
                      interfaceID: InterfaceID, relayNextHop: Data?)
```
with
```swift
        /// Create an initiator link and start establishment. `establishmentTimeout` is computed by
        /// the host, which can see Transport (`LinkTiming.initiatorEstablishmentTimeout`); this
        /// plane never reads Transport state.
        case openLink(initiatorTo: Identity, destinationHash: Data,
                      interfaceID: InterfaceID, relayNextHop: Data?,
                      establishmentTimeout: TimeInterval = LinkTiming.defaultEstablishmentTimeout)
```
Replace the arm head and construction (today :162-167):
```swift
            case let .openLink(identity, destinationHash, interfaceID, relayNextHop):
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, initiatorTo: identity,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID,
                                                     relayNextHop: relayNextHop))
```
with
```swift
            case let .openLink(identity, destinationHash, interfaceID, relayNextHop, establishmentTimeout):
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, initiatorTo: identity,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID,
                                                     establishmentTimeout: establishmentTimeout,
                                                     relayNextHop: relayNextHop))
```
(`establishmentTimeout:` must come before `relayNextHop:`, matching the init's parameter order at `LinkSession.swift:133-136`.)

- [ ] **Step 4: Compute it in TransportEndpoint (`.openLink` arm only)**

In `Sources/ReTiCANode/TransportEndpoint.swift`, replace the arm's tail (today :185-191):
```swift
                // Via a relay (learned nextHop != the destination) → HEADER_2 LINKREQUEST to the
                // relay. The learned entry records which interface the destination was heard on.
                let relayNextHop: Data? = learned.nextHop == destinationHash ? nil : learned.nextHop
                return .send(.linkPlane(.openLink(initiatorTo: learned.identity,
                                                  destinationHash: destinationHash,
                                                  interfaceID: learned.interfaceID,
                                                  relayNextHop: relayNextHop)))
```
with
```swift
                // Via a relay (learned nextHop != the destination) → HEADER_2 LINKREQUEST to the
                // relay. The learned entry records which interface the destination was heard on.
                let relayNextHop: Data? = learned.nextHop == destinationHash ? nil : learned.nextHop
                // Contract 4: the deadline follows the next hop's bitrate and the path's length,
                // read NOW, so a re-registered interface's new bitrate applies to the next link.
                let timeout = LinkTiming.initiatorEstablishmentTimeout(
                    bitrate: state.transport.nextHopInterfaceProfile(destinationHash)?.bitrate,
                    wireHops: learned.hops)
                return .send(.linkPlane(.openLink(initiatorTo: learned.identity,
                                                  destinationHash: destinationHash,
                                                  interfaceID: learned.interfaceID,
                                                  relayNextHop: relayNextHop,
                                                  establishmentTimeout: timeout)))
```
Also change this arm's comment "exits only via the 15s establishment deadline" to "exits only via the establishment deadline".

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter InitiatorEstablishmentTimingTests`
Expected: 5 pass.

- [ ] **Step 6: Mutation batch (step b)**

`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/TransportEndpoint.swift /tmp/slow-link-timing/TransportEndpoint.swift.orig`
`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/LinkTiming.swift /tmp/slow-link-timing/LinkTiming.swift.orig`

Apply both:
- (a) In the `.openLink` arm, change `wireHops: learned.hops` to `wireHops: learned.hops &+ 1`. This is the reference +1 convention the spec rejected.
- (b) In `initiatorEstablishmentTimeout`, drop the floor: return only the inner sum.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter InitiatorEstablishmentTimingTests`
Expected: all 5 FAIL.
- Fast: wire 0 gives 12.0004 instead of 15.
- Growth: one hop high.
- Slow: wire 1 gives 37.8.
- Re-registered (wire 1): 37.8.
- Clock test (wire 2): 43.8, so the link is still alive at 37.9 s.

- [ ] **Step 7: Revert (step c)**

`cp /tmp/slow-link-timing/TransportEndpoint.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/TransportEndpoint.swift`
`cp /tmp/slow-link-timing/LinkTiming.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/LinkTiming.swift`
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter InitiatorEstablishmentTimingTests`
Expected: 5 pass.

- [ ] **Step 8: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing`
Expected: all pass. If an existing test fails because a path of wire hops ≥ 2 now takes longer than 15 s to time out, that is Contract 4's intended change. Update only that test's clock advance to `LinkTiming.initiatorEstablishmentTimeout(bitrate:wireHops:)` for its own profile and hops, with a comment citing Contract 4, and report it. Any other failure: stop and diagnose.

- [ ] **Step 9: Commit**

`git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing add Sources/ReTiCANode/LinkPlane.swift Sources/ReTiCANode/TransportEndpoint.swift Tests/ReTiCANodeTests/LinkEstablishmentTimingTests.swift`
(Also add any test file changed in Step 8.)

`/tmp/slow-link-timing/commit-task2.txt`:
```
feat: initiator link establishment timeout follows the next hop

TransportEndpoint.openLink computes LinkTiming.initiatorEstablishmentTimeout from
the next-hop interface bitrate and the learned wire hop count and passes it into
LinkPlane.openLink. TCP/BLE keep 15 s up to one wire hop; each further hop adds
6 s; a 202 bps next hop stretches a direct link to ~31.8 s.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing commit -F /tmp/slow-link-timing/commit-task2.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing log -1 '--format=%(trailers:key=Claude-Session)'`

---

### Task 3: Responder establishment timeout follows the arrival interface (no hop term)

**Files:**
- Modify: `Sources/ReTiCANode/LinkPlane.swift:87-89` (case), `:170` and `:229-232` (arm)
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift:311-317` (`.linkRequest` arm only)
- Test: `Tests/ReTiCANodeTests/LinkEstablishmentTimingTests.swift` (append suite `ResponderEstablishmentTimingTests`)

**Interfaces:**
- Consumes: `LinkTiming.responderEstablishmentTimeout(bitrate:)` (Task 1); the file-private helpers `mesh`, `slow202`, `approx`, `makeEndpoint` (Task 2).
- Produces: `LinkPlane.Action.acceptLinkRequest(owner: Identity, destinationHash: Data, interfaceID: InterfaceID, data: Data, arrivalBitrate: Int? = nil)`.

- [ ] **Step 1: Write the failing tests**

Append to `Tests/ReTiCANodeTests/LinkEstablishmentTimingTests.swift`:

```swift
/// An inbound LINKREQUEST for `dest`, carrying `wireHops` (unauthenticated) on the wire.
private func linkRequest(to dest: Destination, wireHops: UInt8) -> Data {
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: wireHops,
                         destinationHash: dest.hash, transportId: nil,
                         payload: Identity().publicKey + Link.signallingBytes)
    return try! request.packed()
}

/// Register a local destination and deliver a LINKREQUEST for it on `mesh` (registered as `profile`).
@MainActor
private func acceptRequest(_ store: TestStoreOf<TransportEndpoint>, arrivingOver profile: InterfaceProfile,
                           wireHops: UInt8) async {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["responder"],
                           identity: Identity())!
    await store.send(.registerLocalDestination(dest))
    await store.send(.transport(.interfaceConnected(mesh, profile)))
    await store.send(.transport(.received(mesh, linkRequest(to: dest, wireHops: wireHops))))
    await store.skipReceivedActions(strict: false)
}

@MainActor
private func responderTimeout(arrivingOver profile: InterfaceProfile, wireHops: UInt8) async -> TimeInterval? {
    let store = makeEndpoint()
    await acceptRequest(store, arrivingOver: profile, wireHops: wireHops)
    return store.state.linkPlane.links.first?.establishmentTimeout
}

/// Amended Contract 4, responder: max(15, 2·4000/b_recv + 6), NO hop term. Driven end to end:
/// LINKREQUEST on the wire → Transport → TransportEndpoint → LinkPlane.acceptLinkRequest → LinkSession.
@Suite @MainActor struct ResponderEstablishmentTimingTests {
    @Test func fastArrivalInterfacesAlwaysGiveFifteenSeconds() async {
        #expect(await responderTimeout(arrivingOver: .tcp, wireHops: 0) == 15)
        #expect(await responderTimeout(arrivingOver: .tcp, wireHops: 3) == 15)
        #expect(await responderTimeout(arrivingOver: .ble, wireHops: 0) == 15)
    }

    @Test func aSlowArrivalInterfaceStretchesTheTimeout() async {
        #expect(approx(await responderTimeout(arrivingOver: slow202, wireHops: 0), 45.603960396039604))
    }

    @Test func hopsNeverStretchTheResponder() async {
        // A LINKREQUEST's hop count is attacker-controlled; 255 must change nothing (and not trap).
        #expect(await responderTimeout(arrivingOver: .tcp, wireHops: 255) == 15)
        #expect(approx(await responderTimeout(arrivingOver: slow202, wireHops: 255), 45.603960396039604))
    }

    @Test func anUnknownArrivalBitrateKeepsFifteenSeconds() async {
        let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
            $0.uuid = .incrementing
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
        }
        store.exhaustivity = .off
        let owner = Identity()
        let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["responder"], identity: owner)!
        await store.send(.acceptLinkRequest(owner: owner, destinationHash: dest.hash, interfaceID: mesh,
                                            data: linkRequest(to: dest, wireHops: 3)))
        #expect(store.state.links.first?.establishmentTimeout == 15)
    }

    @Test func aSlowArrivalKeepsTheHalfOpenLinkUntilItsStretchedDeadline() async {
        let clock = TestClock()
        let store = makeEndpoint(clock: clock)
        await acceptRequest(store, arrivingOver: slow202, wireHops: 0)
        #expect(store.state.linkPlane.links.count == 1)
        await clock.advance(by: .seconds(45.5))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.linkPlane.links.count == 1, "the old fixed 15 s would already have reaped it")
        await clock.advance(by: .seconds(0.2))
        await store.skipReceivedActions(strict: false)
        #expect(store.state.linkPlane.links.isEmpty, "a half-open responder still leaves on its deadline")
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter ResponderEstablishmentTimingTests`
Expected: the suite compiles, because no test passes `arrivalBitrate:` directly. `fastArrivalInterfacesAlwaysGiveFifteenSeconds` and `anUnknownArrivalBitrateKeepsFifteenSeconds` pass (today's behaviour). The slow, hops and clock tests FAIL, each getting 15. Step 6 makes all five fail.

- [ ] **Step 3: Thread the bitrate through LinkPlane**

In `Sources/ReTiCANode/LinkPlane.swift`, replace the case (today :87-89):
```swift
        /// Create a responder link for an inbound LINKREQUEST and accept it.
        case acceptLinkRequest(owner: Identity, destinationHash: Data,
                               interfaceID: InterfaceID, data: Data)
```
with
```swift
        /// Create a responder link for an inbound LINKREQUEST and accept it. `arrivalBitrate` is
        /// the bitrate of the interface the request arrived on (`nil` = unknown → 15 s); it sets the
        /// establishment deadline via `LinkTiming.responderEstablishmentTimeout`.
        case acceptLinkRequest(owner: Identity, destinationHash: Data,
                               interfaceID: InterfaceID, data: Data, arrivalBitrate: Int? = nil)
```
Replace `case let .acceptLinkRequest(owner, destinationHash, interfaceID, data):` (today :170) with `case let .acceptLinkRequest(owner, destinationHash, interfaceID, data, arrivalBitrate):`.

Replace (today :229-232):
```swift
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, responderFor: owner,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID))
```
with
```swift
                let newID = uuid()
                // No hop term: the request's hop count is unauthenticated and must not lengthen a half-open hold.
                let timeout = LinkTiming.responderEstablishmentTimeout(bitrate: arrivalBitrate)
                state.links.append(LinkSession.State(id: newID, responderFor: owner,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID,
                                                     establishmentTimeout: timeout))
```
(Do not add anything to the `maxIncompleteResponderLinks` doc.)

- [ ] **Step 4: Pass the arrival bitrate from TransportEndpoint (`.linkRequest` arm only)**

In `Sources/ReTiCANode/TransportEndpoint.swift`, replace (today :315-317):
```swift
                // Reply on the interface the request arrived from.
                return .send(.linkPlane(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                                           interfaceID: arrivalInterface, data: data)))
```
with
```swift
                // Reply on the interface the request arrived from; its bitrate sets the responder
                // establishment deadline (Contract 4).
                return .send(.linkPlane(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                                           interfaceID: arrivalInterface, data: data,
                                                           arrivalBitrate: state.transport.interfaces[arrivalInterface]?.bitrate)))
```

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter ResponderEstablishmentTimingTests`
Expected: 5 pass.

- [ ] **Step 6: Mutation batch (step b)**

`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/LinkTiming.swift /tmp/slow-link-timing/LinkTiming.swift.orig`
`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/LinkPlane.swift /tmp/slow-link-timing/LinkPlane.swift.orig`

Apply all four:
- (i) `responderEstablishmentTimeout`: drop the floor, returning `2 * firstHopLatency(bitrate: bitrate) + establishmentTimeoutPerHop`.
- (ii) `responderEstablishmentTimeout`: the unknown guard returns `0`.
- (iii) `responderEstablishmentTimeout`: drop the `2 *`.
- (iv) In LinkPlane's arm, construct with `establishmentTimeout: timeout + Double(requestPacket.hops)`. This is a hop leak.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter ResponderEstablishmentTimingTests`
Expected: all 5 FAIL.
- Fast: 6.0008 instead of 15 (wire 0).
- Slow: 25.8.
- Hops: 255 is added.
- Unknown: 0 + 3.
- Clock test: reaped at about 25.8 s.

- [ ] **Step 7: Revert (step c)**

`cp /tmp/slow-link-timing/LinkTiming.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/LinkTiming.swift`
`cp /tmp/slow-link-timing/LinkPlane.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/LinkPlane.swift`
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter ResponderEstablishmentTimingTests`
Expected: 5 pass.

- [ ] **Step 8: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing`
Expected: all pass. Every existing responder test arrives on a fast or default profile (62_500 bps gives 2·0.064 + 6 → 15) or carries no bitrate (15).

- [ ] **Step 9: Commit**

`git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing add Sources/ReTiCANode/LinkPlane.swift Sources/ReTiCANode/TransportEndpoint.swift Tests/ReTiCANodeTests/LinkEstablishmentTimingTests.swift`

`/tmp/slow-link-timing/commit-task3.txt`:
```
feat: responder link establishment timeout follows the arrival interface

TransportEndpoint passes the arrival interface's bitrate into
LinkPlane.acceptLinkRequest, which applies max(15, 2*4000/b + 6). No hop term:
a LINKREQUEST's hops are unauthenticated. TCP/BLE stay at 15 s; a 202 bps arrival
holds a half-open link ~45.6 s.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing commit -F /tmp/slow-link-timing/commit-task3.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing log -1 '--format=%(trailers:key=Claude-Session)'`

---

### Task 4: LXMF retry wait stretches on slow next hops

**Files:**
- Modify: `Sources/ReTiCA/LXMF/LXMFDelivery.swift` (add a func; keep `retryWaitSeconds = 10`, which `LXMessageCrossValidationTests.swift:55` pins against genuine LXMF)
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (State, before `public init()` :118; helper after `retryTimer` :300-305; 12 call sites; doc :241-242)
- Test: `Tests/ReTiCANodeTests/LXMFSlowLinkRetryTests.swift` (suite `LXMFSlowLinkRetryTests`)

**Interfaces:**
- Consumes: `Packet.mtu`.
- Produces:
  - `LXMFDelivery.retryWait(nextHopBitrate: Int?) -> Int`
  - `LXMFRouter.State.nextHopRetryWaits: [Data: Int]` (public var; ABSENT = `LXMFDelivery.retryWaitSeconds`). Task 5 writes it.
  - `LXMFRouter.ResendInfo.destinationHash: Data` (internal)

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFSlowLinkRetryTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let stretched = 80        // LXMFDelivery.retryWait(nextHopBitrate: 202)
private let linkID = Data(repeating: 0x5C, count: 16)

private func message(_ content: Data = Data("small".utf8)) -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: content)
}
private let bigContent = Data((0..<800).map { UInt8($0 & 0xff) })   // > Link.mdu → sent as a Resource

@MainActor
private func makeRouter(_ initial: LXMFRouter.State, _ clock: TestClock<Duration>) -> TestStoreOf<LXMFRouter> {
    let store = TestStore(initialState: initial) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@MainActor
private func advance(_ store: TestStoreOf<LXMFRouter>, _ clock: TestClock<Duration>, _ seconds: Int) async {
    await clock.advance(by: .seconds(seconds))
    await store.skipReceivedActions(strict: false)
}

@Suite @MainActor struct LXMFSlowLinkRetryTests {
    // --- the formula: max(10, ⌈4 · 500·8 / b⌉) ---

    @Test func fastLinksKeepTheTenSecondRetry() {
        #expect(LXMFDelivery.retryWait(nextHopBitrate: InterfaceProfile.tcp.bitrate) == 10)
        #expect(LXMFDelivery.retryWait(nextHopBitrate: InterfaceProfile.ble.bitrate) == 10)
        #expect(LXMFDelivery.retryWait(nextHopBitrate: InterfaceProfile.default.bitrate) == 10)
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 1600) == 10)            // exactly 10.0
    }

    @Test func slowLinksStretchTheRetryToFourPacketAirtimesRoundedUp() {
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 202) == 80)             // 79.2
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 538) == 30)             // 29.7
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 107) == 150)            // 149.5
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 1599) == 11)            // 10.006
    }

    @Test func anUnknownBitrateKeepsTheTenSecondRetry() {
        #expect(LXMFDelivery.retryWait(nextHopBitrate: nil) == 10)
        #expect(LXMFDelivery.retryWait(nextHopBitrate: 0) == 10)
        #expect(LXMFDelivery.retryWait(nextHopBitrate: -5) == 10)
    }

    // --- every retry-arming arm reads the destination's wait ---

    @Test func opportunisticSendAndResendBothWaitTheStretchedWait() async {
        let msg = message(); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.knownPaths.insert(msg.destinationHash)
        initial.nextHopRetryWaits[msg.destinationHash] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .opportunistic))
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)   // `.send` arm
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 2)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 3)   // `.retryDue` resend
    }

    @Test func aDirectLinkPacketAndItsResendBothWaitTheStretchedWait() async {
        let msg = message(); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.directLinks[msg.destinationHash] = .active(linkID: linkID)
        initial.nextHopRetryWaits[msg.destinationHash] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .direct))
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)   // `.send` direct arm
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 2)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 3)   // `.retryDue` direct resend
    }

    @Test func aPacketDrainedOnLinkEstablishedWaitsTheStretchedWait() async {
        let msg = message(); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.knownPaths.insert(msg.destinationHash)
        initial.nextHopRetryWaits[msg.destinationHash] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .direct))                 // queued; requestLink
        await store.send(.linkEstablished(destinationHash: msg.destinationHash, linkID: linkID))   // drain
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)
    }

    @Test func aFailedResourceAndItsLinkDownRecheckBothWaitTheStretchedWait() async {
        let msg = message(bigContent); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.directLinks[msg.destinationHash] = .active(linkID: linkID)
        initial.nextHopRetryWaits[msg.destinationHash] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .direct))                 // Resource in flight
        #expect(store.state.pendingDeliveries[key]?.phase == .transferring)
        await store.send(.resourceFailedOnLink(linkID: linkID, rejected: false))      // link torn down
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)   // failure arm
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 2)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 3)   // link-down re-check
    }

    @Test func aResourceOrphanedByALostLinkWaitsTheStretchedWait() async {
        let msg = message(bigContent); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.knownPaths.insert(msg.destinationHash)
        initial.directLinks[msg.destinationHash] = .active(linkID: linkID)
        initial.nextHopRetryWaits[msg.destinationHash] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .direct))
        await store.send(.linkClosed(destinationHash: msg.destinationHash))          // orphanTransfer
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)
    }

    @Test func aPropagatedPacketWaitsTheStretchedWaitWithAndWithoutItsLink() async {
        let msg = message(); let clock = TestClock()
        let pn = Data(repeating: 0x9A, count: 16)
        var initial = LXMFRouter.State()
        initial.outboundPropagationNode = pn
        initial.directLinks[pn] = .active(linkID: linkID)
        initial.nextHopRetryWaits[pn] = stretched
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.propagated(msg.hash)
        await store.send(.sendViaPropagation(message: msg, propagationPacked: Data(repeating: 0xAB, count: 100)))
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 2)   // `.sendViaPropagation` arm
        await store.send(.linkClosed(destinationHash: pn))                           // the PN link drops
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 2)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 3)   // resend (armed with link up)
        await advance(store, clock, 79); #expect(store.state.pendingDeliveries[key]?.attempts == 3)
        await advance(store, clock, 1);  #expect(store.state.pendingDeliveries[key]?.attempts == 4)   // link-down re-check
    }

    @Test func aDestinationWithNoEntryKeepsTenSeconds() async {
        let msg = message(); let clock = TestClock()
        var initial = LXMFRouter.State()
        initial.knownPaths.insert(msg.destinationHash)
        let store = makeRouter(initial, clock)
        let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
        await store.send(.send(message: msg, desiredMethod: .opportunistic))
        await advance(store, clock, 9); #expect(store.state.pendingDeliveries[key]?.attempts == 1)
        await advance(store, clock, 1); #expect(store.state.pendingDeliveries[key]?.attempts == 2)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LXMFSlowLinkRetryTests`
Expected: compile errors, `type 'LXMFDelivery' has no member 'retryWait'` and `value of type 'LXMFRouter.State' has no member 'nextHopRetryWaits'`.

- [ ] **Step 3: Implement the formula**

In `Sources/ReTiCA/LXMF/LXMFDelivery.swift`, after `retryWaitSeconds` (:8), add:

```swift
    /// The retry wait for a copy whose destination's next hop runs at `nextHopBitrate` bits/s:
    /// `max(retryWaitSeconds, ⌈4 · MTU·8 / b⌉)` — four MTU packets of airtime (2026-10-16
    /// Meshtastic spec, Contract 4). Rounded UP because router timers take whole seconds; never
    /// below the reference's fixed 10 s, so TCP and BLE are unchanged. `nil` or `≤ 0` (no path, no
    /// profile) → `retryWaitSeconds`.
    ///
    /// DELIBERATE DEVIATION from reference, which keeps `DELIVERY_RETRY_WAIT` fixed: at ~200 bps a
    /// 391-byte packet is ~24 s of airtime, so a fixed 10 s retry stacks duplicates on the medium.
    public static func retryWait(nextHopBitrate: Int?) -> Int {
        guard let bitrate = nextHopBitrate, bitrate > 0 else { return retryWaitSeconds }
        let airtime = (4.0 * Double(Packet.mtu * 8) / Double(bitrate)).rounded(.up)
        return max(retryWaitSeconds, Int(airtime))
    }
```

- [ ] **Step 4: Router state, helper, and every retry site**

In `Sources/ReTiCANode/LXMFRouter.swift`, State: directly before `public init() {}` (today :118), add:
```swift
        /// destinationHash → retry wait (seconds) for copies addressed there, for destinations whose
        /// next hop is slow enough to stretch it (`LXMFDelivery.retryWait(nextHopBitrate:)`).
        /// ABSENT means `LXMFDelivery.retryWaitSeconds`: fast paths are never stored, so on TCP/BLE
        /// this map stays empty. Written by `LXMFNode`, which can read Transport; the router only reads it.
        public var nextHopRetryWaits: [Data: Int] = [:]
```

Directly after the `retryTimer` local func (today :300-305), add:
```swift
            /// Arm `key`'s retry timer at its destination's wait. EVERY delivery-retry site uses this
            /// (the path-request wait is separate); `key` is armed in `pendingDeliveries` first.
            func deliveryRetryTimer(_ state: State, _ key: DeliveryKey) -> Effect<Action> {
                let wait = state.pendingDeliveries[key].flatMap { state.nextHopRetryWaits[$0.resend.destinationHash] }
                    ?? LXMFDelivery.retryWaitSeconds
                return retryTimer(key, wait)
            }
```

Replace every `retryTimer(key, LXMFDelivery.retryWaitSeconds)` with `deliveryRetryTimer(state, key)` (Edit with `replace_all: true`). There are exactly 12, today at :377, :596, :609, :643, :710, :720, :820, :915, :920, :924, :931, :937. Do NOT touch `retryTimer(key, LXMFDelivery.pathRequestWaitSeconds)` (:911). Every site arms `pendingDeliveries[key]` before the call.

Run: `grep -n "LXMFDelivery.retryWaitSeconds" /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/LXMFRouter.swift`
Expected: exactly ONE line, inside `deliveryRetryTimer`.

At the end of the file, add:
```swift

extension LXMFRouter.ResendInfo {
    /// The destination this copy is addressed to: the recipient, or the propagation node.
    var destinationHash: Data {
        switch self {
        case let .opportunistic(destinationHash, _): return destinationHash
        case let .direct(destinationHash, _, _): return destinationHash
        case let .propagated(destinationHash, _): return destinationHash
        }
    }
}
```

Update the `resourceFailedOnLink` doc (today :241-242), from "…retried once, `retryWaitSeconds` later." to "…retried once, after the destination's retry wait (`nextHopRetryWaits`, default `retryWaitSeconds`)."

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LXMFSlowLinkRetryTests`
Expected: 10 pass.

- [ ] **Step 6: Mutation batch (step b)**

`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCA/LXMF/LXMFDelivery.swift /tmp/slow-link-timing/LXMFDelivery.swift.orig`
`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/LXMFRouter.swift /tmp/slow-link-timing/LXMFRouter.swift.orig`

Apply all:
- `retryWait`: (M1) `return Int(airtime)` (floor dropped); (M2) `.rounded(.down)`; (M3) the guard returns `0`.
- `deliveryRetryTimer`: body becomes `retryTimer(key, LXMFDelivery.retryWaitSeconds + 1)`. It ignores the table and uses the wrong constant.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LXMFSlowLinkRetryTests`
Expected: all 10 FAIL. Fast gives 0. Slow gives 79 / 29 / 149 / 10. Unknown gives 0. Every router test retries at 11 s, so its 79 s or 9 s attempt check fails.

- [ ] **Step 7: Revert (step c)**

`cp /tmp/slow-link-timing/LXMFDelivery.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCA/LXMF/LXMFDelivery.swift`
`cp /tmp/slow-link-timing/LXMFRouter.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/LXMFRouter.swift`
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LXMFSlowLinkRetryTests`
Expected: 10 pass.

- [ ] **Step 8: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing`
Expected: all pass. Nothing writes `nextHopRetryWaits` yet.

- [ ] **Step 9: Commit**

`git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing add Sources/ReTiCA/LXMF/LXMFDelivery.swift Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFSlowLinkRetryTests.swift`

`/tmp/slow-link-timing/commit-task4.txt`:
```
feat: LXMF retry wait stretches on slow next hops

LXMFDelivery.retryWait(nextHopBitrate:) = max(10, ceil(4 * 4000 / b)). LXMFRouter
arms every delivery retry through deliveryRetryTimer, which reads a per-destination
nextHopRetryWaits table (absent = 10 s). Nothing populates the table yet.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing commit -F /tmp/slow-link-timing/commit-task4.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing log -1 '--format=%(trailers:key=Claude-Session)'`

---

### Task 5: LXMFNode feeds next-hop retry waits to the router

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (`.pathLearned` arm, today :797-798; `deliverySend`, today :1183-1187; a new private func before the `deliveryStampCost` doc, today :1136)
- Test: `Tests/ReTiCANodeTests/LXMFNodeSlowLinkRetryTests.swift` (suite `LXMFNodeSlowLinkRetryTests`)

**Interfaces:**
- Consumes: `Transport.State.nextHopInterfaceProfile(_:)` (Task 1), `LXMFDelivery.retryWait(nextHopBitrate:)` and `LXMFRouter.State.nextHopRetryWaits` (Task 4).
- Produces: `private func refreshNextHopRetryWait(_ state: inout LXMFNode.State, _ destinationHash: Data)`. No public API change.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFNodeSlowLinkRetryTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let slowIface = InterfaceID("lxmf-slow-iface")
private let fastIface = InterfaceID("lxmf-fast-iface")
private let slow202 = InterfaceProfile(name: "slow-202", bitrate: 202)
private let sentAt: TimeInterval = 1700000000.5

@MainActor
private func makeNode(_ identity: Identity, _ clock: TestClock<Duration>) -> TestStoreOf<LXMFNode> {
    let store = TestStore(initialState: LXMFNode.State(identity: identity, endpoint: TransportEndpoint.State())) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: sentAt))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// Peer's lxmf.delivery announce, heard `wireHops` relays away, emitted at `now`.
private func deliveryAnnounce(of peer: Identity, wireHops: UInt8, now: UInt64 = 1_700_000_000,
                              prefix: UInt8 = 0x02) -> Data {
    let dest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                           aspects: LXMessage.deliveryAspects, identity: peer)!
    let randomHash = Announce.randomHash(now: now, randomPrefix: Data(repeating: prefix, count: 5))
    let payload = Announce.buildPayload(identity: peer, destinationHash: dest.hash,
                                        nameHash: dest.nameHash, randomHash: randomHash)
    var packet = Packet.announce(from: dest, payload: payload)
    packet.hops = wireHops
    return try! packet.packed()
}

@MainActor
private func hear(_ store: TestStoreOf<LXMFNode>, _ raw: Data, on iface: InterfaceID, as profile: InterfaceProfile) async {
    await store.send(.endpoint(.transport(.interfaceConnected(iface, profile))))
    await store.send(.endpoint(.transport(.received(iface, raw))))
    await store.skipReceivedActions(strict: false)
}

/// Send an opportunistic message to `peer`; returns its hash.
@MainActor
private func sendTo(_ store: TestStoreOf<LXMFNode>, from me: Identity, _ peer: Identity) async -> Data {
    let dest = LXMessage.deliveryHash(identityHash: peer.hash)
    await store.send(.send(destinationHash: dest, title: Data("t".utf8), content: Data("hi".utf8), method: .opportunistic))
    return LXMessage.create(source: me, destinationHash: dest, timestamp: sentAt,
                            title: Data("t".utf8), content: Data("hi".utf8)).hash
}

@MainActor
private func attemptsAfter(_ store: TestStoreOf<LXMFNode>, _ clock: TestClock<Duration>, _ seconds: Int,
                           _ hash: Data) async -> Int? {
    await clock.advance(by: .seconds(seconds))
    await store.skipReceivedActions(strict: false)
    return store.state.router.pendingDeliveries[.delivery(hash)]?.attempts
}

@Suite @MainActor struct LXMFNodeSlowLinkRetryTests {
    @Test func anAnnounceOverASlowInterfaceStretchesTheRetryWait() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await hear(store, deliveryAnnounce(of: peer, wireHops: 0), on: slowIface, as: slow202)
        #expect(store.state.router.nextHopRetryWaits[dest] == 80)                 // written at pathLearned
        let hash = await sendTo(store, from: me, peer)
        #expect(await attemptsAfter(store, clock, 79, hash) == 1)
        #expect(await attemptsAfter(store, clock, 1, hash) == 2)
    }

    @Test(arguments: [InterfaceProfile.tcp, .ble], [UInt8(0), 1, 4])
    func aFastNextHopKeepsTheTenSecondRetryAtEveryHopCount(profile: InterfaceProfile, wireHops: UInt8) async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        await hear(store, deliveryAnnounce(of: peer, wireHops: wireHops), on: fastIface, as: profile)
        let hash = await sendTo(store, from: me, peer)
        #expect(store.state.router.nextHopRetryWaits.isEmpty, "fast paths are never stored")
        #expect(await attemptsAfter(store, clock, 9, hash) == 1)
        #expect(await attemptsAfter(store, clock, 1, hash) == 2)
    }

    @Test func aPathMovingToAFastInterfaceDropsTheStretchedWait() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await hear(store, deliveryAnnounce(of: peer, wireHops: 0), on: slowIface, as: slow202)
        #expect(store.state.router.nextHopRetryWaits[dest] == 80)
        // A NEWER announce (later emission time, fresh blob) over TCP replaces the path.
        await hear(store, deliveryAnnounce(of: peer, wireHops: 0, now: 1_700_000_100, prefix: 0x03),
                   on: fastIface, as: .tcp)
        #expect(store.state.endpoint.transport.learned[dest]?.interfaceID == fastIface)
        #expect(store.state.router.nextHopRetryWaits[dest] == nil)
    }

    @Test func aRehydratedSlowPathStretchesTheRetryAtFirstSend() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await store.send(.endpoint(.transport(.interfaceConnected(slowIface, slow202))))
        await store.send(.endpoint(.transport(.rehydrateLearnedDestinations([dest: LearnedDestination(
            identity: peer, appData: nil, ratchet: nil, interfaceID: slowIface, hops: 0, nextHop: dest,
            announceEmitted: 0, learnedAt: Date(timeIntervalSince1970: 0))]))))
        #expect(store.state.router.nextHopRetryWaits[dest] == nil, "no pathLearned fires on rehydration")
        let hash = await sendTo(store, from: me, peer)
        #expect(store.state.router.nextHopRetryWaits[dest] == 80)                 // written at send
        #expect(await attemptsAfter(store, clock, 79, hash) == 1)
        #expect(await attemptsAfter(store, clock, 1, hash) == 2)
    }

    @Test func aReRegisteredInterfaceBitrateIsReadAtSend() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await hear(store, deliveryAnnounce(of: peer, wireHops: 0), on: slowIface, as: .tcp)
        #expect(store.state.router.nextHopRetryWaits[dest] == nil)
        await store.send(.endpoint(.transport(.interfaceConnected(slowIface, slow202))))   // same id, slower
        let hash = await sendTo(store, from: me, peer)
        #expect(store.state.router.nextHopRetryWaits[dest] == 80)
        #expect(await attemptsAfter(store, clock, 79, hash) == 1)
        #expect(await attemptsAfter(store, clock, 1, hash) == 2)
    }

    @Test func aDisconnectedNextHopFallsBackToTenSecondsAtSend() async {
        let me = Identity(), peer = Identity(), clock = TestClock()
        let store = makeNode(me, clock)
        let dest = LXMessage.deliveryHash(identityHash: peer.hash)
        await hear(store, deliveryAnnounce(of: peer, wireHops: 0), on: slowIface, as: slow202)
        #expect(store.state.router.nextHopRetryWaits[dest] == 80)
        await store.send(.endpoint(.transport(.interfaceDisconnected(slowIface))))
        let hash = await sendTo(store, from: me, peer)
        #expect(store.state.router.nextHopRetryWaits[dest] == nil, "no reachable next hop → unknown bitrate")
        #expect(await attemptsAfter(store, clock, 9, hash) == 1)
        #expect(await attemptsAfter(store, clock, 1, hash) == 2)
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LXMFNodeSlowLinkRetryTests`
Expected: the slow, path-move, rehydrated, re-registered and disconnected tests FAIL, because nothing writes `nextHopRetryWaits` (the disconnected test fails at its `== 80` precondition). The six fast cases pass (today's behaviour). Step 6 makes every test fail.

- [ ] **Step 3: Add the refresh helper**

In `Sources/ReTiCANode/LXMFNode.swift`, directly before the `deliveryStampCost` doc comment (today :1136), add:

```swift
    /// Copy Transport's CURRENT next hop for `destinationHash` into the router's retry-wait table
    /// (Contract 4: LXMF retry wait = max(10, 4·MTU·8/b)). A wait equal to the default is REMOVED
    /// rather than stored, so on TCP/BLE the router's state never changes.
    ///
    /// Called where a path can appear or change (`.pathLearned`) and immediately before a delivery
    /// copy is handed to the router (`deliverySend`). The second call covers what the first cannot
    /// see: a path restored by `rehydrateLearnedDestinations` (no `pathLearned`), an interface
    /// re-registered under the same id with a new bitrate, and a next hop that has disconnected
    /// (falls back to the default). Accepted gap (spec): a change DURING a retry run is seen only at
    /// the next announce or send.
    private func refreshNextHopRetryWait(_ state: inout State, _ destinationHash: Data) {
        let bitrate = state.endpoint.transport.nextHopInterfaceProfile(destinationHash)?.bitrate
        let wait = LXMFDelivery.retryWait(nextHopBitrate: bitrate)
        let stored: Int? = wait == LXMFDelivery.retryWaitSeconds ? nil : wait
        if state.router.nextHopRetryWaits[destinationHash] != stored {
            state.router.nextHopRetryWaits[destinationHash] = stored
        }
    }
```

- [ ] **Step 4: Call it from both sites**

In the `.pathLearned` arm (today :797-798), replace
```swift
            case let .endpoint(.delegate(.pathLearned(h, _))):
                var effects: [Effect<Action>] = [.send(.router(.learnedPath(destinationHash: h)))]
```
with
```swift
            case let .endpoint(.delegate(.pathLearned(h, _))):
                // Synchronous, before the router sees anything for `h` (Transport already holds the
                // new path: its Scope ran first).
                refreshNextHopRetryWait(&state, h)
                var effects: [Effect<Action>] = [.send(.router(.learnedPath(destinationHash: h)))]
```

In `deliverySend` (today :1183-1187), make the first statement of the body
```swift
        refreshNextHopRetryWait(&state, message.destinationHash)
```
so it runs before the `guard`, on both the unstamped and the stamped paths.

- [ ] **Step 5: Run to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LXMFNodeSlowLinkRetryTests`
Expected: 11 pass (the parameterized test counts as 6).

- [ ] **Step 6: Mutation batch (step b)**

`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/LXMFNode.swift /tmp/slow-link-timing/LXMFNode.swift.orig`

Mutation: in `refreshNextHopRetryWait`, replace the `let stored: Int? = …` line with `let stored: Int? = 81`. It always stores a wrong constant.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LXMFNodeSlowLinkRetryTests`
Expected: all FAIL. Slow, rehydrated and re-registered see 81 instead of 80. Fast and disconnected see an entry instead of none, and no retry at 10 s. Path-move keeps 81.

- [ ] **Step 7: Revert (step c)**

`cp /tmp/slow-link-timing/LXMFNode.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/LXMFNode.swift`
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter LXMFNodeSlowLinkRetryTests`
Expected: all pass.

- [ ] **Step 8: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing`
Expected: all pass. Existing LXMFNode tests use TCP, BLE or default profiles, whose wait is 10 s and is never stored. If an exhaustive test fails on `router.nextHopRetryWaits`, add that assertion to the test. Do not disable exhaustivity.

- [ ] **Step 9: Commit**

`git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing add Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFNodeSlowLinkRetryTests.swift`

`/tmp/slow-link-timing/commit-task5.txt`:
```
feat: LXMFNode feeds next-hop retry waits to the router

refreshNextHopRetryWait copies Transport's current next-hop bitrate into
LXMFRouter.nextHopRetryWaits at pathLearned and before every delivery send, so a
202 bps next hop retries at 80 s while TCP/BLE stay at 10 s with no state change.
Covers rehydrated paths, re-registered interfaces and disconnected next hops.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing commit -F /tmp/slow-link-timing/commit-task5.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing log -1 '--format=%(trailers:key=Claude-Session)'`

---

### Task 6: Targeted announce on one interface

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift:242` (case), `:1017` and `:1063` (arm)
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift` (new case directly below `case announce`, today :99; new arm directly below the `.announce` arm, today :164; nothing else)
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (new case after `.announceDelivery`, today :238-242; new arm after its arm, today :554-559)
- Test: `Tests/ReTiCANodeTests/TargetedAnnounceTests.swift` (suite `TargetedAnnounceTests`)

**Interfaces:**
- Produces:
  - `Transport.Action.announce(destinationHash: Data, appData: Data?, interface: InterfaceID? = nil)`. `nil` = every interface (today). Every existing two-argument construction still compiles.
  - `TransportEndpoint.Action.announceOn(interface: InterfaceID, destinationHash: Data, appData: Data?)`
  - `LXMFNode.Action.announceDeliveryOnInterface(InterfaceID)`, which lane E calls from the app's interface-up handler.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/TargetedAnnounceTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let i1 = InterfaceID("ann-i1")
private let i2 = InterfaceID("ann-i2")
private let i3 = InterfaceID("ann-i3-never-connected")

@MainActor
private func routerWithTwoInterfaces() async -> (TestStoreOf<Transport>, Destination) {
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["me"], identity: Identity())!
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(Date(timeIntervalSince1970: 1_700_000_000))
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(i1, .tcp))
    await store.send(.interfaceConnected(i2, .tcp))
    await store.send(.registerLocalDestination(dest))
    return (store, dest)
}

/// No-transmit assertions follow the repo pattern: send under `.off`, then flip to `.on`. Under
/// `.on`, `receive` must match the NEXT queued action and teardown fails on any leftover, so a
/// stray transmit is caught whatever order the `.merge` produced. (An `.off` receive would skip it.)
@Suite @MainActor struct TargetedAnnounceTests {
    @Test func aTargetedAnnounceTransmitsOnlyOnTheNamedInterface() async {
        let (store, dest) = await routerWithTwoInterfaces()
        await store.send(.announce(destinationHash: dest.hash, appData: nil, interface: i1))
        store.exhaustivity = .on
        await store.receive { action in
            if case let .delegate(.transmit(id, _)) = action { return id == i1 }
            return false
        }
    }

    @Test func aTargetedAnnounceToADisconnectedInterfaceTransmitsNothing() async {
        let (store, dest) = await routerWithTwoInterfaces()
        store.exhaustivity = .on
        await store.send(.announce(destinationHash: dest.hash, appData: nil, interface: i3))   // nothing may follow
        // Control: the same destination DOES announce, so the silence above is not vacuous.
        await store.send(.announce(destinationHash: dest.hash, appData: nil, interface: i1))
        await store.receive { action in
            if case let .delegate(.transmit(id, _)) = action { return id == i1 }
            return false
        }
    }

    @Test func theEndpointThreadsTheInterfaceToTheRouter() async {
        let store = TestStore(initialState: TransportEndpoint.State()) { TransportEndpoint() } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        let h = Data(repeating: 0x21, count: 16)
        await store.send(.announceOn(interface: i1, destinationHash: h, appData: Data([0x01])))
        await store.receive(.transport(.announce(destinationHash: h, appData: Data([0x01]), interface: i1)))
    }

    @Test func announceDeliveryOnInterfaceGoesOutOnlyThatInterface() async {
        let store = TestStore(initialState: LXMFNode.State(identity: Identity(), endpoint: TransportEndpoint.State())) {
            LXMFNode()
        } withDependencies: {
            $0.continuousClock = TestClock()
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        await store.send(.endpoint(.transport(.interfaceConnected(i1, .tcp))))
        await store.send(.endpoint(.transport(.interfaceConnected(i2, .tcp))))
        await store.send(.registerDelivery)                       // announces on both; skipped below
        await store.skipReceivedActions(strict: false)
        store.exhaustivity = .on
        await store.send(.announceDeliveryOnInterface(i1))
        await store.receive { if case let .endpoint(.announceOn(id, _, _)) = $0 { return id == i1 }; return false }
        await store.receive { if case let .endpoint(.transport(.announce(_, _, id))) = $0 { return id == i1 }; return false }
        await store.receive { if case let .endpoint(.transport(.delegate(.transmit(id, _)))) = $0 { return id == i1 }; return false }
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter TargetedAnnounceTests`
Expected: compile errors, `extra argument 'interface' in call`, `type 'TransportEndpoint.Action' has no member 'announceOn'`, and `type 'LXMFNode.Action' has no member 'announceDeliveryOnInterface'`.

- [ ] **Step 3: Transport**

In `Sources/ReTiCATransport/Transport.swift`, replace `case announce(destinationHash: Data, appData: Data?)` (today :242) with:
```swift
        /// Announce a local destination. `interface: nil` sends on every connected interface (the
        /// original behaviour). A non-nil `interface` sends on THAT interface only — used to
        /// re-announce on an interface that just came up (2026-10-16 Meshtastic spec, Contract 4) —
        /// and on nothing when it is not connected: never a silent fallback to every interface.
        case announce(destinationHash: Data, appData: Data?, interface: InterfaceID? = nil)
```
Replace `case let .announce(destinationHash, appData):` (today :1017) with `case let .announce(destinationHash, appData, interface):`.
Replace the arm's last line (today :1063):
```swift
                return .merge(state.interfaces.keys.map { .send(.delegate(.transmit($0, raw))) })
```
with
```swift
                let targets: [InterfaceID] = interface.map { state.interfaces[$0] != nil ? [$0] : [] }
                    ?? Array(state.interfaces.keys)
                return .merge(targets.map { .send(.delegate(.transmit($0, raw))) })
```

- [ ] **Step 4: TransportEndpoint (one case + one arm)**

Directly below `case announce(destinationHash: Data, appData: Data?)` (today :99), add:
```swift
        /// Announce on ONE interface only (nothing when it is not connected) — see
        /// `Transport.Action.announce(interface:)`. A separate case so existing
        /// `.announce(_, appData)` pattern matches keep compiling.
        case announceOn(interface: InterfaceID, destinationHash: Data, appData: Data?)
```
Directly below the `.announce` arm (today :164), add:
```swift
            case let .announceOn(i, h, a):          return .send(.transport(.announce(destinationHash: h, appData: a,
                                                                                      interface: i)))
```

- [ ] **Step 5: LXMFNode**

Directly below `case announceDelivery` (today :242), add:
```swift
        /// Announce the delivery destination on ONE interface: the interface-up re-announce
        /// (2026-10-16 Meshtastic spec, Contract 4), so a node joining a slow link does not
        /// re-broadcast on every other interface too. Same app data and same no-op rule as
        /// `.announceDelivery`; transmits nothing when that interface is not connected.
        case announceDeliveryOnInterface(InterfaceID)
```
Directly below the `.announceDelivery` arm (after today :559), add:
```swift
            case let .announceDeliveryOnInterface(interfaceID):
                guard let hash = state.deliveryDestinationHash else { return .none }
                let appData = LXMFAnnounceData.pack(displayName: state.displayName,
                                                    stampCost: state.deliveryStampCost)
                return .send(.endpoint(.announceOn(interface: interfaceID, destinationHash: hash, appData: appData)))
```
Add one sentence to `.announceDelivery`'s doc: "For the interface-up re-announce use `.announceDeliveryOnInterface`."

- [ ] **Step 6: Run to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter TargetedAnnounceTests`
Expected: 4 pass.

- [ ] **Step 7: Mutation batch (step b)**

`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/Transport.swift /tmp/slow-link-timing/Transport.swift.orig`
`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/TransportEndpoint.swift /tmp/slow-link-timing/TransportEndpoint.swift.orig`
`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/LXMFNode.swift /tmp/slow-link-timing/LXMFNode.swift.orig`

Apply all:
- Transport: `let targets: [InterfaceID] = Array(state.interfaces.keys)`, ignoring `interface`.
- TransportEndpoint `announceOn` arm: pass `interface: nil`.
- LXMFNode `announceDeliveryOnInterface` arm: send `.endpoint(.announce(destinationHash: hash, appData: appData))` (untargeted).

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter TargetedAnnounceTests`
Expected: all 4 FAIL. Tests 1 and 2: a stray `ann-i2` transmit is left in the queue or arrives first. Test 3: `interface: nil` does not match. Test 4: an `.announce` arrives, not an `.announceOn`.

- [ ] **Step 8: Revert (step c)**

`cp /tmp/slow-link-timing/Transport.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/Transport.swift`
`cp /tmp/slow-link-timing/TransportEndpoint.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/TransportEndpoint.swift`
`cp /tmp/slow-link-timing/LXMFNode.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCANode/LXMFNode.swift`
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter TargetedAnnounceTests`
Expected: 4 pass.

- [ ] **Step 9: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing`
Expected: all pass, including `announceFansOutToAllInterfaces` (TransportTests.swift:614), which keeps the untargeted behaviour.

- [ ] **Step 10: Commit**

`git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing add Sources/ReTiCATransport/Transport.swift Sources/ReTiCANode/TransportEndpoint.swift Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/TargetedAnnounceTests.swift`

`/tmp/slow-link-timing/commit-task6.txt`:
```
feat: targeted announce on a single interface

Transport.Action.announce gains interface: InterfaceID? = nil (nil = every
interface). A named interface gets the announce alone, and a disconnected one gets
nothing. TransportEndpoint.announceOn and LXMFNode.announceDeliveryOnInterface
expose it for the app's interface-up re-announce (lane E).

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing commit -F /tmp/slow-link-timing/commit-task6.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing log -1 '--format=%(trailers:key=Claude-Session)'`

---

### Task 7: Relay link-table proof deadline allows one MTU of arrival-interface airtime

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift:753-757` (the relay `.linkRequest` branch's `LinkTableEntry` construction)
- Test: `Tests/ReTiCATransportTests/RelayLinkProofDeadlineTests.swift` (suite `RelayLinkProofDeadlineTests`)

**Interfaces:**
- Consumes: `LinkTiming.relayProofExtraTimeout(bitrate:)` (Task 1).
- Produces: no new API. `LinkTableEntry.proofDeadline` = `now + 6·max(1, entry.hops) + L(b_recv)`, where `b_recv` = `state.interfaces[interfaceID]?.bitrate`, the interface the LINKREQUEST arrived on. This follows reference `extra_link_proof_timeout(packet.receiving_interface)` (`RNS/Transport.py:1643`, local 1.4.1 fork).

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCATransportTests/RelayLinkProofDeadlineTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let inIf = InterfaceID("relay-in")
private let outIf = InterfaceID("relay-out")
private let slow202 = InterfaceProfile(name: "slow-202", bitrate: 202)
private let now = Date(timeIntervalSince1970: 1_700_000_000)

/// Drive a real relay: learn `dest` from an announce heard on `outIf` (as a leaf, so no re-broadcast
/// timer is scheduled), become a relay, then forward a HEADER_2 LINKREQUEST arriving on `inIf`.
/// Returns the forwarded link's proof deadline, in seconds after `now`.
///
/// The inbound and outbound profiles always DIFFER in these tests, so reading the wrong interface's
/// bitrate cannot pass by accident.
@MainActor
private func relayProofDeadline(in inProfile: InterfaceProfile, out outProfile: InterfaceProfile,
                                inStillConnected: Bool = true) async -> TimeInterval? {
    let store = TestStore(initialState: Transport.State()) { Transport() } withDependencies: {
        $0.transportDate = .constant(now)
        $0.continuousClock = TestClock()
    }
    store.exhaustivity = .off
    await store.send(.interfaceConnected(inIf, inProfile))
    await store.send(.interfaceConnected(outIf, outProfile))

    let destIdentity = Identity()
    let dest = Destination(kind: .single, direction: .in, appName: "app", aspects: ["relayed"], identity: destIdentity)!
    let randomHash = Announce.randomHash(now: 1_700_000_000, randomPrefix: Data(repeating: 0x07, count: 5))
    let payload = Announce.buildPayload(identity: destIdentity, destinationHash: dest.hash,
                                        nameHash: dest.nameHash, randomHash: randomHash)
    await store.send(.received(outIf, try! Packet.announce(from: dest, payload: payload).packed()))
    #expect(store.state.learned[dest.hash]?.interfaceID == outIf)

    let relay = Identity()
    await store.send(.setTransportIdentity(relay))
    // Transport does not drop `.received` for an unregistered id (Transport.swift:432-442), so a
    // request "arriving" on a deregistered interface still reaches the relay branch with no bitrate.
    if !inStillConnected { await store.send(.interfaceDisconnected(inIf)) }

    let request = Packet(headerType: .header2, packetType: .linkRequest, transportType: .transport,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: dest.hash, transportId: relay.hash,
                         payload: Identity().publicKey + Link.signallingBytes)
    await store.send(.received(inIf, try! request.packed()))
    await store.skipReceivedActions(strict: false)
    return store.state.linkTable[Link.linkID(requestPacket: request)]?.proofDeadline.timeIntervalSince(now)
}

private func approx(_ a: TimeInterval?, _ b: TimeInterval) -> Bool {
    guard let a else { return false }
    return abs(a - b) < 1e-6      // Date resolution at 2023 epochs is ~1e-7 s
}

/// Amended Contract 4: proof deadline = now + 6·max(1, hops) + 4000/b_recv (unknown b_recv → + 0),
/// b_recv = the interface the LINKREQUEST ARRIVED on (reference Transport.py:1643).
/// Learned hops here are 0 → 6 s base.
@Suite @MainActor struct RelayLinkProofDeadlineTests {
    @Test func aFastArrivalInterfaceAddsOnlyItsTinyMTUTime() async {
        #expect(approx(await relayProofDeadline(in: .tcp, out: slow202), 6.0004))
    }

    @Test func aSlowArrivalInterfaceAddsOneMTUOfAirtime() async {
        #expect(approx(await relayProofDeadline(in: slow202, out: .tcp), 25.801980198019802))
    }

    @Test func anUnknownArrivalBitrateAddsNothing() async {
        // The arrival interface is no longer registered, so its bitrate is unknown; the slow OUTBOUND
        // interface must not be used in its place.
        #expect(approx(await relayProofDeadline(in: .tcp, out: slow202, inStillConnected: false), 6))
    }
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter RelayLinkProofDeadlineTests`
Expected: `anUnknownArrivalBitrateAddsNothing` passes (today's behaviour). The fast and slow tests FAIL: they get exactly 6. (The fast test's 0.0004 difference is above the 1e-6 tolerance.) Step 5 makes all three fail.

- [ ] **Step 3: Implement**

In `Sources/ReTiCATransport/Transport.swift`, relay `.linkRequest` branch, replace (today :753-757):
```swift
                        state.linkTable[linkID] = State.LinkTableEntry(
                            rcvdIf: interfaceID, nhIf: entry.interfaceID, refreshedAt: date.now,
                            validated: false,
                            proofDeadline: date.now.addingTimeInterval(
                                Self.establishmentTimeoutPerHop * Double(max(1, entry.hops))))
```
with
```swift
                        // Amended Contract 4: plus one MTU of airtime on the interface the request
                        // ARRIVED on (`interfaceID`, which is the link's `rcvdIf`), as reference does:
                        // `extra_link_proof_timeout(packet.receiving_interface)`
                        // (RNS/Transport.py:1643-1644, local 1.4.1 fork). Unknown bitrate → no extra.
                        state.linkTable[linkID] = State.LinkTableEntry(
                            rcvdIf: interfaceID, nhIf: entry.interfaceID, refreshedAt: date.now,
                            validated: false,
                            proofDeadline: date.now.addingTimeInterval(
                                Self.establishmentTimeoutPerHop * Double(max(1, entry.hops))
                                + LinkTiming.relayProofExtraTimeout(bitrate: state.interfaces[interfaceID]?.bitrate)))
```
Also extend the `establishmentTimeoutPerHop` doc (today :1240-1242) with: "plus `LinkTiming.relayProofExtraTimeout` of the interface the request arrived on."

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter RelayLinkProofDeadlineTests`
Expected: 3 pass.

- [ ] **Step 5: Mutation batch (step b)**

`cp /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/Transport.swift /tmp/slow-link-timing/Transport.swift.orig`

Mutation: in the `proofDeadline` expression only, change `state.interfaces[interfaceID]?.bitrate` to `state.interfaces[entry.interfaceID]?.bitrate`. This reads the OUTBOUND interface instead.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter RelayLinkProofDeadlineTests`
Expected: all 3 FAIL. Fast-arrival gets 25.8, slow-arrival gets 6.0004, and unknown-arrival gets 25.8, because its outbound interface is slow and connected.

- [ ] **Step 6: Revert (step c)**

`cp /tmp/slow-link-timing/Transport.swift.orig /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources/ReTiCATransport/Transport.swift`
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing --filter RelayLinkProofDeadlineTests`
Expected: 3 pass.

- [ ] **Step 7: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing`
Expected: all pass. Existing relay tests register `.default` (62_500 bps → +0.064 s) or `.tcp`. If a link-table reap test fails because its clock advance lands inside that sub-second extra, adjust only that advance by the exact `LinkTiming.relayProofExtraTimeout` for its profile, with a comment citing Contract 4, and report it. Any other failure: stop and diagnose.

- [ ] **Step 8: Commit**

`git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing add Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/RelayLinkProofDeadlineTests.swift`
(Also add any test file adjusted in Step 7.)

`/tmp/slow-link-timing/commit-task7.txt`:
```
feat: relay link-table proof deadline allows one MTU of arrival airtime

A forwarded LINKREQUEST's unvalidated link-table entry now lives
6*max(1, hops) + 4000/b_recv seconds, b_recv = the bitrate of the interface the
request arrived on (unknown → no extra), matching reference
extra_link_proof_timeout(packet.receiving_interface). A request arriving over
202 bps gets ~25.8 s instead of 6 s.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01Vnvun8t5cwrypfjHVETehm
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing commit -F /tmp/slow-link-timing/commit-task7.txt`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing log -1 '--format=%(trailers:key=Claude-Session)'`

---

### Task 8: Full suite, rebase onto main, fast-forward main

**Files:** none new. Conflict resolution only, most likely in `Sources/ReTiCANode/TransportEndpoint.swift` if lane B has merged.

- [ ] **Step 1: Full suite on the branch**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing`
Expected: all pass. The count should be baseline + 11 (T1) + 5 (T2) + 5 (T3) + 10 (T4) + 11 (T5) + 4 (T6) + 3 (T7), plus or minus any test adjusted under Task 2 Step 8 or Task 7 Step 7.

- [ ] **Step 2: Rebase onto main**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing rebase main`
If it stops on conflicts:
- Run `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing status` to list them.
- In `TransportEndpoint.swift`, keep BOTH sides: lane B's meshtastic slot, case, arms and transmit routing, and lane C's `.openLink` timeout, `.linkRequest` `arrivalBitrate:`, and `announceOn` case and arm. They are additive.
- After editing: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing add <file>`, then `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing rebase --continue`.
- Check for new link-construction sites: `grep -rn "openLink(initiatorTo\|acceptLinkRequest(owner" /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing/Sources`. Only the two TransportEndpoint sites may appear. A new interface lifecycle registering `.interfaceConnected(id, profile)` needs no change: `nextHopInterfaceProfile` and the arrival-bitrate lookup pick it up.

- [ ] **Step 3: Full suite after the rebase**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing`
Expected: all pass, including lane B's suites if they merged. On a signal-11 or stale-link failure, `swift package --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing clean` and rerun.

- [ ] **Step 4: Verify trailers on every lane-C commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/slow-link-timing log main..slow-link-timing '--format=%h %s | %(trailers:key=Claude-Session,valueonly)'`
Expected: seven commits, each with the session URL.

- [ ] **Step 5: Fast-forward main**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA merge --ff-only slow-link-timing`
Expected: `Fast-forward`. If it refuses because main moved again, go back to Step 2.

- [ ] **Step 6: Remove the worktree and branch**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA worktree remove ../ReTiCA-worktrees/slow-link-timing`
Run: `git -C /Users/ell/development/ios/pods/ReTiCA branch -d slow-link-timing`

- [ ] **Step 7: Report**

Report: the final test count; any existing test adjusted under Task 2 Step 8 or Task 7 Step 7 (with the reason); and conflicts resolved in Step 2.
