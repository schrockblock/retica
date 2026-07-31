# LXMF Propagation P2a — Router Download State Machine — Design

**Date:** 2026-07-31
**Status:** Approved (design)

## Context

Second part of the propagation glue (P2 = client sync/receive). The real RNS
LXMF download is a **two-phase offer/get** exchange on the PN's `lxmf.propagation`
`/get` request path (LXMF `LXMRouter.request_messages_from_propagation_node` /
`message_list_response`, `LXMPeer.MESSAGE_GET_PATH = "/get"`):

1. Client `IDENTIFY`s, then `request("/get", [None, None])` → PN returns the
   **list of transient_ids** addressed to this client.
2. Client computes `wants` (ids it lacks) + `haves` (ids it has, to purge),
   then `request("/get", [wants, haves, transfer_limit])` → PN returns a
   **list of `lxmf_data` blobs** (each with the 32-byte stamp stripped), which
   the client opens with its own identity and delivers.

The decoupled `LXMFRouter` currently exposes only a single
`requestMessageDownload(linkID)` signal — insufficient for two phases. **P2a**
builds the two-phase state machine in the router (decoupled, unit-testable).
**P2b** (next slice) wires it to real transport in `LXMFNode` (IDENTIFY +
request/response + open → `received`).

## Scope

**In scope (P2a):** the router-side two-phase state machine — sync trigger →
phase-1 list request → wants/haves computation → phase-2 get request →
downloaded-transient-id tracking. Pure reducer logic; no transport, no
decryption, no msgpack.

**Out of scope:** IDENTIFY, request/response transport, msgpack encode/decode
of `[None,None]`/`[wants,haves,limit]`, and **opening/decrypting** the
downloaded blobs — all P2b (the app has the identity; the router never sees
plaintext). Also deferred: `max_messages` cap, `retain_synced_on_node`
(always-purge default), bounding of the have-set.

## Architecture

### State

```swift
/// Client "have" set: transient_ids already downloaded from a PN. Drives the wants/haves split
/// on the next offer (wants = offered we lack; haves = offered we have → PN purges). Unbounded for
/// now (bounding is future, like `seen`).
public var downloadedTransientIds: Set<Data> = []
```

### Rename (phase-1 clarity)

`Action.Delegate.requestMessageDownload(linkID: Data)` →
`requestMessageList(linkID: Data)`. Disambiguates the phase-1 list request from
the new phase-2 `requestMessages`. The `syncFromPropagationNode` handler and
the `linkEstablished` drain (via `pendingDownloadFromPN`) emit the renamed
delegate; their behavior is unchanged. Three existing `LXMFRouterTests` update
to the new name (assertions unchanged).

### New actions

```swift
case offeredMessageList(transientIds: [Data])   // app feeds the phase-1 response
case messagesDownloaded(transientIds: [Data])   // app reports phase-2 ids after opening
```

**`offeredMessageList(transientIds)`** — computes the split and drives phase-2:

```swift
case let .offeredMessageList(offered):
    guard !offered.isEmpty else { return .none }            // empty offer → sync done
    let wants = offered.filter { !state.downloadedTransientIds.contains($0) }
    let haves = offered.filter { state.downloadedTransientIds.contains($0) }
    guard let pn = state.outboundPropagationNode,
          case let .active(linkID) = state.directLinks[pn] else { return .none }  // link gone → abort
    return .send(.delegate(.requestMessages(linkID: linkID, wants: wants, haves: haves)))
```

Order note: `wants`/`haves` preserve the offered order (RNS builds them by
iterating the offered list); use `filter` on `offered` (not set operations) to
keep that order deterministic.

**`messagesDownloaded(transientIds)`** — records the have-set:

```swift
case let .messagesDownloaded(transientIds):
    state.downloadedTransientIds.formUnion(transientIds)
    return .none
```

Delivery of the actual messages is P2b: the app opens each blob and calls the
existing `received(method: .direct, destinationHash: Data(), data: packed)` —
the router dedups by `message.hash` and validates as usual.

### New delegate

```swift
case requestMessages(linkID: Data, wants: [Data], haves: [Data])   // phase-2 get
```

### Wire policy pinned in the reducer

Matching RNS `message_list_response`: `wants` = offered ids the client lacks;
`haves` = offered ids the client has (→ PN purges them). Defaults for P2a: no
`max_messages` cap (want all), always-purge (no `retain_synced_on_node`). Both
are future config, not this slice.

## Testing

Unit tests in `LXMFRouterTests` (no Endpoint):

1. **Phase-1 trigger (renamed):** `syncFromPropagationNode` with an active PN
   link → `requestMessageList(linkID)`. (Existing tests, delegate renamed.)
2. **Offer → full wants:** `offeredMessageList([id1, id2])` with nothing
   downloaded, active PN link → `requestMessages(linkID, wants: [id1, id2],
   haves: [])`.
3. **Offer with a have:** after `messagesDownloaded([id1])`,
   `offeredMessageList([id1, id2])` → `requestMessages(linkID, wants: [id2],
   haves: [id1])` — proves the have-set moves an id from wants to haves.
4. **Empty offer → done:** `offeredMessageList([])` emits no `requestMessages`
   (flip `exhaustivity = .on` last to catch a stray).
5. **No active PN link → abort:** `offeredMessageList([id1])` with no active PN
   link emits no `requestMessages`.

Mutation verification, one at a time (e.g. invert the `wants`/`haves` filter
predicate; drop the `formUnion` in `messagesDownloaded`). Each must break its
covering test, then revert to green.

## Known Limitations (P2a)

- No `max_messages` cap; always-purge (no `retain_synced_on_node`); `have`-set
  unbounded — all future config.
- Opening/decryption, transport, and msgpack are P2b.
