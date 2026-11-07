#!/usr/bin/env python
# Cross-validation fixtures for ReTiCA's ScotMeshRawCodec / MeshCoreReassembler / announce limiter,
# made by driving ScotMesh's GENUINE code, not a re-implementation.
#
# GPL-3.0 NOTICE. The reference is ScotMesh's RNS_Over_Meshcore, licensed GPL-3.0:
#   https://github.com/ScotMesh/RNS_Over_Meshcore
#   commit 2167780f9b2754070ab944262c1a7831d28a72ce
#   file   Interface/MeshCore_Raw_Interface.py
# This script imports that file at DEV TIME ONLY, from a clone that lives outside this repo. It
# contains none of that code, and no copy of the file or of any function of it is committed here.
# The JSON it writes holds bytes only. To get the clone (any new empty directory will do):
#   mkdir -p /tmp/ReTiCaMsgr/research/scotmesh-reclone
#   git clone https://github.com/ScotMesh/RNS_Over_Meshcore /tmp/ReTiCaMsgr/research/scotmesh-reclone/repo
#   git -C /tmp/ReTiCaMsgr/research/scotmesh-reclone/repo checkout 2167780f9b2754070ab944262c1a7831d28a72ce
#
# Run in the conda `rns` env (the reference imports RNS at module top). The one argument is the
# path to the reference file; its sha256 is checked, then it is loaded by path:
#   conda run -n rns python -I -B <repo>/Tests/ReTiCAInterfacesTests/Vectors/generate_meshcore_fixtures.py \
#       /tmp/ReTiCaMsgr/research/scotmesh/repo/Interface/MeshCore_Raw_Interface.py
# Reads meshcore_our_split.json (written by the Swift MeshCoreOurSplitEmitter suite) and writes
# meshcore_fixtures.json, both next to this script.
#
# MeshCore_Raw_Interface.__init__ needs a radio, so the receive path is driven on an instance made
# with __new__ and given exactly the attributes `_on_frame` and `_handle_bind` touch. Every byte
# below comes from the reference's _Frame, _on_frame, _handle_bind and announce_exceeds_hops.
import asyncio
import hashlib
import importlib.util
import json
import os
import struct
import sys
import threading

sys.dont_write_bytecode = True
HERE = os.path.dirname(os.path.abspath(__file__))
OUR_SPLIT = os.path.join(HERE, "meshcore_our_split.json")
OUT = os.path.join(HERE, "meshcore_fixtures.json")
EXPECTED_SHA256 = "d378b47ae59c2ce943bc813385cefff384fcb658f6984a1c7fd72e0c3e00624c"
UPSTREAM_COMMIT = "2167780f9b2754070ab944262c1a7831d28a72ce"

if len(sys.argv) != 2:
    sys.exit("usage: generate_meshcore_fixtures.py <path to MeshCore_Raw_Interface.py>")
REF_PATH = os.path.abspath(sys.argv[1])
with open(REF_PATH, "rb") as f:
    digest = hashlib.sha256(f.read()).hexdigest()
assert digest == EXPECTED_SHA256, "reference file is not the pinned one: " + digest

spec = importlib.util.spec_from_file_location("scotmesh_meshcore_raw_interface", REF_PATH)
ref = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ref)
F = ref._Frame
IFACE = ref.interface_class

SRC = bytes.fromhex("01020304")
PKT_ID = 0xBEEF
LENGTHS = [1, 147, 148, 149, 296, 500, 508]


def pattern(n, seed):
    return bytes((i * 7 + seed) % 256 for i in range(n))


def radio_less_interface(loop):
    iface = IFACE.__new__(IFACE)
    delivered = []
    iface._own_prefix = bytes.fromhex("a1b2c3d4")
    iface._peers = {SRC: pattern(32, 1)}
    iface._peer_caps = {}
    iface._peer_last_seen = {}
    iface._rns_to_peer = {}
    iface._pending_tokens = {}
    iface._seen_pkts = {}
    iface._assembly = {}
    iface._assembly_meta = {}
    iface._path_response_pending = {}
    iface._path_response_bypass_s = 15.0
    iface._peer_lock = threading.RLock()
    iface._pending_tokens_lock = threading.RLock()
    iface._seen_lock = threading.RLock()
    iface._asm_lock = threading.RLock()
    iface._path_response_pending_lock = threading.RLock()
    iface.learn_path_from_rx = False
    iface.allow_direct = False
    iface._pending_resp_task = None
    iface._loop = loop
    iface._log = lambda *a, **k: None
    iface._dbg = lambda *a, **k: None
    iface.process_incoming = lambda data: delivered.append(bytes(data))
    return iface, delivered


def announce_raw(hops, path_response, header2):
    """A raw RNS announce: HEADER_1 or HEADER_2, single destination, 40 payload bytes."""
    flags = 0x01 | (0x50 if header2 else 0x00)
    context = ref.RNS.Packet.PATH_RESPONSE if path_response else 0x00
    dst = pattern(16, 0xD0)
    ids = (b"\x11" * 16 + dst) if header2 else dst
    return bytes([flags, hops]) + ids + bytes([context]) + b"\xa5" * 40


async def main():
    loop = asyncio.get_running_loop()

    # 1. Their split: 7 lengths x can-route at chunk 148, then 500 B at chunk 140.
    their_split = []
    for chunk, can_routes, lengths in [(148, (False, True), LENGTHS), (140, (False,), [500])]:
        for n in lengths:
            for can_route in can_routes:
                packet = pattern(n, 3)
                frags = F.fragments(F.T_DATA, SRC, F.BROADCAST, PKT_ID, packet, chunk, can_route)
                parsed = [F.parse(x) for x in frags]
                assert all(p is not None for p in parsed)
                assert b"".join(p["payload"] for p in parsed) == packet
                their_split.append({"length": n, "can_route": can_route, "chunk": chunk,
                                    "packet": packet.hex(), "fragments": [x.hex() for x in frags]})

    # 2. Their BIND_REQ / BIND frames for a key whose first four bytes are the sender prefix.
    key = SRC + pattern(28, 9)
    their_bind = []
    for name, ftype in [("BIND_REQ", F.T_BIND_REQ), ("BIND", F.T_BIND)]:
        for can_route in (False, True):
            frame = F.build(ftype, SRC, F.BROADCAST, PKT_ID, [key], can_route=can_route)[0]
            assert F.parse(frame)["type"] == ftype
            their_bind.append({"type": name, "can_route": can_route, "key": key.hex(),
                               "frame": frame.hex()})

    # 3. Frames their parse rejects.
    valid = F.build(F.T_DATA, SRC, F.BROADCAST, PKT_ID, [b"abc"])[0]

    def header(magic, idx, total):
        return struct.pack(F.HDR_FMT, magic, 0, SRC, F.BROADCAST, PKT_ID, idx, total) + b"abc"

    rejects = [("empty", b""), ("short", valid[:F.HEADER_SIZE - 1]),
               ("badMagic", bytes([F.MAGIC ^ 1]) + valid[1:]),
               ("zeroTotal", header(F.MAGIC, 0, 0)),
               ("indexEqualsTotal", header(F.MAGIC, 3, 3)),
               ("indexPastTotal", header(F.MAGIC, 200, 2)),
               ("maximalIndexAndTotal", header(F.MAGIC, 255, 255))]
    for name, frame in rejects:
        assert F.parse(frame) is None, name
    their_rejects = [{"name": name, "frame": frame.hex()} for name, frame in rejects]

    # 4. Their parse of OUR split.
    with open(OUR_SPLIT) as f:
        ours = json.load(f)
    assert len(ours["cases"]) == 14, "meshcore_our_split.json is stale: run the emitter"
    our_split_parsed = []
    for case in ours["cases"]:
        frags = [bytes.fromhex(x) for x in case["fragments"]]
        parsed = [F.parse(x) for x in frags]
        assert all(p is not None for p in parsed), "reference rejected our fragment"
        ordered = sorted(parsed, key=lambda p: p["idx"])
        reassembled = b"".join(p["payload"] for p in ordered)
        our_split_parsed.append({
            "packet": case["packet"], "can_route": case["canRoute"],
            "fragments": case["fragments"],
            "parsed": [{"type": p["type"], "can_route": p["can_route"], "src": p["src"].hex(),
                        "dst": p["dst"].hex(), "pkt_id": p["pkt_id"], "idx": p["idx"],
                        "total": p["total"], "payload": p["payload"].hex()} for p in parsed],
            "reassembled": reassembled.hex()})

    # 5. Our split through THEIR _on_frame: in order, reversed, first fragment repeated.
    async def deliver(frames):
        iface, delivered = radio_less_interface(loop)
        for fr in frames:
            await iface._on_frame(fr, "CHANNEL", None)
        return [x.hex() for x in delivered]

    our_split_delivered = []
    for case in ours["cases"]:
        frags = case["fragments"]
        for order, seq in [("inOrder", frags), ("reversed", frags[::-1]),
                           ("firstRepeated", [frags[0]] + frags)]:
            got = await deliver([bytes.fromhex(x) for x in seq])
            assert got == [case["packet"]], "reference failed to deliver our split " + order
            our_split_delivered.append({"packet": case["packet"], "order": order,
                                        "fragments": list(seq), "delivered": got})

    # 6. One packet, retransmitted whole.
    case = next(c for c in ours["cases"] if c["length"] == 296 and not c["canRoute"])
    seq = case["fragments"] + case["fragments"]
    got = await deliver([bytes.fromhex(x) for x in seq])
    assert got == [case["packet"]]
    retransmit = {"packet": case["packet"], "fragments": seq, "delivered": got}

    # 7. A conflicting body at index 0 after x0, x1: the reference keeps the first body.
    x_packet, y_packet = pattern(500, 1), pattern(500, 2)
    x = F.fragments(F.T_DATA, SRC, F.BROADCAST, PKT_ID, x_packet, 148)
    y = F.fragments(F.T_DATA, SRC, F.BROADCAST, PKT_ID, y_packet, 148)
    fed = [x[0], x[1], y[0], x[2], x[3]]
    iface, delivered = radio_less_interface(loop)
    after = None
    for step, fr in enumerate(fed):
        await iface._on_frame(fr, "CHANNEL", None)
        if delivered and after is None:
            after = step
    assert [d.hex() for d in delivered] == [x_packet.hex()] and after == 4
    conflict = {"first": x_packet.hex(), "second": y_packet.hex(),
                "fragments": [fr.hex() for fr in fed],
                "delivered": [d.hex() for d in delivered], "delivered_after_step": after}

    # 8. Our BIND, accepted by their _handle_bind into an empty peer table.
    iface, _ = radio_less_interface(loop)
    iface._peers = {}
    await iface._on_frame(bytes.fromhex(ours["bind"]), "CHANNEL", None)
    bind_key = F.parse(bytes.fromhex(ours["bind"]))["payload"]
    accepted = iface._peers.get(SRC) == bind_key and iface._peer_caps.get(SRC) is True
    assert accepted, "reference did not accept our BIND"
    our_bind_accepted = {"frame": ours["bind"], "accepted": accepted}

    # 9. The hop cap at max 2.
    hop_cap = []
    for hops in (2, 3):
        for path_response in (False, True):
            for header2 in (False, True):
                data = announce_raw(hops, path_response, header2)
                hop_cap.append({"data": data.hex(), "hops": hops, "path_response": path_response,
                                "header2": header2,
                                "exceeds": IFACE.announce_exceeds_hops(data, 2)})
    assert [r["exceeds"] for r in hop_cap].count(True) == 2

    return {
        "source": {"file": "Interface/MeshCore_Raw_Interface.py", "sha256": EXPECTED_SHA256,
                   "upstream": "https://github.com/ScotMesh/RNS_Over_Meshcore",
                   "commit": UPSTREAM_COMMIT},
        "their_split": their_split, "their_bind": their_bind, "their_rejects": their_rejects,
        "our_split_parsed": our_split_parsed, "our_split_delivered": our_split_delivered,
        "retransmit": retransmit, "conflict": conflict,
        "our_bind_accepted": our_bind_accepted, "hop_cap": hop_cap,
    }


fixtures = asyncio.run(main())
with open(OUT, "w") as f:
    json.dump(fixtures, f, indent=1, sort_keys=True)
    f.write("\n")
print("wrote", OUT)
