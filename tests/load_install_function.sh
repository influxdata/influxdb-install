#!/bin/sh
# Load one installer function without running the interactive installer.
load_function() {
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
