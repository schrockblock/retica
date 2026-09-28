# Transfer-Aware Delivery Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** An LXMF message sent as a Resource is never resent while its transfer runs, its outcome comes from the transfer (concluded → confirmed, failed → one retry 10 s later, rejected → failed), progress reaches the app for outbound and inbound Resources, the app can cancel an outbound message, one Resource runs per link at a time, a long transfer keeps its link alive, and two propagation-node gaps are closed.

**Architecture:** `ResourceTransfer` emits `progress` events and says whether a failure was a rejection. `LinkSession` maps them to `resourceProgress` / `resourceFailed(_, rejected:)` keyed by resource hash and gains `cancelResource(hash:)`; `LinkPlane` and `TransportEndpoint` pass both up by link ID. `LXMFRouter` gives every pending copy a `Phase` (`retrying` / `transferring` / `queued`): a Resource copy arms no retry timer, is resolved by `resourceDeliveredOnLink` / `resourceFailedOnLink`, and waits in a per-destination `resourceQueue` while its link is busy. `cancelOutbound` tears a message down and remembers it in a `cancelledMessages` ring. `LXMFNode` records which resource hash is OUR transfer on each link (from the first sender-role progress event), so a conclusion or failure for any other hash on that link (an inbound transfer, or a cancelled one landing late) never resolves our copy; it maps progress onto the reference scale, reports inbound progress, cancels per message, re-arms the router's idle timer on transfer activity, marks the propagated copy pending during its stamp search, and refuses a propagated copy larger than the node's announced limit.

**Tech Stack:** Swift 6 / SwiftPM, swift-composable-architecture (`TestStore`, `TestClock`, `@Reducer`), Swift Testing. Reference: LXMF 1.1.0 / RNS 1.4.2 at `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/`.

**Spec:** `docs/superpowers/specs/2026-09-27-transfer-aware-delivery-design.md` (binding — read it first). Where this plan departs from its wording, the task says so and why; the full list is at the end under "Self-review notes".

## Global Constraints

- **Where:** all ReTiCA work happens ONLY in the worktree `/Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery` on branch `feat/transfer-aware-delivery`. `WT` below means that path. Never read-modify-write, build, or run git commands against `/Users/ell/development/ios/pods/ReTiCA` (another agent owns it) or against the app's main checkout `/Users/ell/development/ios/apps/ReTiCaMsgr`.
- **Task 0 is a gate.** Nothing starts until the branch sits on the latest `main` (rebase if `main` moved; if the rebase conflicts, `git -C WT rebase --abort`, STOP and report) and the full baseline `swift test --package-path WT --no-parallel` is green: currently **1272 tests, 1 known issue**.
- **ReTiCA drift:** if `main` moves during the run, rebase at the next task boundary (`git -C WT rebase main`) and re-run the full suite before starting the next task. A conflict means STOP and report.
- **Commits** go on `feat/transfer-aware-delivery` (never `main`). Stage explicit paths only (`git -C WT add <path> <path> ...`, never `-A`/`.`). Each task writes its message to its OWN file `/tmp/ReTiCaMsgr/msg-tad-task-N.txt` (N = task number) with the Write tool, then runs `git -C WT commit -F /tmp/ReTiCaMsgr/msg-tad-task-N.txt`. Message = `feat:`/`fix:`/`test:`/`docs:` subject, blank line, body, blank line, then exactly these two lines at column 0 (the first names the model that actually wrote the commit, e.g. `Claude Opus 5.5 (1M context)`):
  `Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1`
  No semicolons anywhere in a commit message.
- **Shell:** one command per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreters (`python -c`, heredocs into an interpreter). Scripts and sed scripts go in files under `/tmp/ReTiCaMsgr/` (`mkdir -p /tmp/ReTiCaMsgr` if missing). `sed -i '' -f /tmp/ReTiCaMsgr/x.sed file` is one command and is allowed. Redirecting one command's output to a file (`cmd > /tmp/ReTiCaMsgr/x.log`) is allowed.
- **Tests:** `swift test --package-path WT --filter A --filter B` (`--filter` is repeatable). Full runs ALWAYS with `--no-parallel` (parallel mode has a known signal 10/11 flake). `pnNodeOfferRejectedWithInvalidPeeringKey` is a known timing flake: if it fails alone, re-run the full suite once. Filtering still compiles every target, so the whole package (all sources and all tests) must compile at the end of every task. Every new test name starts with its task's prefix — `transferEvents` (T1), `linkPlumbing` (T2), `routerTransfer` (T3), `linkQueue` (T4), `routerCancel` (T5), `nodeTransfer` (T6), `pnCopy` (T7), `transferEndToEnd` (T8), `tadCompat` (T10) — so `--filter <prefix>` selects exactly that task's new tests. None of these prefixes match any existing test name today (checked: `routerQueue` would have matched `routerQueuedDirectSendStopsEstablishingAfterMaxAttempts`, hence `linkQueue`).
- **Mutation verification is mandatory** for every task with tests: (a) run the task's filter, all GREEN; (b) apply the task's listed mutation batch to production code in one go, run the filter once, confirm EVERY listed test is RED; (c) revert every mutation BY HAND with the Edit tool (never `git checkout -- <file>`, which would also discard the task's real changes), confirm `git -C WT diff` shows only the task's intended changes, run again, all GREEN. If a test survives its mutation, fix the test and restart at (a). Each batch lists which test each mutation breaks, and why no mutation masks another or crashes the process. Tests edited only mechanically to compile against a new shape assert nothing new and are exempt.
- **Test style** (match neighbouring files): free `@Test @MainActor func` functions; `TestStore` with `exhaustivity = .off` for positive flows and exact `receive(.action)` or predicate `receive { ... }`. An ABSENCE claim goes exhaustive for that window (`store.exhaustivity = .on`, then an exhaustive no-op "probe" send, which fails if any received action is still unasserted), then back to `.off` before teardown when long-lived timers run on by design. Under `.off`, `receive` silently skips non-matching actions, so absence can never be asserted under `.off`. Never call `skipInFlightEffects` while `.on`. `skipReceivedActions(strict: false)` before flipping to `.on` is fine. The full suite must end with exactly the 1 pre-existing known issue — no new "Skipped assertions" or other known issues.
- **Ordering fact the tests rely on:** TCA processes synchronous `.send` effects inside the same `store.send` call, breadth-first (FIFO `bufferedActions`, `Core.swift:112-116`; `.publisher` effects are received on `UIScheduler`, which runs inline on the main thread). So after `await store.send(x)` returns, every synchronous chain it started has been reduced and `store.state` reflects it; `.merge(.send(a), .send(b))` reduces `a` before `b`, and an action emitted while reducing `a` comes after `b`.
- **Reference behaviour this mirrors** (spec "Reference behaviour"): `LXMessage.__resource_concluded` (LXMessage.py:597-606) — COMPLETE → delivered, REJECTED → terminal, else tear the link down and go back to OUTBOUND. RNS `Link.receive` treats every RESOURCE_RCL on an outgoing resource as `_rejected()` (RNS/Link.py:1114-1121), whether it answers the advertisement (`Resource.reject`, RNS/Resource.py:155-159) or cancels mid-transfer. `cancel_outbound` (LXMRouter.py:1719-1744). Progress `0.10 + 0.90 × resource progress` (LXMessage.py:623-624), 0.05 when the link is active (LXMRouter.py:2788-2790).
- **Constants:** `LXMFDelivery.retryWaitSeconds` (10), `LXMFDelivery.maxAttempts` (5), `LXMFDelivery.linkMaxInactivitySeconds` (600) are unchanged. New: `LXMFNode.linkActiveProgress = 0.05`, `LXMFNode.transferStartProgress = 0.10`.
- **ReTiCaMsgr app** (Task 10 only). Work happens in a git worktree of the app repo at `/Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat` on branch `feat/retica-tad-compat`, created from the app's `main` in Task 10 Step 1. Same commit rules (message file `/tmp/ReTiCaMsgr/msg-tad-task-10.txt`). The ReTiCA dependency is overridden TEMPORARILY and never committed: `ReTiCaMsgrCore/Package.swift`, `ReTiCaMsgrCore/Package.resolved` and `ReTiCaMsgr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved` are backed up first and restored byte-identical (checked with `cmp`) before committing. Never uninstall anything. The Xcode app-target build `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build` must succeed.

## Review Focus

Inputs the spec implies but its own examples don't exercise, most likely to bite first. Each is pinned by a named test in the owning task.

1. **A late `resourceConcluded` / `resourceFailed` for a transfer that is no longer ours** — cancelled, or an INBOUND transfer on the same link failing — must not resolve the copy now in flight on that link. `LinkSession` reports inbound failures through the same `resourceFailed`, so a link-ID-only mapping would fail our outbound message whenever the peer's transfer to us failed. Tests: T6 `nodeTransferStaleConclusionForAnotherResourceIsIgnored`, `nodeTransferInboundFailureDoesNotFailTheOutboundCopy`; T5 `routerCancelTransferringCopyCancelsItsResource` (late failure/conclusion after cancel is a no-op).
2. **A link that closes mid-transfer** (peer LINKCLOSE, our idle teardown, give-up) reaps its transfers silently — no `resourceFailed` is ever emitted. The copy must go back to `.retrying` with one retry timer, not sit in `.transferring` forever. Tests: T3 `routerTransferLinkClosedMidTransferRequeuesTheCopy`, the edited `idleTeardownReapsLinkResourceInFlight`.
3. **The retry after a failed transfer** must start a fresh Resource on the NEW link once one is established, not on the link that was torn down. Tests: T3 `routerTransferRetryAfterFailureStartsAFreshTransferOnTheNewLink`, `routerTransferPropagatedFailureRetriesTheSameBytesOnAFreshLink`.
4. **A second large send on a busy link** (today it overwrites `LinkSession.State.segmentedSend` and `linkResourceInFlight`, last write wins) must wait, and a SMALL send must never wait behind a transfer. Tests: T4 `linkQueueSecondLargeSendWaitsForTheFirst`, `linkQueueTwoQueuedSendsDrainInOrderOnLinkEstablished`, `linkQueueSmallSendIsNotQueuedBehindATransfer`.
5. **Progress must never go backwards for a copy** — a retry restarts the wire transfer at 0.05/0.10 — and the propagated copy's progress must not be reported as the delivery copy's. Tests: T6 `nodeTransferProgressIsMonotonicPerCopy`, `nodeTransferPropagatedCopyReportsPropagationProgress`; T8 end-to-end samples.
6. **Cancel while the only work is a stamp search** (the router holds nothing for the message yet) must still report `deliveryCancelled` exactly once and stop the CPU burn; cancel with work in the router must not report twice. Tests: T6 `nodeTransferCancelOutboundDuringADeliveryStampSearchReportsCancelled`, `nodeTransferCancelOutboundStopsThePropagationStampSearch`; T5 `routerCancelBothCopiesReportsOnce`.
7. **A propagation node that announces `perTransferLimit: 0`** (every existing test fixture does) must not make every propagated copy "too large". Test: T7 `pnCopyNodeMarksTheCopyPendingWhileItsStampIsSearched`.

---

## File Structure

ReTiCA (`WT`):

- `Sources/ReTiCATransport/ResourceTransfer.swift` — `Delegate.failed(rejected:)`, `Delegate.progress(...)`, `State.lastProgressPercent`, the 1 % rate-limited `progress` helper and its four emission points.
- `Sources/ReTiCATransport/LinkSession.swift` — `Delegate.resourceFailed(_, rejected:)`, `Delegate.resourceProgress(...)`, `Action.cancelResource(hash:)`, `State.cancelledTransferIDs`, the reaper clearing it.
- `Sources/ReTiCANode/LinkPlane.swift` — `Action.cancelResource(linkID:hash:)`, `Delegate.resourceFailed(linkID:resourceHash:rejected:)`, `Delegate.resourceProgress(...)`.
- `Sources/ReTiCANode/TransportEndpoint.swift` — the same three, plus the `linkPlaneRoute` alias for `cancelResource`.
- `Sources/ReTiCANode/LXMFRouter.swift` — `Phase`, `PendingDelivery.phase`, `FailureReason`, `RefusalReason`; `resourceQueue`, `cancelledMessages`, `pendingPropagatedCopies`; actions `resourceFailedOnLink`, `cancelOutbound`, `linkActivity`, `propagatedCopyPending`, `propagatedCopyRefused`, `abandonPendingPropagatedCopies`; delegates `deliveryRejected`, `deliveryCancelled`, `cancelResource`, `propagationRefused`; helpers `destination(ofLink:)`, `startResource`, `startOrQueueResource`, `startNextQueued`, `orphanTransfer`; `State.hasOutboundState(for:)`.
- `Sources/ReTiCANode/LXMFNode.swift` — `outboundTransfers`, `transferProgress`, `inboundProgress`; `Action.cancelOutbound`; delegates `deliveryRejected`, `deliveryCancelled`, `deliveryProgress`, `propagationProgress`, `inboundTransferProgress`, `propagationRefused`; progress constants and fraction helpers; per-hash stamp `CancelID`s; the mappings.
- New tests: `Tests/ReTiCATransportTests/ResourceTransferEventsTests.swift` (T1), `Tests/ReTiCATransportTests/LinkSessionTransferPlumbingTests.swift` (T2), `Tests/ReTiCANodeTests/TransferPlumbingTests.swift` (T2), `Tests/ReTiCANodeTests/LXMFRouterTransferTests.swift` (T3), `Tests/ReTiCANodeTests/LXMFRouterLinkQueueTests.swift` (T4), `Tests/ReTiCANodeTests/LXMFRouterCancelTests.swift` (T5), `Tests/ReTiCANodeTests/LXMFNodeTransferMappingTests.swift` (T6), `Tests/ReTiCANodeTests/LXMFPropagatedCopyTests.swift` (T7), `Tests/ReTiCANodeTests/LXMFNodeTransferEndToEndTests.swift` (T8).
- Existing tests edited: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`, `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift` (T1, T2), `Tests/ReTiCANodeTests/LinkPlaneTests.swift` (T2), `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (T3).
- Docs (T9): `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md`, `docs/reference-parity-checklist.md`.

ReTiCaMsgr (T10, app worktree): `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift`, `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`, `docs/superpowers/backlog-retica-followups.md`.

Verified app surface (read-only analysis, 2026-09-27): the app switches on `LXMFNode.Action.Delegate` only in `AppFeature.swift` (`messageReceived` :687, `deliveryFailed` :777, `propagationAccepted` :897, `deliveryConfirmed` :924) and has a `case .node, .binding:` catch-all (:1032), so new delegate cases compile. `DiagnosticsSnapshot.swift` reads `PendingDelivery.resend` and `.attempts` only (:539-600), and its tests build `LXMFRouter.PendingDelivery(resend:attempts:)` (DiagnosticsSnapshotTests.swift :277-409), which keeps compiling because `phase` is defaulted. Nothing in the app names `ResourceTransfer`, `LinkSession`, `LinkPlane` or `LXMFRouter.Action` cases other than `.rehydrateDedup` / `.messagesDownloaded`.

---

### Task 0: Rebase gate and green baseline

**Files:** none modified.

- [ ] **Step 1: Confirm the branch**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery branch --show-current`
Expected: `feat/transfer-aware-delivery`

- [ ] **Step 2: Confirm the branch sits on the latest main**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery merge-base --is-ancestor main HEAD`
Expected: exit status 0. If non-zero, run `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery rebase main`. If the rebase reports a conflict, run `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery rebase --abort` and STOP: report the conflicting files. (Branch was cut from `main` at `6df1c5a`; the spec commit `15c0301` sits on top.)

- [ ] **Step 3: Confirm the tree**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery status --short`
Expected: empty, or only `?? docs/superpowers/plans/2026-09-27-transfer-aware-delivery.md` if the controller has not committed this plan yet. Anything else: STOP and report.

- [ ] **Step 4: Green baseline**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --no-parallel > /tmp/ReTiCaMsgr/tad-t0-baseline.log`
Expected: the tail of the log reads `Test run with 1272 tests ... passed ... with 1 known issue` (the count may be higher if `main` moved; record it — every later task compares against it). If anything fails to compile or fails (other than one re-run of `pnNodeOfferRejectedWithInvalidPeeringKey`), STOP and report. Do not start Task 1.

---

### Task 1: `ResourceTransfer` reports progress and whether a failure was a rejection

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift` (State :49, Delegate :146-151, helpers after :217, `.advertise` :248-254, `.accept` :276-277, sender request :340-341, receiver part :374-440, RCL :448-452, every `.delegate(.failed)`)
- Modify: `Sources/ReTiCATransport/LinkSession.swift:1121` (pattern only)
- Modify: `Tests/ReTiCATransportTests/ResourceTransferTests.swift:419,430,598`, `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift:166,305` (mechanical)
- Create: `Tests/ReTiCATransportTests/ResourceTransferEventsTests.swift`

**Interfaces:**
- Produces:
  - `ResourceTransfer.Action.Delegate.failed(rejected: Bool)` — `true` only when the SENDER receives a RESOURCE_RCL (advertisement reject or receiver cancel). Every other failure (watchdog, bad assembly, our own `.cancel`, an inbound ICL at the receiver, the HMU sequencing error) is `false`.
  - `ResourceTransfer.Action.Delegate.progress(bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int)` — sender: bytes of the parts served so far over the bytes of all parts; receiver: bytes of the parts received over the advertised transfer size (clamped). `segment`/`segments` come from the advertisement (1-based, clamped to `1...segments`). Emitted with `bytesDone == 0` on `.advertise` (sender) and `.accept` (receiver), then only when the done fraction crosses a new whole percent, so a transfer emits at most 101.
  - `ResourceTransfer.State.lastProgressPercent: Int` (starts at -1).

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCATransportTests/ResourceTransferEventsTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// Transfer-aware delivery, Task 1: `ResourceTransfer` reports progress and says whether a failure
// was the peer refusing the transfer. `TransferEventRecorder` wraps one transfer and records those
// two delegate kinds in its own state, so a test can compare the exact sequence — a
// non-exhaustive `TestStore` can only look for one action at a time, never count them.

private let eventsKey = Data(repeating: 0x01, count: 64)
private let eventsLinkID = Data(repeating: 0xAB, count: 16)

@Reducer
struct TransferEventRecorder {
    @ObservableState
    struct State: Equatable {
        var transfer: ResourceTransfer.State
        var progress: [Progress] = []
        var failures: [Bool] = []
    }
    struct Progress: Equatable { var done: Int; var total: Int; var segment: Int; var segments: Int }
    enum Action: Equatable { case transfer(ResourceTransfer.Action) }
    var body: some ReducerOf<Self> {
        Scope(state: \.transfer, action: \.transfer) { ResourceTransfer() }
        Reduce { state, action in
            switch action {
            case let .transfer(.delegate(.progress(done, total, segment, segments))):
                state.progress.append(Progress(done: done, total: total, segment: segment, segments: segments))
            case let .transfer(.delegate(.failed(rejected))):
                state.failures.append(rejected)
            case .transfer:
                break
            }
            return .none
        }
    }
}

/// SHA-256-derived bytes: bzip2 cannot shrink them, so the part count is predictable.
private func eventsIncompressible(count: Int) -> Data {
    var result = Data()
    var i = 0
    while result.count < count {
        let chunk = Crypto.fullHash(Data([0x5E, UInt8(i & 0xff), UInt8((i >> 8) & 0xff), UInt8((i >> 16) & 0xff)]))
        result.append(contentsOf: chunk.prefix(min(chunk.count, count - result.count)))
        i += 1
    }
    return result
}

private func eventsSender(_ data: Data, sdu: Int = 24, segmentIndex: UInt64 = 1, totalSegments: UInt64 = 1,
                          totalDataSize: UInt64? = nil) -> ResourceTransfer.State {
    ResourceTransfer.State(sending: data, linkID: eventsLinkID, sessionKey: eventsKey, interfaceID: InterfaceID("s"),
                           prefix: Data([0x0A, 0x0B, 0x0C, 0x0D]), randomHash: Data([0x01, 0x02, 0x03, 0x04]),
                           sdu: sdu, segmentIndex: segmentIndex, totalSegments: totalSegments,
                           totalDataSize: totalDataSize)
}

private func eventsReceiver() -> ResourceTransfer.State {
    ResourceTransfer.State(receivingOn: eventsLinkID, sessionKey: eventsKey, interfaceID: InterfaceID("r"))
}

private func eventsPacket(_ context: PacketContext, _ payload: Data) -> Data {
    try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast, destinationType: .link,
                context: context, contextFlag: false, hops: 0, destinationHash: eventsLinkID,
                transportId: nil, payload: payload).packed()
}

/// A RESOURCE_REQ for exactly the parts in `indices`. Each call encrypts afresh (random IV), so two
/// requests for the same parts are two distinct packets and both are served.
private func eventsRequest(_ s: ResourceTransfer.State, _ indices: Range<Int>) -> Data {
    let hashes = s.partMapHashes[indices].reduce(Data()) { $0 + $1 }
    return eventsPacket(.resourceRequest, Link.encrypt(Data([0x00]) + s.resourceHash + hashes, sessionKey: eventsKey))
}

private func eventsAdvertisement(_ s: ResourceTransfer.State) -> Data {
    eventsPacket(.resourceAdvertisement, Link.encrypt(s.advertisement!.pack(), sessionKey: eventsKey))
}

private func eventsCancel(_ context: PacketContext, _ hash: Data) -> Data {
    eventsPacket(context, Link.encrypt(hash, sessionKey: eventsKey))
}

private func eventsBytes(_ s: ResourceTransfer.State, _ indices: Range<Int>) -> Int {
    s.parts[indices].reduce(0) { $0 + $1.count }
}

@MainActor
private func eventsStore(_ transfer: ResourceTransfer.State)
    -> TestStore<TransferEventRecorder.State, TransferEventRecorder.Action> {
    let store = TestStore(initialState: TransferEventRecorder.State(transfer: transfer)) {
        TransferEventRecorder()
    } withDependencies: { $0.continuousClock = TestClock() }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func transferEventsSenderReportsNothingDoneOnAdvertise() async {
    let s = eventsSender(eventsIncompressible(count: 160))
    let total = eventsBytes(s, 0..<s.parts.count)
    #expect(total == Int(s.advertisement!.transferSize))
    let store = eventsStore(s)
    await store.send(.transfer(.advertise))
    #expect(store.state.progress == [.init(done: 0, total: total, segment: 1, segments: 1)])
}

@Test @MainActor func transferEventsSenderReportsTheBytesItHasServed() async {
    let s = eventsSender(eventsIncompressible(count: 160))
    #expect(s.parts.count > 4)
    let total = eventsBytes(s, 0..<s.parts.count)
    let store = eventsStore(s)
    await store.send(.transfer(.advertise))
    await store.send(.transfer(.received(eventsRequest(s, 0..<4))))
    #expect(store.state.progress.last == .init(done: eventsBytes(s, 0..<4), total: total, segment: 1, segments: 1))
    await store.send(.transfer(.received(eventsRequest(s, 4..<s.parts.count))))
    #expect(store.state.progress.last == .init(done: total, total: total, segment: 1, segments: 1))
}

/// Spec §3: an event only when the done fraction crosses a new whole percent (or on the final
/// part). One part per request makes the step visible: there are more parts than percent steps.
@Test @MainActor func transferEventsSenderReportsOnlyWholePercentSteps() async {
    let s = eventsSender(eventsIncompressible(count: 1600), sdu: 8)
    let n = s.parts.count
    #expect(n > 150)
    let total = eventsBytes(s, 0..<n)
    // The rule, replayed: 0 on advertise, then an event whenever a new whole percent is reached.
    var expected: [TransferEventRecorder.Progress] = [.init(done: 0, total: total, segment: 1, segments: 1)]
    var last = 0
    for i in 0..<n {
        let done = eventsBytes(s, 0..<(i + 1))
        let percent = Int(Double(done) * 100 / Double(total))
        if percent > last {
            expected.append(.init(done: done, total: total, segment: 1, segments: 1))
            last = percent
        }
    }
    let store = eventsStore(s)
    await store.send(.transfer(.advertise))
    for i in 0..<n { await store.send(.transfer(.received(eventsRequest(s, i..<(i + 1))))) }
    #expect(store.state.progress == expected)
    #expect(store.state.progress.count < n)
    #expect(store.state.progress.last?.done == total)
}

@Test @MainActor func transferEventsReceiverReportsZeroOnAcceptThenEveryPartsBytes() async {
    let sender = eventsSender(eventsIncompressible(count: 160))
    let total = eventsBytes(sender, 0..<sender.parts.count)
    let store = eventsStore(eventsReceiver())
    await store.send(.transfer(.accept(eventsAdvertisement(sender))))
    #expect(store.state.progress == [.init(done: 0, total: total, segment: 1, segments: 1)])
    for chunk in sender.parts { await store.send(.transfer(.received(eventsPacket(.resource, chunk)))) }
    #expect(store.state.transfer.status == .complete)
    let dones = store.state.progress.map(\.done)
    #expect(dones == dones.sorted())
    // Ten-ish parts: every part is more than one percent, so every part reports.
    #expect(store.state.progress.count == sender.parts.count + 1)
    #expect(store.state.progress.last == .init(done: total, total: total, segment: 1, segments: 1))
}

@Test @MainActor func transferEventsReportTheSegmentOfASplitResource() async {
    let segment = eventsSender(eventsIncompressible(count: 160), segmentIndex: 2, totalSegments: 3, totalDataSize: 480)
    let receiver = eventsStore(eventsReceiver())
    await receiver.send(.transfer(.accept(eventsAdvertisement(segment))))
    #expect(receiver.state.progress.first?.segment == 2)
    #expect(receiver.state.progress.first?.segments == 3)
    let sender = eventsStore(segment)
    await sender.send(.transfer(.advertise))
    #expect(sender.state.progress.first?.segment == 2)
    #expect(sender.state.progress.first?.segments == 3)
}

@Test @MainActor func transferEventsARejectedAdvertisementIsRejected() async {
    let s = eventsSender(eventsIncompressible(count: 100))
    let store = eventsStore(s)
    await store.send(.transfer(.advertise))
    await store.send(.transfer(.received(eventsCancel(.resourceReceiverCancel, s.resourceHash))))
    #expect(store.state.failures == [true])
}

@Test @MainActor func transferEventsAReceiverCancelMidTransferIsRejected() async {
    let s = eventsSender(eventsIncompressible(count: 160))
    let store = eventsStore(s)
    await store.send(.transfer(.advertise))
    await store.send(.transfer(.received(eventsRequest(s, 0..<2))))
    #expect(store.state.transfer.status == .transferring)
    await store.send(.transfer(.received(eventsCancel(.resourceReceiverCancel, s.resourceHash))))
    #expect(store.state.failures == [true])
    #expect(store.state.transfer.status == .failed)
}

@Test @MainActor func transferEventsASenderTimeoutIsNotRejected() async {
    let store = eventsStore(eventsSender(eventsIncompressible(count: 100)))
    await store.send(.transfer(.advertise))
    for _ in 0...ResourceTransfer.Const.maxAdvRetries { await store.send(.transfer(.senderDeadline)) }
    #expect(store.state.failures == [false])
}

@Test @MainActor func transferEventsAnInitiatorCancelAtTheReceiverIsNotRejected() async {
    let sender = eventsSender(eventsIncompressible(count: 100))
    let store = eventsStore(eventsReceiver())
    await store.send(.transfer(.accept(eventsAdvertisement(sender))))
    await store.send(.transfer(.received(eventsCancel(.resourceInitiatorCancel, sender.resourceHash))))
    #expect(store.state.failures == [false])
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter transferEvents`
Expected: FAIL to compile — `ResourceTransfer.Action.Delegate` has no member `progress`, and `failed` has no associated value.

- [ ] **Step 3: Change the delegate and add the progress state**

In `Sources/ReTiCATransport/ResourceTransfer.swift`, replace

```swift
        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(Data)
            case concluded
            case failed
        }
```

with

```swift
        public enum Delegate: Equatable {
            case transmit(InterfaceID, Data)
            case received(Data)
            case concluded
            /// The transfer is over without success. `rejected` is true only when the peer REFUSED
            /// it: a RESOURCE_RCL reaching the sender, whether it answered the advertisement
            /// (reference `Resource.reject`, RNS/Resource.py:155-159) or cancelled mid-transfer.
            /// Reference `Link.receive` routes every RCL on an outgoing resource to `_rejected()`
            /// (RNS/Link.py:1114-1121), and LXMF treats REJECTED as terminal (LXMessage.py:597-606).
            case failed(rejected: Bool)
            /// How far the transfer has got. Sender: bytes of the parts served so far; receiver: bytes
            /// of the parts received. `bytesTotal` is the whole segment's stream size. `segment` and
            /// `segments` are this segment's 1-based index and the count (1 and 1 unless split).
            /// Emitted with `bytesDone == 0` when the transfer starts, then only when the done
            /// fraction crosses a new whole percent, so a transfer reports at most 101 times.
            case progress(bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int)
        }
```

Replace

```swift
        public var servedRequestHashes: Set<Data> = []
```

with

```swift
        public var servedRequestHashes: Set<Data> = []
        /// Highest whole percent already reported through `.delegate(.progress)`; -1 before the
        /// first report. The rate limit of spec §3: report only on crossing a new percent.
        public var lastProgressPercent: Int = -1
```

- [ ] **Step 4: Carry `rejected` on every failure**

Write `/tmp/ReTiCaMsgr/t1-failed.sed`:

```
s/\.delegate(\.failed))/.delegate(.failed(rejected: false)))/g
```

Run: `sed -i '' -f /tmp/ReTiCaMsgr/t1-failed.sed /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery/Sources/ReTiCATransport/ResourceTransfer.swift`
Run: `grep -c "failed(rejected: false)" /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery/Sources/ReTiCATransport/ResourceTransfer.swift`
Expected: `12`.

Then make the sender's RCL branch the one rejection. Replace

```swift
                case (.sender, .data, .resourceReceiverCancel):
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          Data(plain) == state.resourceHash else { return .none }
                    state.status = .failed
                    return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed(rejected: false))))
```

with

```swift
                case (.sender, .data, .resourceReceiverCancel):
                    // The peer refused this transfer — at the advertisement or mid-transfer, which
                    // reference does not distinguish (RNS/Link.py:1114-1121 → `Resource._rejected`).
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          Data(plain) == state.resourceHash else { return .none }
                    state.status = .failed
                    return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.failed(rejected: true))))
```

- [ ] **Step 5: Add the progress helper**

Insert directly after the `senderCancel` helper (after the line `                return .send(.delegate(.transmit(s.interfaceID, icl)))` and its closing `            }`), before `            func requestNextWindow(_ s: inout State) -> Effect<Action> {`:

```swift
            /// One `.progress` event when the done fraction has crossed a new whole percent since the
            /// last report (spec §3's rate limit), else nothing. The first call always reports
            /// (`lastProgressPercent` starts at -1), and the final part always reaches 100.
            func progress(_ s: inout State) -> Effect<Action> {
                let total: Int
                let done: Int
                switch s.role {
                case .sender:
                    total = s.parts.reduce(0) { $0 + $1.count }
                    done = s.sentIndices.reduce(0) { $0 + s.parts[$1].count }
                case .receiver:
                    // `t` is off the wire: clamp rather than trap (docs/wire-narrowing-inventory.md).
                    total = Int(clamping: s.advertisement?.transferSize ?? 0)
                    done = min(s.receivedParts.values.reduce(0) { $0 + $1.count }, total)
                }
                guard total > 0 else { return .none }
                let percent = Int(Double(done) * 100 / Double(total))
                guard percent > s.lastProgressPercent else { return .none }
                s.lastProgressPercent = percent
                let segments = max(1, Int(clamping: s.advertisement?.totalSegments ?? 1))
                let segment = min(max(1, Int(clamping: s.advertisement?.segmentIndex ?? 1)), segments)
                return .send(.delegate(.progress(bytesDone: done, bytesTotal: total,
                                                 segment: segment, segments: segments)))
            }

```

- [ ] **Step 6: Emit at the four points**

`.advertise` — replace

```swift
                state.status = .advertised
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), armSenderWatchdog(state))
```

with

```swift
                state.status = .advertised
                let started = progress(&state)                        // 0 of the whole: the transfer starts
                return .merge(.send(.delegate(.transmit(state.interfaceID, raw))), armSenderWatchdog(state), started)
```

`.accept` — replace

```swift
                state.retriesLeft = Const.maxRetries
                state.status = .requesting
                return requestNextWindow(&state)
```

with

```swift
                state.retriesLeft = Const.maxRetries
                state.status = .requesting
                let request = requestNextWindow(&state)
                return .merge(request, progress(&state))              // 0 of the whole: the transfer starts
```

Sender, served request — replace

```swift
                    effects.append(armSenderWatchdog(state))
                    return .merge(effects)
```

with

```swift
                    effects.append(progress(&state))
                    effects.append(armSenderWatchdog(state))
                    return .merge(effects)
```

Receiver, each part — replace

```swift
                    while state.receivedParts[state.consecutiveCompletedHeight + 1] != nil {
                        state.consecutiveCompletedHeight += 1
                    }
                    guard state.outstanding.isEmpty else { return armReceiverWatchdog(state) }
```

with

```swift
                    while state.receivedParts[state.consecutiveCompletedHeight + 1] != nil {
                        state.consecutiveCompletedHeight += 1
                    }
                    let reported = progress(&state)
                    guard state.outstanding.isEmpty else { return .merge(reported, armReceiverWatchdog(state)) }
```

then replace

```swift
                        state.window = state.window.grown()
                        state.retriesLeft = Const.maxRetries
                        return requestNextWindow(&state)
```

with

```swift
                        state.window = state.window.grown()
                        state.retriesLeft = Const.maxRetries
                        return .merge(reported, requestNextWindow(&state))
```

then replace

```swift
                    guard let praw = linkPacket(.proof, .resourceProof, proof)
                    else { return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.received(out)))) }
                    return .merge(.cancel(id: CancelID.watchdog),
                                  .send(.delegate(.transmit(state.interfaceID, praw))),
                                  .send(.delegate(.received(out))))
```

with

```swift
                    guard let praw = linkPacket(.proof, .resourceProof, proof)
                    else { return .merge(.cancel(id: CancelID.watchdog), reported, .send(.delegate(.received(out)))) }
                    return .merge(.cancel(id: CancelID.watchdog),
                                  reported,
                                  .send(.delegate(.transmit(state.interfaceID, praw))),
                                  .send(.delegate(.received(out))))
```

(The three assembly/verification failure returns in between keep no progress: the transfer failed.)

- [ ] **Step 7: Keep `LinkSession` compiling**

In `Sources/ReTiCATransport/LinkSession.swift` replace

```swift
            case let .transfer(.element(elementID, .delegate(.failed))):
```

with

```swift
            case let .transfer(.element(elementID, .delegate(.failed(_)))):
```

(`.progress` falls into the existing `case .transfer: return .none` until Task 2.)

- [ ] **Step 8: Update the existing tests (mechanical)**

Write `/tmp/ReTiCaMsgr/t1-rt-tests.sed`:

```
419s/\.delegate(\.failed))/.delegate(.failed(rejected: false)))/
430s/\.delegate(\.failed))/.delegate(.failed(rejected: true)))/
598s/\.delegate(\.failed))/.delegate(.failed(rejected: false)))/
```

Run: `sed -i '' -f /tmp/ReTiCaMsgr/t1-rt-tests.sed /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery/Tests/ReTiCATransportTests/ResourceTransferTests.swift`
Run: `grep -n "failed(rejected" /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery/Tests/ReTiCATransportTests/ResourceTransferTests.swift`
Expected: exactly lines 419 (`false`, `receiverFailsOnInboundInitiatorCancel`), 430 (`true`, `senderFailsOnInboundReceiverCancel` — now a pinned rejection), 598 (`false`, `senderCancelsOnNonBoundaryHmuRequest`). If the line numbers moved, fix the addresses and re-run.

Write `/tmp/ReTiCaMsgr/t1-ls-tests.sed`:

```
s/action: \.delegate(\.failed))/action: .delegate(.failed(rejected: false)))/g
```

Run: `sed -i '' -f /tmp/ReTiCaMsgr/t1-ls-tests.sed /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery/Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`
Run: `grep -c "failed(rejected: false)" /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery/Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`
Expected: `2`.

- [ ] **Step 9: Run the new tests**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter transferEvents --filter senderFailsOnInboundReceiverCancel`
Expected: 10 tests PASS.

- [ ] **Step 10: Mutation batch (apply all at once, in `ResourceTransfer.swift`)**

1. `.advertise`: drop `, started` from the merge → RED `transferEventsSenderReportsNothingDoneOnAdvertise` (no event), `transferEventsReportTheSegmentOfASplitResource` (sender half: `progress.first` is nil), `transferEventsSenderReportsOnlyWholePercentSteps` (the leading 0 is missing).
2. Sender served request: delete `effects.append(progress(&state))` → RED `transferEventsSenderReportsTheBytesItHasServed` (last stays at 0).
3. Rate limit: `guard percent > s.lastProgressPercent` → `guard percent >= s.lastProgressPercent` → RED `transferEventsSenderReportsOnlyWholePercentSteps` (an event per part). Mutation 1 and 2 also redden it; that is fine — 3 is the only one that reddens nothing else, and 1/2 each have another test of their own.
4. Receiver bytes: in `progress`, `done = min(s.receivedParts.values.reduce(0) { $0 + $1.count }, total)` → `done = min(s.receivedParts.count, total)` → RED `transferEventsReceiverReportsZeroOnAcceptThenEveryPartsBytes` (last `done` is a part count).
5. Segment: `let segment = min(max(1, ...), segments)` → `let segment = 1` → RED `transferEventsReportTheSegmentOfASplitResource` (receiver half).
6. RCL branch: `.failed(rejected: true)` → `.failed(rejected: false)` → RED `transferEventsARejectedAdvertisementIsRejected`, `transferEventsAReceiverCancelMidTransferIsRejected`, `senderFailsOnInboundReceiverCancel`.
7. `.senderDeadline` `.advertised` give-up branch: its `.failed(rejected: false)` → `true` → RED `transferEventsASenderTimeoutIsNotRejected`.
8. `(.receiver, .data, .resourceInitiatorCancel)` branch: `false` → `true` → RED `transferEventsAnInitiatorCancelAtTheReceiverIsNotRejected`.

No mutation traps (they change values, not control flow into a crash) and none restores another's value. Run the Step 9 command: every listed test FAILS. Revert all eight by hand, `git -C WT diff` shows only this task's changes, run again: all PASS.

- [ ] **Step 11: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --no-parallel > /tmp/ReTiCaMsgr/tad-t1-full.log`
Expected: all pass with the 1 known issue; test count = Task 0 count + 9.

- [ ] **Step 12: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery add Sources/ReTiCATransport/ResourceTransfer.swift Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/ResourceTransferEventsTests.swift Tests/ReTiCATransportTests/ResourceTransferTests.swift Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`

Write `/tmp/ReTiCaMsgr/msg-tad-task-1.txt`:

```
feat: resource transfers report progress and rejection

ResourceTransfer emits progress (bytes done of the segment, segment
index and count) when a transfer starts and whenever the done fraction
crosses a new whole percent. failed now carries rejected, true only
when the sender receives a RESOURCE_RCL, matching reference
Link.receive routing every RCL on an outgoing resource to _rejected.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery commit -F /tmp/ReTiCaMsgr/msg-tad-task-1.txt`

---
### Task 2: Progress, rejection and cancel through `LinkSession`, `LinkPlane` and `TransportEndpoint`

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` (State after :95, Action after :209, Delegate :225, reducer: new cases before :1056, the `.failed` case :1121-1140, reaper :1155-1159)
- Modify: `Sources/ReTiCANode/LinkPlane.swift` (Action after :98, Delegate :120, verb case after :263, delegate cases :403-405)
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift` (Action after :98, Delegate :122, delegate cases :296-297, catch-all :317-320, `linkPlaneRoute` :401-402 and :429-430)
- Modify: `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift:167,306`, `Tests/ReTiCANodeTests/LinkPlaneTests.swift:102,127` (mechanical plus two round-trip lines)
- Create: `Tests/ReTiCATransportTests/LinkSessionTransferPlumbingTests.swift`, `Tests/ReTiCANodeTests/TransferPlumbingTests.swift`

**Interfaces:**
- Consumes (Task 1): `ResourceTransfer.Action.Delegate.failed(rejected: Bool)`, `.progress(bytesDone:bytesTotal:segment:segments:)`.
- Produces:
  - `LinkSession.Action.Delegate.resourceFailed(Data, rejected: Bool)` (was `resourceFailed(Data)`).
  - `LinkSession.Action.Delegate.resourceProgress(hash: Data, role: ResourceTransfer.Role, bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int)` — only for plain Resources (never request/response Resources); `hash` is the hash `resourceConcluded`/`resourceFailed` carry (a split Resource's original hash).
  - `LinkSession.Action.cancelResource(hash: Data)` — cancels OUR plain outbound Resource with that hash (or the split send whose original hash it is): the transfer sends the standard RESOURCE_ICL, remaining segments are dropped, and NO `resourceFailed` follows. Unknown hash: no-op.
  - `LinkSession.State.cancelledTransferIDs: Set<UUID>`.
  - `LinkPlane.Action.cancelResource(linkID: Data, hash: Data)`; `LinkPlane.Action.Delegate.resourceFailed(linkID: Data, resourceHash: Data, rejected: Bool)`; `LinkPlane.Action.Delegate.resourceProgress(linkID: Data, resourceHash: Data, role: ResourceTransfer.Role, bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int)`.
  - `TransportEndpoint.Action.cancelResource(linkID: Data, hash: Data)` (aliased onto the plane by `linkPlaneRoute`); `TransportEndpoint.Action.Delegate.resourceFailed(linkID:resourceHash:rejected:)` and `.resourceProgress(linkID:resourceHash:role:bytesDone:bytesTotal:segment:segments:)`, same shapes as the plane's.

- [ ] **Step 1: Write the failing `LinkSession` tests**

Create `Tests/ReTiCATransportTests/LinkSessionTransferPlumbingTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

// Transfer-aware delivery, Task 2: `LinkSession` reports transfer progress, carries the rejection
// flag, and cancels one of our outbound Resources by hash. `SessionEventRecorder` keeps every
// progress, failure and transmit delegate in state so a test can compare the exact sequence.

private let plumbKey = Data(repeating: 0x01, count: 64)
private let plumbLinkID = Data(repeating: 0xAB, count: 16)

@Reducer
struct SessionEventRecorder {
    @ObservableState
    struct State: Equatable {
        var session: LinkSession.State
        var progress: [LinkSession.Action.Delegate] = []
        var failures: [LinkSession.Action.Delegate] = []
        var transmits: [Data] = []
    }
    enum Action: Equatable { case session(LinkSession.Action) }
    var body: some ReducerOf<Self> {
        Scope(state: \.session, action: \.session) { LinkSession() }
        Reduce { state, action in
            guard case let .session(.delegate(event)) = action else { return .none }
            switch event {
            case .resourceProgress: state.progress.append(event)
            case .resourceFailed: state.failures.append(event)
            case let .transmit(_, raw): state.transmits.append(raw)
            default: break
            }
            return .none
        }
    }
}

private func plumbActiveSession() -> LinkSession.State {
    var s = LinkSession.State(responderFor: Identity(), destinationHash: Data(repeating: 0x02, count: 16),
                              interfaceID: InterfaceID("i"))
    s.status = .active
    s.sessionKey = plumbKey
    s.linkID = plumbLinkID
    s.rtt = 1.0
    return s
}

@MainActor
private func plumbStore(_ session: LinkSession.State = plumbActiveSession())
    -> TestStore<SessionEventRecorder.State, SessionEventRecorder.Action> {
    let store = TestStore(initialState: SessionEventRecorder.State(session: session)) {
        SessionEventRecorder()
    } withDependencies: {
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.continuousClock = TestClock()
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

/// SHA-256-derived bytes: bzip2 cannot shrink them, so a payload above `maxEfficientSize` splits.
private func plumbIncompressible(count: Int) -> Data {
    var result = Data()
    var i = 0
    while result.count < count {
        let chunk = Crypto.fullHash(Data([0x71, UInt8(i & 0xff), UInt8((i >> 8) & 0xff), UInt8((i >> 16) & 0xff)]))
        result.append(contentsOf: chunk.prefix(min(chunk.count, count - result.count)))
        i += 1
    }
    return result
}

private func plumbTotal(_ t: ResourceTransfer.State) -> Int { t.parts.reduce(0) { $0 + $1.count } }

@Test @MainActor func linkPlumbingSenderProgressCarriesTheResourceHash() async {
    let store = plumbStore()
    await store.send(.session(.sendResource(Data("a resource sent out over the link".utf8))))
    let t = store.state.session.transfers[0]
    #expect(store.state.progress == [.resourceProgress(hash: t.resourceHash, role: .sender, bytesDone: 0,
                                                       bytesTotal: plumbTotal(t), segment: 1, segments: 1)])
}

/// A split send reports every segment under the ORIGINAL hash — the one `resourceConcluded` and
/// `resourceFailed` carry for it — so the node can tell it is still the same transfer.
@Test @MainActor func linkPlumbingSegmentedSendReportsTheOriginalHash() async {
    let store = plumbStore()
    await store.send(.session(.sendResource(plumbIncompressible(count: LinkSession.maxEfficientSize + 100))))
    let oh = store.state.session.segmentedSend!.originalHash
    let first = store.state.session.transfers[0]
    await store.send(.session(.transfer(.element(id: first.id, action: .delegate(.concluded)))))
    let second = store.state.session.transfers.first { $0.advertisement?.segmentIndex == 2 }!
    #expect(second.resourceHash != oh)
    #expect(store.state.progress.last == .resourceProgress(hash: oh, role: .sender, bytesDone: 0,
                                                           bytesTotal: plumbTotal(second), segment: 2, segments: 2))
}

@Test @MainActor func linkPlumbingInboundProgressIsReceiverRole() async {
    let sender = ResourceTransfer.State(sending: Data(repeating: 0x33, count: 100), linkID: plumbLinkID,
                                        sessionKey: plumbKey, interfaceID: InterfaceID("i"),
                                        prefix: Data([0, 1, 2, 3]), randomHash: Data([4, 5, 6, 7]), sdu: 24)
    let adv = try! Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                          destinationType: .link, context: .resourceAdvertisement, contextFlag: false, hops: 0,
                          destinationHash: plumbLinkID, transportId: nil,
                          payload: Link.encrypt(sender.advertisement!.pack(), sessionKey: plumbKey)).packed()
    let store = plumbStore()
    await store.send(.session(.received(adv)))
    #expect(store.state.progress == [.resourceProgress(hash: sender.resourceHash, role: .receiver, bytesDone: 0,
                                                       bytesTotal: Int(sender.advertisement!.transferSize),
                                                       segment: 1, segments: 1)])
}

/// Request and response Resources are the link's own plumbing, not messages: no progress for them.
@Test @MainActor func linkPlumbingRequestResourcesReportNoProgress() async {
    let store = plumbStore()
    await store.send(.session(.sendRequest(path: "/big", data: MsgPack.encode(.bin(Data(repeating: 0x41, count: 1000))))))
    #expect(store.state.session.transfers.first?.advertisement?.isRequest == true)   // a Resource did start
    #expect(store.state.progress.isEmpty)
}

@Test @MainActor func linkPlumbingRejectedFailureCarriesTheFlag() async {
    var session = plumbActiveSession()
    let t = ResourceTransfer.State(sending: Data("plain resource payload".utf8), linkID: plumbLinkID,
                                   sessionKey: plumbKey, interfaceID: InterfaceID("i"),
                                   prefix: Data([0, 1, 2, 3]), randomHash: Data([4, 5, 6, 7]), sdu: 24)
    session.transfers.append(t)
    let store = plumbStore(session)
    await store.send(.session(.transfer(.element(id: t.id, action: .delegate(.failed(rejected: true))))))
    #expect(store.state.failures == [.resourceFailed(t.resourceHash, rejected: true)])
}

@Test @MainActor func linkPlumbingCancelResourceSendsTheCancelPacketAndNoFailure() async {
    let store = plumbStore()
    await store.send(.session(.sendResource(Data("cancel me".utf8))))
    let hash = store.state.session.transfers[0].resourceHash
    await store.send(.session(.cancelResource(hash: hash)))
    #expect(store.state.transmits.count == 2)                                  // ADV, then ICL
    let icl = Packet(raw: store.state.transmits[1])!
    #expect(icl.context == .resourceInitiatorCancel)
    #expect(Link.decrypt(icl.payload, sessionKey: plumbKey) == hash)
    #expect(store.state.session.transfers.isEmpty)
    #expect(store.state.failures.isEmpty)                                      // the owner asked: not news
}

@Test @MainActor func linkPlumbingCancelResourceOnASegmentedSendDropsTheRemainingSegments() async {
    let store = plumbStore()
    await store.send(.session(.sendResource(plumbIncompressible(count: LinkSession.maxEfficientSize + 100))))
    let oh = store.state.session.segmentedSend!.originalHash
    await store.send(.session(.cancelResource(hash: oh)))
    #expect(store.state.session.segmentedSend == nil)
    #expect(store.state.session.transfers.isEmpty)
    #expect(store.state.transmits.count == 2)                                  // segment 1's ADV, then its ICL
    #expect(Packet(raw: store.state.transmits[1])?.context == .resourceInitiatorCancel)
    #expect(store.state.failures.isEmpty)
}

/// A split send whose segment in flight is already gone: clearing the rest needs no packet.
@Test @MainActor func linkPlumbingCancelResourceWithNoSegmentInFlightClearsWithoutAPacket() async {
    var session = plumbActiveSession()
    let oh = Data(repeating: 0x5A, count: 32)
    session.segmentedSend = LinkSession.State.SegmentedSend(remaining: [Data([0x01])], nextIndex: 2, total: 2,
                                                            originalHash: oh, totalDataSize: 10,
                                                            currentTransferID: UUID())
    let store = plumbStore(session)
    await store.send(.session(.cancelResource(hash: oh)))
    #expect(store.state.session.segmentedSend == nil)
    #expect(store.state.transmits.isEmpty)
}

@Test @MainActor func linkPlumbingCancelResourceForAnUnknownHashDoesNothing() async {
    let store = plumbStore()
    await store.send(.session(.sendResource(Data("keep me".utf8))))
    await store.send(.session(.cancelResource(hash: Data(repeating: 0xEE, count: 32))))
    #expect(store.state.transmits.count == 1)                                  // the ADV only
    #expect(store.state.session.transfers.count == 1)
}
```

- [ ] **Step 2: Write the failing plane/endpoint tests**

Create `Tests/ReTiCANodeTests/TransferPlumbingTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Transfer-aware delivery, Task 2: the plane names the link for progress and failures, and a cancel
// addressed by link ID reaches the session that owns it.

private let plumbElement = UUID(uuidString: "00000000-0000-0000-0000-0000000000AA")!
private let plumbLink = Data(repeating: 0x4C, count: 16)
private let plumbHash = Data(repeating: 0x07, count: 32)

private func plumbSession() -> LinkSession.State {
    var s = LinkSession.State(id: plumbElement, responderFor: Identity(),
                              destinationHash: Data(repeating: 0x02, count: 16), interfaceID: InterfaceID("tcp"))
    s.status = .active
    s.linkID = plumbLink
    s.sessionKey = Data(repeating: 0x01, count: 64)
    s.rtt = 1
    return s
}

@MainActor
private func plumbEndpoint() -> TestStore<TransportEndpoint.State, TransportEndpoint.Action> {
    let store = TestStore(initialState: TransportEndpoint.State(
        linkPlane: LinkPlane.State(links: [plumbSession()]),
        tcpClient: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) {
        TransportEndpoint()
    } withDependencies: {
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
        $0.uuid = .incrementing
    }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func linkPlumbingPlaneReportsSessionProgressUnderTheLinkID() async {
    let store = plumbEndpoint()
    await store.send(.link(.element(id: plumbElement, action: .delegate(.resourceProgress(
        hash: plumbHash, role: .receiver, bytesDone: 5, bytesTotal: 10, segment: 2, segments: 3)))))
    await store.receive(.delegate(.resourceProgress(linkID: plumbLink, resourceHash: plumbHash, role: .receiver,
                                                    bytesDone: 5, bytesTotal: 10, segment: 2, segments: 3)))
}

@Test @MainActor func linkPlumbingPlaneCarriesTheRejectedFlag() async {
    let store = plumbEndpoint()
    await store.send(.link(.element(id: plumbElement, action: .delegate(.resourceFailed(plumbHash, rejected: true)))))
    await store.receive(.delegate(.resourceFailed(linkID: plumbLink, resourceHash: plumbHash, rejected: true)))
}

@Test @MainActor func linkPlumbingEndpointCancelResourceReachesTheSession() async {
    let store = plumbEndpoint()
    await store.send(.cancelResource(linkID: plumbLink, hash: plumbHash))
    await store.receive(.link(.element(id: plumbElement, action: .cancelResource(hash: plumbHash))))
}
```

- [ ] **Step 3: Run to verify they fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter linkPlumbing`
Expected: FAIL to compile — no `resourceProgress`, no `cancelResource`, `resourceFailed` takes one argument.

- [ ] **Step 4: `LinkSession` shapes**

In `Sources/ReTiCATransport/LinkSession.swift`:

Replace `        public var segmentedSend: SegmentedSend? = nil` with

```swift
        public var segmentedSend: SegmentedSend? = nil
        /// Transfers ended by `.cancelResource`. Their `.failed` is not surfaced as
        /// `resourceFailed`: the owner asked for the cancel, so it is not news, and a late report
        /// could otherwise be mistaken for the failure of whatever the owner sends next.
        public internal(set) var cancelledTransferIDs: Set<UUID> = []
```

Replace

```swift
        case provePacket(packetHash: Data)
        case transfer(IdentifiedActionOf<ResourceTransfer>)
```

with

```swift
        case provePacket(packetHash: Data)
        /// Cancel OUR plain outbound Resource `hash` — the hash `resourceProgress` and
        /// `resourceConcluded` report, i.e. a split send's original hash. The transfer in flight
        /// sends the standard RESOURCE_ICL, segments not yet sent are dropped, and no
        /// `resourceFailed` follows. Unknown hash: no-op. Mirrors reference `Resource.cancel()`
        /// (RNS/Resource.py:1084-1117) as driven by `LXMRouter.cancel_outbound`.
        case cancelResource(hash: Data)
        case transfer(IdentifiedActionOf<ResourceTransfer>)
```

Replace `            case resourceFailed(Data)` with

```swift
            /// A plain Resource on this link failed. `rejected` is true when the peer refused it (see
            /// `ResourceTransfer.Action.Delegate.failed`). Not emitted for a `.cancelResource`.
            case resourceFailed(Data, rejected: Bool)
            /// Progress of a plain (non-request, non-response) Resource, either direction. `hash` is
            /// what `resourceConcluded`/`resourceFailed` carry: a split Resource's original hash.
            case resourceProgress(hash: Data, role: ResourceTransfer.Role, bytesDone: Int,
                                  bytesTotal: Int, segment: Int, segments: Int)
```

- [ ] **Step 5: `LinkSession` reducer**

Replace

```swift
            case let .transfer(.element(_, .delegate(.transmit(ifID, raw)))):
                return .send(.delegate(.transmit(ifID, raw)))
```

with

```swift
            case let .cancelResource(hash):
                if let send = state.segmentedSend, send.originalHash == hash {
                    // A split send: drop the segments not yet sent, then cancel the one in flight.
                    state.segmentedSend = nil
                    guard state.transfers[id: send.currentTransferID] != nil else { return .none }
                    state.cancelledTransferIDs.insert(send.currentTransferID)
                    return .send(.transfer(.element(id: send.currentTransferID, action: .cancel)))
                }
                guard let target = state.transfers.first(where: {
                    $0.role == .sender && $0.resourceHash == hash
                        && $0.advertisement?.isRequest != true && $0.advertisement?.isResponse != true
                }) else { return .none }
                state.cancelledTransferIDs.insert(target.id)
                return .send(.transfer(.element(id: target.id, action: .cancel)))

            case let .transfer(.element(elementID, .delegate(.progress(done, total, segment, segments)))):
                // Request/response Resources are this link's own plumbing, not deliveries.
                guard let t = state.transfers[id: elementID], let adv = t.advertisement,
                      !adv.isRequest, !adv.isResponse else { return .none }
                return .send(.delegate(.resourceProgress(hash: adv.isSplit ? adv.originalHash : t.resourceHash,
                                                         role: t.role, bytesDone: done, bytesTotal: total,
                                                         segment: segment, segments: segments)))
            case let .transfer(.element(_, .delegate(.transmit(ifID, raw)))):
                return .send(.delegate(.transmit(ifID, raw)))
```

Replace the whole failed case

```swift
            case let .transfer(.element(elementID, .delegate(.failed(_)))):
                let t = state.transfers[id: elementID]
                state.transfers.remove(id: elementID)
                if let rid = t?.advertisement?.requestID, state.pendingRequests.contains(rid) {
                    state.pendingRequests.remove(rid)
                    return .merge(.cancel(id: CancelID.request(rid)),
                                  .send(.delegate(.requestFailed(requestID: rid))))
                }
                if t?.advertisement?.isRequest == true || t?.advertisement?.isResponse == true { return .none }
                // Segmented send in progress on this element?
                if let send = state.segmentedSend, send.currentTransferID == elementID {
                    state.segmentedSend = nil
                    return .send(.delegate(.resourceFailed(send.originalHash)))
                }
                if let a = t?.advertisement, a.isSplit == true {
                    state.incomingSegments[a.originalHash] = nil
                    return .send(.delegate(.resourceFailed(a.originalHash)))
                }
                guard let hash = t?.resourceHash else { return .none }
                return .send(.delegate(.resourceFailed(hash)))
```

with

```swift
            case let .transfer(.element(elementID, .delegate(.failed(rejected)))):
                let t = state.transfers[id: elementID]
                state.transfers.remove(id: elementID)
                // Ended by `.cancelResource`: the owner asked for it.
                if state.cancelledTransferIDs.remove(elementID) != nil { return .none }
                if let rid = t?.advertisement?.requestID, state.pendingRequests.contains(rid) {
                    state.pendingRequests.remove(rid)
                    return .merge(.cancel(id: CancelID.request(rid)),
                                  .send(.delegate(.requestFailed(requestID: rid))))
                }
                if t?.advertisement?.isRequest == true || t?.advertisement?.isResponse == true { return .none }
                // Segmented send in progress on this element?
                if let send = state.segmentedSend, send.currentTransferID == elementID {
                    state.segmentedSend = nil
                    return .send(.delegate(.resourceFailed(send.originalHash, rejected: rejected)))
                }
                if let a = t?.advertisement, a.isSplit == true {
                    state.incomingSegments[a.originalHash] = nil
                    return .send(.delegate(.resourceFailed(a.originalHash, rejected: rejected)))
                }
                guard let hash = t?.resourceHash else { return .none }
                return .send(.delegate(.resourceFailed(hash, rejected: rejected)))
```

Replace the reaper

```swift
        Reduce { state, _ in
            guard state.status == .closed, !state.transfers.isEmpty else { return .none }
            state.transfers.removeAll()
            return .none
        }
```

with

```swift
        Reduce { state, _ in
            guard state.status == .closed, !state.transfers.isEmpty || !state.cancelledTransferIDs.isEmpty
            else { return .none }
            state.transfers.removeAll()
            state.cancelledTransferIDs.removeAll()
            return .none
        }
```

- [ ] **Step 6: `LinkPlane`**

In `Sources/ReTiCANode/LinkPlane.swift`:

Replace `        case sendResourceOverLink(linkID: Data, data: Data)` with

```swift
        case sendResourceOverLink(linkID: Data, data: Data)
        /// Cancel our outbound Resource `hash` on `linkID` (see `LinkSession.Action.cancelResource`).
        case cancelResource(linkID: Data, hash: Data)
```

Replace `            case resourceFailed(linkID: Data, resourceHash: Data)` with

```swift
            case resourceFailed(linkID: Data, resourceHash: Data, rejected: Bool)
            case resourceProgress(linkID: Data, resourceHash: Data, role: ResourceTransfer.Role,
                                  bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int)
```

Replace

```swift
            case let .sendResourceOverLink(linkID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendResource(data))))
```

with

```swift
            case let .sendResourceOverLink(linkID, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .sendResource(data))))

            case let .cancelResource(linkID, hash):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                return .send(.link(.element(id: element.id, action: .cancelResource(hash: hash))))
```

Replace

```swift
            case let .link(.element(elementID, .delegate(.resourceFailed(hash)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash)))
```

with

```swift
            case let .link(.element(elementID, .delegate(.resourceFailed(hash, rejected)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash, rejected: rejected)))

            case let .link(.element(elementID, .delegate(.resourceProgress(hash, role, done, total, segment, segments)))):
                guard let linkID = state.links[id: elementID]?.linkID else { return .none }
                return .send(.delegate(.resourceProgress(linkID: linkID, resourceHash: hash, role: role,
                                                         bytesDone: done, bytesTotal: total,
                                                         segment: segment, segments: segments)))
```

- [ ] **Step 7: `TransportEndpoint`**

In `Sources/ReTiCANode/TransportEndpoint.swift`:

Replace (in `Action`) `        case sendResourceOverLink(linkID: Data, data: Data)` with

```swift
        case sendResourceOverLink(linkID: Data, data: Data)
        case cancelResource(linkID: Data, hash: Data)
```

Replace (in `Delegate`) `            case resourceFailed(linkID: Data, resourceHash: Data)` with

```swift
            case resourceFailed(linkID: Data, resourceHash: Data, rejected: Bool)
            case resourceProgress(linkID: Data, resourceHash: Data, role: ResourceTransfer.Role,
                                  bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int)
```

Replace

```swift
            case let .linkPlane(.delegate(.resourceFailed(linkID, hash))):
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash)))
```

with

```swift
            case let .linkPlane(.delegate(.resourceFailed(linkID, hash, rejected))):
                return .send(.delegate(.resourceFailed(linkID: linkID, resourceHash: hash, rejected: rejected)))
            case let .linkPlane(.delegate(.resourceProgress(linkID, hash, role, done, total, segment, segments))):
                return .send(.delegate(.resourceProgress(linkID: linkID, resourceHash: hash, role: role,
                                                         bytesDone: done, bytesTotal: total,
                                                         segment: segment, segments: segments)))
```

Replace

```swift
                 .sendOverLink, .sendResourceOverLink, .identifyOverLink, .sendRequestOverLink,
```

with

```swift
                 .sendOverLink, .sendResourceOverLink, .cancelResource, .identifyOverLink, .sendRequestOverLink,
```

In `linkPlaneRoute`, `embed` — replace

```swift
                case let .sendResourceOverLink(linkID, data):
                    return .sendResourceOverLink(linkID: linkID, data: data)
                case let .identifyOverLink(linkID, identity):
                    return .identifyOverLink(linkID: linkID, identity: identity)
                case let .sendRequestOverLink(linkID, path, data):
                    return .sendRequestOverLink(linkID: linkID, path: path, data: data)
                case let .sendResponseOverLink(linkID, requestID, data):
                    return .sendResponseOverLink(linkID: linkID, requestID: requestID, data: data)
                case let .sendWithReceiptOverLink(linkID, data, token):
                    return .sendWithReceiptOverLink(linkID: linkID, data: data, token: token)
                case let .provePacketOverLink(linkID, packetHash):
                    return .provePacketOverLink(linkID: linkID, packetHash: packetHash)
                case let .closeLink(linkID):
                    return .closeLink(linkID: linkID)
                case let .registerRequestHandler(path, policy):
                    return .registerRequestHandler(path: path, policy: policy)
                case let .deregisterRequestHandler(path):
                    return .deregisterRequestHandler(path: path)
                case .openLink, .acceptLinkRequest, .routeLinkPacket, .interfaceDisconnected, .delegate:
```

with

```swift
                case let .sendResourceOverLink(linkID, data):
                    return .sendResourceOverLink(linkID: linkID, data: data)
                case let .cancelResource(linkID, hash):
                    return .cancelResource(linkID: linkID, hash: hash)
                case let .identifyOverLink(linkID, identity):
                    return .identifyOverLink(linkID: linkID, identity: identity)
                case let .sendRequestOverLink(linkID, path, data):
                    return .sendRequestOverLink(linkID: linkID, path: path, data: data)
                case let .sendResponseOverLink(linkID, requestID, data):
                    return .sendResponseOverLink(linkID: linkID, requestID: requestID, data: data)
                case let .sendWithReceiptOverLink(linkID, data, token):
                    return .sendWithReceiptOverLink(linkID: linkID, data: data, token: token)
                case let .provePacketOverLink(linkID, packetHash):
                    return .provePacketOverLink(linkID: linkID, packetHash: packetHash)
                case let .closeLink(linkID):
                    return .closeLink(linkID: linkID)
                case let .registerRequestHandler(path, policy):
                    return .registerRequestHandler(path: path, policy: policy)
                case let .deregisterRequestHandler(path):
                    return .deregisterRequestHandler(path: path)
                case .openLink, .acceptLinkRequest, .routeLinkPacket, .interfaceDisconnected, .delegate:
```

and in `extract` — replace

```swift
                case let .sendResourceOverLink(linkID, data):
                    return .sendResourceOverLink(linkID: linkID, data: data)
                case let .identifyOverLink(linkID, identity):
                    return .identifyOverLink(linkID: linkID, identity: identity)
                case let .sendRequestOverLink(linkID, path, data):
                    return .sendRequestOverLink(linkID: linkID, path: path, data: data)
                case let .sendResponseOverLink(linkID, requestID, data):
                    return .sendResponseOverLink(linkID: linkID, requestID: requestID, data: data)
                case let .sendWithReceiptOverLink(linkID, data, token):
                    return .sendWithReceiptOverLink(linkID: linkID, data: data, token: token)
                case let .provePacketOverLink(linkID, packetHash):
                    return .provePacketOverLink(linkID: linkID, packetHash: packetHash)
                case let .closeLink(linkID):
                    return .closeLink(linkID: linkID)
                case let .registerRequestHandler(path, policy):
                    return .registerRequestHandler(path: path, policy: policy)
                case let .deregisterRequestHandler(path):
                    return .deregisterRequestHandler(path: path)
                case let .linkPlane(plane):
```

with the same block plus, after the `.sendResourceOverLink` pair,

```swift
                case let .cancelResource(linkID, hash):
                    return .cancelResource(linkID: linkID, hash: hash)
```

(The two blocks are textually identical except for their last line — `case .openLink, ...` in `embed`, `case let .linkPlane(plane):` in `extract` — so use those last lines to anchor each Edit.)

- [ ] **Step 8: Existing tests (mechanical plus two round-trips)**

Write `/tmp/ReTiCaMsgr/t2-ls-tests.sed`:

```
s/\.delegate(\.resourceFailed(hash)) = \$0/.delegate(.resourceFailed(hash, _)) = $0/
s/\.delegate(\.resourceFailed(h)) = \$0/.delegate(.resourceFailed(h, _)) = $0/
```

Run: `sed -i '' -f /tmp/ReTiCaMsgr/t2-ls-tests.sed /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery/Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`
Run: `grep -n "resourceFailed(" /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery/Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`
Expected: lines 167 (`resourceFailed(hash, _)`) and 306 (`resourceFailed(h, _)`).

In `Tests/ReTiCANodeTests/LinkPlaneTests.swift` replace

```swift
    #expect(roundTrips(.sendResourceOverLink(linkID: linkID, data: Data("res".utf8))))
```

with

```swift
    #expect(roundTrips(.sendResourceOverLink(linkID: linkID, data: Data("res".utf8))))
    #expect(roundTrips(.cancelResource(linkID: linkID, hash: Data(repeating: 0x0E, count: 32))))
```

and replace

```swift
    #expect(roundTrips(.delegate(.resourceFailed(linkID: linkID, resourceHash: Data(repeating: 0x08, count: 16)))))
```

with

```swift
    #expect(roundTrips(.delegate(.resourceFailed(linkID: linkID, resourceHash: Data(repeating: 0x08, count: 16),
                                                 rejected: true))))
    #expect(roundTrips(.delegate(.resourceProgress(linkID: linkID, resourceHash: Data(repeating: 0x0F, count: 16),
                                                   role: .sender, bytesDone: 1, bytesTotal: 2,
                                                   segment: 1, segments: 1))))
```

- [ ] **Step 9: Run the new tests**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter linkPlumbing --filter linkPlaneRouteCasePathRoundTripsEveryPlaneAction --filter failedTransferIsRemovedFromState --filter splitSegmentFailureFailsTheWhole`
Expected: all PASS (12 new + 3 edited).

- [ ] **Step 10: Mutation batch (apply all at once)**

1. `LinkSession` progress case: `hash: adv.isSplit ? adv.originalHash : t.resourceHash` → `hash: t.resourceHash` → RED `linkPlumbingSegmentedSendReportsTheOriginalHash` (segment 2's own hash). Segment 1's hash equals the original, which is why the test checks segment 2.
2. Same case: `role: t.role` → `role: .sender` → RED `linkPlumbingInboundProgressIsReceiverRole`.
3. Same case: drop `!adv.isRequest, !adv.isResponse` from the guard → RED `linkPlumbingRequestResourcesReportNoProgress`.
4. Failed case, last line: `rejected: rejected` → `rejected: false` → RED `linkPlumbingRejectedFailureCarriesTheFlag`.
5. `.cancelResource`: delete BOTH `state.cancelledTransferIDs.insert(...)` lines → RED `linkPlumbingCancelResourceSendsTheCancelPacketAndNoFailure`, `linkPlumbingCancelResourceOnASegmentedSendDropsTheRemainingSegments` (a `resourceFailed` is recorded).
6. `.cancelResource` split branch: delete `state.segmentedSend = nil` → RED `linkPlumbingCancelResourceWithNoSegmentInFlightClearsWithoutAPacket`. (It also reddens the segmented test, already red from 5.)
7. `.cancelResource` plain branch: `$0.role == .sender && $0.resourceHash == hash` → `$0.role == .sender` → RED `linkPlumbingCancelResourceForAnUnknownHashDoesNothing`.
8. `LinkPlane` progress delegate case: body → `return .none` → RED `linkPlumbingPlaneReportsSessionProgressUnderTheLinkID`.
9. `TransportEndpoint` `.resourceFailed` delegate: `rejected: rejected` → `rejected: false` → RED `linkPlumbingPlaneCarriesTheRejectedFlag`.
10. `linkPlaneRoute.extract`: delete the `.cancelResource` pair → RED `linkPlaneRouteCasePathRoundTripsEveryPlaneAction` and `linkPlumbingEndpointCancelResourceReachesTheSession` (the verb no longer reaches the plane).

Every new test has a mutation of its own that nothing else in the batch undoes. No mutation traps. Run the Step 9 command: every new test and `linkPlaneRouteCasePathRoundTripsEveryPlaneAction` FAIL. Revert by hand, check `git -C WT diff`, run again: all PASS.

- [ ] **Step 11: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --no-parallel > /tmp/ReTiCaMsgr/tad-t2-full.log`
Expected: all pass with the 1 known issue; count = Task 1 count + 12. If an existing test that runs a real Resource under `exhaustivity = .on` now reports an unhandled `resourceProgress` (none was found when planning — every such window seeds its transfers or runs `.off`), add a `receive` for that delegate at the point it is emitted and list the test in the commit body.

- [ ] **Step 12: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery add Sources/ReTiCATransport/LinkSession.swift Sources/ReTiCANode/LinkPlane.swift Sources/ReTiCANode/TransportEndpoint.swift Tests/ReTiCATransportTests/LinkSessionTransferPlumbingTests.swift Tests/ReTiCANodeTests/TransferPlumbingTests.swift Tests/ReTiCATransportTests/LinkSessionResourceTests.swift Tests/ReTiCANodeTests/LinkPlaneTests.swift`

Write `/tmp/ReTiCaMsgr/msg-tad-task-2.txt`:

```
feat: resource progress, rejection and cancel reach the endpoint

LinkSession reports resourceProgress for plain Resources in both
directions under the hash resourceConcluded uses, carries rejected on
resourceFailed, and gains cancelResource(hash:) which sends the
standard RESOURCE_ICL, drops unsent segments and reports nothing back.
LinkPlane and TransportEndpoint pass all three through by link ID.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery commit -F /tmp/ReTiCaMsgr/msg-tad-task-2.txt`

---
### Task 3: Router — a Resource copy is `transferring`: no retry timer, the transfer decides

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (`linkResourceInFlight` doc :39-41; types :133-147; `Action` :207-208; `Delegate` :229; helpers :259-308; `giveUp` :313-332; `closed` :364-417; `.send` :464-475; `.sendViaPropagation` :496-513; `.linkEstablished` :556-576; new case after :645; `.retryDue` :647-689; `.idleDeadline` :691-698)
- Modify: `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (delete `routerArmsRetryForDrainedResourceMessage` :617-646 and `routerPropagationRetryResendsSameBytes` :1282-1306; edit `idleTeardownReapsLinkResourceInFlight` :1184-1199)
- Create: `Tests/ReTiCANodeTests/LXMFRouterTransferTests.swift`

**Interfaces:**
- Produces:
  - `LXMFRouter.Phase: Equatable, Sendable { case retrying, transferring, queued }`.
  - `LXMFRouter.PendingDelivery.phase: Phase`; `init(resend: ResendInfo, attempts: Int, phase: Phase = .retrying)` (every existing construction keeps compiling).
  - `LXMFRouter.FailureReason` (internal): `.exhausted`, `.rejected`. `fail(_:_:reason:)` defaults to `.exhausted`.
  - `LXMFRouter.Action.resourceFailedOnLink(linkID: Data, rejected: Bool)`.
  - `LXMFRouter.Action.Delegate.deliveryRejected(messageHash: Data)` — the terminal outcome when the LAST copy of a message to fail was rejected.
  - Reducer helpers used by later tasks: `destination(ofLink:_:) -> Data?` (the destination whose ACTIVE link is `linkID`), `startResource(_:_:linkID:) -> Effect<Action>` (sets `.transferring`, records `linkResourceInFlight[linkID]`, emits `sendDirect(asResource: true)` / `sendPropagated`, arms NO timer), `orphanTransfer(_:linkID:) -> Effect<Action>` (a transfer lost with its link goes back to `.retrying` with one retry timer). `clearDirectLink` now returns `Effect<Action>` (the orphan's timer).
- Semantics: `attempts` starts at 1 when a copy is armed and each `.retryDue` tick adds one (as today). A non-rejected `resourceFailedOnLink` closes the link (`.delegate(.closeLink)`) and — if `attempts < maxAttempts` — arms one retry timer; at `attempts == maxAttempts` it fails the copy at once, so a copy gets exactly `maxAttempts` transfers.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFRouterTransferTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

// Transfer-aware delivery, Task 3: a copy sent as a Resource is decided by its transfer. No retry
// timer runs while it is in flight; a failure closes the link and retries once, 10 s later, on a
// fresh link; a rejection is terminal; a link lost mid-transfer sends the copy back to retrying.

private let recipient = Data(repeating: 0xD5, count: 16)
private let recipientLink = Data(repeating: 0xEF, count: 16)
private let freshLink = Data(repeating: 0xF0, count: 16)
private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let large = Data(repeating: 0xAA, count: 432)        // > Link.mdu → Resource
private let small = Data("small-container".utf8)            // <= Link.mdu → link packet
/// An exhaustive no-op: no link is in flight on it, so it changes nothing and emits nothing — and
/// under `.on` it fails if any earlier received action is still unasserted.
private let probe = LXMFRouter.Action.resourceFailedOnLink(linkID: Data(repeating: 0x99, count: 16), rejected: false)

private func bigMessage(_ fill: String = "y") -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: recipient, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data(String(repeating: fill, count: 2000).utf8))
}

private func liveRecipient() -> LXMFRouter.State {
    var state = LXMFRouter.State()
    state.directLinks[recipient] = .active(linkID: recipientLink)
    state.knownPaths.insert(recipient)
    return state
}

@MainActor
private func transferStore(_ state: LXMFRouter.State, _ clock: TestClock<Duration>)
    -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func routerTransferResourceCopyArmsNoRetryTimer() async {
    let big = bigMessage()
    #expect(big.directRepresentation == .resource)
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    store.exhaustivity = .on
    await store.send(.send(message: big, desiredMethod: .direct)) {
        $0.pendingDeliveries[key] = LXMFRouter.PendingDelivery(
            resend: .direct(destinationHash: recipient, data: big.packed, asResource: true),
            attempts: 1, phase: .transferring)
        $0.linkResourceInFlight[recipientLink] = key
    }
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: big.packed, asResource: true)))
    // The old saga resent every 10 s and failed at 50 s. Now nothing may happen.
    await clock.advance(by: .seconds(60))
    await store.send(probe)
    store.exhaustivity = .off   // the recipient link's idle timer runs on by design
}

@Test @MainActor func routerTransferFailureClosesTheLinkAndArmsOneRetry() async {
    let big = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: false)) {
        $0.linkResourceInFlight[recipientLink] = nil
        $0.directLinks[recipient] = nil
        $0.pendingDeliveries[key]?.phase = .retrying
    }
    await store.receive(.delegate(.closeLink(destinationHash: recipient)))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds - 1))
    await store.send(probe)                                    // nothing before the 10 s wait is up
    await clock.advance(by: .seconds(1))
    await store.receive(.retryDue(messageHash: big.hash, leg: .delivery)) {
        $0.pendingDeliveries[key]?.attempts = 2
    }
    store.exhaustivity = .off   // the link is down, so that retry re-armed its timer
}

@Test @MainActor func routerTransferRetryAfterFailureStartsAFreshTransferOnTheNewLink() async {
    let big = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: false))
    await store.receive(.delegate(.closeLink(destinationHash: recipient)))
    await store.send(.linkEstablished(destinationHash: recipient, linkID: freshLink))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.delegate(.sendDirect(linkID: freshLink, data: big.packed, asResource: true)))
    #expect(store.state.pendingDeliveries[key]?.attempts == 2)
    #expect(store.state.pendingDeliveries[key]?.phase == .transferring)
    #expect(store.state.linkResourceInFlight == [freshLink: key])
}

@Test @MainActor func routerTransferFifthFailureFailsTheCopy() async {
    let big = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    await store.send(.send(message: big, desiredMethod: .direct))
    var current = recipientLink
    for attempt in 1..<LXMFDelivery.maxAttempts {
        let next = Data(repeating: 0xF0 + UInt8(attempt), count: 16)
        await store.send(.resourceFailedOnLink(linkID: current, rejected: false))
        await store.send(.linkEstablished(destinationHash: recipient, linkID: next))
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
        await store.receive(.delegate(.sendDirect(linkID: next, data: big.packed, asResource: true)))
        current = next
    }
    #expect(store.state.pendingDeliveries[key]?.attempts == LXMFDelivery.maxAttempts)
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.resourceFailedOnLink(linkID: current, rejected: false)) {
        $0.linkResourceInFlight[current] = nil
        $0.directLinks[recipient] = nil
        $0.pendingDeliveries[key] = nil
    }
    await store.receive(.delegate(.closeLink(destinationHash: recipient)))
    await store.receive(.delegate(.deliveryFailed(messageHash: big.hash)))
    await store.send(probe)
    store.exhaustivity = .off
}

@Test @MainActor func routerTransferRejectionFailsImmediatelyWithNoRetry() async {
    let big = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: true)) {
        $0.linkResourceInFlight[recipientLink] = nil
        $0.pendingDeliveries[key] = nil
    }
    await store.receive(.delegate(.deliveryRejected(messageHash: big.hash)))
    await clock.advance(by: .seconds(60))
    await store.send(probe)
    #expect(store.state.directLinks[recipient] == .active(linkID: recipientLink))   // a rejection keeps the link
    store.exhaustivity = .off
}

@Test @MainActor func routerTransferRejectionWaitsForTheOtherCopy() async {
    let big = bigMessage()
    var state = liveRecipient()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    let store = transferStore(state, TestClock())
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.send(.sendViaPropagation(message: big, propagationPacked: small))   // armed packet copy
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: true)) {
        $0.linkResourceInFlight[recipientLink] = nil
        $0.pendingDeliveries[.delivery(big.hash)] = nil
    }
    await store.send(probe)                                    // no deliveryRejected while the other copy runs
    store.exhaustivity = .off
}

@Test @MainActor func routerTransferRetryDueForATransferringCopyIsANoOp() async {
    let big = bigMessage()
    let store = transferStore(liveRecipient(), TestClock())
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.retryDue(messageHash: big.hash, leg: .delivery))   // no attempt counted, nothing resent
    await store.send(probe)
    store.exhaustivity = .off
}

/// A closing link reaps its transfers without any `resourceFailed`, so the router itself must send
/// the orphaned copy back to retrying — or it would sit in `.transferring` forever.
@Test @MainActor func routerTransferLinkClosedMidTransferRequeuesTheCopy() async {
    let big = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    let clock = TestClock()
    let store = transferStore(liveRecipient(), clock)
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.send(.linkClosed(destinationHash: recipient))
    #expect(store.state.linkResourceInFlight[recipientLink] == nil)
    #expect(store.state.pendingDeliveries[key]?.phase == .retrying)
    await store.receive(.delegate(.requestLink(destinationHash: recipient)))
    await store.send(.linkEstablished(destinationHash: recipient, linkID: freshLink))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.delegate(.sendDirect(linkID: freshLink, data: big.packed, asResource: true)))
    #expect(store.state.pendingDeliveries[key]?.attempts == 2)
}

@Test @MainActor func routerTransferPropagatedFailureRetriesTheSameBytesOnAFreshLink() async {
    let msg = bigMessage("p")
    let key = LXMFRouter.DeliveryKey.propagated(msg.hash)
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    state.knownPaths.insert(pn)
    let clock = TestClock()
    let store = transferStore(state, clock)
    await store.send(.sendViaPropagation(message: msg, propagationPacked: large))
    await store.receive(.delegate(.sendPropagated(linkID: pnLink, propagationPacked: large)))
    await store.send(.resourceFailedOnLink(linkID: pnLink, rejected: false))
    await store.receive(.delegate(.closeLink(destinationHash: pn)))
    await store.send(.linkEstablished(destinationHash: pn, linkID: freshLink))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.delegate(.sendPropagated(linkID: freshLink, propagationPacked: large)))   // same bytes
    #expect(store.state.pendingDeliveries[key]?.attempts == 2)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter routerTransfer`
Expected: FAIL to compile — no `resourceFailedOnLink`, no `phase:`, no `deliveryRejected`.

- [ ] **Step 3: Types, actions, delegates**

In `Sources/ReTiCANode/LXMFRouter.swift`:

Replace

```swift
        /// linkID → the copy whose Resource is currently in flight on that link. Single-in-flight per
        /// link (last write wins); `resourceDeliveredOnLink` resolves exactly that copy.
```

with

```swift
        /// linkID → the copy whose Resource is currently in flight on that link. One per link:
        /// `resourceDeliveredOnLink` / `resourceFailedOnLink` resolve exactly that copy.
```

Replace

```swift
    public struct PendingDelivery: Equatable {
        public var resend: ResendInfo
        public var attempts: Int
        /// Explicit because the synthesised memberwise init on a `public struct` is INTERNAL,
        /// which made this type public in name only — no other module could construct one.
        public init(resend: ResendInfo, attempts: Int) {
            self.resend = resend
            self.attempts = attempts
        }
    }
```

with

```swift
    /// Where a pending copy is in its life (spec §1).
    public enum Phase: Equatable, Sendable {
        /// Armed with a retry timer: opportunistic packets, link packets, and a Resource copy whose
        /// last transfer failed and is waiting for its retry.
        case retrying
        /// A Resource is in flight for this copy. No retry timer: the transfer decides the outcome,
        /// as reference does while a message is SENDING (LXMRouter.py:2788-2796).
        case transferring
        /// Waiting for its link's current Resource transfer to finish (one transfer per link).
        case queued
    }
    public struct PendingDelivery: Equatable {
        public var resend: ResendInfo
        public var attempts: Int
        public var phase: Phase
        /// Explicit because the synthesised memberwise init on a `public struct` is INTERNAL,
        /// which made this type public in name only — no other module could construct one.
        public init(resend: ResendInfo, attempts: Int, phase: Phase = .retrying) {
            self.resend = resend
            self.attempts = attempts
            self.phase = phase
        }
    }
    /// Why a copy failed for good; the terminal delegate says which.
    enum FailureReason: Equatable { case exhausted, rejected }
```

Replace

```swift
        case resourceDeliveredOnLink(linkID: Data)
        case retryDue(messageHash: Data, leg: Leg)
```

with

```swift
        case resourceDeliveredOnLink(linkID: Data)
        /// The Resource in flight on `linkID` failed. `rejected`: the peer refused it (terminal).
        /// Otherwise the link is closed and the copy retried once, `retryWaitSeconds` later.
        case resourceFailedOnLink(linkID: Data, rejected: Bool)
        case retryDue(messageHash: Data, leg: Leg)
```

Replace

```swift
            case deliveryFailed(messageHash: Data)
        }
    }
```

with

```swift
            case deliveryFailed(messageHash: Data)
            /// Every copy is over, none succeeded, and the last to fail was REJECTED by its peer.
            case deliveryRejected(messageHash: Data)
        }
    }
```

- [ ] **Step 4: Helpers**

Replace

```swift
            func arm(_ state: inout State, _ key: DeliveryKey, _ resend: ResendInfo) {
                state.pendingDeliveries[key] = PendingDelivery(resend: resend, attempts: 1)
            }
```

with

```swift
            func arm(_ state: inout State, _ key: DeliveryKey, _ resend: ResendInfo) {
                state.pendingDeliveries[key] = PendingDelivery(resend: resend, attempts: 1)
            }
            /// The destination whose ACTIVE link is `linkID`, if any.
            func destination(ofLink linkID: Data, _ state: State) -> Data? {
                state.directLinks.first { $0.value == .active(linkID: linkID) }?.key
            }
            /// Start this Resource copy's transfer on `linkID`: it becomes `.transferring` and owns the
            /// link's transfer slot. No retry timer — `resourceDeliveredOnLink` / `resourceFailedOnLink`
            /// (or losing the link, see `orphanTransfer`) decide what happens next.
            func startResource(_ state: inout State, _ key: DeliveryKey, linkID: Data) -> Effect<Action> {
                guard var pending = state.pendingDeliveries[key] else { return .none }
                pending.phase = .transferring
                state.pendingDeliveries[key] = pending
                state.linkResourceInFlight[linkID] = key
                switch pending.resend {
                case let .direct(_, data, _):
                    return .send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: true)))
                case let .propagated(_, data):
                    return .send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: data)))
                case .opportunistic:
                    return .none
                }
            }
            /// `linkID` is going away with a Resource in flight. A closing `LinkSession` reaps its
            /// transfers without reporting them, so this IS that transfer's failure: back to
            /// `.retrying` with one retry timer, exactly as `.resourceFailedOnLink` would.
            func orphanTransfer(_ state: inout State, linkID: Data) -> Effect<Action> {
                guard let key = state.linkResourceInFlight.removeValue(forKey: linkID),
                      state.pendingDeliveries[key]?.phase == .transferring else { return .none }
                state.pendingDeliveries[key]?.phase = .retrying
                return retryTimer(key, LXMFDelivery.retryWaitSeconds)
            }
```

Replace

```swift
            func fail(_ state: inout State, _ key: DeliveryKey) -> Effect<Action> {
                state.pendingDeliveries[key] = nil
                let other: Leg = key.leg == .delivery ? .propagated : .delivery
                guard !isOutstanding(state, key.messageHash, other),
                      !state.succeededMessages.contains(key.messageHash)
                else { return .none }
                return .send(.delegate(.deliveryFailed(messageHash: key.messageHash)))
            }
            // Tear down a direct link, reaping its in-flight Resource entry. `linkResourceInFlight`
            // is keyed on the linkID carried by `.active`, so it can only be reaped BEFORE
            // `directLinks[dest]` is cleared — do both here so no teardown path can strand an entry (F7).
            func clearDirectLink(_ state: inout State, _ dest: Data) {
                if case let .active(linkID) = state.directLinks[dest] {
                    state.linkResourceInFlight[linkID] = nil
                }
                state.directLinks[dest] = nil
            }
```

with

```swift
            func fail(_ state: inout State, _ key: DeliveryKey, reason: FailureReason = .exhausted) -> Effect<Action> {
                state.pendingDeliveries[key] = nil
                let other: Leg = key.leg == .delivery ? .propagated : .delivery
                guard !isOutstanding(state, key.messageHash, other),
                      !state.succeededMessages.contains(key.messageHash)
                else { return .none }
                // The terminal outcome carries the reason of the copy that ended the message.
                let outcome: Action.Delegate = reason == .rejected
                    ? .deliveryRejected(messageHash: key.messageHash)
                    : .deliveryFailed(messageHash: key.messageHash)
                return .send(.delegate(outcome))
            }
            // Tear down a direct link, reaping its in-flight Resource entry. `linkResourceInFlight`
            // is keyed on the linkID carried by `.active`, so it can only be reaped BEFORE
            // `directLinks[dest]` is cleared — do both here so no teardown path can strand an entry (F7).
            // The copy that owned the entry goes back to retrying (`orphanTransfer`); the returned
            // effect is its retry timer.
            func clearDirectLink(_ state: inout State, _ dest: Data) -> Effect<Action> {
                var orphaned: Effect<Action> = .none
                if case let .active(linkID) = state.directLinks[dest] {
                    orphaned = orphanTransfer(&state, linkID: linkID)
                }
                state.directLinks[dest] = nil
                return orphaned
            }
```

- [ ] **Step 5: The three `clearDirectLink` callers**

`giveUp` — replace

```swift
                state.knownPaths.remove(dest)
                clearDirectLink(&state, dest)
                let queued = state.outboundQueue[dest] ?? []
```

with

```swift
                state.knownPaths.remove(dest)
                let orphaned = clearDirectLink(&state, dest)
                let queued = state.outboundQueue[dest] ?? []
```

and replace

```swift
                var effects: [Effect<Action>] = [.cancel(id: CancelID.pathRequest(dest))]
```

with

```swift
                var effects: [Effect<Action>] = [orphaned, .cancel(id: CancelID.pathRequest(dest))]
```

`closed` — replace

```swift
            func closed(_ state: inout State, _ dest: Data) -> Effect<Action> {
                clearDirectLink(&state, dest)
```

with

```swift
            func closed(_ state: inout State, _ dest: Data) -> Effect<Action> {
                let orphaned = clearDirectLink(&state, dest)
```

replace

```swift
                if hasPending || hasQueued || hasPendingSync {
                    return establish(&state, dest)
                }
```

with

```swift
                if hasPending || hasQueued || hasPendingSync {
                    return .merge(orphaned, establish(&state, dest))
                }
```

and replace

```swift
                state.establishAttempts[dest] = nil
                return .none
            }
            switch action {
```

with

```swift
                state.establishAttempts[dest] = nil
                return orphaned
            }
            switch action {
```

`.idleDeadline` — replace

```swift
                guard case let .active(current) = state.directLinks[dest], current == linkID
                else { return .none }
                clearDirectLink(&state, dest)
                return .send(.delegate(.closeLink(destinationHash: dest)))
```

with

```swift
                guard case let .active(current) = state.directLinks[dest], current == linkID
                else { return .none }
                let orphaned = clearDirectLink(&state, dest)
                return .merge(orphaned, .send(.delegate(.closeLink(destinationHash: dest))))
```

- [ ] **Step 6: Every Resource start goes through `startResource`**

`.send` — replace

```swift
                    if case let .active(linkID) = state.directLinks[dest] {
                        let key = DeliveryKey.delivery(message.hash)
                        let asResource = message.directRepresentation == .resource
                        arm(&state, key, .direct(destinationHash: dest, data: message.packed, asResource: asResource))
                        if asResource { state.linkResourceInFlight[linkID] = key }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                                  asResource: asResource))),
                                      retryTimer(key, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(dest, linkID))
                    }
```

with

```swift
                    if case let .active(linkID) = state.directLinks[dest] {
                        let key = DeliveryKey.delivery(message.hash)
                        let asResource = message.directRepresentation == .resource
                        arm(&state, key, .direct(destinationHash: dest, data: message.packed, asResource: asResource))
                        if asResource {
                            return .merge(startResource(&state, key, linkID: linkID), idleTimer(dest, linkID))
                        }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                                  asResource: false))),
                                      retryTimer(key, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(dest, linkID))
                    }
```

`.sendViaPropagation` — replace

```swift
                    } else {
                        // Large container: send as Resource; receipt via resourceDeliveredOnLink.
                        state.linkResourceInFlight[linkID] = key
                        return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: propagationPacked))),
                                      retryTimer(key, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(pn, linkID))
                    }
```

with

```swift
                    } else {
                        // Large container: send as Resource; its transfer decides the outcome.
                        return .merge(startResource(&state, key, linkID: linkID), idleTimer(pn, linkID))
                    }
```

`.linkEstablished` — replace

```swift
                for m in queued {
                    let key = DeliveryKey.delivery(m.hash)
                    let asResource = m.directRepresentation == .resource
                    arm(&state, key, .direct(destinationHash: dest, data: m.packed, asResource: asResource))
                    if asResource { state.linkResourceInFlight[linkID] = key }
                    effects.append(.send(.delegate(.sendDirect(linkID: linkID, data: m.packed, asResource: asResource))))
                    effects.append(retryTimer(key, LXMFDelivery.retryWaitSeconds))
                }
                for item in propQueued {
                    let key = DeliveryKey.propagated(item.messageHash)
                    arm(&state, key, .propagated(destinationHash: dest, data: item.propagationPacked))
                    if item.propagationPacked.count <= Link.mdu {
                        effects.append(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                              propagationPacked: item.propagationPacked,
                                                                              messageHash: item.messageHash))))
                    } else {
                        state.linkResourceInFlight[linkID] = key
                        effects.append(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: item.propagationPacked))))
                    }
                    effects.append(retryTimer(key, LXMFDelivery.retryWaitSeconds))
                }
```

with

```swift
                for m in queued {
                    let key = DeliveryKey.delivery(m.hash)
                    let asResource = m.directRepresentation == .resource
                    arm(&state, key, .direct(destinationHash: dest, data: m.packed, asResource: asResource))
                    if asResource {
                        effects.append(startResource(&state, key, linkID: linkID))
                    } else {
                        effects.append(.send(.delegate(.sendDirect(linkID: linkID, data: m.packed, asResource: false))))
                        effects.append(retryTimer(key, LXMFDelivery.retryWaitSeconds))
                    }
                }
                for item in propQueued {
                    let key = DeliveryKey.propagated(item.messageHash)
                    arm(&state, key, .propagated(destinationHash: dest, data: item.propagationPacked))
                    if item.propagationPacked.count <= Link.mdu {
                        effects.append(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                              propagationPacked: item.propagationPacked,
                                                                              messageHash: item.messageHash))))
                        effects.append(retryTimer(key, LXMFDelivery.retryWaitSeconds))
                    } else {
                        effects.append(startResource(&state, key, linkID: linkID))
                    }
                }
```

- [ ] **Step 7: `.resourceFailedOnLink` and `.retryDue`**

Replace

```swift
            case let .resourceDeliveredOnLink(linkID):
                guard let key = state.linkResourceInFlight[linkID] else { return .none }
                state.linkResourceInFlight[linkID] = nil
                return .send(.delivered(messageHash: key.messageHash, leg: key.leg))
```

with

```swift
            case let .resourceDeliveredOnLink(linkID):
                guard let key = state.linkResourceInFlight[linkID] else { return .none }
                state.linkResourceInFlight[linkID] = nil
                return .send(.delivered(messageHash: key.messageHash, leg: key.leg))

            case let .resourceFailedOnLink(linkID, rejected):
                // Reference `LXMessage.__resource_concluded` (LXMessage.py:597-606): REJECTED is
                // terminal; any other failure tears the link down and returns the message to
                // OUTBOUND, where the next pass counts an attempt after DELIVERY_RETRY_WAIT.
                guard let key = state.linkResourceInFlight.removeValue(forKey: linkID),
                      var pending = state.pendingDeliveries[key] else { return .none }
                if rejected {
                    return fail(&state, key, reason: .rejected)
                }
                var close: Effect<Action> = .none
                if let dest = destination(ofLink: linkID, state) {
                    close = .merge(clearDirectLink(&state, dest), .send(.delegate(.closeLink(destinationHash: dest))))
                }
                // `attempts` counts transfers started: the `maxAttempts`-th failure is the last.
                guard pending.attempts < LXMFDelivery.maxAttempts else {
                    return .merge(close, fail(&state, key))
                }
                pending.phase = .retrying
                state.pendingDeliveries[key] = pending
                return .merge(close, retryTimer(key, LXMFDelivery.retryWaitSeconds))
```

In `.retryDue`, replace

```swift
                guard var pending = state.pendingDeliveries[key] else { return .none }
                pending.attempts += 1
```

with

```swift
                guard var pending = state.pendingDeliveries[key] else { return .none }
                // Only a `.retrying` copy has a timer. One whose Resource is in flight (or queued
                // behind one) is decided by its transfer, so a stray retry must not count or resend.
                guard pending.phase == .retrying else { return .none }
                pending.attempts += 1
```

replace

```swift
                case let .direct(destinationHash, data, asResource):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        if asResource { state.linkResourceInFlight[linkID] = key }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                                      retryTimer(key, LXMFDelivery.retryWaitSeconds))
                    }
```

with

```swift
                case let .direct(destinationHash, data, asResource):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        if asResource { return startResource(&state, key, linkID: linkID) }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: false))),
                                      retryTimer(key, LXMFDelivery.retryWaitSeconds))
                    }
```

and replace

```swift
                        } else {
                            state.linkResourceInFlight[linkID] = key
                            return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: data))),
                                          retryTimer(key, LXMFDelivery.retryWaitSeconds))
                        }
```

with

```swift
                        } else {
                            return startResource(&state, key, linkID: linkID)   // Resource: the transfer decides
                        }
```

- [ ] **Step 8: Existing router tests whose premise this task inverts**

In `Tests/ReTiCANodeTests/LXMFRouterTests.swift`:

Delete `routerArmsRetryForDrainedResourceMessage` entirely (from `@Test @MainActor func routerArmsRetryForDrainedResourceMessage() async {` through its closing `}` before `// MARK: - LXMF-4c-3a link-CLOSED recovery`). It asserted that a Resource copy is resent every 10 s — the behaviour this task removes; `routerTransferResourceCopyArmsNoRetryTimer` asserts the opposite.

Delete `routerPropagationRetryResendsSameBytes` entirely (from `@Test @MainActor func routerPropagationRetryResendsSameBytes() async {` through its closing `}` before `// MARK: - Task-2: propagation small-packet + genuine propagationAccepted`). Its claim now holds only after a failed transfer on a fresh link, which `routerTransferPropagatedFailureRetriesTheSameBytesOnAFreshLink` asserts.

In `idleTeardownReapsLinkResourceInFlight` replace

```swift
    // Resolve the delivery so its retry timer is cancelled; the idle timer and the in-flight entry
    // both remain (the Resource is still notionally in flight for eviction purposes).
    await store.send(.delivered(messageHash: bigMsg.hash, leg: .delivery))
    await store.receive { if case .delegate(.deliveryConfirmed) = $0 { return true }; return false }
    #expect(store.state.linkResourceInFlight[linkID] == LXMFRouter.DeliveryKey.delivery(bigMsg.hash), "still in-flight before idle")
    #expect(store.state.directLinks[bigMsg.destinationHash] == .active(linkID: linkID))
```

with

```swift
    // A Resource copy arms no retry timer, so nothing needs resolving first: the in-flight entry and
    // the idle timer are all that is running.
    #expect(store.state.pendingDeliveries[.delivery(bigMsg.hash)]?.phase == .transferring)
    #expect(store.state.directLinks[bigMsg.destinationHash] == .active(linkID: linkID))
```

and replace

```swift
    #expect(store.state.linkResourceInFlight[linkID] == nil,
            "idle teardown must reap the in-flight Resource entry — F7 leak")
    #expect(store.state.directLinks[bigMsg.destinationHash] == nil)
}
```

with

```swift
    #expect(store.state.linkResourceInFlight[linkID] == nil,
            "idle teardown must reap the in-flight Resource entry — F7 leak")
    #expect(store.state.directLinks[bigMsg.destinationHash] == nil)
    #expect(store.state.pendingDeliveries[.delivery(bigMsg.hash)]?.phase == .retrying,
            "the transfer died with the link, so the copy goes back to retrying")
}
```

- [ ] **Step 9: Run the new and edited tests**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter routerTransfer --filter idleTeardownReapsLinkResourceInFlight --filter routerConfirms --filter routerLeg --filter copyOutcome`
Expected: all PASS.

- [ ] **Step 10: Mutation batch (apply all at once, `LXMFRouter.swift`)**

1. `startResource`: `return .send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: true)))` → `return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: true))), retryTimer(key, LXMFDelivery.retryWaitSeconds))` → RED `routerTransferResourceCopyArmsNoRetryTimer` (a `.retryDue` arrives at 10 s; it no-ops on the phase guard but the received action fails the exhaustive probe).
2. `.resourceFailedOnLink`: `close = .merge(clearDirectLink(&state, dest), .send(.delegate(.closeLink(destinationHash: dest))))` → `close = .none` → RED `routerTransferFailureClosesTheLinkAndArmsOneRetry` (no `closeLink`, `directLinks` unchanged). It also reddens `routerTransferFifthFailureFailsTheCopy` at its exhaustive tail and `routerTransferPropagatedFailureRetriesTheSameBytesOnAFreshLink`.
3. `.resourceFailedOnLink`: delete the `if rejected { ... }` block → RED `routerTransferRejectionFailsImmediatelyWithNoRetry`, `routerTransferRejectionWaitsForTheOtherCopy` (a `closeLink` and a retry appear instead).
4. `guard pending.attempts < LXMFDelivery.maxAttempts` → `guard pending.attempts <= LXMFDelivery.maxAttempts` → RED `routerTransferFifthFailureFailsTheCopy` (a sixth retry instead of the failure).
5. `.retryDue`: delete `guard pending.phase == .retrying else { return .none }` → RED `routerTransferRetryDueForATransferringCopyIsANoOp` (attempt counted, `sendDirect` emitted).
6. `orphanTransfer`: replace its body with `state.linkResourceInFlight[linkID] = nil` then `return .none` → RED `routerTransferLinkClosedMidTransferRequeuesTheCopy` and `idleTeardownReapsLinkResourceInFlight` (phase stays `.transferring`, no retry).
7. `.retryDue` `.direct` branch: `if asResource { return startResource(&state, key, linkID: linkID) }` → `if asResource { return retryTimer(key, LXMFDelivery.retryWaitSeconds) }` → RED `routerTransferRetryAfterFailureStartsAFreshTransferOnTheNewLink` (nothing sent on the fresh link).

`routerTransferPropagatedFailureRetriesTheSameBytesOnAFreshLink` is reddened by mutation 2 (and by nothing it depends on being undone). Mutation 2 also touches the fifth-failure test, but that test has mutation 4 of its own; mutations 3 and 7 touch disjoint branches. None traps. Run the Step 9 command: every `routerTransfer*` test and `idleTeardownReapsLinkResourceInFlight` FAIL. Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 11: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --no-parallel > /tmp/ReTiCaMsgr/tad-t3-full.log`
Expected: all pass with the 1 known issue; count = Task 2 count + 9 − 2.

- [ ] **Step 12: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterTransferTests.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift`

Write `/tmp/ReTiCaMsgr/msg-tad-task-3.txt`:

```
feat: a Resource copy is decided by its transfer, not a retry timer

Pending copies gain a phase. A copy sent as a Resource is transferring
and arms no retry timer. resourceFailedOnLink closes the link and
retries once after retryWaitSeconds on whatever link comes back, a
rejection fails the copy at once with deliveryRejected, and a link lost
mid-transfer sends its copy back to retrying. Two router tests that
pinned the old resend-every-10-s behaviour are replaced.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery commit -F /tmp/ReTiCaMsgr/msg-tad-task-3.txt`

---
### Task 4: Router — one Resource transfer per link; further large sends queue

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (State: new `resourceQueue`; helpers after `startResource`; `giveUp`; the six `startResource` call sites from Task 3; `.linkEstablished`; `.resourceDeliveredOnLink`; `.resourceFailedOnLink`)
- Create: `Tests/ReTiCANodeTests/LXMFRouterLinkQueueTests.swift`

**Interfaces:**
- Consumes (Task 3): `Phase`, `startResource(_:_:linkID:)`, `destination(ofLink:_:)`, `fail(_:_:reason:)`, `.resourceFailedOnLink`.
- Produces:
  - `LXMFRouter.State.resourceQueue: [Data: [DeliveryKey]]` — destination (recipient or PN) → Resource copies waiting, oldest first. Each has a `pendingDeliveries` entry in phase `.queued`.
  - `startOrQueueResource(_:_:dest:linkID:) -> Effect<Action>` — starts the copy if `linkResourceInFlight[linkID]` is free, else marks it `.queued` and appends it to `resourceQueue[dest]`.
  - `startNextQueued(_:dest:) -> Effect<Action>` — if `dest`'s link is active and its slot free, starts the oldest copy still `.queued`.
- Semantics: a conclusion, a rejection, or a (re-)established link frees the slot and starts the next queued copy; a non-rejected failure closes the link, so the queue resumes on the next `linkEstablished`; `giveUp` fails queued copies; small (packet-sized) sends never queue.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFRouterLinkQueueTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

// Transfer-aware delivery, Task 4: one Resource transfer per link. `LinkSession` holds a single
// split-send slot and the router a single in-flight entry per link, so a second large send used to
// overwrite both. Now it waits, and small sends never wait behind a transfer.

private let recipient = Data(repeating: 0xD5, count: 16)
private let recipientLink = Data(repeating: 0xEF, count: 16)
private let freshLink = Data(repeating: 0xF0, count: 16)
private let probe = LXMFRouter.Action.resourceFailedOnLink(linkID: Data(repeating: 0x99, count: 16), rejected: false)

private func bigMessage(_ fill: String) -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: recipient, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data(String(repeating: fill, count: 2000).utf8))
}

private func liveRecipient() -> LXMFRouter.State {
    var state = LXMFRouter.State()
    state.directLinks[recipient] = .active(linkID: recipientLink)
    state.knownPaths.insert(recipient)
    return state
}

@MainActor
private func queueStore(_ state: LXMFRouter.State, _ clock: TestClock<Duration> = TestClock())
    -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

private func resource(_ m: LXMessage, _ phase: LXMFRouter.Phase) -> LXMFRouter.PendingDelivery {
    LXMFRouter.PendingDelivery(resend: .direct(destinationHash: recipient, data: m.packed, asResource: true),
                               attempts: 1, phase: phase)
}

@Test @MainActor func linkQueueSecondLargeSendWaitsForTheFirst() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let k1 = LXMFRouter.DeliveryKey.delivery(first.hash), k2 = LXMFRouter.DeliveryKey.delivery(second.hash)
    let store = queueStore(liveRecipient())
    store.exhaustivity = .on
    await store.send(.send(message: first, desiredMethod: .direct)) {
        $0.pendingDeliveries[k1] = resource(first, .transferring)
        $0.linkResourceInFlight[recipientLink] = k1
    }
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: first.packed, asResource: true)))
    await store.send(.send(message: second, desiredMethod: .direct)) {      // nothing sent for it yet
        $0.pendingDeliveries[k2] = resource(second, .queued)
        $0.resourceQueue[recipient] = [k2]
    }
    await store.send(.resourceDeliveredOnLink(linkID: recipientLink)) {
        $0.linkResourceInFlight[recipientLink] = k2
        $0.pendingDeliveries[k2]?.phase = .transferring
        $0.resourceQueue[recipient] = nil
    }
    await store.receive(.delivered(messageHash: first.hash, leg: .delivery)) {
        $0.pendingDeliveries[k1] = nil
        $0.succeededMessages.insert(first.hash)
    }
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: second.packed, asResource: true)))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: first.hash)))
    store.exhaustivity = .off   // idle timer
}

@Test @MainActor func linkQueueSmallSendIsNotQueuedBehindATransfer() async {
    let first = bigMessage("a")
    let note = LXMessage.create(source: Identity(), destinationHash: recipient, timestamp: 1700000000.5,
                                title: Data("t".utf8), content: Data("small".utf8))
    #expect(note.directRepresentation == .packet)
    let store = queueStore(liveRecipient())
    await store.send(.send(message: first, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.send(message: note, desiredMethod: .direct)) {
        $0.pendingDeliveries[.delivery(note.hash)] = LXMFRouter.PendingDelivery(
            resend: .direct(destinationHash: recipient, data: note.packed, asResource: false), attempts: 1)
    }
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: note.packed, asResource: false)))
    store.exhaustivity = .off   // retry + idle timers
}

@Test @MainActor func linkQueueFailedTransferWaitsForTheLinkThenResumesTheQueue() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let k1 = LXMFRouter.DeliveryKey.delivery(first.hash), k2 = LXMFRouter.DeliveryKey.delivery(second.hash)
    let clock = TestClock()
    let store = queueStore(liveRecipient(), clock)
    await store.send(.send(message: first, desiredMethod: .direct))
    await store.send(.send(message: second, desiredMethod: .direct))
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: false))
    #expect(store.state.pendingDeliveries[k2]?.phase == .queued)            // its link is gone: it waits
    await store.send(.linkEstablished(destinationHash: recipient, linkID: freshLink))
    await store.receive(.delegate(.sendDirect(linkID: freshLink, data: second.packed, asResource: true)))
    #expect(store.state.linkResourceInFlight[freshLink] == k2)
    // The failed copy's retry finds the link busy and queues behind it.
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.retryDue(messageHash: first.hash, leg: .delivery))
    #expect(store.state.pendingDeliveries[k1]?.phase == .queued)
    #expect(store.state.resourceQueue[recipient] == [k1])
}

@Test @MainActor func linkQueueRejectionStartsTheNextCopy() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let store = queueStore(liveRecipient())
    await store.send(.send(message: first, desiredMethod: .direct))
    await store.send(.send(message: second, desiredMethod: .direct))
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: true))
    await store.receive(.delegate(.deliveryRejected(messageHash: first.hash)))
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: second.packed, asResource: true)))
}

@Test @MainActor func linkQueueTwoQueuedSendsDrainInOrderOnLinkEstablished() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let k1 = LXMFRouter.DeliveryKey.delivery(first.hash), k2 = LXMFRouter.DeliveryKey.delivery(second.hash)
    var state = LXMFRouter.State()
    state.knownPaths.insert(recipient)
    let store = queueStore(state)
    await store.send(.send(message: first, desiredMethod: .direct))
    await store.send(.send(message: second, desiredMethod: .direct))
    await store.receive(.delegate(.requestLink(destinationHash: recipient)))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.linkEstablished(destinationHash: recipient, linkID: recipientLink)) {
        $0.directLinks[recipient] = .active(linkID: recipientLink)
        $0.establishAttempts[recipient] = nil
        $0.outboundQueue[recipient] = nil
        $0.pendingDeliveries[k1] = resource(first, .transferring)
        $0.pendingDeliveries[k2] = resource(second, .queued)
        $0.linkResourceInFlight[recipientLink] = k1
        $0.resourceQueue[recipient] = [k2]
    }
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: first.packed, asResource: true)))
    await store.send(probe)
    store.exhaustivity = .off
}

/// A queued copy has no timer, so if its destination is given up on it must be failed there.
@Test @MainActor func linkQueueGiveUpFailsQueuedCopies() async {
    let big = bigMessage("a")
    let key = LXMFRouter.DeliveryKey.delivery(big.hash)
    var state = LXMFRouter.State()
    state.directLinks[recipient] = .awaitingPath
    state.establishAttempts[recipient] = LXMFDelivery.maxAttempts
    state.pendingDeliveries[key] = resource(big, .queued)
    state.resourceQueue[recipient] = [key]
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.pathRequestDeadline(destinationHash: recipient)) {
        $0.directLinks[recipient] = nil
        $0.establishAttempts[recipient] = nil
        $0.resourceQueue[recipient] = nil
        $0.pendingDeliveries[key] = nil
    }
    await store.receive(.delegate(.deliveryFailed(messageHash: big.hash)))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter linkQueue`
Expected: FAIL to compile — `LXMFRouter.State` has no member `resourceQueue`.

- [ ] **Step 3: State and helpers**

In `Sources/ReTiCANode/LXMFRouter.swift`, replace

```swift
        public var linkResourceInFlight: [Data: DeliveryKey] = [:]
```

with

```swift
        public var linkResourceInFlight: [Data: DeliveryKey] = [:]
        /// Destination (recipient or propagation node) → Resource copies waiting for its link's
        /// transfer slot, oldest first; each is `.queued` in `pendingDeliveries`. One transfer per
        /// link: `LinkSession` keeps a single split-send slot, and reference's several concurrent
        /// Resources per link is out of scope (spec §4).
        public var resourceQueue: [Data: [DeliveryKey]] = [:]
```

Insert directly after the `startResource` helper (before the `/// \`linkID\` is going away with a Resource in flight.` comment of `orphanTransfer`):

```swift
            /// Start this Resource copy now if `linkID` has no transfer in flight, else queue it.
            func startOrQueueResource(_ state: inout State, _ key: DeliveryKey, dest: Data, linkID: Data) -> Effect<Action> {
                guard state.linkResourceInFlight[linkID] == nil else {
                    state.pendingDeliveries[key]?.phase = .queued
                    state.resourceQueue[dest, default: []].append(key)
                    return .none
                }
                return startResource(&state, key, linkID: linkID)
            }
            /// `dest`'s transfer slot may be free: start its oldest copy still waiting, if the link is up.
            func startNextQueued(_ state: inout State, dest: Data) -> Effect<Action> {
                guard case let .active(linkID) = state.directLinks[dest],
                      state.linkResourceInFlight[linkID] == nil else { return .none }
                while var queue = state.resourceQueue[dest], !queue.isEmpty {
                    let key = queue.removeFirst()
                    state.resourceQueue[dest] = queue.isEmpty ? nil : queue
                    if state.pendingDeliveries[key]?.phase == .queued {
                        return startResource(&state, key, linkID: linkID)
                    }
                }
                return .none
            }
```

- [ ] **Step 4: Route every Resource start through the queue**

Replace

```swift
                            return .merge(startResource(&state, key, linkID: linkID), idleTimer(dest, linkID))
```

with

```swift
                            return .merge(startOrQueueResource(&state, key, dest: dest, linkID: linkID),
                                          idleTimer(dest, linkID))
```

Replace

```swift
                        return .merge(startResource(&state, key, linkID: linkID), idleTimer(pn, linkID))
```

with

```swift
                        return .merge(startOrQueueResource(&state, key, dest: pn, linkID: linkID),
                                      idleTimer(pn, linkID))
```

Replace ALL (two occurrences, both in `.linkEstablished`)

```swift
effects.append(startResource(&state, key, linkID: linkID))
```

with

```swift
effects.append(startOrQueueResource(&state, key, dest: dest, linkID: linkID))
```

Replace

```swift
                        if asResource { return startResource(&state, key, linkID: linkID) }
```

with

```swift
                        if asResource { return startOrQueueResource(&state, key, dest: destinationHash, linkID: linkID) }
```

Replace

```swift
                            return startResource(&state, key, linkID: linkID)   // Resource: the transfer decides
```

with

```swift
                            return startOrQueueResource(&state, key, dest: destinationHash, linkID: linkID)
```

Then run `grep -n "startResource(&state" /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery/Sources/ReTiCANode/LXMFRouter.swift` — expected: exactly two hits, both inside the helpers `startOrQueueResource` and `startNextQueued`.

- [ ] **Step 5: Free the slot → start the next copy**

In `.linkEstablished`, replace

```swift
                var effects: [Effect<Action>] = []
                for m in queued {
```

with

```swift
                // Copies queued on a previous link go first; newly drained ones queue behind them.
                var effects: [Effect<Action>] = [startNextQueued(&state, dest: dest)]
                for m in queued {
```

Replace

```swift
            case let .resourceDeliveredOnLink(linkID):
                guard let key = state.linkResourceInFlight[linkID] else { return .none }
                state.linkResourceInFlight[linkID] = nil
                return .send(.delivered(messageHash: key.messageHash, leg: key.leg))
```

with

```swift
            case let .resourceDeliveredOnLink(linkID):
                guard let key = state.linkResourceInFlight[linkID] else { return .none }
                state.linkResourceInFlight[linkID] = nil
                var next: Effect<Action> = .none
                if let dest = destination(ofLink: linkID, state) { next = startNextQueued(&state, dest: dest) }
                return .merge(.send(.delivered(messageHash: key.messageHash, leg: key.leg)), next)
```

Replace

```swift
                if rejected {
                    return fail(&state, key, reason: .rejected)
                }
```

with

```swift
                if rejected {
                    // The link stays up (reference does not tear it down on REJECTED): next copy.
                    let failed = fail(&state, key, reason: .rejected)
                    var next: Effect<Action> = .none
                    if let dest = destination(ofLink: linkID, state) { next = startNextQueued(&state, dest: dest) }
                    return .merge(failed, next)
                }
```

In `giveUp`, replace

```swift
                for message in queued { effects.append(fail(&state, .delivery(message.hash))) }
                for item in propQueued { effects.append(fail(&state, .propagated(item.messageHash))) }
                return .merge(effects)
```

with

```swift
                for message in queued { effects.append(fail(&state, .delivery(message.hash))) }
                for item in propQueued { effects.append(fail(&state, .propagated(item.messageHash))) }
                // Resource copies waiting for this destination's link have no timer of their own.
                for key in state.resourceQueue.removeValue(forKey: dest) ?? [] where state.pendingDeliveries[key] != nil {
                    effects.append(fail(&state, key))
                }
                return .merge(effects)
```

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter linkQueue --filter routerTransfer --filter routerLeg`
Expected: all PASS.

- [ ] **Step 7: Mutation batch (apply all at once, `LXMFRouter.swift`)**

1. `startOrQueueResource`: replace its body with `return startResource(&state, key, linkID: linkID)` → RED `linkQueueSecondLargeSendWaitsForTheFirst` (second `sendDirect` at once), `linkQueueTwoQueuedSendsDrainInOrderOnLinkEstablished` (two `sendDirect`s).
2. `.send` direct branch: `if asResource {` → `if asResource || state.linkResourceInFlight[linkID] != nil {` → RED `linkQueueSmallSendIsNotQueuedBehindATransfer` (the small copy is started as a Resource-queued copy instead of a link packet).
3. `.resourceDeliveredOnLink`: `return .merge(.send(.delivered(...)), next)` → `return .send(.delivered(messageHash: key.messageHash, leg: key.leg))` → RED `linkQueueSecondLargeSendWaitsForTheFirst` (its state closure expects the next copy started). Mutation 1 also reddens that test; 3 has no other test, which is acceptable — the test's exhaustive state assertion catches 3 even with 1 reverted, and 1's other test (`linkQueueTwoQueued...`) is unaffected by 3.
4. `.linkEstablished`: `[startNextQueued(&state, dest: dest)]` → `[]` → RED `linkQueueFailedTransferWaitsForTheLinkThenResumesTheQueue`.
5. Rejected branch: `return .merge(failed, next)` → `return failed` → RED `linkQueueRejectionStartsTheNextCopy`.
6. `giveUp`: delete the `for key in state.resourceQueue.removeValue(...)` loop → RED `linkQueueGiveUpFailsQueuedCopies`.

No mutation traps. Run the Step 6 filter: every `linkQueue*` test FAILS. Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 8: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --no-parallel > /tmp/ReTiCaMsgr/tad-t4-full.log`
Expected: all pass with the 1 known issue; count = Task 3 count + 6.

- [ ] **Step 9: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterLinkQueueTests.swift`

Write `/tmp/ReTiCaMsgr/msg-tad-task-4.txt`:

```
feat: one Resource transfer per link, further large sends queue

A large copy whose link already carries a transfer waits in
resourceQueue instead of overwriting the link's single transfer slot.
A conclusion, a rejection or a newly established link starts the next
waiting copy, give-up fails the ones still waiting, and small sends
still go out as link packets at once.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery commit -F /tmp/ReTiCaMsgr/msg-tad-task-4.txt`

---
### Task 5: Router — `cancelOutbound`

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (State: `cancelledMessages`; `Action`; `Delegate`; `.send` and `.sendViaPropagation` guards; new case; `State.hasOutboundState(for:)` extension at file end)
- Create: `Tests/ReTiCANodeTests/LXMFRouterCancelTests.swift`

**Interfaces:**
- Consumes (Tasks 3-4): `Phase`, `resourceQueue`, `destination(ofLink:_:)`, `startNextQueued(_:dest:)`, `CancelID.retry(_:)`.
- Produces:
  - `LXMFRouter.Action.cancelOutbound(messageHash: Data)`.
  - `LXMFRouter.Action.Delegate.cancelResource(linkID: Data)` — cancel OUR Resource in flight on `linkID` (the node resolves which resource hash that is).
  - `LXMFRouter.Action.Delegate.deliveryCancelled(messageHash: Data)` — emitted exactly once, and only if the router held work for the message.
  - `LXMFRouter.State.cancelledMessages: RingSet` (internal, capacity `succeededMessageMemory`) — `.send` and `.sendViaPropagation` for a hash in it do nothing.
  - `public func LXMFRouter.State.hasOutboundState(for messageHash: Data) -> Bool` — any pending copy (any phase) or a message queued behind link establishment. (Task 7 adds the propagated-copy marker.)

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFRouterCancelTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

// Transfer-aware delivery, Task 5: the app cancels an outbound message in any state. Reference
// `LXMRouter.cancel_outbound` (LXMRouter.py:1719-1744) marks it CANCELLED and cancels its Resource;
// nothing afterwards may report it delivered or failed.

private let recipient = Data(repeating: 0xD5, count: 16)
private let recipientLink = Data(repeating: 0xEF, count: 16)
private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let small = Data("small-container".utf8)
private let probe = LXMFRouter.Action.resourceFailedOnLink(linkID: Data(repeating: 0x99, count: 16), rejected: false)

private func bigMessage(_ fill: String) -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: recipient, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data(String(repeating: fill, count: 2000).utf8))
}

private func note() -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: recipient, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data("cancel me".utf8))
}

private func liveRecipient() -> LXMFRouter.State {
    var state = LXMFRouter.State()
    state.directLinks[recipient] = .active(linkID: recipientLink)
    state.knownPaths.insert(recipient)
    return state
}

@MainActor
private func cancelStore(_ state: LXMFRouter.State, _ clock: TestClock<Duration> = TestClock())
    -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func routerCancelTransferringCopyCancelsItsResource() async {
    let big = bigMessage("a")
    let store = cancelStore(liveRecipient())
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: big.hash)) {
        $0.pendingDeliveries[.delivery(big.hash)] = nil
        $0.linkResourceInFlight[recipientLink] = nil
        $0.cancelledMessages.insert(big.hash)
    }
    await store.receive(.delegate(.cancelResource(linkID: recipientLink)))
    await store.receive(.delegate(.deliveryCancelled(messageHash: big.hash)))
    // A late outcome of the cancelled transfer finds nothing to resolve: no state, no delegate.
    await store.send(.resourceFailedOnLink(linkID: recipientLink, rejected: false))
    await store.send(.resourceDeliveredOnLink(linkID: recipientLink))
    #expect(store.state.directLinks[recipient] == .active(linkID: recipientLink))
    store.exhaustivity = .off
}

@Test @MainActor func routerCancelQueuedCopyIsRemovedAndNothingIsSent() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let store = cancelStore(liveRecipient())
    await store.send(.send(message: first, desiredMethod: .direct))
    await store.send(.send(message: second, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: second.hash)) {
        $0.pendingDeliveries[.delivery(second.hash)] = nil
        $0.resourceQueue[recipient] = nil
        $0.cancelledMessages.insert(second.hash)
    }
    await store.receive(.delegate(.deliveryCancelled(messageHash: second.hash)))
    await store.send(.resourceDeliveredOnLink(linkID: recipientLink)) {
        $0.linkResourceInFlight[recipientLink] = nil
    }
    await store.receive(.delivered(messageHash: first.hash, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(first.hash)] = nil
        $0.succeededMessages.insert(first.hash)
    }
    await store.receive(.delegate(.deliveryConfirmed(messageHash: first.hash)))
    await store.send(probe)                                   // no sendDirect for the cancelled copy
    store.exhaustivity = .off
}

@Test @MainActor func routerCancelRetryingCopyStopsItsTimer() async {
    let m = note()
    let clock = TestClock()
    let store = cancelStore(liveRecipient(), clock)
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: m.hash)) {
        $0.pendingDeliveries[.delivery(m.hash)] = nil
        $0.cancelledMessages.insert(m.hash)
    }
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
    await store.send(probe)                                   // no retryDue ever fired
}

@Test @MainActor func routerCancelTransferringCopyStartsTheNextQueuedCopy() async {
    let first = bigMessage("a"), second = bigMessage("b")
    let k2 = LXMFRouter.DeliveryKey.delivery(second.hash)
    let store = cancelStore(liveRecipient())
    await store.send(.send(message: first, desiredMethod: .direct))
    await store.send(.send(message: second, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: first.hash)) {
        $0.pendingDeliveries[.delivery(first.hash)] = nil
        $0.linkResourceInFlight[recipientLink] = k2
        $0.pendingDeliveries[k2]?.phase = .transferring
        $0.resourceQueue[recipient] = nil
        $0.cancelledMessages.insert(first.hash)
    }
    // The cancel reaches the link before the next transfer starts on it.
    await store.receive(.delegate(.cancelResource(linkID: recipientLink)))
    await store.receive(.delegate(.deliveryCancelled(messageHash: first.hash)))
    await store.receive(.delegate(.sendDirect(linkID: recipientLink, data: second.packed, asResource: true)))
    store.exhaustivity = .off
}

@Test @MainActor func routerCancelBothCopiesReportsOnce() async {
    let m = note()
    let clock = TestClock()
    var state = liveRecipient()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    let store = cancelStore(state, clock)
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: m, propagationPacked: small))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: m.hash)) {
        $0.pendingDeliveries = [:]
        $0.cancelledMessages.insert(m.hash)
    }
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
    await store.send(probe)                                   // neither copy retries or fails later
    store.exhaustivity = .off                                 // the PN link's idle timer
}

/// A copy handed over after its message was cancelled — a stamp search that finished anyway — is
/// never armed. A cancel with nothing to cancel reports nothing (the node reports the stamp case).
@Test @MainActor func routerCancelLateCopyOfACancelledMessageArmsNothing() async {
    let m = note()
    let store = TestStore(initialState: liveRecipient()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.cancelOutbound(messageHash: m.hash)) {
        $0.cancelledMessages.insert(m.hash)
    }
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: m, propagationPacked: small))   // no PN: would fail if armed
}

@Test @MainActor func routerCancelMessageQueuedBehindItsLinkIsDropped() async {
    let big = bigMessage("a")
    var state = LXMFRouter.State()
    state.knownPaths.insert(recipient)
    let store = cancelStore(state)
    await store.send(.send(message: big, desiredMethod: .direct))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.cancelOutbound(messageHash: big.hash)) {
        $0.outboundQueue[recipient] = nil
        $0.cancelledMessages.insert(big.hash)
    }
    await store.receive(.delegate(.deliveryCancelled(messageHash: big.hash)))
    await store.send(.linkEstablished(destinationHash: recipient, linkID: recipientLink)) {
        $0.directLinks[recipient] = .active(linkID: recipientLink)
        $0.establishAttempts[recipient] = nil
    }
    await store.send(probe)                                   // nothing was drained onto the link
    store.exhaustivity = .off
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter routerCancel`
Expected: FAIL to compile — no `cancelOutbound`, no `cancelledMessages`.

- [ ] **Step 3: State, action, delegates, query**

In `Sources/ReTiCANode/LXMFRouter.swift`, replace

```swift
        var succeededMessages = RingSet(capacity: LXMFRouter.succeededMessageMemory)
```

with

```swift
        var succeededMessages = RingSet(capacity: LXMFRouter.succeededMessageMemory)
        /// Message hashes the app cancelled. A copy of one handed over later (a stamp search that
        /// finished after the cancel) is never armed. Bounded like `succeededMessages`.
        var cancelledMessages = RingSet(capacity: LXMFRouter.succeededMessageMemory)
```

Replace

```swift
        case resourceFailedOnLink(linkID: Data, rejected: Bool)
        case retryDue(messageHash: Data, leg: Leg)
```

with

```swift
        case resourceFailedOnLink(linkID: Data, rejected: Bool)
        /// The app cancelled this message: drop every copy, cancel a Resource in flight, report
        /// `deliveryCancelled` once. Reference `LXMRouter.cancel_outbound` (LXMRouter.py:1719-1744).
        case cancelOutbound(messageHash: Data)
        case retryDue(messageHash: Data, leg: Leg)
```

Replace

```swift
            case deliveryRejected(messageHash: Data)
        }
    }
```

with

```swift
            case deliveryRejected(messageHash: Data)
            /// The app cancelled the message. Nothing else is reported for it afterwards.
            case deliveryCancelled(messageHash: Data)
            /// Cancel our Resource in flight on `linkID` (its copy was cancelled).
            case cancelResource(linkID: Data)
        }
    }
```

At the end of the file (after the struct's closing `}`), append:

```swift

extension LXMFRouter.State {
    /// Whether the router holds any outbound work for `messageHash`: a pending copy in any phase, or
    /// a message queued behind link establishment. `cancelOutbound` reports `deliveryCancelled` only
    /// when this is true; `LXMFNode` reports it itself when the only work was a delivery stamp search.
    public func hasOutboundState(for messageHash: Data) -> Bool {
        pendingDeliveries.keys.contains { $0.messageHash == messageHash }
            || outboundQueue.values.contains { $0.contains { $0.hash == messageHash } }
            || propagationQueue.values.contains { $0.contains { $0.messageHash == messageHash } }
    }
}
```

- [ ] **Step 4: Guards and the cancel**

Replace

```swift
            case let .send(message, desiredMethod):
                let effective: DeliveryMethod =
```

with

```swift
            case let .send(message, desiredMethod):
                // A cancelled message is never armed again, whichever path hands it over late.
                guard !state.cancelledMessages.contains(message.hash) else { return .none }
                let effective: DeliveryMethod =
```

Replace

```swift
            case let .sendViaPropagation(message, propagationPacked):
                guard let pn = state.outboundPropagationNode else {
```

with

```swift
            case let .sendViaPropagation(message, propagationPacked):
                guard !state.cancelledMessages.contains(message.hash) else { return .none }
                guard let pn = state.outboundPropagationNode else {
```

Insert a new case directly before `            case let .retryDue(hash, leg):`:

```swift
            case let .cancelOutbound(hash):
                let hadWork = state.hasOutboundState(for: hash)
                state.cancelledMessages.insert(hash)
                guard hadWork else { return .none }
                var effects: [Effect<Action>] = []
                var freed: [Data] = []
                for leg in [Leg.delivery, .propagated] {
                    let key = DeliveryKey(messageHash: hash, leg: leg)
                    guard let pending = state.pendingDeliveries.removeValue(forKey: key) else { continue }
                    effects.append(.cancel(id: CancelID.retry(key)))
                    switch pending.phase {
                    case .retrying:
                        break
                    case .queued:
                        for (dest, keys) in state.resourceQueue where keys.contains(key) {
                            let rest = keys.filter { $0 != key }
                            state.resourceQueue[dest] = rest.isEmpty ? nil : rest
                        }
                    case .transferring:
                        guard let linkID = state.linkResourceInFlight.first(where: { $0.value == key })?.key
                        else { break }
                        state.linkResourceInFlight[linkID] = nil
                        effects.append(.send(.delegate(.cancelResource(linkID: linkID))))
                        if let dest = destination(ofLink: linkID, state) { freed.append(dest) }
                    }
                }
                for (dest, messages) in state.outboundQueue where messages.contains(where: { $0.hash == hash }) {
                    let rest = messages.filter { $0.hash != hash }
                    state.outboundQueue[dest] = rest.isEmpty ? nil : rest
                }
                for (dest, items) in state.propagationQueue where items.contains(where: { $0.messageHash == hash }) {
                    let rest = items.filter { $0.messageHash != hash }
                    state.propagationQueue[dest] = rest.isEmpty ? nil : rest
                }
                effects.append(.send(.delegate(.deliveryCancelled(messageHash: hash))))
                // The cancel reaches the link (above) before the next copy starts on it (below).
                for dest in freed { effects.append(startNextQueued(&state, dest: dest)) }
                return .merge(effects)

```

- [ ] **Step 5: Run the tests**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter routerCancel --filter linkQueue --filter routerTransfer`
Expected: all PASS.

- [ ] **Step 6: Mutation batch (apply all at once, `LXMFRouter.swift`)**

1. `.transferring` branch: delete `effects.append(.send(.delegate(.cancelResource(linkID: linkID))))` → RED `routerCancelTransferringCopyCancelsItsResource`, `routerCancelTransferringCopyStartsTheNextQueuedCopy`.
2. `.queued` branch: replace its loop with `break` → RED `routerCancelQueuedCopyIsRemovedAndNothingIsSent` (its state closure expects `resourceQueue[recipient] == nil`).
3. Delete `effects.append(.cancel(id: CancelID.retry(key)))` → RED `routerCancelRetryingCopyStopsItsTimer`, `routerCancelBothCopiesReportsOnce` (a `retryDue` arrives before the probe).
4. Move `effects.append(.send(.delegate(.deliveryCancelled(messageHash: hash))))` INTO the `for leg` loop (after `effects.append(.cancel(...))`) and delete it below → RED `routerCancelBothCopiesReportsOnce` (two reports). Mutation 3 also reddens this test; 4's red is independent of 3 because both copies reach the loop either way.
5. `.send`: delete the `cancelledMessages` guard → RED `routerCancelLateCopyOfACancelledMessageArmsNothing`.
6. Delete the `for (dest, messages) in state.outboundQueue ...` loop → RED `routerCancelMessageQueuedBehindItsLinkIsDropped`.
7. Delete `for dest in freed { ... }` → RED `routerCancelTransferringCopyStartsTheNextQueuedCopy` (no `sendDirect` for the second copy). Mutation 1 also reddens it; 7 is observed on its own because 1 leaves the `freed` path untouched.

No mutation traps. Run the Step 5 filter: every `routerCancel*` test FAILS. Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 7: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --no-parallel > /tmp/ReTiCaMsgr/tad-t5-full.log`
Expected: all pass with the 1 known issue; count = Task 4 count + 7.

- [ ] **Step 8: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterCancelTests.swift`

Write `/tmp/ReTiCaMsgr/msg-tad-task-5.txt`:

```
feat: the router cancels an outbound message

cancelOutbound drops every copy of a message whatever its phase,
cancels its retry timers, asks the node to cancel a Resource in flight,
starts the next queued copy on the freed link and reports
deliveryCancelled once. The hash is remembered so a copy handed over
after the cancel is never armed.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery commit -F /tmp/ReTiCaMsgr/msg-tad-task-5.txt`

---
### Task 6: `LXMFNode` — progress, outcomes, inbound progress, cancel, idle re-arm

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (`Action.linkActivity`, its case)
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (State after :163; Action after :234; Delegate :237-244; constants after :309; `CancelID` :311-318; helpers after :330; `.sendMessage` propagation effect :488-494; `.router(.delegate(...))` outcome cases :714-721; `.sendDirect`/`.sendPropagated` :730-736; `.linkClosed` :765-770; `.resourceReceived` / `.resourceConcluded` :827-832; `deliverySend` :912-918)
- Create: `Tests/ReTiCANodeTests/LXMFNodeTransferMappingTests.swift`

**Interfaces:**
- Consumes: T2 `TransportEndpoint.Action.Delegate.resourceProgress(linkID:resourceHash:role:bytesDone:bytesTotal:segment:segments:)`, `.resourceFailed(linkID:resourceHash:rejected:)`, `TransportEndpoint.Action.cancelResource(linkID:hash:)`; T3 `.resourceFailedOnLink`, `Delegate.deliveryRejected`; T5 `.cancelOutbound`, `Delegate.cancelResource`, `Delegate.deliveryCancelled`, `State.hasOutboundState(for:)`.
- Produces:
  - `LXMFRouter.Action.linkActivity(linkID: Data)` — re-arms `idleTimer` for the destination whose active link is `linkID` (no-op otherwise).
  - `LXMFNode.Action.cancelOutbound(messageHash: Data)`.
  - `LXMFNode.Action.Delegate.deliveryRejected(messageHash: Data)`, `.deliveryCancelled(messageHash: Data)`, `.deliveryProgress(messageHash: Data, fraction: Double)`, `.propagationProgress(messageHash: Data, fraction: Double)`, `.inboundTransferProgress(sourceHash: Data?, linkID: Data, fraction: Double)`.
  - `LXMFNode.linkActiveProgress = 0.05`, `LXMFNode.transferStartProgress = 0.10`, `LXMFNode.transferFraction(bytesDone:bytesTotal:segment:segments:) -> Double` (a split Resource's overall done fraction), `LXMFNode.outboundFraction(bytesDone:bytesTotal:segment:segments:) -> Double` (= `0.10 + 0.90 × transferFraction`).
  - `LXMFNode.State.outboundTransfers: [Data: Data]` (linkID → our resource hash), `.transferProgress: [LXMFRouter.DeliveryKey: Double]`, `.inboundProgress: [Data: Double]` (linkID → fraction), all `public internal(set)`.
  - `LXMFNode.CancelID.propagationStampFor(Data)`, `.deliveryStampFor(Data)` (per message; the old all-or-nothing ids stay).
- Mapping rules: our transfer on a link is identified by the resource hash of the first sender-role progress event after the router started a copy there; `resourceConcluded`/`resourceFailed` naming any other hash on that link are not ours (a failure is then an INBOUND failure). `sourceHash` is the link's remote destination when we opened the link, `nil` when the link terminates on our own delivery/propagation destination (the sender is not known before unpack — see "Self-review notes").

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFNodeTransferMappingTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Transfer-aware delivery, Task 6: LXMFNode maps transfer events onto messages. The endpoint's
// delegates are injected directly; the router is seeded with a live link to `dest`, and the
// endpoint has no link element, so `sendResourceOverLink` / `cancelResource` go nowhere.

private let dest = Data(repeating: 0xD5, count: 16)
private let link = Data(repeating: 0xEF, count: 16)
private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let inboundLink = Data(repeating: 0x7A, count: 16)
private let ours = Data(repeating: 0x0D, count: 16)          // our delivery destination, in these tests
private let h1 = Data(repeating: 0x11, count: 32)
private let h2 = Data(repeating: 0x22, count: 32)
/// An exhaustive no-op: a conclusion on a link we have no transfer on changes nothing.
private let probe = LXMFNode.Action.endpoint(.delegate(.resourceConcluded(linkID: Data(repeating: 0x99, count: 16),
                                                                          resourceHash: h1)))

@MainActor
private func mappingNode(clock: TestClock<Duration> = TestClock(),
                         _ configure: (inout LXMFNode.State) -> Void = { _ in })
    -> TestStore<LXMFNode.State, LXMFNode.Action> {
    var state = LXMFNode.State(identity: Identity(),
                               endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    state.router.directLinks[dest] = .active(linkID: link)
    state.router.knownPaths.insert(dest)
    state.directLinks[dest] = link
    state.linkDestinations[link] = dest
    configure(&state)
    let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
        $0.continuousClock = clock
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

private func bigMessage(_ fill: String = "y") -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data(String(repeating: fill, count: 2000).utf8))
}

private func sent(_ hash: Data, done: Int, total: Int, on linkID: Data = link) -> LXMFNode.Action {
    .endpoint(.delegate(.resourceProgress(linkID: linkID, resourceHash: hash, role: .sender,
                                          bytesDone: done, bytesTotal: total, segment: 1, segments: 1)))
}

private func received(_ hash: Data, done: Int, total: Int, on linkID: Data) -> LXMFNode.Action {
    .endpoint(.delegate(.resourceProgress(linkID: linkID, resourceHash: hash, role: .receiver,
                                          bytesDone: done, bytesTotal: total, segment: 1, segments: 1)))
}

@Test func nodeTransferFractionsFollowTheReferenceFormula() {
    // Reference `LXMessage.__update_transfer_progress` (LXMessage.py:623-624): 0.10 + 0.90 × progress.
    #expect(abs(LXMFNode.outboundFraction(bytesDone: 0, bytesTotal: 10, segment: 1, segments: 1) - 0.10) < 1e-12)
    #expect(abs(LXMFNode.outboundFraction(bytesDone: 10, bytesTotal: 10, segment: 1, segments: 1) - 1.0) < 1e-12)
    // A split Resource counts its finished segments: segment 3 of 4, half done → 2.5 / 4.
    #expect(abs(LXMFNode.transferFraction(bytesDone: 5, bytesTotal: 10, segment: 3, segments: 4) - 0.625) < 1e-12)
    #expect(LXMFNode.transferFraction(bytesDone: 5, bytesTotal: 0, segment: 1, segments: 1) == 0)
}

@Test @MainActor func nodeTransferProgressFollowsTheReferenceScale() async {
    let m = bigMessage()
    let store = mappingNode()
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.receive(.delegate(.deliveryProgress(messageHash: m.hash, fraction: LXMFNode.linkActiveProgress)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.receive(.delegate(.deliveryProgress(messageHash: m.hash, fraction: LXMFNode.transferStartProgress)))
    await store.send(sent(h1, done: 500, total: 1000))
    await store.receive(.delegate(.deliveryProgress(
        messageHash: m.hash,
        fraction: LXMFNode.outboundFraction(bytesDone: 500, bytesTotal: 1000, segment: 1, segments: 1))))
    await store.send(.endpoint(.delegate(.resourceConcluded(linkID: link, resourceHash: h1))))
    await store.receive(.delegate(.deliveryProgress(messageHash: m.hash, fraction: 1.0)))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: m.hash)))
    #expect(store.state.transferProgress[.delivery(m.hash)] == nil)
    #expect(store.state.outboundTransfers[link] == nil)
}

@Test @MainActor func nodeTransferProgressIsMonotonicPerCopy() async {
    let m = bigMessage()
    let key = LXMFRouter.DeliveryKey.delivery(m.hash)
    let clock = TestClock()
    let store = mappingNode(clock: clock)
    let halfway = LXMFNode.outboundFraction(bytesDone: 500, bytesTotal: 1000, segment: 1, segments: 1)
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.send(sent(h1, done: 500, total: 1000))
    #expect(store.state.transferProgress[key] == halfway)
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(sent(h1, done: 200, total: 1000))                     // lower: not reported
    await store.receive(.router(.linkActivity(linkID: link)))              // but it is still link activity
    await store.send(probe)
    store.exhaustivity = .off
    // The transfer fails and is retried on a fresh link: the wire restarts at 0.05 / 0.10, the copy
    // does not go backwards.
    await store.send(.endpoint(.delegate(.resourceFailed(linkID: link, resourceHash: h1, rejected: false))))
    let fresh = Data(repeating: 0xF0, count: 16)
    await store.send(.router(.linkEstablished(destinationHash: dest, linkID: fresh)))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.router(.delegate(.sendDirect(linkID: fresh, data: m.packed, asResource: true))))
    await store.send(sent(h2, done: 0, total: 1000, on: fresh))
    #expect(store.state.transferProgress[key] == halfway)
    await store.send(sent(h2, done: 900, total: 1000, on: fresh))
    await store.receive(.delegate(.deliveryProgress(
        messageHash: m.hash,
        fraction: LXMFNode.outboundFraction(bytesDone: 900, bytesTotal: 1000, segment: 1, segments: 1))))
}

@Test @MainActor func nodeTransferPropagatedCopyReportsPropagationProgress() async {
    let m = bigMessage()
    let store = mappingNode { state in
        state.router.outboundPropagationNode = pn
        state.router.directLinks[pn] = .active(linkID: pnLink)
        state.directLinks[pn] = pnLink
    }
    await store.send(.router(.sendViaPropagation(message: m, propagationPacked: Data(repeating: 0xAA, count: 432))))
    await store.receive(.delegate(.propagationProgress(messageHash: m.hash, fraction: LXMFNode.linkActiveProgress)))
    await store.send(sent(h1, done: 0, total: 432, on: pnLink))
    await store.receive(.delegate(.propagationProgress(messageHash: m.hash, fraction: LXMFNode.transferStartProgress)))
    #expect(store.state.transferProgress[.delivery(m.hash)] == nil)
}

@Test @MainActor func nodeTransferInboundProgressIsKeyedByTheLinkDestination() async {
    let store = mappingNode { state in
        state.deliveryDestinationHash = ours
        state.linkDestinations[inboundLink] = ours             // a peer linked to OUR delivery destination
    }
    // On a link we opened, the far end is known.
    await store.send(received(h1, done: 250, total: 1000, on: link))
    await store.receive(.delegate(.inboundTransferProgress(sourceHash: dest, linkID: link, fraction: 0.25)))
    // On a link a peer opened to us, the sender is not known until the message is unpacked.
    await store.send(received(h2, done: 250, total: 1000, on: inboundLink))
    await store.receive(.delegate(.inboundTransferProgress(sourceHash: nil, linkID: inboundLink, fraction: 0.25)))
}

/// Review Focus 1: a conclusion naming a hash that is not our transfer on that link (a cancelled
/// transfer landing late, or anything else) must not confirm the copy now in flight there.
@Test @MainActor func nodeTransferStaleConclusionForAnotherResourceIsIgnored() async {
    let m = bigMessage()
    let store = mappingNode()
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.endpoint(.delegate(.resourceConcluded(linkID: link, resourceHash: h2))))
    await store.send(probe)
    store.exhaustivity = .off
    #expect(store.state.router.pendingDeliveries[.delivery(m.hash)] != nil)
}

/// Review Focus 1: `LinkSession` reports an INBOUND transfer's failure the same way; it must not
/// fail our outbound copy on the same link.
@Test @MainActor func nodeTransferInboundFailureDoesNotFailTheOutboundCopy() async {
    let m = bigMessage()
    let store = mappingNode()
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.endpoint(.delegate(.resourceFailed(linkID: link, resourceHash: h2, rejected: true))))
    await store.send(probe)
    store.exhaustivity = .off
    #expect(store.state.router.pendingDeliveries[.delivery(m.hash)]?.phase == .transferring)
}

@Test @MainActor func nodeTransferOutboundFailureReachesTheRouter() async {
    let m = bigMessage()
    let store = mappingNode()
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.send(.endpoint(.delegate(.resourceFailed(linkID: link, resourceHash: h1, rejected: true))))
    await store.receive(.router(.resourceFailedOnLink(linkID: link, rejected: true)))
    await store.receive(.delegate(.deliveryRejected(messageHash: m.hash)))
    #expect(store.state.outboundTransfers[link] == nil)
    #expect(store.state.transferProgress[.delivery(m.hash)] == nil)
}

@Test @MainActor func nodeTransferCancelOutboundCancelsTheResourceByHash() async {
    let m = bigMessage()
    let store = mappingNode()
    await store.send(.router(.send(message: m, desiredMethod: .direct)))
    await store.send(sent(h1, done: 0, total: 1000))
    await store.send(.cancelOutbound(messageHash: m.hash))
    await store.receive(.router(.cancelOutbound(messageHash: m.hash)))
    await store.receive(.endpoint(.cancelResource(linkID: link, hash: h1)))
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    #expect(store.state.outboundTransfers[link] == nil)
}

/// Review Focus 6: the router holds nothing for a message still in its delivery stamp search, so
/// the node reports the cancel — once — and the search stops (cost 20 would run for minutes).
@Test(.timeLimit(.minutes(1))) @MainActor func nodeTransferCancelOutboundDuringADeliveryStampSearchReportsCancelled() async {
    let store = mappingNode { state in
        state.learnedPeers[dest] = LXMFNode.LearnedPeer(displayName: nil, stampCost: LXMFNode.maxDeliveryStampCost,
                                                        supportsCompression: false,
                                                        learnedAt: Date(timeIntervalSince1970: 1700000000))
    }
    let m = LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                             title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: m, alsoViaPropagation: false))
    #expect(store.state.inFlightDeliveryStamps == [m.hash])
    await store.send(.cancelOutbound(messageHash: m.hash))
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    #expect(store.state.inFlightDeliveryStamps.isEmpty)
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(10))
}

@Test(.timeLimit(.minutes(1))) @MainActor func nodeTransferCancelOutboundStopsThePropagationStampSearch() async {
    let recipient = Identity()
    let store = mappingNode { state in
        state.router.outboundPropagationNode = pn
        state.endpoint.transport.learned[dest] = LearnedDestination(
            identity: recipient, appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
            hops: 1, nextHop: nil, announceEmitted: 0)
        state.endpoint.transport.learned[pn] = LearnedDestination(
            identity: Identity(),
            appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 0, perSyncLimit: 0,
                                targetStampCost: LXMFPropagation.maxPropagationStampCost,
                                stampCostFlexibility: 0, peeringCost: 0).packed,
            ratchet: nil, interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    }
    let m = LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                             title: Data(), content: Data("x".utf8))
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    await store.send(.cancelOutbound(messageHash: m.hash))
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.finish(timeout: .seconds(10))                  // only possible if the search was cancelled
}

@Test @MainActor func nodeTransferLinkActivityReArmsTheIdleTimer() async {
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.directLinks[dest] = .active(linkID: link)
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    await store.send(.linkEstablished(destinationHash: dest, linkID: link))       // arms the idle timer
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds - 1))
    await store.send(.linkActivity(linkID: link))
    await clock.advance(by: .seconds(2))
    #expect(store.state.directLinks[dest] == .active(linkID: link))
    await clock.advance(by: .seconds(LXMFDelivery.linkMaxInactivitySeconds))
    await store.receive(.delegate(.closeLink(destinationHash: dest)))
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter nodeTransfer`
Expected: FAIL to compile — no `linkActivity`, no `cancelOutbound` on the node, no progress delegates.

- [ ] **Step 3: Router `linkActivity`**

In `Sources/ReTiCANode/LXMFRouter.swift` replace

```swift
        case cancelOutbound(messageHash: Data)
        case retryDue(messageHash: Data, leg: Leg)
```

with

```swift
        case cancelOutbound(messageHash: Data)
        /// Resource traffic on `linkID` (either direction). Re-arms the idle timer of the
        /// destination it serves, so a long transfer never trips `linkMaxInactivitySeconds` (spec §5).
        case linkActivity(linkID: Data)
        case retryDue(messageHash: Data, leg: Leg)
```

and insert directly before `            case let .retryDue(hash, leg):`:

```swift
            case let .linkActivity(linkID):
                guard let dest = destination(ofLink: linkID, state) else { return .none }
                return idleTimer(dest, linkID)

```

- [ ] **Step 4: `LXMFNode` state, action, delegates, constants, cancel ids**

In `Sources/ReTiCANode/LXMFNode.swift`, replace

```swift
        public internal(set) var inFlightDeliveryStamps: [Data] = []
```

with

```swift
        public internal(set) var inFlightDeliveryStamps: [Data] = []

        /// linkID → the resource hash of OUR Resource in flight on that link, learned from the first
        /// sender-role `resourceProgress` after the router starts a copy there. A conclusion or
        /// failure naming any other hash on that link is not our copy's: an inbound transfer's, or a
        /// cancelled one landing late.
        public internal(set) var outboundTransfers: [Data: Data] = [:]
        /// The last fraction reported per outbound copy, so `deliveryProgress` /
        /// `propagationProgress` never go backwards — a retry restarts the wire transfer, not the copy.
        public internal(set) var transferProgress: [LXMFRouter.DeliveryKey: Double] = [:]
        /// linkID → the last `inboundTransferProgress` fraction reported for the Resource arriving on it.
        public internal(set) var inboundProgress: [Data: Double] = [:]
```

Replace

```swift
        case cancelDeliveryStamps
        case delegate(Delegate)
```

with

```swift
        case cancelDeliveryStamps
        /// Cancel one outbound message, wherever it is: in its delivery or propagation stamp search,
        /// queued, retrying, or mid-transfer (its Resource is cancelled on the wire). Reports
        /// `.delegate(.deliveryCancelled)` once; nothing else is reported for it afterwards.
        /// Reference `LXMRouter.cancel_outbound` (LXMRouter.py:1719-1744).
        case cancelOutbound(messageHash: Data)
        case delegate(Delegate)
```

Replace

```swift
            case deliveryFailed(messageHash: Data)
            case deliveryConfirmed(messageHash: Data)
            case propagationAccepted(messageHash: Data)
        }
```

with

```swift
            case deliveryFailed(messageHash: Data)
            case deliveryConfirmed(messageHash: Data)
            case propagationAccepted(messageHash: Data)
            /// Every copy is over, none succeeded, and the last one's transfer was refused by its peer.
            case deliveryRejected(messageHash: Data)
            /// The app cancelled the message (`.cancelOutbound`).
            case deliveryCancelled(messageHash: Data)
            /// The delivery copy's progress on the reference scale: 0.05 when its link is up and the
            /// transfer is about to start, 0.10 when it starts, `0.10 + 0.90 × done` during, 1.0 when
            /// confirmed (LXMRouter.py:2788-2790, LXMessage.py:623-624). Never decreases.
            case deliveryProgress(messageHash: Data, fraction: Double)
            /// The same for the copy sent to the propagation node; 1.0 when it is accepted.
            case propagationProgress(messageHash: Data, fraction: Double)
            /// A Resource arriving on `linkID`, 0…1, before any message can be unpacked from it.
            /// `sourceHash` is the far end of the link when WE opened it; nil when a peer linked to our
            /// own destination, because LXMF senders do not identify on delivery links.
            case inboundTransferProgress(sourceHash: Data?, linkID: Data, fraction: Double)
        }
```

Replace

```swift
    public static let stampCostExpiry: TimeInterval = 45 * 24 * 60 * 60
```

with

```swift
    public static let stampCostExpiry: TimeInterval = 45 * 24 * 60 * 60

    /// Progress when a copy's link is active and its transfer is about to start (LXMRouter.py:2788-2790).
    public static let linkActiveProgress = 0.05
    /// Progress when a copy's transfer starts (reference: once the Resource exists).
    public static let transferStartProgress = 0.10

    /// A Resource's overall done fraction: finished segments plus this segment's share.
    public static func transferFraction(bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int) -> Double {
        guard bytesTotal > 0, segments > 0 else { return 0 }
        let within = min(max(Double(bytesDone) / Double(bytesTotal), 0), 1)
        let index = min(max(segment, 1), segments)
        return (Double(index - 1) + within) / Double(segments)
    }

    /// An outbound copy's progress during its transfer: `0.10 + 0.90 × transfer progress`
    /// (reference `LXMessage.__update_transfer_progress`, LXMessage.py:623-624).
    public static func outboundFraction(bytesDone: Int, bytesTotal: Int, segment: Int, segments: Int) -> Double {
        transferStartProgress + (1 - transferStartProgress)
            * transferFraction(bytesDone: bytesDone, bytesTotal: bytesTotal, segment: segment, segments: segments)
    }
```

Replace

```swift
    /// Cancellation identity for the propagation stamp search.
    ///
    /// One id for all in-flight searches rather than one per message: `.sendViaPropagation` builds the
    /// `LXMessage` internally, so a caller wanting to abandon *that* send has no message hash to name.
    /// Reference's `LXStamper.cancel_work` is keyed per message (LXStamper.py:146), driven from
    /// `cancel_outbound(message_id)`; ours is coarser by exactly that much. Effects are registered
    /// **without** `cancelInFlight`, so two concurrent sends coexist and are reclaimed together.
    enum CancelID: Hashable { case propagationStamp; case deliveryStamp }
```

with

```swift
    /// Cancellation identities for the stamp searches.
    ///
    /// `propagationStamp` / `deliveryStamp` cover ALL in-flight searches of that kind
    /// (`.cancelPropagationStamps`, `.cancelDeliveryStamps`, `.setPropagationNode`). A search for a
    /// message the caller built (`.sendMessage`, `.send`) is ALSO registered under its per-message id,
    /// which `.cancelOutbound(messageHash:)` cancels — reference's `LXStamper.cancel_work` is keyed per
    /// message the same way (LXStamper.py:146). `.sendViaPropagation` builds its message internally, so
    /// the caller has no hash to name and it has only the shared id. Effects are registered
    /// **without** `cancelInFlight`, so concurrent sends coexist.
    enum CancelID: Hashable {
        case propagationStamp
        case deliveryStamp
        case propagationStampFor(Data)
        case deliveryStampFor(Data)
    }
```

- [ ] **Step 5: Per-message stamp cancel ids**

In `.sendMessage`, replace

```swift
                        await send(.router(.sendViaPropagation(message: message, propagationPacked: packed)))
                    }
                    .cancellable(id: CancelID.propagationStamp))
                }
                return .merge(effects)
```

with

```swift
                        await send(.router(.sendViaPropagation(message: message, propagationPacked: packed)))
                    }
                    .cancellable(id: CancelID.propagationStampFor(message.hash))
                    .cancellable(id: CancelID.propagationStamp))
                }
                return .merge(effects)
```

In `deliverySend`, replace

```swift
            await send(.router(.send(message: message.withStamp(stamp), desiredMethod: method)))
        }
        .cancellable(id: CancelID.deliveryStamp)
```

with

```swift
            await send(.router(.send(message: message.withStamp(stamp), desiredMethod: method)))
        }
        .cancellable(id: CancelID.deliveryStampFor(message.hash))
        .cancellable(id: CancelID.deliveryStamp)
```

- [ ] **Step 6: Reducer helpers**

Replace

```swift
            func isServedPropagationLink(_ state: LXMFNode.State, _ linkID: Data) -> Bool {
                guard let served = state.propagationDestinationHash else { return false }
                return state.linkDestinations[linkID] == served
            }
```

with

```swift
            func isServedPropagationLink(_ state: LXMFNode.State, _ linkID: Data) -> Bool {
                guard let served = state.propagationDestinationHash else { return false }
                return state.linkDestinations[linkID] == served
            }
            /// Report `fraction` for this copy unless it would not move its progress forward.
            func reportProgress(_ state: inout LXMFNode.State, _ key: LXMFRouter.DeliveryKey,
                                _ fraction: Double) -> Effect<Action> {
                let clamped = min(max(fraction, 0), 1)
                if let last = state.transferProgress[key], clamped <= last { return .none }
                state.transferProgress[key] = clamped
                let event: Action.Delegate = key.leg == .delivery
                    ? .deliveryProgress(messageHash: key.messageHash, fraction: clamped)
                    : .propagationProgress(messageHash: key.messageHash, fraction: clamped)
                return .send(.delegate(event))
            }
            /// The copy succeeded: report 1.0 (unless its transfer already did) and forget it.
            func finishProgress(_ state: inout LXMFNode.State, _ key: LXMFRouter.DeliveryKey) -> Effect<Action> {
                guard let last = state.transferProgress.removeValue(forKey: key), last < 1 else { return .none }
                let event: Action.Delegate = key.leg == .delivery
                    ? .deliveryProgress(messageHash: key.messageHash, fraction: 1)
                    : .propagationProgress(messageHash: key.messageHash, fraction: 1)
                return .send(.delegate(event))
            }
            /// The message is over without success: forget both copies' progress.
            func clearProgress(_ state: inout LXMFNode.State, _ hash: Data) {
                state.transferProgress[.delivery(hash)] = nil
                state.transferProgress[.propagated(hash)] = nil
            }
```

- [ ] **Step 7: `cancelOutbound`**

Insert directly before `            // --- Propagation sync: phase-1 (IDENTIFY + list request) ---`:

```swift
            case let .cancelOutbound(hash):
                // Stop the stamp work for this message (reference `LXStamper.cancel_work`, keyed per
                // message) and hand the rest to the router, which owns every copy it was given. A
                // delivery copy still in its stamp search was never handed over, so if the router holds
                // nothing else for the message the cancel is reported here — once either way.
                let wasSearching = state.inFlightDeliveryStamps.contains(hash)
                state.inFlightDeliveryStamps.removeAll { $0 == hash }
                let routerReports = state.router.hasOutboundState(for: hash)
                var effects: [Effect<Action>] = [
                    .cancel(id: CancelID.deliveryStampFor(hash)),
                    .cancel(id: CancelID.propagationStampFor(hash)),
                    .send(.router(.cancelOutbound(messageHash: hash))),
                ]
                if wasSearching && !routerReports {
                    effects.append(.send(.delegate(.deliveryCancelled(messageHash: hash))))
                }
                return .merge(effects)

```

- [ ] **Step 8: Outcomes**

Replace

```swift
            case let .router(.delegate(.deliveryFailed(hash))):
                return .send(.delegate(.deliveryFailed(messageHash: hash)))

            case let .router(.delegate(.deliveryConfirmed(hash))):
                return .send(.delegate(.deliveryConfirmed(messageHash: hash)))

            case let .router(.delegate(.propagationAccepted(hash))):
                return .send(.delegate(.propagationAccepted(messageHash: hash)))
```

with

```swift
            case let .router(.delegate(.deliveryFailed(hash))):
                clearProgress(&state, hash)
                return .send(.delegate(.deliveryFailed(messageHash: hash)))

            case let .router(.delegate(.deliveryRejected(hash))):
                clearProgress(&state, hash)
                return .send(.delegate(.deliveryRejected(messageHash: hash)))

            case let .router(.delegate(.deliveryCancelled(hash))):
                clearProgress(&state, hash)
                return .send(.delegate(.deliveryCancelled(messageHash: hash)))

            case let .router(.delegate(.deliveryConfirmed(hash))):
                let done = finishProgress(&state, .delivery(hash))
                return .merge(done, .send(.delegate(.deliveryConfirmed(messageHash: hash))))

            case let .router(.delegate(.propagationAccepted(hash))):
                let done = finishProgress(&state, .propagated(hash))
                return .merge(done, .send(.delegate(.propagationAccepted(messageHash: hash))))

            case let .router(.delegate(.cancelResource(linkID))):
                // Our transfer's hash on that link names it to the session. Unknown (the router
                // started the copy but its transfer never reported): nothing on the wire to cancel.
                guard let hash = state.outboundTransfers.removeValue(forKey: linkID) else { return .none }
                return .send(.endpoint(.cancelResource(linkID: linkID, hash: hash)))
```

- [ ] **Step 9: Resource starts report 0.05**

Replace

```swift
            case let .router(.delegate(.sendDirect(linkID, data, asResource))):
                return asResource
                    ? .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: data)))
                    : .send(.endpoint(.sendOverLink(linkID: linkID, data: data)))

            case let .router(.delegate(.sendPropagated(linkID, propagationPacked))):
                return .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: propagationPacked)))
```

with

```swift
            case let .router(.delegate(.sendDirect(linkID, data, asResource))):
                guard asResource else { return .send(.endpoint(.sendOverLink(linkID: linkID, data: data))) }
                // A new transfer starts on this link; its first sender progress names its hash.
                state.outboundTransfers[linkID] = nil
                var started: Effect<Action> = .none
                if let key = state.router.linkResourceInFlight[linkID] {
                    started = reportProgress(&state, key, LXMFNode.linkActiveProgress)
                }
                return .merge(started, .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: data))))

            case let .router(.delegate(.sendPropagated(linkID, propagationPacked))):
                state.outboundTransfers[linkID] = nil
                var started: Effect<Action> = .none
                if let key = state.router.linkResourceInFlight[linkID] {
                    started = reportProgress(&state, key, LXMFNode.linkActiveProgress)
                }
                return .merge(started, .send(.endpoint(.sendResourceOverLink(linkID: linkID, data: propagationPacked))))
```

- [ ] **Step 10: Link closed, resource events**

Replace

```swift
            case let .endpoint(.delegate(.linkClosed(linkID, _))):
                state.linkDestinations[linkID] = nil
```

with

```swift
            case let .endpoint(.delegate(.linkClosed(linkID, _))):
                state.linkDestinations[linkID] = nil
                state.outboundTransfers[linkID] = nil
                state.inboundProgress[linkID] = nil
```

Replace

```swift
            case let .endpoint(.delegate(.resourceReceived(linkID, data))):
                guard !isServedPropagationLink(state, linkID) else { return .none }
                return .send(.router(.received(method: .direct, destinationHash: Data(), data: data)))

            case let .endpoint(.delegate(.resourceConcluded(linkID, _))):
                return .send(.router(.resourceDeliveredOnLink(linkID: linkID)))
```

with

```swift
            case let .endpoint(.delegate(.resourceReceived(linkID, data))):
                state.inboundProgress[linkID] = nil
                guard !isServedPropagationLink(state, linkID) else { return .none }
                return .send(.router(.received(method: .direct, destinationHash: Data(), data: data)))

            case let .endpoint(.delegate(.resourceConcluded(linkID, hash))):
                // Only OUR transfer on that link resolves the copy (Review Focus 1).
                guard state.outboundTransfers[linkID] == hash else { return .none }
                state.outboundTransfers[linkID] = nil
                return .send(.router(.resourceDeliveredOnLink(linkID: linkID)))

            case let .endpoint(.delegate(.resourceFailed(linkID, hash, rejected))):
                guard state.outboundTransfers[linkID] == hash else {
                    state.inboundProgress[linkID] = nil          // an inbound transfer failed
                    return .none
                }
                state.outboundTransfers[linkID] = nil
                return .send(.router(.resourceFailedOnLink(linkID: linkID, rejected: rejected)))

            case let .endpoint(.delegate(.resourceProgress(linkID, hash, role, done, total, segment, segments))):
                let activity = Effect<Action>.send(.router(.linkActivity(linkID: linkID)))
                switch role {
                case .sender:
                    guard let key = state.router.linkResourceInFlight[linkID] else { return .none }
                    if state.outboundTransfers[linkID] == nil { state.outboundTransfers[linkID] = hash }
                    guard state.outboundTransfers[linkID] == hash else { return .none }
                    let fraction = LXMFNode.outboundFraction(bytesDone: done, bytesTotal: total,
                                                             segment: segment, segments: segments)
                    return .merge(reportProgress(&state, key, fraction), activity)
                case .receiver:
                    guard !isServedPropagationLink(state, linkID) else { return activity }
                    let fraction = LXMFNode.transferFraction(bytesDone: done, bytesTotal: total,
                                                             segment: segment, segments: segments)
                    if let last = state.inboundProgress[linkID], fraction <= last { return activity }
                    state.inboundProgress[linkID] = fraction
                    let terminus = state.linkDestinations[linkID]
                    let source = terminus == state.deliveryDestinationHash
                        || terminus == state.propagationDestinationHash ? nil : terminus
                    return .merge(.send(.delegate(.inboundTransferProgress(sourceHash: source, linkID: linkID,
                                                                           fraction: fraction))),
                                  activity)
                }
```

- [ ] **Step 11: Run the tests**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter nodeTransfer --filter lxmfNodeDirectDeliversResourceAndConfirms --filter lxmfNodeSendsViaPropagationNodeAndConfirmsAccept --filter lxmfNodeCancels --filter Stamp`
Expected: all PASS. `lxmfNodeDirectDeliversResourceAndConfirms` and `lxmfNodeSendsViaPropagationNodeAndConfirmsAccept` are the existing real-Resource end-to-end tests: they now confirm through the recorded hash, which proves the sender's first progress event reaches the node before the conclusion.

- [ ] **Step 12: Mutation batch (apply all at once)**

1. `LXMFNode.transferFraction`: `(Double(index - 1) + within) / Double(segments)` → `within` → RED `nodeTransferFractionsFollowTheReferenceFormula`.
2. `.sendDirect` handler: `started = reportProgress(&state, key, LXMFNode.linkActiveProgress)` → delete the line → RED `nodeTransferProgressFollowsTheReferenceScale` (no 0.05).
3. `reportProgress`: delete `if let last = state.transferProgress[key], clamped <= last { return .none }` → RED `nodeTransferProgressIsMonotonicPerCopy` (the lower value is reported inside the exhaustive window).
4. `reportProgress`: swap the ternary branches (`.propagationProgress` for `.delivery`) → RED `nodeTransferPropagatedCopyReportsPropagationProgress`. (Also reddens scale/monotonic; each has its own mutation.)
5. Receiver branch: `let source = ... ? nil : terminus` → `let source = terminus` → RED `nodeTransferInboundProgressIsKeyedByTheLinkDestination`.
6. `.resourceConcluded`: delete `guard state.outboundTransfers[linkID] == hash else { return .none }` → RED `nodeTransferStaleConclusionForAnotherResourceIsIgnored`.
7. `.resourceFailed`: `guard state.outboundTransfers[linkID] == hash else {` → `guard true else {` → RED `nodeTransferInboundFailureDoesNotFailTheOutboundCopy`.
8. `.resourceFailed`: `rejected: rejected` → `rejected: false` → RED `nodeTransferOutboundFailureReachesTheRouter`.
9. `.router(.delegate(.cancelResource))`: body → `return .none` → RED `nodeTransferCancelOutboundCancelsTheResourceByHash`.
10. `.cancelOutbound`: delete the `if wasSearching && !routerReports { ... }` block → RED `nodeTransferCancelOutboundDuringADeliveryStampSearchReportsCancelled`.
11. `.cancelOutbound`: delete `.cancel(id: CancelID.propagationStampFor(hash)),` → RED `nodeTransferCancelOutboundStopsThePropagationStampSearch` (`finish` times out after 10 s).
12. Router `.linkActivity`: body → `return .none` → RED `nodeTransferLinkActivityReArmsTheIdleTimer` (the link idles out at 600 s).

Mutation 7 turns the failure guard into a no-op rather than inverting it, so the outbound path (test 8) still runs; mutation 3 does not affect the exhaustive windows of tests 6/7 (no lower progress is sent there). Run the Step 11 command: every `nodeTransfer*` test FAILS. Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 13: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --no-parallel > /tmp/ReTiCaMsgr/tad-t6-full.log`
Expected: all pass with the 1 known issue; count = Task 5 count + 12.

- [ ] **Step 14: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery add Sources/ReTiCANode/LXMFRouter.swift Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFNodeTransferMappingTests.swift`

Write `/tmp/ReTiCaMsgr/msg-tad-task-6.txt`:

```
feat: LXMFNode reports transfer progress and outcomes and cancels messages

The node learns which resource hash is its own transfer on each link,
so a conclusion or failure for any other transfer there cannot resolve
the copy in flight. It reports delivery and propagation progress on the
reference scale, inbound transfer progress, rejection and cancellation,
cancels one message including its stamp searches, and forwards transfer
activity so the router's idle timer is re-armed.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery commit -F /tmp/ReTiCaMsgr/msg-tad-task-6.txt`

---
### Task 7: Propagation-node fixes — pending marker and oversize refusal

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (State: `pendingPropagatedCopies`; `RefusalReason`; actions; delegate; `isOutstanding` :279-287; `fail`; `.sendViaPropagation`; `.cancelOutbound`; `hasOutboundState`; three new cases)
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (Delegate; `.setPropagationNode` :434-441; `.sendMessage` :484-495; `.cancelPropagationStamps` :501-507; outcome mapping; new `propagationTransferLimitBytes` helper after `propagationStampCost` :848-855)
- Create: `Tests/ReTiCANodeTests/LXMFPropagatedCopyTests.swift`

**Interfaces:**
- Consumes: T3 `fail(_:_:reason:)`, T5 `cancelledMessages`, `hasOutboundState(for:)`, `.cancelOutbound`; T6 `CancelID.propagationStampFor`, `clearProgress`.
- Produces:
  - `LXMFRouter.RefusalReason: Equatable, Sendable { case tooLargeForNode }`.
  - `LXMFRouter.State.pendingPropagatedCopies: Set<Data>` — hashes whose propagated copy is in `LXMFNode`'s stamp search; `isOutstanding(_, hash, .propagated)` counts them.
  - `LXMFRouter.Action.propagatedCopyPending(messageHash:)`, `.propagatedCopyRefused(messageHash:reason:)`, `.abandonPendingPropagatedCopies` (fails every marked copy through `fail`).
  - `LXMFRouter.Action.Delegate.propagationRefused(messageHash: Data, reason: RefusalReason)` and the same case on `LXMFNode.Action.Delegate`.
- Semantics: the marker is set when `.sendMessage(alsoViaPropagation: true)` starts the PN stamp search and cleared by arming (`.sendViaPropagation`), by `fail` of the propagated copy, by `.cancelOutbound`, and — through `.abandonPendingPropagatedCopies` — by `.cancelPropagationStamps` and `.setPropagationNode`. A refused copy is never started; the refusal only reports `propagationRefused` and leaves the message's fate to its delivery copy. The limit is the configured node's announced `perTransferLimit × 1000` bytes, compared with `message.packed.count`; a limit of 0 or less, or no parseable announce, is "unknown" and the copy is attempted as before.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFPropagatedCopyTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Transfer-aware delivery, Task 7: the propagated copy counts as outstanding while its stamp is
// searched (the false "failed" of the proofs work, Amendment 3), and a copy larger than the node
// accepts is refused up front instead of failing after five tries.

private let dest = Data(repeating: 0xD5, count: 16)
private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let small = Data("small-container".utf8)

private func note() -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                     title: Data("t".utf8), content: Data("both ways".utf8))
}

@MainActor
private func routerStore(_ state: LXMFRouter.State, _ clock: TestClock<Duration> = TestClock())
    -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

/// Drive the delivery copy (opportunistic, path known) to the retry that exhausts it, leaving the
/// store exhaustive just before that retry is received.
@MainActor
private func exhaustTheDeliveryCopy(_ store: TestStore<LXMFRouter.State, LXMFRouter.Action>,
                                    _ clock: TestClock<Duration>, _ m: LXMessage) async {
    for _ in 0..<(LXMFDelivery.maxAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive(.retryDue(messageHash: m.hash, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(m.hash)] = nil
    }
}

@Test @MainActor func pnCopyPendingMarkerKeepsTheMessageAlive() async {
    let m = note()
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.knownPaths.insert(dest)
    let store = routerStore(state, clock)
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.send(.propagatedCopyPending(messageHash: m.hash))
    await exhaustTheDeliveryCopy(store, clock, m)
    await store.send(.retryDue(messageHash: m.hash, leg: .delivery))   // probe: a stray deliveryFailed fails here
}

@Test @MainActor func pnCopyAbandonedMarkerFailsTheMessageOnce() async {
    let m = note()
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.knownPaths.insert(dest)
    let store = routerStore(state, clock)
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.send(.propagatedCopyPending(messageHash: m.hash))
    await exhaustTheDeliveryCopy(store, clock, m)
    await store.send(.abandonPendingPropagatedCopies) {
        $0.pendingPropagatedCopies = []
    }
    await store.receive(.delegate(.deliveryFailed(messageHash: m.hash)))
    await store.send(.abandonPendingPropagatedCopies)                 // probe: nothing left, nothing again
}

@Test @MainActor func pnCopyArmingClearsTheMarker() async {
    let m = note()
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    let store = routerStore(state)
    await store.send(.propagatedCopyPending(messageHash: m.hash))
    #expect(store.state.pendingPropagatedCopies == [m.hash])
    await store.send(.sendViaPropagation(message: m, propagationPacked: small))
    #expect(store.state.pendingPropagatedCopies.isEmpty)
    #expect(store.state.pendingDeliveries[.propagated(m.hash)] != nil)
}

@Test @MainActor func pnCopyRefusedReportsAndTheDeliveryCopyStillConfirms() async {
    let m = note()
    var state = LXMFRouter.State()
    state.knownPaths.insert(dest)
    let store = routerStore(state)
    await store.send(.send(message: m, desiredMethod: .opportunistic))
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await store.send(.propagatedCopyRefused(messageHash: m.hash, reason: .tooLargeForNode))
    await store.receive(.delegate(.propagationRefused(messageHash: m.hash, reason: .tooLargeForNode)))
    await store.send(.opportunisticDelivered(messageHash: m.hash)) {
        $0.pendingDeliveries[.delivery(m.hash)] = nil
        $0.succeededMessages.insert(m.hash)
    }
    await store.receive(.delegate(.deliveryConfirmed(messageHash: m.hash)))
}

@Test @MainActor func pnCopyCancelOutboundClearsTheMarker() async {
    let m = note()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.propagatedCopyPending(messageHash: m.hash)) {
        $0.pendingPropagatedCopies = [m.hash]
    }
    await store.send(.cancelOutbound(messageHash: m.hash)) {
        $0.pendingPropagatedCopies = []
        $0.cancelledMessages.insert(m.hash)
    }
    await store.receive(.delegate(.deliveryCancelled(messageHash: m.hash)))
    await store.send(.propagatedCopyPending(messageHash: m.hash))    // a cancelled message is not re-marked
}

// MARK: - LXMFNode

@MainActor
private func pnNode(limitKB: Int, stampCost: Int) -> (TestStore<LXMFNode.State, LXMFNode.Action>, Identity) {
    let recipient = Identity()
    var state = LXMFNode.State(identity: Identity(),
                               endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    state.endpoint.transport.learned[dest] = LearnedDestination(
        identity: recipient, appData: nil, ratchet: nil, interfaceID: InterfaceID("tcp"),
        hops: 1, nextHop: nil, announceEmitted: 0)
    state.endpoint.transport.learned[pn] = LearnedDestination(
        identity: Identity(),
        appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: limitKB, perSyncLimit: limitKB,
                            targetStampCost: stampCost, stampCostFlexibility: 0, peeringCost: 0).packed,
        ratchet: nil, interfaceID: InterfaceID("tcp"), hops: 1, nextHop: nil, announceEmitted: 0)
    state.router.outboundPropagationNode = pn
    state.router.knownPaths.insert(dest)
    let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return (store, recipient)
}

@Test @MainActor func pnCopyNodeRefusesAnOversizeMessageUpFront() async {
    let (store, _) = pnNode(limitKB: 1, stampCost: 4)
    let m = LXMessage.create(source: Identity(), destinationHash: dest, timestamp: 1700000000.5,
                             title: Data(), content: Data(repeating: 0x41, count: 2000))
    #expect(m.packed.count > 1000)
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    await store.receive(.router(.propagatedCopyRefused(messageHash: m.hash, reason: .tooLargeForNode)))
    await store.receive(.delegate(.propagationRefused(messageHash: m.hash, reason: .tooLargeForNode)))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)      // no search was started for it
    #expect(store.state.router.outboundQueue[dest]?.count == 1)      // the delivery copy proceeds
}

/// Review Focus 7: every existing fixture announces `perTransferLimit: 0`. That is "unknown", not
/// "nothing fits": the copy is attempted, and marked pending while its stamp is searched.
@Test @MainActor func pnCopyNodeMarksTheCopyPendingWhileItsStampIsSearched() async {
    let (store, _) = pnNode(limitKB: 0, stampCost: 4)
    let m = note()
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    #expect(store.state.router.pendingPropagatedCopies == [m.hash])
    await store.receive { if case let .router(.sendViaPropagation(sent, _)) = $0 { return sent.hash == m.hash }; return false }
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
    #expect(store.state.router.propagationQueue[pn]?.count == 1)
}

@Test @MainActor func pnCopyNodeAttemptsAMessageWithinTheLimit() async {
    let (store, _) = pnNode(limitKB: 1000, stampCost: 4)
    let m = note()
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    await store.receive { if case let .router(.sendViaPropagation(sent, _)) = $0 { return sent.hash == m.hash }; return false }
}

@Test @MainActor func pnCopyNodeCancelPropagationStampsFailsTheMarkedCopy() async {
    let (store, _) = pnNode(limitKB: 0, stampCost: LXMFPropagation.maxPropagationStampCost)
    let m = note()
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    #expect(store.state.router.pendingPropagatedCopies == [m.hash])
    await store.send(.cancelPropagationStamps)
    await store.receive(.router(.abandonPendingPropagatedCopies))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
    #expect(store.state.router.pendingDeliveries[.delivery(m.hash)] != nil)   // so no failure is reported yet
}

@Test @MainActor func pnCopyNodeChangingThePropagationNodeFailsTheMarkedCopy() async {
    let (store, _) = pnNode(limitKB: 0, stampCost: LXMFPropagation.maxPropagationStampCost)
    let m = note()
    await store.send(.sendMessage(message: m, alsoViaPropagation: true))
    await store.send(.setPropagationNode(destinationHash: Data(repeating: 0xC1, count: 16)))
    await store.receive(.router(.abandonPendingPropagatedCopies))
    #expect(store.state.router.pendingPropagatedCopies.isEmpty)
}
```

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter pnCopy`
Expected: FAIL to compile — no `propagatedCopyPending`, `pendingPropagatedCopies`, `propagationRefused`.

- [ ] **Step 3: Router types, state, actions, delegate**

In `Sources/ReTiCANode/LXMFRouter.swift`:

Replace

```swift
        var cancelledMessages = RingSet(capacity: LXMFRouter.succeededMessageMemory)
```

with

```swift
        var cancelledMessages = RingSet(capacity: LXMFRouter.succeededMessageMemory)
        /// Message hashes whose propagated copy is still in `LXMFNode`'s stamp search, so not yet
        /// handed over. `isOutstanding` counts them: without this, the delivery copy running out first
        /// reported `deliveryFailed` for a message whose propagated copy was about to go out
        /// (2026-09-26 single-packet proofs spec, Amendment 3).
        public var pendingPropagatedCopies: Set<Data> = []
```

Replace

```swift
    /// Why a copy failed for good; the terminal delegate says which.
    enum FailureReason: Equatable { case exhausted, rejected }
```

with

```swift
    /// Why a copy failed for good; the terminal delegate says which.
    enum FailureReason: Equatable { case exhausted, rejected }
    /// Why a propagated copy was not attempted at all.
    public enum RefusalReason: Equatable, Sendable {
        /// Larger than the propagation node's announced per-transfer limit.
        case tooLargeForNode
    }
```

Replace

```swift
        case linkActivity(linkID: Data)
        case retryDue(messageHash: Data, leg: Leg)
```

with

```swift
        case linkActivity(linkID: Data)
        /// `LXMFNode` started the stamp search for this message's propagated copy.
        case propagatedCopyPending(messageHash: Data)
        /// `LXMFNode` did not start this message's propagated copy at all (spec §6).
        case propagatedCopyRefused(messageHash: Data, reason: RefusalReason)
        /// Every propagated-copy stamp search was cancelled: those copies have failed.
        case abandonPendingPropagatedCopies
        case retryDue(messageHash: Data, leg: Leg)
```

Replace

```swift
            /// Cancel our Resource in flight on `linkID` (its copy was cancelled).
            case cancelResource(linkID: Data)
        }
```

with

```swift
            /// Cancel our Resource in flight on `linkID` (its copy was cancelled).
            case cancelResource(linkID: Data)
            /// The propagated copy was not attempted. Not terminal: the delivery copy decides.
            case propagationRefused(messageHash: Data, reason: RefusalReason)
        }
```

- [ ] **Step 4: Router logic**

In `isOutstanding`, replace

```swift
                case .propagated:
                    return state.propagationQueue.values.contains { $0.contains { $0.messageHash == hash } }
```

with

```swift
                case .propagated:
                    return state.pendingPropagatedCopies.contains(hash)
                        || state.propagationQueue.values.contains { $0.contains { $0.messageHash == hash } }
```

In `fail`, replace

```swift
            func fail(_ state: inout State, _ key: DeliveryKey, reason: FailureReason = .exhausted) -> Effect<Action> {
                state.pendingDeliveries[key] = nil
```

with

```swift
            func fail(_ state: inout State, _ key: DeliveryKey, reason: FailureReason = .exhausted) -> Effect<Action> {
                state.pendingDeliveries[key] = nil
                if key.leg == .propagated { state.pendingPropagatedCopies.remove(key.messageHash) }
```

In `.sendViaPropagation`, replace

```swift
            case let .sendViaPropagation(message, propagationPacked):
                guard !state.cancelledMessages.contains(message.hash) else { return .none }
```

with

```swift
            case let .sendViaPropagation(message, propagationPacked):
                state.pendingPropagatedCopies.remove(message.hash)       // handed over: armed or failed below
                guard !state.cancelledMessages.contains(message.hash) else { return .none }
```

In `.cancelOutbound`, replace

```swift
                state.cancelledMessages.insert(hash)
                guard hadWork else { return .none }
```

with

```swift
                state.cancelledMessages.insert(hash)
                state.pendingPropagatedCopies.remove(hash)
                guard hadWork else { return .none }
```

In `hasOutboundState(for:)`, replace

```swift
            || propagationQueue.values.contains { $0.contains { $0.messageHash == messageHash } }
    }
```

with

```swift
            || propagationQueue.values.contains { $0.contains { $0.messageHash == messageHash } }
            || pendingPropagatedCopies.contains(messageHash)
    }
```

Insert directly before `            case let .retryDue(hash, leg):`:

```swift
            case let .propagatedCopyPending(hash):
                guard !state.cancelledMessages.contains(hash) else { return .none }
                state.pendingPropagatedCopies.insert(hash)
                return .none

            case let .propagatedCopyRefused(hash, reason):
                // Never started, so there is nothing to fail: the delivery copy's own outcome decides
                // the message. Running `fail` here could report `deliveryFailed` while the delivery copy
                // is still in ITS stamp search, which the router cannot see.
                state.pendingPropagatedCopies.remove(hash)
                return .send(.delegate(.propagationRefused(messageHash: hash, reason: reason)))

            case .abandonPendingPropagatedCopies:
                let abandoned = state.pendingPropagatedCopies.sorted { $0.lexicographicallyPrecedes($1) }
                state.pendingPropagatedCopies = []
                var effects: [Effect<Action>] = []
                for hash in abandoned { effects.append(fail(&state, .propagated(hash))) }
                return .merge(effects)

```

- [ ] **Step 5: Node**

In `Sources/ReTiCANode/LXMFNode.swift`:

Replace

```swift
            case inboundTransferProgress(sourceHash: Data?, linkID: Data, fraction: Double)
        }
```

with

```swift
            case inboundTransferProgress(sourceHash: Data?, linkID: Data, fraction: Double)
            /// The propagated copy was not attempted — `.tooLargeForNode`: larger than the configured
            /// node's announced per-transfer limit. The delivery copy is unaffected.
            case propagationRefused(messageHash: Data, reason: LXMFRouter.RefusalReason)
        }
```

Replace

```swift
                return .merge(.cancel(id: CancelID.propagationStamp),
                              .send(.router(.setOutboundPropagationNode(destinationHash))))
```

with

```swift
                // The copies whose searches this abandons have failed (through the router's `fail`,
                // so a message whose delivery copy is still pending is not reported failed).
                let abandon: Effect<Action> = state.router.pendingPropagatedCopies.isEmpty
                    ? .none : .send(.router(.abandonPendingPropagatedCopies))
                return .merge(.cancel(id: CancelID.propagationStamp), abandon,
                              .send(.router(.setOutboundPropagationNode(destinationHash))))
```

Replace

```swift
                if alsoViaPropagation,
                   let recipient = state.endpoint.learned[message.destinationHash]?.identity,
                   let cost = propagationStampCost(state) {
                    let ts = date.now.timeIntervalSince1970
                    effects.append(.run { send in
                        guard let (packed, _) = await LXMFPropagation.pack(
                            message: message, recipientIdentity: recipient, timestamp: ts, stampCost: cost)
                        else { return }                              // cancelled mid-search
                        await send(.router(.sendViaPropagation(message: message, propagationPacked: packed)))
                    }
                    .cancellable(id: CancelID.propagationStampFor(message.hash))
                    .cancellable(id: CancelID.propagationStamp))
                }
```

with

```swift
                if alsoViaPropagation,
                   let recipient = state.endpoint.learned[message.destinationHash]?.identity,
                   let cost = propagationStampCost(state) {
                    if let limit = propagationTransferLimitBytes(state), message.packed.count > limit {
                        // Spec §6: the node would refuse it, so the copy is not attempted at all.
                        effects.append(.send(.router(.propagatedCopyRefused(messageHash: message.hash,
                                                                            reason: .tooLargeForNode))))
                    } else {
                        // Outstanding from now on, although the router only gets the copy once its
                        // stamp is found (spec §6).
                        effects.append(.send(.router(.propagatedCopyPending(messageHash: message.hash))))
                        let ts = date.now.timeIntervalSince1970
                        effects.append(.run { send in
                            guard let (packed, _) = await LXMFPropagation.pack(
                                message: message, recipientIdentity: recipient, timestamp: ts, stampCost: cost)
                            else { return }                          // cancelled mid-search
                            await send(.router(.sendViaPropagation(message: message, propagationPacked: packed)))
                        }
                        .cancellable(id: CancelID.propagationStampFor(message.hash))
                        .cancellable(id: CancelID.propagationStamp))
                    }
                }
```

Replace

```swift
                return .cancel(id: CancelID.propagationStamp)

            case .cancelDeliveryStamps:
```

with

```swift
                // ...and the copies those searches were for have failed, through the router's `fail`.
                let abandon: Effect<Action> = state.router.pendingPropagatedCopies.isEmpty
                    ? .none : .send(.router(.abandonPendingPropagatedCopies))
                return .merge(.cancel(id: CancelID.propagationStamp), abandon)

            case .cancelDeliveryStamps:
```

Replace

```swift
            case let .router(.delegate(.cancelResource(linkID))):
```

with

```swift
            case let .router(.delegate(.propagationRefused(hash, reason))):
                state.transferProgress[.propagated(hash)] = nil
                return .send(.delegate(.propagationRefused(messageHash: hash, reason: reason)))

            case let .router(.delegate(.cancelResource(linkID))):
```

After the `propagationStampCost` function (after its closing `    }`), add:

```swift

    /// The configured propagation node's per-transfer limit in bytes, or nil when unknown.
    ///
    /// Reference expresses these limits in KB and compares byte sizes against `limit * 1000`
    /// (LXMRouter.py:1528, `client_transfer_limit = float(data[2])*1000`). A limit of 0 or less is
    /// treated as UNKNOWN rather than "nothing fits": no working node announces it (it would refuse
    /// every message), while test fixtures and minimal announces do, and the spec's rule for an
    /// unknown limit is to attempt the copy as before. The product is overflow-checked because the
    /// field is unauthenticated wire input.
    private func propagationTransferLimitBytes(_ state: State) -> Int? {
        guard let pn = state.router.outboundPropagationNode,
              let appData = state.endpoint.learned[pn]?.appData,
              let ann = PNAnnounce.parse(appData), ann.perTransferLimit > 0
        else { return nil }
        let (bytes, overflow) = ann.perTransferLimit.multipliedReportingOverflow(by: 1000)
        return overflow ? nil : bytes
    }
```

- [ ] **Step 6: Run the tests**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter pnCopy --filter copyOutcome --filter sendMessage --filter lxmfNodeCancels --filter lxmfNodeSendMessageRefuses --filter routerCancel --filter nodeTransfer`
Expected: all PASS.

- [ ] **Step 7: Mutation batch (apply all at once)**

1. `isOutstanding` `.propagated`: delete `state.pendingPropagatedCopies.contains(hash) ||` → RED `pnCopyPendingMarkerKeepsTheMessageAlive` (the exhausting retry emits `deliveryFailed`).
2. `.abandonPendingPropagatedCopies`: delete the `for hash in abandoned { ... }` loop → RED `pnCopyAbandonedMarkerFailsTheMessageOnce`.
3. `.sendViaPropagation`: delete `state.pendingPropagatedCopies.remove(message.hash)` → RED `pnCopyArmingClearsTheMarker`, `pnCopyNodeMarksTheCopyPendingWhileItsStampIsSearched`.
4. `.propagatedCopyRefused`: body → `return .none` → RED `pnCopyRefusedReportsAndTheDeliveryCopyStillConfirms`, `pnCopyNodeRefusesAnOversizeMessageUpFront`.
5. `hasOutboundState`: delete `|| pendingPropagatedCopies.contains(messageHash)` → RED `pnCopyCancelOutboundClearsTheMarker` (no `deliveryCancelled`; the marker is still cleared by the cancel, so the state assertion holds and the missing delegate is what fails).
6. Node `.sendMessage`: `if let limit = propagationTransferLimitBytes(state), message.packed.count > limit {` → `if false {` → RED `pnCopyNodeRefusesAnOversizeMessageUpFront` (also reddened by 4; 6 is visible on its own there because 4 only removes the router's report, while 6 removes the refused action the test receives first).
7. `propagationTransferLimitBytes`: delete `, ann.perTransferLimit > 0` → RED `pnCopyNodeMarksTheCopyPendingWhileItsStampIsSearched` (limit 0 → every copy refused).
8. Node `.sendMessage`: delete the `effects.append(.send(.router(.propagatedCopyPending(...))))` line → RED `pnCopyNodeMarksTheCopyPendingWhileItsStampIsSearched`, `pnCopyNodeCancelPropagationStampsFailsTheMarkedCopy`, `pnCopyNodeChangingThePropagationNodeFailsTheMarkedCopy`.
9. Node `.cancelPropagationStamps`: `return .merge(.cancel(id: CancelID.propagationStamp), abandon)` → `return .cancel(id: CancelID.propagationStamp)` → RED `pnCopyNodeCancelPropagationStampsFailsTheMarkedCopy`.
10. Node `.setPropagationNode`: drop `abandon,` from the merge → RED `pnCopyNodeChangingThePropagationNodeFailsTheMarkedCopy`.
None of 1-10 traps. Run the Step 6 filter: every `pnCopy*` test except `pnCopyNodeAttemptsAMessageWithinTheLimit` FAILS. Revert all ten by hand.

**Step 7b — second, single-mutation batch** for `pnCopyNodeAttemptsAMessageWithinTheLimit`, which needs the size comparison itself to be wrong (mutation 6 disables the whole branch, so the two cannot share a batch): in `.sendMessage` change `message.packed.count > limit` to `message.packed.count > 0`. Run `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter pnCopyNodeAttemptsAMessageWithinTheLimit`: it FAILS (the small message is refused). Revert by hand, check `git -C WT diff` shows only this task's changes, run the Step 6 filter: all PASS.

- [ ] **Step 8: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --no-parallel > /tmp/ReTiCaMsgr/tad-t7-full.log`
Expected: all pass with the 1 known issue; count = Task 6 count + 10.

- [ ] **Step 9: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery add Sources/ReTiCANode/LXMFRouter.swift Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFPropagatedCopyTests.swift`

Write `/tmp/ReTiCaMsgr/msg-tad-task-7.txt`:

```
fix: the propagated copy counts while its stamp is searched, and oversize copies are refused

sendMessage marks the propagated copy pending when its stamp search
starts, so the delivery copy running out no longer reports a false
deliveryFailed. Cancelling propagation stamps or changing the node
fails the marked copies through the router. A message larger than the
node's announced per-transfer limit is not sent to it at all and is
reported as propagationRefused. A limit of 0 counts as unknown.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery commit -F /tmp/ReTiCaMsgr/msg-tad-task-7.txt`

---
### Task 8: End to end over two nodes, including a slow link

**Files:**
- Create: `Tests/ReTiCANodeTests/LXMFNodeTransferEndToEndTests.swift`

**Interfaces:**
- Consumes: everything above, through `LXMFNode`'s public surface plus `@testable` state reads (`router.pendingDeliveries`, `router.succeededMessages`, `router.seen`, `router.linkResourceInFlight`, `router.pendingPropagatedCopies`, `transferProgress`, `inboundProgress`, `endpoint.links`).
- Produces: nothing new. The harness (`TransferPair`) is file-private to this test file.

**Harness notes (read before running):** two `LXMFNode`s over mocked TCP, as in `LXMFNodeSinglePacketProofEndToEndTests.swift`, plus a `pump` that forwards every frame either node writes. A 3 MB Resource is ~6 800 part frames in three segments, and `TestStore` keeps a state snapshot for every received action, so the pump drops each store's received actions every 50 rounds — except once the outcome that store is waiting for has happened (`keepA`/`keepB`), so the test can still `receive` it. `\.date` follows the shared `TestClock` so a link's measured RTT is test-clock time: with a 100 ms delay on every B→A frame the RTT is 0.1 s, every request round costs 0.1 s, and the 3 MB transfer spans ~70 s of test-clock time — past the 50 s at which the old router failed a Resource copy — while each round stays well inside the receiver's watchdog (≥ 0.45 s) and the sender's (≥ 10 s). Expect the two 3 MB tests to take a few minutes each in real time (the 1 MB `twoEndpointsTransferMultiSegmentResourceOverALink` takes ~33 s); they carry a 10-minute time limit.

- [ ] **Step 1: Write the tests**

Create `Tests/ReTiCANodeTests/LXMFNodeTransferEndToEndTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Transfer-aware delivery end to end: two LXMFNodes over mocked TCP (the harness of
// LXMFNodeSinglePacketProofEndToEndTests), with a pump that forwards every frame either node writes.

/// SHA-256-derived bytes: bzip2 cannot shrink them, so a 3 MB payload really is three segments.
private func transferIncompressible(count: Int) -> Data {
    var result = Data()
    result.reserveCapacity(count)
    var i = 0
    while result.count < count {
        let chunk = Crypto.fullHash(Data([0x3E, UInt8(i & 0xff), UInt8((i >> 8) & 0xff), UInt8((i >> 16) & 0xff)]))
        result.append(contentsOf: chunk.prefix(min(chunk.count, count - result.count)))
        i += 1
    }
    return result
}

@MainActor
private func nextFrame(_ sent: LockIsolated<[Data]>, after count: Int) async -> Data {
    for _ in 0..<1_000 where sent.value.count <= count { await Task.yield() }
    #expect(sent.value.count == count + 1, "expected exactly one new frame")
    return sent.value.last ?? Data()
}

private func isTCPSend(_ action: LXMFNode.Action) -> Bool {
    if case .endpoint(.tcpClient(.interface(.send))) = action { return true }
    return false
}

@MainActor
private final class TransferPair {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let sentA = LockIsolated<[Data]>([])
    let sentB = LockIsolated<[Data]>([])
    var a: TestStore<LXMFNode.State, LXMFNode.Action>!
    var b: TestStore<LXMFNode.State, LXMFNode.Action>!
    var eventsA: AsyncStream<TCPEvent>.Continuation!
    var eventsB: AsyncStream<TCPEvent>.Continuation!
    /// How many frames of each node's output the pump has delivered to the other.
    var forwardedA = 0
    var forwardedB = 0

    var bDeliveryHash: Data { LXMessage.deliveryHash(identityHash: bIdentity.hash) }

    init(configureA: (inout LXMFNode.State) -> Void = { _ in }) {
        let nodeA = TransferPair.makeNode("a", aIdentity, sentA, clock, configureA)
        a = nodeA.0
        eventsA = nodeA.1
        let nodeB = TransferPair.makeNode("b", bIdentity, sentB, clock, { _ in })
        b = nodeB.0
        eventsB = nodeB.1
    }

    private static func makeNode(_ host: String, _ identity: Identity, _ sent: LockIsolated<[Data]>,
                                 _ clock: TestClock<Duration>, _ configure: (inout LXMFNode.State) -> Void)
        -> (TestStore<LXMFNode.State, LXMFNode.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        var state = LXMFNode.State(identity: identity,
                                   endpoint: TCPEndpoint.State(host: host, port: 4242, reconnectOnDrop: false))
        configure(&state)
        let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            // Wall time follows the test clock, so a link's measured RTT is test-clock time.
            $0.date = DateGenerator {
                let (seconds, attoseconds) = TestClock<Duration>.Instant().duration(to: clock.now).components
                return Date(timeIntervalSince1970: 1700000000.5 + Double(seconds) + Double(attoseconds) / 1e18)
            }
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    /// Start both nodes, register both delivery destinations, and hand each announce to the other.
    func connectAndIntroduce() async {
        await a.send(.endpoint(.start)); eventsA.yield(.connected)
        await b.send(.endpoint(.start)); eventsB.yield(.connected)
        await a.send(.registerDelivery)
        await a.receive(isTCPSend)
        let aAnnounce = await nextFrame(sentA, after: 0)
        await b.send(.registerDelivery)
        await b.receive(isTCPSend)
        let bAnnounce = await nextFrame(sentB, after: 0)
        eventsA.yield(.data(bAnnounce))
        await a.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }
        eventsB.yield(.data(aAnnounce))
        await b.receive { if case .endpoint(.delegate(.pathLearned)) = $0 { return true }; return false }
        forwardedA = sentA.value.count
        forwardedB = sentB.value.count
    }

    /// A message from A to B carrying `bytes` as a file-attachment field (LXMF field 5).
    func attachmentMessage(bytes: Data) -> LXMessage {
        LXMessage.create(source: aIdentity, destinationHash: bDeliveryHash, timestamp: 1700000000.5,
                         title: Data("file".utf8), content: Data("see attachment".utf8),
                         fields: [.init(5, .array([.array([.string("blob.bin"), .bin(bytes)])]))])
    }

    /// Deliver every frame either node has written to the other, oldest first, until `done()` holds.
    /// `bToADelay` is advanced on the shared clock before each B→A frame (B's requests and proofs),
    /// so every request round costs that much test-clock time. Returns false if nothing moved for
    /// 200 idle rounds (a stalled transfer), true once `done()` holds.
    func pump(bToADelay: Duration = .zero,
              keepA: () -> Bool = { false }, keepB: () -> Bool = { false },
              sample: () -> Void = {}, until done: () -> Bool) async -> Bool {
        var idle = 0
        var rounds = 0
        while !done() {
            var moved = false
            while forwardedA < sentA.value.count {
                let frame = sentA.value[forwardedA]
                forwardedA += 1
                eventsB.yield(.data(frame))
                moved = true
                await Task.megaYield()
            }
            while forwardedB < sentB.value.count {
                let frame = sentB.value[forwardedB]
                forwardedB += 1
                if bToADelay > .zero { await clock.advance(by: bToADelay) }
                eventsA.yield(.data(frame))
                moved = true
                await Task.megaYield()
            }
            sample()
            rounds += 1
            if rounds % 50 == 0 {
                if !keepA() { await a.skipReceivedActions(strict: false) }
                if !keepB() { await b.skipReceivedActions(strict: false) }
            }
            if moved {
                idle = 0
            } else {
                idle += 1
                if idle > 200 { return false }
                await Task.megaYield()
            }
        }
        return true
    }

    func stop() async {
        await a.send(.endpoint(.stop))
        await b.send(.endpoint(.stop))
    }
}

@Test(.timeLimit(.minutes(10))) @MainActor func transferEndToEndThreeMegabytesConfirmWithMonotonicProgress() async {
    let p = TransferPair()
    await p.connectAndIntroduce()
    let msg = p.attachmentMessage(bytes: transferIncompressible(count: 3_000_000))
    #expect(msg.packed.count > 2 * LinkSession.maxEfficientSize)          // three segments
    let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))
    var outbound: [Double] = []
    var inbound: [Double] = []
    var attempts = 0
    let finished = await p.pump(
        keepA: { p.a.state.router.pendingDeliveries[key] == nil },
        keepB: { p.b.state.router.seen.contains(msg.hash) },
        sample: {
            if let f = p.a.state.transferProgress[key], f != outbound.last { outbound.append(f) }
            if let f = p.b.state.inboundProgress.values.first, f != inbound.last { inbound.append(f) }
            attempts = max(attempts, p.a.state.router.pendingDeliveries[key]?.attempts ?? 0)
        },
        until: { p.a.state.router.pendingDeliveries[key] == nil })
    #expect(finished, "the transfer stalled before an outcome")
    await p.b.receive { action in
        guard case let .delegate(.messageReceived(m, validated, method)) = action else { return false }
        return m.hash == msg.hash && m.fields == msg.fields && validated && method == .direct
    }
    await p.a.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(attempts == 1, "the message was resent mid-transfer")
    #expect(p.a.state.router.succeededMessages.contains(msg.hash))
    #expect(outbound.count > 10)
    #expect(outbound == outbound.sorted())
    #expect((outbound.first ?? 0) >= LXMFNode.linkActiveProgress)
    #expect(inbound.count > 10)
    #expect(inbound == inbound.sorted())
    await p.stop()
}

/// The old router resent a Resource copy every 10 s and failed it at 50 s. This transfer takes
/// over 60 s of test-clock time: it must be sent once and confirmed.
@Test(.timeLimit(.minutes(10))) @MainActor func transferEndToEndSlowLinkOutlastsTheOldRetrySaga() async {
    let p = TransferPair()
    await p.connectAndIntroduce()
    let msg = p.attachmentMessage(bytes: transferIncompressible(count: 3_000_000))
    let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))
    var outbound: [Double] = []
    var attempts = 0
    let finished = await p.pump(
        bToADelay: .milliseconds(100),
        keepA: { p.a.state.router.pendingDeliveries[key] == nil },
        sample: {
            if let f = p.a.state.transferProgress[key], f != outbound.last { outbound.append(f) }
            attempts = max(attempts, p.a.state.router.pendingDeliveries[key]?.attempts ?? 0)
        },
        until: { p.a.state.router.pendingDeliveries[key] == nil })
    #expect(finished, "the transfer stalled before an outcome")
    await p.a.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    let elapsed = TestClock<Duration>.Instant().duration(to: p.clock.now)
    #expect(elapsed > .seconds(60), "the harness did not slow the transfer enough to matter")
    #expect(attempts == 1, "the message was resent mid-transfer")
    #expect(outbound == outbound.sorted())
    await p.stop()
}

@Test(.timeLimit(.minutes(5))) @MainActor func transferEndToEndCancelMidTransferFailsThePeersTransfer() async {
    let p = TransferPair()
    await p.connectAndIntroduce()
    let msg = p.attachmentMessage(bytes: transferIncompressible(count: 200_000))
    let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))
    let halfway = await p.pump(until: { (p.a.state.transferProgress[key] ?? 0) >= 0.4 })
    #expect(halfway, "the transfer stalled before it was worth cancelling")
    #expect(p.b.state.endpoint.links.contains { !$0.transfers.isEmpty }, "B is mid-transfer")
    await p.a.send(.cancelOutbound(messageHash: msg.hash))
    await p.a.receive(.delegate(.deliveryCancelled(messageHash: msg.hash)))
    #expect(p.a.state.router.pendingDeliveries[key] == nil)
    #expect(p.a.state.endpoint.links.allSatisfy { $0.transfers.isEmpty })
    // Deliver the RESOURCE_ICL (and whatever was already in flight) until B's transfer is gone.
    let peerFailed = await p.pump(until: { p.b.state.endpoint.links.allSatisfy { $0.transfers.isEmpty } })
    #expect(peerFailed, "the cancel never reached B")
    #expect(!p.b.state.router.seen.contains(msg.hash))
    #expect(p.b.state.inboundProgress.isEmpty)
    #expect(!p.a.state.router.succeededMessages.contains(msg.hash))
    await p.stop()
}

/// With a propagation node configured, both copies report their own success and nothing reports a
/// failure. The node's side of its transfer is played by the delegates the endpoint would emit.
@Test(.timeLimit(.minutes(5))) @MainActor func transferEndToEndWithAPropagationNodeBothCopiesSucceed() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let pnLink = Data(repeating: 0xC0, count: 16)
    let p = TransferPair(configureA: { state in
        state.router.outboundPropagationNode = pn
        state.router.directLinks[pn] = .active(linkID: pnLink)
        state.directLinks[pn] = pnLink
        state.endpoint.transport.learned[pn] = LearnedDestination(
            identity: Identity(),
            appData: PNAnnounce(timebase: 0, nodeState: true, perTransferLimit: 1000, perSyncLimit: 1000,
                                targetStampCost: 4, stampCostFlexibility: 0, peeringCost: 0).packed,
            ratchet: nil, interfaceID: InterfaceID("pn"), hops: 1, nextHop: nil, announceEmitted: 0)
    })
    await p.connectAndIntroduce()
    let msg = p.attachmentMessage(bytes: transferIncompressible(count: 100_000))
    #expect(msg.packed.count < 1000 * 1000)                                 // under the node's limit
    let key = LXMFRouter.DeliveryKey.delivery(msg.hash)
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: true))
    #expect(p.a.state.router.pendingPropagatedCopies.contains(msg.hash))
    await p.a.receive { if case let .router(.sendViaPropagation(m, _)) = $0 { return m.hash == msg.hash }; return false }
    #expect(p.a.state.router.linkResourceInFlight[pnLink] == .propagated(msg.hash))
    let pnResource = Data(repeating: 0x9C, count: 32)
    await p.a.send(.endpoint(.delegate(.resourceProgress(linkID: pnLink, resourceHash: pnResource, role: .sender,
                                                         bytesDone: 0, bytesTotal: 10, segment: 1, segments: 1))))
    await p.a.send(.endpoint(.delegate(.resourceConcluded(linkID: pnLink, resourceHash: pnResource))))
    await p.a.receive(.delegate(.propagationAccepted(messageHash: msg.hash)))
    let finished = await p.pump(keepA: { p.a.state.router.pendingDeliveries[key] == nil },
                                until: { p.a.state.router.pendingDeliveries[key] == nil })
    #expect(finished, "the direct transfer stalled before an outcome")
    await p.a.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(p.a.state.router.pendingDeliveries.isEmpty)
    #expect(p.a.state.router.pendingPropagatedCopies.isEmpty)
    await p.stop()
}
```

- [ ] **Step 2: Run the tests**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --filter transferEndToEnd > /tmp/ReTiCaMsgr/tad-t8-green.log`
Expected: 4 tests PASS. If a pump returns false, diagnose before touching production code: read the last frames in `sentA`/`sentB` (add a temporary `print` in the test only) — a stall usually means a frame was forwarded before the node wrote it, i.e. too few yields; raise the idle limit, never the production timeouts.

- [ ] **Step 3: Mutation batch (apply all at once)**

1. `LXMFRouter.startResource`: in the `.direct` branch return `.merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: true))), retryTimer(key, LXMFDelivery.retryWaitSeconds))`, and set `pending.phase = .retrying` instead of `.transferring` (the old resend-on-a-timer behaviour) → RED `transferEndToEndSlowLinkOutlastsTheOldRetrySaga` (a retry at 10 s counts an attempt: `attempts == 2`). The fast test never advances the clock, so it is unaffected.
2. `ResourceTransfer`, receiver part branch: in the round-incomplete return, `.merge(reported, armReceiverWatchdog(state))` → `armReceiverWatchdog(state)`, and in the next-window return `.merge(reported, requestNextWindow(&state))` → `requestNextWindow(&state)` → RED `transferEndToEndThreeMegabytesConfirmWithMonotonicProgress` (B reports only at segment starts and ends: `inbound.count` ≤ 6). The slow test does not look at inbound progress; the cancel test's `inboundProgress.isEmpty` still holds.
3. `LinkSession.cancelResource`: body → `return .none` → RED `transferEndToEndCancelMidTransferFailsThePeersTransfer` (A's transfer stays; B's never fails).
4. `LXMFNode`: `.router(.delegate(.propagationAccepted(hash)))` → `return .none` → RED `transferEndToEndWithAPropagationNodeBothCopiesSucceed`.

Each mutation reddens exactly one test, so none masks another; none traps. Run the Step 2 command: all four FAIL. Revert by hand, check the diff, run again: all PASS.

- [ ] **Step 4: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery --no-parallel > /tmp/ReTiCaMsgr/tad-t8-full.log`
Expected: all pass with the 1 known issue; count = Task 7 count + 4.

- [ ] **Step 5: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery add Tests/ReTiCANodeTests/LXMFNodeTransferEndToEndTests.swift`

Write `/tmp/ReTiCaMsgr/msg-tad-task-8.txt`:

```
test: transfer-aware delivery end to end over two nodes

A 3 MB message is delivered with monotonic progress on both sides and
confirmed once, the same transfer stretched past 60 s of test-clock
time is never resent, a cancel mid-transfer fails the peer's transfer,
and with a propagation node both copies succeed with no false failure.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery commit -F /tmp/ReTiCaMsgr/msg-tad-task-8.txt`

---
### Task 9: Docs

**Files:**
- Modify: `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md` (Amendment 3, :272-282)
- Modify: `docs/reference-parity-checklist.md` (Tier 5 list, Slices table)

**Interfaces:** none (documentation only; no tests, so no mutation step).

- [ ] **Step 1: Mark the propagated stamp-search gap fixed**

In `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md`, replace

```
     not only peers with a stamp cost. It predates this work. The proper fix is a "propagated copy
     pending" marker, set when the stamp search starts and honoured by `isOutstanding`.
```

with

```
     not only peers with a stamp cost. It predates this work. The proper fix is a "propagated copy
     pending" marker, set when the stamp search starts and honoured by `isOutstanding`.
     **Fixed** by `2026-09-27-transfer-aware-delivery-design.md` §6:
     `LXMFRouter.State.pendingPropagatedCopies`, set by `.propagatedCopyPending` when
     `sendMessage(alsoViaPropagation: true)` starts the search, cleared when the copy is armed,
     failed, or cancelled; `.cancelPropagationStamps` and `.setPropagationNode` fail the marked
     copies through `fail` (`.abandonPendingPropagatedCopies`).
```

and replace

```
   The cancellation gap and the delivery-stamp-search gap affect only peers with a delivery stamp
   cost, or cancellation. The propagated-stamp-search gap does not: it affects every user with a
   propagation node.
```

with

```
   The cancellation gap and the delivery-stamp-search gap affect only peers with a delivery stamp
   cost, or cancellation, and are still open. The propagated-stamp-search gap affected every user
   with a propagation node; it is fixed (above).
```

- [ ] **Step 2: Parity checklist — Tier 5 entry**

In `docs/reference-parity-checklist.md`, replace

```
- [ ] **Resource window capped at the slow ceiling** — `ResourceWindow.swift`: `maxWindowSlow = 10`
```

with

```
- [x] **Outbound Resource semantics** — CLOSED (`2026-09-27-transfer-aware-delivery-design.md`).
      A message sent as a Resource is no longer resent while its transfer runs (reference: a
      SENDING message is not resent, LXMRouter.py:2788-2796): `LXMFRouter` puts the copy in
      `.transferring` with no retry timer and lets the transfer decide — concluded → confirmed,
      failed → the link is torn down and one retry follows `DELIVERY_RETRY_WAIT` later on a fresh
      link, rejected (any RESOURCE_RCL at the sender) → terminal `deliveryRejected`
      (`LXMessage.__resource_concluded`, LXMessage.py:597-606). A link lost mid-transfer counts as
      a failed transfer. **Cancel:** `LXMFNode.cancelOutbound(messageHash:)` mirrors
      `LXMRouter.cancel_outbound` (LXMRouter.py:1719-1744): stamp searches for that message stop,
      a Resource in flight gets the standard RESOURCE_ICL, `deliveryCancelled` is reported once.
      **Progress:** `deliveryProgress` / `propagationProgress` on the reference scale (0.05 link
      active, 0.10 transfer start, `0.10 + 0.90 × progress`, 1.0 done — LXMessage.py:623-624) and
      `inboundTransferProgress` for arriving Resources; `LinkSession` reports per-transfer progress
      at whole-percent steps. Transfer traffic re-arms the router's 600 s link idle timer.
      **Deliberate divergence:** reference allows several concurrent Resources per link; we run
      one per link and queue the rest (`LXMFRouter.resourceQueue`), because `LinkSession` keeps a
      single split-send slot. Not a wire behaviour. **Also:** a propagated copy larger than the
      node's announced per-transfer limit is refused up front (`propagationRefused`); reference
      attempts it and lets the node reject it.
- [ ] **Resource window capped at the slow ceiling** — `ResourceWindow.swift`: `maxWindowSlow = 10`
```

- [ ] **Step 3: Parity checklist — Slices row**

Replace

```
| Link liveness remainder | — | `2026-08-11-link-liveness-remainder.md` | ⚠️ do-not-execute; needs rework |
```

with

```
| Link liveness remainder | — | `2026-08-11-link-liveness-remainder.md` | ⚠️ do-not-execute; needs rework |
| Transfer-aware delivery | Tier 5 | `2026-09-27-transfer-aware-delivery.md` | done |
```

- [ ] **Step 4: Check and commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery diff --stat`
Expected: only the two doc files.

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery add docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md docs/reference-parity-checklist.md`

Write `/tmp/ReTiCaMsgr/msg-tad-task-9.txt`:

```
docs: transfer-aware delivery in the parity checklist and proofs amendment

The propagated stamp-search gap from the single-packet proofs work is
marked fixed, and the parity checklist records the new outbound
Resource semantics, cancel, progress and the one-transfer-per-link
divergence.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery commit -F /tmp/ReTiCaMsgr/msg-tad-task-9.txt`

---

### Task 10: ReTiCaMsgr — rejected and cancelled messages show as failed (app repo)

**Why verification needs an override:** `ReTiCaMsgrCore/Package.swift` depends on `.package(path: "../../../pods/ReTiCA")`, the MAIN ReTiCA checkout, which does not contain this branch until the controller merges it. So point the core package at this worktree TEMPORARILY through a symlink named `ReTiCA` (SwiftPM's package identity stays `retica`, so `.product(..., package: "ReTiCA")` still resolves), verify, then restore every package file byte-for-byte. The override is never committed. **Consequence for the controller:** once this commit is on the app's `main`, the app only builds against a ReTiCA that has `feat/transfer-aware-delivery` merged — merge ReTiCA first.

**Files (app worktree `/Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat`, called `APP` below):**
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` (the `deliveryFailed` case, :777)
- Modify: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (append tests at the end)
- Modify: `docs/superpowers/backlog-retica-followups.md` (remove the fixed item)
- Temporarily modified, then restored byte-identical: `ReTiCaMsgrCore/Package.swift`, `ReTiCaMsgrCore/Package.resolved`, `ReTiCaMsgr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`

**Interfaces:**
- Consumes: `LXMFNode.Action.Delegate.deliveryRejected(messageHash: Data)`, `.deliveryCancelled(messageHash: Data)`. Every other new delegate case (`deliveryProgress`, `propagationProgress`, `inboundTransferProgress`, `propagationRefused`) falls into the existing `case .node, .binding:` catch-all (`AppFeature.swift:1032`) and is left for the files feature. `DiagnosticsSnapshot` and its tests read/construct `PendingDelivery(resend:attempts:)` and keep compiling (`phase` is defaulted).
- Behaviour: a rejected or cancelled outgoing message is marked `MessageStatus.failed` with the same guards as `deliveryFailed` (never downgrades "propagated"/"delivered", outgoing rows only) and records the first `failedAt`.

- [ ] **Step 1: Create the app worktree and check its baseline**

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr worktree add /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat -b feat/retica-tad-compat main`
Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/tad-t10-baseline.log`
Expected: green against the unmodified main ReTiCA checkout. If not, STOP and report.

- [ ] **Step 2: Back up the package files, then override**

Run: `cp /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore/Package.swift /tmp/ReTiCaMsgr/tad-core-Package.swift.orig`
Run: `cp /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore/Package.resolved /tmp/ReTiCaMsgr/tad-core-Package.resolved.orig`
Run: `cp /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved /tmp/ReTiCaMsgr/tad-xcode-Package.resolved.orig`
Run: `cp /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgr.xcodeproj/xcuserdata/ell.xcuserdatad/xcschemes/xcschememanagement.plist /tmp/ReTiCaMsgr/tad-app-schemes.plist.orig`
Run: `cp /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore/.swiftpm/xcode/xcuserdata/ell.xcuserdatad/xcschemes/xcschememanagement.plist /tmp/ReTiCaMsgr/tad-core-schemes.plist.orig`
(The last two are tracked files that Xcode rewrites on a build; the main checkout shows exactly that drift.)
Run: `ln -sfn /Users/ell/development/ios/pods/ReTiCA-worktrees/transfer-aware-delivery /tmp/ReTiCaMsgr/ReTiCA`
Run: `ln -sfn /Users/ell/development/ios/pods/FCB /tmp/ReTiCaMsgr/FCB`
(The second covers the worktree's own `.package(path: "../FCB")` if SwiftPM resolves it next to the symlink; the worktree's real sibling `/Users/ell/development/ios/pods/ReTiCA-worktrees/FCB` already exists.)

In `APP/ReTiCaMsgrCore/Package.swift` replace `        .package(path: "../../../pods/ReTiCA"),` with `        .package(path: "/tmp/ReTiCaMsgr/ReTiCA"),`.

Run: `swift build --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore --build-tests > /tmp/ReTiCaMsgr/tad-t10-build.log`
Expected: SUCCEEDS already (the app's switch has a catch-all). Any error means an app site this plan missed: STOP and report it.

- [ ] **Step 3: Write the failing tests**

Append to `APP/ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`:

```swift

// MARK: - Transfer-aware delivery (ReTiCA): rejected and cancelled messages

/// A message the recipient refused, or the user cancelled, will never go out: it must leave
/// "sending" for "failed" and record when, exactly like `deliveryFailed`.
@MainActor @Test func tadCompatDeliveryRejectedMarksFailedAndRecordsFailedAt() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "61", count: 16)
    try! await seed(db, [msg(1, peerA, "x", 1000, status: MessageStatus.sending, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.failed)
    #expect(row?.failedAt == infoT0)
}

@MainActor @Test func tadCompatDeliveryCancelledMarksFailedAndRecordsFailedAt() async {
    let db = try! AppDatabase.makeInMemory()
    let h = String(repeating: "62", count: 16)
    try! await seed(db, [msg(1, peerA, "x", 1000, status: MessageStatus.sending, hash: h)])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryCancelled(messageHash: hashData(h))))))
    await store.skipReceivedActions(strict: false)
    let row = await rowsByHashAndDirection(db)["\(h)/out"]
    #expect(row?.status == MessageStatus.failed)
    #expect(row?.failedAt == infoT0)
}

/// Same guards as `deliveryFailed`: a delivered row stays delivered, and an incoming row sharing
/// the hash is untouched.
@MainActor @Test func tadCompatRejectedAndCancelledKeepTheDeliveredAndIncomingGuards() async {
    let db = try! AppDatabase.makeInMemory()
    let delivered = String(repeating: "63", count: 16)
    let shared = String(repeating: "64", count: 16)
    try! await seed(db, [
        msg(1, peerA, "done", 1000, status: MessageStatus.delivered, hash: delivered),
        msg(2, peerA, "out", 1000, outgoing: true, status: MessageStatus.sending, hash: shared),
        msg(3, peerA, "in", 1000, outgoing: false, status: MessageStatus.received, hash: shared),
    ])
    let store = makeStore(db, identity: Identity())
    await sendAndSettle(store, .node(.client(.delegate(.deliveryRejected(messageHash: hashData(delivered))))))
    await sendAndSettle(store, .node(.client(.delegate(.deliveryCancelled(messageHash: hashData(shared))))))
    await store.skipReceivedActions(strict: false)
    let rows = await rowsByHashAndDirection(db)
    #expect(rows["\(delivered)/out"]?.status == MessageStatus.delivered)
    #expect(rows["\(shared)/out"]?.status == MessageStatus.failed)
    #expect(rows["\(shared)/in"]?.status == MessageStatus.received)
    #expect(rows["\(shared)/in"]?.failedAt == nil)
}
```

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore --filter tadCompat`
Expected: the first two and the `shared/out` assertion FAIL (the new cases fall into the catch-all, rows stay "sending").

- [ ] **Step 4: Map the two outcomes**

In `APP/ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` replace

```swift
            case let .node(.client(.delegate(.deliveryFailed(hash)))):
```

with

```swift
            // A rejection (the recipient refused the transfer) and a cancel (the user stopped the
            // send) mean the message will not go out, same as a failure. The files feature will style
            // them apart; until then they share the "failed" status and the failure milestone.
            case let .node(.client(.delegate(.deliveryFailed(hash)))),
                 let .node(.client(.delegate(.deliveryRejected(hash)))),
                 let .node(.client(.delegate(.deliveryCancelled(hash)))):
```

- [ ] **Step 5: Run the core suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore > /tmp/ReTiCaMsgr/tad-t10-green.log`
Expected: all PASS, including the three `tadCompat` tests.

- [ ] **Step 6: Mutation batch**

Remove the `deliveryRejected` pattern line from the case (leave `deliveryFailed` and `deliveryCancelled`) → RED `tadCompatDeliveryRejectedMarksFailedAndRecordsFailedAt`. In the same batch, remove the `deliveryCancelled` pattern line → RED `tadCompatDeliveryCancelledMarksFailedAndRecordsFailedAt` and `tadCompatRejectedAndCancelledKeepTheDeliveredAndIncomingGuards` (its `shared/out` row stays "sending"). With both removed the case is the original single pattern, so it compiles. Neither removal affects the other's test.
Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore --filter tadCompat`
Expected: all three FAIL. Restore both lines by hand, run again: all PASS.

- [ ] **Step 7: App target build (override still in place)**

Run: `xcodebuild -project /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgr.xcodeproj -scheme ReTiCaMsgr -destination "generic/platform=iOS Simulator" build > /tmp/ReTiCaMsgr/tad-t10-xcodebuild.log`
Expected: `** BUILD SUCCEEDED **` at the end of the log.

- [ ] **Step 8: Remove the fixed backlog item**

In `APP/docs/superpowers/backlog-retica-followups.md` delete the bullet that starts `- **False "failed" with a propagation node configured.**` through its last line `  copy is armed (or via \`fail\` on \`cancelPropagationStamps\`).`, and replace

```
See ReTiCA spec `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md`, "Amendments at
planning time", item 3.
```

with

```
See ReTiCA spec `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md`, "Amendments at
planning time", item 3. (The false "failed" with a propagation node configured is fixed by ReTiCA's
transfer-aware delivery work, `2026-09-27-transfer-aware-delivery-design.md` §6.)
```

Hop count, arrival interface and retry count stay.

- [ ] **Step 9: Restore the package files byte-identical**

Run: `cp /tmp/ReTiCaMsgr/tad-core-Package.swift.orig /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore/Package.swift`
Run: `cp /tmp/ReTiCaMsgr/tad-core-Package.resolved.orig /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore/Package.resolved`
Run: `cp /tmp/ReTiCaMsgr/tad-xcode-Package.resolved.orig /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
Run: `cmp /tmp/ReTiCaMsgr/tad-core-Package.swift.orig /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore/Package.swift`
Run: `cmp /tmp/ReTiCaMsgr/tad-core-Package.resolved.orig /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgrCore/Package.resolved`
Run: `cmp /tmp/ReTiCaMsgr/tad-xcode-Package.resolved.orig /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat/ReTiCaMsgr.xcodeproj/project.xcworkspace/xcshareddata/swiftpm/Package.resolved`
Expected: each `cmp` prints nothing (exit 0).
Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat status --short`
Expected: exactly ` M ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift`, ` M ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`, ` M docs/superpowers/backlog-retica-followups.md`. If either `xcschememanagement.plist` also shows as modified, copy its Step 2 backup back over it (`cp /tmp/ReTiCaMsgr/tad-app-schemes.plist.orig .../ReTiCaMsgr.xcodeproj/xcuserdata/ell.xcuserdatad/xcschemes/xcschememanagement.plist`, `cp /tmp/ReTiCaMsgr/tad-core-schemes.plist.orig .../ReTiCaMsgrCore/.swiftpm/xcode/xcuserdata/ell.xcuserdatad/xcschemes/xcschememanagement.plist`), `cmp` it, and re-run `status`. Anything else unexpected: STOP and report — never `git checkout` it.

- [ ] **Step 10: Commit (app worktree, branch `feat/retica-tad-compat`)**

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift docs/superpowers/backlog-retica-followups.md`

Write `/tmp/ReTiCaMsgr/msg-tad-task-10.txt`:

```
fix: rejected and cancelled messages show as failed

ReTiCA's transfer-aware delivery reports deliveryRejected and
deliveryCancelled. Both now take the deliveryFailed path, so the row
leaves "sending" and records its failure time, with the same delivered
and incoming guards. Progress and propagationRefused are left to the
files feature. Needs ReTiCA with feat/transfer-aware-delivery merged.

Co-Authored-By: <model that wrote the commit> <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-tad-compat commit -F /tmp/ReTiCaMsgr/msg-tad-task-10.txt`

---
## Self-review notes (for the reviewer)

**Spec coverage.** §1 (phase, no retry mid-transfer, `resourceFailedOnLink` retry/reject/exhaust, `.retryDue` no-op, `fail` reason) → Task 3. §2 (cancel: router → Task 5; node per-hash stamp cancel and `cancelResource` plumbing → Tasks 2 and 6). §3 (progress and `failed(rejected:)` in `ResourceTransfer` → Task 1; passed up → Task 2; node mapping, scale, inbound progress, outcomes → Task 6). §4 (one transfer per link, queue, small sends never queued, closure → re-establish) → Task 4 (closure of an in-flight transfer → Task 3). §5 (idle re-arm) → Task 6. §6 (pending marker, oversize) → Task 7. Delegate API table → Tasks 3, 5, 6, 7. Testing: router → Tasks 3-5, 7; transfer layer → Tasks 1-2; node mapping → Task 6; end to end (3 MB, slow link, cancel, PN) → Task 8; ReTiCaMsgr suite → Task 10. Docs → Task 9 (ReTiCA) and Task 10 (app backlog).

**Where the plan departs from the spec's wording, and why** (each is also stated where it lands):

1. **Our transfer is identified by resource hash, in `LXMFNode`.** The spec maps `resourceFailed` by link ID only. `LinkSession` emits `resourceFailed` for INBOUND transfers too, so that would fail our outbound copy whenever a peer's transfer to us failed on the same link; and a conclusion or failure of a cancelled transfer could resolve the NEXT copy started on the link. The node records the hash of our transfer from its first sender-role progress event (emitted at advertise) and ignores any other hash. The router stays link-keyed, as specified. `cancelledMessages` is still kept, and used where it can act: a copy handed over after a cancel (a stamp search finishing late) is never armed.
2. **`resourceProgress` carries `role`,** so the node can tell our transfer from an inbound one on the same link; progress is not reported for request/response Resources (the link's own plumbing, like `resourceConcluded` today).
3. **The 0.10 point is the transfer's first progress event** (`bytesDone == 0`), emitted when the sender advertises; the receiver likewise reports 0 on accept. Fractions are byte-based (`sentIndices`/`receivedParts` summed by part size) rather than part counts; a split Resource's fraction spans its segments.
4. **`inboundTransferProgress(sourceHash: Data?, linkID: Data, fraction:)`** — the spec's `sourceHash: Data` "remote destination hash of the link" does not exist for the normal inbound case: a peer delivering to us opens a link to OUR `lxmf.delivery` destination and does not identify, so the link's destination hash is our own. `sourceHash` is the far end when we opened the link and nil otherwise; `linkID` lets the app correlate.
5. **The fifth failure fails at once** (`attempts == maxAttempts` at a non-rejected failure) rather than after one more 10 s wait whose only purpose would be to discover that no attempt is left — the spec's "the 5th failure fails the copy". Reference reaches the same end by counting attempts as it re-establishes the link and failing once the count passes `MAX_DELIVERY_ATTEMPTS` (LXMRouter.py:2766, :2826-2841).
6. **Rejection is terminal for both copies**, as the spec says, although reference's `__propagation_resource_concluded` (LXMessage.py:608-613) treats a propagated REJECTED like any failure. The terminal delegate is `deliveryRejected` only when the LAST copy to fail was rejected.
7. **`propagatedCopyRefused` does not run `fail`.** The copy was never started, and `fail`'s "every copy failed" check could then report `deliveryFailed` while the delivery copy is still in its own stamp search (a gap the spec leaves out of scope). The refusal only reports `propagationRefused`; the delivery copy's outcome decides the message.
8. **A PN `perTransferLimit` of 0 or less is "unknown".** Every existing fixture announces 0; the spec's `packed.count > limit × 1000` would refuse every propagated copy there.
9. **`setPropagationNode` also fails the marked copies** (it cancels every propagation stamp search, like `cancelPropagationStamps`), via a new `abandonPendingPropagatedCopies` router action.
10. **A link lost mid-transfer is a failed transfer.** `LinkSession` reaps transfers silently when a link closes, so `closed()`/idle teardown/give-up send the orphaned copy back to `.retrying` with one timer; the spec only covered queued copies. `giveUp` also fails queued copies (they have no timer).
11. **`deliveryCancelled` exactly once:** the router reports it only if it held work for the message; the node reports it when the only work was a delivery stamp search.
12. **`cancelResource` on a split send** drops the unsent segments and cancels the one in flight; "without a packet" happens only when no segment transfer is left.

**Line references in the spec that moved:** `closed()` is at `LXMFRouter.swift:364`, not `:321`. The rest match `main` at `6df1c5a`.

**Placeholder scan:** none — every code step carries the code; the only open-ended instruction is the Task 2 Step 11 contingency for an exhaustive test nobody found when planning.

**Type consistency:** `PendingDelivery(resend:attempts:phase:)`, `startResource(_:_:linkID:)`, `startOrQueueResource(_:_:dest:linkID:)`, `startNextQueued(_:dest:)`, `destination(ofLink:_:)`, `orphanTransfer(_:linkID:)`, `fail(_:_:reason:)`, `hasOutboundState(for:)`, `resourceFailedOnLink(linkID:rejected:)`, `cancelOutbound(messageHash:)`, `linkActivity(linkID:)`, `propagatedCopyPending(messageHash:)`, `propagatedCopyRefused(messageHash:reason:)`, `abandonPendingPropagatedCopies`, `resourceProgress(linkID:resourceHash:role:bytesDone:bytesTotal:segment:segments:)`, `resourceFailed(linkID:resourceHash:rejected:)`, `cancelResource(linkID:hash:)` / `cancelResource(hash:)` are spelled the same in every task that defines or uses them.
