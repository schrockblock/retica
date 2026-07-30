#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_pn_announce_fixtures.py > lxmf_pn_announce_fixtures.json
#
# Emits a genuine lxmf 1.1.0 propagation-node announce app_data: the exact 7-element list layout of
# LXMRouter.get_propagation_node_app_data, encoded with genuine msgpack.packb and validated by genuine
# pn_announce_data_is_valid. Also emits an invalid (6-element) sample. RNS logging suppressed for clean JSON.
import logging
logging.disable(logging.CRITICAL)
import json
import RNS.vendor.umsgpack as msgpack
import LXMF
from LXMF.LXMF import pn_announce_data_is_valid

timebase             = 1700000000
node_state           = True
per_transfer_limit   = LXMF.LXMRouter.PROPAGATION_LIMIT           # 256 (KB)
per_sync_limit       = LXMF.LXMRouter.PROPAGATION_LIMIT * 40      # SYNC_LIMIT
target_stamp_cost    = LXMF.LXMRouter.PROPAGATION_COST            # 16
stamp_cost_flex      = LXMF.LXMRouter.PROPAGATION_COST_FLEX       # 3
peering_cost         = 18

announce_data = [False, timebase, node_state, per_transfer_limit, per_sync_limit,
                 [target_stamp_cost, stamp_cost_flex, peering_cost], {}]
packed = msgpack.packb(announce_data)
assert pn_announce_data_is_valid(packed) is True, "genuine validator rejected the announce"

invalid = msgpack.packb([False, timebase, node_state, per_transfer_limit, per_sync_limit, [target_stamp_cost]])  # 6 elems
assert pn_announce_data_is_valid(invalid) is False, "genuine validator accepted a malformed announce"

print(json.dumps({
    "timebase": timebase,
    "node_state": node_state,
    "per_transfer_limit": per_transfer_limit,
    "per_sync_limit": per_sync_limit,
    "target_stamp_cost": target_stamp_cost,
    "stamp_cost_flexibility": stamp_cost_flex,
    "peering_cost": peering_cost,
    "packed": packed.hex(),
    "invalid_packed": invalid.hex(),
}, indent=2))
