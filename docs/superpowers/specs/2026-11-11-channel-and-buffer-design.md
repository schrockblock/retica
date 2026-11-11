# Channel and Buffer: design

**Date:** 2026-11-11
**Reference:** RNS 1.6.0, in the conda env `rns-latest` (`RNS/Channel.py`, `RNS/Buffer.py`, and the hooks in `RNS/Link.py` and `RNS/Packet.py`). Cite line numbers against that install.
**Worktree:** `/Users/ell/development/ios/pods/ReTiCA-worktrees/channel`, branch `feat/channel`.

## Intent

Parity with reference RNS. That is the whole goal; the user said "just parity". No ReTiCA consumer needs Channel today. The point is that a reference program using `link.get_channel()` or `RNS.Buffer` on a link to a ReTiCA node gets the same behaviour it would get from another reference node.

Today ReTiCA declares `PacketContext.channel = 0x0E` and does nothing with it. When a reference peer sends Channel messages to us, we never prove them. The peer retries five times and then tears the link down (`Channel.py:469-483`).

## Goals

1. **Channel**: reliable, ordered, windowed messaging over an established link. It must match the reference on the wire and in behaviour: the envelope format, sequence numbers and wrap-around, the receive window, duplicate handling, delivery by packet proof, retries with the reference timeout formula, window growth and shrinkage driven by RTT, and teardown when retries run out.
2. **Buffer**: byte streams over a Channel, using the system message type `0xFF00` (`StreamDataMessage`). It must match the reference's 2-byte stream header (14-bit stream id, EOF bit, compressed bit), its bz2 compression attempts, the 16 KiB chunk cap and the bound on decompressed size.
3. **A public library API** that lets a consumer open a channel on a link, register message types, send and receive typed messages, and open stream readers and writers. It is exposed through the same reducer route the existing link features use: `LinkSession` actions and delegates, forwarded by `LinkPlane`.
4. **Cross-validation that drives real RNS.** A live test runs reference Python on one end of a real link and ReTiCA on the other. It exchanges Channel messages and Buffer streams in both directions, including retries and a sequence wrap if that's feasible. Fixture vectors for the envelope and stream header come from the reference's own `pack()`, not hand-rolled bytes.

## Non-goals

- Anything that runs on top of Channel, such as `rnx` remote commands or shell sessions.
- App (ReTiCAMsgr) changes. This is library-only.
- Link MTU negotiation. Channel uses whatever link MDU we already have.
- Improving on the reference's protocol. Where the reference is quirky, we match it unless a quirk is listed below as a deliberate divergence.

## Anti-goals (failure even if it "works")

- A Channel that interoperates only with itself. Tests that run only Swift on both ends prove nothing about parity.
- Proving CHANNEL packets on a link whose channel was never opened. The reference does not (`Link.py:1234-1242`), and doing it would make a peer think messages arrived that were dropped.
- Any unbounded growth driven by the remote peer: the receive ring, stream buffers and decompression. These are now a recognised defect class in this repo.
- Narrowing a wire integer with a trapping `Int(...)` conversion (see the narrowing-conversions defect class).

## Prerequisite: packet proofs in both link roles

Channel delivery depends on link-packet proofs flowing both ways. In the reference, both ends of a link sign their proofs with their own link key (`Link.py:1276`, `prove_packet` at 463):
- the responder signs with its destination's identity key (`Link.py:303`);
- the initiator signs with an ephemeral Ed25519 key it generates per link (`Link.py:316`) and sends in the link request. The responder loads that key as `peer_sig_pub` (`load_peer`, `Link.py:411-416`) and checks proofs against it.

Today ReTiCA does each half in only one role:
- **Proving:** `.provePacket` proves only on a responder, because it requires `owningIdentity` (`LinkSession.swift:1062`).
- **Checking a proof:** only the initiator validates proofs. The `(.active, .proof, .none)` branch checks against `destinationIdentity` (`LinkSession.swift:747-753`), which is nil on a responder, and the responder doesn't keep the initiator's signing key.
- **A wrong comment:** the comment at `LinkSession.swift:1051-1056`, saying the peer "never learns" the initiator's key, is wrong. It must be corrected.

Without this, ReTiCA as initiator can't prove a reference peer's channel messages: the peer retries and tears the link down. ReTiCA as responder never sees its own channel sends delivered.

**Decision (my call, from the parity goal):**
- The plan opens with a task that brings link-packet proofs to reference parity in both roles.
  - The initiator proves with its link's ephemeral signing key.
  - The responder stores the initiator's Ed25519 key from the link request and validates proofs against it.
- **It generalises the existing `provePacket` and receipt path.** There is no Channel-only fork, because the reference has a single path.
- **Keep the F4 guards.**
  - Proving still requires an active link and a private key.
  - The signing key still comes from session state, never from an action argument.
- **Verify, don't assume, that the initiator's ephemeral `Identity` is the key whose public half goes in our link request.** If it isn't, fix it in this task.
- **Tests:** in each role, a proof from the other role validates, and a proof signed by the wrong key is rejected. Verify signatures; never byte-compare them, because ReTiCA's Ed25519 signatures are hedged.

## Reference behaviour the builder must match

### Opening
- A link has no channel until a local consumer asks for one (`Link.get_channel()`, `Link.py:1007-1014`). Opening is idempotent. Either end can open, and there is no wire handshake.
- A CHANNEL packet that arrives with no channel open is logged and dropped: no proof and no decrypt.
- With a channel open: **prove first, then decrypt, then hand to the channel** (`Link.py:1238-1242`). The proof goes out even if the envelope later fails to parse.
- Link teardown shuts the channel down (`Link.py:775`). Rings and handlers are cleared and pending sends stop.

### Envelope
- The format is `>HHH` (msgtype, sequence, payload length) followed by the payload (`Channel.py:119-135`).
- On receive, the reference reads msgtype and sequence from the header and takes the payload as `raw[6:]`. It does **not** check the length field against the payload. Match that, and add a test that pins it.
- Message types `>= 0xF000` are reserved for system use. Consumers may register only below that. `0xFF00` is `SMT_STREAM_DATA`.
- If a received envelope has an unregistered msgtype, the reference raises inside `unpack` before the envelope is placed in the receive ring. The packet has already been proven, so the sender sees it as delivered, but the receiver's expected sequence never advances.

### Receive (`Channel.py:351-397`)
- Sequences are 16-bit and wrap at `0x10000`. `WINDOW_MAX = 48`.
- **Accepted:** a sequence within `[next_rx, next_rx + WINDOW_MAX]`, with the reference's wrap rule for sequences numerically below `next_rx`.
- **Dropped silently:** anything outside that range.
- **Duplicates** (same sequence already in the ring) are dropped.
- **In-order delivery:** contiguous envelopes starting at `next_rx` are delivered in order and `next_rx` advances, including across a wrap to 0. The builder should reproduce the reference's ring-insert ordering rule (`Channel.py:322-341`), including its wrap condition.
- **Handlers** run in registration order. The first one that returns true stops the rest.

### Send (`Channel.py:495-530`)
- **Not ready:** a send fails when the number of un-proven outstanding envelopes is at or above the current window.
- **Too big:** a send fails when the packed envelope exceeds the link MDU. Channel MDU is link MDU − 6, capped at `0xFFFF`.
- **Sequence:** reserved before sending. If the send didn't go out, it's rolled back.
- **Delivery** is the link-packet proof. Each envelope has a timeout of `1.5^(tries-1) × max(rtt × 2.5, 0.025) × (txRingCount + 1.5)` seconds. Each send or retry also extends the timeouts of the other outstanding envelopes (`_update_packet_timeouts`). They may only grow.
- **On timeout:** if tries are below 5, resend. A resend re-encrypts the packet, which produces new ciphertext and so a **new packet hash** (`Packet.py:318-330`). The receipt, and with it the proof match, follow the new hash. At 5 tries the channel shuts down and **the link is torn down**.
- **Window:** start at 2, with min 2, max 5 and flexibility 4. If link RTT is above 1.45 s at open, everything is 1. Grow by one per delivery up to the max.
  - After `FAST_RATE_THRESHOLD = 10` consecutive deliveries at RTT ≤ 0.18 s, the max goes to 48 and the min to 16.
  - After 10 at RTT ≤ 0.75 s, the max goes to 12 and the min to 5.
  - On a timeout, the window shrinks by one (not below the min). The max shrinks by one while it is more than min + flexibility.
  - The constants and the exact order of operations are at `Channel.py:178-245` and `417-493`.

### Buffer (`Buffer.py`)
- **Header:** big-endian `UInt16`. The low 14 bits are the stream id (0–16383), `0x8000` is EOF and `0x4000` is compressed. The data follows.
- **Writer:**
  - Takes at most 16 KiB per write.
  - If the chunk is longer than 32 bytes, it tries bz2 on the first `len/try` bytes for tries 1 to 3. It uses the first result that is both smaller than the writer MDU (channel MDU − 2) and smaller than its input segment.
  - Otherwise it sends the first MDU bytes uncompressed.
  - A write returns the number of input bytes consumed. On "not ready" it returns 0 rather than failing.
- **Writer close:** waits (bounded) for the channel to be ready, then sends an empty EOF message.
- **Reader:** handles only stream data for its own stream id and appends it to its buffer. EOF is sticky.
  - **Decompression** is bounded at 16 KiB. If the bz2 stream doesn't finish within that, the message is invalid. The reference raises inside the handler, and the handler's exception is caught and logged.
  - **Stream ids are per direction.** A bidirectional buffer has a receive id and a send id.

## Deliberate divergences

None are planned. If the builder finds a reference behaviour that is unsafe for us (for example, unbounded on remote input), they flag it, bound it, and record it as a divergence with its reference line. They do not quietly change it.

## Decisions taken (my calls, not the user's)

- **Scope is Channel and Buffer together.** Buffer is small, it's the only built-in Channel user, and it's how most reference tools use Channel. If the plan gets large, Buffer can be its own later tasks in the same plan.
- **Where it lives:**
  - Channel state lives inside `LinkSession.State`. It's created by an explicit open action and absent until then.
  - Driving it uses `LinkSession` actions and delegates, routed by `LinkPlane` the way requests, resources and receipts already are.
  - The pure parts (envelope codec, receive ring, window arithmetic, stream header codec, writer chunking) are plain value types with their own unit tests, separate from the reducer. `ResourceWindow` is the precedent.
- **Message types:** the API speaks `(msgType: UInt16, payload: Data)`, with the consumer registering the types it accepts. There are no Swift subclasses mirroring `MessageBase`.
- **Unregistered msgtype on receive:** match the reference. Prove, drop, don't advance. Parity is the goal, and the sender's view is identical either way.
- **Readiness:** the consumer can read whether the channel is ready to send from state, as in the reference's `is_ready_to_send`. Sending while not ready yields an explicit failure result rather than a throw.
- **Retry exhaustion** closes the link with a distinct close reason, so consumers can tell a channel teardown from other closes.
- **Stream reader** delivery is a delegate event carrying stream id, bytes and EOF. A pull-style read API is up to the builder.

## Left to the builder

- Exact action and delegate names, and the shape of the Buffer API on top of the delegate events.
- How Channel per-envelope timers map onto the existing receipt and proof-deadline machinery (`sendWithReceipt` / `dataProofDeadline` / `pendingDataReceipts`). That machinery may be reused or given a Channel-specific sibling. The requirement is the reference timeout formula and timeouts that extend but never shrink.
- How the live test's reference side is scripted. Follow the existing live-test harness conventions: gated on an environment variable, a unique port, scripts committed in the repo.

## Verification

- **Unit tests** for each pure piece:
  - envelope and stream-header codecs against reference-generated vectors;
  - the receive window at and across the wrap;
  - duplicate and out-of-window drops;
  - window growth and shrinkage sequences;
  - the timeout formula;
  - writer chunking and compression choice;
  - bounded decompression.
- **Reducer tests:**
  - no channel means no proof;
  - prove before parse;
  - in-order delivery with gaps filled;
  - retry with a new packet hash;
  - teardown after 5 tries;
  - link close clears the channel.
- **The live test against reference RNS**, for messages and streams, in both link roles. In one setup ReTiCA opens the link to a reference destination. In the other, the reference opens the link to a ReTiCA destination. Each setup sends in both directions on its link and includes at least one forced retry. One role alone can pass while the other fails completely (see the prerequisite).
- **The repo's three-step mutation check** on every new test.
