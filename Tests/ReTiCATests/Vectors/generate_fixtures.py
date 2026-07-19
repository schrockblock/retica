#!/usr/bin/env python3
# Run inside a Python environment with Reticulum (RNS) installed.
# In the conda `rns` env, use `python` (NOT python3):
#   python generate_fixtures.py > fixtures.json
#
# Produces cross-validation vectors the Swift test suite loads to prove
# byte-for-byte wire compatibility with the reference implementation:
# Swift must decrypt these reference-generated tokens, validate the
# reference signature/announce, and reproduce identity/destination/packet
# hashes exactly.
import json, os, time
import RNS
from RNS.Cryptography import Token

identity = RNS.Identity()
priv = identity.get_private_key()
pub = identity.get_public_key()

sign_message = os.urandom(24)
signature = identity.sign(sign_message)

encrypt_plaintext = b"cross-validation payload"
encrypt_token = identity.encrypt(encrypt_plaintext)

token_key = os.urandom(64)  # AES-256 Token
token_plaintext = b"token vector"
token_ciphertext = Token(token_key).encrypt(token_plaintext)

# --- Packet + Destination vectors ---

# PLAIN packet (deterministic: PLAIN encryption is passthrough). OUT direction is
# headless-safe (register_destination only touches Transport.owner for IN destinations).
plain_app, plain_aspect = "reticula", "plain"
plain_dest = RNS.Destination(None, RNS.Destination.OUT, RNS.Destination.PLAIN, plain_app, plain_aspect)
plain_plaintext = b"plain packet payload"
plain_packet = RNS.Packet(plain_dest, plain_plaintext, RNS.Packet.DATA)
plain_packet.pack()
plain_packet_raw = plain_packet.raw
plain_packet_hash = plain_packet.get_hash()

# SINGLE destination hash for the fixture identity (static, headless-safe).
single_app, single_aspect = "reticula", "single"
single_dest_hash = RNS.Destination.hash(identity, single_app, single_aspect)

# Announce payload, built from authoritative statics (avoids creating an IN destination,
# which would require a running Transport). Mirrors Destination.announce exactly.
ann_app, ann_aspect = "reticula", "announce"
ann_name_hash = RNS.Identity.full_hash(
    RNS.Destination.expand_name(None, ann_app, ann_aspect).encode("utf-8")
)[:RNS.Identity.NAME_HASH_LENGTH // 8]
ann_random_hash = RNS.Identity.get_random_hash()[:5] + int(time.time()).to_bytes(5, "big")
ann_dest_hash = RNS.Destination.hash(identity, ann_app, ann_aspect)
ann_ratchet = b""
ann_signed = ann_dest_hash + identity.get_public_key() + ann_name_hash + ann_random_hash + ann_ratchet
ann_signature = identity.sign(ann_signed)
ann_payload = identity.get_public_key() + ann_name_hash + ann_random_hash + ann_ratchet + ann_signature

print(json.dumps({
    "identity_private_key": priv.hex(),
    "identity_public_key": pub.hex(),
    "identity_hash": identity.hash.hex(),
    "sign_message": sign_message.hex(),
    "signature": signature.hex(),
    "encrypt_plaintext": encrypt_plaintext.hex(),
    "encrypt_token": encrypt_token.hex(),
    "token_key": token_key.hex(),
    "token_plaintext": token_plaintext.hex(),
    "token_ciphertext": token_ciphertext.hex(),
    "plain_app_name": plain_app,
    "plain_aspect": plain_aspect,
    "plain_dest_hash": plain_dest.hash.hex(),
    "plain_packet_plaintext": plain_plaintext.hex(),
    "plain_packet_raw": plain_packet_raw.hex(),
    "plain_packet_hash": plain_packet_hash.hex(),
    "single_app_name": single_app,
    "single_aspect": single_aspect,
    "single_dest_hash": single_dest_hash.hex(),
    "announce_app_name": ann_app,
    "announce_aspect": ann_aspect,
    "announce_dest_hash": ann_dest_hash.hex(),
    "announce_payload": ann_payload.hex(),
    "announce_context_flag": False,
}, indent=2))
