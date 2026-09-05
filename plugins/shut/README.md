# shut

Splits everything said in a session into four shapes, so working is quiet and the answer is
readable by someone who does not write code.

| Shape | When | Language | Size |
|---|---|---|---|
| Step label | while working | English | 4 words max |
| Question | a real chance of misunderstanding | Ukrainian | question + short options |
| Warning | the user must decide or act now | Ukrainian | 1–2 sentences |
| Answer | the turn ends without a tool call | Ukrainian | what happened, then what it changes for them — 8 lines, no tables |

The split by language belongs to the rule, not to a project: a project file that asks for
Ukrainian replies is talking about the last three shapes. Step labels stay English, and a
line that only announces the next tool call is not written in either language.

Like `caveman` it compresses, but on the first pass rather than as a rewrite, and it drops
the terms this reader will not have to click or type. Terms they already use stay.

## How it loads

It lives in `~/.claude/skills/`, so Claude Code loads it as `shut@skills-dir` in every
project with no marketplace and no install step. Its `SessionStart` hook fires on `startup`,
`resume`, `clear` and `compact`, and injects `hooks/context.md` into the conversation. Because the rule
lands in the conversation itself, disabling the plugin mid-session does not remove it.

## Layout

| Path | Holds |
|---|---|
| `hooks/context.md` | The injected rule. Source of truth — edit this. |
| `hooks/session-start.json` | Prebuilt hook payload. Generated, do not hand-edit. |
| `hooks/build.py` | Rebuilds the payload from `context.md`. |
| `hooks/session-start` | The hook. Rebuilds if stale, then prints the payload. |
| `hooks/run-hook.cmd` | Polyglot cmd/bash wrapper so the hook runs on Windows too. |
| `skills/shut/SKILL.md` | The full rule, loaded on demand. |

## Editing the rule

```bash
$EDITOR ~/.claude/skills/shut/hooks/context.md
python  ~/.claude/skills/shut/hooks/build.py   # optional; the hook self-heals
```

Hook changes need `/reload-plugins` or a restart. `SKILL.md` edits apply immediately.

## Turning it off

```bash
claude plugin disable shut@skills-dir
```

Takes effect from the next session. Deleting the folder also works.
