# Network-stamp follow-ups Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close the 26 open follow-ups deferred by the reviews of the RNS 1.6.0 network-stamps work.

**Architecture:** Mostly local fixes in `NetworkStamp`, `Transport`, `LinkPlane` and their tests. Two items add state: a cap and a cancel path for link-key searches (Task 5) and reference's announce verdict cache (Task 9). One adds configuration: per-interface stamp costs (Task 3).

**Tech Stack:** Swift 6, TCA, Swift Testing; reference RNS 1.6.0 in conda env `rns-latest` at `/Users/ell/opt/anaconda3/envs/rns-latest` (Python: `/Users/ell/opt/anaconda3/envs/rns-latest/bin/python`).

**Spec:** the item list `docs/superpowers/stamp-followups-2026-11-08.md`, the triage of it (locations, reference citations) copied into each task below, and the reference RNS 1.6.0 source as the authority on behaviour.

## Global Constraints

- Commit directly to `main`. Each commit ends with, at column 0:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and
  `Claude-Session: https://claude.ai/code/session_011EzuHzmdJW8ynrucAN7Dwx`.
- Shell: one command per Bash call; no `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, heredocs into interpreters,
  or inline scripts. Temp files in `/tmp/ReTiCA/`.
- Every new or changed test goes through: (a) passes; (b) one batch of production mutations makes every
  changed test fail; (c) revert, passes. Then the full suite (`swift test --parallel`) — report any failure.
  The suite has exactly one known issue (`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`).
- Defaults must stay those of reference RNS 1.6.0. A new knob defaults to current behaviour.
- Stamp costs used in assertions about validity are 8 or more (a low-cost stamp passes a random check by luck).
- TestStores with exhaustivity `.off`: a `receive` predicate cannot see actions an earlier `send` skipped;
  count in a wrapping reducer. Flip `.on` before `finish()` when the test claims nothing else happens.

## Review Focus

1. A per-interface cost of 0 must mean "no stamp required on this interface", as reference's clamp allows.
2. The verdict cache must never turn a valid announce into a dropped one: a stamp rejected at a cost that is
   later lowered must be accepted on its next arrival (reference re-validates, Identity.py:758-763).
3. A link-key search cancelled because its requester gave up must report nothing to anyone (the requester is gone).
4. A path request re-issued right after a cancel must transmit the NEW request, once.
5. Re-registering a destination with new app data must never announce the old app data.

---

### Task 1: NetworkStamp hygiene (items 1, 2, 3, 4, 5, 6)

**Files:** `Sources/ReTiCA/Stamps/NetworkStamp.swift`; `Tests/ReTiCATests/Vectors/NetworkStampCrossValidationTests.swift`;
`Tests/ReTiCATests/Vectors/generate_network_stamp_fixtures.py`, `network_stamp_fixtures.json`; a new
`Tests/ReTiCATests/NetworkStampBoundaryTests.swift`.

- [ ] Boundary tests (`@testable`): `hashMeets` accepts a hash exactly equal to the target and rejects target+1;
  the value lookup is `bisect_right` — a mantissa equal to a TAB entry maps to that entry's value, one less maps
  to the previous. Mutating `<=`→`<` and `bisect_right`→`bisect_left` must each fail a test.
- [ ] Fix the comment at `NetworkStampCrossValidationTests.swift:166-168` ("a hash equal to the target is
  valid" is not what that test exercises) and at `generate_network_stamp_fixtures.py:91-92` (fixture stamps are
  tens of units from a TAB entry, not one step).
- [ ] Mark the `!isValid(cost + 16)` assertion (:190-191) as probabilistic, about 1 in 65,000.
- [ ] Add 23.5 and 25 to `GENERATED_COSTS`, regenerate the JSON with the reference Python, and check those cases in
  the existing generated-cases test.
- [ ] Extract the shared search loop of `generate` / `generateKey` into one private helper; behaviour unchanged.
- [ ] Document on `value` / `isValid` that callers reject stamps whose length is not `stampLength`.
- [ ] Commit.

### Task 2: Announce parsing and shared fixtures (items 8, 9)

**Files:** `Sources/ReTiCA/Destination/Announce.swift:57-59`; the three copies of
`stamped_announce_packet_fixtures.json` (ReTiCATests, ReTiCATransportTests, ReTiCANodeTests `Vectors/`).

- [ ] Replace the unreachable `guard let cost = NetworkStamp.cost(fromBytes:)` with a non-optional computation.
- [ ] Add a test in each of the two non-generating targets that pins the SHA-256 of its fixture copy to the
  value of the ReTiCATests copy, so a regenerated fixture that misses a copy fails.
- [ ] Commit.

### Task 3: Per-interface destination and path-request costs (item 10)

**Files:** `Sources/ReTiCATransport/InterfaceProfile.swift` (or wherever `InterfaceProfile` is defined);
`Sources/ReTiCATransport/Transport.swift:164-170, :927, :1126`; README stamp section.

Reference: `packet.receiving_interface.destination_cost`, falling back to `Transport.DESTINATION_COST`
(RNS/Identity.py:760, :778, :794; RNS/Interfaces/Interface.py:350-353); per-interface config clamped to
0...`STAMP_COST_CAP` (RNS/Reticulum.py:963-966, applied :1157). Path-request cost likewise.

- [ ] `InterfaceProfile` gains `destinationCost: Double?` and `pathRequestCost: Double?`, nil meaning "use the
  Transport-wide value". Clamped as reference on the way in.
- [ ] The announce stamp check and the path-request gate use the receiving interface's value when set.
- [ ] Tests: an announce whose stamp meets a low per-interface cost but not the global one is accepted on that
  interface and rejected on another; same for path requests under enforcement; a per-interface 0 accepts an
  unstamped announce.
- [ ] README: document the knob. Commit.

### Task 4: LinkPlane tidy-ups and test strength (items 11, 12, 14, 15, 28)

**Files:** `Sources/ReTiCANode/LinkPlane.swift`; `Sources/ReTiCANode/PNNode.swift:62-66`;
`Tests/ReTiCANodeTests/LinkPlaneStampedRequestTests.swift`.

- [ ] Factor the twice-built `LinkSession.State` (:264, :326) and the three `.stampFailure` writes
  (:272, :324, :337) into one helper each; behaviour unchanged.
- [ ] `PNNode` doc: a node stop fails an in-progress sync as `.pathStale` (LinkPlane chose this on purpose).
- [ ] `acceptLinkRequest` doc: stamp enforcement happens in `Transport` and is not applied when this action is
  sent directly.
- [ ] No-cost test covers `-1` and `.nan`. The endpoint wiring test asserts the search actually ran (e.g. the
  key differs from an unsearched one, or a counted search start), not only `isValid` at cost 3.25.
- [ ] Driver stop tests end with exhaustivity `.on` and `finish()`; add a TCP-server driver variant.
- [ ] Commit.

### Task 5: Bound link-key searches (items 13, 16)

**Files:** `Sources/ReTiCANode/LinkPlane.swift`; `Sources/ReTiCANode/LXMFRouter.swift` (only if the abandon
signal must be added there); tests in `LinkPlaneStampedRequestTests.swift`.

Decisions:
- No concurrency cap here: the later stamp-priority plan puts every stamp search (delivery, propagation,
  network) behind one scheduler, and a cap built now would be rebuilt there.
- A running search is cancelled, silently, when the node gives up on that destination's link
  (whatever action the router uses to abandon/close an establishing link — find it; if none reaches LinkPlane
  for a link still searching, add one).
- After a `.stampFailure` for a destination at cost c, an `openLink` to it at a cost >= c within
  `LinkPlane.linkStampFailureBackoff = 300` seconds fails at once with `.stampFailure` instead of searching
  again. A lower cost (the destination re-announced cheaper) searches.

- [ ] Tests for each decision, including: an abandoned search emits nothing and stops (its effect is cancelled); a repeat within the backoff does not search; after it, or at a lower cost, it does.
- [ ] Commit.

### Task 6: Path-request search correctness (items 17, 18, 19, 20)

**Files:** `Sources/ReTiCATransport/Transport.swift:119, :516, :1568-1616`;
`Tests/ReTiCATransportTests/PathRequestStampTests.swift`.

- [ ] `.pathRequestStampSearchEnded` carries the request's tag; it is ignored unless it matches the search
  currently recorded for that destination. Test: cancel then immediate re-request; the old search's late end
  transmits nothing, the new one transmits its own request once.
- [ ] `.requestPath` with stamping on does not start a search when no interface is connected (the pending
  `pathRequests` entry is still written). Test.
- [ ] `pathRequestSenderID` comes from the `randomBytes` dependency: generated on first use and stored in state.
  Update `aPathRequestAlwaysCarriesASenderID`.
- [ ] Timing tests: yield (`await Task.megaYield()`) before `clock.advance` at :161-165; the real 15.8 search's
  fixed 10 s receive becomes a generous bound (30 s).
- [ ] Commit.

### Task 7: Destination-stamp announce queue (items 21, 22, 24)

**Files:** `Sources/ReTiCATransport/Transport.swift:124-133, :657-676, :731-768, :1929-1931`;
`Tests/ReTiCATransportTests/DestinationStampTests.swift`.

- [ ] Per-destination quota inside the global 32: one destination holds at most 8 queued announces. Test that
  a destination on many interfaces cannot starve another.
- [ ] `.registerLocalDestination` drops that destination's pending stamped announces (as deregister does). Test:
  re-register with new app data while a stamp search runs; only the new app data is ever announced.
- [ ] Doc on `stampDestinations`: set at construction; there is no action to change it.
- [ ] Commit.

### Task 8: Enforcement test strength (items 25, 26, 27)

**Files:** `Tests/ReTiCATransportTests/StampEnforcementTests.swift:310-339`;
`Tests/ReTiCANodeTests/LiveStampInteropTests.swift:344-357`.

- [ ] Add a 64-byte stamped link request (the first 64 bytes of the 67-byte fixture payload; the stamp material
  uses only those) accepted under enforcement, and an unstamped 64-byte one rejected.
- [ ] Read the recorder only after `await store.skipReceivedActions(strict: false)`; re-run the mutation.
- [ ] Reword the live control comment: it also sends `.announceDelivery` and polls 20 s, not 40 s.
- [ ] Commit.

### Task 9: Announce verdict cache (item 29)

**Files:** `Sources/ReTiCATransport/Transport.swift:924-929` and state; a new
`Tests/ReTiCATransportTests/AnnounceVerdictCacheTests.swift`.

Reference (RNS/Identity.py): `announce_valid_cache` and `announce_invalid_cache`, keyed by packet hash, each
capped at 128, oldest evicted (:683, :702); inserts :685-699 / :704-711; invalid verdicts cached for missing or
low stamp, blackholed, key mismatch, destination mismatch, bad signature (:885-889, :897, :919, :932, :937);
a cached `invalid_stamp` verdict is re-validated when the cost target is at or below the cached stamp value
(:758-763); caches cleared by `_reset_validation_caches` (:677-680).

- [ ] Two 128-entry FIFO caches in Transport state, consulted before `Announce.parse`. A cached-invalid announce
  is dropped without parsing, unless its verdict was a low stamp and the receiving interface's current cost
  (Task 3) is at or below its cached stamp value. A cached-valid announce skips signature verification but still
  goes through the replay and path logic exactly as before.
- [ ] Tests: a replayed invalid announce is not re-parsed (count via a test seam, as `Identity.usabilityCheckProbe`
  does); a stamp rejected at one cost is accepted after the cost is lowered; the 129th entry evicts the oldest;
  a cached-valid announce still updates `knownDestinations.lastHeard`.
- [ ] Commit.

### Task 10: Stamp cost cap of 100 (found by the 2026-11-08 parity research)

**Files:** `Sources/ReTiCA/LXMF/LXMFAnnounceData.swift:122`; `Sources/ReTiCANode/LXMFNode.swift:618-623`
(`setDisplayName(_, stampCost:)`); README.

RNS 1.6.0 caps stamp cost at 100 and LXMF 1.3.0's inbound-cost check follows it; reference `generate_stamp`
raises above 100, so a ReTiCA host advertising 101-254 makes every reference sender fail to stamp. Read the
reference (`RNS/Stamps.py` and LXMF 1.3.0 `LXMRouter`/`LXMessage` inbound-cost handling) for the exact constant
and what reference does with an out-of-range configured cost, and match it.

- [ ] Our own advertised delivery cost is limited to reference's range; the parser's accepted range for a
  PEER's advertised cost matches reference too (outbound searches are already capped by
  `maxDeliveryStampCost`).
- [ ] Tests at the boundary (100 accepted, 101 handled as reference handles it). Commit.
