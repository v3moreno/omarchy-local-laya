import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Display-only: every lifecycle action is a call into bin/omarchy-local-laya,
// which owns the generated systemd user unit and the persisted config.
Panel {
  id: root
  moduleName: "v3moreno.local-laya"
  ipcTarget: "v3moreno.local-laya"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string cli: String(Qt.resolvedUrl("bin/omarchy-local-laya"))
    .replace(/^file:\/\//, "")
  readonly property color theme: bar ? bar.foreground : Color.foreground
  readonly property color bg: Color.popups.background
  readonly property color urgent: bar ? bar.urgent : Color.urgent

  property var snap: ({})
  property string problem: ""
  property int menuCursor: 0
  property string expanded: ""

  readonly property bool running: snap.running === true
  readonly property bool busy: snap.active === "activating" || snap.active === "deactivating" || verb.running
  readonly property bool failed: snap.active === "failed"

  onOpenedChanged: if (opened) { menuCursor = 0; expanded = ""; refresh() }

  function refresh() { if (cli !== "" && !poll.running) poll.running = true }

  // ---- menu model ----
  // Same flat layout as omarchy-local-ai / omarchy-modes.switcher: one
  // gutter, faint caps section headers, values flush right, ✓ on the chosen
  // row, ›/⌄ on expandable rows, surface fill on the cursor row.
  readonly property string menuFont: bar && bar.fontFamily ? bar.fontFamily : Style.font.family
  readonly property color menuInk: Color.popups.text
  readonly property color menuValue: Util.alpha(Color.popups.text, 0.72)
  readonly property color menuLabel: Util.alpha(Color.popups.text, 0.48)
  readonly property color menuDanger: bar && bar.urgent ? bar.urgent : Color.urgent
  readonly property color menuSurface: Util.alpha(Color.popups.text, 0.07)
  readonly property int menuGutter: Style.space(18)
  readonly property int menuEdge: Style.space(8)
  readonly property int menuSlot: Style.space(18)
  readonly property int menuRowH: Style.space(24)
  readonly property int menuHeadH: Style.space(14)
  readonly property int menuGroupGap: Style.space(16)
  readonly property int menuTopPad: Style.space(10)

  function fmtDuration(secs) {
    secs = Math.max(0, Math.floor(secs || 0))
    if (secs < 60) return secs + "s"
    var m = Math.floor(secs / 60)
    if (m < 60) return m + "m"
    var h = Math.floor(m / 60)
    if (h < 48) return h + "h " + (m % 60) + "m"
    return Math.floor(h / 24) + "d " + (h % 24) + "h"
  }

  function stateLabel() {
    if (!snap.folderOk) return "no laya-serve"
    if (snap.active === "failed") return "failed"
    if (snap.active === "activating") return "starting…"
    if (snap.active === "deactivating") return "stopping…"
    if (snap.foreign && snap.portPid > 0)
      return "external · pid " + snap.portPid
    if (snap.running) {
      var s = snap.mode || "cpu"
      if (snap.uptime > 0) s += " · " + fmtDuration(snap.uptime)
      return s
    }
    return "stopped"
  }

  function fmtTokens(n) {
    n = n || 0
    if (n >= 1000000) return (n / 1000000).toFixed(1) + "M"
    if (n >= 1000) return (n / 1000).toFixed(1) + "k"
    return String(n)
  }

  function fmtMs(ms) {
    if (ms === null || ms === undefined) return "—"
    if (ms >= 1000) return (ms / 1000).toFixed(1) + "s"
    return Math.round(ms) + "ms"
  }

  function p50(latencies) {
    if (!Array.isArray(latencies) || latencies.length === 0) return null
    var s = latencies.slice().sort(function(a, b) { return a - b })
    return s[Math.floor((s.length - 1) / 2)]
  }

  function shortFolder() {
    var f = snap.folder || ""
    if (f === "") return "—"
    var home = Quickshell.env("HOME")
    if (home && f.indexOf(home) === 0) return "~" + f.substring(home.length)
    return f
  }

  property string gridHover: ""

  // One cell per day: a column a week, a row a weekday — 20 weeks ending
  // today, like local-ai's lifetime grid. Cell value = tokens that day.
  function gridCells() {
    var days = (snap.days && snap.days.days) || {}
    var now = new Date()
    var dow = (now.getDay() + 6) % 7  // Monday = 0
    var start = new Date(now.getFullYear(), now.getMonth(), now.getDate() - dow - 133)
    var cells = [], max = 0
    for (var i = 0; i < 140; i++) {
      var d = new Date(start.getTime() + i * 86400000)
      var key = d.getFullYear() + "-" + ("0" + (d.getMonth() + 1)).slice(-2)
        + "-" + ("0" + d.getDate()).slice(-2)
      var e = days[key]
      var c = { key: key, label: d.toDateString().slice(4, 10),
        r: e ? (e.r || 0) : 0, v: e ? ((e["in"] || 0) + (e.out || 0)) : 0,
        ms: e && e.r > 0 ? e.ms / e.r : 0 }
      if (c.v > max) max = c.v
      cells.push(c)
    }
    return { cells: cells, max: max }
  }

  function menuItems() {
    var items = [{ kind: "sec", label: "STATUS" }]
    items.push({ kind: "info", label: "state",
      value: stateLabel(), danger: failed })
    if (running || snap.health) {
      items.push({ kind: "info", label: "port", value: "127.0.0.1:" + snap.port })
      var loaded = snap.health && snap.health.loaded
      items.push({ kind: "info", label: "checkpoints",
        value: Array.isArray(loaded) ? loaded.length + " loaded" : "—" })
      if (snap.health && snap.health.device)
        items.push({ kind: "info", label: "device", value: snap.health.device })
    }
    var st = snap.stats
    if (st && st.requests > 0) {
      items.push({ kind: "info", label: "requests",
        value: st.requests + (st.errors ? " · " + st.errors + " err" : "") })
      items.push({ kind: "info", label: "tokens",
        value: fmtTokens(st.input_tokens) + " in · " + fmtTokens(st.output_tokens) + " out" })
      items.push({ kind: "info", label: "latency",
        value: fmtMs(st.last_ms) + " · p50 " + fmtMs(p50(st.latencies)) })
    }
    if (problem !== "")
      items.push({ kind: "empty", label: problem })

    var days = (snap.days && snap.days.days) || {}
    var keys = Object.keys(days)
    if (keys.length > 0) {
      var now = new Date()
      var todayKey = now.getFullYear() + "-" + ("0" + (now.getMonth() + 1)).slice(-2)
        + "-" + ("0" + now.getDate()).slice(-2)
      var today = days[todayKey]
      var req = 0, tok = 0, firstKey = keys.slice().sort()[0]
      for (var i = 0; i < keys.length; i++) {
        req += days[keys[i]].r || 0
        tok += (days[keys[i]]["in"] || 0) + (days[keys[i]].out || 0)
      }
      items.push({ kind: "sec", label: "ACTIVITY" })
      items.push({ kind: "info", label: "today",
        value: today
          ? (today.r || 0) + " req · " + fmtTokens((today["in"] || 0) + (today.out || 0)) + " tok"
          : "none yet" })
      items.push({ kind: "grid" })
      items.push({ kind: "info", label: "lifetime",
        value: gridHover !== "" ? gridHover
          : fmtTokens(req) + " req · " + fmtTokens(tok) + " tok · " + firstKey.slice(5) })
    }

    items.push({ kind: "sec", label: "CONTROL" })
    items.push({ kind: "option", id: "mode", label: "mode",
      value: snap.mode || "cpu", chevron: expanded === "mode" ? "⌄" : "›" })
    if (expanded === "mode") {
      var modes = ["cpu", "gpu"]
      for (var i = 0; i < modes.length; i++)
        items.push({ kind: "choice", id: modes[i],
          label: modes[i], chosen: (snap.mode || "cpu") === modes[i] })
    }
    items.push({ kind: "toggle", id: "autostart", label: "autostart",
      value: snap.autostart ? "on" : "off" })

    if (!snap.folderOk) {
      items.push({ kind: "empty",
        label: "set folder: omarchy-local-laya folder <path>" })
    } else if (running) {
      items.push({ kind: "action", id: "stop", label: "stop" })
      items.push({ kind: "action", id: "restart", label: "restart" })
    } else {
      items.push({ kind: "action", id: "start", label: "start", chevron: "›" })
      if (snap.foreign && snap.portPid > 0)
        items.push({ kind: "action", id: "stop", label: "stop" })
    }

    items.push({ kind: "info", label: "folder", value: shortFolder() })
    items.push({ kind: "action", id: "log", label: "open log", chevron: "›" })
    return items
  }

  readonly property var menuModel: menuItems()
  onMenuModelChanged: {
    if (menuCursor >= menuModel.length) menuCursor = menuModel.length - 1
    if (menuCursor < 0) menuCursor = 0
  }

  function isActionable(item) {
    return item && (item.kind === "option" || item.kind === "choice"
      || item.kind === "toggle" || item.kind === "action")
  }

  function moveMenuCursor(dy) {
    var items = menuModel, i = menuCursor
    for (;;) {
      var next = i + dy
      if (next < 0 || next >= items.length) break
      i = next
      if (isActionable(items[i])) break
    }
    menuCursor = i
  }

  function runVerb(args) {
    if (cli === "") return
    verb.command = [cli].concat(args)
    verb.running = true
  }

  function activateMenuItem() {
    var item = menuModel[menuCursor]
    if (!isActionable(item)) return
    switch (item.kind) {
    case "option":
      expanded = expanded === item.id ? "" : item.id
      break
    case "choice":
      runVerb(["mode", item.id])
      expanded = ""
      break
    case "toggle":
      runVerb(["autostart", snap.autostart ? "off" : "on"])
      break
    case "action":
      if (item.id === "log") { runVerb(["log"]); close() }
      else runVerb([item.id])
      break
    }
  }

  readonly property var grid: gridCells()
  readonly property int gridCell: 9
  readonly property int gridGap: 3
  readonly property int gridH: 7 * gridCell + 6 * gridGap

  function cellText(c) {
    if (!c || c.r === 0) return ""
    return c.label + " · " + c.r + " req · " + fmtTokens(c.v) + " tok"
  }

  function collapseOrClose() {
    if (expanded !== "") expanded = ""
    else close()
  }

  Process {
    id: poll
    command: [root.cli, "snapshot"]
    running: root.cli !== ""
    onExited: function(code) {
      if (code !== 0) root.problem = "snapshot failed"
      pollTimer.restart()
    }
    stdout: StdioCollector {
      onStreamFinished: {
        try { root.snap = JSON.parse(text); root.problem = "" }
        catch (e) { root.problem = "bad snapshot" }
      }
    }
  }

  Process {
    id: verb
    onExited: function(code) {
      if (code !== 0) root.problem = String(verbErr.text || "command failed").trim()
      else root.problem = ""
      root.refresh()
    }
    stderr: StdioCollector { id: verbErr }
  }

  Timer {
    id: pollTimer
    interval: root.busy ? 1500 : (root.opened ? 3000 : 10000)
    onTriggered: root.refresh()
  }

  // The mark: a ring that is faint while laya is down and lit when it is
  // serving; the core dot pulses while a mode switch is spinning up, shows
  // urgent on a failed unit, and sits dim while a foreign laya holds the port.
  property real pulse: 0
  Timer {
    interval: 400; repeat: true; running: root.busy
    onTriggered: root.pulse = (root.pulse + 1) % 2
  }
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Local Laya — " + root.stateLabel()
    onPressed: root.toggle()
    iconComponent: Component {
      Item {
        readonly property color ring: root.failed ? root.urgent
          : root.running ? root.theme
          : root.busy || (root.snap.foreign && root.snap.portPid > 0)
            ? Util.alpha(root.theme, 0.55)
            : Util.alpha(root.theme, 0.3)
        Rectangle {
          anchors.centerIn: parent
          width: Style.space(11); height: width; radius: width / 2
          color: "transparent"
          border.width: 2
          border.color: ring
        }
        Rectangle {
          anchors.centerIn: parent
          width: Style.space(5); height: width; radius: width / 2
          visible: root.running || root.busy || root.failed
            || (root.snap.foreign && root.snap.portPid > 0)
          color: root.failed ? root.urgent : root.theme
          opacity: root.busy ? (root.pulse === 0 ? 1 : 0.25)
            : (root.running ? 1 : 0.4)
        }
      }
    }
  }

  KeyboardPanel {
    id: layaMenu
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: menuKeys
    contentWidth: layaMenu.fittedContentWidth(Style.space(300))
    contentHeight: layaMenu.fittedContentHeight(menuRows.implicitHeight)

    PanelKeyCatcher {
      id: menuKeys
      anchors.fill: parent
      onMoveRequested: function(dx, dy) { if (dy !== 0) root.moveMenuCursor(dy) }
      onActivateRequested: root.activateMenuItem()
      onCloseRequested: root.collapseOrClose()

      Column {
        id: menuRows
        width: parent.width
        spacing: 0
        topPadding: Style.space(4)
        bottomPadding: root.menuTopPad

        Repeater {
          model: root.menuModel

          Item {
            required property var modelData
            required property int index
            readonly property var item: modelData
            readonly property bool isGrid: item.kind === "grid"
            readonly property bool isRow: item.kind !== "sec"
            readonly property bool actionable: root.isActionable(item)
            readonly property bool cursor: actionable && root.menuCursor === index
            width: menuRows.width
            height: isGrid ? root.gridH + Style.space(8)
              : isRow ? root.menuRowH
              : (index === 0 ? 0 : root.menuGroupGap) + root.menuHeadH

            Text {
              visible: !parent.isRow
              x: root.menuGutter
              anchors.bottom: parent.bottom
              text: parent.item.label
              color: root.menuLabel
              font.family: root.menuFont
              font.pixelSize: Style.font.caption
              font.bold: true
            }

            Grid {
              visible: parent.isGrid
              x: root.menuGutter
              anchors.verticalCenter: parent.verticalCenter
              columns: 20
              rows: 7
              flow: Grid.TopToBottom
              columnSpacing: root.gridGap
              rowSpacing: root.gridGap

              Repeater {
                model: 140
                Rectangle {
                  required property int index
                  readonly property var cell: root.grid.cells[index]
                  width: root.gridCell
                  height: root.gridCell
                  radius: 2
                  color: cell && cell.v > 0
                    ? Util.alpha(root.menuInk,
                        0.2 + 0.8 * Math.sqrt(cell.v / Math.max(root.grid.max, 1)))
                    : root.menuSurface
                  MouseArea {
                    anchors.fill: parent
                    hoverEnabled: true
                    onEntered: root.gridHover = root.cellText(parent.cell)
                    onExited: root.gridHover = ""
                  }
                }
              }
            }

            Rectangle {
              visible: parent.isRow && !parent.isGrid && parent.actionable
              x: root.menuEdge
              width: parent.width - 2 * root.menuEdge
              height: root.menuRowH
              radius: 2
              color: parent.cursor ? root.menuSurface : "transparent"
            }

            Text {
              id: chevronLabel
              visible: parent.isRow && !parent.isGrid && !!parent.item.chevron
              anchors.right: parent.right
              anchors.rightMargin: root.menuGutter
              anchors.verticalCenter: parent.verticalCenter
              text: parent.item.chevron || ""
              color: root.menuValue
              font.family: root.menuFont
              font.pixelSize: Style.font.body
            }

            Text {
              id: valueLabel
              visible: parent.isRow && !parent.isGrid && !!parent.item.value
              anchors.right: chevronLabel.visible ? chevronLabel.left : parent.right
              anchors.rightMargin: chevronLabel.visible ? Style.space(8) : root.menuGutter
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, parent.width * 0.6)
              text: parent.item.value || ""
              color: parent.item && parent.item.danger === true
                ? root.menuDanger : root.menuValue
              font.family: root.menuFont
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              visible: parent.isRow && !parent.isGrid
              x: root.menuGutter + (parent.item.kind === "choice" ? root.menuSlot : 0)
              width: (valueLabel.visible ? valueLabel.x - Style.space(8)
                : (chevronLabel.visible ? chevronLabel.x - Style.space(8)
                  : parent.width - root.menuGutter)) - x
              anchors.verticalCenter: parent.verticalCenter
              text: (parent.item.kind === "choice" && parent.item.chosen
                ? "✓ " : "") + (parent.item.label || "")
              color: parent.item.kind === "empty" ? root.menuLabel
                : (parent.item.kind === "info" ? root.menuValue : root.menuInk)
              font.family: root.menuFont
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            MouseArea {
              visible: parent.actionable
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onEntered: root.menuCursor = parent.index
              onClicked: root.activateMenuItem()
            }
          }
        }
      }
    }
  }
}
