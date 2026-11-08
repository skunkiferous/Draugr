#!/usr/bin/env bash
# lint-inverted.sh: find bats assertions that cannot fail.
#
# THE RULE: in a .bats test, an inverted command (`! cmd`) must be the LAST
# command of its test. In each other place, bats discards it, and the assertion
# is dead.
#
# WHY, from a test with bats on this machine:
#
#   @test "inverted, LAST command" { ! true; }            -> not ok   (fails)
#   @test "inverted, MID test"     { ! true; true; }      -> ok       (PASSES)
#   @test "plain failure, MID test" { false; true; }      -> not ok   (fails)
#
# bats stops a test at the first failed command, as `set -e` does. POSIX says
# that `set -e` ignores a command after `!`. Thus a `! grep` in the middle of a
# test finds what it finds, and the test continues anyway. It only looks like it
# works in the last place, where the own exit status of the test carries it.
#
# This is real, and not rare. When this script was written, the suite had 59
# inverted assertions, and SIXTEEN of them were dead. Two of them were written
# on that same day. They passed a mutation test that put back the exact bug that
# they had to catch. An assertion that cannot fail is worse than an absent one.
# The suite reports it as tested.
#
# THE FIX IS ONE TOKEN. `|| return 1` makes the failure explicit, and `set -e`
# cannot ignore an explicit failure:
#
#   ! grep -q nope file || return 1
#
# `run cmd`, then `[ "$status" -ne 0 ]`, is also correct. It is the right choice
# when the test wants to read $output later. But it overwrites $status and
# $output, and the assertions around it can still need them.
#
# KNOWN FALSE POSITIVE: `if ! cmd; then` and `while ! cmd; do`. An inverted
# command in a CONDITION is not an assertion, and set -e never applied to it.
# Thus it is not dead. But this script judges only by position, and flags it.
# This happened once, during a test in tests/forge.bats. That test now compares
# two counts, which reads better anyway, so nothing is blocked. A narrower rule
# must find a condition (a line that starts with if/elif/while/until, or one
# that ends in `; then` or `; do`). Do that the next time that it costs somebody
# something, not at the end of an unrelated session.
#
#   ./tests/lint-inverted.sh                 all that CI tests. Use this one
#   ./tests/lint-inverted.sh tests/x.bats    only these files
set -euo pipefail

status=0

# With no arguments, each .bats file. The list is here, not in
# .github/workflows/ci.yml, for the reason in lint-comments.sh: one list, so
# that a local run tests exactly what CI tests.
if [ $# -eq 0 ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    set -- "$root"/tests/*.bats
fi

for f in "$@"; do
    [ -f "$f" ] || continue
    # One pass for each file. The state is the current test, and the place of
    # its last real command. An inverted line is recorded, and judged only at
    # the closing brace, because "is it last" has no answer before that.
    #
    # A real command is a line that is not blank and not a comment. Continuation
    # lines that end in a backslash are not special here. An inverted assertion
    # across lines still STARTS on the line that this matches. The position test
    # is about that start.
    awk -v file="$f" '
        # The name, without @test, the quotes, or the opening brace. A person
        # reads it, and does not need the syntax.
        /^@test / { intest = 1
                    name = $0
                    sub(/^@test[[:space:]]+"?/, "", name)
                    sub(/"?[[:space:]]*\{[[:space:]]*$/, "", name)
                    delete inv; ninv = 0; last = 0; next }
        !intest { next }
        /^}[[:space:]]*$/ {
            # Judged here: each inverted line except the one at `last` is dead.
            for (i = 1; i <= ninv; i++)
                if (inv[i] != last)
                    printf "%s:%d: inverted assertion is not the last command, so it cannot fail\n          %s\n          in %s\n",
                           file, inv[i], invtext[inv[i]], name > "/dev/stderr"
            for (i = 1; i <= ninv; i++) if (inv[i] != last) bad++
            intest = 0; next
        }
        {
            line = $0
            sub(/^[[:space:]]+/, "", line)
            if (line == "" || substr(line, 1, 1) == "#") next
            last = NR
            # An inverted line that already has its own `|| return` (or `||
            # fail`) is fine in each place. That is the fix. Its full purpose is
            # that the failure does not depend on set -e now.
            if (line ~ /^![[:space:]]/ && line !~ /\|\|[[:space:]]*(return|fail)([[:space:]]|$)/) {
                inv[++ninv] = NR; invtext[NR] = line
            }
        }
        END { exit (bad > 0) }
    ' "$f" || status=1
done

# Said after the list, not on each line. The explanation is the same for all of
# them. A reader needs the fix once, not sixteen copies of the reason.
if [ "$status" -ne 0 ]; then
    printf '\n'
    printf 'Each one above found what it found, and the test passed anyway.\n' >&2
    printf 'Add  || return 1  to each, or use run cmd with a status test. The\n' >&2
    printf 'header of this script has the test result. docs/HACKING.md has the rule.\n' >&2
fi
exit "$status"
