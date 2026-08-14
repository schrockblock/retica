"""Model LXMRouter.py:1525-1547 EXACTLY as written, to determine reference's real
effective behaviour per input class.

Reference (verified by reading the installed LXMF 1.1.0 source):

    client_transfer_limit = None
    if len(data) >= 3:
        try:
            client_transfer_limit = float(data[2])*1000
        except: pass
    ...
    if client_transfer_limit != None and next_size > client_transfer_limit: pass
    else: <serve this message>

There is NO int() conversion anywhere. The cap stays a float.
"""

PER_MESSAGE_OVERHEAD = 16


def reference_serves(wire_value, lxm_size=1000):
    """Returns True if reference would SERVE a message of lxm_size under this wire cap."""
    client_transfer_limit = None
    try:
        client_transfer_limit = float(wire_value) * 1000
    except Exception:
        pass  # bare `except: pass` -> stays None -> unlimited

    next_size = 0 + (lxm_size + PER_MESSAGE_OVERHEAD)
    if client_transfer_limit is not None and next_size > client_transfer_limit:
        return False  # `pass` -> skipped
    return True       # `else` -> appended


cases = [
    ("NaN",                   float('nan')),
    ("+inf",                  float('inf')),
    ("-inf",                  float('-inf')),
    ("large finite positive", 1e300),
    ("overflows to +inf",     1e308),
    ("large finite negative", -1e18),
    ("-1 (negative int)",     -1),
    ("-0.0",                  -0.0),
    ("0",                     0),
    ("500.0 (legit, fits)",   500.0),
    ("0.5 (legit, too small)", 0.5),
]

print(f"{'input':24} {'cap (float)':>16}   reference serves a 1000-byte message?")
print("-" * 78)
for name, v in cases:
    try:
        cap = float(v) * 1000
    except Exception:
        cap = None
    served = reference_serves(v)
    print(f"{name:24} {str(cap):>16}   {'YES (unlimited-ish)' if served else 'NO  (serves nothing)'}")

print()
print("Key NaN fact -- every comparison against NaN is False:")
print("  1016 > nan  =", 1016 > float('nan'), " -> the `pass` is NOT taken -> message IS served")
print("  1016 > inf  =", 1016 > float('inf'), " -> the `pass` is NOT taken -> message IS served")
print("  1016 > -inf =", 1016 > float('-inf'), " -> the `pass` IS taken -> skipped")
