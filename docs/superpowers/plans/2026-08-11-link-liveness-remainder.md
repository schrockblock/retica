# Link Liveness — Remainder (re-derived) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Finish the link-liveness work begun in `2026-08-10-link-liveness-and-lifecycle.md`, re-derived against the corrected mechanism that plan's Task 1 uncovered.

**Why this plan supersedes Tasks 2-6 of the predecessor:** the predecessor justified its tasks with an inverted symptom ("links torn down at 60 s"). The truth, measured, is that links **never** timed out, because an eagerly-constructed `cancelAll` killed every timer on every externally-driven action. Task 1 and its fix round (`61566a2`, `86ee622`) closed that. The remaining tasks are still *individually* correct — reference really does gate keepalives on silence and really does have a STALE state — but their rationale, their reachability, and above all their **test technique** all change now that the timer machinery actually works.

**Architecture:** All tasks are confined to `Sources/ReTiCATransport/LinkSession.swift` and its tests. Tasks are strictly sequential: Task 2 introduces the `transmit(_:_:)` helper and `lastOutbound` that Tasks 3-5 build on; Task 5 patches `.staleDeadline`, which Task 4 creates.

**Tech Stack:** Swift 6, The Composable Architecture 1.26, `swift-testing`, `TestClock`.

---

> ## ⚠️ RE-VERIFIED 2026-08-14 at `46e838e` — DO NOT EXECUTE AS WRITTEN
>
> Two security slices landed in `LinkSession.swift` and `LinkPlane.swift` after this plan was
> written (`16db5e7..46e838e`): *unauthenticated input cannot pin, steal, or kill a link element*,
> then *a destructive transition requires authenticated, owned input*. Every Swift line number
> below has rotted. All **reference-Python** citations were re-checked and remain exact.
>
> **Per-task verdicts:**
>
> | Task | Verdict |
> |---|---|
> | 1 — `cancelAll` comments | **Keep, rewrite the "Why".** The comments are already general; what they lack is the *mechanism* paragraph. Retarget to `LinkSession.swift:222-244` and `LinkSessionTests.swift:662-671`. |
> | 2 — cancel establishment timer on `.handshakeRejected` | **DELETE.** All three target sites were removed by `bd5dd7f`/`331843a` (now `return .none`). At the four surviving exits no establishment timer has been armed yet, so `cancelAll()` would be a literal no-op and the double-delivery cannot occur. |
> | 3 — `lastOutbound` + keepalive gate | **Keep, three fixes required.** See below. |
> | 4 — responder `0xFE` gate | **Keep**, but Step 4's reassurance is false and it now collides with a landed test. |
> | 5 — STALE grace state | **REWRITE FROM SCRATCH.** Not salvageable by editing. |
> | 6 — cancel transfers on close | **Keep**, soften the rationale, add a delegate-ordering constraint. |
> | 7 — large-request timer | **Keep as-is.** Strongest task in the plan; three line refs to refresh. |
>
> ### The omission that governs Tasks 3, 4 and 5
>
> `LinkSession` reads wall time from `@Dependency(\.date)` but drives timers from
> `@Dependency(\.continuousClock)`, and **every existing liveness test pins `$0.date = .constant(epoch)`**.
> Tasks 3-5 all introduce elapsed-time predicates over `date.now`; under a constant date
> `now >= lastOutbound + keepaliveInterval` is `0 >= 30` — permanently false, however far the
> `TestClock` advances. Those gates would therefore suppress *every* keepalive and *every* `0xFE`
> reply, failing four existing tests, and the plan's Step-1 recipes ("keep the link busy with
> inbound DATA just under `keepaliveInterval`") are not expressible at all.
>
> **This plan never mentions `\.date`.** It is the single largest omission. The substrate now
> exists — `advancingResponderStore(clock:seconds:)` at `LinkSessionTests.swift:82-110`, added by
> `b384ed6` — but there is no initiator equivalent. **Insert a preparatory task** establishing an
> advancing-date substrate for both roles, and resequence 3 and 4 behind it.
>
> This is also why `lastData` (`39d44bc`) works and `lastOutbound` will not without that work:
> `lastData` is only ever an *ordering key* (`LinkPlane.swift:319`), never an interval predicate.
>
> ### Task 3 — three specific corrections
>
> 1. **The rationale inverts the reference.** This plan says reference "emits none while *either*
>    direction is busy". `RNS/Link.py:749` is `now >= last_inbound + keepalive **or** now >=
>    last_outbound + keepalive` — so suppression is the negation: silent only when **both**
>    directions have carried traffic. Step 5's code transcription is correct; the prose above it is
>    not, and the prose is what an implementer reads.
> 2. **The `transmit` signature cannot cover all sites.** There are 14 outbound emission sites at
>    HEAD; the last of them forwards a `ResourceTransfer` child's transmit using the **child's**
>    `ifID`, so a helper reading `state.interfaceID` cannot serve it — and that site is the dominant
>    emitter during a resource upload, exactly the traffic reference's `had_outbound()` counts.
>    The signature needs an interface parameter.
> 3. **Reference's third gate is dropped silently.** `RNS/Link.py:750` adds
>    `and now >= self.last_keepalive + self.keepalive`. ReTiCA's `while true` loop supplies the same
>    rate limit structurally — say so rather than omitting it.
>
> `lastOutbound` and `lastData` are **complementary, not redundant**: different direction, different
> consumer, different threat model. Note that `lastData`'s doc comment establishes a house rule
> ("must not be advanceable by an unauthenticated peer") that `lastOutbound` satisfies trivially.
>
> ### Task 5 — why it needs redesign, and why my stated suspicion was wrong
>
> I suspected reviving a STALE link on *unauthenticated* input would contradict the landed auth
> slice. **It does not.** That slice defines "destructive" narrowly — `.failed`, `.closed`,
> `.establishmentFailed`, element removal, transfer removal — and STALE→ACTIVE is constructive.
> More decisively, the predecessor spec *pins the opposite* with a deliberate interop test: "a
> plaintext keepalive still refreshes inactivity". Extension-of-life on unauthenticated input was
> adjudicated and **kept**, because ReTiCA keepalives are plaintext and gating them would tear down
> links with real RNS peers. Reference agrees — `RNS/Link.py:939` sets STALE→ACTIVE before any
> decryption.
>
> **The real defect is worse.** The dispatch switch matches on `(role, status, packetType, context)`
> and only ever names `.pending`, `.handshake`, `.active`. A `.stale` status therefore falls to
> `default: return .none`, and `authDecrypt` is called *only* from inside that switch — so while
> `.stale`, `sawAuthenticatedData` is **structurally always false**. It is not that unauthenticated
> revival is permitted; it is that *authenticated* revival is **unreachable**. An implementer who
> reads the auth slice and dutifully gates revival on authentication produces a link that can never
> revive at all.
>
> **Three cross-file collisions the plan does not list** (it claims to be "confined to
> `LinkSession.swift`" — at HEAD, adding a `Status` case is not):
> 1. `LinkPlane.swift:196` counts `status != .active` as the half-open budget — a `.stale` link
>    would consume it, so stale-but-established links would cause new LINKREQUESTs to be **refused**,
>    re-opening from a new direction the availability surface `6f05357` hardened.
> 2. `LinkPlane.swift:289` counts `status == .active` for the responder cap — a `.stale` link is
>    neither counted nor evictable, so the cap silently under-counts during every grace window.
> 3. `LinkSession.close` guards `status == .active`, and `LinkPlane.swift:186-188` reasons
>    explicitly about which statuses make `.close` a no-op — `.stale` would become a third,
>    unenumerated, un-closeable class, reached by both eviction paths.
>
> Plus **eleven** `status == .active` guards in `LinkSession` gate every outbound API, all of which
> would silently drop during the grace window. Reference does not gate outbound on STALE.
>
> ### Task 6 — rationale is one arrow too strong
>
> "A caller awaiting conclusion hangs forever" is **not** true of the in-repo consumer:
> `LXMFRouter` clears its in-flight state on `.linkClosed` and the retry saga recovers. In fact
> **nothing in `LXMFNode` consumes `.resourceFailed` at all**. Keep the task — reference parity and
> the missing signal are real — but state the consequence honestly: a silently-dropped transfer
> that recovers by retry, not a hang.
>
> Two additions: (a) `LinkPlane.swift:314-316` now *claims* eviction "reaps its transfers", a
> reassuring sentence sitting directly on the gap this task closes — correct it; (b) `LinkPlane`'s
> `.resourceFailed` forwarder guards on the element still existing, and its `.closed` handler
> removes the element, so `.resourceFailed` must be emitted **before** `.closed` or the plane
> swallows every one. The task's `LinkSession`-level test would pass while the fix stays invisible
> above it — a `LinkPlane`-level test is required.
>
> ### Recommended sequence
>
> Land **7** first (independent, correct, depends on nothing). Then **1** (documentation only).
> Then **6**, decoupled from Task 5 by targeting only the three existing close paths. Then the new
> `\.date` substrate task, then **3** and **4** behind it. Send **5** back to design.
>
> The plan's two "hard-won rules" below — `Effect.cancel` eagerness and status-readback vacuity —
> were both re-checked and remain valid and load-bearing. Keep them verbatim in any rewrite.

## Global Constraints

- Platform floor **iOS 17 / macOS 13 / macCatalyst 17**, per `Package.swift:6-10` (authoritative; earlier plans' "iOS 16" was stale). Do not lower it.
- `ReTiCATransport` is interface-agnostic — no Network.framework, no CoreBluetooth.
- Wire compatibility with Python-RNS 1.4.1/1.4.2 is mandatory. These tasks change **when** packets are emitted, never their bytes.
- Tests use `swift-testing` (`import Testing`, `@Test @MainActor func …`, `#expect`), not XCTest.
- Reference Python: `/Users/ell/development/python/Reticulum/RNS/Link.py`.
- Run `swift package clean` before the first build — `RingSet`'s layout changed in `4b968ba` and incremental builds have stale-linked into a SIGSEGV.
- Commit after each task. Trailers must start at column 0:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

### Two hard-won rules that bind every task here

**1. `Effect.cancel(id:)` cancels at CONSTRUCTION.** `Effects/Publisher.swift:8-10` invokes `createPublisher()` immediately; `Effects/Cancellation.swift:106-117` performs the cancel inside that closure. Never bind a cancel — or a `.merge` containing one — to a `let` outside the branch that returns it. `cancelAll()` is a `func` for exactly this reason (`LinkSession.swift:221-225`); do not "simplify" it back.

**2. A status readback after `clock.advance` asserts NOTHING.** `TestReducer._reduce` (`TestStore.swift:2380-2388`) has `.send` do `self.state = state` but `.receive` only append to `receivedActions`; `reducer.state` advances only on drain (`:1781`, `:1839`) or skip (`:2097`). So `#expect(store.state.status == .active)` immediately after a bare `clock.advance` reads pre-teardown state even when the teardown is already queued. **To prove a timer did NOT fire, use an exhaustivity probe:** flip `store.exhaustivity = .on`, then `send` — `send` refuses while `receivedActions` is non-empty (`TestStore.swift:904-919`, reported under `.on` via `:2199-2219`). This exact trap produced a vacuous test in the predecessor plan, and then again in the recipe written to replace it.

**Every task below must verify its new tests RED against the change reverted, and GREEN restored.** "It passes" is not evidence.

---

### Task 1: Correct the over-narrow attribution baked into the fix comments

**Why:** the fix round's own comments describe the `cancelAll` trigger as "the `.delegate(.transmit)` echo of our own `.send`". The re-review measured that this is too narrow, and being wrong here matters because these comments are the guidance the rest of this plan is built on — the predecessor already had to remove a wrong explanation from a test file twice.

The true trigger set: **every action other than an active-link `.received`**, because `.delegate` falls through to `.none`. On an initiator that includes `.keepaliveDeadline` itself, so an initiator lost its keepalive loop *and* its inactivity watchdog at t=30. Also `.provePacket`, `.sendResource`, `.sendRequest`, `.requestDeadline`, and any `ResourceTransfer` child-timer callback firing mid-transfer.

The underlying mechanism, worth stating once and precisely: `.run` effects register their cancellable only when the Task body starts (`Cancellation.swift:86-97`), whereas `Effect.send(_:)` is `.publisher(Just(action))` (`Effect.swift:147-149`) and delivers synchronously. A timer armed in return value R therefore survives every action delivered by R's own sibling sends, and dies at the next externally-driven action.

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift:214-216`
- Modify: `Tests/ReTiCATransportTests/LinkSessionTests.swift:532`

- [ ] **Step 1: Correct both comments** to state the trigger set and the registration-ordering mechanism above. No code change, no test change.
- [ ] **Step 2: Run** `swift test --filter LinkSession`. Expected: unchanged, all pass.
- [ ] **Step 3: Commit** — `docs: the cancelAll trigger set is broader than the fix comment claimed`.

---

### Task 2: Cancel the establishment timer on the handshake-rejected exits

**Why:** parked minor P1 from Task 1's re-review. The three `.establishmentFailed(.handshakeRejected)` exits inside `.received` (`LinkSession.swift:373`, `:377`, `:398`) neither set `status = .closed` nor cancel the establishment timer. The old eager `cancelAll` killed that timer for them incidentally; now that it is a function, the timer survives. Masked in production — `LinkPlane.swift:214` removes the element on `.establishmentFailed` and `forEach` cancels a removed element's effects (`ForEachReducer.swift:203-213`) — but an isolated `LinkSession` store emits a **second** failure delegate at `establishmentTimeout`. That is a latent double-delivery the moment anything consumes `LinkSession` without `LinkPlane`.

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift:373, 377, 398`
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

- [ ] **Step 1: Write the failing test** — drive a responder (or initiator) to a `.handshakeRejected` exit, advance past `establishmentTimeout`, and assert exactly one `.establishmentFailed` is delivered. Use the exhaustivity probe, not a status readback, to prove no second delegate arrives.
- [ ] **Step 2: Run it and confirm it FAILS** with a second `.establishmentFailed`.
- [ ] **Step 3:** set `state.status = .closed` and merge `cancelAll()` into each of the three exits.
- [ ] **Step 4: Run** `swift test --filter LinkSession`. Expected: all pass.
- [ ] **Step 5: Commit.**

---

### Task 3: Track `lastOutbound` and gate the initiator keepalive on silence

**Re-derived rationale.** The predecessor justified this as reducing churn. That still holds, but the reachability changed: before `86ee622` the initiator emitted exactly one keepalive per link, so gating was moot. Now the loop actually repeats, and ReTiCA emits a keepalive every 30 s regardless of traffic where reference emits none while either direction is busy (`RNS/Link.py:749`) — on LoRa that is real, harmful overhead on the medium least able to carry it.

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — `State` (add `lastOutbound`), both `init`s, `.keepaliveDeadline`, and every outbound emission site
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces produced:** `public var lastOutbound: Double?` on `State`; `func transmit(_ state: inout State, _ raw: Data) -> Effect<Action>` — used by Tasks 4-6.

- [ ] **Step 1: Write the failing test** — keep the link busy with inbound DATA just under `keepaliveInterval`, let the keepalive timer fire, and prove **no** 0xFF is emitted. Prove it with the exhaustivity probe.
- [ ] **Step 2: Run it and confirm it FAILS** (a 0xFF transmit is emitted).
- [ ] **Step 3: Add `lastOutbound`** to `State` and both initialisers, defaulting to `nil`.
- [ ] **Step 4: Add the `transmit` helper** that stamps `state.lastOutbound = date.now.timeIntervalSince1970` and returns the transmit effect, and route every outbound link-packet emission through it. Enumerate the sites by reading the file — do not trust line numbers from the predecessor plan, which have drifted.
- [ ] **Step 5: Gate `.keepaliveDeadline`** on `now >= max(lastInbound, activatedAt) + keepaliveInterval || now >= lastOutbound + keepaliveInterval`, per `RNS/Link.py:749`.
- [ ] **Step 6: Run** `swift test --filter LinkSession`, then verify the new test RED with the gate removed and GREEN with it restored.
- [ ] **Step 7: Commit.**

---

### Task 4: Gate the responder's 0xFE reply on outbound silence

**Why:** ReTiCA always answers 0xFF with 0xFE (`LinkSession.swift`, the `(.responder, .active, .data, .keepalive)` branch). Reference replies only if it has itself been outbound-silent for `keepalive` (`RNS/Link.py:1124-1125`) — a responder that is actively sending has already proven liveness.

**Files:** `Sources/ReTiCATransport/LinkSession.swift` (responder keepalive branch); tests.

- [ ] **Step 1: Write the failing test** — responder sends application data, then an inbound 0xFF arrives immediately; assert no 0xFE. Exhaustivity probe.
- [ ] **Step 2: Confirm it FAILS.**
- [ ] **Step 3: Add the gate** using `state.lastOutbound` from Task 3, and route the reply through `transmit(&state:_:)`.
- [ ] **Step 4: Run the suite.** Note `keepaliveKeepsLinkAliveThenStarvedSideTimesOut` drives a responder that never sends, so `lastOutbound` stays `nil` and the reply still goes out — it must keep passing.
- [ ] **Step 5: Verify RED/GREEN, then commit.**

---

### Task 5: Add the STALE grace state before teardown

**Re-derived rationale.** Reference goes ACTIVE → STALE, sends one final keepalive, and allows `rtt * KEEPALIVE_TIMEOUT_FACTOR + STALE_GRACE` = `rtt*4 + 5` s before tearing down, recovering to ACTIVE if anything arrives (`RNS/Link.py:753-766`, `:939`; constants at `:84`, `:88`). ReTiCA jumps straight to `.closed` with zero grace. **This task was unreachable before `86ee622`** — the inactivity timer never fired at all — so it is newly meaningful rather than newly correct.

**Files:** `Sources/ReTiCATransport/LinkSession.swift` — `Status` enum, `.inactivityDeadline`, a new `.staleDeadline` action and `CancelID.stale`, and the post-dispatch hoist in `.received`; tests.

**Interfaces produced:** `Status.stale`; `Action.staleDeadline`; `CancelID.stale`. Task 6 patches `.staleDeadline`.

- [ ] **Step 1: Write two failing tests** — (a) a silent link enters `.stale` and recovers to `.active` on inbound traffic during the grace; (b) with no traffic it tears down after `rtt*4 + 5`.
- [ ] **Step 2: Confirm both FAIL to compile** (`Status.stale` / `Action.staleDeadline` do not exist).
- [ ] **Step 3:** add the `.stale` case, the `.staleDeadline` action, `CancelID.stale`, a `staleTimer` helper, and add `.cancel(id: CancelID.stale)` to `cancelAll()`.
- [ ] **Step 4:** make `.inactivityDeadline` enter `.stale` and arm the grace timer (initiator also sends one final keepalive via `transmit`); add `.staleDeadline` to do what `.inactivityDeadline` used to do.
- [ ] **Step 5:** in the post-dispatch hoist, restore `.stale` → `.active` on any inbound packet and cancel the stale timer. Note the dispatch switch matches on `state.status`, so while `.stale` none of the `.active` cases fire — the packet revives the link but is not processed. That is intentional for this task; if a later slice needs STALE packets processed, add `.stale` to the relevant case patterns rather than reordering this block.
- [ ] **Step 6: Run the suite.** Existing tests that assert teardown at `staleTime` now need an extra grace advance — update each and say why in the commit. Verify RED/GREEN. Commit.

---

### Task 6: Cancel hosted resource transfers when the link closes

**Why:** unchanged from the predecessor (§1.7). `cancelPending` cancels only request timers and `cancelAll()` only the three link timers; hosted `state.transfers` are never cancelled on `.close`, `.staleDeadline`, or a peer LINKCLOSE. `LinkPlane` then removes the element (`LinkPlane.swift:209`), cancelling every child effect — so an in-flight resource vanishes with **no** `.failed` delegate and a caller awaiting conclusion hangs forever. Reference cancels both directions in `link_closed()` (`RNS/Link.py:685-687`).

**Files:** `Sources/ReTiCATransport/LinkSession.swift` (add `failTransfers`, call from all three close paths); `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`.

- [ ] **Step 1: Write the failing test** — start a resource send, close the link, assert `resourceFailed` carries the resource hash and `state.transfers` is empty.
- [ ] **Step 2: Confirm it FAILS** (no `resourceFailed` ever arrives).
- [ ] **Step 3: Add** `func failTransfers(_ state: inout State) -> Effect<Action>` that clears `transfers`, `segmentedSend` and `incomingSegments` and emits `.resourceFailed` per hash.
- [ ] **Step 4: Call it** from `.close`, `.staleDeadline` (Task 5) and the peer-initiated LINKCLOSE branch. Bind `cancelPending(&state)` and `failTransfers(&state)` to locals rather than nesting both `inout` calls in one `.merge` argument list.
- [ ] **Step 5:** run the suite, verify RED/GREEN, commit.

---

### Task 7: Start the large-request response timer at upload conclusion

**Why:** unchanged from the predecessor (§1.8). The request-resource branch arms `requestDeadline` when the resource is *advertised*; the upload can far exceed `rtt*6 + 11.25`, so `requestFailed` fires while the request is still transferring. Reference skips `started_at` for the resource case (`RNS/Link.py:1331-1333`) and arms it in `request_resource_concluded` (`:1368`).

`.concluded` is the sender-side terminal (proof validated); a receiver's inbound request-resource completes via `.delegate(.received)` instead. So `.concluded` with `isRequest == true` means precisely "our outbound request finished uploading".

**Files:** `Sources/ReTiCATransport/LinkSession.swift` (large-request branch; the `.concluded` handler); `Tests/ReTiCATransportTests/LinkSessionRequestTests.swift`.

- [ ] **Step 1: Write the failing test** — send a request over `requestMDU` (431 B), advance well past the response timeout while the upload is in flight, assert the request has not failed.
- [ ] **Step 2: Confirm it FAILS** (`requestFailed` arrives during the advance).
- [ ] **Step 3: Remove** the premature timer from the large-request branch, leaving a comment citing `RNS/Link.py:1331-1333, 1368`.
- [ ] **Step 4: Arm it** in the `.concluded` handler when `adv?.isRequest == true` and the request ID is still pending.
- [ ] **Step 5:** run the suite, verify RED/GREEN, commit.

---

## Self-review notes

- **Coverage:** predecessor Tasks 2-6 map to Tasks 3-7 here; Tasks 1-2 are new, arising from Task 1's parked minors P1 and P2.
- **What changed in the re-derivation:** every task's *test technique* (exhaustivity probes, never status readbacks); Task 5's reachability (newly meaningful, not newly correct); Task 3's rationale (the keepalive loop only started working in `86ee622`); and two new tasks from the fix round's residue.
- **Type consistency:** `transmit(_ state: inout State, _ raw: Data) -> Effect<Action>` (Task 3) is used by Tasks 4-6. `failTransfers` (Task 6) is called from `.staleDeadline`, which Task 5 creates — Task 6 must land after Task 5.
- **Out of scope, deliberately:** RTT-derived keepalive intervals (`clamp(rtt*205.7, 5, 360)`). `LinkSession`'s responder takes the peer's *reported* RTT verbatim where reference takes `max(measured, reported)`, so wiring RTT into teardown timing hands a peer a remote teardown lever. Harden `rtt_packet` first.
- **Known open item, not scheduled here:** `LXMFRouter.swift:415` binds `let cancelPathTimer: Effect<Action> = .cancel(...)` eagerly. Benign today (single case, cancellation unconditionally intended, value returned) but the same footgun one refactor away.
