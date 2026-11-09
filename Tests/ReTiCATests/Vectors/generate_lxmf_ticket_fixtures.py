#!/usr/bin/env python
# Run in the conda `rns-latest` env (LXMF 1.3.0 / RNS 1.6.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_lxmf_ticket_fixtures.py > lxmf_ticket_fixtures.json
#
# Emits genuine LXMF 1.3.0 messages stamped with a TICKET (stamp = RNS.Identity.truncated_hash(ticket +
# message_id), LXMessage.py:303-310), for both cross-validation directions:
#
#   "inbound"  — reference -> ReTiCA. A peer's message to us carrying FIELD_TICKET = [expires, ticket]
#                (a ticket the peer gives US) and stamped with the ticket WE issued to the peer. The
#                peer advertises no stamp cost (stamp_cost=None): reference attaches the ticket stamp
#                anyway, because get_stamp checks the outbound ticket before the cost. ReTiCA must
#                unpack it, validate its signature, validate the stamp against the issued ticket, and
#                read the FIELD_TICKET entry. Identities are random; the bytes are what they are.
#
#   "outbound" — ReTiCA -> reference. Every input is FIXED (keys, timestamp, title, content, ticket),
#                so the message_id and the ticket stamp are deterministic. ReTiCA builds the same
#                message from the same inputs; its message_id, ticket stamp and stamped payload must
#                equal these bytes, which reference itself produced and (below) validates. Equal bytes
#                are therefore bytes reference accepts — the ReTiCA->reference direction without a
#                Swift artefact having to be fed back into Python. (Ed25519 signatures are excluded
#                from the comparison: ReTiCA's are randomized; the signature is not in the hash.)
#
# Each case is checked against reference's own validate_stamp(target_cost, tickets=...) here, with a
# wrong-ticket control that must fail, so the JSON never records a stamp reference would reject.
import json
import logging
import sys

logging.disable(logging.CRITICAL)

import RNS
RNS.loglevel = -1
import LXMF
from LXMF import LXMessage

RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)

FIELD_TICKET = LXMF.FIELD_TICKET
assert FIELD_TICKET == 0x0C
assert LXMessage.TICKET_LENGTH == 16
TARGET_COST = 8   # validate_stamp's PoW fallback at this cost rejects a non-ticket stamp 255 times in 256


def check(cond, what):
    if not cond:
        sys.exit(f"reference check failed: {what}")


def delivery(identity, direction):
    return RNS.Destination(identity, direction, RNS.Destination.SINGLE, "lxmf", "delivery")


# --- inbound: reference -> ReTiCA ------------------------------------------------------------------
peer_id = RNS.Identity()          # the sender
us_id = RNS.Identity()            # the recipient (ReTiCA)
peer = delivery(peer_id, RNS.Destination.IN)
us = delivery(us_id, RNS.Destination.OUT)

issued_to_peer = RNS.Identity.get_random_hash()[:LXMessage.TICKET_LENGTH]   # a ticket WE issued to peer
given_to_us = RNS.Identity.get_random_hash()[:LXMessage.TICKET_LENGTH]      # a ticket peer gives US
expires = 1700000000.5 + LXMessage.TICKET_EXPIRY                            # a unix float, as reference sends

inbound = LXMF.LXMessage(us, peer, content=b"ticketed reply", title=b"t",
                         fields={FIELD_TICKET: [expires, given_to_us]})
inbound.timestamp = 1700000000.5
inbound.outbound_ticket = issued_to_peer
inbound.defer_stamp = False
inbound.pack()
check(inbound.stamp == RNS.Identity.truncated_hash(issued_to_peer + inbound.message_id), "inbound ticket stamp")
check(len(inbound.stamp) == 16, "ticket stamp is 16 bytes")

# Reference's receive side, on the exact wire bytes.
rx = LXMF.LXMessage.unpack_from_bytes(inbound.packed)
check(rx.validate_stamp(TARGET_COST, tickets=[issued_to_peer]) is True, "reference accepts with the issued ticket")
check(rx.stamp_value == LXMessage.COST_TICKET, "ticket stamp value is COST_TICKET")
wrong_ticket = bytes(16)
rx2 = LXMF.LXMessage.unpack_from_bytes(inbound.packed)
check(rx2.validate_stamp(TARGET_COST, tickets=[wrong_ticket]) is False, "reference rejects with another ticket")
check(rx2.fields[FIELD_TICKET] == [expires, given_to_us], "FIELD_TICKET round-trips")

# --- outbound: ReTiCA -> reference (all inputs fixed) ----------------------------------------------
src_prv = bytes.fromhex("33" * 32 + "44" * 32)
dst_prv = bytes.fromhex("55" * 32 + "66" * 32)
src_id = RNS.Identity.from_bytes(src_prv)
dst_id = RNS.Identity.from_bytes(dst_prv)
src = delivery(src_id, RNS.Destination.IN)
dst = delivery(dst_id, RNS.Destination.OUT)
ticket = bytes(range(0xA0, 0xB0))

outbound = LXMF.LXMessage(dst, src, content=b"ticketed hello", title=b"greeting")
outbound.timestamp = 1700000000.5
outbound.outbound_ticket = ticket
outbound.defer_stamp = False
outbound.pack()
check(outbound.stamp == RNS.Identity.truncated_hash(ticket + outbound.message_id), "outbound ticket stamp")
rx3 = LXMF.LXMessage.unpack_from_bytes(outbound.packed)
check(rx3.validate_stamp(TARGET_COST, tickets=[ticket]) is True, "reference accepts the outbound ticket stamp")
rx4 = LXMF.LXMessage.unpack_from_bytes(outbound.packed)
check(rx4.validate_stamp(TARGET_COST, tickets=[wrong_ticket]) is False, "reference rejects the wrong ticket")

print(json.dumps({
    "lxmf_version": LXMF.__version__ if hasattr(LXMF, "__version__") else "unknown",
    "target_cost": TARGET_COST,
    "cost_ticket": LXMessage.COST_TICKET,
    "inbound": {
        "source_private_key": peer_id.get_private_key().hex(),
        "source_hash": peer.hash.hex(),
        "destination_hash": us.hash.hex(),
        "issued_ticket": issued_to_peer.hex(),
        "wrong_ticket": wrong_ticket.hex(),
        "field_ticket_expires": expires,
        "field_ticket": given_to_us.hex(),
        "message_id": inbound.message_id.hex(),
        "stamp": inbound.stamp.hex(),
        "packed": inbound.packed.hex(),
    },
    "outbound": {
        "source_private_key": src_prv.hex(),
        "destination_hash": dst.hash.hex(),
        "timestamp": outbound.timestamp,
        "title": b"greeting".hex(),
        "content": b"ticketed hello".hex(),
        "ticket": ticket.hex(),
        "message_id": outbound.message_id.hex(),
        "stamp": outbound.stamp.hex(),
        "packed": outbound.packed.hex(),
    },
}, indent=2))
