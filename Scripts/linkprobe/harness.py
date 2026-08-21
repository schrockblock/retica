#!/usr/bin/env python
"""Live interop harness: ReTiCA as link INITIATOR against genuine reference LXMF.

Topology, deliberately the same shape as a phone talking to a peer through a
transport node — so the link request is RELAYED and takes the HEADER_2 path with a
transport id, rather than the easier direct case:

    ReTiCA / prober  ->  rnsd hub (transport node, 127.0.0.1:4250)  ->  LXMF peer

Runtime state (configs, identities, storage) is written under /tmp so nothing
lands in the repo. The peer keeps a stable identity across runs, so the delivery
hash does not move between probes.

Usage — three terminals, in order:

    python Scripts/linkprobe/harness.py hub
    python Scripts/linkprobe/harness.py peer
    python Scripts/linkprobe/harness.py prober      # validates the HARNESS
    RETICA_LIVE_PROBE=1 swift test --no-parallel --filter LiveLinkProbe

Run `prober` before trusting any ReTiCA result: it is stock RNS doing the same
thing, so if IT cannot establish, the harness is broken and a ReTiCA failure
proves nothing. Expect RESULT=ESTABLISHED in well under a second on loopback.

Requires the reference environment (conda env `rns`): RNS 1.4.2, LXMF 1.1.0.
"""
import os
import subprocess
import sys
import time

RUNTIME = "/tmp/ReTiCA/linkprobe"
HUB_PORT = 4250
HASH_PATH = os.path.join(RUNTIME, "peer_hash.txt")

HUB_CONFIG = """[reticulum]
  enable_transport = True
  share_instance = No
  instance_name = probehub
  panic_on_interface_error = No

[logging]
  loglevel = 6

[interfaces]

  [[TCP Server]]
    type = TCPServerInterface
    interface_enabled = True
    listen_ip = 127.0.0.1
    listen_port = {port}
""".format(port=HUB_PORT)

CLIENT_CONFIG = """[reticulum]
  enable_transport = False
  share_instance = No
  instance_name = {name}
  panic_on_interface_error = No

[logging]
  loglevel = 6

[interfaces]

  [[Hub]]
    type = TCPClientInterface
    interface_enabled = True
    target_host = 127.0.0.1
    target_port = {port}
"""


def write_config(name, body):
    path = os.path.join(RUNTIME, f"{name}_config")
    os.makedirs(path, exist_ok=True)
    with open(os.path.join(path, "config"), "w") as handle:
        handle.write(body)
    return path


def run_hub():
    config = write_config("hub", HUB_CONFIG)
    print(f"hub: config at {config}, listening on 127.0.0.1:{HUB_PORT}")
    os.execvp("rnsd", ["rnsd", "--config", config, "-v"])


def run_peer():
    import RNS
    import LXMF

    config = write_config("peer", CLIENT_CONFIG.format(name="probepeer", port=HUB_PORT))
    storage = os.path.join(RUNTIME, "peer_storage")
    identity_path = os.path.join(RUNTIME, "peer_identity")
    os.makedirs(storage, exist_ok=True)

    RNS.Reticulum(config)

    if os.path.exists(identity_path):
        identity = RNS.Identity.from_file(identity_path)
    else:
        identity = RNS.Identity()
        identity.to_file(identity_path)

    # A real LXMRouter, so the delivery destination is set up exactly as a reference
    # client's is — including `enable_ratchets`, which LXMRouter applies to every
    # delivery destination (LXMRouter.py:357). Ratchet parity matters: it is one of
    # the differences a hand-rolled peer would silently omit.
    router = LXMF.LXMRouter(identity=identity, storagepath=storage)
    delivery = router.register_delivery_identity(identity, display_name="RefPeer")
    router.register_delivery_callback(
        lambda m: RNS.log(f"peer: MESSAGE content={m.content!r}", RNS.LOG_NOTICE)
    )

    with open(HASH_PATH, "w") as handle:
        handle.write(RNS.hexrep(delivery.hash, delimit=False))

    previous = delivery.callbacks.link_established

    def link_established(link):
        RNS.log(f"peer: INBOUND LINK ESTABLISHED {RNS.prettyhexrep(link.link_id)}", RNS.LOG_NOTICE)
        if previous:
            previous(link)

    delivery.set_link_established_callback(link_established)

    RNS.log(f"peer: delivery hash {RNS.prettyhexrep(delivery.hash)}", RNS.LOG_NOTICE)
    print(f"peer: delivery hash written to {HASH_PATH}")

    last = 0
    while True:
        if time.time() - last > 20:
            router.announce(delivery.hash)
            RNS.log("peer: announced", RNS.LOG_NOTICE)
            last = time.time()
        time.sleep(1)


def run_prober():
    import RNS

    config = write_config("prober", CLIENT_CONFIG.format(name="probeprober", port=HUB_PORT))
    with open(HASH_PATH) as handle:
        dest_hash = bytes.fromhex(handle.read().strip())

    RNS.Reticulum(config)
    RNS.log(f"prober: target {RNS.prettyhexrep(dest_hash)}", RNS.LOG_NOTICE)

    if not RNS.Transport.has_path(dest_hash):
        RNS.Transport.request_path(dest_hash)
    deadline = time.time() + 60
    while not RNS.Transport.has_path(dest_hash):
        if time.time() > deadline:
            RNS.log("prober: RESULT=NO_PATH (harness broken)", RNS.LOG_ERROR)
            sys.exit(2)
        time.sleep(0.5)

    RNS.log(f"prober: hops={RNS.Transport.hops_to(dest_hash)}", RNS.LOG_NOTICE)
    identity = RNS.Identity.recall(dest_hash)
    if identity is None:
        RNS.log("prober: RESULT=NO_IDENTITY (harness broken)", RNS.LOG_ERROR)
        sys.exit(2)

    destination = RNS.Destination(
        identity, RNS.Destination.OUT, RNS.Destination.SINGLE, "lxmf", "delivery"
    )
    done = {"ok": False}
    link = RNS.Link(destination)
    link.set_link_established_callback(
        lambda l: (RNS.log(f"prober: RESULT=ESTABLISHED rtt={l.rtt}", RNS.LOG_NOTICE),
                   done.__setitem__("ok", True))
    )

    deadline = time.time() + 20
    while not done["ok"]:
        if time.time() > deadline:
            RNS.log(f"prober: RESULT=TIMEOUT status={link.status}", RNS.LOG_ERROR)
            sys.exit(1)
        time.sleep(0.25)
    sys.exit(0)


COMMANDS = {"hub": run_hub, "peer": run_peer, "prober": run_prober}

if __name__ == "__main__":
    os.makedirs(RUNTIME, exist_ok=True)
    if len(sys.argv) != 2 or sys.argv[1] not in COMMANDS:
        print(f"usage: {sys.argv[0]} [{'|'.join(COMMANDS)}]", file=sys.stderr)
        sys.exit(64)
    COMMANDS[sys.argv[1]]()
