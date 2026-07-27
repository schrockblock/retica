#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_fixtures.py > lxmf_fixtures.json
#
# Emits a genuine lxmf 1.1.0 LXMessage (fixed timestamp) so the Swift LXMessage can be cross-validated.
# source_hash / destination_hash are the parties' genuine `<identity>.lxmf.delivery` destination hashes
# (what real LXMF packs), NOT raw identity hashes. Our Swift create() derives sourceHash the same way
# (LXMessage.deliveryHash). The cross-val byte-matches the DETERMINISTIC wire regions and the message
# hash, and VALIDATES the signature (ReTiCA's Ed25519 is hedged/randomized, so the signature bytes are
# not reproducible — see the ed25519-hedged-nondeterministic note).
import json
import RNS
import LXMF

# Destination construction registers with Transport, which needs a running instance; no-op it.
RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)

src_id = RNS.Identity()
dst_id = RNS.Identity()
src = RNS.Destination(src_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(dst_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")

title = b"greeting"
content = b"hello world"
msg = LXMF.LXMessage(dst, src, content=content, title=title)
msg.timestamp = 1700000000.5      # fixed, deterministic
msg.pack()

print(json.dumps({
    "source_private_key": src_id.get_private_key().hex(),
    "destination_hash": dst.hash.hex(),      # recipient lxmf.delivery destination hash
    "source_hash": src.hash.hex(),           # sender lxmf.delivery destination hash
    "timestamp": msg.timestamp,
    "title": title.hex(),
    "content": content.hex(),
    "hash": msg.hash.hex(),
    "signature": msg.signature.hex(),
    "packed": msg.packed.hex(),
    "link_mdu": RNS.Link.MDU,
}, indent=2))
