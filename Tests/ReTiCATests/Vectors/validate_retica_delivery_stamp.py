#!/usr/bin/env python
"""Cross-validate a ReTiCA-GENERATED delivery stamp against genuine LXMF 1.1.0.

This is the reverse direction from every other generator in this directory. The others
produce reference bytes for Swift to match. This one CONSUMES a Swift artefact and asks
whether the reference implementation accepts it — which is the only way to answer the
question the delivery-stamp slice exists for: "will a peer running enforce_stamps()
actually accept what we send?"

Everything else in that slice establishes this by construction (our stampValid mirrors
reference's stamp_valid, our workblock mirrors theirs). Construction is not proof; the
whole point of a cross-validation directory is that mirrored logic can be mirrored wrong.

USAGE — two steps, because the artefact comes from the Swift side:

  1. Produce the artefact. There is no committed Swift test that writes it yet (filed:
     see docs/reference-parity-checklist.md, Tier 3 delivery stamps). A throwaway
     @Test that does the job:

         let messageId = Data((0..<32).map { UInt8($0) })
         let stamp = await LXStamper.generateStamp(messageId: messageId, targetCost: 10)!
         // write {"message_id": hex, "cost": 10, "stamp": hex} to the path below

  2. Run this against the `rns` conda env, which has stock LXMF 1.1.0:

         /Users/ell/opt/anaconda3/envs/rns/bin/python validate_retica_delivery_stamp.py

RESULT ON 2026-08-16, ReTiCA d6b7420, stock LXMF 1.1.0:

    workblock bytes: 768000            (3000 rounds x 256 B — matches WORKBLOCK_EXPAND_ROUNDS)
    REFERENCE stamp_valid(stamp, 10, workblock) = True
    REFERENCE stamp_value = 11         (>= 10, so genuinely over the bar)
    control (all-zero stamp) valid = False, stamp_value = 0
    VERDICT: reference ACCEPTS ReTiCA's stamp

The all-zero control is load-bearing: without it, a validator that returned True for
everything would look like a pass.
"""
import json
import sys

import LXMF
from LXMF import LXStamper

ARTEFACT = "/tmp/ReTiCA/retica_raw_stamp.json"

try:
    with open(ARTEFACT) as f:
        art = json.load(f)
except FileNotFoundError:
    sys.exit(f"No artefact at {ARTEFACT} — produce it from the Swift side first (see docstring).")

message_id = bytes.fromhex(art["message_id"])
stamp = bytes.fromhex(art["stamp"])
cost = art["cost"]

print(f"LXMF version: {getattr(LXMF, '__version__', 'unknown')}")
print(f"message_id: {art['message_id']}")
print(f"cost claimed: {cost}")

# Exactly what LXMessage.validate_stamp does on the non-ticket path (LXMessage.py:288-289).
workblock = LXStamper.stamp_workblock(message_id)
print(f"workblock bytes: {len(workblock)}")

valid = LXStamper.stamp_valid(stamp, cost, workblock)
value = LXStamper.stamp_value(workblock, stamp)
print(f"REFERENCE stamp_valid(stamp, {cost}, workblock) = {valid}")
print(f"REFERENCE stamp_value = {value}   (must be >= {cost})")

# Negative control — same length, never searched for.
bogus = bytes(32)
print(f"control (all-zero stamp) valid = {LXStamper.stamp_valid(bogus, cost, workblock)}")
print(f"control stamp_value = {LXStamper.stamp_value(workblock, bogus)}")

print("VERDICT:", "reference ACCEPTS ReTiCA's stamp" if valid else "reference REJECTS ReTiCA's stamp")
sys.exit(0 if valid else 1)
