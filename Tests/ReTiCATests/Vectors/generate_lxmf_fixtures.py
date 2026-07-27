#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_fixtures.py > lxmf_fixtures.json
#
# Emits a genuine lxmf 1.1.0 LXMessage (fixed timestamp) so the Swift LXMessage can be cross-validated:
# our create() must reproduce .packed/.hash/.signature byte-for-byte, and our unpack() must recover
# the fields and validate the signature.
#
# NOTE: We patch src.hash = src_id.hash before packing so that the source hash in the packed message
# is the identity hash (SHA-256(pubkey)[:16]) — the same value our Swift LXMessage.create() uses
# (Identity.hash). Reference LXMF would use the delivery-destination hash for src.hash, but our
# LXMF-1 implementation uses identity hash directly. All signing/hashing/msgpack logic is genuine.
import json
import RNS
import LXMF

# Destination construction registers with Transport, which needs a running instance; no-op it.
RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)

src_id = RNS.Identity()
dst_id = RNS.Identity()
src = RNS.Destination(src_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(dst_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")

# Override src.hash to the identity hash so packed[16:32] == src_id.hash, matching our
# LXMessage.create() which uses source.hash (Identity.hash = SHA-256(pubkey)[:16]).
src.hash = src_id.hash

title = b"greeting"
content = b"hello world"
msg = LXMF.LXMessage(dst, src, content=content, title=title)
msg.timestamp = 1700000000.5      # fixed, deterministic
msg.pack()

print(json.dumps({
    "source_private_key": src_id.get_private_key().hex(),
    "destination_hash": dst.hash.hex(),
    "source_hash": src_id.hash.hex(),
    "timestamp": msg.timestamp,
    "title": title.hex(),
    "content": content.hex(),
    "hash": msg.hash.hex(),
    "signature": msg.signature.hex(),
    "packed": msg.packed.hex(),
}, indent=2))
