#!/usr/bin/env python3
"""For each plugin id given, say what `omarchy plugin remove` would lose.

Prints JSON {id: {"kind": ..., "warning": ...}}. `remove` deletes a git
checkout outright, so work that isn't on its remote is gone; a plain folder
is backed up and a symlink only unlinked. Fetches origin to check, because
the remote-tracking refs in plugin checkouts are stale.
"""
import json
import os
import subprocess
import sys

USER_DIR = os.path.expanduser("~/.config/omarchy/plugins")
THEMES_DIR = os.path.expanduser("~/.config/omarchy/themes")
THEME_BACKUPS = "~/.local/share/plugboard/theme-backups"


def git(path, *args, timeout=20):
    p = subprocess.run(["git", "-C", path, *args], capture_output=True, text=True,
                       timeout=timeout, env={**os.environ, "GIT_TERMINAL_PROMPT": "0",
                                             "GIT_SSH_COMMAND": "ssh -oBatchMode=yes"})
    return p.returncode, p.stdout.strip()


def check(pid):
    path = os.path.join(USER_DIR, pid)
    if os.path.islink(path):
        return {"kind": "symlink", "warning": "",
                "note": "only the link is removed; " + os.path.realpath(path) + " is kept"}
    if not os.path.isdir(os.path.join(path, ".git")):
        return {"kind": "local", "warning": "",
                "note": "folder is moved to a .bak backup, not deleted"}
    return check_git(path)


def check_git(path):
    rc, dirty = git(path, "status", "--porcelain", "--untracked-files=normal")
    if rc == 0 and dirty:
        n = len(dirty.splitlines())
        return {"kind": "git", "warning": f"{n} uncommitted local change(s) will be deleted", "note": ""}
    try:
        rc, _ = git(path, "fetch", "--quiet", "origin")
    except subprocess.TimeoutExpired:
        rc = 1
    if rc != 0:
        return {"kind": "git", "warning": "couldn't reach its remote to check for local commits", "note": ""}
    rc, ahead = git(path, "rev-list", "--count", "HEAD", "--not", "--remotes=origin")
    if rc == 0 and ahead not in ("", "0"):
        return {"kind": "git", "warning": f"{ahead} local commit(s) not on its remote will be deleted",
                "note": ""}
    return {"kind": "git", "warning": "", "note": "deleted; its repo remains upstream"}


def check_theme(name):
    """Plugboard backs a theme up before `omarchy theme remove` deletes it,
    so nothing is lost either way; this says what the backup is for."""
    path = os.path.join(THEMES_DIR, name)
    if os.path.islink(path):
        return {"kind": "symlink", "warning": "",
                "note": "only the link is removed; " + os.path.realpath(path) + " is kept"}
    builtin = os.path.isdir(os.path.join(os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy", "themes", name))
    after = " Omarchy's built-in theme of the same name takes its place." if builtin else ""
    if not os.path.isdir(os.path.join(path, ".git")):
        return {"kind": "local", "warning": "not from a git repo, so this is the only copy",
                "note": "a backup goes in " + THEME_BACKUPS + "." + after}
    info = check_git(path)
    info["note"] = "a backup goes in " + THEME_BACKUPS + (" anyway; its repo remains upstream." if not info["warning"] else ".") + after
    return info


def main(ids):
    out = {}
    for pid in ids:
        out[pid] = check_theme(pid[len("theme:"):]) if pid.startswith("theme:") else check(pid)
    print(json.dumps(out))


if __name__ == "__main__":
    main(sys.argv[1:])
