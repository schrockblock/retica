# LXMF delivery stamps Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop peers running `enforce_stamps()` from silently dropping every message ReTiCA sends, by generating a delivery stamp at the cost a peer advertises — and validate inbound stamps against our own advertised cost.

**Architecture:** Every primitive already exists and is unused. `LXStamper.generateStamp` is written, cancellable, and has **no production caller**; `LXMessage.withStamp` / `validateStamp` likewise. The previous slice added `LXMFNode.State.learnedPeers[dest].stampCost` and deliberately never spent it. This slice spends it — behind a ceiling — and closes the receive half.

**Tech Stack:** Swift 6, swift-testing, The Composable Architecture 1.26.

## Global Constraints

- Platform floor **iOS 17 / macOS 13 / macCatalyst 17** (`Package.swift:6-10`).
- `ReTiCATransport` is interface-agnostic; no new dependencies.
- **Wire compatibility with Python-RNS 1.4.1/1.4.2 and LXMF 1.1.0 is mandatory. No existing emitted byte may change** — in particular, a message sent with **no** stamp must pack byte-identically to today.
- `swift-testing`, not XCTest. `#expect(optional?.field == x)` **aborts** when nil — use `#expect(x != nil)` then `if let`, or `try #require`.
- Durable records **name the enclosing function**, not a bare line.
- Reference: `/Users/ell/opt/anaconda3/envs/rns/lib/python3.12/site-packages/{RNS,LXMF}` is stock 1.4.2 / LXMF 1.1.0; `/Users/ell/development/python/Reticulum/RNS` is a 1.4.1 **fork** whose extra import at `Reticulum.py:37` shifts later lines +1. **Cite the version with the line, and verify every reference claim in this plan rather than inheriting it** — reference claims in recent slices were wrong four times, twice reaching production comments.
- Mutation-verify per repo rule, **accounting for each test individually**. A whole-block mutation failing three tests together cannot show which test pins what; this slice's predecessor had a 6-of-7 accounting gap and a round needing per-field mutations.
- Gate (`Scripts/check-wire-narrowing.swift --fail-on-open`) stays at zero known-open; any new conversion needs an allowlist entry naming the enclosing function and the guard that dominates it.
- Commit trailers at **column 0**:

```
Co-Authored-By: Claude <noreply@anthropic.com>
Claude-Session: https://claude.ai/code/session_01AtkFmSeVgRBk3zwfDCqUwy
```

---

## Background — and the asymmetry that shapes the whole plan

**Read this before designing anything.** It is easy to state "stamps need a cost ceiling". That is true of one direction and false of the other, and getting it backwards produces either a DoS or a pointless restriction.

**Outbound — the peer's cost, hostile, exponential.** `LXMRouter.handle_outbound` (`LXMRouter.py:1752-1757`) does:

```python
if lxmessage.stamp_cost == None:
    if destination_hash in self.outbound_stamp_costs:
        stamp_cost = self.outbound_stamp_costs[destination_hash][1]
        lxmessage.stamp_cost = stamp_cost
```

`outbound_stamp_costs` is populated from **peer announces** (`update_stamp_cost`, `:1027-1029`), and `pack()` then calls `get_stamp()` (`LXMessage.py:372`), which searches. The search is ~2^cost. `LXMFAnnounceData.parse` applies **no range gate** — deliberate parity, documented on its `stampCost` property — so a peer can advertise any `Int`. **This is the only place a ceiling belongs, and it is mandatory.**

**Inbound — our own cost, not hostile, O(1).** `LXMRouter.lxmf_delivery` (`:1861-1880`):

```python
required_stamp_cost = self.delivery_destinations[message.destination_hash].stamp_cost
if required_stamp_cost != None:
    if message.validate_stamp(required_stamp_cost, tickets=destination_tickets): ...
    if not message.stamp_valid:
        if self._enforce_stamps: return False    # drop
        else: ...allow anyway, with a log
```

The cost is **ours** — `delivery_destinations[...]`, which for us is `LXMFNode.State.deliveryStampCost`, set by the previous slice. Validation derives **one** workblock and checks leading-zero bits, so its cost is O(1) in `targetCost` — a cost of 200 validates as fast as a cost of 1. **No ceiling is needed inbound, and adding one would wrongly reject our own configuration.**

That O(1)-validation property is the same one whose absence made a previous task's guard vacuous: its author assumed validation cost scaled with the cost parameter. Verify it yourself rather than taking my word.

**Enforcement defaults OFF.** `LXMRouter.__init__` takes `enforce_stamps=False` (`:99`), and `enforce_stamps()` / `ignore_stamps()` (`:696-700`) flip it. An invalid stamp with enforcement off is **delivered anyway**, with a log. Match that default.

**Tickets are out of scope and create a real divergence — document it, do not silently inherit it.** `validate_stamp(target_cost, tickets=...)` (`LXMessage.py:273-294`) accepts a message whose `stamp == truncated_hash(ticket + message_id)` *regardless of cost*. ReTiCA has no tickets (Tier 3, unticked), so a ticket-holding peer that reference would accept, we would reject **if enforcing**. Latent while enforcement defaults off; it must be stated where enforcement is enabled.

---

## File Structure

- `Sources/ReTiCA/LXMF/LXMFDelivery.swift` (or the nearest existing constants home — check first) — `maxDeliveryStampCost`.
- `Sources/ReTiCANode/LXMFNode.swift` — outbound generation, inbound validation, enforcement flag.
- `Tests/ReTiCANodeTests/` — new suite.

---

### Task 1: Generate a delivery stamp at a bounded cost

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Test: new suite under `Tests/ReTiCANodeTests/`

**Interfaces:**
- Produces: `maxDeliveryStampCost` (constant) and a private `deliveryStampCost(_ state:_ destinationHash:) -> Int?` returning the learned cost only when it is within the ceiling. Task 2 does not consume these.

- [ ] **Step 1: Read the existing precedent first.** `LXMFNode.propagationStampCost(_:)` (`LXMFNode.swift:532-537`) does exactly this shape for propagation stamps, gated on `LXMFPropagation.maxPropagationStampCost` (= 20, `LXMFPropagation.swift:74`). Follow it. Note `LXMFNode.swift:33` already anticipates this task's constant by name. Also read how the propagation stamp search is run as a **cancellable** effect (`CancelID.propagationStamp`) — the delivery search needs the same treatment for the same reason, and `LXStamper.generateStamp`'s docstring says so explicitly.

- [ ] **Step 2:** Choose `maxDeliveryStampCost` and **justify it in the code**, not just in the report. 20 matches the propagation ceiling and is roughly a million hashes; state the reasoning and the measured order of magnitude. Note the filed follow-up that `minStampCost > 20` is a footgun — the same tension applies here.

- [ ] **Step 3: Write the failing tests.** At minimum:
  - a message to a peer with a learned cost within the ceiling is sent **with** a stamp, and the stamp validates at that cost
  - a message to a peer with **no** learned cost is sent with **no** stamp, and its packed bytes are **byte-identical** to today's
  - a learned cost **above** the ceiling produces **no** stamp (and the message is still sent — refusing to stamp must not refuse to send; say so in the test name)
  - the search is **cancellable**: an in-flight send abandons when cancelled, and the effect does not leak
  - a learned cost of 0 produces no stamp (0 is "no cost", per reference's own emit gate)

- [ ] **Step 4:** Confirm RED. **Step 5:** Implement. **Step 6:** Confirm green.

- [ ] **Step 7:** Full suite + gate. Mutation-verify per test. Commit.

---

### Task 2: Validate inbound stamps, with enforcement off by default

**Files:**
- Modify: `Sources/ReTiCANode/LXMFNode.swift`
- Test: same suite

**Interfaces:**
- Consumes: `LXMessage.validateStamp(targetCost:)` (exists, currently uncalled) and `State.deliveryStampCost` (exists, from the announce slice).

- [ ] **Step 1: Decide how the result reaches the app, and say why.** `.delegate(.messageReceived(message:signatureValidated:))` currently carries one flag. Reference sets both `stamp_valid` and `stamp_checked` — *checked* distinguishes "validated and failed" from "never validated because no cost is configured", which the app needs to render honestly. Adding a case parameter is a **breaking change for ReTiCaMsgr** (`AppFeature.swift` consumes this delegate) — check that consumer before choosing, and if you change the signature, say plainly in the report that the sibling project needs updating. A previous slice broke it by grepping the app target but not its test directory.

- [ ] **Step 2:** Add `enforceDeliveryStamps: Bool = false` to `State`, matching reference's `enforce_stamps=False` default (`LXMRouter.py:99`).

- [ ] **Step 3: Write the failing tests.** At minimum:
  - with `deliveryStampCost == nil`, no validation is attempted and the message is delivered (the "never checked" case)
  - with a cost configured and a **valid** stamp, delivered and flagged valid
  - with a cost configured and an **invalid or absent** stamp, and enforcement **off** → **still delivered**, flagged invalid (this is the reference behaviour most likely to be got wrong — it is *not* a drop)
  - same, enforcement **on** → **dropped**, and nothing is delivered to the app
  - a message with a stamp arriving when we require **no** cost is delivered unchanged

- [ ] **Step 4:** Confirm RED. **Step 5:** Implement. **Step 6:** Confirm green.

- [ ] **Step 7:** Document the ticket divergence where enforcement is enabled: a ticket-holding peer reference would accept, we reject. Name `LXMessage.py:273-283` and the unticked Tier 3 tickets item.

- [ ] **Step 8:** Full suite + gate. Mutation-verify per test. Commit.

---

### Task 3: Tick the checklist, and make the previous slice visible

**Files:**
- Modify: `docs/reference-parity-checklist.md`
- Modify: `/Users/ell/development/ios/apps/ReTiCaMsgr/ReTiCaMsgrCore/Sources/ReTiCaMsgrCore/AppFeature.swift`

- [ ] **Step 1:** Set a display name in ReTiCaMsgr. It calls `.registerDelivery` (`AppFeature.swift:102`) but never `.setDisplayName`, so the announce-app-data slice shipped a **capability nobody sees** — a reference client still shows the node unnamed. Wire it to whatever the app already knows as a user identity; if there is none, use a clearly-provisional constant and say so. Build the sibling project to confirm.

- [ ] **Step 2:** Tick the Tier 3 delivery-stamps item. Record fixing commit SHAs **inline** — never "see the task report", since `.superpowers/sdd/` is gitignored. Name enclosing functions. Do **not** re-stamp the header date unless you re-checked the untouched items.

- [ ] **Step 3: State plainly what is still not closed**, and check each claim against a run before writing it:
  - **tickets remain absent** (Tier 3's fourth item) — so a ticket-holding peer is rejected when enforcing
  - **enforcement defaults off**, so an invalid stamp is delivered, not dropped
  - whether the outbound ceiling means we **decline to stamp** for peers demanding more than `maxDeliveryStampCost` — those peers will drop our messages if *they* enforce. This is a deliberate trade: unbounded CPU versus undeliverable-to-some-peers. Say which peers it affects.

  Four documentation overclaims in this repo in the last week were the same shape — a summary sentence wider than the evidence beneath it, three of them in *corrections*. Write the tick so the qualifications are not just present but load-bearing.

- [ ] **Step 4:** Commit.

---

## Self-review notes for the implementer

- **Do not put a ceiling on the inbound path.** The cost there is ours, validation is O(1), and gating it would silently ignore our own configuration.
- **Refusing to stamp must not refuse to send.** A peer demanding an absurd cost should get an unstamped message, not nothing — they can drop it if they choose.
- **The no-stamp path must stay byte-identical.** The 167+ cross-validation vectors byte-compare against genuine Python output; run them and name them.
