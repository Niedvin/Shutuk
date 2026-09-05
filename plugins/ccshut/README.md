# ccshut

Stops decorative code comments from being written, and clears out the ones already there
when their code gets edited. A comment ships only if it passes both gates:

1. **Permanence** — still true after the code around it is rewritten.
2. **Irreducibility** — a senior engineer could not have recovered it from the code.

Cap: one line, ending in the date it was written (` — YYYY-MM-DD`). A project's own
comment rules add to this; they never loosen it.

## How it loads

It lives in `~/.claude/skills/`, so Claude Code loads it as `ccshut@skills-dir`
in every project with no marketplace and no install step. Its `SessionStart` hook fires on
`startup`, `resume`, `clear` and `compact`, and injects `hooks/context.md` into the conversation.
Because the rule lands in the conversation itself, disabling the plugin mid-session does not
remove it; the next session starts clean.

## Layout

| Path | Holds |
|---|---|
| `hooks/context.md` | The injected rule. Source of truth — edit this. |
| `hooks/session-start.json` | Prebuilt hook payload. Generated, do not hand-edit. |
| `hooks/build.py` | Rebuilds the payload from `context.md`. |
| `hooks/session-start` | The hook. Rebuilds if stale, then prints the payload. |
| `hooks/run-hook.cmd` | Polyglot cmd/bash wrapper so the hook runs on Windows too. |
| `skills/ccshut/SKILL.md` | The full rule, loaded on demand. |

The payload is built ahead of time rather than escaped at run time: bash 5.3's pattern
substitution eats the backslashes that JSON string escapes are made of.

## Editing the rule

```bash
$EDITOR ~/.claude/skills/ccshut/hooks/context.md
python  ~/.claude/skills/ccshut/hooks/build.py   # optional; the hook self-heals
```

Hook changes need `/reload-plugins` or a restart. `SKILL.md` edits apply immediately.

## Turning it off

```bash
claude plugin disable ccshut@skills-dir
```

Takes effect from the next session. Deleting the folder also works.
