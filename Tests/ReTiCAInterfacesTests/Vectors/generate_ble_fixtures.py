#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path (from the Vectors directory):
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_ble_fixtures.py > ble_fixtures.json
#
# Drives the GENUINE fork ble_support.py (imported by file path; the module is
# deliberately dependency-free) so the Swift port is validated against real
# reference code, not a hand-rolled reimplementation.
import importlib.util
import json

BLE_SUPPORT = "/Users/ell/development/python/Reticulum/RNS/Interfaces/util/ble_support.py"
spec = importlib.util.spec_from_file_location("ble_support", BLE_SUPPORT)
ble = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ble)

packets = [
    bytes([0x00]),
    bytes(range(30)),
    bytes((i * 7 + 3) % 256 for i in range(1196)),  # max-length packet
]
framing = [{"packet": p.hex(), "framed": ble.frame(p).hex()} for p in packets]

stream = b"".join(ble.frame(p) for p in packets)
fb = ble.FrameBuffer()
recovered = fb.append(stream)
assert [bytes(r) for r in recovered] == packets, "reference FrameBuffer sanity check"

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
probe(4.9); probe(5.0); probe(5.01)          # strike 1: 5 s, inclusive boundary
fail(10.0)
probe(19.9); probe(20.0); probe(20.01)       # strike 2: 10 s
for t in (30.0, 40.0, 50.0, 60.0, 70.0, 80.0):
    fail(t)                                   # strikes 3..8, delay caps at 300 s
probe(380.0); probe(380.01)
fail(1000.0)                                  # 920 s quiet > 600 s: strikes forget
probe(1005.0); probe(1005.01)

print(json.dumps({
    "framing": framing,
    "framing_stream": stream.hex(),
    "greylist_ops": ops,
}, indent=2))
