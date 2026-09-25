import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Display-only: every lifecycle action is a call into bin/omarchy-local-laya,
// which owns the generated systemd user unit and the persisted config.
BarWidget {
  id: root
  moduleName: "v3moreno.local-laya"

  readonly property string cli: String(Qt.resolvedUrl("bin/omarchy-local-laya"))
    .replace(/^file:\/\//, "")

  property var snap: ({})
  property string problem: ""
  property bool menuOpen: false
  property int menuCursor: 0
  property string expanded: ""

  readonly property bool running: snap.running === true
  readonly property bool busy: snap.active === "activating" || snap.active === "deactivating" || verb.running
  readonly property bool failed: snap.active === "failed"

  function refresh() { if (cli !== "" && !poll.running) poll.running = true }

  function open() {
    menuCursor = 0
    expanded = ""
    refresh()
    menuOpen = true
  }

  function close() { menuOpen = false }
  function toggle() { if (menuOpen) close(); else open() }

  // ---- menu model ----
  // Same flat layout as omarchy-local-ai / omarchy-modes.switcher: one
  // gutter, faint caps section headers, values flush right, ✓ on the chosen
  // row, ›/⌄ on expandable rows, surface fill on the cursor row.
  readonly property string menuFont: bar && bar.fontFamily ? bar.fontFamily : Style.font.family
  readonly property color menuInk: Color.popups.text
  readonly property color menuValue: Util.alpha(Color.popups.text, 0.72)
  readonly property color menuLabel: Util.alpha(Color.popups.text, 0.48)
  readonly property color menuDanger: Style.color.danger
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
    if (snap.running) {
      var s = "running · " + (snap.mode || "cpu")
      if (snap.uptime > 0) s += " · " + fmtDuration(snap.uptime)
      return s
    }
    return "stopped"
  }

  function shortFolder() {
    var f = snap.folder || ""
    if (f === "") return "—"
    var home = Quickshell.env("HOME")
    if (home && f.indexOf(home) === 0) return "~" + f.substring(home.length)
    return f
  }

  function menuItems() {
    var items = [{ kind: "sec", label: "STATUS" }]
    items.push({ kind: "info", label: "state",
      value: stateLabel(), danger: failed })
    if (running) {
      items.push({ kind: "info", label: "port", value: "127.0.0.1:" + snap.port })
      var loaded = snap.health && snap.health.loaded
      items.push({ kind: "info", label: "checkpoints",
        value: Array.isArray(loaded) ? loaded.length + " loaded" : "—" })
      if (snap.health && snap.health.device)
        items.push({ kind: "info", label: "device", value: snap.health.device })
    }
    if (problem !== "")
      items.push({ kind: "empty", label: problem })

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
    } else if (!running) {
      items.push({ kind: "action", id: "start", label: "start", chevron: "›" })
    } else {
      items.push({ kind: "action", id: "stop", label: "stop" })
      items.push({ kind: "action", id: "restart", label: "restart" })
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

  function collapseOrClose() {
    if (expanded !== "") expanded = ""
    else close()
  }

  implicitWidth: triggerRow.implicitWidth
  implicitHeight: triggerRow.implicitHeight

  IpcHandler {
    target: "v3moreno.local-laya"
    function menu(): string { root.toggle(); return "toggled" }
    function refresh(): string { root.refresh(); return "ok" }
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
    interval: root.busy ? 1500 : (root.menuOpen ? 3000 : 10000)
    onTriggered: root.refresh()
  }

  Row {
    id: triggerRow
    anchors.fill: parent
    spacing: Style.space(1)

    BarIconButton {
      id: layaButton
      bar: root.bar
      text: "⚡"
      tooltipText: "Local Laya — " + root.stateLabel()
      active: root.menuOpen
      onPressed: root.toggle()
    }

    WidgetButton {
      id: layaLabel
      bar: root.bar
      text: "laya" + (root.running ? " " + (root.snap.mode || "cpu")
        : (root.failed ? " err" : "")) + " 󰅂"
      tooltipText: layaButton.tooltipText
      horizontalMargin: Style.spaceReal(3)
      active: root.menuOpen
      onPressed: root.toggle()
    }
  }

  KeyboardPanel {
    id: layaMenu
    anchorItem: layaButton
    owner: root
    bar: root.bar
    open: root.menuOpen
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
            readonly property bool isRow: item.kind !== "sec"
            readonly property bool actionable: root.isActionable(item)
            readonly property bool cursor: actionable && root.menuCursor === index
            width: menuRows.width
            height: isRow ? root.menuRowH
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

            Rectangle {
              visible: parent.isRow && parent.actionable
              x: root.menuEdge
              width: parent.width - 2 * root.menuEdge
              height: root.menuRowH
              radius: 2
              color: parent.cursor ? root.menuSurface : "transparent"
            }

            Text {
              id: chevronLabel
              visible: parent.isRow && !!parent.item.chevron
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
              visible: parent.isRow && !!parent.item.value
              anchors.right: chevronLabel.visible ? chevronLabel.left : parent.right
              anchors.rightMargin: chevronLabel.visible ? Style.space(8) : root.menuGutter
              anchors.verticalCenter: parent.verticalCenter
              width: Math.min(implicitWidth, parent.width * 0.45)
              text: parent.item.value || ""
              color: parent.item && parent.item.danger === true
                ? root.menuDanger : root.menuValue
              font.family: root.menuFont
              font.pixelSize: Style.font.body
              elide: Text.ElideRight
            }

            Text {
              visible: parent.isRow
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
