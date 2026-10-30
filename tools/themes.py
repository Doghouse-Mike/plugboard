#!/usr/bin/env python3
"""Print one JSON snapshot of the Omarchy themes on this machine. Read-only.

Built-in themes live in $OMARCHY_PATH/themes; ones you installed in
~/.config/omarchy/themes, where a folder with a built-in's name takes its
place (as `omarchy theme dir` resolves it).

Also reports, per theme, its wallpapers (the theme's own plus any you added
under ~/.config/omarchy/backgrounds/<theme>/, the two places `omarchy theme
set` picks from) and the plugins that look like they came with it. Omarchy
doesn't record that link (themes install no plugins themselves; bundles use
their own installers), so it's inferred, strongest evidence first: a plugin
that is a symlink into the theme, one whose source the theme ships, or one
named after the theme (`lcars.*` for `lcars`).
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
CURRENT_BG = os.path.join(HOME, ".local/state/omarchy/current/background")
USER_BGS = os.path.join(HOME, ".config/omarchy/backgrounds")
PLUGINS_DIR = os.path.join(HOME, ".config/omarchy/plugins")
MAX_WALLPAPERS = 60
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


def wallpapers(path, name):
    out = []
    for base, mine in ((os.path.join(USER_BGS, name), True), (os.path.join(path, "backgrounds"), False)):
        try:
            files = sorted(f for f in os.listdir(base) if f.lower().endswith(IMAGES))
        except OSError:
            continue
        out += [{"path": os.path.join(base, f), "name": f, "mine": mine} for f in files]
    return out[:MAX_WALLPAPERS]


def shipped_plugin_ids(path):
    """Plugin ids whose manifest.json sits inside the theme folder (a few levels down)."""
    ids = set()
    for root, dirs, files in os.walk(path):
        dirs[:] = [d for d in dirs if d not in (".git", "backgrounds")]
        if root[len(path):].count(os.sep) > 3:
            dirs[:] = []
            continue
        if "manifest.json" in files:
            try:
                with open(os.path.join(root, "manifest.json"), encoding="utf-8") as f:
                    pid = json.load(f).get("id")
                if isinstance(pid, str):
                    ids.add(pid)
            except (OSError, ValueError, AttributeError):
                pass
    return ids


def installed_plugins():
    out = {}
    try:
        names = os.listdir(PLUGINS_DIR)
    except OSError:
        return out
    for name in names:
        p = os.path.join(PLUGINS_DIR, name)
        try:
            with open(os.path.join(p, "manifest.json"), encoding="utf-8") as f:
                m = json.load(f)
        except (OSError, ValueError):
            continue
        out[str(m.get("id") or name)] = {"dir": p, "real": os.path.realpath(p), "name": str(m.get("name") or name)}
    return out


def bundled(theme_path, name, plugins):
    real = os.path.realpath(theme_path) + os.sep
    shipped = shipped_plugin_ids(theme_path)
    out = []
    for pid, p in sorted(plugins.items()):
        if p["real"].startswith(real):
            why = "linked from the theme's folder"
        elif pid in shipped:
            why = "the theme ships its source"
        elif pid.split(".")[0] == name or pid.startswith(name + "."):
            why = "named after the theme"
        else:
            continue
        out.append({"id": pid, "name": p["name"], "why": why})
    return out


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
    plugins = installed_plugins()
    try:
        current_bg = os.readlink(CURRENT_BG)
    except OSError:
        current_bg = ""
    themes = []
    for row in names.values():
        if not row["user"]:
            row.update(source="omarchy", url="", risk="")
        row["preview"] = preview(row["path"])
        row["colours"] = colours(row["path"])
        row["current"] = row["name"] == current
        row["wallpapers"] = wallpapers(row["path"], row["name"])
        row["myWallpapers"] = os.path.join(USER_BGS, row["name"]) if any(w["mine"] for w in row["wallpapers"]) else ""
        row["plugins"] = bundled(row["path"], row["name"], plugins) if row["user"] else []
        themes.append(row)
    themes.sort(key=lambda r: r["title"].lower())
    print(json.dumps({"error": "", "current": current, "currentBackground": current_bg, "themes": themes}))


if __name__ == "__main__":
    sys.exit(main())
