#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0, lxmf 1.3.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_lxmf_offer_responder_fixtures.py > lxmf_offer_responder_fixtures.json
#
# The server half of propagation-node peering, against genuine reference code: a real LXMRouter made a
# propagation node by the real enable_propagation (LXMRouter.py:630-785) answers `/offer` through the
# real LXMRouter.offer_request (:2601-2667) and concludes sync resources through the real
# LXMRouter.propagation_resource_concluded (:2669-2805), which validates stamps with the real
# LXStamper.validate_pn_stamps, stores through the real lxmf_propagation (:2826-2896) and auto-peers
# through the real LXMRouter.peer (:2340-2383). Peering keys are mined by the real
# LXStamper.generate_stamp(..., expand_rounds=WORKBLOCK_EXPAND_ROUNDS_PEERING) over
# `node.identity.hash + peer.identity.hash`, as LXMPeer.generate_peering_key does from the peer's side
# (LXMPeer.py:259-260). Message stamps are mined by the real LXStamper.generate_stamp with
# WORKBLOCK_EXPAND_ROUNDS_PN. A remote node's announce app data is the real
# LXMRouter.get_propagation_node_app_data (:387-401) of a router with that identity.
#
# Each response is recorded as `umsgpack.packb(response)`: the response element RNS packs into the
# request's response packet (Link.handle_request), which is the `data` ReTiCA's endpoint hands to
# `sendResponseOverLink`. Each request is recorded as `umsgpack.packb(data)`, the request data element
# as LXMPeer.sync builds it (`[peering_key, unhandled_ids]`, LXMPeer.py:390).
#
# Stubs (network and scheduling edges only):
#   - LXMRouter.jobloop: a no-op, so no background job thread runs.
#   - LXMRouter.announce_propagation_node: a no-op (enable_propagation announces; no interfaces exist).
#   - RNS.Transport.hops_to: answers HOPS[0] (the remote's hop count, as reference counts hops).
#   - RNS.Identity.recall_app_data: answers APP_DATA (the remote's recalled announce app data).
#   - FakeLink: link_id, get_remote_identity() and teardown() (records that it was torn down).
#   - FakeResource: status COMPLETE, .link, and .data (a BytesIO of the container bytes).
# Peer distribution queues are flushed with the real LXMRouter.flush_peer_distribution_queue and
# LXMPeer.process_queues, which the stubbed jobloop would otherwise run.

import io
import json
import math
import os
import shutil
import tempfile

import RNS
import RNS.vendor.umsgpack as msgpack
import LXMF
from LXMF import LXStamper
from LXMF.LXMPeer import LXMPeer

LXMRouter = LXMF.LXMRouter

workdir = tempfile.mkdtemp(prefix="retica-offer-responder-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)
RNS.loglevel = RNS.LOG_NONE     # reference logs to stdout, which is the JSON

HOPS = [1]
APP_DATA = {}
LXMRouter.jobloop = lambda self: None
LXMRouter.announce_propagation_node = lambda self: None
RNS.Transport.hops_to = lambda h: HOPS[0]
RNS.Identity.recall_app_data = lambda h: APP_DATA.get(h)


class FakeLink:
    def __init__(self, link_id, remote_identity):
        self.link_id = link_id
        self.remote_identity = remote_identity
        self.torn_down = False

    def get_remote_identity(self): return self.remote_identity

    def teardown(self): self.torn_down = True


class FakeResource:
    def __init__(self, link, data):
        self.status = RNS.Resource.COMPLETE
        self.link = link
        self.data = io.BytesIO(data)


def hx(b): return b.hex()


def identity(label):
    prv = RNS.Identity.full_hash(b"retica-offer-responder-x25519-" + label) + \
          RNS.Identity.full_hash(b"retica-offer-responder-ed25519-" + label)
    i = RNS.Identity.from_bytes(prv)
    assert i is not None
    return i


def prop_hash(ident):
    return RNS.Destination.hash_from_name_and_identity("lxmf.propagation", ident)


def link_id(n): return RNS.Identity.full_hash(b"retica-offer-responder-link-%d" % n)[:16]


def make_router(ident, name, peering_cost):
    r = LXMRouter(identity=ident, storagepath=os.path.join(workdir, name), autopeer=True, autopeer_maxdepth=6,
                  propagation_cost=13, propagation_cost_flexibility=9, peering_cost=peering_cost)
    r.enable_propagation()
    return r


# Messages: a 16-byte destination nobody here delivers to, then content, then a real PN stamp at cost 4
# (the nodes accept at max(0, 13 - 9) = 4). lxmf_propagation stores only len(lxmf_data) >= LXMF_OVERHEAD.
def message(label):
    core = RNS.Identity.full_hash(b"retica-offer-responder-dest")[:16]
    body = b""
    while len(core) + len(body) < 140:
        body += RNS.Identity.full_hash(b"retica-offer-responder-body-" + label + bytes([len(body)]))
    core = core + body[:140 - len(core)]
    tid = RNS.Identity.full_hash(core)
    stamp, value = LXStamper.generate_stamp(tid, 4, expand_rounds=LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN)
    assert value >= 4
    return {"label": label.decode(), "core": core, "stamp": stamp, "tid": tid, "value": value}


def container(msgs):
    return msgpack.packb([1700000000.0, [m["core"] + m["stamp"] for m in msgs]])


def peering_key(node_ident, peer_ident, cost, below=None):
    # A key worth at least `cost`; with `below`, also worth less than `below` (fractional values).
    material = node_ident.hash + peer_ident.hash
    while True:
        key, value = LXStamper.generate_stamp(material, cost, expand_rounds=LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING)
        if value >= cost and (below is None or value < below):
            return key, value


def stored(router, msgs):
    return [hx(m["tid"]) for m in msgs if m["tid"] in router.propagation_entries]


NODE8 = identity(b"node8")
NODE18 = identity(b"node18")
PEER = identity(b"peer")
REMOTE_A = identity(b"remote-a")     # announces at depth 6
REMOTE_B = identity(b"remote-b")     # announces at depth 7
OTHER = identity(b"other")           # an existing peer, for distribution

H1, H2, U1, U2, V1, V2, A1, B1, R1, R2 = (message(l) for l in
                                          (b"h1", b"h2", b"u1", b"u2", b"v1", b"v2", b"a1", b"b1", b"r1", b"r2"))

# --- /offer at peering cost 8 ---------------------------------------------------------------------
node8 = make_router(NODE8, "node8", 8)
for m in (H1, H2):
    assert node8.lxmf_propagation(m["core"], stamp_value=m["value"], stamp_data=m["stamp"])
key8, key8_value = peering_key(NODE8, PEER, 8)
key7, key7_value = peering_key(NODE8, PEER, 7, below=8)

offers = []


def offer(name, data, remote, link_number, packed=None):
    lid = link_id(link_number)
    request = packed if packed is not None else msgpack.packb(data)
    response = node8.offer_request("/offer", msgpack.unpackb(request), b"\x00" * 16, lid, remote, 1700000000.0)
    offers.append({"name": name, "identified": remote is not None, "link": hx(lid), "request": hx(request),
                   "response": hx(msgpack.packb(response)),
                   "validated": node8.validated_peer_links.get(lid, False) is True})


offer("no-identity", [key8, [H1["tid"]]], None, 1)
offer("malformed-short-bin", None, PEER, 2, packed=msgpack.packb(b"\x01"))
offer("malformed-one-element", [key8], PEER, 3)
offer("key-below-cost", [key7, [U1["tid"]]], PEER, 4)
offer("all-held", [key8, [H1["tid"], H2["tid"]]], PEER, 5)
offer("none-held", [key8, [U1["tid"], U2["tid"]]], PEER, 6)
offer("partial", [key8, [H1["tid"], U1["tid"], U2["tid"]]], PEER, 7)

# --- resources at peering cost 8 ------------------------------------------------------------------
resources = []


def resource(name, router, msgs, remote, link_number, offer_data=None):
    lid = link_id(link_number)
    offer_response = None
    if offer_data is not None:
        offer_response = router.offer_request("/offer", offer_data, b"\x00" * 16, lid, remote, 1700000000.0)
    link = FakeLink(lid, remote)
    data = container(msgs)
    router.propagation_resource_concluded(FakeResource(link, data))
    return {"name": name, "link": hx(lid), "container": hx(data),
            "offer_request": hx(msgpack.packb(offer_data)) if offer_data is not None else None,
            "offer_response": hx(msgpack.packb(offer_response)) if offer_data is not None else None,
            "torn_down": link.torn_down, "stored": stored(router, msgs)}


resources.append(resource("unvalidated-two-messages", node8, [V1, V2], PEER, 10))
resources.append(resource("validated-two-messages", node8, [U1, U2], PEER, 11,
                          offer_data=[key8, [U1["tid"], U2["tid"]]]))
resources.append(resource("unidentified-one-message", node8, [B1], None, 12))

# --- auto-peer via incoming sync ------------------------------------------------------------------
autopeers = []
node8.peer(prop_hash(OTHER), 1, 256, 10240, 13, 9, 8, {})
assert prop_hash(OTHER) in node8.peers


def remote_app_data(ident, name):
    r = make_router(ident, name, 18)
    data = r.get_propagation_node_app_data()
    RNS.Transport.deregister_destination(r.propagation_destination)
    return data


def autopeer(name, ident, label, hops, msg, link_number):
    remote_hash = prop_hash(ident)
    APP_DATA.clear()
    APP_DATA[remote_hash] = remote_app_data(ident, label.decode())
    HOPS[0] = hops
    assert remote_hash not in node8.peers
    entry = resource(name, node8, [msg], ident, link_number)
    node8.flush_peer_distribution_queue()
    for p in node8.peers.values(): p.process_queues()
    peered = remote_hash in node8.peers
    entry.update({"remote_private_key": hx(ident.get_private_key()), "remote_hash": hx(remote_hash),
                  "app_data": hx(APP_DATA[remote_hash]), "hops": hops, "peered": peered,
                  "handled_by_remote": peered and msg["tid"] in node8.peers[remote_hash].handled_messages,
                  "unhandled_for_other": msg["tid"] in node8.peers[prop_hash(OTHER)].unhandled_messages,
                  "handled_by_other": msg["tid"] in node8.peers[prop_hash(OTHER)].handled_messages})
    autopeers.append(entry)


autopeer("depth-7-not-peered", REMOTE_B, b"remote-b", 7, R2, 21)
autopeer("depth-6-peered", REMOTE_A, b"remote-a", 6, R1, 20)

# --- Review Focus 4: a key worth 17 against our 18 ------------------------------------------------
node18 = make_router(NODE18, "node18", 18)
key17, key17_value = peering_key(NODE18, PEER, 17, below=18)
rf4_link = link_id(30)
rf4_request = msgpack.packb([key17, [A1["tid"], H1["tid"]]])
rf4_response = node18.offer_request("/offer", msgpack.unpackb(rf4_request), b"\x00" * 16, rf4_link, PEER, 1700000000.0)
rf4_fake = FakeLink(rf4_link, PEER)
rf4_container = container([A1, H1])
node18.propagation_resource_concluded(FakeResource(rf4_fake, rf4_container))
rf4 = {"link": hx(rf4_link), "request": hx(rf4_request), "response": hx(msgpack.packb(rf4_response)),
       "key_value": key17_value, "container": hx(rf4_container), "torn_down": rf4_fake.torn_down,
       "stored": stored(node18, [A1, H1])}

fixtures = {
    "constants": {"error_no_identity": LXMPeer.ERROR_NO_IDENTITY, "error_invalid_key": LXMPeer.ERROR_INVALID_KEY,
                  "error_invalid_data": LXMPeer.ERROR_INVALID_DATA, "propagation_cost": 13,
                  "propagation_cost_flexibility": 9, "autopeer_maxdepth": 6},
    "node8": {"private_key": hx(NODE8.get_private_key()), "peering_cost": 8},
    "node18": {"private_key": hx(NODE18.get_private_key()), "peering_cost": 18},
    "peer": {"private_key": hx(PEER.get_private_key()), "prop_hash": hx(prop_hash(PEER))},
    "other": {"prop_hash": hx(prop_hash(OTHER))},
    "keys": {"key8_value": key8_value, "key7_value": key7_value},
    "messages": {m["label"]: {"entry": hx(m["core"] + m["stamp"]), "tid": hx(m["tid"])}
                 for m in (H1, H2, U1, U2, V1, V2, A1, B1, R1, R2)},
    "held": [hx(H1["tid"]), hx(H2["tid"])],
    "offers": offers,
    "resources": resources,
    "autopeers": autopeers,
    "rf4": rf4,
    "versions": {"rns": RNS.__version__, "lxmf": LXMF.__version__},
}

# Guards on the generator: these only prove anything if reference really behaves this way.
by = {o["name"]: o for o in offers}
assert msgpack.unpackb(bytes.fromhex(by["no-identity"]["response"])) == LXMPeer.ERROR_NO_IDENTITY
assert msgpack.unpackb(bytes.fromhex(by["malformed-short-bin"]["response"])) == LXMPeer.ERROR_INVALID_DATA
assert msgpack.unpackb(bytes.fromhex(by["malformed-one-element"]["response"])) is None   # ruling 5b
assert msgpack.unpackb(bytes.fromhex(by["key-below-cost"]["response"])) == LXMPeer.ERROR_INVALID_KEY
assert not by["key-below-cost"]["validated"]
assert msgpack.unpackb(bytes.fromhex(by["all-held"]["response"])) is False
assert msgpack.unpackb(bytes.fromhex(by["none-held"]["response"])) is True
assert msgpack.unpackb(bytes.fromhex(by["partial"]["response"])) == [U1["tid"], U2["tid"]]
assert all(by[n]["validated"] for n in ("all-held", "none-held", "partial"))
rs = {r["name"]: r for r in resources}
assert rs["unvalidated-two-messages"]["torn_down"] and rs["unvalidated-two-messages"]["stored"] == []
assert not rs["validated-two-messages"]["torn_down"] and len(rs["validated-two-messages"]["stored"]) == 2
assert not rs["unidentified-one-message"]["torn_down"] and len(rs["unidentified-one-message"]["stored"]) == 1
ap = {a["name"]: a for a in autopeers}
assert ap["depth-6-peered"]["peered"] and ap["depth-6-peered"]["handled_by_remote"]
assert ap["depth-6-peered"]["unhandled_for_other"]
assert not ap["depth-7-not-peered"]["peered"] and ap["depth-7-not-peered"]["unhandled_for_other"]
assert msgpack.unpackb(bytes.fromhex(rf4["response"])) == LXMPeer.ERROR_INVALID_KEY
assert 17 <= rf4["key_value"] < 18
assert rf4["torn_down"] and rf4["stored"] == []

print(json.dumps(fixtures, indent=2))
shutil.rmtree(workdir, ignore_errors=True)
