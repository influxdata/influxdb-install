#!/bin/sh
# Load one installer function without running the interactive installer.
load_function() {
    # A name defined twice would load only the first body while the shell
    # runs the last one, so the tests would check code the script never runs
    # grep -c exits 1 for a count of 0; keep the status 0 so a caller under
    # set -e reaches the "cannot find function" message below
    DEFINITIONS=$(grep -c "^$1() {\$" "$SCRIPT") || :
    if [ "$DEFINITIONS" -gt 1 ]; then
        printf 'function %s is defined %s times in %s\n' "$1" "$DEFINITIONS" "$SCRIPT" >&2
        exit 2
    fi
    BODY=$(awk -v name="$1" '
        $0 == name "() {" { in_fn = 1 }
        in_fn {
            print
            if (heredoc != "") {
                if ($0 == heredoc) heredoc = ""
                next
            }
            if (match($0, /<< *["'"'"']?[A-Za-z_]+/)) {
                heredoc = substr($0, RSTART, RLENGTH)
                sub(/<< *["'"'"']?/, "", heredoc)
                next
            }
            if ($0 == "}") exit
        }' "$SCRIPT")
    if [ -z "$BODY" ]; then
        printf 'cannot find function %s in %s\n' "$1" "$SCRIPT" >&2
        exit 2
    fi
    eval "$BODY"
}
