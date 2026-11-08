# Deferred follow-ups from the network-stamps work (2026-11-07)

**Status 2026-11-09:** worked by `docs/superpowers/plans/2026-11-08-stamp-followups.md` (commits
9dcdbd5..09a224b on main). #7 was already fixed, #22 is not a defect, #23 needs no change, and the link-key
search concurrency cap from #13 moved to the stamp-priority work. The rest are done, plus a cost cap of 100
and a TCP-server stop fix found on the way. Minors the task reviews deferred are listed at the end.

Recorded by the task and final reviews of `docs/superpowers/plans/2026-11-07-network-stamps.md`
(commits ef77762..46ef2ff) and deferred as minor. The ledger that held them was scratch and is gone;
this is the surviving copy. Each still needs checking against current code before it is worked.

## Task 1 — NetworkStamp arithmetic (`Sources/ReTiCA/Stamps/NetworkStamp.swift`)
1. `<=` in `hashMeets` and the `bisect_right` equality case are untested: mutating to `<` / `bisect_left`
   survives. Needs internal unit tests on constructed bytes. The test comment at
   `NetworkStampCrossValidationTests.swift:437-449` overclaims.
2. The generator's TAB-boundary comment overclaims (stamps are 11-94 units from entries, not one step).
3. No reference-generated valid stamps at cost 23.5 / value 25 in the fixtures.
4. A probabilistic `!isValid(cost + 16)` assertion is undocumented as probabilistic.
5. `generate` and `generateKey` duplicate the search loop.
6. `value` / `isValid` accept any stamp length; the doc must say callers reject wrong lengths.

## Task 2 — announces read stamps and link costs
7. `aRehydratedPathKeepsItsLinkCost` proves only struct assignment.
8. The stamped-announce fixture JSON is duplicated in two (now three) test targets, nothing checks they match.
9. `cost(fromBytes:)` has an unreachable nil guard.
10. `requiredStampValue` is fixed at 23.5; reference uses the receiving interface's `destination_cost`.

## Task 3 — link-request keys
11. A node stop surfaces `PNNode` `syncFailed(.pathStale)`, a misleading reason.
12. Driver stop tests rely on entry + counter, not `.on` / `finish`; the TCP server stop has no test of its own.
13. No limit on concurrent link-key searches; a search continues after its requester abandons it.
14. `LinkSession.State` is built in two arms, and `linkFailed(.stampFailure)` is written four times.
15. The no-cost test misses the negative / NaN halves of its guard; the endpoint wiring test's validity
    check is weak at cost 3.25.
16. Retries spend up to maxAttempts x 15 s of search per delivery at announced costs 17-20.

## Task 4 — 1.6 path requests
17. Cancel followed by a quick re-request can cross two path-request searches (no generation token).
18. A path-request search runs with no interface connected.
19. A timeout boundary assertion could race; a fixed 10 s receive waits on a real cost-15.8 search in debug.
20. `pathRequestSenderID` comes from `SecureRandom`, not the `randomBytes` dependency.

## Task 5 — destination stamps
21. The global 32-announce cap can be filled by one destination with 32+ connected interfaces; announces
    for not-yet-connected interfaces are not queued.
22. Toggling `stampDestinations` off mid-search still releases stamped announces.
23. Sticky app data captured before `waitForStamp` may be dropped.
24. Re-registration does not clear pending announces.
25. A live-test control comment ("only the host's switch differs") is inaccurate.

## Task 6 — enforcement
26. 64-byte link requests are untested.
27. The link-request enforcement test reads its recorder without `skipReceivedActions`.
28. `LinkPlane.acceptLinkRequest`'s doc should say it is not enforced when called directly.
29. No invalid-announce verdict cache: identical replays cost more than in reference.

## Deferred by the 2026-11-08 plan's reviews (all minor)

- NetworkStamp: the bisect_right test pins `tabClimb`, not `value` end to end; a comment says "default
  announce cost" for the destination cost; "none of these hashes EQUALS the target" is unasserted.
- Per-interface costs: propagation is tested for the radio drivers; TCP client, TCP server and BLE only by
  reading. A path-request gate comment in Transport.swift is one overlong line.
- LinkPlane driver stop tests: after the 3600 s clock advance, `links.isEmpty` is not rechecked and no
  assertion that nothing was transmitted; the wiring test could assert the found key is the transmitted key.
  `hasLinkWork`'s doc is one overlong line. `abandonStampSearches` relies on LXMFNode being the only link
  opener (true today, unenforced).
- Path requests: a request made with no interface connected is dropped, not started when one connects
  (reference queues it; the router re-requests anyway) — say so in a comment. The race test injects the old
  search end by hand, so the `Task.isCancelled` guard is untested. TransportTests.swift ~:2662's sender-ID
  check is vacuous (its stub returns the same bytes for every draw). The `megaYield` timing fixes are a
  heuristic.
- `pnCopyAbandonWhileTheDeliveryStampIsSearchedDoesNotFailTheMessage` assumes a cost-20 search never
  finishes during the test; it occasionally does, and the test flakes.
- Destination-stamp queue: a newest-dropped item still starts a stamp search; the path-response quota test
  uses one interface; an in-place replacement keeps its queue position (reference moves it to the back).
- Verdict cache: the enforcement guard on the valid-hit path is untested (matters only if `enforceStamps`
  changes at runtime); `announceVerdicts` is in State equality, so exhaustive tests that send announces must
  account for it.
- TCP server: no test of a stop racing a connection mid-accept. Host-set `name` and `hwMTU` are ignored by
  the radio drivers (by design today).
