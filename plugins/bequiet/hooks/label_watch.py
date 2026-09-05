"""PostToolUse check: catch a bad step label the moment it is written, not at the end of the turn.

A Stop hook fires once, after every label is already on screen. This one fires between calls, so
slip two through five never happen. Silent and token-free unless a label actually broke.
"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tempfile

TAIL_BYTES = 256_000
CYRILLIC = re.compile(r"[\u0400-\u04FF]")
FENCE = re.compile(r"```.*?```", re.S)
INLINE = re.compile(r"`[^`]*`")
BAD_PUNCT = re.compile(r"[,;:\u2014\u2013]")
OPENER = re.compile(r"^(now|first|next|then|right|ok|okay|let me|i'?ll|i am|i'?m)\b", re.I)
LABEL_WORDS = 4


def last_label(path: str) -> str | None:
    """Text of the assistant's most recent text block, or None if a user turn came first."""
    with open(path, "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - TAIL_BYTES))
        raw = fh.read().decode("utf-8", "replace")
    lines = raw.split("\n")
    if size > TAIL_BYTES:
        lines = lines[1:]
    for line in reversed(lines):
        line = line.strip()
        if not line:
            continue
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if rec.get("isSidechain"):
            continue
        kind = rec.get("type")
        content = rec.get("message", {}).get("content")
        if kind == "user":
            if isinstance(content, str):
                return None
            if isinstance(content, list) and not any(
                isinstance(b, dict) and b.get("type") == "tool_result" for b in content
            ):
                return None
            continue
        if kind != "assistant" or not isinstance(content, list):
            continue
        for b in reversed(content):
            if isinstance(b, dict) and b.get("type") == "text":
                text = (b.get("text") or "").strip()
                if text:
                    return text
    return None


def fault(text: str) -> str | None:
    body = INLINE.sub(" ", FENCE.sub(" ", text)).strip()
    if not body or CYRILLIC.search(body):
        return None
    words = body.split()
    if OPENER.match(body):
        return "opens on an ordering word or a pronoun"
    if len(words) > LABEL_WORDS:
        return f"{len(words)} words"
    if BAD_PUNCT.search(body):
        return "carries a comma, colon or dash"
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        path = payload.get("transcript_path")
        if not path or not os.path.isfile(path):
            return 0
        text = last_label(path)
        if not text:
            return 0
        why = fault(text)
        if not why:
            return 0
        session = str(payload.get("session_id") or "x")[:40]
        stamp = os.path.join(tempfile.gettempdir(), f"bequiet-label-{session}.txt")
        digest = hashlib.sha1(text.encode("utf-8")).hexdigest()
        if os.path.isfile(stamp):
            with open(stamp, encoding="utf-8") as fh:
                if fh.read().strip() == digest:
                    return 0
        with open(stamp, "w", encoding="utf-8") as fh:
            fh.write(digest)
        note = (f'bequiet: that step label ({why}) - "{text.splitlines()[0][:60]}". '
                "Write <=4 words or nothing before the next call.")
        body = json.dumps({
            "suppressOutput": True,
            "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": note},
        }, ensure_ascii=False)
        sys.stdout.buffer.write(body.encode("utf-8"))
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
