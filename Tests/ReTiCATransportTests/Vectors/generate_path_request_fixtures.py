#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_path_request_fixtures.py > path_request_fixtures.json
#
# Emits RNS 1.6.0 path requests as the reference puts them on the wire: a stamped one (64 bytes,
# destination + transport ID + tag + the 16-byte 0xC1 extension) and an unstamped one (48 bytes).
#
# The stamp comes from the genuine code path, Transport.stamp_path_request(return_payload=True)
# (Transport.py:4021-4050), which mines PR_VALUE over pr_stamp_material(destination, tag). The
# payload is laid out as Transport.request_path lays it out (Transport.py:3699-3702), and the packet
# is framed by RNS.Packet against the same path-request destination request_path uses
# (Transport.py:3716-3717). The generator then checks both with the reference's own parse and
# validate helpers.
#
# The requested destination belongs to a fixed identity whose private key is emitted, so the Swift
# test can own the destination and answer.

import json
import os
import shutil
import tempfile

import RNS

workdir = tempfile.mkdtemp(prefix="retica-pr-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)
assert RNS.Transport.identity is not None, "1.6.0 path requests always carry the transport ID"

identity = RNS.Identity()
destination = RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, "retica", "prtest")

tag, ext_payload = RNS.Transport.stamp_path_request(destination.hash, return_payload=True)
transport_id = RNS.Transport.identity.hash
stamped_data = destination.hash + transport_id + tag + ext_payload
unstamped_data = destination.hash + transport_id + tag

path_request_dst = RNS.Destination(None, RNS.Destination.OUT, RNS.Destination.PLAIN,
                                   RNS.Transport.APP_NAME, "path", "request")


def framed(data):
    packet = RNS.Packet(path_request_dst, data, packet_type=RNS.Packet.DATA,
                        transport_type=RNS.Transport.BROADCAST, header_type=RNS.Packet.HEADER_1)
    packet.pack()
    return packet.raw


# Guards on the generator itself.
assert len(stamped_data) == RNS.Transport.PR_STAMPED_LENGTH == 64
assert len(unstamped_data) == RNS.Transport.PR_LENGTH == 48
assert ext_payload[0] == RNS.Identity.EXTPAYLOADMARKER and ext_payload[1] == 0x00
parsed = RNS.Transport.parse_path_request(stamped_data)
assert parsed == (destination.hash, transport_id, tag, ext_payload)
stamp = ext_payload[RNS.Transport.PR_EXT_HEADERLENGTH:]
assert RNS.Transport.validate_pr_stamp(stamp, destination.hash, tag, required_value=RNS.Transport.PR_COST)
assert RNS.Transport.parse_path_request(unstamped_data) == (destination.hash, transport_id, tag, None)

fixtures = {
    "identity_private_key": identity.get_private_key().hex(),
    "app_name": "retica",
    "aspects": ["prtest"],
    "destination_hash": destination.hash.hex(),
    "transport_id": transport_id.hex(),
    "tag": tag.hex(),
    "ext_payload": ext_payload.hex(),
    "pr_cost": RNS.Transport.PR_COST,
    "pr_value": RNS.Transport.PR_VALUE,
    "path_request_destination_hash": path_request_dst.hash.hex(),
    "stamped_raw": framed(stamped_data).hex(),
    "unstamped_raw": framed(unstamped_data).hex(),
    "versions": {"rns": RNS.__version__},
}

print(json.dumps(fixtures, indent=2))
shutil.rmtree(workdir, ignore_errors=True)
