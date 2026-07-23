#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_transport_fixtures.py > transport_fixtures.json
#
# Emits a full HEADER_1 ANNOUNCE packet (raw bytes) wrapping a reference-authentic announce
# payload, so the Swift Transport reducer can be cross-validated: feeding this packet must
# make Transport learn the reference destination (identity hash, app_data, hops).
import json, os, time, bz2
import RNS

identity = RNS.Identity()
app, aspect = "reticula", "endpoint"
app_data = b"node-name"
name_hash = RNS.Identity.full_hash(
    RNS.Destination.expand_name(None, app, aspect).encode("utf-8")
)[:RNS.Identity.NAME_HASH_LENGTH // 8]
random_hash = RNS.Identity.get_random_hash()[:5] + int(time.time()).to_bytes(5, "big")
dest_hash = RNS.Destination.hash(identity, app, aspect)
ratchet = b""
signed = dest_hash + identity.get_public_key() + name_hash + random_hash + ratchet + app_data
signature = identity.sign(signed)
payload = identity.get_public_key() + name_hash + random_hash + ratchet + signature + app_data

# HEADER_1 ANNOUNCE packet: flags = SINGLE(0)<<2 | ANNOUNCE(1) = 0x01, no context flag, hops = 3
hops = 3
flags = 0x01
announce_packet = bytes([flags, hops]) + dest_hash + bytes([0x00]) + payload

# --- bz2 compression cross-validation (genuine Python bz2, level 9 = what RNS uses) ---
bz2_original = b"reticulum resource payload for cross validation " * 6
bz2_compressed = bz2.compress(bz2_original, 9)

print(json.dumps({
    "announce_dest_hash": dest_hash.hex(),
    "announce_identity_hash": identity.hash.hex(),
    "announce_app_data": app_data.hex(),
    "announce_hops": hops,
    "announce_packet": announce_packet.hex(),
    "bz2_original": bz2_original.hex(),
    "bz2_compressed": bz2_compressed.hex(),
    "bz2_original_len": len(bz2_original),
}, indent=2))
