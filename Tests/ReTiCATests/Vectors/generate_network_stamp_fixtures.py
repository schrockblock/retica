#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0) by absolute path, from this directory:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_network_stamp_fixtures.py > network_stamp_fixtures.json
#
# Every number below comes out of the genuine RNS.Stamps module: cost_to_fp, target_from_fp,
# stamp_value, stamp_valid, generate_stamp and generate_stamped_key. Nothing is computed by hand.
# Network stamps use expand_rounds=0, so the workblock is the material itself.
#
# Random stamps and materials mean each run emits different bytes. The committed JSON is one run.

import json
import os

import RNS
from RNS import Stamps

STAMP_LENGTH = RNS.Identity.STAMPLENGTH
assert STAMP_LENGTH == 14 and RNS.Identity.EXTPAYLOADMARKER == 0xC1
CAP_FP = RNS.Transport.STAMP_COST_CAP * Stamps.COST_FP

COSTS = [0, 3.25, 8, 8.5, 12.5, 15.8, 23.5, 25, 100]
# Rounding and clamping edges for cost_to_fp. NaN and infinities cannot be written as JSON; the
# Swift tests cover them by hand against cost_to_fp's documented clamp (max(0, min(v, cap))).
EDGE_COSTS = [-1, -1e30, 0.001953125, 0.0019531249, 0.001953126, 3.255859375, 99.998046875, 100.5, 1e30]
# Costs we can afford to search for in Python on one core.
GENERATED_COSTS = [0, 3.25, 8, 8.5, 12.5, 15.8, 23.5, 25]


def target_hex(fp):
    t = Stamps.target_from_fp(fp)
    saturated = t >= 1 << 256
    return format(min(t, (1 << 256) - 1), "064x"), saturated


def fp_case(cost):
    fp = Stamps.cost_to_fp(cost)
    t, saturated = target_hex(fp)
    return {"cost": cost, "fp": fp, "target_hex": t, "target_saturated": saturated}


def value_case(material, stamp, cost):
    return {
        "material": material.hex(),
        "stamp": stamp.hex(),
        "cost": cost,
        "value": Stamps.stamp_value(material, stamp),
        "valid": Stamps.stamp_valid(stamp, cost, material),
    }


fp_cases = [fp_case(c) for c in COSTS + EDGE_COSTS]

# Targets at every grid point, so a single wrong TAB entry or shift shows up.
grid_targets = {str(fp): target_hex(fp) for fp in range(0, CAP_FP + 1, 37)}
grid_targets[str(CAP_FP)] = target_hex(CAP_FP)
grid_targets = {k: {"target_hex": v[0], "target_saturated": v[1]} for k, v in grid_targets.items()}

value_cases = []

# Random stamps of both sizes against every cost, over materials of several lengths.
for cost in COSTS:
    for size in (STAMP_LENGTH, 32):
        material = os.urandom(32)
        value_cases.append(value_case(material, os.urandom(size), cost))
value_cases.append(value_case(b"", os.urandom(STAMP_LENGTH), 8))
value_cases.append(value_case(os.urandom(5), os.urandom(STAMP_LENGTH), 8))
value_cases.append(value_case(os.urandom(300), os.urandom(STAMP_LENGTH), 8))

# Stamps produced by the reference generator (expand_rounds=0, size 14). These are valid at their cost.
generated_cases = []
for cost in GENERATED_COSTS:
    material = os.urandom(32)
    stamp, value = Stamps.generate_stamp(material, cost, expand_rounds=0, size=STAMP_LENGTH)
    assert len(stamp) == STAMP_LENGTH
    case = value_case(material, stamp, cost)
    assert case["valid"] and case["value"] == value, cost
    generated_cases.append(case)

# Low-value stamps for a given cost: random stamps the reference says are NOT valid.
low_value_cases = []
for cost in (8, 12.5, 15.8):
    material = os.urandom(32)
    while True:
        stamp = os.urandom(STAMP_LENGTH)
        if not Stamps.stamp_valid(stamp, cost, material):
            break
    case = value_case(material, stamp, cost)
    assert case["valid"] is False
    low_value_cases.append(case)

# Stamps whose hash lands as close as we can find to a TAB boundary, on each side of it. With 600000
# random tries the closest mantissa is still tens of units from a TAB entry, not one step, so these
# are near-boundary samples. The exact-boundary behaviour (mantissa equal to an entry, and one less)
# is pinned by NetworkStampBoundaryTests, which needs no fixture.
material = os.urandom(32)
closest = {"at_or_above_entry": (1 << 64, None), "just_below_entry": (1 << 64, None)}
closest_extra = {"at_or_above_entry": (1 << 64, None), "just_below_entry": (1 << 64, None)}
for _ in range(600000):
    stamp = os.urandom(STAMP_LENGTH)
    hn = int.from_bytes(RNS.Identity.full_hash(material + stamp), "big")
    bl = hn.bit_length()
    mn = hn >> (bl - 34) if bl > 34 else hn << (34 - bl)
    idx = Stamps.bisect_right(Stamps.TAB, mn)
    distances = {}
    if idx > 0:
        distances["at_or_above_entry"] = mn - Stamps.TAB[idx - 1]
    if idx < len(Stamps.TAB):
        distances["just_below_entry"] = Stamps.TAB[idx] - mn
    for kind, d in distances.items():
        if d < closest[kind][0]:
            closest_extra[kind] = closest[kind]
            closest[kind] = (d, stamp)
        elif d < closest_extra[kind][0]:
            closest_extra[kind] = (d, stamp)
boundary_cases = []
for kind in closest:
    for d, stamp in (closest[kind], closest_extra[kind]):
        assert stamp is not None
        case = value_case(material, stamp, 8)
        case["kind"] = kind
        case["mantissa_distance"] = d
        boundary_cases.append(case)

# Validity right at the target: for a few costs, search for stamps whose hash is just under and just
# over the target and record what stamp_valid says about each.
edge_validity_cases = []
for cost in (3.25, 8):
    material = os.urandom(32)
    target = Stamps.target_from_fp(Stamps.cost_to_fp(cost))
    under = over = None
    for _ in range(400000):
        stamp = os.urandom(STAMP_LENGTH)
        h = int.from_bytes(RNS.Identity.full_hash(material + stamp), "big")
        if h <= target and (under is None or target - h < under[0]):
            under = (target - h, stamp)
        if h > target and (over is None or h - target < over[0]):
            over = (h - target, stamp)
    for _, stamp in (under, over):
        edge_validity_cases.append(value_case(material, stamp, cost))
assert any(c["valid"] for c in edge_validity_cases) and any(not c["valid"] for c in edge_validity_cases)

# Stamped X25519 keys. The public key is the stamp.
key_cases = []
for cost, material in ((3.25, os.urandom(32)), (3.25, b""), (8, os.urandom(16))):
    keypair, value = Stamps.generate_stamped_key(material, cost)
    private, public = keypair
    assert Stamps.stamp_valid(public, cost, material)
    key_cases.append({
        "material": material.hex(),
        "private": private.hex(),
        "public": public.hex(),
        "cost": cost,
        "value": value,
        "valid": True,
    })

fixtures = {
    "tab": list(Stamps.TAB),
    "tab_digest": Stamps.TAB_DIGEST,
    "stamp_length": STAMP_LENGTH,
    "stamp_cost_cap": RNS.Transport.STAMP_COST_CAP,
    "fp_cases": fp_cases,
    "grid_targets": grid_targets,
    "value_cases": value_cases,
    "generated_cases": generated_cases,
    "low_value_cases": low_value_cases,
    "boundary_cases": boundary_cases,
    "edge_validity_cases": edge_validity_cases,
    "key_cases": key_cases,
    "versions": {"rns": RNS.__version__},
}

print(json.dumps(fixtures, indent=2))
