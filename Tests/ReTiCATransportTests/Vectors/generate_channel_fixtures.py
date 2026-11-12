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
#   receive_scenarios: a real RNS.Channel.Channel (stub outlet, MSGTYPE 0x0101 registered) with
#              _next_rx_sequence set to `start`, fed `sends` through _receive. Each case: {name, start,
#              sends, delivered (sequences, in handler order), delivered_by_send (what each send's
#              _receive delivered), next_after, ring_after (rx ring order)}.

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


class _ReceiveOutlet:
    """Channel.__init__ reads rtt (Channel.py:236); _receive builds Envelope(outlet=...) and never calls
    the outlet. mdu is set for completeness (rtt 0.05, mdu 431)."""
    rtt = 0.05
    mdu = 431


# (name, start _next_rx_sequence, sequences fed to _receive in order)
_RECEIVE_SCENARIOS = [
    ("in_order", 0, [0, 1, 2]),
    ("gap_then_fill", 0, [1, 2, 0]),
    ("duplicate", 0, [0, 0, 1]),
    ("out_of_window_ahead", 0, [49]),
    ("boundary_ahead", 0, [48]),
    ("behind", 10, [5]),
    ("wrap", 0xFFFE, [0xFFFE, 0xFFFF, 0, 1]),
    ("wrap_out_of_order", 0xFFFE, [0, 0xFFFF, 0xFFFE, 1]),
    ("behind_near_wrap", 2, [0xFFF0, 0xFFFF]),
    # Beyond the brief's list. wrap_restart ends on the send whose sweep needs the restart after
    # wrapping to 0 (Channel.py:383-387). wrap_reversed_tail: near the wrap, _emplace_envelope's
    # `(next - seq) > SEQ_MAX//2` clause (Channel.py:331) appends small wrapped sequences instead of
    # inserting them, so the ring holds [2, 1, 0, ...] and the single-pass sweep leaves 1 and 2 behind.
    # duplicate's repeat is refused by the window check (0 is already delivered); duplicate_pending
    # repeats a still-pending sequence, so only _emplace_envelope's duplicate check refuses it.
    ("duplicate_pending", 0, [2, 2, 0, 1]),
    ("wrap_restart", 0xFFFE, [0, 0xFFFF, 0xFFFE]),
    ("wrap_reversed_tail", 0xFFFE, [2, 1, 0, 0xFFFF, 0xFFFE, 3]),
]


def _receive_scenario(name, start, sends):
    channel = RNS.Channel.Channel(_ReceiveOutlet())
    channel.register_message_type(_RawMessage)
    delivered = []

    def handler(message):
        # The generator's payload is the 2-byte big-endian sequence, so the handler can recover it.
        delivered.append(int.from_bytes(message.payload, "big"))
        return True

    channel.add_message_handler(handler)
    channel._next_rx_sequence = start
    delivered_by_send = []
    for sequence in sends:
        raw = Envelope(_Outlet(), message=_RawMessage(sequence.to_bytes(2, "big")), sequence=sequence).pack()
        before = len(delivered)
        channel._receive(raw)
        delivered_by_send.append(delivered[before:])
    return {
        "name": name,
        "start": start,
        "sends": sends,
        "delivered": delivered,
        "delivered_by_send": delivered_by_send,
        "next_after": channel._next_rx_sequence,
        "ring_after": [e.sequence for e in channel._rx_ring],
    }


def section_receive_scenarios():
    # Genuine RNS.Channel.Channel._receive (Channel.py:351-394) and _emplace_envelope (322-341).
    return [_receive_scenario(name, start, sends) for name, start, sends in _RECEIVE_SCENARIOS]


def main():
    fixtures = {"envelopes": section_envelopes(), "receive_scenarios": section_receive_scenarios()}
    path = os.path.join(HERE, "channel_fixtures.json")
    with open(path, "w") as f:
        json.dump(fixtures, f, indent=2)
        f.write("\n")
    print("wrote", path)


if __name__ == "__main__":
    main()
