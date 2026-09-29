import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import Quickshell.Widgets
import qs.Commons
import qs.Ui

import "Model.js" as Model

Item {
  id: root

  property var shell: null
  property var manifest: null
  property bool closingFromHost: false
  readonly property bool opened: window.visible

  // shell-theme-aware palette
  readonly property color fg: Color.foreground
  readonly property color dim: Qt.darker(fg, 1.5)
  readonly property color faint: Qt.darker(fg, 2.2)
  readonly property color okC: "#8fd08a"
  readonly property color errC: "#e74c5b"
  readonly property string mono: Style.font.family

  // ---- data
  property var db: null                 // { base, fetchedAt, count, entries: [...] }
  property var filtered: []             // indexes into db.entries passing the filters
  property var facets: ({ tone: {}, color: {}, resMin: {}, resMax: {} })
  property string q: ""
  property string tone: ""
  property string color: ""
  property string resMin: ""
  property string resMax: ""
  property var crumbs: []

  property int phase: 0                 // 0 loading, 1 ready, 2 error
  property string phaseMsg: ""
  property string currentTheme: ""

  // ---- detail (variant picker)
  property int detailIdx: -1
  property string detailPath: ""
  property int detailVariant: 0
  property var detailVariants: []
  property int applyPhase: 0            // 0 none, 1 installing, 2 setting, 3 done, 4 error
  property string applySlug: ""
  property string applyMsg: ""
  property int cursorIdx: 0

  // ---- single-flight operation state ----
  // Only one apply/wallpaper operation may run at a time; UI entry points are
  // gated on operationBusy so a fast user can never start a second install
  // while one is in flight (which used to let an unstable slug win).
  readonly property bool operationBusy:
    applyProc.running || wallpaperProc.running || themeSetProc.running
    || root.themeSetCycleActive || root.activationPending
  property string operationKind: ""     // "" | "theme" | "wallpaper"
  property bool pendingForce: false
  property bool fetchExitSeen: false
  property bool fetchStreamSeen: false
  property bool fetchExpectedStop: false
  readonly property bool fetchSettling:
    root.fetchExitSeen !== root.fetchStreamSeen
    || (root.fetchExpectedStop && (!root.fetchExitSeen || !root.fetchStreamSeen))
  property string applyWarn: ""
  property string themeSetError: ""
  property bool themeSetCycleActive: false
  property bool themeSetExitSeen: false
  property bool themeSetStderrSeen: false
  property int themeSetExitCode: -1
  property bool activationPending: false
  property int activateCheckCount: 0

  readonly property bool hasActiveFilters:
    q !== "" || tone !== "" || color !== "" || resMin !== "" || resMax !== ""
  // ---- auto random + wallpaper-only
  property bool wallpaperOnly: false
  property int autoIntervalSec: 0 // 0=Off, 300=5m, 900=15m, 1800=30m, 3600=60m
  readonly property var autoOptions: [0, 300, 900, 1800, 3600]
  readonly property var autoLabels: ["Off", "5m", "15m", "30m", "60m"]
  readonly property string modeLabel:
    applyPhase > 0 ? "APPLY" :
    detailPath !== "" ? "VIEW" : "BROWSE"
  readonly property int gridCols: Math.max(2, Math.floor(gridView.width / Style.space(200)))

  function scriptPath(name) {
    var u = String(Qt.resolvedUrl("bin/" + name))
    if (u.startsWith("file://")) return u.substring(7)
    return u
  }
  function baseOf() { return db ? String(db.base || "") : "" }
  // Builds a media URL. Both parts are validate-it-early: `base` comes from
  // the manifest (https + allowlisted host) and rel must be a safe relative
  // path — anything else yields "" so Image/Process never see it.
  function safeRel(rel) {
    // Mirrors _sec.safe_relpath: '..' and '.' are rejected as path components,
    // not substrings, so file names like "img..jpg" still load. Trailing slash
    // and "//" are also rejected (would make Image/Process hit a directory).
    var s = String(rel || "")
    return s.length <= 512 && /^[A-Za-z0-9_./+@=~-]+$/.test(s)
      && !s.startsWith("/") && !s.startsWith("\\")
      && s.split("/").indexOf("..") === -1 && s.split("/").indexOf(".") === -1
      && s.indexOf(":") === -1 && !s.endsWith("/") && s.indexOf("//") === -1
  }
  function url(rel) {
    var b = baseOf()
    if (!b || !/^https:\/\/[A-Za-z0-9.-]+\//.test(b + "/")) return ""
    if (!root.safeRel(rel)) return ""
    return b + "/" + String(rel).replace(/^\/+/, "")
  }
  function entryAt(i) { return db && db.entries ? db.entries[i] : null }

  function setQuery(text) {
    root.q = String(text || "")
    qTimer.restart()
  }

  function buildCrumbs() {
    var c = []
    if (root.q) c.push({ key: "search", label: "q:\u0022" + root.q + "\u0022" })
    if (root.tone) c.push({ key: "tone", label: "tone:" + root.tone })
    if (root.color) c.push({ key: "color", label: "color:" + root.color })
    if (root.resMin || root.resMax) {
      var v
      if (root.resMin && root.resMax) v = "res:" + root.resMin + ".." + root.resMax
      else if (root.resMin) v = "res:\u2265" + root.resMin
      else v = "res:\u2264" + root.resMax
      c.push({ key: "res", label: v })
    }
    root.crumbs = c
  }

  function refreshFilters() {
    if (!root.db) return
    var res = Model.apply(root.db.entries, root.q, root.tone, root.color,
                          root.resMin, root.resMax)
    root.filtered = res.filtered
    root.facets = res.facets
    if (root.cursorIdx >= res.filtered.length)
      root.cursorIdx = Math.max(0, res.filtered.length - 1)
    root.buildCrumbs()
  }

  function toggleFacet(key, value) {
    if (key === "tone") root.tone = (root.tone === value) ? "" : value
    else if (key === "color") root.color = (root.color === value) ? "" : value
    else if (key === "res-min") root.resMin = (root.resMin === value) ? "" : value
    else if (key === "res-max") root.resMax = (root.resMax === value) ? "" : value
    root.refreshFilters()
  }

  function clearCrumb(key) {
    if (key === "search") { root.q = ""; searchField.text = "" }
    else if (key === "tone") root.tone = ""
    else if (key === "color") root.color = ""
    else if (key === "res") { root.resMin = ""; root.resMax = "" }
    root.refreshFilters()
  }

  function resetFilters() {
    root.tone = ""
    root.color = ""
    root.resMin = ""
    root.resMax = ""
    root.q = ""
    searchField.text = ""
    root.refreshFilters()
  }

  function startLoad(force) {
    if (fetchProc.running || root.fetchSettling) {
      // Queue the forced replacement, but never reuse the Process until both
      // exit and buffered-stream completion from the old generation arrived.
      if (force) root.pendingForce = true
      return
    }
    root.fetchExitSeen = false
    root.fetchStreamSeen = false
    root.fetchExpectedStop = false
    root.phase = 0
    root.phaseMsg = force ? "re-fetching index (35 MB)\u2026" : "loading index\u2026"
    var sc=root.scriptPath("fetch-manifest.py")
    fetchProc.command = ["python3", sc].concat(force ? ["--force"] : [])
    fetchWatchdog.start()
    fetchProc.running = true
  }

  function finishFetchCycle() {
    if (!root.fetchExitSeen || !root.fetchStreamSeen) return
    root.fetchExpectedStop = false
    if (root.pendingForce) {
      root.pendingForce = false
      root.startLoad(true)
    }
  }

  function handleFetchOutput(text) {
    fetchWatchdog.stop()
    root.fetchStreamSeen = true
    if (root.fetchExpectedStop) {
      root.finishFetchCycle()
      return
    }
    var j = null
    try { j = JSON.parse(text) } catch (e) { j = null }
    if (!j || j.error || !j.entries) {
      root.phase = 2
      root.phaseMsg = (j && j.error) ? String(j.error) : "bad manifest"
      root.finishFetchCycle()
      return
    }
    root.db = j
    Model.prep(j.entries)
    root.phase = 1
    root.phaseMsg = ""
    root.cursorIdx = 0
    root.refreshFilters()
    root.loadCurrentTheme()
    root.finishFetchCycle()
  }

  function loadCurrentTheme() {
    if (themeCurProc.running) return
    themeCurProc.command = ["omarchy", "theme", "current"]
    themeCurProc.running = true
  }

  function currentThemeSlug() {
    return Model.slugFromThemeCurrent(root.currentTheme)
  }

  function moveCursor(dx, dy) {
    var n = root.filtered.length
    if (!root.db || !n) return
    if (root.cursorIdx < 0) root.cursorIdx = 0
    if (root.cursorIdx >= n) root.cursorIdx = n - 1
    var cols = root.gridCols
    var row = Math.floor(root.cursorIdx / cols)
    var col = root.cursorIdx % cols
    var lastRow = Math.floor((n - 1) / cols)
    if (dy > 0) {
      row = Math.min(lastRow, row + 1)
      col = Math.min(col, (n - 1) - row * cols)
    } else if (dy < 0) {
      row = Math.max(0, row - 1)
      col = Math.min(col, (n - 1) - row * cols)
    } else if (dx > 0) {
      col = Math.min(cols - 1, col + 1)
    } else if (dx < 0) {
      col = Math.max(0, col - 1)
    }
    root.cursorIdx = Math.max(0, Math.min(n - 1, row * cols + col))
    gridView.positionViewAtIndex(root.cursorIdx, GridView.Contain)
  }

  function openDetailAt(pos) {
    if (!root.db || !root.filtered.length) return
    pos = Math.max(0, Math.min(root.filtered.length - 1, Math.max(0, pos)))
    var full = root.filtered[pos]
    var e = root.db.entries[full]
    root.detailIdx = full
    root.detailPath = e.p
    root.detailVariants = Model.variantsOf(e)
    root.detailVariant = 0
    // Only reset the apply feedback when nothing is in flight.
    if (!root.operationBusy) {
      root.applyPhase = 0
      root.applyMsg = ""
      root.applyWarn = ""
    }
  }

  function closeDetail() {
    root.detailIdx = -1
    root.detailPath = ""
    root.detailVariants = []
    // Keep an in-flight operation's state visible so closing the detail view
    // cannot make a running apply look like it was cancelled.
    if (!root.operationBusy) {
      root.applyPhase = 0
      root.applyMsg = ""
      root.applyWarn = ""
    }
  }

  function detailNav(delta) {
    if (!root.db || !root.filtered.length) return
    var pos = root.filtered.indexOf(root.detailIdx)
    if (pos < 0) pos = 0
    pos = (pos + delta + root.filtered.length) % root.filtered.length
    root.openDetailAt(pos)
  }

  function cycleVariant(d) {
    var n = root.detailVariants.length
    if (!n) return
    root.detailVariant = ((root.detailVariant + d) % n + n) % n
  }

  function applySelected() {
    if (root.operationBusy || root.applyPhase === 1 || root.applyPhase === 2) return
    var vs = root.detailVariants
    if (!vs.length) return
    var v = vs[root.detailVariant % vs.length]
    if (!v.n || !root.baseOf() || (!root.wallpaperOnly && !v.ct)) {
      root.applyPhase = 4
      root.applyMsg = "missing apply data in index"
      return
    }
    if (!root.safeSlug(v.n)) {
      root.applyPhase = 4
      root.applyMsg = "theme name is not a safe slug"
      return
    }
    root.applySlug = v.n
    root.applyWarn = ""
    root.applyPhase = 1
    root.applyMsg = "downloading " + v.n
    var e = (root.db && root.detailIdx >= 0) ? root.db.entries[root.detailIdx] : null
    // Full-res original as the fallback background (med is a downscaled copy).
    var fallbackP = e ? (e.p || "") : ""
    // wallpaper-only: set image directly, no theme
    if (root.wallpaperOnly) {
      var rel = e ? (e.med || e.p || v.bg || "") : (v.bg || "")
      if (!rel) { root.applyPhase = 4; root.applyMsg = "missing wallpaper"; return }
      root.applySlug = v.n
      root.applyPhase = 1
      root.applyMsg = "setting wallpaper…"
      root.operationKind = "wallpaper"
      wallpaperProc.command = ["timeout", "340", "python3", root.scriptPath("set-wallpaper.py"), root.baseOf(), rel]
      wallpaperProc.running = true
      return
    }
    root.operationKind = "theme"
    applyProc.command = ["timeout", "700", "python3", root.scriptPath("apply-theme.py"),
                         v.n, root.baseOf(), v.ct, v.bg, fallbackP].slice()
    applyProc.running = true
  }

  function applicableThemeVariants(entry) {
    var all = Model.variantsOf(entry)
    var out = []
    for (var i = 0; i < all.length; i++) {
      if (all[i].n && all[i].ct && root.safeSlug(all[i].n)) out.push(all[i])
    }
    return out
  }

  function applyRandom() {
    if (!db || !filtered.length) return
    if (root.operationBusy) return
    // Pick a wallpaper that can actually be applied so shuffle/AUTO never
    // silently no-ops on an entry that lacks a variant or media path.
    var cands = []
    if (wallpaperOnly) {
      for (var i = 0; i < filtered.length; i++) {
        var e = db.entries[filtered[i]]
        if (e && (e.med || e.p)) cands.push(filtered[i])
      }
      if (!cands.length) {
        applyPhase = 4; applyMsg = "no wallpaper available in current filter"
        return
      }
      var full = cands[Math.floor(Math.random() * cands.length)]
      var ee = db.entries[full]
      var rel = ee.med || ee.p
      // show in detail briefly then apply
      detailIdx = full; detailPath = ee.p; detailVariants = Model.variantsOf(ee); detailVariant = 0
      applyWallpaper(rel)
    } else {
      for (var j = 0; j < filtered.length; j++) {
        var ej = db.entries[filtered[j]]
        if (ej && root.applicableThemeVariants(ej).length) cands.push(filtered[j])
      }
      if (!cands.length) {
        applyPhase = 4; applyMsg = "no theme variants in current filter"
        return
      }
      var f2 = cands[Math.floor(Math.random() * cands.length)]
      var e2 = db.entries[f2]
      var vs2 = root.applicableThemeVariants(e2)
      var v2 = vs2[Math.floor(Math.random() * vs2.length)]
      detailIdx = f2; detailPath = e2.p; detailVariants = vs2; detailVariant = vs2.indexOf(v2)
      applySelected()
    }
  }
  function applyWallpaper(rel) {
    if (!rel || !baseOf()) return
    if (root.operationBusy) return
    applyPhase = 1; applyMsg = "setting wallpaper…"; applyWarn = ""
    root.operationKind = "wallpaper"
    wallpaperProc.command = ["timeout", "340", "python3", root.scriptPath("set-wallpaper.py"), baseOf(), rel]
    wallpaperProc.running = true
  }
  function setAutoInterval(sec) { autoIntervalSec = sec }
  // Label of the currently selected AUTO step ("Off"/"5m"/…), from the
  // parallel autoOptions/autoLabels arrays.
  function autoSelLabel() {
    var i = root.autoOptions.indexOf(root.autoIntervalSec)
    return i >= 0 ? root.autoLabels[i] : "Off"
  }

  // Slug validation: theme names come from the remote index and are passed as
  // argv to `omarchy theme set`. Only lowercase slugs with [a-z0-9._-] are
  // allowed; '..' is rejected as a substring (mirrors _sec.safe_slug).
  function safeSlug(s) {
    s = String(s || "")
    return /^[a-z0-9][a-z0-9._-]*$/.test(s) && s.indexOf("..") === -1 && s.length <= 256
  }

  onOpenedChanged: {
    if (opened) {
      root.startLoad(false)
      root.loadCurrentTheme()
    }
  }
  // keepLoaded keeps this mounted while the window is closed, so AUTO keeps firing.
  function open(payloadJson) {
    closingFromHost = false
    window.visible = true
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }
  function close() {
    closingFromHost = true
    window.visible = false
    closingFromHost = false
  }
  function toggle() { opened ? requestClose() : open() }
  function requestClose() {
    if (shell && typeof shell.hide === "function") shell.hide("sumiran.theme-gallery")
    else close()
  }

  IpcHandler {
    target: "sumiran.theme-gallery"
    function open(): string { root.open(); return "ok" }
    function close(): string { root.requestClose(); return "ok" }
    function toggle(): string { root.toggle(); return "ok" }
  }

  Component.onCompleted: {
    desktopEntryProc.running = true
    if (opened) {
      root.startLoad(false)
      root.loadCurrentTheme()
    }
  }

  // ---- processes ----------------------------------------------------------

  Process {
    id: fetchProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: root.handleFetchOutput(String(text || ""))
    }
    onExited: function(exitCode) {
      root.fetchExitSeen = true
      if (!root.fetchExpectedStop && exitCode !== 0 && root.phase === 0) {
        root.phase = 2
        root.phaseMsg = "index fetch failed (exit " + exitCode + ")"
      }
      root.finishFetchCycle()
    }
  }

  Timer {
    id: fetchWatchdog
    interval: 180000
    repeat: false
    onTriggered: {
      if (root.phase === 0) {
        // Ignore buffered output from the canceled generation and keep retries
        // queued until both exit and stream-finished callbacks have settled.
        root.fetchExpectedStop = true
        fetchProc.running = false
        root.phase = 2
        root.phaseMsg = "fetch timed out \u2014 the 35 MB index is unreachable"
      }
    }
  }

  Timer {
    id: qTimer
    interval: 150
    repeat: false
    onTriggered: root.refreshFilters()
  }
  Timer {
    id: autoTimer
    interval: root.autoIntervalSec * 1000
    repeat: true
    running: root.autoIntervalSec > 0 && root.db !== null && root.filtered.length > 0
    onTriggered: root.applyRandom()
  }

  function finishThemeSetCycle() {
    if (!root.themeSetCycleActive || !root.themeSetExitSeen || !root.themeSetStderrSeen) return
    root.themeSetCycleActive = false
    if (root.themeSetExitCode === 0) {
      root.activationPending = true
      root.activateCheckCount = 0
      activateCheckTimer.start()
    } else {
      root.applyPhase = 4
      root.applyMsg = "theme activation failed (exit " + root.themeSetExitCode + ")"
        + (root.themeSetError ? ": " + root.themeSetError : "")
      root.operationKind = ""
    }
  }

  // Activate-state confirmation: after an observable successful
  // `omarchy theme set`, poll the canonical current slug.
  function evalActivation() {
    if (root.currentThemeSlug() === root.applySlug.toLowerCase()) {
      root.activationPending = false
      activateCheckTimer.stop()
      root.applyPhase = 3
      root.applyMsg = "\u2713 " + root.applySlug + (root.applyWarn ? " — background failed: " + root.applyWarn : "")
      root.operationKind = ""
    } else {
      root.activateCheckCount += 1
      if (root.activateCheckCount > 5) {
        root.activationPending = false
        activateCheckTimer.stop()
        root.applyPhase = 4
        root.applyMsg = "installed, but activation not confirmed (current: " + root.currentTheme + ")" + (root.applyWarn ? " — background failed: " + root.applyWarn : "")
        root.operationKind = ""
      } else {
        activateCheckTimer.start()
      }
    }
  }

  Process {
    id: themeCurProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.currentTheme = String(text || "").trim()
        if (root.activationPending) root.evalActivation()
      }
    }
  }

  Process {
    id: applyProc
    running: false
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: function(text) {
        try {
          var j = JSON.parse(String(text || "{}"))
          if (j && j.error) root.applyMsg = String(j.error)
          else if (j && j.warning) {
            root.applyWarn = String(j.warning)
            root.applyMsg = "colors ok, background failed: " + root.applyWarn
          }
        } catch (e) {}
      }
    }
    onExited: function(exitCode) {
      if (exitCode === 0) {
        if (!root.safeSlug(root.applySlug)) {
          root.applyPhase = 4
          root.applyMsg = "theme name is not a safe slug"
          root.operationKind = ""
          return
        }
        root.applyPhase = 2
        root.applyMsg = "activating " + root.applySlug + (root.applyWarn ? " (background failed)" : "") + "…"
        root.themeSetError = ""
        root.themeSetExitSeen = false
        root.themeSetStderrSeen = false
        root.themeSetExitCode = -1
        root.themeSetCycleActive = true
        themeSetProc.command = ["timeout", "180", "omarchy", "theme", "set", root.applySlug]
        themeSetProc.running = true
      } else {
        root.applyPhase = 4
        if (!root.applyMsg || root.applyMsg.startsWith("downloading")) root.applyMsg = "install failed" + (root.applyMsg ? ": " + root.applyMsg : "")
        root.operationKind = ""
      }
    }
  }

  Process {
    id: desktopEntryProc
    command: ["python3", root.scriptPath("desktop-entry.py")]
  }

  Process {
    id: themeSetProc
    running: false
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.themeSetError = String(text || "").trim()
        root.themeSetStderrSeen = true
        root.finishThemeSetCycle()
      }
    }
    onExited: function(exitCode) {
      root.themeSetExitCode = exitCode
      root.themeSetExitSeen = true
      root.finishThemeSetCycle()
    }
  }

  Process {
    id: wallpaperProc
    running: false
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: function(text) { try { var j=JSON.parse(String(text||"{}")); if(j&&j.error) root.applyMsg=String(j.error) } catch(e) {} } }
    onExited: function(exitCode) {
      root.operationKind = ""
      if (exitCode === 0) { root.applyPhase = 3; root.applyMsg = "\u2713 wallpaper set" }
      else { root.applyPhase = 4; if(!root.applyMsg || root.applyMsg.startsWith("setting")) root.applyMsg = "wallpaper failed (exit " + exitCode + ")" }
    }
  }
  Timer {
    id: activateCheckTimer
    interval: 2000
    repeat: false
    onTriggered: root.loadCurrentTheme()
  }

  // ---- UI ------------------------------------------------------------------
  // Tokens derive from Color/Style so the app follows theme and font changes.

  readonly property color bg: Color.background
  readonly property color accent: Color.accent
  readonly property color surface: Qt.alpha(fg, 0.045)
  readonly property color line: Qt.alpha(fg, 0.09)
  readonly property string glyphFont: "JetBrainsMono Nerd Font"
  readonly property int pad: Style.space(28)
  readonly property int gap: Style.space(20)
  readonly property int cardRadius: Style.space(14)
  readonly property int ctrlHeight: Style.space(38)

  function swatchFor(val) {
    if (val === "dark") return "#2b3040"
    if (val === "light") return "#e4e7f2"
    if (val === "monochrome") return "#9aa0ab"
    if (val === "red") return "#e74c5b"
    if (val === "orange") return "#f5994f"
    if (val === "yellow") return "#f0d869"
    if (val === "green") return "#7bbf6f"
    if (val === "cyan") return "#5ec3d0"
    if (val === "blue") return "#6d8fee"
    if (val === "purple") return "#a87cd9"
    if (val === "pink") return "#e88abf"
    return root.faint
  }
  function tierLabel(t) { return t === "<=720p" ? "≤720p" : t }
  function grouped(n) { return String(n).replace(/\B(?=(\d{3})+(?!\d))/g, ",") }

  component SectionLabel: Text {
    color: root.faint
    font.family: root.mono
    font.pointSize: Style.font.caption
    font.weight: Font.DemiBold
    font.letterSpacing: 1.6
    font.capitalization: Font.AllUppercase
  }

  component Keycap: Rectangle {
    property alias label: keyText.text
    implicitWidth: Math.max(height, keyText.implicitWidth + Style.space(12))
    implicitHeight: Style.space(20)
    radius: Style.space(5)
    color: root.surface
    border.width: 1
    border.color: root.line
    Text {
      id: keyText
      anchors.centerIn: parent
      color: root.dim
      font.family: root.mono
      font.pointSize: Style.font.caption
    }
  }

  component Hint: Row {
    property alias key: cap.label
    property alias text: hintText.text
    spacing: Style.space(6)
    Keycap { id: cap; anchors.verticalCenter: parent.verticalCenter }
    Text {
      id: hintText
      anchors.verticalCenter: parent.verticalCenter
      color: root.faint
      font.family: root.mono
      font.pointSize: Style.font.caption
    }
  }

  component IconButton: Item {
    id: ib
    property string glyph: ""
    property string tip: ""
    signal clicked()
    implicitWidth: root.ctrlHeight
    implicitHeight: root.ctrlHeight
    opacity: enabled ? 1 : 0.35
    activeFocusOnTab: true
    Rectangle {
      anchors.fill: parent
      radius: Style.space(10)
      color: ibMouse.containsMouse || ib.activeFocus ? Style.hoverFill : "transparent"
      border.width: 1
      border.color: root.line
      Behavior on color { ColorAnimation { duration: 140 } }
    }
    Text {
      anchors.centerIn: parent
      text: ib.glyph
      color: ibMouse.containsMouse ? root.fg : root.dim
      font.family: root.glyphFont
      font.pointSize: Style.font.title
      Behavior on color { ColorAnimation { duration: 140 } }
    }
    MouseArea {
      id: ibMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: ib.clicked()
    }
    PanelToolTip { visible: ibMouse.containsMouse && ib.tip !== ""; text: ib.tip }
    Keys.onReturnPressed: ib.clicked()
    Keys.onSpacePressed: ib.clicked()
    Accessible.role: Accessible.Button
    Accessible.name: ib.tip
    Accessible.onPressAction: ib.clicked()
  }

  component Segmented: Rectangle {
    id: seg
    property var labels: []
    property var tips: []
    property int current: 0
    property string accessiblePrefix: ""
    signal picked(int index)
    implicitWidth: segRow.implicitWidth + Style.space(8)
    implicitHeight: root.ctrlHeight
    radius: Style.space(10)
    color: root.surface
    border.width: 1
    border.color: root.line

    Rectangle {
      readonly property Item target: { segRep.count; return segRep.itemAt(seg.current) }
      x: target ? segRow.x + target.x : 0
      width: target ? target.width : 0
      y: Style.space(4)
      height: seg.height - Style.space(8)
      radius: Style.space(7)
      color: Style.selectedFill
      Behavior on x { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
      Behavior on width { NumberAnimation { duration: 220; easing.type: Easing.OutCubic } }
    }
    Row {
      id: segRow
      anchors.centerIn: parent
      Repeater {
        id: segRep
        model: seg.labels
        delegate: Item {
          id: segItem
          required property int index
          required property string modelData
          readonly property bool on: index === seg.current
          width: segText.implicitWidth + Style.space(24)
          height: seg.height
          activeFocusOnTab: true
          Text {
            id: segText
            anchors.centerIn: parent
            text: segItem.modelData
            color: segItem.on || segMouse.containsMouse ? root.fg : root.dim
            font.family: root.mono
            font.pointSize: Style.font.bodySmall
            font.weight: segItem.on ? Font.DemiBold : Font.Normal
            Behavior on color { ColorAnimation { duration: 140 } }
          }
          MouseArea {
            id: segMouse
            anchors.fill: parent
            hoverEnabled: true
            cursorShape: Qt.PointingHandCursor
            onClicked: seg.picked(segItem.index)
          }
          PanelToolTip { visible: segMouse.containsMouse && !!seg.tips[segItem.index]; text: seg.tips[segItem.index] || "" }
          Keys.onReturnPressed: seg.picked(segItem.index)
          Keys.onSpacePressed: seg.picked(segItem.index)
          Accessible.role: Accessible.Button
          Accessible.name: seg.accessiblePrefix + segItem.modelData
          Accessible.checked: segItem.on
          Accessible.onPressAction: seg.picked(segItem.index)
        }
      }
    }
  }

  component FacetRow: Item {
    id: fr
    property string label: ""
    property int count: 0
    property bool active: false
    signal toggled()
    width: parent ? parent.width : 0
    height: Style.space(34)
    opacity: fr.count === 0 && !fr.active ? 0.4 : 1
    activeFocusOnTab: true
    Rectangle {
      anchors.fill: parent
      radius: Style.space(9)
      color: fr.active ? Style.selectedAccentFill
        : (frMouse.containsMouse || fr.activeFocus ? Style.hoverFill : "transparent")
      Behavior on color { ColorAnimation { duration: 140 } }
    }
    Rectangle {
      id: frDot
      width: Style.space(10)
      height: width
      radius: width / 2
      color: root.swatchFor(fr.label)
      border.width: 1
      border.color: Qt.alpha(root.fg, 0.2)
      anchors.left: parent.left
      anchors.leftMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
    }
    Text {
      anchors.left: frDot.right
      anchors.leftMargin: Style.space(12)
      anchors.right: frCount.left
      anchors.rightMargin: Style.space(8)
      anchors.verticalCenter: parent.verticalCenter
      text: fr.label
      elide: Text.ElideRight
      color: fr.active ? root.fg : root.dim
      font.family: root.mono
      font.pointSize: Style.font.body
      font.weight: fr.active ? Font.DemiBold : Font.Normal
      font.capitalization: Font.Capitalize
    }
    Text {
      id: frCount
      anchors.right: parent.right
      anchors.rightMargin: Style.space(12)
      anchors.verticalCenter: parent.verticalCenter
      text: Model.formatCount(fr.count)
      color: root.faint
      font.family: root.mono
      font.pointSize: Style.font.caption
    }
    MouseArea {
      id: frMouse
      anchors.fill: parent
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: fr.toggled()
    }
    Keys.onReturnPressed: fr.toggled()
    Keys.onSpacePressed: fr.toggled()
    Accessible.role: Accessible.Button
    Accessible.name: fr.label + ", " + fr.count + " results"
    Accessible.checked: fr.active
    Accessible.onPressAction: fr.toggled()
  }

  component Chip: Rectangle {
    id: chip
    property string label: ""
    property string tip: ""
    property bool active: false
    property bool closable: false
    property bool interactive: true
    signal clicked()
    implicitWidth: chipRow.implicitWidth + Style.space(24)
    implicitHeight: Style.space(28)
    radius: height / 2
    color: chip.active ? Style.selectedAccentFill
      : (chipMouse.containsMouse || chip.activeFocus ? Style.hoverFill : root.surface)
    border.width: 1
    border.color: chip.active ? Qt.alpha(root.accent, 0.55) : root.line
    activeFocusOnTab: chip.interactive
    Behavior on color { ColorAnimation { duration: 140 } }
    Row {
      id: chipRow
      anchors.centerIn: parent
      spacing: Style.space(7)
      Text {
        anchors.verticalCenter: parent.verticalCenter
        text: chip.label
        textFormat: Text.PlainText
        color: chip.active ? root.fg : root.dim
        font.family: root.mono
        font.pointSize: Style.font.caption
      }
      Text {
        visible: chip.closable
        anchors.verticalCenter: parent.verticalCenter
        text: "×"
        color: root.faint
        font.family: root.mono
        font.pointSize: Style.font.bodySmall
      }
    }
    MouseArea {
      id: chipMouse
      anchors.fill: parent
      enabled: chip.interactive
      hoverEnabled: true
      cursorShape: Qt.PointingHandCursor
      onClicked: chip.clicked()
    }
    PanelToolTip { visible: chipMouse.containsMouse && chip.tip !== ""; text: chip.tip }
    Keys.onReturnPressed: chip.clicked()
    Keys.onSpacePressed: chip.clicked()
    Accessible.role: Accessible.Button
    Accessible.name: chip.tip || chip.label
    Accessible.checked: chip.active
    Accessible.onPressAction: chip.clicked()
  }

  // Eases mouse-wheel notches; touchpads already send smooth pixel deltas.
  component SmoothWheel: WheelHandler {
    id: sw
    required property Flickable flick
    property real goal: 0
    property NumberAnimation anim: NumberAnimation {
      target: sw.flick
      property: "contentY"
      duration: 280
      easing.type: Easing.OutCubic
    }
    target: null
    acceptedDevices: PointerDevice.Mouse
    onWheel: function(event) {
      var f = sw.flick
      var base = sw.anim.running ? sw.goal : f.contentY
      var maxY = Math.max(f.originY, f.originY + f.contentHeight - f.height)
      sw.goal = Math.max(f.originY, Math.min(maxY, base - event.angleDelta.y / 120 * Style.space(140)))
      sw.anim.to = sw.goal
      sw.anim.restart()
    }
  }

  component PaletteStrip: ClippingRectangle {
    id: strip
    property var colors: []
    radius: height / 2
    color: "transparent"
    border.width: 1
    border.color: root.line
    Row {
      anchors.fill: parent
      Repeater {
        model: strip.colors ? strip.colors.length : 0
        delegate: Rectangle {
          required property int index
          width: strip.width / strip.colors.length
          height: strip.height
          color: strip.colors[index]
        }
      }
    }
  }

  FloatingWindow {
    id: window
    title: "Themes Gallery"
    color: root.bg
    implicitWidth: Style.space(1180)
    implicitHeight: Style.space(800)
    minimumSize: Qt.size(Style.space(760), Style.space(540))
    visible: false

    // Closed by the compositor (Super+W, titlebar): sync the host's open state.
    onVisibleChanged: if (!visible && !root.closingFromHost) root.requestClose()

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      focus: true
      blocked: searchField.activeFocus
      onCloseRequested: {
        if (root.detailPath !== "") root.closeDetail()
        else root.requestClose()
      }
      onMoveRequested: function(dx, dy) {
        if (root.detailPath !== "") {
          if (dx !== 0) root.detailNav(dx > 0 ? 1 : -1)
          else if (dy !== 0) root.cycleVariant(dy > 0 ? 1 : -1)
        } else if (root.phase === 1) {
          root.moveCursor(dx, dy)
        }
      }
      onActivateRequested: {
        if (root.detailPath !== "") root.applySelected()
        else if (root.phase === 1) root.openDetailAt(root.cursorIdx)
      }
      onDeleteRequested: root.resetFilters()
      onTextKey: function(t) {
        if (t === "/" && root.detailPath === "") searchField.forceActiveFocus()
        else if ((t === "r" || t === "R") && root.detailPath === "") root.startLoad(true)
      }

      // ============================ main browse view =======================
      Item {
        id: content
        anchors.fill: parent
        anchors.margins: root.pad
        visible: root.phase === 1

        // ----------------------- header ----------------------------------
        Item {
          id: headerRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: parent.top
          height: titleCol.implicitHeight

          Column {
            id: titleCol
            anchors.left: parent.left
            anchors.right: headerActions.left
            anchors.rightMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(6)
            Text {
              text: "Themes Gallery"
              color: root.fg
              font.family: root.mono
              font.pointSize: Style.font.display
              font.weight: Font.Light
              font.letterSpacing: -0.5
            }
            Text {
              width: parent.width
              elide: Text.ElideRight
              text: (root.hasActiveFilters
                  ? root.grouped(root.filtered.length) + " of " + root.grouped(root.db ? root.db.count : 0)
                  : root.grouped(root.db ? root.db.count : 0))
                + " wallpapers · five theme variants each"
              color: root.dim
              font.family: root.mono
              font.pointSize: Style.font.bodySmall
            }
          }

          Row {
            id: headerActions
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(8)
            IconButton {
              glyph: ""
              tip: "Re-fetch the index (35 MB) · R"
              onClicked: root.startLoad(true)
            }
            IconButton {
              glyph: ""
              enabled: !root.operationBusy
              tip: root.wallpaperOnly ? "Set a random wallpaper" : "Apply a random theme"
              onClicked: root.applyRandom()
            }
          }
        }

        // ----------------------- toolbar ---------------------------------
        Item {
          id: toolbar
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: headerRow.bottom
          anchors.topMargin: Style.space(24)
          height: root.ctrlHeight

          TextField {
            id: searchField
            anchors.left: parent.left
            anchors.right: modeSeg.left
            anchors.rightMargin: Style.space(16)
            anchors.verticalCenter: parent.verticalCenter
            height: root.ctrlHeight
            leftPadding: Style.space(40)
            rightPadding: Style.space(40)
            topPadding: 0
            bottomPadding: 0
            verticalAlignment: TextInput.AlignVCenter
            color: root.fg
            font.family: root.mono
            font.pointSize: Style.font.body
            placeholderText: "Search wallpapers, palettes, tags…"
            placeholderTextColor: root.faint
            background: Rectangle {
              radius: Style.space(10)
              color: searchField.activeFocus ? Qt.alpha(root.fg, 0.07) : root.surface
              border.width: 1
              border.color: searchField.activeFocus ? Qt.alpha(root.accent, 0.7) : root.line
              Behavior on border.color { ColorAnimation { duration: 140 } }
              Behavior on color { ColorAnimation { duration: 140 } }
            }
            onTextChanged: root.setQuery(text)
            onAccepted: {
              // Flush the debounced search before opening, or Enter within the
              // 150 ms window would open the result from the previous query.
              qTimer.stop()
              root.refreshFilters()
              root.openDetailAt(root.cursorIdx)
              searchField.focus = false
              keyCatcher.forceActiveFocus()
            }
            Keys.onEscapePressed: {
              searchField.text = ""
              root.setQuery("")
              searchField.focus = false
              keyCatcher.forceActiveFocus()
            }
          }
          Text {
            anchors.left: searchField.left
            anchors.leftMargin: Style.space(15)
            anchors.verticalCenter: searchField.verticalCenter
            text: ""
            color: searchField.activeFocus ? root.fg : root.faint
            font.family: root.glyphFont
            font.pointSize: Style.font.body
          }
          Keycap {
            label: "/"
            visible: !searchField.activeFocus && searchField.text === ""
            anchors.right: searchField.right
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: searchField.verticalCenter
          }

          Segmented {
            id: modeSeg
            anchors.right: autoLabel.left
            anchors.rightMargin: Style.space(20)
            anchors.verticalCenter: parent.verticalCenter
            labels: ["Theme", "Wallpaper"]
            tips: ["Apply one-click theme variants", "Set the image only, keep your colors"]
            accessiblePrefix: "Mode "
            current: root.wallpaperOnly ? 1 : 0
            onPicked: function(index) { root.wallpaperOnly = index === 1 }
          }
          SectionLabel {
            id: autoLabel
            text: "Auto"
            anchors.right: autoSeg.left
            anchors.rightMargin: Style.space(10)
            anchors.verticalCenter: parent.verticalCenter
          }
          Segmented {
            id: autoSeg
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            labels: root.autoLabels
            tips: ["Auto-random off", "Random pick every 5 minutes", "Random pick every 15 minutes",
                   "Random pick every 30 minutes", "Random pick every hour"]
            accessiblePrefix: "Auto "
            current: Math.max(0, root.autoOptions.indexOf(root.autoIntervalSec))
            onPicked: function(index) { root.setAutoInterval(root.autoOptions[index]) }
          }
        }

        // ----------------------- active filters --------------------------
        Flow {
          id: crumbRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: toolbar.bottom
          anchors.topMargin: visible ? Style.space(16) : 0
          height: visible ? implicitHeight : 0
          visible: root.crumbs.length > 0
          spacing: Style.space(8)
          Repeater {
            model: root.crumbs
            delegate: Chip {
              required property var modelData
              label: modelData.label
              active: true
              closable: true
              tip: "Remove this filter"
              onClicked: root.clearCrumb(modelData.key)
            }
          }
          Chip {
            label: "Clear all"
            tip: "Reset all filters · Del"
            onClicked: root.resetFilters()
          }
        }

        // ----------------------- body ------------------------------------
        Item {
          id: bodyRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.top: crumbRow.bottom
          anchors.topMargin: Style.space(24)
          anchors.bottom: statusRow.top
          anchors.bottomMargin: Style.space(18)

          Flickable {
            id: filterScroll
            anchors.left: parent.left
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: Style.space(212)
            contentHeight: filterCol.implicitHeight
            boundsBehavior: Flickable.StopAtBounds
            clip: true
            SmoothWheel { flick: filterScroll }

            Column {
              id: filterCol
              width: filterScroll.width
              spacing: Style.space(2)

              SectionLabel { text: "Tone"; bottomPadding: Style.space(8); leftPadding: Style.space(12) }
              Repeater {
                model: Model.TONES
                delegate: FacetRow {
                  required property string modelData
                  label: modelData
                  active: root.tone === modelData
                  count: root.facets.tone[modelData] || 0
                  onToggled: root.toggleFacet("tone", modelData)
                }
              }

              Item { width: 1; height: Style.space(22) }
              SectionLabel { text: "Color"; bottomPadding: Style.space(8); leftPadding: Style.space(12) }
              Repeater {
                model: Model.COLOR_ORDER
                delegate: FacetRow {
                  required property string modelData
                  label: modelData
                  active: root.color === modelData
                  count: root.facets.color[modelData] || 0
                  onToggled: root.toggleFacet("color", modelData)
                }
              }

              Item { width: 1; height: Style.space(22) }
              SectionLabel { text: "Resolution"; bottomPadding: Style.space(10); leftPadding: Style.space(12) }
              Repeater {
                model: [{ key: "res-min", title: "At least", word: "at least " },
                        { key: "res-max", title: "At most", word: "at most " }]
                delegate: Column {
                  id: resGroup
                  required property var modelData
                  width: filterCol.width
                  spacing: Style.space(8)
                  bottomPadding: Style.space(12)
                  Text {
                    leftPadding: Style.space(12)
                    text: resGroup.modelData.title
                    color: root.dim
                    font.family: root.mono
                    font.pointSize: Style.font.caption
                  }
                  Flow {
                    width: parent.width
                    leftPadding: Style.space(8)
                    spacing: Style.space(6)
                    Repeater {
                      model: Model.RES_TIERS
                      delegate: Chip {
                        required property string modelData
                        readonly property bool isMin: resGroup.modelData.key === "res-min"
                        readonly property int n: (isMin ? root.facets.resMin[modelData] : root.facets.resMax[modelData]) || 0
                        label: root.tierLabel(modelData)
                        active: isMin ? root.resMin === modelData : root.resMax === modelData
                        opacity: n === 0 && !active ? 0.4 : 1
                        tip: resGroup.modelData.word + root.tierLabel(modelData) + " · " + root.grouped(n) + " wallpapers"
                        onClicked: root.toggleFacet(resGroup.modelData.key, modelData)
                      }
                    }
                  }
                }
              }
            }
          }

          Rectangle {
            id: railDivider
            anchors.left: filterScroll.right
            anchors.leftMargin: Style.space(20)
            anchors.top: parent.top
            anchors.bottom: parent.bottom
            width: 1
            color: root.line
          }

          // ----------------------- wallpaper grid -------------------------
          Item {
            id: gridArea
            anchors.left: railDivider.right
            anchors.leftMargin: Style.space(24)
            anchors.right: parent.right
            anchors.top: parent.top
            anchors.bottom: parent.bottom

            Column {
              visible: root.filtered.length === 0
              anchors.centerIn: parent
              spacing: Style.space(14)
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: ""
                color: root.faint
                font.family: root.glyphFont
                font.pointSize: Style.font.display
              }
              Text {
                anchors.horizontalCenter: parent.horizontalCenter
                text: "No wallpapers match"
                color: root.dim
                font.family: root.mono
                font.pointSize: Style.font.heading
                font.weight: Font.Light
              }
              Chip {
                anchors.horizontalCenter: parent.horizontalCenter
                visible: root.hasActiveFilters
                label: "Clear filters"
                onClicked: root.resetFilters()
              }
            }

            GridView {
              id: gridView
              // Last column's trailing gap hangs past the edge to align with the toolbar.
              anchors.fill: parent
              anchors.rightMargin: -root.gap
              model: root.filtered
              focus: false
              clip: true
              boundsBehavior: Flickable.StopAtBounds
              interactive: true
              currentIndex: root.cursorIdx
              // Prebuilt, recycled delegates: scrolling back never refetches thumbnails.
              cacheBuffer: Math.round(cellHeight * 3)
              reuseItems: true
              SmoothWheel { flick: gridView }
              cellWidth: width / root.gridCols
              cellHeight: (cellWidth - root.gap) * 10 / 16 + Style.space(64)
              delegate: Item {
                id: card
                width: gridView.cellWidth
                height: gridView.cellHeight
                required property var modelData
                required property int index
                property var entry: root.db && modelData !== undefined ? root.db.entries[modelData] : null
                readonly property bool lit: index === root.cursorIdx

                Item {
                  id: frame
                  width: card.width - root.gap
                  height: width * 10 / 16

                  Rectangle {
                    anchors.fill: parent
                    anchors.margins: -Style.space(4)
                    radius: root.cardRadius + Style.space(4)
                    color: "transparent"
                    border.width: Style.space(2)
                    border.color: root.accent
                    opacity: card.lit ? 1 : 0
                    Behavior on opacity { NumberAnimation { duration: 160 } }
                  }
                  ClippingRectangle {
                    anchors.fill: parent
                    radius: root.cardRadius
                    color: root.surface
                    Image {
                      anchors.fill: parent
                      fillMode: Image.PreserveAspectCrop
                      asynchronous: true
                      cache: true
                      sourceSize: Qt.size(Math.ceil(frame.width), Math.ceil(frame.height))
                      source: card.entry ? root.url(card.entry.thumb) : ""
                      opacity: status === Image.Ready ? 1 : 0
                      scale: card.lit ? 1.05 : 1
                      Behavior on opacity { NumberAnimation { duration: 260 } }
                      Behavior on scale { NumberAnimation { duration: 320; easing.type: Easing.OutCubic } }
                    }
                  }
                }
                Text {
                  id: cardTitle
                  anchors.top: frame.bottom
                  anchors.topMargin: Style.space(12)
                  width: frame.width
                  text: card.entry ? (card.entry.t || card.entry.p) : ""
                  textFormat: Text.PlainText
                  elide: Text.ElideRight
                  color: card.lit ? root.fg : Qt.alpha(root.fg, 0.82)
                  font.family: root.mono
                  font.pointSize: Style.font.bodySmall
                  font.weight: Font.Medium
                }
                PaletteStrip {
                  anchors.top: cardTitle.bottom
                  anchors.topMargin: Style.space(8)
                  width: Math.min(frame.width, Style.space(120))
                  height: Style.space(5)
                  colors: card.entry && card.entry.pal ? card.entry.pal.slice(0, 8) : []
                }
                MouseArea {
                  anchors.fill: parent
                  cursorShape: Qt.PointingHandCursor
                  hoverEnabled: true
                  onEntered: root.cursorIdx = card.index
                  onClicked: root.openDetailAt(card.index)
                }
              }
            }
          }
        }

        // ----------------------- status bar -------------------------------
        Item {
          id: statusRow
          anchors.left: parent.left
          anchors.right: parent.right
          anchors.bottom: parent.bottom
          height: Style.space(22)

          Row {
            id: statusLeft
            anchors.left: parent.left
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(10)
            StatusDot { anchors.verticalCenter: parent.verticalCenter }
            Text {
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, statusRow.width - statusHints.width - Style.space(40))
              elide: Text.ElideRight
              textFormat: Text.PlainText
              text: root.applyPhase !== 0 ? root.applyMsg
                : (root.currentTheme ? "Current theme · " + root.currentTheme : "Ready")
              color: root.applyPhase === 3 ? root.okC : (root.applyPhase === 4 ? root.errC : root.dim)
              font.family: root.mono
              font.pointSize: Style.font.caption
            }
          }
          Row {
            id: statusHints
            anchors.right: parent.right
            anchors.verticalCenter: parent.verticalCenter
            spacing: Style.space(16)
            visible: statusRow.width > Style.space(720)
            Hint { key: "←↑↓→"; text: "browse" }
            Hint { key: "Enter"; text: "open" }
            Hint { key: "/"; text: "search" }
            Hint { key: "Del"; text: "clear" }
          }
        }
      }

      // ============================ loading / error ========================
      Item {
        id: stateOverlay
        anchors.fill: parent
        visible: root.phase !== 1
        Column {
          anchors.centerIn: parent
          spacing: Style.space(14)
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.phase === 0 ? "" : ""
            color: root.phase === 0 ? root.dim : root.errC
            font.family: root.glyphFont
            font.pointSize: Style.font.display * 1.6
            SequentialAnimation on opacity {
              running: root.phase === 0 && stateOverlay.visible
              alwaysRunToEnd: true
              loops: Animation.Infinite
              NumberAnimation { to: 0.3; duration: 900; easing.type: Easing.InOutSine }
              NumberAnimation { to: 1; duration: 900; easing.type: Easing.InOutSine }
            }
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            text: root.phase === 0 ? "Loading the gallery" : "Gallery unavailable"
            color: root.fg
            font.family: root.mono
            font.pointSize: Style.font.heading
            font.weight: Font.Light
          }
          Text {
            anchors.horizontalCenter: parent.horizontalCenter
            width: Style.space(420)
            wrapMode: Text.WordWrap
            horizontalAlignment: Text.AlignHCenter
            text: root.phaseMsg
              || (root.phase === 0
                ? "The first run downloads the 35 MB wallpaper index, then keeps it for 24 hours."
                : "")
            color: root.faint
            font.family: root.mono
            font.pointSize: Style.font.caption
          }
          Chip {
            anchors.horizontalCenter: parent.horizontalCenter
            visible: root.phase === 2
            label: "Try again"
            active: true
            onClicked: root.startLoad(true)
          }
        }
      }

      // ============================ detail / apply =========================
      Item {
        id: detail
        anchors.fill: parent
        visible: root.detailPath !== ""
        z: 10
        property var entry: root.detailIdx >= 0 ? root.entryAt(root.detailIdx) : null

        Rectangle {
          anchors.fill: parent
          color: root.bg
        }

        Item {
          anchors.fill: parent
          anchors.margins: root.pad

          Item {
            id: detailHeader
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: parent.top
            height: root.ctrlHeight

            IconButton {
              id: backBtn
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              glyph: ""
              tip: "Back to gallery · Esc"
              onClicked: root.closeDetail()
            }
            Text {
              anchors.left: backBtn.right
              anchors.leftMargin: Style.space(16)
              anchors.right: detailNavRow.left
              anchors.rightMargin: Style.space(16)
              anchors.verticalCenter: parent.verticalCenter
              text: detail.entry ? (detail.entry.t || detail.entry.p) : ""
              textFormat: Text.PlainText
              elide: Text.ElideRight
              color: root.fg
              font.family: root.mono
              font.pointSize: Style.font.heading
              font.weight: Font.Normal
            }
            Row {
              id: detailNavRow
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(8)
              IconButton { glyph: ""; tip: "Previous wallpaper · ←"; onClicked: root.detailNav(-1) }
              IconButton { glyph: ""; tip: "Next wallpaper · →"; onClicked: root.detailNav(1) }
            }
          }

          Item {
            id: detailBody
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.top: detailHeader.bottom
            anchors.topMargin: Style.space(24)
            anchors.bottom: detailStatus.top
            anchors.bottomMargin: Style.space(18)

            ClippingRectangle {
              id: preview
              anchors.left: parent.left
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              width: Math.floor(parent.width * 0.6)
              radius: Style.space(18)
              color: root.surface
              Image {
                anchors.fill: parent
                fillMode: Image.PreserveAspectCrop
                asynchronous: true
                cache: false
                sourceSize: Qt.size(1920, 1920)
                source: detail.entry ? root.url(detail.entry.med) : ""
                opacity: status === Image.Ready ? 1 : 0
                Behavior on opacity { NumberAnimation { duration: 320 } }
              }
              Row {
                anchors.left: parent.left
                anchors.bottom: parent.bottom
                anchors.margins: Style.space(16)
                spacing: Style.space(6)
                Repeater {
                  model: detail.entry
                    ? [detail.entry.tone, detail.entry.color, detail.entry.w + " × " + detail.entry.h]
                    : []
                  delegate: Rectangle {
                    required property string modelData
                    width: metaText.implicitWidth + Style.space(20)
                    height: Style.space(26)
                    radius: height / 2
                    color: Qt.rgba(0, 0, 0, 0.55)
                    Text {
                      id: metaText
                      anchors.centerIn: parent
                      text: parent.modelData
                      textFormat: Text.PlainText
                      color: "#f2f2f2"
                      font.family: root.mono
                      font.pointSize: Style.font.caption
                      font.capitalization: Font.Capitalize
                    }
                  }
                }
              }
            }

            Flickable {
              id: sidePane
              anchors.left: preview.right
              anchors.leftMargin: Style.space(32)
              anchors.right: parent.right
              anchors.top: parent.top
              anchors.bottom: parent.bottom
              contentHeight: sideCol.implicitHeight
              boundsBehavior: Flickable.StopAtBounds
              clip: true
              SmoothWheel { flick: sidePane }

              Column {
                id: sideCol
                width: parent.width
                spacing: Style.space(12)

                SectionLabel { text: "Palette" }
                Flow {
                  width: parent.width
                  spacing: Style.space(8)
                  Repeater {
                    model: detail.entry && detail.entry.pal ? detail.entry.pal.slice(0, 12) : []
                    delegate: Rectangle {
                      required property string modelData
                      width: Style.space(32)
                      height: width
                      radius: Style.space(9)
                      color: modelData
                      border.width: 1
                      border.color: Qt.alpha(root.fg, 0.14)
                      MouseArea { id: swMouse; anchors.fill: parent; hoverEnabled: true }
                      PanelToolTip { visible: swMouse.containsMouse; text: parent.modelData }
                    }
                  }
                }

                Item { width: 1; height: Style.space(10) }
                SectionLabel { text: root.wallpaperOnly ? "Wallpaper" : "Theme variants" }

                Rectangle {
                  visible: root.wallpaperOnly
                  width: parent.width
                  height: Style.space(44)
                  radius: Style.space(12)
                  color: root.operationBusy ? Style.hoverFill : root.accent
                  Text {
                    anchors.centerIn: parent
                    text: root.operationBusy ? "Setting wallpaper…" : "Set as wallpaper"
                    color: root.operationBusy ? root.dim : root.bg
                    font.family: root.mono
                    font.pointSize: Style.font.body
                    font.weight: Font.DemiBold
                  }
                  MouseArea {
                    anchors.fill: parent
                    cursorShape: Qt.PointingHandCursor
                    onClicked: root.applySelected()
                  }
                  Accessible.role: Accessible.Button
                  Accessible.name: "Set as wallpaper"
                  Accessible.onPressAction: root.applySelected()
                }

                Repeater {
                  model: root.wallpaperOnly ? [] : root.detailVariants
                  delegate: Rectangle {
                    id: vrow
                    required property var modelData
                    required property int index
                    readonly property var v: modelData
                    readonly property bool sel: index === root.detailVariant
                    readonly property bool working:
                      (root.applyPhase === 1 || root.applyPhase === 2) && root.applySlug === v.n
                    readonly property bool isActive:
                      root.currentThemeSlug() !== ""
                      && root.currentThemeSlug() === String(v.n || "").toLowerCase()
                    width: sideCol.width
                    height: Style.space(66)
                    radius: Style.space(12)
                    color: vrow.sel ? Style.selectedAccentFill : (vMouse.containsMouse ? Style.hoverFill : root.surface)
                    border.width: 1
                    border.color: vrow.sel ? Qt.alpha(root.accent, 0.55) : root.line
                    Behavior on color { ColorAnimation { duration: 140 } }

                    MouseArea {
                      id: vMouse
                      anchors.fill: parent
                      hoverEnabled: true
                      cursorShape: Qt.PointingHandCursor
                      onClicked: root.detailVariant = vrow.index
                    }
                    Column {
                      anchors.left: parent.left
                      anchors.leftMargin: Style.space(16)
                      anchors.right: applyBtn.left
                      anchors.rightMargin: Style.space(16)
                      anchors.verticalCenter: parent.verticalCenter
                      spacing: Style.space(9)
                      Row {
                        spacing: Style.space(8)
                        Rectangle {
                          anchors.verticalCenter: parent.verticalCenter
                          width: Style.space(8)
                          height: width
                          radius: width / 2
                          color: vrow.v.hue
                        }
                        Text {
                          text: vrow.v.label
                          color: vrow.sel ? root.fg : root.dim
                          font.family: root.mono
                          font.pointSize: Style.font.body
                          font.weight: vrow.sel ? Font.DemiBold : Font.Normal
                        }
                      }
                      PaletteStrip {
                        width: parent.width
                        height: Style.space(8)
                        colors: vrow.v.c || []
                      }
                    }
                    Rectangle {
                      id: applyBtn
                      anchors.right: parent.right
                      anchors.rightMargin: Style.space(14)
                      anchors.verticalCenter: parent.verticalCenter
                      width: Style.space(96)
                      height: Style.space(34)
                      radius: Style.space(9)
                      color: vrow.working ? Style.hoverFill
                        : (vrow.isActive ? "transparent"
                          : (applyMouse.containsMouse ? Qt.lighter(root.accent, 1.12) : root.accent))
                      border.width: vrow.isActive ? 1 : 0
                      border.color: root.okC
                      Behavior on color { ColorAnimation { duration: 140 } }
                      Text {
                        anchors.centerIn: parent
                        text: vrow.working ? "Applying…" : (vrow.isActive ? "✓ Active" : "Apply")
                        color: vrow.working ? root.faint : (vrow.isActive ? root.okC : root.bg)
                        font.family: root.mono
                        font.pointSize: Style.font.bodySmall
                        font.weight: Font.DemiBold
                      }
                      MouseArea {
                        id: applyMouse
                        anchors.fill: parent
                        hoverEnabled: true
                        cursorShape: Qt.PointingHandCursor
                        onClicked: {
                          root.detailVariant = vrow.index
                          root.applySelected()
                        }
                      }
                      Accessible.role: Accessible.Button
                      Accessible.name: "Apply " + vrow.v.label
                      Accessible.onPressAction: { root.detailVariant = vrow.index; root.applySelected() }
                    }
                  }
                }

                Item { width: 1; height: Style.space(10) }
                SectionLabel {
                  text: "Tags"
                  visible: !!(detail.entry && detail.entry.tags && detail.entry.tags.length)
                }
                Flow {
                  width: parent.width
                  spacing: Style.space(6)
                  Repeater {
                    model: detail.entry && detail.entry.tags ? detail.entry.tags : []
                    delegate: Chip {
                      required property string modelData
                      label: modelData
                      interactive: false
                    }
                  }
                }
              }
            }
          }

          Item {
            id: detailStatus
            anchors.left: parent.left
            anchors.right: parent.right
            anchors.bottom: parent.bottom
            height: Style.space(22)
            Row {
              anchors.left: parent.left
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(10)
              StatusDot { anchors.verticalCenter: parent.verticalCenter }
              Text {
                anchors.verticalCenter: parent.verticalCenter
                width: Math.min(implicitWidth, detailStatus.width - detailHints.width - Style.space(40))
                elide: Text.ElideRight
                textFormat: Text.PlainText
                text: root.applyPhase !== 0 ? root.applyMsg
                  : (root.currentTheme ? "Current theme · " + root.currentTheme : "Ready")
                color: root.applyPhase === 3 ? root.okC : (root.applyPhase === 4 ? root.errC : root.dim)
                font.family: root.mono
                font.pointSize: Style.font.caption
              }
            }
            Row {
              id: detailHints
              anchors.right: parent.right
              anchors.verticalCenter: parent.verticalCenter
              spacing: Style.space(16)
              visible: detailStatus.width > Style.space(720)
              Hint { key: "←→"; text: "wallpaper" }
              Hint { key: "↑↓"; text: "variant" }
              Hint { key: "Enter"; text: "apply" }
              Hint { key: "Esc"; text: "back" }
            }
          }
        }
      }
    }
  }

  component StatusDot: Rectangle {
    width: Style.space(8)
    height: width
    radius: width / 2
    color: root.applyPhase === 3 ? root.okC
      : (root.applyPhase === 4 ? root.errC
        : (root.applyPhase === 0 ? Qt.alpha(root.fg, 0.3) : root.accent))
    SequentialAnimation on opacity {
      running: root.applyPhase === 1 || root.applyPhase === 2
      loops: Animation.Infinite
      alwaysRunToEnd: true
      NumberAnimation { to: 0.25; duration: 650; easing.type: Easing.InOutSine }
      NumberAnimation { to: 1; duration: 650; easing.type: Easing.InOutSine }
    }
  }
}
