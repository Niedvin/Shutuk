# Shut

Two plugins that cut what a coding agent writes — the comments it leaves in your code, and the
text it prints at you. Both are injected at session start, so they hold for the whole session
instead of loading only when the agent decides they are relevant.

They install into Claude Code and Claude Desktop as plugins, and into Codex, opencode, Gemini
CLI and Cursor as skills.

---

## The two plugins

### CCShut — comments

Every comment must pass two gates, or it is not written:

1. **Permanence** — still true after the code around it has been rewritten.
2. **Irreducibility** — a senior engineer already working in that repo could not have recovered
   it from the names, types, control flow, or one call site away.

On top of that: one line each, ending in the date it was written (` — 2026-09-05`), under 5% of
a file's lines, no doc-comment exception. Comments already in a file you edit go through the
same gates — the failing ones get deleted. TODO, FIXME and notes meant for you go into the
reply, never into the file.

A `PostToolUse` hook re-checks every file the agent writes and flags breaches back to it.

### BeQuiet — talk

Every message the agent sends is one of four shapes, and nothing else:

| Shape | Language | Rule |
|---|---|---|
| Step label | English | ≤ 4 words, no punctuation inside, usually omitted entirely |
| Question | plain Ukrainian | only when two readings would change what gets built |
| Warning | plain Ukrainian | only when you must decide or act right now |
| Answer | plain Ukrainian | ≤ 8 lines, no tables, no headings, no write-up of the steps |

No progress chatter, no announcing a tool call before making it, no restating your request, no
telling you to go test your own product. Numbers are digits and relations are symbols
(`>`, `≈`, `→`, `∵`), in both languages.

Hooks re-assert the rule after every skill load and score the turn before it ends, so it does
not decay over a long session.

The Ukrainian half is a personal setting. Change the language in
`plugins/bequiet/hooks/context.md` and `plugins/bequiet/always-on.md`, then re-install.

---

## Install

### Claude Code and Claude Desktop — marketplace

```
/plugin marketplace add Niedvin/Shut
/plugin install ccshut@shut
/plugin install bequiet@shut
```

Updates then come with `/plugin marketplace update shut`.

### Claude Desktop — drag and drop

Download [`dist/CCShut.zip`](dist/CCShut.zip) and [`dist/BeQuiet.zip`](dist/BeQuiet.zip) and
drop each into the plugin upload box. One zip per plugin; each has `.claude-plugin/plugin.json`
at its root, which is what the uploader checks for.

### Codex, opencode, Gemini CLI, Cursor — the installer

The marketplace is Claude-only. For the rest, clone the repo and run the pair for your OS.
Both pairs do exactly the same thing and leave byte-identical files behind.

```
git clone https://github.com/Niedvin/Shut
cd Shut
```

| OS | Install | Remove | Needs |
|---|---|---|---|
| Windows | double-click `install.cmd`, or `powershell -ExecutionPolicy Bypass -File install.ps1` | `uninstall.cmd` | nothing — PowerShell 5.1 ships with Windows 10/11 |
| macOS | `bash install.sh` | `bash uninstall.sh` | nothing — bash, unzip and osascript ship with macOS |
| Linux | `bash install.sh` | `bash uninstall.sh` | `node`, for the JSON edits |

The installer detects which agents are on the machine and skips the rest. `--dry-run` prints
the whole plan and changes nothing — run that first if you want to see the list.

---

## What the installer touches, and why

It edits files under your home directory. Nothing runs as admin, nothing leaves the machine,
and every file it changes is backed up next to itself first. In full, it:

| Path | What happens | Why |
|---|---|---|
| `~/.claude/skills/{ccshut,bequiet}/` | plugin copied in | Claude Code loads plugins from here |
| `~/.codex/skills/`, `~/.config/opencode/skills/`, `~/.gemini/skills/`, `~/.cursor/skills-cursor/`, `~/.agents/skills/` | flat `SKILL.md` copied in | each agent reads skills from its own path |
| `~/.codex/hooks.json` + `~/.codex/hooks/shut-*` | two `SessionStart` entries added | a skill loads on demand, which is too late for a rule about how to talk; the hook injects it every session. Every other hook in the file is left alone |
| `~/.config/opencode/AGENTS.md`, `~/.gemini/GEMINI.md` | a marked block added | those agents have no session-start hook, so the text lives in the file they read every session |
| `~/.claude/settings.json` | `CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION=false`, `CLAUDE_CODE_ENABLE_AWAY_SUMMARY=0` | both print text BeQuiet forbids |
| `~/.claude/settings.local.json` | `outputStyle: Shut` | a built-in output style can drop the brevity rules; this one restates them |
| `~/.claude/output-styles/shut.md` | installed | the output style itself |
| every project `.claude/` it finds | same two settings | so the rule holds in each project, not just globally |
| any `language` key in those settings | **removed** | any value there injects "Always respond in \<lang\>" over every explanation, which overrides BeQuiet's English-label / Ukrainian-answer split whichever language it names |
| `~/.shut-backups/` | originals and state | what `uninstall` reads to put everything back |

**Why it reads the disk.** Finding project `.claude` folders is the only step that looks
outside your home directory: it walks `$HOME` plus each local drive (Windows) or each volume
under `/Volumes` (macOS), four levels deep, skipping `Library`, `AppData`, `node_modules`,
build output and every dot-directory. It reads directory names, opens only files named
`settings.json` / `settings.local.json`, and writes only those. Removable and network drives
are never touched. Pass `--dry-run` to see the exact list before anything is written, or
`--only claude` to keep it to the global config.

On macOS, `~/Desktop`, `~/Documents` and `~/Downloads` are hidden from a terminal without Full
Disk Access. Projects under them are skipped; the installer names the folders and says so.
Granting access is optional.

---

## Uninstall

```
uninstall.cmd                 # Windows
bash uninstall.sh             # macOS / Linux
/plugin uninstall ccshut@shut # Claude Code, if you installed via the marketplace
```

It removes only what the installer put there: skill folders carrying a `.shut-install.json`
marker (`--force` for the rest), its own entries in `~/.codex/hooks.json`, the marked blocks,
and every settings value it changed — restored from `~/.shut-backups/uninstall.json`. Every
file it edits is copied to `*.bak-uninstall` first.

---

## Options

Same set in both installers; PowerShell spells them as switches.

```
--dry-run       -DryRun         print the plan, change nothing
--list          -List           list the agents it found
--only claude   -Only claude    one agent (comma-separated for several)
--skip gemini   -Skip gemini    leave one alone
--no-always-on  -NoAlwaysOn     skills and hooks only, do not touch AGENTS.md
--no-hooks      -NoHooks        skills and AGENTS.md only, no Codex hook
--keep-caveman  -KeepCaveman    leave the caveman skill enabled
```

Removal takes `--force` / `-Force` and `--keep-caveman-off` / `-KeepCavemanOff`.

---

## Notes

**Codex trust.** Codex will not run a new hook until you trust it. Run `/hooks` inside Codex,
trust the two `shut-` entries, then run the installer again — it sees they are trusted and
drops the now-duplicate `AGENTS.md` block. Until then both are in place, so the rule is never off.

**Caveman.** If the `caveman` skill is installed it is turned off, because two rewriters of the
same reply is not a defined state. Exactly what was done is recorded in
`~/.shut-backups/caveman-state.json` and undone by `uninstall`. `--keep-caveman` skips it.
Hand-written "use /caveman" lines in your own `CLAUDE.md` are named, never edited.

**macOS.** The hook payloads ship prebuilt inside the plugins, so the rule holds on a Mac with
no Python at all — only the three gates that score a turn need one, and they exit quietly
without it. Hook scripts prefer `python3` and skip `/usr/bin/python3` unless `xcode-select -p`
succeeds, because that path is a stub that pops the Xcode Command Line Tools installer.

**Project files.** Both plugins carry the whole rule, so a project's `CLAUDE.md` / `AGENTS.md`
does not need to restate any of it and should not. A project line like "reply in Ukrainian"
reads as covering everything the session writes, which contradicts BeQuiet's split. A project
may add to these rules — never loosen them.

**Re-running** upgrades in place and changes nothing that is already correct. Anything already
sitting at a target path is moved to `~/.shut-backups/`, never deleted.

---

## Repo layout

```
.claude-plugin/marketplace.json   the marketplace manifest
plugins/ccshut/                   the CCShut plugin (.claude-plugin/, hooks/, skills/)
plugins/bequiet/                  the BeQuiet plugin
dist/*.zip                        the same two plugins, zipped for drag-and-drop
install.ps1 / uninstall.ps1       Windows installer, plus .cmd wrappers
install.sh / uninstall.sh         macOS and Linux installer
shut-json.js                      JSON editor the shell installer runs through osascript or node
shut.md                           the Claude Code output style
```

`always-on.md`, `manifest.json` and `flat/SKILL.md` inside each plugin folder are read by the
installer and stripped from what it copies into Claude Code.

## License

MIT — see [LICENSE](LICENSE).
