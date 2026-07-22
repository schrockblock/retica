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

# --- HDLC framing vectors (Interfaces sub-project) ---
from RNS.Interfaces.TCPInterface import HDLC

# HDLC framing of the deterministic PLAIN packet raw.
hdlc_framed = bytes([HDLC.FLAG]) + HDLC.escape(plain_packet_raw) + bytes([HDLC.FLAG])

# A payload containing FLAG (0x7E) and ESC (0x7D) bytes to exercise escaping across the boundary.
escape_input = bytes([0x00, HDLC.FLAG, 0x11, HDLC.ESC, 0x22]) + bytes([0xAB] * 20)
escape_framed = bytes([HDLC.FLAG]) + HDLC.escape(escape_input) + bytes([HDLC.FLAG])

# --- Link handshake vectors (base AES-256-CBC handshake, fixed-default MTU signalling) ---
from RNS.Cryptography import X25519PrivateKey, X25519PublicKey
from RNS.Cryptography import Token as LinkToken

# Genuine reference signalling bytes: fixed default MTU (500) + AES-256-CBC mode.
# RNS unconditionally appends these to link requests and proofs (see RNS/Link.py prove/handshake).
link_signalling = RNS.Link.signalling_bytes(RNS.Reticulum.MTU, RNS.Link.MODE_AES256_CBC)  # 3 bytes

link_dest = RNS.Identity()                 # the destination the link is made to (responder owns it)
link_init_eph = RNS.Identity()             # initiator ephemeral (X25519 ‖ Ed25519)
link_resp_eph = RNS.Identity()             # responder ephemeral

# Link request packet: HEADER_1 LINKREQUEST to the destination; data = initiator ephemeral
# public key (64) ‖ signalling (3) = 67 bytes, exactly as a real RNS initiator transmits.
link_dest_hash = RNS.Destination.hash(link_dest, "reticula", "link")
lr_flags = (0 << 6) | (0 << 5) | (0 << 4) | (RNS.Destination.SINGLE << 2) | RNS.Packet.LINKREQUEST  # 0x02
lr_data = link_init_eph.get_public_key() + link_signalling   # 67 bytes
link_request_raw = bytes([lr_flags, 0]) + link_dest_hash + bytes([0x00]) + lr_data

# link_id (RNS link_id_from_lr_packet): trailing bytes beyond ECPUBSIZE(64) are stripped
# from the hashable part before hashing.
lr_hashable = bytes([lr_flags & 0x0F]) + link_dest_hash + bytes([0x00]) + lr_data
if len(lr_data) > 64:
    lr_hashable = lr_hashable[:-(len(lr_data) - 64)]
link_id = RNS.Identity.truncated_hash(lr_hashable)

# session key: HKDF(64, ECDH(init x25519 priv, resp x25519 pub), salt=link_id)
init_x25519_priv = X25519PrivateKey.from_private_bytes(link_init_eph.get_private_key()[:32])
resp_x25519_pub = X25519PublicKey.from_public_bytes(link_resp_eph.get_public_key()[:32])
link_shared = init_x25519_priv.exchange(resp_x25519_pub)
link_derived_key = RNS.Cryptography.hkdf(length=64, derive_from=link_shared, salt=link_id, context=None)

# proof (RNS Link.prove): signed = link_id ‖ resp x25519 pub(32) ‖ dest identity ed25519 pub(32)
# ‖ signalling(3), signed by the destination identity; wire = signature(64) ‖ pub(32) ‖ signalling(3).
resp_x25519_pub_bytes = link_resp_eph.get_public_key()[:32]
dest_ed25519_pub = link_dest.get_public_key()[32:64]
link_proof_signed = link_id + resp_x25519_pub_bytes + dest_ed25519_pub + link_signalling
link_proof = link_dest.sign(link_proof_signed) + resp_x25519_pub_bytes + link_signalling

# link data over the session key
link_plaintext = b"secure link message"
link_ciphertext = LinkToken(link_derived_key).encrypt(link_plaintext)

# --- Link RTT packet (LRRTT) vector: msgpack(rtt) encrypted under the session key ---
import RNS.vendor.umsgpack as umsgpack
link_rtt = 0.125                                    # deterministic fixed RTT
link_rtt_msgpack = umsgpack.packb(link_rtt)         # genuine reference float64 encoding
link_rtt_packet_ciphertext = LinkToken(link_derived_key).encrypt(link_rtt_msgpack)

# --- Link close packet (LINKCLOSE) vector: encrypt(link_id) under the session key ---
link_close_ciphertext = LinkToken(link_derived_key).encrypt(link_id)

# --- Resource primitive vectors (single-segment, uncompressed; genuine RNS building blocks) ---
from RNS.Resource import ResourceAdvertisement as RNSResourceAdvertisement

res_data     = b"reticulum resource payload for cross validation"
res_r        = os.urandom(4)                       # resource random hash
res_prefix   = os.urandom(4)                       # 4-byte stream prefix
res_key      = os.urandom(64)                      # AES-256 Token key
res_sdu      = 32
res_stream   = LinkToken(res_key).encrypt(res_prefix + res_data)   # genuine Token (aliased LinkToken in this generator)
res_hash     = RNS.Identity.full_hash(res_data + res_r)         # genuine full_hash
res_parts    = [res_stream[i:i+res_sdu] for i in range(0, len(res_stream), res_sdu)]
res_map_hash0 = RNS.Identity.full_hash(res_parts[0] + res_r)[:4]
res_proof    = RNS.Identity.full_hash(res_data + res_hash)
res_hashmap  = b"".join(RNS.Identity.full_hash(p + res_r)[:4] for p in res_parts)

# Genuine RNS advertisement pack (construct empty, set fields, pack).
_adv = RNSResourceAdvertisement()
_adv.t = len(res_stream); _adv.d = len(res_data); _adv.n = len(res_parts)
_adv.h = res_hash; _adv.r = res_r; _adv.o = res_hash
_adv.i = 0; _adv.l = 1; _adv.q = None; _adv.f = 0x01; _adv.m = res_hashmap
res_adv_msgpack = _adv.pack(segment=0)

# --- Resource request plaintext (single-window, hashmap not exhausted): 0x00 ‖ hash ‖ hashmap ---
res_request_plaintext = bytes([0x00]) + res_hash + res_hashmap

# --- HMU msgpack payload: umsgpack.packb([chunk_index, hashmap_bytes]) ---
hmu_chunk_index = 1
hmu_hashmap = bytes([i % 256 for i in range(296)])   # 74 * 4 deterministic bytes
hmu_msgpack = umsgpack.packb([hmu_chunk_index, hmu_hashmap])

# --- Link IDENTIFY: RNS-produced payload for a fixed identity + link_id ---
identify_prv = bytes([(i * 7 + 3) % 256 for i in range(64)])
identify_identity = RNS.Identity.from_bytes(identify_prv)
identify_link_id = bytes([0xAB] * 16)
identify_pub = identify_identity.get_public_key()
identify_signature = identify_identity.sign(identify_link_id + identify_pub)
identify_payload = identify_pub + identify_signature

# --- path hash + msgpack request/response layouts ---
req_path = "svc/echo"
req_path_hash = RNS.Identity.truncated_hash(req_path.encode("utf-8"))
req_msgpack = umsgpack.packb([1.5, req_path_hash, b"ping"])
resp_msgpack = umsgpack.packb([bytes([0xCD] * 16), b"pong"])

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
    "hdlc_framed": hdlc_framed.hex(),
    "escape_input": escape_input.hex(),
    "escape_framed": escape_framed.hex(),
    "link_dest_identity_public": link_dest.get_public_key().hex(),
    "link_init_eph_private_key": link_init_eph.get_private_key().hex(),
    "link_resp_eph_public_key": link_resp_eph.get_public_key().hex(),
    "link_request_raw": link_request_raw.hex(),
    "link_id": link_id.hex(),
    "link_derived_key": link_derived_key.hex(),
    "link_proof": link_proof.hex(),
    "link_plaintext": link_plaintext.hex(),
    "link_ciphertext": link_ciphertext.hex(),
    "link_rtt": link_rtt,
    "link_rtt_msgpack": link_rtt_msgpack.hex(),
    "link_rtt_packet_ciphertext": link_rtt_packet_ciphertext.hex(),
    "link_close_ciphertext": link_close_ciphertext.hex(),
    "resource_data": res_data.hex(),
    "resource_random_hash": res_r.hex(),
    "resource_prefix": res_prefix.hex(),
    "resource_token_key": res_key.hex(),
    "resource_sdu": res_sdu,
    "resource_stream": res_stream.hex(),
    "resource_hash": res_hash.hex(),
    "resource_map_hash0": res_map_hash0.hex(),
    "resource_proof": res_proof.hex(),
    "resource_adv_msgpack": res_adv_msgpack.hex(),
    "resource_request_plaintext": res_request_plaintext.hex(),
    "hmu_msgpack": hmu_msgpack.hex(),
    "hmu_hashmap": hmu_hashmap.hex(),
    "identify_prv": identify_prv.hex(),
    "identify_link_id": identify_link_id.hex(),
    "identify_pub": identify_pub.hex(),
    "identify_payload": identify_payload.hex(),
    "req_path_hash": req_path_hash.hex(),
    "req_msgpack": req_msgpack.hex(),
    "resp_msgpack": resp_msgpack.hex(),
}, indent=2))
