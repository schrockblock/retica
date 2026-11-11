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

import argparse
import os
import time

import RNS

parser = argparse.ArgumentParser()
parser.add_argument("--dir", required=True)
parser.add_argument("--listen", type=int, required=True)
args = parser.parse_args()

configdir = os.path.join(args.dir, "rns")
os.makedirs(configdir, exist_ok=True)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = yes\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 4\n\n"
            "[interfaces]\n  [[Tunnel Hub]]\n    type = TCPServerInterface\n    enabled = yes\n"
            "    listen_ip = 127.0.0.1\n    listen_port = %d\n" % args.listen)

RNS.Reticulum(configdir)

tunnels_path = os.path.join(args.dir, "tunnels")
while True:
    ids = [tunnel_id.hex() for tunnel_id in list(RNS.Transport.tunnels.keys())]
    tmp = tunnels_path + ".tmp"
    with open(tmp, "w") as f:
        f.write("\n".join(ids))
    os.replace(tmp, tunnels_path)
    time.sleep(0.2)
