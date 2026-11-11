# Parity batch 2 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Sync from an auth-required propagation node fails visibly with reference's state for every PN error code. The production propagation node (`LXMFServiceNode`) peers with other nodes the way a default lxmd does. Non-expanded workblock stamps are pinned as rejected (LXMF 1.3.0 behaviour). Tunnel synthesis is scoped and its client half planned.

**Architecture:** The library holds the sync state in `LXMFRouter`, reports it from `LXMFNode`, and adds a pure `PNPeerTable` value type that `LXMFServiceNode` drives. `PNNode` is not merged: it keeps its own tests and borrows only the shared offer-response parser. The app (ReTiCAMsgr) shows the sync state, persists the peer table and gains two node-mode settings. Each task cross-validates against reference code run in the `rns-latest` conda env by a committed generator.

**Tech Stack:** Swift 6, TCA, Swift Testing, GRDB/SQLiteData (app). The reference is RNS 1.6.0 / LXMF 1.3.0 in `/Users/ell/opt/anaconda3/envs/rns-latest/lib/python3.12/site-packages` (abbreviated `SP/` below), run with `/Users/ell/opt/anaconda3/envs/rns-latest/bin/python`.

**Spec:** the survey `/tmp/ReTiCA/parity-gap-report.md` (rows L2, L3/X6, L6, T1), as corrected by the "Survey corrections" section below. The reference source cited per task is the authority. Where the survey and reference disagree, reference wins unless this plan records a ruling.

App path (verified): `/Users/ell/development/ios/apps/ReTiCAMsgr`, with the core package at `ReTiCAMsgrCore/` (`swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore`).

## Survey corrections (verified against main at 5167520)

- **L1 is already fixed.** Since 3d74fe8 `opportunisticFits` uses `Packet.encryptedMDU` (383). The doc comment at `Sources/ReTiCA/LXMF/LXMessage+Opportunistic.swift:13-25` is now stale: it calls 383 "a deliberate departure from reference LXMF … 391", but LXMF 1.3.0 *is* 383 (`SP/LXMF/LXMessage.py:68`, `ENCRYPTED_PACKET_MDU = RNS.Packet.ENCRYPTED_MDU`). Fix the comment in Task 1's commit and leave the code alone.
- **L3 "times out on every sync and backs off" is wrong about the backoff.** A reference peer adds `SYNC_BACKOFF_STEP` only when it opens a link. Then `link_established` zeroes `next_sync_attempt` and `sync()` zeroes `sync_backoff` (`SP/LXMF/LXMPeer.py:326-335, 546`). The unanswered `/offer` only tears the link down (`request_failed`, `:400-403`). So the peer keeps opening a fresh link to us on its sync job, about every 24 s when it is selected. It never backs off.
- **L2 line numbers have drifted.** The handler is now at `Sources/ReTiCANode/LXMFNode.swift:1122-1181`. The defect itself holds. The sync also has a second silent path the survey missed: `.requestFailed` on the sync link is not handled in `LXMFNode` at all (grep `requestFailed` there: no hits).
- **Not in the survey:** the client also ignores the PN's upload rejection signal `[ERROR_INVALID_STAMP]` (`SP/LXMF/LXMRouter.py:3035-3048`). That packet reaches `LXMFNode.swift:1543-1571` as a "direct message" that fails to unpack. The copy then retries to exhaustion instead of being REJECTED. This plan covers it in Task 2.
- **L6:** in installed LXMF 1.3.0, no code path generates *or* accepts non-expanded stamps. Every `generate_stamp` call uses the default `no_expand=False` (`SP/LXMF/LXStamper.py:96-111`, `LXMessage.py:327, 352`, `LXMPeer.py:261`), and every validator expands (`LXStamper.py:26-43`, `LXMessage.py:295`). The master commit fbcb642 (checked on GitHub) adds acceptance to the three validators and leaves generation unchanged. One thing the survey leaves out: a non-expanded workblock is the bare 16/32-byte material, so each PoW attempt hashes about 48 bytes instead of `material + 768 000 B` (`SP/RNS/Stamps.py:87-88, 191-196`). Accepting such stamps cuts the anti-spam cost by orders of magnitude. See the Task 8 ruling.
- **L3 "PNNode.swift:286-288 notes no production consumer"** is now at `PNNode.swift:93-100` (the `syncFailed` doc).

## Global Constraints

- Workspace rules: one shell command per Bash call (no pipes, `&&`, `;`, `$(...)` or inline scripts); temp files go under `/tmp/ReTiCA/`; the three-step mutation verification (green → batch-mutate → all red → revert → green) runs before every commit; commit straight to main; `Co-Authored-By` / `Claude-Session` trailers at column 0. The known flaky `holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood` stays as is. Treat any other failure as real until it has been rerun alone.
- Every task cross-validates against genuine reference code through a **committed** generator under `Tests/<target>/Vectors/generate_*.py`. The generator drives real RNS/LXMF functions and stubs only the network edges, following `Tests/ReTiCATests/Vectors/generate_lxmf_pn_offer_limits_fixtures.py`. Its header names every stub. The generated JSON is committed next to it.
- Two code spaces that share byte values, verbatim:
  - Wire errors, `SP/LXMF/LXMPeer.py:24-31`: `ERROR_NO_IDENTITY = 0xf0`, `ERROR_NO_ACCESS = 0xf1`, `ERROR_INVALID_KEY = 0xf3`, `ERROR_INVALID_DATA = 0xf4`, `ERROR_INVALID_STAMP = 0xf5`, `ERROR_THROTTLED = 0xf6`, `ERROR_NOT_FOUND = 0xfd`, `ERROR_TIMEOUT = 0xfe`.
  - Client states, `SP/LXMF/LXMRouter.py:78-91`: `PR_IDLE = 0x00`, `PR_PATH_REQUESTED = 0x01`, `PR_LINK_ESTABLISHING = 0x02`, `PR_LINK_ESTABLISHED = 0x03`, `PR_REQUEST_SENT = 0x04`, `PR_RECEIVING = 0x05`, `PR_RESPONSE_RECEIVED = 0x06`, `PR_COMPLETE = 0x07`, `PR_NO_PATH = 0xf0`, `PR_LINK_FAILED = 0xf1`, `PR_TRANSFER_FAILED = 0xf2`, `PR_NO_IDENTITY_RCVD = 0xf3`, `PR_NO_ACCESS = 0xf4`, `PR_FAILED = 0xfe`.
- Sync response handling, `SP/LXMF/LXMRouter.py:1780-1862`. For both the list and the get response, `ERROR_NO_IDENTITY` → tear the link down, state `PR_NO_IDENTITY_RCVD`; `ERROR_NO_ACCESS` → tear the link down, state `PR_NO_ACCESS`. A list response that is a non-empty list → request `[wants, haves, delivery_per_transfer_limit]`; an empty list → `PR_COMPLETE`, last result 0. Anything else as a list response → tear down, with no state set there. A get response → `PR_COMPLETE`, last result `len(response)`, and the purge request `[None, haves]` follows only when the response is non-empty.
- Link cleanup, `SP/LXMF/LXMRouter.py:1096-1106`, with `acknowledge_sync_completion` at `:1874-1883`. When the outbound PN link closes: state `PR_COMPLETE` → `PR_IDLE`; state `< PR_LINK_ESTABLISHED` → `PR_LINK_FAILED`; state in `[PR_LINK_ESTABLISHED, PR_COMPLETE)` → `PR_TRANSFER_FAILED`; any state above `PR_COMPLETE` is **kept** (failure states are sticky until the next sync request). A path that never arrives → `PR_NO_PATH` (`:1683-1692`). A failed request (`message_get_failed`, `:1869-1872`) only tears down; the close then yields `PR_TRANSFER_FAILED`. Reference never retries a sync itself.
- Upload signal, `SP/LXMF/LXMRouter.py:3035-3048`: a link packet that unpacks to a list whose first element is `ERROR_INVALID_STAMP` cancels the outbound message with `LXMessage.REJECTED`.
- Peering defaults are those of a fresh lxmd: `autopeer = True`, `max_peers = 20` (`LXMRouter.py:56-57`); `peering_cost = 18.0`, `remote_peering_cost_max = 26.0` (`LXMRouter.py:63-64`, `lxmd.py:207-219`); `static_peers = []`, `from_static_only = False` (`lxmd.py:231-247`). `autopeer_maxdepth = 6`: this comes from the config file lxmd writes on first run (`lxmd.py:66-69`, `:1003`). `LXMRouter.AUTOPEER_MAXDEPTH` is 4 (`:58`); see the Task 6 ruling.
- Peer timing, verbatim: sync job every `JOB_PEERSYNC_INTERVAL 6 × PROCESSING_INTERVAL 4` = 24 s (`LXMRouter.py:38, 973`); `MAX_UNREACHABLE = 14*24*60*60`, `SYNC_BACKOFF_STEP = 12*60`, `PATH_REQUEST_GRACE = 7.5` (`LXMPeer.py:39, 45, 50`); `FASTEST_N_RANDOM_POOL = 2` (`LXMRouter.py:59`); `PN_STAMP_THROTTLE = 300` (`:76`); default strategy `STRATEGY_PERSISTENT` (`LXMPeer.py:33-35`).
- `/offer` responder, `SP/LXMF/LXMRouter.py:2601-2667`. No identity → `ERROR_NO_IDENTITY`. Invalid key at our `peering_cost` over `peering_id = self.identity.hash + remote_identity.hash` → `ERROR_INVALID_KEY`. If the key is valid: mark the link validated, then answer `False` if we want none of the ids, `True` if we want all of them, or the list of wanted ids otherwise. Resource conclusion (`:2716-2724`): a container with more than one message on a link without a validated key → teardown, nothing ingested.
- Offer-response handling, `SP/LXMF/LXMPeer.py:405-495`. `ERROR_NO_IDENTITY` → identify again and re-run `sync()`. `ERROR_NO_ACCESS` → `router.unpeer`. `ERROR_THROTTLED` → `next_sync_attempt = now + PN_STAMP_THROTTLE`. `False` → every offered id handled. `True` → send all. A list → the offered ids not in it become handled, and the ids in it are sent. Any other value (`ERROR_INVALID_KEY`, `ERROR_INVALID_DATA`) raises inside the `else` branch and lands in the `except`: teardown, `IDLE`, nothing marked.
- Stamps: `RNS.Stamps.stamp_workblock(material, expand_rounds, no_expand)` returns `material` unexpanded when `no_expand or not expand_rounds` (`SP/RNS/Stamps.py:87-88`). The LXMF 1.3.0 validators always expand (`LXStamper.py:26-43`, `LXMessage.py:295-298`).
- Tunnel synthesis, `SP/RNS/Transport.py:3043-3064`. The payload is `public_key(64) ‖ interface_hash(32) ‖ random_hash(16) ‖ signature(64)` = 176 bytes. `tunnel_id = full_hash(public_key ‖ interface_hash)`. The signature covers `public_key ‖ interface_hash ‖ random_hash`. It goes out as a PLAIN `rnstransport.tunnel.synthesize` DATA packet, BROADCAST, HEADER_1, on that interface only. A TCP client sends one on its initial connect (`TCPInterface.py:178-179` via `Transport.py:670-674`) and on every reconnect (`TCPInterface.py:298-299`). `interface_hash = full_hash(str(interface).encode("utf-8"))` (`Interface.py:185-187`).

## Review Focus

1. An auth-required lxmd answers the list request with `0xF1` (`ERROR_NO_ACCESS`). The client must land in `PR_NO_ACCESS` (0xF4), not `PR_LINK_FAILED`, which is also 0xF1 in the other code space. The link close that follows must not overwrite it with `PR_TRANSFER_FAILED`. (Task 1)
2. The PN link drops after `PR_COMPLETE` and before the purge request lands. The state goes to idle, the downloaded ids stay marked downloaded, and nothing is reported as failed. (Task 1)
3. A node-mode relaunch rehydrates 500 stored entries and 3 persisted peers. No entry may become unhandled for any peer, so the first sync offers only what was unhandled before the relaunch. (Task 6, Task 7)
4. A peer offers with a key valid at cost 17 while we advertise 18. It gets `ERROR_INVALID_KEY`, and a two-message container it then pushes on that link is refused with a teardown. Nothing is ingested. (Task 5)
5. Node mode is switched off mid-sync, during a peering-key search and an outbound offer. The 24 s job stops, the key search is cancelled, no further `/offer` or Resource goes out, and nothing is unpeered. (Task 6)

---

### Task 1: Propagation sync state and PN error codes on the download path (library)

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (State: `propagationTransferState`, `propagationTransferLastResult`; the sync cases at `:898-919`; `giveUp` at `:619-644`; `.linkEstablished` drain at `:970-973`)
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (sync dispatch `:1103-1181`; `.linkClosed` `:1496-1503`; new `.requestFailed` arm; Delegate)
- Modify: `Sources/ReTiCA/LXMF/LXMFPropagation.swift` (error constants next to `errorNoIdentity` `:141`)
- Modify: `Sources/ReTiCA/LXMF/LXMessage+Opportunistic.swift:13-25` (stale comment only, see Survey corrections)
- Create: `Tests/ReTiCANodeTests/Vectors/generate_lxmf_sync_state_fixtures.py`, `Tests/ReTiCANodeTests/Vectors/lxmf_sync_state_fixtures.json`
- Test: `Tests/ReTiCANodeTests/LXMFNodeSyncStateTests.swift`

**Interfaces:**
- Produces: `LXMFRouter.PropagationTransferState: UInt8, Equatable, Sendable`, with cases `idle, pathRequested, linkEstablishing, linkEstablished, requestSent, receiving, responseReceived, complete, noPath, linkFailed, transferFailed, noIdentityReceived, noAccess, failed` and raw values exactly the `PR_*` values in Global Constraints.
- Produces: `LXMFRouter.State.propagationTransferState: PropagationTransferState` (initially `.idle`) and `propagationTransferLastResult: Int?`.
- Produces: `LXMFRouter.Action.syncError(SyncError)`, where `enum SyncError: Equatable { case noIdentity, noAccess, invalid }`. Successful responses keep the existing actions: `.offeredMessageList(transientIds:)`, where an empty list now means `complete` with last result 0, and `.messagesDownloaded(transientIds:)`, which now means `complete` with last result `ids.count`. The router owns every state transition; `LXMFNode` only classifies the bytes.
- Produces: `LXMFNode.Action.Delegate.propagationTransferStateChanged(LXMFRouter.PropagationTransferState, lastResult: Int?)`, emitted once per actual change.
- Produces: `LXMFPropagation.errorNoAccess: UInt64 = 0xF1`, `errorInvalidKey = 0xF3`, `errorInvalidData = 0xF4`, `errorThrottled = 0xF6` (later tasks use them).

**Ruling 1a (retries):** ReTiCA keeps its bounded link-establishment retries for the sync (`establishAttempts`). The terminal states are set only where the router gives up. A park that ends by `pathRequestDeadline` gives `noPath`. An establishment ceiling gives `linkFailed`. Reference has no establishment retry and fails on the first closed link. *Cost if wrong:* an unreachable PN reports `linkFailed` a few attempts later than reference would; there is no wire effect.

**Ruling 1b (get response not a list):** reference raises inside `message_get_response` for a non-list, non-error get response (`len(int)` → TypeError, `LXMRouter.py:1840`), and the state stays where it was. We classify it `.invalid`, tear the link down, and the close yields `transferFailed`. *Cost if wrong:* none against a reference PN, which never sends one.

**Ruling 1c (`receiving` / `responseReceived`):** these states are declared but never entered. ReTiCA has no response-progress delegate for link requests. *Cost if wrong:* a UI cannot show download progress; the terminal states are unaffected.

- [ ] **Step 1: Write the generator.** It drives real `LXMRouter.request_messages_from_propagation_node`, `message_list_response`, `message_get_response`, `message_get_failed`, `clean_links` and `__request_messages_path_job`. Stubs: a fake `outbound_propagation_link` that records `teardown()` and `request()` and has a settable `status`, a fake `request_receipt` with `.response` and `.link`, and `RNS.Transport.has_path`. It records one case per response kind: `0xf0`, `0xf1`, `[]`, `[id]`, `None`, `0xf3`, plus the get-response kinds `0xf0`, `0xf1`, `[blob]`, `[]`. For each case it records the state right after the response, whether teardown happened, any follow-up request payload, and the state after `clean_links` with the link CLOSED. It also records the path-timeout case, a close from `PR_LINK_ESTABLISHING`, and a close after `PR_COMPLETE`. Run it with the rns-latest python and commit the JSON.

- [ ] **Step 2: Write the failing tests** (one `@Test` per fixture case, driven through a `.off` TestStore of `LXMFNode` over the existing sync test harness in `LXMFNodeSyncTests.swift`):

```swift
@Test(arguments: SyncStateFixtures.cases)
func syncResponseLandsInReferenceState(_ c: SyncStateFixtures.Case) async {
    // feed c.response as .endpoint(.delegate(.responseReceived(linkID, rid, data))) in c.phase
    #expect(store.state.router.propagationTransferState.rawValue == c.stateAfterResponse)
    #expect(sentCloseLink == c.teardown)
    // then .endpoint(.delegate(.linkClosed(linkID, .remote)))
    #expect(store.state.router.propagationTransferState.rawValue == c.stateAfterClose)
}
@Test func noAccessIsStickyThroughTheClose()          // Review Focus 1: 0xF1 → 0xF4, close keeps 0xF4
@Test func completeThenCloseGoesIdleAndKeepsDownloaded() // Review Focus 2
@Test func requestFailedOnSyncLinkTearsDownThenTransferFailed()
@Test func nextSyncRequestClearsAStickyFailure()      // .syncFromPropagationNode from .noAccess → .requestSent/.linkEstablishing
@Test func pathDeadlineGivesNoPathAndEstablishCeilingGivesLinkFailed()
@Test func stateChangeEmitsOneDelegatePerChange()
```

- [ ] **Step 3: Run them and confirm they fail.** Run: `swift test --filter LXMFNodeSyncStateTests`. Expected: compile failure (no `PropagationTransferState`), then FAIL.

- [ ] **Step 4: Implement.** In `LXMFNode`, classify an error or non-list response into `SyncError` and send `.router(.syncError)`. An `.awaitingMessages` response that is not a list is now `.invalid` too, where today it returns `.none` silently. Keep `syncPhase` as the phase gate. `LXMFNode` handles `.endpoint(.delegate(.requestFailed(linkID, _)))` for a link with a `syncPhase` by closing it. The router sets every state at the reference transition points in Global Constraints. It emits `.delegate(.propagationTransferStateChanged)`, and `LXMFNode` forwards that unchanged. Replace the stale `LXMessage+Opportunistic.swift:13-25` comment with one stating that LXMF 1.3.0's limit is `RNS.Packet.ENCRYPTED_MDU` (383). Keep the comment on the `encryptedPacketMDU = 391` constant, saying it is the older reference value, kept for its existing test.

- [ ] **Step 5: Run the tests and confirm they pass.** Then do the three-step mutation: map `0xF1` to `.linkFailed`, drop the sticky guard, and skip the teardown on `.noAccess`, all in one batch. Every new test must fail. Revert, rerun, all green. Run: `swift test --filter LXMFNodeSync`. Expected: PASS.

- [ ] **Step 6: Gated live check.** Add `LiveAuthPNSyncTests`, gated on `RETICA_LIVE_PN_PYTHON` the way `LiveStampInteropTests` is gated. It starts lxmd from rns-latest with `auth_required = yes` and an empty `allowed` file, syncs, and expects `.noAccess`. It then writes our identity hash into `allowed`, restarts, syncs, and expects `.complete`. Record the outcome in the commit message, ran or skipped.

- [ ] **Step 7: Commit** (`feat(lxmf): propagation sync reports reference transfer states, handles ERROR_NO_ACCESS`).

### Task 2: The PN's upload rejection signal (library)

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (`.linkDataReceived` at `:1543-1571`: an outbound-PN-link packet is a signal, never a message)
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (new action; uses existing `fail(&state, key, reason: .rejected)` at `:1062`)
- Create: `Tests/ReTiCANodeTests/Vectors/generate_lxmf_pn_upload_signal_fixtures.py` + JSON
- Test: `Tests/ReTiCANodeTests/LXMFPropagationUploadRejectTests.swift`

**Interfaces:**
- Consumes: `LXMFPropagation.errorInvalidStamp` (`:147`).
- Produces: `LXMFRouter.Action.propagationLinkSignal(linkID: Data, signal: UInt64)`.

**Ruling 2 (which copy):** reference rejects `link.for_lxmessage`, the message that *opened* the link (`LXMRouter.py:3293`), which may not be the offending one. We reject the propagated copy whose packet on that link is the oldest one still awaiting its receipt. If no packet copy is outstanding (the copy went as a Resource), we reject nothing: the Resource's own rejection path already covers it. *Cost if wrong:* with two copies in flight on one link, a valid copy could be rejected instead of the bad one, and the bad one then retries to exhaustion. Reference has the same class of error.

- [ ] Generator: drive `LXMRouter.propagation_transfer_signalling_packet` with `msgpack.packb([0xf5])`, `packb([0xf0])`, `packb(0xf5)` (not a list), `packb([])` and garbage bytes. Record, for each, whether `cancel_outbound` was called with `REJECTED` (stub `cancel_outbound` to record; `for_lxmessage` a stub). Commit it.
- [ ] Tests: `invalidStampSignalRejectsTheOutstandingPropagatedCopy` (terminal `.deliveryFailed`-class outcome with no retry timer left; check the router's existing rejected path for the exact delegate); one parameterized test over the fixture where only `[0xf5]` rejects; `signalOnOutboundPNLinkIsNeverDeliveredAsAMessage` (router never sees `.received` for it); `invalidStampSignalWithNoOutstandingPacketRejectsNothing`.
- [ ] Mutation, revert and green as in Task 1. Commit (`fix(lxmf): a propagation node's invalid-stamp signal rejects the outbound copy`).

### Task 3: Show the sync state in ReTiCAMsgr (app)

**Files:**
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift` (State field; `.node(.client(.delegate(.propagationTransferStateChanged)))` arm next to the other node delegates at `:2994`)
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/PropagationSyncText.swift`
- Modify: `ReTiCAMsgr/SettingsView.swift` (Propagation Node section footer, `:487-491`)
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/PropagationSyncStateTests.swift`

**Interfaces:**
- Consumes: `LXMFNode.Action.Delegate.propagationTransferStateChanged(_:lastResult:)` (Task 1).
- Produces: `AppFeature.State.propagationSyncState: LXMFRouter.PropagationTransferState` (not persisted) and `propagationSyncLastResult: Int?`; `enum PropagationSyncText { static func describe(_ state: LXMFRouter.PropagationTransferState, lastResult: Int?) -> String? }`.

Copy (exact): `.noAccess` → "This propagation node only serves approved users. Ask its operator to add your address."; `.noIdentityReceived` → "The propagation node did not receive your identity. Try syncing again."; `.noPath` → "Couldn't find a route to the propagation node."; `.linkFailed` → "Couldn't connect to the propagation node."; `.transferFailed` → "The download from the propagation node was interrupted."; `.complete` → "Last sync: N new messages." (N = lastResult; "1 new message" singular); every other state → nil.

**Ruling 3 (no app-side suppression):** the app keeps syncing on connect, on foreground and on `syncTapped`. A sticky `.noAccess` is cleared by the next sync request, as in reference. The app does not stop syncing an auth-required node. *Cost if wrong:* one refused link per trigger against a node that refuses us, which costs the node little.

- [ ] Tests: each delegate state is stored and produces the text above. The app never resets the state itself: `syncTapped`, `interfaceConnected` and foregrounding leave it unchanged until the library reports the next state. Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCAMsgr/ReTiCAMsgrCore --filter PropagationSyncStateTests`.
- [ ] Mutation, revert and green. Commit in the app repo (`feat: show the propagation sync result`).

### Task 4: `PNPeerTable`, the peer state machine (library, pure)

**Ruling 4 (reuse, don't merge):** `LXMFServiceNode` gains peering through a new pure value type that it owns. It does not merge with `PNNode` or compose it. Reasons:
- `PNNode` owns its own `TransportEndpoint`, so it cannot be a child of `LXMFServiceNode`, which already owns one through `LXMFNode`.
- About 58 references to `PNNode` across 8 test files (`PNNodeTests` 21, `PNNodeIntegrationTests` 7, `PNNodeOfferLimitsTests` 7, `PNNodeMeshTests` 6, `LXMFPropagationCapstoneTests` 6, `StampWorkBoundsTests` 5, …) are the proof of the recent offer-selection parity work. A merge would rewrite them and destroy that proof.
- The two serve paths have already diverged. `LXMFServiceNode` queues `/get`s, answers `ERROR_NO_IDENTITY`, parses the transfer limit and validates packet offers; `PNNode` does none of these.

What *is* shared: `PropagationStore.offerCandidates` (gaining an `among:` filter) and one new parser, `PNPeerTable.OfferResponse.parse`. `PNNode`'s response arm at `PNNode.swift:305-320` switches to that parser with no behaviour change, so its tests stay byte-for-byte unchanged and act as characterization. Peering state is a value type with synchronous mutating methods that return commands, not a TCA child, because peering decisions read the store, which lives in the sibling `PropagationNode.State`. The host computes selections and the table never reads the store. *Cost if wrong:* two serve compositions keep drifting (`PNNode`'s `/get` still lacks the error responses). Record in Status that `PNNode` is a test harness and a candidate for deprecation.

**Files:**
- Create: `Sources/ReTiCANode/PNPeerTable.swift`
- Modify: `Sources/ReTiCA/LXMF/PropagationStore.swift:280-311` (`offerCandidates` gains `among candidates: Set<Data>? = nil`; nil = today's behaviour)
- Modify: `Sources/ReTiCANode/PNNode.swift:305-320` (use `OfferResponse.parse`; no behaviour change)
- Create: `Tests/ReTiCANodeTests/Vectors/generate_lxmf_peer_state_fixtures.py` + JSON
- Test: `Tests/ReTiCANodeTests/PNPeerTableTests.swift`

**Interfaces (produced; Tasks 5-7 consume them):**

```swift
public struct PNPeerTable: Equatable, Sendable {
    public struct Config: Equatable, Sendable {
        public var autopeer = true; public var autopeerMaxDepth: UInt8 = 6; public var maxPeers = 20
        public var peeringCost = 18.0; public var maxRemotePeeringCost = 26.0
        public var staticPeers: Set<Data> = []
    }
    public enum PeerState: Equatable, Sendable { case idle, keyPending, linkEstablishing, linkReady, requestSent, transferring }
    public struct Peer: Equatable, Sendable {
        public var destinationHash: Data; public var peeringTimebase: Int; public var alive: Bool
        public var lastHeard: Date; public var lastSyncAttempt: Date?; public var nextSyncAttempt: Date
        public var syncBackoff: TimeInterval; public var syncTransferRate: Double
        public var announce: PNAnnounce?              // limits + costs; nil = costs unknown (static peer not yet heard)
        public var peeringKey: Data?; public var peeringKeyValue: Double?
        public var state: PeerState; public var linkID: Data?
        public var handled: Set<Data>; public var unhandled: Set<Data>
        public var lastOffer: [Data]; public var transferring: [Data]?
        public var offered: Int; public var outgoing: Int; public var incoming: Int
    }
    public enum Command: Equatable, Sendable {
        case openLink(Data), identify(linkID: Data), generatePeeringKey(peer: Data, cost: Double)
        case sendOffer(linkID: Data, key: Data, ids: [Data]), sendResource(linkID: Data, ids: [Data])
        case closeLink(Data), requestPath(Data)
    }
    public enum OfferResponse: Equatable, Sendable {
        case noIdentity, noAccess, throttled, wantsNone, wantsAll, wants([Data]), other
        public static func parse(_ data: Data, offered: [Data]) -> OfferResponse   // wants = response ∩ offered, offered order
    }
    public var config: Config
    public private(set) var peers: [Data: Peer]
    public init(config: Config)
    public mutating func announceHeard(_ dest: Data, announce: PNAnnounce, hops: UInt8, isPathResponse: Bool, now: Date)   // Handlers.py:56-107
    public mutating func peer(_ dest: Data, announce: PNAnnounce, now: Date)          // LXMRouter.py:2340-2383
    public mutating func unpeer(_ dest: Data, timebase: Int?, now: Date)             // :2385-2394
    public mutating func distribute(_ ids: [Data], from source: Data?)               // flush_peer_distribution_queue :2811-2824
    public mutating func markHandled(_ ids: [Data], for peer: Data)
    public mutating func prune(toStored stored: Set<Data>)                           // from_bytes drops ids not in the store, LXMPeer.py:118-128
    public mutating func syncTick(now: Date, random: inout some RandomNumberGenerator) -> [Command]   // sync_peers :2468-2521 incl. cull
    public mutating func keyReady(peer: Data, key: Data, value: Double, now: Date) -> [Command]
    public mutating func linkEstablished(peer: Data, linkID: Data, now: Date) -> [Command]        // LXMPeer.link_established + sync()
    public mutating func offerSelected(peer: Data, offer: [Data], oversized: [Data], lowValue: [Data]) -> [Command]
    public mutating func offerResponse(linkID: Data, _ response: OfferResponse, now: Date) -> [Command]  // LXMPeer.py:405-495
    public mutating func transferConcluded(linkID: Data, bytes: Int, now: Date) -> [Command]     // :497-530
    public mutating func transferFailed(linkID: Data)                                           // :531-537
    public mutating func linkClosed(linkID: Data)                                               // :549-551
    public mutating func linkFailed(peer: Data, now: Date)                                     // no path / establish failure: backoff, alive = false
    public mutating func requestFailed(linkID: Data) -> [Command]                              // :400-403
    public var persisted: [Peer] { get }
    public mutating func rehydrate(_ peers: [Peer], stored: Set<Data>)
}
```

When `linkEstablished` returns an empty command list, the host is expected to call `offerSelected` next with `store.offerCandidates(..., among: peer.unhandled, excluding: peer.handled, ...)`. Document this on `linkEstablished`.

**Ruling 4b (unhandled semantics):** the table keeps reference's explicit per-peer `unhandled` set. Ids enter it only through `distribute`, which the host calls on fresh ingest. A peer added later is *not* offered the existing store. `PNNode` keeps its current "whole store minus handled" behaviour. *Cost if wrong:* entries stored before a peering never reach that peer through us. This matches reference, where they reach it through the peers that already had them.

**Ruling 4c (rotation deferred):** `rotate_peers` (`LXMRouter.py:2396-2466`) is not implemented. *Cost if wrong:* once 20 peers are held, a new node can only take a slot freed by the 14-day unreachable cull or an unpeer. A phone rarely sees 20 PNs within 6 hops.

**Ruling 4d (sync selection randomness):** `syncTick` takes the random generator as a parameter, so tests pin the choice. It implements `sync_peers` exactly: the waiting pool is the 2 fastest peers plus up to that many unknown-speed peers, then one is picked at random; if no peer is waiting, it picks from the unresponsive peers that are past their backoff.

- [ ] **Step 1: Generator.** Use real `LXMFPropagationAnnounceHandler.received_announce`, `LXMRouter.peer/unpeer/sync_peers` and `LXMPeer.sync/offer_response/resource_concluded/request_failed/link_established`, with network edges stubbed as in `generate_lxmf_pn_offer_limits_fixtures.py` (has_path, hops_to, the Link stub recording request/teardown/identify, a key marked ready, `random.randint` patched to a recorded sequence). Cases:
  - announce at depth 6 / 7; a path response for an unknown node and for a static peer with `last_heard == 0`;
  - `node_state` false (unpeer); peering cost 27 > 26 (refused, or unpeered when already a peer); the 21st peer refused;
  - every offer-response kind (`0xf0`, `0xf1`, `0xf6`, `False`, `True`, a partial list, `0xf3`), recording handled/unhandled/state/next_sync_attempt delta/unpeered/identify-resent;
  - concluded with the persistent strategy and unhandled remaining (re-sync);
  - the 14-day cull, static vs not;
  - sync selection among 5 waiting peers with recorded rates and randint;
  - no path after grace → backoff 720 s and alive false.
- [ ] **Step 2: Failing tests**, one parameterized `@Test` per fixture group, comparing the table's state and commands to the fixture. Also: `offerCandidatesAmongRestrictsToTheGivenIds`, and `pnNodeOfferResponseUnchanged` (the existing `PNNode*` suites must pass untouched; run them in Step 4).
- [ ] **Step 3: Run and confirm they fail.** `swift test --filter PNPeerTableTests`.
- [ ] **Step 4: Implement**, then run `swift test --filter PNPeerTableTests` and `swift test --filter PNNode` (both must PASS, and no `PNNode*` test file may change).
- [ ] **Step 5: Mutation, revert and green.** Mutate in one batch: depth `<=` → `<`, throttle 300 → 0, `False` marks nothing, cull ignores static peers. Then commit (`feat(pn): PNPeerTable, reference peer state machine`).

### Task 5: `LXMFServiceNode` answers `/offer` and accounts for inbound syncs (library)

**Files:**
- Modify: `Sources/ReTiCANode/LXMFServiceNode.swift` (State gains `peering: PNPeerTable`, `validatedOfferLinks: Set<Data>`; `/offer` arm beside `/get` at `:306-389`; `.resourceReceived` `:227-229`; `pnAnnounceAppData` `:162-174` advertises `state.peering.config.peeringCost`)
- Create: `Tests/ReTiCANodeTests/Vectors/generate_lxmf_offer_responder_fixtures.py` + JSON
- Test: `Tests/ReTiCANodeTests/LXMFServiceNodeOfferTests.swift`

**Interfaces:**
- Consumes: `PNPeerTable` (Task 4), `LXStamper.validatePeeringKey(peeringId:peeringKey:targetCost:)` (`LXStamper.swift:170`), `PropagationStore.wanted(fromOffered:)` (`:332`), the error constants (Task 1).
- Produces: `LXMFServiceNode.State.init(..., peering: PNPeerTable.Config = .init())`. Inbound peer receipts call `peering.markHandled(_, for: source)`, and every fresh ingest calls `peering.distribute(added, from: source)`, where `source` is the sending peer's propagation hash if it is in `peering.peers`, else nil.

**Ruling 5a (admission control stays out):** `ERROR_THROTTLED`, sequential validation, `max_inbound_syncs`, `throttled_peers` and `from_static_only` are not implemented (survey X4). *Cost if wrong:* a junk-flooding peer is not throttled. That is the existing, filed gap.

**Ruling 5b (malformed offer):** any `/offer` body that is not an array of at least 2 elements with a bin key gets `ERROR_INVALID_DATA`. Reference's own check is `type(data) != list and len(data) < 2`, which falls through to an exception and answers `None`. *Cost if wrong:* none, since no reference peer sends one.

**Ruling 5c (key validation is synchronous):** the responder validates in the reducer, as reference does in the handler. That is one 6 400-byte workblock and one hash. The `PropagationNode.validatePeeringKey` round trip that `PNNode` uses is not used here.

- [ ] Generator: drive real `LXMRouter.offer_request` (a router with `enable_propagation`, `peering_cost` = 8 so keys are cheap, real `LXStamper.generate_stamp(..., expand_rounds=WORKBLOCK_EXPAND_ROUNDS_PEERING)` keys from a real peer identity). Cases: no identity; malformed; key valid at 7 against 8; all held → `False`; none held → `True`; partial → list; then `propagation_resource_concluded` with 2 messages on an unvalidated link (teardown, nothing stored) and on a validated one, and auto-peer-via-incoming-sync with the remote announce at depth 6 / 7. Record the response bytes as packed by reference.
- [ ] Tests:
  - one per fixture case, comparing response bytes to the fixture;
  - Review Focus 4 (`underCostKeyGetsInvalidKeyAndItsMultiEntryContainerIsRefused`);
  - `offerOnDeliveryLinkOrWithNodeModeOffIsIgnored`;
  - `ingestFromPeerMarksItHandledForThatPeerAndUnhandledForOthers`;
  - `clientSingleEntryUploadStillAcceptedWithoutKey`;
  - `announceAdvertisesPeeringCost18`. Update the existing `LXMFServiceNodeTests` assertion of peering cost 0, saying why in the test's comment.
- [ ] Mutation, revert and green. Commit (`feat(pn): the service node answers /offer and accounts inbound syncs`).

### Task 6: `LXMFServiceNode` peers outward: autopeer, static peers, sync job, keys, persistence hooks (library)

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (emit `.announceReceived` beside both `.pathLearned` sites, `:1429` and `:1485`)
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift` (Delegate `:216-244` gains the forward)
- Modify: `Sources/ReTiCANode/LXMFServiceNode.swift` (sync timer, command interpreter, key cache, persistence actions/delegate, teardown on `setNodeMode(false)` `:177-211`)
- Test: `Tests/ReTiCANodeTests/LXMFServiceNodePeeringTests.swift`, `Tests/ReTiCANodeTests/LXMFServiceNodePeeringSliceTests.swift`

**Interfaces:**
- Produces: `Transport.Action.Delegate.announceReceived(destinationHash: Data, hops: UInt8, isPathResponse: Bool)` and the same case on `TransportEndpoint.Action.Delegate`. It is emitted exactly where `.pathLearned` is, because reference invokes announce handlers inside its path-update branch (`SP/RNS/Transport.py:2756-2806`).
- Produces: `LXMFServiceNode.Action.peerSyncTick`, `.peeringKeyReady(peer: Data, key: Data, value: Double)`, `.rehydratePeers([PNPeerTable.Peer])`, `.setStaticPeers(Set<Data>)`, `.setAutopeer(Bool)`, `.rehydrateStore(entries: [Data])` (ingest **without** `distribute`), and `Delegate.peersChanged([PNPeerTable.Peer])` (emitted after any table mutation that changes `persisted`, coalesced to one per action).
- Consumes: `LXStamper.generatePeeringKey(peeringId:targetCost:)` (`LXStamper.swift:180`) for `.generatePeeringKey`, cancellable per peer. Get the value with `LXStamper.stampValue(workblock:stamp:)` over the peering workblock.

**Ruling 6a (`autopeer_maxdepth` = 6):** use lxmd's written default rather than the `LXMRouter` default of 4. *Cost if wrong:* we peer with nodes 5-6 hops away that Sideband's embedded router would skip, which means more sync traffic on a phone.

**Ruling 6b (the job runs only in node mode):** the 24 s `peerSyncTick` timer runs only while `nodeModeEnabled`. `setNodeMode(false)` cancels the timer and every key search, and closes peer links in `linkEstablishing`/`linkReady`/`requestSent`. The table is kept, with nothing unpeered. *Cost if wrong:* none at the peer, which sees a closed link and retries later.

**Ruling 6c (key cache):** a peer's key is kept with its value and regenerated only when `value < peer.announce.peeringCost` (`LXMPeer.py:229-238`). It is persisted with the peer (Task 7). *Cost if wrong:* a relaunch without persistence would regenerate up to 20 keys at cost 18, which is minutes of CPU on a phone.

**Ruling 6d (static peers):** `.setStaticPeers` adds a table entry with `announce = nil` and issues a path request for any entry never heard (`LXMRouter.py:728-737`). A static peer is never culled. Its costs come from its announce or path response (`Handlers.py:76-86`). Reference keeps a static peer even past `max_peers`, and so do we.

- [ ] Tests:
  - `announceAtDepth6PeersAt7DoesNot` and `pathResponseDoesNotAutopeerButFeedsAStaticPeer`, end to end through `Transport.announceReceived`;
  - `syncTickOpensOneLinkAfterKeyReady`, where the key search runs before any link, as in reference `sync()`;
  - `offerGoesOutWithCachedKeyAndOnlyUnhandledIds`;
  - `noIdentityResponseReidentifiesAndReoffersOnSameLink`;
  - `noAccessUnpeers`;
  - `throttledPostpones300s`;
  - `concludedTransferResyncsWhenUnhandledRemain`;
  - `linkFailedBacksOff720sAndMarksNotAlive`;
  - Review Focus 5 (`nodeModeOffMidSyncStopsJobCancelsKeyAndSendsNothing`);
  - Review Focus 3 (`rehydrateStoreThenPeersMarksNothingUnhandled`);
  - `peersChangedEmittedOncePerMutatingAction`.
- [ ] **Whole-slice probe** (`LXMFServiceNodePeeringSliceTests`): two `LXMFServiceNode`s with node mode on, joined over the loopback TCP server/client pair the existing multi-interface slice tests use. Each hears the other's announce. A client message is ingested at A. Within ticks, B holds it, A marks it handled for B, and a client of B downloads it with `/get`. This exists because per-task tests drive one host, and the seam (command interpreter ↔ endpoint ↔ the peer's responder) is where defects hide.
- [ ] **Gated live check:** extend `LiveAuthPNSyncTests` (Task 1) with `liveLxmdPeersWithServiceNode`. lxmd (rns-latest, default config, `enable_node = yes`) and our node announce. Message for a client stored at lxmd → our node receives it through lxmd's offer, and vice versa. Read lxmd's log for "Peered with" and for the "Syncing N messages to peer … completed" line. Record ran/skipped.
- [ ] Mutation, revert and green. Commit (`feat(pn): the service node auto-peers and syncs to peers`).

### Task 7: Peering in ReTiCAMsgr: settings and persistence (app)

**Files:**
- Create: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/PNPeerRow.swift` (GRDB row: peer hash hex PK, msgpack-encoded `PNPeerTable.Peer` blob; encoder/decoder live here)
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/Database.swift` (migration)
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/AppFeature.swift`. `@Shared(.appStorage("propagationAutopeer")) autopeerEnabled = true` and `@Shared(.appStorage("propagationStaticPeers")) staticPeerHexes: [String] = []` go beside `nodeModeEnabled` at `:278`. `.node(.delegate(.peersChanged))` writes the rows. Launch rehydration at `:3019-3024` changes to `.node(.rehydrateStore(entries:))`, then `.node(.rehydratePeers)`, then the existing `setNodeMode(true)` at `:1556-1557`, in that order.
- Modify: `ReTiCAMsgr/SettingsView.swift:493-501` (Run as Propagation Node section)
- Modify: `ReTiCAMsgrCore/Sources/ReTiCAMsgrCore/DiagnosticsSnapshot.swift:709` (add a "pn peers" row)
- Test: `ReTiCAMsgrCore/Tests/ReTiCAMsgrCoreTests/PropagationPeeringTests.swift`

**Settings that change (Ruling 7):**
- In the "Run as Propagation Node" section, shown only while node mode is on:
  - a toggle "Peer with other propagation nodes" (autopeer, default **on**);
  - a "Static peers" list with an add field that uses the same validation as the PN address field (`isValidPeerAddress`) and swipe-to-delete;
  - a read-only line "Peered with N nodes".
- Not exposed: peering cost (18), remote cost cap (26), max peers (20), max depth (6). They are fixed at lxmd defaults.
- The node-mode caption at `:498` becomes: "Stores and forwards messages for other users while this app is open, and exchanges them with nearby propagation nodes."

*Cost if wrong:* an operator cannot tune costs or limits. Autopeer being on by default spends data and battery for users who turned node mode on; node mode itself stays off by default. Rows follow `.frame(maxWidth: .infinity, alignment: .leading).contentShape(Rectangle())` (user rule) wherever a row is tappable.

- [ ] Tests:
  - a launch with 3 persisted peers and stored entries sends rehydrate store → rehydrate peers → node mode, in that order (Review Focus 3 at the app seam);
  - `peersChanged` upserts and removes rows;
  - the toggle and static-peer edits send `.setAutopeer` / `.setStaticPeers`;
  - a round-trip of `PNPeerTable.Peer` through the row blob is lossless, including `peeringKey`, handled/unhandled and dates.
- [ ] Mutation, revert and green. Commit in the app repo (`feat: propagation node peering settings and peer persistence`).

### Task 8: Non-expanded workblock stamps: pin LXMF 1.3.0's rejection (library, tests only)

**Ruling 8 (tolerance item, not acceptance):** LXMF 1.3.0 neither produces nor accepts non-expanded stamps (Survey corrections). Accepting them now would make every stamp ReTiCA enforces orders of magnitude cheaper to forge, because a reference 1.3.0 peer still rejects them. This batch therefore adds acceptance nowhere. It pins the current rejection with reference-driven fixtures, so that the later change will be a deliberate one. **Trigger to revisit:** a released LXMF (not master) whose `generate_stamp` callers pass `no_expand=True`. When that happens, add acceptance in `LXMessage.validateStamp` (`LXMessage.swift:172, 204`), `LXStamper.validatePnStamp` (`:207`) and `LXStamper.validatePeeringKey` (`:170`) in the same order as reference: non-expanded first. *Cost if wrong:* if such a release ships before we act, ReTiCA rejects its enforced delivery stamps (the sender falls back or fails) and, as a PN, answers `ERROR_INVALID_STAMP`.

**Files:**
- Create: `Tests/ReTiCATests/Vectors/generate_lxmf_non_expanded_stamp_fixtures.py` + JSON
- Test: `Tests/ReTiCATests/Vectors/LXStamperNonExpandedCrossValidationTests.swift`

- [ ] Generator: for a message id, a transient id and a peering id, `RNS.Stamps.generate_stamp(material, cost=12, no_expand=True, size=32)`. Assert in the generator that the expanded value is below 12 (regenerate otherwise, so the case is not an accidental expanded pass). Record that `LXMessage.validate_stamp`, `LXStamper.validate_pn_stamp` and `LXStamper.validate_peering_key` in 1.3.0 all reject it at 12, and that each one's non-expanded `stamp_valid` at 12 is true.
- [ ] Tests: `nonExpandedStampsRejectedLikeLXMF130` (three validators, all false or nil), plus `fixtureStampIsValidNonExpanded`. The second uses `LXStamper.stampValid(stamp:targetCost:workblock: material)` and keeps the first test from passing vacuously.
- [ ] Mutation: make `stampWorkblock` return `material` when called from the validators. The rejection tests must fail. Revert, green. Commit (`test(lxmf): pin LXMF 1.3.0 rejection of non-expanded workblock stamps`).

### Task 9: Tunnels: client-side synthesis (library); the hub side goes to a separate plan

**Scope ruling (9):** a phone benefits from the **client half** only. It sends one signed synthesis packet on each TCP connect, so the hub (reference rnsd) restores its paths to our destinations at once (`handle_tunnel`, `Transport.py:3099-3155`) instead of waiting for our re-announce, which hubs rate-limit. The **hub half** needs:
- a tunnel table with expiry (`TUNNEL_TIMEOUT` / `TUNNEL_PATH_TIMEOUT` 8 h, `Transport.py:234-235`);
- path capture for announces arriving on a tunnelled interface (`:2738-2749`);
- the restore logic with timebase comparison (`:3116-3155`);
- culling (`:1196-1246`) and persistence (`:4382-4463`).

The hub half matters only for `TCPServerEndpoint` in relay mode. It is about M-L in size. **Recommend a separate plan** for it (`tunnel-hub`), which should also decide whether ReTiCA persists tunnels at all.

**Ruling 9b (tunnel identity):** synthesis needs a persisted Ed25519 transport identity. A leaf has none: `transportIdentity` is nil and turning it on flips relay behaviour (`Transport.swift:56, 130-136`). We add a separate `tunnelIdentity`, generated and persisted by the host. It is used only to sign synthesis packets. *Cost if wrong:* the hub sees a different "transport identity" from the one in our path requests. Leaves send random path-request sender IDs anyway, so nothing correlates them.

**Ruling 9c (interface hash):** `interfaceHash = full_hash(UTF-8 of "TCPInterface[<profile.name>]")`. It must be stable across reconnects of one configured node entry, because the tunnel id depends on it. It need not equal reference's `str(interface)`, since only we compute it. *Cost if wrong:* if the name changes when a user edits the node entry, the hub sees a new tunnel and restores nothing once.

**Files:**
- Modify: `Sources/ReTiCATransport/InterfaceProfile.swift` (`public var wantsTunnel: Bool = false`)
- Modify: `Sources/ReTiCATransport/Transport.swift` (State `tunnelIdentity: Identity?`; `.setTunnelIdentity`; on `.interfaceConnected(id, profile)` with `profile.wantsTunnel` and a tunnel identity, transmit the synthesis packet on `id` only)
- Modify: `Sources/ReTiCANode/TCPEndpoint.swift` (client profiles set `wantsTunnel = true`); `TransportEndpoint.swift` (forward `setTunnelIdentity`)
- App: `ReTiCAMsgrCore/.../IdentityStore.swift` or the keychain store already used for the identity: generate and persist the tunnel identity once, then send `.setTunnelIdentity` at launch before `.endpoint(.start)`
- Create: `Tests/ReTiCATransportTests/Vectors/generate_tunnel_synthesis_fixtures.py` + JSON
- Test: `Tests/ReTiCATransportTests/TunnelSynthesisTests.swift`

**Interfaces:**
- Produces: `Transport.tunnelSynthesisPayload(identity: Identity, interfaceHash: Data, randomHash: Data) -> Data` (176 bytes), `Transport.tunnelID(publicKey: Data, interfaceHash: Data) -> Data`, `Transport.Action.setTunnelIdentity(Identity?)`.

- [ ] Generator: a fixed private identity, a fixed interface hash, and `RNS.Identity.get_random_hash` patched to a fixed value. Capture the packet from a real `Transport.synthesize_tunnel` with a stub interface whose `get_hash` returns the fixed hash, and `Packet.send` patched to record `packet.raw`. Record the raw packet, the PLAIN destination hash, `tunnel_id`, and the result of feeding the payload to the real `tunnel_synthesize_handler` (the tunnel created, with a stub `handle_tunnel` recording the id).
- [ ] Tests:
  - `payloadPrefixMatchesReference`: bytes 0..<112 are identical; the signature is validated, not byte-compared, because ReTiCA's Ed25519 is hedged;
  - `rawPacketHeaderMatchesReference`: flags, hops, destination hash, context;
  - `tunnelIDMatchesReference`;
  - `synthesisSentOnEveryConnectOfTunnelInterfaceOnly`: a reconnect under the same id sends again; a BLE or Auto interface never sends;
  - `noTunnelIdentityNoPacket`.
- [ ] Mutation, revert and green. Commit (`feat(transport): synthesize a tunnel on each TCP client connect`). Then, in the app repo, commit the identity wiring with its own test (identity generated once and reused across relaunches).

---

## Status

(Fill in on completion: commits, rulings that changed, live checks run or skipped, and the `tunnel-hub` and admission-control follow-ups.)
