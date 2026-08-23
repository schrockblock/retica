# F11 — a stalled resource-advertiser pins a responder-link slot against eviction

**Written:** 2026-08-23. **Repo:** ReTiCA (`/Users/ell/development/ios/pods/ReTiCA`). Target: `main`.
**Layer:** `ReTiCATransport` (`LinkSession`) and `ReTiCANode` (`LinkPlane`).

## Goal

Close backlog item **F11**: an authenticated peer holding an active responder link sends resource
*advertisements* it never fulfils with segments, becomes immune to eviction, and — because responder
links are capped — pins its slot and locks every other peer out, at zero cost and without
self-clearing. Fix the eviction policy so a stalled advertiser is evictable and is the one chosen for
eviction, while genuinely-active transfers stay protected. Behavior-aligned with stock RNS.

## Root cause

Two flaws in the responder-link eviction policy (which lives, since F14's fix, in `LinkPlane`'s
eviction-at-promotion handler, `LinkPlane.swift:280-338`), both of which measure the wrong signal:

1. **Immunity is granted for any non-empty `transfers`.** The evictable filter
   (`LinkPlane.swift:322`) skips any link whose `transfers` is non-empty:
   `.filter { $0.id != elementID && $0.transfers.isEmpty }`. The `.resourceAdvertisement` branch
   (`LinkSession.swift:513-532`) appends a `ResourceTransfer` on a valid advertisement alone, with
   only a SAME-hash dedup (`:516`), so distinct-hash advertisements append without bound and *one*
   no-parts transfer makes the link eviction-immune. The count is irrelevant — a per-link cap on
   `transfers` (the backlog's original suggestion) would not fix this, because a single stalled
   transfer still confers immunity.
2. **Advertisements advance the eviction clock.** Eviction is LRU by `lastData`
   (`LinkPlane.swift:323`). `lastData` advances on any authenticated, decrypted, non-keepalive packet
   (`LinkSession.swift:637-638`, via `sawAuthenticatedData` set in `authDecrypt`, `:416`).
   Advertisements decrypt, so they advance `lastData` — while actual resource *segments* do not (they
   forward raw bytes to `ResourceTransfer` children that decrypt internally). So the clock is exactly
   backwards: a re-advertising attacker looks "recently active" and outranks quiet legitimate peers,
   while a link mid-large-transfer looks idle (the reason the `transfers.isEmpty` immunity was added).

Composed: a peer advertises distinct-hash resources, never sends a segment, and is both immune (flaw
1) and, if it re-advertises, freshly-ranked (flaw 2). Holding a slot that way at the responder cap
(`maxResponderLinks`, default 256, `LinkPlane.swift:72`) refuses every newcomer — after F14 the
newcomer is admitted, completes a full handshake, and is then the element closed on promotion.
Pinned by `distinctAdvertisementsGrowTransfersAndPinTheLinkAgainstEviction`
(`LinkPlaneTests.swift:1331-1371`).

## Reference alignment (stock RNS 1.4.2)

Verified against `RNS/Link.py` and `RNS/Resource.py` in the conda `rns` env:
- RNS has **no per-link cap** on concurrent inbound resources (`Link.incoming_resources` is an
  unbounded list, dedup by hash only).
- Each inbound Resource has an **independent receiver watchdog** (`Resource.__watchdog_job`,
  `PART_TIMEOUT_FACTOR = 4`, `MAX_RETRIES = 16`) that cancels a stalled resource and removes it.
- The **Link stale timer is independent of resources** (`STALE_TIME = 720s`), so a stalled resource
  can never pin the link.

The reference lesson: bound stalled resources by *time* (per-resource self-reap), keep the link's
liveness decision independent of advertisement activity, and add no count cap. ReTiCA's bug is that
it *coupled* eviction to `transfers` and let advertisements (not segments) drive the clock. This
spec un-couples them; it does not add a cap.

## Design

App/library-side only, in `ReTiCATransport` and `ReTiCANode`. No wire-format change. No per-link cap.

### Fix #1 — Progress-aware eviction immunity (`LinkPlane`)

In the eviction-at-promotion evictable filter (`LinkPlane.swift:322`), replace the
`transfers.isEmpty` immunity with a genuine-progress test: a link is immune only if some transfer has
received a part.

- from `.filter { $0.id != elementID && $0.transfers.isEmpty }`
- to   `.filter { $0.id != elementID && !$0.transfers.contains(where: { $0.receivedFirstPart }) }`

`receivedFirstPart` (`ResourceTransfer.State`, `ResourceTransfer.swift:39`) is set true only when a
real part arrives (`:365`). A link genuinely receiving a large resource stays protected; a link whose
transfers are all advertised-but-stalled (no parts) becomes an eviction candidate. Update the
adjacent comment (`LinkPlane.swift:305-311`) to describe the new rule and drop the "we accept it /
bounding transfers is the real fix" trade-off note, which no longer applies.

### Fix #2 — Advertisements do not advance the eviction clock (`LinkSession`)

The `.resourceAdvertisement` branch must not advance `lastData`. Introduce a distinction so that
ordinary application data still advances `lastData` (as today) but an advertisement does not — e.g. a
`sawGenuineData` signal that the advertisement branch leaves unset while other decrypted-data paths
set it, feeding the existing `lastData` update at `LinkSession.swift:637-638`. This keeps `lastData`
consistent with its documented contract (`:51-61`, "not advanceable by an unauthenticated peer") and
makes it stricter: only genuine data, not advertisements, advances it. Result: a re-advertising
attacker's `lastData` stays old, so it sorts as the LRU eviction victim (`LinkPlane.swift:323`).

### Memory growth — no new mechanism

Distinct-hash advertisements transiently accumulate `ResourceTransfer`s, but each self-reaps: a
no-parts receiver transfer sits in `.requesting` (`ResourceTransfer.swift:271`), its watchdog fires
and retries (`:469-483`, `maxRetries = 16`), and on exhaustion emits `.delegate(.failed)`, which
`LinkSession` handles by removing the transfer (`LinkSession.swift:999-1001`). Growth is bounded by
advertisement-rate × reap-time, matching reference. No per-link cap is added. A test pins this
self-reap so a regression cannot make transfers immortal.

## Data flow (after the fix)

```
Inbound .resourceAdvertisement (authenticated):
   append ResourceTransfer (receivedFirstPart = false), request first window
   lastData NOT advanced  (Fix #2)
Inbound resource part (valid):
   ResourceTransfer.receivedFirstPart = true; watchdog re-armed
No parts arrive:
   watchdog retries 16× → .failed → LinkSession removes the transfer  (self-reap)

Eviction at promotion (responder cap exceeded):
   evictable = active responder links, excluding the newcomer,
               with NO transfer that has receivedFirstPart,           (Fix #1)
               sorted ascending by lastData,                          (Fix #2 keeps advertiser old)
               take (active − cap)
   → a stalled advertiser is evictable AND sorts as the victim; a genuine
     transfer is immune; a quiet legit link outranks a bare advertiser.
```

## Edge cases

- **Legit transfer between advertisement and first part:** briefly non-immune (no part yet) with a
  non-advanced `lastData`, so under cap pressure it could be evicted just before its first part. Rare
  race, indistinguishable from an attacker at that instant, peer re-establishes. Accepted.
- **`receivedFirstPart` is sticky** but bounded by the watchdog: a transfer that receives one part
  then stalls self-reaps in ~60–80s, after which the link loses that immunity. See Accepted
  limitations.
- **Genuine data still protects a link:** a peer sending real application-data messages advances
  `lastData` and is not evicted ahead of a bare advertiser.

## Testing

Follow the three-step verification (green → mutate to red → revert). Tests at the `LinkPlane` /
`LinkSession` level; `TestClock` for watchdog timing.

1. **Rewrite `distinctAdvertisementsGrowTransfersAndPinTheLinkAgainstEviction`** to assert the fixed
   behavior: with the advertiser at the responder cap, a newcomer that completes a handshake causes
   the *stalled advertiser* to be evicted (closed), not the newcomer. Mutation: revert Fix #1 → the
   advertiser survives and the newcomer is closed → test fails.
2. **Genuine transfer is protected:** a link with a transfer that has `receivedFirstPart == true`
   survives cap pressure (not evicted mid-flight). Mutation: over-broaden Fix #1 to also evict
   part-receiving transfers → fails.
3. **Advertisements don't advance `lastData` (Fix #2):** after an advertisement, `lastData` is
   unchanged; after a genuine data message, it advances; a re-advertiser sorts as the LRU victim
   against a link with genuine recent data. Mutation: let the advertisement branch set `lastData` →
   the victim-selection test fails.
4. **Self-reap:** a no-parts transfer is removed from `state.transfers` after its watchdog exhausts.
   Mutation: suppress the `.failed`→remove path → the transfer persists → test fails.

## Accepted limitations

- **Slow-feed to hold a slot (documented, reference-or-better):** the fix eliminates the *zero-cost*
  pin (advertise, send nothing). A residual remains: an attacker willing to *continuously send valid
  parts* keeps a transfer `receivedFirstPart`/re-armed and so holds a slot as long as any legitimate
  long transfer could — because it is then doing the real work the link exists for and is
  indistinguishable from a slow legitimate transfer. Closing it fully needs a transfer-completion
  deadline policy, out of scope; stock RNS has no such eviction mechanism at all.

## Out of scope

- A per-link cap or LRU on `transfers` (deliberately declined; reference has none).
- A transfer-completion deadline / slow-feed defense (see Accepted limitations).
- Any wire-format change; F19 (the sender-side sibling — read together but fixed separately).
