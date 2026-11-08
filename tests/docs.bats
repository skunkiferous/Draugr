#!/usr/bin/env bats
# The documentation, tested against the code, not against good intentions.
#
# Docs decay silently. Nothing fails when a key gets a meaning that nobody wrote
# down, or when the README promises a command that nobody built. These tests
# make both a red build. They test that things are *mentioned*. A test cannot do
# more. Accuracy still needs a reader.

load helper

setup() {
    dr_test_setup
    dr_load_common
}

teardown() { dr_test_teardown; }

# --- every config key is documented -------------------------------------------

@test "docs: every DRAUGR_* key in DR_KEYS appears in docs/CONFIG.md" {
    local missing=()
    for key in "${DR_KEYS[@]}"; do
        grep -qF "$key" "$DR_ROOT/docs/CONFIG.md" || missing+=("$key")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'undocumented in docs/CONFIG.md:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "docs: every DRAUGR_* key in DR_KEYS appears in share/config.example" {
    # A new user copies and edits the example file. Thus a key that is missing
    # there is invisible to the people who most need it.
    local missing=()
    for key in "${DR_KEYS[@]}"; do
        grep -qF "$key" "$DR_ROOT/share/config.example" || missing+=("$key")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'missing from share/config.example:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "docs: config.example invents no key the code does not have" {
    # The other direction: a renamed key leaves behind a value that looks
    # correct, but silently does nothing.
    local key strays=()
    while read -r key; do
        [ -n "$key" ] || continue
        case " ${DR_KEYS[*]} " in
            *" $key "*) ;;
            *) strays+=("$key") ;;
        esac
    done < <(grep -oE '^#?DRAUGR_[A-Z_]+' "$DR_ROOT/share/config.example" \
             | tr -d '#' | sort -u)

    if [ ${#strays[@]} -gt 0 ]; then
        printf 'in share/config.example but not in DR_KEYS:\n' >&2
        printf '  %s\n' "${strays[@]}" >&2
        return 1
    fi
}

@test "docs: project.example invents no key the code does not have" {
    # project.example is a chosen SUBSET, and must stay one. A project commits
    # it, so it lists what a project usually sets, not all keys. Thus only one
    # direction. This cannot see a key that must be here and is not. That stays
    # a decision for a person. But it catches the rename that leaves a dead
    # value that looks correct in the copy of each repo.
    local key strays=()
    while read -r key; do
        [ -n "$key" ] || continue
        case " ${DR_KEYS[*]} " in
            *" $key "*) ;;
            *) strays+=("$key") ;;
        esac
    done < <(grep -oE '^#?DRAUGR_[A-Z_]+' "$DR_ROOT/share/project.example" \
             | tr -d '#' | sort -u)

    if [ ${#strays[@]} -gt 0 ]; then
        printf 'in share/project.example but not in DR_KEYS:\n' >&2
        printf '  %s\n' "${strays[@]}" >&2
        return 1
    fi
}

# --- each command that the docs promise really exists ------------------------

# This was advisory while the README described commands that did not exist yet.
# The last one, dr-code, shipped in 0.1.0, so now it blocks. The README is the
# specification, and a specification that nobody implemented is a lie.
@test "docs: every dr-* named in the README exists in bin/" {
    local cmd missing=()
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        [ -f "$DR_ROOT/bin/$cmd" ] || missing+=("$cmd")
    done < <(grep -ohE '\bdr-[a-z]+' "$DR_ROOT/README.md" | sort -u)

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'named in README.md but absent from bin/:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "docs: every dr-* named in the user-facing docs exists in bin/" {
    # HACKING.md is excluded, on purpose. It is for people who write commands,
    # not for people who use them, and its skeleton template is called dr-thing.
    # A command name in a template does not promise that it exists. A name in
    # SETUP.md does.
    local cmd missing=()
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        [ -f "$DR_ROOT/bin/$cmd" ] || missing+=("$cmd")
    done < <(grep -ohE '\bdr-[a-z]+' \
                 "$DR_ROOT"/docs/SETUP.md "$DR_ROOT"/docs/WORKFLOW.md \
                 "$DR_ROOT"/docs/CONFIG.md "$DR_ROOT"/docs/SECURITY.md \
                 "$DR_ROOT"/docs/TROUBLESHOOTING.md "$DR_ROOT"/docs/DESIGN.md \
                 "$DR_ROOT"/docs/CLAUDE_PLUGINS.md \
             | sort -u)

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'named in the docs but absent from bin/:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "docs: every command in bin/ is mentioned in the README" {
    # The reverse, so that a command cannot ship with no documentation. dr is
    # the dispatcher. The docs describe it, and do not list it as a verb.
    local f cmd missing=()
    for f in "$DR_ROOT"/bin/dr-*; do
        cmd=${f##*/}
        grep -qF "$cmd" "$DR_ROOT/README.md" || missing+=("$cmd")
    done

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'in bin/ but not mentioned in README.md:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

# --- the release itself ---------------------------------------------------------

@test "docs: the CHANGELOG has an entry for the current version" {
    grep -qF "[$DRAUGR_VERSION]" "$DR_ROOT/CHANGELOG.md"
}

@test "docs: no unimplemented-command markers are left in the README" {
    # The hourglass meant "specified but not built". After a release tag,
    # nothing must have one.
    ! grep -q '⏳' "$DR_ROOT/README.md"
}

# --- --help is the header comment, and only that -----------------------------
#
# Before, the help of each command was `sed -n '2,Np' "$0"`, with N counted by
# hand. N was wrong in 17 of 27 commands. Each ended its --help with a stray
# `set -euo pipefail`. dr-status was wrong the other way, and cut its own help
# in the middle of a sentence. dr_help removed the count, and these tests keep
# it removed.

@test "dr_help: prints the header and stops at the code" {
    printf '#!/usr/bin/env bash\n# tool - does a thing.\n#\n#   tool --flag\nset -euo pipefail\necho hi\n' \
        > "$DR_TMP/tool"
    # Compared as one string, not through $lines. bats builds that array with
    # IFS=newline, and newline is IFS *whitespace*. Thus a run of them
    # collapses, and a blank line disappears from the array.
    run dr_help "$DR_TMP/tool"
    [ "$output" = "tool - does a thing.

  tool --flag" ]
}

@test "dr_help: the shebang is never part of the help" {
    printf '#!/usr/bin/env bash\n# tool - x\nset -e\n' > "$DR_TMP/tool"
    run dr_help "$DR_TMP/tool"
    [[ "$output" != *"usr/bin/env"* ]]
}

@test "dr_help: a shellcheck directive ends the block" {
    # A file-wide disable must be above the first command, or it does not apply.
    # Thus it is in the header. But it is metadata, not part of --help.
    printf '#!/usr/bin/env bash\n# tool - x\n#\n# shellcheck disable=SC2016\n# because reasons\nset -e\n' \
        > "$DR_TMP/tool"
    run dr_help "$DR_TMP/tool"
    [ "$output" = "tool - x" ]
}

@test "dr_help: no trailing blank line" {
    printf '#!/usr/bin/env bash\n# tool - x\n#\nset -e\n' > "$DR_TMP/tool"
    run dr_help "$DR_TMP/tool"
    [ "$output" = "tool - x" ]
}

@test "dr_help: blank lines inside the block are kept" {
    # Only the TRAILING ones are dropped. The internal spacing of a header makes
    # the usage readable, so a loss of it is a different bug.
    printf '#!/usr/bin/env bash\n# a\n#\n# b\nset -e\n' > "$DR_TMP/tool"
    run dr_help "$DR_TMP/tool"
    [ "$output" = "a

b" ]
}

@test "every command's --help contains no line of code" {
    # The regression that this full change is for. Tested across all commands
    # at once, because the failure was 17 of them at the same time.
    local bad=()
    for f in "$DR_ROOT"/bin/* "$DR_ROOT/install.sh"; do
        out=$("$f" --help 2>&1) || true
        if printf '%s' "$out" | grep -qE '^(set -|DR_PROG=|_dr_bin=|\. "|awk |shellcheck)'; then
            bad+=("${f##*/}")
        fi
    done
    [ "${#bad[@]}" -eq 0 ] || {
        printf 'help leaks code: %s\n' "${bad[*]}" >&2
        return 1
    }
}

@test "every command's --help opens with a description line" {
    # A cheap proof that the block was found. An empty or cut help does not
    # open with "<something>: <description>". Matched on the colon, not on the
    # command name, because `dr`, the dispatcher, opens with "Draugr <version>:
    # ...", and that is correct.
    local bad=()
    for f in "$DR_ROOT"/bin/*; do
        name=${f##*/}
        out=$("$f" --help 2>&1) || true
        case "${out%%$'\n'*}" in
            *": "*) ;;
            *) bad+=("$name") ;;
        esac
    done
    [ "${#bad[@]}" -eq 0 ] || {
        printf 'help has no description line: %s\n' "${bad[*]}" >&2
        return 1
    }
}
