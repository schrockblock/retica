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
ap.add_argument("--destination-value", type=float, default=12,
                help="with --network-stamps, the value of our own announce stamp. A receiver reads our link "
                     "cost only from a stamp of 23.5 or more; 24 takes Python about half a minute to mine")
ap.add_argument("--enforce-network", action="store_true",
                help="[stamps] enforce_stamps = yes: drop link requests, announces and path requests "
                     "whose network stamp falls short")
ap.add_argument("--destination-cost", type=float,
                help="[stamps] destination_cost: the stamp value an announce must carry to be accepted here. "
                     "Default 10 with --network-stamps, otherwise the reference default of 23.5")
ap.add_argument("--link-cost", type=float,
                help="announce this link-request cost instead of LXMF's 3.25. A random key meets 3.25 about "
                     "one time in ten, too often for a test of refusal; 12 is one in 4,096")
ap.add_argument("--reply", action="store_true", help="message the first delivery destination heard")
ap.add_argument("--propagation-node", action="store_true", help="also serve as a propagation node")
ap.add_argument("--sync-from", help="file holding a propagation node's address, to sync from")
ap.add_argument("--enforce-ratchets", action="store_true",
                help="LXMRouter(enforce_ratchets=True): our delivery destination drops anything not encrypted "
                     "to one of its ratchets (Destination.py:600-607, Identity.py decrypt)")
ap.add_argument("--identity", help="load our identity from this private-key file (RNS.Identity.from_file), so a "
                                   "test knows our address before we start")
args = ap.parse_args()

shutil.rmtree(args.dir, ignore_errors=True)
os.makedirs(args.dir)

# One [stamps] section, whichever flags fill it.
stamp_options = []
if args.network_stamps:
    # Low values keep generation fast. The value does not change the wire layout.
    stamp_options += ["stamp_destinations = yes", f"destination_value = {args.destination_value}"]
destination_cost = args.destination_cost if args.destination_cost is not None else (10 if args.network_stamps else None)
if destination_cost is not None:
    stamp_options.append(f"destination_cost = {destination_cost}")
if args.enforce_network:
    stamp_options.append("enforce_stamps = yes")
stamps = "[stamps]\n" + "".join(f"  {o}\n" for o in stamp_options) if stamp_options else ""

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
# The config must have taken: a test that expects refusals proves nothing against a lenient peer.
assert RNS.Transport.LR_STAMPS_ENFORCED == args.enforce_network
# Path requests (and announces) are enforced by this one, at ingress (Transport.py:2128-2129).
assert RNS.Transport.STAMPS_ENFORCED == args.enforce_network
if destination_cost is not None:
    assert RNS.Transport.DESTINATION_COST == destination_cost
identity = RNS.Identity.from_file(args.identity) if args.identity else RNS.Identity()
assert identity is not None, "the identity file did not load"
# The lowest cost LXMF accepts from a node, so a debug build's search stays short.
router = LXMF.LXMRouter(identity=identity, storagepath=os.path.join(args.dir, "lxmf"), autopeer=False,
                        propagation_cost=LXMF.LXMRouter.PROPAGATION_COST_MIN, propagation_cost_flexibility=0,
                        enforce_ratchets=args.enforce_ratchets)
source = router.register_delivery_identity(identity, display_name="Reference peer",
                                           stamp_cost=args.cost if args.cost > 0 else None)
# Reference enables ratchets on every delivery destination (LXMRouter.py:423) and enforces them only on
# request (LXMRouter.py:428-429). A test of enforcement proves nothing if it did not take.
assert source.ratchets is not None
assert source._Destination__enforce_ratchets == args.enforce_ratchets
if args.cost > 0:
    router.enforce_stamps()
if args.link_cost is not None:
    # register_delivery_identity sets DELIVERY_LINK_COST once (LXMRouter.py:422); this replaces it.
    source.set_link_cost(args.link_cost)


def record(name, line):
    with open(os.path.join(args.dir, name), "a") as f:
        f.write(line + "\n")


def hex_or_none(b):
    return RNS.hexrep(b, delimit=False) if b else "None"


def on_message(m):
    # ratchet_id is the id of the ratchet that decrypted the message, or None when the identity key did
    # (Identity.py decrypt sets it on the destination; LXMRouter.py:2173 and :2861 copy it here).
    record("received.log", f"content={m.content_as_string()} method={m.method} signature={m.signature_validated} "
                           f"stamp_checked={m.stamp_checked} stamp_valid={m.stamp_valid} "
                           f"ratchet_id={hex_or_none(m.ratchet_id)}")


router.register_delivery_callback(on_message)
replied = set()
# Our replies, until each is logged to sent.log once it has gone out.
outbound = []


class Announces:
    aspect_filter = "lxmf.delivery"

    def received_announce(self, destination_hash, announced_identity, app_data):
        if args.reply and destination_hash not in replied and destination_hash != source.hash:
            replied.add(destination_hash)
            destination = RNS.Destination(announced_identity, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery")
            message = LXMF.LXMessage(destination, source, "hello from the reference peer", "t",
                                     desired_method=LXMF.LXMessage.OPPORTUNISTIC)
            outbound.append((destination_hash, message))
            router.handle_outbound(message)


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
    for entry in list(outbound):
        destination_hash, message = entry
        if message.state in (LXMF.LXMessage.SENT, LXMF.LXMessage.DELIVERED):
            # The id of the ratchet the packet was encrypted to, None for the identity key
            # (LXMessage.py:478 from Packet.py:220, set by Destination.py:705-708).
            record("sent.log", f"to={RNS.hexrep(destination_hash, delimit=False)} ratchet_id={hex_or_none(message.ratchet_id)}")
            outbound.remove(entry)
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
