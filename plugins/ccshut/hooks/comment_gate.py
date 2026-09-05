"""PostToolUse check: flag comments in a just-written file that break ccshut. Note only, never blocks."""
from __future__ import annotations

import json
import os
import re
import sys

LINE_MARKERS = {
    ".py": "#", ".gd": "#", ".sh": "#", ".bash": "#", ".rb": "#", ".pl": "#",
    ".yml": "#", ".yaml": "#", ".toml": "#", ".tf": "#", ".nix": "#",
    ".c": "//", ".h": "//", ".cpp": "//", ".hpp": "//", ".cc": "//", ".cs": "//",
    ".js": "//", ".mjs": "//", ".cjs": "//", ".ts": "//", ".tsx": "//", ".jsx": "//",
    ".java": "//", ".kt": "//", ".go": "//", ".rs": "//", ".swift": "//", ".php": "//",
    ".glsl": "//", ".shader": "//", ".gdshader": "//", ".scss": "//",
    ".sql": "--", ".lua": "--",
}
DATED = re.compile(r"\u2014\s*\d{4}-\d{2}-\d{2}[\s*/]*$")
EXEMPT = re.compile(
    r"^(!|\s*-\*-|\s*(noqa|type:|pylint|ruff|mypy|fmt:|isort|coding[:=]|pragma|"
    r"eslint|prettier|biome|@ts-|jshint|global |istanbul|codegen|Code generated))",
    re.I,
)
LICENSE = re.compile(r"copyright|spdx|licen[sc]e|all rights reserved", re.I)
MAX_BYTES = 2_000_000
COMMENT_SHARE = 0.08       # 5% is the rule; flag only a clear overshoot, not one comment over
MIN_COMMENTS = 5           # a 13-line data class with 2 contract lines is not the rot the rule targets


def review(path: str) -> str | None:
    ext = os.path.splitext(path)[1].lower()
    marker = LINE_MARKERS.get(ext)
    if not marker or not os.path.isfile(path) or os.path.getsize(path) > MAX_BYTES:
        return None
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
    if not lines:
        return None

    comments = 0
    undated = 0
    for i, raw in enumerate(lines):
        stripped = raw.strip()
        if not stripped.startswith(marker):
            continue
        body = stripped[len(marker):]
        if not body.strip():
            continue
        comments += 1
        if EXEMPT.match(body) or (i < 6 and LICENSE.search(body)):
            comments -= 1
            continue
        if not DATED.search(stripped):
            undated += 1

    share = comments / len(lines)
    bits = []
    if undated:
        bits.append(f"{undated} undated")
    if comments >= MIN_COMMENTS and share > COMMENT_SHARE:
        bits.append(f"{share * 100:.0f}% of lines")
    if not bits:
        return None
    return (f"ccshut {os.path.basename(path)}: {', '.join(bits)}. "
            "One line each, ending ' — YYYY-MM-DD' (em dash); cut the rest.")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        path = (payload.get("tool_input") or {}).get("file_path")
        note = review(path) if path else None
    except Exception:
        return 0
    if note:
        body = json.dumps({
            "suppressOutput": True,
            "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": note},
        }, ensure_ascii=False)
        sys.stdout.buffer.write(body.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
