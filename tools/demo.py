#!/usr/bin/env python3
"""Stand-in backend for `plugboard --demo`: made-up plugins, nothing touched.

    demo.py state | check <id>... | apply '<ops json>'

Serves demo/fixture.json (public marketplace plugins plus Omarchy's own) so
the UI can be shown or screenshotted without anyone's real plugin list, and
fakes the uninstall check and the apply run.
"""
import json
import os
import sys
import time

FIXTURE = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "demo", "fixture.json")


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "state":
        time.sleep(0.3)
        with open(FIXTURE) as f:
            print(f.read())
    elif cmd == "check":
        out = {}
        for pid in argv[1:]:
            if pid == "matjam.omawall":
                out[pid] = {"kind": "git", "warning": "2 uncommitted local change(s) will be deleted", "note": ""}
            elif pid.startswith("local."):
                out[pid] = {"kind": "local", "warning": "", "note": "folder is moved to a .bak backup, not deleted"}
            else:
                out[pid] = {"kind": "git", "warning": "", "note": "deleted; its repo remains upstream"}
        time.sleep(0.6)
        print(json.dumps(out))
    elif cmd == "apply":
        ops = json.loads(argv[1])
        print(json.dumps({"status": "start", "total": len(ops)}), flush=True)
        for i, op in enumerate(ops):
            print(json.dumps({"i": i, "id": op["id"], "op": op["op"], "status": "running"}), flush=True)
            time.sleep(float(os.environ.get("PLUGBOARD_DEMO_STEP", "1.2")))
            print(json.dumps({"i": i, "id": op["id"], "op": op["op"], "status": "ok", "msg": ""}), flush=True)
        print(json.dumps({"status": "done", "ok": len(ops), "failed": 0, "shellReady": True}), flush=True)
    else:
        sys.exit("usage: demo.py state | check <id>... | apply '<ops json>'")


if __name__ == "__main__":
    main(sys.argv[1:])
