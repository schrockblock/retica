#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0, lxmf 1.3.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_lxmf_pn_offer_limits_fixtures.py > lxmf_pn_offer_limits_fixtures.json
#
# A propagation node's sync offer to a peer, against a real LXMPeer.sync (LXMPeer.py:336-395):
# the low-value filter, the weight sort (LXMRouter.get_weight, LXMRouter.py:1188-1199), the
# per-transfer limit (skip AND mark handled, :375-378) and the per-sync limit (skip, continue, :380-381).
#
# The peer is made by a real LXMFPropagationAnnounceHandler.received_announce → LXMRouter.peer from an
# announce blob carrying the limits, so the limits reach LXMPeer exactly as from the network. Only the
# network edges are replaced, as in generate_lxmf_fractional_cost_app_data_fixtures.py:
# Transport.has_path / hops_to answer "reachable", the peer's destination is a placeholder, its link
# records the request, and the peering key is marked ready. Entries are written straight into
# propagation_entries as LXMRouter.lxmf_propagation does (LXMRouter.py:2881):
# [dest, path, received, size, handled_peers, unhandled_peers, stamp_value]; sync reads only the
# size, the received time and the stamp value, never the file, so no message bytes exist.
#
# Ages: `received` is time.time() - age just before sync, and get_weight reads time.time() again,
# so an age carries microseconds of drift. Cases keep any deliberate weight tie under 4 days, where
# the age factor is exactly 1, so the drift cannot reorder them.
#
# Per case the fixture records the offer (entry indices, in offer order) and, after sync, which
# entries are in the peer's handled list ([4]) and unhandled list ([5]). An entry marked handled by
# the sync is "oversized"; one that left the unhandled list without being handled is "low value";
# an offered entry stays unhandled until the peer's response.

import json
import os
import shutil
import tempfile
import time

import RNS
import RNS.vendor.umsgpack as msgpack
import LXMF
from LXMF.Handlers import LXMFPropagationAnnounceHandler
from LXMF.LXMPeer import LXMPeer

workdir = tempfile.mkdtemp(prefix="retica-pn-offer-limits-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)
RNS.loglevel = RNS.LOG_NONE     # reference logs to stdout, which is the JSON

DAY = 60 * 60 * 24


class PlaceholderDestination:
    def __init__(self, h): self.hash = h


class RecordingLink:
    def __init__(self): self.offers = []
    def request(self, path, data, response_callback=None, failed_callback=None): self.offers.append((path, data))


real_has_path, real_hops_to = RNS.Transport.has_path, RNS.Transport.hops_to


def reference_sync(index, transfer_kb, sync_kb, cost, flex, entries):
    """entries: dicts with size, age (seconds), value, handled (already handled for the peer)."""
    r = LXMF.LXMRouter(identity=RNS.Identity(), storagepath=os.path.join(workdir, f"case-{index}"))
    r.propagation_node = True
    r.autopeer = True
    peer_hash = RNS.Identity.full_hash(b"retica-limits-peer")[:16]
    blob = msgpack.packb([False, 1700000000, True, transfer_kb, sync_kb, [16, 3, 1], {}, [cost, flex, 1.0]])
    RNS.Transport.has_path = lambda h: True
    RNS.Transport.hops_to = lambda h: 1
    try:
        LXMFPropagationAnnounceHandler(r).received_announce(peer_hash, None, blob, b"", False)
        peer = r.peers[peer_hash]
        assert peer.propagation_transfer_limit == transfer_kb and peer.propagation_sync_limit == sync_kb
        tids = []
        now = time.time()
        for i, e in enumerate(entries):
            tid = RNS.Identity.full_hash(b"retica-limits-entry-%d-%d" % (index, i))
            handled = [peer_hash] if e["handled"] else []
            unhandled = [] if e["handled"] else [peer_hash]
            r.propagation_entries[tid] = [b"\x00" * 16, "/nonexistent", now - e["age"], e["size"],
                                          handled, unhandled, e["value"]]
            tids.append(tid)
        peer.destination = PlaceholderDestination(peer_hash)
        peer.peering_key = [b"\x00" * 32, peer.peering_cost]
        peer.link = RecordingLink()
        peer.state = LXMPeer.LINK_READY
        peer.sync()
    finally:
        RNS.Transport.has_path, RNS.Transport.hops_to = real_has_path, real_hops_to
        r.propagation_node = False
    offered = []
    if peer.link.offers:
        path, offer = peer.link.offers[0]
        assert path == LXMPeer.OFFER_REQUEST_PATH
        offered = [tids.index(t) for t in offer[1]]
    handled_after = [i for i, t in enumerate(tids) if peer_hash in r.propagation_entries[t][4]]
    unhandled_after = [i for i, t in enumerate(tids) if peer_hash in r.propagation_entries[t][5]]
    return {"transfer_limit_kb": transfer_kb, "sync_limit_kb": sync_kb, "cost": cost, "flexibility": flex,
            "entries": entries, "offered": offered,
            "handled_after": handled_after, "unhandled_after": unhandled_after}


def e(size, age=0, value=16.0, handled=False):
    return {"size": size, "age": age, "value": value, "handled": handled}


cases = [
    # 0. Transfer limit 256 KB at its boundary (256000-16 fits, 256000-15 does not), a low-value entry,
    #    and weight order: 100 B at 5 days (125) < 150 B (150) < 200 B (200) < 100 B at 10 days (250).
    (256, 10240, 16.0, 3.0, [e(255984), e(255985), e(100, value=12.99609375), e(100, age=10 * DAY),
                             e(100, age=5 * DAY), e(200), e(150)]),
    # 1. Sync limit 2 KB smaller than the first entry in weight order (3000 B, new): it is skipped and
    #    the later, smaller, older entries that fit are still offered.
    (256, 2, 16.0, 3.0, [e(3000), e(1000, age=40 * DAY), e(900, age=30 * DAY)]),
    # 2. Both boundaries at 1 KB transfer / 2 KB sync: 984 B fits the transfer limit and 985 B does not;
    #    after 984 B (total 1024), 960 B at 5 days would bring the total to exactly 2000 and is refused
    #    (>=); 959 B at 6 days, weighted after it, brings it to 1999 and is taken.
    (1, 2, 0.0, 0.0, [e(985), e(984), e(960, age=5 * DAY), e(959, age=6 * DAY)]),
    # 3. Already-handled entries are not considered at all, not even marked again when oversized.
    (1, 10240, 0.0, 0.0, [e(500, handled=True), e(5000, handled=True), e(600), e(5000)]),
    # 4. A peer announcing limits of 0: every entry is oversized (16 + size > 0) and handled.
    (0, 0, 0.0, 0.0, [e(100), e(200)]),
]

fixtures = {"cases": [reference_sync(i, *c) for i, c in enumerate(cases)],
            "versions": {"rns": RNS.__version__, "lxmf": LXMF.__version__}}

# Guards on the generator: these only prove anything if reference really behaves this way.
c0, c1, c2, c3, c4 = fixtures["cases"]
assert c0["offered"] == [4, 6, 5, 3, 0], c0
assert c0["handled_after"] == [1], c0
assert 2 not in c0["unhandled_after"] and 2 not in c0["handled_after"], c0
assert c1["offered"] == [2, 1], c1                      # 3000 B skipped, not a stop
assert 0 in c1["unhandled_after"] and c1["handled_after"] == [], c1
assert c2["offered"] == [1, 3] and c2["handled_after"] == [0], c2
assert c3["offered"] == [2] and c3["handled_after"] == [0, 1, 3], c3
assert c4["offered"] == [] and c4["handled_after"] == [0, 1], c4

print(json.dumps(fixtures, indent=2))
shutil.rmtree(workdir, ignore_errors=True)
