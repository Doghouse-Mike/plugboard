#!/usr/bin/env python3
"""Stand-in backend for `plugboard --demo`: made-up plugins, nothing touched.

    demo.py state | themes | backups | check <id>... | apply '<ops json>'

Serves demo/fixture.json (public marketplace plugins plus Omarchy's own) so
the UI can be shown or screenshotted without anyone's real plugin list, and
fakes the uninstall check and the apply run.
"""
import json
import os
import subprocess
import sys
import tempfile
import time

HERE = os.path.dirname(os.path.abspath(__file__))
FIXTURE = os.path.join(HERE, "..", "demo", "fixture.json")
# Omarchy's own themes, a few dressed up as installed ones so uninstalling shows.
DEMO_USER_THEMES = {"hackerman": "https://github.com/example/omarchy-hackerman-theme",
                    "lumon": "", "retro-82": "https://github.com/example/omarchy-retro-82-theme"}
DEMO_CURRENT = "tokyo-night"


def themes():
    with tempfile.TemporaryDirectory() as home:   # an empty home: built-ins only
        out = subprocess.run([sys.executable, "-I", os.path.join(HERE, "themes.py")], capture_output=True,
                             text=True, env={**os.environ, "HOME": home}).stdout
    data = json.loads(out)
    for t in data["themes"]:
        if t["name"] in DEMO_USER_THEMES:
            url = DEMO_USER_THEMES[t["name"]]
            t.update(user=True, builtin=False, source="git" if url else "local", url=url)
        t["current"] = t["name"] == DEMO_CURRENT
    data["current"] = DEMO_CURRENT
    return data


DEMO_BACKUPS = [
    {"kind": "theme", "name": "osaka-jade", "title": "Osaka Jade", "file": "osaka-jade-20261028-211502.tar.gz",
     "date": "2026-10-28 21:15", "size": 18234112, "installed": False},
    {"kind": "theme", "name": "lumon", "title": "Lumon", "file": "lumon-20261024-090311.tar.gz",
     "date": "2026-10-24 09:03", "size": 6512331, "installed": True},
    {"kind": "plugin", "name": "local.neon-meter", "title": "Neon Meter", "file": ".local.neon-meter.bak.20261026184502",
     "date": "2026-10-26 18:45", "size": 48211, "installed": False},
    {"kind": "plugin", "name": "local.pomodoro", "title": "Pomodoro", "file": ".local.pomodoro.bak.20261019120044",
     "date": "2026-10-19 12:00", "size": 23552, "installed": False},
]


def main(argv):
    cmd = argv[0] if argv else ""
    if cmd == "state":
        time.sleep(0.3)
        with open(FIXTURE) as f:
            print(f.read())
    elif cmd == "themes":
        print(json.dumps(themes()))
    elif cmd == "backups":
        print(json.dumps({"error": "", "backups": [dict(b, id="backup:%s:%s" % (b["kind"], b["file"])) for b in DEMO_BACKUPS]}))
    elif cmd == "check":
        out = {}
        for pid in argv[1:]:
            if pid.startswith("theme:"):
                local = not DEMO_USER_THEMES.get(pid[6:])
                out[pid] = {"kind": "local" if local else "git",
                            "warning": "not from a git repo, so this is the only copy" if local else "",
                            "note": "a backup goes in ~/.local/share/plugboard/theme-backups" + ("." if local else " anyway; its repo remains upstream.")}
            elif pid == "matjam.omawall":
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
        sys.exit("usage: demo.py state | themes | backups | check <id>... | apply '<ops json>'")


if __name__ == "__main__":
    main(sys.argv[1:])
