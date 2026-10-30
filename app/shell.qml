//@ pragma AppId plugboard
//@ pragma UseQApplication
import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import "components"

// Plugboard: queue Omarchy plugin changes (bar placement, on/off, uninstall)
// theme changes (switch, uninstall) and what to do with the backups those
// uninstalls left (restore, delete for good), and apply them in one go. Runs as its own process, so the bar rebuild each
// change triggers can't close it.
ShellRoot {
  id: shell

  IpcHandler {
    target: "plugboard"
    function show(): void { win.visible = true }
    function quit(): void { Qt.quit() }
    function state(): string {
      return JSON.stringify({ plugins: root.plugins.length, themes: root.themes.length, backups: root.backups.length, currentTheme: root.themeCurrent,
                              pending: root.pendingCount, busy: root.busy, loading: root.loading, tab: root.tab, filter: root.filter })
    }
    function filterBy(name: string): void { root.filter = name }
    function tab(name: string): void { root.switchTab(name) }
    function search(text: string): void { searchInput.text = text }
    // Test hooks: queue/apply without real input, and render the window to a PNG.
    function queue(id: string, target: string): string {
      if (id.indexOf("backup:") === 0) {
        var b = root.backupById(id)
        if (!b) return "unknown"
        root.setBackupAction(b, target)
        return JSON.stringify(root.ops())
      }
      if (id.indexOf("theme:") === 0) {
        var t = root.themeByName(id.slice(6))
        if (!t) return "unknown"
        if (target === "remove") root.toggleThemeRemove(t)
        else root.useTheme(t)
        return JSON.stringify(root.ops())
      }
      var p = root.byId(id)
      if (!p) return "unknown"
      if (target === "remove") root.toggleRemove(p)
      else root.setTarget(p, target)
      return JSON.stringify(root.ops())
    }
    function discard(): void { root.discard() }
    function wallpaper(theme: string, file: string): string {
      var t = root.themeByName(theme)
      var w = t ? t.wallpapers.filter(function (x) { return x.name === file })[0] : null
      if (!w) return "unknown"
      root.chooseWallpaper(t, w)
      return JSON.stringify(root.ops())
    }
    function pickWallpaper(theme: string): void { root.wallpaperTheme = root.themeByName(theme) }
    function bundled(theme: string): string {
      var t = root.themeByName(theme)
      if (!t) return "unknown"
      root.toggleBundled(t)
      return JSON.stringify(root.ops())
    }
    function apply(): void { root.startApply() }
    function confirm(): void { if (root.confirmOpen && !root.checking) root.run(root.ops()) }
    function snapshot(path: string): void { root.grabToImage(function (r) { r.saveToFile(path) }) }
  }

  FloatingWindow {
    id: win
    title: "Plugboard — Omarchy plugins, themes & backups" + (Quickshell.env("PLUGBOARD_DEMO") === "1" ? " (demo)" : "")
    implicitWidth: 1000
    implicitHeight: 760
    visible: true
    color: Theme.bg

    Item {
      id: root
      anchors.fill: parent
      focus: true

      readonly property string tools: Quickshell.shellDir + "/../tools"
      // `plugboard --demo`: made-up plugins from demo/fixture.json; nothing is changed.
      readonly property bool demo: Quickshell.env("PLUGBOARD_DEMO") === "1"
      function backend(script, args) {
        return demo ? ["python3", "-I", tools + "/demo.py", { "state.py": "state", "themes.py": "themes", "backups.py": "backups", "removal-check.py": "check", "apply.py": "apply" }[script]].concat(args)
                    : ["python3", "-I", tools + "/" + script].concat(args)
      }

      property var plugins: []
      property string loadError: ""
      property bool loading: stateProc.running || themesProc.running || backupsProc.running
      property var backups: []

      property var themes: []
      property string themeCurrent: ""
      property string currentBackground: ""
      property var wallpaperTheme: null   // the theme whose wallpaper picker is open

      property string tab: "plugins"
      function switchTab(name) {
        if (tab === name) return
        tab = name
        filter = "all"
      }

      // Plugins: id -> { target: "off"|"on"|"left"|"center"|"right", remove: bool }
      // Themes: "theme-set" -> { target: name, wallpaper: {name, mine} | null };
      // "theme:<name>" -> { remove: true }. A plugin queued with its theme
      // carries bundledWith: <theme name>.
      property var pending: ({})
      property int rev: 0
      readonly property int pendingCount: { rev; return Object.keys(pending).length }

      property string filter: "all"

      // apply / confirm state
      property bool busy: applyProc.running
      property bool checking: false
      property var removalInfo: ({})
      property bool confirmOpen: false
      property var progress: []      // [{id, op, section, status, msg}]
      property bool progressOpen: false
      property string progressSummary: ""

      Component.onCompleted: refresh()
      Rectangle { anchors.fill: parent; color: Theme.bg; z: -100 }
      Keys.onPressed: function (e) {
        if (e.key === Qt.Key_Q && (e.modifiers & Qt.ControlModifier)) Qt.quit()
        else if (e.key === Qt.Key_F && (e.modifiers & Qt.ControlModifier)) searchInput.forceActiveFocus()
        else if (e.key === Qt.Key_Escape) {
          if (root.wallpaperTheme) root.wallpaperTheme = null
          else if (root.confirmOpen) root.confirmOpen = false
          else if (root.progressOpen && !root.busy) root.progressOpen = false
        }
      }

      function refresh() {
        if (!stateProc.running) stateProc.running = true
        if (!themesProc.running) themesProc.running = true
        if (!backupsProc.running) backupsProc.running = true
      }

      // ---- backups: "backup:<kind>:<file>" -> { action: "restore" | "delete" }
      function backupById(id) {
        for (var i = 0; i < backups.length; i++) if (backups[i].id === id) return backups[i]
        return null
      }
      function backupAction(b) { rev; var q = pending[b.id]; return q ? q.action : "" }
      function setBackupAction(b, action) {
        if (locked) return
        if (action === "restore" && b.installed) return
        store(b.id, backupAction(b) === action ? {} : { action: action })
      }
      function fmtSize(n) {
        if (n >= 1e9) return (n / 1e9).toFixed(1) + " GB"
        if (n >= 1e6) return (n / 1e6).toFixed(1) + " MB"
        if (n >= 1e3) return Math.round(n / 1e3) + " KB"
        return n + " B"
      }
      readonly property real backupsSize: { var t = 0; for (var i = 0; i < backups.length; i++) t += backups[i].size; return t }
      readonly property var visibleBackups: {
        rev
        var q = searchInput.text.toLowerCase().trim()
        return backups.filter(function (b) {
          if (root.filter === "themes" && b.kind !== "theme") return false
          if (root.filter === "plugins" && b.kind !== "plugin") return false
          if (root.filter === "pending" && !root.pending[b.id]) return false
          return !q || (b.title + " " + b.name + " " + b.date).toLowerCase().indexOf(q) !== -1
        })
      }
      function backupCountFor(f) {
        rev
        return backups.filter(function (b) {
          return f === "all" || (f === "themes" && b.kind === "theme") || (f === "plugins" && b.kind === "plugin") || (f === "pending" && pending[b.id])
        }).length
      }

      function current(p) {
        if (p.replacedBy) return "replaced"
        if (p.isBarWidget) {
          if (p.host) return "drawer"
          if (p.section) return p.section
          return p.enabled ? "loaded" : "off"
        }
        return p.enabled ? "on" : "off"
      }
      function desired(p) {
        rev
        var q = pending[p.id]
        return q && q.target ? q.target : current(p)
      }
      function removing(p) { rev; var q = pending[p.id]; return !!(q && q.remove) }
      function isPending(p) { rev; return !!pending[p.id] }

      // Queued changes are worked out against the last read, so not while it's stale.
      readonly property bool locked: busy || loading
      function setTarget(p, target) {
        if (locked) return
        var q = Object.assign({}, pending[p.id] || {})
        if (target === current(p)) delete q.target
        else q.target = target
        store(p.id, q)
      }
      function toggleRemove(p) {
        if (locked) return
        var q = Object.assign({}, pending[p.id] || {})
        if (q.remove) delete q.remove
        else { q.remove = true; delete q.target }
        store(p.id, q)
      }
      function store(id, q) {
        var next = Object.assign({}, pending)
        if (Object.keys(q).length) next[id] = q
        else delete next[id]
        pending = next
        rev++
      }
      function discard() { pending = {}; rev++ }

      // ---- themes
      function themeByName(name) {
        for (var i = 0; i < themes.length; i++) if (themes[i].name === name) return themes[i]
        return null
      }
      // The theme that will be in use once the queue runs.
      function themeTarget() { rev; var q = pending["theme-set"]; return q ? q.target : themeCurrent }
      function themeRemoving(t) { rev; return !!pending["theme:" + t.name] }
      function useTheme(t) {
        if (locked) return
        var next = Object.assign({}, pending)
        if (t.name === themeCurrent) delete next["theme-set"]
        else next["theme-set"] = { target: t.name, wallpaper: null }
        delete next["theme:" + t.name]
        dropBundled(next, t.name)
        keepCurrentUnlessSwitching(next)
        pending = next
        rev++
      }
      // The theme in use can only be removed while a switch away from it is queued.
      function keepCurrentUnlessSwitching(next) {
        var q = next["theme-set"]
        if (!q || q.target === themeCurrent) { delete next["theme:" + themeCurrent]; dropBundled(next, themeCurrent) }
      }
      function dropBundled(next, name) {
        for (var k in next) if (next[k].bundledWith === name) delete next[k]
      }
      // ---- wallpapers
      function currentWallpaperName() { var b = currentBackground; return b.slice(b.lastIndexOf("/") + 1) }
      function chosenWallpaper(t) {
        rev
        var q = pending["theme-set"]
        if (q && q.target === t.name && q.wallpaper) return q.wallpaper.name
        return t.name === themeCurrent ? currentWallpaperName() : ""
      }
      function chooseWallpaper(t, w) {
        if (locked) return
        var next = Object.assign({}, pending)
        next["theme-set"] = { target: t.name, wallpaper: { name: w.name, mine: !!w.mine } }
        // Picking the wallpaper already showing on the theme in use is no change.
        if (t.name === themeCurrent && w.name === currentWallpaperName()) delete next["theme-set"]
        delete next["theme:" + t.name]
        dropBundled(next, t.name)
        keepCurrentUnlessSwitching(next)
        pending = next
        rev++
      }
      // ---- plugins that came with a theme
      function bundledInstalled(t) { return (t.plugins || []).filter(function (b) { var p = byId(b.id); return p && !p.firstParty }) }
      function bundledQueued(t) {
        rev
        var list = bundledInstalled(t)
        return list.length > 0 && list.every(function (b) { return pending[b.id] && pending[b.id].bundledWith === t.name })
      }
      function toggleBundled(t) {
        if (locked) return
        var next = Object.assign({}, pending)
        if (bundledQueued(t)) dropBundled(next, t.name)
        else bundledInstalled(t).forEach(function (b) { next[b.id] = { remove: true, bundledWith: t.name } })
        pending = next
        rev++
      }
      function toggleThemeRemove(t) {
        if (locked || !t.user) return
        var key = "theme:" + t.name
        if (!pending[key] && t.name === themeTarget()) return
        if (pending[key]) {
          var next = Object.assign({}, pending)
          delete next[key]
          dropBundled(next, t.name)
          pending = next
          rev++
        } else store(key, { remove: true })
      }
      function themePendingLabel(t) {
        rev
        if (pending["theme:" + t.name]) return "will be uninstalled"
        var q = pending["theme-set"]
        if (q && q.target === t.name && t.name === themeCurrent) return "wallpaper will change"
        if (q && q.target === t.name) return "will be switched to"
        if (q && q.target !== themeCurrent && t.name === themeCurrent) return "will be switched away from"
        return ""
      }
      readonly property var visibleThemes: {
        rev
        var q = searchInput.text.toLowerCase().trim()
        return themes.filter(function (t) {
          if (root.filter === "mine" && !t.user) return false
          if (root.filter === "omarchy" && t.user) return false
          if (root.filter === "pending" && !root.themePendingLabel(t)) return false
          if (!q) return true
          return (t.title + " " + t.name + " " + (t.url || "")).toLowerCase().indexOf(q) !== -1
        })
      }
      function themeCountFor(f) {
        rev
        var n = 0
        for (var i = 0; i < themes.length; i++) {
          var t = themes[i]
          if (f === "all" || (f === "mine" && t.user) || (f === "omarchy" && !t.user)
              || (f === "pending" && themePendingLabel(t))) n++
        }
        return n
      }

      function byId(id) {
        for (var i = 0; i < plugins.length; i++) if (plugins[i].id === id) return plugins[i]
        return null
      }

      function ops() {
        var out = []
        for (var id in pending) {
          var q = pending[id]
          if (id.indexOf("backup:") === 0) {
            var bk = backupById(id)
            if (bk) out.push({ id: id, op: "backup-" + q.action, kind: bk.kind, file: bk.file, title: bk.title, date: bk.date, size: bk.size })
            continue
          }
          if (id === "theme-set") {
            if (q.target !== themeCurrent) out.push({ id: id, op: "theme-set", name: q.target, wallpaper: q.wallpaper || null })
            else if (q.wallpaper) out.push({ id: id, op: "theme-wallpaper", name: q.target, wallpaper: q.wallpaper })
            continue
          }
          if (id.indexOf("theme:") === 0) { out.push({ id: id, op: "theme-remove", name: id.slice(6) }); continue }
          var p = byId(id)
          if (!p) continue
          if (q.remove) { out.push({ id: id, op: "remove", bundledWith: q.bundledWith || "" }); continue }
          var cur = current(p), t = q.target
          if (!t || t === cur) continue
          if (t === "off") out.push({ id: id, op: "disable", barWidget: p.isBarWidget })
          else if (t === "on") out.push({ id: id, op: "enable" })
          else if (cur === "left" || cur === "center" || cur === "right") out.push({ id: id, op: "move", section: t })
          else out.push({ id: id, op: "put", section: t })
        }
        // The order apply.py runs them in (tools/apply.py ORDER).
        var order = { disable: 0, move: 1, put: 2, enable: 2, remove: 3, "theme-set": 4, "theme-wallpaper": 4, "theme-remove": 5, "backup-restore": 6, "backup-delete": 7 }
        return out.sort(function (a, b) { return order[a.op] - order[b.op] })
      }
      function sectionName(s) { return { left: "left", center: "centre", right: "right" }[s] || s }
      function describe(o) {
        if (o.op === "backup-restore" || o.op === "backup-delete") {
          var what = (o.title || o.file) + " " + o.kind
          return o.op === "backup-restore" ? "Restore the " + what + " (removed " + o.date + ")"
                                           : "Permanently delete the backup of the " + what + " (" + fmtSize(o.size) + ")"
        }
        if (o.op === "theme-set" || o.op === "theme-wallpaper" || o.op === "theme-remove") {
          var t = themeByName(o.name), tname = t ? t.title : o.name
          var wp = o.wallpaper ? " (wallpaper " + o.wallpaper.name + ")" : ""
          if (o.op === "theme-wallpaper") return "Change the " + tname + " theme's wallpaper to " + o.wallpaper.name
          return (o.op === "theme-set" ? "Switch to the " + tname + " theme" + wp : "Uninstall the " + tname + " theme")
        }
        var p = byId(o.id), name = p ? p.name : o.id
        if (o.op === "remove") {
          var with_ = o.bundledWith ? themeByName(o.bundledWith) : null
          return "Uninstall " + name + (with_ ? " (came with " + with_.title + ")" : "")
        }
        if (o.op === "disable") return "Turn off " + name
        if (o.op === "enable") return "Turn on " + name
        if (o.op === "move") return "Move " + name + " to " + sectionName(o.section)
        return "Put " + name + " on the bar (" + sectionName(o.section) + ")"
      }
      function pendingLabel(p) {
        rev
        var q = pending[p.id]
        if (!q) return ""
        if (q.remove) return q.bundledWith ? "will be uninstalled with the " + ((themeByName(q.bundledWith) || {}).title || q.bundledWith) + " theme" : "will be uninstalled"
        var t = q.target
        if (t === "off") return p.isBarWidget ? "will come off the bar" : "will turn off"
        if (t === "on") return "will turn on"
        return "will go " + (current(p) === "off" || current(p) === "loaded" ? "on the bar, " : "to the ") + sectionName(t)
      }

      // Apply: removals get a fresh git check and a confirmation first, and
      // permanent backup deletes a confirmation.
      function startApply() {
        var list = ops()
        if (!list.length) return
        var removes = list.filter(function (o) { return o.op === "remove" || o.op === "theme-remove" }).map(function (o) { return o.id })
        if (removes.length) {
          checking = true
          removalInfo = {}
          confirmOpen = true
          checkProc.command = backend("removal-check.py", removes)
          checkProc.running = true
        } else if (list.some(function (o) { return o.op === "backup-delete" })) {
          removalInfo = {}
          confirmOpen = true
        } else run(list)
      }
      function run(list) {
        confirmOpen = false
        progress = list.map(function (o) { return { id: o.id, op: o.op, name: o.name || "", kind: o.kind || "", file: o.file || "", title: o.title || "", date: o.date || "", size: o.size || 0, wallpaper: o.wallpaper || null, bundledWith: o.bundledWith || "", section: o.section || "", status: "queued", msg: "" } })
        progressSummary = ""
        progressOpen = true
        applyProc.command = backend("apply.py", [JSON.stringify(list)])
        applyProc.running = true
      }
      function onEvent(ev) {
        if (ev.status === "done") {
          progressSummary = ev.failed ? (ev.ok + " done, " + ev.failed + " failed — see the log below")
                                      : ("All " + ev.ok + " change" + (ev.ok === 1 ? "" : "s") + " applied")
          return
        }
        if (ev.status === "start" || ev.i === undefined) return
        var next = progress.slice()
        // apply.py runs in its own order, so match by id.
        for (var i = 0; i < next.length; i++) {
          if (next[i].id !== ev.id) continue
          var row = Object.assign({}, next[i])
          if (ev.status === "info") row.msg = ev.msg
          else { row.status = ev.status; if (ev.msg) row.msg = ev.msg }
          next[i] = row
        }
        progress = next
      }

      readonly property var visiblePlugins: {
        rev
        var q = searchInput.text.toLowerCase().trim()
        return plugins.filter(function (p) {
          var cur = root.current(p)
          if (root.filter === "bar" && !(cur === "left" || cur === "center" || cur === "right")) return false
          if (root.filter === "drawer" && cur !== "drawer") return false
          if (root.filter === "off" && cur !== "off") return false
          if (root.filter === "other" && p.isBarWidget) return false
          if (root.filter === "third" && p.firstParty) return false
          if (root.filter === "pending" && !root.pending[p.id]) return false
          if (!q) return true
          return (p.name + " " + p.id + " " + p.description + " " + p.author + " " + p.kinds.join(" ")).toLowerCase().indexOf(q) !== -1
        })
      }
      function countFor(f) {
        rev
        var save = filter
        var n = 0
        for (var i = 0; i < plugins.length; i++) {
          var p = plugins[i], cur = current(p)
          if (f === "all" || (f === "bar" && (cur === "left" || cur === "center" || cur === "right"))
              || (f === "drawer" && cur === "drawer") || (f === "off" && cur === "off")
              || (f === "other" && !p.isBarWidget) || (f === "third" && !p.firstParty)
              || (f === "pending" && pending[p.id])) n++
        }
        return n
      }

      Process {
        id: stateProc
        command: root.backend("state.py", [])
        stdout: StdioCollector {
          onStreamFinished: {
            try {
              var data = JSON.parse(text)
              root.loadError = data.error || ""
              if (!data.error) root.plugins = data.plugins
            } catch (e) {
              root.loadError = "Couldn't read plugin state: " + e
            }
            // Drop queued changes that no longer apply (plugin gone, or already in that state).
            var next = {}
            for (var id in root.pending) {
              if (id.indexOf("theme") === 0) { next[id] = root.pending[id]; continue }   // themesProc tidies these
              var p = root.byId(id)
              if (!p) continue
              var q = Object.assign({}, root.pending[id])
              if (q.target === root.current(p)) delete q.target
              if (Object.keys(q).length) next[id] = q
            }
            root.pending = next
            root.rev++
          }
        }
      }
      Process {
        id: themesProc
        command: root.backend("themes.py", [])
        stdout: StdioCollector {
          onStreamFinished: {
            try {
              var data = JSON.parse(text)
              root.themes = data.themes || []
              root.themeCurrent = data.current || ""
              root.currentBackground = data.currentBackground || ""
            } catch (e) {
              root.loadError = "Couldn't read themes: " + e
            }
            // Drop queued theme changes that no longer apply.
            var next = {}
            for (var id in root.pending) {
              var q = root.pending[id]
              if (id === "theme-set") { if (root.themeByName(q.target) && (q.target !== root.themeCurrent || q.wallpaper)) next[id] = q }
              else if (id.indexOf("theme:") === 0) { var t = root.themeByName(id.slice(6)); if (t && t.user) next[id] = q }
              else next[id] = q
            }
            root.keepCurrentUnlessSwitching(next)
            root.pending = next
            root.rev++
          }
        }
      }
      Process {
        id: backupsProc
        command: root.backend("backups.py", [])
        stdout: StdioCollector {
          onStreamFinished: {
            try { root.backups = JSON.parse(text).backups || [] } catch (e) { root.loadError = "Couldn't read backups: " + e }
            var next = {}
            for (var id in root.pending) {
              if (id.indexOf("backup:") !== 0) { next[id] = root.pending[id]; continue }
              var b = root.backupById(id)
              if (b && !(root.pending[id].action === "restore" && b.installed)) next[id] = root.pending[id]
            }
            root.pending = next
            root.rev++
          }
        }
      }
      Process {
        id: checkProc
        stdout: StdioCollector {
          onStreamFinished: {
            try { root.removalInfo = JSON.parse(text) } catch (e) { root.removalInfo = {} }
            root.checking = false
          }
        }
      }
      Process {
        id: applyProc
        stdout: SplitParser {
          onRead: function (line) {
            try { root.onEvent(JSON.parse(line)) } catch (e) {}
          }
        }
        onExited: {
          root.discard()
          root.refresh()
        }
      }

      // ---------------------------------------------------------------- header
      Rectangle {
        id: header
        anchors { left: parent.left; right: parent.right; top: parent.top }
        height: headerCol.implicitHeight + Theme.px(24)
        color: Theme.a(Theme.fg, 0.02)
        Column {
          id: headerCol
          anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.px(12) }
          spacing: Theme.px(10)
          Row {
            width: parent.width
            spacing: Theme.px(10)
            Row {
              id: title
              Repeater {
                model: [{ k: "plugins", l: "Plugins" }, { k: "themes", l: "Themes" }, { k: "backups", l: "Backups" }]
                Rectangle {
                  required property var modelData
                  readonly property bool on: root.tab === modelData.k
                  width: tabTxt.implicitWidth + Theme.px(20); height: Theme.px(30)
                  color: "transparent"
                  Txt {
                    id: tabTxt; anchors.centerIn: parent
                    text: parent.modelData.l
                    font.pixelSize: Theme.fsTitle; font.bold: parent.on
                    color: parent.on ? Theme.fg : Theme.faint
                  }
                  Rectangle { visible: parent.on; anchors.bottom: parent.bottom; width: parent.width; height: 2; color: Theme.accent }
                  MouseArea { anchors.fill: parent; cursorShape: Qt.PointingHandCursor; onClicked: root.switchTab(parent.modelData.k) }
                }
              }
            }
            Txt {
              id: countTxt
              text: root.loading ? "reading…" : root.tab === "backups"
                    ? root.backups.length + " backups · " + root.fmtSize(root.backupsSize)
                    : root.tab === "themes"
                    ? root.themes.length + " themes" + (root.themeCurrent ? " · using " + ((root.themeByName(root.themeCurrent) || {}).title || root.themeCurrent) : "")
                    : root.plugins.length + " installed"
              color: Theme.faint; height: Theme.px(30)
            }
            Item { width: Math.max(0, parent.width - title.width - countTxt.width - refreshBtn.width - searchBox.width - Theme.px(40)); height: 1 }
            Rectangle {
              id: searchBox
              width: Theme.px(280); height: Theme.px(28)
              color: searchInput.activeFocus ? Theme.hoverFill : Theme.normalFill
              border.width: 1
              border.color: searchInput.activeFocus ? Theme.accent : Theme.a(Theme.fg, 0.18)
              TextInput {
                id: searchInput
                anchors.fill: parent
                anchors.leftMargin: Theme.px(8); anchors.rightMargin: Theme.px(8)
                verticalAlignment: TextInput.AlignVCenter
                color: Theme.fg
                font.family: Theme.font; font.pixelSize: Theme.fs
                clip: true
                onTextChanged: root.rev++
                Keys.onEscapePressed: { text = ""; root.forceActiveFocus() }
              }
              Txt {
                visible: searchInput.text === "" && !searchInput.activeFocus
                anchors.fill: parent; anchors.leftMargin: Theme.px(8)
                text: (root.tab === "themes" ? "Search themes…" : root.tab === "backups" ? "Search backups…" : "Search name, id, author…") + "  (Ctrl+F)"; color: Theme.faint
              }
            }
            Btn { id: refreshBtn; text: "Refresh"; tip: "Re-read plugins, themes and backups"; onClicked: root.refresh() }
          }
          Flow {
            visible: root.tab === "backups"
            width: parent.width
            spacing: Theme.px(6)
            Repeater {
              model: [{ key: "all", label: "All" }, { key: "themes", label: "Themes" },
                      { key: "plugins", label: "Plugins" }, { key: "pending", label: "Queued" }]
              Btn {
                required property var modelData
                text: modelData.label + "  " + root.backupCountFor(modelData.key)
                active: root.filter === modelData.key
                onClicked: root.filter = modelData.key
              }
            }
          }
          Flow {
            visible: root.tab === "themes"
            width: parent.width
            spacing: Theme.px(6)
            Repeater {
              model: [{ key: "all", label: "All" }, { key: "mine", label: "Installed by you" },
                      { key: "omarchy", label: "Omarchy's own" }, { key: "pending", label: "Queued" }]
              Btn {
                required property var modelData
                text: modelData.label + "  " + root.themeCountFor(modelData.key)
                active: root.filter === modelData.key
                onClicked: root.filter = modelData.key
              }
            }
          }
          Flow {
            visible: root.tab === "plugins"
            width: parent.width
            spacing: Theme.px(6)
            Repeater {
              model: [
                { key: "all", label: "All" }, { key: "bar", label: "On the bar" },
                { key: "drawer", label: "Tray drawer" }, { key: "off", label: "Not on bar" },
                { key: "other", label: "Services & panels" }, { key: "third", label: "Third-party" },
                { key: "pending", label: "Queued" }
              ]
              Btn {
                required property var modelData
                text: modelData.label + "  " + root.countFor(modelData.key)
                active: root.filter === modelData.key
                onClicked: root.filter = modelData.key
              }
            }
          }
        }
        Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.divider }
      }

      Txt {
        visible: root.loadError !== ""
        anchors { top: header.bottom; left: parent.left; right: parent.right; margins: Theme.px(12) }
        text: root.loadError + " — is the Omarchy shell running? Try Refresh."
        color: Theme.red; wrapMode: Text.Wrap
      }

      // ------------------------------------------------------------------ list
      ListView {
        id: list
        visible: root.tab === "plugins"
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: footer.top }
        clip: true
        model: root.visiblePlugins
        boundsBehavior: Flickable.StopAtBounds
        opacity: root.locked ? 0.55 : 1
        ScrollBar.vertical: ScrollBar {}
        delegate: Rectangle {
          id: rowItem
          required property var modelData
          readonly property var p: modelData
          readonly property string cur: root.current(p)
          readonly property string want: root.desired(p)
          readonly property bool rm: root.removing(p)
          readonly property bool queued: root.isPending(p)
          width: list.width
          height: rowCol.implicitHeight + Theme.px(18)
          color: queued ? Theme.a(rm ? Theme.red : Theme.accent, 0.07) : rowMa.containsMouse ? Theme.a(Theme.fg, 0.03) : "transparent"
          MouseArea { id: rowMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
          Rectangle { visible: rowItem.queued; width: 3; height: parent.height; color: rowItem.rm ? Theme.red : Theme.accent }

          Column {
            id: rowCol
            anchors { left: parent.left; right: controls.left; verticalCenter: parent.verticalCenter; leftMargin: Theme.px(14); rightMargin: Theme.px(12) }
            spacing: Theme.px(3)
            Row {
              spacing: Theme.px(8)
              width: parent.width
              Txt {
                id: nameTxt
                text: rowItem.p.name
                font.bold: true
                font.strikeout: rowItem.rm
                color: rowItem.rm ? Theme.faint : Theme.fg
                width: Math.min(implicitWidth, parent.width * 0.5)
              }
              Txt {
                text: rowItem.p.id + (rowItem.p.version ? "  v" + rowItem.p.version : "")
                color: Theme.faint; font.pixelSize: Theme.fsSmall
                width: Math.min(implicitWidth, parent.width - nameTxt.width - Theme.px(8))
                height: nameTxt.height
              }
            }
            Txt {
              visible: text !== ""
              width: parent.width
              text: rowItem.p.description
              color: Theme.a(Theme.fg, 0.75); font.pixelSize: Theme.fsSmall
            }
            Flow {
              width: parent.width
              spacing: Theme.px(5)
              Repeater {
                model: rowItem.p.kinds
                Chip { required property string modelData; text: modelData }
              }
              Chip {
                text: rowItem.p.firstParty ? "Omarchy" : rowItem.p.source === "symlink" ? "dev link" : rowItem.p.source === "local" ? "local folder" : "git"
                tone: Theme.blue
              }
              Chip { visible: rowItem.cur === "drawer"; text: "in tray drawer"; tone: Theme.accent }
              Chip {
                visible: rowItem.cur === "drawer" && !rowItem.p.hostLoaded
                text: "⚠ in drawer but not loaded (missing from plugins[])"
                tone: Theme.yellow
              }
              Chip { visible: rowItem.cur === "loaded"; text: "loaded, no bar slot"; tone: Theme.yellow }
              Chip {
                visible: rowItem.cur === "replaced"
                text: "replaced by " + (root.byId(rowItem.p.replacedBy) || { name: rowItem.p.replacedBy }).name
                tone: Theme.accent
              }
              Chip { visible: rowItem.p.risk !== ""; text: "⚠ " + rowItem.p.risk; tone: Theme.yellow }
              Txt {
                visible: rowItem.queued
                text: "→ " + root.pendingLabel(rowItem.p)
                color: rowItem.rm ? Theme.red : Theme.accent
                font.pixelSize: Theme.fsSmall
              }
            }
          }

          Row {
            id: controls
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: Theme.px(14) }
            spacing: Theme.px(10)

            // Bar widgets: where on the bar (or off it).
            Row {
              visible: rowItem.p.isBarWidget && !rowItem.p.isBar && rowItem.cur !== "drawer" && rowItem.cur !== "replaced" && !rowItem.rm
              spacing: 0
              Repeater {
                model: [{ k: "off", l: "Off" }, { k: "left", l: "Left" }, { k: "center", l: "Centre" }, { k: "right", l: "Right" }]
                Btn {
                  required property var modelData
                  visible: modelData.k !== "off" || rowItem.p.canDisable
                  text: modelData.l
                  active: rowItem.want === modelData.k
                  tip: modelData.k === "off" ? "Take it off the bar" : "Put it in the " + modelData.k + " section"
                  onClicked: root.setTarget(rowItem.p, modelData.k)
                }
              }
            }
            // Drawer widgets are managed from the tray itself: the plugin
            // manager's disable path is what strands them.
            Txt {
              visible: rowItem.cur === "replaced"
              text: "its clone is in use"
              color: Theme.faint; font.pixelSize: Theme.fsSmall
              height: Theme.px(26)
            }
            Txt {
              visible: rowItem.cur === "drawer" && !rowItem.rm
              text: "managed by the tray"
              color: Theme.faint; font.pixelSize: Theme.fsSmall
              height: Theme.px(26)
            }
            // Services, panels, overlays, menus: on/off.
            Row {
              visible: !rowItem.p.isBarWidget && !rowItem.p.isBar && rowItem.p.canDisable && rowItem.cur !== "replaced" && !rowItem.rm
              Repeater {
                model: [{ k: "off", l: "Off" }, { k: "on", l: "On" }]
                Btn {
                  required property var modelData
                  text: modelData.l
                  active: rowItem.want === modelData.k
                  onClicked: root.setTarget(rowItem.p, modelData.k)
                }
              }
            }
            Txt {
              visible: rowItem.p.isBar || (!rowItem.p.canDisable && !rowItem.p.isBarWidget)
              text: rowItem.p.isBar ? (rowItem.p.enabled ? "active bar" : "bar style") : "always on"
              color: Theme.faint; font.pixelSize: Theme.fsSmall
              height: Theme.px(26)
            }
            Btn {
              visible: !rowItem.p.firstParty
              text: rowItem.rm ? "Keep" : "Uninstall"
              textColor: rowItem.rm ? Theme.fg : Theme.red
              tip: rowItem.rm ? "Don't uninstall" : "Queue for uninstall"
              onClicked: root.toggleRemove(rowItem.p)
            }
            Item { visible: rowItem.p.firstParty; width: Theme.px(74); height: 1 }
          }
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.divider }
        }
        Txt {
          anchors.centerIn: parent
          visible: list.count === 0 && !root.loading && root.loadError === ""
          text: root.filter === "pending" ? "Nothing queued." : "No plugins match."
          color: Theme.faint
        }
      }

      // ---------------------------------------------------------------- themes
      GridView {
        id: grid
        visible: root.tab === "themes"
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: footer.top; margins: Theme.px(10) }
        clip: true
        model: root.visibleThemes
        boundsBehavior: Flickable.StopAtBounds
        opacity: root.locked ? 0.55 : 1
        ScrollBar.vertical: ScrollBar {}
        readonly property int cols: Math.max(1, Math.floor(width / Theme.px(250)))
        cellWidth: Math.floor(width / cols)
        cellHeight: (cellWidth - Theme.px(28)) * 0.5625 + Theme.px(150)
        delegate: Item {
          id: card
          required property var modelData
          readonly property var t: modelData
          readonly property bool rm: root.themeRemoving(t)
          readonly property bool target: root.themeTarget() === t.name
          readonly property string label: root.themePendingLabel(t)
          readonly property real buttonsWidth: (useBtn.visible ? useBtn.width + Theme.px(6) : 0) + (rmBtn.visible ? rmBtn.width + Theme.px(6) : 0)
          width: grid.cellWidth; height: grid.cellHeight
          Rectangle {
            anchors.fill: parent; anchors.margins: Theme.px(6)
            color: card.label ? Theme.a(card.rm ? Theme.red : Theme.accent, 0.08) : cardMa.containsMouse ? Theme.a(Theme.fg, 0.04) : Theme.normalFill
            border.width: card.target || card.label ? 2 : 1
            border.color: card.rm ? Theme.red : card.target ? Theme.accent : Theme.a(Theme.fg, 0.14)
            MouseArea { id: cardMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
            Column {
              anchors { fill: parent; margins: Theme.px(8) }
              spacing: Theme.px(6)
              Item {
                width: parent.width; height: width * 0.5625
                clip: true
                Image {
                  id: shot
                  anchors.fill: parent
                  source: card.t.preview ? "file://" + card.t.preview : ""
                  sourceSize.width: Theme.px(480)
                  fillMode: Image.PreserveAspectCrop
                  asynchronous: true; cache: false
                  opacity: card.rm ? 0.35 : 1
                }
                // No preview image: show the theme's colours instead.
                Row {
                  visible: shot.status === Image.Error || shot.status === Image.Null
                  anchors.fill: parent
                  Repeater {
                    model: card.t.colours
                    Rectangle { required property string modelData; width: parent.width / Math.max(1, card.t.colours.length); height: parent.height; color: modelData }
                  }
                }
                Txt {
                  visible: (shot.status === Image.Error || shot.status === Image.Null) && card.t.colours.length === 0
                  anchors.centerIn: parent; text: "no preview"; color: Theme.faint
                }
              }
              Row {
                width: parent.width
                spacing: Theme.px(6)
                Txt {
                  id: themeName
                  text: card.t.title; font.bold: true; font.strikeout: card.rm
                  width: Math.min(implicitWidth, parent.width - card.buttonsWidth)
                  height: Theme.px(26)
                }
                Item { width: Math.max(0, parent.width - themeName.width - card.buttonsWidth); height: 1 }
                Btn {
                  id: useBtn
                  visible: !card.rm
                  text: card.t.name === root.themeCurrent && !card.label ? "In use" : "Use"
                  active: card.target
                  tip: card.target ? "This will be the theme" : "Queue a switch to this theme"
                  onClicked: root.useTheme(card.t)
                }
                Btn {
                  id: rmBtn
                  visible: card.t.user && (!card.target || card.rm)
                  text: card.rm ? "Keep" : "Uninstall"
                  textColor: card.rm ? Theme.fg : Theme.red
                  tip: card.rm ? "Don't uninstall" : "Queue for uninstall"
                  onClicked: root.toggleThemeRemove(card.t)
                }
              }
              Flow {
                width: parent.width
                spacing: Theme.px(5)
                Chip {
                  text: !card.t.user ? "Omarchy" : card.t.source === "symlink" ? "dev link" : card.t.source === "local" ? "local folder" : "git"
                  tone: Theme.blue
                }
                Chip { visible: card.t.user && card.t.builtin; text: "replaces Omarchy's"; tone: Theme.accent }
                Chip { visible: card.t.wallpapers.length > 1; text: card.t.wallpapers.length + " wallpapers"; tone: Theme.muted }
                Chip {
                  readonly property int n: root.bundledInstalled(card.t).length
                  visible: n > 0
                  text: "came with " + n + " plugin" + (n === 1 ? "" : "s")
                  tone: Theme.yellow
                  MouseArea { id: bundleMa; anchors.fill: parent; hoverEnabled: true }
                  Tip {
                    show: bundleMa.containsMouse
                    text: root.bundledInstalled(card.t).map(function (b) { return b.name }).join(", ")
                          + (card.t.plugins.length ? "  (" + card.t.plugins[0].why + ")" : "")
                  }
                }
                Chip { visible: card.t.risk !== ""; text: "⚠ " + card.t.risk; tone: Theme.yellow }
                Txt { visible: card.label !== ""; text: "→ " + card.label; color: card.rm ? Theme.red : Theme.accent; font.pixelSize: Theme.fsSmall }
              }
              Row {
                spacing: Theme.px(6)
                Btn {
                  visible: card.target && !card.rm && card.t.wallpapers.length > 1
                  text: "Wallpaper…"
                  tip: "Pick which of its wallpapers to show"
                  onClicked: root.wallpaperTheme = card.t
                }
                Btn {
                  readonly property int n: root.bundledInstalled(card.t).length
                  visible: card.rm && n > 0
                  text: root.bundledQueued(card.t) ? "Keep its " + n + " plugin" + (n === 1 ? "" : "s") : "Also uninstall its " + n + " plugin" + (n === 1 ? "" : "s")
                  textColor: root.bundledQueued(card.t) ? Theme.fg : Theme.red
                  tip: root.bundledInstalled(card.t).map(function (b) { return b.name }).join(", ")
                  onClicked: root.toggleBundled(card.t)
                }
              }
            }
          }
        }
        Txt {
          anchors.centerIn: parent
          visible: grid.count === 0 && !root.loading
          text: root.filter === "pending" ? "Nothing queued." : "No themes match."
          color: Theme.faint
        }
      }

      // --------------------------------------------------------------- backups
      ListView {
        id: backupList
        visible: root.tab === "backups"
        anchors { top: header.bottom; left: parent.left; right: parent.right; bottom: footer.top }
        clip: true
        model: root.visibleBackups
        boundsBehavior: Flickable.StopAtBounds
        opacity: root.locked ? 0.55 : 1
        ScrollBar.vertical: ScrollBar {}
        delegate: Rectangle {
          id: bRow
          required property var modelData
          readonly property var b: modelData
          readonly property string action: root.backupAction(b)
          width: backupList.width
          height: bCol.implicitHeight + Theme.px(18)
          color: action ? Theme.a(action === "delete" ? Theme.red : Theme.accent, 0.07) : bMa.containsMouse ? Theme.a(Theme.fg, 0.03) : "transparent"
          MouseArea { id: bMa; anchors.fill: parent; hoverEnabled: true; acceptedButtons: Qt.NoButton }
          Rectangle { visible: bRow.action !== ""; width: 3; height: parent.height; color: bRow.action === "delete" ? Theme.red : Theme.accent }
          Column {
            id: bCol
            anchors { left: parent.left; right: bButtons.left; verticalCenter: parent.verticalCenter; leftMargin: Theme.px(14); rightMargin: Theme.px(12) }
            spacing: Theme.px(3)
            Row {
              spacing: Theme.px(8)
              Txt { text: bRow.b.title; font.bold: true; font.strikeout: bRow.action === "delete"; color: bRow.action === "delete" ? Theme.faint : Theme.fg }
              Txt { text: bRow.b.name !== bRow.b.title ? bRow.b.name : ""; color: Theme.faint; font.pixelSize: Theme.fsSmall; height: Theme.px(18) }
            }
            Flow {
              width: parent.width
              spacing: Theme.px(5)
              Chip { text: bRow.b.kind === "theme" ? "theme" : "plugin"; tone: Theme.blue }
              Chip { text: "removed " + bRow.b.date; tone: Theme.muted }
              Chip { text: root.fmtSize(bRow.b.size); tone: Theme.muted }
              Chip { visible: bRow.b.installed; text: "installed again since"; tone: Theme.yellow }
              Txt {
                visible: bRow.action !== ""
                text: "→ " + (bRow.action === "restore" ? "will be restored" : "will be deleted for good")
                color: bRow.action === "delete" ? Theme.red : Theme.accent
                font.pixelSize: Theme.fsSmall
              }
            }
          }
          Row {
            id: bButtons
            anchors { right: parent.right; verticalCenter: parent.verticalCenter; rightMargin: Theme.px(14) }
            spacing: Theme.px(8)
            Btn {
              text: "Restore"
              active: bRow.action === "restore"
              opacity: bRow.b.installed ? 0.35 : 1
              tip: bRow.b.installed ? "Uninstall the one installed now first" : "Put it back where it was"
              onClicked: root.setBackupAction(bRow.b, "restore")
            }
            Btn {
              text: "Delete"
              active: bRow.action === "delete"
              textColor: bRow.action === "delete" ? Theme.accent : Theme.red
              tip: "Delete this backup permanently"
              onClicked: root.setBackupAction(bRow.b, "delete")
            }
          }
          Rectangle { anchors.bottom: parent.bottom; width: parent.width; height: 1; color: Theme.divider }
        }
        Txt {
          anchors.centerIn: parent
          visible: backupList.count === 0 && !root.loading
          text: root.filter === "pending" ? "Nothing queued." : root.backups.length ? "No backups match." : "No backups. Uninstalled themes, and plugins that aren't git checkouts, leave one here."
          color: Theme.faint
        }
      }

      // ---------------------------------------------------------------- footer
      Rectangle {
        id: footer
        anchors { left: parent.left; right: parent.right; bottom: parent.bottom }
        height: Theme.px(52)
        color: root.pendingCount ? Theme.a(Theme.accent, 0.08) : Theme.a(Theme.fg, 0.02)
        Rectangle { width: parent.width; height: 1; color: Theme.divider }
        Txt {
          anchors { left: parent.left; leftMargin: Theme.px(14); verticalCenter: parent.verticalCenter; right: footerBtns.left; rightMargin: Theme.px(12) }
          text: root.pendingCount
                ? root.pendingCount + " change" + (root.pendingCount === 1 ? "" : "s") + " queued — nothing happens until you apply"
                : root.tab === "backups"
                  ? "Restore puts a theme or plugin back; Delete removes its backup for good. Nothing changes until you apply."
                : root.tab === "themes"
                  ? "Pick a theme to use and any to uninstall; nothing changes until you apply. Uninstalled themes are backed up first."
                  : "Pick changes below; they're queued, then applied together (the bar reloads once per change while it runs)."
          color: root.pendingCount ? Theme.fg : Theme.faint
        }
        Row {
          id: footerBtns
          anchors { right: parent.right; rightMargin: Theme.px(14); verticalCenter: parent.verticalCenter }
          spacing: Theme.px(8)
          Btn { text: "Show queue"; visible: root.pendingCount > 0 && root.filter !== "pending"; onClicked: root.filter = "pending" }
          Btn { text: "Discard"; visible: root.pendingCount > 0; onClicked: root.discard() }
          Btn {
            text: "Apply changes"
            active: root.pendingCount > 0
            opacity: root.pendingCount > 0 && !root.busy ? 1 : 0.4
            onClicked: if (root.pendingCount > 0 && !root.busy) root.startApply()
          }
        }
      }

      // --------------------------------------------------------------- dialogs
      Rectangle {
        anchors.fill: parent
        visible: root.confirmOpen || root.progressOpen || root.wallpaperTheme !== null
        color: Theme.a(Theme.bg, 0.75)
        MouseArea { anchors.fill: parent }
      }

      Rectangle {
        id: confirm
        visible: root.confirmOpen
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.px(80), Theme.px(640))
        height: Math.min(parent.height - Theme.px(80), confirmCol.implicitHeight + Theme.px(32))
        color: Theme.bg
        border.color: Theme.border
        Flickable {
          anchors.fill: parent; anchors.margins: Theme.px(16)
          contentHeight: confirmCol.implicitHeight
          clip: true
          Column {
            id: confirmCol
            width: parent.width
            spacing: Theme.px(10)
            Txt { text: "Apply " + root.ops().length + " changes?"; font.pixelSize: Theme.fsLarge; font.bold: true }
            Txt {
              visible: root.checking
              text: "Checking what's being uninstalled for local work…"
              color: Theme.faint
            }
            Repeater {
              model: root.confirmOpen ? root.ops() : []
              Column {
                required property var modelData
                readonly property var info: root.removalInfo[modelData.id] || null
                readonly property var p: root.byId(modelData.id)
                width: confirmCol.width
                spacing: Theme.px(2)
                Txt { text: "• " + root.describe(modelData); color: modelData.op === "remove" || modelData.op === "theme-remove" || modelData.op === "backup-delete" ? Theme.red : Theme.fg; width: parent.width }
                Txt {
                  visible: !!(parent.info && parent.info.warning)
                  text: "   ⚠ " + (parent.info ? parent.info.warning : "")
                  color: Theme.yellow; wrapMode: Text.Wrap; width: parent.width
                }
                Txt {
                  visible: !!(parent.info && parent.info.note)
                  text: "   " + (parent.info ? parent.info.note : "")
                  color: Theme.faint; font.pixelSize: Theme.fsSmall; wrapMode: Text.Wrap; width: parent.width
                }
                Txt {
                  readonly property int hosted: modelData.op === "remove" ? root.plugins.filter(function (x) { return x.host === modelData.id }).length : 0
                  visible: hosted > 0
                  text: "   ⚠ it hosts " + hosted + " drawer widget(s), which will disappear with it"
                  color: Theme.yellow; wrapMode: Text.Wrap; width: parent.width
                }
                Txt {
                  visible: modelData.op === "remove" && !!parent.p && parent.p.host !== ""
                  text: "   taken out of the tray drawer first"
                  color: Theme.faint; font.pixelSize: Theme.fsSmall
                }
                Txt {
                  // `omarchy plugin remove` restores the original only for an enabled clone.
                  readonly property var orig: modelData.op === "remove" && parent.p && parent.p.clonedFrom && parent.p.enabled ? root.byId(parent.p.clonedFrom) : null
                  visible: !!orig
                  text: "   Omarchy's own " + (orig ? orig.name : "") + " comes back in its place"
                  color: Theme.faint; font.pixelSize: Theme.fsSmall; wrapMode: Text.Wrap; width: parent.width
                }
                Txt {
                  readonly property var th: modelData.op === "theme-remove" ? root.themeByName(modelData.name) : null
                  readonly property var kept: th ? root.bundledInstalled(th).filter(function (b) { return !(root.pending[b.id] && root.pending[b.id].remove) }) : []
                  visible: kept.length > 0
                  text: "   ⚠ " + kept.length + " plugin" + (kept.length === 1 ? "" : "s") + " that came with it stay" + (kept.length === 1 ? "s" : "") + " installed: "
                        + kept.slice(0, 4).map(function (b) { return b.name }).join(", ") + (kept.length > 4 ? "…" : "")
                  color: Theme.yellow; wrapMode: Text.Wrap; width: parent.width
                }
                Txt {
                  visible: modelData.op === "backup-delete"
                  text: "   ⚠ this can't be undone"
                  color: Theme.yellow; font.pixelSize: Theme.fsSmall
                }
                Txt {
                  visible: modelData.op === "backup-restore"
                  text: modelData.kind === "plugin" ? "   comes back off the bar; place it from the Plugins tab" : "   back in the Themes tab, ready to use"
                  color: Theme.faint; font.pixelSize: Theme.fsSmall
                }
                Txt {
                  readonly property var th: modelData.op === "theme-remove" ? root.themeByName(modelData.name) : null
                  visible: !!(th && th.myWallpapers)
                  text: "   your own wallpapers for it in " + (th ? th.myWallpapers.replace(/^\/home\/[^/]+/, "~") : "") + " are kept"
                  color: Theme.faint; font.pixelSize: Theme.fsSmall; wrapMode: Text.Wrap; width: parent.width
                }
              }
            }
            Row {
              anchors.right: parent.right
              spacing: Theme.px(8)
              Btn { text: "Back"; onClicked: root.confirmOpen = false }
              Btn {
                text: root.checking ? "Checking…" : "Apply"
                active: !root.checking
                opacity: root.checking ? 0.4 : 1
                onClicked: if (!root.checking) root.run(root.ops())
              }
            }
          }
        }
      }

      Rectangle {
        id: picker
        visible: root.wallpaperTheme !== null
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.px(60), Theme.px(900))
        height: Math.min(parent.height - Theme.px(60), pickerHint.y + pickerHint.height + wpGrid.contentHeight + Theme.px(40))
        color: Theme.bg
        border.color: Theme.border
        readonly property var t: root.wallpaperTheme || ({ wallpapers: [], title: "" })
        Txt {
          id: pickerTitle
          anchors { left: parent.left; top: parent.top; margins: Theme.px(16) }
          text: "Wallpaper for " + picker.t.title
          font.pixelSize: Theme.fsLarge; font.bold: true
        }
        Txt {
          id: pickerHint
          anchors { left: parent.left; top: pickerTitle.bottom; topMargin: Theme.px(4); leftMargin: Theme.px(16) }
          text: root.chosenWallpaper(picker.t) ? "Applied with the rest of the queue."
                : "Leave it unpicked and Omarchy shows the theme's first wallpaper."
          color: Theme.faint; font.pixelSize: Theme.fsSmall
        }
        Btn {
          anchors { right: parent.right; top: parent.top; margins: Theme.px(12) }
          text: "Done"
          onClicked: root.wallpaperTheme = null
        }
        GridView {
          id: wpGrid
          anchors { left: parent.left; right: parent.right; top: pickerHint.bottom; bottom: parent.bottom; margins: Theme.px(12) }
          clip: true
          model: picker.visible ? picker.t.wallpapers : []
          readonly property int cols: Math.max(1, Math.floor(width / Theme.px(210)))
          cellWidth: Math.floor(width / cols)
          cellHeight: cellWidth * 0.5625 + Theme.px(30)
          ScrollBar.vertical: ScrollBar {}
          delegate: Item {
            required property var modelData
            readonly property bool chosen: root.chosenWallpaper(picker.t) === modelData.name
            width: wpGrid.cellWidth; height: wpGrid.cellHeight
            Rectangle {
              anchors.fill: parent; anchors.margins: Theme.px(5)
              color: Theme.normalFill
              border.width: parent.chosen ? 2 : 1
              border.color: parent.chosen ? Theme.accent : Theme.a(Theme.fg, 0.14)
              Image {
                anchors { left: parent.left; right: parent.right; top: parent.top; margins: Theme.px(4) }
                height: width * 0.5625
                source: "file://" + parent.parent.modelData.path
                sourceSize.width: Theme.px(400)
                fillMode: Image.PreserveAspectCrop
                asynchronous: true; cache: false
              }
              Txt {
                anchors { left: parent.left; right: parent.right; bottom: parent.bottom; margins: Theme.px(6) }
                text: (parent.parent.chosen ? "✓ " : "") + parent.parent.modelData.name + (parent.parent.modelData.mine ? "  (yours)" : "")
                color: parent.parent.chosen ? Theme.accent : Theme.faint; font.pixelSize: Theme.fsSmall
              }
              MouseArea {
                anchors.fill: parent; cursorShape: Qt.PointingHandCursor
                onClicked: root.chooseWallpaper(picker.t, parent.parent.modelData)
              }
            }
          }
        }
      }

      Rectangle {
        visible: root.progressOpen
        anchors.centerIn: parent
        width: Math.min(parent.width - Theme.px(80), Theme.px(680))
        height: Math.min(parent.height - Theme.px(80), progCol.implicitHeight + Theme.px(32))
        color: Theme.bg
        border.color: Theme.border
        Flickable {
          anchors.fill: parent; anchors.margins: Theme.px(16)
          contentHeight: progCol.implicitHeight
          clip: true
          Column {
            id: progCol
            width: parent.width
            spacing: Theme.px(8)
            Txt {
              text: root.busy ? "Applying…" : (root.progressSummary || "Finished")
              font.pixelSize: Theme.fsLarge; font.bold: true
            }
            Repeater {
              model: root.progress
              Column {
                required property var modelData
                width: progCol.width
                Txt {
                  width: parent.width
                  text: ({ queued: "○", running: "▸", ok: "✓", error: "✗" }[modelData.status] || "·") + "  " + root.describe(modelData)
                  color: modelData.status === "error" ? Theme.red : modelData.status === "ok" ? Theme.green
                       : modelData.status === "running" ? Theme.accent : Theme.faint
                }
                Txt {
                  visible: modelData.msg !== "" && (modelData.status !== "ok" || modelData.op === "theme-remove" || modelData.op === "backup-restore")
                  width: parent.width
                  text: "    " + modelData.msg
                  color: Theme.faint; font.pixelSize: Theme.fsSmall; wrapMode: Text.Wrap; elide: Text.ElideNone
                }
              }
            }
            Txt {
              visible: !root.busy
              text: "Log: ~/.local/state/plugboard/apply.log"
              color: Theme.faint; font.pixelSize: Theme.fsSmall
            }
            Btn {
              anchors.right: parent.right
              visible: !root.busy
              text: "Close"
              onClicked: root.progressOpen = false
            }
          }
        }
      }
    }
  }
}
