# Unauthenticated Input Cannot Pin, Steal, or Kill a Link Element — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make link-element lifecycle immune to unauthenticated input — a peer without the session key cannot kill a legitimate establishment, cannot cheaply multiply elements, cannot steal a link by re-homing it, and cannot grow `LinkPlane.State.links` without bound.

**Architecture:** Four independent changes plus a sweep. `LinkSession` stops reaping on an undecryptable RTT and gains a `lastData` clock that only successfully-decrypted non-keepalive traffic advances. `LinkPlane` dedupes inbound LINKREQUESTs by `linkID` before it does any crypto, and caps responder links with eviction ordered by `lastData`. Re-homing moves out of `LinkPlane.routeLinkPacket` into `LinkSession`, where decryption has already happened, gated on either an authenticated packet or a one-shot permission set by a local interface disconnect.

**Tech Stack:** Swift 6, The Composable Architecture (TCA), swift-testing (`@Test`), `swift test --no-parallel`.

**Spec:** `docs/superpowers/specs/2026-08-13-unauthenticated-input-link-elements-design.md`
**Source items:** handoff F1, F2, F6 — `docs/superpowers/2026-08-10-handoff-link-lifecycle-and-delivery-termination.md` (as corrected in `87055bc`).

---

## Global Constraints

Every task's requirements implicitly include this section.

- **Commit directly to `main`.** No feature branch, no merge dance.
- **Commit trailers must start at column 0** (no indent) or git cannot parse them. Every commit ends with:
  ```
  Co-Authored-By: Claude <noreply@anthropic.com>
  Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
  ```
  Verify with `git log -1 --format='%(trailers:key=Claude-Session)'` — empty output means the trailer did not parse.
- **Test command:** `swift test --no-parallel`. Baseline before this plan: **760 tests pass, 1 known issue** (`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood` in `TransportTests`, pre-existing). Any other failure is yours.
- **"I ran it" is not "I read it."** Read the actual test output before reporting a count. Do not report green from an exit code alone.
- **Cite SYMBOLS, not line numbers,** in code comments and commit messages. Line citations in this repo have drifted five times, once invalidated by the commit that wrote them. Symbols drift only on rename, which the compiler catches.
- **Do not encode derived arithmetic in prose or comments.** Name the constants and point at the tests; the clock advances are executable and cannot go stale silently.
- **`Effect.cancel` is EAGER.** Constructing `.cancel(id:)` cancels at construction time. `LinkSession.cancelAll()` is a **func** for this reason — never bind it to a `let`, and never hoist a `.cancel` out of a branch into a stored value. This bug once killed three timers while all tests passed before and after.
- **TestStore hygiene:**
  - Prefer flip-then-send (`store.exhaustivity = .on` then send) over a trailing `.on` — it catches strays and tolerates armed timers.
  - Never flip back to `.off` before teardown; that disables the teardown check and makes the test vacuous.
  - `store.state.x` right after a send reads PRE-effect state. Effect-produced state is invisible until drained.
  - **Do not seed the state you claim to prove.** Tests that seed `LinkPlane.State(links: [...])` prove nothing about reachability. Where a test claims a property about link *creation*, drive it through `acceptLinkRequest` with a real packet.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Sources/ReTiCATransport/LinkSession.swift` | Per-link state machine; decryption lives here | Tasks 1, 3, 5 |
| `Sources/ReTiCANode/LinkPlane.swift` | Owns link elements; routing, creation, reaping | Tasks 2, 4, 5, 6 |
| `Sources/ReTiCANode/BLEEndpoint.swift` | BLE composition; emits interface disconnects | Task 6 |
| `Sources/ReTiCANode/TCPEndpoint.swift` | TCP composition; emits interface disconnects | Task 6 |
| `Tests/ReTiCATransportTests/LinkSessionTests.swift` | LinkSession behaviour | Tasks 1, 3, 5, 7 |
| `Tests/ReTiCANodeTests/LinkPlaneTests.swift` | LinkPlane behaviour | Tasks 2, 4, 5, 6 |
| `docs/superpowers/2026-08-13-unauthenticated-link-element-sweep.md` | Sweep artifact | Task 8 |

---

## Task 1: A bad RTT is ignored, not reaped (F6)

This is the highest-value change in the plan and the only one-packet attack. Do it first.

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — case `(.responder, .handshake, .data, .linkRequestRTT)` inside the `dispatch` function of `case let .received`
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: no signature change. Behavioural only: an undecryptable `.linkRequestRTT` on a `.handshake` responder no longer emits `.delegate(.establishmentFailed(.handshakeRejected))`.

**Background the implementer needs:** `Transport` routes link-addressed packets by cleartext `linkID` *before* its `seenPacketHashes` dedup, and `linkID` appears unencrypted in every link packet header. So anyone who has observed one link packet can inject a packet that reaches this branch. `LinkPlane` removes an element in response to `.establishmentFailed`, so reaping here lets one injected packet silently destroy a legitimate in-progress establishment. `LinkPlane` also suppresses `linkFailed` for responders, so it is silent.

- [ ] **Step 1: Write the failing test**

Add to `Tests/ReTiCATransportTests/LinkSessionTests.swift`:

```swift
/// F6: an RTT we cannot decrypt is UNAUTHENTICATED input — link packets route by cleartext
/// linkID ahead of Transport's dedup, so anyone can inject one. Reaping on it would let a
/// single injected packet silently kill a legitimate establishment. The element must survive
/// and still establish when the real RTT arrives.
@Test @MainActor func garbageRTTDoesNotReapTheResponderElement() async {
    let clock = testClock()
    let owner = Identity()
    let initEph = Identity()
    let destHash = Data(repeating: 0x77, count: 16)
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: destHash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    let store = TestStore(
        initialState: LinkSession.State(responderFor: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"))
    ) { LinkSession() } withDependencies: {
        $0.date = .constant(epoch); $0.continuousClock = clock; $0.uuid = .incrementing
    }
    store.exhaustivity = .off

    await store.send(.acceptRequest(try! request.packed()))
    _ = await captureTransmit(store)                                   // LRPROOF
    #expect(store.state.status == .handshake)

    // Inject a garbage RTT at the (publicly derivable) linkID.
    let garbage = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                         destinationType: .link, context: .linkRequestRTT, contextFlag: false,
                         hops: 0, destinationHash: store.state.linkID, transportId: nil,
                         payload: Data(repeating: 0x00, count: 48))
    await store.send(.received(try! garbage.packed()))

    // The element must NOT have been reaped and must still be mid-handshake.
    #expect(store.state.status == .handshake)

    // The legitimate RTT still completes the handshake.
    let rttCipher = Link.encrypt(MsgPack.encode(0.0), sessionKey: store.state.sessionKey)
    let rttPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                           destinationType: .link, context: .linkRequestRTT, contextFlag: false,
                           hops: 0, destinationHash: store.state.linkID, transportId: nil,
                           payload: rttCipher)
    await store.send(.received(try! rttPacket.packed()))
    await store.receive { if case .delegate(.established) = $0 { return true }; return false }
    #expect(store.state.status == .active)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter garbageRTTDoesNotReapTheResponderElement`
Expected: FAIL. The garbage RTT drives `.delegate(.establishmentFailed(.handshakeRejected))`, so `status` becomes `.closed` and the later `.established` never arrives.

- [ ] **Step 3: Write minimal implementation**

In `LinkSession.swift`, replace the body of case `(.responder, .handshake, .data, .linkRequestRTT)`:

```swift
                case (.responder, .handshake, .data, .linkRequestRTT):
                    // UNAUTHENTICATED INPUT: link packets are routed by cleartext linkID ahead of
                    // Transport's seenPacketHashes dedup, and linkID rides unencrypted in every link
                    // packet header — so any observer can inject a packet that lands here. Reaping
                    // on a decrypt failure would let ONE injected packet silently kill a legitimate
                    // establishment (LinkPlane removes the element on .establishmentFailed, and
                    // suppresses linkFailed for responders, so the death is invisible).
                    //
                    // Ignore it instead and let `establishmentDeadline` decide. Same policy as the
                    // (_, .active, .data, .none) branch below: corrupt/foreign data is ignored and
                    // the element stays alive. The establishment timer is already armed, so the
                    // element is still reapable — the §1b invariant holds.
                    guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
                          let rtt = MsgPack.decodeDouble(plain)
                    else { return .none }
                    state.rtt = rtt
                    state.status = .active
                    state.activatedAt = now
                    state.lastInbound = now
                    return .merge(.send(.delegate(.established(linkID: state.linkID, sessionKey: state.sessionKey))),
                                  .cancel(id: CancelID.establishment), inactivityTimer(state.staleTime))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --no-parallel --filter garbageRTTDoesNotReapTheResponderElement`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `swift test --no-parallel`
Expected: 761 tests pass, 1 known issue. **Read the output.** If a pre-existing test asserted the old reaping behaviour, that test encoded the bug — update it to assert the element survives, and say so in the commit message.

- [ ] **Step 6: Commit**

```bash
git add Sources/ReTiCATransport/LinkSession.swift Tests/ReTiCATransportTests/LinkSessionTests.swift
git commit -F <message-file>
```

Message subject: `fix: an undecryptable RTT no longer reaps a legitimate responder element`

---

## Task 2: Dedupe inbound LINKREQUESTs by linkID (F2)

**Files:**
- Modify: `Sources/ReTiCANode/LinkPlane.swift` — case `.acceptLinkRequest`
- Test: `Tests/ReTiCANodeTests/LinkPlaneTests.swift`

**Interfaces:**
- Consumes: nothing from earlier tasks.
- Produces: no signature change. `LinkPlane.acceptLinkRequest` becomes idempotent for a repeated `linkID`.

**Background:** `acceptLinkRequest` appends an element and dispatches `.acceptRequest` unconditionally. Each duplicate costs an X25519 DH, an HKDF, an Ed25519 signature with our long-term destination key, and — because `LinkPlane` does not pass `ephemeral:` — a fresh **X25519 + Ed25519 keypair generation** from the defaulted `ephemeral: Identity = Identity()`.

Duplicates are safe to drop: both ReTiCA (`ephemeral: Identity = Identity()` per attempt) and RNS (`X25519PrivateKey.generate()` in `Link.__init__`, no LINKREQUEST retransmit) mint a fresh ephemeral per attempt, so an identical `linkID` is always a replay or a multipath copy, **never a legitimate retry**.

This mirrors the pattern already established in this repo by `bd832b1` — *"dedup check before PoW in PropagationStore.ingest closes replay DoS"*. Same shape: cheap identity check before expensive crypto.

- [ ] **Step 1: Write the failing test**

Add to `Tests/ReTiCANodeTests/LinkPlaneTests.swift`:

```swift
/// F2: a replayed LINKREQUEST must not mint a second element. Duplicates share a linkID, and
/// each one costs a DH, an HKDF, an Ed25519 signature with our long-term destination key, and a
/// fresh keypair generation. A retry is never a duplicate — both we and RNS mint a fresh
/// ephemeral per attempt, so an identical linkID is always a replay or a multipath copy.
@Test @MainActor func replayedLinkRequestMintsExactlyOneElementAndOneProof() async {
    let owner = Identity()
    let initEph = Identity()
    let destHash = Data(repeating: 0x21, count: 16)
    let request = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                         destinationType: .single, context: .none, contextFlag: false, hops: 0,
                         destinationHash: destHash, transportId: nil,
                         payload: initEph.publicKey + Link.signallingBytes)
    let raw = try! request.packed()

    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"), data: raw))
    await store.receive { if case .link(.element(_, .acceptRequest)) = $0 { return true }; return false }
    #expect(store.state.links.count == 1)

    // Byte-identical replay: no new element.
    await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"), data: raw))
    #expect(store.state.links.count == 1)

    // A genuinely NEW request (different ephemeral → different linkID) still works.
    let request2 = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                          destinationType: .single, context: .none, contextFlag: false, hops: 0,
                          destinationHash: destHash, transportId: nil,
                          payload: Identity().publicKey + Link.signallingBytes)
    await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                        interfaceID: InterfaceID("i"), data: try! request2.packed()))
    await store.receive { if case .link(.element(_, .acceptRequest)) = $0 { return true }; return false }
    #expect(store.state.links.count == 2)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter replayedLinkRequestMintsExactlyOneElementAndOneProof`
Expected: FAIL at the second `#expect(store.state.links.count == 1)` — actual 2.

- [ ] **Step 3: Write minimal implementation**

In `LinkPlane.swift`, replace case `.acceptLinkRequest`:

```swift
            case let .acceptLinkRequest(owner, destinationHash, interfaceID, data):
                // DEDUPE BEFORE CRYPTO. A duplicate LINKREQUEST costs a DH, an HKDF, an Ed25519
                // signature with our long-term destination key, and — because we do not pass
                // `ephemeral:` below — a fresh keypair generation from the defaulted
                // `ephemeral: Identity = Identity()`. Transport hands LINKREQUESTs to us BEFORE
                // its seenPacketHashes dedup, so byte-identical replays arrive freely.
                //
                // Dropping a duplicate is always correct: both we and RNS mint a fresh ephemeral
                // per attempt (`Link.__init__` calls X25519PrivateKey.generate()) and neither
                // retransmits a LINKREQUEST, so an identical linkID is a replay or a multipath
                // copy — never a legitimate retry. Note HEADER_1 and relayed HEADER_2 copies of
                // the same request share a linkID (`hashablePart` excludes hops/headerType/
                // transportType/transportId), so this also collapses non-adversarial mesh
                // duplicates.
                //
                // Same shape as the dedup-before-PoW guard in `PropagationStore.ingest`.
                guard let requestPacket = Packet(raw: data) else { return .none }
                let requestLinkID = Link.linkID(requestPacket: requestPacket)
                guard !state.links.contains(where: { $0.linkID == requestLinkID }) else { return .none }
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, responderFor: owner,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID))
                return .send(.link(.element(id: newID, action: .acceptRequest(data))))
```

**Note for the implementer:** the `Packet(raw:)` guard returning `.none` is a behaviour change for unparseable input — previously an element was minted and then reaped by `LinkSession.acceptRequest`'s malformed guard. Returning `.none` before minting is strictly better (no element, no reap) and preserves the "no leak" property. `Packet.init?(raw:)` gained an ingress size ceiling in `e64f0e0`, so oversized input is rejected here too.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --no-parallel --filter replayedLinkRequestMintsExactlyOneElementAndOneProof`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `swift test --no-parallel`
Expected: 762 tests pass, 1 known issue. **Read the output.** `malformedInboundLinkRequestReapsItsElement` in `LinkPlaneTests` may now see zero elements minted for unparseable input rather than one-then-reaped. If so, that test's *property* (no leak) still holds by a stronger mechanism — update its assertions and explain in the commit message. Do not weaken it to pass.

- [ ] **Step 6: Commit**

Message subject: `fix: dedupe inbound LINKREQUESTs by linkID before doing any crypto`

---

## Task 3: `lastData` — a clock only authenticated traffic advances

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — `State`, both `init`s, and `case let .received`
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `LinkSession.State.lastData: Double?` — advanced only when a non-keepalive packet **successfully decrypts**. Task 4 sorts eviction on it.

**Background — read this carefully, it is the subtle part of the plan.** RNS maintains this distinction (`if packet.context != RNS.Packet.KEEPALIVE: self.last_data = self.last_inbound`) but assigns it **before** it decrypts. Mirroring RNS exactly would let an attacker advance `lastData` with a garbage non-keepalive packet and defeat Task 4's eviction entirely. **We take RNS's distinction and add a decryption requirement RNS does not have.**

Do **not** set `lastData` per-branch. `LinkSession.received`'s own comment records that per-branch re-arming is how a mid-transfer teardown bug got in — DATA, RESOURCE, REQUEST, RESPONSE and LINKIDENTIFY each silently omitted it. Use the single hoisted site.

- [ ] **Step 1: Write the failing test**

Add to `Tests/ReTiCATransportTests/LinkSessionTests.swift`:

```swift
/// `lastData` must advance ONLY on successfully-decrypted non-keepalive traffic. Task 4 evicts
/// on it, so if a keepalive or an undecryptable packet advanced it, an attacker could hold its
/// link at the head of the eviction order with garbage and the cap would evict legitimate links
/// instead. RNS stamps last_data BEFORE decrypting; we deliberately do not.
@Test @MainActor func lastDataAdvancesOnlyOnDecryptedNonKeepaliveTraffic() async {
    let clock = testClock()
    let store = await activeResponderStore(clock: clock)
    let established = store.state.lastData

    // 1. A plaintext keepalive must NOT advance lastData.
    let ka = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                    destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                    destinationHash: store.state.linkID, transportId: nil,
                    payload: Data([0xFF]))
    await store.send(.received(try! ka.packed()))
    #expect(store.state.lastData == established)

    // 2. An UNDECRYPTABLE non-keepalive packet must NOT advance lastData either.
    let garbage = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                         destinationType: .link, context: .none, contextFlag: false, hops: 0,
                         destinationHash: store.state.linkID, transportId: nil,
                         payload: Data(repeating: 0x00, count: 48))
    await store.send(.received(try! garbage.packed()))
    #expect(store.state.lastData == established)

    // 3. Real decrypted application data DOES advance it.
    let cipher = Link.encrypt(Data([0x01, 0x02, 0x03]), sessionKey: store.state.sessionKey)
    let dataPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                            destinationType: .link, context: .none, contextFlag: false, hops: 0,
                            destinationHash: store.state.linkID, transportId: nil, payload: cipher)
    await store.send(.received(try! dataPacket.packed()))
    await store.receive { if case .delegate(.dataReceived) = $0 { return true }; return false }
    #expect(store.state.lastData != established)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter lastDataAdvancesOnlyOnDecryptedNonKeepaliveTraffic`
Expected: FAIL to compile — `lastData` does not exist.

- [ ] **Step 3: Write minimal implementation**

**3a.** In `LinkSession.State`, add the property immediately after `lastInbound`:

```swift
        public var lastInbound: Double?
        /// Last time an AUTHENTICATED non-keepalive packet arrived — i.e. one that actually
        /// decrypted under the session key. `LinkPlane` evicts responder links in order of this
        /// clock, so it must not be advanceable by an unauthenticated peer.
        ///
        /// RNS keeps the same keepalive-vs-data distinction (`if packet.context != KEEPALIVE:
        /// self.last_data = self.last_inbound`) but stamps it BEFORE it decrypts. We deliberately
        /// diverge: without the decryption requirement, an attacker advances this with garbage and
        /// the eviction policy protects exactly the wrong links.
        public var lastData: Double?
```

**3b.** In **both** `init`s, next to `self.lastInbound = nil`, add:

```swift
            self.lastData = nil
```

**3c.** In `case let .received(data)`, introduce the authenticating decrypt helper immediately before the `func dispatch` declaration:

```swift
                // ONE copy of the "did this packet authenticate" policy. Every branch that
                // decrypts must go through this helper rather than calling `Link.decrypt`
                // directly, so that adding a new decrypting context cannot silently forget to
                // advance `lastData`. (The same reasoning as hoisting the inactivity re-arm
                // below: per-branch bookkeeping is how the mid-transfer teardown bug got in.)
                var sawAuthenticatedData = false
                func authDecrypt(_ payload: Data, _ key: Data) -> Data? {
                    guard let plain = Link.decrypt(payload, sessionKey: key) else { return nil }
                    sawAuthenticatedData = true
                    return plain
                }
                func dispatch(_ state: inout State) -> Effect<Action> {
```

**3d.** Replace **every** `Link.decrypt(packet.payload, sessionKey: state.sessionKey)` call *inside* `dispatch` with `authDecrypt(packet.payload, state.sessionKey)`.

Find them with:
```bash
grep -n "Link.decrypt" Sources/ReTiCATransport/LinkSession.swift
```
Only the calls lexically inside `dispatch` change. Leave any `Link.decrypt` outside `.received` alone.

**3e.** At the hoisted tail of `.received`, add the `lastData` stamp:

```swift
                let effect = dispatch(&state)
                // Re-arm only when the link is still active after dispatch: the LINKCLOSE branch
                // sets .closed and must not have an inactivity timer re-armed behind it.
                guard state.status == .active else { return effect }
                state.lastInbound = now
                if sawAuthenticatedData { state.lastData = now }
                return .merge(effect, inactivityTimer(state.staleTime))
```

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --no-parallel --filter lastDataAdvancesOnlyOnDecryptedNonKeepaliveTraffic`
Expected: PASS

- [ ] **Step 5: Run the full suite**

Run: `swift test --no-parallel`
Expected: 763 tests pass, 1 known issue.

- [ ] **Step 6: Commit**

Message subject: `feat: track lastData, advanced only by authenticated non-keepalive traffic`

---

## Task 4: Cap responder links, evict by `lastData` (F1)

**Files:**
- Modify: `Sources/ReTiCANode/LinkPlane.swift` — `State`, `init`, case `.acceptLinkRequest`
- Test: `Tests/ReTiCANodeTests/LinkPlaneTests.swift`

**Interfaces:**
- Consumes: `LinkSession.State.lastData` from Task 3; the dedupe guard from Task 2.
- Produces: `LinkPlane.State.maxResponderLinks: Int?` (default `256`, `nil` = unlimited).

**Background — two traps, both of which invert the fix if you get them wrong:**

1. **Cap RESPONDER links only.** A global cap with oldest-eviction lets an attacker flood us into evicting our own outbound **initiator** links — the cap becomes a DoS amplifier. Initiator links are ours and are never the attack surface.
2. **Evict on `lastData`, not `lastInbound`.** An attacker sending keepalives keeps `lastInbound` permanently fresh, so an LRU over `lastInbound` evicts quiet *legitimate* links and preserves attacker links — exactly backwards.

Eviction must emit the normal removal-triggering delegate path, not a bare `state.links.remove` — a silent removal would strand `linkResourceInFlight` in `LXMFRouter`, which is handoff item F7's bug. Do not introduce a second instance of it.

**Cap value:** `256`. Rationale: responder links are concurrent *sessions*, not peers, and a propagation node is the realistic high-water case; 256 leaves large headroom over any plausible concurrent-session count while bounding worst-case element memory. **The tests pin the policy, not the number** — they must pass for any cap ≥ 2. `nil` means unlimited; `0` means zero, not unlimited (same rule `PropagationNode` documents for its analogous limit).

- [ ] **Step 1: Write the failing test**

Add to `Tests/ReTiCANodeTests/LinkPlaneTests.swift`. **Note this test drives creation through `acceptLinkRequest` with real packets — it does not seed `state.links`, because the property claimed is about reachability.**

```swift
/// Helper: a well-formed LINKREQUEST with a fresh ephemeral (hence a fresh linkID).
private func freshLinkRequest(destHash: Data) -> Data {
    let packet = Packet(headerType: .header1, packetType: .linkRequest, transportType: .broadcast,
                        destinationType: .single, context: .none, contextFlag: false, hops: 0,
                        destinationHash: destHash, transportId: nil,
                        payload: Identity().publicKey + Link.signallingBytes)
    return try! packet.packed()
}

/// F1: responder links are capped. An attacker completes real handshakes and holds elements
/// forever, so authentication cannot bound this — only resource policy can.
@Test @MainActor func responderLinksAreCappedAndInitiatorLinksAreNeverEvicted() async {
    let owner = Identity()
    let destHash = Data(repeating: 0x31, count: 16)
    let cap = 3
    let store = TestStore(
        initialState: LinkPlane.State(maxResponderLinks: cap)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    // One of OUR outbound links. It must survive any amount of inbound pressure.
    await store.send(.openLink(initiatorTo: Identity(), destinationHash: destHash,
                               interfaceID: InterfaceID("i"), relayNextHop: nil))
    let initiatorCount = { store.state.links.filter { $0.role == .initiator }.count }
    #expect(initiatorCount() == 1)

    // Flood well past the cap with distinct, well-formed requests.
    for _ in 0 ..< (cap * 4) {
        await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                            interfaceID: InterfaceID("i"),
                                            data: freshLinkRequest(destHash: destHash)))
    }

    let responders = store.state.links.filter { $0.role == .responder }
    #expect(responders.count <= cap)
    // The DoS-amplifier trap: the flood must never cost us our own outbound link.
    #expect(initiatorCount() == 1)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter responderLinksAreCappedAndInitiatorLinksAreNeverEvicted`
Expected: FAIL to compile — `maxResponderLinks` does not exist.

- [ ] **Step 3: Write minimal implementation**

**3a.** In `LinkPlane.State`, add the property and thread it through `init`:

```swift
        public var links: IdentifiedArrayOf<LinkSession.State> = []
        public var registrations: [Data: RequestRegistration] = [:]
        /// Upper bound on concurrently-held RESPONDER links. `nil` disables the cap; `0` means
        /// zero, NOT unlimited (same rule `PropagationNode` documents for its transfer limit).
        ///
        /// Only responder links are capped. Initiator links are ours; capping them would let an
        /// inbound flood evict our own outbound links and turn the cap into a DoS amplifier.
        public var maxResponderLinks: Int?
        public init(links: IdentifiedArrayOf<LinkSession.State> = [],
                    registrations: [Data: RequestRegistration] = [:],
                    maxResponderLinks: Int? = 256) {
            self.links = links
            self.registrations = registrations
            self.maxResponderLinks = maxResponderLinks
        }
```

**3b.** In case `.acceptLinkRequest`, insert the cap between the dedupe guard from Task 2 and the append:

```swift
                guard !state.links.contains(where: { $0.linkID == requestLinkID }) else { return .none }
                // CAP. Opening a link is unauthenticated by protocol design: an attacker supplies
                // the LINKREQUEST, completes a genuine handshake with its own ephemeral, and then
                // holds a valid session key — so it can keep an element alive with perfectly
                // AUTHENTICATED keepalives forever. No authentication gate can bound this; only
                // resource policy can.
                //
                // Evict on `lastData`, never on `lastInbound`: keepalives advance `lastInbound`,
                // so an LRU over it would preserve an attacker's keepalive-fed link and evict a
                // quiet legitimate one. `lastData` only advances on traffic that decrypted.
                //
                // Evict via `.close` so the element leaves through the normal
                // `.delegate(.closed)` path that removes it and reaps its transfers. A bare
                // `state.links.remove` here would strand `LXMFRouter.linkResourceInFlight`.
                var evictions: [Effect<Action>] = []
                if let cap = state.maxResponderLinks {
                    let responders = state.links.filter { $0.role == .responder }
                    if responders.count >= cap {
                        let victims = responders
                            .sorted { ($0.lastData ?? $0.activatedAt ?? 0) < ($1.lastData ?? $1.activatedAt ?? 0) }
                            .prefix(responders.count - cap + 1)
                        for victim in victims {
                            evictions.append(.send(.link(.element(id: victim.id, action: .close))))
                        }
                    }
                }
                let newID = uuid()
                state.links.append(LinkSession.State(id: newID, responderFor: owner,
                                                     destinationHash: destinationHash,
                                                     interfaceID: interfaceID))
                return .merge(evictions + [.send(.link(.element(id: newID, action: .acceptRequest(data))))])
```

**Note for the implementer:** `LinkSession.close` guards on `status == .active`, so a victim still in `.pending`/`.handshake` will not close on this action — it will still be reaped by its own establishment deadline, but it will not free a slot immediately. That is acceptable (the cap is a bound, not a hard real-time guarantee) and it is *recorded as a known limitation in Task 8's sweep artifact*. Do not "fix" it here by removing the element directly; that reintroduces the stranding bug.

- [ ] **Step 4: Run test to verify it passes**

Run: `swift test --no-parallel --filter responderLinksAreCappedAndInitiatorLinksAreNeverEvicted`
Expected: PASS

- [ ] **Step 5: Write the eviction-ordering test — the load-bearing one**

This test must FAIL if eviction ever sorts on `lastInbound`. Without it, the subtle half of this task is unpinned.

```swift
/// The eviction ORDER is the load-bearing half of the cap. An attacker keeps `lastInbound`
/// fresh with keepalives for free; only `lastData` reflects traffic it could not forge. If
/// eviction ever sorts on `lastInbound`, this test must fail — the attacker's link would
/// survive and the quiet legitimate link would be evicted.
@Test @MainActor func evictionPrefersLinksWithNoAuthenticatedTrafficEvenIfRecentlyPinged() async {
    let destHash = Data(repeating: 0x41, count: 16)
    // attacker: pinged very recently (high lastInbound) but never carried data (nil lastData).
    var attacker = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000A1")!,
                                     responderFor: Identity(), destinationHash: destHash,
                                     interfaceID: InterfaceID("i"))
    attacker.linkID = Data(repeating: 0xA1, count: 16)
    attacker.status = .active
    attacker.activatedAt = 0
    attacker.lastInbound = 1_000
    attacker.lastData = nil

    // legitimate: quiet lately (low lastInbound) but carried real data (lastData set).
    var legit = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000B1")!,
                                  responderFor: Identity(), destinationHash: destHash,
                                  interfaceID: InterfaceID("i"))
    legit.linkID = Data(repeating: 0xB1, count: 16)
    legit.status = .active
    legit.activatedAt = 0
    legit.lastInbound = 10
    legit.lastData = 500

    let store = TestStore(
        initialState: LinkPlane.State(links: [attacker, legit], maxResponderLinks: 2)
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    await store.send(.acceptLinkRequest(owner: Identity(), destinationHash: destHash,
                                        interfaceID: InterfaceID("i"),
                                        data: freshLinkRequest(destHash: destHash)))
    // The attacker's link is the victim; the legitimate one is closed on neither count.
    await store.receive { action in
        if case let .link(.element(id, .close)) = action { return id == attacker.id }
        return false
    }
}
```

**This test seeds state deliberately** — the property under test is the *ordering comparator*, not reachability, and constructing the two clock skews through real traffic would take more machinery than it proves. Note the distinction in a comment so a future reader does not "fix" it into the reachability style.

- [ ] **Step 6: Run both tests**

Run: `swift test --no-parallel --filter LinkPlaneTests`
Expected: PASS

- [ ] **Step 7: Run the full suite**

Run: `swift test --no-parallel`
Expected: 765 tests pass, 1 known issue.

- [ ] **Step 8: Commit**

Message subject: `fix: cap responder links, evicting by least-recent authenticated data`

---

## Task 5: Move re-homing into LinkSession, gated on authentication

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — `Action.received`, `Delegate`, `case let .received`
- Modify: `Sources/ReTiCANode/LinkPlane.swift` — case `.routeLinkPacket`, new delegate handler
- Test: `Tests/ReTiCANodeTests/LinkPlaneTests.swift`, `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: `sawAuthenticatedData` from Task 3.
- Produces:
  - `LinkSession.Action.received(Data, arrivalInterface: InterfaceID? = nil)` — the default keeps the ~44 existing test call sites compiling; `nil` means "arrived on an unspecified interface, do not re-home."
  - `LinkSession.Action.Delegate.rehomed(InterfaceID)` — emitted when the session rebinds, so `LinkPlane` can re-home in-flight transfers.

**Background:** today `LinkPlane.routeLinkPacket` rebinds the element and every in-flight `ResourceTransfer` to the arrival interface **before** dispatching, driven by any inbound link packet including a plaintext keepalive. Since `linkID` is public and link packets bypass dedup, an attacker can redirect a legitimate peer's traffic to itself. The decision must move to where decryption happens.

Swift permits default values on enum case parameters (verified), so the signature change does not ripple into tests that do not care about routing.

- [ ] **Step 1: Write the failing test**

```swift
/// An authenticated packet from a new interface re-homes the link. A plaintext keepalive from a
/// new interface must NOT — that is the link-theft vector: linkID is public and link packets
/// bypass Transport's dedup, so an unauthenticated peer could otherwise redirect a legitimate
/// peer's traffic to itself.
@Test @MainActor func onlyAuthenticatedTrafficReHomesTheSession() async {
    let clock = testClock()
    let store = await activeResponderStore(clock: clock)
    let original = store.state.interfaceID
    let attacker = InterfaceID("attacker")

    // Plaintext keepalive from a NEW interface: must not move the link.
    let ka = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                    destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                    destinationHash: store.state.linkID, transportId: nil, payload: Data([0xFF]))
    await store.send(.received(try! ka.packed(), arrivalInterface: attacker))
    #expect(store.state.interfaceID == original)

    // Authenticated data from a new interface: DOES move the link.
    let peer = InterfaceID("peer-reconnected")
    let cipher = Link.encrypt(Data([0x09]), sessionKey: store.state.sessionKey)
    let dataPacket = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                            destinationType: .link, context: .none, contextFlag: false, hops: 0,
                            destinationHash: store.state.linkID, transportId: nil, payload: cipher)
    await store.send(.received(try! dataPacket.packed(), arrivalInterface: peer))
    await store.receive { if case .delegate(.dataReceived) = $0 { return true }; return false }
    #expect(store.state.interfaceID == peer)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter onlyAuthenticatedTrafficReHomesTheSession`
Expected: FAIL to compile — `received` takes one argument.

- [ ] **Step 3: Change the action signature**

```swift
        /// `arrivalInterface` is the interface the packet actually arrived on. `nil` means the
        /// caller did not specify one — the session will not re-home. Defaulted so that callers
        /// testing session logic (rather than routing) need not thread it through.
        case received(Data, arrivalInterface: InterfaceID? = nil)
```

Add to `Action.Delegate`:

```swift
            /// The session rebound to a new interface. `LinkPlane` re-homes in-flight transfers.
            case rehomed(InterfaceID)
```

- [ ] **Step 4: Implement the gated re-home**

In `case let .received`, change the pattern binding and add the re-home to the hoisted tail:

```swift
            case let .received(data, arrivalInterface):
```

and at the tail, replacing the Task 3 version:

```swift
                let effect = dispatch(&state)
                guard state.status == .active else { return effect }
                state.lastInbound = now
                var extra: [Effect<Action>] = []
                if sawAuthenticatedData {
                    state.lastData = now
                    // RE-HOME, gated on authentication. A BLE peer that reconnects gets a new
                    // InterfaceID by construction, so the binding taken at creation goes stale and
                    // outbound would fire at a dead interface. But re-homing on UNAUTHENTICATED
                    // input is link theft: linkID is public and link packets bypass Transport's
                    // dedup, so anyone could redirect a legitimate peer's traffic to themselves.
                    // Only a packet that decrypted proves the sender holds the session key.
                    //
                    // The idle-BLE-reconnect case, where the only inbound traffic is plaintext
                    // keepalives, is covered by the one-shot permission a LOCAL interface
                    // disconnect grants (see `rehomePermitted`).
                    if let arrival = arrivalInterface, arrival != state.interfaceID {
                        state.interfaceID = arrival
                        extra.append(.send(.delegate(.rehomed(arrival))))
                    }
                }
                return .merge([effect, inactivityTimer(state.staleTime)] + extra)
```

- [ ] **Step 5: Strip the unconditional re-home from LinkPlane and forward the delegate**

Replace case `.routeLinkPacket` in `LinkPlane.swift` (deleting the whole re-home block and its now-obsolete comment):

```swift
            case let .routeLinkPacket(linkID, arrivalInterface, data):
                guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
                // Re-homing is decided INSIDE LinkSession, after decryption — see its `.received`
                // handler. Routing by cleartext linkID is addressing, not authentication, so this
                // layer must not move the binding.
                return .send(.link(.element(id: element.id,
                                            action: .received(data, arrivalInterface: arrivalInterface))))
```

Add the delegate handler alongside the other `link(.element(...))` cases:

```swift
            case let .link(.element(elementID, .delegate(.rehomed(interfaceID)))):
                // ResourceTransfer.State.interfaceID is a snapshot taken at creation and every
                // transfer transmit uses that stored copy, so a transfer running when the peer
                // reconnects would keep firing parts, hashmap updates, proofs and cancels at the
                // dead interface.
                for tid in state.links[id: elementID]?.transfers.ids ?? [] {
                    state.links[id: elementID]?.transfers[id: tid]?.interfaceID = interfaceID
                }
                return .none
```

- [ ] **Step 6: Update the pre-existing re-home tests**

These four tests in `LinkPlaneTests.swift` assert the OLD unconditional behaviour and seed state:
`linkPacketFromANewInterfaceReHomesTheSession`, `linkPacketFromTheSameInterfaceLeavesTheSessionUnchanged`, `reHomingDoesNotDisturbOtherSessions`, `linkPacketFromANewInterfaceReHomesSessionAndItsTransfers`.

They send an unencrypted `payload` and expect a rebind, which is now exactly the behaviour we forbid. **Do not delete them and do not weaken them.** Rewrite each to drive an authenticated packet through an established session, keeping the property each one names.

First add this helper to `LinkPlaneTests.swift` — it drives a real handshake through the plane so the tests stop seeding a fake session and gain a usable session key:

```swift
/// Drives a full responder handshake through the plane and returns (elementID, linkID,
/// sessionKey) for an ACTIVE session on `interfaceID`. Real handshake, not seeded state — the
/// session key has to be genuine for the re-home tests to send authenticated traffic.
@MainActor
private func activeResponderInPlane(
    _ store: TestStore<LinkPlane.State, LinkPlane.Action>,
    owner: Identity, destHash: Data, interfaceID: InterfaceID
) async -> (id: UUID, linkID: Data, sessionKey: Data) {
    await store.send(.acceptLinkRequest(owner: owner, destinationHash: destHash,
                                        interfaceID: interfaceID,
                                        data: freshLinkRequest(destHash: destHash)))
    await store.receive { if case .link(.element(_, .acceptRequest)) = $0 { return true }; return false }
    let element = store.state.links.first { $0.role == .responder && $0.status == .handshake }!
    let rttCipher = Link.encrypt(MsgPack.encode(0.0), sessionKey: element.sessionKey)
    let rtt = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                     destinationType: .link, context: .linkRequestRTT, contextFlag: false, hops: 0,
                     destinationHash: element.linkID, transportId: nil, payload: rttCipher)
    await store.send(.routeLinkPacket(linkID: element.linkID, arrivalInterface: interfaceID,
                                      data: try! rtt.packed()))
    await store.receive { if case .delegate(.linkEstablished) = $0 { return true }; return false }
    return (element.id, element.linkID, element.sessionKey)
}

/// Builds an authenticated application-data packet for an established link.
private func authenticatedPacket(linkID: Data, sessionKey: Data, body: Data) -> Data {
    let cipher = Link.encrypt(body, sessionKey: sessionKey)
    let packet = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                        destinationType: .link, context: .none, contextFlag: false, hops: 0,
                        destinationHash: linkID, transportId: nil, payload: cipher)
    return try! packet.packed()
}
```

Then rewrite the first test to this shape; apply the same transformation to the other three, keeping each one's original name and the property in its doc comment:

```swift
/// A BLE InterfaceID is derived from the peer's session token, so a reconnected peer is a
/// different interface and the link's stored binding is stale. Re-homing still happens — but
/// now ONLY for traffic that authenticated (see `onlyAuthenticatedTrafficReHomesTheSession`
/// for the negative case).
@Test @MainActor func linkPacketFromANewInterfaceReHomesTheSession() async {
    let ifOld = InterfaceID("old")
    let ifNew = InterfaceID("new")
    let destHash = Data(repeating: 0x01, count: 16)
    let store = TestStore(initialState: LinkPlane.State()) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let session = await activeResponderInPlane(store, owner: Identity(),
                                               destHash: destHash, interfaceID: ifOld)
    #expect(store.state.links[id: session.id]?.interfaceID == ifOld)

    let raw = authenticatedPacket(linkID: session.linkID, sessionKey: session.sessionKey,
                                  body: Data([0x01, 0x02]))
    await store.send(.routeLinkPacket(linkID: session.linkID, arrivalInterface: ifNew, data: raw))
    await store.receive { if case .delegate(.linkDataReceived) = $0 { return true }; return false }
    #expect(store.state.links[id: session.id]?.interfaceID == ifNew)
}
```

Transformation notes for the remaining three:

- `linkPacketFromTheSameInterfaceLeavesTheSessionUnchanged` — same setup, send the authenticated packet on `ifOld`, assert the binding is unchanged. Property (no churn on the common/TCP case) is preserved.
- `reHomingDoesNotDisturbOtherSessions` — build **two** sessions via `activeResponderInPlane` on different interfaces, re-home only the first, assert the second's `interfaceID` is untouched.
- `linkPacketFromANewInterfaceReHomesSessionAndItsTransfers` — this one's property is now enforced by the **`rehomed` delegate handler**, so it is the end-to-end proof that the handler is wired. After establishing, start a transfer with `.sendResourceOverLink`, then re-home with an authenticated packet and assert every `transfers[id:]?.interfaceID` moved. If this test passes with the `rehomed` handler deleted, it is not proving the wiring — check that during Task 7's mutation pass.

- [ ] **Step 7: Run the full suite**

Run: `swift test --no-parallel`
Expected: all pass, 1 known issue. **Read the output.**

- [ ] **Step 8: Commit**

Message subject: `fix: re-home a link only on authenticated input, deciding it inside LinkSession`

---

## Task 6: A local interface disconnect grants one re-home

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` — `State`, both `init`s, re-home condition
- Modify: `Sources/ReTiCANode/LinkPlane.swift` — new `Action.interfaceDisconnected`
- Modify: `Sources/ReTiCANode/BLEEndpoint.swift`, `Sources/ReTiCANode/TCPEndpoint.swift` — fan out
- Test: `Tests/ReTiCANodeTests/LinkPlaneTests.swift`

**Interfaces:**
- Consumes: the re-home gate from Task 5.
- Produces: `LinkSession.State.rehomePermitted: Bool`; `LinkPlane.Action.interfaceDisconnected(InterfaceID)`.

**Background:** Task 5 closed theft but stranded the idle-BLE-reconnect case — a reconnected peer whose only traffic is plaintext keepalives never re-homes, and our outbound fails into a `sendFailed` that nothing consumes. A **local** disconnect is unforgeable by a remote attacker and always precedes a BLE reconnect, so it is a safe trigger. The permission is **one-shot**: it clears on the re-home it authorises, so one disconnect buys one rebind rather than permanently downgrading the element.

- [ ] **Step 1: Write the failing test**

```swift
/// A LOCAL interface disconnect grants ONE unauthenticated re-home, so an idle BLE link whose
/// peer reconnects is not stranded on a dead interface. An attacker cannot forge a local
/// disconnect. The permission is one-shot: a second unauthenticated move must not follow.
@Test @MainActor func localDisconnectGrantsExactlyOneUnauthenticatedReHome() async {
    let dead = InterfaceID("dead")
    let reconnected = InterfaceID("reconnected")
    let attacker = InterfaceID("attacker")
    let linkID = Data(repeating: 0x51, count: 16)
    var session = LinkSession.State(id: UUID(uuidString: "00000000-0000-0000-0000-0000000000C1")!,
                                    responderFor: Identity(),
                                    destinationHash: Data(repeating: 0x05, count: 16),
                                    interfaceID: dead)
    session.linkID = linkID
    session.status = .active

    let store = TestStore(
        initialState: LinkPlane.State(links: [session])
    ) { LinkPlane() } withDependencies: {
        $0.uuid = .incrementing
        $0.continuousClock = TestClock()
        $0.date = .constant(Date(timeIntervalSince1970: 0))
    }
    store.exhaustivity = .off

    let keepalive = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                           destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                           destinationHash: linkID, transportId: nil, payload: Data([0xFF]))
    let kaRaw = try! keepalive.packed()

    // Without a disconnect, an unauthenticated keepalive must not move the link.
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: attacker, data: kaRaw))
    #expect(store.state.links[id: session.id]?.interfaceID == dead)

    // A local disconnect grants the permission; the next keepalive re-homes.
    await store.send(.interfaceDisconnected(dead))
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: reconnected, data: kaRaw))
    #expect(store.state.links[id: session.id]?.interfaceID == reconnected)

    // One-shot: a further unauthenticated keepalive from elsewhere must NOT move it again.
    await store.send(.routeLinkPacket(linkID: linkID, arrivalInterface: attacker, data: kaRaw))
    #expect(store.state.links[id: session.id]?.interfaceID == reconnected)
}
```

- [ ] **Step 2: Run test to verify it fails**

Run: `swift test --no-parallel --filter localDisconnectGrantsExactlyOneUnauthenticatedReHome`
Expected: FAIL to compile — `interfaceDisconnected` is not a `LinkPlane` action.

- [ ] **Step 3: Add the flag to LinkSession**

In `State`, after `lastData`:

```swift
        /// Set by a LOCAL interface disconnect: permits ONE re-home from an unauthenticated
        /// packet, because a reconnected BLE peer's only traffic on an idle link is a plaintext
        /// keepalive. A remote attacker cannot forge a local disconnect. One-shot by design —
        /// it clears on the re-home it authorises, so a disconnect does not permanently downgrade
        /// this element to unauthenticated re-homing.
        public var rehomePermitted: Bool = false
```

Set `self.rehomePermitted = false` in both `init`s alongside `self.lastData = nil`.

- [ ] **Step 4: Widen the re-home condition**

In `.received`'s hoisted tail, replace the Task 5 re-home block so the permission is honoured **outside** the `sawAuthenticatedData` branch:

```swift
                let effect = dispatch(&state)
                guard state.status == .active else { return effect }
                state.lastInbound = now
                if sawAuthenticatedData { state.lastData = now }
                var extra: [Effect<Action>] = []
                // Re-home on authenticated input, OR once on a local-disconnect permission.
                if let arrival = arrivalInterface, arrival != state.interfaceID,
                   sawAuthenticatedData || state.rehomePermitted {
                    state.rehomePermitted = false          // one-shot
                    state.interfaceID = arrival
                    extra.append(.send(.delegate(.rehomed(arrival))))
                }
                return .merge([effect, inactivityTimer(state.staleTime)] + extra)
```

- [ ] **Step 5: Add the LinkPlane action**

Action case, next to `routeLinkPacket`:

```swift
        /// A local interface went away. Grants each link bound to it ONE unauthenticated re-home
        /// so a reconnected peer is not stranded — see `LinkSession.State.rehomePermitted`.
        case interfaceDisconnected(InterfaceID)
```

Handler:

```swift
            case let .interfaceDisconnected(interfaceID):
                for id in state.links.ids where state.links[id: id]?.interfaceID == interfaceID {
                    state.links[id: id]?.rehomePermitted = true
                }
                return .none
```

- [ ] **Step 6: Fan out from both endpoints**

In `BLEEndpoint.swift`, case `.ble(.delegate(.peerOffline(token)))`, add to `effects`:

```swift
                    .send(.linkPlane(.interfaceDisconnected(id))),
```

In `TCPEndpoint.swift`, case `.interface(.connectionEvent(.disconnected))`:

```swift
            case .interface(.connectionEvent(.disconnected)):
                return .merge(.send(.transport(.interfaceDisconnected(id))),
                              .send(.linkPlane(.interfaceDisconnected(id))),
                              .send(.transport(.stopMaintenance)))
```

**Verify the case name** for the link-plane scope in each endpoint before editing:
```bash
grep -n "case linkPlane\|Scope(state: \\\\.linkPlane" Sources/ReTiCANode/BLEEndpoint.swift Sources/ReTiCANode/TCPEndpoint.swift
```

- [ ] **Step 7: Run the test, then the full suite**

Run: `swift test --no-parallel --filter localDisconnectGrantsExactlyOneUnauthenticatedReHome`
Expected: PASS

Run: `swift test --no-parallel`
Expected: all pass, 1 known issue.

- [ ] **Step 8: Commit**

Message subject: `feat: a local interface disconnect grants one unauthenticated re-home`

---

## Task 7: Interop guard and mutation verification

**Files:**
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: everything above. Adds no production code.

**Background:** the single largest risk in this slice is that a future "hardening" edit gates keepalive inactivity refresh on authentication. That would break interop with real RNS peers, because RNS keepalives are unencrypted **by explicit design** (`Packet.pack` has a dedicated `elif self.context == Packet.KEEPALIVE:` branch, commented *"Keepalive packets contain no actual data"*). An idle RNS peer sends only keepalives; refusing to refresh on them tears the link down. Pin the non-change.

- [ ] **Step 1: Write the interop guard test**

```swift
/// INTEROP GUARD — pins a deliberate NON-change. RNS keepalives are unencrypted by explicit
/// design (`Packet.pack` has a dedicated KEEPALIVE branch: "Keepalive packets contain no actual
/// data"). A peer on an otherwise-idle link sends nothing else, so a plaintext keepalive MUST
/// keep refreshing the inactivity clock. Gating that refresh on authentication would tear down
/// links with real RNS peers — and would not bound anything anyway, since an attacker holds a
/// valid session key and can send authenticated keepalives.
@Test @MainActor func plaintextKeepaliveStillRefreshesInactivity() async {
    let clock = testClock()
    let store = await activeResponderStore(clock: clock)
    let stale = store.state.staleTime

    // Advance to just under the stale deadline, then ping with an UNAUTHENTICATED keepalive.
    await clock.advance(by: .seconds(stale * 0.9))
    let ka = Packet(headerType: .header1, packetType: .data, transportType: .broadcast,
                    destinationType: .link, context: .keepalive, contextFlag: false, hops: 0,
                    destinationHash: store.state.linkID, transportId: nil, payload: Data([0xFF]))
    await store.send(.received(try! ka.packed()))
    _ = await captureTransmit(store)                       // 0xFE reply

    // Advance again by the same amount. Without the refresh the link would already be gone.
    await clock.advance(by: .seconds(stale * 0.9))
    #expect(store.state.status == .active)
}
```

- [ ] **Step 2: Run it**

Run: `swift test --no-parallel --filter plaintextKeepaliveStillRefreshesInactivity`
Expected: PASS immediately (it pins existing behaviour).

- [ ] **Step 3: Full suite, green**

Run: `swift test --no-parallel`
Expected: all pass, 1 known issue. **Read the output and record the exact count.**

- [ ] **Step 4: Batch-mutate the production code**

Apply ALL of these at once, then run the suite ONCE:

1. `LinkSession` `(.responder, .handshake, .data, .linkRequestRTT)`: change `else { return .none }` back to `else { return .send(.delegate(.establishmentFailed(.handshakeRejected))) }`
2. `LinkPlane.acceptLinkRequest`: delete the `guard !state.links.contains(where:...)` dedupe line
3. `LinkSession.authDecrypt`: delete `sawAuthenticatedData = true`
4. `LinkPlane.acceptLinkRequest` eviction sort: change `($0.lastData ?? $0.activatedAt ?? 0)` to `($0.lastInbound ?? 0)` on both sides
5. `LinkPlane.acceptLinkRequest`: change `responders.count >= cap` to `responders.count >= Int.max`
6. `LinkSession` re-home condition: change `sawAuthenticatedData || state.rehomePermitted` to `true`
7. `LinkSession` re-home: delete `state.rehomePermitted = false`
8. `LinkPlane`: delete the body of the `.delegate(.rehomed)` handler, leaving `return .none`

- [ ] **Step 5: Run the suite and verify EVERY targeted test fails**

Run: `swift test --no-parallel`

Expected failures, one per mutation:
1. `garbageRTTDoesNotReapTheResponderElement`
2. `replayedLinkRequestMintsExactlyOneElementAndOneProof`
3. `lastDataAdvancesOnlyOnDecryptedNonKeepaliveTraffic`
4. `evictionPrefersLinksWithNoAuthenticatedTrafficEvenIfRecentlyPinged`
5. `responderLinksAreCappedAndInitiatorLinksAreNeverEvicted`
6. `onlyAuthenticatedTrafficReHomesTheSession`
7. `localDisconnectGrantsExactlyOneUnauthenticatedReHome`
8. `linkPacketFromANewInterfaceReHomesSessionAndItsTransfers`

**If any of these still passes, that test is not testing what it claims.** Fix the test, revert the mutations, and restart from Step 3. Do not proceed.

Mutation 8 matters specifically: it is the only check that the `rehomed` delegate is actually *wired*. Task 5 moved transfer re-homing from an inline loop into a delegate hop, and a delegate that nothing consumes is a failure mode this repo has shipped before (`sendFailed` is emitted at five causes and consumed by nobody).

- [ ] **Step 6: Revert every mutation and confirm green**

Run: `git diff` to confirm the working tree matches the committed state, then `swift test --no-parallel`.
Expected: all pass, 1 known issue, same count as Step 3.

- [ ] **Step 7: Commit**

Message subject: `test: pin the plaintext-keepalive interop guard`

Include the mutation-testing results in the commit body — which mutation broke which test.

---

## Task 8: The unauthenticated-input sweep

**Files:**
- Create: `docs/superpowers/2026-08-13-unauthenticated-link-element-sweep.md`

**Interfaces:**
- Consumes: all prior tasks (so the sweep records post-fix state).
- Produces: the artifact, plus new numbered items appended to the handoff.

**Background:** F1, F2 and F6 were three instances of one pattern. Three instances means the pattern is systemic, not that we found them all — the same lesson the wire-narrowing work recorded. This task is where the remaining instances get found, not hoped about.

- [ ] **Step 1: Enumerate the branches**

Read `LinkSession.swift`, `LinkPlane.swift` and `Transport.swift`. For **every** branch reachable from inbound network data, record what unauthenticated input can cause, against the four verbs:

- **CREATE** a link element
- **EXTEND** its life (timer re-arm, status revival)
- **RE-HOME** it (interface rebind, transfer rebind)
- **DESTROY** it (removal, `.closed`, `.establishmentFailed`)

Write the artifact as a table: branch (by SYMBOL, not line) → reachable by unauthenticated input? → which verb → verdict (safe / fixed in this slice / **open**).

- [ ] **Step 2: Start from these known-open items**

These were identified during review and are NOT fixed by this slice:

- `LinkSession.acceptRequest`'s **empty-session-key guard is remotely reachable** via an all-zeros X25519 key (the degenerate-point trick the initiator-side tests already use). Its element-reaping behaviour is untested.
- `LinkSession.close` on a non-`.active` link is a **silent no-op**, so Task 4's eviction cannot free a slot held by a `.pending`/`.handshake` element; that element leaves only at its establishment deadline.
- `LinkSession`'s `.handshakeRejected` labels on the responder-gated sites remain unpinned (mutating them leaves the suite green).

- [ ] **Step 3: Write throwaway probes for anything reasoning cannot settle**

The decisive findings in the last several slices came from probes, not reasoning. Put probes in a scratch directory, not in `Tests/`. Do not leave them in the repo.

- [ ] **Step 4: Append findings to the handoff**

Add any **open** item to `docs/superpowers/2026-08-10-handoff-link-lifecycle-and-delivery-termination.md` as a new numbered item (F9 onwards — IDs are stable, do not renumber), and update its §3 priority list.

- [ ] **Step 5: Commit**

```bash
git add docs/superpowers/2026-08-13-unauthenticated-link-element-sweep.md \
        docs/superpowers/2026-08-10-handoff-link-lifecycle-and-delivery-termination.md
```

Message subject: `docs: sweep every branch where unauthenticated input drives link-element lifecycle`

---

## Final verification

- [ ] `swift test --no-parallel` — all pass, 1 known issue. **Read the output.**
- [ ] `git log --format='%(trailers:key=Claude-Session)' -8` — every commit's trailer parses (non-empty).
- [ ] The spec's §5 test list is fully covered: F6 ✓ (T1), dedupe ✓ (T2), cap ✓ (T4), eviction order ✓ (T4), `lastData` decryption ✓ (T3), re-home ✓ (T5/T6), interop guard ✓ (T7).
- [ ] Request a whole-branch review. It has found a real defect on 10/10 consecutive slices, always in a seam no single diff shows. Ask it STRUCTURAL questions — who consumes the `rehomed` delegate, what bounds the eviction loop, trace an injected keepalive through production wiring rather than the reducer, construct the adversarial packet sequence — and give it licence to write throwaway probes. Budget for a fix wave after it.
