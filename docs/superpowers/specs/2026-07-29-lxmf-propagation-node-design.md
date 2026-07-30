# LXMF-4d-3b: Propagation Node reducer — Design

**Sub-project:** LXMF-4d propagation, integration layer. The deferred "PN serve wiring" from 4d-3, now as a decoupled reducer. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` — `LXMRouter.propagation_resource_concluded` (ingest), `message_get_request` / `message_list_response` (serve a client's messages), `save_locally_delivered_transient_ids` (drop on delivery).

## Scope decision (autonomous)

A running propagation node is Endpoint/Transport-heavy (register the `lxmf.propagation` destination; handle links, concluded resources, and request handlers; announce). Per our architecture, the *stateful orchestration* is a decoupled TCA reducer and the raw transport wiring is app-level glue (exactly as `LXMFRouter` relates to `Endpoint`). This slice builds that reducer — `PropagationNode` — wrapping the cross-validated `PropagationStore` (4d-3) with the action/delegate contract an app wires to the `lxmf.propagation` destination. The literal Endpoint registration, resource framing, and IDENTIFY resolution remain app glue (exercised by feeding the reducer actions), and the PN announce app-data + PN↔PN mesh stay separate follow-ons.

## Architecture

New decoupled reducer `Sources/ReTiCANode/PropagationNode.swift` (`@Reducer`, mirrors `LXMFRouter`'s shape). Holds a `PropagationStore`; the app forwards `lxmf.propagation` events in as actions and wires the delegates back out.

```swift
@Reducer
public struct PropagationNode {
    @ObservableState
    public struct State: Equatable {
        public var store: PropagationStore
        public init(storageLimitBytes: Int? = nil) { store = PropagationStore(storageLimitBytes: storageLimitBytes) }
    }
    public enum Action: Equatable {
        case ingestContainer(Data)                    // app: a client link concluded a resource carrying a container
        case messagesRequested(destinationHash: Data) // app: an IDENTIFY'd client asked for its messages
        case messagesDelivered(transientIds: [Data])  // app: a client confirmed receipt → drop from store
        case delegate(Delegate)
        public enum Delegate: Equatable {
            case stored(transientIds: [Data])                            // newly accepted (deduped) message ids
            case deliverMessages(destinationHash: Data, entries: [Data]) // the lxmf_data blobs addressed to the client
        }
    }
}
```

### Reducer
- **`.ingestContainer(data)`:** `let added = state.store.ingest(container: data)`; `return .send(.delegate(.stored(transientIds: added)))`. (Dedup + storage-limit eviction are the store's job, 4d-3.)
- **`.messagesRequested(destinationHash)`:** `let entries = state.store.entries(forDestination: destinationHash).map(\.lxmfData)`; `return .send(.delegate(.deliverMessages(destinationHash: destinationHash, entries: entries)))`. The app frames `entries` into a response/resource; a syncing client opens each via 4d-2a `open`.
- **`.messagesDelivered(transientIds)`:** `for tid in transientIds { state.store.remove(transientId: tid) }`; `return .none`. (RNS drops delivered messages so they are not re-served.)

No timers, no crypto — pure orchestration over the store. Delivery/serve outcomes surface via the delegates; the app owns the link/resource lifecycle.

## Data flow

```
(client link resource concluded) → .ingestContainer(container) → store.ingest → .delegate(.stored(ids))
(client IDENTIFY + MESSAGE_GET)   → .messagesRequested(destHash) → .delegate(.deliverMessages(destHash, [lxmf_data]))
(client confirms receipt)         → .messagesDelivered([tid])    → store.remove each
```

## Testing

TCA `TestStore`, `exhaustivity = .off`, mutation-verified. Build containers with `LXMFPropagation.container(timestamp:entries:)` over `lxmf_data` blobs (`destHash(16) ‖ opaque`), reusing the 4d-3 store test approach (no cross-val — pure behavior over cross-validated primitives).

1. **Ingest stores and reports ids.** `.ingestContainer(container([e]))` → `.delegate(.stored([tid(e)]))`; `store.count == 1`, `store.contains(tid)`.
2. **Ingest dedups.** Ingest the same container twice → the second `.stored([])`; `store.count == 1`.
3. **Serve filters by destination.** Ingest entries for dest A and dest B; `.messagesRequested(destinationHash: A)` → `.deliverMessages(destinationHash: A, entries: [A's lxmf_data…])` (only A's, oldest-first).
4. **Serve empty when nothing addressed.** `.messagesRequested(destinationHash: unknownDest)` → `.deliverMessages(unknownDest, [])`.
5. **Delivered drops from the store.** After (1), `.messagesDelivered([tid])` → `store.count == 0`; a subsequent `.messagesRequested(dest)` → `.deliverMessages(dest, [])`.

## Deferred (not in this slice)

- Endpoint/Transport glue: registering the `lxmf.propagation` `IN` destination, link + concluded-resource → `.ingestContainer`, an `OFFER`/`MESSAGE_GET` request handler → `.messagesRequested` and framing `.deliverMessages` entries into a response/resource, IDENTIFY → the client's delivery hash.
- PN announce app-data (`pn_announce_data`) wire format; PN↔PN mesh (peer registry + sync-over-link, using the 5c peering-key/PN-stamp validators); PN-stamp enforcement on ingest (`enforce_stamps`).

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new test.
- Prefer non-exhaustive TCA tests (`exhaustivity = .off`) asserting outcomes.
- New production is the `PropagationNode` reducer (ReTiCANode); tests in `ReTiCANodeTests`. Reuses `PropagationStore` + `LXMFPropagation` (ReTiCA core). No core/Transport changes.
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
