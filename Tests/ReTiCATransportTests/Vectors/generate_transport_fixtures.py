#!/usr/bin/env python3
# Run in the conda `rns` env by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns/bin/python generate_transport_fixtures.py > transport_fixtures.json
#
# Emits a full HEADER_1 ANNOUNCE packet (raw bytes) wrapping a reference-authentic announce
# payload, so the Swift Transport reducer can be cross-validated: feeding this packet must
# make Transport learn the reference destination (identity hash, app_data, hops).
import json, os, time, bz2
import RNS
from RNS.Resource import Resource, ResourceAdvertisement

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

# --- Multi-segment resource cross-validation ---
# Monkeypatch RNS.Packet to bypass real part-packet construction (needs a full link).
_RealPacket = RNS.Packet
class _FakePacket:
    RESOURCE = _RealPacket.RESOURCE
    def __init__(self, *a, **k): self.map_hash = None; self.data = None
    def pack(self, *a, **k): return b""
RNS.Packet = _FakePacket

class _StubLink:
    mtu = None
    mdu = 200000          # large SDU → few parts → fast; segmentation is sdu-independent
    rtt = 0.1
    traffic_timeout_factor = 1.5
    def encrypt(self, data): return data

_MAX = Resource.MAX_EFFICIENT_SIZE      # 1048575
_total = _MAX + 100                     # 2 segments
_payload = os.urandom(_total)           # distinct parts → avoids RNS's collision-remap loop
_link = _StubLink()
_seg1 = Resource(_payload, _link, advertise=False, auto_compress=False, segment_index=1)
_seg2 = Resource(_seg1.input_file, _link, advertise=False, auto_compress=False,
                 segment_index=2, original_hash=_seg1.original_hash)
_a1, _a2 = ResourceAdvertisement(_seg1), ResourceAdvertisement(_seg2)
RNS.Packet = _RealPacket                # restore

# --- 4b-3a: announce random-blob anti-replay cross-validation ---
# Two GENUINE announces for the SAME destination with distinct random_hashes. For each, also emit
# the random_blob RNS itself would extract (Transport.py:1807) so the Swift side can assert its
# parsed randomHash byte-equals RNS's key.
_KS = RNS.Identity.KEYSIZE // 8
_NH = RNS.Identity.NAME_HASH_LENGTH // 8
def _build_announce(rnd_hash, hops_):
    signed_ = dest_hash + identity.get_public_key() + name_hash + rnd_hash + ratchet + app_data
    sig_ = identity.sign(signed_)
    payload_ = identity.get_public_key() + name_hash + rnd_hash + ratchet + sig_ + app_data
    packet_ = bytes([flags, hops_]) + dest_hash + bytes([0x00]) + payload_
    blob_ = payload_[_KS + _NH : _KS + _NH + 10]   # RNS Transport.py:1807 slice of packet.data
    return packet_.hex(), blob_.hex()

_rh1 = RNS.Identity.get_random_hash()[:5] + int(time.time()).to_bytes(5, "big")
_rh2 = RNS.Identity.get_random_hash()[:5] + (int(time.time()) + 1).to_bytes(5, "big")  # newer
_rb_ann1, _rb_blob1 = _build_announce(_rh1, 2)
_rb_ann2, _rb_blob2 = _build_announce(_rh2, 2)

print(json.dumps({
    "announce_dest_hash": dest_hash.hex(),
    "announce_identity_hash": identity.hash.hex(),
    "announce_app_data": app_data.hex(),
    "announce_hops": hops,
    "announce_packet": announce_packet.hex(),
    "bz2_original": bz2_original.hex(),
    "bz2_compressed": bz2_compressed.hex(),
    "bz2_original_len": len(bz2_original),
    "ms_max_efficient_size": _MAX,
    "ms_total_size": _total,
    "ms_seg1_adv": _a1.pack().hex(),
    "ms_seg2_adv": _a2.pack().hex(),
    "ms_seg1_i": _a1.i, "ms_seg1_l": _a1.l, "ms_seg1_o": _a1.o.hex(), "ms_seg1_d": _a1.d, "ms_seg1_f": _a1.f,
    "ms_seg2_i": _a2.i, "ms_seg2_o": _a2.o.hex(), "ms_seg2_f": _a2.f,
    "rb_announce1": _rb_ann1,
    "rb_blob1": _rb_blob1,
    "rb_announce2": _rb_ann2,
    "rb_blob2": _rb_blob2,
    "pathfinder_rw": RNS.Transport.PATHFINDER_RW,
    "local_rebroadcasts_max": RNS.Transport.LOCAL_REBROADCASTS_MAX,
    "pathfinder_g": RNS.Transport.PATHFINDER_G,
    "destination_timeout": RNS.Transport.DESTINATION_TIMEOUT,
    "link_timeout": RNS.Transport.LINK_TIMEOUT,
}, indent=2))
