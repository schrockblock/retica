# LXMF Propagation P3b — PNNode Server Composition — Design

**Date:** 2026-07-31
**Status:** Approved (design)

## Context

P3b is the first **server-role composition**: a new `PNNode` reducer wiring
`Endpoint` + `PropagationNode` (P3a) to real transport so a propagation node
registers/announces `lxmf.propagation`, ingests clients' containers, and serves
the two-phase `/get` download. It closes the store-and-forward loop against the
P1 (client send) and P2 (client sync) client paths.

## Scope

**In scope:** the `PNNode` composition — registration + `PNAnnounce` announce;
`resourceReceived → ingestContainer`; `linkIdentified →` per-link client
identity; the `/get` request dispatch (phase-1/phase-2) to the P3a serve
actions with response correlation; two test tasks (injected-delegate unit
tests + a 2-store real-transport integration test).

**Out of scope / deferred:**
- The full 3-store loop (real P1 `LXMFNode` sender → `PNNode` → real P2
  `LXMFNode` recipient) — a capstone follow-on.
- `transfer_limit`/`max_messages` capping; `retain_synced_on_node`.
- P3c propagation-accept confirmation (separate small client slice).
- Packet (non-resource) container ingest — our client always sends the
  container as a Resource (P1), so ingest wires `resourceReceived` only.

## Architecture

### Why serve via unregistered-surface (not `registerRequestHandler`)

A **registered** path auto-responds through the Endpoint's static
`requestResponder` `@Dependency` (Endpoint.swift:209-214), which cannot read
the reducer's `state.node.store` — unsuitable for a store-dependent `/get`. An
**unregistered** path surfaces `requestReceived` to the app (Endpoint.swift:
202-204). So `PNNode` does **not** register `/get`; it handles the surfaced
`requestReceived` and computes the dynamic response. `/get` is ALLOW_ALL in
RNS, so no policy gating is lost; `PNNode` performs the identity check itself.

### State

```swift
@ObservableState
public struct State: Equatable {
    public var endpoint: Endpoint.State
    public var node: PropagationNode.State
    public var identity: Identity
    public var clientIdentities: [Data: Identity] = [:]   // linkID → IDENTIFY'd client
    public var pendingGet: [Data: PendingGet] = [:]        // client delivery hash → (linkID, requestID)
    public init(identity: Identity, endpoint: Endpoint.State, storageLimitBytes: Int? = nil) { … node = PropagationNode.State(storageLimitBytes:) … }
}
public struct PendingGet: Equatable { public var linkID: Data; public var requestID: Data }
```

### Actions / Delegate

```swift
case endpoint(Endpoint.Action)
case node(PropagationNode.Action)
case registerPropagation
case delegate(Delegate)
public enum Delegate: Equatable {
    case messagesStored(transientIds: [Data])   // observability: a client's container was ingested
}
```

### Body (Scope + translations)

```swift
Scope(state: \.endpoint, action: \.endpoint) { Endpoint() }
Scope(state: \.node, action: \.node) { PropagationNode() }
Reduce { state, action in
  switch action {
  case .registerPropagation:
      guard let d = Destination(kind: .single, direction: .in, appName: LXMessage.appName,
                                aspects: ["propagation"], identity: state.identity) else { return .none }
      let appData = PNAnnounce(timebase: Int(date.now.timeIntervalSince1970), nodeState: true,
                               perTransferLimit: 0, perSyncLimit: 0, targetStampCost: 0,
                               stampCostFlexibility: 0, peeringCost: 0).packed
      return .merge(.send(.endpoint(.registerLocalDestination(d))),
                    .send(.endpoint(.announce(destinationHash: d.hash, appData: appData))))

  // Ingest: a client's container arrives as a concluded Resource.
  case let .endpoint(.delegate(.resourceReceived(_, data))):
      return .send(.node(.ingestContainer(data)))
  case let .node(.delegate(.stored(tids))):
      return .send(.delegate(.messagesStored(transientIds: tids)))

  // IDENTIFY: remember the client identity for this link.
  case let .endpoint(.delegate(.linkIdentified(linkID, remoteIdentity))):
      state.clientIdentities[linkID] = remoteIdentity
      return .none

  // /get: dispatch by phase (unregistered path surfaces here).
  case let .endpoint(.delegate(.requestReceived(linkID, requestID, pathHash, data))):
      guard pathHash == Crypto.truncatedHash(Data("/get".utf8)) else { return .none }
      guard let clientIdentity = state.clientIdentities[linkID] else { return .none }   // no IDENTIFY → drop
      let clientHash = LXMessage.deliveryHash(identityHash: clientIdentity.hash)
      state.pendingGet[clientHash] = PendingGet(linkID: linkID, requestID: requestID)
      guard case let .array(items)? = MsgPack.decodeValue(data), items.count >= 2 else { return .none }
      if case .null = items[0], case .null = items[1] {
          return .send(.node(.messageListRequested(destinationHash: clientHash)))    // phase-1
      }
      let wants = arrayOfBin(items[0]); let haves = arrayOfBin(items[1])              // phase-2
      return .send(.node(.messagesRequested(destinationHash: clientHash, wants: wants, haves: haves)))

  // Serve: correlate the deliver delegate back to the pending (linkID, requestID).
  case let .node(.delegate(.deliverMessageList(dest, ids))):
      guard let p = state.pendingGet[dest] else { return .none }
      state.pendingGet[dest] = nil
      return .send(.endpoint(.sendResponseOverLink(linkID: p.linkID, requestID: p.requestID,
                                                   data: MsgPack.encode(.array(ids.map { .bin($0) })))))
  case let .node(.delegate(.deliverMessages(dest, entries))):
      guard let p = state.pendingGet[dest] else { return .none }
      state.pendingGet[dest] = nil
      return .send(.endpoint(.sendResponseOverLink(linkID: p.linkID, requestID: p.requestID,
                                                   data: MsgPack.encode(.array(entries.map { .bin($0) })))))

  case .endpoint, .node, .delegate:
      return .none
  }
}
```

`arrayOfBin(_ v: MsgPackValue) -> [Data]` = the `compactMap { .bin }` helper
(same as the client uses). `@Dependency(\.date)` supplies the announce
timebase. `pendingGet` is keyed by the client delivery hash; phase-1 and
phase-2 are sequential per client, so at most one entry per client at a time.

### Data flow (loop)

```
Client P1 send: resource over link → PN endpoint.resourceReceived → node.ingestContainer → stored
Client P2 sync: identify → PN linkIdentified (clientIdentities[link]=id)
  /get [null,null]  → PN requestReceived → messageListRequested(clientHash) → deliverMessageList → sendResponse([ids])
  /get [wants,haves]→ PN requestReceived → messagesRequested(clientHash,wants,haves) → deliverMessages → sendResponse([blobs])
```

## Testing

### Task 1 — PNNode reducer + injected-delegate unit tests

Drive `PNNode` by sending Endpoint **delegate** actions directly (no link
handshake — the transport is already proven by EndpointTests/P1/P2):

1. `registerPropagation` → receives `endpoint.registerLocalDestination` and
   `endpoint.announce` (assert the announce app-data `PNAnnounce.isValid`).
2. Inject `.endpoint(.delegate(.resourceReceived(linkID, container)))` where
   `container` packs a message for client C → `node.ingestContainer` →
   `.delegate.messagesStored([tid])`; `state.node.store.contains(tid)`.
3. Inject `.endpoint(.delegate(.linkIdentified(linkID, cIdentity)))` then
   `.endpoint(.delegate(.requestReceived(linkID, rid1, hash("/get"),
   MsgPack([.null,.null]))))` → assert `.endpoint(.sendResponseOverLink(linkID,
   rid1, MsgPack([.bin(tid)])))`.
4. Inject `requestReceived(linkID, rid2, hash("/get"), MsgPack([[tid],[]]))` →
   assert `sendResponseOverLink(linkID, rid2, MsgPack([.bin(entry)]))`.
5. Inject `requestReceived` on a link with **no** prior `linkIdentified` →
   no `sendResponseOverLink` (flip `.on` last to catch a stray).

Mutation verification, one at a time (e.g. drop the identity guard → serves
without IDENTIFY; break the `pendingGet` correlation → no response).

### Task 2 — 2-store real-transport integration test

Bare-`Endpoint` client `C` + `PNNode`. `PN.registerPropagation` + announce
bridged to `C` so `C` learns the PN; `C` opens a link; `C` sends a container
(built via `LXMFPropagation.pack` for recipient `C`) as a Resource → assert
`PN.delegate.messagesStored`. Then `C` IDENTIFYs, sends `/get [null,null]` →
assert `C.responseReceived` carries `[tid]`; `C` sends `/get [[tid],[]]` →
assert `C.responseReceived` carries `[entry]` and
`LXMFPropagation.open(entry, recipientIdentity: C) ` recovers the message,
`validateSignature == true`. Models the resource bridge on
`LXMFNodePropagationTests` and the identify/request/response bridge on
`EndpointTests.twoEndpointsIdentifyAndRoundTripARequest`. Keep the message
short so responses stay inline.

Mutation verification (drop `resourceReceived→ingest` → no store; drop a serve
wire → no response).

## Known Limitations (P3b)

- 3-store end-to-end loop deferred to a capstone.
- No transfer-limit/`max_messages`; resource-only ingest; propagation-accept
  confirmation is P3c.
- One `/get` in flight per client at a time (sequential phases).
