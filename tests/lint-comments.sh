#!/usr/bin/env bash
# lint-comments.sh - enforce Draugr's comment-density rule.
#
# The rule: any block of more than MAX lines of code must contain at least one
# comment line.
#
# A "block" is a run of consecutive non-blank lines, so a doc comment sitting
# directly above a function counts as that function's comment - which is usually
# where it belongs. Put a blank line between them and they become two blocks, and
# the code half then needs its own comment. In practice that means: every few
# lines, say what the next few lines are for.
#
# Draugr's entire premise is that you can read a file before you trust it, so
# "the code is self-documenting" is not good enough here.
#
#   ./tests/lint-comments.sh lib/common.sh bin/*
#   MAX=8 ./tests/lint-comments.sh ...       relax the limit
#
# Heredoc bodies are not counted as code: they are data, you cannot put a comment
# inside them, and demanding one would be nonsense.
set -euo pipefail

max=${MAX:-5}
status=0

# Callers glob, and an empty glob is not an error worth failing a build over.
[ $# -gt 0 ] || exit 0

for file in "$@"; do
    [ -f "$file" ] || continue

    # awk walks the file accumulating one block at a time. A blank line ends the
    # current block and triggers the check; end-of-file does the same.
    result=$(awk -v max="$max" -v file="$file" '
        function flush() {
            # Only complain when the block is BOTH long and entirely wordless.
            if (code > max && comments == 0)
                printf "%s:%d: %d lines of code with no comment\n", file, start, code
            code = 0; comments = 0; start = 0
        }

        # --- inside a heredoc: skip to the terminator, counting nothing -------
        heredoc != "" {
            line = $0
            sub(/^[[:space:]]+/, "", line)      # <<- allows an indented tag
            if (line == heredoc) heredoc = ""
            next
        }

        # --- a blank line closes the current block ---------------------------
        /^[[:space:]]*$/ { flush(); next }

        # --- a comment line: the block now has its explanation ----------------
        /^[[:space:]]*#/ {
            if (start == 0) start = NR
            comments++
            next
        }

        # --- a real line of code ---------------------------------------------
        {
            if (start == 0) start = NR
            code++

            # Note a heredoc opening so its body is skipped: <<EOF, <<-EOF,
            # <<"EOF" and <<'"'"'EOF'"'"' all resolve to the bare tag.
            if (match($0, /<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
                tag = substr($0, RSTART, RLENGTH)
                gsub(/^<<-?[[:space:]]*|["'"'"']/, "", tag)
                heredoc = tag
            }
        }

        END { flush() }
    ' "$file")

    # A non-empty report means this file failed; keep going so one run lists all.
    if [ -n "$result" ]; then
        printf '%s\n' "$result"
        status=1
    fi
done

if [ "$status" -ne 0 ]; then
    printf '\nEach block above needs a one-line comment. See docs/HACKING.md.\n' >&2
fi
exit "$status"
