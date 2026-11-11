#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0, lxmf 1.3.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_lxmf_pn_upload_signal_fixtures.py > lxmf_pn_upload_signal_fixtures.json
#
# The client side of a propagation node's upload signal: which link packets on the outbound
# propagation link make a real LXMRouter cancel the outbound message as REJECTED.
#
# Driven for real: `LXMRouter.propagation_transfer_signalling_packet` (LXMRouter.py:3035-3048), the
# packet callback reference sets on its outbound propagation link (:3292). Every signal is the bytes a
# PN would send; the PN side, `propagation_packet` (:2569-2595), sends `msgpack.packb([ERROR_INVALID_STAMP])`
# for an upload with an invalid stamp, and that encoding is recorded as `pn_reject_data`.
#
# Stubs (network edges only):
#  - `router.cancel_outbound` is replaced on the instance by a recorder of (message_id, cancel_state).
#    The real one walks `pending_outbound`; what it is called with is what this fixture is about.
#  - `FakeLXMessage` stands in for `link.for_lxmessage`: only `.message_id` is read.
#  - `FakeLink` / `FakePacket` stand in for the RNS link and packet: `packet.link.for_lxmessage`.

import json
import os
import shutil
import tempfile

import RNS
import RNS.vendor.umsgpack as msgpack
import LXMF
from LXMF.LXMRouter import LXMRouter
from LXMF.LXMPeer import LXMPeer
from LXMF.LXMessage import LXMessage

workdir = tempfile.mkdtemp(prefix="retica-pn-upload-signal-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)
RNS.loglevel = RNS.LOG_NONE     # reference logs to stdout, which is the JSON

MESSAGE_ID = RNS.Identity.full_hash(b"retica-pn-upload-signal-message")


class FakeLXMessage:
    def __init__(self, message_id): self.message_id = message_id


class FakeLink:
    def __init__(self): self.for_lxmessage = FakeLXMessage(MESSAGE_ID)


class FakePacket:
    def __init__(self): self.link = FakeLink()


router = LXMRouter(identity=RNS.Identity(), storagepath=os.path.join(workdir, "router"))
cancels = []
router.cancel_outbound = lambda message_id, cancel_state=LXMessage.CANCELLED: cancels.append((message_id, cancel_state))


def case(name, data):
    cancels.clear()
    router.propagation_transfer_signalling_packet(data, FakePacket())
    assert len(cancels) <= 1
    rejected = len(cancels) == 1
    if rejected:
        assert cancels[0] == (MESSAGE_ID, LXMessage.REJECTED)
    return {"name": name, "data": data.hex(), "rejected": rejected}


cases = [
    case("invalid-stamp-list", msgpack.packb([LXMPeer.ERROR_INVALID_STAMP])),
    case("no-identity-list", msgpack.packb([LXMPeer.ERROR_NO_IDENTITY])),
    case("invalid-stamp-bare", msgpack.packb(LXMPeer.ERROR_INVALID_STAMP)),
    case("empty-list", msgpack.packb([])),
    case("garbage", bytes([0xC1, 0xFF, 0x00, 0x13])),
    case("invalid-stamp-list-with-more", msgpack.packb([LXMPeer.ERROR_INVALID_STAMP, 1])),
    case("invalid-stamp-list-trailing-bytes", msgpack.packb([LXMPeer.ERROR_INVALID_STAMP]) + b"\x01\x02"),
    case("invalid-stamp-as-float", msgpack.packb([float(LXMPeer.ERROR_INVALID_STAMP)])),
    case("invalid-stamp-as-string", msgpack.packb(["\xf5"])),
    case("true-list", msgpack.packb([True])),
]

fixtures = {
    "constants": {"error_invalid_stamp": LXMPeer.ERROR_INVALID_STAMP, "rejected": LXMessage.REJECTED},
    "pn_reject_data": msgpack.packb([LXMPeer.ERROR_INVALID_STAMP]).hex(),
    "cases": cases,
    "versions": {"rns": RNS.__version__, "lxmf": LXMF.__version__},
}

# Guards on the generator: these only prove anything if reference really behaves this way.
by_name = {c["name"]: c for c in cases}
assert by_name["invalid-stamp-list"]["rejected"]
assert by_name["invalid-stamp-list"]["data"] == fixtures["pn_reject_data"]
assert not by_name["no-identity-list"]["rejected"]
assert not by_name["invalid-stamp-bare"]["rejected"]
assert not by_name["empty-list"]["rejected"]
assert not by_name["garbage"]["rejected"]

print(json.dumps(fixtures, indent=2))
shutil.rmtree(workdir, ignore_errors=True)
