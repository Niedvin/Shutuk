#!/usr/bin/env bash
# Remove CCShut and BeQuiet from every agent install.sh put them in, and put caveman back.
#
# The macOS twin of uninstall.py. Needs no zips.
#
#   ./uninstall.sh                    remove what install.sh installed
#   ./uninstall.sh --dry-run          show what it would remove, touch nothing
#   ./uninstall.sh --force            also remove skill folders with no install marker
#   ./uninstall.sh --keep-caveman-off leave caveman disabled

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MARKER=".shut-install.json"
HOOK_PREFIX="shut-"
PACKAGES="ccshut bequiet"
BACKUPS="$HOME/.shut-backups"
CAVEMAN_STATE="$BACKUPS/caveman-state.json"
UNINSTALL_STATE="$BACKUPS/uninstall.json"
LEGACY_STATE="$HERE/uninstall.json"

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_OUTPUT_STYLES="$CLAUDE_HOME/output-styles"

CODEX_HOOKS="$HOME/.codex/hooks.json"
CODEX_HOOK_DIR="$HOME/.codex/hooks"
CODEX_CONFIG="$HOME/.codex/config.toml"

SKILL_DIRS="claude|$CLAUDE_HOME/skills
agents|$HOME/.agents/skills
codex|$HOME/.codex/skills
opencode|$HOME/.config/opencode/skills
cursor|$HOME/.cursor/skills-cursor
gemini|$HOME/.gemini/skills"

ALWAYS_ON="codex|$HOME/.codex/AGENTS.md
opencode|$HOME/.config/opencode/AGENTS.md
gemini|$HOME/.gemini/GEMINI.md"


# ----------------------------------------------------------------- arguments

DRY=0; FORCE=0; KEEP_CAVEMAN_OFF=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)          DRY=1 ;;
        --force)            FORCE=1 ;;
        --keep-caveman-off) KEEP_CAVEMAN_OFF=1 ;;
        -h|--help)          sed -n '2,10p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)                  echo "uninstall.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done


# ----------------------------------------------------------------- small helpers

keep_copy() { [ -f "$1" ] && [ "$DRY" != 1 ] && cp -p "$1" "$1.bak-uninstall"; return 0; }

# Pre-image kept aside, promoted to a .bak only once the op reports a change — 2026-09-05
snap() { if [ -f "$1" ]; then cp -p "$1" "$WORK/pre"; else rm -f "$WORK/pre"; fi; }
promote() { [ "$DRY" = 1 ] && return 0; [ -f "$WORK/pre" ] && cp -p "$WORK/pre" "$1$2"; return 0; }

JS="$HERE/shut-json.js"
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    JSON_RUNNER="osascript"
elif command -v node >/dev/null 2>&1; then
    JSON_RUNNER="node"
else
    echo "uninstall.sh: needs osascript (macOS) or node. Use uninstall.py instead." >&2
    exit 1
fi
[ -f "$JS" ] || { echo "uninstall.sh: shut-json.js must sit next to this script." >&2; exit 1; }

json() {
    case "$JSON_RUNNER" in
        osascript) osascript -l JavaScript "$JS" "$@" ;;
        node)      node "$JS" "$@" ;;
    esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shut.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

# ----------------------------------------------------------------- removal

drop() { # $1 skill dir -> prints the note
    [ -e "$1" ] || return 0
    if [ ! -f "$1/$MARKER" ] && [ "$FORCE" != 1 ]; then
        printf 'kept (not installed by install.sh; --force removes it)'
        return 0
    fi
    [ "$DRY" = 1 ] || rm -rf "$1"
    printf 'removed'
}

ungraft() { # $1 path  $2 name -> prints the note
    local begin="<!-- shut:$2:begin -->" end="<!-- shut:$2:end -->"
    local head="$WORK/ug.head" tail="$WORK/ug.tail" new="$WORK/ug.new"
    [ -f "$1" ] || return 0
    grep -qF "$begin" "$1" && grep -qF "$end" "$1" || return 0
    awk -v b="$begin" 'index($0,b){exit} {print}' "$1" > "$head"
    awk -v e="$end" 'p{print} index($0,e){p=1}' "$1" | sed '/./,$!d' > "$tail"
    if grep -q '[^[:space:]]' "$head"; then
        awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--) if(lines[i]!=""){last=i;break}
             for(i=1;i<=last;i++) print lines[i]}' "$head" > "$new"
    else
        : > "$new"
    fi
    cat "$tail" >> "$new"
    if [ "$DRY" != 1 ]; then keep_copy "$1"; cp "$new" "$1"; fi
    printf 'block removed'
}

unhook() { # $1 pkg -> prints the note
    local notes="" f
    if [ -d "$CODEX_HOOK_DIR" ]; then
        for f in "$CODEX_HOOK_DIR/$HOOK_PREFIX$1-session-start."*; do
            [ -e "$f" ] || continue
            notes="files removed"
            [ "$DRY" = 1 ] || rm -f "$f"
        done
    fi
    if [ -f "$CODEX_HOOKS" ]; then
        snap "$CODEX_HOOKS"
        if json hook-del "$CODEX_HOOKS" "$1" "$HOOK_PREFIX" "$DRY" >/dev/null; then
            promote "$CODEX_HOOKS" ".bak-uninstall"
            notes="${notes:+$notes, }hooks.json entry removed"
        fi
    fi
    printf '%s' "$notes"
}

restore_caveman() { # prints note lines
    [ -f "$CAVEMAN_STATE" ] || return 0
    local src off count block
    json state-pairs "$CAVEMAN_STATE" renamed 2>/dev/null | while IFS="$(printf '\t')" read -r src off; do
        if [ -d "$off" ] && [ ! -e "$src" ]; then
            printf 'skill  %s\n' "$src"
            [ "$DRY" = 1 ] || mv "$off" "$src"
        fi
    done

    if [ -f "$CODEX_HOOKS" ] && json state-get "$CAVEMAN_STATE" hooks >/dev/null 2>&1; then
        snap "$CODEX_HOOKS"
        count="$(json caveman-restore "$CODEX_HOOKS" "$CAVEMAN_STATE" "$DRY")" \
            && { promote "$CODEX_HOOKS" ".bak-uninstall"
                 printf 'hooks  %s entries back in %s\n' "$count" "$CODEX_HOOKS"; }
    fi

    if json state-get "$CAVEMAN_STATE" developer_instructions > "$WORK/devins" 2>/dev/null; then
        if [ -s "$WORK/devins" ] && [ -f "$CODEX_CONFIG" ] && \
           ! grep -q developer_instructions "$CODEX_CONFIG"; then
            printf 'config developer_instructions back in %s\n' "$CODEX_CONFIG"
            if [ "$DRY" != 1 ]; then
                keep_copy "$CODEX_CONFIG"
                cat "$WORK/devins" "$CODEX_CONFIG" > "$WORK/config.toml"
                cp "$WORK/config.toml" "$CODEX_CONFIG"
            fi
        fi
    fi

    if [ "$(json state-get "$CAVEMAN_STATE" gemini 2>/dev/null)" = true ] && command -v gemini >/dev/null 2>&1; then
        if [ "$DRY" = 1 ] || gemini extensions enable caveman >/dev/null 2>&1; then
            printf 'gemini extension caveman\n'
        else
            printf 'gemini extension caveman -- FAILED, enable it by hand\n'
        fi
    fi
}

claude_settings_off() { # prints note lines
    [ -f "$UNINSTALL_STATE" ] || return 0
    local file note
    json settings-list "$UNINSTALL_STATE" 2>/dev/null | while IFS= read -r file; do
        [ -n "$file" ] || continue
        snap "$file"
        note="$(json settings-restore "$file" "$UNINSTALL_STATE" "$DRY")" || continue
        if [ "$note" = remove ]; then
            [ -f "$file" ] || continue
            printf '%s  removed (did not exist before install)\n' "$file"
            if [ "$DRY" != 1 ]; then keep_copy "$file"; rm -f "$file"; fi
        else
            printf '%s  restored\n' "$file"
            promote "$file" ".bak-uninstall"
        fi
    done

    if [ -f "$CLAUDE_OUTPUT_STYLES/shut.md" ]; then
        printf 'output-styles/shut.md  removed\n'
        [ "$DRY" = 1 ] || rm -f "$CLAUDE_OUTPUT_STYLES/shut.md"
    fi
}


# ----------------------------------------------------------------- main

if [ -f "$LEGACY_STATE" ] && [ ! -f "$UNINSTALL_STATE" ]; then
    mkdir -p "$BACKUPS" && mv "$LEGACY_STATE" "$UNINSTALL_STATE"
fi

TAG=""; [ "$DRY" = 1 ] && TAG=" (dry run)"
TOUCHED="$WORK/touched"; : > "$TOUCHED"

echo "Skills$TAG"
while IFS='|' read -r name root; do
    [ -n "$name" ] || continue
    for pkg in $PACKAGES; do
        note="$(drop "$root/$pkg")"
        [ -n "$note" ] && { echo yes >> "$TOUCHED"; printf '  %-10s %-8s %s\n' "$name" "$pkg" "$note"; }
    done
done <<EOF
$SKILL_DIRS
EOF

echo "Hooks$TAG"
for pkg in $PACKAGES; do
    note="$(unhook "$pkg")"
    [ -n "$note" ] && { echo yes >> "$TOUCHED"; printf '  %-10s %-8s %s\n' codex "$pkg" "$note"; }
done

echo "Always-on rule$TAG"
while IFS='|' read -r name path; do
    [ -n "$name" ] || continue
    for pkg in $PACKAGES; do
        note="$(ungraft "$path" "$pkg")"
        [ -n "$note" ] && { echo yes >> "$TOUCHED"; printf '  %-10s %-8s %s  %s\n' "$name" "$pkg" "$note" "$path"; }
    done
done <<EOF
$ALWAYS_ON
EOF

echo "Claude settings$TAG"
NOTES="$(claude_settings_off)"
if [ -n "$NOTES" ]; then
    echo yes >> "$TOUCHED"
    printf '%s\n' "$NOTES" | while IFS= read -r note; do printf '  %-10s %s\n' claude "$note"; done
    [ "$DRY" = 1 ] || rm -f "$UNINSTALL_STATE"
else
    printf '  %-10s unchanged\n' claude
fi

if [ "$KEEP_CAVEMAN_OFF" != 1 ]; then
    echo "Caveman$TAG"
    NOTES="$(restore_caveman)"
    if [ -n "$NOTES" ]; then
        echo yes >> "$TOUCHED"
        printf '%s\n' "$NOTES" | while IFS= read -r note; do echo "  restored  $note"; done
        [ "$DRY" = 1 ] || rm -f "$CAVEMAN_STATE"
    else
        echo "  nothing to put back"
    fi
fi

echo
if [ -s "$TOUCHED" ]; then
    echo "Backups of every edited file are alongside it as *.bak-uninstall."
else
    echo "Nothing found. Nothing removed."
fi
