"""PostToolUse check: a bad step label, and one 30-min heartbeat per silent stretch — 2026-09-29"""
from __future__ import annotations

import hashlib
import json
import os
import re
import sys
import tempfile
import time
from datetime import datetime

TAIL_BYTES = 256_000
CYRILLIC = re.compile(r"[Ѐ-ӿ]")
FENCE = re.compile(r"```.*?```", re.S)
INLINE = re.compile(r"`[^`]*`")
BAD_PUNCT = re.compile(r"[,;:—–]")
OPENER = re.compile(r"^(now|first|next|then|right|ok|okay|let me|i'?ll|i am|i'?m)\b", re.I)
LABEL_WORDS = 4
QUESTION_TOOL = "AskUserQuestion"
BEAT_SECONDS = 60 * float(os.environ.get("SHUT_HEARTBEAT_MIN", "30"))


def epoch(value) -> float | None:
    try:
        return datetime.fromisoformat(str(value).replace("Z", "+00:00")).timestamp()
    except ValueError:
        return None


def read_tail(path: str) -> list[dict]:
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
        try:
            rec = json.loads(line)
        except ValueError:
            continue
        if isinstance(rec, dict) and not rec.get("isSidechain"):
            records.append(rec)
    return records


def starts_turn(rec: dict) -> bool:
    if rec.get("type") != "user":
        return False
    content = rec.get("message", {}).get("content")
    if isinstance(content, str):
        return True
    return isinstance(content, list) and not any(
        isinstance(b, dict) and b.get("type") == "tool_result" for b in content
    )


def human_prompt(rec: dict) -> bool:
    # origin marks injected wake-ups (task notifications), not a word from the user — 2026-09-29
    return starts_turn(rec) and not rec.get("origin")


def last_text(rec: dict) -> str:
    content = rec.get("message", {}).get("content")
    if not isinstance(content, list):
        return ""
    for b in reversed(content):
        if isinstance(b, dict) and b.get("type") == "text" and (b.get("text") or "").strip():
            return b["text"].strip()
    return ""


def last_label(records: list[dict]) -> str | None:
    for rec in reversed(records):
        if starts_turn(rec):
            return None
        if rec.get("type") == "assistant":
            text = last_text(rec)
            if text:
                return text
    return None


def last_word(records: list[dict]) -> float | None:
    for rec in reversed(records):
        if human_prompt(rec) or (rec.get("type") == "assistant" and last_text(rec)):
            return epoch(rec.get("timestamp"))
    return None


def fault(text: str, tool: str) -> str | None:
    body = INLINE.sub(" ", FENCE.sub(" ", text)).strip()
    if not body or tool == QUESTION_TOOL:
        return None
    if CYRILLIC.search(body):
        return "Ukrainian text before a tool call"
    words = body.split()
    if OPENER.match(body):
        return "opens on an ordering word or a pronoun"
    if len(words) > LABEL_WORDS:
        return f"{len(words)} words"
    if BAD_PUNCT.search(body):
        return "carries a comma, colon or dash"
    return None


def state_path(name: str, session: str) -> str:
    return os.path.join(tempfile.gettempdir(), f"shut-{name}-{session}.json")


def heartbeat(records: list[dict], session: str) -> str | None:
    path = state_path("beat", session)
    try:
        with open(path, encoding="utf-8") as fh:
            state = json.load(fh)
    except (OSError, ValueError):
        state = {}
    now = time.time()
    seen = last_word(records)
    ref = max(seen or 0.0, state.get("ref") or 0.0) or now
    state["ref"] = ref
    minutes = int((now - ref) // 60)
    fire = now - ref >= BEAT_SECONDS and (state.get("beat") or 0.0) < ref
    if fire:
        state["beat"] = now
    with open(path, "w", encoding="utf-8") as fh:
        json.dump(state, fh)
    if not fire:
        return None
    return (f"shut: {minutes} min in with no word to the user. Write one step label now "
            "(<=4 English words), then stay silent until something changes.")


def label_note(records: list[dict], tool: str, session: str) -> str | None:
    text = last_label(records)
    why = fault(text, tool) if text else None
    if not why:
        return None
    stamp = state_path("label", session)
    digest = hashlib.sha1(text.encode("utf-8")).hexdigest()
    try:
        with open(stamp, encoding="utf-8") as fh:
            if json.load(fh).get("digest") == digest:
                return None
    except (OSError, ValueError):
        pass
    with open(stamp, "w", encoding="utf-8") as fh:
        json.dump({"digest": digest}, fh)
    return (f'shut: that step label ({why}) - "{text.splitlines()[0][:60]}". '
            "Write <=4 English words or nothing before the next call.")


def main() -> int:
    try:
        payload = json.load(sys.stdin)
        path = payload.get("transcript_path")
        if not path or not os.path.isfile(path):
            return 0
        session = re.sub(r"[^\w-]", "", str(payload.get("session_id") or "x"))[:40]
        records = read_tail(path)
        notes = [n for n in (label_note(records, str(payload.get("tool_name") or ""), session),
                             heartbeat(records, session)) if n]
        if not notes:
            return 0
        body = json.dumps({
            "suppressOutput": True,
            "hookSpecificOutput": {"hookEventName": "PostToolUse", "additionalContext": "\n".join(notes)},
        }, ensure_ascii=False)
        sys.stdout.buffer.write(body.encode("utf-8"))
    except Exception:
        return 0
    return 0


if __name__ == "__main__":
    sys.exit(main())
