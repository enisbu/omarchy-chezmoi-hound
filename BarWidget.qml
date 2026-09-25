import QtQuick
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

Panel {
  id: root
  moduleName: "enisbu.chezmoi-hound"
  ipcTarget: "enisbu.chezmoi-hound"
  manageIpc: false

  readonly property string checkScript: Qt.resolvedUrl("bin/chezmoi-hound-check").toString().replace(/^file:\/\//, "")
  readonly property string actScript: Qt.resolvedUrl("bin/chezmoi-hound-act").toString().replace(/^file:\/\//, "")
  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family
  readonly property int maxRows: 4

  property var sides: ({ chezmoi: emptySide(), claude: emptySide() })
  property int scripts: 0
  property string fetched: ""
  property string problem: ""
  property string runningSide: ""
  property var errors: ({ chezmoi: "", claude: "" })
  property bool pendingFetch: false

  readonly property bool drift: sideDirty("chezmoi") || sideDirty("claude") || errors.chezmoi !== "" || errors.claude !== ""

  function emptySide() { return { local: [], incoming: [], commits: 0, unpushed: 0 } }

  function side(name) { return sides[name] || emptySide() }

  function sideDirtyIn(all, dueScripts, name) {
    var s = all[name] || emptySide()
    return s.local.length + s.incoming.length + s.commits + s.unpushed > 0 || (name === "chezmoi" && dueScripts > 0)
  }

  function sideDirty(name) { return sideDirtyIn(sides, scripts, name) }

  function summary(name) {
    var s = side(name)
    var parts = []
    var changed = rows(name).filter(function (r) { return !r.incoming }).length
    if (changed > 0) parts.push(changed + " geändert")
    if (s.commits > 0) parts.push(s.commits + " eingehend")
    else if (s.incoming.length > 0) parts.push(s.incoming.length + " anzuwenden")
    if (s.unpushed > 0) parts.push(s.unpushed + " ausgehend")
    if (name === "chezmoi" && scripts > 0) parts.push(scripts + (scripts === 1 ? " Skript fällig" : " Skripte fällig"))
    return parts.length > 0 ? parts.join(" · ") : "synchron"
  }

  function unit(path) { return path.split("/").slice(0, 3).join("/") }

  function rows(name) {
    var s = side(name)
    var out = []
    var seen = {}
    function add(path, incoming) {
      var key = (incoming ? "in:" : "local:") + unit(path)
      if (seen[key]) { seen[key].count++; return }
      seen[key] = { path: unit(path), incoming: incoming, count: 1 }
      out.push(seen[key])
    }
    for (var i = 0; i < s.local.length; i++) add(s.local[i], false)
    for (var j = 0; j < s.incoming.length; j++)
      if (s.local.indexOf(s.incoming[j]) === -1) add(s.incoming[j], true)
    return out
  }

  function parse(text) {
    var next = { chezmoi: emptySide(), claude: emptySide() }
    var nextScripts = 0, nextFetched = "", err = ""
    var lines = String(text || "").split("\n")
    for (var i = 0; i < lines.length; i++) {
      var f = lines[i].split("\t")
      var key = f[0]
      if (key === "local" || key === "incoming") {
        if (next[f[1]] && f[2]) next[f[1]][key].push(f[2])
      } else if (key === "commits" || key === "unpushed") {
        if (next[f[1]]) next[f[1]][key] = Number(f[2]) || 0
      } else if (key === "scripts") nextScripts = Number(f[1]) || 0
      else if (key === "fetched") nextFetched = f[1] || ""
      else if (key === "error") err = f[1] || ""
    }
    sides = next
    if (!actProc.running) runningSide = ""
    if (runningSide === "") {
      var e = Object.assign({}, errors)
      for (var k in e) if (!sideDirtyIn(next, nextScripts, k)) e[k] = ""
      errors = e
    }
    scripts = nextScripts
    fetched = nextFetched
    problem = err
  }

  function refresh(fetch) {
    if (checkProc.running) {
      if (fetch) pendingFetch = true
      return
    }
    checkProc.command = fetch ? [checkScript, "--fetch"] : [checkScript]
    checkProc.running = true
  }

  function sync(name) {
    if (actProc.running || !sideDirty(name)) return
    var e = Object.assign({}, errors)
    e[name] = ""
    errors = e
    runningSide = name
    actProc.command = [actScript, "sync", name]
    actProc.running = true
  }

  function resolve(name) {
    Quickshell.execDetached([actScript, "resolve", name])
    close()
  }

  visible: drift || opened || actProc.running
  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  onOpenedChanged: if (opened) refresh(true)

  Timer {
    interval: 300000
    running: true
    repeat: true
    triggeredOnStart: true
    onTriggered: root.refresh(false)
  }

  Timer {
    interval: 900000
    running: true
    repeat: true
    onTriggered: root.refresh(true)
  }

  Process {
    id: checkProc
    stdout: StdioCollector { id: checkOut; waitForEnd: true }
    onExited: {
      root.parse(checkOut.text)
      if (root.pendingFetch) {
        root.pendingFetch = false
        root.refresh(true)
      }
    }
  }

  Process {
    id: actProc
    stdout: StdioCollector { id: actOut; waitForEnd: true }
    onExited: function(code) {
      var m = String(actOut.text || "").match(/^error\t(.*)$/m)
      var e = Object.assign({}, root.errors)
      e[root.runningSide] = code === 0 ? "" : (m ? m[1] : "Sync endete mit " + code)
      root.errors = e
      root.runningSide = ""
      root.refresh(false)
    }
  }

  IpcHandler {
    target: "enisbu.chezmoi-hound"
    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }
    function status(): string {
      return "visible=" + root.visible + " opened=" + root.opened
        + " chezmoi=" + root.summary("chezmoi").replace(/ /g, "_")
        + " claude=" + root.summary("claude").replace(/ /g, "_")
        + " running=" + (actProc.running ? root.runningSide : "none")
        + " errChezmoi=" + (root.errors.chezmoi || "none").replace(/ /g, "_")
        + " errClaude=" + (root.errors.claude || "none").replace(/ /g, "_")
        + " fetched=" + (root.fetched || "never").replace(/ /g, "_")
        + " problem=" + (root.problem || "none").replace(/ /g, "_")
    }
  }

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰓦"
    tooltipText: "Dotfiles nicht synchron"
    onPressed: root.toggle()

  }

  Rectangle {
    anchors.right: button.right
    anchors.rightMargin: Style.space(3)
    anchors.top: button.top
    anchors.topMargin: Style.space(5)
    width: Style.space(6)
    height: width
    radius: width / 2
    color: Color.accent
  }

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(600))
    contentHeight: panel.fittedContentHeight(content.implicitHeight)

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      onCloseRequested: root.close()
      onTabRequested: function(direction) { root.switchPanel(direction) }

      ColumnLayout {
        id: content
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(10)

        RowLayout {
          Layout.fillWidth: true
          spacing: Style.space(16)

          SideColumn { name: "chezmoi"; title: "chezmoi" }
          Rectangle {
            Layout.fillHeight: true
            implicitWidth: 1
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.12)
          }
          SideColumn { name: "claude"; title: "Claude" }
        }

        PanelSeparator { Layout.fillWidth: true; foreground: root.foreground }

        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: root.problem !== "" ? root.problem
            : "Abgleich " + (root.fetched !== "" ? root.fetched.replace(/^.* /, "") : "nie")
          color: root.problem !== "" ? root.urgent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.caption
          elide: Text.ElideRight
        }
      }
    }
  }

  component SideColumn: ColumnLayout {
    id: col
    property string name: ""
    property string title: ""
    readonly property var list: root.rows(name)
    readonly property bool dirty: root.sideDirty(name)
    readonly property string error: root.errors[name] || ""
    readonly property bool busy: actProc.running && root.runningSide === name

    Layout.fillWidth: true
    Layout.fillHeight: true
    Layout.preferredWidth: 1
    Layout.alignment: Qt.AlignTop
    spacing: Style.space(4)

    PanelSectionHeader {
      Layout.fillWidth: true
      text: col.title
      foreground: root.foreground
      fontFamily: root.fontFamily
    }

    Text {
      Layout.fillWidth: true
      Layout.bottomMargin: Style.space(4)
      textFormat: Text.PlainText
      text: root.summary(col.name)
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.bodySmall
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }

    Repeater {
      model: col.list.slice(0, root.maxRows)
      RowLayout {
        required property var modelData
        Layout.fillWidth: true
        spacing: Style.space(6)
        Text {
          textFormat: Text.PlainText
          text: modelData.incoming ? "↓" : "•"
          color: modelData.incoming ? Color.accent : root.dim
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
        }
        Text {
          Layout.fillWidth: true
          textFormat: Text.PlainText
          text: "~/" + modelData.path + (modelData.count > 1 ? "  (" + modelData.count + ")" : "")
          color: root.foreground
          font.family: root.fontFamily
          font.pixelSize: Style.font.bodySmall
          elide: Text.ElideMiddle
        }
      }
    }

    Text {
      visible: col.list.length > root.maxRows
      Layout.fillWidth: true
      textFormat: Text.PlainText
      text: "+" + (col.list.length - root.maxRows) + " weitere"
      color: root.dim
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
    }

    Item { Layout.fillHeight: true }

    Text {
      visible: col.error !== ""
      Layout.fillWidth: true
      textFormat: Text.PlainText
      text: col.error
      color: root.urgent
      font.family: root.fontFamily
      font.pixelSize: Style.font.caption
      wrapMode: Text.Wrap
      maximumLineCount: 2
      elide: Text.ElideRight
    }

    RowLayout {
      Layout.topMargin: Style.space(4)
      spacing: Style.space(6)
      visible: col.dirty || col.busy || col.error !== ""

      Button {
        text: col.busy ? "läuft…" : "Sync"
        iconText: col.busy ? "󰑓" : ""
        iconSpinning: col.busy
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        enabled: !actProc.running && col.dirty
        opacity: enabled || col.busy ? 1 : 0.5
        onClicked: root.sync(col.name)
      }

      Button {
        visible: col.error !== "" && !col.busy
        text: "Mit Claude lösen"
        bordered: true
        foreground: root.foreground
        fontFamily: root.fontFamily
        onClicked: root.resolve(col.name)
      }
    }
  }
}
