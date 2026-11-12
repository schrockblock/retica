#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0) by absolute path, from anywhere:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python Tests/ReTiCATransportTests/Vectors/generate_channel_fixtures.py
# It writes channel_fixtures.json next to this file. One function per section; main() merges every
# section into the one JSON object. Later Channel/Buffer tasks append sections here.
#
# Sections:
#   envelopes: raw bytes of genuine RNS.Channel.Envelope.pack() (Channel.py:130-135), `>HHH` msgtype,
#              sequence, payload length, then the payload. Each case: {msgtype, sequence, payload_hex,
#              raw_hex}. Includes StreamDataMessage (msgtype 0xFF00) envelopes from RNS.Buffer.

import json
import os

import RNS
from RNS.Channel import Envelope, MessageBase
from RNS.Buffer import StreamDataMessage

HERE = os.path.dirname(os.path.abspath(__file__))


class _Outlet:
    """Envelope.pack() never touches the outlet; a stub is enough."""


class _RawMessage(MessageBase):
    MSGTYPE = 0x0101

    def __init__(self, payload=b""):
        super().__init__()
        self.payload = payload

    def pack(self):
        return self.payload

    def unpack(self, raw):
        self.payload = raw


def _envelope(message, sequence):
    raw = Envelope(_Outlet(), message=message, sequence=sequence).pack()
    return {
        "msgtype": message.MSGTYPE,
        "sequence": sequence,
        "payload_hex": message.pack().hex(),
        "raw_hex": raw.hex(),
    }


def section_envelopes():
    cases = []
    # link MDU 431 - 6 envelope bytes = 425
    for payload in (b"", b"\xa5", bytes(i % 251 for i in range(425))):
        cases.append(_envelope(_RawMessage(payload), 1))
    for sequence in (0, 1, 0x7FFF, 0xFFFF):
        cases.append(_envelope(_RawMessage(b"seq" + bytes([sequence & 0xFF])), sequence))
    for stream_id in (0, 0x3FFF):
        for eof in (False, True):
            cases.append(_envelope(StreamDataMessage(stream_id, b"stream-data", eof), 7))
    return cases


def main():
    fixtures = {"envelopes": section_envelopes()}
    path = os.path.join(HERE, "channel_fixtures.json")
    with open(path, "w") as f:
        json.dump(fixtures, f, indent=2)
        f.write("\n")
    print("wrote", path)


if __name__ == "__main__":
    main()
