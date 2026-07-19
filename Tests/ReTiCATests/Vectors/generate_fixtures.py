#!/usr/bin/env python3
# Run inside a Python environment with Reticulum (RNS) installed:
#   python3 generate_fixtures.py > fixtures.json
#
# Produces cross-validation vectors the Swift test suite loads to prove
# byte-for-byte wire compatibility with the reference implementation:
# Swift must decrypt these reference-generated tokens, validate the
# reference signature, and reproduce the identity hash exactly.
import json, os
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
}, indent=2))
