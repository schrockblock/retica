#!/usr/bin/env python
# Cross-validation fixtures for ReTiCA's LandandairCodec / MeshtasticReassembler / sender, made by
# driving landandair's GENUINE code — not a re-implementation.
#
# Run in the conda `rns` env (the reference imports RNS at module top), by absolute path:
#   conda run -n rns python -I -B <repo>/Tests/ReTiCAInterfacesTests/Vectors/generate_meshtastic_fixtures.py
# Reads meshtastic_our_split.json (written by the Swift MeshtasticOurSplitEmitter suite) and writes
# meshtastic_fixtures.json, both next to this script.
#
# Reference: landandair_Meshtastic_Interface.py, an UNMODIFIED copy of
# https://github.com/landandair/RNS_Over_Meshtastic  Interface/Meshtastic_Interface.py at commit
# e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a (sha256 pinned below). The one stub: the `meshtastic` package, which
# process_outgoing imports inside the method only for BROADCAST_ADDR. MeshtasticInterface.__init__
# needs a radio, so instances are made with __new__ and given exactly the attributes the driven
# methods touch; every byte below comes from their PacketHandler / process_message /
# process_outgoing code paths.
import hashlib
import importlib.util
import json
import os
import struct
import sys
import types

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
REF = os.path.join(HERE, "landandair_Meshtastic_Interface.py")
OUR_SPLIT = os.path.join(HERE, "meshtastic_our_split.json")
OUT = os.path.join(HERE, "meshtastic_fixtures.json")
EXPECTED_SHA256 = "8b71aa8efc7624dba05202c5eb356a10a48c31bee783cd4c9295038370b394ab"

with open(REF, "rb") as f:
    digest = hashlib.sha256(f.read()).hexdigest()
assert digest == EXPECTED_SHA256, "reference copy changed: " + digest

stub = types.ModuleType("meshtastic")
stub.BROADCAST_ADDR = "^all"
sys.modules["meshtastic"] = stub

spec = importlib.util.spec_from_file_location("landandair_meshtastic_interface", REF)
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)


def pattern(n, seed):
    return bytes((i * 7 + seed) % 256 for i in range(n))


def radio_less_interface():
    iface = ref.MeshtasticInterface.__new__(ref.MeshtasticInterface)
    iface.packet_i_queue = []
    iface.outgoing_packet_storage = {}
    iface.packet_index = 0
    iface.dest_to_node_dict = {}
    iface.expected_index = {}
    iface.requested_index = {}
    iface.assembly_dict = {}
    iface.rxb = 0
    iface.txb = 0
    inbound = []

    class Owner:
        def inbound(self, data, interface):
            inbound.append(bytes(data))

    iface.owner = Owner()
    return iface, inbound


def deliver(iface, payload, sender=0x1234):
    iface.process_message({"from": sender,
                           "decoded": {"portnum": "RETICULUM_TUNNEL_APP", "payload": payload}}, None)


# 1. Their split, and their own reassembly of it (sanity).
their_split = []
for n in [1, 2, 3, 199, 200, 201, 400, 500, 508]:
    for index in [0, 1, 82, 127, 128, 255]:
        packet = pattern(n, 3)
        frames = list(ref.PacketHandler(packet, index).data_dict.values())   # send order: 1, 2, ..., -n
        check = ref.PacketHandler()
        out = None
        for fr in frames:
            out = check.process_packet(fr)
        assert out == packet, "reference round trip failed"
        their_split.append({"length": n, "index": index, "packet": packet.hex(),
                            "fragments": [x.hex() for x in frames]})

# 2. OUR split through THEIR full receive path (process_message → owner.inbound).
if not os.path.exists(OUR_SPLIT):
    sys.exit("meshtastic_our_split.json missing: run the MeshtasticOurSplitEmitter suite first")
with open(OUR_SPLIT) as f:
    ours = json.load(f)["cases"]
our_split_reassembled = []
for case in ours:
    iface, inbound = radio_less_interface()
    for fr in case["fragments"]:
        deliver(iface, bytes.fromhex(fr))
    assert inbound == [bytes.fromhex(case["packet"])], "reference failed to reassemble our split"
    our_split_reassembled.append({"index": case["index"], "packet": case["packet"],
                                  "reassembled": inbound[0].hex()})

# 3. Their outgoing path: index counter from 0, queue order.
sender, _ = radio_less_interface()
outgoing_packets = [pattern(250, 11), pattern(10, 13), pattern(508, 17)]
for p in outgoing_packets:
    sender.process_outgoing(p)
outgoing_frames = [sender.outgoing_packet_storage[i][pos] for (i, pos) in sender.packet_i_queue]
outgoing = {"packets": [p.hex() for p in outgoing_packets], "frames": [x.hex() for x in outgoing_frames]}

# 4. Their answer to a REQ: which stored frame goes to the queue front.
request_answers = []
for (index, pos) in [(0, 2), (2, 3), (1, 1), (2, 1)]:
    req = b"REQ" + struct.pack(ref.PacketHandler.struct_format, index, pos)
    sender.packet_i_queue = []
    deliver(sender, req, sender=0x9999)
    qi, qp = sender.packet_i_queue[0]
    request_answers.append({"request": req.hex(), "answer": sender.outgoing_packet_storage[qi][qp].hex()})

# 5. REQ frames exactly as their receiver emits them on a skipped index (incl. the 255 → 0 wrap).
requests = []
for (first, second) in [(0, 2), (255, 1)]:
    iface, _ = radio_less_interface()
    deliver(iface, ref.PacketHandler(pattern(5, 1), first).data_dict[-1])
    deliver(iface, ref.PacketHandler(pattern(5, 2), second).data_dict[-1])
    frame = iface.outgoing_packet_storage[-1][0]
    r_index, r_pos = ref.PacketHandler().get_metadata(frame[3:])
    requests.append({"frame": frame.hex(), "index": r_index, "pos": r_pos})
assert [(r["index"], r["pos"]) for r in requests] == [(1, 1), (0, 1)]

# 6. Reordered delivery: where the reference does and does not complete.
reorder = []
packet = pattern(500, 23)
frames3 = list(ref.PacketHandler(packet, 9).data_dict.values())   # pos 1, 2, -3
for order in [[1, 0, 2], [2, 0, 1]]:                               # (2, 1, -3) and (-3, 1, 2)
    h = ref.PacketHandler()
    done = None
    for k in order:
        r = h.process_packet(frames3[k])
        if r is not None:
            done = r
    reorder.append({"packet": packet.hex(), "fragments": [frames3[k].hex() for k in order],
                    "reference_completes": done == packet})
assert [r["reference_completes"] for r in reorder] == [True, False]

fixtures = {
    "source": {"file": "landandair_Meshtastic_Interface.py", "sha256": EXPECTED_SHA256,
               "upstream": "https://raw.githubusercontent.com/landandair/RNS_Over_Meshtastic/e5eb5d23a619958ae0556c88fcbc4bf1d867ab0a/Interface/Meshtastic_Interface.py"},
    "their_split": their_split,
    "our_split_reassembled": our_split_reassembled,
    "outgoing": outgoing,
    "request_answers": request_answers,
    "requests": requests,
    "reorder": reorder,
}
with open(OUT, "w") as f:
    json.dump(fixtures, f, indent=1, sort_keys=True)
    f.write("\n")
print("wrote", OUT)
