#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0, lxmf 1.3.0) by absolute path, from this directory:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_lxmf_fractional_stamp_fixtures.py > lxmf_fractional_stamp_fixtures.json
#
# LXMF stamps at FRACTIONAL costs, every verdict and value from genuine reference code: LXStamper's
# generate_stamp / validate_pn_stamp / validate_peering_key, RNS.Stamps' stamp_valid / stamp_value /
# cost_to_fp / target_from_fp, and LXMessage.pack / validate_stamp. Nothing is computed by hand.
#
#   generated_cases   reference-generated stamps over the three real workblocks (3000 / 1000 / 25 rounds)
#                     at integer and fractional costs, with reference verdicts at a set of probe costs
#   slice_cases       random stamps over the peering workblock whose hash lands between two adjacent
#                     targets (e.g. valid at 8.5 but not at 8.5 + 1/256): the fraction decides them
#   hash_cases        CONSTRUCTED hashes (target, target - 1, target + 1, ...) fed to the real
#                     stamp_valid / stamp_value by substituting RNS.Identity.full_hash, so the exact
#                     boundary is pinned without luck
#   message           a real LXMessage packed with stamp_cost 8.5 and its reference validate_stamp verdicts
#
# Validate mode (used by a gated Swift test for the reverse direction, ReTiCA-generated stamps):
#   python generate_lxmf_fractional_stamp_fixtures.py --validate cases.json
# reads [{"material", "rounds", "stamp", "cost"}...] and prints one line "RESULT <json>" with the
# reference valid / value for each.
#
# Generated stamps and slice stamps are random, so each run emits different bytes. The committed JSON
# is one run.

import json
import logging
import math
import os
import sys

logging.disable(logging.CRITICAL)

import RNS
RNS.loglevel = -1
from RNS import Stamps
import LXMF
import LXMF.LXStamper as LXStamper

STEP = 1 / Stamps.COST_FP
ROUNDS = {"delivery": LXStamper.WORKBLOCK_EXPAND_ROUNDS,
          "pn": LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN,
          "peering": LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING}


def verdicts(stamp, workblock, costs):
    return [{"cost": c, "valid": Stamps.stamp_valid(stamp, c, workblock)} for c in costs]


def probe_costs(cost, value):
    return sorted({math.floor(cost), cost - STEP, cost, cost + STEP, math.ceil(cost), value, value + STEP})


def validate_mode(path):
    with open(path) as f:
        cases = json.load(f)
    out = []
    for c in cases:
        workblock = LXStamper.stamp_workblock(bytes.fromhex(c["material"]), expand_rounds=c["rounds"])
        stamp = bytes.fromhex(c["stamp"])
        out.append({"valid": Stamps.stamp_valid(stamp, c["cost"], workblock),
                    "value": Stamps.stamp_value(workblock, stamp)})
    print("RESULT " + json.dumps(out))


if len(sys.argv) == 3 and sys.argv[1] == "--validate":
    validate_mode(sys.argv[2])
    sys.exit(0)

# --- generated_cases ---------------------------------------------------------------------------------
generated_cases = []
for kind in ("delivery", "pn", "peering"):
    for cost in (8, 8.5, 13.25):
        rounds = ROUNDS[kind]
        if kind == "pn":
            # A transient: lxm_data longer than LXMF_OVERHEAD + STAMP_SIZE, so validate_pn_stamp reads it.
            lxm_data = RNS.Identity.full_hash(f"retica-fractional-pn-{cost}".encode()) * 5
            material = RNS.Identity.full_hash(lxm_data)
        else:
            lxm_data = None
            material = RNS.Identity.full_hash(f"retica-fractional-{kind}-{cost}".encode())
        stamp, value = LXStamper.generate_stamp(material, cost, expand_rounds=rounds)
        workblock = LXStamper.stamp_workblock(material, expand_rounds=rounds)
        assert Stamps.stamp_valid(stamp, cost, workblock) and value == Stamps.stamp_value(workblock, stamp)
        case = {
            "kind": kind,
            "rounds": rounds,
            "cost": cost,
            "material": material.hex(),
            "workblock_hash": RNS.Identity.full_hash(workblock).hex(),
            "stamp": stamp.hex(),
            "value": value,
            "probes": verdicts(stamp, workblock, probe_costs(cost, value)),
        }
        if kind == "pn":
            tid, data, pn_value, pn_stamp = LXStamper.validate_pn_stamp(lxm_data + stamp, cost)
            assert tid == material and pn_stamp == stamp
            case["lxm_data"] = lxm_data.hex()
            case["validate_pn_stamp_value"] = pn_value
            case["validate_pn_stamp_above_value"] = LXStamper.validate_pn_stamp(lxm_data + stamp, value + STEP)[0] is not None
        if kind == "peering":
            case["validate_peering_key"] = LXStamper.validate_peering_key(material, stamp, cost)
            case["validate_peering_key_above_value"] = LXStamper.validate_peering_key(material, stamp, value + STEP)
        generated_cases.append(case)

# --- slice_cases -------------------------------------------------------------------------------------
# (lower, upper): find random stamps valid at `lower` and NOT valid at `upper`.
SLICES = [(8.5, 8.5 + STEP), (8, 8.5), (8.5, 9), (13.25 - STEP, 13.25)]
slice_material = RNS.Identity.full_hash(b"retica-fractional-slices")
slice_workblock = LXStamper.stamp_workblock(slice_material, expand_rounds=LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING)
slice_cases = []
for lower, upper in SLICES:
    t_lower = Stamps.target_from_cost(lower)
    t_upper = Stamps.target_from_cost(upper)
    found = 0
    tries = 0
    wanted = 1 if lower > 13 else 2     # the 13.25 slice takes millions of tries per hit
    while found < wanted:
        tries += 1
        assert tries < 40_000_000, (lower, upper)
        stamp = os.urandom(LXStamper.STAMP_SIZE)
        h = int.from_bytes(RNS.Identity.full_hash(slice_workblock + stamp), "big")
        if t_upper < h <= t_lower:
            assert Stamps.stamp_valid(stamp, lower, slice_workblock)
            assert not Stamps.stamp_valid(stamp, upper, slice_workblock)
            value = Stamps.stamp_value(slice_workblock, stamp)
            slice_cases.append({
                "lower": lower,
                "upper": upper,
                "stamp": stamp.hex(),
                "value": value,
                "probes": verdicts(stamp, slice_workblock, sorted({lower, upper, value, value + STEP})),
            })
            found += 1

# --- hash_cases --------------------------------------------------------------------------------------
# The real stamp_valid / stamp_value read the hash through RNS.Identity.full_hash; substituting it lets
# a chosen 256-bit integer stand in for full_hash(workblock + stamp).
real_full_hash = RNS.Identity.full_hash
hash_cases = []


def constructed(h, costs, label):
    hb = h.to_bytes(32, "big")
    RNS.Identity.full_hash = lambda _data: hb
    try:
        value = Stamps.stamp_value(b"wb", b"stamp")
        probes = [{"cost": c, "valid": Stamps.stamp_valid(b"stamp", c, b"wb")} for c in costs]
    finally:
        RNS.Identity.full_hash = real_full_hash
    return {"label": label, "hash": hb.hex(), "value": value, "probes": probes}


for cost in (8, 8.5, 13.25):
    target = Stamps.target_from_cost(cost)
    costs = sorted({cost - STEP, cost, cost + STEP, math.floor(cost), math.ceil(cost)})
    for delta in (-1, 0, 1):
        hash_cases.append(constructed(target + delta, costs, f"target({cost}){delta:+d}"))
# The integer boundary: target(8) is exactly 2**248, whose leading-zero count is 7, so the legacy rule
# (leading zeros >= 8) refused the "target(8)+0" hash; the fixed-point rule accepts it.
assert Stamps.target_from_cost(8) == 1 << 248

# --- message -----------------------------------------------------------------------------------------
RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)
src_id = RNS.Identity()
dst_id = RNS.Identity()
src = RNS.Destination(src_id, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(dst_id, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
msg_cost = 8.5
msg = LXMF.LXMessage(dst, src, content=b"fractional", title=b"stamp", stamp_cost=msg_cost)
msg.timestamp = 1700000000.25
msg.defer_stamp = False
msg.pack()
msg_workblock = LXStamper.stamp_workblock(msg.message_id)
msg_value = Stamps.stamp_value(msg_workblock, msg.stamp)
message = {
    "packed": msg.packed.hex(),
    "hash": msg.hash.hex(),
    "stamp": msg.stamp.hex(),
    "cost": msg_cost,
    "value": msg_value,
    "validate_stamp": [{"cost": c, "valid": msg.validate_stamp(c)}
                       for c in sorted({msg_cost, msg_value, msg_value + STEP, 9})],
}

print(json.dumps({
    "versions": {"rns": RNS.__version__, "lxmf": LXMF.__version__},
    "generated_cases": generated_cases,
    "slice_material": slice_material.hex(),
    "slice_cases": slice_cases,
    "hash_cases": hash_cases,
    "message": message,
}, indent=2))
