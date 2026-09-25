# Changelog

## 1.2.0-enisbu.1

- Fork unter `enisbu.chezmoi-hound`, Oberfläche auf Deutsch.
- **Eingehend**: die Prüfung zählt Commits im Upstream, die hier fehlen (`behind`, `incoming`).
  `--fetch` holt vorher mit Timeout; das Widget ruft es alle `fetchSeconds` (Standard 900) und beim Öffnen auf.
- **Holen** = `chezmoi update`, verweigert mit Meldung (Exit 4), solange Dateien lokal geändert sind.
- **Fällige Skripte**: `run_once_`/`run_onchange_`-Skripte mit `R` zählen als `scripts`;
  **Skripte ausführen** = `chezmoi apply --include scripts`, schreibt keine Datei-Ziele.
- **Claude neu**: `chezmoi unmanaged` über die Pfade aus `claudePaths`; **Übernehmen** macht `chezmoi add`,
  staged die neuen Quelldateien und committet über den bestehenden Commit-Ablauf.
- **Peer**: `--peer auto|HOST` liest die Prüfung des anderen Rechners per SSH, offline nach spätestens rund 5 s.
  Zählt nicht in die eigene Zahl, ein Punkt in der Bar zeigt offene Änderungen dort.
- Pfeil in Akzentfarbe vor der Zahl, wenn Eingehendes dabei ist.
- Panel-Reihenfolge: Eingehend, Lokal geändert, Claude neu, Fällige Skripte, Nicht gepusht,
  Quellrepo uncommitted, Peer, Verlauf. Nicht gepusht und Verlauf sind getrennte Abschnitte.
- Protokoll `version 2`, abwärtskompatibel: neue Schlüssel, `total` unverändert, neue Summe `all`.

## 1.1.7

- **Add to .chezmoiignore**, beside **Capture and commit**. Not every drifted
  file is a dotfile: a mail client's config that came with an installer, a
  credential helper, a cache. Capturing those into the source is the wrong
  answer, and until now the only answer the panel had. The button names the
  paths it is showing in the source's `.chezmoiignore`, which chezmoi matches
  against target paths, so the next check neither manages nor counts them.
- It asks first and repeats the paths it is about to write, the same shape as the
  undo confirm. Paths already in the file are reported back rather than written
  twice, the heading is written once, and a dry run changes nothing.
- **Nothing in `$HOME` is created, moved, changed or deleted.** The only file
  written is `.chezmoiignore` inside the source repo, and that edit is a source
  change like any other: it appears in the repo section and lands in the next
  capture's diff, so committing it still takes a press on **Capture and commit**.
- Verified against a throwaway source tree and a throwaway `$HOME` (the real
  repo and the real home are never read or written by the test): the ignored
  target disappears from `chezmoi status`, a repeat press reports rather than
  duplicates, and the no-argument form names whatever is drifting at the time.

## 1.1.6

- **The sandbox gets one credential, chosen from the transport — not every
  variable that looks like one.** Two rules were still broad. `hermes`' provider
  key was picked out of `~/.hermes/.env` by variable *name*: any line whose name
  contained `KEY` or `TOKEN` came along, which on a real machine is a GitHub
  token, a Slack bot token, an ssh key path and half a dozen other providers'
  keys inside a 539-line file. And the parent environment was raided for every
  known provider key and copied into *every* agent's sandbox, so a `claude` run
  carried `OPENAI_API_KEY`, `GEMINI_API_KEY`, `OPENROUTER_API_KEY` and four more
  it has no use for. The transport is now decided first — for `hermes` from the
  provider its own config names — and exactly one credential follows: one
  variable for the selected agent, and for `hermes` that one line of the `.env`.
- Measured rather than claimed. With a fake key planted for ten providers in the
  parent environment and six key-shaped lines planted in `.env`, each agent's
  process now sees only its own: `ANTHROPIC_API_KEY` for `claude`,
  `OPENAI_API_KEY` for `codex`, `GEMINI_API_KEY` for `gemini`, nothing for
  `opencode`, and for `hermes` no key in the environment at all plus a single
  `OPENCODE_GO_API_KEY` line as the only entry in the `.env` it is given. The
  pre-fix script, run against the same planted environment, showed all eight
  provider keys in every agent's environment and all six foreign credentials
  inside hermes' `.env`. The three legs that answer here (opencode, codex,
  hermes) still answer, with no planted value anywhere in their output.

## 1.1.5

- **The sandbox shows an agent its own credential, and nothing beside it.** Each
  agent's whole state directory used to be put back inside the namespace, and a
  poisoned diff could ask the agent to read what lives next to its credential —
  session history, request dumps, logs, tens of megabytes of OpenCode state. Each
  state directory is now re-created empty and only the single credential file is
  put back into it, so the rest of the directory is not in the namespace to be
  read: `~/.claude/.credentials.json`, `~/.codex/auth.json`, gemini's oauth files,
  opencode's `auth.json`, and for hermes its provider key alone — copied out of a
  `.env` of 536 lines that also holds every other integration's secrets.
  `~/.claude.json` is no longer exposed at all.
- **Every agent now has a policy of its own, not just a flag.** `claude` takes
  `--tools ''`, `gemini` a deny-everything policy, `codex` a config with the
  plugin tools its marketplace entry enables stripped out. `opencode` cannot be
  given a no-tools config at all — its free tier refuses to serve a no-tools agent
  — so a plugin rejects the tool call instead. `codex` has no tool-disable key
  anywhere in it, which is why the boundary does the work there.
- Generated configs are mounted only for the agent they were written for, and
  hermes' own runtime only for hermes.
- Verified by planting a secret in every agent's state directory: unreachable from
  all five namespaces, with every leg still answering.

## 1.1.4

- **A suggestion works under the environment the panel actually runs in.** The
  sandbox bound the tool runtimes but not the command the leg had resolved, and
  the shell that presses Suggest finds agents in two places that were outside the
  namespace: a wrapper in `$HOME/.local/bin` (hermes) and a mise shim in
  `$HOME/.local/share/mise/shims` (opencode, codex, gemini, claude). The wrapper
  was not there to exec — `env: 'hermes': No such file or directory`, status 127 —
  and a shim is a symlink to the mise binary, so resolving it ran mise as the agent
  and reported `mise ERROR no tasks defined`. The command is now resolved on the
  host, through `mise which` where a shim stands for one, and that one file is
  bound into the namespace. Developers whose `PATH` already pointed into the
  installs did not see this; the panel's environment did.
- Measured in both environments, with each agent run through the leg: hermes,
  opencode and codex answer in both; gemini and claude report their own
  not-logged-in state in both.

## 1.1.3

- **A suggestion no longer fails for the agents that are handed the prompt on
  stdin.** The sandbox code rewrote the shell function's own arguments — once
  onto the agent's command line and again onto bubblewrap's — and then read the
  drift file out of `$3` as if those argument lists had never touched it. `$3`
  was a bubblewrap or agent option by then, so the shell tried to open
  `--unshare-pid` as a file: the agent never ran, and Suggest reported the
  agent's own failure. Taking the two files before anything rewrites the
  arguments fixes it, and opencode, codex and hermes all return a suggestion
  again.
- Verified by running each supported agent through the leg: hermes, opencode and
  codex answer; gemini and claude report their own not-logged-in failures.

## 1.1.2

- **A suggestion no longer reads the whole machine, and no longer runs without a
  sandbox.** The previous sandbox bound `/` read-only, which stops writes but not
  reads: an agent that had been talked into it could still read your ssh keys,
  `gh` credentials and shell environment. The namespace is now an allowlist —
  the machine's runtime (`/usr`, `/etc`, `/opt`), the agents' own runtimes, the
  resolver file, `/proc`, `/dev`, and an empty directory as its working
  directory. `$HOME` is empty, with only the agents' own directories overlaid
  back in, so keys, keyrings, `gh` credentials, `chezmoi` config, projects and
  documents are not there to be read at all.
- The agent's **environment is cleared** rather than inherited: it gets `PATH`,
  `HOME`, `TERM`, `LANG`, `TMPDIR` and a provider key, not the shell's exported
  tokens or its ssh agent socket.
- **`bubblewrap` is required for Suggest**, not merely used when present. There
  is no unsandboxed path left: the `HOUND_NO_SANDBOX` escape hatch is gone, and
  without `bubblewrap` the leg refuses to run and the **Suggest** button is not
  offered.
- Two faults found by testing the above against a live agent: the empty home was
  mounted *after* the agents' runtimes, which hid them and stopped the agent
  starting; and `/etc/resolv.conf` points into `/run` on this distribution, so
  without the resolver file bound the provider call failed as if the endpoint
  were down.

## 1.1.1

- **A suggestion can no longer change anything.** The drift handed to an agent is
  text out of files that may have arrived from anywhere, and the agent used to
  receive it with its tools switched on. It is now asked to work with them off —
  `claude --tools ''`, `codex exec -s read-only`, `gemini --approval-mode plan`,
  `opencode run --agent plan`, `hermes -t todo` — and, where `bubblewrap` is
  installed, is sandboxed as well: the filesystem read-only, an empty throwaway
  working directory, its own state overlaid so nothing it writes outlives the
  run, and key material masked. The diff reaches the agent fenced and labelled as
  untrusted data.
- The **lock** moved out of `$TMPDIR` and into a `0700` directory this user owns
  (`$XDG_RUNTIME_DIR/chezmoi-hound`, else `$HOME/.cache/chezmoi-hound`). A lock
  whose *name* another account can create is a lock that can be pointed at a
  symlink and made to truncate a file of yours. It is now created without
  following links, and opened without truncation.
- The agent runs in a **directory of its own** rather than in the source tree it
  is describing.

## 1.1.0

- A **zero** on the bar is drawn in the same colour as every other count. It used
  to be dimmed and half faded as well, which read as a different sort of number
  rather than as "nothing to do" — the count is the count.
- **Dotfile Drift** is now a permanent heading. With nothing to report it carries
  no count and says *No drift detected — the files here match the source.* in
  place of the list, so the panel keeps its shape and gains a line of plain
  English where the section used to disappear.
- Neither action button is offered with nothing to do: **Capture and commit** is
  absent when there is no drift, and **Push** only appears when the remote has
  not seen a commit. The rows above it record what is already committed; they are
  not a reason for the button.
- **Close** moved to the panel's foot, last of **Re-check now**, **Full
  details**, **Settings**. It used to trail the last action's outcome, so the way
  out of the panel moved around depending on what had just happened. **Retry**
  stays with the failure that asks for it.

- **Capture and commit** now opens a **blank** commit message entry instead of
  committing wording nobody chose. Nothing is filled in for you, and nothing is
  committed until the button is pressed. Press Commit on an empty entry and the
  commit carries no message at all, which the panel says under the entry
  beforehand. That replaces the generated wording (`Capture dotfiles drift from
  <host> on <date>`, then the paths): a list of files is not a message, and a run
  script that is merely due is not even in the commit the list describes.
- Each row of the commit history carries a small **undo** arrow. It asks first,
  repeating the row and saying what taking that commit back means for it: the
  newest unpushed commit leaves the history and its changes return to the working
  tree as drift, while a commit the remote has seen — or one with commits on top
  of it — keeps its place and only its changes are undone. A commit that cannot
  be undone without a clash is backed out entirely and reported, never left as a
  conflicted tree, and only the five commits on screen can be named at all.
- **Suggest with <agent>** writes the message from the diff, using the machine's
  default coding agent — the one `omarchy default agent` reports, whatever it is
  — through that agent's own non-interactive mode. An agent with no such mode
  gets no button rather than a button that hangs, and the `aiCommand` setting
  pins a different one.
- The line under the entry says where the wording came from: a suggestion is
  credited to the agent that wrote it, and a suggestion that failed is never
  papered over — it says so with its exit code and leaves the entry as the person
  left it.
- `suggest` has no generated fallback and no `--draft` flag. With no agent on the
  machine, or an agent that answers with nothing usable, it prints nothing, and
  the message stays the person's to write.
- A suggestion cannot push: the push stays a separate, separately-pressed action.
- **The drift an agent is shown is file drift only.** `chezmoi status` reports
  `R` for every `run_` script on every run, forever - a script is always due on
  the next apply, so that line never clears - and chezmoi prints a due script's
  entire body as a new file in `chezmoi diff`. Both lists therefore drop run
  scripts (`chez diff -x scripts`). Otherwise every request carried the paths and
  the full text of the machine's `run_` wrappers, and the agent answered with the
  wrapper it had just been handed: an installed feature proposed back as work to
  do. The check script already filtered them; now the brief does too.
- **The panel shows the repo's last five commits where it used to show the last
  action's log.** That log could only ever restate what the last button press did
  — which the badge had already answered by changing — and it was empty on every
  fresh start, so it spent its rows saying nothing. The history is a fact about
  the dotfiles themselves. Five rows, newest first, `sha` then subject, with no
  age column: a long message is the only thing that can elide, so nothing else is
  lost to it. `chezmoi-hound-check --render` prints the same five with their ages,
  for the terminal, where the width costs nothing.

- **The panel's top section is gone.** A title, a phrase and the source path
  restated what the badge, the tooltip and the rows under them already said, so
  the panel now opens on the drift itself. **`Dotfile Drift` is the heading that
  replaces "edited here, not captured"**, and each heading counts its own list
  (`Dotfile Drift — 1 change`, `Latest commits — 2 not pushed`) rather than
  leaving the count to be worked out from the rows. The history's count is only
  the commits the remote has not seen, and it is dropped when there are none.
- **The commit message entry opens where the button was pressed.** It used to
  live at the foot of the panel, past the history, which put the field and the
  list it describes at opposite ends of the panel. It is now placed in the
  section that asked for it — under **Capture and commit** for the drift, under
  **Commit n repo changes** for the source tree — and that section holds it on
  screen while it is open, so a re-check that empties the list cannot take the
  field out from under the person typing in it.
- **Section titles take the full-strength foreground.** The shared section header
  is already bold; its default colour was dimmed 1.4x to sit under a hero this
  panel no longer has, which left a title the same grey as the rows beneath it.
- **The rule now falls between the drift and the history**, and only when there is
  something on both sides of it: the old one ran across the top of the panel,
  under nothing.
- **The AI command field says what its empty state means**: *Uses the default
  Omarchy agent unless overridden here.*
- **Full details did nothing, and now it works.** The button set `running` on the
  process that opens the floating terminal without ever setting its `command` —
  only the badge's right-click did that — so it started a process with nothing to
  run and no terminal appeared. Both entry points now call one `showDetails()`,
  and `details` exposes it over IPC so the read-out can be opened without a click.
- **The widget's options are in the panel.** Nothing in the shell draws a form for
  a widget's settings — `settingsForm` is declared in manifests and rendered by
  nothing — so the panel draws its own behind the **Settings** button: source
  directory, seconds between checks, AI command, and show-when-clean. Each change
  is written back into this widget's entry in the bar layout as it is made
  (`settingsSet` over IPC, `omarchy bar set` from a shell), so it survives a
  restart.
- `suggest --probe` lets anything else ask which agent would be used
  (`ai=<command>` or `ai=none`), and the panel exposes `suggest` and
  `commitWith` over its IPC target.
- **The history's heading is `Latest commits`**, not "latest local commits": the
  rows are the source repo's own history and *local* was doing no work. A finished
  action likewise states its outcome in the panel's own words — **`Captured and
  committed.`**, **`Pushed.`**, **`Undone.`** — instead of echoing the script's last
  log line, which read out **`1 target(s) captured`** and its like. The script's log
  is still exactly what **Full details** prints. A suggestion in flight is likewise
  stated once, on the button that asked for it (**`Asking hermes…`**), instead of a
  second time as a line under the entry; that line now carries only what came back
  — who wrote the wording, or why nobody did.

## 1.0.0

First release.

- A bar count of dotfile drift: targets edited here and not captured by the
  source, uncommitted paths in the source repo, and commits the remote has not
  seen, added up into one number.
- Clicking the count opens a panel that names the drift and offers **Push N
  commits** and **Capture and commit**, each shown only when there is something
  to do.
- The badge hides itself when everything agrees, and is a plain number
  otherwise.
- Self-contained: no `jq`, no cache file, no systemd timer, no `~/.local/bin`
  dependency. The widget re-reads on its own interval and after every action.
- Configurable chezmoi source directory, re-check interval, and clean-state
  behaviour.
- Templates and `$HOME`-side deletions are reported and never captured
  automatically. Push only ever goes to the branch's existing upstream, and
  never force-pushes.
- The panel states the outcome of an action instead of only logging it: success
  offers **Close**, failure shows what broke and offers **Retry**.
- One instance runs per monitor; finishing an action refreshes the other
  monitors so their counts stay in step.
- `push` and `commit` exit non-zero when they fail, so a refused push is
  reported as a failure rather than a success.
- The panel is titled after the plugin.
