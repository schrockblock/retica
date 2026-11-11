#!/usr/bin/env python3
# A reference RNS 1.6.0 transport hub for the gated live tunnel-synthesis test
# (Tests/ReTiCANodeTests/LiveTunnelSynthesisTests.swift). Run with the rns-latest python:
#
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python -u hub.py --dir <dir> --listen <port>
#
# It starts a genuine Reticulum instance with transport enabled and one TCPServerInterface, then
# writes the hex ids of Transport.tunnels to <dir>/tunnels every 200 ms. Nothing in RNS is patched:
# a tunnel id appears there only after the real tunnel_synthesize_handler validated a synthesis
# packet and handle_tunnel filed it.
#
# Startup failures end the process at once with a nonzero status and a line on stderr starting
# "HUB-FAILED", so the test can report them instead of waiting out its poll: a port already in use
# (checked before RNS starts, because RNS only logs a failed bind and carries on without the
# interface), and an interface that did not come up.

import argparse
import os
import socket
import sys
import time

import RNS

parser = argparse.ArgumentParser()
parser.add_argument("--dir", required=True)
parser.add_argument("--listen", type=int, required=True)
args = parser.parse_args()


def fail(message):
    print("HUB-FAILED " + message, file=sys.stderr, flush=True)
    sys.exit(2)


# SO_REUSEADDR, as RNS binds (TCPInterface.py:572): a port left in TIME_WAIT by an earlier run is
# not "in use", a port another process is bound to is.
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
    f.write("[reticulum]\n  enable_transport = yes\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 4\n\n"
            "[interfaces]\n  [[Tunnel Hub]]\n    type = TCPServerInterface\n    enabled = yes\n"
            "    listen_ip = 127.0.0.1\n    listen_port = %d\n" % args.listen)

RNS.Reticulum(configdir)

if not any(getattr(i, "name", None) == "Tunnel Hub" and getattr(i, "online", False)
           for i in RNS.Transport.interfaces):
    fail("the TCPServerInterface on port %d did not come up" % args.listen)

tunnels_path = os.path.join(args.dir, "tunnels")
while True:
    ids = [tunnel_id.hex() for tunnel_id in list(RNS.Transport.tunnels.keys())]
    tmp = tunnels_path + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(ids))
    os.replace(tmp, tunnels_path)
    time.sleep(0.2)
