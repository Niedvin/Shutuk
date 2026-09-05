#!/usr/bin/env bash
# Install CCShut and Shut into every agent on this machine that reads skills.
#
# The macOS twin of install.py. Needs nothing installed: bash, unzip, osascript and
# chmod all ship with macOS. On Linux it needs node for the JSON work.
#
#   ./install.sh                 install everywhere it finds an agent
#   ./install.sh --dry-run       show what it would do, touch nothing
#   ./install.sh --list          list detected agents and exit
#   ./install.sh --only claude,codex
#   ./install.sh --skip gemini
#   ./install.sh --no-always-on
#   ./install.sh --no-hooks
#   ./install.sh --keep-caveman

set -uo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
MARKER=".shut-install.json"
HOOK_PREFIX="shut-"
OUTPUT_STYLE="Shut"
SCAN_DEPTH=4
BACKUPS="$HOME/.shut-backups"
CAVEMAN_STATE="$BACKUPS/caveman-state.json"

# State lives outside the repo so a clone stays clean and `git pull` cannot clobber it — 2026-09-05
UNINSTALL_STATE="$BACKUPS/uninstall.json"
LEGACY_STATE="$HERE/uninstall.json"

CLAUDE_HOME="${CLAUDE_CONFIG_DIR:-$HOME/.claude}"
CLAUDE_OUTPUT_STYLES="$CLAUDE_HOME/output-styles"

CODEX_HOOKS="$HOME/.codex/hooks.json"
CODEX_HOOK_DIR="$HOME/.codex/hooks"
CODEX_CONFIG="$HOME/.codex/config.toml"

PACKAGES="ccshut shut"
zip_for() { case "$1" in ccshut) echo CCShut.zip ;; shut) echo Shut.zip ;; esac; }

# Read by the installers only; a Claude Code plugin has no use for them — 2026-09-05
INSTALLER_ONLY="manifest.json always-on.md flat"

# Extracted zips can land without an exec bit, and the harness runs these directly — 2026-09-05
EXEC_NAMES="run-hook.cmd session-start anchor-tool anchor-prompt comment-gate label-watch stop-gate"

# probe list is ';'-separated. form: how a skill is laid out there.
TARGETS="claude|$CLAUDE_HOME|$CLAUDE_HOME/skills|plugin
agents|$HOME/.agents;$HOME/.codex;$HOME/.config/opencode|$HOME/.agents/skills|flat
codex|$HOME/.codex|$HOME/.codex/skills|flat
opencode|$HOME/.config/opencode;$HOME/.opencode|$HOME/.config/opencode/skills|flat
cursor|$HOME/.cursor|$HOME/.cursor/skills-cursor|flat
gemini|$HOME/.gemini|$HOME/.gemini/skills|flat"

# Skills load on demand; these files are read every session, so the rule holds without a trigger.
# Claude Code is absent on purpose: its SessionStart hook already injects the same text.
ALWAYS_ON="codex|$HOME/.codex/AGENTS.md
opencode|$HOME/.config/opencode/AGENTS.md
gemini|$HOME/.gemini/GEMINI.md"

# Directory names that are never worth descending into, whatever machine this runs on.
SCAN_SKIP="Library Applications Volumes private cores Network System Movies Music Pictures
DerivedData Pods Carthage node_modules __pycache__ venv obj bin build builds dist logs
packages target site-packages dist-packages Scripts AppData Temp"

CAVEMAN_PATTERNS="caveman caveman-* cavecrew"


# ----------------------------------------------------------------- arguments

DRY=0; LIST=0; ONLY=""; SKIP=""; NO_ALWAYS_ON=0; NO_HOOKS=0; KEEP_CAVEMAN=0
while [ $# -gt 0 ]; do
    case "$1" in
        --dry-run)       DRY=1 ;;
        --list)          LIST=1 ;;
        --only)          ONLY="${2:-}"; shift ;;
        --skip)          SKIP="${2:-}"; shift ;;
        --no-always-on)  NO_ALWAYS_ON=1 ;;
        --no-hooks)      NO_HOOKS=1 ;;
        --keep-caveman)  KEEP_CAVEMAN=1 ;;
        -h|--help)       sed -n '2,15p' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
        *)               echo "install.sh: unknown option $1" >&2; exit 2 ;;
    esac
    shift
done


# ----------------------------------------------------------------- small helpers

stamp() { date +%Y%m%d-%H%M%S; }

back_up() { [ -f "$1" ] && [ "$DRY" != 1 ] && cp -p "$1" "$1.bak-$(stamp)"; return 0; }

# Pre-image kept aside, promoted to a .bak only once the op reports a change — 2026-09-05
snap() { if [ -f "$1" ]; then cp -p "$1" "$WORK/pre"; else rm -f "$WORK/pre"; fi; }
promote() { [ "$DRY" = 1 ] && return 0; [ -f "$WORK/pre" ] && cp -p "$WORK/pre" "$1$2"; return 0; }

in_list() { # $1 needle, $2 whitespace- or comma-separated haystack
    case " $(printf '%s' "$2" | tr ',' ' ') " in *" $1 "*) return 0 ;; *) return 1 ;; esac
}

JS="$HERE/shut-json.js"
if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
    JSON_RUNNER="osascript"
elif command -v node >/dev/null 2>&1; then
    JSON_RUNNER="node"
else
    echo "install.sh: needs osascript (macOS) or node. Use install.py instead." >&2
    exit 1
fi
if [ ! -f "$JS" ]; then
    echo "install.sh: shut-json.js must sit next to this script." >&2
    exit 1
fi

json() {
    case "$JSON_RUNNER" in
        osascript) osascript -l JavaScript "$JS" "$@" ;;
        node)      node "$JS" "$@" ;;
    esac
}

WORK="$(mktemp -d "${TMPDIR:-/tmp}/shut.XXXXXX")" || exit 1
trap 'rm -rf "$WORK"' EXIT INT TERM

# ----------------------------------------------------------------- the one dialog

nag() { # $1 message
    if [ "$(uname -s 2>/dev/null)" = "Darwin" ] && command -v osascript >/dev/null 2>&1; then
        osascript -e "display dialog \"$1\" buttons {\"Where?\"} default button 1 with title \"Shut\"" \
            >/dev/null 2>&1 && return 0
    fi
    for exe in zenity kdialog xmessage; do
        command -v "$exe" >/dev/null 2>&1 || continue
        case "$exe" in
            zenity)   zenity --info --text="$1" --ok-label="Where?" --title=Shut >/dev/null 2>&1 ;;
            kdialog)  kdialog --msgbox "$1" --ok-label "Where?" --title Shut >/dev/null 2>&1 ;;
            xmessage) xmessage -center -buttons "Where?" "$1" >/dev/null 2>&1 ;;
        esac
        return 0
    done
    echo "$1" >&2
}


# ----------------------------------------------------------------- packages

unpack() { # fills $WORK/<pkg> for every package
    local missing="" pkg zipname loose archive d
    for pkg in $PACKAGES; do
        zipname="$(zip_for "$pkg")"
        loose=""
        for d in "$HERE" "$PWD"; do
            [ -f "$d/plugins/$pkg/manifest.json" ] && { loose="$d/plugins/$pkg"; break; }
        done
        if [ -n "$loose" ]; then cp -R "$loose" "$WORK/$pkg"; continue; fi
        archive=""
        for d in "$HERE/dist" "$HERE" "$PWD"; do
            [ -f "$d/$zipname" ] && { archive="$d/$zipname"; break; }
        done
        if [ -z "$archive" ]; then missing="$missing${missing:+\\}$zipname"; continue; fi
        # The zip's root is the plugin itself, so Claude Desktop takes it as a drag-and-drop.
        unzip -qo "$archive" -d "$WORK/$pkg" || { echo "install.sh: cannot unzip $archive" >&2; exit 1; }
    done
    if [ -n "$missing" ]; then nag "No $missing. Where?"; exit 1; fi
}

make_executable() { # $1 root
    local name
    for name in $EXEC_NAMES; do
        find "$1" -type f -name "$name" -exec chmod 755 {} + 2>/dev/null
    done
}

place() { # $1 src  $2 dest  $3 form -> prints the note
    local note="installed" backup version name pkgname
    if [ -e "$2" ]; then
        if [ -f "$2/$MARKER" ]; then
            note="updated"
            [ "$DRY" = 1 ] || rm -rf "$2"
        else
            # Outside the skills tree on purpose: a backup left inside it loads as a second plugin.
            backup="$BACKUPS/$(basename "$(dirname "$2")")-$(basename "$2")-$(stamp)"
            note="replaced (yours saved to $backup)"
            if [ "$DRY" != 1 ]; then mkdir -p "$BACKUPS"; mv "$2" "$backup"; fi
        fi
    fi
    if [ "$DRY" = 1 ]; then printf '%s' "$note"; return 0; fi

    mkdir -p "$(dirname "$2")"
    if [ "$3" = plugin ]; then
        cp -R "$1" "$2"
        for name in $INSTALLER_ONLY; do rm -rf "$2/$name"; done
        make_executable "$2"
        # A zip off GitHub carries com.apple.quarantine into every file it holds — 2026-09-05
        command -v xattr >/dev/null 2>&1 && xattr -dr com.apple.quarantine "$2" 2>/dev/null
    else
        mkdir -p "$2"
        cp "$1/flat/SKILL.md" "$2/SKILL.md"
        cp "$1/README.md" "$2/README.md"
    fi
    name="$(json get "$1/manifest.json" name)"
    version="$(json get "$1/manifest.json" version)"
    json marker "$2/$MARKER" "$name" "$version" "$3"
    printf '%s' "$note"
}


# ----------------------------------------------------------------- always-on text

graft() { # $1 path  $2 name  $3 version  $4 body file -> prints the note
    local begin="<!-- shut:$2:begin -->" end="<!-- shut:$2:end -->" note
    local old="$WORK/graft.old" new="$WORK/graft.new" tail="$WORK/graft.tail"
    if [ -f "$1" ]; then cp "$1" "$old"; else : > "$old"; fi

    { printf '%s\n' "$begin"
      printf '<!-- managed by Shut, v%s. Edits here are overwritten. -->\n\n' "$3"
      sed -e :a -e '/^[[:space:]]*$/{$d;N;ba' -e '}' "$4" | sed '/./,$!d'
      printf '\n%s\n' "$end"
    } > "$WORK/graft.block"

    if grep -qF "$begin" "$old" && grep -qF "$end" "$old"; then
        awk -v b="$begin" 'index($0,b){exit} {print}' "$old" > "$new"
        awk -v e="$end" 'p{print} index($0,e){p=1}' "$old" | sed '/./,$!d' > "$tail"
        cat "$WORK/graft.block" >> "$new"
        if [ -s "$tail" ]; then printf '\n' >> "$new"; cat "$tail" >> "$new"; fi
        note="refreshed"
    else
        if [ -s "$old" ] && grep -q '[^[:space:]]' "$old"; then
            awk 'BEGIN{n=0} {lines[NR]=$0} END{for(i=NR;i>=1;i--) if(lines[i]!=""){last=i;break}
                 for(i=1;i<=last;i++) print lines[i]; print ""}' "$old" > "$new"
        else
            : > "$new"
        fi
        cat "$WORK/graft.block" >> "$new"
        note="added"
    fi

    if cmp -s "$old" "$new"; then printf 'unchanged'; return 0; fi
    if [ "$DRY" != 1 ]; then back_up "$1"; mkdir -p "$(dirname "$1")"; cp "$new" "$1"; fi
    printf '%s' "$note"
}

strip_graft() { # $1 path  $2 name -> prints the note
    local begin="<!-- shut:$2:begin -->" end="<!-- shut:$2:end -->"
    local new="$WORK/strip.new" tail="$WORK/strip.tail"
    [ -f "$1" ] || return 0
    grep -qF "$begin" "$1" && grep -qF "$end" "$1" || return 0
    awk -v b="$begin" 'index($0,b){exit} {print}' "$1" > "$WORK/strip.head"
    awk -v e="$end" 'p{print} index($0,e){p=1}' "$1" | sed '/./,$!d' > "$tail"
    if grep -q '[^[:space:]]' "$WORK/strip.head"; then
        awk '{lines[NR]=$0} END{for(i=NR;i>=1;i--) if(lines[i]!=""){last=i;break}
             for(i=1;i<=last;i++) print lines[i]}' "$WORK/strip.head" > "$new"
    else
        : > "$new"
    fi
    cat "$tail" >> "$new"
    if [ "$DRY" != 1 ]; then back_up "$1"; cp "$new" "$1"; fi
    printf 'removed (the hook carries it)'
}


# ----------------------------------------------------------------- Codex hooks

codex_hook() { # $1 pkg  $2 body file -> prints the note
    local payload="$CODEX_HOOK_DIR/${HOOK_PREFIX}$1-session-start.json"
    local launcher="$CODEX_HOOK_DIR/${HOOK_PREFIX}$1-session-start.sh"
    if [ "$DRY" != 1 ]; then
        mkdir -p "$CODEX_HOOK_DIR"
        json payload "$payload" SessionStart "$2"
        printf '#!/usr/bin/env bash\ncat "$(dirname "$0")/%s"\n' "$(basename "$payload")" > "$launcher"
        chmod 755 "$launcher"
    fi
    snap "$CODEX_HOOKS"
    local note; note="$(json hook-add "$CODEX_HOOKS" "$1" "$launcher" "$HOOK_PREFIX" "$DRY")"
    [ "$note" = unchanged ] || promote "$CODEX_HOOKS" ".bak-$(stamp)"
    printf '%s' "$note"
}

codex_hooks_feature() {
    # `hooks` defaults on since 2026; the key only exists to turn them off.
    [ -f "$CODEX_CONFIG" ] || return 0
    if grep -Eq '^[[:space:]]*hooks[[:space:]]*=[[:space:]]*false' "$CODEX_CONFIG"; then
        printf 'OFF -- set [features] hooks = true in config.toml or the hook will not run'
    else
        printf 'on'
    fi
}


# ----------------------------------------------------------------- Claude settings

scan_roots() {
    printf '%s\n' "$HOME"
    [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 0
    # `mount` tags a non-network volume "local"; the boot disk is a symlink under /Volumes — 2026-09-05
    /sbin/mount 2>/dev/null | awk -F' on ' '/ local[,)]/ {
        split($2, a, " ("); print a[1] }' | while IFS= read -r point; do
        case "$point" in /Volumes/*) [ -d "$point" ] && [ ! -L "$point" ] && printf '%s\n' "$point" ;; esac
    done
}

macos_blocked() {
    [ "$(uname -s 2>/dev/null)" = "Darwin" ] || return 0
    local name
    for name in Desktop Documents Downloads; do
        [ -d "$HOME/$name" ] || continue
        ls "$HOME/$name" >/dev/null 2>&1 || printf '%s\n' "$HOME/$name"
    done
}

claude_dirs() {
    local prune=() name root
    for name in $SCAN_SKIP; do prune+=( -iname "$name" -o ); done
    {
        printf '%s\n' "$CLAUDE_HOME"
        scan_roots | while IFS= read -r root; do
            [ -d "$root" ] || continue
            find "$root" -maxdepth $((SCAN_DEPTH + 1)) -type d \
                \( -name '.claude' \) -print -prune -o \
                \( \( -name '.*' "${prune[@]}" -false \) -prune \) 2>/dev/null
        done
    } | awk '!seen[$0]++' | sort
}

claude_settings() { # prints "<label>\t<detail>" lines
    local dir label state mode note style dest file pair
    state="$UNINSTALL_STATE"
    [ "$DRY" = 1 ] || mkdir -p "$BACKUPS"

    claude_dirs | while IFS= read -r dir; do
        if [ "$dir" = "$CLAUDE_HOME" ]; then
            label="claude"
            for pair in "settings.json|env" "settings.local.json|style"; do
                file="$dir/${pair%%|*}"; mode="${pair##*|}"
                snap "$file"
                note="$(json settings-apply "$file" "$state" "$mode" "$DRY")" \
                    && { promote "$file" ".bak-$(stamp)"
                         printf '%s\t%s  %s\n' "$label" "$note" "$file"; }
            done
        else
            label="$(basename "$(dirname "$dir")")"
            file="$dir/settings.local.json"
            snap "$file"
            note="$(json settings-apply "$file" "$state" both "$DRY")" \
                && { promote "$file" ".bak-$(stamp)"
                     printf '%s\t%s  %s\n' "$label" "$note" "$file"; }
        fi
    done

    style="$HERE/shut.md"
    dest="$CLAUDE_OUTPUT_STYLES/shut.md"
    if [ -f "$style" ] && ! cmp -s "$style" "$dest"; then
        printf 'claude\toutput-styles/shut.md  installed\n'
        if [ "$DRY" != 1 ]; then mkdir -p "$CLAUDE_OUTPUT_STYLES"; cp "$style" "$dest"; fi
    fi
}


# ----------------------------------------------------------------- caveman

caveman_targets() {
    local line dest pattern d
    printf '%s\n' "$TARGETS" | while IFS='|' read -r _ _ dest _; do
        [ -d "$dest" ] || continue
        for pattern in $CAVEMAN_PATTERNS; do
            for d in "$dest"/$pattern; do [ -d "$d" ] && printf '%s\n' "$d"; done
        done
    done | awk '!seen[$0]++'
}

devins_block() { # $1 config.toml, $2 want=block|rest
    awk -v want="$2" '
        BEGIN { state = 0 }
        state == 0 && /^developer_instructions[ \t]*=[ \t]*"""/ {
            state = 1; if (want == "block") print
            rest = substr($0, index($0, "\"\"\"") + 3)
            if (index(rest, "\"\"\"") > 0) state = 2
            next
        }
        state == 1 { if (want == "block") print; if (index($0, "\"\"\"") > 0) state = 2; next }
        { if (want == "rest") print }
    ' "$1"
}

caveman_state_init() {
    [ -f "$CAVEMAN_STATE" ] && return 0
    mkdir -p "$BACKUPS"
    json state-set "$CAVEMAN_STATE" disabled_at "\"$(date +%Y-%m-%dT%H:%M:%S)\""
}

disable_caveman() { # prints note lines
    # Caveman rewrites every reply too; two compressors fighting is not a defined state.
    local d off lifted block
    [ "$DRY" = 1 ] || mkdir -p "$BACKUPS"

    caveman_targets | while IFS= read -r d; do
        off="$d.off-by-shut"
        printf 'skill  %s\n' "$d"
        # Written after every step: a crash later must still leave uninstall able to undo this.
        if [ "$DRY" != 1 ]; then
            caveman_state_init
            json state-push "$CAVEMAN_STATE" renamed "[\"$d\",\"$off\"]"
            mv "$d" "$off"
        fi
    done

    if [ -f "$CODEX_HOOKS" ] && [ "$DRY" != 1 ] && grep -qi caveman "$CODEX_HOOKS"; then
        caveman_state_init
        snap "$CODEX_HOOKS"
        lifted="$(json caveman-lift "$CODEX_HOOKS" "$CAVEMAN_STATE" "$DRY")" \
            && { promote "$CODEX_HOOKS" ".bak-$(stamp)"
                 printf 'hooks  %s caveman entries in %s\n' "$lifted" "$CODEX_HOOKS"; }
    fi

    if [ -f "$CODEX_CONFIG" ]; then
        block="$(devins_block "$CODEX_CONFIG" block)"
        if [ -n "$block" ] && printf '%s' "$block" | grep -qi caveman; then
            printf 'config developer_instructions in %s\n' "$CODEX_CONFIG"
            if [ "$DRY" != 1 ]; then
                caveman_state_init
                printf '%s\n' "$block" > "$WORK/devins"
                json state-set-file "$CAVEMAN_STATE" developer_instructions "$WORK/devins"
                back_up "$CODEX_CONFIG"
                devins_block "$CODEX_CONFIG" rest > "$WORK/config.toml"
                cp "$WORK/config.toml" "$CODEX_CONFIG"
            fi
        fi
    fi

    if [ -d "$HOME/.gemini/extensions/caveman" ] && command -v gemini >/dev/null 2>&1; then
        if [ "$DRY" = 1 ] || gemini extensions disable caveman >/dev/null 2>&1; then
            [ "$DRY" = 1 ] || { caveman_state_init; json state-set "$CAVEMAN_STATE" gemini true; }
            printf 'gemini extension caveman\n'
        else
            printf 'gemini extension caveman -- FAILED, disable it by hand\n'
        fi
    fi
}

caveman_prose() {
    # Hand-written mentions. Left alone: they are the user's own text, not a mechanism.
    local f
    for f in "$CLAUDE_HOME/CLAUDE.md" "$HOME/.codex/AGENTS.md" \
             "$HOME/.config/opencode/AGENTS.md" "$HOME/.gemini/GEMINI.md"; do
        [ -f "$f" ] && grep -qi caveman "$f" && printf '%s\n' "$f"
    done
    return 0
}


# ----------------------------------------------------------------- main

if [ -f "$LEGACY_STATE" ] && [ ! -f "$UNINSTALL_STATE" ]; then
    mkdir -p "$BACKUPS" && mv "$LEGACY_STATE" "$UNINSTALL_STATE"
fi

AGENTS=""
while IFS='|' read -r name probes dest form; do
    [ -n "$name" ] || continue
    [ -n "$ONLY" ] && ! in_list "$name" "$ONLY" && continue
    [ -n "$SKIP" ] && in_list "$name" "$SKIP" && continue
    hit=0
    old_ifs="$IFS"; IFS=';'
    for probe in $probes; do [ -e "$probe" ] && hit=1; done
    IFS="$old_ifs"
    [ "$hit" = 1 ] && AGENTS="$AGENTS$name|$dest|$form
"
done <<EOF
$TARGETS
EOF

if [ "$LIST" = 1 ]; then
    printf '%s' "$AGENTS" | while IFS='|' read -r name dest form; do
        [ -n "$name" ] && printf '%-10s %-7s %s\n' "$name" "$form" "$dest"
    done
    exit 0
fi
if [ -z "$AGENTS" ]; then echo "no agents found. Nothing to install." >&2; exit 1; fi

WANTED="$(printf '%s' "$AGENTS" | cut -d'|' -f1 | tr '\n' ' ')"
TAG=""; [ "$DRY" = 1 ] && TAG=" (dry run)"
TRAILER="$WORK/trailer"; : > "$TRAILER"

unpack

echo "Skills$TAG"
printf '%s' "$AGENTS" | while IFS='|' read -r name dest form; do
    [ -n "$name" ] || continue
    for pkg in $PACKAGES; do
        printf '  %-10s %-8s %s\n' "$name" "$pkg" "$(place "$WORK/$pkg" "$dest/$pkg" "$form")"
    done
done

HOOKED=""
if [ "$NO_HOOKS" != 1 ] && in_list codex "$WANTED"; then
    echo "Hooks$TAG"
    FEATURE="$(codex_hooks_feature)"
    for pkg in $PACKAGES; do
        printf '  %-10s %-8s %s\n' codex "$pkg" "$(codex_hook "$pkg" "$WORK/$pkg/always-on.md")"
    done
    [ -n "$FEATURE" ] && [ "$FEATURE" != "on" ] && printf '  %-10s %-8s %s\n' codex features "$FEATURE"
    if json hook-trusted "$CODEX_HOOKS" "$CODEX_CONFIG" "$HOOK_PREFIX"; then
        HOOKED="codex"
        printf '  %-10s %-8s %s\n' codex trust "trusted, the hook runs"
    else
        printf '  %-10s %-8s %s\n' codex trust "NOT trusted yet -- AGENTS.md block stays"
        echo "Codex skips a hook until you trust it: run /hooks inside Codex, trust the two \`shut-\` entries, then run install.sh again to drop the duplicate AGENTS.md block." >> "$TRAILER"
    fi
fi

if [ "$NO_ALWAYS_ON" != 1 ]; then
    echo "Always-on rule$TAG"
    while IFS='|' read -r name path; do
        [ -n "$name" ] || continue
        in_list "$name" "$WANTED" || continue
        [ -d "$(dirname "$path")" ] || continue
        for pkg in $PACKAGES; do
            # A trusted hook and a block would inject the same text twice, every session.
            if in_list "$name" "$HOOKED"; then
                note="$(strip_graft "$path" "$pkg")"
            else
                note="$(graft "$path" "$pkg" "$(json get "$WORK/$pkg/manifest.json" version)" "$WORK/$pkg/always-on.md")"
            fi
            [ -n "$note" ] && printf '  %-10s %-8s %s  %s\n' "$name" "$pkg" "$note" "$path"
        done
    done <<EOF
$ALWAYS_ON
EOF
fi

if in_list claude "$WANTED"; then
    echo "Claude settings$TAG"
    BLOCKED="$(macos_blocked | tr '\n' ' ')"
    if [ -n "${BLOCKED// /}" ]; then
        echo "macOS hides $BLOCKED from this terminal, so projects under them were skipped. Give your terminal Full Disk Access in System Settings > Privacy & Security, reopen it, and run install.sh again." >> "$TRAILER"
    fi
    NOTES="$(claude_settings)"
    if [ -n "$NOTES" ]; then
        printf '%s\n' "$NOTES" | while IFS="$(printf '\t')" read -r label detail; do
            printf '  %-10s %s\n' "$label" "$detail"
        done
    else
        printf '  %-10s unchanged\n' claude
    fi
fi

if [ "$KEEP_CAVEMAN" != 1 ]; then
    echo "Caveman$TAG"
    NOTES="$(disable_caveman)"
    if [ -n "$NOTES" ]; then
        printf '%s\n' "$NOTES" | while IFS= read -r note; do echo "  disabled  $note"; done
    else
        echo "  not installed"
    fi
    PROSE="$(caveman_prose)"
    if [ -n "$PROSE" ]; then
        echo "  left alone (your own text, not a mechanism):"
        printf '%s\n' "$PROSE" | while IFS= read -r f; do echo "      $f"; done
        echo "Those files still tell the agent to use /caveman for commits and docs. Remove those lines yourself if you want caveman fully gone." >> "$TRAILER"
    fi
fi

echo
echo "Claude Code and Codex pick it up at the next /clear or restart; the rest next session."
while IFS= read -r line; do [ -n "$line" ] && { echo; echo "! $line"; }; done < "$TRAILER"
echo
echo "Remove it all with: ./uninstall.sh"
