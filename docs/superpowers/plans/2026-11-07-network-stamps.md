# RNS Network Stamps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Implement RNS 1.6.0 network stamps so ReTiCA stays reachable when networks start enforcing them, with the same defaults as reference 1.6.0.

**Architecture:** A pure `NetworkStamp` type in the `ReTiCA` core ports `RNS/Stamps.py`. `Announce`, `Transport`, `LinkPlane` and `LXMFNode` use it for the three on-network stamps. All searches run as cancellable TCA effects with a bound.

**Tech Stack:** Swift, TCA, Swift Testing. Reference: RNS 1.6.0 and LXMF 1.3.0 in the conda env `rns-latest`.

**Spec:** There is no separate spec. The reference source is the specification: `RNS/Stamps.py`, `Identity.py:749-930`, `Destination.py:266-417`, `Transport.py:191-206, 2071-2131, 3685-3722, 3975-4050`, `Link.py:187-199, 310-390`, `Reticulum.py:505-551`. Read the file in `/Users/ell/opt/anaconda3/envs/rns-latest/lib/python3.12/site-packages/RNS/` before each task. Background: `https://rns.recipes/forum/general/an-introduction-to-network-stamps`, which describes 1.6.1 and 1.6.2 as plans, not facts.

## Global Constraints

- Defaults match reference 1.6.0: stamp a link request when the destination announced a cost; do NOT emit destination or path request stamps; do NOT enforce. Each is a host-settable option.
- Wire values, verbatim: extension marker `0xC1`, stamp 14 bytes, destination extension 18 bytes (`marker, flags, stamp, cost mantissa byte, cost integer byte`), path request extension 16 bytes (`marker, flags, stamp`), lenient relay flag `0xFF`.
- Defaults, verbatim: `DESTINATION_COST 23.5`, `DESTINATION_VALUE 25.0`, `PR_COST 15.8`, `PR_VALUE 15.8`, `LR_COST 12.5`, `STAMP_COST_CAP 100`, `LINK_COST_CAP 40`, link and path stamp timeout 15 s, `DELIVERY_LINK_COST 3.25`, `PROPAGATION_LINK_COST 3.25`.
- Everything arriving off the wire is hostile: no trapping conversions, and every search bounded and cancellable. A search must yield as `LXStamper.search` does.
- Fixtures drive genuine RNS code, and generators are committed. Do not hand-roll expected values.
- Tests use `.off` TestStores asserting outcomes. Follow `/Users/ell/.claude/CLAUDE.md`: mutation-verify every test set, one shell command per call, no pipes. Temp files go in `/tmp/ReTiCA/`.
- Trailers go at column 0: `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_011EzuHzmdJW8ynrucAN7Dwx`.
- Build in this worktree. Do not merge or push.

## Review Focus

- A non-stamp announce whose last 18 bytes happen to start with `0xC1`: its app data must survive untouched. Owned by Task 2.
- A stamped announce below our required value: reference keeps the bytes and ignores the link cost in them. A hostile announce must not make us search. Owned by Task 2.
- A hostile link cost of 100 from a valid low-cost stamp: a phone must fail in bounded time, not burn the battery. Owned by Task 3.
- A destination stamp not yet mined when a path request arrives: reference's queue must not become silence for good. Owned by Task 5.
- An oversized display name once 18 extension bytes are added: the announce must still fit in one packet. Owned by Task 5.

---

### Task 1: `NetworkStamp` primitives

**Files:**
- Create: `Sources/ReTiCA/Stamps/NetworkStamp.swift`
- Create: `Tests/ReTiCATests/Vectors/generate_network_stamp_fixtures.py`, `Tests/ReTiCATests/Vectors/network_stamp_fixtures.json`
- Create: `Tests/ReTiCATests/Vectors/NetworkStampCrossValidationTests.swift`
- Modify: `Package.swift` (add the fixture resource)

**Interfaces:**
- Produces, in `public enum NetworkStamp`: `stampLength = 14`; `extensionMarker: UInt8 = 0xC1`; the cost constants above; `static func fixedPoint(cost: Double) -> Int`; `static func target(fixedPoint: Int) -> Data` (32 bytes, big-endian); `static func isValid(stamp: Data, cost: Double, material: Data) -> Bool`; `static func value(stamp: Data, material: Data) -> Double`; `static func generate(material: Data, cost: Double) async -> (stamp: Data, value: Double)?`; `static func generateKey(material: Data, cost: Double) async -> (privateKey: Data, publicKey: Data, value: Double)?`. `generate*` return nil only when cancelled.

- [ ] **Step 1: Write the generator.** It calls genuine `RNS.Stamps`: `cost_to_fp`, `target_from_fp`, `stamp_value`, `stamp_valid` and `generate_stamp` for costs 0, 3.25, 8, 8.5, 12.5, 15.8, 23.5, 25, 100, and for random stamps of 14 and 32 bytes. Record material, stamp, value and validity. Include a stamped X25519 key from `generate_stamped_key` at cost 3.25. Include a material that yields a low-value stamp, and values near a `TAB` boundary.
- [ ] **Step 2: Write failing tests.** `networkStampFixedPointMatchesReference`, `networkStampTargetMatchesReference`, `networkStampValueMatchesReference`, `networkStampValidityMatchesReference`, `generatedStampValidatesInReference` (write ours to a test-only fixture check against `isValid` and against a reference fixture run by the generator's `--verify`), `generatedKeyMeetsCost`, `cancelledSearchReturnsNil`.
- [ ] **Step 3: Run to verify they fail** with `swift test --filter NetworkStamp`.
- [ ] **Step 4: Implement.** Copy `TAB` verbatim and check its SHA-256 against `TAB_DIGEST` from `Stamps.py` in a test. `value` needs 256-bit arithmetic on the hash: work on the byte array, take the top 34 significant bits, and bisect. Note `stamp_value` takes `(workblock, stamp)` in that order. `target` shifts `TAB[f]` left by `i` and right by 33. Compare hash and target as big-endian bytes. Network stamps use `expand_rounds=0`, so the workblock is the material.
- [ ] **Step 5: Run tests, mutate, confirm failure, revert, confirm pass.**
- [ ] **Step 6: Record real hash rates** for both search kinds in a release build on this Mac, in the file's doc comment, and label them Mac figures.
- [ ] **Step 7: Commit** as `feat(core): port RNS 1.6 network stamp arithmetic`.

### Task 2: Read stamped announces as reference does

**Files:**
- Modify: `Sources/ReTiCA/Destination/Announce.swift`, `Sources/ReTiCATransport/Transport.swift`, `Sources/ReTiCATransport/LearnedDestination.swift`
- Create: `Tests/ReTiCATests/Vectors/generate_stamped_announce_packet_fixtures.py` and its JSON (from real `Destination._announce`)
- Test: `Tests/ReTiCATests/Destination/StampedAnnounceTests.swift`

**Interfaces:**
- Produces: `Announce.Parsed.stamp: Data?`, `.stampValue: Double?`, `.linkCost: Double?`; `Announce.parse(payload:destinationHash:contextFlagSet:requiredStampValue:)`, with `requiredStampValue` defaulting to `NetworkStamp.defaultDestinationCost`; `LearnedDestination.linkCost: Double?`, `.stampValue: Double?` (both default nil).

- [ ] **Step 1: Write failing tests.** Follow `Identity.py:840-873` exactly:
  - `aStampMeetingTheCostIsStrippedFromAppData`: `.appData` equals the msgpack alone, and `.linkCost == 3.25`.
  - `anAnnounceThatIsOnlyAStampHasNilAppData`.
  - `aStampBelowTheCostStaysInAppDataAndItsLinkCostIsIgnored`, for the Review Focus case. `.linkCost == nil`, while `.stampValue` is still reported.
  - `appDataEndingLikeAMarkerSurvivesUntouched`, with `0xC1` at -18 and an invalid stamp.
  - `anExtendedFlagOrOverCapCostIsNotTreatedAsAStamp`, for `known_format`.
  - `theSignatureCoversTheExtension`: stripping must not break validation.
  - `aRelayForwardsTheOriginalBytes`: `announceCache` payload keeps the extension.
  - `aPathLearnedRecordsTheLinkCost` at the Transport level.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.** Verify the signature over the full bytes first, then strip. The 1.3.0 parser tolerance from `d4eb179` stays, because low-value stamps still reach it.
- [ ] **Step 4: Run all tests, mutate, confirm failure, revert, confirm pass.** The live test `aStampedAnnounceGivesUsTheCost...` must still pass, since its peer's value of 12 stays below 23.5.
- [ ] **Step 5: Commit** as `feat(transport): read stamps and link costs from announces`.

### Task 3: Stamp link requests to destinations that announce a cost

**Files:**
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift:233`, `Sources/ReTiCANode/LinkPlane.swift:104,184`
- Test: `Tests/ReTiCANodeTests/LinkPlaneStampedRequestTests.swift`, plus a live test in `LiveStampInteropTests.swift`
- Modify: `Scripts/stampprobe/peer.py` (add `--enforce-network`, which writes `enforce_stamps = yes`)

**Interfaces:**
- Consumes: `NetworkStamp.generateKey`, `LearnedDestination.linkCost`.
- Produces: `LinkPlane.Action.openLink(...)` gains `linkCost: Double?`; `LinkPlane.State.stampingLinks`, one entry per in-flight search; `LinkSession.CloseReason.stampFailure`, or the equivalent existing failure delegate if one fits; `LinkPlane.maxLinkStampCost = 20` with a doc comment explaining why.

- [ ] **Step 1: Write failing tests.**
  - `aLinkToADestinationWithACostUsesAKeyMeetingIt`: `NetworkStamp.isValid(stamp: x25519Public, cost:, material: destHash + ed25519Public)`, on the emitted link request.
  - `noCostMeansAnOrdinaryKeyAndNoSearch`.
  - `aSearchThatTimesOutFailsTheLinkWithoutSendingARequest` at 15 s on a `TestClock`, with a cost that cannot finish.
  - `aCostAboveTheCeilingFailsTheLinkWithoutSearching`, for the Review Focus case.
  - `stoppingTheEndpointCancelsTheSearch`.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.** Order as `Link.py:355-378`: new Ed25519 key, material `destinationHash + ed25519Public`, then the X25519 search. Pass the result to `LinkSession.State(... ephemeral:)`, which already accepts an `Identity`. Build it with `Identity(privateKey: x25519Private + ed25519Private)`. Do not change the router's existing timeout: the link's establishment timeout starts when `.establish` runs, after the search.
- [ ] **Step 4: Add the live test** `aLinkRequestSurvivesAPeerEnforcingNetworkStamps`: peer with `--enforce-network --network-stamps`, large message, and the peer's log shows it arrived. Run it under `RETICA_LIVE_STAMP_PYTHON`.
- [ ] **Step 5: Run all tests, mutate, confirm failure, revert, confirm pass.**
- [ ] **Step 6: Commit** as `feat(node): stamp link requests when the destination announces a cost`.

### Task 4: Path requests in the 1.6 format

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift:801-880, 1240-1256`
- Test: `Tests/ReTiCATransportTests/PathRequestStampTests.swift`, plus a live test

**Interfaces:**
- Produces: `Transport.State.stampPathRequests: Bool` (default false); `Transport.State.pathRequestValue: Double` (default 15.8); `Transport.State.pathRequestSenderID: Data`, a random 16 bytes per instance used when there is no `transportIdentity`.

- [ ] **Step 1: Write failing tests.**
  - `aPathRequestAlwaysCarriesASenderID`: leaf payload 48 bytes. Reference says 1.6.0 and later always carry one (`Transport.py:3699`), and marks the 32-byte form for removal.
  - `aStampedPathRequestIs64BytesAndValidates`, with material `destinationHash + tag`, flags `0x00`.
  - `anUnansweredStampSearchGivesUpAfter15SecondsAndSendsNothing`.
  - `aStampedInboundRequestIsAnsweredWithTheRightTag`: a fixture from a real `stamp_path_request`.
  - `aRelayForwardsTheExtensionUnchanged`.
  - `aRelayMarksAnUnstampedRequestLenientlyOnlyWhenStamping`: `0xC1 0xFF` plus 14 zero bytes (`Transport.py:3935-3936, 3955-3956`).
  - `oversizedPathRequestsAreIgnored`: over 64 bytes.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** with a cancellable search effect. `state.pathRequests[dest]` is set before the search, as `Transport.py:3714` does, so the announce arriving is exempt from ingress holding.
- [ ] **Step 4: Add the live test** `aPathRequestFromReTiCAReachesAnEnforcingPeer`, with `stampPathRequests` on, and `...isDroppedWhenItIsNotStamped` proving the peer really enforces.
- [ ] **Step 5: Run all tests, mutate, confirm failure, revert, confirm pass.**
- [ ] **Step 6: Commit** as `feat(transport): send and relay path requests in the 1.6 format`.

### Task 5: Destination stamps on our announces

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift:816-835, 1190-1238`, `Sources/ReTiCA/LXMF/LXMFAnnounceData.swift:87`, `Sources/ReTiCANode/LXMFNode.swift` (action and delegate plumbing, link cost at `registerDelivery`)
- Test: `Tests/ReTiCATransportTests/DestinationStampTests.swift`, plus a live test

**Interfaces:**
- Produces: `Transport.State.stampDestinations: Bool` (default false); `Transport.State.destinationValue: Double` (default 25.0); `Transport.Action.rehydrateDestinationStamp(destinationHash: Data, stamp: Data)`; `Transport.Action.Delegate.destinationStampGenerated(destinationHash: Data, stamp: Data, value: Double)`, so the host can persist it. A destination stamp takes minutes on a phone and reference persists it (`Stamps.py:888-930`). `Transport.Action.registerLocalDestination` gains `linkCost: Double?`, nil meaning `LR_COST`, set to `3.25` for LXMF delivery.

- [ ] **Step 1: Write failing tests.**
  - `anAnnounceCarriesTheStampExtensionWhenEnabled`, parsed back through `Announce.parse`; a fixture check in the Python `--verify` that genuine `validate_announce` accepts it and reads the link cost.
  - `aLoadedStampBelowTheValueIsMinedAgain`.
  - `theStampIsMinedOncePerDestination`: two announces, one search.
  - `aStampIsReportedForTheHostToPersist` and `aRehydratedStampSkipsTheSearch`.
  - `announcesWaitForTheStampAndAllGoOutWhenItIsReady`.
  - `aPathRequestDuringTheSearchIsAnsweredWhenTheStampIsReady`, for the Review Focus case.
  - `anOverlongNameStillFitsWithTheExtension`, for the Review Focus case. `maxAppDataBytes` drops by 18, the same whether or not stamping is on, so a name does not change length when a host turns it on.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement.** Material is `destinationHash + publicKey + nameHash`; extension as `Destination.py:353-357`. Note the two cost bytes are written in reverse order there. The signature covers the extension.
- [ ] **Step 4: Add the live test** `aStampedAnnounceFromReTiCAIsAcceptedByAnEnforcingPeer` at a low `destinationValue`, with the peer's `destination_cost` below it, and the peer replies.
- [ ] **Step 5: Run all tests, mutate, confirm failure, revert, confirm pass.**
- [ ] **Step 6: Commit** as `feat(transport): stamp our announces when enabled`.

### Task 6: Enforcement, off by default

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift`, `Sources/ReTiCANode/LinkPlane.swift:193`
- Test: `Tests/ReTiCATransportTests/StampEnforcementTests.swift`
- Modify: `README.md`, `docs/reference-parity-checklist.md`

**Interfaces:**
- Produces: `Transport.State.enforceStamps: Bool` (default false); `Transport.State.destinationCost: Double` (default 23.5); `Transport.State.pathRequestCost: Double` (default 15.8).

- [ ] **Step 1: Write failing tests.** `withEnforcementAnUnstampedAnnounceIsNotLearnedOrRelayed`; `...aLowValueStampIsNotLearned`; `...anUnstampedPathRequestIsIgnored`; `...aLinkRequestBelowTheCostIsNotAnswered`; `withoutEnforcementAllOfThoseStillWork`. Our own destination's cost comes from Task 5.
- [ ] **Step 2: Run to verify they fail.**
- [ ] **Step 3: Implement** per `Identity.py:883-889`, `Transport.py:2128-2129`, `Link.py:195`. Check the stamp, a single hash, before the signature, as reference does, so junk costs little.
- [ ] **Step 4: Run all tests, mutate, confirm failure, revert, confirm pass.**
- [ ] **Step 5: Update docs.** Add network stamps to the README's feature tables, with what is on by default. Add what stays unverified: the real MeshChatX app, and phone hash rates.
- [ ] **Step 6: Commit** as `feat(transport): enforce network stamps when enabled`.

## Deliberately not in this plan

Each is a separate slice toward wider parity with the latest reference:

- Exact fractional LXMF stamps: we search at the ceiling, which is valid but up to twice the work.
- LXMF tickets.
- Ratchets on our own destinations.
- RNS 1.6's table culling and SQLite storage, which change no wire format.
- App-side settings and persistence in ReTiCaMsgr for Tasks 3 to 6.
- Regenerating existing fixtures against the new reference.
