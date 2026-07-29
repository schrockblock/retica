#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_propagation_fixtures.py > lxmf_propagation_fixtures.json
#
# Emits a genuine lxmf 1.1.0 PROPAGATED LXMessage's propagation container so LXMFPropagation can be
# cross-validated. The container timestamp is pinned via a fixed time.time so propagation_packed is
# reproducible. NO propagation stamp (LXMF-5 concern), so the container entry equals the transient_id
# preimage. The destination-encrypted tail inside lxmf_data is hedged/ephemeral (not byte-reproducible),
# so only the deterministic container structure + transient_id (full_hash of the given bytes) are pinned.
import json
import time
import RNS
import LXMF

# Destination construction registers with Transport, which needs a running instance; no-op it.
RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)
time.time = lambda: 1700000000.5      # pin the container timestamp (LXMessage.pack uses time.time())

src_id = RNS.Identity()
dst_id = RNS.Identity()
src = RNS.Destination(src_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(dst_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")

title = b"greeting"
content = b"hello propagation"
msg = LXMF.LXMessage(dst, src, content=content, title=title, desired_method=LXMF.LXMessage.PROPAGATED)
msg.timestamp = 1700000000.5
msg.pack()

print(json.dumps({
    "source_private_key": src_id.get_private_key().hex(),
    "recipient_private_key": dst_id.get_private_key().hex(),
    "destination_hash": dst.hash.hex(),          # recipient lxmf.delivery destination hash
    "title": title.hex(),
    "content": content.hex(),
    "container_timestamp": 1700000000.5,
    "transient_id": msg.transient_id.hex(),
    "propagation_packed": msg.propagation_packed.hex(),
}, indent=2))
