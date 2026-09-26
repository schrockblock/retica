#!/usr/bin/env python3
"""
Cross-validation fixture for ReTiCA single-packet delivery proofs.

Every proof byte below comes from GENUINE RNS 1.4.2 code paths:
  * the DATA packet is parsed by RNS.Packet.unpack (which computes packet_hash);
  * the proofs are produced by calling the real RNS.Identity.prove(packet), which builds a
    ProofDestination and a PROOF packet and calls Packet.send(). send() is replaced by a capture
    stub (there is no running Reticulum instance), so the packet is packed by the real
    Packet.pack() and captured before it would reach Transport.outbound.
  * implicit vs explicit is selected by the same class flag Identity.prove reads
    (Reticulum.should_use_implicit_proof -> Reticulum.__use_implicit_proof).

Run by absolute path with the conda `rns` env, from any directory:
  /Users/ell/opt/anaconda3/envs/rns/bin/python <this file>
It writes proof_fixtures.json next to itself.

The DATA packet's ciphertext is random (Identity.encrypt uses an ephemeral key), so re-running
changes data_packet / data_packet_hash / both proofs. That is expected: commit the regenerated
JSON as a unit. The identity, destination hash and plaintext are fixed.
"""
import json
import os
import sys

try:
    import RNS
    from RNS.Identity import Identity
    from RNS.Packet import Packet
except ImportError as e:
    print("BLOCKED: RNS import failed:", e, file=sys.stderr)
    sys.exit(1)

PRV = bytes(range(1, 65))            # X25519 seed (32) || Ed25519 seed (32), ReTiCA's order too
PLAINTEXT = b"single-packet proof vector"

identity = Identity.from_bytes(PRV)
if identity is None:
    print("BLOCKED: Identity.from_bytes returned None", file=sys.stderr)
    sys.exit(1)

dest_hash = RNS.Destination.hash(identity, "lxmf", "delivery")

# HEADER_1 / BROADCAST / SINGLE / DATA (flags 0x00), hops 0, context NONE.
data_raw = bytes([0x00, 0x00]) + dest_hash + bytes([0x00]) + identity.encrypt(PLAINTEXT)
data_packet = Packet(None, data_raw)
if not data_packet.unpack():
    print("BLOCKED: RNS could not unpack the DATA packet", file=sys.stderr)
    sys.exit(1)

captured = []
def _capture_send(self):
    if not self.packed:
        self.pack()
    captured.append(self.raw)
    return None
Packet.send = _capture_send


def prove(implicit):
    RNS.Reticulum._Reticulum__use_implicit_proof = implicit
    before = len(captured)
    identity.prove(data_packet)          # THE REAL THING: RNS.Identity.prove
    if len(captured) != before + 1:
        print("BLOCKED: Identity.prove did not send exactly one packet", file=sys.stderr)
        sys.exit(1)
    return captured[-1]


implicit_proof_packet = prove(True)
explicit_proof_packet = prove(False)

# Sanity: the genuine code must have produced what the spec describes. Stop, don't fudge.
assert implicit_proof_packet[0] == 0x03, hex(implicit_proof_packet[0])       # H1/BCAST/SINGLE/PROOF
assert implicit_proof_packet[2:18] == data_packet.packet_hash[:16]
assert implicit_proof_packet[18] == 0x00                                        # context NONE
assert len(implicit_proof_packet) == 19 + 64
assert len(explicit_proof_packet) == 19 + 96
assert explicit_proof_packet[19:51] == data_packet.packet_hash

out = {
    "rns_version": RNS.__version__,
    "identity_private_key": PRV.hex(),
    "identity_public_key": identity.get_public_key().hex(),
    "destination_hash": dest_hash.hex(),
    "plaintext": PLAINTEXT.hex(),
    "data_packet": data_raw.hex(),
    "data_packet_hash": data_packet.packet_hash.hex(),
    "implicit_proof_payload": implicit_proof_packet[19:].hex(),
    "explicit_proof_payload": explicit_proof_packet[19:].hex(),
    "implicit_proof_packet": implicit_proof_packet.hex(),
    "explicit_proof_packet": explicit_proof_packet.hex(),
}
path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "proof_fixtures.json")
with open(path, "w") as f:
    json.dump(out, f, indent=2, sort_keys=True)
    f.write("\n")
print("wrote " + path)
