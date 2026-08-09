#!/usr/bin/env python
"""
Cross-validation fixture for ReTiCA's IFAC.

Every value below is produced by GENUINE RNS code paths -- nothing is transcribed or
hand-computed:
  * key derivation mirrors Reticulum.py:958-972 by CALLING RNS.Identity.full_hash,
    RNS.Cryptography.hkdf and RNS.Identity.from_bytes;
  * the wire bytes come from calling the real RNS.Transport.transmit() against a stub
    interface that captures process_outgoing() -- the masking loop is NOT reimplemented here.

Emits two fixtures:
  1. netname-only ("retica-xval"), ifac_size=16, over a fixed 48-byte packet -> wire bytes.
  2. dual-credential ("alpha" + "beta") derived key, which pins the CONCATENATION ORDER of
     full_hash(netname) || full_hash(netkey). Also prints the order-swapped derivation to
     prove the two are distinct (i.e. that the fixture actually constrains the order).

Run in the conda `rns` env (RNS 1.4.2) from this directory:
  python generate_ifac_fixtures.py

Committed values in IFACCrossValidationTests.swift must match the output of this script
byte-for-byte. If any value disagrees, STOP -- do not adjust either side until the
discrepancy is understood.
"""
import sys

try:
    import RNS
    import RNS.Cryptography
    from RNS.Identity import Identity
    from RNS.Transport import Transport
except ImportError as e:
    print("BLOCKED: RNS import failed:", e, file=sys.stderr)
    sys.exit(1)

print("rns_version=" + RNS.__version__)

IFAC_SALT = bytes.fromhex("adf54d882c9a9b80771eb4995d702d4a3e733391b2a0f53f416d9f907e55cff8")


def derive_key(netname=None, netkey=None, swap_order=False):
    """Mirror Reticulum.py:958-969 by calling the real RNS primitives."""
    name_hash = Identity.full_hash(netname.encode("utf-8")) if netname is not None else b""
    key_hash = Identity.full_hash(netkey.encode("utf-8")) if netkey is not None else b""

    # Reference order is full_hash(netname) then full_hash(netkey) (Reticulum.py:961-966).
    ifac_origin = (key_hash + name_hash) if swap_order else (name_hash + key_hash)

    ifac_origin_hash = Identity.full_hash(ifac_origin)
    return RNS.Cryptography.hkdf(
        length=64, derive_from=ifac_origin_hash, salt=IFAC_SALT, context=None
    )


class StubInterface:
    """Minimal duck-typed interface: Transport.transmit only needs these attrs plus
    process_outgoing. Nothing about the masking lives here."""

    def __init__(self, ifac_key, ifac_size):
        self.ifac_key = ifac_key
        self.ifac_size = ifac_size
        self.ifac_identity = Identity.from_bytes(ifac_key)
        self.captured = None

    def process_outgoing(self, data):
        self.captured = data


# ---- Fixture 1: netname-only, real Transport.transmit -------------------------
IFAC_SIZE = 16
key1 = derive_key(netname="retica-xval", netkey=None)

iface = StubInterface(key1, IFAC_SIZE)
if iface.ifac_identity is None:
    print("BLOCKED: Identity.from_bytes returned None", file=sys.stderr)
    sys.exit(1)

raw = bytes([0x00, 0x00]) + bytes(range(46))  # 48 bytes total

# THE REAL THING: this performs the masking inside RNS, not here.
Transport.transmit(iface, raw)

# Transport.transmit swallows exceptions and only logs them, so an empty capture means the
# call failed rather than produced empty output. Fail loudly instead of emitting a bad fixture.
if iface.captured is None:
    print("BLOCKED: Transport.transmit did not call process_outgoing", file=sys.stderr)
    sys.exit(1)
if len(iface.captured) != len(raw) + IFAC_SIZE:
    print("BLOCKED: unexpected wire length %d" % len(iface.captured), file=sys.stderr)
    sys.exit(1)

print("ifac_key_hex=" + key1.hex())
print("wire_hex=" + iface.captured.hex())

# ---- Fixture 2: dual-credential derived key, pinning concatenation order ------
key_both = derive_key(netname="alpha", netkey="beta")
key_swapped = derive_key(netname="alpha", netkey="beta", swap_order=True)

print("alpha_beta_key_hex=" + key_both.hex())
print("alpha_beta_swapped_hex=" + key_swapped.hex())
print("order_matters=" + str(key_both != key_swapped))

# Also emit the dual-credential WIRE via real Transport.transmit. Asserting on this exercises
# ReTiCA's own derivation end-to-end (rather than a test-side recomputation of hkdf), so an
# order-swapped Swift implementation cannot pass it.
iface2 = StubInterface(key_both, IFAC_SIZE)
raw2 = bytes([0x00, 0x00]) + bytes(range(30))  # 32 bytes total
Transport.transmit(iface2, raw2)
if iface2.captured is None or len(iface2.captured) != len(raw2) + IFAC_SIZE:
    print("BLOCKED: dual-credential transmit failed", file=sys.stderr)
    sys.exit(1)
print("alpha_beta_wire_hex=" + iface2.captured.hex())
