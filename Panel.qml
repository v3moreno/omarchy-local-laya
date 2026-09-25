import QtQuick
import QtQuick.Controls as Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
import "Model.js" as Model

// Local Laya: the laya decision daemon as a service card — its lifetime request grid, its token line,
// one click to watch the log, one click for the rest. Model.js turns the backend's snapshot into a view;
// this file draws it and runs the backend's verbs.
Panel {
  id: root
  moduleName: "v3moreno.local-laya"
  ipcTarget: "v3moreno.local-laya"
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property string cli: String(Qt.resolvedUrl("bin/omarchy-local-laya")).replace(/^file:\/\//, "")
  readonly property color theme: bar ? bar.foreground : Color.foreground
  readonly property color bg: Color.popups.background
  readonly property color surface: Util.alpha(theme, 0.06)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string mono: bar ? bar.fontFamily : Style.font.family
  // Nerd Font glyphs for the icon names Model.js uses
  readonly property var glyphs: ({ gpu: 0xf08ae, memory: 0xf035b, temp: 0xf050f, weights: 0xf01a7,
    speed: 0xf140c, tokens: 0xf04a0, folder: 0xf0256, machine: 0xf0379, check: 0xf012c,
    down: 0xf0140, mode: 0xf0668, version: 0xf02d4, tune: 0xf066c })
  function glyph(name) { return glyphs[name] ? String.fromCodePoint(glyphs[name]) : "" }

  // Four tones, each picked by the APCA contrast it must reach on a card (Model.tones): ink for what matters
  // now, value for what a label names, one tone for every label, and rule for lines that are not text.
  readonly property var tones: Model.tones(theme, bg, surface, urgent)
  readonly property color ink: Qt.rgba(tones.ink.r, tones.ink.g, tones.ink.b, 1)
  readonly property color valueTone: Qt.rgba(tones.value.r, tones.value.g, tones.value.b, 1)
  readonly property color labelTone: Qt.rgba(tones.label.r, tones.label.g, tones.label.b, 1)
  readonly property color ruleTone: Qt.rgba(tones.rule.r, tones.rule.g, tones.rule.b, 1)
  readonly property color alertTone: Qt.rgba(tones.alert.r, tones.alert.g, tones.alert.b, 1)
  readonly property color alertRule: Qt.rgba(tones.alertRule.r, tones.alertRule.g, tones.alertRule.b, 1)

  // One grid. Every line of text starts and ends on the gutter; surfaces sit at the edge, so the text inside
  // them lands on the same gutter. Rows in a group touch; groups are a gap apart; a heading sits on its rows.
  readonly property int gutter: Style.space(20)
  readonly property int edge: Style.space(8)
  readonly property int pad: gutter - edge
  readonly property int rowH: Style.space(22)
  // the chart borders breathe between 12% and 26% of the ink every 3.6 s while one is on screen
  property real glow: 0.12
  Timer {
    property real t: 0
    interval: 100
    repeat: true
    running: root.opened && (!!root.view.hero && !!root.view.hero.line || (root.view.rows || []).some(function(r) { return r.type === "run" }))
    onTriggered: {
      t = (t + interval) % 3600
      root.glow = 0.19 - 0.07 * Math.cos(t / 3600 * 2 * Math.PI)
    }
  }
  readonly property int headH: Style.space(16)
  readonly property int groupGap: Style.space(20)
  readonly property int blockGap: Style.space(8)
  readonly property int topGap: Style.space(12)

  property var snap: ({})
  property var ui: ({ view: "home", open: "", problem: "" })
  property var queue: []
  // A snapshot the view cannot read says so
  readonly property var view: {
    try {
      return Model.build(snap, ui)
    } catch (e) {
      return { title: "LOCAL LAYA", mark: "failed", rows: [{ type: "error", label: "could not read the backend's answer: " + e.message }] }
    }
  }

  function nav(patch) {
    var moved = patch.view !== undefined
    ui = Object.assign({ view: ui.view, open: "", problem: "" }, patch)
    if (moved) flick.contentY = 0
  }
  function home() { nav({ view: "home" }) }
  function run(args) { queue.push(args); if (!verb.running) next() }
  function next() {
    if (!queue.length) return refresh()
    verb.command = [cli].concat(queue.shift())
    verb.running = true
  }
  function refresh() { if (!poll.running) poll.running = true }

  // The space above row i: a group opens a gap, a surface follows a surface closely, rows in a group touch
  function gapBefore(i) {
    var rows = view.rows || [], t = rows[i].type
    if (i === 0 && !view.hero && t !== "sec") return topGap
    if (t === "sec" || t === "acts" || t === "error") return groupGap
    if (t === "run" || t === "grid") return i === 0 && !view.hero ? topGap : blockGap
    return i === 0 ? topGap : 0
  }

  // An action is "verb|arg|arg", from Model.js
  function activate(action) {
    var a = (action || "").split("|")
    switch (a[0]) {
    case "start": case "stop": case "restart": run([a[0]]); break
    case "mode": run(["mode", a[1]]); nav({ open: "" }); break
    case "auto": run(["autostart", a[1]]); break
    case "update": run(a[1] ? ["update", a[1]] : ["update"]); break
    case "install": run(["install"]); break
    case "agents": run(["agents"]); nav({ open: "" }); break
    case "set": run([a[1], a[2]]); nav({ open: "" }); break
    case "more": nav({ view: "more" }); break
    case "home": home(); break
    case "pick": nav({ open: ui.open === a[1] ? "" : a[1] }); break
    case "log": logOpen.running = true; root.close(); break
    }
  }

  Process {
    id: poll
    command: [root.cli, "snapshot"]
    stdout: StdioCollector { waitForEnd: true; onStreamFinished: root.snap = Model.parse(text) || root.snap }
  }
  // A verb that fails says why on its last "local-laya:" line; the panel opens to show it
  Process {
    id: verb
    stderr: StdioCollector { id: verbErr; waitForEnd: true }
    onExited: function(code) {
      if (code !== 0) {
        var m = (verbErr.text || "").split("\n").filter(function(l) { return l.indexOf("local-laya: ") === 0 }).pop()
        root.queue = []
        if (!root.opened) root.open()
        root.ui = Object.assign({}, root.ui, { problem: m ? m.slice(12) : "that did not work (see the log)" })
      }
      root.next()
    }
  }
  Process { id: logOpen; command: [root.cli, "log"] }
  Timer {
    interval: root.view.mark === "busy" ? 1500 : root.opened ? 5000 : 30000
    running: true; repeat: true; triggeredOnStart: true
    onTriggered: root.refresh()
  }
  onOpenedChanged: if (opened) { refresh(); if (!ui.problem) home() }

  // The mark: a ring that is faint while laya is down and lit while anything serves the port — ours or a
  // foreign laya; the core dot pulses while a mode switch is spinning up and turns urgent on a failed unit.
  property real pulse: 0
  Timer {
    interval: 400; repeat: true; running: root.view.mark === "busy"
    onTriggered: root.pulse = (root.pulse + 1) % 2
  }
  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    tooltipText: "Local Laya"
    onPressed: root.toggle()
    iconComponent: Component {
      Item {
        Mark {
          anchors.centerIn: parent
          size: 11
          ring: root.view.mark === "failed" ? root.urgent
            : root.view.mark === "ready" ? root.theme
            : root.view.mark === "busy" ? Util.alpha(root.theme, 0.55)
            : root.view.mark === "foreign" ? root.theme
            : Util.alpha(root.theme, 0.3)
          dot: root.view.mark !== ""
          dotColor: root.view.mark === "failed" ? root.urgent : root.theme
          dotOpacity: root.view.mark === "busy" ? (root.pulse === 0 ? 1 : 0.25)
            : (root.view.mark === "ready" || root.view.mark === "foreign" ? 1 : 0.4)
        }
      }
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keys
    padding: 0
    contentWidth: Style.space(340)
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    Rectangle { anchors.fill: parent; color: root.bg }
    Item {
      id: keys
      anchors.fill: parent
      focus: true
      Keys.onEscapePressed: root.ui.view === "home" ? root.close() : root.home()

      Flickable {
        id: flick
        anchors.fill: parent
        contentHeight: content.implicitHeight
        clip: true
        interactive: contentHeight > height
        boundsBehavior: Flickable.StopAtBounds

        Column {
          id: content
          objectName: "local-laya-content"
          width: flick.width
          topPadding: Style.space(16)
          bottomPadding: Style.space(16)
          spacing: 0

          // The top line: the name and version, or the way back
          Item {
            width: parent.width
            height: root.headH
            Label {
              id: head
              x: root.gutter
              anchors.verticalCenter: parent.verticalCenter
              text: root.view.back ? "‹ home" : root.view.title
              color: root.view.back ? root.valueTone : root.labelTone
            }
            Label {
              visible: !root.view.back
              anchors.left: head.right
              anchors.leftMargin: Style.space(8)
              anchors.baseline: head.baseline
              text: root.view.version || ""
              color: Util.alpha(root.labelTone, 0.55)
              font.pixelSize: Style.font.caption - 2
            }
            Click { anchors.fill: head; action: root.view.back ? "home" : "" }
          }

          Item {
            width: parent.width
            height: root.view.hero && hero.item ? root.topGap + hero.item.implicitHeight : 0
            Loader {
              id: hero
              active: !!root.view.hero
              x: root.edge
              y: root.topGap
              width: parent.width - 2 * root.edge
              sourceComponent: Component { Hero { h: root.view.hero } }
            }
          }

          Repeater {
            // keyed by position, so a refresh updates rows in place instead of rebuilding them (no flicker)
            model: (root.view.rows || []).length
            Item {
              required property int index
              readonly property var r: (root.view.rows || [])[index] || ({ type: "" })
              readonly property int gap: root.gapBefore(index)
              width: content.width
              height: gap + row.height

              Loader {
                id: row
                readonly property real inset: ["run", "grid"].indexOf(r.type) >= 0 ? root.edge : 0
                x: inset
                y: parent.gap
                width: parent.width - 2 * inset
                sourceComponent: ({ life: lifeC, run: runC, soon: soonC, grid: gridC, gpu: gpuC,
                  field: fieldC, opt: optC, path: pathC, acts: linksC, links: linksC })[r.type] || textC
              }

              // Your lifetime: the totals, then the activity grid (a column a week, a row a weekday) with its months
              Component {
                id: lifeC
                Column {
                  id: life
                  objectName: "local-laya-life"
                  readonly property int cols: Math.ceil((r.cells || []).length / 7)
                  readonly property real cell: Math.min(Style.space(12), (width - 2 * root.gutter - (cols - 1) * Style.space(3)) / cols)
                  // the hovered day, whose date and tokens replace "since" at the top right
                  property int hover: -1
                  spacing: Style.space(10)
                  Item {
                    width: parent.width
                    height: lifeTokens.implicitHeight
                    Row {
                      x: root.gutter
                      spacing: Style.space(10)
                      Label { id: lifeTokens; text: r.tokens; color: root.ink }
                      Label { anchors.baseline: lifeTokens.baseline; text: r.requests; color: root.labelTone }
                    }
                    Right {
                      margin: root.gutter
                      text: life.hover >= 0 ? (r.labels || [])[life.hover] || "" : r.since
                      color: life.hover >= 0 ? root.ink : root.labelTone
                    }
                  }
                  Grid {
                    x: root.gutter
                    rows: 7
                    flow: Grid.TopToBottom
                    spacing: Style.space(3)
                    Repeater {
                      model: (r.cells || []).length
                      Rectangle {
                        required property int index
                        readonly property int level: (r.cells || [])[index]
                        width: life.cell
                        height: life.cell
                        radius: 2
                        color: level < 0 ? "transparent" : Util.alpha(root.theme, [0.07, 0.25, 0.45, 0.7, 0.95][level])
                        border.width: life.hover === index ? 1 : 0
                        border.color: root.ink
                        MouseArea {
                          anchors.fill: parent
                          enabled: level >= 0
                          hoverEnabled: true
                          onEntered: life.hover = index
                          onExited: if (life.hover === index) life.hover = -1
                        }
                      }
                    }
                  }
                  Item {
                    width: parent.width
                    height: Style.space(12)
                    Repeater {
                      model: r.months || []
                      Label {
                        required property var modelData
                        x: root.gutter + modelData.col * (life.cell + Style.space(3))
                        text: modelData.label
                        color: root.labelTone
                        font.pixelSize: Style.font.caption - 1
                      }
                    }
                  }
                }
              }

              // The service as a card: its cumulative token line across the whole card, behind its name, mode,
              // latency and tokens; Open log (or Stop while it works) and More
              Component {
                id: runC
                Rectangle {
                  height: Style.space(156)
                  color: Util.alpha(root.theme, 0.08)
                  border.width: 1
                  border.color: Util.alpha(root.theme, root.glow)
                  clip: true
                  Line { anchors.fill: parent; values: r.line }
                  Column {
                    x: root.pad
                    y: Style.space(16)
                    width: parent.width - 2 * root.pad
                    spacing: Style.space(6)
                    Row {
                      spacing: Style.space(10)
                      Mark {
                        size: 9
                        anchors.verticalCenter: parent.verticalCenter
                        ring: root.ink
                        dot: root.view.mark === "ready"
                        dotColor: root.ink
                        dotOpacity: 1
                      }
                      Label { id: runName; text: r.name; color: root.ink; font.pixelSize: Style.font.subtitle }
                      Label {
                        visible: !!r.version
                        anchors.baseline: runName.baseline
                        text: r.version || ""
                        color: Util.alpha(root.labelTone, 0.55)
                        font.pixelSize: Style.font.caption - 2
                      }
                    }
                    Row {
                      spacing: Style.space(10)
                      Label { text: r.gpu; color: root.labelTone }
                      Label { visible: !!r.mem; text: r.mem || ""; color: Util.alpha(root.labelTone, 0.6) }
                    }
                    Item { width: 1; height: Style.space(4) }
                    Label {
                      visible: !!r.sub
                      width: parent.width
                      text: r.sub || ""
                      color: root.valueTone
                      wrapMode: Text.WordWrap
                      maximumLineCount: 2
                      elide: Text.ElideRight
                    }
                  }
                  Chips {
                    items: r.chips || []
                    anchors.right: parent.right
                    anchors.rightMargin: root.pad
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(20)
                    size: Style.font.caption - 1
                  }
                  Row {
                    x: root.pad
                    anchors.bottom: parent.bottom
                    anchors.bottomMargin: Style.space(14)
                    spacing: Style.space(8)
                    Btn {
                      label: r.primary.label + (r.primary.quiet ? "" : " ›")
                      action: r.primary.action
                      primary: !r.primary.quiet
                      danger: !!r.primary.quiet
                    }
                    Btn { label: "More"; action: r.more }
                  }
                }
              }

              // Nothing installed yet: a square wave drifting left, one line, and the install button
              Component {
                id: soonC
                Column {
                  topPadding: Style.space(28)
                  bottomPadding: Style.space(20)
                  spacing: Style.space(18)
                  Item {
                    anchors.horizontalCenter: parent.horizontalCenter
                    width: Style.space(140)
                    height: Style.space(18)
                    clip: true
                    Timer {
                      interval: 50
                      repeat: true
                      running: root.opened
                      onTriggered: wave.x = (wave.x - wave.period * interval / 2400) % wave.period
                    }
                    Row {
                      id: wave
                      readonly property real period: Style.space(28)
                      readonly property real stroke: 1.5
                      Repeater {
                        model: Math.ceil(Style.space(140) / wave.period) + 1
                        Item {
                          width: wave.period
                          height: Style.space(18)
                          Rectangle { x: -wave.stroke / 2; y: 2 - wave.stroke / 2; width: wave.stroke; height: parent.height - 4 + wave.stroke; color: root.labelTone }
                          Rectangle { y: 2 - wave.stroke / 2; width: wave.period / 2; height: wave.stroke; color: root.labelTone }
                          Rectangle { x: wave.period / 2 - wave.stroke / 2; width: wave.stroke; height: parent.height - 4 + wave.stroke; color: root.labelTone }
                          Rectangle { x: wave.period / 2; y: parent.height - 2 - wave.stroke / 2; width: wave.stroke; height: wave.stroke; color: root.labelTone }
                        }
                      }
                    }
                    Rectangle {
                      width: parent.width / 4
                      height: parent.height
                      gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: root.bg } GradientStop { position: 1; color: "transparent" } }
                    }
                    Rectangle {
                      x: parent.width * 3 / 4
                      width: parent.width
                      height: parent.height
                      gradient: Gradient { orientation: Gradient.Horizontal; GradientStop { position: 0; color: "transparent" } GradientStop { position: 1; color: root.bg } }
                    }
                  }
                  Label {
                    x: root.gutter
                    width: parent.width - 2 * root.gutter
                    horizontalAlignment: Text.AlignHCenter
                    text: r.head
                    wrapMode: Text.WordWrap
                  }
                  Btn { anchors.horizontalCenter: parent.horizontalCenter; label: r.button || "Install ›"; action: r.action }
                }
              }

              // Six figures, three by two, hairline gaps
              Component {
                id: gridC
                Grid {
                  columns: 3
                  spacing: 1
                  Repeater {
                    model: r.cells
                    Rectangle {
                      required property var modelData
                      width: (parent.width - 2) / 3
                      height: Style.space(44)
                      color: root.surface
                      Column {
                        x: root.pad
                        anchors.verticalCenter: parent.verticalCenter
                        spacing: Style.space(4)
                        Row {
                          spacing: Style.space(6)
                          Label { id: figure; text: modelData.v }
                          Label { anchors.baseline: figure.baseline; text: modelData.u; color: root.labelTone }
                        }
                        Label { text: modelData.k; color: root.labelTone }
                      }
                    }
                  }
                }
              }

              // One card: its name, memory in use, temperature
              Component {
                id: gpuC
                Item {
                  height: root.rowH
                  Column {
                    x: root.gutter
                    width: Style.space(100)
                    anchors.verticalCenter: parent.verticalCenter
                    Label { width: parent.width; text: r.name; elide: Text.ElideRight }
                  }
                  Rectangle {
                    x: root.gutter + Style.space(104)
                    visible: r.bar
                    width: Math.max(0, gpuMem.x - x - Style.space(12))
                    height: 3
                    anchors.verticalCenter: parent.verticalCenter
                    color: root.ruleTone
                    Rectangle {
                      width: parent.width * r.pct / 100
                      height: parent.height
                      color: root.valueTone
                    }
                  }
                  Right { id: gpuMem; margin: root.gutter; text: r.mem + (r.temp ? "  " + r.temp : "") }
                }
              }

              // A label on the left, a value on the right; rows that open a picker carry a chevron
              Component {
                id: fieldC
                Item {
                  height: root.rowH
                  Row {
                    id: fieldLabel
                    x: root.gutter
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)
                    Label { visible: !!r.icon; width: Style.space(12); text: root.glyph(r.icon || ""); color: root.labelTone }
                    Label { text: r.label; color: root.labelTone }
                  }
                  Right {
                    id: fieldValue
                    margin: root.gutter
                    width: Math.min(implicitWidth, parent.width - fieldLabel.x - fieldLabel.width - root.gutter - Style.space(16))
                    elide: Text.ElideMiddle
                    text: r.value + (r.drop ? "  " + root.glyph("down") : r.action ? " ›" : "")
                    color: r.open ? root.ink : root.valueTone
                  }
                  Click { action: r.action || "" }
                }
              }

              Component {
                id: optC
                Item {
                  height: root.rowH
                  Row {
                    x: root.gutter
                    anchors.verticalCenter: parent.verticalCenter
                    spacing: Style.space(8)
                    Label { width: Style.space(12); text: r.on ? root.glyph("check") : ""; color: root.ink }
                    Label { text: r.label; color: r.on ? root.ink : root.valueTone }
                  }
                  Right { visible: !!r.value; margin: root.gutter; text: r.value || ""; color: root.labelTone }
                  Click { action: r.action }
                }
              }

              // Any folder, typed
              Component {
                id: pathC
                Item {
                  height: Style.space(30)
                  Controls.TextField {
                    x: root.gutter + Style.space(12)
                    width: parent.width - x - root.gutter
                    placeholderText: "or type a path"
                    placeholderTextColor: root.labelTone
                    color: root.ink
                    font.family: root.mono
                    font.pixelSize: Style.font.caption
                    background: Rectangle { color: "transparent"; border.width: 1; border.color: root.ruleTone }
                    onAccepted: {
                      var path = text.indexOf("~") === 0 ? Quickshell.env("HOME") + text.slice(1) : text
                      root.activate("set|folder|" + path)
                    }
                  }
                }
              }

              // A row of buttons, with what there is to know above it
              Component {
                id: linksC
                Column {
                  topPadding: Style.space(2)
                  bottomPadding: Style.space(10)
                  spacing: Style.space(8)
                  Chips { visible: (r.chips || []).length > 0; x: root.gutter; items: r.chips || [] }
                  Label { visible: !!r.note; x: root.gutter; width: parent.width - 2 * root.gutter; text: r.note || ""; color: root.labelTone; wrapMode: Text.WordWrap }
                  Flow {
                    visible: (r.items || []).length > 0
                    x: root.gutter
                    width: parent.width - 2 * root.gutter
                    spacing: Style.space(8)
                    Repeater {
                      model: r.items || []
                      Btn {
                        required property var modelData
                        label: modelData.label
                        action: modelData.action
                        primary: !!modelData.primary
                        danger: !!modelData.danger
                      }
                    }
                  }
                }
              }

              // A section's name, or an error in its place
              Component {
                id: textC
                Label {
                  readonly property bool sec: r.type === "sec"
                  leftPadding: root.gutter; rightPadding: root.gutter
                  width: parent.width
                  height: sec ? root.headH : implicitHeight
                  verticalAlignment: Text.AlignVCenter
                  text: r.label || ""
                  color: sec ? root.labelTone : root.alertTone
                  wrapMode: Text.WordWrap
                }
              }
            }
          }
        }
      }
    }
  }

  // ---------------------------------------------------------------- pieces

  component Label: Text {
    textFormat: Text.PlainText
    color: root.valueTone
    font.family: root.mono
    font.pixelSize: Style.font.caption
  }

  // Facts as small icon-and-text pairs, spaced instead of joined with dots
  component Chips: Flow {
    id: chips
    property var items: []
    property color tone: root.labelTone
    property int size: Style.font.caption
    spacing: Style.space(12)
    Repeater {
      model: chips.items
      Row {
        required property var modelData
        spacing: Style.space(4)
        Label { visible: !!modelData.icon; text: root.glyph(modelData.icon || ""); color: root.labelTone; font.pixelSize: chips.size }
        Label { visible: !!modelData.text; text: modelData.text || ""; color: chips.tone; font.pixelSize: chips.size }
      }
    }
  }

  // A label against its row's right edge
  component Right: Label {
    property int margin
    anchors.right: parent.right
    anchors.rightMargin: margin
    anchors.verticalCenter: parent.verticalCenter
  }

  // A whole row, or the item it fills, that runs an action; nothing when the action is ""
  component Click: MouseArea {
    property string action
    anchors.fill: parent
    enabled: action !== ""
    cursorShape: Qt.PointingHandCursor
    onClicked: root.activate(action)
  }

  // The ring-and-dot mark, anywhere a logo would sit
  component Mark: Item {
    property int size: 11
    property color ring: root.theme
    property bool dot: true
    property color dotColor: root.theme
    property real dotOpacity: 1
    implicitWidth: Style.space(size)
    implicitHeight: Style.space(size)
    Rectangle {
      anchors.fill: parent
      radius: width / 2
      color: "transparent"
      border.width: Math.max(1, width / 6)
      border.color: ring
    }
    Rectangle {
      // the dot keeps the ring's parity, so (width - d) / 2 is a whole pixel and it centers exactly
      property int d: Math.round(parent.width * 0.4) | (Math.round(parent.width) % 2)
      x: (parent.width - d) / 2
      y: (parent.height - d) / 2
      width: d
      height: d
      radius: d / 2
      visible: dot
      color: dotColor
      opacity: dotOpacity
    }
  }

  // Tokens over time, cumulative, rising to the right: a dim line over a faint area, so text over it keeps its contrast
  component Line: Canvas {
    property var values: []
    onValuesChanged: requestPaint()
    Component.onCompleted: requestPaint()
    onPaint: {
      var g = getContext("2d"), v = values || [], n = v.length, top = Math.max.apply(null, v.concat([1]))
      g.clearRect(0, 0, width, height)
      if (n < 2 || top <= 1) return
      g.beginPath()
      for (var i = 0; i < n; i++) {
        var x = i / (n - 1) * width, y = height - 4 - v[i] / top * (height * 0.8)
        if (i) g.lineTo(x, y)
        else g.moveTo(x, y)
      }
      g.strokeStyle = Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.25)
      g.lineWidth = 1.2
      g.stroke()
      g.lineTo(width, height)
      g.lineTo(0, height)
      g.closePath()
      g.fillStyle = Qt.rgba(root.ink.r, root.ink.g, root.ink.b, 0.06)
      g.fill()
    }
  }

  // Primary is filled with ink; secondary is outlined in the same ink; danger is outlined in alert
  component Btn: Rectangle {
    id: btn
    property string label
    property string action
    property bool primary
    property bool danger
    readonly property bool chevron: /\s›$/.test(label)
    readonly property rect glyphs: metrics.tightBoundingRect
    readonly property real weight: chevron ? (glyphs.x + glyphs.width - words.tightBoundingRect.x - words.tightBoundingRect.width) / 6 : 0
    visible: label !== ""
    implicitWidth: Math.ceil(glyphs.width) + Style.space(24)
    implicitHeight: btnText.implicitHeight + Style.space(10)
    color: primary ? root.ink : "transparent"
    border.width: primary ? 0 : 1
    border.color: danger ? root.alertRule : root.ink
    opacity: action === "" ? 0.5 : 1
    TextMetrics { id: metrics; font: btnText.font; text: btn.label }
    TextMetrics { id: words; font: btnText.font; text: btn.label.replace(/\s›$/, "") }
    Label {
      id: btnText
      anchors.centerIn: parent
      anchors.horizontalCenterOffset: metrics.advanceWidth / 2 - (btn.glyphs.x + btn.glyphs.width / 2) + btn.weight
      text: btn.label
      color: btn.primary ? Qt.rgba(root.bg.r, root.bg.g, root.bg.b, 1) : btn.danger ? root.alertTone : root.ink
    }
    Click { action: btn.action }
  }

  // The top of the details page: the name, what it runs on, and a surface under them (its token line with the
  // scale and dates, while it serves)
  component Hero: Column {
    property var h
    spacing: 0
    Column {
      x: root.pad
      width: parent.width - 2 * root.pad
      spacing: Style.space(4)
      Row {
        spacing: Style.space(8)
        Mark { size: 8; anchors.verticalCenter: parent.verticalCenter; ring: root.ink; dot: root.view.mark === "ready"; dotColor: root.ink }
        Label { id: heroName; text: h.name; color: root.ink; font.pixelSize: Style.font.body }
        Label {
          visible: !!h.version
          anchors.baseline: heroName.baseline
          text: h.version || ""
          color: Util.alpha(root.labelTone, 0.55)
          font.pixelSize: Style.font.caption - 2
        }
      }
      Chips { width: parent.width; items: h.chips || []; tone: root.valueTone }
      Label { visible: !!h.sub; text: h.sub || ""; color: root.labelTone }
    }
    Item { width: 1; height: root.topGap }
    Rectangle {
      visible: !!h.line
      width: parent.width
      height: visible ? Style.space(110) : 0
      color: root.surface
      border.width: 1
      border.color: Util.alpha(root.theme, root.glow)
      clip: true
      Line { anchors.fill: parent; values: h.line || [] }
      Label { x: root.pad; y: Style.space(8); text: h.top || ""; color: root.labelTone }
      Label { x: root.pad; y: parent.height / 2 - height / 2; text: h.mid || ""; color: root.labelTone }
      Label { x: root.pad; y: parent.height - Style.space(8) - height; text: h.since || ""; color: root.labelTone }
      Label { x: parent.width - Style.space(6) - width; y: parent.height - Style.space(8) - height; text: h.now || ""; color: root.labelTone }
    }
  }
}
