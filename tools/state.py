#!/usr/bin/env python3
"""Print one JSON snapshot of every Omarchy shell plugin and where it lives.

Read-only. Combines `omarchy plugin list --json` (what the shell has
discovered) with ~/.config/omarchy/shell.json (where each widget is placed)
and each plugin folder (manifest details, git state).

Placement is read from the layout rather than from `enabled`, because a
widget in the tray drawer reads as disabled to the plugin registry.
"""
import json
import os
import subprocess
import sys
import time

HOME = os.path.expanduser("~")
USER_DIR = os.path.join(HOME, ".config/omarchy/plugins")
FIRST_PARTY_DIR = "/usr/share/omarchy/shell/plugins"
SHELL_JSON = os.path.join(HOME, ".config/omarchy/shell.json")
SECTIONS = ("left", "center", "right")


def run(cmd, timeout=20):
    p = subprocess.run(cmd, capture_output=True, text=True, timeout=timeout)
    return p.returncode, p.stdout, p.stderr


def plugin_list():
    # The shell answers slowly (or not at all) while it rebuilds the bar.
    last = ""
    for _ in range(20):
        rc, out, err = run(["omarchy", "plugin", "list", "--json"])
        if rc == 0:
            try:
                return json.loads(out)
            except ValueError:
                last = "unparseable plugin list"
        else:
            last = (err or out).strip()
        time.sleep(0.5)
    raise RuntimeError(last or "omarchy plugin list failed")


def entry_id(entry):
    if isinstance(entry, str):
        return entry
    if isinstance(entry, dict):
        return str(entry.get("id") or "")
    return ""


def layout_placement(config):
    """Map id -> section, id -> host id (for widgets nested in a host like the tray)."""
    placed, nested = {}, {}
    layout = (config.get("bar") or {}).get("layout") or {}
    for section in SECTIONS:
        for entry in layout.get(section) or []:
            host = entry_id(entry)
            if host:
                placed[host] = section
            widgets = entry.get("widgets") if isinstance(entry, dict) else None
            for w in widgets if isinstance(widgets, list) else []:
                wid = entry_id(w.get("entry") if isinstance(w, dict) and "entry" in w else w)
                if wid:
                    nested[wid] = host
    return placed, nested


def manifests():
    out = {}
    for base, first in ((FIRST_PARTY_DIR, True), (USER_DIR, False)):
        try:
            names = sorted(os.listdir(base))
        except OSError:
            continue
        for name in names:
            path = os.path.join(base, name)
            try:
                with open(os.path.join(path, "manifest.json")) as f:
                    m = json.load(f)
            except (OSError, ValueError):
                continue
            pid = str(m.get("id") or name)
            out.setdefault(pid, {"manifest": m, "dir": path, "firstPartyDir": first})
    return out


def git_state(path):
    """Classify a user plugin folder the way `omarchy plugin remove` treats it."""
    if os.path.islink(path):
        return {"source": "symlink", "target": os.path.realpath(path), "risk": ""}
    if not os.path.isdir(os.path.join(path, ".git")):
        return {"source": "local", "risk": ""}
    info = {"source": "git", "risk": ""}
    rc, url, _ = run(["git", "-C", path, "remote", "get-url", "origin"])
    info["url"] = url.strip() if rc == 0 else ""
    rc, branch, _ = run(["git", "-C", path, "symbolic-ref", "--quiet", "--short", "HEAD"])
    info["branch"] = branch.strip() if rc == 0 else ""
    # Offline hints only; `removal-check.py` fetches before anything is deleted.
    # (Remote-tracking refs here are stale: updates fetch FETCH_HEAD only.)
    rc, dirty, _ = run(["git", "-C", path, "status", "--porcelain", "--untracked-files=normal"])
    if rc == 0 and dirty.strip():
        info["risk"] = "uncommitted local changes"
    return info


def main():
    try:
        listed = plugin_list()
    except Exception as e:  # noqa: BLE001 - surfaced to the UI as text
        print(json.dumps({"error": str(e), "plugins": []}))
        return 0
    try:
        with open(SHELL_JSON) as f:
            config = json.load(f)
    except (OSError, ValueError):
        config = {}
    placed, nested = layout_placement(config)
    loaded = {entry_id(p) for p in config.get("plugins") or []}
    mans = manifests()

    plugins = []
    for p in listed:
        pid = str(p.get("id") or "")
        kinds = [str(k) for k in p.get("kinds") or []]
        found = mans.get(pid, {})
        m = found.get("manifest") or {}
        first = bool(p.get("firstParty"))
        bw = m.get("barWidget") if isinstance(m.get("barWidget"), dict) else {}
        row = {
            "id": pid,
            "name": str(p.get("name") or bw.get("displayName") or m.get("name") or pid),
            "description": str(bw.get("description") or m.get("description") or ""),
            "version": str(m.get("version") or ""),
            "author": str(m.get("author") or ""),
            "kinds": kinds,
            "firstParty": first,
            "enabled": bool(p.get("enabled")),
            "canDisable": p.get("canDisable") is not False,
            "isBarWidget": "bar-widget" in kinds,
            "isBar": "bar" in kinds,
            "section": placed.get(pid, ""),
            "host": nested.get(pid, ""),
            "hostLoaded": True,
            "source": "first-party" if first else "local",
            "risk": "",
            "clonedFrom": str(p.get("clonedFrom") or ""),
            "replacedBy": "",
        }
        if row["host"] and not first:
            # A third-party widget hosted in the drawer only loads while it is
            # listed in plugins[]; without that its drawer icon does nothing.
            row["hostLoaded"] = pid in loaded
        if not first and found.get("dir"):
            row.update(git_state(found["dir"]))
        plugins.append(row)

    # A first-party plugin with an enabled clone is stood in for by it: the
    # shell treats the original as already placed, so `bar put` on it is a no-op.
    for clone in plugins:
        if clone["clonedFrom"] and clone["enabled"]:
            for orig in plugins:
                if orig["id"] == clone["clonedFrom"] and not orig["enabled"]:
                    orig["replacedBy"] = clone["id"]

    plugins.sort(key=lambda r: r["name"].lower())
    print(json.dumps({"error": "", "plugins": plugins}))
    return 0


if __name__ == "__main__":
    sys.exit(main())
