#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0, lxmf 1.3.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_lxmf_peer_state_fixtures.py > lxmf_peer_state_fixtures.json
#
# A propagation node's peer state machine, against genuine reference code: announces go through a real
# LXMFPropagationAnnounceHandler.received_announce (Handlers.py:56-107) into LXMRouter.peer / unpeer
# (LXMRouter.py:2340-2394); distribution through enqueue_peer_distribution + flush_queues
# (:1028-1036, :2808-2824) and LXMPeer.queue_*/process_queues (LXMPeer.py:556-577); selection and the
# cull through LXMRouter.sync_peers (:2468-2521); and each peer through the real LXMPeer.sync,
# link_established, offer_response, resource_concluded, request_failed and link_closed
# (LXMPeer.py:269-551). Routers are real LXMRouters made propagation nodes by the real
# enable_propagation (:630-785), with lxmd's written defaults (autopeer_maxdepth 6, lxmd.py:66-69).
# Persisted peers are loaded by the real LXMPeer.from_bytes (LXMPeer.py:53-136).
#
# Stubs (network and scheduling edges only):
#   - LXMRouter.jobloop: a no-op, so no background job thread runs sync_peers / flush_queues on its own.
#   - LXMRouter.announce_propagation_node: a no-op (enable_propagation announces; no interfaces exist).
#   - LXMRouter.request_path (per router): records a "request_path" command.
#   - RNS.Transport.has_path: answers HAS_PATH (per step; True unless the step says otherwise).
#   - RNS.Transport.hops_to: answers the announce step's "hops".
#   - RNS.Identity.recall: answers one fixed identity, so a peer's destination resolves.
#   - RNS.Link: FakeLink, recording "open_link", "identify", the "/offer" request and "teardown"; teardown
#     calls the closed callback, as RNS.Link.teardown -> link_closed does.
#   - RNS.Resource: FakeResource, recording "resource" (the ids are the peer's
#     currently_transferring_messages, which offer_response sets right after constructing it).
#   - LXMPeer.generate_peering_key: records "generate_key" instead of mining; a "key_ready" step then
#     sets peer.peering_key = [key, peering_cost], which is what a successful generation stores.
#   - the `threading` module LXMPeer sees: Thread.start() runs the target synchronously, so the
#     key-generation request is recorded inside the step that caused it.
#   - the `time` module LXMPeer and LXMRouter see: a fake clock starting at T0; sleep() advances it
#     (LXMPeer.sync sleeps PATH_REQUEST_GRACE = 7.5 s when it has no path).
#   - the `random` module LXMRouter sees: randint(a, b) returns the step's scripted values in turn
#     (asserting each is in range) and records b + 1, the pool size.
# Propagation entries are written straight into propagation_entries in LXMRouter.lxmf_propagation's
# layout (LXMRouter.py:2881): [dest, path, received, size, handled_peers, unhandled_peers, stamp_value].
# No file exists, so a sync resource carries no message bytes; only the ids matter here.
#
# Per step the fixture records the commands the step issued, in order, and a snapshot of every peer in
# router.peers (in its dict order). For a step that runs LXMPeer.sync in LINK_READY, it also records
# the offer selection reference made: the offered ids, the ids it marked handled (oversized) and the
# ids it dropped from the unhandled list without marking them (low value).

import json
import math
import os
import shutil
import sys
import tempfile
import threading as real_threading
import time as real_time
from types import SimpleNamespace

import RNS
import RNS.vendor.umsgpack as msgpack
import LXMF
from LXMF.Handlers import LXMFPropagationAnnounceHandler
from LXMF.LXMPeer import LXMPeer

ROUTER_MODULE = sys.modules["LXMF.LXMRouter"]
PEER_MODULE = sys.modules["LXMF.LXMPeer"]
LXMRouter = ROUTER_MODULE.LXMRouter

workdir = tempfile.mkdtemp(prefix="retica-peer-state-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)
RNS.loglevel = RNS.LOG_NONE     # reference logs to stdout, which is the JSON

T0 = 1_700_000_000.0
DAY = 24 * 60 * 60
KEY = bytes(range(32))
LOG = []
HAS_PATH = [True]
HOPS = [1]
RAND = []
POOLS = []


class FakeClock:
    def __init__(self): self.now = T0
    def time(self): return self.now
    def sleep(self, seconds): self.now += seconds
    def __getattr__(self, name): return getattr(real_time, name)


CLOCK = FakeClock()


class FakeRandom:
    def seed(self, *args): pass

    def randint(self, a, b):
        assert RAND, "sync_peers drew a random index the step did not script"
        value = RAND.pop(0)
        assert a <= value <= b, (a, value, b)
        POOLS.append(b + 1)
        return value


class SyncThread:
    def __init__(self, target=None, daemon=None): self.target = target
    def start(self): self.target()


class FakeThreading:
    Thread = SyncThread
    Lock = real_threading.Lock


def hx(b): return b.hex()


class FakeLink:
    def __init__(self, destination, established_callback=None, closed_callback=None):
        self.peer_hash = established_callback.__self__.destination_hash
        self.closed_callback = closed_callback
        LOG.append({"kind": "open_link", "peer": hx(self.peer_hash)})

    def identify(self, identity): LOG.append({"kind": "identify", "peer": hx(self.peer_hash)})

    def request(self, path, data, response_callback=None, failed_callback=None):
        assert path == LXMPeer.OFFER_REQUEST_PATH
        assert data[0] == KEY
        LOG.append({"kind": "offer", "peer": hx(self.peer_hash), "ids": [hx(t) for t in data[1]]})

    def teardown(self):
        LOG.append({"kind": "teardown", "peer": hx(self.peer_hash)})
        if self.closed_callback: self.closed_callback(self)

    def get_establishment_rate(self): return None


class FakeResource:
    COMPLETE = RNS.Resource.COMPLETE
    FAILED = RNS.Resource.FAILED

    def __init__(self, data, link, callback=None):
        LOG.append({"kind": "resource", "peer": hx(link.peer_hash), "ids": None})


FIXED_IDENTITY = RNS.Identity()
LXMRouter.jobloop = lambda self: None
LXMRouter.announce_propagation_node = lambda self: None
LXMPeer.generate_peering_key = lambda self: LOG.append({"kind": "generate_key", "peer": hx(self.destination_hash)})
RNS.Transport.has_path = lambda h: HAS_PATH[0]
RNS.Transport.hops_to = lambda h: HOPS[0]
RNS.Identity.recall = lambda h, *a, **k: FIXED_IDENTITY
RNS.Link = FakeLink
RNS.Resource = FakeResource
PEER_MODULE.threading = FakeThreading
PEER_MODULE.time = CLOCK
ROUTER_MODULE.time = CLOCK
ROUTER_MODULE.random = FakeRandom()


def PEER(i): return RNS.Identity.full_hash(b"retica-peer-state-peer-%d" % i)[:16]
def TID(j): return RNS.Identity.full_hash(b"retica-peer-state-tid-%d" % j)


# Store entries: 0-3 and 6-9 are plain (100 B, stamp value 16); 4 is below a 16/3 peer's minimum
# accepted cost of 13 (low value); 5 is over a 256 KB per-transfer limit (oversized).
ENTRIES = {j: (100, 16.0) for j in range(10)}
ENTRIES[4] = (100, 10.0)
ENTRIES[5] = (300_000, 16.0)


def snapshot(r):
    out = []
    for dest, p in r.peers.items():
        out.append({
            "dest": hx(dest), "timebase": p.peering_timebase, "alive": p.alive,
            "last_heard": p.last_heard, "last_sync_attempt": p.last_sync_attempt,
            "next_sync_attempt": p.next_sync_attempt, "sync_backoff": p.sync_backoff,
            "rate": p.sync_transfer_rate, "state": p.state,
            "handled": sorted(hx(t) for t in p.handled_messages),
            "unhandled": sorted(hx(t) for t in p.unhandled_messages),
            "last_offer": [hx(t) for t in p.last_offer],
            "transferring": None if p.currently_transferring_messages is None
                            else [hx(t) for t in p.currently_transferring_messages],
            "offered": p.offered, "outgoing": p.outgoing, "incoming": p.incoming,
            "peering_cost": p.peering_cost, "stamp_cost": p.propagation_stamp_cost,
            "flexibility": p.propagation_stamp_cost_flexibility,
            "transfer_limit": p.propagation_transfer_limit, "sync_limit": p.propagation_sync_limit,
            "key_value": p.peering_key_value(),
        })
    return out


def announce_blob(s):
    costs = [s.get("stamp_cost", 16.0), s.get("flexibility", 3.0), s.get("peering_cost", 18.0)]
    return msgpack.packb([False, s["timebase"], s.get("node_state", True), s.get("transfer_kb", 256),
                          s.get("sync_kb", 10240), [math.ceil(c) for c in costs], {}, costs])


def apply(r, s):
    op = s["op"]
    if op == "announce":
        HOPS[0] = s.get("hops", 1)
        for i in s["who"]:
            LXMFPropagationAnnounceHandler(r).received_announce(PEER(i), None, announce_blob(s), b"",
                                                                s.get("path_response", False))
    elif op == "advance":
        CLOCK.now += s["seconds"]
    elif op == "distribute":
        source = r.peers.get(PEER(s["from"])) if s.get("from") is not None else None
        for j in s["ids"]: r.enqueue_peer_distribution(TID(j), source)
        r.flush_queues()
    elif op == "mark_handled":
        p = r.peers[PEER(s["peer"])]
        for j in s["ids"]: p.queue_handled_message(TID(j))
        r.flush_queues()
    elif op == "key_ready":
        p = r.peers[PEER(s["peer"])]
        s["value"] = p.peering_cost
        p.peering_key = [KEY, p.peering_cost]
    elif op == "sync_tick":
        RAND[:] = list(s.get("randint", []))
        HAS_PATH[0] = s.get("has_path", True)
        POOLS.clear()
        r.sync_peers()
        assert not RAND, "scripted random values left over"
        s["pools"] = list(POOLS)
        HAS_PATH[0] = True
    elif op == "link_established":
        p = r.peers[PEER(s["peer"])]
        p.link_established(p.link)
    elif op == "offer_response":
        p = r.peers[PEER(s["peer"])]
        p.offer_response(SimpleNamespace(response=msgpack.unpackb(bytes.fromhex(s["response"]))))
    elif op == "resource_concluded":
        p = r.peers[PEER(s["peer"])]
        status = FakeResource.COMPLETE if s["status"] == "complete" else FakeResource.FAILED
        n = s.get("transfer_size", 0)
        p.resource_concluded(SimpleNamespace(status=status, get_transfer_size=lambda: n,
                                             get_data_size=lambda: n))
    elif op == "request_failed":
        r.peers[PEER(s["peer"])].request_failed(None)
    elif op == "link_closed":
        p = r.peers[PEER(s["peer"])]
        p.link_closed(p.link)
    elif op == "rehydrate":
        for d in s["load"]:
            dictionary = {
                "destination_hash": PEER(d["peer"]), "peering_timebase": d.get("timebase", 0),
                "alive": d.get("alive", True), "last_heard": d.get("last_heard", CLOCK.now),
                "sync_transfer_rate": d.get("rate", 0), "propagation_transfer_limit": 256,
                "propagation_sync_limit": 10240, "propagation_stamp_cost": 16.0,
                "propagation_stamp_cost_flexibility": 3.0, "peering_cost": 18.0,
                "peering_key": [KEY, 18.0] if d.get("key", True) else None,
                "last_sync_attempt": d.get("last_sync_attempt", 0),
                "handled_ids": [TID(j) for j in d.get("handled", [])],
                "unhandled_ids": [TID(j) for j in d.get("unhandled", [])],
            }
            peer = LXMPeer.from_bytes(msgpack.packb(dictionary), r)
            r.peers[peer.destination_hash] = peer
    else:
        raise ValueError(op)


def run_case(index, name, steps, static=(), max_peers=20, entries=True):
    LOG.clear()
    CLOCK.now = T0
    r = LXMF.LXMRouter(identity=RNS.Identity(), storagepath=os.path.join(workdir, f"case-{index}"),
                       autopeer=True, autopeer_maxdepth=6, static_peers=[PEER(i) for i in static],
                       max_peers=max_peers)
    r.request_path = lambda h: LOG.append({"kind": "request_path", "peer": hx(h)})
    r.enable_propagation()
    if entries:
        for j, (size, value) in ENTRIES.items():
            r.propagation_entries[TID(j)] = [b"\x00" * 16, "/nonexistent", CLOCK.now, size, [], [], value]
    recorded = []
    if static:
        recorded.append({"op": "activate_static", "commands": list(LOG), "peers": snapshot(r),
                         "now": CLOCK.now})
    for s in steps:
        s = dict(s)
        LOG.clear()
        target = r.peers.get(PEER(s["peer"])) if "peer" in s else None
        before_h = set(target.handled_messages) if target else set()
        before_u = set(target.unhandled_messages) if target else set()
        apply(r, s)
        for c in LOG:
            if c["kind"] == "resource":
                c["ids"] = [hx(t) for t in r.peers[bytes.fromhex(c["peer"])].currently_transferring_messages]
        if s["op"] in ("link_established", "offer_response") and target is not None:
            offers = [c for c in LOG if c["kind"] == "offer"]
            if offers or s["op"] == "link_established":
                after_h = set(target.handled_messages)
                after_u = set(target.unhandled_messages)
                oversized = after_h - before_h
                s["selection"] = {
                    "offer": offers[0]["ids"] if offers else [],
                    "oversized": sorted(hx(t) for t in oversized),
                    "low_value": sorted(hx(t) for t in (before_u - after_u) - oversized),
                }
        s["commands"] = list(LOG)
        s["peers"] = snapshot(r)
        s["now"] = CLOCK.now
        recorded.append(s)
    return {"name": name, "static": [hx(PEER(i)) for i in static], "max_peers": max_peers, "steps": recorded}


def announce(*who, **kw): return dict(op="announce", who=list(who), **kw)
def advance(seconds): return dict(op="advance", seconds=seconds)


# A peer with six unhandled entries (one low value, one oversized), a ready key, an open sync link and
# an offer of the four it accepts in flight.
OFFER_PREFIX = [
    announce(0, timebase=100),
    dict(op="distribute", ids=[0, 1, 2, 3, 4, 5]),
    dict(op="sync_tick", randint=[0]),          # key not ready: generation requested, no link
    dict(op="key_ready", peer=0),
    advance(24),
    dict(op="sync_tick", randint=[0]),          # opens the link, backoff 720
    advance(1),
    dict(op="link_established", peer=0),        # identify, offer [0, 1, 2, 3]
    advance(1),
]


def response(value): return msgpack.packb(value).hex()


CASES = [
    ("announce_depth", [
        announce(0, timebase=100, hops=6),                  # peered (6 <= 6); a new peer's timebase stays 0
        announce(1, timebase=100, hops=7),                  # not peered
        advance(5),
        announce(0, timebase=200, hops=7),                  # an existing peer moves out of range: unpeered
        announce(2, timebase=100, hops=1, path_response=True),   # a path response never autopeers
        announce(0, timebase=300, hops=1),                  # peered afresh
        advance(5),
        announce(0, timebase=400, hops=1),                  # newer timebase: updated
        advance(5),
        announce(0, timebase=350, hops=1),                  # older timebase: ignored
    ], ()),
    ("static_peer", [
        announce(5, timebase=100, path_response=True),      # never heard: a path response feeds it
        advance(10),
        announce(5, timebase=200, path_response=True),      # heard now: a path response is ignored
        announce(5, timebase=300, hops=9),                  # an announce updates it, whatever the depth
        announce(5, timebase=400, node_state=False),        # and whatever its node state
        announce(6, timebase=100, path_response=True),      # an unknown node's path response does nothing
    ], (5,)),
    ("unpeer_node_state", [
        announce(0, timebase=100),
        announce(0, timebase=200),                          # timebase 200
        announce(0, timebase=150, node_state=False),        # older than the peering: kept
        announce(0, timebase=200, node_state=False),        # >= the peering timebase: unpeered
        announce(1, timebase=100, node_state=False),        # not a peer: nothing
    ], ()),
    ("peering_cost", [
        announce(0, timebase=100, peering_cost=27.0),       # over 26: refused
        announce(1, timebase=100, peering_cost=26.0),       # at 26: peered
        announce(1, timebase=200, peering_cost=27.0),       # raised past 26: unpeered
    ], ()),
    ("max_peers", [
        announce(*range(20), timebase=100),
        announce(20, timebase=100),                         # the 21st: refused
    ], ()),
    ("distribute", [
        announce(0, 1, timebase=100),
        dict(op="distribute", ids=[0], **{"from": 0}),      # not back to the peer it came from
        dict(op="distribute", ids=[1]),
        dict(op="mark_handled", peer=1, ids=[2, 1]),        # handled leaves unhandled
        dict(op="distribute", ids=[2, 3]),                  # a handled id is not unhandled again
    ], ()),
    ("offer_no_identity", OFFER_PREFIX + [
        dict(op="offer_response", peer=0, response=response(0xF0)),   # identify again, offer again
        dict(op="offer_response", peer=0, response=response(True)),
        advance(2),
        dict(op="resource_concluded", peer=0, status="complete", transfer_size=1000),
    ], ()),
    ("offer_no_access", OFFER_PREFIX + [
        dict(op="offer_response", peer=0, response=response(0xF1)),   # unpeered
    ], ()),
    ("offer_throttled", OFFER_PREFIX + [
        dict(op="offer_response", peer=0, response=response(0xF6)),   # next attempt 300 s on
    ], ()),
    ("offer_false", OFFER_PREFIX + [
        dict(op="offer_response", peer=0, response=response(False)),  # every offered id handled
    ], ()),
    ("offer_true", OFFER_PREFIX + [
        dict(op="offer_response", peer=0, response=response(True)),
        advance(2),
        dict(op="resource_concluded", peer=0, status="complete", transfer_size=1000),
    ], ()),
    ("offer_partial", OFFER_PREFIX + [
        dict(op="offer_response", peer=0, response=response([TID(3), TID(1)])),
        advance(4),
        dict(op="resource_concluded", peer=0, status="complete", transfer_size=500),
    ], ()),
    ("offer_empty_list", OFFER_PREFIX + [
        dict(op="offer_response", peer=0, response=response([])),
    ], ()),
    ("offer_invalid_key", OFFER_PREFIX + [
        dict(op="offer_response", peer=0, response=response(0xF3)),   # raises inside: nothing marked
    ], ()),
    ("offer_invalid_data", OFFER_PREFIX + [
        dict(op="offer_response", peer=0, response=response(0xF4)),
    ], ()),
    ("offer_request_failed", OFFER_PREFIX + [
        dict(op="request_failed", peer=0),
    ], ()),
    ("offer_transfer_failed", OFFER_PREFIX + [
        dict(op="offer_response", peer=0, response=response(True)),
        dict(op="resource_concluded", peer=0, status="failed"),
    ], ()),
    ("offer_link_closed", OFFER_PREFIX + [
        dict(op="link_closed", peer=0),
    ], ()),
    ("persistent_resync", OFFER_PREFIX + [
        dict(op="distribute", ids=[6]),                     # arrives while the offer is out
        dict(op="offer_response", peer=0, response=response(True)),
        advance(2),
        dict(op="resource_concluded", peer=0, status="complete", transfer_size=1000),   # re-sync: new link
        advance(1),
        dict(op="link_established", peer=0),                # offers [6]
    ], ()),
    ("key_regeneration", [
        announce(0, timebase=100),
        dict(op="distribute", ids=[0]),
        dict(op="key_ready", peer=0),                       # value 18
        announce(0, timebase=200, peering_cost=20.0),       # the peer now demands 20
        dict(op="sync_tick", randint=[0]),                  # key cleared, regeneration requested
    ], ()),
    ("cull", [
        announce(0, timebase=100),
        announce(5, timebase=100),                          # the static peer, heard now
        advance(14 * DAY),
        dict(op="sync_tick"),                               # exactly MAX_UNREACHABLE: kept
        advance(1),
        dict(op="sync_tick"),                               # past it: the non-static peer is culled
    ], (5,)),
    ("selection", [
        dict(op="rehydrate", load=[
            dict(peer=0, rate=0, unhandled=[0]),
            dict(peer=1, rate=500, unhandled=[0]),
            dict(peer=2, rate=500, unhandled=[0]),
            dict(peer=3, rate=0, unhandled=[0]),
            dict(peer=4, rate=200, unhandled=[0], handled=[1]),
        ]),
        dict(op="sync_tick", randint=[2]),                  # pool [1, 2, 0, 3]: peer 0
        dict(op="sync_tick", randint=[2]),                  # pool [1, 2, 3]: peer 3
    ], ()),
    ("selection_unknown_speed", [
        dict(op="rehydrate", load=[
            dict(peer=0, rate=0, unhandled=[0]),
            dict(peer=1, rate=300, unhandled=[0]),
            dict(peer=2, rate=0, unhandled=[0]),
        ]),
        dict(op="sync_tick", randint=[3]),                  # fastest [1, 0] + unknown [0, 2]: pool [1, 0, 0, 2]
        dict(op="sync_tick", randint=[2]),                  # fastest [1, 0] + unknown [0]: pool [1, 0, 0]
    ], ()),
    ("static_counts_toward_max_peers", [
        announce(0, timebase=100),                          # the static peer fills max_peers 1: refused
        announce(5, timebase=100),                          # the static peer still updates
    ], (5,), 1),
    ("no_path", [
        announce(0, timebase=100),
        dict(op="distribute", ids=[0]),
        dict(op="key_ready", peer=0),
        dict(op="sync_tick", randint=[0], has_path=False),  # request_path, 7.5 s grace, backoff 720
        advance(100),
        dict(op="sync_tick"),                               # not alive, in backoff: not picked
        advance(700),
        dict(op="sync_tick", randint=[0]),                  # unresponsive pool: opens the link, backoff 1440
    ], ()),
]

fixtures = {
    "t0": T0,
    "key": hx(KEY),
    "peers": [hx(PEER(i)) for i in range(21)],
    "tids": [hx(TID(j)) for j in range(10)],
    "cases": [run_case(i, *case) for i, case in enumerate(CASES)],
    "versions": {"rns": RNS.__version__, "lxmf": LXMF.__version__},
}

# Guards on the generator: these only prove anything if reference really behaves this way.
by_name = {c["name"]: c for c in fixtures["cases"]}
P = fixtures["peers"]
T = fixtures["tids"]


def last(name): return by_name[name]["steps"][-1]
def peer_in(step, i): return next((p for p in step["peers"] if p["dest"] == P[i]), None)


d = by_name["announce_depth"]["steps"]
assert [p["dest"] for p in d[0]["peers"]] == [P[0]] and d[0]["peers"][0]["timebase"] == 0
assert peer_in(d[1], 1) is None and d[3]["peers"] == [] and d[4]["peers"] == []
assert peer_in(d[7], 0)["timebase"] == 400 and peer_in(d[9], 0)["timebase"] == 400
s = by_name["static_peer"]["steps"]
assert s[0]["commands"] == [{"kind": "request_path", "peer": P[5]}] and s[0]["peers"][0]["peering_cost"] is None
assert s[1]["peers"][0]["timebase"] == 100 and s[3]["peers"][0]["timebase"] == 100
assert s[4]["peers"][0]["timebase"] == 300 and s[5]["peers"][0]["timebase"] == 400 and len(s[6]["peers"]) == 1
u = by_name["unpeer_node_state"]["steps"]
assert len(u[2]["peers"]) == 1 and u[3]["peers"] == [] and u[4]["peers"] == []
c = by_name["peering_cost"]["steps"]
assert c[0]["peers"] == [] and len(c[1]["peers"]) == 1 and c[2]["peers"] == []
assert len(last("max_peers")["peers"]) == 20 and peer_in(last("max_peers"), 20) is None
o = by_name["offer_true"]["steps"]
assert o[7]["commands"] == [{"kind": "identify", "peer": P[0]},
                            {"kind": "offer", "peer": P[0], "ids": [T[0], T[1], T[2], T[3]]}], o[7]
assert o[7]["selection"]["oversized"] == [T[5]] and o[7]["selection"]["low_value"] == [T[4]]
assert by_name["offer_no_identity"]["steps"][9]["commands"][0]["kind"] == "identify"
assert by_name["offer_no_access"]["steps"][-1]["peers"] == []
th = peer_in(last("offer_throttled"), 0)
assert th["next_sync_attempt"] == last("offer_throttled")["now"] + 300 and th["state"] == LXMPeer.RESPONSE_RECEIVED
assert sorted(peer_in(last("offer_false"), 0)["handled"]) == sorted([T[0], T[1], T[2], T[3], T[5]])
assert peer_in(last("offer_invalid_key"), 0)["handled"] == [T[5]]
rs = last("persistent_resync")
assert rs["commands"] == [{"kind": "identify", "peer": P[0]}, {"kind": "offer", "peer": P[0], "ids": [T[6]]}]
assert [x["kind"] for x in by_name["persistent_resync"]["steps"][-3]["commands"]] == ["teardown", "open_link"]
kr = last("key_regeneration")
assert kr["commands"] == [{"kind": "generate_key", "peer": P[0]}] and kr["peers"][0]["key_value"] is None
cu = by_name["cull"]["steps"]
assert len(cu[-3]["peers"]) == 2 and [p["dest"] for p in cu[-1]["peers"]] == [P[5]]
se = by_name["selection"]["steps"]
assert se[1]["pools"] == [4] and se[1]["commands"] == [{"kind": "open_link", "peer": P[0]}]
assert se[2]["pools"] == [3] and se[2]["commands"] == [{"kind": "open_link", "peer": P[3]}]
su = by_name["selection_unknown_speed"]["steps"]
assert su[1]["pools"] == [4] and su[1]["commands"] == [{"kind": "open_link", "peer": P[2]}]
assert su[2]["pools"] == [3] and su[2]["commands"] == [{"kind": "open_link", "peer": P[0]}]
sm = by_name["static_counts_toward_max_peers"]["steps"]
assert [p["dest"] for p in sm[1]["peers"]] == [P[5]] and sm[2]["peers"][0]["timebase"] == 100
np = by_name["no_path"]["steps"]
assert np[3]["commands"] == [{"kind": "request_path", "peer": P[0]}]
assert peer_in(np[3], 0)["sync_backoff"] == 720 and peer_in(np[3], 0)["alive"] is False
assert np[3]["now"] == T0 + 7.5 and peer_in(np[3], 0)["next_sync_attempt"] == T0 + 7.5 + 720
assert np[5]["commands"] == [] and np[7]["commands"] == [{"kind": "open_link", "peer": P[0]}]
assert peer_in(np[7], 0)["sync_backoff"] == 1440

print(json.dumps(fixtures, indent=1))
shutil.rmtree(workdir, ignore_errors=True)
