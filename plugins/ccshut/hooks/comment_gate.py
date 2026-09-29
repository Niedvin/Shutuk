"""PostToolUse check: flag comments in a just-written file that break ccshut. Note only, never blocks — 2026-09-29"""
from __future__ import annotations

import json
import os
import re
import sys

HASH = ("py gd sh bash zsh fish rb pl yml yaml toml tf nix ps1 psm1 psd1 ex exs r jl "
        "cmake gitignore").split()
SLASH = ("c h cpp hpp cc cs js mjs cjs ts tsx jsx java kt kts go rs swift php dart scala groovy gradle zig "
         "glsl shader gdshader vert frag hlsl wgsl scss less").split()
DASH = "sql lua hs elm".split()
LINE_MARKERS = {f".{e}": "#" for e in HASH} | {f".{e}": "//" for e in SLASH} | {f".{e}": "--" for e in DASH}
NAME_MARKERS = {"makefile": "#", "dockerfile": "#"}
BLOCK_EXTS = {f".{e}" for e in SLASH} | {".css"}
BLOCK_HEAD = re.compile(r"^(/\*+|\*+)\s*")
TRIPLE = ('"""', "'''")
DATED = re.compile(r"—\s*\d{4}-\d{2}-\d{2}[\s*/]*$")
EXEMPT = re.compile(
    r"^(\s*-\*-|\s*(noqa|type:|pylint|ruff|mypy|fmt:|isort|coding[:=]|pragma|"
    r"eslint|prettier|biome|@ts-|jshint|global |istanbul|codegen|Code generated))",
    re.I,
)
LICENSE = re.compile(r"copyright|spdx|licen[sc]e|all rights reserved", re.I)
MAX_BYTES = 2_000_000
COMMENT_SHARE = 0.08       # 5% is the rule; flag only a clear overshoot, not one comment over
MIN_COMMENTS = 5           # a 13-line data class with 2 contract lines is not the rot the rule targets


def marker_for(path: str) -> str | None:
    base = os.path.basename(path).lower()
    return LINE_MARKERS.get(os.path.splitext(base)[1]) or NAME_MARKERS.get(base)


def trailing(line: str, marker: str) -> str | None:
    quote = ""
    i = 0
    while i < len(line):
        ch = line[i]
        if quote:
            if ch == "\\":
                i += 1
            elif ch == quote:
                quote = ""
        elif ch in "\"'`":
            quote = ch
        elif line.startswith(marker, i) and i > 0 and line[i - 1].isspace():
            return line[i:]
        i += 1
    return None


def review(path: str) -> str | None:
    marker = marker_for(path)
    if not marker or not os.path.isfile(path) or os.path.getsize(path) > MAX_BYTES:
        return None
    with open(path, encoding="utf-8", errors="replace") as fh:
        lines = fh.read().splitlines()
    if not lines:
        return None
    block = os.path.splitext(path)[1].lower() in BLOCK_EXTS
    py_like = marker == "#"

    found: list[tuple[int, str, int]] = []
    start = -1
    in_triple = False
    in_block = False
    for i, raw in enumerate(lines):
        stripped = raw.strip()
        if py_like:
            flips = sum(stripped.count(t) for t in TRIPLE) % 2 == 1
            if in_triple or flips:
                in_triple = in_triple != flips
                continue
        if in_block or (block and stripped.startswith("/*")):
            start = start if in_block else i
            found.append((i, stripped, start))
            in_block = "*/" not in stripped
            continue
        if stripped.startswith(marker):
            found.append((i, stripped, -1))
            continue
        tail = trailing(raw, marker)
        if tail:
            found.append((i, tail.strip(), -1))

    licensed = {g for i, text, g in found if g >= 0 and g < 6 and LICENSE.search(text)}
    comments = undated = 0
    for i, text, group in found:
        body = text[len(marker):] if text.startswith(marker) else BLOCK_HEAD.sub("", text)
        if not body.strip("/*! "):
            continue
        if (i == 0 and text.startswith("#!")) or EXEMPT.match(body) or group in licensed:
            continue
        if group < 0 and i < 6 and LICENSE.search(body):
            continue
        comments += 1
        if not DATED.search(text):
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
