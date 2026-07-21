# Link ↔ Resource Integration — Design

**Status:** Approved (design phase)
**Date:** 2026-07-21
**Depends on:** 6a (Resource primitives), 6b (ResourceTransfer state machine), 6c (windowing/retransmit/cancellation), and the existing Link↔Endpoint integration (LinkSession hosted in Endpoint).

## Goal

Make resource transfers usable end-to-end through the public `Endpoint` API: a consumer can send a
resource over an established link and receive one on the other side, with the full 6a–6c transfer
machinery (windowing, retransmission, cancellation) driven automatically. This slice adds **routing and
lifecycle wiring only** — no new wire formats.

## Scope

**In scope**

1. `ResourceTransfer` instances hosted inside `LinkSession` (`transfers: IdentifiedArrayOf<...>` via
   `.forEach`), link-scoped like the resource protocol itself.
2. Inbound RESOURCE_* routing in `LinkSession.received`: spawn a receiver transfer on an inbound
   RESOURCE_ADV (deduped by resource hash), and route other RESOURCE_* packets to the hosted transfers.
3. New delegate cases surfaced from `LinkSession` and re-exposed by `Endpoint`
   (`resourceReceived`/`resourceConcluded`/`resourceFailed`).
4. A public send path: `Endpoint.sendResourceOverLink(linkID:data:)` → `LinkSession.sendResource(data)`
   → spawn a sender transfer + advertise.
5. A new `RandomBytes` dependency (live = `SecRandomCopyBytes`, test = deterministic stub) for the
   sender's 4-byte `prefix` and `randomHash`.
6. Unit tests at the LinkSession and Endpoint levels, plus a two-`Endpoint` end-to-end transfer.

**Explicitly deferred (out of scope)**

- Transfer garbage collection — terminal (`.complete`/`.failed`) transfers persist in the array,
  mirroring the existing no-teardown policy for closed `LinkSession` elements.
- MTU/SDU negotiation — the sender uses a constant SDU (the RNS default).
- Multi-segment (6d) and compression (6e).
- Hardening for many concurrent transfers on one link (the broadcast-routing design supports it, but it
  is not stress-tested here).

## Architecture

`LinkSession` becomes the parent of its resource transfers (all resource packets are `linkID`-scoped,
and `LinkSession.State` already holds `linkID`/`sessionKey`/`interfaceID`/`rtt`). `Endpoint` re-surfaces
the new link delegates exactly as it re-surfaces `dataReceived` today. `Transport` and the interface are
untouched. Outbound resource transmits reuse `LinkSession`'s existing `.delegate(.transmit(...))` path,
which `Endpoint` already forwards to the interface — so **no Endpoint change is needed for outbound**.

### New dependency: `RandomBytes`

New file `Sources/ReTiCATransport/RandomBytesDependency.swift`:

```
public struct RandomBytesGenerator: Sendable {
    public var generate: @Sendable (Int) -> Data
    public func callAsFunction(_ count: Int) -> Data { generate(count) }
}

extension DependencyValues {
    public var randomBytes: RandomBytesGenerator { get set }
}
```

- **liveValue:** `SecRandomCopyBytes`-backed (`import Security`), returning `count` cryptographically
  random bytes.
- **testValue / previewValue:** a deterministic stub (e.g. `Data((0..<count).map { UInt8($0 & 0xff) })`)
  so tests are reproducible. The specific bytes never affect wire compatibility — the resource
  hash/map-hash algorithms were cross-validated in 6a regardless of the prefix/randomHash values.

`RandomBytesGenerator` lives in `ReTiCATransport` (where `LinkSession` consumes it). `Endpoint`
(`ReTiCANode`) does not use it directly.

## LinkSession changes (`Sources/ReTiCATransport/LinkSession.swift`)

- **State:** add `public var transfers: IdentifiedArrayOf<ResourceTransfer.State> = []`.
- **Dependencies:** add `@Dependency(\.uuid) var uuid` and `@Dependency(\.randomBytes) var randomBytes`.
- **body:** add `.forEach(\.transfers, action: \.transfer) { ResourceTransfer() }` alongside the existing
  reducer composition, before the `Reduce` intercept layer.
- **Action:** add
  - `case transfer(IdentifiedActionOf<ResourceTransfer>)`
  - `case sendResource(Data)`
  - Delegate additions: `case resourceReceived(Data)`, `case resourceConcluded(Data)`,
    `case resourceFailed(Data)` (the `Data` on concluded/failed is the resource hash).
- **SDU constant:** `static let resourceSDU = 464` (RNS default `Packet.MDU`); MTU negotiation deferred.

### Inbound routing (in the `switch (role, status, packetType, context)` inside `.received`)

Add, before `default`:

- **`(_, .active, .data, .resourceAdvertisement)`** — decrypt + unpack to read the advertised hash;
  dedup and spawn:
  ```
  guard let plain = Link.decrypt(packet.payload, sessionKey: state.sessionKey),
        let adv = ResourceAdvertisement.unpack(plain) else { return .none }
  if state.transfers.contains(where: { $0.resourceHash == adv.hash }) { return .none }  // re-advertise
  let newID = uuid()
  let rtt: Duration = .seconds(state.rtt ?? 1)
  state.transfers.append(ResourceTransfer.State(
      receivingOn: state.linkID, sessionKey: state.sessionKey,
      interfaceID: state.interfaceID, rtt: rtt, id: newID))
  state.transfers[id: newID]?.resourceHash = adv.hash   // set NOW so dedup is race-free vs the async .accept
  return .send(.transfer(.element(id: newID, action: .accept(data))))
  ```
  **Dedup race note:** `resourceHash` is set synchronously at spawn (the line above), NOT deferred to the
  `.accept` effect. `.accept` is dispatched as a `.send` effect and processes on a later store step, so a
  re-advertised ADV arriving before `.accept` runs must still find the in-flight transfer — hence the
  hash is written into the appended element immediately. `.accept` re-derives and writes the same hash
  (idempotent).
- **`(_, .active, .data, .resource)`**, **`.resourceRequest`**, **`.resourceProof`**,
  **`.resourceInitiatorCancel`**, **`.resourceReceiverCancel`** — broadcast the raw packet to every hosted
  transfer; each transfer self-filters by resource hash / map-hash, so a non-matching transfer is a
  no-op:
  ```
  return .merge(state.transfers.ids.map { .send(.transfer(.element(id: $0, action: .received(data)))) })
  ```

### Delegate interception (in the `Reduce` intercept layer, mirroring the `dataReceived` idiom)

- `.transfer(.element(_, .delegate(.transmit(ifID, raw))))` → `.send(.delegate(.transmit(ifID, raw)))`.
- `.transfer(.element(_, .delegate(.received(data))))` → `.send(.delegate(.resourceReceived(data)))`.
- `.transfer(.element(id, .delegate(.concluded)))` → look up `state.transfers[id: id]?.resourceHash` →
  `.send(.delegate(.resourceConcluded(hash)))`.
- `.transfer(.element(id, .delegate(.failed)))` → look up the hash → `.send(.delegate(.resourceFailed(hash)))`.

### Public send action

- **`.sendResource(Data)`** — guard `status == .active`; otherwise `.none`. Then:
  ```
  let r = Data(randomBytes(8))
  let prefix = Data(r[r.startIndex ..< r.startIndex + 4])
  let randomHash = Data(r[r.startIndex + 4 ..< r.startIndex + 8])
  let newID = uuid()
  state.transfers.append(ResourceTransfer.State(
      sending: data, linkID: state.linkID, sessionKey: state.sessionKey,
      interfaceID: state.interfaceID, prefix: prefix, randomHash: randomHash,
      sdu: Self.resourceSDU, rtt: .seconds(state.rtt ?? 1), id: newID))
  return .send(.transfer(.element(id: newID, action: .advertise)))
  ```

## Endpoint changes (`Sources/ReTiCANode/Endpoint.swift`)

- **Action:** add `case sendResourceOverLink(linkID: Data, data: Data)`.
- **Delegate:** add `case resourceReceived(linkID: Data, data: Data)`,
  `case resourceConcluded(linkID: Data, resourceHash: Data)`,
  `case resourceFailed(linkID: Data, resourceHash: Data)`.
- **Reduce:**
  - `.sendResourceOverLink(linkID, data)` → find the element by `linkID` (linear scan, as with
    `linkPacket` routing); dispatch `.link(.element(id: element.id, action: .sendResource(data)))`; no
    matching active link → `.none`.
  - Intercept the three new link delegates and re-surface, looking up `linkID` from the element (exactly
    as `.dataReceived` → `.linkDataReceived` does today):
    - `.link(.element(id, .delegate(.resourceReceived(data))))` → `.delegate(.resourceReceived(linkID:data:))`
    - `.link(.element(id, .delegate(.resourceConcluded(hash))))` → `.delegate(.resourceConcluded(linkID:resourceHash:))`
    - `.link(.element(id, .delegate(.resourceFailed(hash))))` → `.delegate(.resourceFailed(linkID:resourceHash:))`
  - Outbound transmits already bubble up via the existing `.link(.element(_, .delegate(.transmit(txID,
    raw))))` intercept — no new outbound handling.

## Data flow (end-to-end)

1. Consumer sends `Endpoint.sendResourceOverLink(linkID, data)`.
2. Endpoint → `LinkSession.sendResource(data)` → spawn sender transfer + `.advertise`.
3. The sender's `.delegate(.transmit)` bubbles transfer → LinkSession → Endpoint → interface (RESOURCE_ADV).
4. The peer's `Transport` delivers the ADV; peer `Endpoint` routes it to the peer `LinkSession.received`.
5. The `resourceAdvertisement` case spawns a receiver transfer + `.accept` → emits RESOURCE_REQ (same
   bubble-up path).
6. Parts / proof flow through the same routing; the receiver assembles → `.delegate(.received(data))` →
   `LinkSession.resourceReceived` → `Endpoint.resourceReceived(linkID:data:)`.
7. The receiver's RESOURCE_PRF reaches the sender; the sender validates → `.delegate(.concluded)` →
   `LinkSession.resourceConcluded(hash)` → `Endpoint.resourceConcluded(linkID:resourceHash:)`.

## Error handling

- `sendResource` on a non-active link → `.none` (no transfer created).
- A duplicate RESOURCE_ADV (the sender re-advertising per 6c) is deduped by resource hash — no second
  receiver transfer.
- Transfer timeout / cancellation / assembly failure (all handled inside `ResourceTransfer` per 6b/6c) →
  `.delegate(.failed)` → surfaced as `resourceFailed(linkID:resourceHash:)`.
- Malformed/non-matching resource packets are ignored by the transfers' own content guards.

## Testing

- **`RandomBytes` dependency:** the test stub is deterministic; a small unit test pins its output so the
  spawned transfer's hashes are reproducible.
- **LinkSession-level (`TestStore`):**
  - `sendResource` on an active link spawns a sender transfer and emits an encrypted RESOURCE_ADV.
  - An inbound RESOURCE_ADV spawns a receiver transfer and emits a RESOURCE_REQ.
  - A second (duplicate) RESOURCE_ADV for the same hash does NOT spawn a second transfer (dedup).
  - An inbound RESOURCE part routes to the hosted receiver (advances it).
  - The three new delegates (`resourceReceived`/`resourceConcluded`/`resourceFailed`) are emitted when a
    hosted transfer emits the corresponding child delegate.
- **Endpoint-level (`TestStore`):** `sendResourceOverLink` dispatches to the correct link element;
  `resourceReceived`/`resourceConcluded`/`resourceFailed` surface with the correct `linkID`.
- **End-to-end:** two `Endpoint`s (mirroring `twoEndpointsEstablishLinkExchangeDataAndClose`) establish a
  link, then transfer a multi-part resource end-to-end — the receiver surfaces the exact original bytes
  and the sender concludes.
  - *Timer note:* a link's keepalive/inactivity timers and its transfers' watchdogs share one
    `continuousClock` per store. The E2E drives packet routing directly and does NOT advance the clock
    (and/or configures a long keepalive interval) so link and resource timers do not interfere — the same
    discipline the 6c/link-watchdog tests used.
- **No new wire fixtures:** the integration adds routing only; every RESOURCE_* byte format was already
  cross-validated in 6a–6c. (The `SecRandomCopyBytes` live path is not cross-validated — randomness
  quality is not a wire-format concern.)
- Every new/changed test is verified by the project's mutation-testing discipline.

## Known simplifications (carry to review)

- Non-ADV resource packets are broadcast to all hosted transfers (each self-filters) rather than routed
  by a targeted scan — simplest correct approach; the common case is one transfer per link.
- `resourceConcluded`/`resourceFailed` are keyed by resource hash (not the transfer's UUID) at the public
  boundary, since a consumer identifies a resource by its hash, not an internal element id.
- Terminal transfers are not garbage-collected (mirrors the existing closed-link policy).
- SDU is a constant (RNS default); MTU negotiation is deferred.
