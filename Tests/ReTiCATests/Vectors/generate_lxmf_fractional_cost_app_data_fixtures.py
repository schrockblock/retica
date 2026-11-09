#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0, lxmf 1.3.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_lxmf_fractional_cost_app_data_fixtures.py > lxmf_fractional_cost_app_data_fixtures.json
#
# Fractional (LXMF 1.3.0) costs in announce app data and in propagation-node ingest. Everything
# below comes from genuine reference code:
#
#   delivery_emit       LXMRouter.get_announce_app_data on a real router and delivery destination,
#                       with destination.stamp_cost set directly (so the emit gate itself is
#                       exercised, not only the setter), read back by stamp_cost_from_app_data.
#   inbound_setter      LXMRouter.set_inbound_stamp_cost on that destination: what it stores, or
#                       "kept" when it refuses.
#   delivery_parse      stamp_cost_from_app_data on hostile hand-packed blobs (msgpack.packb).
#   pn_emit             LXMRouter.get_propagation_node_app_data on a real router configured with
#                       fractional costs, read back by pn_announce_data_is_valid /
#                       pn_stamp_cost_from_app_data.
#   pn_parse            pn_announce_data_is_valid / pn_stamp_cost_from_app_data on hostile blobs, and
#                       LXMRouter.get_outbound_propagation_cost (the client's clamp) on each valid one,
#                       with RNS.Identity.recall_app_data returning the blob.
#   pn_ingest           LXMRouter.propagation_packet (the client offer path, which computes
#                       min_accepted_cost = max(0, cost - flex) itself, LXMRouter.py:2577) on a real
#                       router, with RNS.Identity.full_hash substituted ONLY for the final
#                       full_hash(workblock + stamp), so a chosen 256-bit hash stands in for it while the
#                       transient id and the 1000-round workblock are computed genuinely. The sink
#                       (lxmf_propagation) is replaced by a recorder on the instance; the decision is
#                       whether propagation_packet proves the packet.
#   pn_length           LXStamper.validate_pn_stamp at cost 0 on entries of 144 and 145 bytes: the
#                       length rule (LXStamper.py:33) alone.
#   peer_offer          LXMFPropagationAnnounceHandler.received_announce → LXMRouter.peer → LXMPeer.sync
#                       on hostile and ordinary announce blobs: which stored stamp values the real
#                       offer keeps (max(0, cost - flex), LXMPeer.py:336), or no offer at all.
#
# Non-finite numbers are written as strings ("nan", "inf", "-inf") because JSON has no token for them.

import json
import math
import os
import shutil
import tempfile
import time

import RNS
import RNS.vendor.umsgpack as msgpack
import RNS.Stamps as Stamps
import LXMF
from LXMF import LXStamper
from LXMF.LXMRouter import LXMRouter

workdir = tempfile.mkdtemp(prefix="retica-fractional-cost-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)
RNS.loglevel = RNS.LOG_NONE     # reference logs to stdout, which is the JSON


def num(x):
    """A JSON-safe number: non-finite floats as strings, bools and other objects as their repr."""
    if x is None: return None
    if isinstance(x, bool): return {"repr": repr(x)}
    if isinstance(x, float) and not math.isfinite(x): return repr(x)       # 'nan', 'inf', '-inf'
    if isinstance(x, (int, float)): return x
    return {"repr": repr(x)}


def router(name, **kwargs):
    return LXMF.LXMRouter(identity=RNS.Identity(), storagepath=os.path.join(workdir, name), **kwargs)


# ---- delivery emit -------------------------------------------------------------------------------
delivery_router = router("delivery")
destination = delivery_router.register_delivery_identity(RNS.Identity(), display_name="Alice", stamp_cost=None)

delivery_emit = []
for cost in [8, 8.5, 13.3, 99.5, 99.999, 0.001, 1, 100, 100.0, -1, -0.5, None,
             float("nan"), float("inf"), float("-inf")]:
    destination.stamp_cost = cost
    packed = delivery_router.get_announce_app_data(destination.hash)
    delivery_emit.append({"cost": num(cost), "packed": packed.hex(),
                          "read_back": num(LXMF.stamp_cost_from_app_data(packed))})

# ---- inbound setter ------------------------------------------------------------------------------
inbound_setter = []
for cost in [8, 8.5, 99.5, 99.999, 1, 0.5, 0, -1, float("-inf"), 100, 100.0, 255, float("inf"), float("nan"), None]:
    destination.stamp_cost = 42.0                     # a sentinel "previous value"
    accepted = delivery_router.set_inbound_stamp_cost(destination.hash, cost)
    stored = destination.stamp_cost
    inbound_setter.append({"cost": num(cost), "accepted": accepted,
                           "stored": "kept" if stored == 42.0 and cost != 42.0 else num(stored)})

# ---- delivery parse ------------------------------------------------------------------------------
delivery_parse = []
for element3 in [8.25, 7, 0.0, -1.0, 100.0, 1e300, float("nan"), float("inf"), True, "x", None]:
    blob = msgpack.packb([b"n", 9, [LXMF.SF_COMPRESSION], element3])
    delivery_parse.append({"packed": blob.hex(), "read_back": num(LXMF.stamp_cost_from_app_data(blob))})
for element1 in [8, 8.5, 0, -5, 255, 100, 99.75, float("nan"), "x"]:
    blob = msgpack.packb([b"n", element1, [LXMF.SF_COMPRESSION]])
    delivery_parse.append({"packed": blob.hex(), "read_back": num(LXMF.stamp_cost_from_app_data(blob))})

# ---- PN emit -------------------------------------------------------------------------------------
pn_emit = []
for cost, flex, peering in [(16.0, 3.0, 18.0), (16.5, 3.25, 18.75), (13.3, 0.0, 26.0), (99.5, 0.5, 0.0), (16, 3, 18)]:
    r = router(f"pn-{cost}-{flex}-{peering}", propagation_cost=cost, propagation_cost_flexibility=flex,
               peering_cost=peering)
    r.propagation_node = True
    packed = r.get_propagation_node_app_data()
    r.propagation_node = False          # so its exit handler does not touch the never-made destination
    decoded = msgpack.unpackb(packed)
    pn_emit.append({"cost": cost, "flexibility": flex, "peering_cost": peering,
                    "timebase": decoded[1], "packed": packed.hex(),
                    "valid": LXMF.pn_announce_data_is_valid(packed),
                    "stamp_cost": num(LXMF.pn_stamp_cost_from_app_data(packed))})

# ---- PN parse ------------------------------------------------------------------------------------
client = router("client")
real_recall = RNS.Identity.recall_app_data
pn_hash = RNS.Identity.full_hash(b"retica-pn")[:16]
client.outbound_propagation_node = pn_hash
client.path_request_wait = lambda: 0


def outbound_cost(blob):
    RNS.Identity.recall_app_data = lambda h: blob
    try: return client.get_outbound_propagation_cost()
    finally: RNS.Identity.recall_app_data = real_recall


pn_parse = []
base = [False, 1700000000, True, 256, 10240]
for costs7 in [[16.5, 3.0, 18.0], [float("nan"), 3.0, 18.0], [-1.0, 3.0, 18.0], [float("inf"), 0.0, 0.0],
               [float("-inf"), 0.0, 0.0], [1e300, 0.0, 0.0], [7.5, -2.0, float("nan")], [0.0, 0.0, 0.0],
               [20.25, 0.0, 0.0], [20.0, 0.0, 0.0]]:
    blob = msgpack.packb(base + [[16, 3, 18], {}, costs7])          # [7] wins over [5]
    valid = LXMF.pn_announce_data_is_valid(blob)
    pn_parse.append({"packed": blob.hex(), "valid": valid,
                     "stamp_cost": num(LXMF.pn_stamp_cost_from_app_data(blob)),
                     "outbound_cost": num(outbound_cost(blob)) if valid else None})
for whole in [[2**64 - 1, 3, 18], [-3, 3, 18], [16.5, 3, 18]]:
    blob = msgpack.packb(base + [whole, {}])
    valid = LXMF.pn_announce_data_is_valid(blob)
    pn_parse.append({"packed": blob.hex(), "valid": valid,
                     "stamp_cost": num(LXMF.pn_stamp_cost_from_app_data(blob)),
                     "outbound_cost": num(outbound_cost(blob)) if valid else None})

# ---- PN ingest boundary --------------------------------------------------------------------------
real_full_hash = RNS.Identity.full_hash
workblock_length = 256 * LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN


class FakePacket:
    destination_type = RNS.Destination.LINK
    link = None

    def __init__(self): self.proved = False
    def prove(self): self.proved = True


def ingest(cost, flex, hash_int):
    """Offer one stamped entry to a real router's propagation_packet; True when it proves it."""
    r = router(f"ingest-{cost}-{flex}-{hash_int}", propagation_cost=cost, propagation_cost_flexibility=flex)
    received = []
    r.lxmf_propagation = lambda lxmf_data, **kw: received.append(kw.get("stamp_value"))
    lxm_data = real_full_hash(b"retica-ingest-core") * 5            # 160 bytes, past the length rule
    stamp = real_full_hash(b"retica-ingest-stamp")
    hb = hash_int.to_bytes(32, "big")
    RNS.Identity.full_hash = lambda data: hb if len(data) == workblock_length + 32 else real_full_hash(data)
    try:
        packet = FakePacket()
        r.propagation_packet(msgpack.packb([1700000000.0, [lxm_data + stamp]]), packet)
    finally:
        RNS.Identity.full_hash = real_full_hash
    assert packet.proved == (len(received) == 1)
    return packet.proved, (received[0] if received else None)


def value_of(h):
    """The real stamp_value of a chosen hash, by the same substitution."""
    hb = h.to_bytes(32, "big")
    RNS.Identity.full_hash = lambda _data: hb
    try: return Stamps.stamp_value(b"", b"")
    finally: RNS.Identity.full_hash = real_full_hash


pn_ingest = []
for cost, flex in [(16.0, 3.0), (16.5, 3.25), (13.0, 15.0)]:   # reference floors cost at 13
    target = Stamps.target_from_fp(Stamps.cost_to_fp(max(0, cost - flex)))
    # target - 1 has value exactly min_accepted; target itself is valid (hash <= target) though
    # stamp_value floors it 1/256 lower; target + 1 is the first refused hash. At acceptance cost 0
    # the target is 2^256: every hash is valid, so the largest one is the case.
    hashes = [target - 1, target, target + 1] if target < 2**256 else [2**256 - 1]
    for h in hashes:
        accepted, stored_value = ingest(cost, flex, h)
        pn_ingest.append({"cost": cost, "flexibility": flex, "hash": h.to_bytes(32, "big").hex(),
                          "value": value_of(h), "accepted": accepted, "stored_value": num(stored_value)})

# ---- PN length rule ------------------------------------------------------------------------------
pn_length = []
for total in (143, 144, 145, 146):
    transient_data = bytes(range(256))[:total - 32] + bytes(32)
    tid, _, _, _ = LXStamper.validate_pn_stamp(transient_data, 0)
    pn_length.append({"length": total, "accepted": tid is not None})

# ---- PN peer offer filter ------------------------------------------------------------------------
# A real LXMFPropagationAnnounceHandler.received_announce takes each blob into a real LXMRouter.peer,
# which records the peer's costs on a real LXMPeer; LXMPeer.sync then builds the offer, dropping
# entries whose stored stamp value is below max(0, cost - flex) (LXMPeer.py:336-361) and sending
# nothing when none is left (:386-388). Only the network edges are replaced: Transport.has_path /
# hops_to answer "reachable", the peer's destination is a placeholder, its link records the request,
# and the peering key is marked ready. Entries are 100 bytes, far below the transfer and sync limits.
from LXMF.Handlers import LXMFPropagationAnnounceHandler
from LXMF.LXMPeer import LXMPeer

offer_values = [0.0, 12.99609375, 13.0, 13.24609375, 13.25, 16.0, 19.99609375, 20.0, 24.5]


class PlaceholderDestination:
    def __init__(self, h): self.hash = h


class RecordingLink:
    def __init__(self): self.offers = []
    def request(self, path, data, response_callback=None, failed_callback=None): self.offers.append((path, data))


real_has_path, real_hops_to = RNS.Transport.has_path, RNS.Transport.hops_to


def reference_offer(blob):
    """The stamp values of the entries a real LXMPeer.sync offers the peer that announced `blob`,
    or None when it sends no offer."""
    r = router(f"offer-{len(peer_offer)}")
    r.propagation_node = True
    r.autopeer = True
    peer_hash = RNS.Identity.full_hash(b"retica-offer-peer")[:16]
    RNS.Transport.has_path = lambda h: True
    RNS.Transport.hops_to = lambda h: 1
    try:
        LXMFPropagationAnnounceHandler(r).received_announce(peer_hash, None, blob, b"", False)
        peer = r.peers[peer_hash]
        by_id = {}
        for i, value in enumerate(offer_values):
            tid = RNS.Identity.full_hash(b"retica-offer-entry-%d" % i)
            r.propagation_entries[tid] = [b"\x00" * 16, "/nonexistent", time.time(), 100, [], [peer_hash], value]
            by_id[tid] = value
        peer.destination = PlaceholderDestination(peer_hash)
        peer.peering_key = [b"\x00" * 32, peer.peering_cost]
        peer.link = RecordingLink()
        peer.state = LXMPeer.LINK_READY
        peer.sync()
    finally:
        RNS.Transport.has_path, RNS.Transport.hops_to = real_has_path, real_hops_to
        r.propagation_node = False
    if not peer.link.offers: return None
    path, offer = peer.link.offers[0]
    assert path == LXMPeer.OFFER_REQUEST_PATH
    return sorted(by_id[tid] for tid in offer[1])


peer_offer = []
for costs7 in [[20.0, 0.0, 1.0], [16.0, 3.0, 1.0], [16.5, 3.25, 1.0], [float("nan"), 3.0, 1.0],
               [float("-inf"), 0.0, 1.0], [float("inf"), 0.0, 1.0], [float("inf"), float("inf"), 1.0],
               [8.0, 12.0, 1.0], [25.0, 0.0, 1.0], [16.0, float("nan"), 1.0], [16.0, float("-inf"), 1.0]]:
    blob = msgpack.packb(base + [[16, 3, 1], {}, costs7])
    peer_offer.append({"packed": blob.hex(), "values": offer_values, "offered": reference_offer(blob)})
blob = msgpack.packb(base + [[16, 3, 1], {}])               # seven elements: integer costs from [5]
peer_offer.append({"packed": blob.hex(), "values": offer_values, "offered": reference_offer(blob)})

fixtures = {"delivery_emit": delivery_emit, "inbound_setter": inbound_setter, "delivery_parse": delivery_parse,
            "pn_emit": pn_emit, "pn_parse": pn_parse, "pn_ingest": pn_ingest, "pn_length": pn_length,
            "peer_offer": peer_offer,
            "versions": {"rns": RNS.__version__, "lxmf": LXMF.__version__}}

# Guards on the generator: these only prove anything if reference really behaves this way.
assert [e for e in delivery_emit if e["cost"] == 8.5][0]["read_back"] == 8.5
assert [e for e in delivery_emit if e["cost"] == 13.3][0]["read_back"] == 13.30078125
assert [e for e in delivery_emit if e["cost"] == 100][0]["read_back"] is None
assert [e for e in inbound_setter if e["cost"] == 99.5][0]["stored"] == 99.5
assert [e for e in inbound_setter if e["cost"] == 0.5][0]["stored"] is None
assert [e for e in inbound_setter if e["cost"] == "nan"][0]["stored"] == "kept"
assert all(e["valid"] for e in pn_emit)
pn16 = [e for e in pn_ingest if e["cost"] == 16.0]
assert [e["accepted"] for e in pn16] == [True, True, False]
assert pn16[0]["value"] == 13.0 and pn16[2]["value"] < 13.0
assert [e["accepted"] for e in pn_ingest if e["cost"] == 16.5] == [True, True, False]
assert [e["accepted"] for e in pn_ingest if e["cost"] == 13.0] == [True]
assert [e["accepted"] for e in pn_length] == [False, False, True, True]
assert peer_offer[0]["offered"] == [20.0, 24.5]
assert peer_offer[1]["offered"] == [13.0, 13.24609375, 13.25, 16.0, 19.99609375, 20.0, 24.5]
assert peer_offer[3]["offered"] == offer_values                  # NaN cost: max(0, nan) is 0
assert peer_offer[5]["offered"] is None                          # +inf: nothing, so no offer
assert peer_offer[-1]["offered"] == [13.0, 13.24609375, 13.25, 16.0, 19.99609375, 20.0, 24.5]

print(json.dumps(fixtures, indent=2))
shutil.rmtree(workdir, ignore_errors=True)
