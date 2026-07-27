# LXMF-3: Direct Delivery Over a Link — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Deliver an LXMF message over an established Link — the whole `packed` as a link packet if it fits `Link.mdu`, else as a Resource — so messages larger than one opportunistic packet arrive.

**Architecture:** One core constant (`Link.mdu = 431`, RNS `Link.MDU`) and one pure helper (`LXMessage.directRepresentation`, `.packet` vs `.resource` by `packed.count <= Link.mdu`), plus two end-to-end integration tests over the existing two-Endpoint link harness. Everything else (link establish, `sendOverLink`/`sendResourceOverLink`, `unpack`, Resource transfer) is existing machinery.

**Tech Stack:** Swift, Swift Testing, TCA (integration), genuine `rns 1.4.2` / `lxmf 1.1.0` for cross-val.

## Global Constraints

- Commit directly to `main`; no feature branch.
- No compound shell commands (no `&&`, `||`, `;`, `xargs`, inline interpreter scripts). One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to write files — use editor tools.
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Signatures + resource/link payloads are validated, never byte-compared (`ed25519-hedged-nondeterministic`).
- Cross-val fixtures MUST derive from genuine RNS (`cross-validation-drive-real-rns`); the generator runs via `/Users/ell/opt/anaconda3/envs/rns/bin/python` (rns 1.4.2 / lxmf 1.1.0).
- Wire pin (proven algebra): RNS DIRECT packet-vs-resource `content_size <= LINK_PACKET_MAX_CONTENT` ⟺ `packed.count <= RNS.Link.MDU`; `RNS.Link.MDU = 431`. DIRECT sends the WHOLE `packed` (not stripped); the receiver takes `lxmf_data = data` whole (LXMRouter.py:1936-1937).
- Build gotcha: signal-11/10/SIGILL → `swift package clean` then retry.
- Commit trailers, exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

**Spec:** `docs/superpowers/specs/2026-07-27-lxmf-direct-delivery-design.md`
**Base:** this plan's own commit (verify with `git log --oneline <planCommit>..HEAD`, never `HEAD~1`).

---

## File Structure

- **Modify** `Sources/ReTiCA/Link/Link.swift` — add `public static let mdu = 431`.
- **Create** `Sources/ReTiCA/LXMF/LXMessage+Direct.swift` — `DirectRepresentation` + `directRepresentation`.
- **Modify** `Tests/ReTiCATests/LXMessageTests.swift` — `directRepresentation` unit tests.
- **Modify** `Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py` — emit `link_mdu`.
- **Regenerate** `Tests/ReTiCATests/Vectors/lxmf_fixtures.json`.
- **Modify** `Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift` — add `linkMdu`.
- **Modify** `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift` — `Link.mdu == RNS.Link.MDU` cross-val.
- **Create** `Tests/ReTiCANodeTests/LXMFDirectDeliveryTests.swift` — packet + resource integration tests.

---

## Task 1: `Link.mdu` + `directRepresentation` + unit/cross-val

**Files:**
- Modify: `Sources/ReTiCA/Link/Link.swift`
- Create: `Sources/ReTiCA/LXMF/LXMessage+Direct.swift`
- Test: `Tests/ReTiCATests/LXMessageTests.swift`, `Tests/ReTiCATests/Vectors/{generate_lxmf_fixtures.py, LXMFVectorFixtures.swift, LXMessageCrossValidationTests.swift}` (+ regenerate `lxmf_fixtures.json`)

**Interfaces:**
- Produces: `Link.mdu: Int`, `LXMessage.DirectRepresentation` (`.packet`/`.resource`), `LXMessage.directRepresentation`. Task 2 uses `directRepresentation`.

- [ ] **Step 1: Write the failing unit tests**

Add to `Tests/ReTiCATests/LXMessageTests.swift`:

```swift
@Test func directRepresentationIsPacketForSmallAndResourceForLarge() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    let small = LXMessage.create(source: source, destinationHash: destHash,
                                 timestamp: 1700000000.5, title: Data(), content: Data("hi".utf8))
    #expect(small.packed.count <= Link.mdu)
    #expect(small.directRepresentation == .packet)
    let large = LXMessage.create(source: source, destinationHash: destHash,
                                 timestamp: 1700000000.5, title: Data(), content: Data(repeating: 0x41, count: 1000))
    #expect(large.packed.count > Link.mdu)
    #expect(large.directRepresentation == .resource)
}

/// The boundary is exactly Link.mdu (packed.count == mdu → packet; +1 → resource), so the `<=` and
/// the threshold value are load-bearing. Content length is tuned so `packed.count == Link.mdu`.
@Test func directRepresentationBoundaryIsLinkMdu() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    func msg(_ contentLen: Int) -> LXMessage {
        LXMessage.create(source: source, destinationHash: destHash, timestamp: 1700000000.5,
                         title: Data(), content: Data(repeating: 0x41, count: contentLen))
    }
    // Probe in the bin16 range (>=256) so +1 content byte == +1 packed byte (stable 3-byte bin header).
    let probeLen = 300
    let atMduLen = probeLen + (Link.mdu - msg(probeLen).packed.count)   // → packed.count == Link.mdu
    let atMdu = msg(atMduLen)
    #expect(atMdu.packed.count == Link.mdu)
    #expect(atMdu.directRepresentation == .packet)
    let overMdu = msg(atMduLen + 1)
    #expect(overMdu.packed.count == Link.mdu + 1)
    #expect(overMdu.directRepresentation == .resource)
}
```

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --filter "directRepresentation" 2>&1 | tail -20`
Expected: compile failure — `Link.mdu` / `directRepresentation` don't exist.

- [ ] **Step 3: Add `Link.mdu`**

In `Sources/ReTiCA/Link/Link.swift`, in the `Link` enum's constants:

```swift
    /// Maximum single-packet data unit over a link (RNS `Link.MDU`, = 431). An LXMF DIRECT message
    /// whose `packed` fits this is sent as one link packet, else as a Resource.
    public static let mdu = 431
```

- [ ] **Step 4: Implement `directRepresentation`**

Create `Sources/ReTiCA/LXMF/LXMessage+Direct.swift`:

```swift
import Foundation

extension LXMessage {
    public enum DirectRepresentation: Equatable { case packet, resource }

    /// How this message is delivered over a Link (LXMF DIRECT method): the whole `packed` as a single
    /// link packet if it fits the link MDU, else as a Resource. Reference LXMF compares `content_size`
    /// to `LINK_PACKET_MAX_CONTENT = Link.MDU − LXMF_OVERHEAD`, which reduces exactly to
    /// `packed.count <= Link.mdu` (LXMessage.py:417-424). DIRECT sends the WHOLE `packed` (unlike
    /// opportunistic's `opportunisticPayload`), since a link is addressed by its link id.
    public var directRepresentation: DirectRepresentation {
        packed.count <= Link.mdu ? .packet : .resource
    }
}
```

- [ ] **Step 5: Run the unit tests to verify they pass**

Run: `swift test --filter "directRepresentation" 2>&1 | tail -20`
Expected: both unit tests PASS.

- [ ] **Step 6: Add the cross-val**

In `Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py`, add `RNS.Link.MDU` to the emitted dict (after `packed`):

```python
    "link_mdu": RNS.Link.MDU,
```

Regenerate: `/Users/ell/opt/anaconda3/envs/rns/bin/python Tests/ReTiCATests/Vectors/generate_lxmf_fixtures.py > Tests/ReTiCATests/Vectors/lxmf_fixtures.json`
(Expected: exit 0; `link_mdu` present with value 431. NOTE: regeneration replaces the whole fixture with fresh random identities — the LXMF-1/LXMF-2 cross-val tests re-derive and still pass; confirm in Step 7.)

Add to `Tests/ReTiCATests/Vectors/LXMFVectorFixtures.swift`: property `let linkMdu: Int` and CodingKey `case linkMdu = "link_mdu"`.

Add to `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift`:

```swift
/// Our Link.mdu equals genuine RNS Link.MDU — the threshold LXMF uses to choose a link packet vs a
/// Resource for DIRECT delivery.
@Test func linkMduMatchesRns() throws {
    let f = try LXMFVectorFixtures.load()
    #expect(Link.mdu == f.linkMdu)
}
```

- [ ] **Step 7: Run to verify pass (incl. siblings)**

Run: `swift test --filter "linkMdu\|directRepresentation\|lxMessage\|fromOpportunistic" 2>&1 | tail -30` (or run each filter separately if the regex is fiddly).
Expected: `linkMduMatchesRns` PASSES; all LXMF-1/LXMF-2 cross-val + unit tests still PASS after the fixture regeneration.

- [ ] **Step 8: Mutation-verify (three-step)**

Batch-mutate: (1) change `packed.count <= Link.mdu` to `packed.count < Link.mdu` — `directRepresentationBoundaryIsLinkMdu` fails (the exact-mdu message becomes `.resource`). (2) change `Link.mdu = 431` to `430` — `linkMduMatchesRns` fails (≠ RNS) AND `directRepresentationBoundaryIsLinkMdu` fails (boundary shifts). Run the filters; confirm each named test fails. Revert both; run again; all PASS. (Run one at a time if batching masks either.)

- [ ] **Step 9: Commit**

```bash
git add Sources/ReTiCA/Link/Link.swift Sources/ReTiCA/LXMF/LXMessage+Direct.swift Tests/ReTiCATests/
git commit -F /tmp/ReTiCA/commit-lxmf3-t1.txt
```

(Message e.g. `feat: LXMF-3 task 1 — Link.mdu + directRepresentation + cross-val` plus trailers.)

---

## Task 2: End-to-end direct delivery integration tests (packet + resource)

**Files:**
- Create: `Tests/ReTiCANodeTests/LXMFDirectDeliveryTests.swift`

**Interfaces:**
- Consumes: `LXMessage.create/packed/directRepresentation/unpack/validateSignature/deliveryHash`; `Endpoint` actions `.connect/.registerLocalDestination/.announce/.openLink/.sendOverLink/.sendResourceOverLink`; delegates `.linkEstablished/.linkDataReceived/.resourceReceived/.pathLearned`.

**Context:** Mirror `Tests/ReTiCANodeTests/EndpointTests.swift`:
- **Link establishment** — copy the exact setup + drain from `twoEndpointsEstablishLinkExchangeDataAndClose` (lines ~252-310) / `twoEndpointsTransferAResourceOverALink` (lines ~393-438). The recipient's destination is its **`lxmf.delivery`** destination: `Destination(kind: .single, direction: .in, appName: "lxmf", aspects: ["delivery"], identity: bIdentity)`.
- **Link packet exchange** — copy the send-data-over-link drain (establish test, lines ~312-322): `sendOverLink` → `\.interface.send` → bridge → `\.transport.received` → `.linkDataReceived`.
- **Resource transfer** — copy the full resource drain from `twoEndpointsTransferAResourceOverALink` (lines ~440-469): `sendResourceOverLink` → ADV → REQ → parts loop → `.resourceReceived`.
The `.off` store tolerates unlisted actions; only the awaited ones must occur in order. The drain sequence may need alignment with observed behavior — adapt from those neighboring tests. Do NOT weaken the final assertions (unpack != nil, content/title equal, validateSignature true, hash equal).

Both tests validate the recovered message against `aIdentity` directly (the sender identity is in test scope); source-identity resolution via announce is already proven by LXMF-2, so these tests focus on link delivery integrity.

- [ ] **Step 1: Write the failing tests**

Create `Tests/ReTiCANodeTests/LXMFDirectDeliveryTests.swift`. Two tests sharing the link-establishment pattern (duplicate the setup in each, as the existing tests do):

**Test A — small message as a link packet:**
```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA

@Test @MainActor func directLXMFSmallMessageDeliversAsLinkPacket() async {
    // ... establish a link A→B to B's lxmf.delivery destination (copy twoEndpointsEstablishLink steps 1–4,
    //     with dest = Destination(.single, .in, "lxmf", ["delivery"], bIdentity)) ...
    let msg = LXMessage.create(source: aIdentity, destinationHash: bDelivery.hash,
                               timestamp: 1700000000.5, title: Data("hi".utf8), content: Data("small direct".utf8))
    #expect(msg.directRepresentation == .packet)
    await a.send(.sendOverLink(linkID: linkID, data: msg.packed))
    await a.receive { if case .interface(.send) = $0 { return true }; return false }
    let got = LockIsolated<Data?>(nil)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive { action in
        if case let .delegate(.linkDataReceived(lid, d)) = action, lid == linkID { got.setValue(d); return true }
        return false
    }
    let recovered = LXMessage.unpack(got.value!)
    #expect(recovered?.content == Data("small direct".utf8))
    #expect(recovered?.hash == msg.hash)
    #expect(recovered?.validateSignature(source: aIdentity) == true)
}
```

**Test B — large message as a Resource (headline):**
```swift
@Test @MainActor func directLXMFLargeMessageDeliversAsResource() async {
    // ... same link establishment to B's lxmf.delivery destination ...
    let bigContent = Data((0..<800).map { UInt8($0 & 0xff) })
    let msg = LXMessage.create(source: aIdentity, destinationHash: bDelivery.hash,
                               timestamp: 1700000000.5, title: Data("big".utf8), content: bigContent)
    #expect(msg.directRepresentation == .resource)     // packed > Link.mdu
    await a.send(.sendResourceOverLink(linkID: linkID, data: msg.packed))
    // ... copy the resource drain from twoEndpointsTransferAResourceOverALink (ADV → REQ → parts → PRF),
    //     capturing B's .resourceReceived(linkID, data) into `got` ...
    let recovered = LXMessage.unpack(got.value!)
    #expect(recovered != nil)
    #expect(recovered?.content == bigContent)
    #expect(recovered?.title == Data("big".utf8))
    #expect(recovered?.hash == msg.hash)
    #expect(recovered?.validateSignature(source: aIdentity) == true)
}
```

(Fill in the link-establishment and resource-drain bodies by copying the exact drain steps from the two named `EndpointTests` functions. The `make(host:sent:)` harness helper is defined inside each existing test — replicate it.)

- [ ] **Step 2: Run — adjust the drain sequence if needed**

Run: `swift test --filter "directLXMF" 2>&1 | tail -40`
Expected: both PASS. If a `receive` step mismatches, align it with the exact drain steps in `twoEndpointsEstablishLinkExchangeDataAndClose` / `twoEndpointsTransferAResourceOverALink`. Do NOT weaken the final unpack/validate/content assertions.

- [ ] **Step 3: Mutation-verify (three-step)**

Verify one at a time (revert between):
1. In Test B, corrupt one resource part frame before bridging it to B (flip a byte of one `parts[i]`): the resource fails to assemble / `unpack` fails → the test fails. (Confirms the delivered bytes are genuinely the transferred `packed`.) Revert.
2. In both tests, validate against a fresh `Identity()` instead of `aIdentity`: `validateSignature` returns false → tests fail. (Confirms the signature binds to the real sender.) Revert.
3. In Test A, send `msg.opportunisticPayload` (stripped) instead of `msg.packed` over the link: B's `unpack(data)` gets a payload missing the leading destination hash → wrong slice → `recovered` nil / assertions fail. (Confirms DIRECT sends the WHOLE `packed`.) Revert.

Run after each; confirm failure; revert; final run PASSES.

- [ ] **Step 4: Commit**

```bash
git add Tests/ReTiCANodeTests/LXMFDirectDeliveryTests.swift
git commit -F /tmp/ReTiCA/commit-lxmf3-t2.txt
```

(Message e.g. `test: LXMF-3 task 2 — direct LXMF delivery over a link (packet + resource)` plus trailers.)

---

## Self-Review

- **Spec coverage:** `Link.mdu` + `directRepresentation` + boundary/cross-val (Task 1); packet-over-link + resource-over-link end-to-end (Task 2). Router/link-management/method-selection/receipts deferred (spec §Scope) — no task, by design.
- **Placeholder scan:** the Task 2 test bodies reference "copy the link-establishment/resource drain from the named EndpointTests functions" — a bounded, concrete adaptation (the exact steps are cited by file+line), not an open placeholder. Everything else is complete code.
- **Type consistency:** `Link.mdu: Int`, `LXMessage.DirectRepresentation`/`directRepresentation`, `LXMessage.deliveryHash/create/packed/unpack/validateSignature` (LXMF-1/2); Endpoint action/delegate names verified against `Endpoint.swift`; fixture `linkMdu`/`link_mdu` consistent across generator, struct, CodingKeys, test.
- **Wire correctness:** `directRepresentation` threshold `packed.count <= Link.mdu` == RNS `content_size <= LINK_PACKET_MAX_CONTENT` (proven algebra); DIRECT sends whole `packed`; receiver `unpack(data)` on the whole bytes — matches LXMessage.py:636 / LXMRouter.py:1936-1937.
