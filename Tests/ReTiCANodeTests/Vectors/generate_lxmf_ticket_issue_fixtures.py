#!/usr/bin/env python
# Run in the conda `rns-latest` env (LXMF 1.3.0 / RNS 1.6.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_lxmf_ticket_issue_fixtures.py
#
# The FIELD_TICKET a ticket ISSUER puts in its message (LXMRouter.generate_ticket, LXMRouter.py:1205-1228,
# set before pack at :2098-2102): fields[0x0C] = [now + TICKET_EXPIRY, ticket]. Every input is fixed, so
# reference's message_id and packed payload are deterministic. The values printed here are pasted into
# LXMFNodeTicketIssueTests.swift (`issueFixture`), where ReTiCA builds the same message with the field
# from LXMFNode.State.ticketFieldToIssue and must produce the same message_id and payload bytes.
# Equal bytes are bytes reference produced, and (below) bytes whose FIELD_TICKET passes the structural
# checks reference's receiver applies before remembering a ticket (lxmf_delivery, LXMRouter.py:2176-2184).
# The signature is excluded from the comparison: ReTiCA's Ed25519 signatures are randomized and the
# signature is not part of the message_id.
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


def check(cond, what):
    if not cond:
        sys.exit(f"reference check failed: {what}")


def delivery(identity, direction):
    return RNS.Destination(identity, direction, RNS.Destination.SINGLE, "lxmf", "delivery")


src_prv = bytes.fromhex("33" * 32 + "44" * 32)   # the issuer (ReTiCA side)
dst_prv = bytes.fromhex("55" * 32 + "66" * 32)   # the peer the ticket is issued to
src_id = RNS.Identity.from_bytes(src_prv)
dst_id = RNS.Identity.from_bytes(dst_prv)
src = delivery(src_id, RNS.Destination.IN)
dst = delivery(dst_id, RNS.Destination.OUT)

now = 1700000000.5
ticket = bytes(range(0xA0, 0xB0))
expires = now + LXMessage.TICKET_EXPIRY          # generate_ticket: expires = now+expiry (a float)

m = LXMF.LXMessage(dst, src, content=b"have a ticket", title=b"t", fields={FIELD_TICKET: [expires, ticket]})
m.timestamp = now
m.pack()

rx = LXMF.LXMessage.unpack_from_bytes(m.packed)
entry = rx.fields.get(FIELD_TICKET)
check(type(entry) == list and len(entry) > 1, "FIELD_TICKET is a list of at least two")
check(type(entry[0]) == float and entry[0] == expires, "expires is the float now+TICKET_EXPIRY")
check(type(entry[1]) == bytes and len(entry[1]) == LXMessage.TICKET_LENGTH, "ticket is 16 bytes")
check(rx.message_id == m.message_id, "message_id round-trips")

header = 2 * 16 + 64   # destination hash, source hash, signature
print(f"source_private_key = {src_prv.hex()}")
print(f"destination_hash   = {dst.hash.hex()}")
print(f"timestamp/now      = {now!r}")
print(f"expires            = {expires!r}")
print(f"ticket             = {ticket.hex()}")
print(f"message_id         = {m.message_id.hex()}")
print(f"payload            = {m.packed[header:].hex()}")
