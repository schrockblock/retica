#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0, lxmf 1.3.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_lxmf_stamped_announce_fixtures.py > lxmf_stamped_announce_fixtures.json
#
# Emits announce app_data as RNS 1.6.0 / LXMF 1.3.0 really put it on the wire, including the
# 18-byte network-stamp extension that Destination._announce appends (Destination.py:348-357),
# and what the reference's own helpers read back from those bytes.
#
# The bytes come from the genuine code paths: a real LXMRouter, a real delivery / propagation
# destination, and Destination.announce(send=False). Only the two "post_1_6_2" cases are built by
# hand, because that format does not ship yet: it is the commented-out shape at
# LXMRouter.py:1180 and the comment at LXMRouter.py:399. They are still checked against the
# reference helpers below.

import json
import os
import shutil
import tempfile

import RNS
import RNS.vendor.umsgpack as msgpack
import LXMF

workdir = tempfile.mkdtemp(prefix="retica-stamped-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    # Low destination_value keeps generation fast. The value does not change the wire layout.
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[stamps]\n  stamp_destinations = yes\n  destination_value = 8\n  destination_cost = 8\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)
assert RNS.Transport.STAMP_DESTINATIONS


def wire_app_data(destination, app_data=None):
    """Slice app_data back out of the real announce packet (Identity.py:824-828)."""
    assert destination._await_stamp()
    packet = destination._announce(app_data=app_data, send=False)
    fixed = RNS.Identity.KEYSIZE // 8 + RNS.Identity.NAME_HASH_LENGTH // 8 + 10
    if packet.context_flag == RNS.Packet.FLAG_SET:
        fixed += RNS.Identity.RATCHETSIZE // 8
    return packet.data[fixed + RNS.Identity.SIGLENGTH // 8:]


def router(name, **kwargs):
    return LXMF.LXMRouter(identity=RNS.Identity(), storagepath=os.path.join(workdir, name), **kwargs)


def delivery_case(raw):
    return {"packed": raw.hex(),
            "display_name": LXMF.display_name_from_app_data(raw),
            "stamp_cost": LXMF.stamp_cost_from_app_data(raw),
            "supports_compression": LXMF.compression_support_from_app_data(raw)}


def delivery(name, display_name, cost):
    r = router(name)
    destination = r.register_delivery_identity(RNS.Identity(), display_name=display_name, stamp_cost=cost)
    return wire_app_data(destination)


def pn_case(raw):
    return {"packed": raw.hex(),
            "valid": LXMF.pn_announce_data_is_valid(raw),
            "stamp_cost": LXMF.pn_stamp_cost_from_app_data(raw),
            "transfer_limit": int(msgpack.unpackb(raw)[3]) if LXMF.pn_announce_data_is_valid(raw) else None,
            "sync_limit": int(msgpack.unpackb(raw)[4]) if LXMF.pn_announce_data_is_valid(raw) else None}


def propagation(name, cost, flexibility, peering, transfer_limit=None, sync_limit=None):
    r = router(name, propagation_cost=cost, propagation_cost_flexibility=flexibility, peering_cost=peering)
    # MeshChatX assigns these as `bytes / 1000`, a float (identity_context.py:330-335 in 4.10.7).
    if transfer_limit is not None: r.propagation_per_transfer_limit = transfer_limit
    if sync_limit is not None: r.propagation_per_sync_limit = sync_limit
    r.propagation_node = True
    # Same construction as LXMRouter.enable_propagation (LXMRouter.py:633), which we avoid calling
    # because it also starts node housekeeping and a delayed real announce.
    destination = RNS.Destination(r.identity, RNS.Destination.IN, RNS.Destination.SINGLE, LXMF.APP_NAME, "propagation")
    return wire_app_data(destination, app_data=r.get_propagation_node_app_data())


fixtures = {
    "delivery_integer_cost": delivery_case(delivery("d1", "Alice", 8)),
    "delivery_fractional_cost": delivery_case(delivery("d2", "Bob", 8.5)),
    "delivery_no_cost": delivery_case(delivery("d3", "Carol", None)),
    "delivery_stamp_only": delivery_case(delivery("d4", None, None)),
    "delivery_post_1_6_2": delivery_case(msgpack.packb([b"Dave", 8.5, [LXMF.SF_COMPRESSION]])),
    "pn_fractional_cost": pn_case(propagation("p1", 16.5, 3.0, 18.0)),
    "pn_float_limits": pn_case(propagation("p2", 16, 3, 18, transfer_limit=256000 / 1000, sync_limit=10240000 / 1000)),
    "pn_post_1_6_2": pn_case(msgpack.packb([False, 1700000000, True, 256, 10240, [16.5, 3.0, 18.0], {}])),
    "pn_bad_fractional_element": pn_case(msgpack.packb([False, 1700000000, True, 256, 10240, [17, 3, 18], {}, "bad"])),
    # Reference publishes ceil([3]) in [1] and ceil([7]) in [5], so its own output cannot show which
    # element a parser reads. These disagree on purpose, and the helpers decide what is right.
    "delivery_element_3_wins": delivery_case(msgpack.packb([b"n", 9, [LXMF.SF_COMPRESSION], 7])),
    "delivery_element_3_not_a_number": delivery_case(msgpack.packb([b"n", 9, [LXMF.SF_COMPRESSION], "x"])),
    "pn_element_7_wins": pn_case(msgpack.packb([False, 1700000000, True, 256, 10240, [20, 3, 18], {}, [16.5, 3.0, 18.0]])),
    "pn_bad_whole_costs_good_fractional": pn_case(msgpack.packb([False, 1700000000, True, 256, 10240, ["x", 3, 18], {}, [16.5, 3.0, 18.0]])),
    "versions": {"rns": RNS.__version__, "lxmf": LXMF.__version__},
}

# Guards on the generator itself: these cases only prove anything if the stamp really is there.
for key in ("delivery_integer_cost", "delivery_fractional_cost", "delivery_no_cost", "pn_fractional_cost", "pn_float_limits"):
    assert bytes.fromhex(fixtures[key]["packed"])[-18] == RNS.Identity.EXTPAYLOADMARKER, key
assert fixtures["delivery_stamp_only"]["packed"].startswith("c1")
assert fixtures["delivery_fractional_cost"]["stamp_cost"] == 8.5
assert fixtures["pn_fractional_cost"]["stamp_cost"] == 16.5
assert isinstance(msgpack.unpackb(bytes.fromhex(fixtures["pn_float_limits"]["packed"]))[3], float)
assert fixtures["pn_bad_fractional_element"]["valid"] is False
assert fixtures["pn_bad_whole_costs_good_fractional"]["valid"] is False
assert fixtures["delivery_element_3_wins"]["stamp_cost"] == 7
assert fixtures["delivery_element_3_not_a_number"]["stamp_cost"] == 9
assert fixtures["pn_element_7_wins"]["stamp_cost"] == 16.5

print(json.dumps(fixtures, indent=2))
shutil.rmtree(workdir, ignore_errors=True)
