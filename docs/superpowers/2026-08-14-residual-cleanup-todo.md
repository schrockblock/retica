# Cleanup TODO — four parked residuals from the destructive-transition slice

## ✅ DONE — all four items, `d9e3a05`. Suite 835 + the one known issue, unchanged.

**Two things a future reader should take from how this went, both about this file
rather than about the items:**

1. **Item 1's table was incomplete.** It listed five occurrences of the permanence
   overstatement; there were **six**. The missing one is in **F9's third-order
   consequence** — *"Replays faster than the window therefore mean the transfer
   never terminates at all"* — added by the same commit (`c47443b`) as the others.
   A fresh `git grep -e` over the pair found it; inheriting the table would not
   have. This file's own instruction to verify rather than comply is what caught
   it, and the lesson is now recorded in the sweep's §6.
2. **The corrections needed correcting, exactly as this file predicted.** Five
   defects were caught in my own new text during self-review, before the commit:
   a paragraph I orphaned onto the wrong parent, a citation placing the host
   `.cancel` inside `ResourceTransfer.received` when it is a reducer ACTION, an
   inline code span broken across a line, and two sentences wider than their
   evidence (*"nothing ever reclaims the leaked entry"* as a bare universal, and
   *"closing it means scoping duplicate sends"* — which ignores that a per-chain
   `segmentedSend` would also close it).

**One same-shape claim was deliberately NOT touched**, flagged here rather than
edited: F9's *second*-order consequence says one captured advertisement replayed
on a cycle *"keeps `transfers` permanently non-empty."* Same over-wide flavour, but
it is a different finding, it states its condition inline, and Item 1 scoped this
pass to F19's claim. Narrow it in a pass that owns F9.

**Written:** 2026-08-14, at HEAD `c702ddf`.
**Suite at HEAD:** 835 passing, 1 known issue
(`holdArmsDeferredReleaseTimerNotImmediateFireDuringFlood`, `TransportTests`,
pre-existing). **This is a documentation-only pass — no production code changes,
and the test count must not move.**

These four were found by the final whole-branch review and its scoped re-review,
adjudicated as real-but-not-merge-blocking, and parked. Each is small. Together
they are one commit, or at most two.

---

## ⚠️ Read this before touching anything

**This is a CORRECTIONS pass, which is the highest-risk kind of edit in these
documents.** Over five consecutive rounds on this same pair of files, *every*
defect had the same shape — **a sentence wider than the evidence supporting it**
— and sat in one of exactly two positions: a `safe` verdict's stated
justification, or **a paragraph whose job was correcting an earlier claim**.
Rounds 1 and 2 each introduced new Important defects via their own fixes.

Three rules, all learned here, all recorded in the sweep's §6:

1. **State the narrowest claim your evidence supports, then check whether the
   sentence you actually wrote is wider than that.**
2. **Narrow the wrong clause; do not invert the paragraph.** Over-correcting once
   swept up a correct rationale *and* a coverage claim that one grep falsified.
3. **The twin rule — when a claim lives in both documents, fix both or neither.**
   A one-sided correction is *worse* than leaving both wrong, because the wider
   statement survives in the document nobody is reading at the time and the
   disagreement is invisible. **Item 1 below exists precisely because this rule
   was violated one commit after being written.**

**Verify every quoted string and every claim below against the code yourself
before acting.** During this slice, three relayed findings from the controller
turned out to be false or numerically wrong, and each was caught only because the
implementer checked rather than complied. Assume the same of this file.

---

## Item 1 — the permanence overstatement is one-sided (MOST IMPORTANT)

**What happened.** Commit `c702ddf` narrowed the claim in the sweep but left the
handoff wide. The sweep now reads (verified present):

> `…destructive-transition-sweep.md`: "transfer makes a RESPONDER link
> un-evictable **for as long as the pin holds**, and once nothing is …"

The handoff still carries absolutes. **I verified five occurrences; check each in
context, because they may not all be the same claim:**

| File | Quoted string to search for |
|---|---|
| handoff | `postpones the sender watchdog for ever, so` |
| handoff | `the transfer never ends and its responder link is never evictable` |
| handoff | `RESOURCE_REQ` … `postponing the sender watchdog for ever, which pins the transfer` |
| handoff | `exists for — never ends.` |
| handoff | `link becomes permanently un-evictable, and once nothing is evictable the plane` |

**What is actually true** (verify before writing): F19's pin holds only while the
transfer's peer stays silent. A valid proof (`(.sender, .proof, .resourceProof)`
→ `.complete`), a `RESOURCE_RCL`, or a host `.cancel` each still terminate it.
`proofRetriesLeft` is decremented in exactly one place — `.senderDeadline`'s
`.awaitingProof` branch — and a replayed `RESOURCE_REQ` re-arms the watchdog
before that decrement lands, which is *why* it never counts down. "Unbounded
while replayed" is true; "never ends" unconditionally is not.

**Required:** bring the handoff's wording into line with the sweep's, at every
site where the claim is the same one. Do not merely soften — say what bounds it.

**Note and record:** commit `c47443b`'s SUBJECT LINE is
`docs: F19 — a replayed RESOURCE_REQ postpones the sender watchdog for ever`.
That message is pushed and cannot be corrected. Add a one-line note where F19 is
defined saying the commit subject overstates, so a reader following git blame is
not misled.

---

## Item 2 — the sweep's probe-level claim is now false at HEAD

**Quoted string to search for**, in the sweep's §6 method notes:

> `Every probe in this document is REDUCER-level, and the endpoint boundary has a trap that makes`

It is falsified by the same document, in two places added by the same fix wave —
search for `through production wiring`, which appears in the F17 reachability
paragraph and again in the F19 paragraph.

**Also check the sentence immediately after it**, which generalises the final
review's composition run to the whole probe set. The review re-ran composition
equivalents of roughly five of the document's probes, not all of them.

**Required:** narrowest supportable form is something like *"the sweep's own
probes were reducer-level except where a paragraph says otherwise; the final
review re-ran composition equivalents of several and the claims those cover
held."* Verify the actual counts before writing any number — or write none.

**Do not delete the HDLC trap itself.** It is correct and valuable:
`TCPClientInterface` deframes with HDLC, so unframed bytes handed to
`TCPEvent.data` are silently swallowed and never reach `Transport.received`. A
probe that injects unframed bytes measures nothing while printing reassuring
state. The guard is a positive control — inject N frames, assert N
`transport.received`.

---

## Item 3 — F19's "Above F7" argument has a clause that argues the wrong comparison, AND it has a twin

**Quoted strings to search for**, both in the handoff:

> `Above F7`, because the consequences are not comparable in kind: F7 leaks a map …
> And F19 has a cheap, reference-blessed partial already specified — F9's …

and, in the §3 priority list:

> entry, and its cheapest fix (F9's `req_hashlist`) is already specified. Full

**The problem.** "F19 has a cheap fix already specified" argues F19 over **F11**
(whose fix is its own slice), not over **F7** — whose fix is *cheaper still*,
roughly two lines: capture `linkID` before `directLinks[dest] = nil` in
`LXMFRouter.idleDeadline`. As a reason to outrank F7 it is backwards.

**Required:** drop the cost clause from the "Above F7" bullet. The severity
argument carries the rank on its own — per instance F19 pins a whole
`ResourceTransfer.State` plus the `LinkSession` element and denies every new
responder peer once at `maxResponderLinks`, where F7 leaks a map entry.

**Also add the missing counterweight:** F7's one advantage over F19 is that it
needs no attacker and never stops. That is currently unstated anywhere, and a
rank argument that omits the opposing consideration is the same over-wide shape
as everything else on this list.

**Twin rule applies:** the clause appears in both the §3 priority list and the
F19 entry. Fix both.

---

## Item 4 — an unrecorded lead (additive, no correction needed)

`LinkSession.State.segmentedSend` is a **single optional**, keyed on
`currentTransferID`. The F17/F15 duplication chain — two `sendResource` calls on
one link, which `LXMFRouter.retryDue` produces routinely for any resource-framed
message slower than `retryWaitSeconds` — therefore **clobbers it for any payload
above `maxEfficientSize`**, stranding the first multi-segment send's continuation
state.

Verify this before recording it. Neither document mentions it today. Add a line
to F17 in whichever document is the right home (probably the handoff's F17, with
the sweep's F17 outline pointing at it — **twin rule**), framed as a lead for
whoever takes F17, not as a new numbered finding.

---

## Global constraints for the cleanup commit(s)

- **Commit directly to `main`.** No feature branch — standing project convention.
- **Commit trailers MUST start at column 0** or git cannot parse them:
  ```
  Co-Authored-By: Claude <noreply@anthropic.com>
  Claude-Session: <the session URL>
  ```
  Verify with `git log -1 --format='%(trailers:key=Claude-Session)'` — empty
  output means it did not parse.
- **Cite SYMBOLS, not line numbers.** Line citations in this repo have drifted
  repeatedly, once invalidated by the very commit that wrote them.
- **No derived arithmetic in prose.** Name the constants; the executable figures
  live in the tests.
- **Run `swift test --no-parallel` and READ the output.** Expect 835 passing and
  the one known issue, unchanged — this pass changes no code.
- **Do not write property claims you have not verified.**

## Background, if you want it

- The slice that produced these: `docs/superpowers/plans/2026-08-13-destructive-transitions-need-authentication.md`
  and its spec in `docs/superpowers/specs/`.
- The two artifacts being corrected:
  `docs/superpowers/2026-08-13-destructive-transition-sweep.md` and
  `docs/superpowers/2026-08-10-handoff-link-lifecycle-and-delivery-termination.md`.
- F19, F17, F18, F7 and F11 are all defined in the handoff's §3 / §3b / §3c.
