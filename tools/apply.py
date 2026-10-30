#!/usr/bin/env python3
"""Apply a queue of plugin and theme changes, one after another, through Omarchy's own CLI.

    apply.py '[{"id": "...", "op": "put", "section": "right"}, ...]'

ops: enable, disable, put (onto a bar section), move (to a bar section),
remove (uninstall); theme-set (with "name", optionally "wallpaper"),
theme-wallpaper (with "name" and "wallpaper") and theme-remove (with "name"). Each plugin
change makes the shell rebuild the bar, so before
every step this waits for the shell to answer again. Prints one JSON line
per event for the UI and appends the same to ~/.local/state/plugboard/apply.log.
"""
import json
import os
import re
import subprocess
import sys
import tarfile
import time

SHELL_JSON = os.path.expanduser("~/.config/omarchy/shell.json")
PLUGINS_DIR = os.path.expanduser("~/.config/omarchy/plugins")
LOG = os.path.expanduser("~/.local/state/plugboard/apply.log")
THEMES_DIR = os.path.expanduser("~/.config/omarchy/themes")
THEME_BACKUPS = os.path.expanduser("~/.local/share/plugboard/theme-backups")
CURRENT_THEME = os.path.expanduser("~/.local/state/omarchy/current/theme.name")
STAGED_THEME = os.path.expanduser("~/.local/state/omarchy/current/theme")
CURRENT_BG = os.path.expanduser("~/.local/state/omarchy/current/background")
USER_BGS = os.path.expanduser("~/.config/omarchy/backgrounds")
# Switch before removing, so a batch can move off a theme and then delete it.
ORDER = {"disable": 0, "move": 1, "put": 2, "enable": 2, "remove": 3, "theme-set": 4, "theme-wallpaper": 4, "theme-remove": 5}
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
    env = {**os.environ, "OMARCHY_SHELL_IPC_TIMEOUT": "20s"}
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=90, env=env)
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


def json_arg(value):
    # `qs ipc` unpacks an argument that looks like a JSON array into separate
    # arguments; a leading space keeps it one string, and JSON.parse ignores it.
    # (`omarchy bar set` re-encodes with jq, dropping the space, hence the direct call.)
    return " " + json.dumps(value, separators=(",", ":"))


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
            rc, out = shell_cmd(["omarchy-shell", "shell", "setBarWidget", host, "widgets", json_arg(kept), "{}"])
            if rc != 0 or out != "ok":
                return rc, out
            if isinstance(entry.get("order"), list) and pid in entry["order"]:
                order = [o for o in entry["order"] if o != pid]
                rc, out = shell_cmd(["omarchy-shell", "shell", "setBarWidget", host, "order", json_arg(order), "{}"])
                if rc != 0 or out != "ok":
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


def current_theme():
    try:
        with open(CURRENT_THEME, encoding="utf-8") as f:
            return f.read().strip()
    except OSError:
        return ""


def set_wallpaper(name, wallpaper):
    """Point the background at one of the theme's wallpapers, as `omarchy theme
    bg set` would. `wallpaper` is {"name": file, "mine": bool}: the theme's own
    ones are used from the staged copy of the current theme (where Omarchy's
    own next-background cycling looks), yours from ~/.config/omarchy/backgrounds."""
    fname = str(wallpaper.get("name") or "")
    if not fname or "/" in fname or fname.startswith("."):
        return 1, "bad wallpaper name"
    base = os.path.join(USER_BGS, name) if wallpaper.get("mine") else os.path.join(STAGED_THEME, "backgrounds")
    path = os.path.join(base, fname)
    if not os.path.isfile(path):
        return 1, "wallpaper not found: " + fname
    rc, out = run(["omarchy", "theme", "bg", "set", path])
    try:
        got = os.path.basename(os.readlink(CURRENT_BG))
    except OSError:
        got = ""
    if got != fname:
        return 1, "the wallpaper is still " + (got or "unknown") + (f" ({out})" if out else "")
    return 0, ""


def theme_step(op):
    name = op.get("name", "")
    # The same rule `omarchy theme install` holds names to.
    if not re.match(r"^[A-Za-z0-9_][A-Za-z0-9._+-]*$", name):
        return 1, "bad theme name"
    if op["op"] in ("theme-set", "theme-wallpaper"):
        if op["op"] == "theme-set":
            rc, out = run(["omarchy", "theme", "set", name])
        if current_theme() != name:
            return 1, "the theme is still " + (current_theme() or "unknown") + (f" ({out})" if out else "")
        return set_wallpaper(name, op["wallpaper"]) if op.get("wallpaper") else (0, "")
    path = os.path.join(THEMES_DIR, name)
    if current_theme() == name:
        return 1, "it's the theme in use; switch to another one first"
    if not os.path.lexists(path):
        return 1, "not installed in ~/.config/omarchy/themes"
    # `omarchy theme remove` deletes the folder outright; keep a copy first.
    # A symlinked theme is someone's working copy elsewhere: only the link goes.
    backup = ""
    if not os.path.islink(path):
        os.makedirs(THEME_BACKUPS, exist_ok=True)
        backup = os.path.join(THEME_BACKUPS, "%s-%s.tar.gz" % (name, time.strftime("%Y%m%d-%H%M%S")))
        with tarfile.open(backup, "w:gz") as tar:
            tar.add(path, arcname=name)
        emit(id=op["id"], status="info", msg="backed up to " + backup.replace(os.path.expanduser("~"), "~"))
    rc, out = run(["omarchy", "theme", "remove", name])
    if os.path.lexists(path):
        return 1, "its folder is still there" + (f" ({out})" if out else "")
    return 0, ("backup: " + backup.replace(os.path.expanduser("~"), "~")) if backup else ""


def step(op):
    if op["op"] in ("theme-set", "theme-wallpaper", "theme-remove"):
        return theme_step(op)
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
