# A Destructive Transition Requires Authenticated, Owned Input — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop two branches from destroying state on input they have not authenticated or confirmed they own — an invalid LRPROOF reaping our own link element (F12), and a resource proof aborting every transfer on the link (F15).

**Architecture:** Three small production edits, all transcriptions of reference behaviour. `LinkSession` ignores an invalid LRPROOF instead of reaping and mislabelling it. `LinkSession` routes resource proofs to the one sender-role transfer that owns them, using the resource hash already carried in the proof's leading 32 bytes. `ResourceTransfer` stops failing itself on a proof that does not validate. Then a sweep for the same pattern.

**Tech Stack:** Swift 6, The Composable Architecture (TCA), swift-testing (`@Test`), `swift test --no-parallel`.

**Spec:** `docs/superpowers/specs/2026-08-13-destructive-transitions-need-authentication-design.md`
**Source items:** F12, F15 in `docs/superpowers/2026-08-13-unauthenticated-link-element-sweep.md`.

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Commit directly to `main`.** No feature branch.
- **Commit trailers must start at column 0** (no indent) or git cannot parse them. Every commit ends with:
  ```
  Co-Authored-By: Claude <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
  ```
  Verify with `git log -1 --format='%(trailers:key=Claude-Session)'` — empty output means it did not parse.
- **Test command:** `swift test --no-parallel`. Baseline before this plan: **826 tests pass, 1 known issue** (`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood` in `TransportTests`, pre-existing). Any other failure is yours.
- **"I ran it" is not "I read it."** Read the actual output before reporting a count.
- **Cite SYMBOLS, not line numbers,** in comments and commit messages.
- **Do not encode derived arithmetic in prose or comments.**
- **Do not write property claims you have not verified.** The previous slice shipped several false ones, and they clustered in *reassuring* sentences and in comments whose job was correcting something else. Verify the reassuring sentences first.
- **`Effect.cancel` is EAGER.** Constructing `.cancel(id:)` cancels at construction time; `LinkSession.cancelAll()` is a func for this reason. Never bind a `.cancel` to a stored value.
- **Mutate once per clause in a test's name.** A compound name is a coverage claim. The previous slice shipped three tests whose names promised two properties while asserting one, and in each case the unasserted half was the one that mattered.
- **TestStore hazards:**
  - Effect-produced state is invisible via `store.state` until effects drain.
  - Under `.off`, `store.send` *silences and then discards* a stray action from the previous send — so proving an action was NOT delivered requires an `.on` window across the boundary, not an assertion afterwards.
  - Never flip back to `.off` before teardown.
  - Do not seed the state you claim to prove.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Sources/ReTiCATransport/LinkSession.swift` | Per-link state machine; routes packets to transfers | Tasks 1, 2 |
| `Sources/ReTiCATransport/ResourceTransfer.swift` | Per-transfer state machine | Task 3 |
| `Tests/ReTiCATransportTests/LinkSessionTests.swift` | LinkSession behaviour | Task 1 |
| `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift` | LinkSession↔transfer routing | Task 2 |
| `Tests/ReTiCATransportTests/ResourceTransferTests.swift` | Transfer behaviour | Task 3 |
| `docs/superpowers/2026-08-13-destructive-transition-sweep.md` | Sweep artifact | Task 5 |

---

## Task 1: An invalid LRPROOF is ignored, not reaped (F12)

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — case `(.initiator, .pending, .proof, .linkRequestProof)` inside `dispatch`
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: no signature change. Behavioural only — an invalid LRPROOF on a `.pending` initiator no longer emits `.delegate(.establishmentFailed(.handshakeRejected))`.

**Background.** `linkID` rides unencrypted in every link packet header and `Transport` routes link-addressed packets *before* `seenPacketHashes`, so anyone who has observed one link packet can inject a packet that reaches this branch. Today it reaps our own element, and labels the failure `.handshakeRejected` — the one PEER-shaped `LinkFailure`, which makes `LXMFNode` retry the link rather than request a path. So one packet both kills the establishment and burns the delivery budget against a route that works.

This is the exact mirror of the responder-side fix already shipped in `(.responder, .handshake, .data, .linkRequestRTT)` — read that branch's comment before writing yours.

- [ ] **Step 1: Write the two failing tests**

Two tests, because the name of a single test would claim two properties.

```swift
/// F12: an invalid LRPROOF is UNAUTHENTICATED input — linkID is cleartext and link packets
/// bypass Transport's dedup, so anyone can inject one. Reaping here let a single packet kill
/// our own outbound establishment. The element must survive and still establish when the real
/// proof arrives.
@Test @MainActor func garbageLinkProofDoesNotReapTheInitiatorElement() async {
    let clock = testClock()
    let dest = Identity()
    let destHash = Data(repeating: 0x91, count: 16)
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: dest.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.establish)
    _ = await captureTransmit(store)                                   // LINKREQUEST
    #expect(store.state.status == .pending)

    // Inject a bogus proof at the (publicly derivable) linkID.
    let garbage = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                         destinationType: .link, context: .linkRequestProof, contextFlag: false,
                         hops: 0, destinationHash: store.state.linkID, transportId: nil,
                         payload: Data(repeating: 0x00, count: 99))
    await store.send(.received(try! garbage.packed()))

    // Not reaped, still pending.
    #expect(store.state.status == .pending)

    // The genuine proof still establishes the link.
    let proof = Link.buildProof(linkID: store.state.linkID,
                                responderEphemeral: Identity(),
                                destinationIdentity: dest)
    let proofPacket = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                             destinationType: .link, context: .linkRequestProof, contextFlag: false,
                             hops: 0, destinationHash: store.state.linkID, transportId: nil,
                             payload: proof)
    await store.send(.received(try! proofPacket.packed()))
    _ = await captureTransmit(store)                                   // LRRTT
    await store.receive { if case .delegate(.established) = $0 { return true }; return false }
    #expect(store.state.status == .active)
}

/// F12, second half — the MISLABEL. After an injected proof, the establishment must fail as
/// PATH-shaped (.timedOut → .establishmentTimedOut), not PEER-shaped (.handshakeRejected).
/// LXMFNode answers .handshakeRejected by retrying the link instead of requesting a path, so a
/// mislabel here burns the whole delivery budget against a route that works. This is the
/// expensive half of F12 and needs its own test — a survival assertion would not catch it.
@Test @MainActor func garbageLinkProofFailsAsPathShapedNotPeerShaped() async {
    let clock = testClock()
    let dest = Identity()
    let destHash = Data(repeating: 0x92, count: 16)
    let store = TestStore(
        initialState: LinkSession.State(initiatorTo: Identity(publicKey: dest.publicKey)!,
                                        destinationHash: destHash, interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.establish)
    _ = await captureTransmit(store)
    let garbage = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                         destinationType: .link, context: .linkRequestProof, contextFlag: false,
                         hops: 0, destinationHash: store.state.linkID, transportId: nil,
                         payload: Data(repeating: 0x00, count: 99))
    await store.send(.received(try! garbage.packed()))

    await clock.advance(by: .seconds(store.state.establishmentTimeout))
    await store.receive(.establishmentDeadline)
    await store.receive(.delegate(.establishmentFailed(.timedOut))) { $0.status = .closed }
}
```

- [ ] **Step 2: Run both tests to verify they fail**

Run: `swift test --no-parallel --filter garbageLinkProof`
Expected: both FAIL. The injected proof drives `.establishmentFailed(.handshakeRejected)`, so `status` becomes `.closed`, the later `.established` never arrives, and the second test receives `.handshakeRejected` where it expects `.timedOut`.

- [ ] **Step 3: Write minimal implementation**

In `LinkSession.swift`, change the two `else` returns in that branch:

```swift
                case (.initiator, .pending, .proof, .linkRequestProof):
                    // UNAUTHENTICATED INPUT — the initiator-side mirror of the responder RTT
                    // branch below. `linkID` rides unencrypted in every link packet header and
                    // `Transport` routes link-addressed packets ahead of `seenPacketHashes`, so
                    // any observer can inject a packet that lands here.
                    //
                    // Reaping on a bad proof cost us twice: `LinkPlane` removed our own outbound
                    // element, AND `.handshakeRejected` is the one PEER-shaped `LinkFailure`, so
                    // `LXMFNode` answered by retrying the link instead of requesting a path —
                    // spending the whole establishment budget against a route that works.
                    //
                    // Ignore it and let `establishmentDeadline` decide. The establishment timer is
                    // already armed, so the element stays reapable; and the failure then arrives
                    // as `.timedOut` → `.establishmentTimedOut`, which is PATH-shaped and triggers
                    // a path request.
                    guard let destID = state.destinationIdentity,
                          let peerPub = Link.validateProof(proofData: packet.payload,
                                                           linkID: state.linkID,
                                                           destinationIdentity: destID)
                    else { return .none }
                    let ourPriv = Data((state.ephemeral.privateKey ?? Data()).prefix(32))
                    let key = Link.sessionKey(ephemeralPrivateX25519: ourPriv,
                                              peerPublicX25519: peerPub, linkID: state.linkID)
                    guard !key.isEmpty else { return .none }
```

Leave the rest of the branch unchanged.

- [ ] **Step 4: Run both tests to verify they pass**

Run: `swift test --no-parallel --filter garbageLinkProof`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `swift test --no-parallel`
Expected: 828 tests pass, 1 known issue. **Read the output.** If a pre-existing test asserted the old reaping or the `.handshakeRejected` label on THIS branch, it encoded the bug — update it to the new behaviour and say so in your report and commit message. Do not weaken the new tests.

Note `initiatorRejectsTamperedProof` and `initiatorEmptySessionKeyReportsHandshakeRejectedNotTimeout` exist in `LinkSessionTests` and both target this branch. Expect them to fail. Their names encode the OLD contract; rename them to describe the new one (an injected proof is ignored) rather than deleting them.

- [ ] **Step 6: Commit**

Message subject: `fix: an invalid LRPROOF no longer reaps our own element or mislabels the failure`

---

## Task 2: Route resource proofs to the transfer that owns them (F15, part 1)

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — the fan-out group ending `(_, .active, .proof, .resourceProof)`
- Test: `Tests/ReTiCATransportTests/LinkSessionResourceTests.swift`

**Interfaces:**
- Consumes: nothing from Task 1.
- Produces: `.resourceProof` packets are delivered to at most one transfer. The other six contexts in that group keep fanning out unchanged.

**Background.** `Resource.proofData(data:hash:)` is `hash ‖ fullHash(data ‖ hash)`, so the leading 32 bytes ARE the resource hash — the discriminator is already on the wire and unused. Reference does the routing in `Link.receive`:

```python
resource_hash = packet.data[0:RNS.Identity.HASHLENGTH//8]
for resource in self.outgoing_resources:
    if resource_hash == resource.hash:
        resource.validate_proof(packet.data)
```

Note it scopes to `outgoing_resources` — **sender-role only**. That is part of the reference, not an embellishment.

`ResourceTransfer.State` has `role: Role` (`.sender`/`.receiver`) and `resourceHash: Data`.

**Important for the test:** this test must pin **ROUTING**, not merely the outcome. Task 3 makes a mis-delivered proof harmless, so after Task 3 an outcome-only test would pass even with the fan-out restored, and the mutation would become unattributable. Assert that the non-owning transfer never receives the action.

- [ ] **Step 1: Write the failing tests**

```swift
/// F15: two concurrent SENDER transfers on one link. A's valid proof must reach A ONLY.
/// Before this fix the proof was fanned out to every transfer and each one failed itself on a
/// mismatch, so two of our OWN transfers destroyed each other with no attacker present.
///
/// This asserts ROUTING, not just outcome: the `.on` window makes a delivery to B an
/// unexpected action. An outcome-only assertion would stop discriminating once a mis-delivered
/// proof became harmless.
@Test @MainActor func aResourceProofReachesOnlyTheTransferThatOwnsIt() async {
    let clock = TestClock<Duration>()
    let store = activeLinkStore(clock)

    await store.send(.sendResource(Data(repeating: 0x01, count: 64)))
    await store.send(.sendResource(Data(repeating: 0x02, count: 64)))
    let ids = store.state.transfers.ids
    #expect(ids.count == 2)
    let a = store.state.transfers[id: ids[0]]!
    let b = store.state.transfers[id: ids[1]]!
    #expect(a.resourceHash != b.resourceHash)

    let proof = Resource.proofData(data: Data(repeating: 0x01, count: 64), hash: a.resourceHash)
    let packet = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                        destinationType: .link, context: .resourceProof, contextFlag: false,
                        hops: 0, destinationHash: store.state.linkID, transportId: nil,
                        payload: proof)

    store.exhaustivity = .on
    await store.send(.received(try! packet.packed()))
    await store.receive { action in
        if case let .transfer(.element(id, .received)) = action { return id == a.id }
        return false
    }
    // FLIP-THEN-SEND, and it is load-bearing. `send`'s "must handle N received actions" check
    // fires on actions queued by a PREVIOUS send, so a stray delivery to B is only observable
    // on the NEXT send while still `.on`. Asserting here and flipping to `.off` would let B's
    // action be silently discarded — and flipping back before teardown also disables the
    // teardown check. This second send is what makes the routing claim real.
    let inert = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                       destinationType: .link, context: .none, contextFlag: false, hops: 0,
                       destinationHash: store.state.linkID, transportId: nil,
                       payload: Data(repeating: 0x00, count: 8))
    await store.send(.received(try! inert.packed()))

    store.exhaustivity = .off
    #expect(store.state.transfers[id: b.id]?.status != .failed)
    await store.send(.close)
}

/// Reference scopes proof routing to `outgoing_resources` — sender-role only. A RECEIVER-role
/// transfer must not consume a proof even when its resourceHash matches.
///
/// This test uses the existing `activeLinkHostingPlainReceiver` helper in this file, which
/// stands up a link whose only transfer is receiver-role. Read that helper for its exact
/// signature and for the receiver's `resourceHash`; the assertions below are the point.
@Test @MainActor func aResourceProofIsNotDeliveredToAReceiverRoleTransfer() async {
    let clock = TestClock<Duration>()
    let (store, receiverHash) = activeLinkHostingPlainReceiver(clock)

    // A proof addressed to the receiver's own resource hash. Sender-role scoping means it must
    // not be delivered at all — under `.on`, any `.transfer(.element(...))` is unhandled.
    let proof = Resource.proofData(data: Data(repeating: 0x04, count: 64), hash: receiverHash)
    let packet = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                        destinationType: .link, context: .resourceProof, contextFlag: false,
                        hops: 0, destinationHash: store.state.linkID, transportId: nil,
                        payload: proof)

    store.exhaustivity = .on
    await store.send(.received(try! packet.packed()))
    // FLIP-THEN-SEND — see the note in the previous test. Without this second `.on` send, a
    // delivery to the receiver-role transfer is queued, never inspected, and then discarded when
    // exhaustivity drops. The test would assert nothing at all.
    let inert = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                       destinationType: .link, context: .none, contextFlag: false, hops: 0,
                       destinationHash: store.state.linkID, transportId: nil,
                       payload: Data(repeating: 0x00, count: 8))
    await store.send(.received(try! inert.packed()))

    store.exhaustivity = .off
    #expect(store.state.transfers.first?.status != .failed)
    await store.send(.close)
}
```

**Implementer note on the second test:** `activeLinkHostingPlainReceiver` exists in `LinkSessionResourceTests.swift` — read it and adapt the destructuring above to whatever it actually returns (it may return the store alone, in which case take the hash from `store.state.transfers.first!.resourceHash`). Do NOT invent a new helper, and do not contort the first test, which must stay reachability-driven.

- [ ] **Step 2: Run to verify they fail**

Run: `swift test --no-parallel --filter ResourceProof`
Expected: the first FAILS — the proof is fanned out, so B also receives `.received` and the `.on` window reports an unhandled action (and B transitions to `.failed`).

- [ ] **Step 3: Write minimal implementation**

In `LinkSession.swift`, split `.resourceProof` out of the fan-out group:

```swift
                case (_, .active, .data, .resource),
                     (_, .active, .data, .resourceRequest),
                     (_, .active, .data, .resourceHashmapUpdate),
                     (_, .active, .data, .resourceInitiatorCancel),
                     (_, .active, .data, .resourceReceiverCancel):
                    return .merge(state.transfers.ids.map {
                        .send(.transfer(.element(id: $0, action: .received(data))))
                    })

                case (_, .active, .data, .resourceProof),
                     (_, .active, .proof, .resourceProof):
                    // OWNERSHIP ROUTING. `Resource.proofData` is `hash ‖ fullHash(data ‖ hash)`,
                    // so the leading 32 bytes ARE the resource hash. Fanning a proof out to every
                    // transfer meant one packet reached transfers that did not own it — and two of
                    // our OWN concurrent sends destroyed each other, with no attacker involved.
                    //
                    // Reference routes the same way in `Link.receive`, and scopes to
                    // `outgoing_resources` — sender-role only. Note a proof CANNOT be
                    // authenticated: `Packet.pack` has a branch dedicated to `RESOURCE_PRF`
                    // leaving resource proofs unencrypted, so ownership is the only discriminator
                    // available. That is why `ResourceTransfer` must also never destroy itself on
                    // a proof that fails to validate.
                    guard packet.payload.count >= 32 else { return .none }
                    let owner = Data(packet.payload.prefix(32))
                    guard let target = state.transfers.first(where: {
                        $0.role == .sender && $0.resourceHash == owner
                    }) else { return .none }
                    return .send(.transfer(.element(id: target.id, action: .received(data))))
```

- [ ] **Step 4: Run to verify they pass**

Run: `swift test --no-parallel --filter ResourceProof`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `swift test --no-parallel`
Expected: 830 tests pass, 1 known issue. **Read the output.** Existing resource tests deliver a proof to a single transfer, which still routes correctly; if any fails, it is because it relied on fan-out — report which and why before changing it.

- [ ] **Step 6: Commit**

Message subject: `fix: route a resource proof to the sender transfer that owns it`

---

## Task 3: A bad proof never fails a transfer (F15, part 2)

**Files:**
- Modify: `Sources/ReTiCATransport/ResourceTransfer.swift` — case `(.sender, .proof, .resourceProof)`
- Test: `Tests/ReTiCATransportTests/ResourceTransferTests.swift`

**Interfaces:**
- Consumes: Task 2's routing (a transfer now only sees proofs addressed to it).
- Produces: no signature change. A proof that does not validate leaves the transfer's status untouched.

**Background.** Reference `Resource.validate_proof` has **no else branch at all** — a proof of the wrong length, or whose trailing 32 bytes do not match, does nothing; the resource keeps its status and the sender watchdog terminates it. Ours sets `.failed` and emits `.delegate(.failed)`, which is how one junk packet aborts a transfer.

Task 2 makes a mis-delivered proof unreachable, but the ownership discriminator is a *secret* (the resource hash travels only in an encrypted advertisement), not an authenticator. This change is what makes the outcome safe if that secret ever leaks.

- [ ] **Step 1: Write the failing test**

```swift
/// A proof correctly addressed to this transfer but whose trailing 32 bytes do not match must
/// NOT fail the transfer. Reference `Resource.validate_proof` has no else branch; the sender
/// watchdog is the terminator. Ownership routing is a secret, not an authenticator, so this is
/// what keeps a leaked resource hash from being a kill primitive.
@Test @MainActor func aProofThatDoesNotValidateLeavesTheTransferAlive() async {
    let data = Data("a bad proof must not destroy the transfer".utf8)
    let clock = TestClock<Duration>()
    let store = senderStore(data, clock)
    await store.send(.advertise)
    _ = await captureTransmits(store, count: 1)
    let s = store.state
    await store.send(.received(resourceRequestPacket(s)))            // requests all parts
    _ = await captureTransmits(store, count: s.parts.count)
    #expect(store.state.status == .awaitingProof)

    // Correct owner prefix, wrong proof body.
    let bad = Data(s.resourceHash) + Data(repeating: 0xAA, count: 32)
    let pkt = Packet(headerType: .header1, packetType: .proof, transportType: .broadcast,
                     destinationType: .link, context: .resourceProof, contextFlag: false,
                     hops: 0, destinationHash: s.linkID, transportId: nil, payload: bad)
    await store.send(.received(try! pkt.packed()))

    #expect(store.state.status == .awaitingProof)
}
```

This reuses the exact drive-to-`.awaitingProof` sequence that `senderServesAllPartsThenAwaitsProofAndConcludes` already uses in this file — `senderStore(_:_:)`, `.advertise`, `captureTransmits`, `resourceRequestPacket(_:)`. Do not add a new helper.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --no-parallel --filter aProofThatDoesNotValidate`
Expected: FAIL — `status` is `.failed`.

- [ ] **Step 3: Write minimal implementation**

```swift
                case (.sender, .proof, .resourceProof):
                    // A proof that does not validate is IGNORED, never destructive. Resource
                    // proofs are unencrypted by reference design (`Packet.pack` has a branch
                    // dedicated to `RESOURCE_PRF`), so nothing here is authenticated — the
                    // ownership routing in `LinkSession` keys on the resource hash, which is a
                    // SECRET carried in an encrypted advertisement, not an authenticator.
                    // Failing on a mismatch therefore made a leaked hash into a kill primitive,
                    // and it is how one junk packet aborted a transfer.
                    //
                    // Reference `Resource.validate_proof` has no else branch: the resource keeps
                    // its status and the sender watchdog terminates it.
                    guard Resource.validateProof(proofData: packet.payload,
                                                 expectedProof: state.expectedProof)
                    else { return .none }
                    state.status = .complete
                    return .merge(.cancel(id: CancelID.watchdog), .send(.delegate(.concluded)))
```

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --no-parallel --filter aProofThatDoesNotValidate`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `swift test --no-parallel`
Expected: 831 tests pass, 1 known issue. **Read the output.** If an existing test asserted that a bad proof fails the transfer, it encoded the divergence — update it and explain.

- [ ] **Step 6: Commit**

Message subject: `fix: a resource proof that does not validate no longer fails the transfer`

---

## Task 4: Consolidated mutation verification

**Files:**
- No production changes. Test amendments only if a mutation survives.

**Background.** Per-task review does not catch a test that was vacuous from the start — the previous slice shipped one that passed a clean review and was only exposed when an old mutation was re-run against the current tree. Run the whole set against the finished code.

- [ ] **Step 1: Confirm green and record the count**

Run: `swift test --no-parallel`. Read the output. Record the exact count.

- [ ] **Step 2: Apply each mutation INDIVIDUALLY and record which test fails**

1. `LinkSession` `(.initiator, .pending, .proof, .linkRequestProof)`: change the `validateProof` `else { return .none }` back to `else { return .send(.delegate(.establishmentFailed(.handshakeRejected))) }`
2. Same branch: change the `guard !key.isEmpty else { return .none }` back to `.send(.delegate(.establishmentFailed(.handshakeRejected)))`
3. `LinkSession` proof routing: drop `$0.role == .sender` from the `first(where:)` predicate
4. `LinkSession` proof routing: drop `$0.resourceHash == owner` from the predicate (match any transfer)
5. `LinkSession`: restore `.resourceProof` to the fan-out group
6. `ResourceTransfer` `(.sender, .proof, .resourceProof)`: restore `state.status = .failed` + `.send(.delegate(.failed))` on the mismatch path
7. `LinkSession` proof routing: delete the `packet.payload.count >= 32` guard

Every one must fail at least one test. Expected catchers:
1 → `garbageLinkProofDoesNotReapTheInitiatorElement`; 2 → same or `garbageLinkProofFailsAsPathShapedNotPeerShaped`; 3 → `aResourceProofIsNotDeliveredToAReceiverRoleTransfer`; 4 and 5 → `aResourceProofReachesOnlyTheTransferThatOwnsIt`; 6 → `aProofThatDoesNotValidateLeavesTheTransferAlive`; 7 → may survive, see Step 3.

- [ ] **Step 3: If ANY mutation survives, that is a coverage hole — report it and close it**

Do not paper over it. Write the test that catches it, and say in your report which mutation survived and what property was therefore unpinned. Mutation 7 in particular may have no catcher; if so, add a test feeding a short (<32 byte) proof payload and asserting no crash and no delivery.

Note mutation 5 is the one most at risk of becoming unattributable: after Task 3, restoring the fan-out no longer changes any transfer's *outcome*. It is caught only because Task 2's test asserts routing under `.on`. If it survives, Task 2's test has regressed to an outcome assertion — fix the test, not the mutation list.

- [ ] **Step 4: Revert every mutation and confirm green**

Run `git diff` to confirm the tree matches the committed state, then `swift test --no-parallel`. Same count as Step 1.

- [ ] **Step 5: Commit**

Message subject: `test: mutation-verify the destructive-transition fixes`

Put the full mutation table in the commit body.

---

## Task 5: The destructive-transition sweep

**Files:**
- Create: `docs/superpowers/2026-08-13-destructive-transition-sweep.md`
- Modify: `docs/superpowers/2026-08-10-handoff-link-lifecycle-and-delivery-termination.md`

**Background.** F6, F12 and F15 are three instances of one pattern. Three instances means it is systemic, not that we found them all.

- [ ] **Step 1: Enumerate destructive branches**

Read `LinkSession.swift`, `ResourceTransfer.swift` and `Transport.swift`. For every branch reachable from inbound network data that performs a **destructive** transition — `.failed`, `.closed`, `.establishmentFailed`, link-element removal, transfer removal — record:

- branch (by SYMBOL, not line number)
- does it gate on an authentication check (a successful `Link.decrypt`)?
- does it gate on an ownership check (`resourceHash`, `linkID`, or equivalent)?
- verdict: safe / fixed here / **OPEN**

**This is a different question from the previous sweep,** which classified by CREATE / EXTEND / RE-HOME / DESTROY *reachability*. That framing recorded F15's adversarial half and missed the non-adversarial one entirely. Ask "does this destroy something without checking ownership?", not "can an attacker reach this?".

- [ ] **Step 2: Use the house style as the yardstick**

These three branches already do it correctly and are the standard to compare against:
- `(.receiver, .data, .resourceInitiatorCancel)` — `Link.decrypt` + `plain == state.resourceHash`
- `(.sender, .data, .resourceReceiverCancel)` — same
- `(.receiver, .data, .resourceHashmapUpdate)` — `Link.decrypt` + `prefix(32) == state.resourceHash`

Any destructive branch missing both gates is an anomaly to justify or fix.

- [ ] **Step 3: Probe anything reasoning cannot settle**

Probes, not reasoning, found every significant defect in the previous slice. Put them in a scratch directory outside `Tests/`, and leave none behind.

- [ ] **Step 4: Append findings to the handoff**

Any OPEN item becomes a numbered handoff entry (F17 onward — IDs are stable, do not renumber). Mark F12 and F15 CLOSED with the commit range and a one-line note of what closed each. **Do not overclaim:** F15 is ownership-routed and non-destructive, NOT authenticated — resource proofs cannot be authenticated at all.

- [ ] **Step 5: Verify the reassuring sentences first**

Five of the six accuracy defects in the previous sweep sat in reassuring positions, or inside entries whose job was correcting another claim. Those are the two spots a later reader will not re-derive. Check every `safe` verdict's stated justification against the code before checking anything else.

- [ ] **Step 6: Commit**

Message subject: `docs: sweep every branch that destroys state on unowned input`

---

## Final verification

- [ ] `swift test --no-parallel` — all pass, 1 known issue. **Read the output.**
- [ ] `git log --format='%(trailers:key=Claude-Session)' -6` — every commit's trailer parses.
- [ ] Spec coverage: F12 ✓ (T1, both halves separately), F15 routing ✓ (T2), F15 no-fail ✓ (T3), role scoping ✓ (T2), mutation discipline ✓ (T4), sweep ✓ (T5).
- [ ] Request a whole-branch review on the most capable model. It has found a real defect on 11 of 11 slices, and on the last one it found a Critical the slice itself introduced. Ask it STRUCTURAL questions — trace an adversarial sequence through production wiring rather than reducers, name who consumes each changed path, and check whether Tasks 1–3 interact badly. Give it licence to write throwaway probes.
