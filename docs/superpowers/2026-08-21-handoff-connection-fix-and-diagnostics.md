# Handoff — the device connection bug, and the diagnostics screen built from it

**Written:** 2026-08-21, end of session. **Repos:** ReTiCA (`/Users/ell/development/ios/pods/ReTiCA`)
and ReTiCaMsgr (`/Users/ell/development/ios/apps/ReTiCaMsgr`), both on `main`.

**Suite state, verified by running it at the end, not assumed:** ReTiCA **1007 tests, 1 known
issue** (`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`, pre-existing). ReTiCaMsgrCore
**91 tests**. The iOS app **builds** for the simulator.

---

## ⚠️ How to read this

Per this repo's own history with handoffs (see §6 of
`2026-08-10-handoff-link-lifecycle-and-delivery-termination.md`), the failure mode here is a
sentence wider than its evidence. So this document marks every substantive claim as one of:

- **VERIFIED** — I ran it or read the code and can name what I read.
- **HYPOTHESIS** — plausible, not demonstrated. Do not build on it.
- **UNEXPLAINED** — observed on a device, cause unknown.

**Verify anything you are about to depend on.** During this session three claims I relayed to
implementers were wrong, and each was caught only because the implementer checked rather than
complied. Assume the same of this file.

---

## 1. Why the session started

Four symptoms reported from real-device testing (iPhone ↔ Sideband on Android, via an rnsd):

1. Node connection stuck on "Disconnected" after backgrounding a few times.
2. Received messages showing an empty body in the UI.
3. Tapping an announce row → "requesting public key" → always fails.
4. Later added: the Send button sometimes never enables.

Three of the four turned out to share one root cause. One is still open.

---

## 2. The root cause — a stale `NWConnection` callback (FIXED)

**VERIFIED, and reproduced by a test that failed before the fix and passes after.**

`TCPConnection.liveValue` builds ONE `NWConnectionActor` and captures it in all three closures, so
every reconnect reuses the instance. `start` cancelled the previous `NWConnection` and then — with
no suspension point — installed the new continuation. Network.framework delivers `.cancelled`
asynchronously onto the actor *afterwards*, where `handleState` ran `continuation?.finish()` on
whatever it found: **the new stream**.

Consequence: the new socket connects normally, `.ready` yields into a finished continuation, and
**every inbound byte is dropped** — while `send` keeps working, because it writes to the new
connection. So the node sees a healthy client and the app sees silence. Only a fresh process
escaped it, which is why killing the app was the only recovery.

Fixed in **`5d310f7`** by generation-stamping each connection and rejecting stale callbacks, plus:

- `.waiting` was falling into `default: break`. NWConnection reports connection-refused and
  no-route as `.waiting`, **not** `.failed`, so dialling a dead node emitted nothing at all and —
  because the reconnect arms only on `.disconnected` — never retried.
- A stream ending without a terminal event left the interface stuck with no reconnect armed.
- The reconnect is now cancellable, so an explicit Disconnect no longer silently re-dials.

**The tests are real-socket tests over loopback** (`TCPConnectionReconnectTests`), a deliberate
exception to the mock-only convention noted at the type. A mocked `TCPConnection` replaces exactly
the layer this bug lived in — which is why it survived 996 passing tests. Mutation-verified: with
the generation guard disabled both reconnect tests fail immediately; with `.waiting` swallowed the
third fails **by timing out**, i.e. by reproducing the original silence.

**Confirmed fixed on device by the user.**

### Downstream of it

- **Symptom 4 (Send button)** — the gate is honest. Without a peer's identity we genuinely cannot
  send (opportunistic encrypts *to* the recipient identity). Root cause was no durable identity
  store; **the user has since fixed this** (see §5).
- **Symptom 3 (announce row)** — partly F8 below, but **not fully explained**. See §4.

---

## 3. F8 — a dead socket laundered into a dead route (FIXED)

**VERIFIED by reading both endpoints.** `Transport.State.learned` is deliberately
non-destructive, so a path outlives the interface it was heard on. `Transport.send` gates on
`reachableLearned`, and `BLEEndpoint.openLink` does too — `TCPEndpoint.openLink` did not.

The damage was worse than the old entry's cost argument: a `LinkSession` was minted against a dead
interface and exited only via the 15s establishment deadline, reported as `.establishmentTimedOut`,
which `LXMFNode` classifies **PATH-shaped** and routes to `pathLostAndClosed`. So a dead *socket*
made the router discard a good *route*. That is why a connection failure was indistinguishable
from a routing failure.

Fixed in **`c4d00b2`**; entry closed in `3504489`.

**Trap worth keeping:** landing it required correcting two fixtures that seeded
`transport.learned` while leaving `transport.interfaces` empty — a state the runtime cannot
produce. They passed only because nothing read both tables together.

---

## 4. STILL OPEN — the two unexplained things

### 4a. Announce-row tap fails after ~15s with a healthy connection — UNEXPLAINED

15s is `LinkSession.establishmentTimeout`, whose own comment says *"No LINKPROOF within
`establishmentTimeout` … the peer never spoke at all."* So the request went out and nothing came
back.

**What has been eliminated, VERIFIED by a live harness** (`Scripts/linkprobe/harness.py` +
`LiveLinkProbeTests`, committed in `4dca6bd`):

ReTiCA **does** establish an outbound link to a genuine reference LXMF peer — 1.5s, over a
*relayed* path (hops=1, nextHop ≠ destination, i.e. the HEADER_2 branch). A stock RNS prober does
the same in 6ms, which is the control that makes the result mean anything. So these are NOT the
cause: outbound link establishment generally, the HEADER_2 relay path, the MTU/mode signalling
bytes (ReTiCA's hardcoded `[0x20, 0x01, 0xf4]` decodes to exactly what
`Link.signalling_bytes(500, MODE_AES256_CBC)` produces and 1.4.2 accepts it), and ratchets —
`LXMRouter.register_delivery_identity` calls `enable_ratchets` on **every** delivery destination
(`LXMRouter.py:357`), so the reference peer had them exactly as Sideband does.

**To run the harness:** three terminals —
`python Scripts/linkprobe/harness.py hub`, then `peer`, then `prober` (the prober validates the
harness itself; expect `RESULT=ESTABLISHED`), then
`RETICA_LIVE_PROBE=1 swift test --no-parallel --filter LiveLinkProbe`. Needs the conda `rns` env.

**The sharpest remaining clue:** inbound links work — Sideband opened a link *to* the device and
delivered over it — while outbound ones time out. **HYPOTHESIS (untested):** Android Doze. A
backgrounded Sideband can initiate whenever the user interacts with it but does not wake to answer
an inbound LINKREQUEST. That asymmetry fits, but nothing has tested it.

### 4b. Received messages with an empty body — UNEXPLAINED, did not reproduce

**Ruled out by reading code, all VERIFIED:**
- Byte slicing is symmetric. Reference drops 16 bytes only for OPPORTUNISTIC
  (`LXMessage.py:634`); DIRECT sends the **full** packed (636 packet / 654 resource), and ReTiCA
  hands link data straight to `unpack`, which expects the full packed.
- `LXMessage.unpack` cannot produce an empty body — it is strict and returns nil on any mismatch,
  and `LXMFRouter.received` drops nil. There is no fallback that yields empty content.
- Not str/bin confusion (the MsgPack decoder maps them to distinct cases), not compression (LXMF
  1.1.0 `pack()` has none; compression is Resource-level).

So the content genuinely arrived empty in a well-formed, signed message.
**HYPOTHESIS:** Sideband control messages — LXMF defines `FIELD_TELEMETRY` (0x02),
`FIELD_ICON_APPEARANCE` (0x04), `FIELD_COMMANDS` (0x09), all of which carry empty `content` by
design — and the app renders every delivered message as a bubble while discarding `fields`.

**A diagnostic is live in `AppFeature`'s `.messageReceived` handler**, logging content size, title
size, field keys, wire size and validation to subsystem `com.reticamsgr`, category `inbound`. It
costs one line per inbound message. Read it via Xcode's console or Console.app with the device
selected — **not** `log stream`, which has no device flag and shows only the Mac.

`content=0B fields=[0x2]` confirms the hypothesis. `content=0B fields=[]` kills it.

---

## 5. The diagnostics screen (BUILT, never run on a device)

Settings → **Diagnostics**. Read-only, live, with a share/copy text export. Spec and plan:
`ReTiCaMsgr/docs/superpowers/specs/2026-08-21-diagnostics-page-design.md` and
`plans/2026-08-21-diagnostics-page.md`.

Architecture: a pure `DiagnosticsSnapshot` value (`ReTiCaMsgrCore`) built by
`init(from: AppFeature.State, at: Date)` — no clock, no network, no mutation — plus a
render-only view. Six layers, each with a health dot and a reason: Socket, Identity, Paths, Peers,
Links, Delivery.

**Two layers exist specifically to answer this session's questions:** Paths cross-checks `learned`
against `interfaces` (F8), Peers cross-checks `learnedPeers` against `learned` (F20). Socket shows
app-connection and interface-status as **separate rows**, because those two disagreed for the
entire duration of the reconnect bug.

**Security property:** rows are built from a hand-written allowlist, never reflection.
`LinkSession.State` carries `sessionKey` and an `ephemeral` keypair, and this text gets pasted into
bug reports. One test plants four distinct byte patterns (`sessionKey`, link ephemeral private key,
`owningIdentity` private key, an `InterfaceProfile.ifac` key) and asserts none of the bytes and
none of the field names reach `text`. Two of those assertions are **not mutation-killable today**
because `IFAC.key` and `IFAC.seed` are `private let` (`IFAC.swift:172,174` — I checked this rather
than taking the reviewer's word), so nothing in the snapshot file can reach those bytes. They are
kept as future-proofing and the test says so inline. Note the honest limit: the realistic
regression they guard against is a `Mirror`/`String(describing:)` dump, and Swift renders `Data`
as `"64 bytes"` rather than hex — so even once reachable, the **field-name** assertion would be
doing the work, not the byte one.

### What the final whole-branch review caught that six task reviews did not

Two Criticals, both **false greens on the exact faults their layer existed to report**, both on
seams no single task owned. Both VERIFIED independently before fixing:

- **The Links rule was unsatisfiable.** `role == .initiator && status == .handshake` — but
  `.handshake` is assigned only under `guard state.role == .responder` in
  `LinkSession.acceptRequest`, and the initiator's `.establish` never assigns status at all. No
  test existed for that rule, so mutation testing had nothing to kill. Now `.pending`, with
  `requestedAt` rendered as the age that separates in-flight from stalled.
- **The Delivery rule read the wrong table.** The app sends only opportunistic, which arms
  `pendingDeliveries` but needs no link → yellow during every normal send; while the real fault, a
  `.direct` send with no link, goes to `outboundQueue` and never reaches `pendingDeliveries` →
  green throughout a genuinely failing delivery. The rule is now method-aware and
  destination-correlated, and warns on destinations parked at `.awaitingPath`/`.establishing`.

**Known and accepted limit:** opportunistic sends are structurally unobservable — there is no
receipt — so a small message to an offline peer still yields an all-green board. No rule over that
data could do better, so the Delivery layer now carries an informational **row** saying green means
"no evidence of failure, not confirmed delivery". It deliberately does not affect health.

---

## 6. What the user fixed in parallel (not mine)

Interleaved with the above, the user landed **path persistence**: ReTiCA `9667afe` + `aa19115`
(a `rehydrateLearnedDestinations` action, public `pathExpiry`) and app `5d2b33a` + `cbe1845`
(a `LearnedDestinationRow` GRDB table, debounced writes, launch prune and replay).

**This closed F20 hours after I filed it, and made its headline claim false.** Corrected in
`4e8395e` — narrowed at the header, body relabelled as the analysis the fix was built from.

**One design question is genuinely open, not settled:** the fix restores identity **and** path
together, where the analysis argued the parity target for a leaf client is *persist identities,
re-learn paths* (reference loads its path table only on transport-enabled nodes —
`Transport.py:306`; the identity cache is loaded unconditionally — `Reticulum.py:344`). A
rehydrated entry therefore carries an `interfaceID` minted by a previous process, which F8's gate
refuses until an interface with that id registers. Works while the id is stable
(`InterfaceID("tcp")` is a constant) — but it is a choice, not an accident, and should be recorded
as one.

---

## 7. THE NEXT STEP

**Take the diagnostics screen to the device and re-tap the announce row.** It closes the oldest
open question and validates the new screen in one pass. Watch Paths and Links:

| What you see | What it means |
|---|---|
| Paths `reachable=NO` | Path names a dead interface — F8 territory, 15s explained |
| Paths green, Links shows a `.pending` initiator with climbing `req=` | Request went out, Sideband never answered → the Doze hypothesis |
| No Links row at all | `openLink` never minted a session — a third, different bug |

Those three were indistinguishable before today.

**Two things to expect, so they are not misread as bugs:** a peer rehydrated from disk reads
`reachable=NO` until the socket registers its interface; and the Delivery layer will say plainly
that opportunistic sends cannot be confirmed.

Also worth doing eventually: tap the row with **Sideband open and foregrounded** on the Android
device. If it establishes then, it is Android power management and there is nothing to fix here.

---

## 8. Backlog

`docs/superpowers/2026-08-10-handoff-link-lifecycle-and-delivery-termination.md` §3 is the standing
task list. Ranked: **F13** (a reflected LINKREQUEST makes us forward our own link's traffic — the
only item that redirects a peer's traffic rather than merely denying service), then **F11**,
**F19**, **F7**. F8 and F20 are now closed; read their headers before trusting their bodies.

---

## 9. Process notes worth keeping

- **The mock boundary is a blind spot.** The reconnect bug lived in the live adapter that every
  test replaced. For any dependency wrapping a callback-based OS API, one test should drive the
  LIVE value. The signature to suspect: *"recovers only on a fresh process."*
- **I gave subagents three wrong facts in one brief** — a stale HEAD, a wrong baseline, and an
  instruction to ignore a test failure that was not occurring. Re-derive repo state immediately
  before each dispatch; do not carry it forward from a plan or an earlier review.
- **Fold a Minor into the next task when that task already edits the same files.** Four closed that
  way at near-zero cost, rather than rotting on a deferred list.
- **Fix the class, not the instance.** One plural-agreement defect recurred four times because each
  fix patched the string. The fourth pass added a `pluralize` helper. Likewise "test name claims
  two, asserts one" appeared three times in this one feature — twice proven vacuous by probe.
