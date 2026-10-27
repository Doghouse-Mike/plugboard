pragma Singleton
import QtQuick
import Quickshell
import Quickshell.Io

// Omarchy's palette and control tokens, read from the same files the shell
// uses (theme/colors.toml + theme/shell.toml, plus the user's shell.toml
// override). Re-read whenever theme.name is rewritten, which
// omarchy-theme-set does last, after the theme folder is in place.
Singleton {
  id: root

  readonly property string stateDir: Quickshell.env("HOME") + "/.local/state/omarchy/current"

  property color fg: "#cacccc"
  property color bg: "#101315"
  property color accent: "#8a9ba8"
  property color muted: "#707880"
  property color red: "#a55555"
  property color green: "#7c9c6c"
  property color yellow: "#c8b46e"
  property color blue: "#6c8cac"
  property color lighterBg: Qt.lighter(bg, 1.6)
  property bool dark: true

  // [controls] alphas from shell.toml
  property real hoverAlpha: 0.08
  property real selectedAlpha: 0.18
  property real normalAlpha: 0.04
  property real borderAlpha: 0.4
  property real baseSize: 12

  readonly property string font: "monospace"
  readonly property real fontScale: baseSize / 12
  function px(n) { return Math.round(n * fontScale) }
  readonly property int fsSmall: px(11)
  readonly property int fs: px(12)
  readonly property int fsLarge: px(15)
  readonly property int fsTitle: px(18)
  readonly property int rowH: px(30)
  readonly property int pad: px(10)
  readonly property int gap: px(6)

  function a(c, alpha) { return Qt.rgba(c.r, c.g, c.b, alpha) }
  readonly property color hoverFill: a(fg, hoverAlpha)
  readonly property color selectedFill: a(fg, selectedAlpha)
  readonly property color normalFill: a(fg, normalAlpha)
  readonly property color border: a(fg, borderAlpha)
  readonly property color faint: a(fg, 0.55)
  readonly property color divider: a(fg, 0.12)


  function parseToml(text) {
    var out = {}, section = ""
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var l = lines[i].replace(/^\s+|\s+$/g, "")
      if (!l || l[0] === "#") continue
      var s = l.match(/^\[([^\]]+)\]$/)
      if (s) { section = s[1] + "."; continue }
      var m = l.match(/^([A-Za-z0-9_.-]+)\s*=\s*(.+)$/)
      if (!m) continue
      var v = m[2].replace(/\s+#.*$/, "")
      if (v[0] === '"') v = v.slice(1, v.lastIndexOf('"'))
      out[section + m[1]] = v
    }
    return out
  }

  function applyColors(text) {
    var c = parseToml(text)
    function pick(k, d) { return c[k] ? c[k] : d }
    fg = pick("foreground", fg)
    bg = pick("background", bg)
    accent = pick("accent", accent)
    muted = pick("muted", pick("color8", muted))
    red = pick("red", pick("color1", red))
    green = pick("green", pick("color2", green))
    yellow = pick("yellow", pick("color3", yellow))
    blue = pick("blue", pick("color4", blue))
    lighterBg = pick("lighter_bg", Qt.lighter(bg, 1.6))
    dark = pick("mode", "dark") !== "light"
  }

  property var shellVals: ({})
  property var userVals: ({})
  function applyShell() {
    var v = Object.assign({}, shellVals, userVals)
    function num(k, d) { var n = Number(v[k]); return isFinite(n) && v[k] !== undefined ? n : d }
    hoverAlpha = num("controls.hover-cursor-fill-alpha", 0.08)
    selectedAlpha = num("controls.selected-fill-alpha", 0.18)
    normalAlpha = num("controls.normal-fill-alpha", 0.04)
    borderAlpha = num("controls.normal-border-alpha", 0.4)
    baseSize = num("font.base-size", 12)
  }

  function reload() {
    colorsFile.reload()
    shellFile.reload()
  }

  FileView {
    id: colorsFile
    path: root.stateDir + "/theme/colors.toml"
    printErrors: false
    onLoaded: root.applyColors(text())
  }
  FileView {
    id: shellFile
    path: root.stateDir + "/theme/shell.toml"
    printErrors: false
    onLoaded: { root.shellVals = root.parseToml(text()); root.applyShell() }
    onLoadFailed: { root.shellVals = {}; root.applyShell() }
  }
  FileView {
    path: Quickshell.env("HOME") + "/.config/omarchy/shell.toml"
    watchChanges: true
    printErrors: false
    onFileChanged: reload()
    onLoaded: { root.userVals = root.parseToml(text()); root.applyShell() }
    onLoadFailed: { root.userVals = {}; root.applyShell() }
  }
  FileView {
    path: root.stateDir + "/theme.name"
    watchChanges: true
    printErrors: false
    onFileChanged: { reload(); root.reload() }
  }
}
