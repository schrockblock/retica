# LXMF Propagation P2b — Client Sync Endpoint Glue — Design

**Date:** 2026-07-31
**Status:** Approved (design)

## Context

Second half of P2 (client sync/receive). P2a built the decoupled two-phase
`/get` download state machine in `LXMFRouter`. **P2b** wires it to real
transport in `LXMFNode`: trigger sync → `IDENTIFY` + phase-1 list request →
offer → phase-2 get request → receive `lxmf_data` blobs → open (decrypt with
the client identity) → deliver via the existing `received(.direct)` path.

No MsgPack change is needed — `MsgPackValue.null` (0xC0) already exists, so
`[None, None]` encodes as `.array([.null, .null])`.

## Scope

**In scope:** the client-side transport glue — `syncFromPropagationNode`
trigger, IDENTIFY + two `/get` request/response round-trips, msgpack
encode/decode of the request/response payloads, opening the returned blobs,
and feeding delivery + `messagesDownloaded` back to the router. Plus one small
symmetric core helper (`LXMFPropagation.recoverPacked`).

**Out of scope / deferred:**
- **Stamped-message transient_id correlation.** RNS strips a 32-byte stamp
  before serving a blob, so for stamped messages the client's recomputed
  `transientId(blob)` would not match the PN's offered id. Documented
  follow-on; unstamped messages (the common case now, and our test) match
  exactly.
- One sync at a time per link (no concurrent syncs on one link).
- `max_messages` cap, `retain_synced_on_node`, have-set bounding (P2a-deferred).
- The PN server itself (P3) — the test uses a bare-`Endpoint` stub where the
  test plays the server's response logic.

## Architecture

### Core helper: `LXMFPropagation.recoverPacked`

```swift
/// Recover the packed LXMF wire bytes (destinationHash ‖ decrypted tail) from one container/download
/// entry, decrypting the tail with `recipientIdentity`. Nil if malformed or decryption fails. The
/// symmetric inverse of `pack`'s encryption step; `open` is `unpack(recoverPacked(...))`.
public static func recoverPacked(lxmfData: Data, recipientIdentity: Identity) -> Data? {
    guard let destHash = destinationHash(lxmfData: lxmfData) else { return nil }
    let encrypted = Data(lxmfData.dropFirst(LXMessage.destinationLength))
    guard let tail = recipientIdentity.decrypt(encrypted) else { return nil }
    return destHash + tail
}
```

`open` refactors to:

```swift
public static func open(lxmfData: Data, recipientIdentity: Identity) -> LXMessage? {
    guard let packed = recoverPacked(lxmfData: lxmfData, recipientIdentity: recipientIdentity) else { return nil }
    return LXMessage.unpack(packed)
}
```

Keeping the decrypt-to-packed step in `LXMFPropagation` (where `pack`/`open`
live) lets `LXMFNode` feed the existing `router.received(.direct, …)` path
without re-implementing decryption and without a double-unpack.

### `LXMFNode` state + trigger

```swift
public enum SyncPhase: Equatable { case awaitingList, awaitingMessages }
public var syncPhase: [Data: SyncPhase] = [:]   // linkID → current download phase (one sync/link)
```

```swift
case syncFromPropagationNode   // → .send(.router(.syncFromPropagationNode))
```

`setPropagationNode` already exists (P1). The router's
`syncFromPropagationNode` establishes/reuses the PN link and emits
`requestMessageList` when active (P2a).

### Wires

Request path constant: `"/get"` (RNS `LXMPeer.MESSAGE_GET_PATH`).

```swift
// Phase-1: IDENTIFY then request the message list. Identify is listed first so its link packet
// precedes the request (in-order link delivery → PN sets remote identity before handling /get).
case let .router(.delegate(.requestMessageList(linkID))):
    state.syncPhase[linkID] = .awaitingList
    return .merge(
        .send(.endpoint(.identifyOverLink(linkID: linkID, identity: state.identity))),
        .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/get",
                                             data: MsgPack.encode(.array([.null, .null]))))))

// Phase-2: request the wanted messages (and report haves for purge). 2-element form; RNS treats
// the transfer-limit third element as optional.
case let .router(.delegate(.requestMessages(linkID, wants, haves))):
    state.syncPhase[linkID] = .awaitingMessages
    let payload = MsgPack.encode(.array([.array(wants.map { .bin($0) }),
                                         .array(haves.map { .bin($0) })]))
    return .send(.endpoint(.sendRequestOverLink(linkID: linkID, path: "/get", data: payload)))

// Response: dispatch by the per-link phase.
case let .endpoint(.delegate(.responseReceived(linkID, _, data))):
    switch state.syncPhase[linkID] {
    case .awaitingList:
        guard case let .array(items)? = MsgPack.decodeValue(data) else { return .none }
        let ids = items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
        return .send(.router(.offeredMessageList(transientIds: ids)))
    case .awaitingMessages:
        state.syncPhase[linkID] = nil
        guard case let .array(items)? = MsgPack.decodeValue(data) else { return .none }
        let blobs = items.compactMap { if case let .bin(d) = $0 { return d } else { return nil } }
        var effects: [Effect<Action>] = []
        var tids: [Data] = []
        for blob in blobs {
            tids.append(LXMFPropagation.transientId(lxmfData: blob))
            if let packed = LXMFPropagation.recoverPacked(lxmfData: blob, recipientIdentity: state.identity) {
                effects.append(.send(.router(.received(method: .direct, destinationHash: Data(), data: packed))))
            }
        }
        effects.append(.send(.router(.messagesDownloaded(transientIds: tids))))
        return .merge(effects)
    case .none:
        return .none
    }
```

(Placed among the existing translations, before the `.endpoint, .router,
.delegate` catch-all. `responseReceived` was previously unhandled → `.none`.)

### Data flow

```
A.syncFromPropagationNode → router: establish PN link → requestMessageList(linkID)
  → A: identifyOverLink + sendRequestOverLink("/get", [null,null])
  → PN: requestReceived → (serves) → responseReceived([ids])
  → A (.awaitingList): router.offeredMessageList(ids) → router: requestMessages(linkID, wants, haves)
  → A: sendRequestOverLink("/get", [wants, haves])
  → PN: requestReceived → (serves) → responseReceived([blobs])
  → A (.awaitingMessages): recoverPacked(blob) → router.received(.direct) → messageReceived;
    messagesDownloaded(tids); clear syncPhase
```

## Testing

### Task 1 — `recoverPacked` unit test (core)

`pack(message, recipientIdentity: R, timestamp) → (packed container-less entry)`
is hedged; build an entry via `pack`, take its single container entry, and
assert `recoverPacked(entry, recipientIdentity: R)` reproduces the original
`message.packed`, and `open(entry, R)` still recovers the message
(`validateSignature` true). Mutation: corrupt the recipient identity → nil.

### Task 2 — `LXMFNode` sync integration test

Two stores: client `A` (`LXMFNode`) + PN stub (bare `Endpoint`; the test plays
the server). Identities: A (client/recipient), S (sender). A learns the PN's
`lxmf.propagation` path/identity and S's `lxmf.delivery` identity (bridged
announces). Pre-build `blob = pack(LXMessage.create(source: S, destinationHash:
aDeliveryHash, …), recipientIdentity: aIdentity).container entry`, with
`tid = transientId(blob)`.

Flow: `A.setPropagationNode(pnHash)`; `A.syncFromPropagationNode` → link
handshake A↔PN → A sends IDENTIFY + phase-1 `/get`; bridge to PN; on the PN
stub's `requestReceived`, the test replies `sendResponseOverLink(linkID,
requestID, MsgPack([.bin(tid)]))`; bridge back → A sends phase-2 `/get`; on the
next `requestReceived`, the test replies `sendResponseOverLink(…,
MsgPack([.bin(blob)]))`; bridge back. Assert A emits
`.delegate.messageReceived` with S's `content`/`title`/`sourceHash`,
`signatureValidated == true` (A learned S), and
`a.state.router.downloadedTransientIds.contains(tid)`. Models the
request/response over-link bridge on `EndpointTests`/`LinkSessionRequestTests`;
reuses the link-handshake bridge from the direct/propagation tests.

Mutation verification, one at a time (e.g. drop the phase-2 `requestMessages`
wire → no phase-2 request → no delivery; break the `recoverPacked` feed → no
`messageReceived`). Each must break the covering test, then revert to green.

## Known Limitations (P2b)

- Stamped-message transient_id correlation deferred (see Scope).
- One sync at a time per link.
- Opening requires the client identity (has it) and, for validation, the
  sender's identity learned via announce (as with every receive path).
