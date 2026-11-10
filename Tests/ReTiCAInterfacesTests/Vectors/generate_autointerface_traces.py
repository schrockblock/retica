"""Reference behaviour traces for the AutoInterface reducer (spec 2026-11-10-autointerface §7.1 item 5).

Drives the REAL RNS 1.6.0 `AutoInterface.discovery_handler` (one fake socket per datagram, whose
`recvfrom` replays the datagram and then sets `detached`) and the REAL `AutoInterface.process_incoming` /
`AutoInterfacePeer.process_incoming`, with the module's `time` patched to a scripted clock and
`RNS.Transport.add_interface` / the owner's `inbound` stubbed. After every step it records the peer
table, the multicast echo tables and whether a data datagram reached `inbound`.
`AutoInterfaceTraceTests.swift` replays the same scripts into the Swift reducer and compares.

Run: /Users/ell/opt/anaconda3/envs/rns-latest/bin/python -I generate_autointerface_traces.py autointerface_traces.json
The output path is an argument because RNS.log writes to stdout.

Reference: RNS/Interfaces/AutoInterface.py (1.6.0): final_init :331-356, discovery_handler :358-374,
add_peer :526-607, refresh_peer :609-611, process_incoming :613-615, AutoInterfacePeer.process_incoming
:652-668, MULTI_IF_DEQUE_LEN/TTL :72-73.
"""
import hashlib
import json
import sys

import RNS
from RNS.Interfaces import AutoInterface as AImod
from RNS.Interfaces.AutoInterface import AutoInterface

RNS.loglevel = -1


class StubReticulum:
    def __getattr__(self, name):
        if name.startswith("_default_"):
            return lambda: None
        raise AttributeError(name)


RNS.Reticulum.get_instance = staticmethod(lambda: StubReticulum())
RNS.Transport.add_interface = staticmethod(lambda interface: None)
RNS.Transport.remove_interface = staticmethod(lambda interface: None)


class FakeTime:
    """Replaces the `time` module inside AutoInterface.py only."""

    def __init__(self):
        self.now = 0.0

    def time(self):
        return self.now

    def sleep(self, _):
        raise RuntimeError("no sleeping in traces")


clock = FakeTime()
AImod.time = clock


class Owner:
    """Stands in for Transport: `AutoInterfacePeer.process_incoming` calls owner.owner.inbound."""

    def __init__(self):
        self.inbound_log = []

    def inbound(self, data, interface):
        self.inbound_log.append((data, interface.addr))


class OneShotSocket:
    """`recvfrom` returns the scripted datagram once, then sets `detached` so the handler loop ends
    (`AI:366`) on an empty read that the handler ignores (`AI:368`)."""

    def __init__(self, ai, data, src):
        self.ai = ai
        self.item = (data, src)

    def recvfrom(self, size):
        assert size == 1024
        if self.item is not None:
            item, self.item = self.item, None
            return item
        self.ai.detached = True
        return b"", None


def token(group, addr):
    return hashlib.sha256(group + addr.encode("utf-8")).digest()


def blob(label, n=40):
    out = b""
    i = 0
    while len(out) < n:
        out += hashlib.sha256(f"{label}/{i}".encode()).digest()
        i += 1
    return out[:n]


def make(group_id, nics):
    ai = AutoInterface(None, {"name": "trace", "devices": "__none__", "group_id": group_id})
    ai.owner = Owner()
    # What Reticulum sets on every interface after construction (RT:1117-1170). add_peer copies them.
    ai.ifac_size = 16
    ai.ifac_netname = None
    ai.ifac_netkey = None
    ai.announce_rate_target = None
    ai.announce_rate_grace = None
    ai.announce_rate_penalty = None
    ai.mode = RNS.Interfaces.Interface.Interface.MODE_FULL
    ai.announce_cap = 2 / 100.0
    for nic in nics:
        ll = nic["addrs"][-1]
        ai.adopted_interfaces[nic["name"]] = ll
        for a in nic["addrs"]:
            ai.link_local_addresses.append(a)
        ai.multicast_echoes[nic["name"]] = 0.0   # seeded at adoption (AI:241), t = 0
    return ai


def snapshot(ai, delivered):
    return {
        "peers": {a: {"nic": p[0], "last_heard": p[1]} for a, p in sorted(ai.peers.items())},
        "echoes": {n: {"last": ai.multicast_echoes.get(n), "initial": ai.initial_echoes.get(n)}
                   for n in sorted(ai.adopted_interfaces)},
        "accepting": ai.final_init_done,
        "delivered": delivered,
    }


def run_trace(name, group_id, nics, steps):
    ai = make(group_id, nics)
    index = {n["name"]: n["index"] for n in nics}
    results = []
    for step in steps:
        clock.now = step["t"]
        delivered = None
        if step["kind"] == "final_init":
            # What final_init does after its 1.92 s sleep (AI:353-356).
            ai.online = True
            ai.final_init_done = True
        elif step["kind"] == "discovery":
            ai.detached = False
            src = (step["src"], 29716, 0, index[step["nic"]])
            ai.discovery_handler(OneShotSocket(ai, bytes.fromhex(step["payload"]), src), step["nic"], announce=False)
        elif step["kind"] == "data":
            before = len(ai.owner.inbound_log)
            ai.process_incoming(bytes.fromhex(step["payload"]), step["src"])
            delivered = len(ai.owner.inbound_log) > before
        else:
            raise ValueError(step["kind"])
        results.append(snapshot(ai, delivered))
    return {"name": name, "group_id_hex": group_id.encode("utf-8").hex(), "nics": nics,
            "steps": steps, "results": results}


G = b"reticulum"
NICS = [{"name": "en0", "index": 4, "addrs": ["fe80::1"]},
        {"name": "en1", "index": 5, "addrs": ["fe80::2"]}]


def disc(t, nic, src, payload, plane="multicastDiscovery"):
    return {"t": t, "kind": "discovery", "nic": nic, "plane": plane, "src": src, "payload": payload.hex()}


def data(t, src, payload):
    return {"t": t, "kind": "data", "src": src, "payload": payload.hex()}


FINAL = {"t": 1.92, "kind": "final_init"}

discovery_steps = [
    disc(0.5, "en0", "fe80::aa", token(G, "fe80::aa")),                     # before final_init: dropped
    disc(1.0, "en0", "fe80::1", token(G, "fe80::1")),                       # echo before final_init: dropped
    FINAL,
    disc(2.0, "en0", "fe80::aa", token(G, "fe80::aa")),                     # new peer on en0
    disc(2.5, "en1", "fe80::aa", token(G, "fe80::aa"), "unicastDiscovery"), # known: refresh, NIC stays en0
    disc(3.0, "en0", "fe80::bb", token(G, "fe80::cc")),                     # bad hash
    disc(3.125, "en0", "fe80::bb", token(G, "fe80::bb")[:31]),              # short
    disc(3.25, "en0", "fe80::bb", token(b"othergroup", "fe80::bb")),        # wrong group
    disc(3.375, "en1", "fe80::bb", token(G, "fe80::bb") + b"\x01\x02\x03"), # trailing bytes accepted
    disc(3.5, "en0", "fe80::1", token(G, "fe80::1")),                       # echo on en0
    disc(3.625, "en1", "fe80::1", token(G, "fe80::1")),                     # en0's echo arriving on en1
    disc(3.75, "en1", "fe80::2", token(G, "fe80::2"), "unicastDiscovery"),  # en1's echo
    disc(3.875, "en0", "fe80::1", token(G, "fe80::aa")),                    # our address, wrong token
    disc(3.9375, "en0", "fe80::aa", b""),                                   # empty
]

P1 = blob("P1")
Q = [blob(f"Q{i}") for i in range(49)]
dedupe_steps = [
    data(1.0, "fe80::aa", P1),                                              # no peer yet: dropped
    FINAL,
    disc(2.0, "en0", "fe80::aa", token(G, "fe80::aa")),
    disc(2.0625, "en1", "fe80::ab", token(G, "fe80::ab")),                  # the same remote's 2nd NIC
    data(3.0, "fe80::aa", P1),                                              # delivered
    data(3.125, "fe80::ab", P1),                                            # copy via the other peer: hit, no refresh
    data(3.5, "fe80::ab", blob("P2")),                                      # delivered, refreshes ab
    data(3.75, "fe80::aa", P1),                                             # exactly t+0.75: miss (strict <)
    data(3.8125, "fe80::aa", P1),                                           # hit on the 3.75 entry
    data(3.875, "fe80::cc", blob("P3")),                                    # unknown source: dropped
]
t = 5.0
for i in range(48):                                                         # fill the 48-entry ring
    dedupe_steps.append(data(t, "fe80::aa", Q[i]))
    t += 0.0009765625                                                       # 2**-10, exact
dedupe_steps += [
    data(5.125, "fe80::aa", Q[0]),                                          # still in the ring: hit
    data(5.1875, "fe80::aa", Q[48]),                                        # 49th: evicts Q0
    data(5.25, "fe80::aa", Q[0]),                                           # evicted: miss
    data(5.3125, "fe80::aa", Q[1]),                                         # evicted by Q0's re-append: miss
    data(5.375, "fe80::aa", Q[47]),                                         # still present: hit
]

traces = [
    run_trace("discovery", "reticulum", NICS, discovery_steps),
    run_trace("dedupe", "reticulum", NICS, dedupe_steps),
]

# Self-checks of the facts the Swift tests lean on, so a reference change fails here loudly.
d = traces[0]["results"]
assert d[0]["peers"] == {} and d[1]["echoes"]["en0"]["initial"] is None
assert list(d[3]["peers"]) == ["fe80::aa"] and d[4]["peers"]["fe80::aa"] == {"nic": "en0", "last_heard": 2.5}
assert "fe80::bb" not in d[7]["peers"] and d[8]["peers"]["fe80::bb"]["nic"] == "en1"
assert d[10]["echoes"]["en0"] == {"last": 3.625, "initial": 3.5} and d[10]["echoes"]["en1"]["initial"] is None
assert "fe80::1" not in d[-1]["peers"] and "fe80::2" not in d[-1]["peers"]
r = traces[1]["results"]
assert [x["delivered"] for x in r[4:10]] == [True, False, True, True, False, False]
assert [x["delivered"] for x in r[-5:]] == [False, True, True, True, False]

with open(sys.argv[1], "w") as f:
    json.dump({"traces": traces}, f, indent=1)
    f.write("\n")
