#!/usr/bin/env bats
# Facts about the repository itself, rather than about the code in it.
#
# These exist because of a failure mode that is invisible locally. The project is
# developed on /mnt/c, where git sets core.filemode=false and therefore ignores
# the filesystem's executable bit entirely. A new script runs perfectly on the
# developer's machine and arrives on Linux as mode 100644 - not executable - so
# CI dies with status 126 and nothing before CI says a word.
#
# It reached CI three times. The first version of this test missed the third,
# because it read `git ls-files`, which lists only files already in the index -
# and a brand-new command is untracked, which is the whole point. So this walks
# the FILESYSTEM and asks git about each file, which catches one that has not
# been staged yet as well as one staged with the wrong mode.

load helper

# Everything something else executes by path: the commands, the installer, and
# the two test-support scripts CI invokes directly.
want_executable() {
    printf '%s\n' "$DR_ROOT"/bin/dr* \
                  "$DR_ROOT/install.sh" \
                  "$DR_ROOT/tests/mocks/sbx" \
                  "$DR_ROOT/tests/lint-comments.sh"
}

@test "every script that must be executable will arrive executable" {
    git -C "$DR_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || skip "not a git work tree"

    local f rel mode untracked= wrongmode=
    while read -r f; do
        [ -f "$f" ] || continue
        rel=${f#"$DR_ROOT"/}

        # Field 1 of ls-files -s is the mode. Empty output means git has never
        # seen this path, so committing it now would store 100644.
        mode=$(git -C "$DR_ROOT" ls-files -s -- "$rel" | awk '{print $1}')
        if [ -z "$mode" ]; then
            untracked="$untracked $rel"
        elif [ "$mode" != 100755 ]; then
            wrongmode="$wrongmode $rel"
        fi
    done < <(want_executable)

    [ -z "$untracked$wrongmode" ] && return 0

    # One message, with the exact commands, because the fix is unmemorable and
    # the reason it is needed is genuinely surprising.
    printf 'These will not be executable when checked out on Linux:\n' >&2
    for rel in $untracked;  do printf '  %-28s (not staged yet)\n' "$rel" >&2; done
    for rel in $wrongmode;  do printf '  %-28s (staged as 100644)\n' "$rel" >&2; done
    printf '\nFix with:\n' >&2
    [ -n "$untracked" ] && printf '  git add%s\n' "$untracked" >&2
    printf '  git update-index --chmod=+x%s%s\n' "$untracked" "$wrongmode" >&2
    printf '\ncore.filemode is false here, so chmod alone will NOT do it and git add\n' >&2
    printf 'will NOT pick it up - the mode lives only in the index.\n' >&2
    return 1
}

@test "the mode check is actually looking at something" {
    # A guard on the guard: if the paths above stopped matching any file, the
    # test would pass by finding nothing and we would be back where we started,
    # only with a green tick to reassure us.
    [ "$(want_executable | wc -l)" -ge 10 ]
}

@test "every dr-* command has a matching entry in the README" {
    # The README is the specification, so a command that exists without being
    # documented is a gap in the spec rather than a bonus.
    # Accept `dr-data` and `dr-data status` alike: a command documented through
    # its subcommands is documented. The trailing character class is what makes
    # the difference - a bare `grep "\`$cmd\`"` demands the closing backtick
    # immediately and reports a false gap for every command that takes a verb.
    local cmd missing=
    for cmd in "$DR_ROOT"/bin/dr-*; do
        cmd=${cmd##*/}
        grep -qE "\`$cmd[\` ]" "$DR_ROOT/README.md" || missing="$missing $cmd"
    done
    [ -z "$missing" ] || {
        printf 'not documented in README.md:%s\n' "$missing" >&2
        return 1
    }
}
