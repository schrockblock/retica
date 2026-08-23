# F19 — Replayed RESOURCE_REQ Sender-Watchdog Fix Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop a replayed (byte-identical) RESOURCE_REQ from re-arming the sender transfer's watchdog, so the transfer self-terminates on schedule and its responder link is reclaimable.

**Architecture:** Adopt reference's per-resource `req_hashlist`: add a `servedRequestHashes` set to the sender `ResourceTransfer.State`, and in the `(.sender, .data, .resourceRequest)` branch dedup on the raw request packet's hash (over the encrypted bytes) BEFORE any re-send, state reset, or watchdog re-arm. A replay becomes a complete no-op; genuine re-requests (fresh random IV → new packet hash) are still served.

**Tech Stack:** Swift, The Composable Architecture (TCA / swift-testing). Package: ReTiCA, target `ReTiCATransport` (`ResourceTransfer`).

## Global Constraints

- Repo: `/Users/ell/development/ios/pods/ReTiCA`. Edits in `Sources/ReTiCATransport/ResourceTransfer.swift` and `Tests/ReTiCATransportTests/ResourceTransferTests.swift` only. No wire-format change. **No cap** on `servedRequestHashes` (reference has none; it is transfer-scoped and self-bounding).
- The dedup key MUST be the encrypted request packet's hash (`packet.packetHash`), NEVER the decrypted plaintext. `Link.encrypt` uses a fresh random IV per call (`Token.swift:31-32`), so a genuine re-request re-encrypts to a different packet while a replay is byte-identical. Keying on plaintext would falsely dedup a legitimate re-request for the same still-missing parts.
- Commit directly to `main`. No feature branch.
- Commit trailers start at **column 0**. End every commit with exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
  ```
  Write the message to a file, `git commit -F <file>`, verify: `git -C /Users/ell/development/ios/pods/ReTiCA log -1 --format='%(trailers:key=Claude-Session)'` echoes the trailer.
- **One command per shell invocation.** No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`. Redirect a single command's output to a file under /tmp/ReTiCA/ (create with one `mkdir -p`) and Read it back.
- Run tests: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter <TestName>` (single) or without `--filter` for the full suite (expect the 1 known-issue test `holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood` — not your failure). Timeout up to 600000ms. On a spurious signal-11/signal-10 or stale-link `LinkSessionRequestTests` failure, run `swift package clean --package-path /Users/ell/development/ios/pods/ReTiCA` once and retry.
- **Mutation verification mandatory** (three-step rule): green → apply the stated mutation → confirm red → revert → confirm green, before committing.
- Tests keep `store.exhaustivity = .off`. Line numbers here are approximate — locate code by the quoted surrounding lines and report drift.

---

### Task 1: Dedup replayed RESOURCE_REQ on the sender (req_hashlist)

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift` — add a state field (near `sentIndices`, `:42`) and a guard in the `(.sender, .data, .resourceRequest)` branch (`:278-289`).
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift` — add two `@Test` functions.

**Interfaces:**
- Consumes (existing): `packet` (bound from `Packet(raw: data)` at the top of the resource-context handling, `~:275`) and its `packet.packetHash`; test helpers `senderStore(_:_:)`, `senderState`, `resourceRequestPacket(_:)`, `captureTransmits(_:count:)`; `ResourceTransfer.Const.proofRetries` (= 3); the `.awaitingProof` watchdog window `rtt(=1s)*proofTimeoutFactor(=3) + senderGrace(=10s) = 13s`.
- Produces: `ResourceTransfer.State.servedRequestHashes: Set<Data>`.

- [ ] **Step 1: Write the failing tests**

Add to `ResourceTransferTests.swift`:

```swift
// F19: a genuine re-request (same plaintext, but re-encrypted with a fresh random IV → a different
// packetHash) must still be served. This proves the dedup keys on the ciphertext, not the plaintext,
// so legitimate retransmission is not broken.
@Test @MainActor func aFreshlyEncryptedReRequestIsStillServed() async {
    let data = Data("f19: a genuine re-request must still be served".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)                 // drain the advertisement
    let s = store.state
    await store.send(.received(resourceRequestPacket(s)))        // first genuine request
    _ = await captureTransmits(store, count: s.parts.count)      // all parts served
    // Second call re-encrypts with a fresh IV → different packet → must be served again.
    await store.send(.received(resourceRequestPacket(s)))
    let reServed = await captureTransmits(store, count: s.parts.count)
    #expect(reServed.count == s.parts.count,
            "a freshly-encrypted re-request must be served — dedup keys on ciphertext, not plaintext")
}

// F19: a byte-identical replayed RESOURCE_REQ must NOT re-arm the sender watchdog. Advancing the
// clock in sub-window steps while replaying the captured request must still let the watchdog fire
// (proofRetriesLeft decrements). Without the dedup, each replay re-arms (cancelInFlight) the
// watchdog and it never fires.
@Test @MainActor func replayedRequestsDoNotPostponeTheSenderWatchdog() async {
    let data = Data("f19: replays must not re-arm the sender watchdog".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    let s = store.state
    let req = resourceRequestPacket(s)                           // capture ONE request; replay these bytes
    await store.send(.received(req))
    _ = await captureTransmits(store, count: s.parts.count)
    #expect(store.state.status == .awaitingProof)
    #expect(store.state.servedRequestHashes.count == 1)
    // awaitingProof window = rtt(1s)*proofTimeoutFactor(3) + senderGrace(10s) = 13s. Step 5s < 13s,
    // 4 steps = 20s > 13s, replaying each step. With the dedup the replays are no-ops so the window
    // elapses and the watchdog fires; without it every replay resets the 13s timer.
    let before = store.state.proofRetriesLeft
    for _ in 0..<4 {
        await store.send(.received(req))                        // byte-identical replay → deduped no-op
        await clock.advance(by: .seconds(5))
        await store.skipReceivedActions(strict: false)
    }
    #expect(store.state.proofRetriesLeft < before,
            "the watchdog must fire despite replays — a replay must not re-arm it")
    #expect(store.state.servedRequestHashes.count == 1, "a replay is not recorded a second time")
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter replayedRequestsDoNotPostponeTheSenderWatchdog`
Expected: FAILS to compile first (no `servedRequestHashes` member) — that is the red state. `aFreshlyEncryptedReRequestIsStillServed` will PASS once it compiles (today's code serves every request), which is fine — it is the guard test proving the fix doesn't over-dedup; it must still pass after.

- [ ] **Step 3: Add the state field**

In `ResourceTransfer.State` (near `public var sentIndices: Set<Int>`, `~:42`), add:
```swift
        /// F19 `req_hashlist`: hashes of RESOURCE_REQ packets already served on this SENDER transfer.
        /// Keyed on the ENCRYPTED packet (`packet.packetHash`) so a byte-identical replay is deduped
        /// while a genuine re-request (fresh random IV → new packet) is served. Transfer-scoped;
        /// no cap, matching reference's per-resource list.
        public var servedRequestHashes: Set<Data> = []
```
The `= []` default means neither the sender nor the receiver init needs to change (the custom inits omit it and the default applies). Verify the file compiles with the inits untouched.

- [ ] **Step 4: Add the dedup guard in the sender request branch**

In the `(.sender, .data, .resourceRequest)` branch, immediately after the existing gate
`guard p.count >= pad + 32, Data(p[...]) == state.resourceHash else { return .none }` (`~:284-285`)
and BEFORE `state.status = .transferring` (`~:287`), insert:
```swift
                    // F19: dedup on the ENCRYPTED request packet. A byte-identical replay has the
                    // same packetHash; a genuine re-request re-encrypts with a fresh random IV, so
                    // its packetHash differs and it is served. A replay must be a complete no-op —
                    // no re-send, no status/retry reset, and above all no watchdog re-arm, or it
                    // postpones the sender watchdog (the transfer's only self-terminator) without bound.
                    guard !state.servedRequestHashes.contains(packet.packetHash) else { return .none }
                    state.servedRequestHashes.insert(packet.packetHash)
```
(`packet` is already in scope from `Packet(raw: data)` at the top of the resource handling; confirm the property is spelled `packetHash` on `Packet` — it is the same property `Transport.seenPacketHashes` keys on.)

- [ ] **Step 5: Run the tests to verify they pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter replayedRequestsDoNotPostponeTheSenderWatchdog` → PASS.
Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA --filter aFreshlyEncryptedReRequestIsStillServed` → PASS.

- [ ] **Step 6: Mutation-verify both directions**

(a) Comment out the `guard !state.servedRequestHashes.contains(...)` line (leave the insert). Run `replayedRequestsDoNotPostponeTheSenderWatchdog` → FAIL (replays re-arm the watchdog; `proofRetriesLeft` stays at its initial value). Revert.
(b) Change the guard/insert to key on the decrypted body instead of `packet.packetHash` — e.g. key on `Data(p)` (the decrypted plaintext). Run `aFreshlyEncryptedReRequestIsStillServed` → FAIL (the second request has identical plaintext, gets wrongly deduped, so its parts are never served and `captureTransmits` times out). Revert to `packet.packetHash`.
Run both tests again → PASS.

- [ ] **Step 7: Full suite + commit**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA` — all pass except the known issue. Existing sender tests (`senderServesAllPartsThenAwaitsProofAndConcludes`, `senderAwaitingProofTimesOutThenFails`) must stay green — they send a request once, so the dedup never triggers on them.
Stage only the two files. Commit:
```
fix: F19 — dedup replayed RESOURCE_REQ so it cannot re-arm the sender watchdog

A captured, byte-identical RESOURCE_REQ replayed on a loop re-armed the sender
transfer's watchdog every round (cancelInFlight restarts it), so the transfer
never self-terminated and its eviction-immune responder link stayed pinned —
F11's lockout without the session key. Adopt reference's per-resource
req_hashlist: dedup an incoming request on packet.packetHash (the encrypted
packet) before any re-send or watchdog re-arm. A replay is now a no-op; genuine
re-requests (fresh random IV → new packet hash) are still served. No cap.
```
Verify the trailer parses.

---

## Notes for the executor

- **Key on `packet.packetHash`, never the decrypted body.** This is load-bearing (see Global Constraints and mutation (b)). If `Packet` spells the hash differently, use the same property `Transport` uses for `seenPacketHashes` and report the drift.
- **No cap** on `servedRequestHashes` — transfer-scoped, dies with the transfer. Do not add one.
- **Out of scope:** F16 (the link's inactivity timer is still refreshed by replayed traffic). This fix makes the transfer self-terminate despite replays; F11 then reclaims the transfer-less link under cap pressure. F16 is a separate item.
- If the sender init's `rtt` default is not `.seconds(1)`, recompute the `.awaitingProof` window (`rtt*3 + 10s`) and adjust the step (must be `< window`) and loop count (total must exceed `window`) in the pin-broken test; report the change.
