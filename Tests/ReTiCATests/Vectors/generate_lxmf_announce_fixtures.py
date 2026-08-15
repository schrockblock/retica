#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_lxmf_announce_fixtures.py > lxmf_announce_fixtures.json
#
# Emits genuine lxmf 1.1.0 delivery-destination announce app_data wire bytes for cross-
# validation of LXMFAnnounceData.pack / .parse in Swift.
#
# WHY msgpack.packb directly, NOT LXMRouter.get_announce_app_data:
#   register_delivery_identity calls enable_ratchets (filesystem, ratchet state), and the
#   router's __init__ requires an identity + storagepath, binding RNS's network stack.
#   That scaffolding brings in network I/O and ephemeral filesystem state that would make
#   the generator non-deterministic and fragile. Instead we build the EXACT peer_data list
#   that get_announce_app_data constructs (LXMRouter.py:1038-1049) and encode it with the
#   same msgpack.packb call. This is a one-hop step away from ground truth (the logic is
#   short and auditable here), and it stays so as long as get_announce_app_data does not
#   change. Future readers: re-read LXMRouter.py:1034-1050 to confirm the list shape has
#   not drifted before regenerating.
#
# Reference: LXMF 1.1.0 (stock, conda `rns` env)
#   LXMRouter.get_announce_app_data   LXMRouter.py:1034-1050
#   SF_COMPRESSION                    LXMF.py:142   (= 0x00)
#   display_name_from_app_data        LXMF.py:151-172
#   stamp_cost_from_app_data          LXMF.py:174-185
#   compression_support_from_app_data LXMF.py:187-200

import json
import RNS.vendor.umsgpack as msgpack
import LXMF

SF_COMPRESSION = LXMF.SF_COMPRESSION  # 0x00

def build_peer_data(display_name_str, stamp_cost):
    """Mirror the logic in LXMRouter.get_announce_app_data (LXMRouter.py:1038-1048)."""
    if display_name_str is not None:
        display_name = display_name_str.encode("utf-8")  # line 1040
    else:
        display_name = None                              # line 1038

    if stamp_cost is not None and isinstance(stamp_cost, int):
        if stamp_cost > 0 and stamp_cost < 255:          # line 1044
            sc = stamp_cost
        else:
            sc = None
    else:
        sc = None

    supported_functionality = [SF_COMPRESSION]           # line 1047
    return [display_name, sc, supported_functionality]   # line 1048

def pack_peer_data(display_name_str, stamp_cost):
    return msgpack.packb(build_peer_data(display_name_str, stamp_cost))

def round_trip_check(packed, expected_name, expected_cost, expected_compression):
    """Verify with genuine LXMF helper functions."""
    dn  = LXMF.display_name_from_app_data(packed)
    sc  = LXMF.stamp_cost_from_app_data(packed)
    cmp = LXMF.compression_support_from_app_data(packed)
    assert dn  == expected_name,        f"display_name: {dn!r} != {expected_name!r}"
    assert sc  == expected_cost,        f"stamp_cost: {sc!r} != {expected_cost!r}"
    assert cmp == expected_compression, f"compression: {cmp!r} != {expected_compression!r}"

# ── Fixture 1: name + cost ────────────────────────────────────────────────────
name_cost = pack_peer_data("Alice", 8)
round_trip_check(name_cost, "Alice", 8, True)

# ── Fixture 2: both nil ───────────────────────────────────────────────────────
both_nil = pack_peer_data(None, None)
round_trip_check(both_nil, None, None, True)

# ── Fixture 3: name only (nil cost) ──────────────────────────────────────────
name_only = pack_peer_data("Bob", None)
round_trip_check(name_only, "Bob", None, True)

# ── Fixture 4: cost only (nil name) ──────────────────────────────────────────
cost_only = pack_peer_data(None, 16)
round_trip_check(cost_only, None, 16, True)

# ── Fixture 5: pre-0.5.0 raw-UTF-8 (legacy) blob ────────────────────────────
# Before LXMF 0.5.0 the announce app_data was a plain UTF-8 display name, NOT
# a msgpack array. The reference consumer (LXMF.py:172) takes the `else` branch
# when the first byte is outside 0x90-0x9F / 0xDC.  We reproduce that blob here:
# "Legacy User" begins with 'L' (0x4C), which is outside the gate.
legacy_blob = "Legacy User".encode("utf-8")
assert legacy_blob[0] < 0x90 or legacy_blob[0] > 0x9F
assert legacy_blob[0] != 0xDC
# The reference helpers treat this as: display_name="Legacy User", stamp_cost=None, compression=True
assert LXMF.display_name_from_app_data(legacy_blob) == "Legacy User"
assert LXMF.stamp_cost_from_app_data(legacy_blob)   is None
assert LXMF.compression_support_from_app_data(legacy_blob) is True

print(json.dumps({
    "name_cost": {
        "display_name": "Alice",
        "stamp_cost": 8,
        "supports_compression": True,
        "packed": name_cost.hex(),
    },
    "both_nil": {
        "display_name": None,
        "stamp_cost": None,
        "supports_compression": True,
        "packed": both_nil.hex(),
    },
    "name_only": {
        "display_name": "Bob",
        "stamp_cost": None,
        "supports_compression": True,
        "packed": name_only.hex(),
    },
    "cost_only": {
        "display_name": None,
        "stamp_cost": 16,
        "supports_compression": True,
        "packed": cost_only.hex(),
    },
    "legacy": {
        "display_name": "Legacy User",
        "stamp_cost": None,
        "supports_compression": True,
        "packed": legacy_blob.hex(),
    },
}, indent=2))
