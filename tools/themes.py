#!/usr/bin/env python3
"""Print one JSON snapshot of the Omarchy themes on this machine. Read-only.

Built-in themes live in $OMARCHY_PATH/themes; ones you installed in
~/.config/omarchy/themes, where a folder with a built-in's name takes its
place (as `omarchy theme dir` resolves it).
"""
import json
import os
import re
import subprocess
import sys

HOME = os.path.expanduser("~")
USER_DIR = os.path.join(HOME, ".config/omarchy/themes")
BUILTIN_DIR = os.path.join(os.environ.get("OMARCHY_PATH") or "/usr/share/omarchy", "themes")
CURRENT = os.path.join(HOME, ".local/state/omarchy/current/theme.name")
PREVIEWS = ("preview.png", "preview.jpg", "preview.webp", "theme.png", "theme.jpg", "theme.webp")
IMAGES = (".png", ".jpg", ".jpeg", ".webp")
# Shown when a theme has no preview image; older themes number their colours.
SWATCHES = (("background",), ("foreground",), ("accent",), ("red", "color1"), ("green", "color2"),
            ("yellow", "color3"), ("blue", "color4"), ("magenta", "color5"), ("cyan", "color6"))


def title(name):
    # Same display name `omarchy theme list` prints.
    return re.sub(r"(^|-)([a-z])", lambda m: m.group(1) + m.group(2).upper(), name).replace("-", " ")


def colours(path):
    out = {}
    try:
        with open(os.path.join(path, "colors.toml"), encoding="utf-8") as f:
            for line in f:
                m = re.match(r'\s*([A-Za-z0-9_]+)\s*=\s*"(#[0-9A-Fa-f]{6})"', line)
                if m:
                    out[m.group(1)] = m.group(2)
    except OSError:
        pass
    return [next(out[k] for k in keys if k in out) for keys in SWATCHES if any(k in out for k in keys)]


def preview(path):
    for name in PREVIEWS:
        p = os.path.join(path, name)
        if os.path.isfile(p):
            return p
    bgs = os.path.join(path, "backgrounds")
    try:
        first = sorted(f for f in os.listdir(bgs) if f.lower().endswith(IMAGES))
    except OSError:
        first = []
    return os.path.join(bgs, first[0]) if first else ""


def git(path, *args):
    p = subprocess.run(["git", "-C", path, *args], capture_output=True, text=True, timeout=10)
    return p.returncode, p.stdout.strip()


def source(path):
    if os.path.islink(path):
        return {"source": "symlink", "target": os.path.realpath(path), "url": "", "risk": ""}
    if not os.path.isdir(os.path.join(path, ".git")):
        return {"source": "local", "url": "", "risk": ""}
    rc, url = git(path, "remote", "get-url", "origin")
    rc2, dirty = git(path, "status", "--porcelain", "--untracked-files=normal")
    return {"source": "git", "url": url if rc == 0 else "",
            "risk": "uncommitted local changes" if rc2 == 0 and dirty else ""}


def main():
    try:
        with open(CURRENT, encoding="utf-8") as f:
            current = f.read().strip()
    except OSError:
        current = ""
    names = {}
    for base, user in ((BUILTIN_DIR, False), (USER_DIR, True)):
        try:
            entries = os.listdir(base)
        except OSError:
            continue
        for name in entries:
            path = os.path.join(base, name)
            if name.startswith(".") or not os.path.isdir(path):
                continue
            row = names.setdefault(name, {"name": name, "title": title(name), "builtin": False, "user": False})
            if user:
                row.update(user=True, path=path, **source(path))
            else:
                row["builtin"] = True
                row.setdefault("path", path)
    themes = []
    for row in names.values():
        if not row["user"]:
            row.update(source="omarchy", url="", risk="")
        row["preview"] = preview(row["path"])
        row["colours"] = colours(row["path"])
        row["current"] = row["name"] == current
        themes.append(row)
    themes.sort(key=lambda r: r["title"].lower())
    print(json.dumps({"error": "", "current": current, "themes": themes}))


if __name__ == "__main__":
    sys.exit(main())
