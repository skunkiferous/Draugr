#!/usr/bin/env python3
"""A stand-in for the AppSandbox daemon, so the forge's PowerShell can be RUN rather than read.

==> STARTED BY tests/forge-api.bats. Not meant to be run by hand. <==

WHY THIS EXISTS. Most of the forge suite greps the scripts for strings: 64 assertions of the
form "this file contains this call". Those catch a verb being changed but not logic being
broken - `dr-forge rollback` could discard the wrong branch and every one of them would still
pass. The scripts reach AppSandbox through about ten HTTP endpoints and nothing else, so a
server speaking those is enough to execute them for real.

WHAT IT RECORDS. Every authenticated request is appended to the log as "METHOD /path", which is
what lets a test assert the ORDER of calls a script made - that `stop` asks `/shutdown` before
`/stop`, or that `rollback` deletes the old branch before starting the new one. That ordering is
forced by the API and is exactly the kind of thing a grep cannot see.

WHAT IT DELIBERATELY MODELS. The refusals that shape the callers:
  - a snapshot of a running VM is 409, as the real daemon does
  - `/shutdown` is graceful and `/stop` is the plug, and a test can make the graceful one do
    nothing (--ignore-shutdown) to exercise the grace period and the fallback
  - an unknown VM is 404, and a bad bearer token is 401

It is NOT a simulator. It has no timing, no state machine beyond running/stopped, and it makes
no attempt to reproduce the snapshot bug - the callers are written for the bug's behaviour and
the test's job is to check the caller, not to re-enact the daemon's defect.

    python3 tests/appsandbox_mock.py --port N --state FILE [--log FILE] [--ignore-shutdown]

The state file is JSON, read at startup and rewritten after every mutation so a test can assert
on it afterwards:

    {"token": "...", "vms": {"test": {"running": false, "diskDirectory": "C:\\\\ForgeLayers",
     "ramMb": 8192, "snapshots": [], "current": {"snapIndex": -1, "branchIndex": -1}}}}
"""
import argparse
import json
import re
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer

ARGS = None
STATE = None
LOCK = threading.Lock()


def save():
    with open(ARGS.state, "w", encoding="utf-8") as fh:
        json.dump(STATE, fh, indent=2)


def note(method, path):
    if ARGS.log:
        with open(ARGS.log, "a", encoding="utf-8") as fh:
            fh.write("%s %s\n" % (method, path))


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    # --- plumbing ---------------------------------------------------------------------
    def reply(self, code, obj):
        body = json.dumps(obj).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def log_message(self, *a):
        pass  # the real log is ours, written by note()

    def authed(self):
        want = "Bearer " + STATE["token"]
        if self.headers.get("Authorization") != want:
            self.reply(401, {"errorCode": "unauthorized"})
            return False
        return True

    def vm(self, name):
        v = STATE["vms"].get(name)
        if v is None:
            self.reply(404, {"errorCode": "not_found"})
        return v

    # --- routing ----------------------------------------------------------------------
    # Matched longest-first by hand rather than with a framework: ten routes do not earn a
    # dependency, and the exact shapes are the point of the file.
    def do_GET(self):
        if not self.authed():
            return
        note("GET", self.path)
        with LOCK:
            if self.path == "/v1/version":
                return self.reply(200, {"version": "0.1.8-mock",
                                        "capabilities": {"snapshots": True, "templates": True}})
            if self.path == "/v1/vms":
                return self.reply(200, {"vms": [dict(name=k, running=v["running"])
                                                for k, v in STATE["vms"].items()]})
            m = re.match(r"^/v1/vms/([^/]+)/snapshots$", self.path)
            if m:
                v = self.vm(m.group(1))
                if v is None:
                    return
                return self.reply(200, {"snapshots": v.get("snapshots", []),
                                        "baseBranches": v.get("baseBranches", []),
                                        "current": v.get("current",
                                                         {"snapIndex": -1, "branchIndex": -1})})
            m = re.match(r"^/v1/vms/([^/]+)/sshInfo$", self.path)
            if m:
                v = self.vm(m.group(1))
                if v is None:
                    return
                return self.reply(200, {"port": v.get("sshPort", 57350),
                                        "user": v.get("user", "forge")})
            m = re.match(r"^/v1/vms/([^/]+)$", self.path)
            if m:
                v = self.vm(m.group(1))
                if v is None:
                    return
                out = dict(v)
                out.pop("snapshots", None)
                out["name"] = m.group(1)
                return self.reply(200, out)
            return self.reply(404, {"errorCode": "not_found"})

    def do_POST(self):
        if not self.authed():
            return
        note("POST", self.path)
        n = int(self.headers.get("Content-Length") or 0)
        try:
            body = json.loads(self.rfile.read(n) or b"{}")
        except ValueError:
            body = {}
        with LOCK:
            m = re.match(r"^/v1/vms/([^/]+)/(start|stop|shutdown|delete)$", self.path)
            if m:
                name, verb = m.group(1), m.group(2)
                v = self.vm(name)
                if v is None:
                    return
                if verb == "start":
                    # A BRANCH IS CREATED BY STARTING. There is no other call for it, which is
                    # what forces rollback to discard the old branch before it can make a new
                    # one - the ordering this mock exists to let a test observe.
                    if body.get("branchName") is not None:
                        si = int(body.get("snapIndex", -1))
                        snap = next((s for s in v.get("snapshots", []) if s["index"] == si), None)
                        if snap is None:
                            return self.reply(404, {"errorCode": "no_such_snapshot"})
                        bi = max([b["index"] for b in snap.get("branches", [])] + [-1]) + 1
                        snap.setdefault("branches", []).append(
                            {"index": bi, "name": body["branchName"]})
                        snap["branchCount"] = len(snap["branches"])
                        v["current"] = {"snapIndex": si, "branchIndex": bi}
                    v["running"] = True
                elif verb == "shutdown":
                    # Graceful. --ignore-shutdown accepts it and does nothing, which is how a
                    # test reaches the grace period and whatever the caller does after it.
                    if not ARGS.ignore_shutdown:
                        v["running"] = False
                elif verb == "stop":
                    v["running"] = False
                elif verb == "delete":
                    if v["running"]:
                        return self.reply(409, {"errorCode": "vm_running"})
                    del STATE["vms"][name]
                save()
                return self.reply(202, {"accepted": True})

            m = re.match(r"^/v1/vms/([^/]+)/snapshots$", self.path)
            if m:
                v = self.vm(m.group(1))
                if v is None:
                    return
                # THE VM MUST BE STOPPED, and 409 is the real daemon's answer. The caller stops
                # it first; this is what catches a caller that forgets to.
                if v["running"]:
                    return self.reply(409, {"errorCode": "vm_running"})
                snaps = v.setdefault("snapshots", [])
                idx = max([s["index"] for s in snaps] + [-1]) + 1
                snaps.append({"index": idx, "name": body.get("name") or "snapshot",
                              "branchCount": 1,
                              "branches": [{"index": 0, "name": "Default Branch"}]})
                # Taking a snapshot switches the VM onto a fresh branch of it - measured on the
                # real daemon, and the state `rollback` is written for.
                v["current"] = {"snapIndex": idx, "branchIndex": 0}
                save()
                return self.reply(202, {"accepted": True})
            return self.reply(404, {"errorCode": "not_found"})

    def do_DELETE(self):
        if not self.authed():
            return
        note("DELETE", self.path)
        with LOCK:
            m = re.match(r"^/v1/vms/([^/]+)/snapshots/(-?\d+)/branches/(\d+)$", self.path)
            if m:
                v = self.vm(m.group(1))
                if v is None:
                    return
                si, bi = int(m.group(2)), int(m.group(3))
                snap = next((s for s in v.get("snapshots", []) if s["index"] == si), None)
                if snap is None:
                    return self.reply(404, {"errorCode": "no_such_snapshot"})
                before = len(snap.get("branches", []))
                snap["branches"] = [b for b in snap.get("branches", []) if b["index"] != bi]
                if len(snap["branches"]) == before:
                    return self.reply(404, {"errorCode": "no_such_branch"})
                snap["branchCount"] = len(snap["branches"])
                save()
                return self.reply(200, {"deleted": True})
            return self.reply(404, {"errorCode": "not_found"})


def main():
    global ARGS, STATE
    p = argparse.ArgumentParser()
    p.add_argument("--port", type=int, required=True)
    p.add_argument("--state", required=True)
    p.add_argument("--log")
    p.add_argument("--ignore-shutdown", action="store_true")
    ARGS = p.parse_args()
    with open(ARGS.state, encoding="utf-8") as fh:
        STATE = json.load(fh)
    HTTPServer(("127.0.0.1", ARGS.port), Handler).serve_forever()


if __name__ == "__main__":
    main()
