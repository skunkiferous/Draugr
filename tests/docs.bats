#!/usr/bin/env bats
# The documentation, checked against the code rather than against good intentions.
#
# Docs rot silently: nothing fails when a key gains a meaning nobody wrote down,
# or when the README promises a command that was never built. These turn both
# into a red build. They check that things are *mentioned*, which is the most a
# test can do - accuracy still needs a reader.

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
    # The example file is what a new user copies and edits, so a key missing
    # there is invisible to exactly the people most likely to need it.
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
    # The other direction: a key that was renamed leaves a plausible-looking
    # setting behind that silently does nothing.
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

# --- every command the docs promise actually exists ---------------------------

# Was advisory while the README described commands that were not written yet.
# The last one, dr-code, shipped in 0.1.0, so it is blocking now: the README is
# the specification, and a specification nobody implemented is a lie.
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
    # HACKING.md is excluded deliberately: it is for people writing commands, not
    # using them, and its skeleton template is called dr-thing. Naming a command
    # in a template is not a promise that it exists; naming one in SETUP.md is.
    local cmd missing=()
    while read -r cmd; do
        [ -n "$cmd" ] || continue
        [ -f "$DR_ROOT/bin/$cmd" ] || missing+=("$cmd")
    done < <(grep -ohE '\bdr-[a-z]+' \
                 "$DR_ROOT"/docs/SETUP.md "$DR_ROOT"/docs/WORKFLOW.md \
                 "$DR_ROOT"/docs/CONFIG.md "$DR_ROOT"/docs/SECURITY.md \
                 "$DR_ROOT"/docs/TROUBLESHOOTING.md "$DR_ROOT"/docs/DESIGN.md \
             | sort -u)

    if [ ${#missing[@]} -gt 0 ]; then
        printf 'named in the docs but absent from bin/:\n' >&2
        printf '  %s\n' "${missing[@]}" >&2
        return 1
    fi
}

@test "docs: every command in bin/ is mentioned in the README" {
    # The reverse, so a command cannot ship undocumented. dr is the dispatcher
    # and is described rather than listed as a verb.
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
    # The hourglass meant "specified but not built". Nothing should carry one
    # once a release is tagged.
    ! grep -q '⏳' "$DR_ROOT/README.md"
}

# --- --help is the header comment, and only that -----------------------------
#
# Every command's help used to be `sed -n '2,Np' "$0"` with N counted by hand.
# N had gone stale in 17 of 27 commands, each ending its --help with a stray
# `set -euo pipefail`; dr-status had drifted the other way and truncated its own
# help mid-sentence. dr_help removed the counting, and these keep it removed.

@test "dr_help: prints the header and stops at the code" {
    printf '#!/usr/bin/env bash\n# tool - does a thing.\n#\n#   tool --flag\nset -euo pipefail\necho hi\n' \
        > "$DR_TMP/tool"
    # Compared as one string, not through $lines: bats builds that array with
    # IFS=newline, and newline is IFS *whitespace*, so runs of them collapse and
    # a blank line simply disappears from the array.
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
    # A file-wide disable has to sit above the first command to apply at all, so
    # it lives in the header - but it is metadata, not something --help asked for.
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
    # Only the TRAILING ones are dropped. A header's internal spacing is what
    # makes usage readable, so losing it would be a different bug.
    printf '#!/usr/bin/env bash\n# a\n#\n# b\nset -e\n' > "$DR_TMP/tool"
    run dr_help "$DR_TMP/tool"
    [ "$output" = "a

b" ]
}

@test "every command's --help contains no line of code" {
    # The regression this whole change exists for. Checked across every command
    # at once, because the failure mode was 17 of them at the same time.
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
    # Cheap proof the block was found at all: an empty or truncated help would
    # not open with "<something> - <description>". Matched on the dash rather
    # than the command name because `dr`, the dispatcher, opens with
    # "Draugr <version> - ..." and is right to.
    local bad=()
    for f in "$DR_ROOT"/bin/*; do
        name=${f##*/}
        out=$("$f" --help 2>&1) || true
        case "${out%%$'\n'*}" in
            *" - "*) ;;
            *) bad+=("$name") ;;
        esac
    done
    [ "${#bad[@]}" -eq 0 ] || {
        printf 'help has no description line: %s\n' "${bad[*]}" >&2
        return 1
    }
}
