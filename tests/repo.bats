#!/usr/bin/env bats
# Facts about the repository itself, rather than about the code in it.
#
# These exist because of a failure mode that is invisible locally: this project
# is developed on /mnt/c, where git sets core.filemode=false and therefore
# ignores the filesystem's executable bit entirely. A new script runs perfectly
# on the developer's machine and arrives on Linux as mode 100644 - not
# executable - so CI fails with status 126 and nothing before CI says a word.
#
# It happened twice before this test was written.

load helper

# Everything something else executes by path: the commands, the installer, and
# the two test-support scripts CI invokes directly.
executables() {
    git -C "$DR_ROOT" ls-files -s bin/ install.sh tests/mocks/sbx tests/lint-comments.sh \
        2>/dev/null
}

@test "every script that must be executable is mode 100755 in git" {
    git -C "$DR_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || skip "not a git work tree"

    # Field 1 of ls-files -s is the mode, field 4 the path.
    local bad
    bad=$(executables | awk '$1 != "100755" { print $4 }')

    if [ -n "$bad" ]; then
        printf 'These are not executable in git:\n' >&2
        printf '  %s\n' $bad >&2
        printf '\nFix with:\n  git update-index --chmod=+x %s\n' "$(printf '%s ' $bad)" >&2
        printf '\ncore.filemode is false here, so chmod alone will NOT fix it and\n' >&2
        printf 'git add will NOT pick it up - the mode lives only in the index.\n' >&2
        return 1
    fi
}

@test "the mode check is actually looking at something" {
    # A guard on the guard: if the paths above stopped matching any file, the
    # test above would pass by finding nothing and we would be back where we
    # started, only with a green tick to reassure us.
    git -C "$DR_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || skip "not a git work tree"
    [ "$(executables | wc -l)" -ge 10 ]
}

@test "every dr-* command has a matching entry in the README" {
    # The README is the specification, so a command that exists without being
    # documented is a gap in the spec rather than a bonus.
    local cmd missing=
    for cmd in "$DR_ROOT"/bin/dr-*; do
        cmd=${cmd##*/}
        grep -q "\`$cmd\`" "$DR_ROOT/README.md" || missing="$missing $cmd"
    done
    [ -z "$missing" ] || {
        printf 'not documented in README.md:%s\n' "$missing" >&2
        return 1
    }
}
