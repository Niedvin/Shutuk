
# macOS /usr/bin/python3 is an Xcode-CLT stub that pops an installer dialog when CLT is absent — 2026-09-05
shut_py() {
    _shut_c=""
    _shut_p=""
    for _shut_c in python3 python; do
        _shut_p="$(command -v "$_shut_c" 2>/dev/null)" || continue
        [ -n "$_shut_p" ] || continue
        case "$_shut_p" in
            /usr/bin/python*)
                if [ "$(uname -s 2>/dev/null)" = "Darwin" ]; then
                    xcode-select -p >/dev/null 2>&1 || continue
                fi
                ;;
        esac
        "$_shut_p" -c "" >/dev/null 2>&1 || continue
        printf '%s' "$_shut_p"
        return 0
    done
    return 1
}
