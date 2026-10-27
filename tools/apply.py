#!/usr/bin/env python3
"""Apply a queue of plugin changes, one after another, through Omarchy's own CLI.

    apply.py '[{"id": "...", "op": "put", "section": "right"}, ...]'

ops: enable, disable, put (onto a bar section), move (to a bar section),
remove (uninstall). Each change makes the shell rebuild the bar, so before
every step this waits for the shell to answer again. Prints one JSON line
per event for the UI and appends the same to ~/.local/state/plugstage/apply.log.
"""
import json
import os
import subprocess
import sys
import time

SHELL_JSON = os.path.expanduser("~/.config/omarchy/shell.json")
PLUGINS_DIR = os.path.expanduser("~/.config/omarchy/plugins")
LOG = os.path.expanduser("~/.local/state/plugstage/apply.log")
ORDER = {"disable": 0, "move": 1, "put": 2, "enable": 2, "remove": 3}
BUSY = ("not responding", "not running", "not ready")

os.makedirs(os.path.dirname(LOG), exist_ok=True)
log = open(LOG, "a")


def emit(**event):
    event["t"] = time.strftime("%Y-%m-%d %H:%M:%S")
    line = json.dumps(event)
    print(line, flush=True)
    log.write(line + "\n")
    log.flush()


def run(cmd):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=60)
    return p.returncode, (p.stdout + p.stderr).strip()


def wait_ready(limit=30):
    end = time.time() + limit
    while time.time() < end:
        rc, out = run(["omarchy-shell", "shell", "ping"])
        if rc == 0 and out == "ok":
            return True
        time.sleep(0.4)
    return False


def shell_cmd(cmd, attempts=3):
    rc, out = 1, ""
    for _ in range(attempts):
        wait_ready()
        rc, out = run(cmd)
        if rc == 0 or not any(b in out for b in BUSY):
            break
    return rc, out


def entry_id(entry):
    return entry if isinstance(entry, str) else str((entry or {}).get("id") or "")


def drop_from_hosts(pid):
    """Take a widget out of any host (the tray drawer) that nests it, keeping the host's order list in step."""
    with open(SHELL_JSON) as f:
        config = json.load(f)
    for section, entries in ((config.get("bar") or {}).get("layout") or {}).items():
        for entry in entries or []:
            if not isinstance(entry, dict) or not isinstance(entry.get("widgets"), list):
                continue
            widgets = entry["widgets"]
            kept = [w for w in widgets
                    if entry_id(w.get("entry") if isinstance(w, dict) and "entry" in w else w) != pid]
            if len(kept) == len(widgets):
                continue
            host = entry_id(entry)
            rc, out = shell_cmd(["omarchy", "bar", "set", host, "widgets", json.dumps(kept), "--json"])
            if rc != 0:
                return rc, out
            if isinstance(entry.get("order"), list) and pid in entry["order"]:
                order = [o for o in entry["order"] if o != pid]
                rc, out = shell_cmd(["omarchy", "bar", "set", host, "order", json.dumps(order), "--json"])
                if rc != 0:
                    return rc, out
            emit(id=pid, status="info", msg=f"taken out of {host}")
    return 0, ""


def placement(pid):
    with open(SHELL_JSON) as f:
        config = json.load(f)
    for section, entries in ((config.get("bar") or {}).get("layout") or {}).items():
        if any(entry_id(e) == pid for e in entries or []):
            return section
    return ""


def enabled(pid):
    rc, out = run(["omarchy", "plugin", "list", "--json"])
    if rc != 0:
        return None
    for p in json.loads(out):
        if p.get("id") == pid:
            return bool(p.get("enabled"))
    return None


def achieved(op):
    """Whether the system now says what was asked: "" if so, else what it says instead.

    The CLI can answer ok without changing anything (a clone original), or time
    out while the shell rebuilds and still have made the change, so the result
    is read back rather than taken from the exit code.
    """
    kind, pid = op["op"], op["id"]
    if kind in ("put", "move"):
        got = placement(pid)
        return "" if got == op["section"] else ("it is in " + got if got else "it is not on the bar")
    if kind == "disable":
        if op.get("barWidget") and placement(pid):
            return "it is still on the bar"
        return "it is still enabled" if enabled(pid) else ""
    if kind == "enable":
        return "" if enabled(pid) else "it is still off"
    if kind == "remove":
        return "its folder is still there" if os.path.lexists(os.path.join(PLUGINS_DIR, pid)) else ""
    return "unknown op"


def command(op):
    pid, kind = op["id"], op["op"]
    if kind == "enable":
        return ["omarchy", "plugin", "enable", pid]
    if kind == "disable":
        return ["omarchy", "plugin", "disable", pid]
    if kind == "put":
        # `bar put` also places a widget already in plugins[] with no bar
        # slot, where `plugin enable <id> <section>` silently does nothing.
        return ["omarchy", "bar", "put", pid, op["section"]]
    if kind == "move":
        return ["omarchy", "bar", "move", pid, op["section"]]
    return ["omarchy", "plugin", "remove", pid, "--yes"]


def step(op):
    if op["op"] == "remove":
        rc, out = drop_from_hosts(op["id"])
        if rc != 0:
            return rc, out
        # Clears its plugins[] entry too; `remove` only does that when the
        # registry reports it enabled, which a drawer widget never is.
        shell_cmd(["omarchy-shell", "shell", "setPluginEnabled", op["id"], "false"])
    rc, out = 1, ""
    for attempt in range(2):
        wait_ready()
        rc, out = run(command(op))
        busy = any(b in out for b in BUSY)
        if rc == 0 or busy:
            # Slow shell: give the rebuild time to land, then read back.
            wait_ready(60)
            problem = achieved(op)
            if not problem:
                return 0, out if rc == 0 else "done (the shell was slow to answer)"
            if not busy:
                return 1, "Omarchy answered ok but " + problem + (f" ({out})" if out else "")
            continue
        return rc, out
    return 1, out


def main():
    ops = sorted(json.loads(sys.argv[1]), key=lambda o: ORDER.get(o.get("op"), 9))
    emit(status="start", total=len(ops))
    ok = failed = 0
    for i, op in enumerate(ops):
        emit(i=i, id=op["id"], op=op["op"], section=op.get("section", ""), status="running")
        try:
            rc, out = step(op)
        except Exception as e:  # noqa: BLE001 - reported, then the queue carries on
            rc, out = 1, str(e)
        if rc == 0:
            ok += 1
        else:
            failed += 1
        emit(i=i, id=op["id"], op=op["op"], status="ok" if rc == 0 else "error", msg=out[-600:])
    ready = wait_ready()
    emit(status="done", ok=ok, failed=failed, shellReady=ready)


if __name__ == "__main__":
    main()
