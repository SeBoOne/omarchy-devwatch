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
  // Tastatur-Fokus (eigene Deklaration, robust gegenüber Basis-Änderungen).
  property bool cursorActive: false
  property int focusedIndex: 0

  property int refreshIntervalSec: Math.max(10, Number(setting("refreshIntervalSec", 15)))

  readonly property var projects: snapshot ? (snapshot.projects || []) : []

  // Flatten for keyboard nav: [{project, path, svc}] entries, plus groups:
  // [{project, path, group:{name, services}}] when a project is grouped.
  // In Group-Drill-Down (drillProject set) sind nur die Gruppendienste drin.
  property string drillProject: ""
  readonly property string drillName: drillProject ? (root.projects[drillProject].group ? root.projects[drillProject].group.name : "") : ""

  readonly property var rows: {
    var out = []
    var names = Object.keys(root.projects).sort()
    if (root.drillProject !== "") {
      var gp = root.projects[root.drillProject]
      if (!gp || !gp.group) return out
      var gsvcs = gp.group.services || []
      for (var k = 0; k < gsvcs.length; k++)
        out.push({ project: root.drillProject, path: gp.path, svc: gsvcs[k] })
      return out
    }
    for (var i = 0; i < names.length; i++) {
      var p = root.projects[names[i]]
      if (p.group) {
        out.push({ project: names[i], path: p.path, group: p.group })
      } else {
        var svcs = p.services || []
        for (var j = 0; j < svcs.length; j++)
          out.push({ project: names[i], path: p.path, svc: svcs[j] })
      }
    }
    return out
  }

  function groupRunningCount(project) {
    var gp = root.projects[project]
    if (!gp || !gp.group) return 0
    var s = gp.group.services || []
    var r = 0
    for (var i = 0; i < s.length; i++) if (s[i].running === true) r++
    return r
  }

  function groupAllRunning(project) {
    var gp = root.projects[project]
    if (!gp || !gp.group) return false
    var s = gp.group.services || []
    if (s.length === 0) return false
    for (var i = 0; i < s.length; i++) if (s[i].running !== true) return false
    return true
  }

  function groupAnyRunning(project) { return root.groupRunningCount(project) > 0 }

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
    // svcName nur anhaengen, wenn gesetzt — groupstart/groupstop erwarten
    // genau 2 Argumente (kein trailing undefined, sonst Usage-exit: "nichts passiert").
    var cmd = ["python3", backendPath(), kind, project]
    if (svcName && String(svcName) !== "") cmd.push(svcName)
    actionProcess.command = cmd
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

  // Gruppen-Schalter-Zustand: Mischzustand wenn einige (nicht alle) laufen.
  function groupState(project) {
    var c = root.groupRunningCount(project)
    if (c === 0) return "off"
    if (root.groupAllRunning(project)) return "all"
    return "mix"
  }

  function groupColor(project) {
    var st = root.groupState(project)
    if (st === "off") return root.stopColor
    if (st === "mix") return root.accent
    return root.okColor
  }

  function groupGlyph(project) {
    var st = root.groupState(project)
    if (st === "off") return "○"
    if (st === "mix") return "◐"
    return "●"
  }

  function groupFirewallProblem(groupService) {
    return groupService && groupService.firewall === true && groupService.allowed === false
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
    root.drillProject = ""
    root.focusedIndex = 0
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
    var names = Object.keys(root.projects)
    for (var i = 0; i < names.length; i++) {
      var p = root.projects[names[i]]
      if (p.group) {
        if (root.groupAnyRunning(names[i])) { r = true; break }
      } else {
        var svcs = p.services || []
        for (var j = 0; j < svcs.length; j++) if (svcs[j].running === true) { r = true; break }
      }
      if (r) break
    }
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
        // Gruppenzeile in der Übersicht: Enter = Schalter (start/stop-Flow).
        if (root.drillProject === "" && row.group) {
          var pk = row.project
          if (root.groupState(pk) !== "off") {
            root.confirmTarget = root.confirmTarget === pk ? "" : pk
            if (root.confirmTarget === "") root.action("groupstop", pk)
          } else {
            root.action("groupstart", pk)
          }
          return
        }
        if (!row.svc) return
        var key = row.project + "/" + row.svc.name
        if (row.svc.running === true) {
          if (root.confirmTarget === key) { root.action("stop", row.project, row.svc.name); root.confirmTarget = "" }
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
            title: root.drillProject !== "" ? "DevWatch — " + root.drillName : "DevWatch"
            meta: {
              if (root.drillProject !== "") return root.rows.length + " Dienste in Gruppe"
              var run = 0
              var names = Object.keys(root.projects)
              for (var i = 0; i < names.length; i++) {
                var p = root.projects[names[i]]
                if (p.group) run += root.groupRunningCount(names[i])
                else { var svs = p.services || []; for (var j = 0; j < svs.length; j++) if (svs[j].running === true) run++ }
              }
              return run + " / " + root.rows.length + " Dienste aktiv"
            }
            foreground: root.foreground
            fontFamily: root.fontFamily
          }

          // Group-Drill-Down: zurück zur Übersicht.
          CursorSurface {
            visible: root.drillProject !== ""
            width: parent.width
            implicitHeight: backRow.implicitHeight + Style.space(16)
            bordered: false
            foreground: root.foreground
            accent: root.accent
            current: false
            hasCursor: false

            MouseArea {
              anchors.fill: parent
              hoverEnabled: true
              cursorShape: Qt.PointingHandCursor
              onClicked: { root.drillProject = ""; root.refresh(); Qt.callLater(function() { keyCatcher.forceActiveFocus() }) }
              Row {
                id: backRow
                anchors.left: parent.left
                anchors.verticalCenter: parent.verticalCenter
                anchors.leftMargin: Style.space(12)
                spacing: Style.space(8)
                Text {
                  text: "←"
                  color: root.accent
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.title
                  anchors.verticalCenter: parent.verticalCenter
                }
                Text {
                  text: "zurück zur Übersicht"
                  color: root.foreground
                  font.family: root.fontFamily
                  font.pixelSize: Style.font.body
                  anchors.verticalCenter: parent.verticalCenter
                }
              }
            }
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

              // EINE Zeile ist eine Gruppenzeile, wenn modelData.group existiert
              // und kein Drill-Down-Treffer (svc) vorliegt.
              readonly property bool isGroupRow: root.drillProject === "" && !!modelData.group
              readonly property var svc: modelData.svc
              readonly property string svcName: svc ? (svc.name || "?") : "?"
              readonly property string groupName: modelData.group ? (modelData.group.name || modelData.project) : ""

              hasCursor: root.cursorActive && index === root.focusedIndex
              current: root.drillProject === "" ? false : (modelData.svc.running === true)
              bordered: false
              foreground: root.foreground
              accent: root.accent

              width: parent.width
              implicitHeight: rowCol.implicitHeight + Style.space(20)

              MouseArea {
                id: rowMouse
                anchors.fill: parent
                hoverEnabled: true
                acceptedButtons: Qt.LeftButton | Qt.RightButton
                cursorShape: Qt.PointingHandCursor

                onContainsMouseChanged: if (containsMouse) {
                  root.cursorActive = true
                  root.focusedIndex = index
                }

                // Rechtsklick auf Gruppenzeile = Drill-Down in die Unteransicht.
                onClicked: function(mouse) {
                  if (mouse.button === Qt.RightButton) {
                    if (row.isGroupRow) {
                      root.drillProject = modelData.project
                      root.cursorActive = false
                      Qt.callLater(function() { keyCatcher.forceActiveFocus() })
                    }
                    return
                  }
                  // Linksklick
                  if (row.isGroupRow) {
                    var pk = modelData.project
                    // Misch- oder All-Laufend: 2×-Flow stoppt alle AKTIVEN.
                    if (root.groupState(pk) !== "off") {
                      if (root.confirmTarget === pk) root.action("groupstop", pk)
                      else root.confirmTarget = pk
                    } else {
                      root.action("groupstart", pk)
                    }
                    return
                  }
                  // Einzeldienst (auch im Drill-Down): 1× start, 2× stop.
                  var key = modelData.project + "/" + modelData.svc.name
                  if (modelData.svc.running === true) {
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
                    text: row.isGroupRow ? root.groupGlyph(modelData.project) : statusGlyph(modelData.svc)
                    color: row.isGroupRow ? root.groupColor(modelData.project) : svcColor(modelData.svc)
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.body
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    width: parent.width - typePill.width - statusText.width - Style.space(16)
                    text: row.isGroupRow ? row.groupName : (modelData.svc.name || "?")
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
                      text: row.isGroupRow ? "Gruppe" : typeLabel(modelData.svc.type)
                      color: root.dim
                      font.family: root.fontFamily
                      font.pixelSize: Style.font.caption - 1 > 8 ? Style.font.caption - 1 : 8
                    }
                  }

                  Text {
                    id: statusText
                    text: {
                      if (row.isGroupRow) {
                        var c = root.groupRunningCount(modelData.project)
                        var svcLen = (modelData.group.services || []).length
                        return c + " / " + svcLen + " aktiv"
                      }
                      var parts = []
                      if (modelData.svc.detail) parts.push(modelData.svc.detail)
                      if (modelData.svc.port) parts.push(":" + modelData.svc.port + (modelData.svc.port_open === true ? " ✓" : " ✗"))
                      if (modelData.svc.firewall === true) {
                        parts.push(modelData.svc.allowed === true ? "fw ✓" :
                                   (modelData.svc.allowed === false ? "fw ✕" : "fw …"))
                      }
                      return parts.join(" · ")
                    }
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
                    text: row.isGroupRow ? ("♢ Gruppe · " + modelData.project + " · Rechtsklick = Details") : ("▣ " + modelData.project)
                    color: row.isGroupRow ? root.accent : root.dim
                    font.family: root.fontFamily
                    font.pixelSize: Style.font.caption
                    elide: Text.ElideRight
                    width: parent.width - actionHint.width - Style.space(8)
                    anchors.verticalCenter: parent.verticalCenter
                  }

                  Text {
                    id: actionHint
                    text: {
                      if (row.isGroupRow) {
                        var pk = modelData.project
                        if (root.confirmTarget === pk) return "Erneut klicken = ALLE stoppen"
                        if (root.groupState(pk) !== "off") return "Klick: Alle stoppen"
                        if (root.busy) return "…"
                        return "Klick: Alle starten"
                      }
                      var key = modelData.project + "/" + modelData.svc.name
                      if (root.confirmTarget === key) return "Erneut klicken = STOPP"
                      if (modelData.svc.running === true) return "Klick: Stoppen"
                      if (root.busy) return "…"
                      return "Klick: Starten"
                    }
                    color: (row.isGroupRow ? root.confirmTarget === modelData.project : root.confirmTarget === (modelData.project + "/" + modelData.svc.name)) ? root.errColor : root.dim
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
