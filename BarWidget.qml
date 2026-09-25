import QtQuick
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui
// Qualified, and only for the multi-line entry: an unqualified
// QtQuick.Controls import would shadow the kit's own Button and TextField.
import QtQuick.Controls as QQC

// Chezmoi Hound - a count of dotfile drift, and the two things it makes you
// want to do about it.
//
// The number is three parts added up: managed targets this machine has edited
// and the source has not captured, paths the source repo's own working tree is
// holding uncommitted, and commits the remote has not seen. The badge is silent
// while everything is in sync - a permanent zero is noise.
//
// Neither the counting nor the git work happens in QML. bin/chezmoi-hound-check
// is polled on a timer and answers in a line protocol, and the panel's two
// buttons run bin/chezmoi-hound-act. Both ship next to this file, so the plugin
// depends on chezmoi and git and on nothing else the author happens to have
// installed; the widget itself never shells out to git.
Panel {
  id: root
  moduleName: "enisbu.chezmoi-hound"
  ipcTarget: "enisbu.chezmoi-hound"
  // manageIpc: false because this file owns the single IpcHandler the target
  // allows, so it can answer status()/geometry() as well as open/close.
  manageIpc: false

  // ---- bar geometry -------------------------------------------------------
  // A popup widget is a Panel, which carries no bar geometry of its own, so the
  // two properties every bar widget reads are defined here with a fallback for
  // the moment before the host injects `bar`.
  readonly property bool vertical: bar ? bar.vertical : false
  readonly property int barSize: bar ? bar.barSize : Style.bar.sizeHorizontal

  // ---- settings -----------------------------------------------------------
  // The source directory is the one setting that cannot be guessed: a machine
  // that passes `chezmoi --source DIR` in a wrapper has no source in chezmoi's
  // own configuration, so `chezmoi source-path` cannot name it. Empty means
  // "whatever chezmoi is configured with".
  readonly property string sourceDir: String(setting("sourceDir", "")).replace(/^\s+|\s+$/g, "")

  readonly property int checkSeconds: {
    var n = Number(setting("checkSeconds", 300))
    if (!isFinite(n) || n < 60) return 300      // a floor, not a preference:
    if (n > 3600) return 3600                   // this runs git on a timer
    return Math.floor(n)
  }
  readonly property int pollInterval: root.checkSeconds * 1000

  readonly property bool showWhenClean: String(setting("whenClean", "Hide")) === "Show"

  // Section titles. The shared PanelSectionHeader is bold already - what made
  // these read weakly was its default colour, dimmed 1.4x to sit under a hero
  // this panel no longer has, which left a title the same grey as the rows it
  // introduces. They take the full-strength foreground here.
  readonly property color sectionTitleColor: root.bar.foreground

  // The AI CLI that may write a commit message. Empty means "whichever one is
  // installed and logged in here", which the act script resolves and reports
  // back; naming one forces it, authenticated or not.
  readonly property string aiCommand: String(setting("aiCommand", "")).replace(/^\s+|\s+$/g, "")
  // The button's name has to match the command that will actually run, whether
  // that came from this panel's own field or from `omarchy bar set` outside it.
  onAiCommandChanged: root.probeAi()

  // ---- the plugin's own scripts ------------------------------------------
  // Resolved next to this file, because a plugin that shells out to something
  // in one user's ~/.local/bin only works on the machine it was written on.
  readonly property string checkScript: Qt.resolvedUrl("bin/chezmoi-hound-check").toString().replace(/^file:\/\//, "")
  readonly property string actScript: Qt.resolvedUrl("bin/chezmoi-hound-act").toString().replace(/^file:\/\//, "")

  // A reading is input from another process, so it is bounded in size, type-
  // and range-checked, and a reading that disagrees with itself is rejected
  // outright instead of shown half-believed.
  readonly property int maxBytes: 65536

  property int homeCount: 0
  property int repoCount: 0
  property int unpushed: 0
  property int total: 0
  property var detail: []
  property var commits: []
  property var repoDetail: []
  property var recentCommits: []      // "<sha>  <subject>", newest first
  property var notes: []
  property string stamp: ""
  property string reportedSource: ""
  property string branchName: ""
  property string upstream: ""
  property string problem: ""
  property bool everLoaded: false

  // ---- action state -------------------------------------------------------
  // Which action is in flight ("" when idle). While one runs the buttons are
  // inert: two commits racing over the same index, or a commit and a push
  // interleaving, is how a half-captured tree gets committed.
  property string running: ""
  property var logLines: []
  // The outcome of the last action as state, not log text: the panel says what
  // happened and then offers the one thing that makes sense next - close it,
  // or try again.
  property string result: ""          // "" | "ok" | "error"
  property string resultText: ""
  property string lastAction: ""
  // Set when a re-check is asked for while one is already running.
  property bool pendingRecheck: false

  // ---- the commit message -------------------------------------------------
  // A commit only says something if a person wrote it, so the button opens an
  // entry rather than firing a commit with wording nobody chose. The entry
  // arrives empty and stays that way unless someone types in it or asks an agent
  // to write it: nothing the script can work out on its own is offered as a
  // substitute message.
  property bool asking: false         // the message entry is open
  // Which drift section that entry is open in: "home" for what was edited here,
  // "repo" for what is uncommitted in the source tree. One entry, and it lives
  // in the section whose button asked for it.
  property string askWhere: "home"
  property bool suggesting: false     // a suggestion call is in flight
  property string aiCli: ""           // the CLI that can write one, "" for none
  property string lastMessage: ""     // what the last commit was told to say
  // The undo confirm. `undoRow` is what is on screen and is dropped the moment
  // the confirm is pressed; `undoSha` is what the script is told, and outlives it
  // so that retry re-runs the same commit rather than an empty one.
  property string undoRow: ""
  property string undoSha: ""
  property string suggestHint: ""     // one line under the entry, on what it holds
  property bool settingsOpen: false   // the widget's own options are showing
  // The ignore confirm. It has no entry: the paths are already named under the
  // button, so the confirm says what will be written and nothing else.
  property bool ignoring: false       // the .chezmoiignore confirm is open

  // -1 means "the record was there but was not a count", which is different
  // from 0 and must not be mistaken for a valid reading.
  function countOf(value) {
    var n = Number(String(value))
    return (isFinite(n) && n >= 0 && n <= 100000) ? Math.floor(n) : -1
  }

  // The reading is a line protocol - "key<TAB>value", one record per line, in
  // no particular order - so the widget needs no JSON parser and the script
  // needs no jq.
  function apply(raw) {
    var text = String(raw || "")
    if (text.length === 0 || text.length > maxBytes) return false

    var lines = text.split("\n")
    var home = -1, repo = -1, unpushed = -1, total = -1
    var detail = [], commits = [], repoDetail = [], notes = [], recent = []
    var src = "", branch = "", upstream = "", stamp = "", problem = ""

    for (var i = 0; i < lines.length; i++) {
      var line = lines[i]
      if (line === "") continue
      var tab = line.indexOf("\t")
      var key = tab < 0 ? line : line.substring(0, tab)
      var value = tab < 0 ? "" : line.substring(tab + 1)

      if (key === "home") home = countOf(value)
      else if (key === "repo") repo = countOf(value)
      else if (key === "unpushed") unpushed = countOf(value)
      else if (key === "total") total = countOf(value)
      else if (key === "file") { if (detail.length < 8) detail.push(plain(value)) }
      else if (key === "commit") { if (commits.length < 8) commits.push(plain(value)) }
      else if (key === "repofile") { if (repoDetail.length < 8) repoDetail.push(plain(value)) }
      else if (key === "recent") {
        // One record, three tabs: <sha> <when> <subject>.
        var parts = value.split("\t")
        if (recent.length < 20 && parts.length >= 3)
          // sha, then subject. No age: it padded the one column you are
          // least likely to be reading, and --render still prints it.
          recent.push(plain(parts[0] + "  " + parts[2]))
      }
      else if (key === "note") { if (notes.length < 4) notes.push(plain(value)) }
      else if (key === "error") problem = plain(value)
      else if (key === "source") src = plain(value)
      else if (key === "branch") branch = plain(value)
      else if (key === "upstream") upstream = plain(value)
      else if (key === "stamp") stamp = value.substring(0, 32)
    }

    // An error record is a complete answer: say so and keep the last reading.
    if (problem !== "") {
      root.problem = problem
      return false
    }
    // The three parts must add up; a reading that disagrees with itself is
    // rejected rather than shown half-believed.
    if (home < 0 || repo < 0 || unpushed < 0 || total < 0) return false
    if (home + repo + unpushed !== total) return false

    root.homeCount = home
    root.repoCount = repo
    root.unpushed = unpushed
    root.total = total
    root.detail = detail
    root.commits = commits
    root.repoDetail = repoDetail
    root.recentCommits = recent
    root.notes = notes
    root.reportedSource = src
    root.branchName = branch
    root.upstream = upstream
    root.stamp = stamp
    root.problem = ""
    root.everLoaded = true
    return true
  }

  // bar.showTooltip renders with AutoText, which this plugin cannot pin to
  // PlainText, so markup and control characters are stripped before handoff.
  function plain(value) {
    return String(value)
      .replace(/[<>&]/g, "")
      .replace(/[\u0000-\u001f\u007f-\u009f\u200e\u200f\u202a-\u202e\u2066-\u2069]/g, "")
      .substring(0, 200)
  }

  function plural(count, noun) {
    return count + " " + noun + (count === 1 ? "" : "s")
  }

  function tooltip() {
    if (root.total === 0) {
      return root.everLoaded
        ? "Dotfiles in sync" + (root.stamp ? "  ·  checked " + root.stamp : "")
        : "No dotfiles reading yet  ·  the first check is on its way"
    }

    var parts = []
    if (root.homeCount > 0) parts.push(root.homeCount + " changed in $HOME")
    if (root.repoCount > 0) parts.push(root.repoCount + " uncommitted")
    if (root.unpushed > 0) parts.push(root.unpushed + " unpushed")
    var out = "Dotfiles out of sync: " + parts.join("  ·  ")

    if (root.detail.length > 0) {
      out += "\n" + root.detail.join("\n")
      if (root.homeCount > root.detail.length) out += "\n…"
    }
    if (root.stamp) out += "\nchecked " + root.stamp
    out += "\nclick: push / commit what is drifting"
    return out
  }

  // Naive plural: these are file counts, never language-facing prose.
  function countText() {
    return String(root.total)
  }

  // A divider with nothing on one side of it is a stray line, not a divider.
  function commitsDividerShown() {
    if (root.recentCommits.length === 0 && root.unpushed === 0) return false
    return root.problem !== "" || root.notes.length > 0
        || root.homeCount > 0 || root.repoCount > 0 || root.total === 0
  }

  // The history's heading. Its count is only ever the part of the history the
  // remote has not seen - the rows speak for themselves, and a total next to
  // an unfixed number was two counts doing one job.
  function commitsTitle() {
    if (root.unpushed <= 0) return "LATEST COMMITS"
    return "LATEST COMMITS \u2014 " + root.plural(root.unpushed, "commit") + " not pushed"
  }

  // The full text in a floating terminal. The badge's right-click and the
  // panel's button both come here, because detailProc does nothing until its
  // command is set: assigning `running` on a Process with no command starts
  // nothing, which is exactly what the panel's button used to do.
  function showDetails() {
    if (detailProc.running) return
    detailProc.command = withSource(["/usr/bin/omarchy-launch-floating-terminal-with-presentation",
                                     root.checkScript, "--render"])
    detailProc.running = true
  }

  // One option, written back into this widget's entry in the bar layout. The
  // running shell does it in process; `omarchy bar set` is the same write from
  // outside, kept for the moment the shell API is not there to be called.
  function saveSetting(key, value) {
    var entry = { id: root.moduleName }
    for (var existing in root.settings) if (existing !== "id") entry[existing] = root.settings[existing]
    entry[key] = value
    root.settings = entry
    // The button names the agent that will answer it, so replacing that setting
    // re-probes now instead of waiting for the next panel open: the button is the
    // status, and one naming the CLI you just replaced is worse than none.
    if (key === "aiCommand") root.probeAi(value)
    if (root.bar && root.bar.shell && typeof root.bar.shell.updateEntryInline === "function") {
      root.bar.shell.updateEntryInline(root.moduleName, entry)
      return
    }
    if (saveProc.running) return
    saveProc.command = ["omarchy", "bar", "set", root.moduleName, key, String(value)]
    saveProc.running = true
  }

  // ---- actions ------------------------------------------------------------

  // Both buttons go through here, so there is exactly one place that decides
  // what a click runs and one place that refreshes the badge afterwards.
  function runAction(what) {
    if (actionProc.running || root.running !== "") return
    root.logLines = []
    root.result = ""
    root.resultText = ""
    root.lastAction = what
    root.running = what
    // A commit carries whatever the message entry was holding. A push never
    // does: writing a commit message must not quietly become permission to
    // publish it, which stays a separate thing to authorise.
    var args
    if (what === "push") {
      args = ["push"]
    } else if (what === "undo") {
      // One commit, named by its own sha: never a range, never a reflog word.
      args = ["undo", "--commit", root.undoSha]
    } else if (what === "ignore") {
      // The paths the panel is showing, named one at a time. The script will
      // fall back to whatever is drifting if it is given none, but the panel
      // already knows which ones its button was pressed against, and a list the
      // person can see before pressing is worth more than one it works out.
      args = ["ignore"]
      for (var i = 0; i < root.detail.length; i++) {
        var p = String(root.detail[i]).replace(/^\s+/, "")
        if (p !== "") args.push("--path", p)
      }
    } else {
      args = ["commit"]
      if (root.lastMessage !== "") args.push("--message", root.lastMessage)
    }
    // 180s: capturing a large tree can take a while, and a half-captured tree
    // abandoned by a timeout is worse than a slow button.
    actionProc.command = withSource(["/usr/bin/timeout", "-k", "2", "180", root.actScript].concat(args))
    actionProc.running = true
  }

  // The source argument is appended in exactly one place, so no call can forget
  // it and read a different tree than the badge is showing.
  function withSource(args) {
    var out = [].concat(args)
    if (root.sourceDir !== "") out.push("--source", root.sourceDir)
    return out
  }

  // Run the last action again - the other half of a failure.
  function retry() {
    if (root.lastAction !== "") root.runAction(root.lastAction)
  }

  // ---- taking a commit back -----------------------------------------------
  // The button only asks. Nothing moves until the confirm is pressed, because
  // this is the one control here that changes what the history holds, and it is
  // an icon: small enough to hit while reaching for something else.
  function askUndo(row) {
    if (root.running !== "" || actionProc.running) return
    root.asking = false
    root.undoRow = String(row).replace(/^\s+/, "")
    root.undoSha = root.undoRow.split(/\s+/)[0]
  }

  function keepCommit() {
    root.undoRow = ""
    root.undoSha = ""
  }

  function runUndo() {
    if (root.undoSha === "") return
    root.undoRow = ""            // the confirm goes; the sha stays for retry
    root.runAction("undo")
  }

  // ---- the message entry --------------------------------------------------

  // What the commit button does before it commits: open an empty entry and hand
  // the field the keyboard. Nothing is worked out and filled in on the person's
  // behalf - a message a script derived from the paths is not what they would
  // have written, and it is theirs to write.
  function askCommit(where) {
    if (root.running !== "" || actionProc.running) return
    root.undoRow = ""
    root.askWhere = where === "repo" ? "repo" : "home"
    root.asking = true
    root.suggestHint = ""
    messageField.text = ""
    messageField.forceActiveFocus()
  }

  function cancelCommit() {
    root.asking = false
    root.suggestHint = ""
    messageField.text = ""
  }

  // ---- the ignore confirm -------------------------------------------------
  // The same shape as the undo confirm: the button only asks, and the write
  // happens on the second press. Nothing moves in $HOME either way - this adds
  // lines to the source's .chezmoiignore, which is why the confirm says so.
  function askIgnore() {
    if (root.running !== "" || actionProc.running || root.detail.length === 0) return
    root.asking = false
    root.undoRow = ""
    root.ignoring = true
  }

  function cancelIgnore() {
    root.ignoring = false
  }

  function runIgnore() {
    root.ignoring = false
    root.runAction("ignore")
  }

  // Which CLI could write a message. Asked of the script rather than guessed from
  // the setting, because a command that is set but not installed must not put a
  // button on screen that can only fail. Called when the panel opens, and again
  // whenever that setting changes: the button carries this name as its status, so
  // a button naming the CLI you just replaced is worse than no status at all.
  function probeAi(aiOverride) {
    if (probeProc.running) return
    var ai = aiOverride === undefined ? root.aiCommand : String(aiOverride)
    var args = [root.actScript, "suggest", "--probe"]
    if (ai !== "") args.push("--ai", ai)
    probeProc.command = withSource(args)
    probeProc.running = true
  }

  // Asking an AI for wording is its own button, so a suggestion is always
  // something a person asked for: no keystroke of the entry sends the diff
  // anywhere by itself.
  function suggestMessage() {
    if (suggestProc.running || root.aiCli === "" || root.running !== "") return
    root.suggesting = true
    // In flight is the button's business - it already reads "Asking <cli>…".
    // The line under the entry is for what came back (who wrote it, or why
    // nobody did), so it stays empty until there is something to say.
    root.suggestHint = ""
    var args = [root.actScript, "suggest"]
    if (root.aiCommand !== "") args.push("--ai", root.aiCommand)
    // 150s: a one-shot agent call is slow the first time and there is a timeout
    // inside this one as well, so the button always comes back.
    suggestProc.command = withSource(["/usr/bin/timeout", "-k", "2", "150"].concat(args))
    suggestProc.running = true
  }

  // The commit itself, carrying the field's text exactly as it reads. An empty
  // entry commits with an empty message: the script passes
  // --allow-empty-message, so the commit holds the blank the person left rather
  // than words invented for them.
  function commitNow() {
    if (root.running !== "" || actionProc.running) return
    root.lastMessage = messageField.text
    root.asking = false
    root.suggestHint = ""
    root.runAction("commit")
  }

  // There is one bar surface per monitor, so there is one of us per screen. An
  // action lands on the instance that was clicked; the others are told to
  // re-check, or the other monitor keeps showing the count from before it.
  function notifyPeers() {
    var items = root.bar && typeof root.bar.moduleWidgets === "function"
      ? root.bar.moduleWidgets(root.moduleName) : []
    for (var i = 0; i < items.length; i++) {
      if (items[i] && items[i] !== root && typeof items[i].syncFromPeer === "function")
        items[i].syncFromPeer()
    }
  }

  // A peer can be mid-check when the call lands; the flag makes it run the
  // check again the moment the one in flight finishes, instead of leaving the
  // other monitor showing the count from before the action.
  function syncFromPeer() {
    if (checkProc.running) {
      root.pendingRecheck = true
      return
    }
    root.refresh(false)
  }

  // `notify` is true only where the reading changed because of something the
  // user did; the timer passes nothing, so a tick cannot ping-pong between
  // monitors.
  function refresh(notify) {
    // Peers are told first and unconditionally: an action must never leave
    // another monitor showing the count from before it, and a check of our own
    // already in flight must not swallow that.
    if (notify === true) notifyPeers()
    if (checkProc.running) {
      root.pendingRecheck = true
      return
    }
    checkProc.command = withSource(["/usr/bin/timeout", "-k", "2", "60", root.checkScript])
    checkProc.running = true
  }

  visible: root.total > 0 || root.showWhenClean
  implicitWidth: vertical ? barSize : (badge.width + Style.spaceReal(6))
  implicitHeight: vertical ? (badge.height + Style.spaceReal(6)) : barSize

  // The reading is taken on a timer rather than watched in a file: it is a few
  // chezmoi and git calls, and doing it here means the badge is right on a
  // machine that has never heard of a systemd timer.
  Timer {
    interval: root.pollInterval
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.refresh()
  }

  // Right-click only: the old behaviour, kept because a floating terminal is
  // the one place the full `git diff`-worthy detail can be copied out of.
  Process {
    id: detailProc
  }

  // Only used when the running shell cannot take the setting in process.
  Process {
    id: saveProc
  }

  Row {
    id: badge
    anchors.centerIn: parent

    // Just the count. A Nerd Font glyph used to sit to its left; it was dropped
    // because the codepoint it used draws a barcode in this font, not a git
    // icon, and a bare number is clearer than a number with a puzzle next to it.
    Text {
      id: badgeLabel
      anchors.verticalCenter: parent.verticalCenter
      textFormat: Text.PlainText
      text: root.countText()
      // One colour whether or not there is anything to report: a dimmed zero
      // read as a different kind of number rather than as "nothing to do".
      color: Color.foreground
      font.family: root.bar ? root.bar.fontFamily : Style.font.family
      font.pixelSize: Math.max(9, Math.round(root.barSize * 0.5))
      renderType: Text.NativeRendering
    }
  }

  MouseArea {
    anchors.fill: parent
    acceptedButtons: Qt.LeftButton | Qt.MiddleButton | Qt.RightButton
    hoverEnabled: true
    cursorShape: Qt.PointingHandCursor

    // Left opens the panel, which both lists the drift and offers the two
    // actions. Middle re-runs the check now rather than waiting for the timer.
    // Right keeps the floating terminal for the full text.
    onClicked: function (mouse) {
      if (root.bar) root.bar.hideTooltip(root)
      if (mouse.button === Qt.LeftButton) {
        root.toggle()
      } else if (mouse.button === Qt.MiddleButton) {
        root.refresh()
      } else {
        root.showDetails()
      }
    }
    onEntered: if (root.bar && !root.opened) root.bar.showTooltip(root, root.tooltip())
    onExited: if (root.bar) root.bar.hideTooltip(root)
  }

  Process {
    id: checkProc
    stdout: StdioCollector {
      id: checkOut
      waitForEnd: true
    }
    stderr: StdioCollector {
      id: checkErr
      waitForEnd: true
    }
    onExited: function (code, status) {
      var applied = root.apply(checkOut.text)
      if (!applied && root.problem === "") {
        var err = plain(String(checkErr.text || "").trim())
        root.problem = err !== "" ? err : "chezmoi-hound-check exited " + code
      }
      // Someone asked for a fresh reading while this one was in flight.
      if (root.pendingRecheck) {
        root.pendingRecheck = false
        root.refresh(false)
      }
    }
  }

  Process {
    id: actionProc
    stdout: SplitParser {
      onRead: function (line) {
        var next = root.logLines.slice()
        next.push(String(line))
        // Bounded: this is a panel, not a scrollback.
        if (next.length > 12) next = next.slice(next.length - 12)
        root.logLines = next
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var text = String(text || "").trim()
        if (text === "") return
        var next = root.logLines.slice()
        next.push(text)
        if (next.length > 12) next = next.slice(next.length - 12)
        root.logLines = next
      }
    }
    onExited: function (exitCode, exitStatus) {
      root.running = ""
      // The outcome is stated rather than left in the log to be inferred from:
      // success says so and offers to close, failure says what broke and
      // offers to try again.
      var tail = root.logLines.length > 0
        ? String(root.logLines[root.logLines.length - 1]).trim() : ""
      if (exitCode === 0) {
        root.result = "ok"
        // The panel's own voice, not the script's last log line. Echoing the tail
        // used to read out "1 target(s) captured" - the script's summary of its
        // work, not the outcome the panel means to state. The detail stays in the
        // log, which Full details prints.
        root.resultText = root.lastAction === "push" ? "Pushed."
          : root.lastAction === "undo" ? "Undone."
          : root.lastAction === "ignore" ? "Added to .chezmoiignore — nothing here changed."
          : "Captured and committed."
      } else {
        root.result = "error"
        root.resultText = tail !== "" ? tail : "the action exited " + exitCode
      }
      // Re-read now rather than at the next tick, and tell the other monitors'
      // badges to do the same.
      root.refresh(true)
    }
  }

  // ---- the message entry's three processes ---------------------------------
  //
  // Two questions, one script: is there anything here that could write a message,
  // and what would an AI write. Separate processes because they are separate
  // questions, and only the last can take seconds.
  Process {
    id: probeProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var answer = String(text || "").trim()
        var found = answer.match(/^ai=(.+)$/)
        root.aiCli = found && found[1] !== "none" ? found[1] : ""
      }
    }
    onExited: function (exitCode, exitStatus) {
      if (exitCode !== 0) root.aiCli = ""
    }
  }

  // The suggestion call. It reports on stderr which of the three things happened
  // - a CLI wrote the message, no CLI is available here, or the CLI did not
  // answer - so the line under the entry never credits an AI for wording it did
  // not write, and a failed call is said out loud rather than papered over with
  // a message the script made up.
  Process {
    id: suggestProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var answer = String(text || "").trim()
        if (answer !== "") messageField.text = answer
      }
    }
    stderr: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var marker = String(text || "")
        var wrote = marker.match(/HOUND-SUGGEST ai=(.+)/)
        var failed = marker.match(/HOUND-SUGGEST failed=(\S+)(?: status=(\S+))?/)
        if (wrote) root.suggestHint = "Written by " + wrote[1].trim() + " - read it before committing."
        else if (failed) root.suggestHint = failed[1] + " could not write one"
                                                 + (failed[2] && failed[2] !== "0" ? " (exit " + failed[2] + ")" : "")
                                                 + "; the entry is yours to fill."
        else root.suggestHint = "No AI CLI here answered; the entry is yours to fill."
      }
    }
    onExited: function (exitCode, exitStatus) {
      root.suggesting = false
      if (exitCode !== 0) root.suggestHint = "The suggestion run exited " + exitCode + "."
    }
  }

  // The panel: the drift, then the commits, then the actions and this widget's
  // own options. Everything it shows comes from the cache, so opening it costs
  // nothing.
  KeyboardPanel {
    id: panel
    anchorItem: badge
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(420))
    contentHeight: panel.fittedContentHeight(column.implicitHeight)

    // The one thing worth asking the filesystem when the panel opens: whether
    // anything here could write the commit message. A couple of PATH lookups, so
    // it runs every time, and a CLI logged in since is picked up without a
    // restart. Closing forgets any half-typed message.
    onOpenChanged: {
      if (!open) {
        root.asking = false
        root.suggestHint = ""
        messageField.text = ""
        // An armed undo confirm is a question about a row that is no longer on
        // screen, so closing drops it. The target stays: Retry is still the last
        // action that ran.
        root.undoRow = ""
        return
      }
      if (probeProc.running) return
      root.probeAi()
    }

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While the message field holds the keyboard this must stay out of the
      // way: the catcher takes keys on Keys.BeforeItem, so Escape has to reach
      // the field to cancel the entry and Return has to reach it to commit.
      blocked: messageField.activeFocus || sourceField.activeFocus
               || checkField.field.activeFocus || aiField.activeFocus
      onCloseRequested: root.close()

      Column {
        id: column
        anchors.left: parent.left
        anchors.right: parent.right
        anchors.top: parent.top
        spacing: Style.space(12)

        // Whatever the reading could not do - no chezmoi, no source tree, a
        // git command that failed - is said plainly instead of leaving the
        // panel insisting everything is fine.
        Text {
          width: parent.width
          visible: root.problem !== "" || root.notes.length > 0
          textFormat: Text.PlainText
          text: root.problem !== "" ? root.problem : root.notes.join("\n")
          color: root.bar.foreground
          opacity: 0.7
          wrapMode: Text.WordWrap
          font.family: root.bar.fontFamily
          font.pixelSize: Style.font.bodySmall
        }

        // ---- what the repo has not got -------------------------------------
        // Two lists: what was edited on this machine and not captured, and what
        // is uncommitted in the source tree itself.
        Column {
          id: driftSection
          width: parent.width
          spacing: Style.space(8)
          // Always up, drift or none: the header is how the panel names the
          // section, and with nothing in the list the line under it says so in
          // words. It also has to stay up while its own entry is open, even when
          // a re-check empties the list behind it - a section that vanishes
          // mid-sentence takes the field with it.

          PanelSectionHeader {
            id: driftHeader
            text: root.homeCount > 0
              ? "DOTFILE DRIFT \u2014 " + root.plural(root.homeCount, "change")
              : "DOTFILE DRIFT"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            color: root.sectionTitleColor
          }

          Repeater {
            model: root.detail
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "  " + modelData
              color: root.bar.foreground
              opacity: 0.75
              elide: Text.ElideLeft
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Text {
            id: driftNote
            width: parent.width
            visible: root.homeCount === 0
            textFormat: Text.PlainText
            text: root.everLoaded
              ? "No drift detected — the files here match the source."
              : "No reading yet — the first check is on its way."
            color: root.bar.foreground
            opacity: 0.7
            wrapMode: Text.WordWrap
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              // Nothing to commit means no button: it is only ever the first half
              // of a commit. The ellipsis is the promise that it opens the message
              // rather than committing on the spot.
              visible: root.homeCount > 0
              text: root.running === "commit" ? "Committing…" : "Capture and commit " + root.plural(root.homeCount, "change") + "…"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              opacity: root.running === "" ? 1 : 0.45
              onClicked: root.askCommit("home")
            }

            Button {
              // The other answer to the same list: this was never a dotfile.
              // Beside the commit button because it is the choice made at the
              // same moment - capture it, or stop managing it - and the ellipsis
              // says it asks first.
              visible: root.homeCount > 0
              text: root.running === "ignore" ? "Ignoring…" : "Add to .chezmoiignore…"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              opacity: root.running === "" ? 1 : 0.45
              onClicked: root.askIgnore()
            }
          }

          // What the ignore button would write, said before it writes it: the
          // same paths the drift list names, and where they are going. Nothing in
          // $HOME is touched by this - which is the part worth saying out loud,
          // since "ignore this file" reads like it might delete or move it.
          Column {
            id: ignoreEntry
            width: parent.width
            spacing: Style.space(8)
            visible: root.ignoring

            PanelSectionHeader {
              text: "IGNORE IN CHEZMOI"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              color: root.sectionTitleColor
            }

            Repeater {
              model: root.detail
              Text {
                width: parent.width
                textFormat: Text.PlainText
                text: "  " + modelData
                color: root.bar.foreground
                opacity: 0.75
                elide: Text.ElideLeft
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Goes in the source's .chezmoiignore, so chezmoi stops managing "
                + "and counting " + root.plural(root.detail.length, "path") + ". Nothing in "
                + "your home is deleted, moved or changed, and the edit to .chezmoiignore "
                + "is itself uncommitted until you capture it."
              color: root.bar.foreground
              opacity: 0.7
              wrapMode: Text.WordWrap
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: "Add " + root.plural(root.detail.length, "path") + " to .chezmoiignore"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                onClicked: root.runIgnore()
              }

              Button {
                text: "Cancel"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                onClicked: root.cancelIgnore()
              }
            }
          }
        }

        PanelSeparator {
          visible: root.homeCount > 0 && root.repoCount > 0
          foreground: root.bar.foreground
        }

        // ---- the repo's own working tree ----
        Column {
          id: repoSection
          width: parent.width
          spacing: Style.space(8)
          // As above: the entry outlives the list it was opened against.
          visible: root.repoCount > 0 || (root.asking && root.askWhere === "repo")

          PanelSectionHeader {
            text: "UNCOMMITTED IN THE REPO — " + root.plural(root.repoCount, "path")
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            color: root.sectionTitleColor
          }

          Repeater {
            model: root.repoDetail
            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "  " + modelData
              color: root.bar.foreground
              opacity: 0.75
              elide: Text.ElideLeft
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }
          }

          Button {
            text: root.running === "commit" ? "Committing…" : "Commit " + root.plural(root.repoCount, "repo change") + "…"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            opacity: root.running === "" ? 1 : 0.45
            onClicked: root.askCommit("repo")
          }
        }


        // The divider that used to open the panel, when a hero and a separate
        // "not pushed" list lived above this point. With both gone it belongs
        // between the drift and the history - and only when there is something
        // on both sides of it.
        PanelSeparator {
          visible: root.commitsDividerShown()
          foreground: root.bar.foreground
        }

        // ---- local commits --------------------------------------------------
        // The history, and the push that follows from it. There is no separate
        // "not pushed" list any more: those commits are the first rows of this
        // one, and the heading counts them, so no sha can appear twice.
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.recentCommits.length > 0 || root.unpushed > 0

          PanelSectionHeader {
            text: root.commitsTitle()
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            color: root.sectionTitleColor
          }

          Repeater {
            model: root.recentCommits
            Row {
              width: parent.width
              spacing: Style.space(6)

              Text {
                // The subject gives way to the ellipsis, never the sha: the sha is
                // the half the undo button acts on.
                width: parent.width - undoButton.width - parent.spacing
                textFormat: Text.PlainText
                text: "  " + modelData
                color: root.bar.foreground
                opacity: 0.75
                elide: Text.ElideRight
                font.family: root.bar.fontFamily
                font.pixelSize: Style.font.bodySmall
              }

              Button {
                id: undoButton
                iconText: "\uf0e2"
                iconSize: Style.font.bodySmall
                tooltipText: "Take this commit back"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.space(4)
                verticalPadding: Style.space(2)
                onClicked: root.askUndo(modelData)
              }
            }
          }

          // What the button above promises, said plainly before it happens. The
          // wording is not one sentence for both cases: whether the commit can
          // leave the history at all depends on whether the remote has seen it.
          Column {
            width: parent.width
            spacing: Style.space(6)
            visible: root.undoRow !== ""

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Take back " + root.undoRow + "?"
              wrapMode: Text.WordWrap
              color: root.bar.foreground
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Text {
              width: parent.width
              textFormat: Text.PlainText
              text: "Its changes come back to the working tree as drift. If this commit is not the newest, or the remote already has it, it keeps its place in the history and only its changes are undone."
              wrapMode: Text.WordWrap
              color: root.bar.foreground
              opacity: 0.7
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            Row {
              spacing: Style.space(8)

              Button {
                text: root.running === "undo" ? "Taking it back…" : "Take it back"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                onClicked: root.runUndo()
              }

              Button {
                text: "Keep it"
                foreground: root.bar.foreground
                fontFamily: root.bar.fontFamily
                fontSize: Style.font.bodySmall
                horizontalPadding: Style.spacing.controlPaddingX
                verticalPadding: Style.spacing.controlPaddingY
                bordered: true
                onClicked: root.keepCommit()
              }
            }
          }

        Button {
          id: pushButton
          // Only when there is something to push. The rows above are a record of
          // what is already committed, not a reason for the button.
          visible: root.unpushed > 0
          text: root.running === "push" ? "Pushing…" : "Push " + root.plural(root.unpushed, "commit")
          foreground: root.bar.foreground
          fontFamily: root.bar.fontFamily
          fontSize: Style.font.bodySmall
          horizontalPadding: Style.spacing.controlPaddingX
          verticalPadding: Style.spacing.controlPaddingY
          bordered: true
          opacity: root.running === "" ? 1 : 0.45
          onClicked: root.runAction("push")
        }
        }

        // ---- the commit message ----
        // A step in the commit, not a mode of the panel: it arrives empty, and
        // the only things that ever fill it are the person at the keyboard and a
        // suggestion they asked for. It is the only place a suggestion lands.
        Column {
          id: messageEntry
          // Placed in the section that asked for it, so the entry arrives under
          // the button and against the list it is about, instead of at the far
          // end of the panel past the history.
          parent: root.askWhere === "repo" ? repoSection : driftSection
          width: parent.width
          spacing: Style.space(8)
          visible: root.asking

          PanelSectionHeader {
            text: "COMMIT MESSAGE"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            color: root.sectionTitleColor
          }

          // Two lines tall, and it scrolls inside itself when the message runs
          // on longer than that: a commit can be a subject and a line of body,
          // and the kit ships no multi-line field. The outer ScrollView is the
          // box - it draws the kit's field border and fill and holds the
          // scrollbar - and the TextArea inside it wears the kit's font and
          // padding, so the pair reads as the single-line TextField this
          // replaces, taller, rather than as two controls.
          QQC.ScrollView {
            id: messageBox
            width: parent.width
            // Two lines, plus the field's own padding and border, so the box
            // never grows with the text and the panel never becomes a wall of it.
            height: 2 * messageField.lineHeight + messageField.topPadding + messageField.bottomPadding
            clip: true
            padding: 0

            background: BorderSurface {
              id: messageBorder
              color: Style.controlFill(messageField.activeFocus, messageField.hovered, root.bar.foreground, Color.accent)
              borderSpec: Border.controlSpec(messageField.activeFocus ? "focus" : (messageField.hovered ? "hover-cursor" : "normal"), root.bar.foreground, Color.accent)
              radius: Style.cornerRadius
            }

            // There only when there is more to read than the two lines show.
            QQC.ScrollBar.vertical: QQC.ScrollBar {
              id: messageScroll
              policy: QQC.ScrollBar.AsNeeded
              width: 4
              background: null
              contentItem: Rectangle {
                implicitWidth: 3
                radius: 1.5
                color: root.bar.foreground
                opacity: 0.4
              }
            }
            QQC.ScrollBar.horizontal.policy: QQC.ScrollBar.AlwaysOff

            QQC.TextArea {
              id: messageField
              readonly property real lineHeight: Math.ceil(messageMetrics.height)

              placeholderText: "say what this commit does"
              wrapMode: TextEdit.Wrap
              color: root.bar.foreground
              selectionColor: Style.selectionFillFor(root.bar.foreground, Color.accent)
              selectedTextColor: root.bar.foreground
              placeholderTextColor: Qt.darker(root.bar.foreground, 1.6)
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
              leftPadding: Style.spacing.controlPaddingX + messageBorder.borderLeft
              // The scrollbar's lane, reserved whether or not the bar is showing,
              // so the text does not re-wrap the moment it appears.
              rightPadding: Style.spacing.controlPaddingX + 4 + messageBorder.borderRight
              topPadding: Style.spacing.controlPaddingY + messageBorder.borderTop
              bottomPadding: Style.spacing.controlPaddingY + messageBorder.borderBottom

              // Return still commits, as it did when this was one line; Shift or
              // Ctrl is left to the field, which puts a newline in instead.
              Keys.onReturnPressed: function (event) {
                if (event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier)) event.accepted = false
                else root.commitNow()
              }
              Keys.onEnterPressed: function (event) {
                if (event.modifiers & (Qt.ShiftModifier | Qt.ControlModifier)) event.accepted = false
                else root.commitNow()
              }
              Keys.onEscapePressed: root.cancelCommit()
            }
          }

          // The line height the two-line box is built from, taken from the field's
          // own font rather than guessed at.
          TextMetrics {
            id: messageMetrics
            font: messageField.font
            text: "Mg"
          }

          Row {
            spacing: Style.space(8)
            Button {
              text: root.running === "commit" ? "Committing…" : "Commit"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              onClicked: root.commitNow()
            }
            // Only present when something could answer it: a button that can
            // only fail is worse than no button.
            Button {
              visible: root.aiCli !== ""
              text: root.suggesting ? "Asking " + root.aiCli + "…" : "Suggest with " + root.aiCli
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              opacity: root.suggesting ? 0.45 : 1
              onClicked: root.suggestMessage()
            }
            Button {
              text: "Cancel"
              foreground: root.bar.foreground
              fontFamily: root.bar.fontFamily
              fontSize: Style.font.bodySmall
              horizontalPadding: Style.spacing.controlPaddingX
              verticalPadding: Style.spacing.controlPaddingY
              bordered: true
              onClicked: root.cancelCommit()
            }
          }

          // Who wrote the sentence above, said plainly: a suggestion must not
          // look hand-typed, and a generation that failed must not be mistaken
          // for one that came back empty-handed.
          Text {
            width: parent.width
            visible: root.suggestHint !== ""
            textFormat: Text.PlainText
            text: root.suggestHint
            color: root.bar.foreground
            opacity: 0.7
            wrapMode: Text.WordWrap
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          // What an empty entry does, said before the button is pressed rather
          // than discovered in the log afterwards: the commit goes through with
          // no message at all.
          Text {
            width: parent.width
            visible: messageField.text === "" && root.suggestHint === ""
            textFormat: Text.PlainText
            text: "Blank - pressing Commit writes a commit with no message."
            color: root.bar.foreground
            opacity: 0.7
            wrapMode: Text.WordWrap
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }
        }

        // ---- how the last action ended ----
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.result !== ""

          Text {
            width: parent.width
            textFormat: Text.PlainText
            wrapMode: Text.WordWrap
            text: root.result === "ok" ? root.resultText : "Failed: " + root.resultText
            color: root.bar.foreground
            opacity: root.result === "ok" ? 0.85 : 1
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          Button {
            visible: root.result === "error"
            text: "Retry"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            onClicked: root.retry()
          }
        }

        // ---- settings ------------------------------------------------------
        // The shell sets a widget's options from the command line and draws no
        // form for them, so the panel carries its own. Every change goes back
        // into this widget's entry in the bar layout, which is why it survives
        // a shell restart and is the same write `omarchy bar set` makes.
        Column {
          width: parent.width
          spacing: Style.space(8)
          visible: root.settingsOpen

          PanelSectionHeader {
            text: "SETTINGS"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            color: root.sectionTitleColor
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "chezmoi source directory"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: sourceField
            width: parent.width
            text: root.sourceDir
            placeholderText: "empty: the source chezmoi itself is configured with"
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            Keys.onReturnPressed: root.saveSetting("sourceDir", sourceField.text)
            Keys.onEnterPressed: root.saveSetting("sourceDir", sourceField.text)
            onEditingFinished: root.saveSetting("sourceDir", sourceField.text)
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "check every, in seconds"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          NumberField {
            id: checkField
            value: root.checkSeconds
            from: 60
            to: 3600
            stepSize: 60
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            onModified: root.saveSetting("checkSeconds", value)
          }

          Text {
            width: parent.width
            textFormat: Text.PlainText
            text: "AI command a suggestion runs"
            color: root.bar.foreground
            opacity: 0.6
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
          }

          TextField {
            id: aiField
            width: parent.width
            text: root.aiCommand
            placeholderText: "Uses the default Omarchy agent unless overridden here."
            foreground: root.bar.foreground
            font.family: root.bar.fontFamily
            font.pixelSize: Style.font.bodySmall
            verticalPadding: Style.spacing.controlPaddingY
            Keys.onReturnPressed: root.saveSetting("aiCommand", aiField.text)
            Keys.onEnterPressed: root.saveSetting("aiCommand", aiField.text)
            onEditingFinished: root.saveSetting("aiCommand", aiField.text)
          }

          Row {
            width: parent.width
            spacing: Style.space(8)

            Text {
              width: parent.width - showToggle.width - parent.spacing
              text: "show the count when everything is clean"
              color: root.bar.foreground
              opacity: 0.6
              elide: Text.ElideRight
              font.family: root.bar.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            ToggleSwitch {
              id: showToggle
              checked: root.showWhenClean
              foreground: root.bar.foreground
              onToggled: root.saveSetting("whenClean", root.showWhenClean ? "Hide" : "Show")
            }
          }
        }

        PanelSeparator {
          foreground: root.bar.foreground
        }

        Row {
          width: parent.width
          spacing: Style.space(8)

          Button {
            text: "Re-check now"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            onClicked: root.refresh()
          }

          Button {
            text: "Full details"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            onClicked: root.showDetails()
          }

          Button {
            text: root.settingsOpen ? "Hide settings" : "Settings"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            onClicked: root.settingsOpen = !root.settingsOpen
          }

          // Last, and always in the same place: closing is not a comment on the
          // last action, it is the way out of the panel.
          Button {
            text: "Close"
            foreground: root.bar.foreground
            fontFamily: root.bar.fontFamily
            fontSize: Style.font.bodySmall
            horizontalPadding: Style.spacing.controlPaddingX
            verticalPadding: Style.spacing.controlPaddingY
            bordered: true
            onClicked: root.close()
          }

        }
      }
    }
  }

  // Proves what the badge is actually showing, without reading pixels off the
  // screen: `omarchy-shell <id> status`. The other commands are the same entry
  // points the buttons call, so an action can be exercised without a synthetic
  // click.
  IpcHandler {
    target: "enisbu.chezmoi-hound"

    function open(): void { root.open() }
    function close(): void { root.close() }
    function toggle(): void { root.toggle() }

    function status(): string {
      return "total=" + root.total + " home=" + root.homeCount + " repo=" + root.repoCount
        + " unpushed=" + root.unpushed + " visible=" + root.visible
        + " running=" + (root.running === "" ? "idle" : root.running)
        + " problem=" + (root.problem === "" ? "none" : root.problem)
        + " source=" + (root.sourceDir !== "" ? root.sourceDir : (root.reportedSource === "" ? "unset" : root.reportedSource))
        + " branch=" + (root.branchName === "" ? "unset" : root.branchName)
        + " result=" + (root.result === "" ? "none" : root.result)
        + " lastAction=" + (root.lastAction === "" ? "none" : root.lastAction)
        + " asking=" + root.asking + " where=" + root.askWhere
        + " ai=" + (root.aiCli === "" ? "none" : root.aiCli)
        + " msgChars=" + root.lastMessage.length
        + " stamp=" + root.stamp
        + " text=" + root.countText() + " badgeW=" + Math.round(badge.width)
        + " settingsOpen=" + root.settingsOpen
        + " fieldChars=" + messageField.text.length
        + " entryH=" + Math.round(messageBox.height) + " entryLine=" + messageField.lineHeight
        + " undo=" + (root.undoRow === "" ? "none" : root.undoRow)
        + " entryBar=" + (messageScroll.size < 1 ? "shown" : "hidden")
        + " badgeText=" + root.countText()
        + " badgeColor=" + badgeLabel.color.toString()
        + " driftHeader=" + driftHeader.text
        + " driftLine=" + (driftNote.visible ? "shown" : "hidden")
        + " push=" + (pushButton.visible ? "shown" : "hidden")
        + " hint=" + (root.suggestHint === "" ? "none" : root.suggestHint)
        + " commitsTitle=" + root.commitsTitle()
        + " outcomeText=" + (root.resultText === "" ? "none" : root.resultText)
        + " suggesting=" + root.suggesting
        + " ignoring=" + root.ignoring + " ignorable=" + root.detail.length
    }

    // Where the widget actually is on screen, so its rendering can be checked
    // without hunting the bar pixel by pixel.
    function geometry(): string {
      var p = root.mapToItem(null, 0, 0)
      return "x=" + Math.round(p.x) + " y=" + Math.round(p.y)
        + " w=" + Math.round(root.width) + " h=" + Math.round(root.height)
    }

    // The panel's own view of itself, and the same two entry points the buttons
    // call - so the actions can be exercised without a synthetic click.
    function panel(): string {
      return "opened=" + root.opened + " running=" + (root.running === "" ? "idle" : root.running)
        + " commits=" + root.commits.length + " detail=" + root.detail.length
        + " repoDetail=" + root.repoDetail.length + " log=" + root.logLines.length
        + " recent=" + root.recentCommits.length
        + " canPush=" + (root.unpushed > 0) + " canCommit=" + (root.homeCount + root.repoCount > 0)
        + " asking=" + root.asking + " where=" + root.askWhere
        + " ignoring=" + root.ignoring
        + " entryIn=" + (messageEntry.parent === repoSection ? "repo" : "drift")
        + " ai=" + (root.aiCli === "" ? "none" : root.aiCli)
        + " settingsOpen=" + root.settingsOpen
        + " query=" + panel.fittedContentWidth(Style.space(420))
        + "x" + panel.fittedContentHeight(column.implicitHeight)
    }

    // The button and this do the same thing now: ask for the message first. The
    // section is named, so the entry's other home can be exercised without a
    // hand on the mouse: "repo" opens it under the repo's own button.
    function commit(where: string): void { root.askCommit(where) }
    // The suggestion is a button too; this is the scriptable path to the same
    // thing, for an agent or a keybind.
    function suggest(): void { root.suggestMessage() }

    // Commit with a message decided elsewhere, which is the same path the entry's
    // Commit button takes: the message is what runAction hands the script.
    function commitWith(message: string): void {
      root.lastMessage = message
      root.asking = false
      root.runAction("commit")
    }
    function push(): void { root.runAction("push") }

    // The ignore button asks first for the same reason: `ignore` arms the
    // confirm the way a press does, `ignoreNow` carries it through.
    function ignore(): void { root.askIgnore() }
    function ignoreNow(): void {
      root.askIgnore()
      root.runIgnore()
    }

    // The undo button asks first, so these do too: `undo` arms the confirm the
    // same way a press on the row does, and `undoNow` carries it through for a
    // script or a keybind that has nobody to press the second button.
    function undo(sha: string): void { root.askUndo(sha) }
    function undoNow(sha: string): void {
      root.askUndo(sha)
      root.runUndo()
    }

    // Full details is a button; this is the scriptable path to the same
    // floating terminal, so the read-out can be opened without a click.
    function details(): void { root.showDetails() }

    // The same write the panel's own fields make, so the path can be
    // exercised without a hand on the mouse.
    function settingsApply(key: string, value: string): void {
      root.saveSetting(key, value)
    }

    // The settings view is a view, not a mode: this opens and closes it.
    function settings(): string {
      root.settingsOpen = !root.settingsOpen
      return "settingsOpen=" + root.settingsOpen
    }

    // The same write the fields make, so an option can be set without typing
    // into a field: settingsSet("checkSeconds", "300").
    function settingsSet(key: string, value: string): string {
      root.saveSetting(key, value)
      return key + "=" + value
    }

    function refresh(): void {
      root.refresh()
    }

    function check(): void {
      root.refresh()
    }

    function reread(): void {
      root.refresh()
    }
  }

  // Keep bar drag-to-reorder working, the way WidgetButton does.
  property var registeredBar: null
  function syncClickRegistration() {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    registeredBar = root.bar
    if (registeredBar && registeredBar.registerClickTarget) registeredBar.registerClickTarget(root)
  }
  onBarChanged: syncClickRegistration()
  Component.onCompleted: syncClickRegistration()
  Component.onDestruction: {
    if (registeredBar && registeredBar.unregisterClickTarget) registeredBar.unregisterClickTarget(root)
    detailProc.signal(15)
    checkProc.signal(15)
    actionProc.signal(15)
    probeProc.signal(15)
    suggestProc.signal(15)
    saveProc.signal(15)
  }
}
