# LXMF-4b: Core Outbound Orchestration — Design

**Sub-project:** LXMF-4 (LXMRouter), second sub-slice. Follows 4a (inbound router + dedup). LXMF-4 = 4a inbound+dedup [done] → **4b core outbound** (this) → 4c retries/receipts/timing → 4d propagation. See the `lxmf` memory.

**Reference pin:** `lxmf 1.1.0` (`LXMRouter.py:1746 handle_outbound`, `2682-2839 process_outbound`; `LXMessage.py:397-424`), `rns 1.4.2`.

**Goal.** Extend the `LXMFRouter` reducer with the send side: given a message + desired method, drive it out — opportunistically for small messages, or over a direct link (establishing/reusing one and queuing until it is up) for larger/direct ones.

## Problem

LXMF-2/3 gave the *mechanics* of a single opportunistic/direct send, but the caller must manually pick the method, manage the link, and time the send. The LXMRouter's outbound side automates this: choose the method (with a size-safety fallback), reuse or establish a direct link to the recipient's `lxmf.delivery` destination, hold the message until the link is active, then send it. This slice builds the **happy-path** state machine; retries, path-requests, timing, and link-CLOSED recovery are LXMF-4c.

## How reference LXMF does it (scoped to the happy path)

- **Method selection** (`LXMessage.py:397-401`): the caller's `desired_method`; if opportunistic but the content exceeds a single encrypted packet, fall back to DIRECT.
- **`process_outbound`** (`LXMRouter.py:2735-2839`), happy path: **OPPORTUNISTIC** → `send()` (a single encrypted DATA packet). **DIRECT** → if a `direct_links[dest]` link exists and is ACTIVE, `set_delivery_destination(link)` + `send()` (link packet or resource); if none exists, `RNS.Link(dest)` with `set_link_established_callback(process_outbound)`, store in `direct_links`, and leave the message queued — when the link establishes, the callback re-runs `process_outbound`, now finds it ACTIVE, and sends. (The retry/timing/path-request/CLOSED branches are LXMF-4c.)

## The size fallback reduces to a constant

RNS falls back opportunistic→direct when `content_size > ENCRYPTED_PACKET_MAX_CONTENT` (`= ENCRYPTED_PACKET_MDU − LXMF_OVERHEAD + DESTINATION_LENGTH`). Since the opportunistic wire payload is `opportunisticPayload = packed[16:]` and the overhead terms cancel, this reduces exactly to **`opportunisticPayload.count ≤ ENCRYPTED_PACKET_MDU`**, with `ENCRYPTED_PACKET_MDU = 391` (verified against genuine LXMF). (Algebra: `content_size = opportunisticPayload.count − 96`; `ENCRYPTED_PACKET_MAX_CONTENT = 391 − 112 + 16 = 295`; `x − 96 ≤ 295 ⟺ x ≤ 391`.)

## Architecture

Extends `Sources/ReTiCANode/LXMFRouter.swift` (the 4a reducer). Still **decoupled** from `Endpoint`: outbound is driven by **send-request delegates** the app wires to Endpoint, and link lifecycle comes back as actions the app forwards. Plus a small pure addition to `LXMessage` for the size threshold.

### `LXMessage` addition (pure, cross-validated)
```swift
extension LXMessage {
    public static let encryptedPacketMDU = 391   // RNS ENCRYPTED_PACKET_MDU
    /// True if this message fits a single opportunistic encrypted packet (else DIRECT is required).
    /// Reduces RNS content_size ≤ ENCRYPTED_PACKET_MAX_CONTENT to opportunisticPayload.count ≤ MDU.
    public var opportunisticFits: Bool { opportunisticPayload.count <= LXMessage.encryptedPacketMDU }
}
```

### New router state
```swift
enum LinkStatus: Equatable { case establishing; case active(linkID: Data) }
public var directLinks: [Data: LinkStatus] = [:]            // destinationHash → link state
var outboundQueue: [Data: [LXMessage]] = [:]                // destinationHash → messages awaiting a link
```

### New actions (added to the existing 4a `Action`)
```swift
case send(message: LXMessage, desiredMethod: DeliveryMethod)
case linkEstablished(destinationHash: Data, linkID: Data)
case linkClosed(destinationHash: Data)
```
### New `Delegate` cases (send requests the app forwards to Endpoint — added to the existing 4a `Delegate` alongside `messageDelivered`/`duplicateDropped`)
```swift
case sendOpportunistic(destinationHash: Data, payload: Data)   // → Transport.send
case requestLink(destinationHash: Data)                         // → Endpoint.openLink
case sendDirect(linkID: Data, data: Data, asResource: Bool)     // → sendOverLink / sendResourceOverLink
```

### Reducer
- `.send(message, desiredMethod)`:
  - `effective = (desiredMethod == .opportunistic && !message.opportunisticFits) ? .direct : desiredMethod`.
  - **`.opportunistic`** → `.send(.delegate(.sendOpportunistic(message.destinationHash, message.opportunisticPayload)))`.
  - **`.direct`**: let `dest = message.destinationHash`.
    - `if case .active(let linkID) = directLinks[dest]` → `.send(.delegate(.sendDirect(linkID, message.packed, asResource: message.directRepresentation == .resource)))`.
    - else → enqueue `outboundQueue[dest, default: []].append(message)`; if `directLinks[dest] == nil` → `directLinks[dest] = .establishing` + `.send(.delegate(.requestLink(dest)))`; if already `.establishing` → `.none` (a request is already in flight).
- `.linkEstablished(dest, linkID)` → `directLinks[dest] = .active(linkID)`; drain: for each queued `m` in `outboundQueue[dest]`, emit `.delegate(.sendDirect(linkID, m.packed, asResource: m.directRepresentation == .resource))`; `outboundQueue[dest] = nil`. (`.merge` of the sends.)
- `.linkClosed(dest)` → `directLinks[dest] = nil` (a later `.send` re-establishes; queued-message recovery on close is 4c).

## Data flow

```
.send(msg, .opportunistic)  ── fits? ──▶ .delegate(.sendOpportunistic(dest, msg.opportunisticPayload))  ▶ Transport.send
                            └─ too big → treat as .direct ↓
.send(msg, .direct):
   directLinks[dest] active? ── yes ──▶ .delegate(.sendDirect(linkID, msg.packed, asResource))          ▶ sendOverLink/Resource
                             └─ no ──▶ enqueue msg; if not establishing → mark establishing + .delegate(.requestLink(dest)) ▶ Endpoint.openLink
        (app opens link … Endpoint.linkEstablished …)
.linkEstablished(dest, linkID) ──▶ directLinks[dest]=.active; drain queue → .delegate(.sendDirect(...)) per queued msg
.linkClosed(dest) ──▶ directLinks[dest]=nil
```

## Testing

TCA `TestStore`, mutation-verified.

**Task 1 (size threshold + opportunistic dispatch):**
1. `opportunisticFits` — true for a small message, false when `opportunisticPayload.count > 391`; boundary at 391 (tune content length).
2. Cross-val: `LXMessage.encryptedPacketMDU == RNS ENCRYPTED_PACKET_MDU` (fixture emits it; == 391).
3. `.send(small, .opportunistic)` → `.delegate(.sendOpportunistic(destHash, msg.opportunisticPayload))`.
4. Size fallback: `.send(big, .opportunistic)` where `!big.opportunisticFits` → treated as direct (→ `requestLink` + enqueue, no `sendOpportunistic`).

**Task 2 (direct link lifecycle + queue):**
5. `.send(msg, .direct)` with no link → `.delegate(.requestLink(dest))` and `directLinks[dest] == .establishing`, message enqueued, no `sendDirect`.
6. `.linkEstablished(dest, linkID)` → `.delegate(.sendDirect(linkID, msg.packed, asResource:))` (assert `asResource` matches `directRepresentation`; test both a packet-sized and a resource-sized message), and `directLinks[dest] == .active(linkID)`, queue drained.
7. `.send(msg, .direct)` with an already-active link → immediate `.delegate(.sendDirect(linkID, msg.packed, ...))`, no `requestLink`.
8. Two `.send(.direct)` for the same dest before establishment → one `requestLink`, both enqueued; `.linkEstablished` drains both (two `sendDirect`).
9. `.linkClosed(dest)` → `directLinks[dest] == nil` (a subsequent `.send(.direct)` re-requests a link).

No cross-val beyond the `encryptedPacketMDU` constant (the rest is behavior over LXMF-1/2/3's cross-validated primitives).

## Constraints

- Commit directly to `main`; no feature branch (`commit-directly-to-main`).
- No compound shell commands; temp files in `/tmp/ReTiCA/`.
- Three-step mutation verification for every new/changed test.
- Cross-val fixtures MUST drive genuine LXMF (`cross-validation-drive-real-rns`); reuse/extend the committed LXMF fixture.
- Signatures validated, never byte-compared (`ed25519-hedged-nondeterministic`).
- New production: `LXMessage.encryptedPacketMDU`/`opportunisticFits` (pure, ReTiCA) + `LXMFRouter` outbound extension (ReTiCANode). Tests in `ReTiCATests` (helper/cross-val) + `ReTiCANodeTests` (reducer). No Endpoint/Transport changes (the Endpoint↔router wiring is app-level, exercised by feeding the router actions).
- Commit trailers: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>` and `Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy`.
