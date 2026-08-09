# BLE Link Re-homing — Design

**Status:** approved 2026-08-09.
**Follows:** the BLE outbound drop-visibility slice (`1d12fa6..4d7ed2e`), which made this defect observable without fixing it.

## The defect

A `LinkSession` binds `interfaceID` **once at creation** (`LinkSession.swift:30`) and reads it at 20+ outbound transmit sites. On BLE an `InterfaceID` is derived from the peer's 16-byte HELLO session token (`bleInterfaceID(token)`), so **a reconnecting peer is a different interface by construction** — the tokens are unrelated random values.

When a peer cycles:

1. `peerOffline` clears `peerInterfaces` for the old ID (`BLEEndpoint.swift:134-135`); `peerOnline` registers a new one.
2. The link's stored `interfaceID` now names a dead interface. Every outbound transmit hits the `peerInterfaces` guard and — since the drop-visibility slice — reports `sendFailed(.interfaceUnavailable)` instead of vanishing.
3. **Inbound still works.** `Transport` emits `.linkPacket(linkID:data:)` and `LinkPlane` routes purely by `linkID` (`LinkPlane.swift:94-96`), never consulting the interface.

So the link is **half-alive**: receiving normally, transmitting into the void, until the ~60 s inactivity watchdog closes it (`staleTime = keepaliveInterval * 2`, `LinkSession.swift:62`). On a phone, where BLE peers cycle constantly, this breaks direct-mode LXMF and propagation sync in ordinary use.

The asymmetry is the key: inbound routing is already interface-agnostic and correct. Only the outbound binding goes stale — and the information needed to repair it arrives on every inbound packet, where `Transport` currently discards it.

## Approach

**Thread the arrival interface through `linkPacket`, and re-home on receipt.**

`Transport.Action.Delegate.linkPacket(linkID:data:)` gains `arrivalInterface: InterfaceID`, mirroring its sibling `linkRequest(destinationHash:arrivalInterface:data:)` (`Transport.swift:177`) which already carries it for exactly this class of reason. `Transport` has the value in scope at the emission site.

Re-homing happens in **`LinkPlane.routeLinkPacket`**, which already resolves the session by `linkID`:

```swift
case let .routeLinkPacket(linkID, data):
    guard let element = state.links.first(where: { $0.linkID == linkID }) else { return .none }
    return .send(.link(.element(id: element.id, action: .received(data))))
```

It updates that element's `interfaceID` when the arrival differs, then forwards `.received(data)` unchanged. No new `LinkSession` action, and none of the 20+ sites reading `state.interfaceID` change — they simply start reading a current value.

### Alternatives rejected

- **Re-home from `peerOnline`.** `BLEEndpoint` cannot know the new token corresponds to the same device as the old one — the tokens are unrelated randoms and the HELLO carries no stable identity. Would require identity correlation we do not have.
- **Fall back to "any live peer" on an outbound miss.** Wrong under multi-peer: a link's traffic would go to an arbitrary peer. Also unauthenticated.

## Why this is safe (and where it is not)

- **Re-homing follows link addressing, not link authentication.** The gate here is cleartext addressing only: `destinationType == .link` and `destinationHash == linkID`. Decryption and validation happen downstream in `LinkSession.received`, which may still reject the packet — by which time the interface has already moved. Consequently:
  - **No replay protection.** Link traffic deliberately bypasses `seenPacketHashes` (`Transport.swift:283-285`), so a captured link packet re-injected from another interface re-homes the link. In a multi-peer mesh a duplicate arriving over a second peer does the same non-adversarially.
  - **RNS divergence.** RNS gates delivery on interface match (`RNS/Transport.py:2166-2187`) and handles endpoint re-appearance via a stable `tunnel_id` exchanged in the interface handshake — the stable identity the rejected-alternatives section notes we lack.
  - **Keepalive wrinkle blocks the obvious fix.** Keepalives are plaintext `0xFF`/`0xFE` byte compares (`LinkSession.swift:309-310, 534`), so on an idle link the only inbound packet available to re-home from is one that does not authenticate. Gating re-homing on successful decryption would therefore break the idle-link recovery case — this is a real design decision, not a one-liner, and is deferred.
- **TCP is provably inert.** `TCPEndpoint` uses one fixed `InterfaceID` (`TCPEndpoint.swift:22`), so the arrival always equals the stored value and the assignment is a no-op. This is asserted, not assumed.
- **Recovery window is narrower than originally stated, and recovery is one-sided.**
  - `staleTime = keepaliveInterval * 2` (`LinkSession.swift:62`) is reset only by **inbound** traffic, and the timer runs through the outage untouched. The real budget is `60 s − (elapsed since last inbound at disconnect)` — anywhere from 60 s down to ~0, not a fixed 60 s margin.
  - Keepalives are **initiator-only**: `guard state.status == .active, state.role == .initiator` (`LinkSession.swift:533`). A responder speaks only in reply.
  - Recovery is therefore structurally one-sided. The side whose session token changed (call it X) can still transmit; the other side can only re-home when X sends. If X is the **initiator**, its 30 s keepalive re-homes the peer (the case the E2E test covers). If X is the **responder**, it never sends unprompted — the initiator's keepalives go to the dead interface, neither side receives, and both die at the watchdog. Responder-side reconnect does not self-heal without app traffic. This is the honest scope of what this slice delivers.

## Known boundary (deliberate, not a gap)

Re-homing repairs **on receipt**. A link created on an interface that dies before any inbound packet arrives cannot self-repair, and will still close at the watchdog. That is correct: there is no authenticated signal to re-home from, and the alternative — guessing — is the rejected "any live peer" approach. Recorded so it is a stated boundary rather than a later discovery.

## Reframing a previously-recorded finding

The sibling issue **"`peerOffline` doesn't proactively close links"** is hereby **resolved by design, not deferred**. It was only attractive while a reconnect was fatal to the link. With re-homing, proactively closing on `peerOffline` would destroy exactly the link this design teaches the system to recover. Do not implement it.

## Scope

In:
1. `linkPacket` carries `arrivalInterface`; `LinkPlane` re-homes on a differing arrival.
2. **Proof that re-homing actually eliminates the failure** — a test driving a full BLE peer cycle (peer online → link established → peer offline → peer online under a NEW token → inbound packet) asserting that outbound traffic now reaches the new peer and that `sendFailed(.interfaceUnavailable)` does NOT fire. This uses the diagnostic from the previous slice as the instrument rather than requiring a consumer for it.

### Not wiring a `sendFailed` consumer — corrected scope

The previous slice's review recommended wiring one, and I initially carried that forward. Investigation changed the answer:

- `LXMFRouter` has `retryDue`/`deliveryFailed` but no `sendFailed` input; its retry is purely timer-driven. Feeding `.interfaceUnavailable` into it would be a **behaviour** change, not a diagnostic one — and an unthrottled one, since a stale binding emits one `sendFailed` per outbound packet including every keepalive and resource part.
- `.interfaceUnavailable` is **BLE-specific**: `TCPEndpoint`'s equivalent guard is structurally unreachable with a single fixed `InterfaceID`.
- **`ReTiCaMsgr` is TCP-only** — it constructs `TCPEndpoint.State` and contains no `BLEEndpoint` reference at all.

So any consumer wired today could never fire in production. That is speculative plumbing, which this project has explicitly refused before. The honest position: `sendFailed` is *consumable* at the `TransportEndpoint` boundary, no production consumer exists, and one should be added when an app actually adopts BLE — at which point the consumer's behaviour can be designed against real requirements instead of guessed. Recorded rather than silently skipped.

Out:
- `FCBDriverAdapter`'s `try?` swallowing L2CAP write errors (needs a new `BLEDriverEvent`; mechanism layer).
- The `BLEInterface` no-channel window recorded in the previous slice: `state.peers` clears synchronously while `peerOffline` propagates as an effect, so there is a one-action-hop window (N hops on adapter loss / `.stop`) where both layers drop silently. Re-homing does not address it; it remains a recorded residue.
- Notifying a link so it can close or retry early. Re-homing is expected to make this largely moot; revisit only with evidence.
- **Staleness of `learned[dest].interfaceID` (sibling defect, not fixed here).** `Transport` captures the arrival interface from the announce (`Transport.swift:414`) and replaces it only when a strictly-newer announce arrives (`shouldReplace`). It is never purged by `interfaceDisconnected`. After a peer restarts, until its next announce, opportunistic sends go to a dead interface and a new link cannot be opened at all — the LINKREQUEST is dropped, `establishmentDeadline` fires, and `linkFailed` is surfaced. This is distinct from the link re-homing fix (which operates on already-established links) and is deferred.
