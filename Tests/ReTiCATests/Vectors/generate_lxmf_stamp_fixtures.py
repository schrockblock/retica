#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_stamp_fixtures.py > lxmf_stamp_fixtures.json
#
# Emits a genuine lxmf 1.1.0 stamped LXMessage plus the LXStamper artefacts so the Swift LXStamper and
# LXMessage stamp handling can be cross-validated. Stamp cost is small (8) so generation is fast. The
# workblock is 768 KB, so we emit its full_hash (compact) rather than the block itself. The stamp is a
# PoW search result (not reproducible), so the Swift byte-parity test attaches THIS exact stamp.
import json
import logging
import sys

# Suppress RNS log output that goes to stdout
logging.disable(logging.CRITICAL)

import RNS
RNS.loglevel = -1
import LXMF
import LXMF.LXStamper as LXStamper

RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)

src_id = RNS.Identity()
dst_id = RNS.Identity()
src = RNS.Destination(src_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(dst_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")

title = b"greeting"
content = b"hello stamp"
stamp_cost = 8
msg = LXMF.LXMessage(dst, src, content=content, title=title, stamp_cost=stamp_cost)
msg.timestamp = 1700000000.5
msg.defer_stamp = False        # generate the stamp during pack()
msg.pack()

message_id = msg.hash          # stamp is bound to the message_id (= hash over the 4-element payload)
stamp = msg.stamp
workblock = LXStamper.stamp_workblock(message_id)
workblock_hash = RNS.Identity.full_hash(workblock)
stamp_value = LXStamper.stamp_value(workblock, stamp)

print(json.dumps({
    "source_private_key": src_id.get_private_key().hex(),
    "destination_hash": dst.hash.hex(),
    "timestamp": msg.timestamp,
    "title": title.hex(),
    "content": content.hex(),
    "stamp_cost": stamp_cost,
    "message_id": message_id.hex(),
    "stamp": stamp.hex(),
    "workblock_hash": workblock_hash.hex(),
    "stamp_value": stamp_value,
    "hash": msg.hash.hex(),
    "signature": msg.signature.hex(),
    "packed": msg.packed.hex(),
}, indent=2))
