# Single-Packet Delivery Proofs Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** ReTiCA proves inbound opportunistic LXMF packets the way reference does, tracks receipts for its own opportunistic sends so a valid proof yields `deliveryConfirmed`, keeps the delivery copy and the propagated copy of one message apart in the router, and reports how each inbound message arrived.

**Architecture:** `Transport` gains a one-shot prover (`.proveSingle`), a receipt table (`pendingReceipts`) filled by `.send(..., receiptToken:)` and drained by a new inbound `.proof` case, and a `singlePacketDelivered(token:)` delegate. `TransportEndpoint` forwards all of it. `LXMFNode` proves inbound opportunistic packets for its delivery destination before routing them, and threads `message.hash` as the receipt token. `LXMFRouter` keys pending deliveries by `(messageHash, leg)`, reports each copy's success independently, fails a message only when every copy has failed and none succeeded, and carries the arrival method on `messageDelivered`.

**Tech Stack:** Swift 6 / SwiftPM, swift-composable-architecture (`TestStore`, `TestClock`, `@Dependency`), Swift Testing, CryptoKit (hedged Ed25519 via `Identity.sign`). Python 3 from the conda `rns` env (RNS 1.4.2 / LXMF 1.1.0) only to generate the proof fixture.

**Spec:** `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md` (binding — read it first).

## Global Constraints

- **Where:** all ReTiCA work happens ONLY in the worktree `/Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs` on branch `feat/single-packet-proofs`. Never read-modify-write, build, or run git commands against `/Users/ell/development/ios/pods/ReTiCA` (another agent owns it). `WT` below means that worktree path.
- **Task 0 is a gate.** Nothing starts until the branch is rebased on the latest `main` and the full baseline `swift test --package-path WT` is green. If `main`'s tests don't compile or fail, STOP and report.
- **Commits** go on `feat/single-packet-proofs` (never `main`). Stage explicit paths only. Write the message to `/tmp/ReTiCaMsgr/commit-msg.txt` with the Write tool, then `git -C WT commit -F /tmp/ReTiCaMsgr/commit-msg.txt`. Message = `feat:`/`fix:`/`test:`/`docs:` subject, blank line, optional body, blank line, then exactly these two lines at column 0:
  `Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>`
  `Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1`
  No semicolons anywhere in a commit message (a hook rejects them).
- **Shell:** one command per Bash call. No `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreters (`python -c`, heredocs into an interpreter). Scripts and sed scripts go in files under `/tmp/ReTiCaMsgr/` (create it with `mkdir -p /tmp/ReTiCaMsgr` if missing). `sed -i '' -f /tmp/ReTiCaMsgr/x.sed file1 file2` is one command and is allowed.
- **Tests:** `swift test --package-path WT` (full) or `swift test --package-path WT --filter A --filter B` (`--filter` is repeatable). Filtering still compiles every target, so the whole package — all sources and all tests — must compile at the end of every task. Every new test function name starts with its task's prefix (`proofVector`, `inboundProving`, `receiptTable`, `proofValidation`, `routerLeg`, `opportunisticReceipt`, `copyOutcome`, `arrivalMethod`, `proofEndToEnd`) so `--filter <prefix>` selects exactly the task's new tests. None of these prefixes exist in the repo today.
- **Mutation verification is mandatory** for every task with tests: (a) run the new tests, all GREEN; (b) apply the task's listed mutation batch to production code in one go, run the listed filter once, confirm EVERY listed test is RED; (c) revert every mutation (`git -C WT diff` must show only the task's intended changes), run again, all GREEN. Only then commit. If a test survives its mutation, fix the test and restart at (a). Each task lists its batch, which test each mutation breaks, and why no two mutations mask each other or crash the process. Tests that were only edited mechanically to compile against a new shape (added `_` wildcards, added a constant argument) assert nothing new and are exempt; tests whose exact-value assertions changed are included.
- **Testing conventions** (match the neighbouring files): free `@Test @MainActor func` functions with Swift Testing, `TestStore` with `exhaustivity = .off` for positive flows and exact `receive(.action)` or predicate `receive { ... }`; flip to `.on` (or use an exhaustive store from the start) whenever the claim is an ABSENCE, so a stray action fails. Under `.off`, `receive` silently skips non-matching actions, so absence can never be asserted under `.off`.
- **Action ordering fact the tests rely on:** TCA processes synchronous `.send` effects breadth-first (FIFO `bufferedActions` in `Core.swift`), and `.merge(.send(a), .send(b))` enqueues `a` before `b`. The existing `LXMFNodeDeliveryProvingTests` already relies on this. Each test states the depth order it assumes.
- **Wire behaviour, verbatim from the spec:**
  - Proof packet: `Packet(headerType: .header1, packetType: .proof, transportType: .broadcast, destinationType: .single, context: .none, contextFlag: false, hops: 0, destinationHash: packetHash.prefix(16), transportId: nil, payload: identity.sign(packetHash))` — the 64-byte implicit form, unencrypted, emitted as `.delegate(.transmit(interfaceID, raw))` on the arrival interface. Nothing is emitted if the identity has no private key or the interface isn't registered.
  - `pendingReceipts` keyed by `packetHash.prefix(16)`; `PendingReceipt { packetHash (32 bytes), token, identity, expiresAt }`; `expiresAt = now + receiptTimeoutBase + receiptTimeoutPerHop * max(1, entry.hops)`; capped at `Transport.maxPendingReceipts`, evicting the soonest expiry.
  - Implicit proof = 64-byte signature over `receipt.packetHash`. Explicit proof = 96 bytes, `payload.prefix(32) == receipt.packetHash`, signature `payload.suffix(64)`. Anything else (unknown hash, bad signature, other length) → `.none`, receipt left in place. Valid → receipt removed, `.delegate(.singlePacketDelivered(token:))`. Proof packets are not deduped by `seenPacketHashes`.
  - `maintenanceTick` removes receipts with `expiresAt <= now` and emits NOTHING — the LXMF retry timer stays the only failure authority.
  - `TransportEndpoint` forwards `.singlePacketDelivered(token:)` as its own delegate; `packetDelivered(token:)` stays link-only.
  - Router: `DeliveryKey(messageHash: Data, leg: Leg)`, `enum Leg { case delivery, propagated }`. `deliveryFailed` fires only when every armed copy for that hash has failed, and never after either copy succeeded. Each success is reported independently.
- **Chosen values (spec left them open):** `receiptTimeoutBase = 6`, `receiptTimeoutPerHop = 6` (reference `DEFAULT_PER_HOP_TIMEOUT`, Reticulum.py:142), `maxPendingReceipts = 1024` (reference `MAX_RECEIPTS`, Transport.py:96), `LXMFRouter.succeededMessageMemory = 1024`.
- **Python:** `/Users/ell/opt/anaconda3/envs/rns/bin/python` (RNS 1.4.2). Reference sources: `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/`.
- **ReTiCaMsgr app** (Task 10 only). The work happens in a git worktree of the app repo:
  - Path: `/Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat`.
  - Branch: `feat/retica-proofs-compat`, created from the app's `main` in Task 10 Step 0.
  - Never commit in `/Users/ell/development/ios/apps/ReTiCaMsgr` itself.
  - The worktree is a sibling of `ReTiCaMsgr` on purpose. From there, `ReTiCaMsgrCore/Package.swift`'s committed relative path `../../../pods/ReTiCA` still resolves to `/Users/ell/development/ios/pods/ReTiCA`, the main ReTiCA checkout, not this worktree.
  - Commits follow the same trailer and `-F` rules and stage explicit paths only.
  - A fresh worktree has none of the main checkout's unrelated local changes (the xcuserdata plists and the untracked display-name plan). `git status` there should show only this task's files.

## Review Focus

Inputs the spec implies that its own examples don't exercise, most likely to bite first. Each is pinned by a test in the named task.

1. **A resend of a message the receiver already delivered** (a reference or ReTiCA sender whose first proof was lost) must be proved AGAIN, even though the receiver's router drops it as a duplicate — otherwise that sender retries until it gives up on a message that arrived. Tests: Task 2 `inboundProvingProvesADuplicateAgain`, Task 9 `proofEndToEndALostProofIsRecoveredByTheResend`.
2. **The propagated copy is armed late** — `sendMessage(alsoViaPropagation: true)` hands it to the router only after a propagation-stamp search that can take seconds to minutes, i.e. after the delivery copy may already be confirmed. If it then fails, no `deliveryFailed` may be reported. Test: Task 7 `copyOutcomeLateArmedPropagatedFailureAfterSuccessIsSilent`.
3. **No propagation node configured** while `alsoViaPropagation` is set: the propagated copy fails instantly. That must not report the whole message failed while the opportunistic copy is still pending (today it does). Test: Task 7 `copyOutcomeNoPropagationNodeDoesNotFailAPendingDeliveryCopy`.
4. **A copy still QUEUED behind its link** (not yet armed with a retry timer) is outstanding. The other copy running out must not fail the message, and a queued copy that gives up must not fail it while the other copy is pending. Tests: Task 7 `copyOutcomeQueuedPropagatedCopyKeepsTheMessageAlive`, `copyOutcomeGiveUpOnAQueuedCopyWaitsForTheOtherCopy`.
5. **Forged or malformed proofs** — wrong signer, an explicit proof with a valid signature but a mismatched embedded hash, a wrong length, an unknown hash — must be ignored AND must leave the receipt in place, so a later genuine proof still confirms. Tests: Task 4 `proofValidationWrongSignerIsIgnoredAndKeepsTheReceipt`, `proofValidationExplicitProofWithAMismatchedHashIsIgnored`, `proofValidationWrongLengthIsIgnored`, `proofValidationUnknownHashIsIgnored`.

---

## File Structure

ReTiCA (`WT`):

- `Sources/ReTiCATransport/Transport.swift` — `.proveSingle` action; `received` delegate gains `packetHash`/`interfaceID`; `.send` gains `receiptToken`; `State.PendingReceipt` + `pendingReceipts`; `recordReceipt`; inbound `.proof` case; `singlePacketDelivered` delegate; receipt sweep in `maintenanceTick`; receipt/proof constants.
- `Sources/ReTiCANode/TransportEndpoint.swift` — `.proveSinglePacket` action; `.send(... receiptToken:)`; `messageReceived` gains `packetHash`/`interfaceID`; `singlePacketDelivered` delegate.
- `Sources/ReTiCANode/LXMFRouter.swift` — `Leg`, `DeliveryKey`; re-keyed `pendingDeliveries`, `linkResourceInFlight`, retry `CancelID`; `.delivered(messageHash:leg:)`, `.retryDue(messageHash:leg:)`, `.opportunisticDelivered(messageHash:)`; `succeed`/`fail`/`isOutstanding`; `succeededMessages`; `sendOpportunistic` gains `messageHash`; `DeliveryMethod.propagated`; `messageDelivered` gains `method`.
- `Sources/ReTiCANode/LXMFNode.swift` — proves inbound opportunistic delivery packets; passes `receiptToken`; maps `singlePacketDelivered`, link receipts (→ `.propagated`); downloads fed as `.propagated`; `messageReceived` gains `method`.
- `Package.swift` — adds the `proof_fixtures.json` resource to `ReTiCATransportTests`.
- New tests: `Tests/ReTiCATransportTests/Vectors/generate_proof_fixtures.py`, `.../Vectors/proof_fixtures.json` (generated), `.../Vectors/ProofVectorFixtures.swift`, `.../Vectors/ProofCrossValidationTests.swift`, `Tests/ReTiCATransportTests/TransportSinglePacketProofTests.swift`, `Tests/ReTiCANodeTests/TransportEndpointSinglePacketProofTests.swift`, `Tests/ReTiCANodeTests/LXMFNodeSinglePacketProvingTests.swift`, `Tests/ReTiCANodeTests/LXMFRouterLegTests.swift`, `Tests/ReTiCANodeTests/LXMFOpportunisticReceiptTests.swift`, `Tests/ReTiCANodeTests/LXMFRouterCopyOutcomeTests.swift`, `Tests/ReTiCANodeTests/LXMFArrivalMethodTests.swift`, `Tests/ReTiCANodeTests/LXMFNodeSinglePacketProofEndToEndTests.swift`.
- Existing tests edited for new shapes (exact lists in each task): `TransportTests.swift`, `TransportEndpointTests.swift`, `BLEEndpointTests.swift`, `LXMFOpportunisticDeliveryTests.swift`, `BLEEndpointIntegrationTests.swift`, `TCPEndpointTests.swift`, `LXMFRouterTests.swift`, `StampWorkBoundsTests.swift`, `LXMFNodeDeliveryStampTests.swift`, `LXMFNodeInboundStampTests.swift`, `LXMFNodeOpportunisticTests.swift`, `LXMFNodeBLETests.swift`, `LXMFPropagationCapstoneTests.swift`, `LXMFNodeSyncTests.swift`, `LXMFNodeDirectTests.swift`.
- Docs: `docs/reference-gap-analysis-2026-08-10.md`, `docs/reference-parity-checklist.md`, `docs/superpowers/specs/2026-07-28-lxmf-opportunistic-path-request-design.md`.

ReTiCaMsgr (Task 10): `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift`, `.../DiagnosticsSnapshot.swift`, `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`, `.../DiagnosticsSnapshotTests.swift`.

---

### Task 0: Rebase gate and green baseline

**Files:** none modified.

- [ ] **Step 1: Confirm the branch**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs branch --show-current`
Expected: `feat/single-packet-proofs`

- [ ] **Step 2: Confirm the branch sits on the latest main**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs merge-base --is-ancestor main HEAD`
Expected: exit status 0. If non-zero, run `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs rebase main` and re-run this step. (The controller rebased onto `main` at `314b812` on 2026-09-26. The BLE work has landed.)

- [ ] **Step 3: Confirm a clean tree**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs status --short`
Expected: empty (the plan file is committed by the controller before execution).

- [ ] **Step 4: Green baseline**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs`
Expected: all tests pass. If anything fails to compile or fails, STOP and report the output — do not start Task 1.

---

### Task 1: Reference proof vectors and `Transport.proveSingle`

**Files:**
- Create: `Tests/ReTiCATransportTests/Vectors/generate_proof_fixtures.py`
- Create (generated): `Tests/ReTiCATransportTests/Vectors/proof_fixtures.json`
- Create: `Tests/ReTiCATransportTests/Vectors/ProofVectorFixtures.swift`
- Create: `Tests/ReTiCATransportTests/Vectors/ProofCrossValidationTests.swift`
- Modify: `Package.swift` (the `ReTiCATransportTests` `resources:` line)
- Modify: `Sources/ReTiCATransport/Transport.swift` (Action enum after `case send(...)` at :223; new case in the reducer switch before `case .delegate:` at :1011)

**Interfaces:**
- Produces: `Transport.Action.proveSingle(packetHash: Data, interfaceID: InterfaceID, identity: Identity)` → emits `.delegate(.transmit(interfaceID, raw))` with the 83-byte implicit proof, or nothing.
- Produces (tests): `ProofVectorFixtures.load()` with `identity` (private), `publicIdentity`, `destinationHashBytes`, `plaintextBytes`, `dataPacketBytes`, `dataPacketHashBytes`, `implicitProofPacketBytes`, `explicitProofPacketBytes`. Tasks 2 and 4 append tests to `ProofCrossValidationTests.swift` and use these.

- [ ] **Step 1: Write the fixture generator**

Create `Tests/ReTiCATransportTests/Vectors/generate_proof_fixtures.py`:

```python
#!/usr/bin/env python3
"""
Cross-validation fixture for ReTiCA single-packet delivery proofs.

Every proof byte below comes from GENUINE RNS 1.4.2 code paths:
  * the DATA packet is parsed by RNS.Packet.unpack (which computes packet_hash);
  * the proofs are produced by calling the real RNS.Identity.prove(packet), which builds a
    ProofDestination and a PROOF packet and calls Packet.send(). send() is replaced by a capture
    stub (there is no running Reticulum instance), so the packet is packed by the real
    Packet.pack() and captured before it would reach Transport.outbound.
  * implicit vs explicit is selected by the same class flag Identity.prove reads
    (Reticulum.should_use_implicit_proof -> Reticulum.__use_implicit_proof).

Run by absolute path with the conda `rns` env, from any directory:
  /Users/ell/opt/anaconda3/envs/rns/bin/python <this file>
It writes proof_fixtures.json next to itself.

The DATA packet's ciphertext is random (Identity.encrypt uses an ephemeral key), so re-running
changes data_packet / data_packet_hash / both proofs. That is expected: commit the regenerated
JSON as a unit. The identity, destination hash and plaintext are fixed.
"""
import json
import os
import sys

try:
    import RNS
    from RNS.Identity import Identity
    from RNS.Packet import Packet
except ImportError as e:
    print("BLOCKED: RNS import failed:", e, file=sys.stderr)
    sys.exit(1)

PRV = bytes(range(1, 65))            # X25519 seed (32) || Ed25519 seed (32), ReTiCA's order too
PLAINTEXT = b"single-packet proof vector"

identity = Identity.from_bytes(PRV)
if identity is None:
    print("BLOCKED: Identity.from_bytes returned None", file=sys.stderr)
    sys.exit(1)

dest_hash = RNS.Destination.hash(identity, "lxmf", "delivery")

# HEADER_1 / BROADCAST / SINGLE / DATA (flags 0x00), hops 0, context NONE.
data_raw = bytes([0x00, 0x00]) + dest_hash + bytes([0x00]) + identity.encrypt(PLAINTEXT)
data_packet = Packet(None, data_raw)
if not data_packet.unpack():
    print("BLOCKED: RNS could not unpack the DATA packet", file=sys.stderr)
    sys.exit(1)

captured = []
def _capture_send(self):
    if not self.packed:
        self.pack()
    captured.append(self.raw)
    return None
Packet.send = _capture_send


def prove(implicit):
    RNS.Reticulum._Reticulum__use_implicit_proof = implicit
    before = len(captured)
    identity.prove(data_packet)          # THE REAL THING: RNS.Identity.prove
    if len(captured) != before + 1:
        print("BLOCKED: Identity.prove did not send exactly one packet", file=sys.stderr)
        sys.exit(1)
    return captured[-1]


implicit_proof_packet = prove(True)
explicit_proof_packet = prove(False)

# Sanity: the genuine code must have produced what the spec describes. Stop, don't fudge.
assert implicit_proof_packet[0] == 0x03, hex(implicit_proof_packet[0])       # H1/BCAST/SINGLE/PROOF
assert implicit_proof_packet[2:18] == data_packet.packet_hash[:16]
assert implicit_proof_packet[18] == 0x00                                        # context NONE
assert len(implicit_proof_packet) == 19 + 64
assert len(explicit_proof_packet) == 19 + 96
assert explicit_proof_packet[19:51] == data_packet.packet_hash

out = {
    "rns_version": RNS.__version__,
    "identity_private_key": PRV.hex(),
    "identity_public_key": identity.get_public_key().hex(),
    "destination_hash": dest_hash.hex(),
    "plaintext": PLAINTEXT.hex(),
    "data_packet": data_raw.hex(),
    "data_packet_hash": data_packet.packet_hash.hex(),
    "implicit_proof_payload": implicit_proof_packet[19:].hex(),
    "explicit_proof_payload": explicit_proof_packet[19:].hex(),
    "implicit_proof_packet": implicit_proof_packet.hex(),
    "explicit_proof_packet": explicit_proof_packet.hex(),
}
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "proof_fixtures.json")
with open(path, "w") as f:
    json.dump(out, f, indent=2, sort_keys=True)
    f.write("\n")
print("wrote " + path)
```

(This script was dry-run against the installed RNS 1.4.2 while writing this plan: it runs without a Reticulum instance and every assert holds.)

- [ ] **Step 2: Generate the fixture**

Run: `/Users/ell/opt/anaconda3/envs/rns/bin/python /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCATransportTests/Vectors/generate_proof_fixtures.py`
Expected: `wrote .../Vectors/proof_fixtures.json`, and the JSON has `"rns_version": "1.4.2"`.

- [ ] **Step 3: Register the resource**

In `Package.swift`, replace
```swift
            resources: [.process("Vectors/transport_fixtures.json")]
```
with
```swift
            resources: [.process("Vectors/transport_fixtures.json"), .process("Vectors/proof_fixtures.json")]
```

- [ ] **Step 4: Write the fixture loader**

Create `Tests/ReTiCATransportTests/Vectors/ProofVectorFixtures.swift`:

```swift
import Foundation
@testable import ReTiCA

/// Reference single-packet proof vectors, generated by `generate_proof_fixtures.py` from genuine
/// RNS 1.4.2 (`Identity.prove` → `ProofDestination` → PROOF packet, Identity.py:942-953).
struct ProofVectorFixtures: Decodable {
    let rnsVersion: String
    let identityPrivateKey: String
    let identityPublicKey: String
    let destinationHash: String
    let plaintext: String
    let dataPacket: String
    let dataPacketHash: String
    let implicitProofPacket: String
    let explicitProofPacket: String

    enum CodingKeys: String, CodingKey {
        case rnsVersion = "rns_version"
        case identityPrivateKey = "identity_private_key"
        case identityPublicKey = "identity_public_key"
        case destinationHash = "destination_hash"
        case plaintext
        case dataPacket = "data_packet"
        case dataPacketHash = "data_packet_hash"
        case implicitProofPacket = "implicit_proof_packet"
        case explicitProofPacket = "explicit_proof_packet"
    }

    static func load() throws -> ProofVectorFixtures {
        let url = Bundle.module.url(forResource: "proof_fixtures", withExtension: "json")!
        return try JSONDecoder().decode(ProofVectorFixtures.self, from: Data(contentsOf: url))
    }

    /// The prover, with its private key (what `.proveSingle` signs with).
    var identity: Identity { Identity(privateKey: bytes(identityPrivateKey))! }
    /// The same identity as a sender learns it from an announce: public key only.
    var publicIdentity: Identity { Identity(publicKey: bytes(identityPublicKey))! }
    var destinationHashBytes: Data { bytes(destinationHash) }
    var plaintextBytes: Data { bytes(plaintext) }
    var dataPacketBytes: Data { bytes(dataPacket) }
    var dataPacketHashBytes: Data { bytes(dataPacketHash) }
    var implicitProofPacketBytes: Data { bytes(implicitProofPacket) }
    var explicitProofPacketBytes: Data { bytes(explicitProofPacket) }

    /// Generated fixture: a bad hex string is a broken fixture, so trap.
    private func bytes(_ hex: String) -> Data { Data(hexString: hex)! }
}
```

- [ ] **Step 5: Write the failing tests**

Create `Tests/ReTiCATransportTests/Vectors/ProofCrossValidationTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let proofIfID = InterfaceID("tcp-1")

/// Our packet hash for the reference DATA packet equals RNS's `packet_hash` — the value a proof
/// signs, and whose first 16 bytes address the proof.
@Test func proofVectorDataPacketHashMatchesReference() throws {
    let f = try ProofVectorFixtures.load()
    let packet = try #require(Packet(raw: f.dataPacketBytes))
    #expect(packet.packetHash == f.dataPacketHashBytes)
}

/// `.proveSingle` emits, on the requested interface, a PROOF whose flags, hops, proof destination
/// (`packetHash[:16]`) and context bytes are identical to reference `Identity.prove` (implicit form),
/// and whose 64-byte signature validates over the packet hash with the prover's PUBLIC identity.
///
/// Byte-identity of the signature itself is NOT asserted and cannot be: `Identity.sign` is
/// CryptoKit, whose Ed25519 is hedged (randomised — see DeterministicSigner.swift), while RNS signs
/// deterministically (RFC 8032). Both are valid signatures of the same message, and receivers only
/// verify, never compare.
@Test @MainActor func proofVectorProveSingleMatchesReferenceImplicitProof() async throws {
    let f = try ProofVectorFixtures.load()
    var initial = Transport.State()
    initial.interfaces[proofIfID] = .default
    let store = TestStore(initialState: initial) { Transport() }   // exhaustive: exactly one transmit

    await store.send(.proveSingle(packetHash: f.dataPacketHashBytes, interfaceID: proofIfID,
                                  identity: f.identity))
    let sent = LockIsolated<Data?>(nil)
    await store.receive { action in
        guard case let .delegate(.transmit(id, raw)) = action, id == proofIfID else { return false }
        sent.setValue(raw)
        return true
    }

    let raw = try #require(sent.value)
    let reference = f.implicitProofPacketBytes
    #expect(raw.count == reference.count)                 // 19 header bytes + 64-byte signature
    #expect(raw.prefix(19) == reference.prefix(19))       // flags, hops, hash[:16], context
    let proof = try #require(Packet(raw: raw))
    #expect(proof.packetType == .proof)
    #expect(proof.destinationType == .single)
    #expect(proof.destinationHash == f.dataPacketHashBytes.prefix(16))
    #expect(f.publicIdentity.validate(signature: proof.payload, message: f.dataPacketHashBytes))
}

/// An identity that cannot sign (public key only) proves nothing — and must not trap in `sign`.
@Test @MainActor func proofVectorProveSingleNeedsAPrivateKey() async throws {
    let f = try ProofVectorFixtures.load()
    var initial = Transport.State()
    initial.interfaces[proofIfID] = .default
    let store = TestStore(initialState: initial) { Transport() }   // exhaustive: a transmit fails
    await store.send(.proveSingle(packetHash: f.dataPacketHashBytes, interfaceID: proofIfID,
                                  identity: f.publicIdentity))
}

/// A proof for an interface that is not (or no longer) connected is dropped, not sent into nothing.
@Test @MainActor func proofVectorProveSingleNeedsAConnectedInterface() async throws {
    let f = try ProofVectorFixtures.load()
    let store = TestStore(initialState: Transport.State()) { Transport() }   // no interfaces
    await store.send(.proveSingle(packetHash: f.dataPacketHashBytes, interfaceID: proofIfID,
                                  identity: f.identity))
}
```

- [ ] **Step 6: Run the tests to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter proofVector`
Expected: build FAILS — `type 'Transport.Action' has no member 'proveSingle'`.

- [ ] **Step 7: Implement `.proveSingle`**

In `Sources/ReTiCATransport/Transport.swift`, after the line `        case send(destinationHash: Data, plaintext: Data)` (Action enum, :223) add:

```swift
        /// Prove a single packet we received, reference-style (RNS `Identity.prove`,
        /// Identity.py:942-953): an unencrypted HEADER_1 PROOF to the packet's `ProofDestination`
        /// (hash = `packetHash[:16]`, type SINGLE, Packet.py:376-379), context NONE, carrying the
        /// 64-byte IMPLICIT proof — `identity.sign(packetHash)`, the reference default
        /// (Reticulum.py:259) — sent on the interface the packet arrived on. Does nothing when
        /// `identity` has no private key or `interfaceID` is not connected.
        case proveSingle(packetHash: Data, interfaceID: InterfaceID, identity: Identity)
```

In the reducer switch, immediately before `            case .delegate:` (:1011) add:

```swift
            case let .proveSingle(packetHash, interfaceID, identity):
                guard identity.privateKey != nil, state.interfaces[interfaceID] != nil else { return .none }
                let proof = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                                   destinationType: .single, context: .none, contextFlag: false, hops: 0,
                                   destinationHash: Data(packetHash.prefix(Packet.addressLength)),
                                   transportId: nil, payload: identity.sign(packetHash))
                guard let raw = try? proof.packed() else { return .none }
                return .send(.delegate(.transmit(interfaceID, raw)))
```

- [ ] **Step 8: Run the tests to see them pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter proofVector`
Expected: 4 tests PASS.

- [ ] **Step 9: Mutation batch (apply all at once)**

1. `.proveSingle`: `payload: identity.sign(packetHash)` → `payload: Data(count: 64)` — breaks `proofVectorProveSingleMatchesReferenceImplicitProof` (signature no longer validates).
2. `.proveSingle`: delete `identity.privateKey != nil, ` from the guard — breaks `proofVectorProveSingleNeedsAPrivateKey` (a transmit appears under the exhaustive store). Safe only together with mutation 1: without it, `Identity.sign` would `preconditionFailure` and crash the run.
3. `.proveSingle`: delete `, state.interfaces[interfaceID] != nil` from the guard — breaks `proofVectorProveSingleNeedsAConnectedInterface`.
4. `Sources/ReTiCA/Packet/Packet.swift` `hashablePart`: delete the line `part.append(context.rawValue)` — breaks `proofVectorDataPacketHashMatchesReference`. (It does not affect the other three tests: they pass the fixture hash in, they never compute one.)

No mutation removes another's failure: 1 only changes the payload, 2 and 3 only widen the guard, 4 is in a different file.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter proofVector`
Expected: all 4 FAIL.

- [ ] **Step 10: Revert and re-run**

Revert all four mutations. Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs diff --stat` — expected: only `Package.swift` and `Sources/ReTiCATransport/Transport.swift` modified (new files are untracked). Then run the Step 8 command: all 4 PASS.

- [ ] **Step 11: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs`
Expected: all PASS.

- [ ] **Step 12: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs add Package.swift Sources/ReTiCATransport/Transport.swift Tests/ReTiCATransportTests/Vectors/generate_proof_fixtures.py Tests/ReTiCATransportTests/Vectors/proof_fixtures.json Tests/ReTiCATransportTests/Vectors/ProofVectorFixtures.swift Tests/ReTiCATransportTests/Vectors/ProofCrossValidationTests.swift`

Message file content:
```
feat: Transport proves a single packet reference-style

Adds Transport.Action.proveSingle, which emits the 64-byte implicit
proof to the packet's proof destination on the arrival interface.
Cross-validated against genuine RNS 1.4.2 Identity.prove vectors.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs commit -F /tmp/ReTiCaMsgr/commit-msg.txt`

---

### Task 2: Received packets carry hash and interface, and LXMFNode proves opportunistic deliveries

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (:258 `received` delegate, :699-700 emission)
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift` (Action enum :103-104, Delegate :111, reducer :248-249)
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (:600-601)
- Create: `Tests/ReTiCANodeTests/TransportEndpointSinglePacketProofTests.swift`
- Create: `Tests/ReTiCANodeTests/LXMFNodeSinglePacketProvingTests.swift`
- Modify (append): `Tests/ReTiCATransportTests/Vectors/ProofCrossValidationTests.swift`
- Modify (shape): `Tests/ReTiCATransportTests/TransportTests.swift` (:149, :304, :863, :1092, :1412, :4293, :4299), `Tests/ReTiCANodeTests/TransportEndpointTests.swift` (:112-124), `Tests/ReTiCANodeTests/BLEEndpointTests.swift` (:271-272), `Tests/ReTiCANodeTests/LXMFOpportunisticDeliveryTests.swift` (:68), `Tests/ReTiCANodeTests/BLEEndpointIntegrationTests.swift` (:95), `Tests/ReTiCANodeTests/TCPEndpointTests.swift` (:89)

**Interfaces:**
- Consumes: `Transport.Action.proveSingle(packetHash:interfaceID:identity:)` (Task 1).
- Produces: `Transport.Action.Delegate.received(destinationHash: Data, plaintext: Data, packetHash: Data, interfaceID: InterfaceID)`; `TransportEndpoint.Action.Delegate.messageReceived(destinationHash: Data, plaintext: Data, packetHash: Data, interfaceID: InterfaceID)`; `TransportEndpoint.Action.proveSinglePacket(packetHash: Data, interfaceID: InterfaceID, identity: Identity)` → `.transport(.proveSingle(...))`.
- LXMFNode behaviour: on `endpoint(.delegate(.messageReceived(dest, plaintext, packetHash, interfaceID)))` with `dest == state.deliveryDestinationHash`, emits `.merge(.send(.endpoint(.proveSinglePacket(packetHash:interfaceID:identity: state.identity))), .send(.router(.received(method: .opportunistic, ...))))`; otherwise only the router action.

- [ ] **Step 1: Write the failing Transport test**

Append to `Tests/ReTiCATransportTests/Vectors/ProofCrossValidationTests.swift`:

```swift
/// A single DATA packet decrypted for a local destination surfaces its full 32-byte packet hash —
/// the reference `packet_hash` a proof must sign — and the interface it arrived on.
@Test @MainActor func inboundProvingReceivedCarriesReferencePacketHashAndArrivalInterface() async throws {
    let f = try ProofVectorFixtures.load()
    let local = try #require(Destination(kind: .single, direction: .in, appName: "lxmf",
                                         aspects: ["delivery"], identity: f.identity))
    #expect(local.hash == f.destinationHashBytes)
    let store = TestStore(initialState: Transport.State()) { Transport() }
    store.exhaustivity = .off
    await store.send(.registerLocalDestination(local))
    await store.send(.received(proofIfID, f.dataPacketBytes))
    await store.receive(.delegate(.received(destinationHash: f.destinationHashBytes,
                                            plaintext: f.plaintextBytes,
                                            packetHash: f.dataPacketHashBytes,
                                            interfaceID: proofIfID)))
}
```

- [ ] **Step 2: Write the failing endpoint tests**

Create `Tests/ReTiCANodeTests/TransportEndpointSinglePacketProofTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

@MainActor
private func makeEndpoint() -> TestStore<TransportEndpoint.State, TransportEndpoint.Action> {
    let store = TestStore(
        initialState: .tcp(TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
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

@Test @MainActor func inboundProvingEndpointForwardsProveSinglePacketToTransport() async {
    let store = makeEndpoint()
    let packetHash = Data(repeating: 0x44, count: 32)
    let prover = Identity()
    await store.send(.proveSinglePacket(packetHash: packetHash, interfaceID: InterfaceID("tcp"),
                                        identity: prover))
    await store.receive(.transport(.proveSingle(packetHash: packetHash, interfaceID: InterfaceID("tcp"),
                                                identity: prover)))
}

@Test @MainActor func inboundProvingEndpointSurfacesPacketHashAndInterface() async {
    let store = makeEndpoint()
    let dest = Data(repeating: 0x22, count: 16)
    let packetHash = Data(repeating: 0x55, count: 32)
    await store.send(.transport(.delegate(.received(destinationHash: dest, plaintext: Data([7]),
                                                    packetHash: packetHash, interfaceID: InterfaceID("x")))))
    await store.receive(.delegate(.messageReceived(destinationHash: dest, plaintext: Data([7]),
                                                   packetHash: packetHash, interfaceID: InterfaceID("x"))))
}
```

- [ ] **Step 3: Write the failing LXMFNode tests**

Create `Tests/ReTiCANodeTests/LXMFNodeSinglePacketProvingTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Reference `LXMRouter.delivery_packet` (LXMRouter.py:1926-1927) calls `packet.prove()` as its FIRST
// statement for opportunistic packets too, before unpacking and before the duplicate check.
//
// Depth order these tests rely on (TCA runs `.send` effects breadth-first): the LXMFNode reduction
// of `messageReceived` returns `.merge(prove, router.received)`, so `.endpoint(.proveSinglePacket)`
// is received BEFORE `.router(.received)`, and `.endpoint(.transport(.proveSingle))` after both.

@MainActor
private func makeNode(_ identity: Identity) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let store = TestStore(
        initialState: LXMFNode.State(
            identity: identity,
            endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) {
        LXMFNode()
    } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

/// A packet for OUR delivery destination is proved on its arrival interface, then routed. The
/// payload here is not a valid LXMF message: LXMF-level malformation is still proved, as in
/// reference, where `packet.prove()` precedes unpacking.
@MainActor @Test func inboundProvingProvesOpportunisticDeliveryBeforeRouting() async throws {
    let identity = Identity()
    let store = makeNode(identity)
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)
    let ours = try #require(store.state.deliveryDestinationHash)
    let packetHash = Data(repeating: 0xE1, count: 32)
    let ifID = InterfaceID("tcp")
    let garbage = Data("not an lxmf message".utf8)

    await store.send(.endpoint(.delegate(.messageReceived(destinationHash: ours, plaintext: garbage,
                                                          packetHash: packetHash, interfaceID: ifID))))
    await store.receive(.endpoint(.proveSinglePacket(packetHash: packetHash, interfaceID: ifID,
                                                     identity: identity)))
    await store.receive(.router(.received(method: .opportunistic, destinationHash: ours, data: garbage)))
}

/// The proof goes out BEFORE the router's `seen` dedup, so a resend of a message we already
/// delivered is proved again — otherwise a sender whose first proof was lost never learns.
@MainActor @Test func inboundProvingProvesADuplicateAgain() async throws {
    let identity = Identity()
    let store = makeNode(identity)
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)
    let ours = try #require(store.state.deliveryDestinationHash)
    let msg = LXMessage.create(source: Identity(), destinationHash: ours, timestamp: 1700000000.5,
                               title: Data("t".utf8), content: Data("twice".utf8))
    let first = Data(repeating: 0xE4, count: 32)
    let second = Data(repeating: 0xE5, count: 32)   // a resend is a new packet with a new hash
    let ifID = InterfaceID("tcp")

    await store.send(.endpoint(.delegate(.messageReceived(destinationHash: ours, plaintext: msg.opportunisticPayload,
                                                          packetHash: first, interfaceID: ifID))))
    await store.receive(.endpoint(.proveSinglePacket(packetHash: first, interfaceID: ifID, identity: identity)))
    await store.receive { if case .delegate(.messageReceived) = $0 { return true }; return false }

    await store.send(.endpoint(.delegate(.messageReceived(destinationHash: ours, plaintext: msg.opportunisticPayload,
                                                          packetHash: second, interfaceID: ifID))))
    await store.receive(.endpoint(.proveSinglePacket(packetHash: second, interfaceID: ifID, identity: identity)))
    await store.receive(.router(.delegate(.duplicateDropped(hash: msg.hash))))
}

/// A packet for any other local destination is routed but NOT proved.
@MainActor @Test func inboundProvingIgnoresPacketsForOtherDestinations() async {
    let store = makeNode(Identity())
    await store.send(.registerDelivery)
    await store.skipReceivedActions(strict: false)
    let other = Data(repeating: 0xCC, count: 16)
    let payload = Data("x".utf8)
    store.exhaustivity = .on   // from here, a stray proveSinglePacket is an unexpected action
    await store.send(.endpoint(.delegate(.messageReceived(destinationHash: other, plaintext: payload,
                                                          packetHash: Data(repeating: 0xE2, count: 32),
                                                          interfaceID: InterfaceID("tcp")))))
    await store.receive(.router(.received(method: .opportunistic, destinationHash: other, data: payload)))
}

/// Before `registerDelivery` nothing is ours, so nothing is proved — even for the hash our
/// delivery destination WOULD have.
@MainActor @Test func inboundProvingNeedsARegisteredDeliveryDestination() async {
    let identity = Identity()
    let store = makeNode(identity)
    let wouldBe = LXMessage.deliveryHash(identityHash: identity.hash)
    let payload = Data("x".utf8)
    store.exhaustivity = .on
    await store.send(.endpoint(.delegate(.messageReceived(destinationHash: wouldBe, plaintext: payload,
                                                          packetHash: Data(repeating: 0xE3, count: 32),
                                                          interfaceID: InterfaceID("tcp")))))
    await store.receive(.router(.received(method: .opportunistic, destinationHash: wouldBe, data: payload)))
}
```

- [ ] **Step 4: Run the new tests to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter inboundProving`
Expected: build FAILS — extra arguments `packetHash`/`interfaceID` in `received`/`messageReceived`, no member `proveSinglePacket`.

- [ ] **Step 5: Transport — carry the hash and the interface**

In `Sources/ReTiCATransport/Transport.swift` replace
```swift
            case received(destinationHash: Data, plaintext: Data)
```
with
```swift
            /// A single packet decrypted for a local destination. `packetHash` is the full 32-byte
            /// `Packet.packetHash` (what a proof signs) and `interfaceID` is where it arrived (where
            /// a proof must go back out).
            case received(destinationHash: Data, plaintext: Data, packetHash: Data, interfaceID: InterfaceID)
```
and replace
```swift
                    return .send(.delegate(.received(destinationHash: packet.destinationHash,
                                                     plaintext: plaintext)))
```
with
```swift
                    return .send(.delegate(.received(destinationHash: packet.destinationHash,
                                                     plaintext: plaintext,
                                                     packetHash: packet.packetHash,
                                                     interfaceID: interfaceID)))
```

- [ ] **Step 6: TransportEndpoint — forward, and expose the prover**

In `Sources/ReTiCANode/TransportEndpoint.swift`:

After `        case provePacketOverLink(linkID: Data, packetHash: Data)` (Action enum) add:
```swift
        /// Prove a single (non-link) packet we received — see `Transport.Action.proveSingle`.
        case proveSinglePacket(packetHash: Data, interfaceID: InterfaceID, identity: Identity)
```
Replace
```swift
            case messageReceived(destinationHash: Data, plaintext: Data)
```
with
```swift
            case messageReceived(destinationHash: Data, plaintext: Data, packetHash: Data, interfaceID: InterfaceID)
```
After the line `            case let .requestPath(h):               return .send(.transport(.requestPath(destinationHash: h)))` add:
```swift
            case let .proveSinglePacket(h, id, identity):
                return .send(.transport(.proveSingle(packetHash: h, interfaceID: id, identity: identity)))
```
Replace
```swift
            case let .transport(.delegate(.received(h, p))):
                return .send(.delegate(.messageReceived(destinationHash: h, plaintext: p)))
```
with
```swift
            case let .transport(.delegate(.received(h, p, packetHash, interfaceID))):
                return .send(.delegate(.messageReceived(destinationHash: h, plaintext: p,
                                                        packetHash: packetHash, interfaceID: interfaceID)))
```

- [ ] **Step 7: LXMFNode — prove, then route**

In `Sources/ReTiCANode/LXMFNode.swift` replace
```swift
            case let .endpoint(.delegate(.messageReceived(destHash, plaintext))):
                return .send(.router(.received(method: .opportunistic, destinationHash: destHash, data: plaintext)))
```
with
```swift
            case let .endpoint(.delegate(.messageReceived(destHash, plaintext, packetHash, interfaceID))):
                // Reference `LXMRouter.delivery_packet` (LXMRouter.py:1926-1927) calls `packet.prove()`
                // as its FIRST statement, for opportunistic (non-link) packets too. The proof therefore
                // goes out BEFORE the router's `seen` dedup, so a resend of an already-delivered message
                // is proved again, and before unpacking, so LXMF-level malformation is proved too.
                // Only packets for OUR delivery destination are proved: `Transport` surfaces a packet
                // here only after decrypting it for a local destination, and link traffic and
                // propagated downloads never arrive on this path.
                let deliver = Effect<Action>.send(.router(.received(method: .opportunistic,
                                                                    destinationHash: destHash, data: plaintext)))
                guard let ours = state.deliveryDestinationHash, destHash == ours else { return deliver }
                return .merge(.send(.endpoint(.proveSinglePacket(packetHash: packetHash, interfaceID: interfaceID,
                                                                 identity: state.identity))),
                              deliver)
```

- [ ] **Step 8: Update existing tests to the new shapes**

8a. `TransportTests.swift` — confirm line numbers first:
Run: `grep -n "delegate(.received(destinationHash" /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCATransportTests/TransportTests.swift`
Expected lines: 149, 304, 863, 1092, 1412, 4293, 4299 (inside `deliversInboundDataToLocalDestination`, `duplicateDataPacketIsDeduped`, `localDestinationDataStillDeliveredInRelayMode`, `threeNodeRelayDeliversMessageEndToEnd`, `duplicateDataStillDedupedByPacketHash`, and twice in `seenPacketRingEvictsOldestAndReDeliversIt`). If they differ, adjust the addresses below to the lines inside those tests.

Write `/tmp/ReTiCaMsgr/t2-transport.sed`:
```
149s/plaintext: plaintext)))/plaintext: plaintext, packetHash: packet.packetHash, interfaceID: InterfaceID("i1"))))/
304s/plaintext: plaintext)))/plaintext: plaintext, packetHash: packet.packetHash, interfaceID: InterfaceID("i1"))))/
863s/plaintext: plaintext)))/plaintext: plaintext, packetHash: packet.packetHash, interfaceID: InterfaceID("i1"))))/
1092s/plaintext: plaintext)))/plaintext: plaintext, packetHash: rPacket.packetHash, interfaceID: ifRB)))/
1412s/plaintext: plaintext)))/plaintext: plaintext, packetHash: packet.packetHash, interfaceID: InterfaceID("i"))))/
4293s/plaintext: payload)))/plaintext: payload, packetHash: Packet(raw: packet)!.packetHash, interfaceID: InterfaceID("i"))))/
4299s/plaintext: payloads\[0\])))/plaintext: payloads[0], packetHash: Packet(raw: packets[0])!.packetHash, interfaceID: InterfaceID("i"))))/
```
Run: `sed -i '' -f /tmp/ReTiCaMsgr/t2-transport.sed /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCATransportTests/TransportTests.swift`
(Each of those tests already has the named variable: `packet` is the `Packet` built in the test, `rPacket` is the relayed packet parsed at :1084, and at :4293/:4299 `packet`/`packets[0]` are raw `Data`.)

8b. `TransportEndpointTests.swift` — in `sharedMachineryDelegatesSurfaceAsUnifiedDelegates` replace
```swift
    let h = Data(repeating: 0x22, count: 16)

    let tcp = makeTCP()
    await tcp.send(.transport(.delegate(.received(destinationHash: h, plaintext: Data([0x01])))))
    await tcp.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x01]))))
```
with
```swift
    let h = Data(repeating: 0x22, count: 16)
    let ph = Data(repeating: 0x33, count: 32)

    let tcp = makeTCP()
    await tcp.send(.transport(.delegate(.received(destinationHash: h, plaintext: Data([0x01]),
                                                  packetHash: ph, interfaceID: InterfaceID("tcp")))))
    await tcp.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x01]),
                                                 packetHash: ph, interfaceID: InterfaceID("tcp"))))
```
and replace
```swift
    await ble.send(.transport(.delegate(.received(destinationHash: h, plaintext: Data([0x02])))))
    await ble.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x02]))))
```
with
```swift
    await ble.send(.transport(.delegate(.received(destinationHash: h, plaintext: Data([0x02]),
                                                  packetHash: ph, interfaceID: InterfaceID("ble")))))
    await ble.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x02]),
                                                 packetHash: ph, interfaceID: InterfaceID("ble"))))
```

8c. `BLEEndpointTests.swift` — in `transportDelegatesForwardToEndpointDelegates` replace
```swift
    await store.send(.transport(.delegate(.received(destinationHash: h, plaintext: Data([0x09])))))
    await store.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x09]))))
```
with
```swift
    await store.send(.transport(.delegate(.received(destinationHash: h, plaintext: Data([0x09]),
                                                    packetHash: Data(repeating: 0x66, count: 32),
                                                    interfaceID: InterfaceID("ble-peer")))))
    await store.receive(.delegate(.messageReceived(destinationHash: h, plaintext: Data([0x09]),
                                                   packetHash: Data(repeating: 0x66, count: 32),
                                                   interfaceID: InterfaceID("ble-peer"))))
```

8d. Wildcard-only compile fixes (mechanical):
- `LXMFOpportunisticDeliveryTests.swift:68`: `.delegate(.messageReceived(h, p))` → `.delegate(.messageReceived(h, p, _, _))`
- `BLEEndpointIntegrationTests.swift:95`: `.delegate(.messageReceived(_, p))` → `.delegate(.messageReceived(_, p, _, _))`
- `TCPEndpointTests.swift:89`: `.delegate(.messageReceived(_, p))` → `.delegate(.messageReceived(_, p, _, _))`

- [ ] **Step 9: Run the new and changed tests**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter inboundProving --filter deliversInboundDataToLocalDestination --filter duplicateDataPacketIsDeduped --filter localDestinationDataStillDeliveredInRelayMode --filter threeNodeRelayDeliversMessageEndToEnd --filter duplicateDataStillDedupedByPacketHash --filter seenPacketRingEvictsOldestAndReDeliversIt --filter sharedMachineryDelegatesSurfaceAsUnifiedDelegates --filter transportDelegatesForwardToEndpointDelegates`
Expected: all PASS (7 new `inboundProving*` + 9 changed).

- [ ] **Step 10: Mutation batch (apply all at once)**

1. Transport emission: `packetHash: packet.packetHash` → `packetHash: packet.truncatedHash` — breaks `inboundProvingReceivedCarriesReferencePacketHashAndArrivalInterface` and the 7 changed `TransportTests` assertions.
2. TransportEndpoint forwarding of `received`: `interfaceID: interfaceID))` → `interfaceID: InterfaceID("mutant")))` — breaks `inboundProvingEndpointSurfacesPacketHashAndInterface`, `sharedMachineryDelegatesSurfaceAsUnifiedDelegates`, `transportDelegatesForwardToEndpointDelegates`.
3. TransportEndpoint `.proveSinglePacket`: `identity: identity)))` → `identity: Identity())))` — breaks `inboundProvingEndpointForwardsProveSinglePacketToTransport`.
4. LXMFNode: delete the `guard let ours ... else { return deliver }` line AND change `packetHash: packetHash` in the prove to `packetHash: Data(packetHash.reversed())` — always proves, with the wrong hash. Breaks `inboundProvingProvesOpportunisticDeliveryBeforeRouting` and `inboundProvingProvesADuplicateAgain` (exact prove never arrives) and `inboundProvingIgnoresPacketsForOtherDestinations`, `inboundProvingNeedsARegisteredDeliveryDestination` (a prove arrives first under `.on`).

1-3 touch different lines/files from 4, and each only changes values, so none can restore another's passing assertion. No mutation can crash (the proved identity is a signing identity).

Run the Step 9 command. Expected: every listed test FAILS.

- [ ] **Step 11: Revert and re-run**

Revert all four. Run the Step 9 command: all PASS.

- [ ] **Step 12: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs`
Expected: all PASS.

- [ ] **Step 13: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs add Sources/ReTiCATransport/Transport.swift Sources/ReTiCANode/TransportEndpoint.swift Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCATransportTests/Vectors/ProofCrossValidationTests.swift Tests/ReTiCATransportTests/TransportTests.swift Tests/ReTiCANodeTests/TransportEndpointSinglePacketProofTests.swift Tests/ReTiCANodeTests/LXMFNodeSinglePacketProvingTests.swift Tests/ReTiCANodeTests/TransportEndpointTests.swift Tests/ReTiCANodeTests/BLEEndpointTests.swift Tests/ReTiCANodeTests/LXMFOpportunisticDeliveryTests.swift Tests/ReTiCANodeTests/BLEEndpointIntegrationTests.swift Tests/ReTiCANodeTests/TCPEndpointTests.swift`

Message:
```
feat: LXMFNode proves inbound opportunistic LXMF packets

Transport.received and TransportEndpoint.messageReceived now carry the
packet hash and the arrival interface. LXMFNode proves packets for its
delivery destination before routing them, as LXMRouter.delivery_packet
does, so a resend of an already-delivered message is proved again.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs commit -F /tmp/ReTiCaMsgr/commit-msg.txt`

---

### Task 3: Receipt table for outbound sends

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (Action `send` :223; `State` — new nested type + property; `.send` handler :917-943; `.maintenanceTick` :737-764; constants next to `establishmentTimeoutPerHop` :1162)
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift` (Action `send` :93; reducer :148)
- Create: `Tests/ReTiCATransportTests/TransportSinglePacketProofTests.swift`
- Modify (append): `Tests/ReTiCANodeTests/TransportEndpointSinglePacketProofTests.swift`

**Interfaces:**
- Produces: `Transport.Action.send(destinationHash: Data, plaintext: Data, receiptToken: Data? = nil)`; `TransportEndpoint.Action.send(destinationHash: Data, plaintext: Data, receiptToken: Data? = nil)`.
- Produces: `Transport.State.PendingReceipt` (`public struct`, `Equatable, Sendable`, public memberwise `init(packetHash:token:identity:expiresAt:)`), `Transport.State.pendingReceipts: [Data: PendingReceipt]` keyed by `packetHash.prefix(16)`.
- Produces: `Transport.receiptTimeoutBase`, `Transport.receiptTimeoutPerHop` (`TimeInterval`, 6 each), `Transport.maxPendingReceipts = 1024`, `Transport.recordReceipt(_:in:)`.

- [ ] **Step 1: Write the failing Transport tests**

Create `Tests/ReTiCATransportTests/TransportSinglePacketProofTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCATransport
@testable import ReTiCA

private let ifID = InterfaceID("tcp-1")
private let dest = Data(repeating: 0xD1, count: 16)
private let now = Date(timeIntervalSince1970: 1_700_000_000)

/// One connected interface and a destination learned on it, `hops` away.
private func stateWithLearnedDestination(_ recipient: Identity, hops: UInt8 = 0) -> Transport.State {
    var state = Transport.State()
    state.interfaces[ifID] = .default
    state.learned[dest] = LearnedDestination(identity: recipient, appData: nil, ratchet: nil,
                                             interfaceID: ifID, hops: hops, nextHop: nil,
                                             announceEmitted: 0, learnedAt: now)
    return state
}

@MainActor
private func makeStore(_ initial: Transport.State) -> TestStore<Transport.State, Transport.Action> {
    let store = TestStore(initialState: initial) { Transport() } withDependencies: {
        $0.transportDate = .constant(now)
    }
    store.exhaustivity = .off
    return store
}

/// Sends to `dest` and returns the raw packet Transport transmitted.
@MainActor
private func sendAndCapture(_ store: TestStore<Transport.State, Transport.Action>, token: Data?) async -> Data {
    let sent = LockIsolated<Data?>(nil)
    await store.send(.send(destinationHash: dest, plaintext: Data("hello".utf8), receiptToken: token))
    await store.receive { action in
        guard case let .delegate(.transmit(_, raw)) = action else { return false }
        sent.setValue(raw)
        return true
    }
    return sent.value ?? Data()
}

@Test @MainActor func receiptTableSendWithATokenRecordsAReceipt() async throws {
    let recipient = Identity()
    let token = Data("message-hash".utf8)
    let store = makeStore(stateWithLearnedDestination(recipient))
    let raw = await sendAndCapture(store, token: token)
    let packetHash = try #require(Packet(raw: raw)).packetHash
    #expect(store.state.pendingReceipts == [
        Data(packetHash.prefix(16)): Transport.State.PendingReceipt(
            packetHash: packetHash, token: token, identity: recipient,
            expiresAt: now.addingTimeInterval(Transport.receiptTimeoutBase + Transport.receiptTimeoutPerHop)),
    ])
}

@Test @MainActor func receiptTableSendWithoutATokenRecordsNothing() async {
    let store = makeStore(stateWithLearnedDestination(Identity()))
    _ = await sendAndCapture(store, token: nil)
    #expect(store.state.pendingReceipts.isEmpty)
}

@Test @MainActor func receiptTableExpiryScalesWithHops() async throws {
    let store = makeStore(stateWithLearnedDestination(Identity(), hops: 3))
    let raw = await sendAndCapture(store, token: Data([1]))
    let key = Data(try #require(Packet(raw: raw)).packetHash.prefix(16))
    #expect(store.state.pendingReceipts[key]?.expiresAt
            == now.addingTimeInterval(Transport.receiptTimeoutBase + 3 * Transport.receiptTimeoutPerHop))
}

/// A resend is a new packet (new ephemeral ciphertext, new hash) with its own receipt, under the
/// same token — so a proof for EITHER copy confirms the message.
@Test @MainActor func receiptTableResendKeepsBothReceiptsUnderOneToken() async throws {
    let store = makeStore(stateWithLearnedDestination(Identity()))
    let token = Data([0xAB])
    let first = await sendAndCapture(store, token: token)
    let second = await sendAndCapture(store, token: token)
    let k1 = Data(try #require(Packet(raw: first)).packetHash.prefix(16))
    let k2 = Data(try #require(Packet(raw: second)).packetHash.prefix(16))
    #expect(k1 != k2)
    #expect(store.state.pendingReceipts.count == 2)
    #expect(store.state.pendingReceipts[k1]?.token == token)
    #expect(store.state.pendingReceipts[k2]?.token == token)
}

/// Expiry removes receipts at or past their deadline and emits NOTHING: the LXMF retry timer stays
/// the only failure authority.
@Test @MainActor func receiptTableMaintenanceTickDropsExpiredReceiptsSilently() async {
    let prover = Identity()
    func receipt(_ byte: UInt8, expiresAt: Date) -> (Data, Transport.State.PendingReceipt) {
        let hash = Data(repeating: byte, count: 32)
        return (Data(hash.prefix(16)),
                Transport.State.PendingReceipt(packetHash: hash, token: Data([byte]), identity: prover,
                                               expiresAt: expiresAt))
    }
    let past = receipt(0x01, expiresAt: now.addingTimeInterval(-1))
    let exact = receipt(0x02, expiresAt: now)
    let future = receipt(0x03, expiresAt: now.addingTimeInterval(1))
    var initial = Transport.State()
    initial.pendingReceipts = [past.0: past.1, exact.0: exact.1, future.0: future.1]
    let store = makeStore(initial)
    store.exhaustivity = .on   // any delegate from expiry is an unexpected action
    await store.send(.maintenanceTick) {
        $0.pendingReceipts = [future.0: future.1]
    }
}

@Test @MainActor func receiptTableAtCapacityEvictsTheSoonestExpiry() async throws {
    var initial = stateWithLearnedDestination(Identity())
    let filler = Identity()
    var soonestKey = Data()
    for i in 0..<Transport.maxPendingReceipts {
        var hash = Data(repeating: 0xEE, count: 32)
        hash[0] = UInt8(i & 0xFF)
        hash[1] = UInt8(i >> 8)
        let key = Data(hash.prefix(16))
        let expiresAt = i == 500 ? now.addingTimeInterval(1) : now.addingTimeInterval(1000 + Double(i))
        if i == 500 { soonestKey = key }
        initial.pendingReceipts[key] = Transport.State.PendingReceipt(packetHash: hash, token: Data([0]),
                                                                      identity: filler, expiresAt: expiresAt)
    }
    let store = makeStore(initial)
    let raw = await sendAndCapture(store, token: Data([0x77]))
    let newKey = Data(try #require(Packet(raw: raw)).packetHash.prefix(16))
    #expect(store.state.pendingReceipts.count == Transport.maxPendingReceipts)
    #expect(store.state.pendingReceipts[soonestKey] == nil)
    #expect(store.state.pendingReceipts[newKey]?.token == Data([0x77]))
}
```

- [ ] **Step 2: Write the failing endpoint test**

Append to `Tests/ReTiCANodeTests/TransportEndpointSinglePacketProofTests.swift`:

```swift
@Test @MainActor func receiptTableEndpointPassesTheTokenToTransport() async {
    let store = makeEndpoint()
    let dest = Data(repeating: 0x11, count: 16)
    let plaintext = Data("hi".utf8)
    let token = Data([0xAB])
    await store.send(.send(destinationHash: dest, plaintext: plaintext, receiptToken: token))
    await store.receive(.transport(.send(destinationHash: dest, plaintext: plaintext, receiptToken: token)))
}
```

- [ ] **Step 3: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter receiptTable`
Expected: build FAILS — extra argument `receiptToken`, no member `pendingReceipts`/`PendingReceipt`.

- [ ] **Step 4: Transport — state, action, constants**

In `Sources/ReTiCATransport/Transport.swift`:

Replace `        case send(destinationHash: Data, plaintext: Data)` with:
```swift
        /// Encrypt `plaintext` to a learned destination and send it as one packet. With a non-nil
        /// `receiptToken`, also record a `PendingReceipt` so a valid proof for this packet emits
        /// `.delegate(.singlePacketDelivered(token:))`. The token is opaque to Transport.
        case send(destinationHash: Data, plaintext: Data, receiptToken: Data? = nil)
```

In `State`, after `public var interfaceConnectedAt: [InterfaceID: Date] = [:]` (:150) add:
```swift

        /// An outbound single packet awaiting its delivery proof (RNS `PacketReceipt`,
        /// Packet.py:402-419), recorded by `.send(..., receiptToken:)`.
        public struct PendingReceipt: Equatable, Sendable {
            /// Full 32-byte packet hash: what the proof signs, and (first 16 bytes) its address.
            public var packetHash: Data
            /// Opaque to Transport. LXMF passes `message.hash`, so every resend shares one token.
            public var token: Data
            /// The recipient identity from `learned[dest]` at send time; the proof must verify with it.
            public var identity: Identity
            public var expiresAt: Date
            public init(packetHash: Data, token: Data, identity: Identity, expiresAt: Date) {
                self.packetHash = packetHash
                self.token = token
                self.identity = identity
                self.expiresAt = expiresAt
            }
        }
        /// `packetHash.prefix(16)` → receipt. The key is the proof's destination hash (the packet's
        /// `ProofDestination`), so an inbound proof finds its receipt with one lookup.
        public var pendingReceipts: [Data: PendingReceipt] = [:]
```

After `    static let establishmentTimeoutPerHop: TimeInterval = 6` (:1162) add:
```swift
    /// Single-packet receipt lifetime: `receiptTimeoutBase + receiptTimeoutPerHop * max(1, hops)`.
    /// Reference: `PacketReceipt.timeout = first_hop_timeout + TIMEOUT_PER_HOP * hops_to(dest)`
    /// (Packet.py:417-418), where `first_hop_timeout` is `DEFAULT_PER_HOP_TIMEOUT` (6 s) plus a
    /// link-latency term ReTiCA does not track (Transport.py:2788-2791) and `TIMEOUT_PER_HOP` is
    /// also `DEFAULT_PER_HOP_TIMEOUT` (Reticulum.py:142). ReTiCA's learned `hops` is the announce's
    /// on-wire count (reference increments it on receipt), so `max(1, hops)` matches reference for a
    /// directly-heard peer and is one hop short for a relayed one. Harmless: an expired receipt emits
    /// nothing, because the LXMF retry timer is the only failure authority.
    static let receiptTimeoutBase: TimeInterval = 6
    static let receiptTimeoutPerHop: TimeInterval = 6
    /// RNS `MAX_RECEIPTS` (Transport.py:96). Reference culls the OLDEST receipt past the cap
    /// (Transport.py:570-575); ReTiCA evicts the one expiring soonest, which is the one least
    /// likely to still be proved.
    static let maxPendingReceipts = 1024

    /// Record `receipt` under `packetHash.prefix(16)`, evicting the soonest-expiring entry when a
    /// NEW key would exceed `maxPendingReceipts`.
    static func recordReceipt(_ receipt: State.PendingReceipt, in state: inout State) {
        let key = Data(receipt.packetHash.prefix(Packet.addressLength))
        if state.pendingReceipts[key] == nil,
           state.pendingReceipts.count >= maxPendingReceipts,
           let soonest = state.pendingReceipts.min(by: { $0.value.expiresAt < $1.value.expiresAt })?.key {
            state.pendingReceipts[soonest] = nil
        }
        state.pendingReceipts[key] = receipt
    }
```

- [ ] **Step 5: Transport — record on send, sweep on tick**

Replace `            case let .send(destinationHash, plaintext):` with `            case let .send(destinationHash, plaintext, receiptToken):`.

In the same case replace
```swift
                guard let raw = try? packet.packed() else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .tooLarge)))
                }
                return .send(.delegate(.transmit(entry.interfaceID, raw)))
```
with
```swift
                guard let raw = try? packet.packed() else {
                    return .send(.delegate(.sendFailed(destinationHash: destinationHash,
                                                       reason: .tooLarge)))
                }
                if let receiptToken {
                    let hopTimeout = Transport.receiptTimeoutPerHop * Double(max(1, entry.hops))
                    Transport.recordReceipt(State.PendingReceipt(
                        packetHash: packet.packetHash, token: receiptToken, identity: entry.identity,
                        expiresAt: date.now.addingTimeInterval(Transport.receiptTimeoutBase + hopTimeout)),
                                            in: &state)
                }
                return .send(.delegate(.transmit(entry.interfaceID, raw)))
```

In `case .maintenanceTick:` replace
```swift
                for (id, queue) in state.announceQueues {
                    let live = queue.filter { now.timeIntervalSince($0.queuedAt) <= Transport.queuedAnnounceLife }
                    state.announceQueues[id] = live.isEmpty ? nil : live
                }
                return .none
```
with
```swift
                for (id, queue) in state.announceQueues {
                    let live = queue.filter { now.timeIntervalSince($0.queuedAt) <= Transport.queuedAnnounceLife }
                    state.announceQueues[id] = live.isEmpty ? nil : live
                }
                // Expired receipts go silently: the LXMF retry timer is the only failure authority,
                // so reporting expiry here would double the retries (spec §2).
                state.pendingReceipts = state.pendingReceipts.filter { $0.value.expiresAt > now }
                return .none
```

- [ ] **Step 6: TransportEndpoint — pass the token through**

In `Sources/ReTiCANode/TransportEndpoint.swift` replace `        case send(destinationHash: Data, plaintext: Data)` with
```swift
        case send(destinationHash: Data, plaintext: Data, receiptToken: Data? = nil)
```
and replace
```swift
            case let .send(h, p):                   return .send(.transport(.send(destinationHash: h, plaintext: p)))
```
with
```swift
            case let .send(h, p, token):            return .send(.transport(.send(destinationHash: h, plaintext: p,
                                                                                  receiptToken: token)))
```
(Every existing construction site keeps compiling through the `nil` default.)

- [ ] **Step 7: Run to see them pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter receiptTable`
Expected: 7 PASS.

- [ ] **Step 8: Mutation batch (apply all at once)**

1. `.send`: replace `if let receiptToken {` with `do { let receiptToken = receiptToken ?? Data()` AND `packetHash: packet.packetHash,` (inside the receipt) with `packetHash: packet.truncatedHash,` — breaks `receiptTableSendWithATokenRecordsAReceipt` (wrong receipt) and `receiptTableSendWithoutATokenRecordsNothing` (a receipt appears).
2. `.send`: `Double(max(1, entry.hops))` → `1.0` — breaks `receiptTableExpiryScalesWithHops`.
3. `recordReceipt`: `let key = Data(receipt.packetHash.prefix(Packet.addressLength))` → `let key = receipt.token` — breaks `receiptTableResendKeepsBothReceiptsUnderOneToken` (the second overwrites the first).
4. `recordReceipt`: `.min(by:` → `.max(by:` — breaks `receiptTableAtCapacityEvictsTheSoonestExpiry` (the soonest survives).
5. `.maintenanceTick`: `$0.value.expiresAt > now` → `$0.value.expiresAt >= now` — breaks `receiptTableMaintenanceTickDropsExpiredReceiptsSilently` (the exactly-due receipt survives).
6. TransportEndpoint: `receiptToken: token)))` → `receiptToken: nil)))` — breaks `receiptTableEndpointPassesTheTokenToTransport`.

Masking check: under 1+3 the "with token" test looks up by packet-hash prefix and finds nothing (fails); the "expiry" test looks up by packet-hash prefix and finds nothing (fails, and 2 would also fail it); under 3+4 the capacity test still evicts (the max) so the soonest survives (fails); 5 and 6 are independent. Nothing traps.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter receiptTable`
Expected: all 7 FAIL.

- [ ] **Step 9: Revert and re-run**

Revert all six. Run the Step 7 command: 7 PASS.

- [ ] **Step 10: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs`
Expected: all PASS.

- [ ] **Step 11: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs add Sources/ReTiCATransport/Transport.swift Sources/ReTiCANode/TransportEndpoint.swift Tests/ReTiCATransportTests/TransportSinglePacketProofTests.swift Tests/ReTiCANodeTests/TransportEndpointSinglePacketProofTests.swift`

Message:
```
feat: Transport records receipts for single-packet sends

send gains an optional receipt token. A token records a PendingReceipt
keyed by the packet's proof destination, capped at MAX_RECEIPTS with
soonest-expiry eviction, and swept silently at maintenance.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs commit -F /tmp/ReTiCaMsgr/commit-msg.txt`

---

### Task 4: Inbound proof validation

**Files:**
- Modify: `Sources/ReTiCATransport/Transport.swift` (Delegate enum :256-263; dedup guard :448-450; new `case .proof:` before `default:` at :722; constants)
- Modify: `Sources/ReTiCANode/TransportEndpoint.swift` (Delegate enum; reducer, next to the `received` forward)
- Modify (append): `Tests/ReTiCATransportTests/TransportSinglePacketProofTests.swift`, `Tests/ReTiCATransportTests/Vectors/ProofCrossValidationTests.swift`, `Tests/ReTiCANodeTests/TransportEndpointSinglePacketProofTests.swift`

**Interfaces:**
- Consumes: `Transport.State.pendingReceipts`, `PendingReceipt` (Task 3).
- Produces: `Transport.Action.Delegate.singlePacketDelivered(token: Data)`; `TransportEndpoint.Action.Delegate.singlePacketDelivered(token: Data)`; `Transport.implicitProofLength = 64`, `Transport.explicitProofLength = 96`.

- [ ] **Step 1: Write the failing Transport tests**

Append to `Tests/ReTiCATransportTests/TransportSinglePacketProofTests.swift`:

```swift
/// Transport state holding one receipt for a packet with hash `packetHash`, sent to `recipient`.
private func stateAwaitingProof(of packetHash: Data, from recipient: Identity, token: Data) -> Transport.State {
    var state = Transport.State()
    state.interfaces[ifID] = .default
    state.pendingReceipts[Data(packetHash.prefix(16))] = Transport.State.PendingReceipt(
        packetHash: packetHash, token: token, identity: Identity(publicKey: recipient.publicKey)!,
        expiresAt: now.addingTimeInterval(60))
    return state
}

/// A raw PROOF packet addressed to `packetHash`'s proof destination.
private func proofPacket(for packetHash: Data, payload: Data) -> Data {
    try! Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                destinationType: .single, context: .none, contextFlag: false, hops: 1,
                destinationHash: Data(packetHash.prefix(16)), transportId: nil, payload: payload).packed()
}

private let provedHash = Data(repeating: 0x5A, count: 32)
private let otherHash = Data(repeating: 0x5B, count: 32)

@Test @MainActor func proofValidationImplicitProofDeliversOnceAndClearsTheReceipt() async {
    let recipient = Identity()
    let token = Data("msg".utf8)
    let raw = proofPacket(for: provedHash, payload: recipient.sign(provedHash))
    let store = TestStore(initialState: stateAwaitingProof(of: provedHash, from: recipient, token: token)) {
        Transport()
    }
    await store.send(.received(ifID, raw)) { $0.pendingReceipts = [:] }
    await store.receive(.delegate(.singlePacketDelivered(token: token)))
    await store.send(.received(ifID, raw))   // a duplicate proof misses the lookup: nothing
}

@Test @MainActor func proofValidationExplicitProofDelivers() async {
    let recipient = Identity()
    let token = Data("msg".utf8)
    let raw = proofPacket(for: provedHash, payload: provedHash + recipient.sign(provedHash))
    let store = TestStore(initialState: stateAwaitingProof(of: provedHash, from: recipient, token: token)) {
        Transport()
    }
    await store.send(.received(ifID, raw)) { $0.pendingReceipts = [:] }
    await store.receive(.delegate(.singlePacketDelivered(token: token)))
}

@Test @MainActor func proofValidationWrongSignerIsIgnoredAndKeepsTheReceipt() async {
    let raw = proofPacket(for: provedHash, payload: Identity().sign(provedHash))
    let store = TestStore(initialState: stateAwaitingProof(of: provedHash, from: Identity(), token: Data([1]))) {
        Transport()
    }
    await store.send(.received(ifID, raw))   // exhaustive: no state change, no delegate
}

@Test @MainActor func proofValidationUnknownHashIsIgnored() async {
    let recipient = Identity()
    let raw = proofPacket(for: otherHash, payload: recipient.sign(otherHash))
    let store = TestStore(initialState: stateAwaitingProof(of: provedHash, from: recipient, token: Data([1]))) {
        Transport()
    }
    await store.send(.received(ifID, raw))
}

@Test @MainActor func proofValidationWrongLengthIsIgnored() async {
    let recipient = Identity()
    let raw = proofPacket(for: provedHash, payload: recipient.sign(provedHash) + Data([0x00]))   // 65 bytes
    let store = TestStore(initialState: stateAwaitingProof(of: provedHash, from: recipient, token: Data([1]))) {
        Transport()
    }
    await store.send(.received(ifID, raw))
}

/// An explicit proof whose signature is valid but whose embedded hash is not the receipt's must be
/// rejected (reference: `proof_hash == self.hash`, Packet.py:486).
@Test @MainActor func proofValidationExplicitProofWithAMismatchedHashIsIgnored() async {
    let recipient = Identity()
    let raw = proofPacket(for: provedHash, payload: otherHash + recipient.sign(provedHash))
    let store = TestStore(initialState: stateAwaitingProof(of: provedHash, from: recipient, token: Data([1]))) {
        Transport()
    }
    await store.send(.received(ifID, raw))
}

/// Proofs bypass the packet-hash dedup ring.
@Test @MainActor func proofValidationProofIsNotRecordedInTheDedupRing() async throws {
    let recipient = Identity()
    let raw = proofPacket(for: provedHash, payload: provedHash + recipient.sign(provedHash))
    let store = TestStore(initialState: stateAwaitingProof(of: provedHash, from: recipient, token: Data([1]))) {
        Transport()
    }
    store.exhaustivity = .off
    await store.send(.received(ifID, raw))
    await store.receive { if case .delegate(.singlePacketDelivered) = $0 { return true }; return false }
    #expect(!store.state.seenPacketHashes.contains(try #require(Packet(raw: raw)).packetHash))
}
```

- [ ] **Step 2: Write the failing reference-vector tests**

Append to `Tests/ReTiCATransportTests/Vectors/ProofCrossValidationTests.swift`:

```swift
/// Genuine RNS proofs — both forms — confirm a ReTiCA receipt for the proved packet.
@MainActor
private func assertReferenceProofConfirms(_ proofPacket: Data, _ f: ProofVectorFixtures) async {
    let token = Data("lxmf message hash".utf8)
    var initial = Transport.State()
    initial.interfaces[proofIfID] = .default
    initial.pendingReceipts[Data(f.dataPacketHashBytes.prefix(16))] = Transport.State.PendingReceipt(
        packetHash: f.dataPacketHashBytes, token: token, identity: f.publicIdentity, expiresAt: .distantFuture)
    let store = TestStore(initialState: initial) { Transport() }
    await store.send(.received(proofIfID, proofPacket)) { $0.pendingReceipts = [:] }
    await store.receive(.delegate(.singlePacketDelivered(token: token)))
}

@Test @MainActor func proofValidationAcceptsReferenceImplicitProof() async throws {
    let f = try ProofVectorFixtures.load()
    await assertReferenceProofConfirms(f.implicitProofPacketBytes, f)
}

@Test @MainActor func proofValidationAcceptsReferenceExplicitProof() async throws {
    let f = try ProofVectorFixtures.load()
    await assertReferenceProofConfirms(f.explicitProofPacketBytes, f)
}
```

- [ ] **Step 3: Write the failing endpoint test**

Append to `Tests/ReTiCANodeTests/TransportEndpointSinglePacketProofTests.swift`:

```swift
@Test @MainActor func proofValidationEndpointForwardsSinglePacketDelivered() async {
    let store = makeEndpoint()
    let token = Data([0xCD])
    await store.send(.transport(.delegate(.singlePacketDelivered(token: token))))
    await store.receive(.delegate(.singlePacketDelivered(token: token)))
}
```

- [ ] **Step 4: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter proofValidation`
Expected: build FAILS — no member `singlePacketDelivered`.

- [ ] **Step 5: Transport — delegate, constants, dedup exemption, `.proof` case**

In the `Delegate` enum after `            case linkRequest(destinationHash: Data, arrivalInterface: InterfaceID, data: Data)` add:
```swift
            /// A valid proof arrived for a packet sent with `receiptToken`; the receipt is gone.
            case singlePacketDelivered(token: Data)
```

Replace
```swift
                if packet.packetType != .announce {
                    guard state.seenPacketHashes.insert(packet.packetHash) else { return .none }
                }
```
with
```swift
                // Proofs are not deduped either: a proof is matched against `pendingReceipts`, and a
                // duplicate proof for a receipt already removed simply misses that lookup.
                if packet.packetType != .announce, packet.packetType != .proof {
                    guard state.seenPacketHashes.insert(packet.packetHash) else { return .none }
                }
```

Replace
```swift
                    return .none
                default:
                    return .none
                }
```
(the end of the `.linkRequest` case and the `default` of the inbound switch, :721-724) with
```swift
                    return .none
                case .proof:
                    // A delivery proof for a single packet we sent with a receipt token (RNS
                    // Transport.py:2334-2360 → PacketReceipt.validate_proof, Packet.py:480-515). It is
                    // addressed to our packet's ProofDestination, `packetHash[:16]`, which is exactly
                    // the `pendingReceipts` key — so where reference tries an implicit proof against
                    // every outstanding receipt, one lookup finds the only candidate.
                    guard packet.destinationType == .single,
                          let receipt = state.pendingReceipts[packet.destinationHash]
                    else { return .none }
                    let valid: Bool
                    switch packet.payload.count {
                    case Transport.implicitProofLength:
                        valid = receipt.identity.validate(signature: packet.payload, message: receipt.packetHash)
                    case Transport.explicitProofLength:
                        valid = packet.payload.prefix(32) == receipt.packetHash
                            && receipt.identity.validate(signature: Data(packet.payload.suffix(64)),
                                                         message: receipt.packetHash)
                    default:
                        valid = false
                    }
                    // A bad proof leaves the receipt in place, so a later genuine proof still confirms.
                    guard valid else { return .none }
                    state.pendingReceipts[packet.destinationHash] = nil
                    return .send(.delegate(.singlePacketDelivered(token: receipt.token)))
                default:
                    return .none
                }
```

After `    static let maxPendingReceipts = 1024` (Task 3) add:
```swift
    /// RNS `PacketReceipt.IMPL_LENGTH` (Packet.py:399): an implicit proof is the bare signature.
    static let implicitProofLength = 64
    /// RNS `PacketReceipt.EXPL_LENGTH` (Packet.py:398): packet hash (32) ‖ signature (64).
    static let explicitProofLength = 96
```

- [ ] **Step 6: TransportEndpoint — forward**

In the `Delegate` enum after `            case packetDeliveryFailed(token: Data)` add:
```swift
            /// A single (non-link) packet sent with a receipt token was proved. Distinct from
            /// `packetDelivered(token:)`, which stays link-only.
            case singlePacketDelivered(token: Data)
```
After the `.transport(.delegate(.received(...)))` forward case add:
```swift
            case let .transport(.delegate(.singlePacketDelivered(token))):
                return .send(.delegate(.singlePacketDelivered(token: token)))
```

- [ ] **Step 7: Run to see them pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter proofValidation`
Expected: 10 PASS.

- [ ] **Step 8: Mutation batch (apply all at once)**

1. `.proof` success: `.singlePacketDelivered(token: receipt.token)` → `.singlePacketDelivered(token: receipt.packetHash)` — breaks `proofValidationImplicitProofDeliversOnceAndClearsTheReceipt`, `proofValidationExplicitProofDelivers`, `proofValidationAcceptsReferenceImplicitProof`, `proofValidationAcceptsReferenceExplicitProof` (wrong token).
2. Explicit branch: delete `packet.payload.prefix(32) == receipt.packetHash\n                            && ` — breaks `proofValidationExplicitProofWithAMismatchedHashIsIgnored`.
3. Implicit branch: `valid = receipt.identity.validate(...)` → `valid = true` — breaks `proofValidationWrongSignerIsIgnoredAndKeepsTheReceipt`.
4. Lookup: `let receipt = state.pendingReceipts[packet.destinationHash]` → `let receipt = state.pendingReceipts[packet.destinationHash] ?? state.pendingReceipts.values.first` — breaks `proofValidationUnknownHashIsIgnored` (with 3, the implicit proof for the other hash is accepted).
5. `default: valid = false` → `default: valid = true` — breaks `proofValidationWrongLengthIsIgnored`.
6. Dedup: delete `, packet.packetType != .proof` — breaks `proofValidationProofIsNotRecordedInTheDedupRing` (its `receive` matches the delegate case whatever the token, so only this mutation fails it).
7. TransportEndpoint: the `singlePacketDelivered` forward returns `.none` — breaks `proofValidationEndpointForwardsSinglePacketDelivered`.

Masking check: 1 changes only the emitted value; 2, 3, 5 only ACCEPT more, so they cannot make a positive test pass that 1 broke; 4 only widens the lookup. No mutation calls `sign` or force-unwraps, so nothing traps.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter proofValidation`
Expected: all 10 FAIL.

- [ ] **Step 9: Revert and re-run**

Revert all seven. Run the Step 7 command: 10 PASS.

- [ ] **Step 10: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs`
Expected: all PASS.

- [ ] **Step 11: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs add Sources/ReTiCATransport/Transport.swift Sources/ReTiCANode/TransportEndpoint.swift Tests/ReTiCATransportTests/TransportSinglePacketProofTests.swift Tests/ReTiCATransportTests/Vectors/ProofCrossValidationTests.swift Tests/ReTiCANodeTests/TransportEndpointSinglePacketProofTests.swift`

Message:
```
feat: Transport validates single-packet proofs against receipts

A non-link PROOF is matched to its receipt by proof destination and
accepted in implicit or explicit form, emitting singlePacketDelivered.
Bad proofs are ignored and leave the receipt. Genuine RNS proofs of
both forms are accepted.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs commit -F /tmp/ReTiCaMsgr/commit-msg.txt`

---

### Task 5: Router tracks the delivery copy and the propagated copy separately

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (:14 `CancelID`; :30-34 state; :101 types; :171/:173 actions; :200-220 helpers; :373-390 `.send`; :406-423 `.sendViaPropagation`; :465-483 `.linkEstablished`; :543-598 `.delivered`/`.resourceDeliveredOnLink`/`.retryDue`)
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (:724-731)
- Create: `Tests/ReTiCANodeTests/LXMFRouterLegTests.swift`
- Modify (shape): `Tests/ReTiCANodeTests/LXMFRouterTests.swift`, `Tests/ReTiCANodeTests/StampWorkBoundsTests.swift` (:99), `Tests/ReTiCANodeTests/LXMFNodeDeliveryStampTests.swift` (:200, :226, :307, :369)

**Interfaces:**
- Produces: `LXMFRouter.Leg` (`delivery`, `propagated`; `Hashable, Sendable`), `LXMFRouter.DeliveryKey(messageHash: Data, leg: Leg)` with `static func delivery(_ messageHash: Data) -> DeliveryKey` and `static func propagated(_ messageHash: Data) -> DeliveryKey`.
- Produces: `State.pendingDeliveries: [DeliveryKey: PendingDelivery]`, `State.linkResourceInFlight: [Data: DeliveryKey]`.
- Produces: `Action.delivered(messageHash: Data, leg: Leg)`, `Action.retryDue(messageHash: Data, leg: Leg)`.
- Produces (reducer-local helper, Tasks 6 and 7 extend it): `func succeed(_ state: inout State, _ key: DeliveryKey) -> Effect<Action>`.
- LXMFNode: `packetDelivered(token)` → `.router(.delivered(messageHash: token, leg: .propagated))`; `packetDeliveryFailed(token)` → `.router(.retryDue(messageHash: token, leg: .propagated))`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFRouterLegTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let small = Data("small-container".utf8)          // <= Link.mdu → proof-requesting link packet
private let large = Data(repeating: 0xAA, count: 432)     // >  Link.mdu → Resource

private func makeMessage(content: String = "two copies") -> LXMessage {
    LXMessage.create(source: Identity(),
                     destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data(content.utf8))
}

/// A live link to the outbound propagation node, and a known path to `recipient`.
private func routerState(recipient: Data) -> LXMFRouter.State {
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    state.knownPaths.insert(recipient)
    return state
}

@MainActor
private func makeStore(_ state: LXMFRouter.State,
                       clock: TestClock<Duration> = TestClock()) -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func routerLegBothCopiesAreArmedSideBySide() async {
    let msg = makeMessage()
    let store = makeStore(routerState(recipient: msg.destinationHash))
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    #expect(store.state.pendingDeliveries.count == 2)
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.resend
            == .opportunistic(destinationHash: msg.destinationHash, payload: msg.opportunisticPayload))
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)]?.resend
            == .propagated(destinationHash: pn, data: small))
}

/// Regression for the collision: the propagated copy was armed LAST, and a receipt for the
/// delivery copy used to be reported as `propagationAccepted`.
@Test @MainActor func routerLegDeliveryReceiptAfterThePropagatedCopyIsArmedReportsDeliveryConfirmed() async {
    let msg = makeMessage()
    let store = makeStore(routerState(recipient: msg.destinationHash))
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    await store.send(.delivered(messageHash: msg.hash, leg: .delivery))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)] == nil)
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)] != nil)   // the other copy is untouched
}

@Test @MainActor func routerLegPropagatedReceiptResolvesOnlyThePropagatedCopy() async {
    let msg = makeMessage()
    let store = makeStore(routerState(recipient: msg.destinationHash))
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    await store.send(.delivered(messageHash: msg.hash, leg: .propagated))
    await store.receive(.delegate(.propagationAccepted(messageHash: msg.hash)))
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)] == nil)
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)] != nil)
}

/// One retry timer per copy: before, arming the second copy cancelled the first copy's timer.
@Test @MainActor func routerLegEachCopyRunsItsOwnRetryTimer() async {
    let msg = makeMessage()
    let clock = TestClock()
    let store = makeStore(routerState(recipient: msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    let legs = LockIsolated<Set<LXMFRouter.Leg>>([])
    for _ in 0..<2 {
        await store.receive { action in
            guard case let .retryDue(hash, leg) = action, hash == msg.hash else { return false }
            legs.withValue { _ = $0.insert(leg) }
            return true
        }
    }
    #expect(legs.value == [.delivery, .propagated])
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 2)
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)]?.attempts == 2)
}

/// A Resource conclusion resolves the copy that sent that Resource, not whichever was armed last.
@Test @MainActor func routerLegResourceConclusionResolvesTheCopyThatSentIt() async {
    let big = makeMessage(content: String(repeating: "y", count: 2000))
    #expect(big.directRepresentation == .resource)
    let recipientLink = Data(repeating: 0xEF, count: 16)
    var state = routerState(recipient: big.destinationHash)
    state.directLinks[big.destinationHash] = .active(linkID: recipientLink)
    let store = makeStore(state)
    await store.send(.send(message: big, desiredMethod: .direct))                  // Resource on the recipient link
    await store.send(.sendViaPropagation(message: big, propagationPacked: large))   // Resource on the PN link, armed LAST
    #expect(store.state.linkResourceInFlight[recipientLink] == LXMFRouter.DeliveryKey.delivery(big.hash))
    #expect(store.state.linkResourceInFlight[pnLink] == LXMFRouter.DeliveryKey.propagated(big.hash))

    await store.send(.resourceDeliveredOnLink(linkID: recipientLink))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: big.hash)))
    #expect(store.state.pendingDeliveries[.propagated(big.hash)] != nil)

    await store.send(.resourceDeliveredOnLink(linkID: pnLink))
    await store.receive(.delegate(.propagationAccepted(messageHash: big.hash)))
}

/// Link receipts come only from `sendPropagatedPacket` (the one receipted link send), so LXMFNode
/// routes them to the propagated copy.
@Test @MainActor func routerLegNodeRoutesLinkReceiptsToThePropagatedCopy() async {
    let store = TestStore(initialState: LXMFNode.State(
        identity: Identity(), endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    let hash = Data(repeating: 0x42, count: 32)
    await store.send(.endpoint(.delegate(.packetDelivered(token: hash))))
    await store.receive(.router(.delivered(messageHash: hash, leg: .propagated)))
    await store.send(.endpoint(.delegate(.packetDeliveryFailed(token: hash))))
    await store.receive(.router(.retryDue(messageHash: hash, leg: .propagated)))
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter routerLeg`
Expected: build FAILS — no `DeliveryKey`, `Leg`, `leg:` argument.

- [ ] **Step 3: Router — types, state, actions, CancelID**

In `Sources/ReTiCANode/LXMFRouter.swift`:

Replace `    private enum CancelID: Hashable { case retry(Data); case idle(Data); case pathRequest(Data) }` with
```swift
    private enum CancelID: Hashable { case retry(DeliveryKey); case idle(Data); case pathRequest(Data) }
```

Replace
```swift
        /// message.hash → in-flight send awaiting a delivery outcome (with its resend info + attempts).
        public var pendingDeliveries: [Data: PendingDelivery] = [:]
        /// linkID → message.hash of the Resource-direct send currently in flight on that link.
        /// Single-in-flight per link (last write wins); resolves resourceDeliveredOnLink → deliveryConfirmed.
        public var linkResourceInFlight: [Data: Data] = [:]
```
with
```swift
        /// (message.hash, copy) → in-flight send awaiting a delivery outcome (with its resend info +
        /// attempts). Keyed per COPY because `LXMFNode.sendMessage(alsoViaPropagation:)` arms a
        /// delivery copy and a propagated copy of one message; under one key the second overwrote
        /// the first and its outcome was reported as the other's.
        public var pendingDeliveries: [DeliveryKey: PendingDelivery] = [:]
        /// linkID → the copy whose Resource is currently in flight on that link. Single-in-flight per
        /// link (last write wins); `resourceDeliveredOnLink` resolves exactly that copy.
        public var linkResourceInFlight: [Data: DeliveryKey] = [:]
```

After `    public enum LinkStatus: Equatable { case awaitingPath; case establishing; case active(linkID: Data) }` add:
```swift

    /// Which copy of an outbound message a pending delivery tracks. `delivery` is the copy addressed
    /// to the recipient — opportunistic, or direct over a link, including an opportunistic send
    /// promoted to direct because it does not fit one packet. `propagated` is the copy handed to the
    /// outbound propagation node.
    public enum Leg: Hashable, Sendable { case delivery, propagated }

    /// Key of `pendingDeliveries` and of each copy's retry timer.
    public struct DeliveryKey: Hashable, Sendable {
        public var messageHash: Data
        public var leg: Leg
        public init(messageHash: Data, leg: Leg) {
            self.messageHash = messageHash
            self.leg = leg
        }
        public static func delivery(_ messageHash: Data) -> DeliveryKey { DeliveryKey(messageHash: messageHash, leg: .delivery) }
        public static func propagated(_ messageHash: Data) -> DeliveryKey { DeliveryKey(messageHash: messageHash, leg: .propagated) }
    }
```

Replace `        case delivered(messageHash: Data)` with
```swift
        /// A receipt for one copy of a message. The copy is named by the path that produced the
        /// receipt, never inferred from which copy was armed last.
        case delivered(messageHash: Data, leg: Leg)
```
and `        case retryDue(messageHash: Data)` with `        case retryDue(messageHash: Data, leg: Leg)`.

- [ ] **Step 4: Router — helpers**

Replace
```swift
            func retryTimer(_ hash: Data, _ seconds: Int) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(seconds))
                    await send(.retryDue(messageHash: hash))
                }.cancellable(id: CancelID.retry(hash), cancelInFlight: true)
            }
```
with
```swift
            func retryTimer(_ key: DeliveryKey, _ seconds: Int) -> Effect<Action> {
                .run { send in
                    try await clock.sleep(for: .seconds(seconds))
                    await send(.retryDue(messageHash: key.messageHash, leg: key.leg))
                }.cancellable(id: CancelID.retry(key), cancelInFlight: true)
            }
```
Replace
```swift
            func arm(_ state: inout State, _ hash: Data, _ resend: ResendInfo) {
                state.pendingDeliveries[hash] = PendingDelivery(resend: resend, attempts: 1)
            }
```
with
```swift
            func arm(_ state: inout State, _ key: DeliveryKey, _ resend: ResendInfo) {
                state.pendingDeliveries[key] = PendingDelivery(resend: resend, attempts: 1)
            }
            /// One copy of a message was confirmed: settle that copy only, stop its retries, and
            /// report the outcome that copy stands for. A receipt for a copy no longer pending is
            /// ignored.
            func succeed(_ state: inout State, _ key: DeliveryKey) -> Effect<Action> {
                guard state.pendingDeliveries[key] != nil else { return .none }
                state.pendingDeliveries[key] = nil
                let outcome: Action.Delegate = key.leg == .propagated
                    ? .propagationAccepted(messageHash: key.messageHash)
                    : .deliveryConfirmed(messageHash: key.messageHash)
                return .merge(.cancel(id: CancelID.retry(key)), .send(.delegate(outcome)))
            }
```

- [ ] **Step 5: Router — arming sites**

In `case let .send(message, desiredMethod):` replace
```swift
                case .opportunistic:
                    let resend = ResendInfo.opportunistic(destinationHash: message.destinationHash,
                                                          payload: message.opportunisticPayload)
                    arm(&state, message.hash, resend)
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: message.destinationHash,
                                                                     payload: message.opportunisticPayload))),
                                  retryTimer(message.hash, LXMFDelivery.retryWaitSeconds))
                case .direct:
                    let dest = message.destinationHash
                    if case let .active(linkID) = state.directLinks[dest] {
                        let asResource = message.directRepresentation == .resource
                        arm(&state, message.hash, .direct(destinationHash: dest, data: message.packed, asResource: asResource))
                        if asResource { state.linkResourceInFlight[linkID] = message.hash }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: message.packed,
                                                                  asResource: asResource))),
                                      retryTimer(message.hash, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(dest, linkID))
                    }
```
with
```swift
                case .opportunistic:
                    let key = DeliveryKey.delivery(message.hash)
                    let resend = ResendInfo.opportunistic(destinationHash: message.destinationHash,
                                                          payload: message.opportunisticPayload)
                    arm(&state, key, resend)
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: message.destinationHash,
                                                                     payload: message.opportunisticPayload))),
                                  retryTimer(key, LXMFDelivery.retryWaitSeconds))
                case .direct:
                    let dest = message.destinationHash
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

In `case let .sendViaPropagation(message, propagationPacked):` replace
```swift
                if case let .active(linkID) = state.directLinks[pn] {
                    arm(&state, message.hash, .propagated(destinationHash: pn, data: propagationPacked))
                    if propagationPacked.count <= Link.mdu {
                        // Small container: send as a proof-requesting link packet.
                        // token = message.hash so packetDelivered maps back to this pending delivery.
                        return .merge(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                            propagationPacked: propagationPacked,
                                                                            messageHash: message.hash))),
                                      retryTimer(message.hash, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(pn, linkID))
                    } else {
                        // Large container: send as Resource; receipt via resourceDeliveredOnLink (unchanged).
                        state.linkResourceInFlight[linkID] = message.hash
                        return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: propagationPacked))),
                                      retryTimer(message.hash, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(pn, linkID))
                    }
                }
```
with
```swift
                if case let .active(linkID) = state.directLinks[pn] {
                    let key = DeliveryKey.propagated(message.hash)
                    arm(&state, key, .propagated(destinationHash: pn, data: propagationPacked))
                    if propagationPacked.count <= Link.mdu {
                        // Small container: send as a proof-requesting link packet. token = message.hash,
                        // and LXMFNode maps its packetDelivered back to THIS copy (leg .propagated).
                        return .merge(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                            propagationPacked: propagationPacked,
                                                                            messageHash: message.hash))),
                                      retryTimer(key, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(pn, linkID))
                    } else {
                        // Large container: send as Resource; receipt via resourceDeliveredOnLink.
                        state.linkResourceInFlight[linkID] = key
                        return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: propagationPacked))),
                                      retryTimer(key, LXMFDelivery.retryWaitSeconds),
                                      idleTimer(pn, linkID))
                    }
                }
```

In `case let .linkEstablished(dest, linkID):` replace
```swift
                for m in queued {
                    let asResource = m.directRepresentation == .resource
                    arm(&state, m.hash, .direct(destinationHash: dest, data: m.packed, asResource: asResource))
                    if asResource { state.linkResourceInFlight[linkID] = m.hash }
                    effects.append(.send(.delegate(.sendDirect(linkID: linkID, data: m.packed, asResource: asResource))))
                    effects.append(retryTimer(m.hash, LXMFDelivery.retryWaitSeconds))
                }
                for item in propQueued {
                    arm(&state, item.messageHash, .propagated(destinationHash: dest, data: item.propagationPacked))
                    if item.propagationPacked.count <= Link.mdu {
                        effects.append(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                              propagationPacked: item.propagationPacked,
                                                                              messageHash: item.messageHash))))
                    } else {
                        state.linkResourceInFlight[linkID] = item.messageHash
                        effects.append(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: item.propagationPacked))))
                    }
                    effects.append(retryTimer(item.messageHash, LXMFDelivery.retryWaitSeconds))
                }
```
with
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

- [ ] **Step 6: Router — outcome and retry cases**

Replace everything from `            case let .delivered(hash):` down to (not including) `            case let .idleDeadline(dest, linkID):` with:
```swift
            case let .delivered(hash, leg):
                return succeed(&state, DeliveryKey(messageHash: hash, leg: leg))

            case let .resourceDeliveredOnLink(linkID):
                guard let key = state.linkResourceInFlight[linkID] else { return .none }
                state.linkResourceInFlight[linkID] = nil
                return .send(.delivered(messageHash: key.messageHash, leg: key.leg))

            case let .retryDue(hash, leg):
                let key = DeliveryKey(messageHash: hash, leg: leg)
                guard var pending = state.pendingDeliveries[key] else { return .none }
                pending.attempts += 1
                if pending.attempts > LXMFDelivery.maxAttempts {
                    state.pendingDeliveries[key] = nil
                    return .send(.delegate(.deliveryFailed(messageHash: hash)))
                }
                state.pendingDeliveries[key] = pending
                switch pending.resend {
                case let .opportunistic(destinationHash, payload):
                    if !state.knownPaths.contains(destinationHash) {
                        // Pathless opportunistic retry: request a path instead of resending, and wait longer.
                        return .merge(.send(.delegate(.requestPath(destinationHash: destinationHash))),
                                      retryTimer(key, LXMFDelivery.pathRequestWaitSeconds))
                    }
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: destinationHash, payload: payload))),
                                  retryTimer(key, LXMFDelivery.retryWaitSeconds))
                case let .direct(destinationHash, data, asResource):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        if asResource { state.linkResourceInFlight[linkID] = key }
                        return .merge(.send(.delegate(.sendDirect(linkID: linkID, data: data, asResource: asResource))),
                                      retryTimer(key, LXMFDelivery.retryWaitSeconds))
                    }
                    // Link is down or re-establishing: no live link to send on. Wait and re-check; the
                    // attempt was already counted, so the saga stays bounded by maxAttempts.
                    return retryTimer(key, LXMFDelivery.retryWaitSeconds)
                case let .propagated(destinationHash, data):
                    if case let .active(linkID) = state.directLinks[destinationHash] {
                        if data.count <= Link.mdu {
                            return .merge(.send(.delegate(.sendPropagatedPacket(linkID: linkID,
                                                                                propagationPacked: data,
                                                                                messageHash: hash))),
                                          retryTimer(key, LXMFDelivery.retryWaitSeconds))
                        } else {
                            state.linkResourceInFlight[linkID] = key
                            return .merge(.send(.delegate(.sendPropagated(linkID: linkID, propagationPacked: data))),
                                          retryTimer(key, LXMFDelivery.retryWaitSeconds))
                        }
                    }
                    // Link down/re-establishing: no live link; wait and re-check (bounded by maxAttempts).
                    return retryTimer(key, LXMFDelivery.retryWaitSeconds)
                }

```

- [ ] **Step 7: LXMFNode — link receipts belong to the propagated copy**

In `Sources/ReTiCANode/LXMFNode.swift` replace
```swift
            case let .endpoint(.delegate(.packetDelivered(token))):
                // token == message.hash (set when sendPropagatedPacket was dispatched)
                // → feeds the router's existing delivered→propagationAccepted path
                return .send(.router(.delivered(messageHash: token)))

            case let .endpoint(.delegate(.packetDeliveryFailed(token))):
                // Treat a lost packet the same as a retry-due so the message isn't silently dropped.
                return .send(.router(.retryDue(messageHash: token)))
```
with
```swift
            case let .endpoint(.delegate(.packetDelivered(token))):
                // token == message.hash, set when `sendPropagatedPacket` was dispatched. That is the
                // ONLY link send that requests a receipt (direct link packets go out via
                // `sendOverLink`, unreceipted), so a link receipt always belongs to the PROPAGATED copy.
                return .send(.router(.delivered(messageHash: token, leg: .propagated)))

            case let .endpoint(.delegate(.packetDeliveryFailed(token))):
                // Treat a lost packet the same as a retry-due so the message isn't silently dropped.
                // Same reasoning as above: a link receipt is always the propagated copy's.
                return .send(.router(.retryDue(messageHash: token, leg: .propagated)))
```

- [ ] **Step 8: Update existing tests to the new shapes**

8a. Confirm the propagated-copy lines in `LXMFRouterTests.swift`:
Run: `grep -n "pendingDeliveries\[\|linkResourceInFlight\[linkID\] ==\|delivered(messageHash" /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/LXMFRouterTests.swift`
The PROPAGATED copy's lines are the ones inside `routerPropagationDrainsOnLinkEstablished` (1256), `routerPropagationSendsImmediatelyWithActiveLink` (1279), `routerPropagationRetryResendsSameBytes` (1305), `propagationSmallSendsPacketAndAcceptsOnProof` (1339, 1344 comment, 1345, 1353) and `routerConfirmsPropagationAcceptOnResourceDelivered` (1645, 1646, 1653). If the numbers differ, adjust the addresses below to the lines inside those tests.

Write `/tmp/ReTiCaMsgr/t5-propagated.sed`:
```
1256s/pendingDeliveries\[msg\.hash\]/pendingDeliveries[.propagated(msg.hash)]/
1279s/pendingDeliveries\[msg\.hash\]/pendingDeliveries[.propagated(msg.hash)]/
1305s/pendingDeliveries\[msg\.hash\]/pendingDeliveries[.propagated(msg.hash)]/
1339s/pendingDeliveries\[msg\.hash\]/pendingDeliveries[.propagated(msg.hash)]/
1344s/router(\.delivered(messageHash: token))/router(.delivered(messageHash: token, leg: .propagated))/
1345s/\.delivered(messageHash: msg\.hash)/.delivered(messageHash: msg.hash, leg: .propagated)/
1353s/pendingDeliveries\[msg\.hash\]/pendingDeliveries[.propagated(msg.hash)]/
1645s/linkResourceInFlight\[linkID\] == msg\.hash/linkResourceInFlight[linkID] == LXMFRouter.DeliveryKey.propagated(msg.hash)/
1646s/pendingDeliveries\[msg\.hash\]/pendingDeliveries[.propagated(msg.hash)]/
1653s/pendingDeliveries\[msg\.hash\]/pendingDeliveries[.propagated(msg.hash)]/
```
Run: `sed -i '' -f /tmp/ReTiCaMsgr/t5-propagated.sed /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/LXMFRouterTests.swift`

8b. Everything left is the delivery copy. Write `/tmp/ReTiCaMsgr/t5-delivery.sed` (`[^,)]*` skips the lines 8a already gave a leg):
```
s/\.delivered(messageHash: \([^,)]*\))/.delivered(messageHash: \1, leg: .delivery)/g
s/pendingDeliveries\[\([A-Za-z]*\)\.hash\]/pendingDeliveries[.delivery(\1.hash)]/g
s/linkResourceInFlight\[linkID\] == bigMsg\.hash/linkResourceInFlight[linkID] == LXMFRouter.DeliveryKey.delivery(bigMsg.hash)/g
```
Run: `sed -i '' -f /tmp/ReTiCaMsgr/t5-delivery.sed /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/LXMFRouterTests.swift /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/StampWorkBoundsTests.swift /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/LXMFNodeDeliveryStampTests.swift`

8c. Check nothing was missed:
Run: `grep -rn "delivered(messageHash: [^,)]*)\|pendingDeliveries\[[a-zA-Z]*\.hash\]" /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests`
Expected: no output.

- [ ] **Step 9: Run the new and changed tests**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs`
Expected: all PASS (includes 6 `routerLeg*` and the edited router/stamp tests).

- [ ] **Step 10: Mutation batch (apply all at once)**

1. `arm`: `state.pendingDeliveries[key] = ...` → `state.pendingDeliveries[DeliveryKey(messageHash: key.messageHash, leg: .delivery)] = ...` (every copy under the delivery leg — the old single-key behaviour) — breaks `routerLegBothCopiesAreArmedSideBySide` (count 1), `routerLegDeliveryReceiptAfterThePropagatedCopyIsArmedReportsDeliveryConfirmed` (propagated copy missing), `routerLegPropagatedReceiptResolvesOnlyThePropagatedCopy` (no propagated pending → no outcome), `routerLegEachCopyRunsItsOwnRetryTimer` (the propagated `retryDue` finds nothing, attempts check fails), `routerLegResourceConclusionResolvesTheCopyThatSentIt` (propagated pending missing after the first conclusion), and the edited `propagationSmallSendsPacketAndAcceptsOnProof`.
2. LXMFNode `packetDelivered`: `leg: .propagated` → `leg: .delivery` — breaks `routerLegNodeRoutesLinkReceiptsToThePropagatedCopy`.
3. LXMFNode `packetDeliveryFailed`: `leg: .propagated` → `leg: .delivery` — same test, second half.

2 and 3 are in LXMFNode, 1 in the router; none restores another's assertion. Nothing traps.

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter routerLeg --filter propagationSmallSendsPacketAndAcceptsOnProof`
Expected: all 7 FAIL.

- [ ] **Step 11: Revert and re-run**

Revert all three. Run the Step 10 command: 7 PASS. Then the full suite once more: all PASS.

- [ ] **Step 12: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs add Sources/ReTiCANode/LXMFRouter.swift Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFRouterLegTests.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift Tests/ReTiCANodeTests/StampWorkBoundsTests.swift Tests/ReTiCANodeTests/LXMFNodeDeliveryStampTests.swift`

Message:
```
fix: router tracks the delivery and propagated copies separately

pendingDeliveries, linkResourceInFlight and the retry timers are keyed
by (messageHash, leg), and delivered names the copy it confirms. A
delivery receipt after the propagated copy is armed is no longer
reported as propagationAccepted.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs commit -F /tmp/ReTiCaMsgr/commit-msg.txt`

---

### Task 6: Opportunistic sends carry a receipt token and are confirmed by proofs

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (Delegate `sendOpportunistic` :181; Action enum next to `delivered`; `.send` opportunistic branch; `.retryDue` opportunistic resend; new case)
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (:597-598; new case after the `packetDeliveryFailed` case)
- Create: `Tests/ReTiCANodeTests/LXMFOpportunisticReceiptTests.swift`
- Modify (shape): `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (:133, :564)

**Interfaces:**
- Consumes: `TransportEndpoint.Action.send(destinationHash:plaintext:receiptToken:)` (Task 3), `TransportEndpoint.Action.Delegate.singlePacketDelivered(token:)` (Task 4), `succeed(_:_:)` (Task 5).
- Produces: `LXMFRouter.Action.Delegate.sendOpportunistic(destinationHash: Data, payload: Data, messageHash: Data)`; `LXMFRouter.Action.opportunisticDelivered(messageHash: Data)`.
- LXMFNode: `sendOpportunistic(dest, payload, hash)` → `.endpoint(.send(destinationHash: dest, plaintext: payload, receiptToken: hash))`; `endpoint(.delegate(.singlePacketDelivered(token)))` → `.router(.opportunisticDelivered(messageHash: token))`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFOpportunisticReceiptTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)

private func makeMessage() -> LXMessage {
    LXMessage.create(source: Identity(),
                     destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data("receipted".utf8))
}

@MainActor
private func makeRouter(_ state: LXMFRouter.State,
                        clock: TestClock<Duration> = TestClock()) -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

@MainActor
private func makeNode() -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let store = TestStore(initialState: LXMFNode.State(
        identity: Identity(), endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    ) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

@Test @MainActor func opportunisticReceiptSendCarriesTheMessageHash() async {
    let msg = makeMessage()
    let store = makeRouter(LXMFRouter.State())
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive(.delegate(.sendOpportunistic(destinationHash: msg.destinationHash,
                                                     payload: msg.opportunisticPayload,
                                                     messageHash: msg.hash)))
}

/// A proof confirms the delivery copy, and no retry survives it.
@Test @MainActor func opportunisticReceiptConfirmsAndCancelsTheRetry() async {
    let msg = makeMessage()
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.knownPaths.insert(msg.destinationHash)
    let store = makeRouter(state, clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.opportunisticDelivered(messageHash: msg.hash))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(store.state.pendingDeliveries.isEmpty)
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on   // a retry that outlived the proof is an unexpected action at teardown
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
}

/// Each resend carries the same message hash (so its packet gets a receipt under the same token),
/// and a proof for the RESEND confirms the message.
@Test @MainActor func opportunisticReceiptProofOfTheResendConfirms() async {
    let msg = makeMessage()
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.knownPaths.insert(msg.destinationHash)
    let store = makeRouter(state, clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.receive { if case .delegate(.sendOpportunistic) = $0 { return true }; return false }   // first send
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await store.receive { action in                                                                    // the resend
        guard case let .delegate(.sendOpportunistic(_, _, hash)) = action else { return false }
        return hash == msg.hash
    }
    #expect(store.state.pendingDeliveries[.delivery(msg.hash)]?.attempts == 2)
    await store.send(.opportunisticDelivered(messageHash: msg.hash))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
}

@Test @MainActor func opportunisticReceiptDoesNotTouchThePropagatedCopy() async {
    let msg = makeMessage()
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    let store = makeRouter(state)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: Data("small".utf8)))
    await store.send(.opportunisticDelivered(messageHash: msg.hash))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(store.state.pendingDeliveries[.propagated(msg.hash)] != nil)
}

@Test @MainActor func opportunisticReceiptNodeSendsWithTheMessageHashAsToken() async {
    let store = makeNode()
    let dest = Data(repeating: 0xD2, count: 16)
    let payload = Data("p".utf8)
    let hash = Data(repeating: 0x43, count: 32)
    await store.send(.router(.delegate(.sendOpportunistic(destinationHash: dest, payload: payload, messageHash: hash))))
    await store.receive(.endpoint(.send(destinationHash: dest, plaintext: payload, receiptToken: hash)))
}

@Test @MainActor func opportunisticReceiptNodeRoutesSinglePacketDelivered() async {
    let store = makeNode()
    let hash = Data(repeating: 0x44, count: 32)
    await store.send(.endpoint(.delegate(.singlePacketDelivered(token: hash))))
    await store.receive(.router(.opportunisticDelivered(messageHash: hash)))
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter opportunisticReceipt`
Expected: build FAILS — extra argument `messageHash`, no member `opportunisticDelivered`.

- [ ] **Step 3: Router**

In `Sources/ReTiCANode/LXMFRouter.swift`:

Replace `            case sendOpportunistic(destinationHash: Data, payload: Data)` with
```swift
            /// `messageHash` becomes the packet's receipt token, so a proof for ANY attempt of this
            /// message comes back as `.opportunisticDelivered(messageHash:)`.
            case sendOpportunistic(destinationHash: Data, payload: Data, messageHash: Data)
```
After the `case delivered(messageHash: Data, leg: Leg)` declaration (Task 5) add:
```swift
        /// A single-packet proof arrived for one of this message's opportunistic packets (Transport
        /// `singlePacketDelivered`, token = message hash). Confirms the DELIVERY copy.
        case opportunisticDelivered(messageHash: Data)
```
In the `.send` opportunistic branch replace
```swift
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: message.destinationHash,
                                                                     payload: message.opportunisticPayload))),
                                  retryTimer(key, LXMFDelivery.retryWaitSeconds))
```
with
```swift
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: message.destinationHash,
                                                                     payload: message.opportunisticPayload,
                                                                     messageHash: message.hash))),
                                  retryTimer(key, LXMFDelivery.retryWaitSeconds))
```
In `.retryDue` replace
```swift
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: destinationHash, payload: payload))),
                                  retryTimer(key, LXMFDelivery.retryWaitSeconds))
```
with
```swift
                    return .merge(.send(.delegate(.sendOpportunistic(destinationHash: destinationHash, payload: payload,
                                                                     messageHash: hash))),
                                  retryTimer(key, LXMFDelivery.retryWaitSeconds))
```
After the `case let .delivered(hash, leg):` case add:
```swift
            case let .opportunisticDelivered(hash):
                return succeed(&state, .delivery(hash))
```

- [ ] **Step 4: LXMFNode**

Replace
```swift
            case let .router(.delegate(.sendOpportunistic(dest, payload))):
                return .send(.endpoint(.send(destinationHash: dest, plaintext: payload)))
```
with
```swift
            case let .router(.delegate(.sendOpportunistic(dest, payload, messageHash))):
                // The message hash is the receipt token: every resend is a new packet with its own
                // receipt under the same token, so a proof for any attempt confirms the message.
                return .send(.endpoint(.send(destinationHash: dest, plaintext: payload, receiptToken: messageHash)))
```
After the `case let .endpoint(.delegate(.packetDeliveryFailed(token))):` case add:
```swift
            case let .endpoint(.delegate(.singlePacketDelivered(token))):
                return .send(.router(.opportunisticDelivered(messageHash: token)))
```

- [ ] **Step 5: Update the two existing router patterns**

In `Tests/ReTiCANodeTests/LXMFRouterTests.swift`:
- `if case let .delegate(.sendOpportunistic(dest, payload)) = action {` → `if case let .delegate(.sendOpportunistic(dest, payload, _)) = action {`
- `if case let .delegate(.sendOpportunistic(dest, _)) = action {` → `if case let .delegate(.sendOpportunistic(dest, _, _)) = action {`

- [ ] **Step 6: Run to see them pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter opportunisticReceipt`
Expected: 6 PASS.

- [ ] **Step 7: Mutation batch (apply all at once)**

1. Router `.send`: `messageHash: message.hash` → `messageHash: message.destinationHash` — breaks `opportunisticReceiptSendCarriesTheMessageHash`.
2. Router `.retryDue`: `messageHash: hash` (in the `sendOpportunistic` resend) → `messageHash: Data()` — breaks `opportunisticReceiptProofOfTheResendConfirms` (the resend predicate never matches).
3. Router `.opportunisticDelivered`: `.delivery(hash)` → `.propagated(hash)` — breaks `opportunisticReceiptConfirmsAndCancelsTheRetry` (no confirmation), `opportunisticReceiptDoesNotTouchThePropagatedCopy` (confirms the wrong copy).
4. LXMFNode: `receiptToken: messageHash` → `receiptToken: nil` — breaks `opportunisticReceiptNodeSendsWithTheMessageHashAsToken`.
5. LXMFNode `singlePacketDelivered` case returns `.none` — breaks `opportunisticReceiptNodeRoutesSinglePacketDelivered`.

Each mutation changes one value on a distinct line; none can make another's failing assertion pass. Nothing traps.

Run the Step 6 command. Expected: all 6 FAIL.

- [ ] **Step 8: Revert, re-run, full suite**

Revert all five. Run the Step 6 command (6 PASS), then `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs` (all PASS).

- [ ] **Step 9: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs add Sources/ReTiCANode/LXMFRouter.swift Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFOpportunisticReceiptTests.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift`

Message:
```
feat: opportunistic LXMF sends are confirmed by single-packet proofs

sendOpportunistic carries the message hash, which LXMFNode passes as the
receipt token. singlePacketDelivered becomes opportunisticDelivered in
the router, which confirms the delivery copy and cancels its retries.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs commit -F /tmp/ReTiCaMsgr/commit-msg.txt`

---

### Task 7: A message fails only when every copy has failed and none succeeded

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (state after `seen` :20; helpers after `succeed`; `succeed`; `giveUp` :250-253; `.sendViaPropagation` guard :403-405; `.retryDue` ceiling; new static constant)
- Create: `Tests/ReTiCANodeTests/LXMFRouterCopyOutcomeTests.swift`

**Interfaces:**
- Consumes: `DeliveryKey`, `succeed` (Task 5), `.opportunisticDelivered` (Task 6).
- Produces: `LXMFRouter.succeededMessageMemory = 1024`; internal `State.succeededMessages: RingSet`; reducer-local `isOutstanding(_ state: State, _ hash: Data, _ leg: Leg) -> Bool` and `fail(_ state: inout State, _ key: DeliveryKey) -> Effect<Action>`. Every router path that used to emit `deliveryFailed` (retry ceiling, `giveUp` of queued copies, `sendViaPropagation` without a node) now goes through `fail`.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFRouterCopyOutcomeTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCATransport

private let pn = Data(repeating: 0xBB, count: 16)
private let pnLink = Data(repeating: 0xC0, count: 16)
private let small = Data("small-container".utf8)

private func makeMessage() -> LXMessage {
    LXMessage.create(source: Identity(),
                     destinationHash: LXMessage.deliveryHash(identityHash: Identity().hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data("two copies".utf8))
}

/// A live link to the propagation node and a known path to `recipient`, so both copies are armed
/// with retry timers and every retry resends (10 s apart).
private func bothCopiesLive(recipient: Data) -> LXMFRouter.State {
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .active(linkID: pnLink)
    state.knownPaths.insert(recipient)
    return state
}

@MainActor
private func makeStore(_ state: LXMFRouter.State, clock: TestClock<Duration>) -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: { $0.continuousClock = clock }
    store.exhaustivity = .off
    return store
}

/// Advance to just before a copy's LAST retry, drop everything so far, and turn exhaustive on:
/// the final retry is then asserted exactly, and anything after it (a deliveryFailed) is a stray.
@MainActor
private func advanceToTheFinalRetry(_ store: TestStore<LXMFRouter.State, LXMFRouter.Action>, _ clock: TestClock<Duration>) async {
    for _ in 0..<(LXMFDelivery.maxAttempts - 1) {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.skipReceivedActions(strict: false)
    store.exhaustivity = .on
    await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
}

@Test @MainActor func copyOutcomeDeliveryFailedWaitsForEveryCopy() async {
    let msg = makeMessage()
    let clock = TestClock()
    let store = makeStore(bothCopiesLive(recipient: msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    for _ in 0..<LXMFDelivery.maxAttempts {
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    }
    await store.receive(.delegate(.deliveryFailed(messageHash: msg.hash)))
    #expect(store.state.pendingDeliveries.isEmpty)
    await store.skipInFlightEffects(strict: false)   // the PN link's idle timer
    store.exhaustivity = .on   // a SECOND deliveryFailed (from the first copy to fail) fails teardown
}

@Test @MainActor func copyOutcomeNoFailureAfterThePropagatedCopySucceeded() async {
    let msg = makeMessage()
    let clock = TestClock()
    let store = makeStore(bothCopiesLive(recipient: msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    await store.send(.delivered(messageHash: msg.hash, leg: .propagated))
    await store.receive(.delegate(.propagationAccepted(messageHash: msg.hash)))
    await advanceToTheFinalRetry(store, clock)
    await store.receive(.retryDue(messageHash: msg.hash, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(msg.hash)] = nil
    }
    await store.skipInFlightEffects(strict: false)   // the PN link's idle timer
}

@Test @MainActor func copyOutcomeNoFailureAfterTheDeliveryCopySucceeded() async {
    let msg = makeMessage()
    let clock = TestClock()
    let store = makeStore(bothCopiesLive(recipient: msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    await store.send(.opportunisticDelivered(messageHash: msg.hash))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    await advanceToTheFinalRetry(store, clock)
    await store.receive(.retryDue(messageHash: msg.hash, leg: .propagated)) {
        $0.pendingDeliveries[.propagated(msg.hash)] = nil
    }
    await store.skipInFlightEffects(strict: false)
}

/// The propagated copy is armed only after its propagation stamp is found — possibly after the
/// delivery copy was already confirmed. Its later failure must stay silent.
@Test @MainActor func copyOutcomeLateArmedPropagatedFailureAfterSuccessIsSilent() async {
    let msg = makeMessage()
    let clock = TestClock()
    let store = makeStore(bothCopiesLive(recipient: msg.destinationHash), clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.opportunisticDelivered(messageHash: msg.hash))
    await store.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))   // armed only now
    await advanceToTheFinalRetry(store, clock)
    await store.receive(.retryDue(messageHash: msg.hash, leg: .propagated)) {
        $0.pendingDeliveries[.propagated(msg.hash)] = nil
    }
    await store.skipInFlightEffects(strict: false)
}

/// A propagated copy QUEUED behind a link request has no timer yet, but it is outstanding: the
/// delivery copy running out must not fail the message.
@Test @MainActor func copyOutcomeQueuedPropagatedCopyKeepsTheMessageAlive() async {
    let msg = makeMessage()
    let clock = TestClock()
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.knownPaths.insert(pn)                    // no link yet → the copy queues and a link is requested
    state.knownPaths.insert(msg.destinationHash)
    let store = makeStore(state, clock: clock)
    await store.send(.send(message: msg, desiredMethod: .opportunistic))
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))
    #expect(store.state.propagationQueue[pn]?.count == 1)
    await advanceToTheFinalRetry(store, clock)
    await store.receive(.retryDue(messageHash: msg.hash, leg: .delivery)) {
        $0.pendingDeliveries[.delivery(msg.hash)] = nil
    }
}

/// A queued copy that gives up (its destination's establishment budget is spent) does not fail
/// the message while the other copy is still pending.
@Test @MainActor func copyOutcomeGiveUpOnAQueuedCopyWaitsForTheOtherCopy() async {
    let msg = makeMessage()
    var state = LXMFRouter.State()
    state.outboundPropagationNode = pn
    state.directLinks[pn] = .awaitingPath
    state.establishAttempts[pn] = LXMFDelivery.maxAttempts
    state.propagationQueue[pn] = [LXMFRouter.PropagationItem(messageHash: msg.hash, propagationPacked: small)]
    state.pendingDeliveries[.delivery(msg.hash)] = LXMFRouter.PendingDelivery(
        resend: .opportunistic(destinationHash: msg.destinationHash, payload: msg.opportunisticPayload), attempts: 1)
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    // Exhaustive: the park deadline gives up on the PN; a deliveryFailed would be unexpected.
    await store.send(.pathRequestDeadline(destinationHash: pn)) {
        $0.directLinks[pn] = nil
        $0.establishAttempts[pn] = nil
        $0.propagationQueue[pn] = nil
    }
}

/// `sendMessage(alsoViaPropagation: true)` with no propagation node configured: the propagated copy
/// fails at once, but the delivery copy is pending, so nothing is reported.
@Test @MainActor func copyOutcomeNoPropagationNodeDoesNotFailAPendingDeliveryCopy() async {
    let msg = makeMessage()
    var state = LXMFRouter.State()
    state.pendingDeliveries[.delivery(msg.hash)] = LXMFRouter.PendingDelivery(
        resend: .opportunistic(destinationHash: msg.destinationHash, payload: msg.opportunisticPayload), attempts: 1)
    let store = TestStore(initialState: state) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.sendViaPropagation(message: msg, propagationPacked: small))   // exhaustive: nothing happens
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter copyOutcome`
Expected: the tests compile (they use only Task 5/6 API) and FAIL — `copyOutcomeDeliveryFailedWaitsForEveryCopy` sees two `deliveryFailed`, the "no failure" tests see a stray `deliveryFailed`.

- [ ] **Step 3: Router — remember successes**

After `        var seen = RingSet(capacity: 10_000)` add:
```swift
        /// Message hashes one of whose copies has succeeded. A copy that fails LATER — even one armed
        /// after the success, as a propagated copy is once its stamp search finishes — is then not
        /// reported as `deliveryFailed`. Bounded like `seen`; see `succeededMessageMemory`.
        var succeededMessages = RingSet(capacity: LXMFRouter.succeededMessageMemory)
```
Immediately before `    public var body: some ReducerOf<Self> {` (unique in the file — note that `public init() {}` is NOT unique, `State` has one too) add:
```swift
    /// How many recently-succeeded message hashes `succeededMessages` remembers. A copy that fails
    /// more than this many successes later could be reported failed; far beyond any retry saga.
    static let succeededMessageMemory = 1024

```

- [ ] **Step 4: Router — `succeed`, `isOutstanding`, `fail`**

Replace the `succeed` helper from Task 5 with:
```swift
            /// One copy of a message was confirmed: settle that copy only, stop its retries, remember
            /// the success, and report the outcome that copy stands for. A receipt for a copy no
            /// longer pending is ignored.
            func succeed(_ state: inout State, _ key: DeliveryKey) -> Effect<Action> {
                guard state.pendingDeliveries[key] != nil else { return .none }
                state.pendingDeliveries[key] = nil
                state.succeededMessages.insert(key.messageHash)
                let outcome: Action.Delegate = key.leg == .propagated
                    ? .propagationAccepted(messageHash: key.messageHash)
                    : .deliveryConfirmed(messageHash: key.messageHash)
                return .merge(.cancel(id: CancelID.retry(key)), .send(.delegate(outcome)))
            }
            /// Whether the `leg` copy of `hash` can still succeed: armed with a retry timer, or queued
            /// behind its link (not yet armed, but it will be when the link comes up).
            func isOutstanding(_ state: State, _ hash: Data, _ leg: Leg) -> Bool {
                if state.pendingDeliveries[DeliveryKey(messageHash: hash, leg: leg)] != nil { return true }
                switch leg {
                case .delivery:
                    return state.outboundQueue.values.contains { $0.contains { $0.hash == hash } }
                case .propagated:
                    return state.propagationQueue.values.contains { $0.contains { $0.messageHash == hash } }
                }
            }
            /// One copy of a message has failed for good. `deliveryFailed` is reported only when no
            /// other copy can still succeed and none already did (spec §3).
            func fail(_ state: inout State, _ key: DeliveryKey) -> Effect<Action> {
                state.pendingDeliveries[key] = nil
                let other: Leg = key.leg == .delivery ? .propagated : .delivery
                guard !isOutstanding(state, key.messageHash, other),
                      !state.succeededMessages.contains(key.messageHash)
                else { return .none }
                return .send(.delegate(.deliveryFailed(messageHash: key.messageHash)))
            }
```
(These sit right after `arm`, before `clearDirectLink` and `giveUp`, so `giveUp` can call `fail`.)

- [ ] **Step 5: Router — route every failure through `fail`**

In `giveUp` replace
```swift
                var effects: [Effect<Action>] = [.cancel(id: CancelID.pathRequest(dest))]
                effects += queued.map { .send(.delegate(.deliveryFailed(messageHash: $0.hash))) }
                effects += propQueued.map { .send(.delegate(.deliveryFailed(messageHash: $0.messageHash))) }
                return .merge(effects)
```
with
```swift
                var effects: [Effect<Action>] = [.cancel(id: CancelID.pathRequest(dest))]
                for message in queued { effects.append(fail(&state, .delivery(message.hash))) }
                for item in propQueued { effects.append(fail(&state, .propagated(item.messageHash))) }
                return .merge(effects)
```
In `.sendViaPropagation` replace
```swift
                guard let pn = state.outboundPropagationNode else {
                    return .send(.delegate(.deliveryFailed(messageHash: message.hash)))
                }
```
with
```swift
                guard let pn = state.outboundPropagationNode else {
                    return fail(&state, .propagated(message.hash))
                }
```
In `.retryDue` replace
```swift
                if pending.attempts > LXMFDelivery.maxAttempts {
                    state.pendingDeliveries[key] = nil
                    return .send(.delegate(.deliveryFailed(messageHash: hash)))
                }
```
with
```swift
                if pending.attempts > LXMFDelivery.maxAttempts {
                    return fail(&state, key)
                }
```

- [ ] **Step 6: Run to see them pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter copyOutcome`
Expected: 7 PASS.

- [ ] **Step 7: Mutation batch (apply all at once)**

1. `fail`: delete `!isOutstanding(state, key.messageHash, other),\n                      ` from the guard — breaks `copyOutcomeDeliveryFailedWaitsForEveryCopy` (two failures), `copyOutcomeQueuedPropagatedCopyKeepsTheMessageAlive`, `copyOutcomeGiveUpOnAQueuedCopyWaitsForTheOtherCopy`, `copyOutcomeNoPropagationNodeDoesNotFailAPendingDeliveryCopy` (a stray `deliveryFailed` each).
2. `fail`: delete `!state.succeededMessages.contains(key.messageHash)` (keep the guard syntactically valid, e.g. replace it with `true`) — breaks `copyOutcomeNoFailureAfterThePropagatedCopySucceeded`, `copyOutcomeNoFailureAfterTheDeliveryCopySucceeded`, `copyOutcomeLateArmedPropagatedFailureAfterSuccessIsSilent` (a stray `deliveryFailed` each).

Both mutations only ADD emissions, and every test's failure is a stray emission, so neither can mask the other. Nothing traps.

Run the Step 6 command. Expected: all 7 FAIL.

- [ ] **Step 8: Revert, re-run, full suite**

Revert both. Run the Step 6 command (7 PASS), then the full suite (all PASS — `routerRetriesThenFailsAtMaxAttempts` and `routerPropagationFailsWithNoNode` still see their single-copy `deliveryFailed`).

- [ ] **Step 9: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs add Sources/ReTiCANode/LXMFRouter.swift Tests/ReTiCANodeTests/LXMFRouterCopyOutcomeTests.swift`

Message:
```
fix: deliveryFailed only after every copy failed and none succeeded

All router failure paths go through one helper that stays silent while
the other copy is pending or queued, or once any copy has succeeded,
including a propagated copy armed after the delivery copy confirmed.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs commit -F /tmp/ReTiCaMsgr/commit-msg.txt`

---

### Task 8: Inbound messages report how they arrived

**Files:**
- Modify: `Sources/ReTiCANode/LXMFRouter.swift` (`DeliveryMethod` :100; `messageDelivered` :179; `.received` :353-367; `.send` switch :372-396)
- Modify: `Sources/ReTiCANode/LXMFNode.swift` (:238 Delegate; :584 downloads; :645 and :687 `messageDelivered` → `messageReceived`)
- Create: `Tests/ReTiCANodeTests/LXMFArrivalMethodTests.swift`
- Modify (shape): `Tests/ReTiCANodeTests/LXMFRouterTests.swift` (:24, :42, :56, :96, :118, :261, :267), `Tests/ReTiCANodeTests/LXMFNodeInboundStampTests.swift`, `Tests/ReTiCANodeTests/LXMFNodeOpportunisticTests.swift` (:67), `Tests/ReTiCANodeTests/LXMFNodeBLETests.swift` (:134), `Tests/ReTiCANodeTests/LXMFPropagationCapstoneTests.swift` (:233), `Tests/ReTiCANodeTests/LXMFNodeSyncTests.swift` (:159), `Tests/ReTiCANodeTests/LXMFNodeDirectTests.swift` (:123)

**Interfaces:**
- Consumes: `fail(_:_:)` (Task 7).
- Produces: `LXMFRouter.DeliveryMethod.propagated`; `LXMFRouter.Action.Delegate.messageDelivered(message: LXMessage, signatureValidated: Bool, method: DeliveryMethod)`; `LXMFNode.Action.Delegate.messageReceived(message: LXMessage, signatureValidated: Bool, method: LXMFRouter.DeliveryMethod)`. `.received(method: .propagated, ...)` unpacks like `.direct`. `.send(desiredMethod: .propagated)` fails the delivery copy.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFArrivalMethodTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

private func makeMessage(to recipient: Identity = Identity()) -> LXMessage {
    LXMessage.create(source: Identity(), destinationHash: LXMessage.deliveryHash(identityHash: recipient.hash),
                     timestamp: 1700000000.5, title: Data("t".utf8), content: Data("arrived".utf8))
}

@MainActor
private func makeRouter() -> TestStore<LXMFRouter.State, LXMFRouter.Action> {
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() }
    store.exhaustivity = .off
    return store
}

@MainActor
private func makeNode(_ state: LXMFNode.State) -> TestStore<LXMFNode.State, LXMFNode.Action> {
    let store = TestStore(initialState: state) { LXMFNode() } withDependencies: {
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
        $0.uuid = .incrementing
        $0.tcpConnection = TCPConnection(open: { _, _ in AsyncStream { _ in } }, send: { _ in }, close: { })
    }
    store.exhaustivity = .off
    return store
}

@MainActor
private func expectDelivered(_ store: TestStore<LXMFRouter.State, LXMFRouter.Action>, _ msg: LXMessage,
                             via expected: LXMFRouter.DeliveryMethod) async {
    await store.receive { action in
        guard case let .delegate(.messageDelivered(m, _, method)) = action else { return false }
        return m.hash == msg.hash && method == expected
    }
}

@Test @MainActor func arrivalMethodRouterReportsOpportunistic() async {
    let msg = makeMessage()
    let store = makeRouter()
    await store.send(.received(method: .opportunistic, destinationHash: msg.destinationHash, data: msg.opportunisticPayload))
    await expectDelivered(store, msg, via: .opportunistic)
}

@Test @MainActor func arrivalMethodRouterReportsDirect() async {
    let msg = makeMessage()
    let store = makeRouter()
    await store.send(.received(method: .direct, destinationHash: Data(), data: msg.packed))
    await expectDelivered(store, msg, via: .direct)
}

/// `.propagated` carries the full packed message, like `.direct`, and is reconstructed the same way.
@Test @MainActor func arrivalMethodRouterReportsPropagated() async {
    let msg = makeMessage()
    let store = makeRouter()
    await store.send(.received(method: .propagated, destinationHash: Data(), data: msg.packed))
    await expectDelivered(store, msg, via: .propagated)
}

/// Dedup is unchanged, so the FIRST arrival's method is the one reported.
@Test @MainActor func arrivalMethodFirstArrivalWins() async {
    let msg = makeMessage()
    let store = makeRouter()
    await store.send(.received(method: .propagated, destinationHash: Data(), data: msg.packed))
    await expectDelivered(store, msg, via: .propagated)
    await store.send(.received(method: .opportunistic, destinationHash: msg.destinationHash, data: msg.opportunisticPayload))
    await store.receive(.delegate(.duplicateDropped(hash: msg.hash)))
}

@Test @MainActor func arrivalMethodNodeSurfacesTheMethod() async {
    let store = makeNode(LXMFNode.State(identity: Identity(),
                                        endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false)))
    let msg = makeMessage()
    await store.send(.router(.delegate(.messageDelivered(message: msg, signatureValidated: true, method: .propagated))))
    await store.receive(.delegate(.messageReceived(message: msg, signatureValidated: true, method: .propagated)))
}

/// Messages downloaded from a propagation node reach the router as `.propagated`, not `.direct`.
@Test @MainActor func arrivalMethodNodeFeedsDownloadedMessagesAsPropagated() async {
    let me = Identity()
    let msg = makeMessage(to: me)
    let entry = LXMFPropagation.lxmfData(destinationHash: msg.destinationHash,
                                         encryptedData: me.encrypt(Data(msg.packed.dropFirst(LXMessage.destinationLength))))
    let linkID = Data(repeating: 0xA7, count: 16)
    var state = LXMFNode.State(identity: me, endpoint: TCPEndpoint.State(host: "h", port: 4242, reconnectOnDrop: false))
    state.syncPhase[linkID] = .awaitingMessages
    let store = makeNode(state)
    await store.send(.endpoint(.delegate(.responseReceived(linkID: linkID, requestID: Data(repeating: 1, count: 16),
                                                           data: MsgPack.encode(.array([.bin(entry)]))))))
    await store.receive(.router(.received(method: .propagated, destinationHash: Data(), data: msg.packed)))
}

/// A propagated copy needs a packed propagation container and goes through `.sendViaPropagation`;
/// `.send` cannot build one, so asking it for `.propagated` fails the copy instead of silently
/// sending it some other way.
@Test @MainActor func arrivalMethodSendingWithThePropagatedMethodFailsTheCopy() async {
    let msg = makeMessage()
    let store = TestStore(initialState: LXMFRouter.State()) { LXMFRouter() } withDependencies: {
        $0.continuousClock = TestClock()
    }
    await store.send(.send(message: msg, desiredMethod: .propagated))
    await store.receive(.delegate(.deliveryFailed(messageHash: msg.hash)))
}
```

- [ ] **Step 2: Run to see them fail**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter arrivalMethod`
Expected: build FAILS — no member `propagated` in `DeliveryMethod`, extra argument `method`.

- [ ] **Step 3: Router**

Replace `    public enum DeliveryMethod: Equatable, Sendable { case opportunistic, direct }` with
```swift
    /// How an LXMF message travels. Inbound it is the arrival path reported on `messageDelivered`:
    /// a single packet (`opportunistic`), a link packet or Resource (`direct`), or a download from a
    /// propagation node (`propagated`). Outbound, `.send` accepts `opportunistic` and `direct` only;
    /// propagated sends go through `.sendViaPropagation`.
    public enum DeliveryMethod: Equatable, Sendable { case opportunistic, direct, propagated }
```
Replace `            case messageDelivered(message: LXMessage, signatureValidated: Bool)` with
```swift
            case messageDelivered(message: LXMessage, signatureValidated: Bool, method: DeliveryMethod)
```
In `.received` replace
```swift
                case .direct:
                    reconstructed = LXMessage.unpack(data)
                }
```
with
```swift
                case .direct, .propagated:
                    // Both carry the full packed message, destination hash included: a link packet or
                    // Resource for `.direct`, a decrypted propagation entry for `.propagated`.
                    reconstructed = LXMessage.unpack(data)
                }
```
and replace
```swift
                return .send(.delegate(.messageDelivered(message: message, signatureValidated: validated)))
```
with
```swift
                return .send(.delegate(.messageDelivered(message: message, signatureValidated: validated,
                                                         method: method)))
```
In `.send`, directly after the `case .direct:` branch's closing `return .none   // a link/path request is already in flight` line add:
```swift
                case .propagated:
                    // A propagated copy needs a packed propagation container, which `.send` cannot
                    // build; `.sendViaPropagation` is the entry point. Fail this copy rather than send
                    // it some other way.
                    return fail(&state, .delivery(message.hash))
```

- [ ] **Step 4: LXMFNode**

Replace `            case messageReceived(message: LXMessage, signatureValidated: Bool)` with
```swift
            /// `method` is how the message arrived: a single packet, a link, or a propagation node
            /// download. With duplicates the first arrival wins (the router's dedup is unchanged).
            case messageReceived(message: LXMessage, signatureValidated: Bool, method: LXMFRouter.DeliveryMethod)
```
Replace
```swift
                            effects.append(.send(.router(.received(method: .direct, destinationHash: Data(), data: packed))))
```
with
```swift
                            effects.append(.send(.router(.received(method: .propagated, destinationHash: Data(), data: packed))))
```
Replace `            case let .router(.delegate(.messageDelivered(message, validated))):` with `            case let .router(.delegate(.messageDelivered(message, validated, method))):` and
```swift
                return .send(.delegate(.messageReceived(message: delivered, signatureValidated: validated)))
```
with
```swift
                return .send(.delegate(.messageReceived(message: delivered, signatureValidated: validated,
                                                        method: method)))
```

- [ ] **Step 5: Update existing tests (mechanical)**

Write `/tmp/ReTiCaMsgr/t8-router.sed`:
```
s/\.messageDelivered(m, validated))/.messageDelivered(m, validated, _))/g
s/\.messageDelivered(m, _))/.messageDelivered(m, _, _))/g
s/\.messageDelivered(_, validated))/.messageDelivered(_, validated, _))/g
s/\.messageDelivered(_, v))/.messageDelivered(_, v, _))/g
```
Run: `sed -i '' -f /tmp/ReTiCaMsgr/t8-router.sed /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/LXMFRouterTests.swift`

Write `/tmp/ReTiCaMsgr/t8-node.sed`:
```
s/\.messageReceived(m, v))/.messageReceived(m, v, _))/g
s/\.messageReceived(m, _))/.messageReceived(m, _, _))/g
s/signatureValidated: false))))/signatureValidated: false, method: .opportunistic))))/g
s/signatureValidated: true))))/signatureValidated: true, method: .opportunistic))))/g
```
Run: `sed -i '' -f /tmp/ReTiCaMsgr/t8-node.sed /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/LXMFNodeInboundStampTests.swift /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/LXMFNodeOpportunisticTests.swift /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/LXMFNodeBLETests.swift /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/LXMFPropagationCapstoneTests.swift /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/LXMFNodeSyncTests.swift /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests/ReTiCANodeTests/LXMFNodeDirectTests.swift`
(The two `signatureValidated:` rules only occur in `LXMFNodeInboundStampTests.swift`, on its eleven `.router(.delegate(.messageDelivered(...)))` constructions including the two-line one at :404-405. The Task 2 endpoint-level patterns already have four slots, so these rules cannot touch them.)

Check: `grep -rn "messageDelivered(m, [a-z_]*))\|messageDelivered(_, [a-z]*))\|messageReceived(m, [a-z_]*))" /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs/Tests` — expected: no output.

- [ ] **Step 6: Run to see them pass**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter arrivalMethod`
Expected: 7 PASS.

- [ ] **Step 7: Mutation batch (apply all at once)**

1. Router `.received` emission: `method: method)))` → `method: method == .direct ? .opportunistic : .direct)))` — breaks `arrivalMethodRouterReportsOpportunistic` (gets `.direct`), `arrivalMethodRouterReportsDirect` (gets `.opportunistic`), `arrivalMethodRouterReportsPropagated` and `arrivalMethodFirstArrivalWins` (get `.direct`).
2. LXMFNode `messageDelivered` → `messageReceived`: `method: method)))` → `method: .direct)))` — breaks `arrivalMethodNodeSurfacesTheMethod`.
3. LXMFNode download: `.received(method: .propagated,` → `.received(method: .direct,` — breaks `arrivalMethodNodeFeedsDownloadedMessagesAsPropagated`.
4. Router `.send` `.propagated` case: `return fail(&state, .delivery(message.hash))` → `return .none` — breaks `arrivalMethodSendingWithThePropagatedMethodFailsTheCopy`.

Each is on a different line and only rewrites one value. Nothing traps.

Run the Step 6 command. Expected: all 7 FAIL.

- [ ] **Step 8: Revert, re-run, full suite**

Revert all four. Run the Step 6 command (7 PASS), then the full suite (all PASS).

- [ ] **Step 9: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs add Sources/ReTiCANode/LXMFRouter.swift Sources/ReTiCANode/LXMFNode.swift Tests/ReTiCANodeTests/LXMFArrivalMethodTests.swift Tests/ReTiCANodeTests/LXMFRouterTests.swift Tests/ReTiCANodeTests/LXMFNodeInboundStampTests.swift Tests/ReTiCANodeTests/LXMFNodeOpportunisticTests.swift Tests/ReTiCANodeTests/LXMFNodeBLETests.swift Tests/ReTiCANodeTests/LXMFPropagationCapstoneTests.swift Tests/ReTiCANodeTests/LXMFNodeSyncTests.swift Tests/ReTiCANodeTests/LXMFNodeDirectTests.swift`

Message:
```
feat: inbound LXMF messages report how they arrived

DeliveryMethod gains propagated. messageDelivered and messageReceived
carry the method, and propagation-node downloads are fed to the router
as propagated instead of direct.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs commit -F /tmp/ReTiCaMsgr/commit-msg.txt`

---

### Task 9: End-to-end over two nodes, and docs

**Files:**
- Create: `Tests/ReTiCANodeTests/LXMFNodeSinglePacketProofEndToEndTests.swift`
- Modify: `docs/reference-gap-analysis-2026-08-10.md` (:12, §1.6 at :193), `docs/reference-parity-checklist.md` (:604-606), `docs/superpowers/specs/2026-07-28-lxmf-opportunistic-path-request-design.md` (:100)

**Interfaces:**
- Consumes: everything from Tasks 1-8. No new production API.

- [ ] **Step 1: Write the end-to-end tests**

Create `Tests/ReTiCANodeTests/LXMFNodeSinglePacketProofEndToEndTests.swift`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA
@testable import ReTiCAInterfaces
@testable import ReTiCATransport

// Two LXMFNodes over mocked TCP — the harness of LXMFNodeOpportunisticTests. A frame one node
// "sends" reaches the other only when the test yields it into that node's TCP event stream, so a
// test can deliver, drop, or reorder proofs.
//
// Depth order on the receiving node B (breadth-first `.send` processing): for an inbound DATA packet,
// `.endpoint(.proveSinglePacket)` and `.router(.received)` share a depth; the router's
// `.router(.delegate(...))` comes next, then `.delegate(.messageReceived)`, and the proof's
// `.endpoint(.tcpClient(.interface(.send)))` comes LAST. The receives below follow that order.

/// Nonisolated on purpose: it is passed as `receive`'s matcher.
private func isTCPSend(_ action: LXMFNode.Action) -> Bool {
    if case .endpoint(.tcpClient(.interface(.send))) = action { return true }
    return false
}

/// The TCP driver writes each frame from a `.run` effect, so a frame can land a moment after its
/// `.interface(.send)` action is received. Wait for exactly one new frame and return it.
@MainActor
private func nextFrame(_ sent: LockIsolated<[Data]>, after count: Int) async -> Data {
    for _ in 0..<1_000 where sent.value.count <= count { await Task.yield() }
    #expect(sent.value.count == count + 1, "expected exactly one new frame")
    return sent.value.last ?? Data()
}

@MainActor
private final class Pair {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    let sentA = LockIsolated<[Data]>([])
    let sentB = LockIsolated<[Data]>([])
    var a: TestStore<LXMFNode.State, LXMFNode.Action>!
    var b: TestStore<LXMFNode.State, LXMFNode.Action>!
    var eventsA: AsyncStream<TCPEvent>.Continuation!
    var eventsB: AsyncStream<TCPEvent>.Continuation!

    var bDeliveryHash: Data { LXMessage.deliveryHash(identityHash: bIdentity.hash) }

    init(configureA: (inout LXMFNode.State) -> Void = { _ in }) {
        let nodeA = Pair.makeNode("a", aIdentity, sentA, clock, configureA)
        a = nodeA.0
        eventsA = nodeA.1
        let nodeB = Pair.makeNode("b", bIdentity, sentB, clock, { _ in })
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
            $0.date = .constant(Date(timeIntervalSince1970: 1700000000.5))
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
    }

    func message(_ content: String) -> LXMessage {
        LXMessage.create(source: aIdentity, destinationHash: bDeliveryHash, timestamp: 1700000000.5,
                         title: Data("t".utf8), content: Data(content.utf8))
    }

    /// Nothing more may happen on A for the whole retry saga: no resend, no deliveryFailed. The
    /// advance stays under the 60 s maintenance tick, so any action here is a leftover retry.
    func expectANeverRetriesAgain() async {
        await a.skipReceivedActions(strict: false)
        a.exhaustivity = .on
        await clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds * LXMFDelivery.maxAttempts))
        await a.send(.cancelPropagationStamps)   // an exhaustive send fails if the advance produced ANY action
        a.exhaustivity = .off
    }

    func stop() async {
        await a.send(.endpoint(.stop))
        await b.send(.endpoint(.stop))
    }
}

@Test @MainActor func proofEndToEndOpportunisticSendIsConfirmedAndNeverFails() async {
    let p = Pair()
    await p.connectAndIntroduce()
    let msg = p.message("prove me")

    let aFrames = p.sentA.value.count
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))
    await p.a.receive(isTCPSend)
    let data = await nextFrame(p.sentA, after: aFrames)
    #expect(p.a.state.endpoint.transport.pendingReceipts.count == 1)

    // B proves the packet on its arrival interface and delivers the message.
    let bFrames = p.sentB.value.count
    p.eventsB.yield(.data(data))
    await p.b.receive { if case .endpoint(.proveSinglePacket) = $0 { return true }; return false }
    await p.b.receive { action in
        guard case let .delegate(.messageReceived(m, _, method)) = action else { return false }
        return m.hash == msg.hash && method == .opportunistic
    }
    await p.b.receive(isTCPSend)
    let proof = await nextFrame(p.sentB, after: bFrames)

    // The proof confirms the message on A and retires every retry.
    p.eventsA.yield(.data(proof))
    await p.a.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(p.a.state.router.pendingDeliveries.isEmpty)
    #expect(p.a.state.endpoint.transport.pendingReceipts.isEmpty)
    await p.expectANeverRetriesAgain()
    await p.stop()
}

@Test @MainActor func proofEndToEndALostProofIsRecoveredByTheResend() async {
    let p = Pair()
    await p.connectAndIntroduce()
    let msg = p.message("resend me")

    var aFrames = p.sentA.value.count
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))
    await p.a.receive(isTCPSend)
    let first = await nextFrame(p.sentA, after: aFrames)

    // B proves the first copy, but that proof is lost on the way back.
    var bFrames = p.sentB.value.count
    p.eventsB.yield(.data(first))
    let firstProved = LockIsolated<Data?>(nil)
    await p.b.receive { action in
        guard case let .endpoint(.proveSinglePacket(hash, _, _)) = action else { return false }
        firstProved.setValue(hash)
        return true
    }
    await p.b.receive(isTCPSend)
    _ = await nextFrame(p.sentB, after: bFrames)   // dropped: never handed to A

    // A's retry sends a NEW packet with a new receipt under the same token.
    aFrames = p.sentA.value.count
    await p.clock.advance(by: .seconds(LXMFDelivery.retryWaitSeconds))
    await p.a.receive(isTCPSend)
    let resend = await nextFrame(p.sentA, after: aFrames)
    #expect(p.a.state.endpoint.transport.pendingReceipts.count == 2)

    // B's router has already seen this message and drops it — but B proves the resend anyway.
    bFrames = p.sentB.value.count
    p.eventsB.yield(.data(resend))
    let secondProved = LockIsolated<Data?>(nil)
    await p.b.receive { action in
        guard case let .endpoint(.proveSinglePacket(hash, _, _)) = action else { return false }
        secondProved.setValue(hash)
        return true
    }
    await p.b.receive(.router(.delegate(.duplicateDropped(hash: msg.hash))))
    await p.b.receive(isTCPSend)
    let proof = await nextFrame(p.sentB, after: bFrames)
    #expect(firstProved.value != nil)
    #expect(secondProved.value != nil)
    #expect(firstProved.value != secondProved.value)

    p.eventsA.yield(.data(proof))
    await p.a.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(p.a.state.router.pendingDeliveries.isEmpty)
    await p.stop()
}

/// With a propagation node, both copies report their own outcome and there is no false failure.
/// The propagated copy is handed to the router directly, exactly as `sendMessage(alsoViaPropagation:)`
/// does once its stamp search finishes; the PN's link receipt is injected as `packetDelivered`.
@Test @MainActor func proofEndToEndBothCopiesReportTheirOwnOutcomeWithNoFalseFailure() async {
    let pn = Data(repeating: 0xBB, count: 16)
    let pnLink = Data(repeating: 0xC0, count: 16)
    let p = Pair(configureA: { state in
        state.router.outboundPropagationNode = pn
        state.router.directLinks[pn] = .active(linkID: pnLink)
    })
    await p.connectAndIntroduce()
    let msg = p.message("both ways")

    let aFrames = p.sentA.value.count
    await p.a.send(.sendMessage(message: msg, alsoViaPropagation: false))     // the delivery copy
    await p.a.receive(isTCPSend)
    let data = await nextFrame(p.sentA, after: aFrames)
    await p.a.send(.router(.sendViaPropagation(message: msg, propagationPacked: Data("small-container".utf8))))
    #expect(p.a.state.router.pendingDeliveries.count == 2)

    // The PN accepts first.
    await p.a.send(.endpoint(.delegate(.packetDelivered(token: msg.hash))))
    await p.a.receive(.delegate(.propagationAccepted(messageHash: msg.hash)))

    // Then the recipient's proof arrives: still reported as deliveryConfirmed.
    let bFrames = p.sentB.value.count
    p.eventsB.yield(.data(data))
    await p.b.receive { if case .endpoint(.proveSinglePacket) = $0 { return true }; return false }
    await p.b.receive(isTCPSend)
    let proof = await nextFrame(p.sentB, after: bFrames)
    p.eventsA.yield(.data(proof))
    await p.a.receive(.delegate(.deliveryConfirmed(messageHash: msg.hash)))
    #expect(p.a.state.router.pendingDeliveries.isEmpty)
    await p.expectANeverRetriesAgain()
    await p.stop()
}
```

- [ ] **Step 2: Run them**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs --filter proofEndToEnd`
Expected: 3 PASS. (All production code exists; these pin the composition. If one fails, debug the production code — do not loosen the test.)

- [ ] **Step 3: Mutation batch (apply all at once)**

1. LXMFNode inbound proving: replace `return .merge(.send(.endpoint(.proveSinglePacket(...))), deliver)` with `return deliver` — breaks all three (B never proves: the `proveSinglePacket` receive times out).
2. LXMFNode `sendOpportunistic`: `receiptToken: messageHash` → `receiptToken: nil` — breaks all three (no receipt: the `pendingReceipts` expectation fails, and no proof can confirm).

Both remove behaviour on the same success path, so neither can make a test pass. Nothing traps.

Run the Step 2 command. Expected: all 3 FAIL.

- [ ] **Step 4: Revert and re-run**

Revert both. Run the Step 2 command: 3 PASS.

- [ ] **Step 5: Docs**

5a. `docs/reference-gap-analysis-2026-08-10.md`: replace
```
> and §2.6 are all closed. **Still live:** §1.6 (deferred by decision), §1.7, §1.8, §2.3 (narrowed,
```
with
```
> and §2.6 are all closed. **Still live:** §1.6 (relay half only, see there), §1.7, §1.8, §2.3 (narrowed,
```
and replace
```
### 1.6 No PROOF handling for non-link packets **[verified]**
```
with
```
### 1.6 No PROOF handling for non-link packets **[verified]**

> **Endpoint half RESOLVED (2026-09-26)** by `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md`.
> ReTiCA now proves inbound opportunistic LXMF packets (`Transport.Action.proveSingle`, driven by
> `LXMFNode`), and validates implicit and explicit proofs for its own opportunistic sends against a
> receipt table (`Transport.State.pendingReceipts`), so break (a) below is closed and `LXMFRouter`
> reports `deliveryConfirmed` for opportunistic messages. **Still open:** break (b) — ReTiCA has no
> reverse table, so a ReTiCA relay does not route proofs for third parties (Transport.py:1690,
> 2340-2348).
```

5b. `docs/reference-parity-checklist.md`: replace
```
- [ ] **Non-link proofs / `PacketReceipt` / reverse table** (§1.6, deferred by decision) — a
      reference peer proving a plain DATA packet to a ReTiCA destination **always times out**, on a
      message we received fine. Also breaks proof relay *through* a ReTiCA node.
```
with
```
- [~] **Non-link proofs / `PacketReceipt` / reverse table** (§1.6) — **endpoint DONE**
      (`docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md`): ReTiCA proves inbound
      opportunistic LXMF packets, so a reference sender no longer times out on messages we
      received, and validates implicit and explicit proofs for its own opportunistic sends.
      **Still open:** the reverse table — a ReTiCA relay does not route proofs for third parties.
```

5c. `docs/superpowers/specs/2026-07-28-lxmf-opportunistic-path-request-design.md` :100 — replace
```
Revisit if/when opportunistic delivery gains a receipt.
```
with
```
Revisit if/when opportunistic delivery gains a receipt. (It now has one — see `docs/superpowers/specs/2026-09-26-single-packet-proofs-design.md`. Rediscovery itself is still not implemented.)
```

- [ ] **Step 6: Full suite**

Run: `swift test --package-path /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs`
Expected: all PASS.

- [ ] **Step 7: Commit**

Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs add Tests/ReTiCANodeTests/LXMFNodeSinglePacketProofEndToEndTests.swift docs/reference-gap-analysis-2026-08-10.md docs/reference-parity-checklist.md docs/superpowers/specs/2026-07-28-lxmf-opportunistic-path-request-design.md`

Message:
```
test: single-packet proofs end to end over two LXMF nodes

Covers confirmation with no later failure, a lost proof recovered by
the resend, and both copies reporting their own outcome. Docs mark the
endpoint half of gap 1.6 resolved and keep the relay half open.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
Run: `git -C /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs commit -F /tmp/ReTiCaMsgr/commit-msg.txt`

---

### Task 10: ReTiCaMsgr compile fix (app repo)

**Why verification needs an override:** `ReTiCaMsgrCore/Package.swift` depends on `.package(path: "../../../pods/ReTiCA")`, the MAIN checkout's working tree, which does not contain this branch until the controller merges it to ReTiCA `main`. So: point the core package at this worktree TEMPORARILY (via a symlink named `ReTiCA`, so SwiftPM's package identity stays `retica` and `.product(..., package: "ReTiCA")` still resolves), verify, then restore `Package.swift` and `Package.resolved` byte-for-byte. The override is never committed. **Consequence the controller must handle:** once this commit is on the app's `main`, the app only builds against a ReTiCA checkout that has `feat/single-packet-proofs` merged — land the ReTiCA merge first, or together.

**Files:**
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift` (:605)
- Modify: `ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/DiagnosticsSnapshot.swift` (:539-546)
- Modify: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift` (12 `messageReceived` constructions, :1233)
- Modify: `ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/DiagnosticsSnapshotTests.swift` (:277, :291, :306, :317, :330, :332, :343, :355, :409)
- Temporarily modified, then restored: `ReTiCaMsgrCore/Package.swift`, `ReTiCaMsgrCore/Package.resolved`

**Interfaces:**
- Consumes: `LXMFNode.Action.Delegate.messageReceived(message:signatureValidated:method:)`, `LXMFRouter.Action.Delegate.sendOpportunistic(destinationHash:payload:messageHash:)`, `LXMFRouter.State.pendingDeliveries: [LXMFRouter.DeliveryKey: PendingDelivery]`, `DeliveryKey.delivery(_:)`/`.propagated(_:)`.
- No behaviour change: the app ignores `method` and keeps ignoring `deliveryConfirmed` until the follow-up Info project. The F5.5 guard in `AppFeature.swift:688-692` stays (now unreachable).

- [ ] **Step 0: Create the app worktree**

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr worktree add /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat -b feat/retica-proofs-compat main`
Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat/ReTiCaMsgrCore`
Expected: the baseline is green against the unmodified main ReTiCA checkout. If it isn't, stop and report.

- [ ] **Step 1: Temporary override**

Run: `ln -sfn /Users/ell/development/ios/pods/ReTiCA-worktrees/single-packet-proofs /tmp/ReTiCaMsgr/ReTiCA`
Run: `ln -sfn /Users/ell/development/ios/pods/FCB /tmp/ReTiCaMsgr/FCB`
(The second covers the worktree's own `.package(path: "../FCB")` if SwiftPM resolves it relative to the symlink.)

In `/Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat/ReTiCaMsgrCore/Package.swift` replace `        .package(path: "../../../pods/ReTiCA"),` with `        .package(path: "/tmp/ReTiCaMsgr/ReTiCA"),`.

- [ ] **Step 2: See the breakage**

Run: `swift build --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat/ReTiCaMsgrCore --build-tests`
Expected: FAILS, with errors only at `AppFeature.swift:605` (tuple pattern arity), `DiagnosticsSnapshot.swift` (`hexString` on `DeliveryKey`), `AppFeatureTests.swift` (missing `method:`, `sendOpportunistic` arity) and `DiagnosticsSnapshotTests.swift` (subscript key type). Any error elsewhere means this plan missed a site: stop and report it.

- [ ] **Step 3: Source fixes**

`AppFeature.swift`: replace `            case let .node(.client(.delegate(.messageReceived(m, validated)))):` with
```swift
            case let .node(.client(.delegate(.messageReceived(m, validated, _)))):   // arrival method unused for now
```

`DiagnosticsSnapshot.swift`: replace
```swift
        let pendingRows = router.pendingDeliveries
            .map { hash, pending -> (String, Row) in
                let (method, dest) = describe(pending.resend)
                return (hash.hexString, Row(hash.hexString,
                                            "method=\(method) dest=\(dest.hexString) "
                                            + "attempts=\(pending.attempts)"))
            }
```
with
```swift
        let pendingRows = router.pendingDeliveries
            .map { key, pending -> (String, Row) in
                let (method, dest) = describe(pending.resend)
                let hash = key.messageHash.hexString
                // One message can now have two pending copies (delivery + propagated); sorting by
                // hash then method keeps the row order deterministic.
                return (hash + " " + method, Row(hash,
                                                 "method=\(method) dest=\(dest.hexString) "
                                                 + "attempts=\(pending.attempts)"))
            }
```

- [ ] **Step 4: Test fixes (mechanical)**

Write `/tmp/ReTiCaMsgr/t10-appfeature.sed`:
```
s/signatureValidated: true)))))/signatureValidated: true, method: .opportunistic)))))/g
s/signatureValidated: false)))))/signatureValidated: false, method: .opportunistic)))))/g
s/\.sendOpportunistic(dest, payload)))))/.sendOpportunistic(dest, payload, _)))))/g
```
Run: `sed -i '' -f /tmp/ReTiCaMsgr/t10-appfeature.sed /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat/ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift`
(All 12 `signatureValidated:` occurrences in that file are `.node(.client(.delegate(.messageReceived(...)))))` constructions.)

Confirm the diagnostics lines: `grep -n "pendingDeliveries\[" /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat/ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/DiagnosticsSnapshotTests.swift` — expected 277, 291, 306, 317, 330, 332, 343, 355, 409; only :317 (in `deliveryWarnsWhenAPropagatedSendIsPendingWithNoLinkToThePropagationNode`) is a propagated copy. Adjust the address below if it moved.

Write `/tmp/ReTiCaMsgr/t10-diagnostics.sed`:
```
317s/pendingDeliveries\[messageHash\]/pendingDeliveries[.propagated(messageHash)]/
s/pendingDeliveries\[\(messageHash2*\)\]/pendingDeliveries[.delivery(\1)]/g
```
Run: `sed -i '' -f /tmp/ReTiCaMsgr/t10-diagnostics.sed /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat/ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/DiagnosticsSnapshotTests.swift`

- [ ] **Step 5: Full core suite**

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat/ReTiCaMsgrCore`
Expected: all PASS.

- [ ] **Step 6: Mutation batch for the edited tests (apply all at once)**

No test is new; the edits are argument-only. Still, confirm the edited tests exercise the code they sit on:
1. `AppFeature.swift` messageReceived handler: insert `return .none` as its first statement — breaks the edited tests that expect an inbound message to be stored or shown: `receivedFromOpenPeerReloadsThread`, `deliveredMessageIsNotReDeliveredAfterRestart`, `incomingTextMessageStoresItsHash`, `incomingReactionIsStoredAndNotABubble`, `peerReactionOnMyOutgoingMessageShows`, `reactionBeforeTargetShowsOnceTargetArrives`.
2. `DiagnosticsSnapshot.swift`: make `stranded` and `opportunisticPending` both `0` (append `* 0` to each `.count`) — breaks the edited `deliveryWarnsWhenADirectSendIsPendingWithNoLinkAtAll`, `deliveryWarnsWhenAPropagatedSendIsPendingWithNoLinkToThePropagationNode`, `deliveryWarnsWithPluralGrammarWhenMultipleDirectSendsAreStranded`, `deliveryWarnsWhenTheActiveLinkIsToADifferentDestinationThanThePendingSend`, `deliveryStatesBothClausesWhenAStrandedMessageAndAParkedDestinationCoexist`, `deliveryAddsAnInformationalNoteWhenOpportunisticSendsArePendingAndHealthStaysOk`.

Edited tests that assert only an ABSENCE (`receivedFromOtherPeerDoesNotReloadThread`, `reactionWithFallbackContentIsNotABubble`, `unvalidatedReactionIsDropped`, `malformedReactionIsDroppedNotABubble`, `deliveryIsOk...` cases, `seenHashRowsArePrunedToRingCapacity` if it stays green) and `peerStampCostSurvivesRestartAndIsSpent` (its `sendOpportunistic` edit is a wildcard over library behaviour already covered in ReTiCA) are exempt: their assertions are unchanged from `main`.

Run: `swift test --package-path /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat/ReTiCaMsgrCore --filter receivedFromOpenPeerReloadsThread --filter deliveredMessageIsNotReDeliveredAfterRestart --filter incomingTextMessageStoresItsHash --filter incomingReactionIsStoredAndNotABubble --filter peerReactionOnMyOutgoingMessageShows --filter reactionBeforeTargetShowsOnceTargetArrives --filter deliveryWarns --filter deliveryStatesBothClauses --filter deliveryAddsAnInformationalNote`
Expected: every listed test FAILS. If one passes, it does not exercise what it claims — report it rather than editing app behaviour.

- [ ] **Step 7: Revert the mutations and re-run**

Revert both. Run the Step 6 command: all PASS.

- [ ] **Step 8: Restore the dependency path**

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat checkout -- ReTiCaMsgrCore/Package.swift ReTiCaMsgrCore/Package.resolved`
Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat status --short`
Expected: exactly the four intended files modified and nothing else. `Package.swift` and `Package.resolved` must NOT appear.

- [ ] **Step 9: Commit (app worktree, branch `feat/retica-proofs-compat`)**

Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat add ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/DiagnosticsSnapshot.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/AppFeatureTests.swift ReTiCaMsgrCore/Tests/ReTiCaMsgrCoreTests/DiagnosticsSnapshotTests.swift`

Message:
```
fix: compile against ReTiCA single-packet proofs

messageReceived gains an arrival method (ignored for now),
sendOpportunistic gains the message hash, and pendingDeliveries is
keyed per copy. No behaviour change. Needs ReTiCA with
feat/single-packet-proofs merged.

Co-Authored-By: Claude Opus 5.5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_016gVnRKKggZdh6nzoKCGxb1
```
Run: `git -C /Users/ell/development/ios/apps/ReTiCaMsgr-proofs-compat commit -F /tmp/ReTiCaMsgr/commit-msg.txt`

---

## Self-review notes (for the reviewer)

- **Spec coverage:** §1 → Tasks 1-2; §2 → Tasks 3-4; §3 → Tasks 5 (keys, `.delivered` by path, `.resourceDeliveredOnLink` owner, per-copy retry), 6 (`sendOpportunistic` hash, `.opportunisticDelivered`, resend proof), 7 (failure only when all copies failed, never after success); §4 → Task 8; Testing (vectors, Transport, router, end-to-end, arrival, app suite) → Tasks 1-10; Docs → Task 9; Compatibility (app fix) → Task 10.
- **Deliberate divergences from the spec's wording**, each explained where it lands: proof signatures are not byte-compared with reference (CryptoKit is hedged — Task 1); `.delivered` carries an explicit `leg:` because the only receipted link send is the propagated one (Task 5); `linkResourceInFlight` stores the owning `DeliveryKey` (Task 5); "armed" includes queued copies and a success is remembered past its pending entry (Task 7); `.send(desiredMethod: .propagated)` fails the delivery copy (Task 8); the app fix also covers `DiagnosticsSnapshot` and one `sendOpportunistic` test match (Task 10).
