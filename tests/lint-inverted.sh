#!/usr/bin/env bash
# lint-inverted.sh - find bats assertions that cannot fail.
#
# THE RULE: in a .bats test, an inverted command - `! cmd` - must be the LAST
# command of its test. Anywhere else it is discarded and the assertion is dead.
#
# WHY, measured against bats on this machine:
#
#   @test "inverted, LAST command" { ! true; }            -> not ok   (fails)
#   @test "inverted, MID test"     { ! true; true; }      -> ok       (PASSES)
#   @test "plain failure, MID test" { false; true; }      -> not ok   (fails)
#
# bats stops a test at the first failing command the way `set -e` does, and POSIX
# says `set -e` is ignored for a command preceded by `!`. So a mid-test `! grep`
# finds whatever it finds and the test carries on regardless; it only appears to
# work in the last position, where the test's own exit status carries it.
#
# This is not hypothetical and it is not rare. When this script was written the
# suite held 59 inverted assertions and SIXTEEN of them were dead - including two
# written that same day, which passed a mutation test that had reintroduced the
# exact bug they were added to catch. An assertion that cannot fail is worse than
# an absent one: the suite reports it as checked.
#
# THE FIX IS ONE TOKEN. `|| return 1` makes the failure explicit, and explicit is
# what `set -e` cannot be talked out of:
#
#   ! grep -q nope file || return 1
#
# `run cmd` followed by `[ "$status" -ne 0 ]` is equally correct, and is the right
# choice when the test wants to read $output afterwards - but it overwrites $status
# and $output, which the surrounding assertions may still need.
#
# KNOWN FALSE POSITIVE: `if ! cmd; then` and `while ! cmd; do`. An inverted command
# inside a CONDITION is not an assertion and was never subject to set -e, so there is
# nothing dead about it - but this script judges by position alone and flags it. Met
#, writing a test in tests/forge.bats; the test was restructured to compare
# two counts instead, which reads better anyway, so nothing is blocked. Narrowing the
# rule means recognising a condition (a line opening with if/elif/while/until, or one
# ending in `; then` or `; do`), which is worth doing the next time it costs anybody
# anything rather than at the end of an unrelated session.
#
#   ./tests/lint-inverted.sh                 everything CI checks - use this one
#   ./tests/lint-inverted.sh tests/x.bats    just these files
set -euo pipefail

status=0

# With no arguments, every .bats file - and the list lives here rather than in
# .github/workflows/ci.yml for the reason lint-comments.sh gives: one list, so
# that running this locally checks exactly what CI checks.
if [ $# -eq 0 ]; then
    root=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)
    set -- "$root"/tests/*.bats
fi

for f in "$@"; do
    [ -f "$f" ] || continue
    # One pass per file. The state is which test we are in and where its last
    # real command was; an inverted line is remembered and only judged at the
    # closing brace, because "is it last" is not answerable until then.
    #
    # A real command is a line that is neither blank nor a comment. Continuation
    # lines ending in a backslash are not special here: an inverted assertion
    # spanning lines still STARTS on the line this matches, and that start is
    # what the position test is about.
    awk -v file="$f" '
        # The name, without @test, the quotes or the opening brace - it is printed
        # to a human, who does not need the syntax read back to them.
        /^@test / { intest = 1
                    name = $0
                    sub(/^@test[[:space:]]+"?/, "", name)
                    sub(/"?[[:space:]]*\{[[:space:]]*$/, "", name)
                    delete inv; ninv = 0; last = 0; next }
        !intest { next }
        /^}[[:space:]]*$/ {
            # Judged here: every inverted line but the one at `last` is dead.
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
            # An inverted line that already carries its own `|| return` (or `|| fail`)
            # is fine wherever it sits: that is the fix, and the whole point of it is
            # that the failure no longer depends on set -e noticing.
            if (line ~ /^![[:space:]]/ && line !~ /\|\|[[:space:]]*(return|fail)([[:space:]]|$)/) {
                inv[++ninv] = NR; invtext[NR] = line
            }
        }
        END { exit (bad > 0) }
    ' "$f" || status=1
done

# Said after the list rather than per line: the explanation is the same for all of
# them, and what a reader needs once is the fix, not sixteen copies of the reason.
if [ "$status" -ne 0 ]; then
    printf '\n'
    printf 'Each one above found whatever it found and the test passed anyway.\n' >&2
    printf 'Add  || return 1  to each, or use run cmd with a status check. The\n' >&2
    printf 'header of this script has the measurement, docs/HACKING.md the rule.\n' >&2
fi
exit "$status"
