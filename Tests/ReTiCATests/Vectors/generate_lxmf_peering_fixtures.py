#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_peering_fixtures.py > lxmf_peering_fixtures.json
#
# Emits genuine lxmf 1.1.0 LXStamper peering-key and PN-stamp artefacts so the Swift validators can be
# cross-validated. Costs are small (4) so generation is fast. Workblocks (6 KB peering / 256 KB PN) are
# emitted as their full_hash (compact). RNS logging is suppressed so stdout JSON stays clean.
import logging
logging.disable(logging.CRITICAL)
import json
import RNS
import LXMF.LXStamper as LXStamper
RNS.loglevel = -1

# --- Peering key: a stamp over peering_id with the 25-round workblock ---
peering_id   = bytes.fromhex("00112233445566778899aabbccddeeff")   # e.g. own.hash | peer.hash (opaque here)
peering_cost = 4
peering_result = LXStamper.generate_stamp(peering_id, peering_cost, expand_rounds=LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING)
# generate_stamp returns (stamp_bytes, stamp_value) tuple
peering_key  = peering_result[0] if isinstance(peering_result, tuple) else peering_result
peering_wb   = LXStamper.stamp_workblock(peering_id, expand_rounds=LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING)

# --- PN stamp: a stamp appended to lxmf_data, over transient_id, with the 1000-round workblock ---
lxmf_data    = bytes.fromhex("aabbccddeeff00112233445566778899") + b"encrypted-lxmf-payload-placeholder"
transient_id = RNS.Identity.full_hash(lxmf_data)
pn_cost      = 4
pn_result    = LXStamper.generate_stamp(transient_id, pn_cost, expand_rounds=LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN)
pn_stamp     = pn_result[0] if isinstance(pn_result, tuple) else pn_result
pn_wb        = LXStamper.stamp_workblock(transient_id, expand_rounds=LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN)
transient_data = lxmf_data + pn_stamp
pn_value     = LXStamper.stamp_value(pn_wb, pn_stamp)

print(json.dumps({
    "workblock_expand_rounds_peering": LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING,
    "workblock_expand_rounds_pn": LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN,
    "peering_id": peering_id.hex(),
    "peering_cost": peering_cost,
    "peering_key": peering_key.hex(),
    "peering_workblock_hash": RNS.Identity.full_hash(peering_wb).hex(),
    "lxmf_data": lxmf_data.hex(),
    "pn_cost": pn_cost,
    "pn_stamp": pn_stamp.hex(),
    "transient_data": transient_data.hex(),
    "transient_id": transient_id.hex(),
    "pn_value": pn_value,
    "pn_workblock_hash": RNS.Identity.full_hash(pn_wb).hex(),
}, indent=2))
