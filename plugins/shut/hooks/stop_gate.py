"""Stop-hook check: block a turn that broke shut's shapes — 2026-09-29"""
from __future__ import annotations

import json
import os
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
QUESTION_TOOL = "AskUserQuestion"
ANSWER_LINES = int(os.environ.get("SHUT_ANSWER_LINES", "30"))  # 8 by rule, 30 when a large task closes — 2026-09-29
ANSWER_MIN_WORDS = 12      # shorter English tails are fragments — 2026-09-29


def strip_code(text: str) -> str:
    return INLINE.sub(" ", FENCE.sub(" ", text))


def load_turn(path: str) -> list[tuple[str, set[str]]]:
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

    out: list[tuple[str, set[str]]] = []
    last = -1
    for rec in records[start:]:
        if rec.get("isSidechain"):
            continue
        if rec.get("type") == "user":
            last = -1
            continue
        content = rec.get("message", {}).get("content")
        if rec.get("type") != "assistant" or not isinstance(content, list):
            continue
        for b in content:
            if not isinstance(b, dict):
                continue
            if b.get("type") == "text" and (b.get("text") or "").strip():
                out.append((b["text"].strip(), set()))
                last = len(out) - 1
            elif b.get("type") == "tool_use" and last >= 0:
                out[last][1].add(b.get("name"))
    return out


def with_labels(reason: str, labels: list[str]) -> str:
    if not labels:
        return reason
    return reason + f" Also {len(labels)} line(s) between calls broke the <=4-word English rule: " + "; ".join(labels)


def check(blocks: list[tuple[str, set[str]]]) -> str | None:
    if not blocks:
        return None
    labels: list[str] = []
    for idx, (text, tools) in enumerate(blocks):
        body = strip_code(text)
        final = idx == len(blocks) - 1
        lines = [ln for ln in body.splitlines() if ln.strip()]
        words = body.split()

        if not final:
            # shown text cannot be retracted, so report it only beside a block the answer earned — 2026-09-04
            if CYRILLIC.search(body):
                if QUESTION_TOOL not in tools:
                    labels.append("(Ukrainian) " + " ".join(words[:6]))
            elif len(words) > LABEL_WORDS or BAD_PUNCT.search(body):
                labels.append(" ".join(words[:6]))
            continue

        if any(HEADING.match(ln) for ln in lines):
            return with_labels("The answer used a markdown heading. shut bans headings. Rewrite it as plain Ukrainian sentences.", labels)
        if sum(1 for ln in lines if TABLE.match(ln) and ln.count("|") >= 2):
            return with_labels("The answer used a table. shut bans tables. Rewrite it as plain Ukrainian sentences.", labels)
        if len(words) >= ANSWER_MIN_WORDS and not CYRILLIC.search(body):
            return with_labels("The final answer is in English. shut requires Ukrainian for the answer. Rewrite it.", labels)
        if len(lines) > ANSWER_LINES:
            return with_labels(
                f"The final answer ran {len(lines)} lines. shut caps it at {ANSWER_LINES}, and at 8 "
                "unless a large task just closed. Delete the facts the user cannot act on, "
                "do not reflow them.", labels)
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
