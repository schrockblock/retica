# LXMF-2: Opportunistic Delivery — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Send/receive a small LXMF message as a single encrypted packet to a recipient's `lxmf.delivery` destination — the first end-to-end LXMF message.

**Architecture:** Two pure transforms on `LXMessage` (`opportunisticPayload` = `packed.dropFirst(16)`; `fromOpportunistic(destinationHash:payload:)` = `unpack(destinationHash + payload)`), plus an end-to-end integration test that drives the existing Transport/Endpoint encrypt→route→decrypt machinery. No new production module, no TCA changes.

**Tech Stack:** Swift, Swift Testing, The Composable Architecture (integration test), genuine `lxmf 1.1.0` (reuse the committed LXMF-1 fixture).

## Global Constraints

- Commit directly to `main`; no feature branch.
- No compound shell commands (no `&&`, `||`, `;`, `xargs`, inline interpreter scripts). One command per Bash call. A single `>` redirect is allowed. Never use echo/printf/heredoc to write files — use editor tools.
- Temp files go in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- ReTiCA signatures are hedged/randomized and opportunistic packet payloads are encrypted with ephemeral keys → validate/decrypt-and-reconstruct, never byte-compare a signature or an encrypted packet.
- Reuse the committed LXMF-1 fixture (`Tests/ReTiCATests/Vectors/lxmf_fixtures.json` + `LXMFVectorFixtures`) for cross-val; do NOT regenerate it.
- Pure additions to `LXMessage`; tests in the pure-core (`ReTiCATests`) and node (`ReTiCANodeTests`) targets. No new production module.
- Build gotcha: signal-11/10/SIGILL → `swift package clean` then retry.
- Commit trailers, exactly:
  ```
  Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
  ```

**Spec:** `docs/superpowers/specs/2026-07-27-lxmf-opportunistic-delivery-design.md`
**Base:** this plan's own commit (verify with `git log --oneline <planCommit>..HEAD`, never `HEAD~1`).

---

## File Structure

- **Create** `Sources/ReTiCA/LXMF/LXMessage+Opportunistic.swift` — the two helpers.
- **Modify** `Tests/ReTiCATests/LXMessageTests.swift` — unit tests.
- **Modify** `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift` — reconstruction cross-val (reuse LXMF-1 fixture).
- **Create** `Tests/ReTiCANodeTests/LXMFOpportunisticDeliveryTests.swift` — end-to-end integration test.

---

## Task 1: Opportunistic helpers + unit/cross-val tests

**Files:**
- Create: `Sources/ReTiCA/LXMF/LXMessage+Opportunistic.swift`
- Test: `Tests/ReTiCATests/LXMessageTests.swift`, `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift`

**Interfaces:**
- Produces: `LXMessage.opportunisticPayload: Data`, `LXMessage.fromOpportunistic(destinationHash: Data, payload: Data) -> LXMessage?`. Task 2 uses both.
- Consumes: `LXMessage.packed`, `LXMessage.unpack`, `LXMessage.destinationLength` (all from LXMF-1).

- [ ] **Step 1: Write the failing tests**

Add to `Tests/ReTiCATests/LXMessageTests.swift`:

```swift
@Test func opportunisticPayloadStripsLeadingDestinationHash() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    let msg = LXMessage.create(source: source, destinationHash: destHash,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi".utf8))
    #expect(msg.opportunisticPayload == Data(msg.packed.dropFirst(16)))
    #expect(msg.opportunisticPayload.count == msg.packed.count - 16)
}

@Test func fromOpportunisticReconstructsAndValidates() {
    let source = Identity()
    let destHash = LXMessage.deliveryHash(identityHash: Identity().hash)
    let msg = LXMessage.create(source: source, destinationHash: destHash,
                               timestamp: 1700000000.5, title: Data("t".utf8), content: Data("hi".utf8))
    // Receiver reconstructs from its delivery-destination hash + the decrypted payload.
    let recovered = LXMessage.fromOpportunistic(destinationHash: destHash, payload: msg.opportunisticPayload)
    #expect(recovered != nil)
    #expect(recovered?.hash == msg.hash)
    #expect(recovered?.content == Data("hi".utf8))
    #expect(recovered?.sourceHash == LXMessage.deliveryHash(identityHash: source.hash))
    #expect(recovered?.validateSignature(source: source) == true)
}

@Test func fromOpportunisticRejectsMalformed() {
    // destinationHash + payload shorter than the LXMF header (16+16+64) → nil.
    #expect(LXMessage.fromOpportunistic(destinationHash: Data(count: 16), payload: Data(count: 10)) == nil)
}
```

Add to `Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift`:

```swift
/// A genuine LXMF opportunistic payload is `packed[16:]`; reconstructing it with our
/// `fromOpportunistic` (prepending the delivery destination hash) recovers the genuine reference
/// message and validates its signature.
@Test func fromOpportunisticReconstructsReferenceMessage() throws {
    let f = try LXMFVectorFixtures.load()
    let refPacked = Data(hexString: f.packed)!
    let destHash = Data(hexString: f.destinationHash)!
    let source = Identity(privateKey: Data(hexString: f.sourcePrivateKey)!)!
    let opportunistic = Data(refPacked.dropFirst(16))          // what RNS.Packet carries as payload
    let recovered = LXMessage.fromOpportunistic(destinationHash: destHash, payload: opportunistic)
    #expect(recovered != nil)
    #expect(recovered?.hash == Data(hexString: f.hash)!)
    #expect(recovered?.content == Data(hexString: f.content)!)
    #expect(recovered?.validateSignature(source: source) == true)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run: `swift test --filter "opportunistic\|fromOpportunistic" 2>&1 | tail -20`
Expected: compile failure — `opportunisticPayload` / `fromOpportunistic` don't exist.

- [ ] **Step 3: Implement the helpers**

Create `Sources/ReTiCA/LXMF/LXMessage+Opportunistic.swift`:

```swift
import Foundation

extension LXMessage {
    /// The plaintext for an opportunistic send: `packed` minus the leading 16-byte destinationHash
    /// (the RNS packet header carries the destination). Hand this to Transport's `.send` toward the
    /// recipient's `lxmf.delivery` destination — `LXMessage.deliveryHash(recipientIdentityHash)` —
    /// which encrypts it to the recipient's identity. Mirrors reference LXMF's opportunistic packet:
    /// `RNS.Packet(delivery_destination, packed[DESTINATION_LENGTH:])` (LXMessage.py:634).
    public var opportunisticPayload: Data {
        Data(packed.dropFirst(LXMessage.destinationLength))
    }

    /// Reconstruct a message received opportunistically: prepend our `lxmf.delivery` destination hash
    /// (which the packet header carried, not the payload) to the decrypted `payload`, then unpack.
    /// `destinationHash` is our delivery-destination hash; `payload` is the decrypted inbound plaintext.
    /// Returns nil for malformed input (LXMF-1 `unpack` rules). Signature validation is separate.
    public static func fromOpportunistic(destinationHash: Data, payload: Data) -> LXMessage? {
        unpack(destinationHash + payload)
    }
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run: `swift test --filter "opportunistic\|fromOpportunistic\|Opportunistic" 2>&1 | tail -20`
Expected: the four new tests PASS; existing `lxMessage*` tests still PASS.

- [ ] **Step 5: Mutation-verify (three-step)**

Batch-mutate: (1) change `dropFirst(LXMessage.destinationLength)` to `dropFirst(0)` in `opportunisticPayload` — `opportunisticPayloadStripsLeadingDestinationHash` fails (length/content wrong) and the round-trip tests fail (reconstruction prepends an extra 16 bytes → unpack sees a wrong-length payload). (2) change `fromOpportunistic` to `unpack(payload)` (drop the `destinationHash` prefix) — `fromOpportunisticReconstructsAndValidates` and the cross-val fail (unpack of a payload missing its destination hash → wrong slice → nil or wrong fields). Run `swift test --filter "opportunistic\|Opportunistic"`, confirm the named tests fail. Revert both; run again; all PASS.

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCA/LXMF/LXMessage+Opportunistic.swift Tests/ReTiCATests/LXMessageTests.swift Tests/ReTiCATests/Vectors/LXMessageCrossValidationTests.swift
git commit -F /tmp/ReTiCA/commit-lxmf2-t1.txt
```

(Message e.g. `feat: LXMF-2 task 1 — opportunistic payload helpers + cross-val` plus trailers.)

---

## Task 2: End-to-end opportunistic delivery integration test

**Files:**
- Create: `Tests/ReTiCANodeTests/LXMFOpportunisticDeliveryTests.swift`

**Interfaces:**
- Consumes: `LXMessage.create/opportunisticPayload/fromOpportunistic/validateSignature/deliveryHash` (Task 1 + LXMF-1); `Endpoint` actions `.connect/.registerLocalDestination/.announce/.send`; `Endpoint.Delegate.messageReceived/.pathLearned`.

**Context:** Mirror the two-Endpoint harness in `Tests/ReTiCANodeTests/EndpointTests.swift` (`twoEndpointsEstablishLinkExchangeDataAndClose`, lines ~252-290): two `Endpoint` TestStores over mock `TCPConnection`s, `sent` capture arrays, HDLC-framed bytes bridged by yielding one store's last `sent` frame into the other's event stream. This test is CONNECTIONLESS (no link) — simpler than the link tests. The receive/drain sequence (`await store.receive(...)`) must match observed behavior; adapt from the existing two-node tests in the same file (they show the exact `\.transport.received` / `\.delegate.pathLearned` / `\.interface.send` drain steps). Use `store.exhaustivity = .off`.

- [ ] **Step 1: Write the failing test**

Create `Tests/ReTiCANodeTests/LXMFOpportunisticDeliveryTests.swift`. Model the setup on `twoEndpointsEstablishLinkExchangeDataAndClose`:

```swift
import Testing
import Foundation
import ComposableArchitecture
@testable import ReTiCANode
@testable import ReTiCA

/// End-to-end: sender A opportunistically delivers an LXMF message to recipient B's lxmf.delivery
/// destination over the real encrypt→route→decrypt path; B reconstructs, validates, and reads it.
@Test @MainActor func opportunisticLXMFMessageDeliversEndToEnd() async {
    let clock = TestClock()
    let aIdentity = Identity()
    let bIdentity = Identity()
    // Both parties' lxmf.delivery destinations (SINGLE, IN — owned locally).
    let aDelivery = Destination(kind: .single, direction: .in, appName: "lxmf", aspects: ["delivery"], identity: aIdentity)!
    let bDelivery = Destination(kind: .single, direction: .in, appName: "lxmf", aspects: ["delivery"], identity: bIdentity)!

    func make(_ host: String, _ sent: LockIsolated<[Data]>) -> (TestStore<Endpoint.State, Endpoint.Action>, AsyncStream<TCPEvent>.Continuation) {
        let events = AsyncStream<TCPEvent>.makeStream()
        let store = TestStore(initialState: Endpoint.State(host: host, port: 4242, reconnectOnDrop: false)) {
            Endpoint()
        } withDependencies: {
            $0.tcpConnection = TCPConnection(open: { _, _ in events.stream },
                                             send: { d in sent.withValue { $0.append(d) } },
                                             close: { })
            $0.continuousClock = clock
            $0.date = .constant(Date(timeIntervalSince1970: 0))
            $0.uuid = .incrementing
        }
        store.exhaustivity = .off
        return (store, events.continuation)
    }

    let sentA = LockIsolated<[Data]>([]); let sentB = LockIsolated<[Data]>([])
    let (a, eventsA) = make("a", sentA)
    let (b, eventsB) = make("b", sentB)

    await a.send(.connect); eventsA.yield(.connected); await a.receive(\.transport.interfaceConnected)
    await b.send(.connect); eventsB.yield(.connected); await b.receive(\.transport.interfaceConnected)
    await a.send(.registerLocalDestination(aDelivery))
    await b.send(.registerLocalDestination(bDelivery))

    // B announces its lxmf.delivery destination; A learns it (so A can address + encrypt to B).
    await b.send(.announce(destinationHash: bDelivery.hash, appData: nil))
    eventsA.yield(.data(sentB.value.last!))
    await a.receive(\.transport.received); await a.receive(\.delegate.pathLearned)
    // A announces its lxmf.delivery destination; B learns it (so B can resolve the sender identity).
    await a.send(.announce(destinationHash: aDelivery.hash, appData: nil))
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received); await b.receive(\.delegate.pathLearned)

    // A builds an LXMF message to B's delivery destination and sends it opportunistically.
    let msg = LXMessage.create(source: aIdentity, destinationHash: bDelivery.hash,
                               timestamp: 1700000000.5, title: Data("hi".utf8), content: Data("hello lxmf".utf8))
    #expect(bDelivery.hash == LXMessage.deliveryHash(identityHash: bIdentity.hash))   // addressing sanity
    await a.send(.send(destinationHash: bDelivery.hash, plaintext: msg.opportunisticPayload))
    await a.receive { if case .interface(.send) = $0 { return true }; return false }

    // Bridge the DATA packet to B; B decrypts and surfaces the plaintext.
    let got = LockIsolated<(Data, Data)?>(nil)
    eventsB.yield(.data(sentA.value.last!))
    await b.receive(\.transport.received)
    await b.receive { action in
        if case let .delegate(.messageReceived(h, p)) = action { got.setValue((h, p)); return true }
        return false
    }
    let (deliveryHash, plaintext) = got.value!
    #expect(deliveryHash == bDelivery.hash)

    // B reconstructs the LXMF message and validates it against the sender identity it learned.
    let recovered = LXMessage.fromOpportunistic(destinationHash: deliveryHash, payload: plaintext)
    #expect(recovered != nil)
    #expect(recovered?.content == Data("hello lxmf".utf8))
    #expect(recovered?.title == Data("hi".utf8))
    let senderIdentity = b.state.transport.learned[recovered!.sourceHash]?.identity
    #expect(senderIdentity != nil)
    #expect(recovered?.validateSignature(source: senderIdentity!) == true)
    #expect(recovered?.hash == msg.hash)
}
```

- [ ] **Step 2: Run the test — adjust the drain sequence if needed**

Run: `swift test --filter "opportunisticLXMFMessageDeliversEndToEnd" 2>&1 | tail -30`
Expected: PASS. If a `receive` step mismatches (extra/missing intermediate action), align it with the exact drain steps used by the neighboring two-node tests in `EndpointTests.swift` (e.g. an extra `\.interface.send` on announce, or `\.transport.received` ordering) — the `.off` store tolerates unlisted actions, so only the awaited ones must be present and ordered. Do NOT weaken the final assertions (reconstruct/validate/content).

- [ ] **Step 3: Mutation-verify (three-step)**

Verify one at a time (revert between):
1. In production `Transport.send`, skip encryption (`let ciphertext = plaintext`): the test still delivers bytes but B's decrypt of an unencrypted payload fails → `messageReceived` is not emitted (or yields garbage) → the test fails at the `messageReceived`/reconstruct step. (Confirms the encrypt→decrypt path is exercised.) Revert.
2. In the test, corrupt the sent frame before bridging (flip a byte of `sentA.value.last!`): B's decrypt/authentication fails → no valid `messageReceived`/reconstruct → test fails. Revert.
3. In the test, validate against `bIdentity` instead of the learned sender identity: `validateSignature` returns false → test fails (proves the signature is genuinely bound to the sender). Revert.

Run the test after each; confirm failure; revert; final run PASSES. (If mutation 1 is impractical to isolate cleanly, rely on mutations 2 and 3, which fully exercise the delivery + signature binding.)

- [ ] **Step 4: Commit**

```bash
git add Tests/ReTiCANodeTests/LXMFOpportunisticDeliveryTests.swift
git commit -F /tmp/ReTiCA/commit-lxmf2-t2.txt
```

(Message e.g. `test: LXMF-2 task 2 — end-to-end opportunistic LXMF delivery` plus trailers.)

---

## Self-Review

- **Spec coverage:** `opportunisticPayload` + `fromOpportunistic` (Task 1); unit round-trip/malformed + genuine-LXMF reconstruction cross-val (Task 1); end-to-end delivery incl. source-identity resolution (Task 2). Direct/link, propagation/router, stamps/rich-fields deferred (spec §Scope) — no task, by design.
- **Placeholder scan:** none — every step has concrete code/commands, except the Task 2 drain sequence which is explicitly flagged as "align with the neighboring two-node tests" (a real, bounded adaptation, not a placeholder).
- **Type consistency:** `opportunisticPayload: Data`, `fromOpportunistic(destinationHash:payload:) -> LXMessage?`, `LXMessage.deliveryHash(identityHash:)`, `LXMessage.destinationLength` all match LXMF-1; Endpoint action/delegate names (`.send`, `.registerLocalDestination`, `.announce`, `.messageReceived`, `.pathLearned`) verified against `Endpoint.swift`; `b.state.transport.learned[...].identity` matches `LearnedDestination`.
- **Wire correctness:** opportunistic payload = `packed.dropFirst(16)` and reconstruction = `unpack(destinationHash + payload)` mirror RNS.Packet(delivery_destination, packed[16:]) and the router's `destination.hash + decrypted`; encryption/routing/decryption reuse existing cross-validated machinery.
