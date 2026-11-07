#!/usr/bin/env python
"""Reference LXMF peer for LiveStampInteropTests. Those tests start and stop it themselves.

Needs a current reference stack, the conda env `rns-latest` (rns 1.6.0, lxmf 1.3.0).

By default it configures its router the way MeshChatX 4.10.7 does: an inbound stamp cost of 8, and
enforce_stamps(), which stock LXMF leaves off (identity_context.py:345-353). A sender's own view of
delivery proves nothing against this peer: it proves a packet before checking the stamp
(LXMRouter.py:2263), so the tests read received.log, which only gets what survived enforcement.
"""
import argparse
import os
import shutil
import time

ap = argparse.ArgumentParser()
ap.add_argument("--dir", required=True)
ap.add_argument("--listen", type=int, help="run a transport-enabled TCP server on this port")
ap.add_argument("--connect", type=int, help="connect to a TCP server on this port")
ap.add_argument("--cost", type=int, default=8)
ap.add_argument("--announce-every", type=float, default=0, help="0 = only answer path requests")
ap.add_argument("--network-stamps", action="store_true", help="[stamps] stamp_destinations = yes")
ap.add_argument("--reply", action="store_true", help="message the first delivery destination heard")
ap.add_argument("--propagation-node", action="store_true", help="also serve as a propagation node")
ap.add_argument("--sync-from", help="file holding a propagation node's address, to sync from")
args = ap.parse_args()

shutil.rmtree(args.dir, ignore_errors=True)
os.makedirs(args.dir)

stamps = ""
if args.network_stamps:
    # Low values keep generation fast. The value does not change the wire layout.
    stamps = "[stamps]\n  stamp_destinations = yes\n  destination_value = 12\n  destination_cost = 10\n"

if args.listen:
    interface = f"type = TCPServerInterface\n    listen_ip = 127.0.0.1\n    listen_port = {args.listen}"
else:
    interface = f"type = TCPClientInterface\n    target_host = 127.0.0.1\n    target_port = {args.connect}"

with open(os.path.join(args.dir, "config"), "w") as f:
    f.write(f"""[reticulum]
  enable_transport = {"yes" if args.listen else "no"}
  share_instance = no

{stamps}
[logging]
  loglevel = 5

[interfaces]
  [[TCP]]
    {interface}
    enabled = yes
""")

import RNS
import LXMF

RNS.Reticulum(args.dir)
identity = RNS.Identity()
# The lowest cost LXMF accepts from a node, so a debug build's search stays short.
router = LXMF.LXMRouter(identity=identity, storagepath=os.path.join(args.dir, "lxmf"), autopeer=False,
                        propagation_cost=LXMF.LXMRouter.PROPAGATION_COST_MIN, propagation_cost_flexibility=0)
source = router.register_delivery_identity(identity, display_name="Reference peer",
                                           stamp_cost=args.cost if args.cost > 0 else None)
if args.cost > 0:
    router.enforce_stamps()


def record(name, line):
    with open(os.path.join(args.dir, name), "a") as f:
        f.write(line + "\n")


def on_message(m):
    record("received.log", f"content={m.content_as_string()} method={m.method} signature={m.signature_validated} "
                           f"stamp_checked={m.stamp_checked} stamp_valid={m.stamp_valid}")


router.register_delivery_callback(on_message)
replied = set()


class Announces:
    aspect_filter = "lxmf.delivery"

    def received_announce(self, destination_hash, announced_identity, app_data):
        if args.reply and destination_hash not in replied and destination_hash != source.hash:
            replied.add(destination_hash)
            destination = RNS.Destination(announced_identity, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
            router.handle_outbound(LXMF.LXMessage(destination, source, "hello from the reference peer", "t",
                                                  desired_method=LXMF.LXMessage.OPPORTUNISTIC))


RNS.Transport.register_announce_handler(Announces())

if args.propagation_node:
    router.enable_propagation()
    record("pn_address", RNS.hexrep(router.propagation_destination.hash, delimit=False))

# Written last: the tests take this file as the signal that the peer is ready.
with open(os.path.join(args.dir, "address.tmp"), "w") as f:
    f.write(RNS.hexrep(source.hash, delimit=False))
os.replace(os.path.join(args.dir, "address.tmp"), os.path.join(args.dir, "address"))

sync_target = None
last_announce = 0
last_sync = 0
while True:
    time.sleep(0.5)
    now = time.time()
    if args.announce_every and now - last_announce >= args.announce_every:
        router.announce(source.hash)
        last_announce = now
    if args.sync_from and now - last_sync >= 5:
        last_sync = now
        if sync_target is None and os.path.exists(args.sync_from):
            with open(args.sync_from) as f:
                sync_target = bytes.fromhex(f.read().strip())
            router.set_outbound_propagation_node(sync_target)
        if sync_target is not None:
            if not RNS.Transport.has_path(sync_target):
                RNS.Transport.request_path(sync_target)
            elif router.propagation_transfer_state in (LXMF.LXMRouter.PR_IDLE, LXMF.LXMRouter.PR_COMPLETE):
                router.request_messages_from_propagation_node(identity)
