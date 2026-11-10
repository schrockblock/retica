"""Reference fixtures for the AutoInterface wire functions (spec 2026-11-10-autointerface §7.1 items 1-4).

Drives the REAL RNS 1.6.0 `AutoInterface` (constructed with devices="__none__" so no NIC qualifies and no
socket opens) and records its group address, ports, descoping, discovery datagrams and address formatting.

Run: /Users/ell/opt/anaconda3/envs/rns-latest/bin/python -I generate_autointerface_fixtures.py autointerface_fixtures.json
The output path is an argument because RNS.log writes to stdout.

Reference: RNS/Interfaces/AutoInterface.py (1.6.0): descope_linklocal :80-85, constructor :164-213,
reverse_announce :490-499, peer_announce :504-513.
"""
import ipaddress
import json
import socket
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

sent = []


class FakeSocket:
    def __init__(self, *a, **k):
        pass

    def setsockopt(self, *a):
        sent.append(("setsockopt",) + tuple(x.hex() if isinstance(x, bytes) else x for x in a))

    def sendto(self, data, addr):
        sent.append(("sendto", data.hex(), list(addr)))

    def close(self):
        pass


def make(cfg):
    c = {"name": "fixture", "devices": "__none__"}
    c.update(cfg)
    return AutoInterface(None, c)


# --- 1. group address matrix -------------------------------------------------------------------
groups = []
group_ids = ["reticulum", "testgroup", "ünicode", ""]
scopes = ["link", "admin", "site", "organisation", "global"]
types = ["temporary", "permanent"]
for gid in group_ids:
    for scope in scopes:
        for t in types:
            cfg = {"group_id": gid, "discovery_scope": scope, "multicast_address_type": t}
            ai = make(cfg)
            groups.append({
                "group_id_hex": gid.encode("utf-8").hex(),
                "scope": scope,
                "type": t,
                "addr": ai.mcast_discovery_address,
                "bytes": socket.inet_pton(socket.AF_INET6, ai.mcast_discovery_address).hex(),
                "group_hash": ai.group_hash.hex(),
            })

# Unknown multicast_address_type falls back to temporary (AI:176-183).
ai = make({"multicast_address_type": "bogus"})
fallback = {
    "scope": "link", "type": "bogus", "addr": ai.mcast_discovery_address,
    "bytes": socket.inet_pton(socket.AF_INET6, ai.mcast_discovery_address).hex(),
}

# Mixed-case scope is accepted (case-insensitive).
ai = make({"discovery_scope": "SITE"})
mixed_case = {"scope": "SITE", "addr": ai.mcast_discovery_address,
              "bytes": socket.inet_pton(socket.AF_INET6, ai.mcast_discovery_address).hex()}

# The bogus scope: the reference crashes in the constructor. Recorded as `error`.
try:
    make({"discovery_scope": "bogus"})
    bogus = {"scope": "bogus", "error": None}
except Exception as e:  # noqa: BLE001
    bogus = {"scope": "bogus", "error": repr(e)}
assert bogus["error"] is not None, "reference no longer rejects an unknown scope"

# Ports and defaults.
ports = []
for cfg in [{}, {"discovery_port": "1234"}, {"data_port": "5555"}, {"discovery_port": "2000", "data_port": "3000"}]:
    ai = make(cfg)
    ports.append({"cfg": cfg, "discovery_port": ai.discovery_port,
                  "unicast_discovery_port": ai.unicast_discovery_port, "data_port": ai.data_port})

# --- 2. descope_linklocal ----------------------------------------------------------------------
ai = make({})
descope = []
for a in ["fe80::1", "fe80::1%en0", "fe80:4::1c2b:3a4d:5e6f:7081", "fe80:4:0:0:a::", "fe80::a:b:c:d%lo0",
          "fe80:ab::1%en0", "fe80:b::1425:a9a9:777d:c72f", "fe80::1425:a9a9:777d:c72f%en0",
          "fe80:0::1", "fe80:abcd:1::5", "fe80::"]:
    descope.append({"in": a, "out": ai.descope_linklocal(a)})

# --- 3. peer_announce / reverse_announce -------------------------------------------------------
announce = []
AImod.socket.socket = FakeSocket
for gid in ["reticulum", "testgroup"]:
    for scope, t in [("link", "temporary"), ("site", "temporary"), ("global", "permanent")]:
        ai = make({"group_id": gid, "discovery_scope": scope, "multicast_address_type": t})
        ai.adopted_interfaces = {"lo0": "fe80::1"}
        del sent[:]
        ai.peer_announce("lo0")
        peer_calls = list(sent)
        del sent[:]
        ai.reverse_announce("lo0", "fe80::dead:beef")
        rev_calls = list(sent)
        announce.append({
            "group_id_hex": gid.encode("utf-8").hex(), "scope": scope, "type": t,
            "link_local": "fe80::1", "reverse_peer": "fe80::dead:beef", "ifindex": 1,
            "peer_announce": peer_calls, "reverse_announce": rev_calls,
        })

# --- 4. address formatting ---------------------------------------------------------------------
def b(s):
    return bytes.fromhex(s)


raw_cases = [
    "fe800000000000000000000000000001",   # zero run in the middle, at end
    "fe800000000000001425a9a9777dc72f",   # run in the middle, 4 groups
    "fe800000000000000000000000000000",   # all-zero tail
    "fe800000000000000001000000000001",   # tie: leftmost wins
    "fe800000000100000000000100000001",   # two runs of 2/3
    "fe800000000000000001000000000000",   # runs 3 then 3, leftmost
    "fe800001000000000000000000000001",   # zero run at 4-8
    "fe800001000100010001000100010001",   # no zeros
    "fe800000000100010001000100010001",   # single run of 2 at start
    "fe80000100000001000100010001ffff",   # single zero group (not compressed)
    "febf0000000000000000000000000001",   # top of fe80::/10
    "fe810000000000000000000000000002",
    "fe9000000000000000000000000000ab",
    "fea00000000000000000000000000001",
    "feb0000000000000000000000000abcd",
    "fe800004000000000000000a00000000",   # the fe80:4:0:0:a:: shape (compression at the end)
    "fe80000400000000000a000000000000",
    "fe800004000000000000000000000001",
    "fe8000ab00000000000000000000fe01",
    "fe800000000000000000000000001234",
    "fe800000000000000000000012340000",
    "fe800000000000000000123400000000",
    "fe80000000000000123400000000abcd",
    "fe800000123400000000000000000001",
    "fe80000012340000000012340000abcd",   # two single zeros and a run of 1: no compression of singles
    "fe800000000000000000000000000100",
    "fe800000000000000000000000000010",
    "fe80000000000000deadbeef00000001",
    "fe800b000000000000000000000000ff",
    "fe80000b000000000000000000000000",
    "fe80ffffffffffffffffffffffffffff",
    "fe80000000000000ffffffff00000000",
    "fe800000ffff0000ffff000000000000",
]
formatting = []
for h in raw_cases:
    raw = b(h)
    assert len(raw) == 16
    formatting.append({
        "bytes": h,
        "ipaddress": str(ipaddress.IPv6Address(raw)),
        "inet_ntop": socket.inet_ntop(socket.AF_INET6, raw),
    })
    assert formatting[-1]["ipaddress"] == formatting[-1]["inet_ntop"], h

out = {
    "groups": groups,
    "type_fallback": fallback,
    "scope_mixed_case": mixed_case,
    "bogus_scope": bogus,
    "ports": ports,
    "descope": descope,
    "announce": announce,
    "formatting": formatting,
}

with open(sys.argv[1], "w") as f:
    json.dump(out, f, indent=1)
    f.write("\n")
