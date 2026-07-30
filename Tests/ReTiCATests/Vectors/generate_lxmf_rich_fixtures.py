#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_rich_fixtures.py > lxmf_rich_fixtures.json
#
# Emits a genuine lxmf 1.1.0 LXMessage WITH integer-keyed fields (FIELD_TICKET=0x0C bytes,
# FIELD_RENDERER=0x0F uint) so the Swift LXMessage rich-fields packing can be byte-cross-validated.
# Fields are inserted in ascending-key order so the msgpack map order is deterministic and matches the
# Swift ordered [IntPair]. The signature is hedged/randomized (validated, not byte-compared).
import json
import RNS
import LXMF

RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)

src_id = RNS.Identity()
dst_id = RNS.Identity()
src = RNS.Destination(src_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(dst_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")

title = b"greeting"
content = b"hello fields"
field_ticket = bytes.fromhex("0011223344556677")
field_renderer = LXMF.RENDERER_MARKDOWN   # 0x02
fields = {LXMF.FIELD_TICKET: field_ticket, LXMF.FIELD_RENDERER: field_renderer}   # keys 0x0C, 0x0F

msg = LXMF.LXMessage(dst, src, content=content, title=title, fields=fields)
msg.timestamp = 1700000000.5
msg.pack()

print(json.dumps({
    "source_private_key": src_id.get_private_key().hex(),
    "destination_hash": dst.hash.hex(),
    "timestamp": msg.timestamp,
    "title": title.hex(),
    "content": content.hex(),
    "field_ticket": field_ticket.hex(),
    "field_renderer": field_renderer,
    "hash": msg.hash.hex(),
    "signature": msg.signature.hex(),
    "packed": msg.packed.hex(),
}, indent=2))
