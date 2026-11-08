#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0) by absolute path, from this directory:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_link_request_stamp_fixtures.py > link_request_stamp_fixtures.json
#
# Emits two RNS 1.6.0 LINKREQUEST packets to one destination, as the reference puts them on the wire:
#   * stamped:   RNS.Link with ALWAYS_STAMP_LRS on, so Link.__initiate (Link.py:344-382) mines an X25519
#                key meeting LR_COST over `destination.hash + sig_pub_bytes` before it builds the request.
#   * unstamped: RNS.Link with ALWAYS_STAMP_LRS off and no announced cost, so an ordinary random key.
# Both carry the 3-byte MTU signalling, so the payload is 67 bytes.
#
# The generator then runs each through the reference's own receiving check, Link.validate_request
# with LR_STAMPS_ENFORCED on (Link.py:187-199), and asserts it accepts the stamped request and refuses
# the unstamped one. The destination belongs to a fixed identity whose private key is emitted, so the
# Swift test can own the destination.

import json
import os
import shutil
import tempfile
import time

import RNS
from RNS import Stamps

workdir = tempfile.mkdtemp(prefix="retica-lr-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)

identity = RNS.Identity()
inbound = RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, "retica", "lrtest")
outbound = RNS.Destination(identity, RNS.Destination.OUT, RNS.Destination.SINGLE, "retica", "lrtest")
assert inbound.hash == outbound.hash
lr_cost = RNS.Transport.LR_COST
assert lr_cost == 12.5 and inbound.get_link_cost() == lr_cost


def request_of(link, seconds):
    deadline = time.time() + seconds
    while link.link_id is None and time.time() < deadline:
        time.sleep(0.05)
    assert link.link_id is not None, "the link request was never built"
    return link.packet.raw, link.pub_bytes, link.sig_pub_bytes


RNS.Transport.ALWAYS_STAMP_LRS = True
stamped_raw, stamped_pub, stamped_sig_pub = request_of(RNS.Link(outbound), 120)
RNS.Transport.ALWAYS_STAMP_LRS = False
unstamped_raw, unstamped_pub, unstamped_sig_pub = request_of(RNS.Link(outbound), 5)

# Guards on the generator itself.
assert Stamps.stamp_valid(stamped_pub, lr_cost, inbound.hash + stamped_sig_pub)
assert not Stamps.stamp_valid(unstamped_pub, lr_cost, inbound.hash + unstamped_sig_pub), \
    "a random key met the cost (about one time in 5,800): run again"


def reference_accepts(raw):
    packet = RNS.Packet(None, raw)
    packet.unpack()
    assert packet.packet_type == RNS.Packet.LINKREQUEST and packet.destination_hash == inbound.hash
    assert len(packet.data) == RNS.Link.ECPUBSIZE + RNS.Link.LINK_MTU_SIZE
    packet.destination = inbound
    return RNS.Link.validate_request(inbound, packet.data, packet) is not None


RNS.Transport.LR_STAMPS_ENFORCED = True
assert reference_accepts(stamped_raw), "the reference refused its own stamped request"
assert not reference_accepts(unstamped_raw), "the reference accepted an unstamped request"
RNS.Transport.LR_STAMPS_ENFORCED = False

fixtures = {
    "identity_private_key": identity.get_private_key().hex(),
    "app_name": "retica",
    "aspects": ["lrtest"],
    "destination_hash": inbound.hash.hex(),
    "lr_cost": lr_cost,
    "stamped_raw": stamped_raw.hex(),
    "stamped_value": Stamps.stamp_value(inbound.hash + stamped_sig_pub, stamped_pub),
    "unstamped_raw": unstamped_raw.hex(),
    "unstamped_value": Stamps.stamp_value(inbound.hash + unstamped_sig_pub, unstamped_pub),
    "versions": {"rns": RNS.__version__},
}

print(json.dumps(fixtures, indent=2), flush=True)
shutil.rmtree(workdir, ignore_errors=True)
# The links' watchdog threads would otherwise keep the process alive until they time out.
os._exit(0)
