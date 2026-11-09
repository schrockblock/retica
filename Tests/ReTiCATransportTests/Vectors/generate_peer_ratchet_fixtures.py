#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0, lxmf 1.3.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_peer_ratchet_fixtures.py > peer_ratchet_fixtures.json
#
# A PROPAGATED LXMF payload encrypted to the recipient's ratchet, exactly as LXMF 1.3.0 builds it:
#
#   1. A recipient delivery destination with ratchets enabled (Destination.enable_ratchets) emits a
#      genuine ratcheted announce (Destination._announce, Destination.py:307-379: context flag set,
#      ratchet public key after the random hash, signed over). The reference validates it
#      (Identity.validate_announce), which remembers the ratchet.
#   2. A genuine LXMessage with desired_method PROPAGATED is packed (LXMessage.py:433-443). Its tail is
#      encrypted through Destination.encrypt, which takes the recipient's ratchet from
#      Identity.get_ratchet (Destination.py:694-708).
#
# Encryption draws an ephemeral X25519 key (Identity.py:1187) and a Token IV (Token.py:89). For the
# duration of pack() only, those two draws are pinned to the fixed EPHEMERAL and IV below, so the
# output is reproducible: the Swift test feeds the same announce to Transport, recalls the ratchet, and
# must produce these lxmf_data bytes with the same ephemeral key and IV. Everything else is the
# reference's own code path.
#
# Guards on the generator itself: the reference decrypts the payload with the ratchet's private key,
# and does NOT decrypt it with the recipient's identity key alone.
#
# The recipient identity and its ratchet are generated here for the fixture only: no real identity's
# keys are committed.

import json
import os
import shutil
import sys
import tempfile
import types

import RNS
import LXMF

EPHEMERAL = bytes(range(0x40, 0x60))   # 32-byte X25519 private key for the ephemeral draw
IV = bytes(range(0xA0, 0xB0))          # 16-byte Token IV

workdir = tempfile.mkdtemp(prefix="retica-ratchet-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)

# 1. The recipient announces a ratchet.
recipient = RNS.Identity()
recipient_in = RNS.Destination(recipient, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
recipient_in.enable_ratchets(os.path.join(workdir, "recipient.ratchets"))
announce = recipient_in._announce(send=False)
announce.pack()
announce_raw = announce.raw
ratchet_private = recipient_in.ratchets[0]
ratchet_public = RNS.Identity._ratchet_public_bytes(ratchet_private)

received = RNS.Packet(None, announce_raw)
received.unpack()
assert received.context_flag == RNS.Packet.FLAG_SET
assert ratchet_public in received.data
assert RNS.Identity.validate_announce(received) is True
assert RNS.Identity.get_ratchet(recipient_in.hash) == ratchet_public

# 2. A sender packs a PROPAGATED message to it.
source = RNS.Identity()
source_in = RNS.Destination(source, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
recipient_out = RNS.Destination(RNS.Identity.recall(recipient_in.hash), RNS.Destination.OUT,
                                RNS.Destination.SINGLE, "lxmf", "delivery")
assert recipient_out.hash == recipient_in.hash
message = LXMF.LXMessage(recipient_out, source_in, "to the ratchet", "ratchet",
                         desired_method=LXMF.LXMessage.PROPAGATED)
message.timestamp = 1700000000.5

identity_module = sys.modules["RNS.Identity"]
token_module = sys.modules["RNS.Cryptography.Token"]
real_x25519 = identity_module.X25519PrivateKey
real_os = token_module.os


class PinnedEphemeral:
    @staticmethod
    def generate():
        return real_x25519.from_private_bytes(EPHEMERAL)

    @staticmethod
    def from_private_bytes(data):
        return real_x25519.from_private_bytes(data)


def pinned_urandom(n):
    assert n == 16, f"unexpected urandom({n}) during pack"
    return IV


identity_module.X25519PrivateKey = PinnedEphemeral
token_module.os = types.SimpleNamespace(urandom=pinned_urandom)
try:
    message.pack()
finally:
    identity_module.X25519PrivateKey = real_x25519
    token_module.os = real_os

timestamp, entries = RNS.vendor.umsgpack.unpackb(message.propagation_packed)
assert len(entries) == 1
lxmf_data = entries[0]
assert message.propagation_stamp is None   # stampless: the transient id covers exactly these bytes
assert message.transient_id == RNS.Identity.full_hash(lxmf_data)
assert message.ratchet_id == RNS.Identity._get_ratchet_id(ratchet_public)

encrypted = lxmf_data[LXMF.LXMessage.DESTINATION_LENGTH:]
assert encrypted[:32] == real_x25519.from_private_bytes(EPHEMERAL).public_key().public_bytes()
tail = message.packed[LXMF.LXMessage.DESTINATION_LENGTH:]
assert recipient.decrypt(encrypted, ratchets=[ratchet_private]) == tail
assert recipient.decrypt(encrypted) is None

print(json.dumps({
    "recipient_private_key": recipient.get_private_key().hex(),
    "destination_hash": recipient_in.hash.hex(),
    "announce_raw": announce_raw.hex(),
    "ratchet_public": ratchet_public.hex(),
    "ratchet_private": ratchet_private.hex(),
    "message_packed": message.packed.hex(),
    "ephemeral_private": EPHEMERAL.hex(),
    "iv": IV.hex(),
    "lxmf_data": lxmf_data.hex(),
    "transient_id": message.transient_id.hex(),
    "versions": {"rns": RNS.__version__, "lxmf": LXMF.__version__},
}, indent=2))
shutil.rmtree(workdir, ignore_errors=True)
