#!/usr/bin/env python3
"""A stand-in for the AppSandbox daemon, so that the forge PowerShell can RUN, not only be read.

==> tests/forge-api.bats STARTS IT. Do not run it by hand. <==

WHY THIS EXISTS. Most of the forge suite greps the scripts for strings: 64 assertions of the
form "this file contains this call". Those catch a changed verb, but not broken logic.
`dr-forge rollback` can discard the wrong branch, and each of them still passes. The scripts
reach AppSandbox only through about ten HTTP endpoints. Thus a server for those is enough to
really execute them.

WHAT IT RECORDS. It appends each authenticated request to the log as "METHOD /path". Thus a
test can assert the ORDER of the calls of a script: that `stop` asks `/shutdown` before
`/stop`, or that `rollback` deletes the old branch before it starts the new one. The API forces
that order, and a grep cannot see it.

WHAT IT MODELS, ON PURPOSE. The refusals that shape the callers:
  - a snapshot of a running VM is 409, as with the real daemon
  - `/shutdown` is a clean stop and `/stop` is the plug. A test can make the clean one do
    nothing (--ignore-shutdown), to exercise the grace period and the fallback
  - an unknown VM is 404, and a bad bearer token is 401

It is NOT a simulator. It has no timing, no state machine except running/stopped, and it does
not reproduce the snapshot bug. The callers are written for the behavior of the bug. The test
checks the caller, and does not act out the defect of the daemon.

    python3 tests/appsandbox_mock.py --port N --state FILE [--log FILE] [--ignore-shutdown]

The state file is JSON. The mock reads it at startup, and writes it again after each change,
so that a test can assert on it later:

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
        pass  # our own log is the real one. note() writes it

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
    # Matched longest first, by hand, not with a framework. Ten routes do not need a
    # dependency, and the exact shapes are the purpose of the file.
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
                    # A START CREATES A BRANCH. No other call does it. Thus rollback must
                    # discard the old branch before it can make a new one. This mock lets a
                    # test see that order.
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
                    # Clean stop. --ignore-shutdown accepts it and does nothing. Thus a test
                    # reaches the grace period, and the next action of the caller.
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
                # THE VM MUST BE STOPPED, and 409 is the answer of the real daemon. The caller
                # stops it first. This catches a caller that forgets.
                if v["running"]:
                    return self.reply(409, {"errorCode": "vm_running"})
                snaps = v.setdefault("snapshots", [])
                idx = max([s["index"] for s in snaps] + [-1]) + 1
                snaps.append({"index": idx, "name": body.get("name") or "snapshot",
                              "branchCount": 1,
                              "branches": [{"index": 0, "name": "Default Branch"}]})
                # A snapshot moves the VM to a new branch of it. A test on the real daemon
                # showed this. `rollback` is written for that state.
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
