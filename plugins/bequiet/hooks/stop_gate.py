"""Stop-hook check: block a turn that broke bequiet's shapes. Zero model tokens when clean."""
from __future__ import annotations

import json
import re
import sys

TAIL_BYTES = 4_000_000
CYRILLIC = re.compile(r"[\u0400-\u04FF]")
FENCE = re.compile(r"```.*?```", re.S)
INLINE = re.compile(r"`[^`]*`")
HEADING = re.compile(r"^\s{0,3}#{1,6}\s")
TABLE = re.compile(r"^\s*\|?[\s:|-]*\|[\s:|-]*$")
BAD_PUNCT = re.compile(r"[,;:\u2014\u2013]")

LABEL_WORDS = 4
ANSWER_LINES = 9           # 8 is the rule; one line of slack is not worth a rewrite
ANSWER_MIN_WORDS = 12      # below this an English tail is a fragment, not a report


def strip_code(text: str) -> str:
    return INLINE.sub(" ", FENCE.sub(" ", text))


def load_turn(path: str) -> list[tuple[str, bool]]:
    """Assistant text blocks since the last real user prompt, oldest first."""
    with open(path, "rb") as fh:
        fh.seek(0, 2)
        size = fh.tell()
        fh.seek(max(0, size - TAIL_BYTES))
        raw = fh.read().decode("utf-8", "replace")
    lines = raw.split("\n")
    if size > TAIL_BYTES:
        lines = lines[1:]

    records = []
    for line in lines:
        line = line.strip()
        if not line:
            continue
        try:
            records.append(json.loads(line))
        except ValueError:
            continue

    start = 0
    for i in range(len(records) - 1, -1, -1):
        rec = records[i]
        if rec.get("type") != "user" or rec.get("isSidechain"):
            continue
        content = rec.get("message", {}).get("content")
        if isinstance(content, str):
            start = i + 1
            break
        if isinstance(content, list) and not any(
            isinstance(b, dict) and b.get("type") == "tool_result" for b in content
        ):
            start = i + 1
            break

    out: list[tuple[str, bool]] = []
    for rec in records[start:]:
        if rec.get("type") != "assistant" or rec.get("isSidechain"):
            continue
        content = rec.get("message", {}).get("content")
        if not isinstance(content, list):
            continue
        has_tool = any(isinstance(b, dict) and b.get("type") == "tool_use" for b in content)
        for b in content:
            if isinstance(b, dict) and b.get("type") == "text":
                text = (b.get("text") or "").strip()
                if text:
                    out.append((text, has_tool))
    return out


def with_labels(reason: str, labels: list[str]) -> str:
    if not labels:
        return reason
    return reason + f" Also {len(labels)} step label(s) broke the <=4-word rule: " + "; ".join(labels)


def check(blocks: list[tuple[str, bool]]) -> str | None:
    if not blocks:
        return None
    labels: list[str] = []
    for idx, (text, _) in enumerate(blocks):
        body = strip_code(text)
        final = idx == len(blocks) - 1
        lines = [ln for ln in body.splitlines() if ln.strip()]
        words = body.split()

        if not final:
            # A label is already on screen when Stop fires; blocking cannot retract it, so it is
            # only ever reported alongside a block the answer has earned - 2026-09-04
            if not CYRILLIC.search(body) and (len(words) > LABEL_WORDS or BAD_PUNCT.search(body)):
                labels.append(" ".join(words[:6]))
            continue

        if any(HEADING.match(ln) for ln in lines):
            return with_labels("The answer used a markdown heading. bequiet bans headings. Rewrite it as plain Ukrainian sentences.", labels)
        if sum(1 for ln in lines if TABLE.match(ln) and ln.count("|") >= 2):
            return with_labels("The answer used a table. bequiet bans tables. Rewrite it as plain Ukrainian sentences.", labels)
        if len(words) >= ANSWER_MIN_WORDS and not CYRILLIC.search(body):
            return with_labels("The final answer is in English. bequiet requires Ukrainian for the answer. Rewrite it.", labels)
        if len(lines) > ANSWER_LINES:
            return with_labels(
                f"The final answer ran {len(lines)} lines. bequiet caps it at 8. "
                "Delete the facts the user cannot act on, do not reflow them.", labels)
    return None


def main() -> int:
    try:
        payload = json.load(sys.stdin)
    except Exception:
        return 0
    if payload.get("stop_hook_active"):
        return 0
    path = payload.get("transcript_path")
    if not path:
        return 0
    try:
        reason = check(load_turn(path))
    except Exception:
        return 0
    if reason:
        body = json.dumps({"decision": "block", "reason": reason}, ensure_ascii=True)
        sys.stdout.buffer.write(body.encode("utf-8"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
