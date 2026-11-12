#!/usr/bin/env python3
# A reference RNS 1.6.0 Channel and Buffer peer for the gated live test
# (Tests/ReTiCANodeTests/LiveChannelTests.swift). Run with the rns-latest python:
#
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python -u peer.py --dir <dir> --listen <port> \
#       --mode accept|initiate
#
# It starts a genuine Reticulum instance (no transport) with one TCPServerInterface on
# 127.0.0.1:<port> and the destination channelprobe.peer.
#
#   accept    announces every second until a link arrives, then serves it (below).
#   initiate  waits for an announce of channelprobe.retica, opens a link to it, serves it, and also
#             originates three echo-type messages b"from-ref-<n>" and 5000 bytes on stream 2, then EOF.
#
# Serving a link: on link_established it opens link.get_channel(), registers EchoMessage (MSGTYPE
# 0x0101), whose payload it sends back reversed, and creates the Buffer pair Buffer.create_
# bidirectional_buffer would (Buffer.py:368-372): RawChannelReader on stream 1, RawChannelWriter on
# stream 2. Bytes received on stream 1 are echoed on stream 2; EOF on stream 1 is echoed as EOF.
# The raw reader and writer are used without the io.Buffered* wrappers so a write the channel is not
# ready for (RawChannelWriter.write returns 0, Buffer.py:264-267) is retried here instead of raising
# BlockingIOError inside BufferedWriter. One sender thread does every channel send, in order.
#
# Forced retry: RNS.Packet.prove is wrapped so the FIRST CHANNEL-context packet this process receives
# is NOT proven (it is still handed to the channel, Link.py:1238-1242). The sender must resend it.
#
# Stdout carries only the milestone lines the test waits on:
#   READY <destination hash hex>     the interface is up and the destination registered
#   LINK <link id hex>               a link is established and its channel is open
#   SKIPPED_PROOF <packet hash hex>  the one unproven CHANNEL packet
#   GOT <msgtype hex4> <payload hex> an EchoMessage arrived (duplicates are not delivered by Channel)
#   STREAM_EOF <n>                   EOF on stream 1 after <n> bytes in total
#   SENT_ALL                         initiate mode: everything it originates was handed to the channel
#   CLOSED <link id hex> <reason>    the link closed
# RNS's own log goes to stderr (loglevel debug). Startup failures exit with status 2 and a line on
# stderr starting "PEER-FAILED", as Scripts/tunnelprobe/hub.py does.
#
# The process ends itself after --lifetime seconds, or as soon as its parent (the test) is gone, so
# a crashed or killed test run cannot leave it behind.

import argparse
import os
import queue
import socket
import sys
import threading
import time

import RNS
from RNS.Buffer import RawChannelReader, RawChannelWriter, StreamDataMessage
from RNS.Channel import CEType, ChannelException, MessageBase

parser = argparse.ArgumentParser()
parser.add_argument("--dir", required=True)
parser.add_argument("--listen", type=int, required=True)
parser.add_argument("--mode", choices=["accept", "initiate"], required=True)
parser.add_argument("--lifetime", type=float, default=240)
args = parser.parse_args()

ECHO_TYPE = 0x0101
RECEIVE_STREAM = 1
SEND_STREAM = 2
ORIGINATED_MESSAGES = [b"from-ref-%d" % n for n in range(3)]


def originated_stream():
    # 2500 bytes of text, which RawChannelWriter sends bz2-compressed, then 2500 LCG bytes, which do
    # not compress and go raw, so both chunk kinds cross the wire. LiveChannelTests builds the same.
    out = bytearray()
    line = 0
    while len(out) < 2500:
        out += b"from-ref stream line %04d\n" % line
        line += 1
    del out[2500:]
    x = 1
    while len(out) < 5000:
        x = (x * 1103515245 + 12345) & 0x7FFFFFFF
        out.append((x >> 16) & 0xFF)
    return bytes(out)


ORIGINATED_STREAM = originated_stream()

out_lock = threading.Lock()


def say(line):
    with out_lock:
        print(line, flush=True)


def fail(message):
    print("PEER-FAILED " + message, file=sys.stderr, flush=True)
    sys.exit(2)


def log_to_stderr(line):
    print(line, file=sys.stderr, flush=True)


# SO_REUSEADDR, as RNS binds (TCPInterface.py:572): a port left in TIME_WAIT is not "in use".
probe = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
probe.setsockopt(socket.SOL_SOCKET, socket.SO_REUSEADDR, 1)
try:
    probe.bind(("127.0.0.1", args.listen))
except OSError as e:
    fail("port %d is in use: %s" % (args.listen, e))
finally:
    probe.close()

configdir = os.path.join(args.dir, "rns")
os.makedirs(configdir, exist_ok=True)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[interfaces]\n  [[Channel Probe]]\n    type = TCPServerInterface\n    enabled = yes\n"
            "    listen_ip = 127.0.0.1\n    listen_port = %d\n" % args.listen)

# --- forced retry -------------------------------------------------------------------------------

original_prove = RNS.Packet.prove
skip_state = {"skipped": False}
skip_lock = threading.Lock()


def prove_skipping_first_channel_packet(self, destination=None):
    if self.context == RNS.Packet.CHANNEL:
        with skip_lock:
            skip = not skip_state["skipped"]
            skip_state["skipped"] = True
        if skip:
            say("SKIPPED_PROOF " + self.packet_hash.hex())
            return
    return original_prove(self, destination)


RNS.Packet.prove = prove_skipping_first_channel_packet

# --- the echo message ---------------------------------------------------------------------------


class EchoMessage(MessageBase):
    MSGTYPE = ECHO_TYPE

    def __init__(self, data=b""):
        self.data = data

    def pack(self):
        return self.data

    def unpack(self, raw):
        self.data = raw


# --- serving one link ---------------------------------------------------------------------------


class Session:
    def __init__(self, link, originate):
        self.link = link
        self.queue = queue.Queue()
        self.stream_lock = threading.Lock()
        self.received = 0
        self.eof_echoed = False

        self.channel = link.get_channel()
        self.channel.register_message_type(EchoMessage)
        # The pair create_bidirectional_buffer builds (Buffer.py:368-372). The reader registers its
        # handler first; it returns False for anything that is not stream data on its stream.
        self.reader = RawChannelReader(RECEIVE_STREAM, self.channel)
        self.reader.add_ready_callback(self.stream_ready)
        self.writer = RawChannelWriter(SEND_STREAM, self.channel)
        self.channel.add_message_handler(self.message_received)
        link.set_link_closed_callback(self.closed)

        if originate:
            for message in ORIGINATED_MESSAGES:
                self.queue.put(("message", message))
            self.queue.put(("stream", ORIGINATED_STREAM))
            self.queue.put(("eof", None))
            self.queue.put(("say", "SENT_ALL"))

        threading.Thread(target=self.sender, daemon=True).start()
        say("LINK " + link.link_id.hex())

    def message_received(self, message):
        if isinstance(message, EchoMessage):
            say("GOT %04x %s" % (EchoMessage.MSGTYPE, message.data.hex()))
            self.queue.put(("message", bytes(reversed(message.data))))
            return True
        return False

    def stream_ready(self, _ready_bytes):
        # One callback thread per delivered chunk (Buffer.py:159-161): the lock keeps read-and-queue
        # in buffer order across them.
        with self.stream_lock:
            while True:
                data = self.reader.read(65536)   # None: nothing buffered; b"": EOF and empty
                if not data:
                    break
                self.received += len(data)
                self.queue.put(("stream", bytes(data)))
            if self.reader._eof and not self.eof_echoed:
                with self.reader._lock:
                    drained = len(self.reader._buffer) == 0
                if drained:
                    self.eof_echoed = True
                    say("STREAM_EOF %d" % self.received)
                    self.queue.put(("eof", None))

    def active(self):
        return self.link.status == RNS.Link.ACTIVE

    def send_when_ready(self, build):
        while self.active():
            try:
                self.channel.send(build())
                return
            except ChannelException as e:
                if e.type != CEType.ME_LINK_NOT_READY:
                    raise
            time.sleep(0.01)

    def sender(self):
        while self.active():
            try:
                kind, value = self.queue.get(timeout=0.2)
            except queue.Empty:
                continue
            if kind == "message":
                self.send_when_ready(lambda: EchoMessage(value))
            elif kind == "stream":
                rest = value
                while rest and self.active():
                    consumed = self.writer.write(rest)
                    if consumed:
                        rest = rest[consumed:]
                    else:
                        time.sleep(0.01)
            elif kind == "eof":
                # What RawChannelWriter.close sends (Buffer.py:279-280: _eof, then write(b"")), retried
                # until the channel takes it rather than dropped when the window is full.
                self.send_when_ready(lambda: StreamDataMessage(SEND_STREAM, b"", True, False))
            elif kind == "say":
                say(value)

    def closed(self, link):
        say("CLOSED %s %s" % (link.link_id.hex(), link.teardown_reason))


sessions = []


def accept_link(link):
    sessions.append(Session(link, originate=False))


def initiated_link_established(link):
    sessions.append(Session(link, originate=True))


# --- start --------------------------------------------------------------------------------------

RNS.Reticulum(configdir, loglevel=RNS.LOG_DEBUG, logdest=log_to_stderr)

if not any(getattr(i, "name", None) == "Channel Probe" and getattr(i, "online", False)
           for i in RNS.Transport.interfaces):
    fail("the TCPServerInterface on port %d did not come up" % args.listen)

identity = RNS.Identity()
destination = RNS.Destination(identity, RNS.Destination.IN, RNS.Destination.SINGLE, "channelprobe", "peer")
destination.set_link_established_callback(accept_link)

link_requested = threading.Event()


class ReTiCAAnnounceHandler:
    aspect_filter = "channelprobe.retica"

    def received_announce(self, destination_hash, announced_identity, app_data):
        if link_requested.is_set():
            return
        link_requested.set()
        say("ANNOUNCE " + destination_hash.hex())
        remote = RNS.Destination(announced_identity, RNS.Destination.OUT, RNS.Destination.SINGLE,
                                 "channelprobe", "retica")
        RNS.Link(remote, established_callback=initiated_link_established)


if args.mode == "initiate":
    RNS.Transport.register_announce_handler(ReTiCAAnnounceHandler())

say("READY " + destination.hash.hex())

parent = os.getppid()
started = time.time()
next_announce = 0
while time.time() - started < args.lifetime and os.getppid() == parent:
    if args.mode == "accept" and not sessions and time.time() >= next_announce:
        destination.announce()
        next_announce = time.time() + 1
    time.sleep(0.1)
os._exit(0)
