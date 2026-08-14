#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_signed_fixtures.py > lxmf_signed_fixtures.json
#
# Emits a genuine lxmf 1.1.0 LXMessage whose `fields` carry NEGATIVE integers — the shape the
# Tier-1 data-loss defect discards whole. FIELD_TELEMETRY holds an array of negatives that crosses
# every signed-width boundary umsgpack._pack_integer can pick (negative fixint, int8, int16, int32,
# int64) plus a realistic pair of scaled coordinates, which is what really shows up in the wild.
#
# Fields are inserted in ascending-key order so the msgpack map order is deterministic and matches
# the Swift ordered [IntPair]. The signature is hedged/randomized → validated, not byte-compared;
# the payload region and the message hash ARE byte-compared.
import json
import RNS
import LXMF

RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)

src_id = RNS.Identity()
dst_id = RNS.Identity()
src = RNS.Destination(src_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(dst_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")

title = b"telemetry"
content = b"position report"

# One value per signed encoding umsgpack can choose, then two scaled coordinates
# (latitude -33.8688, longitude -151.2093 at 1e6 scale) — the routine real-world case.
telemetry = [-1, -33, -129, -32769, -2147483649, -33868800, -151209300]
fields = {LXMF.FIELD_TELEMETRY: telemetry, LXMF.FIELD_RENDERER: LXMF.RENDERER_PLAIN}

msg = LXMF.LXMessage(dst, src, content=content, title=title, fields=fields)
msg.timestamp = 1700000000.5
msg.pack()

print(json.dumps({
    "source_private_key": src_id.get_private_key().hex(),
    "destination_hash": dst.hash.hex(),
    "timestamp": msg.timestamp,
    "title": title.hex(),
    "content": content.hex(),
    "telemetry": [str(v) for v in telemetry],
    "renderer": LXMF.RENDERER_PLAIN,
    "hash": msg.hash.hex(),
    "signature": msg.signature.hex(),
    "packed": msg.packed.hex(),
}, indent=2))
