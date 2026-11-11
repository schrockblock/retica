#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_tunnel_synthesis_fixtures.py > tunnel_synthesis_fixtures.json
#
# Emits the tunnel-synthesis packet RNS 1.6.0 sends when a TCP client interface connects
# (Transport.synthesize_tunnel, Transport.py:3043-3064), and what the hub's real
# Transport.tunnel_synthesize_handler (Transport.py:3067-3089) makes of its payload.
#
# Genuine reference code paths driven: Transport.synthesize_tunnel (packet layout, signing,
# PLAIN "rnstransport.tunnel.synthesize" destination, RNS.Packet framing via Packet.pack) and
# Transport.tunnel_synthesize_handler (length check, tunnel_id derivation, signature validation).
#
# Named stubs (network edges and randomness only):
#   - STUB RNS.Transport.identity      -> a fixed identity (Identity.from_bytes of FIXED_PRIVATE_KEY)
#   - STUB RNS.Identity.get_random_hash -> returns FIXED_RANDOM_HASH
#   - STUB StubInterface               -> a stand-in interface whose get_hash() returns the fixed
#                                         interface hash full_hash(b"TCPInterface[tcp]") (ReTiCA's
#                                         Ruling 9c derivation for a profile named "tcp")
#   - STUB RNS.Packet.send             -> packs the packet (genuine Packet.pack) and records raw
#                                         bytes instead of handing them to Transport.outbound
#   - STUB RNS.Transport.handle_tunnel -> records the tunnel id the handler validated
#   - STUB StubPacket                  -> carries receiving_interface into the handler

import hashlib
import json
import os
import shutil
import tempfile

import RNS

workdir = tempfile.mkdtemp(prefix="retica-tunnel-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)

FIXED_PRIVATE_KEY = hashlib.sha512(b"retica-tunnel-synthesis-fixture").digest()
FIXED_RANDOM_HASH = bytes(range(0xA0, 0xB0))
INTERFACE_NAME = "TCPInterface[tcp]"
FIXED_INTERFACE_HASH = RNS.Identity.full_hash(INTERFACE_NAME.encode("utf-8"))

identity = RNS.Identity.from_bytes(FIXED_PRIVATE_KEY)
RNS.Transport.identity = identity                               # STUB
RNS.Identity.get_random_hash = staticmethod(lambda: FIXED_RANDOM_HASH)  # STUB


class StubInterface:                                            # STUB
    wants_tunnel = True

    def get_hash(self):
        return FIXED_INTERFACE_HASH

    def __str__(self):
        return INTERFACE_NAME


sent = []


def recording_send(self):                                       # STUB
    if not self.packed:
        self.pack()
    sent.append(self)
    return True


RNS.Packet.send = recording_send

interface = StubInterface()
RNS.Transport.synthesize_tunnel(interface)
assert len(sent) == 1, "synthesize_tunnel sends exactly one packet"
assert interface.wants_tunnel is False, "synthesize_tunnel clears wants_tunnel"
packet = sent[0]
raw = packet.raw
payload = packet.data

# Hub side: the real handler, with handle_tunnel recording what it validated.
handled = []
RNS.Transport.handle_tunnel = staticmethod(lambda tunnel_id, iface: handled.append((tunnel_id, iface)))  # STUB


class StubPacket:                                               # STUB
    def __init__(self, receiving_interface):
        self.receiving_interface = receiving_interface


hub_interface = object()
RNS.Transport.tunnel_synthesize_handler(payload, StubPacket(hub_interface))
assert len(handled) == 1 and handled[0][1] is hub_interface, "the reference handler accepts the payload"

# A one-bit flip in the signed part is rejected by the same handler: proves the check is live.
tampered = bytearray(payload)
tampered[70] ^= 0x01
RNS.Transport.tunnel_synthesize_handler(bytes(tampered), StubPacket(hub_interface))
assert len(handled) == 1, "a tampered payload creates no tunnel"

public_key = identity.get_public_key()
tunnel_id = RNS.Identity.full_hash(public_key + FIXED_INTERFACE_HASH)
assert handled[0][0] == tunnel_id

tnl_snth_dst = RNS.Destination(None, RNS.Destination.OUT, RNS.Destination.PLAIN,
                               RNS.Transport.APP_NAME, "tunnel", "synthesize")

# Guards on the layout the brief states: 64 + 32 + 16 signed, + 64 signature.
assert len(payload) == 176
assert payload[:64] == public_key
assert payload[64:96] == FIXED_INTERFACE_HASH
assert payload[96:112] == FIXED_RANDOM_HASH
assert packet.destination_hash == tnl_snth_dst.hash
assert packet.packet_type == RNS.Packet.DATA
assert packet.header_type == RNS.Packet.HEADER_1
assert packet.transport_type == RNS.Transport.BROADCAST
assert packet.context == RNS.Packet.NONE

fixtures = {
    "identity_private_key": identity.get_private_key().hex(),
    "identity_public_key": public_key.hex(),
    "interface_name": INTERFACE_NAME,
    "interface_hash": FIXED_INTERFACE_HASH.hex(),
    "random_hash": FIXED_RANDOM_HASH.hex(),
    "tunnel_id": tunnel_id.hex(),
    "handler_tunnel_id": handled[0][0].hex(),
    "tunnel_synthesize_destination_hash": tnl_snth_dst.hash.hex(),
    "payload": payload.hex(),
    "raw": raw.hex(),
    "flags": raw[0],
    "hops": raw[1],
    "context": packet.context,
    "versions": {"rns": RNS.__version__},
}

print(json.dumps(fixtures, indent=2))
shutil.rmtree(workdir, ignore_errors=True)
