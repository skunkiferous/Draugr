#!/usr/bin/env bats
# Facts about the repository itself, not about its code.
#
# These tests exist because of a failure that is not visible locally. The
# project is developed on /mnt/c. There, git sets core.filemode=false, and thus
# ignores the executable bit of the filesystem. A new script runs well on the
# machine of the developer. It arrives on Linux as mode 100644, which is not
# executable. CI then dies with status 126, and nothing before CI says anything.
#
# It reached CI three times. The first version of this test missed the third. It
# read `git ls-files`, which lists only files in the index, and a new command is
# untracked. Thus this test walks the FILESYSTEM and asks git about each file.
# It finds a file that is not staged, and also a file staged with the wrong
# mode.

load helper

# The list is in tests/executable-paths.sh, not here. It has two consumers, and
# they must always agree. If one of these files is not executable, this test
# fails the build, and .githooks/pre-commit fixes it before the commit. That
# script explains WHICH files are on the list.
want_executable() {
    "$DR_ROOT/tests/executable-paths.sh"
}

@test "every script that must be executable will arrive executable" {
    git -C "$DR_ROOT" rev-parse --is-inside-work-tree >/dev/null 2>&1 \
        || skip "not a git work tree"

    local f rel mode untracked= wrongmode=
    while read -r f; do
        [ -f "$f" ] || continue
        rel=${f#"$DR_ROOT"/}

        # Field 1 of ls-files -s is the mode. Empty output means that git does
        # not know this path. A commit of it now stores 100644.
        mode=$(git -C "$DR_ROOT" ls-files -s -- "$rel" | awk '{print $1}')
        if [ -z "$mode" ]; then
            untracked="$untracked $rel"
        elif [ "$mode" != 100755 ]; then
            wrongmode="$wrongmode $rel"
        fi
    done < <(want_executable)

    [ -z "$untracked$wrongmode" ] && return 0

    # One message, with the exact commands, because the fix is hard to remember,
    # and the reason for it is a surprise.
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
    # A guard on the guard. If the paths above match no file, the test passes
    # because it finds nothing. We are then back at the start, but with a green
    # tick.
    [ "$(want_executable | wc -l)" -ge 10 ]
}

@test "every dr-* command has a matching entry in the README" {
    # The README is the specification. Thus a command with no documentation is a
    # gap in the specification, not a bonus.
    # Accept both `dr-data` and `dr-data status`. A command documented through
    # its subcommands is documented. The trailing character class makes the
    # difference. A bare `grep "\`$cmd\`"` needs the closing backtick at once,
    # and reports a false gap for each command that takes a verb.
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

# The hook is the half of this that runs in time, so it is tested as all other
# code is. A fake repository, not this one, because the assertion is about what
# `git add` records. Here, that makes the index of the repo under test dirty.
@test "the pre-commit hook sets the bit that git add cannot" {
    local fake="$BATS_TEST_TMPDIR/fake"
    mkdir -p "$fake/bin" "$fake/tests" "$fake/.githooks"
    cp "$DR_ROOT/tests/executable-paths.sh" "$fake/tests/"
    cp "$DR_ROOT/.githooks/pre-commit" "$fake/.githooks/"
    chmod +x "$fake/tests/executable-paths.sh" "$fake/.githooks/pre-commit"
    printf '#!/usr/bin/env bash\ntrue\n' > "$fake/bin/dr-thing"

    git -C "$fake" init -q -b main
    git -C "$fake" config user.email t@example.com
    git -C "$fake" config user.name T
    # The condition that causes the bug: git ignores the executable bit of the
    # filesystem, exactly as it does on /mnt/c.
    git -C "$fake" config core.fileMode false
    git -C "$fake" add -A

    [ "$(git -C "$fake" ls-files -s -- bin/dr-thing | awk '{print $1}')" = 100644 ]
    ( cd "$fake" && ./.githooks/pre-commit >/dev/null 2>&1 )
    [ "$(git -C "$fake" ls-files -s -- bin/dr-thing | awk '{print $1}')" = 100755 ]
}

# A listed file that is not staged belongs to a different commit. If the hook
# adds it, the commit holds a file that the author did not ask for.
@test "the pre-commit hook leaves an unstaged script alone" {
    local fake="$BATS_TEST_TMPDIR/fake2"
    mkdir -p "$fake/bin" "$fake/tests" "$fake/.githooks"
    cp "$DR_ROOT/tests/executable-paths.sh" "$fake/tests/"
    cp "$DR_ROOT/.githooks/pre-commit" "$fake/.githooks/"
    chmod +x "$fake/tests/executable-paths.sh" "$fake/.githooks/pre-commit"
    printf '#!/usr/bin/env bash\ntrue\n' > "$fake/bin/dr-unstaged"

    git -C "$fake" init -q -b main
    git -C "$fake" config user.email t@example.com
    git -C "$fake" config user.name T
    ( cd "$fake" && ./.githooks/pre-commit >/dev/null 2>&1 )

    [ -z "$(git -C "$fake" ls-files -s -- bin/dr-unstaged)" ]
}

# If the script does not replace a placeholder, a live nginx configuration gets
# the literal text "@FOO@". nginx rejects it, or, worse, accepts it as a
# hostname. The test is fast, and it needs no nginx.
@test "every placeholder in the ollama-proxy template is substituted by the script" {
    local tmpl="$DR_ROOT/share/ollama-proxy/nginx.conf.template"
    local script="$DR_ROOT/share/ollama-proxy/ollama-proxy"
    [ -f "$tmpl" ] || skip "no ollama-proxy template"

    local ph missing=()
    while read -r ph; do
        [ -n "$ph" ] || continue
        grep -qF "{conf//$ph/" "$script" || missing+=("$ph")
    done < <(grep -oE '@[A-Z_]+@' "$tmpl" | sort -u)

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'in the template but never substituted by the script:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}
