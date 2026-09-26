#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path (from the Vectors directory):
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_ble_fixtures.py > ble_fixtures.json
#
# Drives the GENUINE reference modules by file path so the Swift ports are validated
# against real code, not a hand-rolled reimplementation:
#   - fragmentation: torlando-tech/ble-reticulum BLEFragmentation.py (pinned checkout)
#   - greylist:      the Reticulum fork's ble_support.py (dependency-free)
import importlib.util
import json
import random
import sys

# BLEFragmentation logs through RNS when importable; RNS.log writes to STDOUT, which would
# corrupt the JSON. Make `import RNS` fail so the module takes its RNS = None branch.
sys.modules["RNS"] = None

FRAG = "/Users/ell/development/python/ble-reticulum/src/ble_reticulum/BLEFragmentation.py"
BLE_SUPPORT = "/Users/ell/development/python/Reticulum/RNS/Interfaces/util/ble_support.py"

def load(name, path):
    spec = importlib.util.spec_from_file_location(name, path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod

frag = load("BLEFragmentation", FRAG)
ble = load("ble_support", BLE_SUPPORT)

def pattern(n, seed):
    return bytes((i * 7 + seed) % 256 for i in range(n))

packets = [pattern(1, 3), pattern(15, 5), pattern(16, 9), pattern(40, 11),
           pattern(233, 13), pattern(500, 17)]
mtus = [20, 23, 185, 517]
fragmentation = []
for mtu in mtus:
    f = frag.BLEFragmenter(mtu=mtu)
    for p in packets:
        fragmentation.append({"mtu": mtu, "packet": p.hex(),
                              "fragments": [x.hex() for x in f.fragment_packet(p)]})

# Reassembly scenario: a 500-byte packet at MTU 23 with sequence 0 first and the REST shuffled,
# plus one benign duplicate; the reference reassembler must return the packet on the last
# fragment. Sequence 0 must lead: the reference restarts the buffer on sequence 0, discarding
# anything received before it (so a fully shuffled order can never complete).
rng = random.Random(2026)
big = pattern(500, 19)
frags = frag.BLEFragmenter(mtu=23).fragment_packet(big)
rest = list(range(1, len(frags)))
rng.shuffle(rest)
delivery = [frags[0]] + [frags[i] for i in rest]
delivery.insert(5, delivery[2])            # duplicate of an earlier fragment
r = frag.BLEReassembler()
result = None
for i, x in enumerate(delivery):
    got = r.receive_fragment(x, "peer")
    assert (got is not None) == (i == len(delivery) - 1), "reference reassembly sanity"
    if got is not None:
        result = got
assert result == big
reassembly = {"mtu": 23, "fragments": [x.hex() for x in delivery], "packet": big.hex()}

# Conflict: same sequence, different bytes → the reference raises ValueError.
r2 = frag.BLEReassembler()
three = frag.BLEFragmenter(mtu=23).fragment_packet(pattern(50, 23))
r2.receive_fragment(three[0], "peer")
r2.receive_fragment(three[1], "peer")
bad = bytearray(three[1]); bad[5] ^= 0xFF; bad = bytes(bad)
threw = False
try:
    r2.receive_fragment(bad, "peer")
except ValueError:
    threw = True
assert threw
reassembly_conflict = {"fragments": [three[0].hex(), three[1].hex(), bad.hex()], "throws": True}

# Greylist scenario: every probe expectation is the REAL PeerGreylist's answer.
ops = []
g = ble.PeerGreylist()
PEER = "aa:bb:cc:dd:ee:01"

def fail(t):
    g.record_failure(PEER, t)
    ops.append({"op": "fail", "t": t})

def probe(t):
    ops.append({"op": "probe", "t": t, "blocked": g.is_blocked(PEER, t)})

fail(0.0)
probe(4.9); probe(5.0); probe(5.01)
fail(10.0)
probe(19.9); probe(20.0); probe(20.01)
for t in (30.0, 40.0, 50.0, 60.0, 70.0, 80.0):
    fail(t)
probe(380.0); probe(380.01)
fail(1000.0)
probe(1005.0); probe(1005.01)

print(json.dumps({
    "fragmentation": fragmentation,
    "reassembly": reassembly,
    "reassembly_conflict": reassembly_conflict,
    "greylist_ops": ops,
}, indent=2))
