#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0, lxmf 1.3.0) by absolute path.
#
# Generate mode (no arguments) writes the committed fixture:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_own_ratchet_fixtures.py > own_ratchet_fixtures.json
#
# Validate mode checks an announce ReTiCA built, and encrypts a packet to the ratchet it carries:
#   python generate_own_ratchet_fixtures.py --validate <file holding the announce's raw bytes as hex> <plaintext hex>
# It prints one line `RESULT <json>` (and nothing else on success), which
# Tests/ReTiCATransportTests/Vectors/OwnRatchetCrossValidationTests.swift reads when
# RETICA_REFERENCE_PYTHON (or RETICA_LIVE_STAMP_PYTHON) names this interpreter.
#
# What the fixture holds, all built by reference code paths:
#
#   * A FIXED TEST identity and a fixed ring of three ratchet private keys (newest first), derived from
#     SHA-256 of labels below. They are fixture keys only: no real identity's keys are committed.
#   * `announce_raw`: the announce a reference destination with that identity and ring emits
#     (Destination._announce, Destination.py:307-379: ratchet = public key of ratchets[0] after the
#     random hash, signed over, context flag set). Rotation is held off by setting
#     latest_ratchet_time to now, so the announced ratchet is ring[0]. The reference validates it.
#   * Three DATA packets to the destination ("retica", "ownratchet"), each packed by a genuine
#     RNS.Packet to an OUT destination, so encryption goes through Destination.encrypt, which uses
#     Identity.get_ratchet (Destination.py:694-708):
#       - `packet_identity`: packed before any ratchet is known, so to the identity key;
#       - `packet_ratchet0`: after the reference announce is validated, so to ring[0];
#       - `packet_ratchet2`: after the reference remembers ring[2]'s public key, so to an older ratchet.
#   * Two PROPAGATED LXMF entries to ("lxmf", "delivery") of the same identity, packed by a genuine
#     LXMessage.pack() (LXMessage.py:433-443), encrypting through Destination.encrypt:
#       - `propagated_identity`: before any ratchet is known for that destination;
#       - `propagated_ratchet1`: after the reference remembers ring[1]'s public key.
#
# Guards on the generator itself: the reference decrypts every ratchet case with the ring and with
# ratchet enforcement, decrypts the identity-key cases with the ring but NOT with enforcement, and
# cannot decrypt a ratchet case with the identity key alone.

import hashlib
import json
import os
import shutil
import sys
import tempfile
import time

import RNS


def fixture_key(label):
    return hashlib.sha256(("retica own-ratchet fixture " + label).encode()).digest()


IDENTITY_PRIVATE = fixture_key("identity x25519") + fixture_key("identity ed25519")
RING = [fixture_key(f"ratchet {i}") for i in range(3)]   # newest first
PLAINTEXT = b"to our own ratchet"


def start_reticulum():
    workdir = tempfile.mkdtemp(prefix="retica-own-ratchet-")
    configdir = os.path.join(workdir, "rns")
    os.makedirs(configdir)
    with open(os.path.join(configdir, "config"), "w") as f:
        f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
                "[logging]\n  loglevel = 0\n\n[interfaces]\n")
    RNS.Reticulum(configdir)
    return workdir


def validate_mode(announce_path, plaintext_hex):
    workdir = start_reticulum()
    with open(announce_path) as f:
        raw = bytes.fromhex(f.read().strip())
    received = RNS.Packet(None, raw)
    received.unpack()
    result = {"context_flag": received.context_flag == RNS.Packet.FLAG_SET}
    result["valid"] = RNS.Identity.validate_announce(received) is True
    ratchet = RNS.Identity.get_ratchet(received.destination_hash)
    result["ratchet"] = ratchet.hex() if ratchet else None
    if result["valid"] and ratchet:
        identity = RNS.Identity.recall(received.destination_hash)
        # The aspects are not on the wire; an OUT destination is found by its hash alone here, so build
        # it with the name ReTiCA's test uses and check the hash matches.
        out = RNS.Destination(identity, RNS.Destination.OUT, RNS.Destination.SINGLE, "retica", "ownratchet")
        assert out.hash == received.destination_hash, "the test must announce retica.ownratchet"
        packet = RNS.Packet(out, bytes.fromhex(plaintext_hex))
        packet.pack()
        result["packet"] = packet.raw.hex()
        result["ratchet_id"] = out.latest_ratchet_id.hex() if out.latest_ratchet_id else None
    print("RESULT " + json.dumps(result))
    shutil.rmtree(workdir, ignore_errors=True)


def generate_mode():
    import LXMF

    workdir = start_reticulum()
    identity = RNS.Identity.from_bytes(IDENTITY_PRIVATE)
    public_only = RNS.Identity(create_keys=False)
    public_only.load_public_key(identity.get_public_key())
    ring_public = [RNS.Identity._ratchet_public_bytes(r) for r in RING]

    destination = RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, "retica", "ownratchet")
    out = RNS.Destination(public_only, RNS.Destination.OUT, RNS.Destination.SINGLE, "retica", "ownratchet")
    assert out.hash == destination.hash

    def packet_to(dest):
        p = RNS.Packet(dest, PLAINTEXT)
        p.pack()
        return p.raw, p.ciphertext

    # 1. Nothing known about a ratchet yet: the identity key.
    assert RNS.Identity.get_ratchet(destination.hash) is None
    packet_identity, ct_identity = packet_to(out)

    # 2. The reference destination announces ring[0].
    destination.enable_ratchets(os.path.join(workdir, "own.ratchets"))
    destination.ratchets = list(RING)
    destination.latest_ratchet_time = time.time()   # hold off rotation: announce ring[0]
    announce = destination._announce(send=False)
    announce.pack()
    announce_raw = announce.raw
    assert destination.ratchets == RING, "the announce must not have rotated"
    received = RNS.Packet(None, announce_raw)
    received.unpack()
    assert received.context_flag == RNS.Packet.FLAG_SET
    assert RNS.Identity.validate_announce(received) is True
    assert RNS.Identity.get_ratchet(destination.hash) == ring_public[0]
    packet_ratchet0, ct_ratchet0 = packet_to(out)

    # 3. An older ratchet of ours, still in the ring.
    RNS.Identity.known_ratchets[destination.hash] = ring_public[2]
    RNS.Identity._remember_ratchet(destination.hash, ring_public[2])
    assert RNS.Identity.get_ratchet(destination.hash) == ring_public[2]
    packet_ratchet2, ct_ratchet2 = packet_to(out)

    for name, ct, ratcheted in [("identity", ct_identity, False), ("ratchet0", ct_ratchet0, True),
                                ("ratchet2", ct_ratchet2, True)]:
        assert identity.decrypt(ct, ratchets=RING) == PLAINTEXT, name
        enforced = identity.decrypt(ct, ratchets=RING, enforce_ratchets=True)
        assert enforced == (PLAINTEXT if ratcheted else None), name
        if ratcheted:
            assert identity.decrypt(ct) is None, name

    # 4. Propagated LXMF to our delivery destination.
    delivery = RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")
    delivery_out = RNS.Destination(public_only, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
    assert delivery_out.hash == delivery.hash
    source = RNS.Identity.from_bytes(fixture_key("source x25519") + fixture_key("source ed25519"))
    source_in = RNS.Destination(source, RNS.Destination.IN, RNS.Destination.SINGLE, "lxmf", "delivery")

    def propagated(title):
        message = LXMF.LXMessage(delivery_out, source_in, "propagated to our ratchet", title,
                                 desired_method=LXMF.LXMessage.PROPAGATED)
        message.timestamp = 1700000000.5
        message.pack()
        _, entries = RNS.vendor.umsgpack.unpackb(message.propagation_packed)
        assert len(entries) == 1 and message.propagation_stamp is None
        return entries[0], message.packed

    assert RNS.Identity.get_ratchet(delivery.hash) is None
    propagated_identity, packed_identity = propagated("identity")
    RNS.Identity.known_ratchets[delivery.hash] = ring_public[1]
    RNS.Identity._remember_ratchet(delivery.hash, ring_public[1])
    assert RNS.Identity.get_ratchet(delivery.hash) == ring_public[1]
    propagated_ratchet1, packed_ratchet1 = propagated("ratchet1")

    for name, entry, packed, ratcheted in [("identity", propagated_identity, packed_identity, False),
                                           ("ratchet1", propagated_ratchet1, packed_ratchet1, True)]:
        encrypted = entry[LXMF.LXMessage.DESTINATION_LENGTH:]
        tail = packed[LXMF.LXMessage.DESTINATION_LENGTH:]
        assert identity.decrypt(encrypted, ratchets=RING) == tail, name
        assert identity.decrypt(encrypted, ratchets=RING, enforce_ratchets=True) == (tail if ratcheted else None), name
        if ratcheted:
            assert identity.decrypt(encrypted) is None, name

    print(json.dumps({
        "identity_private_key": IDENTITY_PRIVATE.hex(),
        "ring": [r.hex() for r in RING],
        "ring_public": [r.hex() for r in ring_public],
        "app_name": "retica",
        "aspects": ["ownratchet"],
        "destination_hash": destination.hash.hex(),
        "delivery_destination_hash": delivery.hash.hex(),
        "announce_raw": announce_raw.hex(),
        "plaintext": PLAINTEXT.hex(),
        "packet_identity": packet_identity.hex(),
        "packet_ratchet0": packet_ratchet0.hex(),
        "packet_ratchet2": packet_ratchet2.hex(),
        "propagated_identity": propagated_identity.hex(),
        "propagated_identity_packed": packed_identity.hex(),
        "propagated_ratchet1": propagated_ratchet1.hex(),
        "propagated_ratchet1_packed": packed_ratchet1.hex(),
        "versions": {"rns": RNS.__version__, "lxmf": LXMF.__version__},
    }, indent=2))
    shutil.rmtree(workdir, ignore_errors=True)


if __name__ == "__main__":
    if len(sys.argv) == 4 and sys.argv[1] == "--validate":
        validate_mode(sys.argv[2], sys.argv[3])
    else:
        generate_mode()
