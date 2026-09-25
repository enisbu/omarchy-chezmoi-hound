# Chezmoi Hound

Omarchy-Bar-Widget für Dotfile-Drift über [chezmoi](https://www.chezmoi.io/). Fork von
[dadofsambonzuki/chezmoi-hound](https://github.com/dadofsambonzuki/chezmoi-hound) (MIT), für zwei Rechner,
die ihre Dotfiles und `~/.claude` über ein chezmoi-Repo teilen.

## Oberfläche

**Bar.** Ist alles synchron, ist das Widget unsichtbar. Sonst steht dort ein Sync-Symbol mit einem Punkt in
Akzentfarbe, ohne Zahl.

**Panel.** Ein Klick öffnet zwei Spalten:

- **chezmoi**: alles außerhalb von `~/.claude`.
- **Claude**: alles unter `~/.claude`, also verwaltete Dateien, die hier geändert wurden, und neue Dateien in
  `~/.claude/skills`, `~/.claude/hooks` und `~/.claude/projects/<home>/memory`.

Jede Spalte zeigt eine Zusammenfassung (etwa „2 geändert · 1 eingehend“ oder „synchron“), bis zu vier Pfade
(`•` lokal geändert, `↓` eingehend) und „+N weitere“, darunter einen Button **Sync**. Eingehende Commits zählen
auf der Seite, deren Pfade sie ändern (`private_dot_claude/` in der Quelle ist die Claude-Seite). Die Fußzeile
nennt den letzten Abgleich mit dem Remote. Einstellungen gibt es keine: Prüfung alle 300 s, `git fetch` alle
900 s und beim Öffnen.

## Sync

**Sync** arbeitet nur mit den Pfaden seiner Seite, in dieser Reihenfolge:

1. Lokale Änderungen übernehmen: `chezmoi add` für geänderte und neue Ziele, `chezmoi forget` für hier gelöschte.
   Vorlagen (`.tmpl`) werden nicht überschrieben, sondern am Ende als Fehler gemeldet.
2. `git add` für die Quellpfade der Seite, Commit `chore: sync <chezmoi|claude> from <role>`,
   `git pull --rebase --autostash`, `git push`. `role` kommt aus `chezmoi execute-template '{{ .role }}'`.
3. Eingehendes anwenden: `chezmoi apply --exclude scripts` nur für Ziele dieser Seite, die hier nicht lokal
   geändert sind. Lokale Änderungen der anderen Seite bleiben unberührt.
4. Nur chezmoi-Seite: sind `run_once_`- oder `run_onchange_`-Skripte fällig, zuletzt
   `chezmoi apply --include scripts`.

Schlägt ein Schritt fehl, hört Sync auf. Ein Rebase-Konflikt wird mit `git rebase --abort` zurückgerollt, der
lokale Commit bleibt und wird beim nächsten Sync gepusht. Die Spalte zeigt eine kurze Fehlerzeile und den Button
**Mit Claude lösen**: er startet über `omarchy-agent-prompt` den Standard-Agenten von Omarchy im Standard-Terminal,
im Quellverzeichnis, mit Seite, Schritt, Fehlerausgabe, `git status --short` und Rolle im Prompt. Die Fehlerzeile
verschwindet, sobald die Seite wieder synchron ist. Es läuft immer nur ein Sync (Sperre per `flock`).

## Skripte

- `bin/chezmoi-hound-check [--fetch]` liest den Stand und antwortet zeilenweise `key<TAB>value`:
  `version 3`, `fetched`, `scripts <n>`, `local <seite> <pfad>`, `incoming <seite> <pfad>`,
  `commits <seite> <n>`, `unpushed <seite> <n>`, `note`, `error`. Nur `--fetch` geht ins Netz.
- `bin/chezmoi-hound-act sync <chezmoi|claude>` führt den Sync aus, `resolve <seite>` öffnet den Agenten zum
  letzten Fehler dieser Seite.
- IPC: `omarchy-shell enisbu.chezmoi-hound open|close|toggle|status`.

## Installieren

```sh
omarchy plugin add https://github.com/enisbu/omarchy-chezmoi-hound.git --enable --yes
omarchy plugin remove enisbu.chezmoi-hound --yes
```

Voraussetzungen: `chezmoi`, `git`, `flock`, Omarchy 4 mit der Omarchy-Shell.

## Lizenz

MIT, siehe [LICENSE](LICENSE).
