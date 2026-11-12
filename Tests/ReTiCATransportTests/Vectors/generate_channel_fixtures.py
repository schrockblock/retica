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
#   window_scenarios: a real Channel (stub outlet, settable rtt) driven through D (delivered) and T
#              (timed out) events; the six window fields after __init__ and after every event.
#   timeouts:  _get_packet_timeout_time for tries 1..5 x rtt {0, 0.01, 0.5} x tx ring length {0, 3}.

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


class _TxPacket:
    """Stands in for a Packet; the stub outlet identifies it by `packet_id`."""

    def __init__(self, packet_id):
        self.packet_id = packet_id


class _TxOutlet:
    """The outlet surface _packet_tx_op (Channel.py:417-444) and _packet_timeout (459-493) touch.
    rtt is settable per event. Packet state is always SENT, so _packet_timeout never returns early
    and never takes its already-delivered path. resend and the callback setters are no-ops."""

    def __init__(self, rtt):
        self.rtt = rtt

    def get_packet_id(self, packet):
        return packet.packet_id

    def get_packet_state(self, packet):
        return RNS.Channel.MessageState.MSGSTATE_SENT

    def resend(self, packet):
        pass

    def set_packet_delivered_callback(self, packet, callback):
        pass

    def set_packet_timeout_callback(self, packet, callback, timeout=None):
        pass

    def timed_out(self):
        raise AssertionError("no scenario should exhaust its tries")


def _window_state(channel):
    return {
        "window": channel.window,
        "window_max": channel.window_max,
        "window_min": channel.window_min,
        "window_flexibility": channel.window_flexibility,
        "fast_rate_rounds": channel.fast_rate_rounds,
        "medium_rate_rounds": channel.medium_rate_rounds,
    }


# (name, rtt at Channel construction, events). Each event is ("D" | "T", rtt during the event).
_WINDOW_SCENARIOS = [
    ("slow_link_init", 2.0, []),
    ("grow_to_slow_max", 0.5, [("D", 0.5)] * 6),
    ("promote_medium", 0.5, [("D", 0.5)] * 12),
    ("promote_fast", 0.1, [("D", 0.1)] * 12),
    ("fast_then_slow_resets", 0.1, [("D", 0.1)] * 5 + [("D", 0.5)] * 3),
    ("shrink", 0.1, [("D", 0.1)] * 12 + [("T", 0.1)] * 20),
    # Beyond the brief's list. In `shrink` the T events change nothing: fast promotion raises
    # window_min to 16 while window is only 7, so `window > window_min` (Channel.py:474) is false.
    # These two reach the shrink branch: window and window_max both step down until window hits
    # window_min, after which T changes nothing.
    ("shrink_after_medium", 0.5, [("D", 0.5)] * 12 + [("T", 0.5)] * 5),
    ("shrink_after_fast", 0.1, [("D", 0.1)] * 30 + [("T", 0.1)] * 20),
    # Alternating T and D keeps window above window_min while window_max falls, so the
    # `window_max > window_min + window_flexibility` guard (Channel.py:476) is what stops window_max
    # at 9 (medium: 5 + 4) while window keeps shrinking.
    ("shrink_max_floor", 0.5, [("D", 0.5)] * 12 + [("T", 0.5), ("D", 0.5)] * 5),
    # A slow link: window 1 never grows (1 < window_max 1 is false), rtt > RTT_MEDIUM resets both
    # round counters, and T never shrinks below window_min 1.
    ("slow_link_traffic", 2.0, [("D", 2.0)] * 3 + [("T", 2.0)] * 2),
    # rtt 0 skips rate tracking entirely (Channel.py:428) but still grows the window.
    ("rtt_zero_skips_rate_tracking", 0, [("D", 0)] * 3),
    # The comparisons are strict: rtt exactly RTT_SLOW is not slow at init, exactly RTT_FAST counts
    # as fast, exactly RTT_MEDIUM counts as medium.
    ("rtt_boundaries", 1.45, [("D", 0.18)] * 2 + [("D", 0.75)] * 2 + [("D", 0.7500001)]),
]


def _window_scenario(name, init_rtt, events):
    outlet = _TxOutlet(init_rtt)
    channel = RNS.Channel.Channel(outlet)
    initial = _window_state(channel)
    states = []
    for index, (op, rtt) in enumerate(events):
        outlet.rtt = rtt
        envelope = Envelope(outlet, message=_RawMessage(b"x"), sequence=index)
        envelope.packet = _TxPacket(index)
        channel._tx_ring.append(envelope)
        if op == "D":
            # Genuine _packet_delivered -> _packet_tx_op: removes the envelope, then the window part.
            channel._packet_delivered(envelope.packet)
            assert envelope not in channel._tx_ring
        else:
            # Genuine _packet_timeout with a fresh envelope (tries 0 < max_tries 5): the shrink branch
            # (Channel.py:474-477), then a no-op resend. The envelope is removed afterwards so every T
            # event starts from the same ring length and never reaches the teardown branch.
            channel._packet_timeout(envelope.packet)
            assert envelope.tries == 1
            channel._tx_ring.remove(envelope)
        states.append(_window_state(channel))
    return {
        "name": name,
        "init_rtt": init_rtt,
        "events": [{"op": op, "rtt": rtt} for op, rtt in events],
        "initial": initial,
        "states": states,
    }


def section_window_scenarios():
    # Genuine RNS.Channel.Channel.__init__ (Channel.py:236-245), _packet_tx_op (417-444) via
    # _packet_delivered, and _packet_timeout (459-493). Nothing is hand-rolled. Each case: {name,
    # init_rtt, events [{op, rtt}], initial (state after __init__), states (state after each event)}.
    return [_window_scenario(*scenario) for scenario in _WINDOW_SCENARIOS]


def section_timeouts():
    # Genuine _get_packet_timeout_time (Channel.py:455-457) on a real Channel whose _tx_ring holds
    # `ring` envelopes. Each case: {tries, rtt, ring, timeout}.
    cases = []
    for tries in range(1, 6):
        for rtt in (0, 0.01, 0.5):
            for ring in (0, 3):
                outlet = _TxOutlet(rtt)
                channel = RNS.Channel.Channel(outlet)
                for sequence in range(ring):
                    channel._tx_ring.append(Envelope(outlet, message=_RawMessage(b"x"), sequence=sequence))
                cases.append({"tries": tries, "rtt": rtt, "ring": ring,
                              "timeout": channel._get_packet_timeout_time(tries)})
    return cases


def main():
    fixtures = {
        "envelopes": section_envelopes(),
        "receive_scenarios": section_receive_scenarios(),
        "window_scenarios": section_window_scenarios(),
        "timeouts": section_timeouts(),
    }
    path = os.path.join(HERE, "channel_fixtures.json")
    with open(path, "w") as f:
        json.dump(fixtures, f, indent=2)
        f.write("\n")
    print("wrote", path)


if __name__ == "__main__":
    main()
