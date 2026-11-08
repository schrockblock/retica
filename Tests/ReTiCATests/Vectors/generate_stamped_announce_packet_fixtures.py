#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0) by absolute path, from anywhere:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_stamped_announce_packet_fixtures.py
#
# Writes stamped_announce_packet_fixtures.json to Tests/ReTiCATests/Vectors (Announce.parse),
# Tests/ReTiCATransportTests/Vectors (Transport ingest) and Tests/ReTiCANodeTests/Vectors (link costs
# read when a link opens). A resource belongs to one test target, so the three copies are written from
# one run here and must never be edited by hand.
#
# LinkPlaneStampedRequestTests relies on every "hi" case sharing one emission second (they are made in
# one burst), so a later one heard over more hops does not replace the path.
#
# Every announce is a real Destination._announce(send=False) packet: genuine RNS signing over the
# app data, and for the stamped cases the genuine 18-byte extension that _announce appends
# (Destination.py:348-357). The expected outputs are what the reference's own validate_announce
# (Identity.py:749-930) records for that packet: the app data it keeps, the stamp, its value and the
# link cost. Nothing is hand-computed.
#
# Cases whose extension is unusual (extended flag, over-cap cost, wrong marker, non-zero flags byte,
# a random stamp) are app data we build and hand to _announce with stamping off, so RNS still signs
# them. Their stamp is the real one RNS generated for that destination, so the only thing that can
# stop the reference stripping them is the property the case is named for.
#
# Generating the value-25 stamp takes about a minute.

import json
import os
import shutil
import tempfile

import RNS
import RNS.vendor.umsgpack as msgpack
from RNS.Stamps import cost_from_bytes, fp_from_bytes, stamp_valid, stamp_value

here = os.path.dirname(os.path.abspath(__file__))
outputs = [os.path.join(here, "stamped_announce_packet_fixtures.json"),
           os.path.join(here, "..", "..", "ReTiCATransportTests", "Vectors", "stamped_announce_packet_fixtures.json"),
           os.path.join(here, "..", "..", "ReTiCANodeTests", "Vectors", "stamped_announce_packet_fixtures.json")]

workdir = tempfile.mkdtemp(prefix="retica-stamped-packet-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    # destination_value 8 is the default target for "lo"; "hi" raises its own to 25 with set_value.
    # destination_cost is NOT set, so validate_announce demands the default 23.5, as ReTiCA does.
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[stamps]\n  stamp_destinations = yes\n  destination_value = 8\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)
assert RNS.Transport.STAMP_DESTINATIONS
assert RNS.Transport.STAMPS_ENABLED
assert RNS.Transport.DESTINATION_COST == 23.5
required = RNS.Transport.DESTINATION_COST

MSGPACK = msgpack.packb([b"Alice", None])


def hx(b):
    return None if b is None else bytes(b).hex()


def received(packet):
    """The packet as a receiver sees it: packed, then parsed back from raw bytes."""
    packet.pack()
    rx = RNS.Packet(None, packet.raw)
    assert rx.unpack()
    return rx


def case(destination, app_data=None, stamped=True):
    RNS.Transport.STAMP_DESTINATIONS = stamped
    if stamped:
        assert destination._await_stamp()
    rx = received(destination._announce(app_data=app_data, send=False))
    RNS.Transport.STAMP_DESTINATIONS = True
    accepted = RNS.Identity.validate_announce(rx)
    assert accepted is True
    r = RNS.Identity.announce_valid_cache[rx.packet_hash]
    return {"destination_hash": hx(rx.destination_hash),
            "context_flag": rx.context_flag == RNS.Packet.FLAG_SET,
            "payload": hx(rx.data),
            "app_data": hx(r["app_data"]) if r["app_data"] else None,
            "stamp": hx(r["stamp"]),
            "stamp_value": r["stamp_value"],
            "lr_cost": r["lr_cost"]}


def extension(stamp, marker=RNS.Identity.EXTPAYLOADMARKER, flags=0x00, frac=0x40, anchor=0x03):
    # Same byte order as Destination.py:354: the fractional byte first, the anchor (integer part,
    # reserved flag in the MSB) last.
    return bytes([marker, flags]) + stamp + bytes([frac, anchor])


hi = RNS.Destination(RNS.Identity(), RNS.Destination.IN, RNS.Destination.SINGLE, "retica", "stamped", "hi")
hi.set_value(25)
hi.set_link_cost(3.25)
lo = RNS.Destination(RNS.Identity(), RNS.Destination.IN, RNS.Destination.SINGLE, "retica", "stamped", "lo")

assert hi._await_stamp()
assert lo._await_stamp()
hi_stamp = hi.stamp
assert hi.stamp_value >= 25, hi.stamp_value
assert lo.stamp_value < required, lo.stamp_value

random_stamp = os.urandom(RNS.Identity.STAMPLENGTH)
lo_material = lo.hash + lo.identity.get_public_key() + lo.name_hash
assert not stamp_valid(random_stamp, required, lo_material)

cases = {
    "stripped": case(hi, MSGPACK),
    "stamp_only": case(hi, None),
    "below_cost": case(lo, MSGPACK),
    "marker_invalid_stamp": case(lo, MSGPACK + extension(random_stamp), stamped=False),
    "extended_flag": case(hi, MSGPACK + extension(hi_stamp, anchor=0x83), stamped=False),
    "over_cap": case(hi, MSGPACK + extension(hi_stamp, frac=0x01, anchor=0x64), stamped=False),
    "at_cap": case(hi, MSGPACK + extension(hi_stamp, frac=0x00, anchor=0x64), stamped=False),
    "wrong_marker": case(hi, MSGPACK + extension(hi_stamp, marker=0xC0), stamped=False),
    "nonzero_flags": case(hi, MSGPACK + extension(hi_stamp, flags=0x5A), stamped=False),
}
hi.enable_ratchets(os.path.join(workdir, "hi_ratchets"))
cases["ratchet_stripped"] = case(hi, MSGPACK)

# An lxmf.delivery destination announcing link cost 20 (LinkPlane.maxLinkStampCost), whose key search
# cannot finish inside a test: LinkPlaneStampedRequestTests stops an LXMFNode with a message queued to it.
lxmf = RNS.Destination(RNS.Identity(), RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
lxmf.set_value(25)
lxmf.set_link_cost(20)
assert lxmf._await_stamp()
cases["lxmf_delivery_cost_20"] = case(lxmf, MSGPACK)

cost_cases = [{"bytes": bytes(b).hex(), "fp": fp_from_bytes(bytes(b)), "cost": cost_from_bytes(bytes(b))}
              for b in ([0x00, 0x00], [0x03, 0x40], [0x0C, 0x80], [0x64, 0x00], [0x64, 0x01],
                        [0x7F, 0xFF], [0xFF, 0xFF])]

fixtures = {"versions": {"rns": RNS.__version__},
            "required_value": required,
            "msgpack": MSGPACK.hex(),
            "cases": cases,
            "cost_from_bytes": cost_cases}

# Guards on the generator itself: each case only proves something if the reference did what it is named for.
c = cases
assert c["stripped"]["app_data"] == MSGPACK.hex() and c["stripped"]["lr_cost"] == 3.25
assert c["stamp_only"]["app_data"] is None and c["stamp_only"]["lr_cost"] == 3.25
assert c["below_cost"]["stamp"] is not None and c["below_cost"]["lr_cost"] is None
assert c["below_cost"]["app_data"] == bytes.fromhex(c["below_cost"]["payload"])[-len(MSGPACK) - 18:].hex()
assert c["below_cost"]["stamp_value"] < required
assert c["marker_invalid_stamp"]["stamp"] == random_stamp.hex() and c["marker_invalid_stamp"]["lr_cost"] is None
for k in ("extended_flag", "over_cap", "wrong_marker"):
    assert c[k]["stamp"] is None and c[k]["lr_cost"] is None, k
    assert c[k]["app_data"].endswith(hi_stamp.hex() + c[k]["app_data"][-4:]), k
assert c["at_cap"]["lr_cost"] == 100.0 and c["at_cap"]["app_data"] == MSGPACK.hex()
assert c["nonzero_flags"]["lr_cost"] == 3.25 and c["nonzero_flags"]["app_data"] == MSGPACK.hex()
assert c["ratchet_stripped"]["context_flag"] and c["ratchet_stripped"]["lr_cost"] == 3.25
assert c["ratchet_stripped"]["app_data"] == MSGPACK.hex()
assert c["lxmf_delivery_cost_20"]["lr_cost"] == 20.0 and c["lxmf_delivery_cost_20"]["app_data"] == MSGPACK.hex()
# The emission time is the last five bytes of the random hash (payload bytes 79..84). If the burst ever
# straddles a second, run the generator again.
assert len({bytes.fromhex(c[k]["payload"])[79:84] for k in ("stripped", "at_cap")}) == 1

text = json.dumps(fixtures, indent=2) + "\n"
for path in outputs:
    with open(path, "w") as f:
        f.write(text)
shutil.rmtree(workdir, ignore_errors=True)
print("wrote", *outputs)
