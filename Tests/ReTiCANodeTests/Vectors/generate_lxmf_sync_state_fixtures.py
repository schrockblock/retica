#!/usr/bin/env python3
# Run in the conda `rns-latest` env (rns 1.6.0, lxmf 1.3.0) by absolute path:
#   /Users/ell/opt/anaconda3/envs/rns-latest/bin/python generate_lxmf_sync_state_fixtures.py > lxmf_sync_state_fixtures.json
#
# The client side of a propagation node sync, against a real LXMRouter: which
# `propagation_transfer_state` (LXMRouter.py:78-91) each PN response leaves it in, whether it tears
# the link down, what it requests next, and what `clean_links` (:1096-1106, through
# `acknowledge_sync_completion`, :1874-1883) does to that state when the link then closes.
#
# Driven for real: `request_messages_from_propagation_node` (:579-621), `message_list_response`
# (:1780-1823), `message_get_response` (:1825-1862), `message_get_failed` (:1869-1872),
# `clean_links` (:1056-1106) and `__request_messages_path_job` (:1683-1692).
#
# Stubs (network edges only):
#  - `FakeLink` stands in for `outbound_propagation_link`: a settable `status`, and it records
#    `teardown()` and every `request(path, data, ...)` with its callbacks. `identify()` is a no-op.
#  - `FakeReceipt` stands in for the RNS RequestReceipt handed to the response callbacks: `.response`
#    and `.link`.
#  - `RNS.Transport.has_path` answers per case; `RNS.Transport.request_path` records nothing and
#    sends nothing.
#  - For the establishing case only: `RNS.Link` is replaced by a factory returning a `FakeLink` in
#    PENDING (the real class's status constants are kept), and `RNS.Identity.recall` returns a fresh
#    identity for the PN.
#  - For the path-timeout case only: `request_messages_path_job` (which starts a thread) is a no-op,
#    and the private `__request_messages_path_job` is then called directly with its deadline already
#    passed, so the no-path branch runs without sleeping.
#
# Responses are given as Python values and recorded as their msgpack encoding, which is how a
# request response travels on the link. The follow-up request is recorded the same way.

import json
import os
import shutil
import tempfile
import time

import RNS
import RNS.vendor.umsgpack as msgpack
import LXMF
from LXMF.LXMRouter import LXMRouter
from LXMF.LXMPeer import LXMPeer

workdir = tempfile.mkdtemp(prefix="retica-sync-state-fixtures-")
configdir = os.path.join(workdir, "rns")
os.makedirs(configdir)
with open(os.path.join(configdir, "config"), "w") as f:
    f.write("[reticulum]\n  enable_transport = no\n  share_instance = no\n\n"
            "[logging]\n  loglevel = 1\n\n[interfaces]\n")
RNS.Reticulum(configdir)
RNS.loglevel = RNS.LOG_NONE     # reference logs to stdout, which is the JSON

RealLink = RNS.Link
real_has_path, real_request_path, real_recall = RNS.Transport.has_path, RNS.Transport.request_path, RNS.Identity.recall

PN_HASH = RNS.Identity.full_hash(b"retica-sync-state-pn")[:16]
OFFERED_ID = RNS.Identity.full_hash(b"retica-sync-state-offered")
# Long enough for lxmf_propagation's LXMF_OVERHEAD check; addressed to nobody we know, so it is
# only marked processed, never delivered.
BLOB = b"\x11" * 16 + b"\x22" * 200


class FakeLink:
    def __init__(self, status):
        self.status = status
        self.teardowns = 0
        self.requests = []

    def teardown(self): self.teardowns += 1
    def identify(self, identity): pass
    def request(self, path, data=None, response_callback=None, failed_callback=None, progress_callback=None,
                timeout=None):
        self.requests.append({"path": path, "data": data, "response": response_callback, "failed": failed_callback})


class FakeReceipt:
    def __init__(self, response, link):
        self.response = response
        self.link = link


def new_router(name):
    r = LXMRouter(identity=RNS.Identity(), storagepath=os.path.join(workdir, name))
    r.outbound_propagation_node = PN_HASH
    return r


def packed_hex(value):
    return msgpack.packb(value).hex()


def close_and_clean(r, link):
    link.status = RealLink.CLOSED
    r.clean_links()


def snapshot(r):
    return r.propagation_transfer_state, r.propagation_transfer_last_result


def response_case(name, phase, response):
    """phase: 'list' answers the list request; 'get' answers the wanted-messages request."""
    r = new_router(name)
    link = FakeLink(RealLink.ACTIVE)
    r.outbound_propagation_link = link
    r.request_messages_from_propagation_node(RNS.Identity())
    assert r.propagation_transfer_state == LXMRouter.PR_REQUEST_SENT
    assert link.requests[-1]["data"] == [None, None]
    if phase == "get":
        # Reach the get phase the real way: an offer of one id we do not have.
        r.message_list_response(FakeReceipt([OFFERED_ID], link))
        assert len(link.requests) == 2 and link.requests[-1]["response"] == r.message_get_response
    state_before, result_before = snapshot(r)
    requests_before = len(link.requests)
    callback = r.message_list_response if phase == "list" else r.message_get_response
    callback(FakeReceipt(response, link))
    state_after, result_after = snapshot(r)
    follow_ups = link.requests[requests_before:]
    assert len(follow_ups) <= 1
    teardown = link.teardowns > 0
    close_and_clean(r, link)
    state_close, result_close = snapshot(r)
    return {"name": name, "phase": phase, "response": packed_hex(response),
            "state_before_response": state_before, "last_result_before_response": result_before,
            "state_after_response": state_after, "last_result_after_response": result_after,
            "teardown": teardown,
            "follow_up": packed_hex(follow_ups[0]["data"]) if follow_ups else None,
            "state_after_close": state_close, "last_result_after_close": result_close}


def request_failed_case():
    """The list request fails (timeout): message_get_failed tears down; the close decides the state."""
    r = new_router("request-failed")
    link = FakeLink(RealLink.ACTIVE)
    r.outbound_propagation_link = link
    r.request_messages_from_propagation_node(RNS.Identity())
    failed = link.requests[-1]["failed"]
    assert failed == r.message_get_failed
    state_before, _ = snapshot(r)
    failed(FakeReceipt(None, link))
    state_after, _ = snapshot(r)
    teardown = link.teardowns > 0
    close_and_clean(r, link)
    return {"state_before": state_before, "state_after_failure": state_after, "teardown": teardown,
            "state_after_close": snapshot(r)[0], "last_result_after_close": snapshot(r)[1]}


def establishing_close_case():
    """A sync with a path but no link: LINK_ESTABLISHING; the link closes before it is established."""
    r = new_router("establishing")
    created = []

    class LinkFactory:
        ACTIVE, CLOSED, PENDING = RealLink.ACTIVE, RealLink.CLOSED, RealLink.PENDING
        def __new__(cls, destination, established_callback=None):
            link = FakeLink(RealLink.PENDING)
            created.append(link)
            return link

    RNS.Transport.has_path = lambda h: True
    RNS.Identity.recall = lambda h, *a, **k: RNS.Identity()
    RNS.Link = LinkFactory
    try:
        r.request_messages_from_propagation_node(RNS.Identity())
    finally:
        RNS.Link = RealLink
        RNS.Transport.has_path = real_has_path
        RNS.Identity.recall = real_recall
    assert len(created) == 1 and r.outbound_propagation_link is created[0]
    state_before, _ = snapshot(r)
    close_and_clean(r, created[0])
    return {"state_before_close": state_before, "state_after_close": snapshot(r)[0],
            "last_result_after_close": snapshot(r)[1]}


def path_timeout_case():
    """No path: PATH_REQUESTED, and the path job's deadline passes with no path: NO_PATH."""
    r = new_router("path-timeout")
    RNS.Transport.has_path = lambda h: False
    RNS.Transport.request_path = lambda *a, **k: None
    r.request_messages_path_job = lambda: None
    try:
        r.request_messages_from_propagation_node(RNS.Identity())
        state_before, _ = snapshot(r)
        r.wants_download_on_path_available_timeout = time.time() - 1
        r._LXMRouter__request_messages_path_job()
    finally:
        RNS.Transport.has_path = real_has_path
        RNS.Transport.request_path = real_request_path
    return {"state_before_deadline": state_before, "state_after_deadline": snapshot(r)[0],
            "last_result_after_deadline": snapshot(r)[1]}


def next_request_case():
    """A sticky failure (NO_ACCESS) is overwritten by the next sync request over an active link."""
    r = new_router("next-request")
    link = FakeLink(RealLink.ACTIVE)
    r.outbound_propagation_link = link
    r.request_messages_from_propagation_node(RNS.Identity())
    r.message_list_response(FakeReceipt(LXMPeer.ERROR_NO_ACCESS, link))
    close_and_clean(r, link)
    sticky = snapshot(r)[0]
    link2 = FakeLink(RealLink.ACTIVE)
    r.outbound_propagation_link = link2
    r.request_messages_from_propagation_node(RNS.Identity())
    return {"sticky_state": sticky, "state_after_next_request": snapshot(r)[0]}


cases = [
    response_case("list-no-identity", "list", LXMPeer.ERROR_NO_IDENTITY),
    response_case("list-no-access", "list", LXMPeer.ERROR_NO_ACCESS),
    response_case("list-empty", "list", []),
    response_case("list-one-id", "list", [OFFERED_ID]),
    response_case("list-none", "list", None),
    response_case("list-invalid-key", "list", LXMPeer.ERROR_INVALID_KEY),
    response_case("get-no-identity", "get", LXMPeer.ERROR_NO_IDENTITY),
    response_case("get-no-access", "get", LXMPeer.ERROR_NO_ACCESS),
    response_case("get-one-blob", "get", [BLOB]),
    response_case("get-empty", "get", []),
]

fixtures = {
    "constants": {
        "error_no_identity": LXMPeer.ERROR_NO_IDENTITY, "error_no_access": LXMPeer.ERROR_NO_ACCESS,
        "error_invalid_key": LXMPeer.ERROR_INVALID_KEY, "error_invalid_data": LXMPeer.ERROR_INVALID_DATA,
        "error_throttled": LXMPeer.ERROR_THROTTLED,
        "pr_idle": LXMRouter.PR_IDLE, "pr_path_requested": LXMRouter.PR_PATH_REQUESTED,
        "pr_link_establishing": LXMRouter.PR_LINK_ESTABLISHING,
        "pr_link_established": LXMRouter.PR_LINK_ESTABLISHED, "pr_request_sent": LXMRouter.PR_REQUEST_SENT,
        "pr_receiving": LXMRouter.PR_RECEIVING, "pr_response_received": LXMRouter.PR_RESPONSE_RECEIVED,
        "pr_complete": LXMRouter.PR_COMPLETE, "pr_no_path": LXMRouter.PR_NO_PATH,
        "pr_link_failed": LXMRouter.PR_LINK_FAILED, "pr_transfer_failed": LXMRouter.PR_TRANSFER_FAILED,
        "pr_no_identity_rcvd": LXMRouter.PR_NO_IDENTITY_RCVD, "pr_no_access": LXMRouter.PR_NO_ACCESS,
        "pr_failed": LXMRouter.PR_FAILED,
    },
    "offered_id": OFFERED_ID.hex(),
    "blob": BLOB.hex(),
    "cases": cases,
    "request_failed": request_failed_case(),
    "establishing_close": establishing_close_case(),
    "path_timeout": path_timeout_case(),
    "next_request": next_request_case(),
    "versions": {"rns": RNS.__version__, "lxmf": LXMF.__version__},
}

# Guards on the generator: these only prove anything if reference really behaves this way.
by_name = {c["name"]: c for c in cases}
assert by_name["list-no-access"]["state_after_response"] == 0xF4 and by_name["list-no-access"]["teardown"]
assert by_name["list-no-access"]["state_after_close"] == 0xF4                 # sticky
assert by_name["list-no-identity"]["state_after_close"] == 0xF3
assert by_name["list-empty"]["state_after_response"] == 0x07 and by_name["list-empty"]["last_result_after_response"] == 0
assert by_name["list-empty"]["state_after_close"] == 0x00 and by_name["list-empty"]["last_result_after_close"] is None
assert by_name["list-one-id"]["follow_up"] is not None and not by_name["list-one-id"]["teardown"]
assert by_name["list-one-id"]["state_after_close"] == 0xF2
assert by_name["list-none"]["teardown"] and by_name["list-none"]["state_after_response"] == 0x04
assert by_name["list-invalid-key"]["teardown"] and by_name["list-invalid-key"]["state_after_close"] == 0xF2
assert by_name["get-one-blob"]["last_result_after_response"] == 1 and by_name["get-one-blob"]["follow_up"] is not None
assert by_name["get-empty"]["follow_up"] is None and by_name["get-empty"]["state_after_response"] == 0x07
assert fixtures["request_failed"]["teardown"] and fixtures["request_failed"]["state_after_close"] == 0xF2
assert fixtures["establishing_close"]["state_before_close"] == 0x02 and fixtures["establishing_close"]["state_after_close"] == 0xF1
assert fixtures["path_timeout"]["state_before_deadline"] == 0x01 and fixtures["path_timeout"]["state_after_deadline"] == 0xF0
assert fixtures["next_request"]["sticky_state"] == 0xF4 and fixtures["next_request"]["state_after_next_request"] == 0x04

print(json.dumps(fixtures, indent=2))
shutil.rmtree(workdir, ignore_errors=True)
