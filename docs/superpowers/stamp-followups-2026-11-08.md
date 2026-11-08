# Deferred follow-ups from the network-stamps work (2026-11-07)

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
