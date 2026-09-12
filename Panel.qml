import QtQuick
import QtQuick.Controls
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// DevWatch — project-grouped dev service manager for the Omarchy bar.
// Backend: scripts/devwatch.py (start/stop/restart/status).
Panel {
  id: root
  moduleName: "sebo.devwatch"
  ipcTarget: "sebo.devwatch"
  manageIpc: false

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color accent: Color.accent
  readonly property color okColor: "#7ec46f"
  readonly property color stopColor: Qt.darker(foreground, 1.8)
  readonly property color errColor: "#e06c5f"
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property string logTag: "devwatch"

  function alpha(c, a) { return Qt.rgba(c.r, c.g, c.b, a) }

  // ------------------------------------------------------------- data

  property var snapshot: null
  property bool loading: false
  property bool busy: false
  // Confirm state for stop: "project/service" or "".
  property string confirmTarget: ""

  property int refreshIntervalSec: Math.max(10, Number(setting("refreshIntervalSec", 15)))

  readonly property var projects: snapshot ? (snapshot.projects || []) : []

  // Flatten for keyboard nav: [{project, path, svc}] entries.
  readonly property var rows: {
    var out = []
    var names = Object.keys(root.projects).sort()
    for (var i = 0; i < names.length; i++) {
      var p = root.projects[names[i]]
      var svcs = p.services || []
      for (var j = 0; j < svcs.length; j++)
        out.push({ project: names[i], path: p.path, svc: svcs[j] })
    }
    return out
  }

  function backendPath() {
    return Qt.resolvedUrl("scripts/devwatch.py").toString().replace(/^file:\/\//, "")
  }

  function refresh() {
    if (root.busy) return
    loading = true
    statusProcess.command = ["python3", backendPath(), "status"]
    statusProcess.running = true
  }

  function action(kind, project, svcName) {
    if (root.busy) return
    root.busy = true
    root.confirmTarget = ""
    actionProcess.command = ["python3", backendPath(), kind, project, svcName]
    actionProcess.running = true
  }

  function svcColor(svc) {
    if (svc.running) return root.okColor
    if (svc.detail && String(svc.detail).indexOf("Fehler") >= 0) return root.errColor
    return root.stopColor
  }

  function statusGlyph(svc) {
    if (svc.running) return "●"
    if (svc.detail && String(svc.detail).indexOf("Fehler") >= 0) return "✕"
    return "○"
  }

  function typeLabel(t) {
    return t === "compose" ? "docker" : (t === "systemd" ? "systemd" : (t === "cmd" ? "cmd" : t))
  }

  Process {
    id: statusProcess
    running: false

    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        root.loading = false
        try {
          root.snapshot = JSON.parse(String(text))
        } catch (e) {
          console.warn(root.logTag, "bad snapshot", e)
        }
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "") console.warn(root.logTag, String(text).trim())
    }
  }

  Process {
    id: actionProcess
    running: false

    stdout: StdioCollector { waitForEnd: true }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: if (String(text).trim() !== "") console.warn(root.logTag, String(text).trim())
    }
    onExited: function(code) {
      root.busy = false
      if (code !== 0) console.warn(root.logTag, "action failed, exit", code)
      root.refresh()
    }
  }

  Timer {
    interval: root.refreshIntervalSec * 1000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  onOpenedChanged: if (opened) {
    root.confirmTarget = ""
    root.refresh()
    Qt.callLater(function() { keyCatcher.forceActiveFocus() })
  }

  IpcHandler {
    target: root.ipcTarget
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function refresh(): string { root.refresh(); return "ok" }
  }

  // ------------------------------------------------------------ helpers

  function rowAt(i) { return root.rows[i] || null }

  // Nothing to show → collapse out of the bar entirely.
  visible: root.rows.length > 0
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  readonly property bool anyRunning: {
    var r = false
    for (var i = 0; i < root.rows.length; i++) if (root.rows[i].svc.running) r = true
    return r
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰣆"
    active: root.anyRunning
    activeColor: root.okColor
    onPressed: function(buttonCode) {
      if (buttonCode === Qt.RightButton) root.refresh()
      else root.toggle()
    }
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(430))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(700))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent

      onMoveRequested: function(dx, dy) {
        if (dy === 0 || root.rows.length === 0) return
        var count = root.rows.length
        if (dy < 0) {
          if (!root.cursorActive) { root.cursorActive = true; root.focusedIndex = count - 1 }
          else if (root.focusedIndex > 0) root.focusedIndex--
        } else {
          if (!root.cursorActive) { root.cursorActive = true; root.focusedIndex = 0 }
          else if (root.focusedIndex < count - 1) root.focusedIndex++
        }
      }
      onCloseRequested: root.close()
      onActivateRequested: {
        var row = rowAt(root.focusedIndex)
        if (!row) return
        var key = row.project + "/" + row.svc.name
        if (row.svc.running) {
          if (root.confirmTarget === key) root.action("stop", row.project, row.svc.name)
          else root.confirmTarget = key
        } else {
          root.action("start", row.project, row.svc.name)
        }
      }

      Flickable {
        id: listFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          x: Style.space(6)
          width: listFlick.width - Style.space(12)
          spacing: Style.space(14)

          PanelHero {
            width: parent.width
            title: "DevWatch"
            meta: {
              var run = 0
              for (var i = 0; i < root.rows.length; i++) if (root.rows[i].svc.running) run++
              return run + " / " + root.rows.length + " Dienste aktiv"
            }
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          Text {
            visible: root.rows.length === 0 && !root.loading
            width: parent.width
            topPadding: Style.space(24)
            text: "Keine Dienste gefunden.\nLege eine .devservices.json im Projekt an."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.body
            horizontalAlignment: Text.AlignHCenter
            wrapMode: Text.WordWrap
          }

          Repeater {
            model: root.rows

            delegate: CursorSurface {
              id: row
              required property var modelData
              required property int index

              hasCursor: root.cursorActive && index === root.focusedIndex
              current: modelData.svc.running
              bordered: false
              foreground: root.foreground
              accent: root.accent

              width: parent.width
              implicitHeight: rowCol.implicitHeight + Style.space(20)

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton
                cursorShape: Qt.PointingHandCursor

                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.focusedIndex = index
                }

                onClicked: {
                  var key = modelData.project + "/" + modelData.svc.name
                  if (modelData.svc.running) {
                    if (root.confirmTarget === key)
                      root.action("stop", modelData.project, modelData.svc.name)
                    else
                      root.confirmTarget = key
                  } else {
                    root.action("start", modelData.project, modelData.svc.name)
                  }
                }
              }

              function keyFor(r) { return r.project + "/" + r.svc.name }

              Column {
                id: rowCol
                anchors.left: parent.left
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                anchors.rightMargin: Style.space(12)
                spacing: Style.space(3)

                Row {
                  width: parent.width
                  spacing: Style.space(6)

                  Text {
                    text: statusGlyph(modelData.svc)
                    color: svcColor(modelData.svc)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    width: parent.width - typePill.width - statusText.width - Style.space(16)
                    text: modelData.svc.name
                    textFormat: Text.PlainText
                    color: root.foreground
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    font.bold: true
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Rectangle {
                    id: typePill
                    radius: height / 2
                    width: typeText.implicitWidth + Style.space(8)
                    height: typeText.implicitHeight + Style.space(3)
                    color: root.alpha(root.foreground, 0.08)
                    anchors.verticalCenter: parent.verticalCenter

                    Text {
                      id: typeText
                      anchors.centerIn: parent
                      text: typeLabel(modelData.svc.type)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption - 1 > 8 ? Style.font.caption - 1 : 8
                    }
                  }

                  Text {
                    id: statusText
                    text: modelData.svc.detail || ""
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }

                Row {
                  width: parent.width
                  spacing: Style.space(8)

                  Text {
                    text: "▣ " + modelData.project
                    color: root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width - actionHint.width - Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: actionHint
                    text: {
                      var key = modelData.project + "/" + modelData.svc.name
                      if (root.confirmTarget === key) return "Erneut klicken = STOPP"
                      if (modelData.svc.running) return "Klick: Stoppen"
                      if (root.busy) return "…"
                      return "Klick: Starten"
                    }
                    color: root.confirmTarget === (modelData.project + "/" + modelData.svc.name) ? root.errColor : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    anchors.verticalCenter: parent.verticalCenter
                  }
                }
              }

              PanelToolTip {
                visible: rowMouse.containsMouse
                text: modelData.path
                fontFamily: root.fontFamily
              }
            }
          }

          Item { width: parent.width; height: Style.space(2) }
        }
      }
    }
  }
}
