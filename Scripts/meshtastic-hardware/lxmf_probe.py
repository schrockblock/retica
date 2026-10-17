#!/usr/bin/env python
"""LXMF probe for the Meshtastic hardware run (spec 2026-10-16 section 1 criterion 3, lane E).

Runs as a client of the Mac's shared rnsd instance (default config dir) or, with --config,
as its own Reticulum instance. Prints its LXMF address, announces it, prints every LXMF
delivery announce it hears (so the iPhone's address can be read off), prints every message
it receives, and with --send sends one message to a destination.

Run in the conda env `rns` with `python` (not python3):
  /Users/ell/opt/anaconda3/envs/rns/bin/python -u <path>/lxmf_probe.py --name "Mac probe"
"""
import argparse
import os
import sys
import time

import RNS
import LXMF


class DeliveryAnnounceLogger:
    aspect_filter = "lxmf.delivery"

    def received_announce(self, destination_hash, announced_identity, app_data):
        name = LXMF.display_name_from_app_data(app_data)
        print(f"[{time.strftime('%H:%M:%S')}] ANNOUNCE {RNS.hexrep(destination_hash, delimit=False)} name={name!r}",
              flush=True)


def load_identity(path):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    if os.path.isfile(path):
        return RNS.Identity.from_file(path)
    identity = RNS.Identity()
    identity.to_file(path)
    return identity


def send(router, source, args):
    destination_hash = bytes.fromhex(args.send)
    if not RNS.Transport.has_path(destination_hash):
        RNS.Transport.request_path(destination_hash)
        deadline = time.time() + args.path_timeout
        while not RNS.Transport.has_path(destination_hash) and time.time() < deadline:
            time.sleep(0.5)
    recipient_identity = RNS.Identity.recall(destination_hash)
    if recipient_identity is None:
        print(f"no path or identity for {args.send} after {args.path_timeout} s", flush=True)
        sys.exit(2)
    recipient = RNS.Destination(recipient_identity, RNS.Destination.OUT, RNS.Destination.SINGLE,
                                "lxmf", "delivery")
    method = LXMF.LXMessage.DIRECT if args.method == "direct" else LXMF.LXMessage.OPPORTUNISTIC
    message = LXMF.LXMessage(recipient, source, args.text, "hw probe", desired_method=method)
    started = time.time()
    message.register_delivery_callback(
        lambda m: print(f"DELIVERED after {time.time() - started:.1f} s", flush=True))
    message.register_failed_callback(
        lambda m: print(f"FAILED after {time.time() - started:.1f} s", flush=True))
    router.handle_outbound(message)
    print(f"queued {args.method} message to {args.send}", flush=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--config", default=None, help="Reticulum config dir (default: the shared instance)")
    parser.add_argument("--identity", default=os.path.expanduser("~/.reticulum-lxmf-probe/identity"))
    parser.add_argument("--name", default="ReTiCA hw probe")
    parser.add_argument("--send", metavar="DEST_HEX", help="LXMF delivery address to send one message to")
    parser.add_argument("--text", default="hello from the Mac over Meshtastic")
    parser.add_argument("--method", choices=["opportunistic", "direct"], default="opportunistic")
    parser.add_argument("--path-timeout", type=float, default=180.0)
    parser.add_argument("--announce-every", type=float, default=600.0)
    args = parser.parse_args()

    RNS.Reticulum(args.config)
    identity = load_identity(args.identity)
    # storagepath derives from --identity's directory, so separate identities don't share state.
    router = LXMF.LXMRouter(identity=identity, storagepath=os.path.join(os.path.dirname(args.identity), "lxmf"))
    source = router.register_delivery_identity(identity, display_name=args.name)

    def on_message(message):
        print(f"[{time.strftime('%H:%M:%S')}] RECEIVED from {RNS.hexrep(message.source_hash, delimit=False)} "
              f"method={message.method} signature_validated={message.signature_validated} "
              f"title={message.title_as_string()!r} content={message.content_as_string()!r}", flush=True)

    router.register_delivery_callback(on_message)
    RNS.Transport.register_announce_handler(DeliveryAnnounceLogger())
    print(f"LXMF address: {RNS.hexrep(source.hash, delimit=False)}", flush=True)
    router.announce(source.hash)
    if args.send:
        send(router, source, args)
    last_announce = time.time()
    while True:
        time.sleep(1)
        if time.time() - last_announce >= args.announce_every:
            router.announce(source.hash)
            last_announce = time.time()


if __name__ == "__main__":
    main()
