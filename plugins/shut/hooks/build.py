"""Rebuild the injected JSON payloads from their markdown sources. Run after editing those."""
import json
import pathlib

here = pathlib.Path(__file__).parent

# (source, output, hookEventName, suppressOutput)
TARGETS = [
    ("context.md", "session-start.json", "SessionStart", False),
    ("anchor.md", "anchor-tool.json", "PostToolUse", True),
    ("anchor-prompt.md", "anchor-prompt.json", "UserPromptSubmit", True),
]

for src, out, event, quiet in TARGETS:
    path = here / src
    if not path.exists():
        continue
    text = path.read_text(encoding="utf-8").strip()
    payload = {}
    if quiet:
        payload["suppressOutput"] = True
    payload["hookSpecificOutput"] = {
        "hookEventName": event,
        "additionalContext": text,
    }
    body = json.dumps(payload, ensure_ascii=False, indent=2) + "\n"
    (here / out).write_text(body, encoding="utf-8")
    print(f"{out} rebuilt ({len(text)} chars)")
