# LXMF Propagation — 3-Store Capstone Loop Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** One test proving the whole store-and-forward loop over real transport: real `LXMFNode` sender → `PNNode` ingest → real `LXMFNode` recipient sync.

**Architecture:** Test-only. Three `TestStore`s (S=`LXMFNode`, PN=`PNNode`, R=`LXMFNode`) bridged over the mock-TCP harness, exercising two link sessions (S↔PN Resource ingest; R↔PN `/get` sync). No production changes.

**Tech Stack:** Swift, Point-Free Composable Architecture (TCA), Swift Testing (`@Test`/`#expect`), `swift test`.

## Global Constraints

- **Commit directly to `main`** — no feature branch, no merge dance.
- **No compound shell commands** — one command per invocation. Write files with the editor, not echo/heredoc.
- **Temp files** go in `/tmp/ReTiCA/`.
- **Commit trailers, verbatim, at COLUMN 0 (no leading whitespace)**, via `git commit -F <file>` (never `-m`):
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```
  Verify after commit: `git log -1 --format='%(trailers:key=Claude-Session,valueonly=true)'` must print the URL.
- **Mutation verification** for the capstone: mutate production, confirm the test breaks, revert so production is UNCHANGED at commit (this slice commits only the test file).
- **Non-exhaustive TCA tests** (`store.exhaustivity = .off`).
- **Ed25519/hedged** — never byte-compare a signature; assert `signatureValidated == true` (real validation) + deterministic content/title/sourceHash.
- **Scope:** the one test only. No production change.
- **If the capstone reveals a real integration bug** (a stub hid a fidelity gap), STOP and report BLOCKED with the specifics — do NOT change production to force the test green without the controller adjudicating.
- If `swift test` shows a stale cross-module link error, run `swift package clean` then retry.

---

### Task 1: 3-store capstone integration test

**Files:**
- Create: `Tests/ReTiCANodeTests/LXMFPropagationCapstoneTests.swift`

**Interfaces (all existing):**
- `LXMFNode`: `.registerDelivery`, `.setPropagationNode(destinationHash:)`, `.sendViaPropagation(destinationHash:title:content:)`, `.syncFromPropagationNode`, delegate `.messageReceived(message:signatureValidated:)`.
- `PNNode`: `.registerPropagation`, delegate `.messagesStored(transientIds:)`; `PNNode.State(identity:endpoint:)`.
- `LXMessage.deliveryHash(identityHash:)`; `LXMFPropagation.transientId`/`.parseContainer` (for optional en-route assertions).

- [ ] **Step 1: Study the bridge models.**

READ these first (do not skip) — the capstone is their union:
- `Tests/ReTiCANodeTests/LXMFNodePropagationTests.swift` — `LXMFNode` client → bare-`Endpoint` PN: announce bridging + link handshake + Resource (container) transfer. This is the **S↔PN ingest** half (but PN here is a real `PNNode`).
- `Tests/ReTiCANodeTests/LXMFNodeSyncTests.swift` — `LXMFNode` client sync → stub PN: IDENTIFY + two-phase `/get` request/response + open. This is the **R↔PN sync** half (client side).
- `Tests/ReTiCANodeTests/PNNodeIntegrationTests.swift` — bare-`Endpoint` client ↔ `PNNode`: the PN-server side of `/get` (ingest + serve). This is the **PN side** of both halves.
- `Tests/ReTiCANodeTests/PNNodeMeshTests.swift` — two `PNNode`s over a real link (link-initiation + handshake bridging reference).

Note the recurring gotcha: a chain of synchronous effects can emit MULTIPLE `interface.send` within one `await receive` — capture such frames by index off a snapshot taken before bridging, not `sent.value.last!`.

- [ ] **Step 2: Write the capstone test.**

Create `Tests/ReTiCANodeTests/LXMFPropagationCapstoneTests.swift`. Three stores: S and R are `LXMFNode`; PN is a `PNNode`. Model the harness `make*` helpers on the referenced tests (mock `TCPConnection` writing to a per-store `LockIsolated<[Data]>`, `TestClock`, `$0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))`, `$0.uuid = .incrementing`, `store.exhaustivity = .off`).

Structure (the implementer fills in the exact `receive`/bridge interleaving by running):

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

/// Full store-and-forward loop over real transport: real LXMFNode sender S sends a message to recipient R
/// VIA a real PNNode PN; PN ingests it; R (real LXMFNode) syncs from PN and receives S's signature-valid
/// message. Proves the P1 send + P3b ingest + P3b serve + P2 sync compositions interoperate end-to-end
/// (each half previously proven only against a stub of the other).
@Test @MainActor func lxmfPropagationCapstoneSenderPnRecipient() async {
    let clock = TestClock()
    let sIdentity = Identity()      // sender
    let rIdentity = Identity()      // recipient
    let pnIdentity = Identity()     // propagation node
    let rDeliveryHash = LXMessage.deliveryHash(identityHash: rIdentity.hash)
    let sDeliveryHash = LXMessage.deliveryHash(identityHash: sIdentity.hash)
    let pnPropDest = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                 aspects: ["propagation"], identity: pnIdentity)!

    // makeNode(_ host:_ identity:_ sent:) -> (TestStore<LXMFNode.State, LXMFNode.Action>, continuation)
    // makePN(_ host:_ identity:_ sent:)  -> (TestStore<PNNode.State, PNNode.Action>, continuation)
    // ... build (s, eventsS, sentS), (pn, eventsPN, sentPN), (r, eventsR, sentR); connect all three ...

    // --- Announces: S learns R's identity + PN; R learns S's identity + PN ---
    // R.registerDelivery → announce → bridge to S     (S needs R identity to encrypt the container)
    // S.registerDelivery → announce → bridge to R     (R needs S identity to validate the signature)
    // PN.registerPropagation → announce → bridge to S AND to R  (both link to PN)

    // --- SEND (S → PN ingest): P1 send + P3b ingest, both real ---
    // S.setPropagationNode(pnPropDest.hash)
    // S.sendViaPropagation(destinationHash: rDeliveryHash, title:, content:)
    // → bridge S↔PN link handshake + Resource(container) transfer (model: LXMFNodePropagationTests)
    // → assert PN.delegate(.messagesStored) contains the container's tid

    // --- SYNC (R ← PN serve): P2 sync + P3b serve, both real ---
    // R.setPropagationNode(pnPropDest.hash)
    // R.syncFromPropagationNode
    // → bridge R↔PN link handshake + IDENTIFY + /get [null,null] (PN serves list) + /get [[tid],[]] (PN serves blob)
    //   (models: LXMFNodeSyncTests [R side] + PNNodeIntegrationTests [PN side])
    // → R opens the blob → R.delegate(.messageReceived(m, v))

    let gotContent = LockIsolated<Data?>(nil)
    let gotSrcHash = LockIsolated<Data?>(nil)
    let gotValidated = LockIsolated<Bool>(false)
    // await r.receive matching .delegate(.messageReceived(m, v)) → capture m.content, m.sourceHash, v

    #expect(gotContent.value == Data("store and forward".utf8))       // == what S sent
    #expect(gotSrcHash.value == sDeliveryHash)                        // from S
    #expect(gotValidated.value == true)                              // R learned S → signature validates

    // disconnect all
}
```

Use a SHORT message content (e.g. `Data("store and forward".utf8)`) so the `/get` responses stay inline; the ingest container transfers as a Resource regardless.

- [ ] **Step 3: Run the capstone; confirm green.**

Run: `swift test --filter lxmfPropagationCapstoneSenderPnRecipient`
Expected: PASS. Reconcile the intermediate `receive` predicates / index-based frame captures to the real emission order; do NOT change the final assertions. (`swift package clean` first if it stale-links.)

If the test cannot be made to pass because of a genuine integration mismatch between the real compositions (not a bridging/interleaving issue in the test), STOP: write up the specific mismatch in the report and return BLOCKED — do not alter production to force it green.

- [ ] **Step 4: Mutation-verify (one at a time, revert between each; production reverted before commit).**

- Mutation A — break PN serve: in `PNNode`'s `messagesRequested` phase-2 handler (or its `deliverMessages` wire), return no entries. Run the Step 3 filter → must FAIL (R never gets the blob → no `messageReceived`). Revert → PASS.
- Mutation B — break R's sync open: in `LXMFNode`'s `responseReceived` `.awaitingMessages` branch, skip the `router.received(.direct, …)` feed. Run → must FAIL (R can't reconstruct S's message). Revert → PASS.

- [ ] **Step 5: Run the full ReTiCANode suite; confirm green.**

Run: `swift test --filter ReTiCANodeTests`
Expected: all PASS.

- [ ] **Step 6: Commit.** (column-0 trailers; verify parse after)

Write `/tmp/ReTiCA/commit-msg-capstone-task1.txt`, then:
```bash
git add Tests/ReTiCANodeTests/LXMFPropagationCapstoneTests.swift
git commit -F /tmp/ReTiCA/commit-msg-capstone-task1.txt
```
Suggested subject: `test: LXMF propagation 3-store capstone loop (sender → PN → recipient)`

---

## Self-Review

**Spec coverage:**
- 3 real stores (S/R `LXMFNode`, PN `PNNode`) → Task 1 Step 2. ✅
- Four announce bridges (R.delivery→S, S.delivery→R, PN.propagation→S+R) → Step 2. ✅
- SEND half (sendViaPropagation → S↔PN link + Resource → PN messagesStored) → Step 2. ✅
- SYNC half (syncFromPropagationNode → R↔PN link + IDENTIFY + 2-phase /get → messageReceived) → Step 2. ✅
- Load-bearing assertion (R gets S's content/sourceHash + validated==true) → Step 2. ✅
- No production change; BLOCKED-on-real-mismatch guard → Global Constraints + Step 3. ✅
- Signature validated not byte-compared → Step 2. ✅

**Placeholder scan:** the test is a structured sketch with concrete identities, exact announce/flow steps, named source models to copy bridges from, and fixed final assertions — the standard shape for this project's multi-store integration tests (reconciled by running). No production placeholders.

**Type consistency:** `setPropagationNode(destinationHash:)`, `sendViaPropagation(destinationHash:title:content:)`, `syncFromPropagationNode`, `registerDelivery`, `.messageReceived(message:signatureValidated:)`, `PNNode.registerPropagation`, `.messagesStored(transientIds:)`, `LXMessage.deliveryHash(identityHash:)`, `Destination(kind:direction:appName:aspects:identity:)` all match the current sources.
