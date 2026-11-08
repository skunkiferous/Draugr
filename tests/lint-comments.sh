#!/usr/bin/env bash
# lint-comments.sh: enforce the comment-density rule of Draugr.
#
# The rule: each block of more than MAX lines of code must have one comment line
# or more.
#
# A "block" is a run of non-blank lines. Thus a doc comment directly above a
# function counts as the comment of that function. That is usually its correct
# place. Put a blank line between them, and they become two blocks. Then the
# code half needs its own comment. In practice: every few lines, say what the
# next few lines are for.
#
# The full premise of Draugr is that you can read a file before you trust it.
# Thus "the code is self-documenting" is not enough here.
#
#   ./tests/lint-comments.sh                 all that CI tests. Use this one
#   ./tests/lint-comments.sh lib/common.sh   only these files
#   MAX=8 ./tests/lint-comments.sh ...       a higher limit
#
# Heredoc bodies do not count as code. They are data, you cannot put a comment
# in them, and a demand for one makes no sense.
set -euo pipefail

max=${MAX:-5}
status=0

# With no arguments, test all. Before, this did `exit 0`, because an empty glob
# must not fail a build. The result: the obvious local run,
# `./tests/lint-comments.sh`, passed, and tested not one file. Thus a green
# local run meant nothing, and CI caught what the developer believed was tested.
#
# Thus the list is HERE, not in .github/workflows/ci.yml, which calls this with
# no arguments. One list, so that the two cannot drift apart. You lint each file
# that CI lints, and you do not need to remember a long command.
if [ $# -eq 0 ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    set -- "$root"/lib/common.sh "$root"/lib/agents/*.sh "$root"/lib/forge/*.sh "$root"/install.sh \
           "$root"/bin/* "$root"/tests/mocks/sbx "$root"/tests/helper.bash \
           "$root"/tests/lint-comments.sh "$root"/tests/executable-paths.sh \
           "$root"/tests/lint-inverted.sh "$root"/tests/lint-native-stderr.sh \
           "$root"/.githooks/* "$root"/share/ollama-proxy/ollama-proxy
fi

for file in "$@"; do
    [ -f "$file" ] || continue

    # awk walks the file, and collects one block at a time. A blank line ends
    # the current block, and starts the test. The end of the file does the same.
    result=$(awk -v max="$max" -v file="$file" '
        function flush() {
            # Complain only when the block is BOTH long and has no words.
            if (code > max && comments == 0)
                printf "%s:%d: %d lines of code with no comment\n", file, start, code
            code = 0; comments = 0; start = 0
        }

        # --- in a heredoc: skip to the terminator, and count nothing ---------
        heredoc != "" {
            line = $0
            sub(/^[[:space:]]+/, "", line)      # <<- allows an indented tag
            if (line == heredoc) heredoc = ""
            next
        }

        # --- a blank line closes the current block ---------------------------
        /^[[:space:]]*$/ { flush(); next }

        # --- a comment line: now the block has its explanation ----------------
        /^[[:space:]]*#/ {
            if (start == 0) start = NR
            comments++
            next
        }

        # --- a real line of code ---------------------------------------------
        {
            if (start == 0) start = NR
            code++

            # Record a heredoc start, so that its body is skipped. <<EOF,
            # <<-EOF, <<"EOF", and <<'"'"'EOF'"'"' all resolve to the bare tag.
            if (match($0, /<<-?[[:space:]]*["'"'"']?[A-Za-z_][A-Za-z0-9_]*["'"'"']?/)) {
                tag = substr($0, RSTART, RLENGTH)
                gsub(/^<<-?[[:space:]]*|["'"'"']/, "", tag)
                heredoc = tag
            }
        }

        END { flush() }
    ' "$file")

    # A non-empty report means that this file failed. Continue, so that one run
    # lists all.
    if [ -n "$result" ]; then
        printf '%s\n' "$result"
        status=1
    fi
done

# On stdout, with its findings. On stderr, it had a separate buffer, and came
# out ABOVE them when the output was piped. That is the same trap that dr-status
# documents: one report, one stream.
if [ "$status" -ne 0 ]; then
    printf '\nEach block above needs a one-line comment. See docs/HACKING.md.\n'
fi
exit "$status"
