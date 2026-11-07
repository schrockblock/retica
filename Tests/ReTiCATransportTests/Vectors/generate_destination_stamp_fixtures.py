#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_destination_stamp_fixtures.py > destination_stamp_fixtures.json
#
# Emits announces exactly as an RNS 1.6.0 destination with `stamp_destinations = yes` emits them:
# the genuine Destination._announce (Destination.py:307-379) mines the stamp over
# stamp_material() = hash + public key + name hash, appends the 18-byte extension
# `0xC1, flags, stamp, cost[1], cost[0]` (Destination.py:353-357) and signs over it. The Swift test
# owns the same destinations (private keys emitted), rehydrates the same stamps, and compares the
# extension it emits with these bytes. Signatures are NOT comparable (ReTiCA's Ed25519 is hedged),
# so only layout and the extension bytes are.
#
# destination_value is lowered to 8 so Python mines in well under a second; the value does not
# change the wire layout. Every case is then checked with the reference's own validate_announce,
# which must accept it and read back the app data (stripped) and the link cost.

import json
import os
import shutil
import tempfile

import RNS

VALUE = 8
workdir = tempfile.mkdtemp(prefix="retica-dstamp-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            f"[stamps]\n  stamp_destinations = yes\n  destination_value = {VALUE}\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)
assert RNS.Transport.STAMP_DESTINATIONS
assert RNS.Transport.DESTINATION_VALUE == VALUE

# (name, app data, link cost or None for the LR_COST default)
CASES = [
    ("with_app_data", bytes.fromhex("93c4055265546943c09100"), 3.25),
    ("no_app_data", None, None),
]

cases = []
for name, app_data, link_cost in CASES:
    identity = RNS.Identity()
    destination = RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, "retica", "dstamp", name)
    if link_cost is not None:
        destination.set_link_cost(link_cost)
    packet = destination._announce(app_data=app_data, send=False)
    packet.pack()
    raw = packet.raw

    # Guards on the generator itself: the reference must accept what it emitted.
    received = RNS.Packet(None, raw)
    received.unpack()
    payload = received.data
    ext = payload[-RNS.Identity.EXTPAYLOADLENGTH:]
    assert ext[0] == RNS.Identity.EXTPAYLOADMARKER and ext[1] == destination.get_ext_flags() == 0x00
    stamp = ext[2:2 + RNS.Identity.STAMPLENGTH]
    assert stamp == destination.stamp
    # Destination.py:354 writes the two cost bytes reversed.
    cost_bytes = RNS.Stamps.cost_to_bytes(destination.get_link_cost())
    assert ext[-2:] == bytes([cost_bytes[1], cost_bytes[0]])
    assert RNS.Identity.validate_announce(received, required_value=VALUE) is True
    assert RNS.Identity.recall_app_data(destination.hash) == app_data
    assert RNS.Identity.recall_link_cost(destination.hash) == destination.get_link_cost()

    cases.append({
        "name": name,
        "identity_private_key": identity.get_private_key().hex(),
        "app_name": "retica",
        "aspects": ["dstamp", name],
        "destination_hash": destination.hash.hex(),
        "app_data": app_data.hex() if app_data is not None else None,
        "link_cost": link_cost,
        "announced_link_cost": destination.get_link_cost(),
        "stamp": stamp.hex(),
        "stamp_value": destination.stamp_value,
        "payload": payload.hex(),
        "raw": raw.hex(),
    })

print(json.dumps({"destination_value": VALUE, "cases": cases, "versions": {"rns": RNS.__version__}}, indent=2))
shutil.rmtree(workdir, ignore_errors=True)
