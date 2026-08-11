# Link Elements Are Always Reaped Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** A `LinkSession` element that can never make progress is always removed from `LinkPlane.state.links`. Closes a remotely-triggerable unbounded-growth leak: today a malformed inbound LINKREQUEST appends an element that nothing ever reaps.

**Architecture:** No new mechanism. `LinkSession` already has a delegate that means "this session is over and cannot recover" — `establishmentFailed` — and `LinkPlane` already removes the element on it. The dead-end paths just return `.none` instead of emitting it. Make them emit it.

**Tech Stack:** Swift 6 / TCA / swift-testing. Repo: `/Users/ell/development/ios/pods/ReTiCA`.

## The leak, verified end to end

`LinkPlane.acceptLinkRequest` appends the element **before** dispatching the work:

```swift
case let .acceptLinkRequest(owner, destinationHash, interfaceID, data):
    let newID = uuid()
    state.links.append(LinkSession.State(id: newID, responderFor: owner, ...))   // LinkPlane.swift:110-114
    return .send(.link(.element(id: newID, action: .acceptRequest(data))))
```

`LinkSession.acceptRequest` bails to `.none` on a malformed request:

```swift
case let .acceptRequest(data):
    guard state.role == .responder, state.status == .pending,
          let packet = Packet(raw: data), packet.packetType == .linkRequest,
          (packet.payload.count == 64 || packet.payload.count == 67),
          let owner = state.owningIdentity
    else { return .none }                                    // LinkSession.swift:236-240
```

`LinkPlane` removes elements at exactly two sites — `:209` (on `.closed`) and `:214` (on `.establishmentFailed`). Both require a delegate. `.none` emits nothing, so **the element is permanent**.

**Remotely reachable.** `TCPEndpoint.swift:141-146` forwards any inbound `.linkRequest` addressed to a destination we own, with no payload validation:

```swift
case let .transport(.delegate(.linkRequest(destHash, _, data))):
    guard let owner = state.transport.localDestinations[destHash]?.identity,
          owner.privateKey != nil
    else { return .none }
    return .send(.linkPlane(.acceptLinkRequest(...)))
```

So anyone who has heard our announce can send LINKREQUEST packets with a wrong-sized payload and grow `state.links` without bound. `LinkPlane.routeLinkPacket` linear-scans `state.links` (`first(where:)`) for every inbound link packet, so the cost is not just memory.

`BLEEndpoint` has the same forwarding shape — check it and treat it identically.

**Matching initiator-side leak.** `LinkSession.establish` returns `.none` if `packet.packed()` throws, **before** arming the establishment timer, while `LinkPlane.swift:104` has already appended the element. Effectively unreachable for a 67-byte LINKREQUEST (`packed()` throws only on a non-16-byte hash or MTU overflow), but it is the same defect and a one-line fix.

## Why the fix is small

The previous slice added a `role == .initiator` gate on `LinkPlane`'s `linkFailed` emission, with element removal kept **unconditional**:

```swift
case let .link(.element(elementID, .delegate(.establishmentFailed(kind)))):
    guard let session = state.links[id: elementID] else { return .none }
    state.links.remove(id: elementID)          // unconditional — the leak-prevention half
    guard session.role == .initiator else { return .none }
    ...
```

So a **responder** emitting `.establishmentFailed` reaps its element and emits no delegate at all. That is exactly the behaviour a malformed inbound request needs. The mechanism already exists; the dead-end paths simply do not use it.

## Global Constraints

- Commit directly to `main`. No branches, merges, rebases, resets.
- **You are the implementer, NOT the controller. Do NOT invoke the `superpowers:subagent-driven-development` skill or run any of its scripts.**
- The user commits CONCURRENTLY. `git add` ONLY the files each task names — never `-A`, never `.`.
- **One command per Bash invocation** — no `|`, `&&`, `||`, `;`, `$(...)`, `xargs`, no inline interpreter scripts. Redirect output to a file under `/tmp/ReTiCA/` and read it.
- **Read the suite output file before asserting a result.** "I ran it" is not "I read it" — an implementer on the previous slice reported a count before reading the file.
- Commit trailers MUST start at column 0:
```
Co-Authored-By: Claude Fable 5 <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01119muaq7gzADhfuNznkZEd
```
- Baseline: **758/758 serially** at HEAD `ba090d5`, 1 known issue (`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`). Use `swift test --no-parallel`; parallel runs flake `PNNode*`, `LXMFNodeSync*`, `twoEndpointsTransferMultiSegmentResourceOverALink`, `pairedModePublishesWithEncryptionAndEncryptedReadPerms`. Classify with `--filter` before reporting a failure.
- **If a PRE-EXISTING test fails, STOP and report — do not fix it.**

## Verification discipline

A claim of the form "only X does Y" or "nothing reaches Z" needs a `grep -rn` over `Sources/`, not a look at the file already open. Nine property claims went wrong on this project this month, every one of them checked in a single place and false somewhere else.

Cite **symbols**, not line numbers, for same-repo cross-file references — line citations here have drifted five times, once invalidated by the very commit that wrote them.

## TestStore traps (all have bitten this project)

1. **Effect-produced state is invisible via `store.state` until drained.** `#expect(store.state.links.isEmpty)` right after a send reads PRE-effect state and passes even with the production code deleted. This exact assertion was vacuous on the previous slice. Assert via ordered exhaustive `receive`, or drain first.
2. **`.on` semantics.** Teardown reads exhaustivity AT CALL TIME, so a trailing `.on` DOES catch strays — but it also asserts no in-flight effects. Flipping back to `.off` before teardown disables the teardown check.
3. **Do not seed the state you claim to prove.**

---

### Task 1: A malformed inbound LINKREQUEST reaps its element

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` (the `.acceptRequest` guard)
- Test: `Tests/ReTiCANodeTests/LinkPlaneTests.swift` (element lifecycle) and/or `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: `LinkSession.Action.Delegate.establishmentFailed(EstablishmentFailure)`, and `LinkPlane`'s unconditional element removal + `role == .initiator` delegate gate. Both already exist.
- Produces: nothing new.

- [ ] **Step 1: Write the failing test**

The load-bearing assertion is that the element is GONE, and that no `linkFailed` delegate escapes (the sender is a responder, so reporting our own served destination as an unreachable peer would be wrong).

```swift
/// A malformed inbound LINKREQUEST must not leave a permanent element behind. `LinkPlane`
/// appends the session BEFORE dispatching `.acceptRequest`, and removal happens only on a
/// delegate — so a guard that bails to `.none` leaks the element forever. Remotely triggerable:
/// any peer that has heard our announce can send wrong-sized payloads and grow `state.links`
/// without bound, which `routeLinkPacket` then linear-scans on every inbound packet.
@Test @MainActor func malformedInboundLinkRequestReapsItsElement() async {
    // Drive .acceptLinkRequest through LinkPlane with a LINKREQUEST whose payload is neither
    // 64 nor 67 bytes (e.g. 10). Assert store.state.links is empty AFTER draining — not via a
    // bare #expect right after the send, which reads pre-effect state.
    // Assert NO .linkFailed delegate escapes (responder role).
    // Cover more than one malformed shape: unparseable bytes, wrong packetType, wrong payload size.
}
```

Read the existing `LinkPlaneTests` element-lifecycle tests first and follow their harness.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter malformedInboundLinkRequestReapsItsElement`
Expected: FAIL — `state.links` still holds the element.

- [ ] **Step 3: Implement**

Split the guard so INTERNAL invariants still return `.none` (a misrouted action is a bug here, not a peer's doing) while PEER-CONTROLLED validation failures reap the element:

```swift
case let .acceptRequest(data):
    // Internal invariants: reaching here in the wrong role/status means the action was
    // misrouted, not that a peer sent garbage. Leave the element alone.
    guard state.role == .responder, state.status == .pending, let owner = state.owningIdentity
    else { return .none }
    // Everything below is PEER-CONTROLLED. A malformed request must reap the element, or it
    // lives forever: LinkPlane appends before dispatching and removes only on a delegate.
    // `.establishmentFailed` is the existing "over, cannot recover" signal, and LinkPlane's
    // role gate means a RESPONDER emitting it removes the element without reporting a
    // spurious linkFailed for our own served destination.
    guard let packet = Packet(raw: data), packet.packetType == .linkRequest,
          (packet.payload.count == 64 || packet.payload.count == 67)
    else { return .send(.delegate(.establishmentFailed(.handshakeRejected))) }
    ...
```

Keep the rest of the case unchanged. Confirm `owningIdentity` is genuinely internal (it comes from `LinkPlane.acceptLinkRequest`'s `owner` parameter, which the endpoint sourced from `localDestinations`) — if it can be nil for a peer-controlled reason, move it below the split and say so.

- [ ] **Step 4: Run to verify it passes**

Run: `swift test --filter LinkPlane`
Expected: pass; existing element-lifecycle tests unaffected.

- [ ] **Step 5: Check the BLE path**

`BLEEndpoint` forwards inbound link requests too. Read it, confirm it has the same shape, and state in your report whether the fix covers it (it should — the fix is in `LinkSession`, below both endpoints). If BLE reaches `acceptLinkRequest` by a different route, say so.

- [ ] **Step 6: Full suite**

Run: `swift test --no-parallel > /tmp/ReTiCA/reap-task1.txt 2>&1` then READ the file.
Expected: 759/759 (or higher if you added several tests), 1 known issue.

- [ ] **Step 7: Mutation verification**

Revert the guard split (bail to `.none` again) → the new test must fail on the element still being present. Report verbatim. Restore; green.

- [ ] **Step 8: Commit**

Write `/tmp/ReTiCA/reap-task1-msg.txt` (subject `fix: a malformed inbound LINKREQUEST no longer leaks its link element`), `git add` the files you touched, `git commit -F`.

---

### Task 2: An initiator that cannot pack its LINKREQUEST reaps its element

**Files:**
- Modify: `Sources/ReTiCATransport/LinkSession.swift` (the `.establish` case)
- Test: `Tests/ReTiCATransportTests/LinkSessionTests.swift`

**Interfaces:**
- Consumes: the same `establishmentFailed` machinery. Here the role IS `.initiator`, so a `linkFailed` delegate WILL be emitted — which is correct: the caller asked to open a link and it cannot happen.

- [ ] **Step 1: Write the failing test**

```swift
/// An initiator that cannot pack its LINKREQUEST must not leave a permanent element behind.
/// `.establish` returns `.none` if `packed()` throws, BEFORE arming the establishment timer —
/// so nothing ever reaps the element that `LinkPlane.openLink` already appended. Effectively
/// unreachable for a well-formed 67-byte request (`packed()` throws only on a non-16-byte hash
/// or MTU overflow), but it is the same defect as the responder path and the only remaining
/// route with no terminus.
@Test @MainActor func initiatorThatCannotPackItsLinkRequestReapsItsElement() async {
    // Construct the pack failure through real state — a destinationHash that is not 16 bytes is
    // the documented trigger. If that cannot be driven without seeding invalid state, say so
    // in your report rather than faking it; a test that seeds the failure proves less.
}
```

**If you cannot construct this failure honestly, STOP and report.** Do not fabricate a scenario. It is legitimate to conclude the path is unreachable and that the fix is defensive — but then say that plainly, and make the production change anyway with a comment recording that no test drives it and why.

- [ ] **Step 2: Run to verify it fails**

Run: `swift test --filter initiatorThatCannotPackItsLinkRequestReapsItsElement`

- [ ] **Step 3: Implement**

In `.establish`, replace the `.none` return on `packed()` failure with:

```swift
guard let raw = try? packet.packed()
else { return .send(.delegate(.establishmentFailed(.handshakeRejected))) }
```

Consider whether `.handshakeRejected` is the honest label — no handshake was rejected; we could not even send. If neither existing case fits, say so in your report rather than forcing one. **Do not add a new `EstablishmentFailure` case without flagging it**, because `LinkPlane`'s mapping is an exhaustive switch precisely so a new case is a compile error and a routing decision, not a silent default.

- [ ] **Step 4: Run to verify it passes**

- [ ] **Step 5: Full suite**

Run: `swift test --no-parallel > /tmp/ReTiCA/reap-task2.txt 2>&1` then READ the file.

- [ ] **Step 6: Mutation verification**

Revert to `.none` → the test must fail (if a test exists; if the path proved undrivable, state that no mutation barrier exists and why).

- [ ] **Step 7: Commit**

Write `/tmp/ReTiCA/reap-task2-msg.txt` (subject `fix: an unpackable LINKREQUEST no longer leaks its link element`), `git add`, `git commit -F`.

---

## Final verification (after Task 2)

- [ ] `swift test --no-parallel` — read the file, report the exact count.
- [ ] `grep -n "return .none" Sources/ReTiCATransport/LinkSession.swift` — for EACH remaining `.none` return, state whether the element can still be reaped afterwards. This is the completeness check the whole slice rests on: a `.none` that leaves a session unable to progress and unable to be removed is the same bug in a different place.
- [ ] Confirm `LinkPlane` still removes elements at exactly two sites and that removal remains unconditional at both.
- [ ] `git log --format='%(trailers:key=Claude-Session)' -2` — both commits' trailers parse.
