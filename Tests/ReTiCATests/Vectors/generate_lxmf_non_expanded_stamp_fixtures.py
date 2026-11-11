#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0, lxmf 1.3.0) by absolute path, from this directory:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_lxmf_non_expanded_stamp_fixtures.py > lxmf_non_expanded_stamp_fixtures.json
#
# NON-EXPANDED workblock stamps, and LXMF 1.3.0 rejecting them. RNS.Stamps.generate_stamp(material,
# cost, no_expand=True, size=32) searches over the raw material as the workblock (no HKDF expansion).
# LXMF 1.3.0 never produces such a stamp and its validators always expand the workblock, so a
# non-expanded stamp is refused at the same cost. Every verdict below comes from genuine reference code:
# RNS.Stamps.generate_stamp / stamp_valid / stamp_value, LXMF.LXStamper.validate_pn_stamp /
# validate_peering_key / stamp_workblock, and LXMF.LXMessage.validate_stamp. Nothing is hand-rolled.
# Stubs: RNS.Transport.register_destination (network edge only, so Destinations can be built offline).
#
# Per kind (message id, transient id, peering id) the generator asserts the stamp is valid against the
# non-expanded workblock at the cost, and that the EXPANDED value is below the cost (it regenerates
# otherwise, so the rejection is never an accidental expanded pass).
#
# Stamps are random, so each run emits different bytes. The committed JSON is one run.

import json
import logging

logging.disable(logging.CRITICAL)

import RNS
RNS.loglevel = -1
from RNS import Stamps
import LXMF
import LXMF.LXStamper as LXStamper

COST = 12
SIZE = LXStamper.STAMP_SIZE


def non_expanded_stamp(material, rounds):
    """A genuine reference non-expanded stamp whose EXPANDED value (over `rounds`) is below COST."""
    expanded = LXStamper.stamp_workblock(material, expand_rounds=rounds)
    while True:
        stamp, value = Stamps.generate_stamp(material, COST, no_expand=True, size=SIZE)
        assert len(stamp) == SIZE
        assert Stamps.stamp_valid(stamp, COST, material), "non-expanded stamp must meet the cost"
        expanded_value = Stamps.stamp_value(expanded, stamp)
        if expanded_value < COST:
            assert not Stamps.stamp_valid(stamp, COST, expanded)
            return stamp, value, expanded_value


# --- delivery stamp, over a real LXMessage ------------------------------------------------------------
RNS.Transport.register_destination = staticmethod(lambda *a, **k: None)
src = RNS.Destination(RNS.Identity(), RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
dst = RNS.Destination(RNS.Identity(), RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
msg = LXMF.LXMessage(dst, src, content=b"non-expanded", title=b"stamp")
msg.timestamp = 1700000000.25
msg.defer_stamp = False
msg.pack()
assert msg.stamp is None
stamp, ne_value, expanded_value = non_expanded_stamp(msg.message_id, LXStamper.WORKBLOCK_EXPAND_ROUNDS)
msg.stamp = stamp
message = {
    "packed": msg.packed.hex(),
    "hash": msg.hash.hex(),
    "stamp": stamp.hex(),
    "non_expanded_value": ne_value,
    "expanded_value": expanded_value,
    "reference_validate_stamp": msg.validate_stamp(COST),
    "non_expanded_stamp_valid": Stamps.stamp_valid(stamp, COST, msg.message_id),
}
assert message["reference_validate_stamp"] is False and message["non_expanded_stamp_valid"] is True

# --- propagation-node stamp ---------------------------------------------------------------------------
# A transient: lxm_data longer than LXMF_OVERHEAD + STAMP_SIZE, so validate_pn_stamp reads it.
lxm_data = RNS.Identity.full_hash(b"retica-non-expanded-pn") * 5
transient_id = RNS.Identity.full_hash(lxm_data)
pn_stamp, pn_ne_value, pn_expanded_value = non_expanded_stamp(transient_id, LXStamper.WORKBLOCK_EXPAND_ROUNDS_PN)
pn_result = LXStamper.validate_pn_stamp(lxm_data + pn_stamp, COST)
assert pn_result == (None, None, None, None)
pn = {
    "lxm_data": lxm_data.hex(),
    "transient_id": transient_id.hex(),
    "stamp": pn_stamp.hex(),
    "non_expanded_value": pn_ne_value,
    "expanded_value": pn_expanded_value,
    "reference_validate_pn_stamp_accepts": pn_result[0] is not None,
    "non_expanded_stamp_valid": Stamps.stamp_valid(pn_stamp, COST, transient_id),
}
assert pn["non_expanded_stamp_valid"] is True

# --- peering key --------------------------------------------------------------------------------------
peering_id = RNS.Identity.full_hash(b"retica-non-expanded-peering")
pk_stamp, pk_ne_value, pk_expanded_value = non_expanded_stamp(peering_id, LXStamper.WORKBLOCK_EXPAND_ROUNDS_PEERING)
peering = {
    "peering_id": peering_id.hex(),
    "stamp": pk_stamp.hex(),
    "non_expanded_value": pk_ne_value,
    "expanded_value": pk_expanded_value,
    "reference_validate_peering_key": LXStamper.validate_peering_key(peering_id, pk_stamp, COST),
    "non_expanded_stamp_valid": Stamps.stamp_valid(pk_stamp, COST, peering_id),
}
assert peering["reference_validate_peering_key"] is False and peering["non_expanded_stamp_valid"] is True

print(json.dumps({
    "versions": {"rns": RNS.__version__, "lxmf": LXMF.__version__},
    "cost": COST,
    "message": message,
    "pn": pn,
    "peering": peering,
}, indent=2))
