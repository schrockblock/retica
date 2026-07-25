# Collaborative Announce Suppression Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Cancel our pending announce retry when we hear peers/downstream re-broadcast the same announce (RNS `LOCAL_REBROADCASTS_MAX`-gated collaborative suppression).

**Architecture:** One production file changes: `Sources/ReTiCATransport/Transport.swift`. A peer/downstream re-broadcast of a held announce is a same-blob 4b-3a *replay*, so suppression enriches the blob-dedup replay branch (the `else` of `ring.insert(...)`): count HEADER_2 re-broadcasts whose hops match our held re-broadcast, and `.cancel` the pending retry once the cap is reached (peer) or the announce is seen passed on downstream. `PendingAnnounce` gains `rebroadcastHops` + `localRebroadcasts`. The fresh-announce path and re-broadcast bytes are untouched. Cross-validation is behavioral (the constant and hop arithmetic are already RNS-pinned/byte-validated).

**Tech Stack:** Swift, The Composable Architecture (~1.26): `@Dependency(\.continuousClock)`, `TestClock`, `.cancel(id:)`/`.cancellable(id:cancelInFlight:)`.

## Global Constraints

- Wire-compatible with Python-RNS 1.3.8. Core `Sources/ReTiCA/*` stays zero-dep and **untouched** — changes only in `Sources/ReTiCATransport/Transport.swift` and `Tests/ReTiCATransportTests/TransportTests.swift`.
- Commit **directly to `main`** — no feature branch. The commit leaves the FULL suite green.
- **No compound shell commands** — one command per shell call (a single `|` pipeline or `>` redirect allowed). Run `swift build`, `swift test`, `git add`, `git commit` separately. Never inline a script into an interpreter; write it to a file under `/tmp/ReTiCA/` and run the file.
- Temp files under `/tmp/ReTiCA/`.
- **Mutation-testing verification** for every new/changed test: run pass → batch-mutate production so they should fail → confirm fail → revert → confirm pass. If two mutations interact, verify those independently.
- Reference RNS at `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/RNS/`. Build gotcha: signal-11/SIGILL → `swift package clean` then retry.
- Commit trailers (exact, both lines):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

Spec: `docs/superpowers/specs/2026-07-25-collaborative-suppression-design.md`.

## Grounding facts (verified — do not re-derive)

- Current `PendingAnnounce` (`Transport.swift:23-30`): `{ raw: Data; arrivalInterface: InterfaceID; rebroadcasts: Int; init(raw:arrivalInterface:rebroadcasts:) }`.
- The scheduling site (`Transport.swift:196-197`) constructs `State.PendingAnnounce(raw: rebroadcastRaw, arrivalInterface: interfaceID)`.
- The blob-dedup replay guard (`Transport.swift:165`): `guard ring.insert(parsed.randomHash) else { return .none }`. The `state.announceBlobs[...] = ring` write-back (`:166`) is only reached on a fresh (new-blob) insert; the replay branch returns before it.
- Existing on `Transport`: `static let announceMaxRebroadcasts = 2`; `private enum CancelID: Hashable { case announceRetransmit(Data) }`; `.announceRetransmitDue` handler guards `guard var entry = state.announceTable[destinationHash] else { return .none }` (a removed entry no-ops when its timer fires).
- Test helper `makeTimedRelayStore(_ relay:_ clock:jitterByte:)` (TransportTests.swift): a 2-interface (`i0`,`i1`) relay store with a `TestClock` and `randomBytes` fixed to the byte; `store.exhaustivity = .off`. `makeAnnouncePacket(hops:emitted:)` returns `(raw, destHash)` for a HEADER_1 announce.
- The retry delay is a fixed 5.5s (`announceRetryGrace + announceRebroadcastWindow`). After the initial send (advance past jitter) the entry is retained with `rebroadcasts == 1` and a retry pending; a live TestStore retry timer must be cancelled (suppression) or fired+drained (advance 5.5 + receive) before the test ends, else deinit flags an in-flight effect.
- RNS suppression (`Transport.py:1774-1791`): peer `packet.hops-1 == IDX_AT_HOPS` → `IDX_AT_LCL_RBRD += 1`, pop if `IDX_AT_RETRIES>0 and IDX_AT_LCL_RBRD >= LOCAL_REBROADCASTS_MAX`; downstream `packet.hops-1 == IDX_AT_HOPS+1 and IDX_AT_RETRIES>0` → pop. In our no-pre-increment convention these are `packet.hops == rebroadcastHops` (peer) and `packet.hops == rebroadcastHops+1` (downstream).

---

### Task 1: Collaborative suppression in the replay branch

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift`.
- Test: `Tests/ReTiCATransportTests/TransportTests.swift`.

- [ ] **Step 1: Add the two `PendingAnnounce` fields**

Replace the struct (`Transport.swift:23-30`) with:

```swift
        public struct PendingAnnounce: Equatable, Sendable {
            public var raw: Data
            public var arrivalInterface: InterfaceID
            public var rebroadcasts: Int
            public var rebroadcastHops: UInt8     // hops our re-broadcast carries (= arrival packet.hops + 1)
            public var localRebroadcasts: Int     // heard peer re-broadcasts (RNS IDX_AT_LCL_RBRD)
            public init(raw: Data, arrivalInterface: InterfaceID, rebroadcastHops: UInt8,
                        rebroadcasts: Int = 0, localRebroadcasts: Int = 0) {
                self.raw = raw; self.arrivalInterface = arrivalInterface
                self.rebroadcastHops = rebroadcastHops
                self.rebroadcasts = rebroadcasts; self.localRebroadcasts = localRebroadcasts
            }
        }
```

- [ ] **Step 2: Pass `rebroadcastHops` at the scheduling site**

At `Transport.swift:196-197`, change the initializer call to:

```swift
                            state.announceTable[destHash] = State.PendingAnnounce(
                                raw: rebroadcastRaw, arrivalInterface: interfaceID,
                                rebroadcastHops: packet.hops + 1)
```

(The re-broadcast `rebroadcast` packet is already built with `hops: packet.hops + 1`, so this matches its bytes. `packet.hops < maxHops-1` here by the schedule guard, so `+1` cannot overflow `UInt8`.)

- [ ] **Step 3: Enrich the replay branch with suppression**

Replace the blob-dedup guard (`Transport.swift:165`) `guard ring.insert(parsed.randomHash) else { return .none }` with:

```swift
                    guard ring.insert(parsed.randomHash) else {
                        // REPLAY. A peer/downstream re-broadcast of an announce we are holding is a
                        // same-blob replay. Collaborative suppression: cancel our pending RETRY once
                        // neighbours have propagated it (RNS Transport.py:1774-1791).
                        guard var entry = state.announceTable[packet.destinationHash],
                              packet.transportId != nil    // HEADER_2 re-broadcast (RNS transport_id != None)
                        else { return .none }
                        if packet.hops == entry.rebroadcastHops {           // a peer re-broadcast
                            entry.localRebroadcasts += 1                     // count always (RNS increments unconditionally)
                            if entry.rebroadcasts >= 1,                      // a retry is pending (RNS IDX_AT_RETRIES > 0)
                               entry.localRebroadcasts >= Transport.announceMaxRebroadcasts {
                                state.announceTable[packet.destinationHash] = nil
                                return .cancel(id: CancelID.announceRetransmit(packet.destinationHash))
                            }
                            state.announceTable[packet.destinationHash] = entry
                            return .none
                        }
                        if packet.hops == entry.rebroadcastHops + 1, entry.rebroadcasts >= 1 {  // passed on downstream
                            state.announceTable[packet.destinationHash] = nil
                            return .cancel(id: CancelID.announceRetransmit(packet.destinationHash))
                        }
                        return .none
                    }
```

- [ ] **Step 4: Build**

Run: `swift build`
Expected: compiles. (Editor "No such module 'ComposableArchitecture'" is a known false positive.)

- [ ] **Step 5: Add the test helper and the suppression tests**

Append to `Tests/ReTiCATransportTests/TransportTests.swift`:

```swift
// MARK: - 4b-3b-3 collaborative announce suppression

/// Build a HEADER_2 "re-broadcast" of a HEADER_1 announce `originalRaw`, with the SAME payload
/// (→ same random_hash → same blob, i.e. a replay) at a chosen hop count and a peer transport_id.
private func peerRebroadcast(of originalRaw: Data, hops: UInt8) -> Data {
    let orig = Packet(raw: originalRaw)!
    let p = Packet(headerType: .header2, packetType: .announce, transportType: .transport,
                   destinationType: orig.destinationType, context: orig.context,
                   contextFlag: orig.contextFlag, hops: hops,
                   destinationHash: orig.destinationHash,
                   transportId: Data(repeating: 0x99, count: 16), payload: orig.payload)
    return try! p.packed()
}

/// After our first send (retry pending), two peer re-broadcasts (hops == rebroadcastHops) reach the
/// cap and cancel the pending retry.
@Test @MainActor func peerRebroadcastsCancelPendingRetryAtCap() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)   // arrival 2 → rebroadcastHops 3
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))              // send #1 → rebroadcasts=1, retry pending
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)
    #expect(store.state.announceTable[destHash]?.rebroadcastHops == 3)
    // Peer re-broadcast #1: counts, no cancel.
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 3)))
    #expect(store.state.announceTable[destHash]?.localRebroadcasts == 1)
    #expect(store.state.announceTable[destHash] != nil)
    // Peer re-broadcast #2: reaches the cap (2) → cancel the retry.
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 3)))
    #expect(store.state.announceTable[destHash] == nil)
    // Retry was cancelled: advancing past the grace fires nothing.
    await clock.advance(by: .seconds(5.5))
    #expect(store.state.announceTable[destHash] == nil)
}

/// A downstream re-broadcast (hops == rebroadcastHops + 1) cancels the pending retry immediately.
@Test @MainActor func downstreamRebroadcastCancelsPendingRetry() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    // hops == rebroadcastHops + 1 == 4 → cancel.
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 4)))
    #expect(store.state.announceTable[destHash] == nil)
    await clock.advance(by: .seconds(5.5))
    #expect(store.state.announceTable[destHash] == nil)
}

/// Peer re-broadcasts BEFORE the first send (initial jitter window, rebroadcasts==0) count but do
/// NOT cancel — the initial send is never suppressed.
@Test @MainActor func peerRebroadcastsBeforeFirstSendDoNotCancel() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 0)   // holding the initial send
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 3)))
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 3)))
    #expect(store.state.announceTable[destHash]?.localRebroadcasts == 2)
    #expect(store.state.announceTable[destHash] != nil)              // NOT cancelled (rebroadcasts==0)
    // Initial send still fires; drain both sends of the (un-suppressed) lifecycle.
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // send #1
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)
    await clock.advance(by: .seconds(5.5))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry (send #2)
}

/// A same-blob HEADER_2 replay whose hops match neither rebroadcastHops nor +1 leaves the pending
/// retry untouched.
@Test @MainActor func nonMatchingHopsReplayDoesNotSuppress() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    await store.send(.received(InterfaceID("i0"), peerRebroadcast(of: raw, hops: 7)))   // neither 3 nor 4
    #expect(store.state.announceTable[destHash]?.rebroadcasts == 1)
    #expect(store.state.announceTable[destHash]?.localRebroadcasts == 0)
    await clock.advance(by: .seconds(5.5))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry still fires
}

/// A HEADER_1 replay (transport_id == nil) is not a relay re-broadcast → no suppression, no count.
@Test @MainActor func header1ReplayDoesNotSuppress() async {
    let clock = TestClock()
    let (raw, destHash) = makeAnnouncePacket(hops: 2, emitted: 1000)
    let store = await makeTimedRelayStore(Identity(), clock, jitterByte: 128)
    await store.send(.received(InterfaceID("i0"), raw))
    await store.receive(.delegate(.pathLearned(destinationHash: destHash, hops: 2)))
    await clock.advance(by: .seconds(0.25))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false }
    // Same-blob HEADER_1 replay at hops == rebroadcastHops: transportId nil → not counted.
    let orig = Packet(raw: raw)!
    let h1 = try! Packet(headerType: .header1, packetType: .announce, transportType: .broadcast,
                         destinationType: orig.destinationType, context: orig.context,
                         contextFlag: orig.contextFlag, hops: 3,
                         destinationHash: orig.destinationHash, transportId: nil,
                         payload: orig.payload).packed()
    await store.send(.received(InterfaceID("i0"), h1))
    #expect(store.state.announceTable[destHash]?.localRebroadcasts == 0)
    #expect(store.state.announceTable[destHash] != nil)
    await clock.advance(by: .seconds(5.5))
    await store.receive { if case .delegate(.transmit) = $0 { return true }; return false } // retry still fires
}
```

> If `Packet`'s initializer argument labels or `Packet(raw:)`/`.payload`/`.hops` differ from the above, match the exact `Packet` construction used elsewhere in this test file (e.g. `makeAnnouncePacket` and the relay-forwarding tests both build `Packet(headerType:packetType:transportType:destinationType:context:contextFlag:hops:destinationHash:transportId:payload:)`). Do NOT invent Packet API.

- [ ] **Step 6: Run the new tests**

Run: `swift test --filter TransportTests`
Expected: all pass.

- [ ] **Step 7: Mutation verification**

Apply and confirm the mapped test fails; verify independently if any pair interacts:
1. No suppression — make the replay branch just `return .none` (delete the suppression body) → `peerRebroadcastsCancelPendingRetryAtCap`, `downstreamRebroadcastCancelsPendingRetry`, and the `localRebroadcasts` assertions in the before-first-send/non-matching tests fail.
2. Drop the `entry.rebroadcasts >= 1` gate on the peer cancel (cancel purely on `localRebroadcasts >= cap`) → `peerRebroadcastsBeforeFirstSendDoNotCancel` fails (the entry is cancelled during the initial jitter window at count 2).
3. Wrong peer hops — change the peer condition to `packet.hops == entry.rebroadcastHops + 1` (i.e. the downstream value) → `peerRebroadcastsCancelPendingRetryAtCap` fails (hops 3 no longer counts as a peer).

Run: `swift test --filter TransportTests`. Then revert all and re-run — expect all pass.

- [ ] **Step 8: Full suite**

Run: `swift test`
Expected: all pass (baseline before this slice: 337 pass / 1 skip; +5 new tests → ~342 / 1 skip). Confirm the 4b-3a `exactReplayAnnounceIsDroppedAndNotRebroadcast` / `forgeReplayWithMutatedAppDataIsDropped` still pass (a replay with no pending retry entry still drops silently via the new `guard var entry … else { return .none }`).

- [ ] **Step 9: Commit**

Write the message to `/tmp/ReTiCA/commit-t1.txt`, `git add` the two files, `git commit -F`.

```
feat: collaborative announce suppression — cancel retry on heard re-broadcasts

A peer/downstream re-broadcast of a held announce is a same-blob replay, so
suppression enriches the blob-dedup replay branch: count HEADER_2 re-broadcasts
whose hops equal our held re-broadcast (peer) and cancel the pending retry at
LOCAL_REBROADCASTS_MAX, or cancel immediately when the announce is seen passed on
downstream (hops+1) — both gated on a retry being pending, so the initial send is
never suppressed. PendingAnnounce gains rebroadcastHops + localRebroadcasts. Core
untouched. RNS Transport.py:1774-1791.

Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Notes for the executor

- After this task, the slice (4b-3b-3) is done — and the whole 4b-3b re-broadcast-robustness sub-project (jitter + retries + suppression) is complete. A final whole-slice review is warranted, then the full `swift test` gate on `main` and updating the `transport-relaying` memory (4b-3b-3 merged; only 4b-3c expiry/GC + #4c path requests remain).
- Do NOT touch `Sources/ReTiCA/*`. Suppression removes the `announceTable` entry and cancels the timer; there is no unbounded growth here (a suppressed entry is gone, `localRebroadcasts` is bounded by the cap-then-cancel).
- The suppression cancel fires only when a matching re-broadcast is HEARD (RNS-faithful); an accumulated `localRebroadcasts` does not retroactively cancel a retry after the first send if no further re-broadcast arrives — that is correct (the retry then fires).
