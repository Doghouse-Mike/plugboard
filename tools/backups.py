#!/usr/bin/env python3
"""Print one JSON snapshot of the backups left by uninstalls. Read-only.

Two kinds:
- theme: ~/.local/share/plugboard/theme-backups/<name>-<YYYYmmdd-HHMMSS>.tar.gz,
  which Plugboard writes before `omarchy theme remove` deletes a theme.
- plugin: ~/.config/omarchy/plugins/.<id>.bak.<YYYYmmddHHMMSS>[-n], the
  folder `omarchy plugin remove` renames a non-git plugin to instead of
  deleting it. (A git-managed plugin is deleted outright and leaves none.)
"""
import json
import os
import re
import sys
from datetime import datetime

HOME = os.path.expanduser("~")
THEME_BACKUPS = os.path.join(HOME, ".local/share/plugboard/theme-backups")
THEMES_DIR = os.path.join(HOME, ".config/omarchy/themes")
PLUGINS_DIR = os.path.join(HOME, ".config/omarchy/plugins")
THEME_RE = re.compile(r"^(?P<name>[A-Za-z0-9_][A-Za-z0-9._+-]*)-(?P<ts>\d{8}-\d{6})\.tar\.gz$")
PLUGIN_RE = re.compile(r"^\.(?P<name>[A-Za-z0-9][A-Za-z0-9._-]*)\.bak\.(?P<ts>\d{14})(?:-\d+)?$")


def size_of(path):
    if not os.path.isdir(path) or os.path.islink(path):
        return os.lstat(path).st_size
    total = 0
    for root, _, files in os.walk(path):
        for f in files:
            try:
                total += os.lstat(os.path.join(root, f)).st_size
            except OSError:
                pass
    return total


def when(ts, fmt):
    try:
        return datetime.strptime(ts, fmt).strftime("%Y-%m-%d %H:%M")
    except ValueError:
        return ""


def display(name):
    return re.sub(r"(^|-)([a-z])", lambda m: m.group(1) + m.group(2).upper(), name).replace("-", " ")


def main():
    out = []
    try:
        files = sorted(os.listdir(THEME_BACKUPS))
    except OSError:
        files = []
    for f in files:
        m = THEME_RE.match(f)
        if not m:
            continue
        name = m.group("name")
        out.append({"id": "backup:theme:" + f, "kind": "theme", "name": name, "title": display(name),
                    "file": f, "date": when(m.group("ts"), "%Y%m%d-%H%M%S"),
                    "size": size_of(os.path.join(THEME_BACKUPS, f)),
                    "installed": os.path.lexists(os.path.join(THEMES_DIR, name))})
    try:
        entries = sorted(os.listdir(PLUGINS_DIR))
    except OSError:
        entries = []
    for f in entries:
        m = PLUGIN_RE.match(f)
        path = os.path.join(PLUGINS_DIR, f)
        if not m or not os.path.isdir(path) or os.path.islink(path):
            continue
        name = m.group("name")
        title = name
        try:
            with open(os.path.join(path, "manifest.json"), encoding="utf-8") as fh:
                manifest = json.load(fh)
            title = str(manifest.get("name") or name)
        except (OSError, ValueError, AttributeError):
            pass
        out.append({"id": "backup:plugin:" + f, "kind": "plugin", "name": name, "title": title,
                    "file": f, "date": when(m.group("ts"), "%Y%m%d%H%M%S"), "size": size_of(path),
                    "installed": os.path.lexists(os.path.join(PLUGINS_DIR, name))})
    out.sort(key=lambda b: b["date"], reverse=True)
    print(json.dumps({"error": "", "backups": out}))


if __name__ == "__main__":
    sys.exit(main())
